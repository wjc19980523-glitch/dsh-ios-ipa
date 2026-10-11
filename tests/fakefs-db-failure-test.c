/* Actual SQLite and actual fakefs entry points; all data is disposable. */
#include <assert.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include <stdatomic.h>
#include <time.h>
#include "fs/fake.c"
#include "sqlite-fault-vfs.h"

__thread struct task *current;
int errno_map(void) { return -errno; }
void ish_printk(const char *format, ...) { (void) format; }
_Noreturn void die(const char *format, ...) { (void) format; abort(); }
struct fd *fd_create(const struct fd_ops *ops) {
    struct fd *fd = calloc(1, sizeof(*fd));
    if (fd) { fd->ops = ops; fd->refcount = 1; }
    return fd;
}
int fd_close(struct fd *fd) { int rc = close(fd->real_fd); free(fd); return rc; }
int realfs_getpath(struct fd *fd, char *path) { (void) fd; path[0] = 0; return 0; }
static int no_entries(struct fd *fd, struct dir_entry *entry) { (void) fd; (void) entry; return 0; }
static int host_unlink(struct mount *mount, const char *path) {
    return unlinkat(mount->root_fd, fix_path(path), 0) < 0 ? -errno : 0;
}
const struct fd_ops realfs_fdops = { .readdir = no_entries };
const struct fs_ops realfs = { .unlink = host_unlink };
int realfs_statfs(struct mount *mount, struct statfsbuf *stat) { (void) mount; (void) stat; return _ENOSYS; }
int realfs_close(struct fd *fd) { return close(fd->real_fd) < 0 ? -errno : 0; }
int realfs_utime(struct mount *mount, const char *path, struct timespec a, struct timespec m) {
    (void) mount; (void) path; (void) a; (void) m; return _ENOSYS;
}
int realfs_flock(struct fd *fd, int op) { return flock(fd->real_fd, op) < 0 ? -errno : 0; }
void inode_check_orphaned(struct mount *mount, ino_t inode) { (void) mount; (void) inode; }

static atomic_bool fail_mknod_close;
static int last_mknod_close_fd = -1;
static int injected_mknod_close(int host_fd) {
    // The real descriptor is closed even when the error is injected. This
    // models close reporting an I/O error without leaking a host fd in tests.
    last_mknod_close_fd = host_fd;
    int result = close(host_fd);
    if (atomic_exchange(&fail_mknod_close, false)) {
        assert(result == 0);
        errno = EIO;
        return -1;
    }
    return result;
}
void lock_fchdir(int root) { (void) root; assert(false); }
void unlock_fchdir(void) { assert(false); }
#define close injected_mknod_close
#include "production-mknod.h"
#undef close

static uint64_t now_ns(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t) ts.tv_sec * 1000000000 + ts.tv_nsec;
}
static void pause_ms(unsigned ms) {
    struct timespec ts = {.tv_sec = ms / 1000, .tv_nsec = (ms % 1000) * 1000000};
    nanosleep(&ts, NULL);
}
static void sql(sqlite3 *db, const char *text) { assert(sqlite3_exec(db, text, NULL, NULL, NULL) == SQLITE_OK); }
static int deny_action;
static bool deny_rollback;
static unsigned rollback_denials;
static int authorize(void *context, int action, const char *a, const char *b, const char *c, const char *d) {
    (void) context; (void) b; (void) c; (void) d;
    if (deny_action == SQLITE_READ && action == SQLITE_READ && a && strcmp(a, "paths") == 0) return SQLITE_DENY;
    if (deny_action == SQLITE_TRANSACTION && action == SQLITE_TRANSACTION && a && strcmp(a, "COMMIT") == 0) return SQLITE_DENY;
    if (deny_rollback && action == SQLITE_TRANSACTION && a && strcmp(a, "ROLLBACK") == 0) {
        rollback_denials++;
        return SQLITE_DENY;
    }
    return SQLITE_OK;
}
struct worker { struct fakefs_db *fs; atomic_bool ready; int result; uint64_t elapsed; };
static void *hold_mutex(void *context) {
    struct worker *worker = context;
    sqlite3_mutex_enter(worker->fs->lock);
    atomic_store(&worker->ready, true);
    pause_ms(35);
    sqlite3_mutex_leave(worker->fs->lock);
    return NULL;
}
static void *try_begin(void *context) {
    struct worker *worker = context;
    uint64_t start = now_ns();
    worker->result = db_begin_write(worker->fs);
    worker->elapsed = now_ns() - start;
    return NULL;
}
static void *external_failure(void *context) {
    db_require_external_recovery(context, SQLITE_IOERR);
    return NULL;
}
static void begin_fast_failure(struct fakefs_db *fs) {
    struct worker worker = {.fs = fs}; pthread_t thread;
    assert(pthread_create(&thread, NULL, try_begin, &worker) == 0);
    assert(pthread_join(thread, NULL) == 0);
    assert(worker.result == SQLITE_IOERR);
    assert(worker.elapsed < 50000000);
}
static void fixture(struct fakefs_db *fs, const char *path) {
    sqlite3 *db = NULL; assert(sqlite3_open(path, &db) == SQLITE_OK);
    sql(db, "create table meta (db_inode integer); insert into meta values (0);"
        "create table stats (inode integer primary key, stat blob);"
        "create table paths (path blob primary key, inode integer references stats(inode));"
        "pragma user_version=3;");
    struct stat st; assert(stat(path, &st) == 0);
    sqlite3_stmt *save = NULL;
    assert(sqlite3_prepare_v2(db, "update meta set db_inode=?", -1, &save, NULL) == SQLITE_OK);
    assert(sqlite3_bind_int64(save, 1, st.st_ino) == SQLITE_OK);
    assert(sqlite3_step(save) == SQLITE_DONE); assert(sqlite3_finalize(save) == SQLITE_OK);
    assert(sqlite3_close(db) == SQLITE_OK);
    assert(fake_db_init(fs, path, -1) == 0);
}
static void host_contents(int root, const char *name, const char *expected) {
    char data[100] = {0}; int fd = openat(root, name, O_RDONLY);
    assert(fd >= 0); ssize_t count = read(fd, data, sizeof(data) - 1); assert(count >= 0);
    assert(close(fd) == 0); assert(strcmp(data, expected) == 0);
}
static void committed_stat(sqlite3 *observer, const char *path, inode_t inode, const struct ish_stat *expected) {
    sqlite3_stmt *query = NULL;
    assert(sqlite3_prepare_v2(observer, "select inode,stat from paths natural join stats where path=?", -1, &query, NULL) == SQLITE_OK);
    assert(sqlite3_bind_blob(query, 1, path, strlen(path), SQLITE_TRANSIENT) == SQLITE_OK);
    assert(sqlite3_step(query) == SQLITE_ROW && (inode_t) sqlite3_column_int64(query, 0) == inode);
    assert(sqlite3_column_bytes(query, 1) == sizeof(*expected));
    assert(memcmp(sqlite3_column_blob(query, 1), expected, sizeof(*expected)) == 0);
    assert(sqlite3_step(query) == SQLITE_DONE && sqlite3_finalize(query) == SQLITE_OK);
}
int main(int argc, char **argv) {
    assert(argc == 3);
    fault_vfs_install();
    struct mount mount = {0}; fixture(&mount.fakefs, argv[1]);
    mount.root_fd = open(argv[2], O_RDONLY | O_DIRECTORY); assert(mount.root_fd >= 0);
    struct fakefs_db *fs = &mount.fakefs;
    struct fd *fd = fakefs_open(&mount, "/existing", O_CREAT_ | O_RDWR_, 0644);
    assert(!IS_ERR(fd)); assert(write(fd->real_fd, "preserved", 9) == 9); assert(fd_close(fd) == 0);

    /* BEGIN has one total budget including contention on the serialization mutex. */
    sqlite3 *other = NULL; assert(sqlite3_open(argv[1], &other) == SQLITE_OK);
    sql(other, "begin immediate");
    struct worker worker = {.fs = fs}; pthread_t thread;
    assert(pthread_create(&thread, NULL, hold_mutex, &worker) == 0);
    while (!atomic_load(&worker.ready)) pause_ms(1);
    uint64_t start = now_ns();
    fd = fakefs_open(&mount, "/must-not-create", O_CREAT_ | O_RDWR_, 0644);
    uint64_t elapsed = now_ns() - start;
    if (!IS_ERR(fd) || PTR_ERR(fd) != _EBUSY || elapsed < 60000000 || elapsed >= 250000000)
        fprintf(stderr, "combined BEGIN contention: open_error=%d elapsed_ns=%llu\n",
                IS_ERR(fd) ? (int) PTR_ERR(fd) : 0, (unsigned long long) elapsed);
    assert(IS_ERR(fd) && PTR_ERR(fd) == _EBUSY);
    assert(elapsed >= 60000000 && elapsed < 250000000);
    assert(pthread_join(thread, NULL) == 0);
    assert(faccessat(mount.root_fd, "must-not-create", F_OK, 0) < 0 && errno == ENOENT);

    /* Scheduling can spend the entire first budget waiting for the mutex. That
     * caller must not overwrite an owner's transaction_error. After join, only
     * SQLite is contended, so its explicit return code identifies this timeout. */
    start = now_ns();
    int begin_rc = db_begin_write(fs);
    elapsed = now_ns() - start;
    int autocommit = sqlite3_get_autocommit(fs->db);
    if (begin_rc != SQLITE_BUSY_TIMEOUT || elapsed < 60000000 || elapsed >= 250000000 ||
            !autocommit || fs->transaction_owned)
        fprintf(stderr, "SQLite BEGIN contention: rc=%d elapsed_ns=%llu autocommit=%d owned=%d\n",
                begin_rc, (unsigned long long) elapsed, autocommit, fs->transaction_owned);
    assert(begin_rc == SQLITE_BUSY_TIMEOUT);
    assert(elapsed >= 60000000 && elapsed < 250000000);
    assert(autocommit && !fs->transaction_owned);
    fd = fakefs_open(&mount, "/existing", O_RDWR_ | O_TRUNC_, 0644);
    assert(IS_ERR(fd) && PTR_ERR(fd) == _EBUSY); host_contents(mount.root_fd, "existing", "preserved");
    sql(other, "rollback"); assert(sqlite3_close(other) == SQLITE_OK);
    puts("PASS bounded BEGIN mutex+SQLite contention; no create/truncate on failure");

    /* Real SQLite authorization failure occurs in metadata before host effects. */
    deny_action = SQLITE_READ; assert(sqlite3_set_authorizer(fs->db, authorize, NULL) == SQLITE_OK);
    fd = fakefs_open(&mount, "/existing", O_RDWR_ | O_TRUNC_, 0644);
    assert(IS_ERR(fd) && PTR_ERR(fd) == _EIO); host_contents(mount.root_fd, "existing", "preserved");
    assert(!fakefs_db_recovery_required(fs) && sqlite3_get_autocommit(fs->db));
    assert(fakefs_unlink(&mount, "/existing") == _EIO); host_contents(mount.root_fd, "existing", "preserved");
    deny_action = 0; assert(sqlite3_set_authorizer(fs->db, NULL, NULL) == SQLITE_OK);
    puts("PASS metadata error propagation before host truncate/unlink");

    /* A pending UPDATE RETURNING makes COMMIT genuinely BUSY even in WAL mode. */
    assert(db_begin_write(fs) == SQLITE_OK);
    sqlite3_stmt *pending = NULL;
    assert(sqlite3_prepare_v2(fs->db, "update stats set stat=stat returning inode", -1, &pending, NULL) == SQLITE_OK);
    assert(db_exec(fs, pending) == SQLITE_ROW);
    start = now_ns(); assert(db_commit(fs) == SQLITE_BUSY_TIMEOUT); elapsed = now_ns() - start;
    assert(elapsed < 250000000 && !sqlite3_get_autocommit(fs->db));
    assert(sqlite3_mutex_try(fs->lock) == SQLITE_BUSY && fakefs_db_recovery_required(fs));
    struct dsh_lifecycle_snapshot snap; dsh_lifecycle_get_snapshot(&snap);
    assert(snap.active_write_transactions == 1 && snap.recovery_blocked_connections == 1);
    begin_fast_failure(fs);
    assert(db_reset(fs, pending) == SQLITE_OK); assert(sqlite3_finalize(pending) == SQLITE_OK);
    assert(db_commit(fs) == SQLITE_OK); assert(!fakefs_db_recovery_required(fs));
    dsh_lifecycle_get_snapshot(&snap); assert(snap.recovery_blocked_connections == 0);
    puts("PASS failed active COMMIT retains owner/mutex; other worker fails immediately");

    /* Reject the actual ROLLBACK statement, rather than merely preserving an
     * external sticky marker after SQLite already ended its transaction. Only
     * metadata changes here, so explicit rollback is safe after fault removal. */
    sqlite3 *rollback_observer = NULL;
    assert(sqlite3_open_v2(argv[1], &rollback_observer, SQLITE_OPEN_READONLY, NULL) == SQLITE_OK);
    assert(db_begin_write(fs) == SQLITE_OK);
    struct ish_stat original_stat;
    inode_t rollback_inode;
    assert(path_read_stat(fs, "/existing", &original_stat, &rollback_inode));
    struct ish_stat temporary_stat = original_stat;
    temporary_stat.uid ^= 1;
    inode_write_stat(fs, rollback_inode, &temporary_stat);
    assert(db_transaction_error(fs) == SQLITE_OK);
    committed_stat(rollback_observer, "/existing", rollback_inode, &original_stat);
    deny_rollback = true;
    assert(sqlite3_set_authorizer(fs->db, authorize, NULL) == SQLITE_OK);
    assert(db_rollback(fs) == SQLITE_AUTH && rollback_denials == 1);
    assert(!sqlite3_get_autocommit(fs->db) && fs->transaction_owned &&
            pthread_equal(fs->transaction_owner, pthread_self()));
    assert(sqlite3_mutex_try(fs->lock) == SQLITE_BUSY && db_blocked_error(fs) == SQLITE_AUTH);
    dsh_lifecycle_get_snapshot(&snap);
    assert(snap.active_write_transactions == 1 && snap.recovery_blocked_connections == 1 &&
            snap.transaction_count == 1 && snap.transactions[0].cached_autocommit == 0 &&
            snap.transactions[0].cached_result == SQLITE_AUTH && snap.transactions[0].recovery_required);
    uint64_t rollback_generation = dsh_lifecycle_request_quiesce();
    assert(!dsh_lifecycle_mark_quiescent(rollback_generation));
    begin_fast_failure(fs);
    committed_stat(rollback_observer, "/existing", rollback_inode, &original_stat);
    host_contents(mount.root_fd, "existing", "preserved");
    deny_rollback = false;
    assert(sqlite3_set_authorizer(fs->db, NULL, NULL) == SQLITE_OK);
    assert(db_rollback(fs) == SQLITE_OK && sqlite3_get_autocommit(fs->db) &&
            !fs->transaction_owned && !fakefs_db_recovery_required(fs));
    assert(sqlite3_mutex_try(fs->lock) == SQLITE_OK); sqlite3_mutex_leave(fs->lock);
    committed_stat(rollback_observer, "/existing", rollback_inode, &original_stat);
    assert(sqlite3_close(rollback_observer) == SQLITE_OK);
    dsh_lifecycle_get_snapshot(&snap);
    assert(snap.recovery_blocked_connections == 0 && snap.transaction_count == 0);
    assert(dsh_lifecycle_mark_quiescent(rollback_generation));
    dsh_lifecycle_resume();
    host_contents(mount.root_fd, "existing", "preserved");
    puts("PASS real ROLLBACK AUTH retains transaction/owner/mutex and blocks new DB work/quiescence; explicit safe rollback recovers");

    sql(fs->db, "create table locked_fixture (value integer); insert into locked_fixture values (1)");
    assert(db_begin_read(fs) == SQLITE_OK);
    assert(sqlite3_prepare_v2(fs->db, "select value from locked_fixture", -1, &pending, NULL) == SQLITE_OK);
    assert(db_exec(fs, pending) == SQLITE_ROW);
    start = now_ns();
    int locked_rc = db_exec_sql(fs, "drop table locked_fixture");
    assert((locked_rc & 0xff) == SQLITE_LOCKED);
    assert(now_ns() - start < 50000000);
    assert(db_reset(fs, pending) == SQLITE_OK); assert(sqlite3_finalize(pending) == SQLITE_OK);
    assert(db_rollback(fs) == SQLITE_OK);
    puts("PASS real SQLITE_LOCKED returns immediately without BUSY retry loops");

    assert(db_begin_read(fs) == SQLITE_OK);
    inode_t existing_inode = path_get_inode(fs, "/existing");
    assert(db_commit(fs) == SQLITE_OK && existing_inode != 0);
    sql(fs->db, "update stats set stat=x'00'");
    struct statbuf bad_stat;
    assert(fakefs_stat(&mount, "/existing", &bad_stat) == _EIO);
    assert(!fakefs_db_recovery_required(fs));
    assert(db_begin_write(fs) == SQLITE_OK);
    struct ish_stat restored = {.mode = S_IFREG | 0644};
    inode_write_stat(fs, existing_inode, &restored);
    assert(db_commit(fs) == SQLITE_OK);
    puts("PASS malformed metadata is an explicit CORRUPT error, with no host mutation");

    assert(mkdirat(mount.root_fd, "mount-target", 0700) == 0);
    int marker = openat(mount.root_fd, "mount-target/marker", O_CREAT | O_EXCL | O_WRONLY, 0600);
    assert(marker >= 0 && write(marker, "keep", 4) == 4 && close(marker) == 0);
    assert(db_begin_write(fs) == SQLITE_OK);
    struct ish_stat directory = {.mode = S_IFDIR | 0755};
    inode_t dangling = path_create(fs, "/mount-target", &directory);
    assert(dangling && db_commit(fs) == SQLITE_OK);
    char *corrupt = sqlite3_mprintf("pragma foreign_keys=off; delete from stats where inode=%lld; pragma foreign_keys=on", (long long) dangling);
    assert(corrupt); sql(fs->db, corrupt); sqlite3_free(corrupt);
    g_fakefs_mount = &mount;
    assert(fakefs_bind_mount("/mount-target", argv[2], false) == _EIO);
    assert(!fakefs_db_recovery_required(fs));
    host_contents(mount.root_fd, "mount-target/marker", "keep");
    g_fakefs_mount = NULL;
    assert(unlinkat(mount.root_fd, "mount-target/marker", 0) == 0);
    assert(unlinkat(mount.root_fd, "mount-target", AT_REMOVEDIR) == 0);
    puts("PASS dangling bind metadata fails before replacing an existing host directory");

    /* Reject COMMIT after a real host unlink: production must retain recovery,
     * not roll metadata back and falsely report the host file as present. */
    deny_action = SQLITE_TRANSACTION; assert(sqlite3_set_authorizer(fs->db, authorize, NULL) == SQLITE_OK);
    assert(fakefs_unlink(&mount, "/existing") == _EIO);
    assert(faccessat(mount.root_fd, "existing", F_OK, 0) < 0 && errno == ENOENT);
    assert(fakefs_db_recovery_required(fs) && !sqlite3_get_autocommit(fs->db));
    assert(path_get_inode(fs, "/existing") == 0);
    assert(fake_db_deinit(fs) != SQLITE_OK); begin_fast_failure(fs);
    deny_action = 0; assert(sqlite3_set_authorizer(fs->db, NULL, NULL) == SQLITE_OK);
    /* This disposable fixture explicitly completes its known host+metadata
     * operation. Runtime code does not automatically repair blocked state. */
    assert(db_commit(fs) == SQLITE_OK);
    puts("PASS post-host COMMIT error remains blocked without false rollback/close");

    assert(db_begin_write(fs) == SQLITE_OK);
    assert(db_exec_sql(fs, "create table fill (data blob)") == SQLITE_OK);
    assert(db_commit(fs) == SQLITE_OK);
    sql(fs->db, "pragma max_page_count=1");
    assert(db_begin_write(fs) == SQLITE_OK);
    assert((db_exec_sql(fs, "insert into fill values (zeroblob(1048576))") & 0xff) == SQLITE_FULL);
    assert(db_transaction_error(fs) == SQLITE_FULL);
    assert(db_rollback(fs) == SQLITE_OK); assert(!fakefs_db_recovery_required(fs));
    assert(db_begin_read(fs) == SQLITE_OK); assert(db_commit(fs) == SQLITE_OK);
    puts("PASS real SQLITE_FULL propagates and pure metadata rollback safely releases locks");

    fd = fakefs_open(&mount, "/ioerr-target", O_CREAT_ | O_RDWR_, 0644);
    assert(!IS_ERR(fd)); assert(fd_close(fd) == 0);
    atomic_store(&fault_next_write, true);
    assert(fakefs_unlink(&mount, "/ioerr-target") == _EIO);
    assert(!atomic_load(&fault_next_write));
    assert(fakefs_db_recovery_required(fs));
    /* SQLite may automatically roll back on IOERR. That does not undo the
     * host unlink: even auto1/NONE must remain explicitly recovery-blocked. */
    assert(sqlite3_get_autocommit(fs->db));
    dsh_lifecycle_get_snapshot(&snap);
    assert(snap.recovery_blocked_connections == 1 && snap.active_read_transactions == 0 &&
            snap.active_write_transactions == 0 && snap.active_deferred_transactions == 0);
    assert(snap.transaction_count == 1 && snap.transactions[0].cached_autocommit == 1 &&
            snap.transactions[0].recovery_required);
    begin_fast_failure(fs);
    assert(faccessat(mount.root_fd, "ioerr-target", F_OK, 0) < 0 && errno == ENOENT);
    /* Restore the known disposable host file before clearing recovery solely
     * for test cleanup; runtime provides no automatic repair path. */
    int restored_host = openat(mount.root_fd, "ioerr-target", O_CREAT | O_WRONLY | O_EXCL, 0666);
    assert(restored_host >= 0 && close(restored_host) == 0);
    assert(db_rollback(fs) == SQLITE_OK);
    assert(unlinkat(mount.root_fd, "ioerr-target", 0) == 0);
    puts("PASS real VFS IOERR auto-rollback still blocks post-host recovery/suspend");

    assert(db_begin_write(fs) == SQLITE_OK);
    assert(pthread_create(&thread, NULL, external_failure, fs) == 0);
    assert(pthread_join(thread, NULL) == 0);
    assert(db_commit(fs) == SQLITE_IOERR && sqlite3_get_autocommit(fs->db));
    assert(fakefs_db_recovery_required(fs) && db_rollback(fs) == SQLITE_IOERR);
    dsh_lifecycle_get_snapshot(&snap); assert(snap.recovery_blocked_connections == 1);
    begin_fast_failure(fs);
    /* The external marker was synthetic and changed no host data in this
     * fixture. Clear it only after joining the reporting worker for cleanup. */
    fs->external_recovery_required = false;
    assert(db_rollback(fs) == SQLITE_OK);
    puts("PASS external host recovery cannot be cleared by another transaction's COMMIT/rollback");

    sql(fs->db, "pragma max_page_count=2147483646");
    assert(realfs_mknod(&mount, "/mknod-success", S_IFREG | 0600, 0) == 0);
    assert(fcntl(last_mknod_close_fd, F_GETFD) < 0 && errno == EBADF);
    assert(unlinkat(mount.root_fd, "mknod-success", 0) == 0);
    assert(fakefs_mknod(&mount, "/mknod-success", S_IFREG | 0600, 0) == 0);
    assert(fcntl(last_mknod_close_fd, F_GETFD) < 0 && errno == EBADF);
    assert(faccessat(mount.root_fd, "mknod-success", F_OK, 0) == 0);
    assert(db_begin_read(fs) == SQLITE_OK);
    assert(path_get_inode(fs, "/mknod-success") != 0 && db_commit(fs) == SQLITE_OK);
    assert(fakefs_mknod(&mount, "/missing-parent/node", S_IFREG | 0600, 0) == _ENOENT);
    assert(!fakefs_db_recovery_required(fs) && sqlite3_get_autocommit(fs->db));
    assert(db_begin_read(fs) == SQLITE_OK);
    assert(path_get_inode(fs, "/missing-parent/node") == 0 && db_commit(fs) == SQLITE_OK);
    atomic_store(&fail_mknod_close, true);
    assert(fakefs_mknod(&mount, "/mknod-close-failed", S_IFCHR | 0600, 1) == _EIO);
    assert(!atomic_load(&fail_mknod_close));
    assert(fcntl(last_mknod_close_fd, F_GETFD) < 0 && errno == EBADF);
    assert(faccessat(mount.root_fd, "mknod-close-failed", F_OK, 0) == 0);
    assert(fakefs_db_recovery_required(fs) && fs->transaction_owned && !sqlite3_get_autocommit(fs->db));
    assert(sqlite3_mutex_try(fs->lock) == SQLITE_BUSY);
    assert(path_get_inode(fs, "/mknod-close-failed") != 0);
    dsh_lifecycle_get_snapshot(&snap);
    assert(snap.recovery_blocked_connections == 1 && snap.active_write_transactions == 1);
    uint64_t generation = dsh_lifecycle_request_quiesce();
    assert(!dsh_lifecycle_mark_quiescent(generation));
    begin_fast_failure(fs);
    assert(fake_db_deinit(fs) != SQLITE_OK);
    // Verify the uncommitted metadata is invisible to another real connection.
    sqlite3 *observer = NULL;
    assert(sqlite3_open(argv[1], &observer) == SQLITE_OK);
    sqlite3_stmt *query = NULL;
    assert(sqlite3_prepare_v2(observer, "select inode from paths where path=?", -1, &query, NULL) == SQLITE_OK);
    const char *created = "/mknod-close-failed";
    assert(sqlite3_bind_blob(query, 1, created, strlen(created), SQLITE_TRANSIENT) == SQLITE_OK);
    assert(sqlite3_step(query) == SQLITE_DONE);
    assert(sqlite3_finalize(query) == SQLITE_OK && sqlite3_close(observer) == SQLITE_OK);
    // Only this disposable fixture, after verifying its known host file, may
    // explicitly complete metadata. Production performs no automatic repair.
    assert(db_commit(fs) == SQLITE_OK);
    assert(dsh_lifecycle_mark_quiescent(generation));
    dsh_lifecycle_resume();
    assert(fakefs_unlink(&mount, "/mknod-close-failed") == 0);
    assert(fakefs_unlink(&mount, "/mknod-success") == 0);
    puts("PASS production mknod close IOERR preserves created host file/metadata ownership and blocks recovery/suspend without fd leaks");

    assert(fake_db_deinit(fs) == SQLITE_OK);
    assert(close(mount.root_fd) == 0);
    puts("All fakefs SQLite failure tests passed.");
    return 0;
}
