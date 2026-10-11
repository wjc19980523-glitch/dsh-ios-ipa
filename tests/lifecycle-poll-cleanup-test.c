/* Link the real kernel sys_poll with its guest-memory/poll backend replaced.
 * Its admission and final-close ordering remain production code. */
#include "kernel/calls.h"
#include "fs/poll.h"
#include "fs/dsh-lifecycle.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

__thread struct task *current;
static struct task guest_task;
static struct fd retained_file;
static struct pollfd_ guest_poll;
static pthread_mutex_t control = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t changed = PTHREAD_COND_INITIALIZER;
static bool waiting, release_wait, returned, destroyed, finished;
static unsigned final_closes;

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
    int result = 0;
    while (!*flag && result == 0)
        result = pthread_cond_timedwait(&changed, &control, &end);
    assert(result == 0 || result == ETIMEDOUT);
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

int user_read(addr_t address, void *buffer, size_t count) {
    memcpy(buffer, (const void *) (uintptr_t) address, count);
    return 0;
}
int user_write(addr_t address, const void *buffer, size_t count) {
    memcpy((void *) (uintptr_t) address, buffer, count);
    return 0;
}
struct fd *f_get(fd_t number) { assert(number == 7); return &retained_file; }
struct fd *fd_retain(struct fd *fd) { atomic_fetch_add(&fd->refcount, 1); return fd; }
int fd_close(struct fd *fd) {
    assert(dsh_lifecycle_operation_depth() > 0);
    assert(atomic_fetch_sub(&fd->refcount, 1) == 1);
    assert(close(fd->real_fd) == 0);
    final_closes++;
    return 0;
}
struct poll *poll_create(void) {
    struct poll *poll = calloc(1, sizeof(*poll));
    assert(poll != NULL);
    return poll;
}
int poll_add_fd(struct poll *poll, struct fd *fd, int number, int types, union poll_fd_info info) {
    (void) poll; (void) types; (void) info;
    assert(fd == &retained_file && number == 7);
    return 0;
}
int poll_wait(struct poll *poll, poll_callback_t callback, void *context, struct timespec *timeout) {
    (void) poll; (void) callback; (void) context; (void) timeout;
    assert(dsh_lifecycle_operation_depth() == 0);
    // Model another guest thread closing the original reference while this
    // poll retains it. The production sys_poll must perform the final close.
    assert(atomic_fetch_sub(&retained_file.refcount, 1) == 2);
    set_flag(&waiting);
    assert(await_flag(&release_wait, 5000));
    set_flag(&returned);
    return 0; // backend has returned with all of its own locks released
}
void poll_destroy(struct poll *poll) {
    assert(dsh_lifecycle_operation_depth() > 0);
    set_flag(&destroyed);
    free(poll);
}
static void *run_guest_poll(void *unused) {
    (void) unused;
    current = &guest_task;
    assert(sys_poll((addr_t) (uintptr_t) &guest_poll, 1, -1) == 0);
    assert(dsh_lifecycle_operation_depth() == 0);
    dsh_lifecycle_thread_exit();
    set_flag(&finished);
    return NULL;
}
int main(int argc, char **argv) {
    assert(argc == 2);
    alarm(15);
    retained_file.real_fd = open(argv[1], O_RDWR | O_CREAT | O_TRUNC, 0600);
    assert(retained_file.real_fd >= 0);
    atomic_store(&retained_file.refcount, 1);
    guest_task.pid = 100;
    guest_poll.fd = 7;
    guest_poll.events = POLL_READ;
    dsh_lifecycle_enable_admission_gate();
    pthread_t thread;
    assert(pthread_create(&thread, NULL, run_guest_poll, NULL) == 0);
    assert(await_flag(&waiting, 5000));
    uint64_t generation = dsh_lifecycle_request_quiesce();
    assert(dsh_lifecycle_mark_quiescent(generation));
    set_flag(&release_wait);
    assert(await_flag(&returned, 5000));
    assert(!await_flag(&destroyed, 50));
    assert(fcntl(retained_file.real_fd, F_GETFD) >= 0);
    dsh_lifecycle_begin_resume();
    assert(!await_flag(&destroyed, 50));
    dsh_lifecycle_resume();
    assert(await_flag(&finished, 5000));
    assert(pthread_join(thread, NULL) == 0);
    assert(destroyed && final_closes == 1 && atomic_load(&retained_file.refcount) == 0);
    assert(fcntl(retained_file.real_fd, F_GETFD) < 0 && errno == EBADF);
    struct dsh_lifecycle_snapshot value;
    dsh_lifecycle_get_snapshot(&value);
    assert(value.active_operations == 0);
    alarm(0);
    puts("PASS production sys_poll waits before poll_destroy/final fd_close in Quiescent and Resuming");
    return 0;
}
