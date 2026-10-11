#ifndef FS_FAKEFS_API_H
#define FS_FAKEFS_API_H

#include <sqlite3.h>
#include <pthread.h>
#include <stdatomic.h>
#include "fs/fix_path.h"
#include "misc.h"

#ifndef SQLITE_BUSY_TIMEOUT
#define SQLITE_BUSY_TIMEOUT (SQLITE_BUSY | (3 << 8))
#endif

struct fakefs_db {
    sqlite3 *db;
    uint64_t lifecycle_connection_id;
    struct {
        sqlite3_stmt *begin_deferred;
        sqlite3_stmt *begin_immediate;
        sqlite3_stmt *commit;
        sqlite3_stmt *rollback;
        sqlite3_stmt *path_get_inode;
        sqlite3_stmt *path_read_stat;
        sqlite3_stmt *path_create_stat;
        sqlite3_stmt *path_create_path;
        sqlite3_stmt *inode_read_stat;
        sqlite3_stmt *inode_write_stat;
        sqlite3_stmt *path_link;
        sqlite3_stmt *path_unlink;
        sqlite3_stmt *path_rename;
        sqlite3_stmt *path_from_inode;
        sqlite3_stmt *try_cleanup_inode;
    } stmt;
    sqlite3_mutex *lock;
    uint64_t deadline_monotonic_ns;
    pthread_t transaction_owner;
    bool transaction_owned;
    int transaction_error; /* Accessed only by the transaction owner. */
    atomic_int blocked_error; /* Other workers may inspect without the DB mutex. */
    bool external_recovery_required; /* Guarded by the short recovery-state mutex. */
};

int fake_db_init(struct fakefs_db *fs, const char *db_path, int root_fd);
int fake_db_deinit(struct fakefs_db *fs);

int db_begin_read(struct fakefs_db *fs);
int db_begin_write(struct fakefs_db *fs);
int db_commit(struct fakefs_db *fs);
int db_rollback(struct fakefs_db *fs);
int db_blocked_error(const struct fakefs_db *fs);
bool fakefs_db_recovery_required(const struct fakefs_db *fs);
int db_transaction_error(const struct fakefs_db *fs);
void db_require_recovery(struct fakefs_db *fs, int error);
void db_require_external_recovery(struct fakefs_db *fs, int error);

/* db_exec returns SQLITE_ROW/DONE or an explicit error, never a boolean. */
int db_exec(struct fakefs_db *fs, sqlite3_stmt *stmt);
int db_reset(struct fakefs_db *fs, sqlite3_stmt *stmt);
int db_exec_reset(struct fakefs_db *fs, sqlite3_stmt *stmt);
int db_exec_sql(struct fakefs_db *fs, const char *sql);
int db_prepare(struct fakefs_db *fs, const char *sql, sqlite3_stmt **statement);

struct ish_stat {
    uint32_t mode;
    uint32_t uid;
    uint32_t gid;
    uint32_t rdev;
};

typedef uint64_t inode_t;

inode_t path_get_inode(struct fakefs_db *fs, const char *path);
bool path_read_stat(struct fakefs_db *fs, const char *path, struct ish_stat *stat, uint64_t *inode);
inode_t path_create(struct fakefs_db *fs, const char *path, struct ish_stat *stat);

bool inode_read_stat_if_exist(struct fakefs_db *fs, inode_t inode, struct ish_stat *stat);
void inode_read_stat_or_die(struct fakefs_db *fs, inode_t inode, struct ish_stat *stat);
void inode_write_stat(struct fakefs_db *fs, inode_t inode, struct ish_stat *stat);

void path_link(struct fakefs_db *fs, const char *src, const char *dst);
inode_t path_unlink(struct fakefs_db *fs, const char *path);
void path_rename(struct fakefs_db *fs, const char *src, const char *dst);

#endif
