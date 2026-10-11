/* Real production Linux/UML wrappers, real SQLite and real host files.
 * Kernel object allocation/dentry plumbing is shimmed; this is not a kernel
 * build and does not replace native FileProvider/UM Linux integration tests. */
#include <assert.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "fs/fake-db.h"
#include "fs/dsh-lifecycle.h"

void ish_printk(const char *format, ...) { (void)format; }
_Noreturn void die(const char *format, ...) { (void)format; abort(); }
struct fakefs_super { struct fakefs_db db; int root_fd; };
struct super_block { void *s_fs_info; };
struct user_namespace { int unused; };
typedef mode_t umode_t;
struct inode { struct super_block *i_sb; uintptr_t i_private; inode_t i_ino; unsigned uid, gid; int refs; };
struct dentry { struct { const char *name; } d_name; const char *path; struct dentry *d_parent; struct inode *inode; };
struct file { struct inode *f_inode; struct { struct dentry *dentry; } f_path; void *private_data; };
struct dir_context { long pos; unsigned emitted; };
struct host_dirent { const char *name; uint64_t ino; unsigned type; };
#define INODE_FD(ino) (*((uintptr_t *)&(ino)->i_private))
#define FILE_DIR(file) ((file)->private_data)
#define BUG_ON(condition) assert(!(condition))
static char *__getname(void) { return malloc(PATH_MAX); }
static void __putname(char *name) { free(name); }
static char *dentry_path_raw(struct dentry *dentry, char *name, size_t length) {
    if (strlen(dentry->path) + 1 > length) return ERR_PTR(-ENAMETOOLONG);
    strcpy(name, dentry->path); return name;
}
static struct inode *new_inode(struct super_block *sb) {
    struct inode *ino = calloc(1, sizeof(*ino));
    if (ino) { ino->i_sb = sb; INODE_FD(ino) = -1; ino->refs = 1; }
    return ino;
}
static void iput(struct inode *ino) {
    if (--ino->refs) return;
    struct fakefs_super *info = ino->i_sb->s_fs_info;
    if ((int)INODE_FD(ino) >= 0 && (int)INODE_FD(ino) != info->root_fd) close((int)INODE_FD(ino));
    free(ino);
}
static void inode_init_owner(struct user_namespace *ns, struct inode *ino, struct inode *dir, umode_t mode) {
    (void)ns; (void)mode; ino->uid = dir->uid; ino->gid = dir->gid;
}
static unsigned i_uid_read(struct inode *ino) { return ino->uid; }
static unsigned i_gid_read(struct inode *ino) { return ino->gid; }
static struct inode *d_inode(struct dentry *dentry) { return dentry->inode; }
static void ihold(struct inode *ino) { ino->refs++; }
static void d_instantiate(struct dentry *dentry, struct inode *ino) { dentry->inode = ino; }
static bool host_created_since_deny;
static int host_openat(int fd, const char *path, int flags, mode_t mode) {
    int result = openat(fd, path, flags, mode);
    if (result >= 0 && (flags & O_CREAT)) host_created_since_deny = true;
    return result < 0 ? -errno : result;
}
static int host_mkdirat(int fd, const char *path, mode_t mode) { return mkdirat(fd, path, mode) < 0 ? -errno : 0; }
static int host_renameat(int a, const char *b, int c, const char *d) { return renameat(a, b, c, d) < 0 ? -errno : 0; }
static int host_linkat(int a, const char *b, int c, const char *d) { return linkat(a, b, c, d, 0) < 0 ? -errno : 0; }
static int host_unlinkat(int fd, const char *path) { return unlinkat(fd, path, 0) < 0 ? -errno : 0; }
static int host_rmdirat(int fd, const char *path) { return unlinkat(fd, path, AT_REMOVEDIR) < 0 ? -errno : 0; }
static bool short_host_write;
static ssize_t host_write(int fd, const void *data, size_t size) {
    ssize_t rc = write(fd, data, short_host_write && size ? 1 : size); return rc < 0 ? -errno : rc;
}
static int read_inode(struct inode *ino) {
    struct fakefs_super *info = ino->i_sb->s_fs_info;
    struct ish_stat stat; inode_read_stat_or_die(&info->db, ino->i_ino, &stat);
    return db_transaction_error(&info->db) == SQLITE_OK ? 0 : -EIO;
}
static int host_dup_opendir(int fd, void **output) {
    int copy = dup(fd); if (copy < 0) return -errno;
    DIR *dir = fdopendir(copy); if (!dir) { int rc = -errno; close(copy); return rc; }
    *output = dir; return 0;
}
static int host_rewinddir(void *dir) { rewinddir(dir); return 0; }
static int host_seekdir(void *dir, long offset) { seekdir(dir, offset); return 0; }
static long host_telldir(void *dir) { return telldir(dir); }
static int host_readdir(void *dir, struct host_dirent *entry) {
    errno = 0; struct dirent *next = readdir(dir);
    if (!next) return errno ? -errno : 0;
    entry->name = next->d_name; entry->ino = next->d_ino; entry->type = next->d_type; return 1;
}
static bool dir_emit(struct dir_context *ctx, const char *name, size_t length, uint64_t ino, unsigned type) {
    (void)name; (void)length; (void)ino; (void)type; ctx->emitted++; return true;
}
#include "legacy-wrappers.h"

static void sql(sqlite3 *db, const char *text) { assert(sqlite3_exec(db, text, NULL, NULL, NULL) == SQLITE_OK); }
static int deny_action;
static int authorize(void *context, int action, const char *a, const char *b, const char *c, const char *d) {
    (void)context; (void)b; (void)c; (void)d;
    if (action == SQLITE_READ && !host_created_since_deny) return SQLITE_OK;
    if (action == deny_action && a && (strcmp(a, "paths") == 0 || strcmp(a, "stats") == 0 ||
        (action == SQLITE_TRANSACTION && strcmp(a, "COMMIT") == 0))) return SQLITE_DENY;
    return SQLITE_OK;
}
static void set_deny(struct fakefs_db *db, int action) {
    host_created_since_deny = false;
    deny_action = action; assert(sqlite3_set_authorizer(db->db, action ? authorize : NULL, NULL) == SQLITE_OK);
}
static void recover_for_test(struct fakefs_db *db) {
    set_deny(db, 0); assert(db_rollback(db) == SQLITE_OK);
    assert(!fakefs_db_recovery_required(db));
}
static bool exists(int fd, const char *name) { return faccessat(fd, name, F_OK, 0) == 0; }
static void fixture(struct fakefs_db *fs, const char *path, int root_fd) {
    sqlite3 *db = NULL; assert(sqlite3_open(path, &db) == SQLITE_OK);
    sql(db, "create table meta (db_inode integer); insert into meta values(0);"
        "create table stats (inode integer primary key, stat blob);"
        "create table paths (path blob primary key, inode integer references stats(inode));pragma user_version=3;");
    struct stat st; assert(stat(path, &st) == 0);
    sqlite3_stmt *save; assert(sqlite3_prepare_v2(db, "update meta set db_inode=?", -1, &save, NULL) == SQLITE_OK);
    assert(sqlite3_bind_int64(save, 1, st.st_ino) == SQLITE_OK); assert(sqlite3_step(save) == SQLITE_DONE);
    assert(sqlite3_finalize(save) == SQLITE_OK); assert(sqlite3_close(db) == SQLITE_OK);
    assert(fake_db_init(fs, path, root_fd) == 0);
}
int main(int argc, char **argv) {
    assert(argc == 3);
    struct fakefs_super info = {.root_fd = open(argv[2], O_DIRECTORY | O_RDONLY)}; assert(info.root_fd >= 0);
    fixture(&info.db, argv[1], info.root_fd);
    struct super_block sb = {.s_fs_info = &info};
    struct inode root = {.i_sb = &sb, .i_private = (uintptr_t)info.root_fd, .refs = 1};
    struct dentry parent = {.d_name.name = "", .path = "/", .inode = &root}; parent.d_parent = &parent;
    struct dentry a = {.d_name.name = "existing", .path = "/existing", .d_parent = &parent};
    struct dentry b = {.d_name.name = "target", .path = "/target", .d_parent = &parent};
    assert(fakefs_create(NULL, &root, &a, S_IFREG | 0644, true) == 0);
    assert(write((int)INODE_FD(a.inode), "preserved", 9) == 9);
    sqlite3 *other; assert(sqlite3_open(argv[1], &other) == SQLITE_OK); sql(other, "begin immediate");
    assert(fakefs_create(NULL, &root, &b, S_IFREG | 0644, true) == -EBUSY);
    assert(fakefs_rename(NULL, &root, &a, &root, &b, 0) == -EBUSY);
    assert(fakefs_unlink(&root, &a) == -EBUSY);
    assert(exists(info.root_fd, "existing") && !exists(info.root_fd, "target"));
    sql(other, "rollback"); assert(sqlite3_close(other) == SQLITE_OK);
    puts("PASS legacy BEGIN contention prevents create/rename/unlink host effects");

    set_deny(&info.db, SQLITE_INSERT);
    assert(fakefs_create(NULL, &root, &b, S_IFREG | 0644, true) == -EIO);
    assert(!exists(info.root_fd, "target") && !fakefs_db_recovery_required(&info.db));
    set_deny(&info.db, SQLITE_UPDATE);
    assert(fakefs_rename(NULL, &root, &a, &root, &b, 0) == -EIO);
    set_deny(&info.db, SQLITE_DELETE);
    assert(fakefs_unlink(&root, &a) == -EIO);
    assert(exists(info.root_fd, "existing") && !exists(info.root_fd, "target"));
    assert(!fakefs_db_recovery_required(&info.db));
    puts("PASS legacy metadata faults rollback before host create/rename/unlink");

    set_deny(&info.db, SQLITE_TRANSACTION);
    assert(fakefs_rename(NULL, &root, &a, &root, &b, 0) == -EIO);
    assert(!exists(info.root_fd, "existing") && exists(info.root_fd, "target"));
    assert(fakefs_db_recovery_required(&info.db) && !sqlite3_get_autocommit(info.db.db));
    assert(fakefs_unlink(&root, &b) == -EIO && exists(info.root_fd, "target"));
    recover_for_test(&info.db);
    assert(renameat(info.root_fd, "target", info.root_fd, "existing") == 0);

    set_deny(&info.db, SQLITE_TRANSACTION);
    assert(fakefs_create(NULL, &root, &b, S_IFREG | 0644, true) == -EIO);
    assert(exists(info.root_fd, "target") && fakefs_db_recovery_required(&info.db));
    assert(!b.inode); recover_for_test(&info.db);
    assert(unlinkat(info.root_fd, "target", 0) == 0);

    set_deny(&info.db, SQLITE_TRANSACTION);
    assert(fakefs_unlink(&root, &a) == -EIO);
    assert(!exists(info.root_fd, "existing") && fakefs_db_recovery_required(&info.db));
    recover_for_test(&info.db);
    puts("PASS post-host COMMIT failure remains recovery-blocked; no implicit rollback or host cleanup");

    set_deny(&info.db, SQLITE_READ);
    assert(fakefs_create(NULL, &root, &b, S_IFREG | 0644, true) == -EIO);
    assert(exists(info.root_fd, "target") && fakefs_db_recovery_required(&info.db));
    recover_for_test(&info.db); assert(unlinkat(info.root_fd, "target", 0) == 0);
    struct dentry partial = {.d_name.name = "partial", .path = "/partial", .d_parent = &parent};
    short_host_write = true;
    assert(fakefs_symlink(NULL, &root, &partial, "contents") == -EIO);
    short_host_write = false;
    assert(exists(info.root_fd, "partial") && fakefs_db_recovery_required(&info.db));
    struct stat partial_stat; assert(fstatat(info.root_fd, "partial", &partial_stat, 0) == 0 && partial_stat.st_size == 1);
    recover_for_test(&info.db); assert(unlinkat(info.root_fd, "partial", 0) == 0);
    puts("PASS post-create metadata read and partial symlink writes retain host data and recovery ownership");

    struct dentry link = {.d_name.name = "link", .path = "/link", .d_parent = &parent};
    assert(fakefs_symlink(NULL, &root, &link, "contents") == 0);
    struct dentry failed_link = {.d_name.name = "failed-link", .path = "/failed-link", .d_parent = &parent};
    set_deny(&info.db, SQLITE_TRANSACTION);
    assert(fakefs_link(&link, &root, &failed_link) == -EIO);
    assert(!failed_link.inode && exists(info.root_fd, "failed-link") && fakefs_db_recovery_required(&info.db));
    recover_for_test(&info.db); assert(unlinkat(info.root_fd, "failed-link", 0) == 0);
    struct dentry hard = {.d_name.name = "hard", .path = "/hard", .d_parent = &parent};
    assert(fakefs_link(&link, &root, &hard) == 0);
    assert(fakefs_unlink(&root, &hard) == 0); iput(hard.inode);
    assert(fakefs_unlink(&root, &link) == 0); iput(link.inode);
    struct dentry dir = {.d_name.name = "dir", .path = "/dir", .d_parent = &parent};
    assert(fakefs_mkdir(NULL, &root, &dir, 0755) == 0);
    assert(fakefs_rmdir(&root, &dir) == 0); iput(dir.inode);
    struct dentry special = {.d_name.name = "special", .path = "/special", .d_parent = &parent};
    assert(fakefs_mknod(NULL, &root, &special, S_IFIFO | 0600, 0) == 0);
    assert(fakefs_unlink(&root, &special) == 0); iput(special.inode);
    puts("PASS legacy successful symlink/link/mkdir/mknod/unlink paths");

    char long_path[PATH_MAX]; memset(long_path, 'x', sizeof(long_path) - 2); long_path[0] = '/'; long_path[sizeof(long_path) - 2] = 0;
    struct dentry long_parent = {.path = long_path, .d_parent = &parent, .inode = &root};
    struct file file = {.f_inode = &root, .f_path.dentry = &long_parent};
    struct dir_context ctx = {0}; assert(fakefs_iterate(&file, &ctx) == 0);
    assert(closedir(file.private_data) == 0);
    struct dsh_lifecycle_snapshot snapshot; dsh_lifecycle_get_snapshot(&snapshot);
    assert(snapshot.transaction_count == 0 && snapshot.recovery_blocked_connections == 0);
    puts("PASS overlong directory entry never leaves a read transaction open");
    iput(a.inode);
    assert(fake_db_deinit(&info.db) == SQLITE_OK); assert(close(info.root_fd) == 0);
    return 0;
}
