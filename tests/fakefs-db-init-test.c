/* Production migration/rebuild paths against disposable files and SQLite. */
#include <assert.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "fs/fake-db.h"
#include "fs/dsh-lifecycle.h"
#include "sqlite-fault-vfs.h"

void ish_printk(const char *format, ...) { (void) format; }
_Noreturn void die(const char *format, ...) { (void) format; abort(); }
static void sql(sqlite3 *db, const char *s) { assert(sqlite3_exec(db, s, NULL, NULL, NULL) == SQLITE_OK); }
static void schema(const char *name, bool migrate, bool fail, bool rebuild) {
    sqlite3 *db = NULL; assert(sqlite3_open(name, &db) == SQLITE_OK);
    sql(db, "create table meta (db_inode integer); insert into meta values (0);"
        "create table stats (inode integer primary key, stat blob);"
        "create table paths (path blob primary key, inode integer);");
    if (!migrate) sql(db, "pragma user_version=3");
    if (fail) sql(db, "create index inode_to_path on paths (inode, path)");
    struct stat st; assert(stat(name, &st) == 0);
    if (!rebuild) {
        sqlite3_stmt *save = NULL;
        assert(sqlite3_prepare_v2(db, "update meta set db_inode=?", -1, &save, NULL) == SQLITE_OK);
        assert(sqlite3_bind_int64(save, 1, st.st_ino) == SQLITE_OK);
        assert(sqlite3_step(save) == SQLITE_DONE); assert(sqlite3_finalize(save) == SQLITE_OK);
    }
    struct ish_stat metadata = {.mode = 0100644, .uid = 123, .gid = 456};
    sqlite3_stmt *save = NULL;
    assert(sqlite3_prepare_v2(db, "insert into stats values (100, ?)", -1, &save, NULL) == SQLITE_OK);
    assert(sqlite3_bind_blob(save, 1, &metadata, sizeof(metadata), SQLITE_TRANSIENT) == SQLITE_OK);
    assert(sqlite3_step(save) == SQLITE_DONE); assert(sqlite3_finalize(save) == SQLITE_OK);
    sql(db, "insert into paths values (cast('/one' as blob),100); insert into paths values(cast('/two' as blob),100)");
    assert(sqlite3_close(db) == SQLITE_OK);
}
static void write_host(int root, const char *path) {
    int fd = openat(root, path, O_CREAT | O_EXCL | O_WRONLY, 0666); assert(fd >= 0);
    assert(write(fd, "retained", 8) == 8); assert(close(fd) == 0);
}
extern int fakefs_rebuild(struct fakefs_db *, int);
int main(int argc, char **argv) {
    assert(argc == 2); fault_vfs_install();
    int root = open(argv[1], O_RDONLY | O_DIRECTORY); assert(root >= 0);
    char path[4096];
    snprintf(path, sizeof(path), "%s/migrate.db", argv[1]);
    schema(path, true, false, false);
    struct fakefs_db fs = {0}; assert(fake_db_init(&fs, path, root) == 0);
    sqlite3_stmt *version = NULL;
    assert(db_prepare(&fs, "pragma user_version", &version) == SQLITE_OK);
    assert(db_exec(&fs, version) == SQLITE_ROW && sqlite3_column_int(version, 0) == 3);
    assert(db_reset(&fs, version) == SQLITE_OK); assert(sqlite3_finalize(version) == SQLITE_OK);
    assert(fake_db_deinit(&fs) == SQLITE_OK);
    puts("PASS real multi-statement migration reaches version 3");

    snprintf(path, sizeof(path), "%s/fail.db", argv[1]);
    schema(path, true, true, false);
    assert(fake_db_init(&fs, path, root) < 0);
    assert(!fs.db && !fs.lock && !fakefs_db_recovery_required(&fs));
    struct dsh_lifecycle_snapshot snap; dsh_lifecycle_get_snapshot(&snap);
    assert(snap.open_connections == 0 && snap.transaction_count == 0);
    puts("PASS migration SQL error safely rolls back and cleans partial init");

    snprintf(path, sizeof(path), "%s/rebuild.db", argv[1]);
    schema(path, false, false, true);
    write_host(root, "one"); write_host(root, "two");
    assert(fake_db_init(&fs, path, root) == 0);
    struct stat a, b;
    assert(fstatat(root, "one", &a, 0) == 0 && fstatat(root, "two", &b, 0) == 0);
    assert(a.st_ino == b.st_ino);
    assert(db_begin_read(&fs) == SQLITE_OK);
    struct ish_stat metadata; inode_t inode;
    assert(path_read_stat(&fs, "/one", &metadata, &inode));
    assert(inode == a.st_ino && metadata.uid == 123 && metadata.gid == 456);
    assert(path_get_inode(&fs, "/two") == inode && db_commit(&fs) == SQLITE_OK);
    puts("PASS rebuild restores hardlinks and metadata uses the canonical host inode");

    /* Split a known disposable hardlink then inject an actual WAL xWrite error
     * after the rebuild's host replacement. Preserve blocked state on IOERR. */
    assert(unlinkat(root, "two", 0) == 0); write_host(root, "two");
    atomic_store(&fault_next_write, true);
    assert(fakefs_rebuild(&fs, root) < 0);
    assert(!atomic_load(&fault_next_write) && fakefs_db_recovery_required(&fs));
    assert(fstatat(root, "one", &a, 0) == 0 && fstatat(root, "two", &b, 0) == 0 && a.st_ino == b.st_ino);
    dsh_lifecycle_get_snapshot(&snap); assert(snap.recovery_blocked_connections == 1);
    assert(fake_db_deinit(&fs) != SQLITE_OK);
    /* This fixture knows the host inode was already canonical before IOERR;
     * completing explicit cleanup is safe here. Runtime does not auto-repair. */
    assert(db_rollback(&fs) == SQLITE_OK);
    assert(fakefs_rebuild(&fs, root) == 0);
    assert(fake_db_deinit(&fs) == SQLITE_OK);
    assert(close(root) == 0);
    puts("PASS post-host rebuild IOERR retains recovery evidence and refuses close");
    return 0;
}
