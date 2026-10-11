/* Real fs/poll.c + real epoll/kqueue. Guest tasks, a virtual readiness source,
 * sockrestart bookkeeping and monotonic time are supplied by this fixture.
 * An old last-progress timestamp must not turn healthy idle into process exit. */
#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <malloc/malloc.h>
#endif
#include "kernel/task.h"
#include "kernel/errno.h"
#include "fs/poll.h"
#include "fs/real.h"
#include "fs/sockrestart.h"
#include "fs/dsh-lifecycle.h"

__thread struct task *current;
lock_t pids_lock = LOCK_INITIALIZER;
static struct task guest;
static struct tgroup group;
static struct sighand sighand;
static struct fd event_fd;
static struct poll *test_poll;
static pthread_mutex_t control = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t changed = PTHREAD_COND_INITIALIZER;
static bool waiting, cycled, exited, finished;
static unsigned listen_begins, listen_ends;
static atomic_int readiness;
static int result, callbacks;

int lifecycle_test_clock_gettime(clockid_t clock_id, struct timespec *time) {
    if (clock_id == CLOCK_MONOTONIC) { *time = (struct timespec) {.tv_sec = 120}; return 0; }
    return clock_gettime(clock_id, time);
}
static struct timespec deadline(unsigned milliseconds) {
    struct timespec end;
    assert(clock_gettime(CLOCK_REALTIME, &end) == 0);
    end.tv_sec += milliseconds / 1000;
    end.tv_nsec += (long) (milliseconds % 1000) * 1000000;
    if (end.tv_nsec >= 1000000000) { end.tv_sec++; end.tv_nsec -= 1000000000; }
    return end;
}
static bool await_flag(bool *flag, unsigned milliseconds) {
    struct timespec end = deadline(milliseconds);
    assert(pthread_mutex_lock(&control) == 0);
    int error = 0;
    while (!*flag && error == 0) error = pthread_cond_timedwait(&changed, &control, &end);
    assert(error == 0 || error == ETIMEDOUT);
    bool value = *flag;
    assert(pthread_mutex_unlock(&control) == 0);
    return value;
}
static void set_flag(bool *flag) {
    assert(pthread_mutex_lock(&control) == 0);
    *flag = true;
    assert(pthread_cond_broadcast(&changed) == 0);
    assert(pthread_mutex_unlock(&control) == 0);
}
static struct dsh_lifecycle_snapshot snapshot(void) {
    struct dsh_lifecycle_snapshot value;
    dsh_lifecycle_get_snapshot(&value);
    return value;
}
static void assert_wait_cleaned(void) {
    assert(test_poll->waiters == 0 && test_poll->notify_pipe[0] == -1 && test_poll->notify_pipe[1] == -1);
    assert(pthread_mutex_trylock(&test_poll->lock.m) == 0);
    assert(pthread_mutex_unlock(&test_poll->lock.m) == 0);
    assert(pthread_mutex_trylock(&pids_lock.m) == 0);
    assert(pthread_mutex_unlock(&pids_lock.m) == 0);
    assert(pthread_mutex_trylock(&group.lock.m) == 0);
    assert(pthread_mutex_unlock(&group.lock.m) == 0);
    assert(listen_begins > 0 && listen_begins == listen_ends);
}
/* Keep this symbol for the pre-fix negative control: production must never
 * decide to end a healthy process merely because poll has been idle. */
_Noreturn void do_exit_group(int status) {
    assert_wait_cleaned();
    fprintf(stderr, "UNEXPECTED idle poll process exit: status=%d\n", status);
    exited = true;
    pthread_exit(NULL);
}
int errno_map(void) { return -errno; }
int realfs_poll(struct fd *fd) { (void) fd; return 0; }
void sockrestart_begin_listen_wait(struct fd *fd) {
    assert(fd == &event_fd);
    listen_begins++;
    set_flag(&waiting);
    if (listen_begins >= 2) set_flag(&cycled);
}
void sockrestart_end_listen_wait(struct fd *fd) {
    assert(fd == &event_fd);
    listen_ends++;
}
bool sockrestart_should_restart_listen_wait(void) { return false; }
void ish_printk(const char *format, ...) { (void) format; }
static int source_poll(struct fd *fd) {
    assert(fd == &event_fd);
    return atomic_load(&readiness);
}
static const struct fd_ops source_ops = {.poll = source_poll};
static int callback(void *context, int types, union poll_fd_info info) {
    assert(context == &event_fd && types == POLL_READ && info.num == 73);
    callbacks++;
    return 1;
}
static void finished_cleanup(void *unused) {
    (void) unused;
    assert_wait_cleaned();
    poll_destroy(test_poll);
    assert(list_empty(&event_fd.poll_fds));
    dsh_lifecycle_thread_exit();
    set_flag(&finished);
}
static void *run_poll(void *timed) {
    current = &guest;
    pthread_cleanup_push(finished_cleanup, NULL);
    struct timespec timeout = {.tv_sec = 1};
    result = poll_wait(test_poll, callback, &event_fd, timed ? &timeout : NULL);
    pthread_cleanup_pop(1);
    return NULL;
}
static pthread_t start_poll(bool timed) {
    waiting = cycled = exited = finished = false;
    listen_begins = listen_ends = 0;
    result = callbacks = 0;
    guest.pending = 0;
    atomic_store(&readiness, 0);
    test_poll = poll_create();
    assert(!IS_ERR(test_poll));
    assert(poll_add_fd(test_poll, &event_fd, 3, POLL_READ, (union poll_fd_info) {.num = 73}) == 0);
    pthread_t thread;
    assert(pthread_create(&thread, NULL, run_poll, timed ? &group : NULL) == 0);
    assert(await_flag(&waiting, 5000));
    return thread;
}
static void finish_poll(pthread_t thread, int expected) {
    assert(await_flag(&finished, 5000));
    assert(pthread_join(thread, NULL) == 0);
    assert(!exited && result == expected);
    assert(callbacks == (expected == 1 ? 1 : 0));
    assert(snapshot().active_operations == 0);
}
static void wake_event(void) {
    atomic_store(&readiness, POLL_READ);
    poll_wakeup(&event_fd, POLL_READ);
}
static void wake_signal(void) {
    lock(&sighand.lock);
    guest.pending = 1;
    unlock(&sighand.lock);
    poll_wakeup(&event_fd, POLL_READ);
}
static void require_idle_alive(void) {
    /* The monotonic fixture reports 120s while last_progress is 0. Observe
     * the next real backend wait, rather than guess at scheduler wall time:
     * the old idle kill runs before it can begin that second wait. */
    struct timespec end = deadline(5000);
    assert(pthread_mutex_lock(&control) == 0);
    int error = 0;
    while (!cycled && !finished && error == 0)
        error = pthread_cond_timedwait(&changed, &control, &end);
    assert(error == 0 || error == ETIMEDOUT);
    bool alive = cycled && !finished;
    assert(pthread_mutex_unlock(&control) == 0);
    if (!alive) {
        fprintf(stderr, "idle poll ended unexpectedly: exited=%d result=%d begins=%u ends=%u\n",
                exited, result, listen_begins, listen_ends);
        assert(false);
    }
    assert(snapshot().active_operations == 0);
}
int main(int argc, char **argv) {
    assert(argc == 2);
    alarm(20);
    bool group_exit = strcmp(argv[1], "group-exit") == 0;
    bool stale_case = strcmp(argv[1], "stale") == 0;
    bool recent_resume = strcmp(argv[1], "recent-resume") == 0;
    bool quiescing = strcmp(argv[1], "quiescing") == 0;
    bool idle = strcmp(argv[1], "idle") == 0;
    assert(group_exit || stale_case || recent_resume || quiescing || idle);
    lock_init(&group.lock);
    lock_init(&sighand.lock);
    lock_init(&event_fd.poll_lock);
    list_init(&event_fd.poll_fds);
    event_fd.ops = &source_ops;
    list_init(&group.threads);
    list_init(&guest.children);
    list_add(&group.threads, &guest.group_links);
    guest.pid = 2;
    guest.group = &group;
    guest.sighand = &sighand;
    atomic_store(&group.last_progress_ns, 0);
    dsh_lifecycle_enable_admission_gate();
    if (recent_resume) {
        dsh_lifecycle_request_quiesce();
        dsh_lifecycle_begin_resume();
        dsh_lifecycle_resume();
        struct dsh_lifecycle_snapshot value = snapshot();
        assert(value.state == DSH_LIFECYCLE_RUNNING && value.last_resume_monotonic_ns == 120000000000ULL);
        dsh_lifecycle_resume();
        assert(snapshot().generation == value.generation);
    } else if (quiescing) {
        uint64_t generation = dsh_lifecycle_request_quiesce();
        assert(dsh_lifecycle_request_quiesce() == generation);
    }
    if (group_exit) group.doing_group_exit = true;
    pthread_t thread = start_poll(recent_resume || quiescing);
    if (stale_case) {
        uint64_t generation = dsh_lifecycle_request_quiesce();
        assert(dsh_lifecycle_request_quiesce() == generation);
        assert(dsh_lifecycle_mark_quiescent(generation));
        assert(snapshot().state == DSH_LIFECYCLE_QUIESCENT);
        assert(!await_flag(&finished, 50));
        dsh_lifecycle_begin_resume();
        struct dsh_lifecycle_snapshot value = snapshot();
        dsh_lifecycle_begin_resume();
        assert(value.state == DSH_LIFECYCLE_RESUMING && snapshot().generation == value.generation);
        assert(!await_flag(&finished, 50));
        dsh_lifecycle_resume();
        assert(snapshot().state == DSH_LIFECYCLE_RUNNING);
        require_idle_alive();
        wake_event();
        finish_poll(thread, 1);
    } else if (idle) {
        require_idle_alive();
        wake_event();
        finish_poll(thread, 1);
        atomic_store(&group.last_progress_ns, 0);
        thread = start_poll(false);
        require_idle_alive();
        wake_signal();
        finish_poll(thread, _EINTR);
    } else {
        finish_poll(thread, group_exit ? _EINTR : 0);
        if (quiescing) {
            struct dsh_lifecycle_snapshot value = snapshot();
            assert(value.state == DSH_LIFECYCLE_QUIESCING);
            assert(dsh_lifecycle_request_quiesce() == value.generation);
            assert(dsh_lifecycle_mark_quiescent(value.generation));
            assert(!dsh_lifecycle_mark_quiescent(value.generation));
            assert(snapshot().state == DSH_LIFECYCLE_QUIESCENT);
        }
    }
    alarm(0);
    printf("PASS production poll_wait %s: healthy wait semantics; locks/waiters/pipe cleaned\n", argv[1]);
    return 0;
}
