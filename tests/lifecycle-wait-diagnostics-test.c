/* Production diagnostic core, real pthread admission/cancellation and a real
 * host flock. No guest task/FD scans or user files are needed. */
#include "fs/dsh-lifecycle.h"
#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <sys/file.h>
#include <time.h>
#include <unistd.h>

static struct dsh_lifecycle_snapshot snapshot(void) {
    struct dsh_lifecycle_snapshot state;
    dsh_lifecycle_get_snapshot(&state);
    return state;
}
static uint64_t now_ms(void) {
    struct timespec ts;
    assert(clock_gettime(CLOCK_MONOTONIC, &ts) == 0);
    return (uint64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}
static void await_waiters(unsigned count) {
    uint64_t end = now_ms() + 5000;
    while (snapshot().gate_waiters != count) {
        assert(now_ms() < end);
        struct timespec delay = {.tv_nsec = 1000000};
        nanosleep(&delay, NULL);
    }
}
struct waiter {
    int pid, tgid;
    bool operation;
    atomic_bool entered;
};
static void thread_cleanup(void *unused) {
    (void)unused;
    // The wait cancellation handler must unlock diagnostic_lock first.
    dsh_lifecycle_thread_exit();
}
static void *wait_at_gate(void *argument) {
    struct waiter *waiter = argument;
    (void)dsh_lifecycle_exchange_guest_context((struct dsh_lifecycle_guest_context) {
        waiter->pid, waiter->tgid});
    pthread_cleanup_push(thread_cleanup, NULL);
    errno = EDOM;
    if (waiter->operation) {
        uint64_t op = dsh_lifecycle_operation_begin("guest_syscall_63", waiter->pid);
        assert(errno == EDOM);
        dsh_lifecycle_operation_end(op);
    } else {
        dsh_lifecycle_checkpoint(waiter->pid);
        assert(errno == EDOM);
    }
    atomic_store(&waiter->entered, true);
    pthread_cleanup_pop(1);
    return NULL;
}
static pthread_t launch(struct waiter *waiter) {
    pthread_t thread;
    pthread_attr_t attributes;
    assert(pthread_attr_init(&attributes) == 0);
    assert(pthread_attr_setstacksize(&attributes, 256 * 1024) == 0);
    assert(pthread_create(&thread, &attributes, wait_at_gate, waiter) == 0);
    assert(pthread_attr_destroy(&attributes) == 0);
    return thread;
}
static void read_owner_and_waiting_dependency(void) {
    FILE *file = tmpfile();
    assert(file && flock(fileno(file), LOCK_EX | LOCK_NB) == 0);
    (void)dsh_lifecycle_exchange_guest_context((struct dsh_lifecycle_guest_context){250, 250});
    uint64_t op = dsh_lifecycle_operation_begin("guest_syscall_63", 250);
    dsh_lifecycle_native_flock_update(file, fileno(file), 250, DSH_LIFECYCLE_FLOCK_EXCLUSIVE);
    errno = EDOM;
    assert(dsh_lifecycle_read_observe(4, DSH_READ_FD_PIPE) == op && errno == EDOM);
    uint64_t generation = dsh_lifecycle_request_quiesce();
    struct waiter dependency = {.pid = 251, .tgid = 251};
    pthread_t thread = launch(&dependency);
    await_waiters(1);
    struct dsh_lifecycle_snapshot state = snapshot();
    assert(state.generation == generation && state.active_native_flocks == 1 && state.active_operations == 1);
    assert(state.operations[0].owner.guest_pid == 250 && state.operations[0].owner.guest_tgid == 250);
    assert(state.operations[0].read_fd_observed && state.operations[0].read_guest_fd == 4 &&
        state.operations[0].read_fd_kind == DSH_READ_FD_PIPE);
    assert(state.gate_wait_count == 1 && state.gate_waits[0].owner.guest_pid == 251 &&
        state.gate_waits[0].owner.guest_tgid == 251 && state.gate_waits[0].owner.thread_id != state.operations[0].owner.thread_id);
    assert(state.gate_waits[0].reason == DSH_GATE_WAIT_CHECKPOINT && state.gate_waits[0].entered_generation == generation);
    assert(state.gate_waits[0].started_monotonic_ns <= state.sampled_monotonic_ns);
    assert(!dsh_lifecycle_mark_quiescent(generation) && !atomic_load(&dependency.entered));
    dsh_lifecycle_read_clear(op);
    assert(!snapshot().operations[0].read_fd_observed);
    dsh_lifecycle_operation_end(op);
    // A known lock owner can still progress while the unrelated task stays
    // parked. Recording waiters must never broaden or revoke admission.
    op = dsh_lifecycle_operation_begin("guest_syscall_64", 250);
    assert(snapshot().gate_waiters == 1);
    dsh_lifecycle_operation_end(op);
    assert(flock(fileno(file), LOCK_UN) == 0);
    dsh_lifecycle_native_flock_close(file);
    assert(fclose(file) == 0);
    assert(dsh_lifecycle_mark_quiescent(generation));
    dsh_lifecycle_resume();
    assert(pthread_join(thread, NULL) == 0 && atomic_load(&dependency.entered));
    assert(snapshot().gate_waiters == 0 && snapshot().gate_wait_count == 0);
    puts("PASS one snapshot correlates a real lock owner's pipe read with a different guest parked at the gate; admission and lock lifetime stay intact");
}
static void cancellation_and_bounded_metadata(void) {
    // 129 exceeds the production table's bounded 128 records; returned arrays
    // are capped at 16. Missing diagnostics must not change quiescence safety.
    enum { COUNT = 129 };
    struct waiter waiters[COUNT] = {0};
    pthread_t threads[COUNT];
    uint64_t generation = dsh_lifecycle_request_quiesce();
    for (unsigned i = 0; i < COUNT; i++) {
        waiters[i].pid = 1000 + i;
        waiters[i].tgid = 900;
        waiters[i].operation = true;
        threads[i] = launch(&waiters[i]);
        await_waiters(i + 1);
    }
    struct dsh_lifecycle_snapshot state = snapshot();
    assert(state.gate_waiters == COUNT && state.gate_wait_count == DSH_LIFECYCLE_SNAPSHOT_ITEMS);
    assert(state.gate_wait_tracking_overflows >= 1 && state.tracking_overflows == 0);
    assert(state.active_operations == 0 && dsh_lifecycle_mark_quiescent(generation));
    for (unsigned i = 0; i < state.gate_wait_count; i++) {
        assert(state.gate_waits[i].owner.guest_tgid == 900);
        assert(state.gate_waits[i].reason == DSH_GATE_WAIT_OPERATION);
    }
    // Cancel both a tracked waiter and the waiter without a table slot.
    for (unsigned i = 0; i < COUNT; i++) assert(pthread_cancel(threads[i]) == 0);
    for (unsigned i = 0; i < COUNT; i++) {
        void *result = NULL;
        assert(pthread_join(threads[i], &result) == 0 && result == PTHREAD_CANCELED);
        assert(!atomic_load(&waiters[i].entered));
    }
    state = snapshot();
    assert(state.gate_waiters == 0 && state.gate_wait_count == 0 && state.active_operations == 0);
    dsh_lifecycle_resume();
    puts("PASS 129 real gate waiters preserve total/overflow/truncation counts; cancellation removes every record and leaves the diagnostic mutex usable");
}
static void read_metadata_retirement(void) {
    (void)dsh_lifecycle_exchange_guest_context((struct dsh_lifecycle_guest_context){17, 9});
    uint64_t outer = dsh_lifecycle_operation_begin("guest_syscall_63", 17);
    uint64_t nested = dsh_lifecycle_operation_begin("realfs_read", 17);
    assert(dsh_lifecycle_read_observe(8, DSH_READ_FD_SOCKET) == nested);
    struct dsh_lifecycle_snapshot state = snapshot();
    assert(!state.operations[0].read_fd_observed && state.operations[1].read_fd_kind == DSH_READ_FD_SOCKET);
    assert(state.operations[1].owner.guest_tgid == 9);
    dsh_lifecycle_operation_end(nested);
    dsh_lifecycle_read_clear(nested); // A retired token must not affect reuse.
    assert(!snapshot().operations[0].read_fd_observed);
    assert(dsh_lifecycle_read_observe(-2, (enum dsh_lifecycle_read_fd_kind)999) == outer);
    assert(snapshot().operations[0].read_guest_fd == -1 && snapshot().operations[0].read_fd_kind == DSH_READ_FD_UNKNOWN);
    dsh_lifecycle_thread_exit();
    assert(snapshot().operation_count == 0);
    uint64_t misses = snapshot().read_metadata_misses;
    assert(dsh_lifecycle_read_observe(2, DSH_READ_FD_REGULAR) == 0);
    assert(snapshot().read_metadata_misses == misses + 1);
    // A native/mismatched PID must not be assigned a stale trusted group.
    outer = dsh_lifecycle_operation_begin("realfs_read", 99);
    assert(snapshot().operations[0].owner.guest_tgid == -1);
    dsh_lifecycle_operation_end(outer);
    puts("PASS nested read metadata retires with its own scope; stale tokens, exit, unknown enums and missing identities remain bounded and explicit");
}
int main(void) {
    alarm(30);
    dsh_lifecycle_enable_admission_gate();
    read_owner_and_waiting_dependency();
    cancellation_and_bounded_metadata();
    read_metadata_retirement();
    struct dsh_lifecycle_snapshot state = snapshot();
    assert(state.active_operations == 0 && state.gate_waiters == 0 && state.active_native_flocks == 0 && state.tracking_overflows == 0);
    alarm(0);
    puts("All lifecycle wait diagnostic tests passed.");
    return 0;
}
