/* Real fakefs_umount/fake_db_deinit/mount_remove with a close-only fault shim.
 * Guest fd/user-memory helpers are link fixtures, not an emulated kernel boot. */
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <malloc/malloc.h>
#include <dispatch/dispatch.h>
#endif
#include "kernel/fs.h"
#include "fs/dsh-lifecycle.h"

static int injected_close(int fd);
#define close(fd) injected_close(fd)
#include "fs/fake.c"
#undef close
#include "fs/mount.c"

__thread struct task *current;
int errno_map(void) { return -errno; }
void ish_printk(const char *format, ...) { (void) format; }
_Noreturn void die(const char *format, ...) { (void) format; abort(); }
bool path_is_normalized(const char *path) { return path[0] == '/'; }
struct fd *fd_create(const struct fd_ops *ops) {
    struct fd *fd = calloc(1, sizeof(*fd));
    if (fd) { fd->ops = ops; fd->refcount = 1; }
    return fd;
}
int fd_close(struct fd *fd) { int result = close(fd->real_fd); free(fd); return result; }
int realfs_getpath(struct fd *fd, char *path) { (void) fd; path[0] = 0; return 0; }
const struct fd_ops realfs_fdops = {0};
const struct fs_ops realfs = {0}, procfs = {0}, devptsfs = {0}, tmpfs = {0};
int realfs_statfs(struct mount *mount, struct statfsbuf *out) { (void) mount; (void) out; return _ENOSYS; }
int realfs_close(struct fd *fd) { return close(fd->real_fd) < 0 ? -errno : 0; }
int realfs_utime(struct mount *mount, const char *path, struct timespec a, struct timespec m) {
    (void) mount; (void) path; (void) a; (void) m; return _ENOSYS;
}
int realfs_flock(struct fd *fd, int op) { return flock(fd->real_fd, op) < 0 ? -errno : 0; }
int realfs_mknod_with_effect(struct mount *mount, const char *path, mode_t_ mode, dev_t_ dev, bool *created) {
    (void) mount; (void) path; (void) mode; (void) dev; (void) created; abort();
}
void inode_check_orphaned(struct mount *mount, ino_t inode) { (void) mount; (void) inode; }

static int target_fd = -1, replacement_source = -1, replacement_fd = -1;
static int close_error, close_calls;
static bool leave_open, invalidated_before_close;
static struct mount *tested_mount;
static int injected_close(int fd) {
    if (fd != target_fd) return close(fd);
    close_calls++;
    invalidated_before_close = tested_mount->root_fd == -1 && g_fakefs_mount == NULL;
    int error = close_error;
    close_error = 0;
    if (!error) return close(fd);
    if (!leave_open) {
        int result = close(fd);
        assert(error == EBADF ? result == -1 && errno == EBADF : result == 0);
        assert(dup2(replacement_source, fd) == fd);
    }
    replacement_fd = fd;
    errno = error;
    return -1;
}
static void sql(sqlite3 *db, const char *text) {
    assert(sqlite3_exec(db, text, NULL, NULL, NULL) == SQLITE_OK);
}
static void schema(const char *path) {
    sqlite3 *db = NULL;
    assert(sqlite3_open(path, &db) == SQLITE_OK);
    sql(db, "create table meta (db_inode integer); insert into meta values(0);"
        "create table stats (inode integer primary key, stat blob);"
        "create table paths (path blob primary key, inode integer references stats(inode));"
        "pragma user_version=3;");
    struct stat st; assert(stat(path, &st) == 0);
    sqlite3_stmt *stmt = NULL;
    assert(sqlite3_prepare_v2(db, "update meta set db_inode=?", -1, &stmt, NULL) == SQLITE_OK);
    assert(sqlite3_bind_int64(stmt, 1, st.st_ino) == SQLITE_OK);
    assert(sqlite3_step(stmt) == SQLITE_DONE && sqlite3_finalize(stmt) == SQLITE_OK);
    struct ish_stat metadata = {.mode = S_IFREG | 0600, .uid = 123, .gid = 456};
    assert(sqlite3_prepare_v2(db, "insert into stats values(100,?)", -1, &stmt, NULL) == SQLITE_OK);
    assert(sqlite3_bind_blob(stmt, 1, &metadata, sizeof(metadata), SQLITE_TRANSIENT) == SQLITE_OK);
    assert(sqlite3_step(stmt) == SQLITE_DONE && sqlite3_finalize(stmt) == SQLITE_OK);
    sql(db, "insert into paths values(cast('/umount-preserved' as blob),100)");
    assert(sqlite3_close(db) == SQLITE_OK);
}
static void assert_data(const char *db_path, int root) {
    char bytes[16] = {0};
    int fd = openat(root, "umount-preserved", O_RDONLY);
    assert(fd >= 0 && read(fd, bytes, sizeof(bytes)) == 9);
    assert(close(fd) == 0 && !strcmp(bytes, "preserved"));
    sqlite3 *db = NULL;
    assert(sqlite3_open_v2(db_path, &db, SQLITE_OPEN_READONLY, NULL) == SQLITE_OK);
    sqlite3_stmt *stmt = NULL;
    assert(sqlite3_prepare_v2(db, "select inode,stat from paths natural join stats", -1, &stmt, NULL) == SQLITE_OK);
    assert(sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_int(stmt, 0) == 100);
    assert(sqlite3_column_bytes(stmt, 1) == sizeof(struct ish_stat));
    struct ish_stat metadata;
    memcpy(&metadata, sqlite3_column_blob(stmt, 1), sizeof(metadata));
    assert(metadata.mode == (S_IFREG | 0600) && metadata.uid == 123 && metadata.gid == 456);
    assert(sqlite3_finalize(stmt) == SQLITE_OK && sqlite3_close(db) == SQLITE_OK);
}
static bool operational(const char *point) {
    struct mount *mount;
    list_for_each_entry(&mounts, mount, mounts)
        if (!strcmp(mount->point, point)) return true;
    return false;
}
int main(int argc, char **argv) {
    assert(argc == 4);
    alarm(20);
    bool busy = !strcmp(argv[1], "busy"), success = !strcmp(argv[1], "success");
    if (!busy && !success) {
        if (!strcmp(argv[1], "closed-eintr")) close_error = EINTR;
        else if (!strcmp(argv[1], "closed-eio")) close_error = EIO;
        else if (!strcmp(argv[1], "unclosed-eio")) { close_error = EIO; leave_open = true; }
        else { assert(!strcmp(argv[1], "ebadf")); close_error = EBADF; }
    }
    int expected_error = close_error;
    schema(argv[2]);
    int observer_root = open(argv[3], O_RDONLY | O_DIRECTORY); assert(observer_root >= 0);
    int file = openat(observer_root, "umount-preserved", O_CREAT | O_TRUNC | O_WRONLY, 0600);
    assert(file >= 0 && write(file, "preserved", 9) == 9 && close(file) == 0);
    replacement_source = openat(observer_root, "umount-preserved", O_RDONLY); assert(replacement_source >= 0);
    assert(do_mount(&realfs, "disposable", "", "", 0) == 0);
    struct mount *fallback = list_entry(mounts.next, struct mount, mounts);
    tested_mount = calloc(1, sizeof(*tested_mount)); assert(tested_mount);
    tested_mount->source = strdup("disposable"); tested_mount->point = strdup("/mounted");
    tested_mount->info = strdup(""); tested_mount->fs = &fakefs;
    tested_mount->root_fd = open(argv[3], O_RDONLY | O_DIRECTORY); assert(tested_mount->root_fd >= 0);
    assert(fake_db_init(&tested_mount->fakefs, argv[2], tested_mount->root_fd) == 0);
    target_fd = tested_mount->root_fd;
    g_fakefs_mount = tested_mount;
    list_add(&mounts, &tested_mount->mounts); global_mount_version++;
    char guest_path[] = "/mounted/umount-preserved";
    assert(mount_find(guest_path) == tested_mount); mount_release(tested_mount);
    if (busy) {
        assert(db_begin_write(&tested_mount->fakefs) == SQLITE_OK);
        assert(do_umount("/mounted") == _EBUSY && operational("/mounted"));
        assert(tested_mount->fakefs.db && tested_mount->root_fd == target_fd && g_fakefs_mount == tested_mount);
        assert(close_calls == 0 && fcntl(target_fd, F_GETFD) >= 0);
        assert(db_rollback(&tested_mount->fakefs) == SQLITE_OK);
    }
    if (expected_error == EBADF) assert(close(target_fd) == 0);
    int result = do_umount("/mounted");
    assert(result == (expected_error ? -expected_error : 0));
    if (operational("/mounted")) {
        /* Old production deterministically leaves a torn-down operational mount.
         * Prove a retry also closes the descriptor installed at the same number. */
        fprintf(stderr, "FAIL torn-down mount retained: db_null=%d mutex_null=%d close_calls=%d\n",
                tested_mount->fakefs.db == NULL, tested_mount->fakefs.lock == NULL, close_calls);
        if (replacement_fd >= 0) {
            int retry = do_umount("/mounted");
            errno = 0; int descriptor = fcntl(replacement_fd, F_GETFD);
            fprintf(stderr, "FAIL retry: result=%d close_calls=%d replacement_closed=%d\n",
                    retry, close_calls, descriptor == -1 && errno == EBADF);
        }
        assert(!"irreversible teardown must detach even when close reports an error");
    }
    assert(invalidated_before_close && close_calls == 1 && g_fakefs_mount == NULL);
    assert(do_umount("/mounted") == _EINVAL && close_calls == 1);
    assert(mount_find(guest_path) == fallback); mount_release(fallback);
    if (replacement_fd >= 0) {
        assert(fcntl(replacement_fd, F_GETFD) >= 0);
        assert(close(replacement_fd) == 0); replacement_fd = -1;
    }
    struct dsh_lifecycle_snapshot snapshot;
    dsh_lifecycle_get_snapshot(&snapshot);
    assert(snapshot.open_connections == 0 && snapshot.active_operations == 0 && snapshot.recovery_blocked_connections == 0);
    assert(snapshot.native_close_failures == (expected_error ? 1u : 0u));
    uint64_t generation = dsh_lifecycle_request_quiesce();
    assert(dsh_lifecycle_mark_quiescent(generation) == !expected_error);
    dsh_lifecycle_resume();
    assert_data(argv[2], observer_root);
    assert(do_umount("") == 0 && list_empty(&mounts));
    assert(close(replacement_source) == 0 && close(observer_root) == 0);
    printf("PASS production fakefs umount %s: teardown ownership, detach/error, fd reuse, cached lookup and preserved data\n", argv[1]);
    alarm(0);
    return 0;
}
