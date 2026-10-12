/* The production task_run_current + task_run_tlb_cleanup and actual syscall
 * admission prefix execute with real task/mm structures, pthreads and locks.
 * No fixture manually installs the identity under test. */
#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>
#include "kernel/calls.h"
#include "kernel/task.h"
#include "kernel/lifecycle-wait.h"
#include "emu/tlb.h"
#include "emu/interrupt.h"
#include "fs/dsh-lifecycle.h"

__thread struct task *current;
enum finish_kind { NO_FINISH, CLEAR_GROUP, GROUP_EXIT, CLEAR_CURRENT };
struct worker {
    struct task task;
    struct tgroup group;
    struct mm mm;
    pthread_mutex_t lock;
    pthread_cond_t changed;
    unsigned interrupts, allow, quanta, finish_at;
    enum finish_kind finish;
    bool finished, tlb_freed, group_exited;
};
static _Thread_local struct worker *active_worker;

static struct timespec deadline(unsigned milliseconds) {
    struct timespec end;
    assert(clock_gettime(CLOCK_REALTIME, &end) == 0);
    end.tv_sec += milliseconds / 1000;
    end.tv_nsec += (long)(milliseconds % 1000) * 1000000;
    if (end.tv_nsec >= 1000000000) { end.tv_sec++; end.tv_nsec -= 1000000000; }
    return end;
}
static bool await_progress(struct worker *worker, unsigned interrupt, bool finished, unsigned milliseconds) {
    struct timespec end = deadline(milliseconds);
    assert(pthread_mutex_lock(&worker->lock) == 0);
    int result = 0;
    while (!(finished ? worker->finished : worker->interrupts >= interrupt) && result == 0)
        result = pthread_cond_timedwait(&worker->changed, &worker->lock, &end);
    assert(result == 0 || result == ETIMEDOUT);
    bool reached = finished ? worker->finished : worker->interrupts >= interrupt;
    assert(pthread_mutex_unlock(&worker->lock) == 0);
    return reached;
}
static void release_interrupt(struct worker *worker, unsigned number, enum finish_kind finish) {
    assert(pthread_mutex_lock(&worker->lock) == 0);
    assert(worker->interrupts >= number);
    if (finish != NO_FINISH) { worker->finish = finish; worker->finish_at = number; }
    worker->allow = number;
    assert(pthread_cond_broadcast(&worker->changed) == 0);
    assert(pthread_mutex_unlock(&worker->lock) == 0);
}
static struct dsh_lifecycle_snapshot snapshot(void) {
    struct dsh_lifecycle_snapshot state;
    dsh_lifecycle_get_snapshot(&state);
    return state;
}
static void assert_context(int pid, int tgid) {
    struct dsh_lifecycle_guest_context saved = dsh_lifecycle_exchange_guest_context(
        (struct dsh_lifecycle_guest_context){pid, tgid});
    assert(saved.guest_pid == pid && saved.guest_tgid == tgid);
    dsh_lifecycle_restore_guest_context(&saved);
}
int current_pid(void) { return current ? current->pid : -1; }
void die(const char *message, ...) { (void)message; assert(false); abort(); }
void tlb_refresh(struct tlb *tlb, struct mmu *mmu) { tlb->mmu = mmu; }
void mm_release(struct mm *mm) { (void)mm; assert(false); }
void tlb_free(struct tlb *tlb) {
    struct worker *worker = active_worker;
    assert(dsh_lifecycle_operation_depth() > 0);
    if (current) assert_context(current->pid, current->tgid);
    else assert_context(-1, -1);
    assert(!worker->tlb_freed);
    worker->tlb_freed = true;
    free(tlb);
}
int cpu_run_to_interrupt(struct cpu_state *cpu, struct tlb *tlb) {
    struct worker *worker = active_worker;
    assert(tlb->mmu == &worker->mm.mem.mmu);
    assert(atomic_load(&worker->mm.mem.lock.val) > 0);
    assert(pthread_mutex_lock(&worker->lock) == 0);
    worker->quanta++;
    assert(pthread_mutex_unlock(&worker->lock) == 0);
    cpu->regs[8] = 64; // Ordinary write admission; no host file effects in fixture.
    return INT_SYSCALL;
}
_Noreturn void do_exit(int code) {
    assert(code == 77 && dsh_lifecycle_operation_depth() > 0);
    assert_context(current->pid, current->tgid);
    active_worker->group_exited = true;
    pthread_exit(NULL);
}
static void controlled_syscall_body(void) {
    struct worker *worker = active_worker;
    assert_context(worker->task.pid, worker->task.tgid);
    assert(dsh_lifecycle_operation_depth() == 1);
    assert(atomic_load(&worker->mm.mem.lock.val) == 0);
    assert(pthread_mutex_lock(&worker->lock) == 0);
    unsigned number = ++worker->interrupts;
    assert(pthread_cond_broadcast(&worker->changed) == 0);
    struct timespec end = deadline(5000);
    while (worker->allow < number)
        assert(pthread_cond_timedwait(&worker->changed, &worker->lock, &end) == 0);
    enum finish_kind finish = worker->finish_at == number ? worker->finish : NO_FINISH;
    assert(pthread_mutex_unlock(&worker->lock) == 0);
    if (finish == CLEAR_GROUP) worker->task.group = NULL;
    if (finish == GROUP_EXIT) {
        worker->group.doing_group_exit = true;
        worker->group.group_exit_code = 77;
    }
    if (finish == CLEAR_CURRENT) {
        // pthread_exit skips the syscall C cleanups. The real cleanup must
        // discard this stale identity before admitting any native cleanup.
        current = NULL;
        pthread_exit(NULL);
    }
}
#include "production-interrupt-admission.h"
#ifdef LEGACY_LOOP_NEGATIVE_CONTROL
#include "production-legacy-task-loop.h"
#else
#include "production-task-loop.h"
#endif

static void finished_cleanup(void *argument) {
    struct worker *worker = argument;
    assert_context(-1, -1);
    assert(dsh_lifecycle_operation_depth() == 0 && worker->tlb_freed);
    assert(pthread_mutex_lock(&worker->lock) == 0);
    worker->finished = true;
    assert(pthread_cond_broadcast(&worker->changed) == 0);
    assert(pthread_mutex_unlock(&worker->lock) == 0);
}
static void *run(void *argument) {
    struct worker *worker = argument;
    current = &worker->task;
    active_worker = worker;
    pthread_cleanup_push(finished_cleanup, worker);
    task_run_current();
    assert(false);
    pthread_cleanup_pop(1);
    return NULL;
}
static pthread_t launch(struct worker *worker, int pid, int tgid) {
    worker->task.pid = pid;
    worker->task.tgid = tgid;
    worker->task.group = &worker->group;
    worker->task.mm = &worker->mm;
    worker->task.mem = &worker->mm.mem;
    wrlock_init(&worker->mm.mem.lock);
    assert(pthread_mutex_init(&worker->lock, NULL) == 0);
    assert(pthread_cond_init(&worker->changed, NULL) == 0);
    pthread_t thread;
    assert(pthread_create(&thread, NULL, run, worker) == 0);
    assert(await_progress(worker, 1, false, 5000));
    return thread;
}
static void join(struct worker *worker, pthread_t thread) {
    assert(await_progress(worker, 0, true, 5000));
    assert(pthread_join(thread, NULL) == 0);
    wrlock_destroy(&worker->mm.mem.lock);
    assert(pthread_cond_destroy(&worker->changed) == 0);
    assert(pthread_mutex_destroy(&worker->lock) == 0);
}
static void blocked(struct worker *worker, unsigned next_interrupt) {
    assert(!await_progress(worker, next_interrupt, false, 50));
    // The actual loop checkpoint precedes mem->lock. Neither this mutex nor
    // the diagnostic mutex is held while admission waits on its condition.
    assert(pthread_mutex_trylock(&worker->lock) == 0);
    assert(pthread_mutex_unlock(&worker->lock) == 0);
    assert(pthread_rwlock_trywrlock(&worker->mm.mem.lock.l) == 0);
    assert(pthread_rwlock_unlock(&worker->mm.mem.lock.l) == 0);
    (void)snapshot();
}

#ifdef LEGACY_LOOP_NEGATIVE_CONTROL
static void test_missing_loop_context_reproduces(void) {
    struct worker worker = {0};
    pthread_t thread = launch(&worker, 43, 42);
    uint64_t generation = dsh_lifecycle_request_quiesce();
    assert(dsh_lifecycle_grant_session_drain(42, generation));
    release_interrupt(&worker, 1, NO_FINISH);
    blocked(&worker, 2);
    assert(snapshot().session_drain_active && snapshot().active_operations == 0);
    dsh_lifecycle_resume();
    assert(await_progress(&worker, 2, false, 5000));
    release_interrupt(&worker, 2, CLEAR_GROUP);
    join(&worker, thread);
    puts("PASS negative control: syscall-local identity alone strands the authorized Node at the real outer loop checkpoint");
}
#else
static void test_syscall_return_loop_and_revocation(void) {
    struct worker first = {0}, second = {0}, outsider = {0};
    pthread_t a = launch(&first, 43, 42), b = launch(&second, 44, 42), c = launch(&outsider, 99, 99);
    uint64_t generation = dsh_lifecycle_request_quiesce();
    assert(dsh_lifecycle_grant_session_drain(42, generation));
    release_interrupt(&first, 1, NO_FINISH);
    release_interrupt(&second, 1, NO_FINISH);
    release_interrupt(&outsider, 1, NO_FINISH);
    assert(await_progress(&first, 2, false, 5000) && await_progress(&second, 2, false, 5000));
    blocked(&outsider, 2);
    puts("PASS real syscall cleanup restores the outer task identity; two authorized libuv workers advance, other TGID parks");

    assert(dsh_lifecycle_revoke_session_drain(42, generation));
    release_interrupt(&first, 2, NO_FINISH);
    release_interrupt(&second, 2, NO_FINISH);
    blocked(&first, 3); blocked(&second, 3);
    assert(snapshot().active_operations == 0 && dsh_lifecycle_mark_quiescent(generation));
    puts("PASS revocation seals the real next CPU-loop checkpoint without holding guest or diagnostic mutexes");

    dsh_lifecycle_begin_resume();
    assert(dsh_lifecycle_grant_session_drain(42, snapshot().generation));
    assert(await_progress(&first, 3, false, 5000) && await_progress(&second, 3, false, 5000));
    blocked(&outsider, 2);
    release_interrupt(&first, 3, CLEAR_GROUP);
    release_interrupt(&second, 3, CLEAR_GROUP);
    join(&first, a); join(&second, b);
    assert(snapshot().active_operations == 0);
    dsh_lifecycle_resume();
    assert(await_progress(&outsider, 2, false, 5000));
    release_interrupt(&outsider, 2, CLEAR_GROUP);
    join(&outsider, c);
    puts("PASS resume permit reaches the real loop and pthread cleanup even after its prior loop context was restored");
}
static void test_exit_entries(void) {
    struct worker worker = {0};
    pthread_t thread = launch(&worker, 45, 42);
    uint64_t generation = dsh_lifecycle_request_quiesce();
    assert(dsh_lifecycle_grant_session_drain(42, generation));
    release_interrupt(&worker, 1, GROUP_EXIT);
    join(&worker, thread);
    assert(worker.group_exited && snapshot().active_operations == 0);
    dsh_lifecycle_resume();
    puts("PASS actual group-exit admission and pthread cleanup retain the managed group identity without leaking permits");

    struct worker cleared = {0};
    thread = launch(&cleared, 46, 42);
    generation = dsh_lifecycle_request_quiesce();
    assert(dsh_lifecycle_grant_session_drain(42, generation));
    release_interrupt(&cleared, 1, CLEAR_CURRENT);
    join(&cleared, thread);
    assert(snapshot().active_operations == 0);
    dsh_lifecycle_resume();
    puts("PASS pthread cleanup clears a stale syscall identity when current has been cleared");
}
#endif
int main(void) {
    alarm(30); // Failure guard; timeout is never a successful result.
    dsh_lifecycle_enable_admission_gate();
#ifdef LEGACY_LOOP_NEGATIVE_CONTROL
    test_missing_loop_context_reproduces();
#else
    test_syscall_return_loop_and_revocation();
    test_exit_entries();
#endif
    struct dsh_lifecycle_snapshot state = snapshot();
    assert(state.state == DSH_LIFECYCLE_RUNNING && state.active_operations == 0 &&
        !state.session_drain_active && state.tracking_overflows == 0);
    alarm(0);
    puts("All production task lifecycle context tests passed.");
    return 0;
}
