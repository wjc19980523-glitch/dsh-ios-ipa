/* Compile the complete production exit.c below. The fixtures supply task/PID
 * setup and unrelated resource/guest-memory services; no exit algorithm is
 * copied or mocked. do_exit/do_exit_group really terminate host pthreads.
 * Resource pointers remain NULL, so mm/files/fs teardown is outside this test.
 */
#if defined(__APPLE__)
#include <malloc/malloc.h>
#endif
#include <assert.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "kernel/calls.h"
#include "kernel/task.h"
#include "kernel/futex.h"
#include "fs/fd.h"

__thread struct task *current;
lock_t pids_lock = LOCK_INITIALIZER;
lock_t mounts_lock = LOCK_INITIALIZER;
struct list mounts = LIST_INITIALIZER(mounts);

#define FIXTURE_THREADS 4
struct fixture {
    struct task init, tasks[FIXTURE_THREADS];
    // Intrusive list iteration forms a sentinel container pointer. Place the
    // fixture list heads at the same alignment residue as task.group_links so
    // even that non-dereferenced sentinel passes UBSan's alignment check.
    _Alignas(struct task) unsigned char init_group_alignment[
        offsetof(struct task, group_links) % _Alignof(struct task)];
    struct tgroup init_group;
    _Alignas(struct task) unsigned char group_alignment[
        offsetof(struct task, group_links) % _Alignof(struct task)];
    struct tgroup group;
    atomic_bool delivered[FIXTURE_THREADS], start;
    atomic_uint hook_calls, log_calls, pidfd_calls, destroyed;
    int reported_pid, reported_status, reported_last_tid;
    int count;
};
static struct fixture *active;

/* These shims are observable or fail loudly. In particular the fixture never
 * supplies a second implementation of exit/group-status selection. */
void dump_pc_hist(void) {}
void dump_pc_trace(void) {}
void dump_wx_stats(void) {}
void dump_stage_trace(void) {}
void dump_block_prof(void) {}
void mm_release(struct mm *mm) { (void)mm; assert(false); }
void fdtable_release(struct fdtable *files) { (void)files; assert(false); }
void fs_info_release(struct fs_info *fs) { (void)fs; assert(false); }
void sighand_release(struct sighand *sighand) { (void)sighand; assert(false); }
void timer_free(struct timer *timer) { (void)timer; assert(false); }
void cpu_poke(struct cpu_state *cpu) { (void)cpu; assert(false); }
int mount_remove(struct mount *mount) { (void)mount; assert(false); return _EIO; }
int user_write(addr_t address, const void *buffer, size_t size) {
    (void)address; (void)buffer; (void)size; assert(false); return 1;
}
int futex_wake(addr_t address, dword_t count) {
    (void)address; (void)count; assert(false); return 0;
}
void vfork_notify(struct task *task) { assert(task->vfork == NULL); }
void task_leave_session(struct task *task) { (void)task; assert(false); }
struct rusage_ rusage_get_current(void) { return (struct rusage_) {}; }
void rusage_add(struct rusage_ *destination, struct rusage_ *source) {
    (void)destination; (void)source;
}
struct task *pid_get_task(dword_t pid) {
    if (pid == 1) return &active->init;
    for (int i = 0; i < active->count; i++)
        if ((dword_t)active->tasks[i].pid == pid && !active->tasks[i].zombie)
            return &active->tasks[i];
    return NULL;
}
struct task *pid_get_task_zombie(dword_t pid) {
    if (pid == 1) return &active->init;
    for (int i = 0; i < active->count; i++)
        if ((dword_t)active->tasks[i].pid == pid) return &active->tasks[i];
    return NULL;
}
void pidfd_notify_exit(pid_t_ pid) {
    assert(pid == active->tasks[0].pid);
    atomic_fetch_add(&active->pidfd_calls, 1);
}
void task_destroy(struct task *task) {
    // Production retains the leader until wait/reap. Our stack-backed fixture
    // mirrors removal of the worker from its parent's children without freeing.
    assert(task != &active->tasks[0] && task->exiting);
    list_remove(&task->siblings);
    atomic_fetch_add(&active->destroyed, 1);
}
void send_signal(struct task *task, int signal, struct siginfo_ info) {
    (void)task; (void)signal; (void)info;
    // exit_signal=0 prevents this unrelated parent-signal path in the fixture.
    assert(false);
}
void deliver_signal(struct task *task, int signal, struct siginfo_ info) {
    (void)info;
    assert(signal == SIGKILL_);
    ptrdiff_t index = task - active->tasks;
    assert(index >= 0 && index < active->count);
    atomic_store(&active->delivered[index], true);
}
void ish_printk(const char *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    assert(strcmp(format, "[dsh-ios] guest exit: leader=%d last_tid=%d wait_status=%d\n") == 0);
    int leader = va_arg(arguments, int);
    int last_tid = va_arg(arguments, int);
    int status = va_arg(arguments, int);
    va_end(arguments);
    assert(leader == active->tasks[0].pid);
    assert(last_tid == current->pid);
    active->reported_last_tid = last_tid;
    active->reported_status = status;
    atomic_fetch_add(&active->log_calls, 1);
}

// This is the production translation unit, including its actual final-thread
// decision, group-exit coordination, hook call and wait-status calculation.
#include "../ish-arm64/kernel/exit.c"

static void capture_exit(struct task *task, int status) {
    assert(task == &active->tasks[0]);
    assert(task->zombie);
    // The real iOS hook filters grandchildren, so the leader identity must also
    // preserve the init-child relationship, not merely substitute a PID later.
    assert(task->parent == &active->init && task->parent->parent == NULL);
    assert(status == active->reported_status);
    active->reported_pid = task->pid;
    atomic_fetch_add(&active->hook_calls, 1);
}

static void initialize_task(struct task *task, struct tgroup *group, int pid) {
    memset(task, 0, sizeof(*task));
    task->pid = pid;
    task->tgid = group->leader ? group->leader->pid : pid;
    task->group = group;
    task->futex_pipe[0] = task->futex_pipe[1] = -1;
    list_init(&task->children);
    list_init(&task->siblings);
    list_init(&task->queue);
    list_add_tail(&group->threads, &task->group_links);
}
static void initialize_group(struct tgroup *group) {
    memset(group, 0, sizeof(*group));
    list_init(&group->threads);
    lock_init(&group->lock);
    cond_init(&group->child_exit);
    cond_init(&group->stopped_cond);
}
static void initialize_fixture(struct fixture *fixture, int count) {
    memset(fixture, 0, sizeof(*fixture));
    active = fixture;
    fixture->count = count;
    initialize_group(&fixture->init_group);
    initialize_group(&fixture->group);
    initialize_task(&fixture->init, &fixture->init_group, 1);
    fixture->init_group.leader = &fixture->init;
    for (int i = 0; i < count; i++) {
        initialize_task(&fixture->tasks[i], &fixture->group, 7 + i);
        if (i == 0) fixture->group.leader = &fixture->tasks[0];
        fixture->tasks[i].parent = i == 0 ? &fixture->init : &fixture->tasks[0];
        list_add_tail(&fixture->tasks[i].parent->children, &fixture->tasks[i].siblings);
    }
    exit_hook = capture_exit;
}
static void destroy_fixture(struct fixture *fixture) {
    assert(atomic_load(&fixture->destroyed) == (unsigned)fixture->count - 1);
    cond_destroy(&fixture->group.child_exit);
    cond_destroy(&fixture->group.stopped_cond);
    cond_destroy(&fixture->init_group.child_exit);
    cond_destroy(&fixture->init_group.stopped_cond);
    assert(pthread_mutex_destroy(&fixture->group.lock.m) == 0);
    assert(pthread_mutex_destroy(&fixture->init_group.lock.m) == 0);
    active = NULL;
}
struct exiting_thread {
    struct task *task;
    int status;
    bool group_exit, await_delivery, await_start;
};
static void *run_exit(void *argument) {
    struct exiting_thread *thread = argument;
    current = thread->task;
    while (thread->await_start && !atomic_load(&active->start)) usleep(100);
    int index = (int)(current - active->tasks);
    while (thread->await_delivery && !atomic_load(&active->delivered[index])) usleep(100);
    if (thread->group_exit) do_exit_group(thread->status);
    do_exit(thread->status);
}
static pthread_t launch_exit(struct exiting_thread *thread) {
    pthread_t host;
    assert(pthread_create(&host, NULL, run_exit, thread) == 0);
    return host;
}
static void join_exit(pthread_t thread) { assert(pthread_join(thread, NULL) == 0); }
static void assert_report(struct fixture *fixture, int last_tid, int expected_status) {
    assert(atomic_load(&fixture->hook_calls) == 1);
    assert(atomic_load(&fixture->log_calls) == 1);
    assert(atomic_load(&fixture->pidfd_calls) == 1);
    assert(fixture->reported_pid == 7);
    assert(fixture->reported_last_tid == last_tid);
    assert(fixture->reported_status == expected_status);
    assert(list_empty(&fixture->group.threads));
    // Compare the callback with the actual production wait/reap calculation.
    // WNOWAIT leaves the fixture leader/group owned by this test.
    struct siginfo_ info = {};
    lock(&pids_lock);
    assert(reap_if_zombie(&fixture->tasks[0], &info, NULL, WNOWAIT_));
    unlock(&pids_lock);
    assert(info.child.status == expected_status);
}
static void ordered_normal_exit(bool worker_last) {
    for (int iteration = 0; iteration < 50; iteration++) {
        struct fixture fixture;
        initialize_fixture(&fixture, 2);
        struct exiting_thread leader = {.task = &fixture.tasks[0], .status = 23 << 8};
        struct exiting_thread worker = {.task = &fixture.tasks[1], .status = 91 << 8};
        join_exit(launch_exit(worker_last ? &leader : &worker));
        assert(atomic_load(&fixture.hook_calls) == 0);
        assert(!fixture.tasks[0].zombie);
        join_exit(launch_exit(worker_last ? &worker : &leader));
        assert_report(&fixture, worker_last ? 8 : 7, 23 << 8);
        destroy_fixture(&fixture);
    }
    puts(worker_last ? "ok guest-exit: worker-last preserves leader identity/status (50 loops)"
                     : "ok guest-exit: leader-last notifies exactly once (50 loops)");
}
static void ordered_group_exit(bool worker_first) {
    for (int iteration = 0; iteration < 10; iteration++) {
        struct fixture fixture;
        initialize_fixture(&fixture, 2);
        int caller = worker_first ? 1 : 0;
        int peer = !caller;
        int expected_status = worker_first ? SIGKILL_ : 37 << 8;
        struct exiting_thread first = {.task = &fixture.tasks[caller], .status = expected_status, .group_exit = true};
        struct exiting_thread other = {.task = &fixture.tasks[peer], .status = 91 << 8, .await_delivery = true};
        pthread_t other_host = launch_exit(&other);
        pthread_t first_host = launch_exit(&first);
        join_exit(other_host);
        join_exit(first_host);
        assert_report(&fixture, 7 + caller, expected_status);
        destroy_fixture(&fixture);
    }
    puts(worker_first ? "ok guest-exit: worker initiates exit_group signal status (10 loops)"
                     : "ok guest-exit: leader initiates exit_group status (10 loops)");
}
static void group_status_overrides_last_thread(void) {
    for (int iteration = 0; iteration < 25; iteration++) {
        struct fixture fixture;
        initialize_fixture(&fixture, 2);
        // Model threads that already selected local sys_exit statuses before
        // another thread selected a process-wide exit_group status. The real
        // do_exit final-thread path must still report the group-wide status.
        fixture.group.doing_group_exit = true;
        fixture.group.group_exit_code = 44 << 8;
        struct exiting_thread leader = {.task = &fixture.tasks[0], .status = 23 << 8};
        struct exiting_thread worker = {.task = &fixture.tasks[1], .status = 91 << 8};
        join_exit(launch_exit(&leader));
        assert(atomic_load(&fixture.hook_calls) == 0);
        join_exit(launch_exit(&worker));
        assert_report(&fixture, 8, 44 << 8);
        destroy_fixture(&fixture);
    }
    puts("ok guest-exit: group status overrides different leader/last-thread statuses (25 loops)");
}
static void concurrent_group_exit(void) {
    for (int iteration = 0; iteration < 30; iteration++) {
        struct fixture fixture;
        initialize_fixture(&fixture, FIXTURE_THREADS);
        pthread_t hosts[FIXTURE_THREADS];
        struct exiting_thread threads[FIXTURE_THREADS];
        for (int i = 0; i < FIXTURE_THREADS; i++) {
            threads[i] = (struct exiting_thread){.task = &fixture.tasks[i], .status = (40 + i) << 8,
                                               .group_exit = true, .await_start = true};
            hosts[i] = launch_exit(&threads[i]);
        }
        atomic_store(&fixture.start, true);
        for (int i = 0; i < FIXTURE_THREADS; i++) join_exit(hosts[i]);
        int winner_status = fixture.group.group_exit_code;
        assert(winner_status >= (40 << 8) && winner_status <= (43 << 8));
        assert_report(&fixture, fixture.reported_last_tid, winner_status);
        destroy_fixture(&fixture);
    }
    puts("ok guest-exit: four concurrent exit_group callers notify exactly once (30 loops)");
}
int main(void) {
    alarm(30);
    unsetenv("ISH_PC_HIST_DIR");
    ordered_normal_exit(false);
    ordered_normal_exit(true);
    ordered_group_exit(false);
    ordered_group_exit(true);
    group_status_overrides_last_thread();
    concurrent_group_exit();
    puts("PASS guest-exit: real production do_exit/do_exit_group and wait-status agreement");
    return 0;
}
