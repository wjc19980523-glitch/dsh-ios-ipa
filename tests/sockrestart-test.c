// Compile the real production implementation with kernel type stubs only.
// Host sockets, bind/listen/dup2, and loopback traffic remain real syscalls.
#define _GNU_SOURCE
#include <assert.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#define container_of(ptr, type, member) ((type *) ((char *) (ptr) - offsetof(type, member)))
#include "fs/sockrestart.h"

typedef pthread_mutex_t lock_t;
#define LOCK_INITIALIZER PTHREAD_MUTEX_INITIALIZER
static int lock_depth;
static void lock(lock_t *mutex) {
    assert(lock_depth == 0); // fail promptly instead of hanging on recursive acquisition
    assert(pthread_mutex_lock(mutex) == 0);
    lock_depth++;
}
static void unlock(lock_t *mutex) {
    assert(lock_depth == 1);
    lock_depth--;
    assert(pthread_mutex_unlock(mutex) == 0);
}
struct fd_ops { int unused; };
const struct fd_ops socket_fdops = {0};
struct fd {
    const struct fd_ops *ops;
    int real_fd;
    struct { int protocol; } socket;
    struct fd_sockrestart sockrestart;
    atomic_uint refcount;
};
struct task { pthread_t thread; struct task_sockrestart sockrestart; };
static struct task test_task;
static struct task *current = &test_task;
static int retained, allocated, temporary_fds, logs, wakeups, final_closes;
static struct fd *drop_guest_reference_on_snapshot;
static bool close_before_compare_exchange;
static bool tracked[4096];
static char last_log[512];
enum failure { NONE, ALLOC, SNAPSHOT_FLAGS, SNAPSHOT_TYPE, SO_TYPE_SIZE,
    SNAPSHOT_REUSEADDR, SO_REUSEADDR_SIZE, GET_NAME, SOCKET, RESTORE_FLAGS,
    RESTORE_REUSEADDR, BIND, LISTEN, DUP2 };
static enum failure inject;

static bool snapshot_compare_exchange(atomic_uint *refcount, unsigned *expected, unsigned desired) {
    if (close_before_compare_exchange) {
        atomic_store(refcount, 0);
        close_before_compare_exchange = false;
    }
    bool success = atomic_compare_exchange_weak(refcount, expected, desired);
    if (success) retained++;
    return success;
}
static void fd_close(struct fd *fd) {
    assert(lock_depth == 0 && fd->refcount > 0);
    fd->refcount--;
    retained--;
    if (fd->refcount == 0) {
        // The real fd_close calls sock_close, which unregisters and locks again.
        sockrestart_end_listen(fd);
        assert(close(fd->real_fd) == 0);
        final_closes++;
    }
}
static void printk(const char *format, ...) {
    va_list args;
    va_start(args, format);
    vsnprintf(last_log, sizeof(last_log), format, args);
    va_end(args);
    logs++;
}
static bool fail(enum failure requested) {
    if (inject != requested) return false;
    inject = NONE;
    errno = EIO;
    return true;
}
static void *saved_malloc(size_t size) {
    if (fail(ALLOC)) return NULL;
    void *memory = malloc(size);
    assert(memory != NULL);
    allocated++;
    return memory;
}
static void saved_free(void *memory) {
    assert(memory != NULL && allocated > 0);
    allocated--;
    free(memory);
}
static int restore_socket(int family, int type, int protocol) {
    if (fail(SOCKET)) return -1;
    int fd = socket(family, type, protocol);
    if (fd >= 0) {
        assert(fd < (int) (sizeof(tracked) / sizeof(tracked[0])) && !tracked[fd]);
        tracked[fd] = true;
        temporary_fds++;
    }
    return fd;
}
static int restore_close(int fd) {
    assert(fd >= 0 && fd < (int) (sizeof(tracked) / sizeof(tracked[0])));
    assert(tracked[fd]);
    tracked[fd] = false;
    temporary_fds--;
    return close(fd);
}
static int restore_bind(int fd, const struct sockaddr *address, socklen_t length) {
    if (fail(BIND)) return -1;
    return bind(fd, address, length);
}
static int restore_listen(int fd, int backlog) {
    if (fail(LISTEN)) return -1;
    return listen(fd, backlog);
}
static int restore_dup2(int from, int to) {
    if (fail(DUP2)) return -1;
    int result = dup2(from, to);
    // A reused target descriptor transfers ownership instead of being closed.
    if (result >= 0 && from == to && tracked[from]) {
        tracked[from] = false;
        temporary_fds--;
    }
    return result;
}
static int snapshot_getsockopt(int fd, int level, int name, void *value, socklen_t *length) {
    if (drop_guest_reference_on_snapshot) {
        assert(drop_guest_reference_on_snapshot->refcount == 2);
        drop_guest_reference_on_snapshot->refcount--;
        drop_guest_reference_on_snapshot = NULL;
    }
    if (name == SO_TYPE && fail(SNAPSHOT_TYPE)) return -1;
    if (name == SO_REUSEADDR && fail(SNAPSHOT_REUSEADDR)) return -1;
    int result = getsockopt(fd, level, name, value, length);
    if (name == SO_TYPE && fail(SO_TYPE_SIZE)) *length = 0;
    if (name == SO_REUSEADDR && fail(SO_REUSEADDR_SIZE)) *length = 0;
    return result;
}
static int restore_setsockopt(int fd, int level, int name, const void *value, socklen_t length) {
    assert(level == SOL_SOCKET && name == SO_REUSEADDR && length == sizeof(int));
    if (fail(RESTORE_REUSEADDR)) return -1;
    return setsockopt(fd, level, name, value, length);
}
static int snapshot_getsockname(int fd, struct sockaddr *address, socklen_t *length) {
    if (fail(GET_NAME)) return -1;
    return getsockname(fd, address, length);
}
static int recovery_fcntl(int fd, int command, int value) {
    if ((command == F_GETFL && fail(SNAPSHOT_FLAGS)) ||
        (command == F_SETFL && fail(RESTORE_FLAGS))) return -1;
    return fcntl(fd, command, value);
}
static int wake_thread(pthread_t thread, int signal_number) {
    (void) thread;
    assert(signal_number == SIGUSR1);
    wakeups++;
    return 0;
}

#define malloc saved_malloc
#define free saved_free
#define socket(...) restore_socket(__VA_ARGS__)
#define close restore_close
#define bind restore_bind
#define listen(...) restore_listen(__VA_ARGS__)
#define dup2 restore_dup2
#define getsockopt snapshot_getsockopt
#define setsockopt restore_setsockopt
#define getsockname snapshot_getsockname
#define fcntl recovery_fcntl
#define pthread_kill wake_thread
#undef atomic_compare_exchange_weak
#define atomic_compare_exchange_weak snapshot_compare_exchange
#include SOCKRESTART_SOURCE
#undef malloc
#undef free
#undef socket
#undef close
#undef bind
#undef listen
#undef dup2
#undef getsockopt
#undef setsockopt
#undef getsockname
#undef fcntl
#undef pthread_kill
#undef atomic_compare_exchange_weak

static int fd_count(void) {
    DIR *directory = opendir("/dev/fd");
    assert(directory != NULL);
    int count = 0;
    struct dirent *entry;
    while ((entry = readdir(directory))) {
        char *end;
        (void) strtol(entry->d_name, &end, 10);
        if (entry->d_name[0] != '\0' && *end == '\0') count++;
    }
    assert(closedir(directory) == 0);
    return count - 1; // exclude the directory descriptor held while counting
}
static struct fd listener_with_reuse_addr(struct sockaddr_in *address, int reuse_addr) {
    int descriptor = socket(AF_INET, SOCK_STREAM, 0);
    assert(descriptor >= 0);
    assert(setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse_addr, sizeof(reuse_addr)) == 0);
    *address = (struct sockaddr_in) {.sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    assert(bind(descriptor, (struct sockaddr *) address, sizeof(*address)) == 0);
    socklen_t length = sizeof(*address);
    assert(getsockname(descriptor, (struct sockaddr *) address, &length) == 0);
    assert(listen(descriptor, 8) == 0);
    struct fd fd = {.ops = &socket_fdops, .real_fd = descriptor, .refcount = 1};
    return fd;
}
static struct fd listener(struct sockaddr_in *address) {
    return listener_with_reuse_addr(address, 0);
}
static void assert_drained(struct fd *fd) {
    assert(fd->refcount == 1 && retained == 0 && allocated == 0 && temporary_fds == 0);
    assert(list_empty(&saved_sockets));
    assert(inject == NONE);
}
static void retire(struct fd *fd, int before) {
    sockrestart_end_listen(fd);
    assert(list_empty(&listen_fds));
    assert(close(fd->real_fd) == 0);
    assert(fd_count() == before);
}
static void replace_with_nonsocket(int target) {
    int dummy = open("/dev/null", O_RDWR);
    assert(dummy >= 0 && dummy != target);
    assert(dup2(dummy, target) == target);
    assert(close(dummy) == 0);
}
static int64_t socket_now_ns(void) {
    struct timespec now;
    assert(clock_gettime(CLOCK_MONOTONIC, &now) == 0);
    return (int64_t) now.tv_sec * 1000000000 + now.tv_nsec;
}
static void wait_socket_ready(int fd, short events, int64_t deadline) {
    for (;;) {
        int64_t remaining = deadline - socket_now_ns();
        assert(remaining > 0);
        struct pollfd ready = {.fd = fd, .events = events};
        int result = poll(&ready, 1, (int) ((remaining + 999999) / 1000000));
        if (result < 0) {
            assert(errno == EINTR);
            continue; // Preserve the original deadline across interruptions.
        }
        assert(result > 0 && (ready.revents & events));
        assert(!(ready.revents & (POLLERR | POLLHUP | POLLNVAL)));
        return;
    }
}
static int accept_ready_listener(int listener_fd, int64_t deadline) {
    for (;;) {
        wait_socket_ready(listener_fd, POLLIN, deadline);
        int accepted = accept(listener_fd, NULL, NULL);
        if (accepted >= 0) return accepted;
        assert(errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK);
        // A stale readiness result must not turn into an unbounded retry.
    }
}
static void transfer_socket_byte(int fd, char *byte, bool sending, int64_t deadline) {
    for (;;) {
        wait_socket_ready(fd, sending ? POLLOUT : POLLIN, deadline);
        // Accepted sockets inherit O_NONBLOCK on Darwin, while Linux leaves
        // them blocking. Per-call nonblocking I/O keeps both bounded after a
        // stale readiness result without changing the descriptor's flags.
        ssize_t result = sending ? send(fd, byte, 1, MSG_DONTWAIT)
                                 : recv(fd, byte, 1, MSG_DONTWAIT);
        if (result == 1) return;
        assert(result < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK));
    }
}
static void real_round_trip(int listener_fd, struct sockaddr_in *address) {
#ifndef __APPLE__
    // Darwin defines SO_ACCEPTCONN as an internal socket option bit, but its
    // getsockopt switch does not expose it. The real connect/accept exchange
    // below proves listening on every platform (and fails if listen is lost).
    int accepting = 0;
    socklen_t length = sizeof(accepting);
    assert(getsockopt(listener_fd, SOL_SOCKET, SO_ACCEPTCONN, &accepting, &length) == 0 && accepting);
#endif
    int client = socket(AF_INET, SOCK_STREAM, 0);
    assert(client >= 0);
    assert(connect(client, (struct sockaddr *) address, sizeof(*address)) == 0);
    int64_t deadline = socket_now_ns() + 5000000000LL;
    // A completed connect need not make a nonblocking listener immediately
    // acceptable on Darwin. Wait for readiness without changing its flags.
    int accepted = accept_ready_listener(listener_fd, deadline);
    assert(accepted >= 0);
    char byte = 'x';
    transfer_socket_byte(client, &byte, true, deadline);
    byte = 0;
    transfer_socket_byte(accepted, &byte, false, deadline);
    assert(byte == 'x');
    assert(close(accepted) == 0 && close(client) == 0);
}
static void wait_socket_eof(int fd, int64_t deadline) {
    for (;;) {
        int64_t remaining = deadline - socket_now_ns();
        assert(remaining > 0);
        struct pollfd ready = {.fd = fd, .events = POLLIN};
        int result = poll(&ready, 1, (int) ((remaining + 999999) / 1000000));
        if (result < 0) {
            assert(errno == EINTR);
            continue;
        }
        assert(result > 0 && (ready.revents & (POLLIN | POLLHUP)));
        assert(!(ready.revents & (POLLERR | POLLNVAL)));
        char byte;
        ssize_t received = recv(fd, &byte, 1, MSG_DONTWAIT);
        if (received == 0) return;
        assert(received < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK));
    }
}
static void active_close_round_trip(int listener_fd, struct sockaddr_in *address) {
    int client = socket(AF_INET, SOCK_STREAM, 0);
    assert(client >= 0);
    assert(connect(client, (struct sockaddr *) address, sizeof(*address)) == 0);
    int64_t deadline = socket_now_ns() + 5000000000LL;
    int accepted = accept_ready_listener(listener_fd, deadline);
    char byte = 'x';
    transfer_socket_byte(client, &byte, true, deadline);
    byte = 0;
    transfer_socket_byte(accepted, &byte, false, deadline);
    assert(byte == 'x');
    byte = 'y';
    transfer_socket_byte(accepted, &byte, true, deadline);
    byte = 0;
    transfer_socket_byte(client, &byte, false, deadline);
    assert(byte == 'y');
    // The server sends FIN first; the peer observes EOF before closing. The
    // server then observes the peer's FIN before releasing the accepted socket.
    // This puts the server endpoint into TIME_WAIT without platform /proc data.
    assert(shutdown(accepted, SHUT_WR) == 0);
    wait_socket_eof(client, deadline);
    assert(close(client) == 0);
    wait_socket_eof(accepted, deadline);
    assert(close(accepted) == 0);
}
static void same_port_after_traffic(void) {
    int before = fd_count();
    struct sockaddr_in address;
    struct fd fd = listener_with_reuse_addr(&address, 1);
    int original_reuse_addr = 0;
    socklen_t original_size = sizeof(original_reuse_addr);
    assert(getsockopt(fd.real_fd, SOL_SOCKET, SO_REUSEADDR, &original_reuse_addr, &original_size) == 0 &&
           original_size == sizeof(original_reuse_addr) && original_reuse_addr != 0);
    int flags = fcntl(fd.real_fd, F_GETFL, 0);
    assert(flags >= 0 && fcntl(fd.real_fd, F_SETFL, flags | O_NONBLOCK) == 0);
    sockrestart_begin_listen(&fd, 8);
    for (int iteration = 0; iteration < 100; iteration++) {
        active_close_round_trip(fd.real_fd, &address);
        sockrestart_on_suspend();
        replace_with_nonsocket(fd.real_fd);
        sockrestart_on_resume();
        assert_drained(&fd);
        int reuse_addr = 0;
        socklen_t size = sizeof(reuse_addr);
        assert(getsockopt(fd.real_fd, SOL_SOCKET, SO_REUSEADDR, &reuse_addr, &size) == 0 &&
               size == sizeof(reuse_addr) && reuse_addr == original_reuse_addr);
        int restored_flags = fcntl(fd.real_fd, F_GETFL, 0);
        assert(restored_flags >= 0 && (restored_flags & O_NONBLOCK) != 0);
        assert(accept(fd.real_fd, NULL, NULL) == -1 &&
               (errno == EAGAIN || errno == EWOULDBLOCK));
    }
    real_round_trip(fd.real_fd, &address); // the final rebuild must also serve
    retire(&fd, before);
}
static void successful_resume(void) {
    int before = fd_count();
    struct sockaddr_in address;
    struct fd fd = listener(&address);
    int original_flags = fcntl(fd.real_fd, F_GETFL, 0);
    assert(original_flags >= 0 && fcntl(fd.real_fd, F_SETFL, original_flags | O_NONBLOCK) == 0);
    sockrestart_begin_listen(&fd, 8);
    sockrestart_begin_listen(&fd, 9); // repeated listen refreshes, never duplicates
    assert(list_size(&listen_fds) == 1 && fd.sockrestart.backlog == 9);
    sockrestart_begin_listen_wait(&fd);
    sockrestart_on_suspend();
    assert(allocated == 1 && retained == 1 && list_size(&saved_sockets) == 1);
    replace_with_nonsocket(fd.real_fd); // emulate iOS leaving a non-socket fd
    int old_wakeups = wakeups;
    sockrestart_on_resume();
    assert_drained(&fd);
    assert(wakeups == old_wakeups + 1 && sockrestart_should_restart_listen_wait());
    assert(!sockrestart_should_restart_listen_wait());
    sockrestart_end_listen_wait(&fd);
    assert(list_empty(&listen_tasks));
    int restored_flags = fcntl(fd.real_fd, F_GETFL, 0);
    assert(restored_flags >= 0 && (restored_flags & O_NONBLOCK) != 0);
    int reuse_addr = -1;
    socklen_t size = sizeof(reuse_addr);
    assert(getsockopt(fd.real_fd, SOL_SOCKET, SO_REUSEADDR, &reuse_addr, &size) == 0 &&
           size == sizeof(reuse_addr) && reuse_addr == 0);
    // An event loop depends on empty/stale accept readiness returning EAGAIN.
    // A blocking replacement would hang this empty-queue call.
    assert(accept(fd.real_fd, NULL, NULL) == -1 &&
           (errno == EAGAIN || errno == EWOULDBLOCK));
    real_round_trip(fd.real_fd, &address);
    retire(&fd, before);
}
static void snapshot_failure(enum failure failure) {
    int before = fd_count(), old_logs = logs;
    struct sockaddr_in address;
    struct fd fd = listener(&address);
    sockrestart_begin_listen(&fd, 8);
    inject = failure;
    sockrestart_on_suspend();
    sockrestart_on_resume();
    assert_drained(&fd);
    if (failure != ALLOC) assert(logs > old_logs);
    if (failure == SNAPSHOT_REUSEADDR || failure == SO_REUSEADDR_SIZE)
        assert(strstr(last_log, "SO_REUSEADDR") != NULL);
    real_round_trip(fd.real_fd, &address); // snapshot failures preserve the original
    retire(&fd, before);
}
static void restore_failure(enum failure failure) {
    int before = fd_count(), old_logs = logs;
    struct sockaddr_in address;
    struct fd fd = listener(&address);
    sockrestart_begin_listen(&fd, 8);
    sockrestart_on_suspend();
    replace_with_nonsocket(fd.real_fd);
    struct stat original, after;
    assert(fstat(fd.real_fd, &original) == 0);
    inject = failure;
    sockrestart_on_resume();
    assert_drained(&fd);
    assert(logs > old_logs && strstr(last_log, "failed") != NULL);
    if (failure == RESTORE_REUSEADDR) assert(strstr(last_log, "SO_REUSEADDR") != NULL);
    assert(fstat(fd.real_fd, &after) == 0);
    assert(original.st_dev == after.st_dev && original.st_ino == after.st_ino && S_ISCHR(after.st_mode));
    retire(&fd, before);
}
static void reused_descriptor(void) {
    int before = fd_count();
    struct sockaddr_in address;
    struct fd fd = listener(&address);
    sockrestart_begin_listen(&fd, 8);
    sockrestart_on_suspend();
    assert(close(fd.real_fd) == 0);
    // With the target released, socket() reuses it. Successful dup2(fd, fd)
    // must transfer ownership without cleanup closing the restored fd.
    sockrestart_on_resume();
    assert_drained(&fd);
    real_round_trip(fd.real_fd, &address);
    retire(&fd, before);
}
static void still_live_listener(void) {
    int before = fd_count(), old_logs = logs;
    struct sockaddr_in address;
    struct fd fd = listener(&address);
    sockrestart_begin_listen(&fd, 8);
    sockrestart_on_suspend();
    // A surviving listener causes a real EADDRINUSE, not a synthetic failure.
    sockrestart_on_resume();
    assert_drained(&fd);
    assert(logs > old_logs && strstr(last_log, "rebinding") != NULL);
    real_round_trip(fd.real_fd, &address);
    retire(&fd, before);
}
static void final_reference_on_resume(void) {
    int before = fd_count(), old_closes = final_closes;
    struct sockaddr_in address;
    struct fd fd = listener(&address);
    sockrestart_begin_listen(&fd, 8);
    sockrestart_on_suspend();
    assert(fd.refcount == 2);
    fd.refcount--; // the guest closes while the saved snapshot keeps the fd alive
    replace_with_nonsocket(fd.real_fd);
    sockrestart_on_resume();
    assert(fd.refcount == 0 && retained == 0 && allocated == 0 && temporary_fds == 0);
    assert(final_closes == old_closes + 1 && list_empty(&listen_fds) && list_empty(&saved_sockets));
    assert(fd_count() == before);
}
static void final_reference_on_snapshot_failure(enum failure failure) {
    int before = fd_count(), old_closes = final_closes;
    struct sockaddr_in address;
    struct fd fd = listener(&address);
    sockrestart_begin_listen(&fd, 8);
    drop_guest_reference_on_snapshot = &fd;
    inject = failure;
    sockrestart_on_suspend();
    assert(fd.refcount == 0 && retained == 0 && allocated == 0 && temporary_fds == 0);
    assert(final_closes == old_closes + 1 && list_empty(&listen_fds) && list_empty(&saved_sockets));
    assert(drop_guest_reference_on_snapshot == NULL && inject == NONE);
    assert(fd_count() == before);
}
static void closing_listener_is_not_resurrected(bool races_with_retain) {
    int before = fd_count();
    struct sockaddr_in address;
    struct fd fd = listener(&address);
    sockrestart_begin_listen(&fd, 8);
    if (races_with_retain) close_before_compare_exchange = true;
    else atomic_store(&fd.refcount, 0);
    sockrestart_on_suspend();
    sockrestart_on_resume();
    assert(fd.refcount == 0 && retained == 0 && allocated == 0 && temporary_fds == 0);
    assert(!close_before_compare_exchange && list_empty(&saved_sockets));
    // Finish the original closer which had been waiting for end_listen's lock.
    retire(&fd, before);
}
int main(void) {
    same_port_after_traffic();
    reused_descriptor();
    still_live_listener();
    final_reference_on_resume();
    final_reference_on_snapshot_failure(SNAPSHOT_TYPE);
    final_reference_on_snapshot_failure(SNAPSHOT_REUSEADDR);
    final_reference_on_snapshot_failure(SO_REUSEADDR_SIZE);
    final_reference_on_snapshot_failure(GET_NAME);
    closing_listener_is_not_resurrected(false);
    closing_listener_is_not_resurrected(true);
    for (int iteration = 0; iteration < 100; iteration++) {
        successful_resume();
        snapshot_failure(ALLOC);
        snapshot_failure(SNAPSHOT_FLAGS);
        snapshot_failure(SNAPSHOT_TYPE);
        snapshot_failure(SO_TYPE_SIZE);
        snapshot_failure(SNAPSHOT_REUSEADDR);
        snapshot_failure(SO_REUSEADDR_SIZE);
        snapshot_failure(GET_NAME);
        restore_failure(SOCKET);
        restore_failure(RESTORE_FLAGS);
        restore_failure(RESTORE_REUSEADDR);
        restore_failure(BIND);
        restore_failure(LISTEN);
        restore_failure(DUP2);
    }
    printf("ok sockrestart: 100 same-port TIME_WAIT resumes + 100 nonblocking loopback resumes + 1300 injected failures + reused/live/final/zero-ref cases; fd/malloc/retain balance zero\n");
    return 0;
}
