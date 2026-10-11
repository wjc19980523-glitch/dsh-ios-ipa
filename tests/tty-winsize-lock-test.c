/* Execute extracted production tty_read/ioctl/winsize and send_group_signal.
 * Only unrelated ioctl helpers, PID lookup and final signal delivery are shims.
 * The host call body is extracted from Terminal.m, including its lock contract. */
#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#if __APPLE__
#include <malloc/malloc.h>
#endif
#include "kernel/calls.h"
#include "kernel/task.h"
#include "kernel/signal.h"
#include "fs/fd.h"
#include "fs/tty.h"

__thread struct task *current;
lock_t pids_lock;
struct tty_driver pty_master;
static struct tty_driver memory_tty;
static struct tty primary, slave;
static struct task guest;
static struct tgroup group;
static struct pid process_group;
static struct { struct tty *tty; } self;
static struct fd read_fd, resize_fd;
static atomic_bool resize_has_tty, reader_has_pids;
static atomic_bool resize_waits_pids, reader_waits_tty;
static atomic_uint signals;
static __thread int role;
static __thread unsigned held_tty_locks;
static int reader_result, resize_result;
static char read_buffer[8];

static bool is_tty_lock(lock_t *value) {
    return value == &primary.lock || value == &slave.lock;
}
static void test_lock(lock_t *value) {
    if (role == 1 && value == &pids_lock) atomic_store(&resize_waits_pids, true);
    if (role == 2 && value == &primary.lock) atomic_store(&reader_waits_tty, true);
    __lock(value, __FILE__, __LINE__);
    if (is_tty_lock(value)) held_tty_locks++;
    if (role == 1 && value == &primary.lock) {
        atomic_store(&resize_has_tty, true);
        while (!atomic_load(&reader_has_pids)) sched_yield();
    }
    if (role == 2 && value == &pids_lock)
        atomic_store(&reader_has_pids, true);
}
static void test_unlock(lock_t *value) {
    if (is_tty_lock(value)) { assert(held_tty_locks); held_tty_locks--; }
    unlock(value);
}
#undef lock
#define lock(value) test_lock(value)
#define unlock(value) test_unlock(value)

struct pid *pid_get(dword_t pid) {
    assert(pid == 125);
    return &process_group;
}
void send_signal(struct task *task, int sig, struct siginfo_ info) {
    (void)info;
    assert(task == &guest && sig == SIGWINCH_);
    // The real send_group_signal takes pids_lock. Neither master nor slave may
    // still be held by its caller, even when the other thread has read input.
    assert(held_tty_locks == 0);
    atomic_fetch_add(&signals, 1);
}
bool try_self_signal(int sig) { (void)sig; assert(false); return false; }
static int tiocsctty(struct tty *tty, int force) {
    (void)tty; (void)force; assert(false); return _EIO;
}
static int tiocgpgrp(struct tty *tty, pid_t_ *pgid) {
    (void)tty; (void)pgid; assert(false); return _EIO;
}
#include "production-tty-winsize.h"

static const struct winsize_ requested = {.row = 41, .col = 109, .xpixel = 7, .ypixel = 9};
static const char *scenario;
static void *resize_thread(void *unused) {
    (void)unused;
    role = 1;
    if (strcmp(scenario, "host") == 0) {
        const int cols = requested.col, rows = requested.row;
#include "production-terminal-resize.h"
        resize_result = 0;
    } else {
        struct winsize_ size = requested;
        resize_result = tty_ioctl(&resize_fd, TIOCSWINSZ_, &size);
    }
    assert(held_tty_locks == 0);
    return NULL;
}
static void *read_thread(void *unused) {
    (void)unused;
    role = 2;
    current = &guest;
    while (!atomic_load(&resize_has_tty)) sched_yield();
    reader_result = tty_read(&read_fd, read_buffer, sizeof(read_buffer));
    assert(held_tty_locks == 0);
    return NULL;
}
static void watchdog(int sig) {
    (void)sig;
    if (atomic_load(&resize_has_tty) && atomic_load(&reader_has_pids) &&
            atomic_load(&resize_waits_pids) && atomic_load(&reader_waits_tty)) {
        static const char cycle[] = "FAIL production ABBA: resizer acquired TTY and attempts pids; reader acquired pids and attempts TTY\n";
        (void)write(STDERR_FILENO, cycle, sizeof(cycle) - 1);
        _exit(124);
    }
    static const char timeout[] = "FAIL fixture did not reach the complete production ABBA boundary\n";
    (void)write(STDERR_FILENO, timeout, sizeof(timeout) - 1);
    _exit(125);
}
static void tty_init(struct tty *tty, struct tty_driver *driver) {
    memset(tty, 0, sizeof(*tty));
    tty->driver = driver;
    tty->fg_group = 125;
    tty->termios.lflags = ICANON_;
    lock_init(&tty->lock);
    cond_init(&tty->produced);
    cond_init(&tty->consumed);
}
static void tty_destroy(struct tty *tty) {
    assert(pthread_mutex_destroy(&tty->lock.m) == 0);
    cond_destroy(&tty->produced);
    cond_destroy(&tty->consumed);
}
static void assert_unlocked(lock_t *value) {
    assert(pthread_mutex_trylock(&value->m) == 0);
    assert(pthread_mutex_unlock(&value->m) == 0);
}
int main(int argc, char **argv) {
    assert(argc == 2);
    scenario = argv[1];
    assert(strcmp(scenario, "host") == 0 || strcmp(scenario, "slave") == 0 ||
           strcmp(scenario, "master") == 0 || strcmp(scenario, "state") == 0);
    signal(SIGALRM, watchdog);
    alarm(15);
    lock_init(&pids_lock);
    lock_init(&group.lock);
    guest.pid = 125; guest.group = &group;
    group.leader = &guest; group.pgid = 125;
    list_init(&process_group.pgroup);
    list_add(&process_group.pgroup, &group.pgroup);
    current = &guest;
    tty_init(&primary, strcmp(scenario, "master") == 0 ? &pty_master : &memory_tty);
    tty_init(&slave, &memory_tty);
    primary.pty.other = &slave;
    group.tty = &primary;
    read_fd.tty = &primary; resize_fd.tty = &primary; self.tty = &primary;
    struct tty *target = strcmp(scenario, "master") == 0 ? &slave : &primary;
    if (strcmp(scenario, "state") == 0) {
        target->fg_group = 0;
        tty_set_winsize(target, requested);
        assert(memcmp(&target->winsize, &requested, sizeof(requested)) == 0);
        struct winsize_ observed = {};
        assert(tty_ioctl(&resize_fd, TIOCGWINSZ_, &observed) == 0);
        assert(memcmp(&observed, &requested, sizeof(requested)) == 0);
        primary.hung_up = true;
        struct winsize_ ignored = {.row = 1, .col = 1};
        assert(tty_ioctl(&resize_fd, TIOCSWINSZ_, &ignored) == _EIO);
        assert(memcmp(&target->winsize, &requested, sizeof(requested)) == 0);
        assert(atomic_load(&signals) == 0);
        puts("PASS production resize preserves size/getter/no-foreground and hung-up error semantics");
    } else {
        for (unsigned iteration = 0; iteration < 100; iteration++) {
            atomic_store(&resize_has_tty, false); atomic_store(&reader_has_pids, false);
            atomic_store(&resize_waits_pids, false); atomic_store(&reader_waits_tty, false);
            primary.buf[0] = 'R'; primary.buf[1] = '\n'; primary.bufsize = 2;
            memset(primary.buf_flag, 0, sizeof(primary.buf_flag)); primary.buf_flag[1] = true;
            pthread_t resizer, reader;
            assert(pthread_create(&resizer, NULL, resize_thread, NULL) == 0);
            assert(pthread_create(&reader, NULL, read_thread, NULL) == 0);
            assert(pthread_join(reader, NULL) == 0);
            assert(pthread_join(resizer, NULL) == 0);
            assert(reader_result == 2 && memcmp(read_buffer, "R\n", 2) == 0 && resize_result == 0);
            assert(target->winsize.row == requested.row && target->winsize.col == requested.col);
            if (strcmp(scenario, "host") != 0)
                assert(memcmp(&target->winsize, &requested, sizeof(requested)) == 0);
            assert(atomic_load(&signals) == iteration + 1);
            assert_unlocked(&primary.lock); assert_unlocked(&slave.lock); assert_unlocked(&pids_lock);
        }
        printf("PASS production %s resize vs tty_read 100 forced interleavings, SIGWINCH once after all TTY locks\n", scenario);
    }
    tty_destroy(&primary); tty_destroy(&slave);
    assert(pthread_mutex_destroy(&group.lock.m) == 0);
    assert(pthread_mutex_destroy(&pids_lock.m) == 0);
    alarm(0);
    return 0;
}
