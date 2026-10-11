/* Execute the complete production kernel/futex.c and lifecycle core. The
 * fixture replaces only guest address translation/copy and poll's timeout
 * scheduling. Real pthreads, pipe wakeups, futex queues, task/group structures
 * and locks remain. No guest MMU/JIT or actual 180-second clock is exercised.
 */
#include <assert.h>
#include <errno.h>
#include <poll.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include "kernel/calls.h"
#include "fs/dsh-lifecycle.h"

__thread struct task *current;
lock_t pids_lock = LOCK_INITIALIZER;
static struct task guest, peer;
static struct mem memory;
static struct sighand handlers;
static struct {
    _Alignas(struct task) unsigned char alignment[
        offsetof(struct task, group_links) % _Alignof(struct task)];
    struct tgroup group;
} fixture;
#define test_group (fixture.group)
static dword_t word = 42;
static const addr_t word_address = 0x1000, timeout_address = 0x2000;
static struct timespec_ guest_timeout;
static pthread_mutex_t control = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t changed = PTHREAD_COND_INITIALIZER;
enum mode { ACTIVE_IDLE, QUIET_IDLE, NORMAL_WAKE, TIMED_WAIT, GROUP_EXIT };
static enum mode mode;
static unsigned polls, progressed, exit_calls;
static bool released, done, stop_progress;
static int result;

static struct timespec deadline(unsigned milliseconds) {
    struct timespec end;
    assert(clock_gettime(CLOCK_REALTIME, &end) == 0);
    end.tv_sec += milliseconds / 1000;
    end.tv_nsec += (long)(milliseconds % 1000) * 1000000;
    if (end.tv_nsec >= 1000000000) { end.tv_sec++; end.tv_nsec -= 1000000000; }
    return end;
}
static uint64_t monotonic_now(void) {
    struct timespec now;
    assert(clock_gettime(CLOCK_MONOTONIC, &now) == 0);
    return (uint64_t)now.tv_sec * UINT64_C(1000000000) + (uint64_t)now.tv_nsec;
}
static void wait_condition(bool for_done, unsigned target) {
    struct timespec end = deadline(5000);
    assert(pthread_mutex_lock(&control) == 0);
    int error = 0;
    while (!done && (for_done || polls < target ||
            (mode == ACTIVE_IDLE && progressed < target)) && !error)
        error = pthread_cond_timedwait(&changed, &control, &end);
    assert(error == 0 || error == ETIMEDOUT);
    assert(done || (!for_done && polls >= target &&
            (mode != ACTIVE_IDLE || progressed >= target)));
    assert(pthread_mutex_unlock(&control) == 0);
}
static int scheduled_poll(struct pollfd *fds, nfds_t count, int milliseconds) {
    assert(pthread_mutex_lock(&control) == 0);
    polls++;
    assert(pthread_cond_broadcast(&changed) == 0);
    if (mode == ACTIVE_IDLE) {
        struct timespec end = deadline(5000);
        while (progressed < polls)
            assert(pthread_cond_timedwait(&changed, &control, &end) == 0);
    }
    if (mode != TIMED_WAIT &&
            ((mode == ACTIVE_IDLE || mode == QUIET_IDLE) ? polls >= 2200 : polls >= 1)) {
        struct timespec end = deadline(5000);
        while (!released)
            assert(pthread_cond_timedwait(&changed, &control, &end) == 0);
    }
    assert(pthread_mutex_unlock(&control) == 0);
    // Still observe real readiness and use the production pipe for wakeups.
    // Only timeout duration is accelerated in the two idle cases.
    return poll(fds, count, mode == TIMED_WAIT ? milliseconds : 0);
}
void *mem_ptr(struct mem *mem, addr_t address, int type) {
    (void)type;
    return mem == &memory && address == word_address ? &word : NULL;
}
int user_read(addr_t address, void *buffer, size_t size) {
    if (address != timeout_address || size != sizeof(guest_timeout)) return 1;
    memcpy(buffer, &guest_timeout, size);
    return 0;
}
int user_write(addr_t address, const void *buffer, size_t size) {
    (void)address; (void)buffer; (void)size; assert(false); return 1;
}
struct task *pid_get_task(dword_t pid) {
    return pid == (dword_t)guest.pid ? &guest : pid == (dword_t)peer.pid ? &peer : NULL;
}
void ish_printk(const char *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    vfprintf(stderr, format, arguments);
    va_end(arguments);
}
_Noreturn void do_exit_group(int status) {
    assert(status == 0);
    assert(pthread_mutex_lock(&control) == 0);
    exit_calls++;
    fprintf(stderr, "OBSERVED unwanted exit_group(0): polls=%u progress_updates=%u\n", polls, progressed);
    assert(pthread_mutex_unlock(&control) == 0);
    pthread_exit(NULL);
}
#define poll scheduled_poll
#include "../ish-arm64/kernel/futex.c"
#undef poll

static void finished(void *unused) {
    (void)unused;
    assert(pthread_mutex_lock(&control) == 0);
    done = true;
    assert(pthread_cond_broadcast(&changed) == 0);
    assert(pthread_mutex_unlock(&control) == 0);
}
static void *progress_worker(void *unused) {
    (void)unused;
    current = &peer;
    assert(pthread_mutex_lock(&control) == 0);
    while (!stop_progress) {
        if (progressed < polls) {
            atomic_store_explicit(&test_group.last_progress_ns, monotonic_now(), memory_order_relaxed);
            progressed = polls;
            assert(pthread_cond_broadcast(&changed) == 0);
        } else {
            struct timespec end = deadline(5000);
            int error = pthread_cond_timedwait(&changed, &control, &end);
            assert(error == 0 || error == ETIMEDOUT);
            assert(error == 0 || stop_progress);
        }
    }
    assert(pthread_mutex_unlock(&control) == 0);
    return NULL;
}
static void *waiter(void *unused) {
    (void)unused;
    current = &guest;
    pthread_cleanup_push(finished, NULL);
    result = (int)sys_futex(word_address, FUTEX_WAIT_ | FUTEX_PRIVATE_FLAG_, word,
            mode == TIMED_WAIT ? timeout_address : 0, 0, 0);
    pthread_cleanup_pop(1);
    return NULL;
}
static void reset(enum mode test_mode) {
    mode = test_mode;
    polls = progressed = exit_calls = 0;
    released = done = stop_progress = false;
    result = 123456;
    test_group.doing_group_exit = false;
    test_group.group_exit_code = 0;
    guest.pending = 0;
    word = 42;
    atomic_store_explicit(&test_group.last_progress_ns, monotonic_now(), memory_order_relaxed);
}
static void join_waiter(pthread_t thread, int expected) {
    wait_condition(true, 0);
    assert(pthread_join(thread, NULL) == 0);
    assert(exit_calls == 0 && "a valid FUTEX_WAIT must never terminate its process");
    assert(result == expected && !guest.blocking);
    assert(pthread_mutex_trylock(&futex_lock.m) == 0);
    assert(pthread_mutex_unlock(&futex_lock.m) == 0);
    for (unsigned i = 0; i < FUTEX_HASH_SIZE; i++) assert(list_empty(&futex_hash[i]));
    struct dsh_lifecycle_snapshot snapshot;
    dsh_lifecycle_get_snapshot(&snapshot);
    assert(snapshot.active_operations == 0);
}
static void release_waiter(void) {
    assert(pthread_mutex_lock(&control) == 0);
    released = true;
    assert(pthread_cond_broadcast(&changed) == 0);
    assert(pthread_mutex_unlock(&control) == 0);
}
static void idle_case(enum mode test_mode) {
    reset(test_mode);
    pthread_t thread, progress;
    if (mode == ACTIVE_IDLE) assert(pthread_create(&progress, NULL, progress_worker, NULL) == 0);
    assert(pthread_create(&thread, NULL, waiter, NULL) == 0);
    wait_condition(false, 2200);
    assert(pthread_mutex_lock(&control) == 0);
    bool killed = exit_calls != 0;
    unsigned reached = polls, updates = progressed;
    if (mode == ACTIVE_IDLE) {
        stop_progress = true;
        assert(pthread_cond_broadcast(&changed) == 0);
    }
    assert(pthread_mutex_unlock(&control) == 0);
    if (mode == ACTIVE_IDLE) assert(pthread_join(progress, NULL) == 0);
    if (killed) {
        assert(pthread_join(thread, NULL) == 0);
        fprintf(stderr, "FAIL healthy/idle group killed: polls=%u other-thread-progress=%u\n", reached, updates);
        assert(!killed && "idle futex waiter must not call exit_group(0)");
    }
    assert(reached >= 2200 && !test_group.doing_group_exit);
    if (mode == ACTIVE_IDLE) assert(updates == reached && updates >= 2200);
    current = &peer;
    assert(futex_wake(word_address, 1) == 1);
    release_waiter();
    join_waiter(thread, 0);
    printf("PASS production futex indefinite %s wait survives 2200 timeouts and real pipe wake\n",
            mode == ACTIVE_IDLE ? "other-thread-active" : "whole-group-idle");
}
int main(void) {
    alarm(30);
    assert(setenv("ISH_EXEC_TRACE", "1", 1) == 0);
    setvbuf(stdout, NULL, _IONBF, 0);
    memset(&guest, 0, sizeof(guest));
    memset(&peer, 0, sizeof(peer));
    memset(&test_group, 0, sizeof(test_group));
    guest.pid = 91; peer.pid = 92;
    guest.group = peer.group = &test_group;
    guest.mem = peer.mem = &memory;
    guest.sighand = peer.sighand = &handlers;
    guest.futex_pipe[0] = guest.futex_pipe[1] = -1;
    peer.futex_pipe[0] = peer.futex_pipe[1] = -1;
    test_group.leader = &guest;
    lock_init(&test_group.lock);
    lock_init(&handlers.lock);
    wrlock_init(&memory.lock);
    list_init(&test_group.threads);
    list_add_tail(&test_group.threads, &guest.group_links);
    list_add_tail(&test_group.threads, &peer.group_links);
    list_init(&guest.children); list_init(&peer.children);
    idle_case(ACTIVE_IDLE);
    idle_case(QUIET_IDLE);
    reset(TIMED_WAIT);
    guest_timeout = (struct timespec_){.sec = 0, .nsec = 30000000};
    pthread_t thread;
    assert(pthread_create(&thread, NULL, waiter, NULL) == 0);
    join_waiter(thread, _ETIMEDOUT);
    puts("PASS production futex finite timeout still returns ETIMEDOUT without exit");

    reset(NORMAL_WAKE);
    assert(pthread_create(&thread, NULL, waiter, NULL) == 0);
    wait_condition(false, 1);
    current = &peer;
    assert(futex_wake(word_address, 1) == 1);
    release_waiter();
    join_waiter(thread, 0);
    puts("PASS production futex normal FUTEX_WAKE uses its actual pipe and queue");

    reset(GROUP_EXIT);
    assert(pthread_create(&thread, NULL, waiter, NULL) == 0);
    wait_condition(false, 1);
    // The waiter is held inside scheduled_poll; release_waiter synchronizes
    // this actual process-exit state before production reads it again.
    test_group.doing_group_exit = true;
    release_waiter();
    join_waiter(thread, _EINTR);
    assert(test_group.doing_group_exit);
    puts("PASS production futex explicit group exit interrupts waiting and cleans queue");

    assert(close(guest.futex_pipe[0]) == 0 && close(guest.futex_pipe[1]) == 0);
    wrlock_destroy(&memory.lock);
    assert(pthread_mutex_destroy(&handlers.lock.m) == 0);
    assert(pthread_mutex_destroy(&test_group.lock.m) == 0);
    return 0;
}
