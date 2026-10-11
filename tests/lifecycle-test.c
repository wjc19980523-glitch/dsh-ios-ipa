/* Portable diagnostic-core regressions; does not claim to emulate RunningBoard. */
#include "fs/dsh-lifecycle.h"
#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>

static struct dsh_lifecycle_snapshot snapshot(void) {
    struct dsh_lifecycle_snapshot value;
    dsh_lifecycle_get_snapshot(&value);
    return value;
}

static void early_return(void) {
    DSH_LIFECYCLE_SCOPE(41);
    assert(snapshot().active_operations == 1);
    return;
}

static void test_scopes(void) {
    assert(snapshot().state == DSH_LIFECYCLE_RUNNING);
    assert(snapshot().active_operations == 0);
    early_return();
    assert(snapshot().active_operations == 0);
    errno = EACCES;
    uint64_t syscall = dsh_lifecycle_operation_begin("guest_syscall_63", 42);
    uint64_t outer = dsh_lifecycle_operation_begin("fakefs_open", 42);
    uint64_t inner = dsh_lifecycle_operation_begin("realfs_open", -1);
    uint64_t nested_fakefs = dsh_lifecycle_operation_begin("fakefs_fstat", -1);
    struct dsh_lifecycle_snapshot value = snapshot();
    assert(errno == EACCES);
    assert(dsh_lifecycle_operation_depth() == 4);
    assert(value.active_operations == 4 && value.operation_count == 4);
    assert(value.active_fakefs_operations == 2 && value.tracking_overflows == 0);
    assert(value.operations[0].owner.guest_pid == 42);
    assert(value.operations[1].owner.guest_pid == 42);
    assert(value.operations[0].owner.thread_id == value.operations[1].owner.thread_id);
    assert(value.operations[0].nesting_depth == 1 && value.operations[1].nesting_depth == 2);
    assert(strcmp(value.operations[0].name, "guest_syscall_63") == 0);
    assert(strcmp(value.operations[1].name, "fakefs_open") == 0);
    assert(strcmp(value.operations[2].name, "realfs_open") == 0);
    assert(strcmp(value.operations[3].name, "fakefs_fstat") == 0);
    assert(value.operations[0].started_monotonic_ns <= value.sampled_monotonic_ns);
    dsh_lifecycle_operation_end(nested_fakefs);
    assert(snapshot().active_fakefs_operations == 1);
    dsh_lifecycle_operation_end(inner);
    dsh_lifecycle_operation_end(outer);
    assert(snapshot().active_fakefs_operations == 0 && snapshot().active_operations == 1);
    dsh_lifecycle_operation_end(syscall);
    dsh_lifecycle_operation_end(outer); /* An accidental duplicate cannot underflow. */
    assert(dsh_lifecycle_operation_depth() == 0 && snapshot().active_operations == 0);
    assert(errno == EACCES);
    puts("PASS scope cleanup, nested fakefs/realfs/syscall counts, ownership and errno");
}

static void test_state(void) {
    uint64_t generation = dsh_lifecycle_request_quiesce();
    assert(generation == dsh_lifecycle_request_quiesce());
    uint64_t operation = dsh_lifecycle_operation_begin("diagnostic_only_no_gate", 9);
    assert(snapshot().state == DSH_LIFECYCLE_QUIESCING);
    assert(snapshot().operations_after_quiesce == 1);
    assert(!dsh_lifecycle_mark_quiescent(generation));
    dsh_lifecycle_operation_end(operation);
    assert(dsh_lifecycle_mark_quiescent(generation));
    assert(snapshot().state == DSH_LIFECYCLE_QUIESCENT);
    dsh_lifecycle_resume();
    assert(snapshot().state == DSH_LIFECYCLE_RUNNING);
    uint64_t next_generation = dsh_lifecycle_request_quiesce();
    assert(!dsh_lifecycle_mark_quiescent(generation));
    assert(dsh_lifecycle_mark_quiescent(next_generation));
    dsh_lifecycle_resume();
    puts("PASS diagnostic intent state, duplicate callbacks and stale generations");
}

static void test_sqlite_cache(void) {
    uint64_t operation = dsh_lifecycle_operation_begin("fakefs_rename", 77);
    uint64_t connection = dsh_lifecycle_sqlite_open(-1);
    assert(snapshot().open_connections == 1);
    dsh_lifecycle_sqlite_update(connection, -1, 0, 0, 0, "begin_deferred");
    assert(snapshot().active_deferred_transactions == 1);
    dsh_lifecycle_sqlite_update(connection, -1, 0, 1, 100, "read");
    struct dsh_lifecycle_snapshot value = snapshot();
    assert(value.active_read_transactions == 1);
    assert(value.transactions[0].owner.guest_pid == 77);
    assert(value.transactions[0].cached_autocommit == 0);
    assert(value.transactions[0].observed_monotonic_ns <= value.sampled_monotonic_ns);
    dsh_lifecycle_sqlite_update(connection, -1, 0, 2, 5, "commit_busy");
    value = snapshot();
    assert(value.active_write_transactions == 1 && value.active_read_transactions == 0);
    assert(value.sqlite_busy_observations == 1 && value.last_sqlite_result == 5);
    assert(value.transactions[0].cached_result == 5);
    assert(strcmp(value.transactions[0].phase, "commit_busy") == 0);
    dsh_lifecycle_operation_end(operation);
    uint64_t generation = dsh_lifecycle_request_quiesce();
    assert(!dsh_lifecycle_mark_quiescent(generation));
    dsh_lifecycle_sqlite_close(connection, 5); /* Failed close cannot erase a transaction. */
    assert(snapshot().active_write_transactions == 1 && snapshot().open_connections == 1);
    dsh_lifecycle_sqlite_update(connection, 77, 1, 0, 0, "commit_done");
    assert(snapshot().transaction_count == 0);
    assert(dsh_lifecycle_mark_quiescent(generation));
    dsh_lifecycle_resume();
    /* Autocommit enabled does not mean an implicit SELECT has released its lock. */
    dsh_lifecycle_sqlite_update(connection, 77, 1, 1, 100, "implicit_select_row");
    assert(snapshot().active_read_transactions == 1);
    dsh_lifecycle_sqlite_update(connection, 77, 1, 0, 0, "select_reset");
    assert(snapshot().transaction_count == 0);
    dsh_lifecycle_sqlite_close(connection, 0);
    assert(snapshot().open_connections == 0);
    puts("PASS cached SQLite read/write/deferred/implicit state and failed commit/close");
}

static void test_flocks(void) {
    int retained_fd_object = 0;
    int different_fd_object = 0;
    dsh_lifecycle_native_flock_update(&retained_fd_object, 14, 88, DSH_LIFECYCLE_FLOCK_SHARED);
    struct dsh_lifecycle_snapshot value = snapshot();
    assert(value.active_native_flocks == 1 && value.native_flock_count == 1);
    uint64_t id = value.native_flocks[0].id;
    dsh_lifecycle_native_flock_update(&retained_fd_object, 14, 88, DSH_LIFECYCLE_FLOCK_EXCLUSIVE);
    value = snapshot();
    assert(value.active_native_flocks == 1 && value.native_flocks[0].id == id);
    assert(value.native_flocks[0].mode == DSH_LIFECYCLE_FLOCK_EXCLUSIVE);
    uint64_t generation = dsh_lifecycle_request_quiesce();
    assert(!dsh_lifecycle_mark_quiescent(generation));
    dsh_lifecycle_native_flock_close(&retained_fd_object);
    assert(snapshot().active_native_flocks == 0);
    assert(dsh_lifecycle_mark_quiescent(generation));
    dsh_lifecycle_resume();
    /* Reusing a host fd number on a different retained object is a new lock. */
    dsh_lifecycle_native_flock_update(&different_fd_object, 14, 89, DSH_LIFECYCLE_FLOCK_SHARED);
    assert(snapshot().native_flocks[0].id != id);
    dsh_lifecycle_native_flock_update(&different_fd_object, 14, 89, DSH_LIFECYCLE_FLOCK_UNLOCKED);
    assert(snapshot().active_native_flocks == 0);
    puts("PASS native flock conversion, unlock, final close and host fd reuse");
}

static pthread_mutex_t worker_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t worker_condition = PTHREAD_COND_INITIALIZER;
static bool worker_entered;
static bool worker_release;

static void *held_worker(void *argument) {
    (void) argument;
    DSH_LIFECYCLE_SCOPE(123);
    uint64_t connection = dsh_lifecycle_sqlite_open(-1);
    dsh_lifecycle_sqlite_update(connection, -1, 0, 2, 0, "held_write");
    pthread_mutex_lock(&worker_lock);
    worker_entered = true;
    pthread_cond_signal(&worker_condition);
    while (!worker_release) pthread_cond_wait(&worker_condition, &worker_lock);
    pthread_mutex_unlock(&worker_lock);
    dsh_lifecycle_sqlite_update(connection, -1, 1, 0, 0, "commit");
    dsh_lifecycle_sqlite_close(connection, 0);
    return NULL;
}

static void test_concurrent_snapshot(void) {
    pthread_t worker;
    assert(pthread_create(&worker, NULL, held_worker, NULL) == 0);
    pthread_mutex_lock(&worker_lock);
    while (!worker_entered) pthread_cond_wait(&worker_condition, &worker_lock);
    pthread_mutex_unlock(&worker_lock);
    for (unsigned i = 0; i < 1000; i++) {
        struct dsh_lifecycle_snapshot value = snapshot();
        assert(value.active_operations == 1 && value.active_write_transactions == 1);
        assert(value.transactions[0].owner.guest_pid == 123);
        assert(value.transactions[0].owner.thread_id == value.operations[0].owner.thread_id);
    }
    pthread_mutex_lock(&worker_lock);
    worker_release = true;
    pthread_cond_signal(&worker_condition);
    pthread_mutex_unlock(&worker_lock);
    assert(pthread_join(worker, NULL) == 0);
    assert(snapshot().active_operations == 0 && snapshot().transaction_count == 0);
    puts("PASS concurrent snapshots while a SQL worker remains blocked");
}

static atomic_uint completed_workers;
static void *stress_worker(void *argument) {
    int guest_pid = *(int *) argument;
    for (unsigned i = 0; i < 1000; i++) {
        uint64_t outer = dsh_lifecycle_operation_begin("fakefs_write", guest_pid);
        uint64_t inner = dsh_lifecycle_operation_begin("realfs_write", -1);
        dsh_lifecycle_operation_end(inner);
        dsh_lifecycle_operation_end(outer);
    }
    atomic_fetch_add(&completed_workers, 1);
    return NULL;
}

static void test_stress(void) {
    pthread_t workers[4];
    int pids[4] = { 201, 202, 203, 204 };
    for (unsigned i = 0; i < 4; i++)
        assert(pthread_create(&workers[i], NULL, stress_worker, &pids[i]) == 0);
    while (atomic_load(&completed_workers) != 4) {
        struct dsh_lifecycle_snapshot value = snapshot();
        assert(value.active_operations <= 8 && value.tracking_overflows == 0);
        assert(value.active_fakefs_operations <= 4 && value.active_fakefs_operations <= value.active_operations);
        for (unsigned i = 0; i < value.operation_count; i++)
            assert(value.operations[i].owner.guest_pid >= 201 && value.operations[i].owner.guest_pid <= 204);
    }
    for (unsigned i = 0; i < 4; i++) assert(pthread_join(workers[i], NULL) == 0);
    assert(snapshot().active_operations == 0);
    puts("PASS multiworker scope/snapshot stress");
}

static void test_truncation_and_uncertainty(void) {
    uint64_t tokens[513];
    for (unsigned i = 0; i < 20; i++)
        tokens[i] = dsh_lifecycle_operation_begin(i < 16 ? "guest_syscall_63" : "fakefs_open", 7);
    struct dsh_lifecycle_snapshot value = snapshot();
    assert(value.active_operations == 20 && value.operation_count == 16);
    assert(value.active_fakefs_operations == 4 && value.tracking_overflows == 0);
    for (unsigned i = 0; i < value.operation_count; i++)
        assert(strcmp(value.operations[i].name, "guest_syscall_63") == 0);
    for (unsigned i = 20; i > 0; i--) dsh_lifecycle_operation_end(tokens[i - 1]);
    assert(snapshot().active_operations == 0);
    for (unsigned i = 0; i < 513; i++) tokens[i] = dsh_lifecycle_operation_begin("fakefs_open", 7);
    value = snapshot();
    assert(value.active_operations == 513 && value.tracking_overflows == 1);
    assert(value.active_fakefs_operations == 512); /* Untracked entries make this a lower bound. */
    for (unsigned i = 513; i > 0; i--) dsh_lifecycle_operation_end(tokens[i - 1]);
    assert(snapshot().active_operations == 0 && dsh_lifecycle_operation_depth() == 0);
    assert(snapshot().active_fakefs_operations == 0 && snapshot().tracking_overflows == 1);
    uint64_t generation = dsh_lifecycle_request_quiesce();
    assert(!dsh_lifecycle_mark_quiescent(generation));
    dsh_lifecycle_resume();
    int fd_object = 0;
    dsh_lifecycle_native_flock_update(&fd_object, 15, 9, DSH_LIFECYCLE_FLOCK_SHARED);
    dsh_lifecycle_native_flock_close_failed(&fd_object);
    assert(snapshot().native_close_failures == 1 && snapshot().active_native_flocks == 1);
    dsh_lifecycle_native_flock_close(&fd_object);
    assert(snapshot().active_native_flocks == 0);
    puts("PASS full-table fakefs counts beyond item truncation and incomplete overflow/close-failure handling");
}

int main(void) {
    test_scopes();
    test_state();
    test_sqlite_cache();
    test_flocks();
    test_concurrent_snapshot();
    test_stress();
    test_truncation_and_uncertainty();
    puts("All lifecycle diagnostic tests passed.");
    return 0;
}
