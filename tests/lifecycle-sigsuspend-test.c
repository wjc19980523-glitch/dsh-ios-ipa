/* Execute the actual production sys_rt_sigsuspend and wait_for with real
 * pthreads. Only guest memory access and post-dispatch fd cleanup are shims. */
#include "kernel/calls.h"
#include "kernel/signal.h"
#include "kernel/lifecycle-wait.h"
#include "fs/dsh-lifecycle.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

__thread struct task *current;
static struct task guest;
static struct sighand handlers;
static sigset_t_ guest_mask;
static pthread_mutex_t control = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t changed = PTHREAD_COND_INITIALIZER;
static bool returned, cleaned;
static int cleanup_fd;

int user_read(addr_t address, void *buffer, size_t size) {
    if (address != (addr_t)(uintptr_t)&guest_mask || size > sizeof(guest_mask)) return 1;
    memcpy(buffer, &guest_mask, size);
    return 0;
}
#define UNBLOCKABLE_MASK (sig_mask(SIGKILL_) | sig_mask(SIGSTOP_))
#include "production-sigsuspend.h"

static struct timespec deadline(unsigned milliseconds) {
    struct timespec end;
    assert(clock_gettime(CLOCK_REALTIME, &end) == 0);
    end.tv_sec += milliseconds / 1000;
    end.tv_nsec += (long)(milliseconds % 1000) * 1000000;
    if (end.tv_nsec >= 1000000000) { end.tv_sec++; end.tv_nsec -= 1000000000; }
    return end;
}
static void flag(bool *value) {
    assert(pthread_mutex_lock(&control) == 0);
    *value = true;
    assert(pthread_cond_broadcast(&changed) == 0);
    assert(pthread_mutex_unlock(&control) == 0);
}
static bool await_flag(bool *value, unsigned milliseconds) {
    struct timespec end = deadline(milliseconds);
    assert(pthread_mutex_lock(&control) == 0);
    int rc = 0;
    while (!*value && rc == 0) rc = pthread_cond_timedwait(&changed, &control, &end);
    assert(rc == 0 || rc == ETIMEDOUT);
    bool result = *value;
    assert(pthread_mutex_unlock(&control) == 0);
    return result;
}
static struct dsh_lifecycle_snapshot snapshot(void) {
    struct dsh_lifecycle_snapshot value;
    dsh_lifecycle_get_snapshot(&value);
    return value;
}
static void await_signal_wait(void) {
    struct timespec end = deadline(5000);
    for (;;) {
        lock(&guest.waiting_cond_lock);
        bool waiting = guest.waiting_cond == &guest.pause;
        unlock(&guest.waiting_cond_lock);
        if (waiting) {
            // wait_for publishes its waiter while holding sighand->lock.
            // Taking this mutex proves pthread_cond_wait has released it.
            lock(&handlers.lock);
            assert(guest.has_saved_mask && guest.blocked == guest_mask);
            unlock(&handlers.lock);
            return;
        }
        struct timespec now;
        assert(clock_gettime(CLOCK_REALTIME, &now) == 0);
        assert(now.tv_sec < end.tv_sec || (now.tv_sec == end.tv_sec && now.tv_nsec < end.tv_nsec));
        struct timespec delay = {.tv_nsec = 1000000};
        nanosleep(&delay, NULL);
    }
}
static void test_signal_wakeup(void) {
    lock(&handlers.lock);
    guest.pending |= sig_mask(SIGUSR1_);
    notify(&guest.pause);
    unlock(&handlers.lock);
}
static void *run_sigsuspend(void *unused) {
    (void)unused;
    current = &guest;
    uint64_t permit = 0;
    // The same ARM64 classification used by handle_interrupt, followed by
    // its production syscall body and its mandatory post-wait admission.
    if (dsh_lifecycle_arm64_is_pure_wait(133)) dsh_lifecycle_checkpoint(guest.pid);
    else permit = dsh_lifecycle_operation_begin("guest_interrupt", guest.pid);
    assert(sys_rt_sigsuspend((addr_t)(uintptr_t)&guest_mask, sizeof(guest_mask)) == _EINTR);
    flag(&returned);
    if (!permit) permit = dsh_lifecycle_operation_begin("guest_wait_cleanup", guest.pid);
    assert(dsh_lifecycle_operation_depth() > 0);
    assert(close(cleanup_fd) == 0);
    flag(&cleaned);
    dsh_lifecycle_operation_end(permit);
    dsh_lifecycle_thread_exit();
    return NULL;
}
static pthread_t start_waiter(void) {
    returned = cleaned = false;
    guest.pending = 0;
    guest.blocked = sig_mask(SIGUSR2_);
    guest.has_saved_mask = false;
    guest_mask = 0;
    cleanup_fd = open("/dev/null", O_RDONLY);
    assert(cleanup_fd >= 0);
    pthread_t worker;
    assert(pthread_create(&worker, NULL, run_sigsuspend, NULL) == 0);
    return worker;
}
int main(void) {
    alarm(30);
    memset(&guest, 0, sizeof(guest));
    guest.pid = 91;
    guest.sighand = &handlers;
    lock_init(&handlers.lock);
    lock_init(&guest.waiting_cond_lock);
    cond_init(&guest.pause);
    dsh_lifecycle_enable_admission_gate();

    current = &guest;
    assert(sys_rt_sigsuspend(0, 1) == _EINVAL);
    assert(sys_rt_sigsuspend(0, sizeof(guest_mask)) == _EFAULT);
    assert(!guest.has_saved_mask && snapshot().active_operations == 0);
    current = NULL;

    pthread_t worker = start_waiter();
    await_signal_wait();
    assert(snapshot().active_operations == 0);
    test_signal_wakeup();
    assert(await_flag(&cleaned, 5000));
    assert(pthread_join(worker, NULL) == 0);
    puts("PASS production sigsuspend validates guest mask and wakes with EINTR while Running");

    for (unsigned cycle = 0; cycle < 10; cycle++) {
        worker = start_waiter();
        await_signal_wait();
        assert(snapshot().active_operations == 0);
        uint64_t generation = dsh_lifecycle_request_quiesce();
        assert(dsh_lifecycle_mark_quiescent(generation));
        test_signal_wakeup();
        assert(await_flag(&returned, 5000));
        assert(!await_flag(&cleaned, 40));
        assert(snapshot().active_operations == 0);
        assert(pthread_mutex_trylock(&handlers.lock.m) == 0);
        assert(pthread_mutex_unlock(&handlers.lock.m) == 0);
        assert(fcntl(cleanup_fd, F_GETFD) >= 0);
        dsh_lifecycle_begin_resume();
        assert(!await_flag(&cleaned, 40));
        dsh_lifecycle_resume();
        assert(await_flag(&cleaned, 5000));
        assert(pthread_join(worker, NULL) == 0);
        assert(snapshot().active_operations == 0);
    }
    puts("PASS 10 real sigsuspend waits allow drain; signal/close cleanup waits through Quiescent and Resuming");

    uint64_t generation = dsh_lifecycle_request_quiesce();
    assert(dsh_lifecycle_mark_quiescent(generation));
    worker = start_waiter();
    assert(!await_flag(&returned, 40));
    lock(&guest.waiting_cond_lock);
    assert(guest.waiting_cond == NULL);
    unlock(&guest.waiting_cond_lock);
    assert(!guest.has_saved_mask && snapshot().active_operations == 0);
    dsh_lifecycle_resume();
    await_signal_wait();
    test_signal_wakeup();
    assert(await_flag(&cleaned, 5000));
    assert(pthread_join(worker, NULL) == 0);
    puts("PASS sigsuspend entering after gate closes parks before signal-mask/condition work");
    assert(pthread_cond_destroy(&guest.pause.cond) == 0);
    assert(pthread_mutex_destroy(&guest.waiting_cond_lock.m) == 0);
    assert(pthread_mutex_destroy(&handlers.lock.m) == 0);
    return 0;
}
