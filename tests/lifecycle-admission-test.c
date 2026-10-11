/* Real pthread admission regressions linked with the production lifecycle core.
 * This tests portable coordination, not RunningBoard's device-only policy. */
#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)
// flock is a BSD extension hidden by the runner's strict POSIX feature level.
#define _DARWIN_C_SOURCE 1
#endif
#include "fs/dsh-lifecycle.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/file.h>
#include <time.h>
#include <unistd.h>

enum phase { CREATED, STARTED, ENTERED, CLEANUP_ATTEMPT, CLEANUP_ENTERED, DONE };
struct worker {
    pthread_mutex_t lock;
    pthread_cond_t changed;
    enum phase phase;
    bool proceed, finish;
    int guest_pid, host_fd;
    const char *path;
    bool exit_with_scopes;
    uint64_t connection;
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
    end.tv_nsec += (long) (milliseconds % 1000) * 1000000;
    if (end.tv_nsec >= 1000000000) { end.tv_sec++; end.tv_nsec -= 1000000000; }
    return end;
}
static struct worker new_worker(int guest_pid) {
    struct worker worker = {.guest_pid = guest_pid, .host_fd = -1};
    return worker;
}
static void initialize(struct worker *worker) {
    assert(pthread_mutex_init(&worker->lock, NULL) == 0);
    assert(pthread_cond_init(&worker->changed, NULL) == 0);
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
static void permit_progress(struct worker *worker, bool finish) {
    assert(pthread_mutex_lock(&worker->lock) == 0);
    if (finish) worker->finish = true;
    else worker->proceed = true;
    assert(pthread_cond_broadcast(&worker->changed) == 0);
    assert(pthread_mutex_unlock(&worker->lock) == 0);
}
static void wait_progress(struct worker *worker, bool finish) {
    struct timespec end = deadline(5000);
    assert(pthread_mutex_lock(&worker->lock) == 0);
    while (!(finish ? worker->finish : worker->proceed))
        assert(pthread_cond_timedwait(&worker->changed, &worker->lock, &end) == 0);
    assert(pthread_mutex_unlock(&worker->lock) == 0);
}
static pthread_t launch(struct worker *worker, void *(*entry)(void *)) {
    initialize(worker);
    pthread_t thread;
    assert(pthread_create(&thread, NULL, entry, worker) == 0);
    assert(await_phase(worker, STARTED, 5000));
    return thread;
}
static void joined(struct worker *worker, pthread_t thread) {
    assert(await_phase(worker, DONE, 5000));
    assert(pthread_join(thread, NULL) == 0);
    assert(pthread_cond_destroy(&worker->changed) == 0);
    assert(pthread_mutex_destroy(&worker->lock) == 0);
}
static void thread_done(struct worker *worker) {
    dsh_lifecycle_thread_exit();
    assert(dsh_lifecycle_operation_depth() == 0);
    announce(worker, DONE);
}
static void *ordinary_worker(void *argument) {
    struct worker *worker = argument;
    announce(worker, STARTED);
    uint64_t scope = dsh_lifecycle_operation_begin("new_host_operation", worker->guest_pid);
    announce(worker, ENTERED);
    wait_progress(worker, true);
    dsh_lifecycle_operation_end(scope);
    thread_done(worker);
    return NULL;
}
static void *nested_worker(void *argument) {
    struct worker *worker = argument;
    announce(worker, STARTED);
    uint64_t outer = dsh_lifecycle_operation_begin("old_outer", worker->guest_pid);
    announce(worker, ENTERED);
    wait_progress(worker, false);
    // An existing permit must drain instead of parking inside its transaction.
    dsh_lifecycle_checkpoint(worker->guest_pid);
    uint64_t inner = dsh_lifecycle_operation_begin("nested_commit_cleanup", -1);
    assert(dsh_lifecycle_operation_depth() == 2);
    dsh_lifecycle_operation_end(inner);
    dsh_lifecycle_operation_end(outer);
    thread_done(worker);
    return NULL;
}
static void test_default_is_observation_only(void) {
    uint64_t generation = dsh_lifecycle_request_quiesce();
    uint64_t observed = dsh_lifecycle_try_operation_begin("try_without_gate", 0);
    assert(observed != 0);
    dsh_lifecycle_operation_end(observed);
    struct worker worker = new_worker(1);
    pthread_t thread = launch(&worker, ordinary_worker);
    assert(await_phase(&worker, ENTERED, 5000));
    assert(snapshot().active_operations == 1);
    permit_progress(&worker, true);
    joined(&worker, thread);
    assert(dsh_lifecycle_mark_quiescent(generation));
    dsh_lifecycle_resume();
    dsh_lifecycle_enable_admission_gate();
    puts("PASS admission defaults off and requires explicit enable");
}
static void test_nonblocking_try_admission(void) {
    uint64_t permitted = dsh_lifecycle_try_operation_begin("try_running", 5);
    assert(permitted != 0 && snapshot().active_operations == 1);
    dsh_lifecycle_operation_end(permitted);
    uint64_t generation = dsh_lifecycle_request_quiesce();
    uint64_t prior_count = snapshot().operations_after_quiesce;
    errno = EACCES;
    assert(dsh_lifecycle_try_operation_begin("try_closed", 5) == 0);
    assert(errno == EACCES && snapshot().active_operations == 0 && dsh_lifecycle_operation_depth() == 0);
    assert(snapshot().operations_after_quiesce == prior_count);
    assert(dsh_lifecycle_mark_quiescent(generation));
    assert(dsh_lifecycle_try_operation_begin("try_quiescent", 5) == 0);
    dsh_lifecycle_begin_resume();
    assert(dsh_lifecycle_try_operation_begin("try_resuming", 5) == 0);
    dsh_lifecycle_resume();
    permitted = dsh_lifecycle_try_operation_begin("try_outer", 5);
    generation = dsh_lifecycle_request_quiesce();
    uint64_t nested = dsh_lifecycle_try_operation_begin("try_nested_drain", -1);
    assert(permitted != 0 && nested != 0 && dsh_lifecycle_operation_depth() == 2);
    dsh_lifecycle_operation_end(nested);
    dsh_lifecycle_operation_end(permitted);
    assert(dsh_lifecycle_mark_quiescent(generation));
    dsh_lifecycle_resume();
    puts("PASS atomic try admission rejects closed gates without counters, admits Running and nested drain");
}
static void *nonowner_recovery_worker(void *argument) {
    struct worker *worker = argument;
    announce(worker, STARTED);
    uint64_t scope = dsh_lifecycle_operation_begin("unrelated_recovery_thread", worker->guest_pid);
    dsh_lifecycle_operation_end(scope);
    errno = EACCES;
    dsh_lifecycle_sqlite_recovery_resolved(worker->connection);
    assert(errno == EACCES);
    thread_done(worker);
    return NULL;
}
static void test_sticky_sqlite_recovery(void) {
    uint64_t operation = dsh_lifecycle_operation_begin("owner_recovery_failure", 6);
    uint64_t connection = dsh_lifecycle_sqlite_open(6);
    dsh_lifecycle_sqlite_recovery_required(connection, 5);
    // Autocommit alone must not erase an earlier unverified recovery failure.
    dsh_lifecycle_sqlite_update(connection, 6, 1, 0, 0, "autocommit_after_failure");
    dsh_lifecycle_operation_end(operation);
    struct worker nonowner = new_worker(7);
    nonowner.connection = connection;
    pthread_t nonowner_thread = launch(&nonowner, nonowner_recovery_worker);
    joined(&nonowner, nonowner_thread);
    assert(snapshot().recovery_blocked_connections == 1);
    uint64_t generation = dsh_lifecycle_request_quiesce();
    struct dsh_lifecycle_snapshot value = snapshot();
    assert(value.active_operations == 0 && value.recovery_blocked_connections == 1);
    assert(value.transactions[0].recovery_required && !dsh_lifecycle_mark_quiescent(generation));
    // The recorded owner must be allowed to finish pending recovery before
    // clearing the sticky observation; it is still an existing critical scope.
    assert(dsh_lifecycle_try_operation_begin("native_launch_must_not_bypass", 6) == 0);
    assert(value.transactions[0].recovery_result == 5);
    operation = dsh_lifecycle_operation_begin("owner_finishes_recovery", 6);
    assert(operation != 0);
    dsh_lifecycle_sqlite_recovery_resolved(connection);
    assert(snapshot().recovery_blocked_connections == 0);
    assert(!dsh_lifecycle_mark_quiescent(generation));
    dsh_lifecycle_operation_end(operation);
    assert(dsh_lifecycle_mark_quiescent(generation));
    dsh_lifecycle_resume();
    operation = dsh_lifecycle_operation_begin("owner_closes_connection", 6);
    dsh_lifecycle_sqlite_close(connection, 0);
    dsh_lifecycle_operation_end(operation);
    assert(snapshot().open_connections == 0);
    puts("PASS active=0 does not clear sticky SQLite recovery; owner recovery must resolve before quiescence");
}
static void test_new_work_waits_through_resume(void) {
    uint64_t generation = dsh_lifecycle_request_quiesce();
    struct worker worker = new_worker(2);
    pthread_t thread = launch(&worker, ordinary_worker);
    assert(!await_phase(&worker, ENTERED, 50));
    assert(snapshot().active_operations == 0);
    assert(dsh_lifecycle_mark_quiescent(generation));
    assert(dsh_lifecycle_request_quiesce() == generation);
    assert(!await_phase(&worker, ENTERED, 50));
    dsh_lifecycle_begin_resume();
    assert(snapshot().state == DSH_LIFECYCLE_RESUMING);
    assert(!await_phase(&worker, ENTERED, 50));
    dsh_lifecycle_resume();
    assert(await_phase(&worker, ENTERED, 5000));
    permit_progress(&worker, true);
    joined(&worker, thread);
    puts("PASS new work blocks in Quiescing, Quiescent and Resuming");
}
static void test_nested_work_drains(void) {
    struct worker old = new_worker(3), later = new_worker(4);
    pthread_t old_thread = launch(&old, nested_worker);
    assert(await_phase(&old, ENTERED, 5000));
    uint64_t generation = dsh_lifecycle_request_quiesce();
    assert(!dsh_lifecycle_mark_quiescent(generation));
    pthread_t later_thread = launch(&later, ordinary_worker);
    assert(!await_phase(&later, ENTERED, 50));
    permit_progress(&old, false);
    joined(&old, old_thread);
    assert(snapshot().active_operations == 0);
    assert(dsh_lifecycle_mark_quiescent(generation));
    assert(!await_phase(&later, ENTERED, 50));
    dsh_lifecycle_resume();
    assert(await_phase(&later, ENTERED, 5000));
    permit_progress(&later, true);
    joined(&later, later_thread);
    puts("PASS old nested scopes drain while new work remains parked");
}
static void test_rapid_foreground_and_duplicates(void) {
    for (unsigned iteration = 0; iteration < 20; iteration++) {
        uint64_t old = dsh_lifecycle_request_quiesce();
        assert(dsh_lifecycle_request_quiesce() == old);
        assert(dsh_lifecycle_mark_quiescent(old));
        struct worker worker = new_worker(20 + (int) iteration);
        pthread_t thread = launch(&worker, ordinary_worker);
        dsh_lifecycle_begin_resume();
        uint64_t resuming = snapshot().generation;
        dsh_lifecycle_begin_resume();
        assert(snapshot().generation == resuming);
        uint64_t next = dsh_lifecycle_request_quiesce();
        assert(next > old && snapshot().state == DSH_LIFECYCLE_QUIESCING);
        assert(!dsh_lifecycle_mark_quiescent(old));
        assert(!await_phase(&worker, ENTERED, 25));
        assert(dsh_lifecycle_mark_quiescent(next));
        dsh_lifecycle_begin_resume();
        assert(!await_phase(&worker, ENTERED, 25));
        dsh_lifecycle_resume();
        uint64_t running = snapshot().generation;
        dsh_lifecycle_resume();
        assert(snapshot().generation == running);
        assert(await_phase(&worker, ENTERED, 5000));
        permit_progress(&worker, true);
        joined(&worker, thread);
    }
    puts("PASS 20 rapid foreground/background cycles, duplicate callbacks and stale generations");
}
static void simulated_task_cleanup(void *argument) {
    struct worker *worker = argument;
    announce(worker, CLEANUP_ATTEMPT);
    uint64_t cleanup = dsh_lifecycle_operation_begin("task_cleanup_before_fd_close", worker->guest_pid);
    announce(worker, CLEANUP_ENTERED);
    if (worker->host_fd >= 0) {
        assert(close(worker->host_fd) == 0);
        worker->host_fd = -1;
    }
    dsh_lifecycle_operation_end(cleanup);
    thread_done(worker);
}
static void *exiting_worker(void *argument) {
    struct worker *worker = argument;
    pthread_cleanup_push(simulated_task_cleanup, worker);
    announce(worker, STARTED);
    if (worker->exit_with_scopes) {
        DSH_LIFECYCLE_SCOPE(worker->guest_pid);
        {
            DSH_LIFECYCLE_SCOPE(-1);
            worker->host_fd = open(worker->path, O_RDONLY);
            assert(worker->host_fd >= 0);
            announce(worker, ENTERED);
            wait_progress(worker, false);
            // GCC/Clang C cleanup attributes are skipped by pthread_exit.
            pthread_exit(NULL);
        }
    } else {
        wait_progress(worker, false);
        pthread_exit(NULL);
    }
    pthread_cleanup_pop(1);
    return NULL;
}
static void test_pthread_exit_cleanup(const char *path) {
    struct worker admitted = new_worker(70);
    admitted.path = path;
    admitted.exit_with_scopes = true;
    pthread_t admitted_thread = launch(&admitted, exiting_worker);
    assert(await_phase(&admitted, ENTERED, 5000));
    assert(snapshot().active_operations == 2);
    uint64_t generation = dsh_lifecycle_request_quiesce();
    permit_progress(&admitted, false);
    joined(&admitted, admitted_thread);
    assert(snapshot().active_operations == 0);
    assert(dsh_lifecycle_mark_quiescent(generation));
    dsh_lifecycle_resume();

    struct worker unadmitted = new_worker(71);
    pthread_t unadmitted_thread = launch(&unadmitted, exiting_worker);
    generation = dsh_lifecycle_request_quiesce();
    assert(dsh_lifecycle_mark_quiescent(generation));
    permit_progress(&unadmitted, false);
    assert(await_phase(&unadmitted, CLEANUP_ATTEMPT, 5000));
    assert(!await_phase(&unadmitted, CLEANUP_ENTERED, 50));
    dsh_lifecycle_begin_resume();
    assert(!await_phase(&unadmitted, CLEANUP_ENTERED, 50));
    dsh_lifecycle_resume();
    joined(&unadmitted, unadmitted_thread);
    assert(snapshot().active_operations == 0);
    puts("PASS pthread_exit retires nested permits; unadmitted cleanup waits before host effects");
}
static void *flock_worker(void *argument) {
    struct worker *worker = argument;
    announce(worker, STARTED);
    uint64_t scope = dsh_lifecycle_operation_begin("flock_acquire", worker->guest_pid);
    worker->host_fd = open(worker->path, O_RDWR);
    assert(worker->host_fd >= 0 && flock(worker->host_fd, LOCK_EX | LOCK_NB) == 0);
    dsh_lifecycle_native_flock_update(worker, worker->host_fd, worker->guest_pid, DSH_LIFECYCLE_FLOCK_EXCLUSIVE);
    dsh_lifecycle_operation_end(scope);
    announce(worker, ENTERED);
    wait_progress(worker, false);
    dsh_lifecycle_checkpoint(worker->guest_pid);
    scope = dsh_lifecycle_operation_begin("finish_preexisting_flock", worker->guest_pid);
    announce(worker, CLEANUP_ENTERED);
    wait_progress(worker, true);
    assert(flock(worker->host_fd, LOCK_UN) == 0);
    dsh_lifecycle_native_flock_update(worker, worker->host_fd, worker->guest_pid, DSH_LIFECYCLE_FLOCK_UNLOCKED);
    assert(close(worker->host_fd) == 0);
    worker->host_fd = -1;
    dsh_lifecycle_operation_end(scope);
    thread_done(worker);
    return NULL;
}
static void test_real_flock_holder_drains(const char *path) {
    struct worker holder = new_worker(80), newcomer = new_worker(81);
    holder.path = path;
    pthread_t holder_thread = launch(&holder, flock_worker);
    assert(await_phase(&holder, ENTERED, 5000));
    uint64_t generation = dsh_lifecycle_request_quiesce();
    assert(snapshot().active_operations == 0 && snapshot().active_native_flocks == 1);
    assert(!dsh_lifecycle_mark_quiescent(generation));
    int competing = open(path, O_RDWR);
    assert(competing >= 0);
    assert(flock(competing, LOCK_EX | LOCK_NB) < 0 && (errno == EWOULDBLOCK || errno == EAGAIN));
    pthread_t newcomer_thread = launch(&newcomer, ordinary_worker);
    assert(!await_phase(&newcomer, ENTERED, 50));
    permit_progress(&holder, false);
    assert(await_phase(&holder, CLEANUP_ENTERED, 5000));
    assert(!dsh_lifecycle_mark_quiescent(generation));
    assert(snapshot().native_flocks[0].age_ns > 0);
    assert(flock(competing, LOCK_EX | LOCK_NB) < 0 && (errno == EWOULDBLOCK || errno == EAGAIN));
    permit_progress(&holder, true);
    joined(&holder, holder_thread);
    assert(flock(competing, LOCK_EX | LOCK_NB) == 0);
    assert(flock(competing, LOCK_UN) == 0 && close(competing) == 0);
    assert(dsh_lifecycle_mark_quiescent(generation));
    assert(!await_phase(&newcomer, ENTERED, 50));
    dsh_lifecycle_resume();
    assert(await_phase(&newcomer, ENTERED, 5000));
    permit_progress(&newcomer, true);
    joined(&newcomer, newcomer_thread);
    puts("PASS real flock remains held, prevents quiescence, and its owner drains without forced unlock");
}
static void watchdog(int signal_number) {
    (void) signal_number;
    const char message[] = "FAIL admission test watchdog expired\n";
    (void) write(STDERR_FILENO, message, sizeof(message) - 1);
    _exit(124);
}
int main(int argc, char **argv) {
    assert(argc == 2);
    assert(signal(SIGALRM, watchdog) != SIG_ERR);
    alarm(30);
    int fixture = open(argv[1], O_RDWR | O_CREAT | O_TRUNC, 0600);
    assert(fixture >= 0 && close(fixture) == 0);
    test_default_is_observation_only();
    test_nonblocking_try_admission();
    test_sticky_sqlite_recovery();
    test_new_work_waits_through_resume();
    test_nested_work_drains();
    test_rapid_foreground_and_duplicates();
    test_pthread_exit_cleanup(argv[1]);
    test_real_flock_holder_drains(argv[1]);
    struct dsh_lifecycle_snapshot value = snapshot();
    assert(value.active_operations == 0 && value.active_native_flocks == 0 && value.tracking_overflows == 0);
    alarm(0);
    return 0;
}
