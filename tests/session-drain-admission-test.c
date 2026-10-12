/* Production lifecycle core + real pthread workers/native flock. The host is
 * responsible for authenticating the managed Harness group; these tests cover
 * the admission boundary after that decision, including late callbacks. */
#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)
#define _DARWIN_C_SOURCE 1
#endif
#include "fs/dsh-lifecycle.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <sys/file.h>
#include <time.h>
#include <unistd.h>

enum phase { CREATED, ATTEMPTING, ENTERED, DONE };
struct worker {
    pthread_mutex_t lock;
    pthread_cond_t changed;
    enum phase phase;
    bool finish, checkpoint;
    int pid, tgid, operation_pid;
    int close_fd;
    const void *close_key;
};

static struct dsh_lifecycle_snapshot snapshot(void) {
    struct dsh_lifecycle_snapshot value;
    dsh_lifecycle_get_snapshot(&value);
    return value;
}
static struct timespec deadline(unsigned milliseconds) {
    struct timespec end;
    assert(clock_gettime(CLOCK_REALTIME, &end) == 0);
    end.tv_sec += milliseconds / 1000;
    end.tv_nsec += (long)(milliseconds % 1000) * 1000000;
    if (end.tv_nsec >= 1000000000) { end.tv_sec++; end.tv_nsec -= 1000000000; }
    return end;
}
static void announce(struct worker *worker, enum phase phase) {
    assert(pthread_mutex_lock(&worker->lock) == 0);
    assert(phase > worker->phase);
    worker->phase = phase;
    assert(pthread_cond_broadcast(&worker->changed) == 0);
    assert(pthread_mutex_unlock(&worker->lock) == 0);
}
static bool await_phase(struct worker *worker, enum phase phase, unsigned milliseconds) {
    struct timespec end = deadline(milliseconds);
    assert(pthread_mutex_lock(&worker->lock) == 0);
    int result = 0;
    while (worker->phase < phase && result == 0)
        result = pthread_cond_timedwait(&worker->changed, &worker->lock, &end);
    assert(result == 0 || result == ETIMEDOUT);
    bool reached = worker->phase >= phase;
    assert(pthread_mutex_unlock(&worker->lock) == 0);
    return reached;
}
static void *work(void *argument) {
    struct worker *worker = argument;
    struct dsh_lifecycle_guest_context previous = dsh_lifecycle_exchange_guest_context(
        (struct dsh_lifecycle_guest_context){worker->pid, worker->tgid});
    announce(worker, ATTEMPTING);
    /* No caller mutex, SQLite mutex or native flock is held by this waiter.
     * Both pure wait checkpoints and ordinary syscall scopes use this gate. */
    if (worker->checkpoint) dsh_lifecycle_checkpoint(worker->operation_pid);
    uint64_t token = dsh_lifecycle_operation_begin("session_drain_worker", worker->operation_pid);
    announce(worker, ENTERED);
    if (worker->close_fd >= 0) {
        assert(flock(worker->close_fd, LOCK_UN) == 0);
        assert(close(worker->close_fd) == 0);
        dsh_lifecycle_native_flock_close(worker->close_key);
    }
    assert(pthread_mutex_lock(&worker->lock) == 0);
    struct timespec end = deadline(5000);
    while (!worker->finish)
        assert(pthread_cond_timedwait(&worker->changed, &worker->lock, &end) == 0);
    assert(pthread_mutex_unlock(&worker->lock) == 0);
    dsh_lifecycle_operation_end(token);
    dsh_lifecycle_restore_guest_context(&previous);
    dsh_lifecycle_thread_exit();
    announce(worker, DONE);
    return NULL;
}
static struct worker worker(int pid, int tgid) {
    return (struct worker){.pid = pid, .tgid = tgid, .operation_pid = pid, .close_fd = -1};
}
static pthread_t launch(struct worker *worker) {
    assert(pthread_mutex_init(&worker->lock, NULL) == 0);
    assert(pthread_cond_init(&worker->changed, NULL) == 0);
    pthread_t thread;
    assert(pthread_create(&thread, NULL, work, worker) == 0);
    assert(await_phase(worker, ATTEMPTING, 5000));
    return thread;
}
static void joined(struct worker *worker, pthread_t thread) {
    assert(await_phase(worker, ENTERED, 5000));
    assert(pthread_mutex_lock(&worker->lock) == 0);
    worker->finish = true;
    assert(pthread_cond_broadcast(&worker->changed) == 0);
    assert(pthread_mutex_unlock(&worker->lock) == 0);
    assert(await_phase(worker, DONE, 5000));
    assert(pthread_join(thread, NULL) == 0);
    assert(pthread_cond_destroy(&worker->changed) == 0);
    assert(pthread_mutex_destroy(&worker->lock) == 0);
}
static void blocked(struct worker *worker) {
    assert(!await_phase(worker, ENTERED, 50));
    /* The admission condvar drops diagnostic_lock. These observations and
     * trylock prove the blocked waiter does not pin either test mutex. */
    assert(pthread_mutex_trylock(&worker->lock) == 0);
    assert(pthread_mutex_unlock(&worker->lock) == 0);
    (void)snapshot();
}

static void test_group_admission_and_resume(void) {
    uint64_t generation = dsh_lifecycle_request_quiesce();
    struct worker first = worker(43, 42), second = worker(44, 42);
    second.checkpoint = true;
    struct worker outsider = worker(99, 99), no_context = worker(42, -1);
    struct worker mismatched = worker(45, 42), native = worker(46, 42);
    mismatched.operation_pid = 55;
    native.operation_pid = -1;
    pthread_t a = launch(&first), b = launch(&second), c = launch(&outsider);
    pthread_t d = launch(&no_context), e = launch(&mismatched), f = launch(&native);
    blocked(&first); blocked(&second);
    assert(!dsh_lifecycle_grant_session_drain(-1, generation));
    assert(!dsh_lifecycle_grant_session_drain(42, generation + 1));
    assert(dsh_lifecycle_grant_session_drain(42, generation));
    assert(dsh_lifecycle_grant_session_drain(42, generation));
    assert(!dsh_lifecycle_grant_session_drain(99, generation));
    assert(await_phase(&first, ENTERED, 5000) && await_phase(&second, ENTERED, 5000));
    blocked(&outsider); blocked(&no_context); blocked(&mismatched); blocked(&native);
    assert(snapshot().active_operations == 2);
    joined(&first, a); joined(&second, b);
    assert(snapshot().active_operations == 0);
    assert(snapshot().session_drain_active && snapshot().session_drain_guest_tgid == 42);
    assert(!dsh_lifecycle_mark_quiescent(generation));
    puts("PASS authenticated group workers drain through scope/checkpoint; native and unrelated guests remain blocked");

    assert(!dsh_lifecycle_revoke_session_drain(99, generation));
    assert(dsh_lifecycle_revoke_session_drain(42, generation));
    assert(dsh_lifecycle_revoke_session_drain(42, generation));
    assert(!dsh_lifecycle_grant_session_drain(42, generation));
    struct worker after_ack = worker(47, 42);
    pthread_t g = launch(&after_ack);
    blocked(&after_ack);
    assert(dsh_lifecycle_mark_quiescent(generation));
    assert(!dsh_lifecycle_grant_session_drain(42, generation));
    puts("PASS acknowledgement revokes and seals the generation before verified quiescence; new Node work is blocked");

    dsh_lifecycle_begin_resume();
    uint64_t resume_generation = snapshot().generation;
    assert(resume_generation != generation && snapshot().state == DSH_LIFECYCLE_RESUMING);
    assert(!dsh_lifecycle_grant_session_drain(42, generation));
    assert(dsh_lifecycle_grant_session_drain(42, resume_generation));
    assert(!dsh_lifecycle_revoke_session_drain(42, generation));
    dsh_lifecycle_begin_resume();
    assert(snapshot().generation == resume_generation && snapshot().session_drain_active);
    assert(await_phase(&after_ack, ENTERED, 5000));
    blocked(&outsider); blocked(&no_context); blocked(&mismatched); blocked(&native);
    joined(&after_ack, g);
    assert(dsh_lifecycle_revoke_session_drain(42, resume_generation));
    assert(!dsh_lifecycle_mark_quiescent(resume_generation));
    dsh_lifecycle_resume();
    joined(&outsider, c); joined(&no_context, d); joined(&mismatched, e); joined(&native, f);
    assert(!snapshot().session_drain_active && snapshot().active_operations == 0);
    puts("PASS resume grants only the new Node group generation; duplicate notifications and stale callbacks cannot reopen or revoke it");
}

static void test_expiration_and_fast_foreground(void) {
    uint64_t expired = dsh_lifecycle_request_quiesce();
    assert(dsh_lifecycle_grant_session_drain(42, expired));
    assert(dsh_lifecycle_revoke_session_drain(42, expired));
    struct worker node = worker(48, 42);
    pthread_t a = launch(&node);
    blocked(&node);
    assert(dsh_lifecycle_mark_quiescent(expired));
    dsh_lifecycle_resume();
    joined(&node, a);
    uint64_t old = dsh_lifecycle_request_quiesce();
    assert(dsh_lifecycle_grant_session_drain(42, old));
    dsh_lifecycle_begin_resume();
    uint64_t fresh = snapshot().generation;
    assert(!snapshot().session_drain_active);
    assert(!dsh_lifecycle_revoke_session_drain(42, old));
    assert(dsh_lifecycle_grant_session_drain(42, fresh));
    /* A second background request cancels an incomplete foreground drain. */
    uint64_t next = dsh_lifecycle_request_quiesce();
    assert(next != fresh && !snapshot().session_drain_active);
    assert(!dsh_lifecycle_revoke_session_drain(42, fresh));
    assert(dsh_lifecycle_grant_session_drain(42, next));
    assert(dsh_lifecycle_revoke_session_drain(42, next));
    assert(dsh_lifecycle_mark_quiescent(next));
    dsh_lifecycle_resume();
    puts("PASS expiration closes new Node admission; rapid foreground/background invalidates only the cancelled cycle");
}

static void test_original_lock_and_sql_guards(const char *path) {
    int key = 0;
    int fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0600);
    assert(fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) == 0);
    dsh_lifecycle_native_flock_update(&key, fd, 22, DSH_LIFECYCLE_FLOCK_EXCLUSIVE);
    uint64_t generation = dsh_lifecycle_request_quiesce();
    assert(dsh_lifecycle_grant_session_drain(42, generation));
    struct worker closer = worker(49, 42);
    closer.close_fd = fd; closer.close_key = &key;
    pthread_t a = launch(&closer);
    joined(&closer, a);
    assert(snapshot().active_native_flocks == 0);
    assert(!dsh_lifecycle_mark_quiescent(generation));
    assert(dsh_lifecycle_revoke_session_drain(42, generation));
    assert(dsh_lifecycle_mark_quiescent(generation));
    dsh_lifecycle_resume();
    assert(unlink(path) == 0);
    puts("PASS another libuv worker in the permitted group completes real native flock unlock/close; acknowledgement is still required");

    uint64_t connection = dsh_lifecycle_sqlite_open(42);
    dsh_lifecycle_sqlite_update(connection, 42, 0, 2, 0, "fixture_write");
    generation = dsh_lifecycle_request_quiesce();
    assert(dsh_lifecycle_grant_session_drain(42, generation));
    assert(dsh_lifecycle_revoke_session_drain(42, generation));
    assert(!dsh_lifecycle_mark_quiescent(generation));
    dsh_lifecycle_sqlite_update(connection, 42, 1, 0, 0, "fixture_commit");
    assert(dsh_lifecycle_mark_quiescent(generation));
    dsh_lifecycle_sqlite_close(connection, 0);
    dsh_lifecycle_resume();
    assert(snapshot().active_native_flocks == 0 && snapshot().open_connections == 0);
    puts("PASS revoking a drain never overrides the original active SQLite transaction barrier");
}

static void test_context_restoration(void) {
    struct dsh_lifecycle_guest_context original = dsh_lifecycle_exchange_guest_context(
        (struct dsh_lifecycle_guest_context){60, 42});
    struct dsh_lifecycle_guest_context first = dsh_lifecycle_exchange_guest_context(
        (struct dsh_lifecycle_guest_context){61, 42});
    assert(first.guest_pid == 60 && first.guest_tgid == 42);
    dsh_lifecycle_restore_guest_context(&first);
    struct dsh_lifecycle_guest_context restored = dsh_lifecycle_exchange_guest_context(original);
    assert(restored.guest_pid == 60 && restored.guest_tgid == 42);
    dsh_lifecycle_thread_exit();
    restored = dsh_lifecycle_exchange_guest_context(original);
    assert(restored.guest_pid == -1 && restored.guest_tgid == -1);
    puts("PASS nested syscall identities restore correctly and thread exit clears cached group identity");
}

int main(int argc, char **argv) {
    assert(argc == 2);
    alarm(30); /* Failure guard only; a signal/timeout is never test success. */
    assert(!dsh_lifecycle_grant_session_drain(42, 0));
    dsh_lifecycle_enable_admission_gate();
    test_group_admission_and_resume();
    test_expiration_and_fast_foreground();
    test_original_lock_and_sql_guards(argv[1]);
    test_context_restoration();
    struct dsh_lifecycle_snapshot value = snapshot();
    assert(value.state == DSH_LIFECYCLE_RUNNING && value.active_operations == 0 &&
        value.active_native_flocks == 0 && value.tracking_overflows == 0 && !value.session_drain_active);
    alarm(0);
    puts("All session drain admission tests passed.");
    return 0;
}
