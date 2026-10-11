/* Exercises the real fake-db.c observation hooks against a disposable DB. */
#include <assert.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>
#include "fs/fake-db.h"
#include "fs/dsh-lifecycle.h"

static bool raw_migration_observed;

void ish_printk(const char *format, ...) { (void) format; }
_Noreturn void die(const char *format, ...) {
    va_list args;
    va_start(args, format);
    vfprintf(stderr, format, args);
    va_end(args);
    abort();
}

/* Keep the fixture schema small while testing the same direct-SQL route as
 * production migration/rebuild. These stubs do not replace the tested DB code. */
int fakefs_migrate(struct fakefs_db *fs, int root_fd) {
    (void) root_fd;
    assert(sqlite3_exec(fs->db, "begin immediate", NULL, NULL, NULL) == SQLITE_OK);
    struct dsh_lifecycle_snapshot value;
    dsh_lifecycle_get_snapshot(&value);
    assert(value.active_write_transactions == 1);
    assert(sqlite3_exec(fs->db, "commit", NULL, NULL, NULL) == SQLITE_OK);
    dsh_lifecycle_get_snapshot(&value);
    assert(value.transaction_count == 0);
    raw_migration_observed = true;
    return 0;
}
int fakefs_rebuild(struct fakefs_db *fs, int root_fd) {
    (void) fs; (void) root_fd;
    assert(!"fixture inode must match: rebuilding was unexpected");
    return -1;
}

int main(int argc, char **argv) {
    assert(argc == 2);
    const char *path = argv[1];
    sqlite3 *fixture = NULL;
    assert(sqlite3_open(path, &fixture) == SQLITE_OK);
    assert(sqlite3_exec(fixture,
        "create table meta (db_inode integer); insert into meta values (0);"
        "create table stats (inode integer primary key, stat blob);"
        "create table paths (path blob primary key, inode integer references stats(inode));",
        NULL, NULL, NULL) == SQLITE_OK);
    struct stat info;
    assert(stat(path, &info) == 0);
    sqlite3_stmt *save_inode = NULL;
    assert(sqlite3_prepare_v2(fixture, "update meta set db_inode=?", -1, &save_inode, NULL) == SQLITE_OK);
    assert(sqlite3_bind_int64(save_inode, 1, (sqlite3_int64) info.st_ino) == SQLITE_OK);
    assert(sqlite3_step(save_inode) == SQLITE_DONE);
    assert(sqlite3_finalize(save_inode) == SQLITE_OK);
    assert(sqlite3_close(fixture) == SQLITE_OK);

    uint64_t scope = dsh_lifecycle_operation_begin("sqlite_fixture", 301);
    struct fakefs_db fs = {0};
    assert(fake_db_init(&fs, path, -1) == 0);
    assert(raw_migration_observed);
    struct dsh_lifecycle_snapshot value;
    dsh_lifecycle_get_snapshot(&value);
    assert(value.open_connections == 1 && value.transaction_count == 0);

    db_begin_write(&fs);
    dsh_lifecycle_get_snapshot(&value);
    assert(value.active_write_transactions == 1);
    assert(value.transactions[0].owner.guest_pid == 301);
    struct ish_stat metadata = { .mode = 0100644, .uid = 0, .gid = 0, .rdev = 0 };
    assert(path_create(&fs, "/diagnostic-fixture", &metadata) != 0);
    db_commit(&fs);
    dsh_lifecycle_get_snapshot(&value);
    assert(value.transaction_count == 0);

    db_begin_read(&fs);
    assert(path_read_stat(&fs, "/diagnostic-fixture", NULL, NULL));
    dsh_lifecycle_get_snapshot(&value);
    assert(value.active_read_transactions == 1);
    db_rollback(&fs);
    dsh_lifecycle_get_snapshot(&value);
    assert(value.transaction_count == 0);

    /* Hold the SQLite serialization mutex while taking a snapshot. A snapshot
     * that tries to acquire it would deadlock this test on SQLITE_MUTEX_FAST. */
    sqlite3_mutex_enter(fs.lock);
    dsh_lifecycle_get_snapshot(&value);
    sqlite3_mutex_leave(fs.lock);

    sqlite3_stmt *implicit_read = NULL;
    assert(sqlite3_prepare_v2(fs.db, "select inode from stats", -1, &implicit_read, NULL) == SQLITE_OK);
    assert(db_exec(&fs, implicit_read) == SQLITE_ROW);
    dsh_lifecycle_get_snapshot(&value);
    assert(value.active_read_transactions == 1);
    assert(value.transactions[0].cached_autocommit == 1);
    db_reset(&fs, implicit_read);
    dsh_lifecycle_get_snapshot(&value);
    assert(value.transaction_count == 0);
    assert(sqlite3_finalize(implicit_read) == SQLITE_OK);

    assert(fake_db_deinit(&fs) == SQLITE_OK);
    dsh_lifecycle_operation_end(scope);
    dsh_lifecycle_get_snapshot(&value);
    assert(value.open_connections == 0 && value.active_operations == 0);
    puts("PASS real fake-db SQLite hooks, direct SQL, implicit reads and mutex-independent snapshots");
    return 0;
}
