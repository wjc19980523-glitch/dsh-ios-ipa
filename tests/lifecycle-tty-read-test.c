/* Production sys_read/sys_readv/preadv2, fd retention/close and tty_read run
 * verbatim with production wait_for and the lifecycle core. Guest memory access
 * is a checked copy shim; unrelated poll/inode/mount cleanup is never needed. */
#include "debug.h"
#include "kernel/calls.h"
#include "kernel/task.h"
#include "kernel/mm.h"
#include "kernel/fs.h"
#include "kernel/signal.h"
#include "kernel/resource.h"
#include "fs/fd.h"
#include "fs/tty.h"
#include "fs/inode.h"
#include "fs/poll.h"
#include "fs/real.h"
#include "fs/dsh-lifecycle.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

__thread struct task *current;
lock_t pids_lock;
struct tty_driver pty_master;
static struct tty_driver memory_tty;
static atomic_uint copyouts, final_closes, file_reads;
const struct fd_ops realfs_fdops;

int user_read(addr_t address, void *buffer, size_t size) {
    assert(dsh_lifecycle_operation_depth() > 0);
    if (!address) return 1;
    memcpy(buffer, (const void *)(uintptr_t)address, size);
    return 0;
}
int user_write(addr_t address, const void *buffer, size_t size) {
    assert(dsh_lifecycle_operation_depth() > 0);
    if (!address) return 1;
    memcpy((void *)(uintptr_t)address, buffer, size);
    atomic_fetch_add(&copyouts, 1);
    return 0;
}
bool try_self_signal(int signal) { (void)signal; return true; }
void poll_cleanup_fd(struct fd *fd) {
    assert(dsh_lifecycle_operation_depth() > 0);
    assert(fd->mount == NULL && fd->inode == NULL);
    // fd_close frees the allocation; release its actual pthread resources here.
    assert(pthread_mutex_destroy(&fd->poll_lock.m) == 0);
    assert(pthread_mutex_destroy(&fd->lock.m) == 0);
    cond_destroy(&fd->cond);
}
void inode_release(struct inode_data *inode) { (void)inode; assert(false); }
void mount_release(struct mount *mount) { (void)mount; assert(false); }
void file_lock_remove_owned_by(struct fd *fd, void *owner) { (void)fd; (void)owner; assert(false); }
int fcntl_getlk(struct fd *fd, struct flock_ *flock) { (void)fd; (void)flock; assert(false); return _EIO; }
int fcntl_setlk(struct fd *fd, struct flock_ *flock, bool block) { (void)fd; (void)flock; (void)block; assert(false); return _EIO; }
rlim_t_ rlimit(int resource) { assert(resource == RLIMIT_NOFILE_); return 512; }
int errno_map(void) { assert(errno == EBADF); return _EBADF; }
dword_t sys_preadv(fd_t fd, addr_t vec, dword_t count, dword_t lo, dword_t hi) {
    (void)fd; (void)vec; (void)count; (void)lo; (void)hi;
    assert(false); return _ESPIPE;
}
#define RWF_HIPRI_ 0x1
#define RWF_NOWAIT_ 0x8
#include "production-tty-read.h"

static int test_fd_close(struct fd *fd) {
    (void)fd;
    assert(dsh_lifecycle_operation_depth() > 0);
    atomic_fetch_add(&final_closes, 1);
    return 0;
}
struct dev_ops tty_dev = {.fd = {.read = tty_read, .close = test_fd_close}};
static ssize_t file_read(struct fd *fd, void *buf, size_t size) {
    (void)fd;
    assert(dsh_lifecycle_operation_depth() > 0);
    struct dsh_lifecycle_snapshot state;
    dsh_lifecycle_get_snapshot(&state);
    assert(state.active_operations > 0 && state.paused_fileless_operations == 0);
    enum dsh_lifecycle_read_fd_kind expected = DSH_READ_FD_OTHER;
    if (S_ISREG(fd->type)) expected = DSH_READ_FD_REGULAR;
    else if (S_ISFIFO(fd->type)) expected = DSH_READ_FD_PIPE;
    else if (S_ISSOCK(fd->type)) expected = DSH_READ_FD_SOCKET;
    else if (S_ISCHR(fd->type)) expected = DSH_READ_FD_CHARACTER;
    else if (S_ISBLK(fd->type)) expected = DSH_READ_FD_BLOCK;
    assert(state.operation_count == 1 && state.operations[0].read_fd_observed &&
        state.operations[0].read_guest_fd == 0 && state.operations[0].read_fd_kind == expected);
    atomic_fetch_add(&file_reads, 1);
    if (size) ((char *)buf)[0] = 'F';
    return size ? 1 : 0;
}
static const struct fd_ops file_ops = {.read = file_read, .close = test_fd_close};

enum read_kind { READ_SINGLE, READ_VECTOR, READ_STREAM_VECTOR };
enum critical_kind { NO_CRITICAL, NESTED_SCOPE, CRITICAL_SQLITE_TRANSACTION, CRITICAL_SQLITE_RECOVERY, NATIVE_FLOCK };
struct reader {
    struct task guest;
    struct tgroup group;
    struct sighand handlers;
    struct fdtable files;
    struct tty tty;
    struct mm mm;
    enum read_kind kind;
    enum critical_kind critical;
    char output[8];
    int result;
    pthread_t thread;
    atomic_bool started, returned;
};
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
static void delay_ms(unsigned milliseconds) {
    struct timespec delay = {.tv_sec = milliseconds / 1000,
                            .tv_nsec = (long)(milliseconds % 1000) * 1000000};
    nanosleep(&delay, NULL);
}
static void await_bool(atomic_bool *flag) {
    uint64_t deadline = now_ms() + 5000;
    while (!atomic_load(flag)) { assert(now_ms() < deadline); delay_ms(1); }
}
static void await_waiting(struct reader *reader, bool expected) {
    uint64_t deadline = now_ms() + 5000;
    for (;;) {
        lock(&reader->guest.waiting_cond_lock);
        bool waiting = reader->guest.waiting_cond == &reader->tty.produced;
        unlock(&reader->guest.waiting_cond_lock);
        if (waiting == expected) {
            lock(&reader->tty.lock);
            unlock(&reader->tty.lock);
            return;
        }
        assert(now_ms() < deadline); delay_ms(1);
    }
}
static void assert_no_guest_locks(struct reader *reader) {
    lock_t *locks[] = {&reader->tty.lock, &pids_lock, &reader->files.lock,
                      &reader->handlers.lock, &reader->group.lock};
    for (unsigned i = 0; i < sizeof(locks) / sizeof(locks[0]); i++) {
        assert(pthread_mutex_trylock(&locks[i]->m) == 0);
        assert(pthread_mutex_unlock(&locks[i]->m) == 0);
    }
    assert(pthread_rwlock_trywrlock(&reader->mm.mem.lock.l) == 0);
    assert(pthread_rwlock_unlock(&reader->mm.mem.lock.l) == 0);
}
static void feed(struct reader *reader, const char *text) {
    lock(&reader->tty.lock);
    size_t length = strlen(text);
    assert(length < sizeof(reader->tty.buf));
    memcpy(reader->tty.buf, text, length);
    memset(reader->tty.buf_flag, 0, sizeof(reader->tty.buf_flag));
    reader->tty.buf_flag[length - 1] = true;
    reader->tty.bufsize = length;
    notify(&reader->tty.produced);
    unlock(&reader->tty.lock);
}
static void reader_init(struct reader *reader, int pid) {
    memset(reader, 0, sizeof(*reader));
    reader->guest.pid = pid;
    reader->guest.files = &reader->files;
    reader->guest.group = &reader->group;
    reader->guest.sighand = &reader->handlers;
    reader->guest.mm = &reader->mm;
    reader->group.pgid = pid;
    reader->files.size = 2;
    reader->files.files = calloc(reader->files.size, sizeof(struct fd *));
    reader->files.cloexec = calloc(1, BITS_SIZE(reader->files.size));
    assert(reader->files.files && reader->files.cloexec);
    lock_init(&reader->files.lock);
    lock_init(&reader->guest.waiting_cond_lock);
    lock_init(&reader->handlers.lock);
    lock_init(&reader->group.lock);
    lock_init(&reader->tty.lock);
    wrlock_init(&reader->mm.mem.lock);
    cond_init(&reader->tty.produced);
    cond_init(&reader->tty.consumed);
    reader->tty.driver = &memory_tty;
    reader->tty.termios.lflags = ICANON_;
    reader->files.files[0] = fd_create(&tty_dev.fd);
    assert(reader->files.files[0]);
    reader->files.files[0]->tty = &reader->tty;
    reader->files.files[0]->type = S_IFCHR;
}
static void reader_destroy(struct reader *reader) {
    current = &reader->guest;
    uint64_t permit = dsh_lifecycle_operation_begin("fixture_close", reader->guest.pid);
    lock(&reader->files.lock);
    for (unsigned i = 0; i < reader->files.size; i++)
        if (reader->files.files[i]) assert(fdtable_close(&reader->files, i) == 0);
    free(reader->files.files);
    free(reader->files.cloexec);
    unlock(&reader->files.lock);
    dsh_lifecycle_operation_end(permit);
    current = NULL;
    lock_t *locks[] = {&reader->tty.lock, &reader->files.lock, &reader->guest.waiting_cond_lock,
                      &reader->handlers.lock, &reader->group.lock};
    for (unsigned i = 0; i < sizeof(locks) / sizeof(locks[0]); i++)
        assert(pthread_mutex_destroy(&locks[i]->m) == 0);
    assert(pthread_rwlock_destroy(&reader->mm.mem.lock.l) == 0);
    cond_destroy(&reader->tty.produced);
    cond_destroy(&reader->tty.consumed);
}
static void *run_read(void *argument) {
    struct reader *reader = argument;
    current = &reader->guest;
    uint64_t permit = dsh_lifecycle_operation_begin("guest_syscall_63", reader->guest.pid);
    uint64_t nested = 0, connection = 0;
    int host_fd = -1;
    if (reader->critical == NESTED_SCOPE)
        nested = dsh_lifecycle_operation_begin("nested", reader->guest.pid);
    if (reader->critical == CRITICAL_SQLITE_TRANSACTION || reader->critical == CRITICAL_SQLITE_RECOVERY) {
        connection = dsh_lifecycle_sqlite_open(reader->guest.pid);
        if (reader->critical == CRITICAL_SQLITE_TRANSACTION)
            dsh_lifecycle_sqlite_update(connection, reader->guest.pid, 0, 2, 0, "begin");
        else dsh_lifecycle_sqlite_recovery_required(connection, 10);
    }
    if (reader->critical == NATIVE_FLOCK) {
        // A real host flock plus its production observation must remain counted.
        FILE *file = tmpfile(); assert(file);
        host_fd = dup(fileno(file)); assert(host_fd >= 0);
        fclose(file);
        assert(flock(host_fd, LOCK_EX) == 0);
        dsh_lifecycle_native_flock_update(reader, host_fd, reader->guest.pid, DSH_LIFECYCLE_FLOCK_EXCLUSIVE);
    }
    atomic_store(&reader->started, true);
    if (reader->kind == READ_SINGLE) {
        struct cpu_state cpu = {};
        cpu.regs[0] = 0;
        cpu.regs[1] = (uintptr_t)reader->output;
        cpu.regs[2] = 4;
        assert(fast_read(&cpu) == -1);
        assert(atomic_load(&reader->files.files[0]->refcount) == 1);
        reader->result = (int_t)sys_read(0, (addr_t)(uintptr_t)reader->output, 4);
    } else {
        struct iovec64_ vector[2] = {
            {.base = (uintptr_t)reader->output, .len = 2},
            {.base = (uintptr_t)(reader->output + 2), .len = 2},
        };
        reader->result = (int_t)(reader->kind == READ_VECTOR
            ? sys_readv(0, (addr_t)(uintptr_t)vector, 2)
            : sys_preadv2(0, (addr_t)(uintptr_t)vector, 2, UINT32_MAX, UINT32_MAX, 0));
    }
    assert(dsh_lifecycle_operation_depth() == (nested ? 2U : 1U));
    if (connection) {
        dsh_lifecycle_sqlite_update(connection, reader->guest.pid, 1, 0, 0, "commit");
        dsh_lifecycle_sqlite_recovery_resolved(connection);
        dsh_lifecycle_sqlite_close(connection, 0);
    }
    if (host_fd >= 0) {
        assert(flock(host_fd, LOCK_UN) == 0);
        dsh_lifecycle_native_flock_close(reader);
        assert(close(host_fd) == 0);
    }
    if (nested) dsh_lifecycle_operation_end(nested);
    // This is the ORIGINAL dispatcher token, proving pause/resume does not leak
    // a replacement permit after the lexical outer cleanup runs.
    dsh_lifecycle_operation_end(permit);
    atomic_store(&reader->returned, true);
    dsh_lifecycle_thread_exit();
    return NULL;
}
static void start(struct reader *reader) {
    assert(pthread_create(&reader->thread, NULL, run_read, reader) == 0);
    await_bool(&reader->started);
    await_waiting(reader, true);
}
static void join_reader(struct reader *reader) {
    await_bool(&reader->returned);
    assert(pthread_join(reader->thread, NULL) == 0);
}

static void six_readers(void) {
    struct reader readers[6];
    unsigned writes = atomic_load(&copyouts), closes = atomic_load(&final_closes);
    for (unsigned i = 0; i < 6; i++) {
        reader_init(&readers[i], 5 + i);
        readers[i].kind = (enum read_kind)(i % 3);
        start(&readers[i]);
    }
    struct dsh_lifecycle_snapshot state = snapshot();
    assert(state.active_operations == 0 && state.paused_fileless_operations == 6 && state.operation_count == 0);
    for (unsigned cycle = 0; cycle < 10; cycle++) {
        uint64_t generation = dsh_lifecycle_request_quiesce();
        assert(dsh_lifecycle_mark_quiescent(generation));
        for (unsigned i = 0; i < 6; i++) assert_no_guest_locks(&readers[i]);
        assert(snapshot().paused_fileless_operations == 6);
        dsh_lifecycle_resume();
    }
    uint64_t generation = dsh_lifecycle_request_quiesce();
    assert(dsh_lifecycle_mark_quiescent(generation));
    for (unsigned i = 0; i < 6; i++) feed(&readers[i], "abc\n");
    for (unsigned i = 0; i < 6; i++) await_waiting(&readers[i], false);
    delay_ms(30);
    for (unsigned i = 0; i < 6; i++) {
        assert(!atomic_load(&readers[i].returned));
        assert_no_guest_locks(&readers[i]);
    }
    assert(snapshot().active_operations == 0 && snapshot().paused_fileless_operations == 6);
    state = snapshot();
    assert(state.gate_waiters == 6 && state.gate_wait_count == 6);
    for (unsigned i = 0; i < state.gate_wait_count; i++)
        assert(state.gate_waits[i].reason == DSH_GATE_WAIT_TTY_RESUME &&
            state.gate_waits[i].owner.guest_pid >= 5 && state.gate_waits[i].owner.guest_pid <= 10);
    assert(atomic_load(&copyouts) == writes && atomic_load(&final_closes) == closes);
    dsh_lifecycle_begin_resume();
    delay_ms(30);
    assert(atomic_load(&copyouts) == writes);
    dsh_lifecycle_resume();
    for (unsigned i = 0; i < 6; i++) {
        join_reader(&readers[i]);
        assert(readers[i].result == 4 && memcmp(readers[i].output, "abc\n", 4) == 0);
        reader_destroy(&readers[i]);
    }
    assert(snapshot().active_operations == 0 && snapshot().paused_fileless_operations == 0);
    puts("PASS six production TTY read/readv/stream-preadv2 readers drain across 10 cycles; copyout waits without guest locks through resume");
}
struct retaining_reader { struct reader *reader; atomic_bool started, stop; unsigned retained; };
static void *retain_during_dup(void *argument) {
    struct retaining_reader *worker = argument;
    current = &worker->reader->guest;
    uint64_t permit = dsh_lifecycle_operation_begin("concurrent_retained_lookup", current->pid);
    atomic_store(&worker->started, true);
    do {
        struct fd *fd = f_get_retained(0);
        assert(fd && (fd->ops == &tty_dev.fd || fd->ops == &file_ops));
        assert(fd_close(fd) == 0);
        worker->retained++;
    } while (!atomic_load(&worker->stop));
    dsh_lifecycle_operation_end(permit);
    dsh_lifecycle_thread_exit();
    return NULL;
}
static void reused_fd(void) {
    struct reader reader;
    reader_init(&reader, 70);
    start(&reader);
    struct fd *original = reader.files.files[0];
    assert(atomic_load(&original->refcount) == 2);
    unsigned closes = atomic_load(&final_closes), reads = atomic_load(&file_reads), writes = atomic_load(&copyouts);
    current = &reader.guest;
    uint64_t permit = dsh_lifecycle_operation_begin("production_duplication", reader.guest.pid);
    lock(&reader.files.lock);
    reader.files.files[1] = fd_create(&file_ops);
    assert(reader.files.files[1]); reader.files.files[1]->type = S_IFREG;
    unlock(&reader.files.lock);
    struct fd *source = reader.files.files[1];
    assert((int_t)sys_dup3(1, -1, 0) == _EBADF);
    assert((int_t)sys_dup3(1, INT32_MAX, 0) == _EMFILE);
    assert((int_t)sys_dup3(-1, 0, 0) == _EBADF);
    assert((int_t)sys_fcntl(1, F_DUPFD_, (addr_t)-1) == _EINVAL);
    assert((int_t)sys_fcntl(-1, F_DUPFD_CLOEXEC_, 0) == _EBADF);
    assert(atomic_load(&source->refcount) == 1);
    // Preserve the existing dup2-through-dup3 same-fd behavior while retaining
    // source before target close. Invalid dup3 flags are outside this fix.
    assert((int_t)sys_dup3(1, 1, O_CLOEXEC_) == 1);
    assert(atomic_load(&source->refcount) == 1);
    struct retaining_reader retaining = {.reader = &reader};
    pthread_t lookup;
    assert(pthread_create(&lookup, NULL, retain_during_dup, &retaining) == 0);
    await_bool(&retaining.started);
    for (unsigned i = 0; i < 1000; i++) {
        int target = 2 + i % 254;
        assert((int_t)sys_dup3(1, target, O_CLOEXEC_) == target);
        lock(&reader.files.lock);
        assert(reader.files.files[target] == source && bit_test(target, reader.files.cloexec));
        unlock(&reader.files.lock);
        assert((int_t)sys_dup3(1, 0, i % 2 ? O_CLOEXEC_ : 0) == 0);
        int command = i % 2 ? F_DUPFD_CLOEXEC_ : F_DUPFD_;
        int duplicate = (int_t)sys_fcntl(1, command, 3);
        assert(duplicate >= 3);
        lock(&reader.files.lock);
        assert(reader.files.files[duplicate] == source);
        assert(bit_test(duplicate, reader.files.cloexec) == (i % 2 != 0));
        unlock(&reader.files.lock);
        assert(f_close(duplicate) == 0);
        duplicate = (int_t)sys_dup(1);
        assert(duplicate >= 0 && duplicate != 1);
        assert(f_close(duplicate) == 0);
        if (i % 8 == 0) sched_yield();
    }
    atomic_store(&retaining.stop, true);
    assert(pthread_join(lookup, NULL) == 0 && retaining.retained > 0);
    dsh_lifecycle_operation_end(permit);
    assert(atomic_load(&original->refcount) == 1);
    uint64_t generation = dsh_lifecycle_request_quiesce();
    assert(dsh_lifecycle_mark_quiescent(generation));
    feed(&reader, "old\n");
    await_waiting(&reader, false); delay_ms(30);
    assert_no_guest_locks(&reader);
    assert(atomic_load(&final_closes) == closes && atomic_load(&copyouts) == writes);
    dsh_lifecycle_resume();
    join_reader(&reader);
    assert(reader.result == 4 && memcmp(reader.output, "old\n", 4) == 0);
    assert(atomic_load(&file_reads) == reads && atomic_load(&final_closes) == closes + 1);
    reader_destroy(&reader);
    assert(snapshot().active_operations == 0 && snapshot().paused_fileless_operations == 0);
    puts("PASS production dup3/F_DUPFD slot reuse and 1000 concurrent expansion/retention iterations preserve original TTY and admitted final close");
}
static void conservative_reads(void) {
    for (enum critical_kind critical = NESTED_SCOPE; critical <= NATIVE_FLOCK; critical++) {
        struct reader reader;
        reader_init(&reader, 80 + critical);
        reader.critical = critical;
        start(&reader);
        assert(snapshot().active_operations == (critical == NESTED_SCOPE ? 2U : 1U));
        assert(snapshot().paused_fileless_operations == 0);
        struct dsh_lifecycle_snapshot observed = snapshot();
        unsigned innermost = observed.operation_count - 1;
        assert(observed.operations[innermost].read_fd_observed &&
            observed.operations[innermost].read_guest_fd == 0 &&
            observed.operations[innermost].read_fd_kind == DSH_READ_FD_TTY);
        uint64_t generation = dsh_lifecycle_request_quiesce();
        assert(!dsh_lifecycle_mark_quiescent(generation));
        feed(&reader, "safe");
        join_reader(&reader);
        assert(reader.result == 4);
        assert(dsh_lifecycle_mark_quiescent(generation));
        dsh_lifecycle_resume();
        reader_destroy(&reader);
    }
    struct reader reader;
    reader_init(&reader, 90);
    current = &reader.guest;
    uint64_t permit = dsh_lifecycle_operation_begin("file_read", reader.guest.pid);
    fd_close(reader.files.files[0]);
    reader.files.files[0] = fd_create(&file_ops); assert(reader.files.files[0]);
    const mode_t_ types[] = {S_IFREG, S_IFIFO, S_IFSOCK, S_IFCHR, S_IFBLK, 0};
    for (unsigned i = 0; i < sizeof(types) / sizeof(types[0]); i++) {
        reader.files.files[0]->type = types[i];
        assert((int_t)sys_read(0, (addr_t)(uintptr_t)reader.output, 4) == 1 && reader.output[0] == 'F');
        struct dsh_lifecycle_operation_snapshot observed = snapshot().operations[0];
        assert(!observed.read_fd_observed && observed.read_guest_fd == -1);
    }
    assert((int_t)sys_read(1, (addr_t)(uintptr_t)reader.output, 4) == _EBADF);
    reader.files.files[0]->type = S_IFDIR;
    assert((int_t)sys_read(0, (addr_t)(uintptr_t)reader.output, 4) == _EISDIR);
    assert(atomic_load(&reader.files.files[0]->refcount) == 1);
    dsh_lifecycle_operation_end(permit);
    reader_destroy(&reader);
    assert(snapshot().active_operations == 0 && snapshot().paused_fileless_operations == 0);
    puts("PASS nested/SQLite-active/recovery/native-flock TTY readers retain permits; ordinary files and fd errors never pause");
}
static void signal_and_nonblocking(void) {
    struct reader reader;
    reader_init(&reader, 100);
    start(&reader);
    uint64_t generation = dsh_lifecycle_request_quiesce();
    assert(dsh_lifecycle_mark_quiescent(generation));
    lock(&reader.tty.lock);
    lock(&reader.handlers.lock);
    reader.guest.pending |= sig_mask(SIGUSR1_);
    unlock(&reader.handlers.lock);
    notify(&reader.tty.produced);
    unlock(&reader.tty.lock);
    await_waiting(&reader, false); delay_ms(30);
    assert(!atomic_load(&reader.returned)); assert_no_guest_locks(&reader);
    dsh_lifecycle_resume();
    join_reader(&reader);
    assert(reader.result == _EINTR);
    reader_destroy(&reader);
    reader_init(&reader, 101); current = &reader.guest;
    uint64_t permit = dsh_lifecycle_operation_begin("tty_nonblocking", reader.guest.pid);
    reader.files.files[0]->flags = O_NONBLOCK_;
    assert((int_t)sys_read(0, (addr_t)(uintptr_t)reader.output, 4) == _EAGAIN);
    assert((int_t)sys_read(0, (addr_t)(uintptr_t)reader.output, 0) == 0);
    assert(dsh_lifecycle_operation_depth() == 1 && snapshot().active_operations == 1 && snapshot().paused_fileless_operations == 0);
    dsh_lifecycle_operation_end(permit); reader_destroy(&reader);
    assert(dsh_lifecycle_pause_tty_read() == 0);
    puts("PASS production TTY signal/nonblocking/zero-length semantics preserve original permit and error behavior");
}
static void paused_exit_cleanup(void *argument) {
    (void)argument;
    dsh_lifecycle_thread_exit();
    assert(dsh_lifecycle_operation_depth() == 0);
}
static void *retire_paused_thread(void *argument) {
    (void)argument;
    pthread_cleanup_push(paused_exit_cleanup, NULL);
    uint64_t permit = dsh_lifecycle_operation_begin("paused_thread_retirement", 111);
    assert(dsh_lifecycle_pause_tty_read() == permit);
    assert(snapshot().active_operations == 0 && snapshot().paused_fileless_operations == 1);
    pthread_exit(NULL);
    pthread_cleanup_pop(1);
    return NULL;
}
static void paused_thread_cleanup(void) {
    pthread_t worker;
    assert(pthread_create(&worker, NULL, retire_paused_thread, NULL) == 0);
    assert(pthread_join(worker, NULL) == 0);
    assert(snapshot().active_operations == 0 && snapshot().paused_fileless_operations == 0);
    // Retire an already-paused token without subtracting another worker's live
    // operation; lexical cleanup normally follows resume, but must be robust.
    uint64_t outer = dsh_lifecycle_operation_begin("paused_scope_retirement", 112);
    assert(dsh_lifecycle_pause_tty_read() == outer);
    uint64_t other = dsh_lifecycle_operation_begin("separate_live_scope", 112);
    dsh_lifecycle_operation_end(outer);
    assert(snapshot().active_operations == 1 && snapshot().paused_fileless_operations == 0);
    dsh_lifecycle_operation_end(other);
    puts("PASS real pthread exit and paused-token retirement clear only paused accounting, preserving another live scope");
}
static void fast_read_balance(void) {
    struct reader reader;
    reader_init(&reader, 120);
    current = &reader.guest;
    uint64_t permit = dsh_lifecycle_operation_begin("production_fast_read", current->pid);
    struct cpu_state cpu = {};
    cpu.regs[0] = 0; cpu.regs[1] = (uintptr_t)reader.output; cpu.regs[2] = 4;
    assert(fast_read(&cpu) == -1);
    assert(atomic_load(&reader.files.files[0]->refcount) == 1);
    assert(fd_close(reader.files.files[0]) == 0);
    reader.files.files[0] = fd_create(&realfs_fdops); assert(reader.files.files[0]);
    FILE *file = tmpfile(); assert(file);
    assert(fwrite("host", 1, 4, file) == 4 && fflush(file) == 0);
    assert(fseek(file, 0, SEEK_SET) == 0);
    reader.files.files[0]->real_fd = fileno(file);
    assert(fast_read(&cpu) == 4 && memcmp(reader.output, "host", 4) == 0);
    assert(atomic_load(&reader.files.files[0]->refcount) == 1);
    reader.files.files[0]->real_fd = -1;
    assert(fast_read(&cpu) == _EBADF);
    assert(atomic_load(&reader.files.files[0]->refcount) == 1);
    cpu.regs[2] = 4097;
    assert(fast_read(&cpu) == -1 && atomic_load(&reader.files.files[0]->refcount) == 1);
    assert(fclose(file) == 0);
    dsh_lifecycle_operation_end(permit);
    reader_destroy(&reader);
    puts("PASS production fast_read TTY fallback/real-host read/error/large-buffer paths balance retained fd references");
}
int main(void) {
    alarm(30);
    lock_init(&pids_lock);
    dsh_lifecycle_enable_admission_gate();
    six_readers(); reused_fd(); conservative_reads(); signal_and_nonblocking(); paused_thread_cleanup(); fast_read_balance();
    struct dsh_lifecycle_snapshot state = snapshot();
    assert(state.active_operations == 0 && state.paused_fileless_operations == 0 && state.open_connections == 0 &&
           state.active_native_flocks == 0 && state.recovery_blocked_connections == 0 && state.tracking_overflows == 0);
    assert(pthread_mutex_destroy(&pids_lock.m) == 0);
    return 0;
}
