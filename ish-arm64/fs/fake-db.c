#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <time.h>
#include "kernel/errno.h"
#include "debug.h"
#include "misc.h"
#include "fs/fake-db.h"
#include "fs/dsh-lifecycle.h"
#include "util/signpost.h"

/* Called only by the SQLite worker, never by the lifecycle snapshot reader.
 * Cache both autocommit and txn_state: an implicit SELECT can retain a read
 * transaction even while autocommit is enabled. No SQL/path/content is logged.
 */
static void db_observe(struct fakefs_db *fs, int result, const char *phase) {
    if (fs->db == NULL) return;
    int txn_state = -1;
#if SQLITE_VERSION_NUMBER >= 3034000
    txn_state = sqlite3_txn_state(fs->db, "main");
#endif
    dsh_lifecycle_sqlite_update(fs->lifecycle_connection_id, -1,
            sqlite3_get_autocommit(fs->db), txn_state, result, phase);
}

/* The profile hook also observes direct SQL in migration/rebuild, which do
 * not use db_begin/db_commit. It augments DEBUG_sql instead of replacing it.
 */
static int db_lifecycle_trace(unsigned event, void *context, void *statement, void *detail) {
    struct fakefs_db *fs = context;
    (void) detail;
    if (event == SQLITE_TRACE_PROFILE)
        db_observe(fs, SQLITE_OK, "sql_profile");
#if DEBUG_sql
    if (event == SQLITE_TRACE_STMT)
        printk("sql trace: %s\n", sqlite3_sql(statement));
#else
    (void) statement;
#endif
    return 0;
}

static int db_finalize_observed(struct fakefs_db *fs, sqlite3_stmt *statement) {
    int result = sqlite3_finalize(statement);
    db_observe(fs, result, "finalize");
    return result;
}

#ifndef DSH_DB_TRANSACTION_TIMEOUT_MS
#define DSH_DB_TRANSACTION_TIMEOUT_MS 2000
#endif
#define DB_RETRY_DELAY_NS UINT64_C(20000000)

static uint64_t db_now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t) ts.tv_sec * UINT64_C(1000000000) + (uint64_t) ts.tv_nsec;
}

static uint64_t db_deadline(void) {
    return db_now() + (uint64_t) DSH_DB_TRANSACTION_TIMEOUT_MS * UINT64_C(1000000);
}

static bool db_wait(uint64_t deadline) {
    uint64_t now = db_now();
    if (now >= deadline) return false;
    uint64_t remaining = deadline - now;
    if (remaining > DB_RETRY_DELAY_NS) remaining = DB_RETRY_DELAY_NS;
    struct timespec delay = { .tv_sec = 0, .tv_nsec = (long) remaining };
    nanosleep(&delay, NULL);
    return db_now() < deadline;
}

static int db_busy(void *context, int attempts) {
    (void) attempts;
    struct fakefs_db *fs = context;
    return db_wait(fs->deadline_monotonic_ns);
}

static bool db_success(int result) {
    return result == SQLITE_OK || result == SQLITE_ROW || result == SQLITE_DONE;
}

static int db_record(struct fakefs_db *fs, int result, const char *phase) {
    db_observe(fs, result, phase);
    if (!db_success(result) && fs->transaction_owned && fs->transaction_error == SQLITE_OK)
        fs->transaction_error = result;
    return result;
}

int db_blocked_error(const struct fakefs_db *fs) {
    return atomic_load_explicit(&fs->blocked_error, memory_order_acquire);
}

bool fakefs_db_recovery_required(const struct fakefs_db *fs) {
    return db_blocked_error(fs) != SQLITE_OK;
}

int db_transaction_error(const struct fakefs_db *fs) {
    return fs->transaction_error;
}

/* This short lock never guards SQL or host IO. It serializes externally
 * discovered host/metadata failures with a different worker finishing COMMIT,
 * so that worker cannot clear recovery evidence for an operation it did not own. */
static pthread_mutex_t db_recovery_lock = PTHREAD_MUTEX_INITIALIZER;
static void db_mark_recovery(struct fakefs_db *fs, int error, bool external) {
    if (db_success(error)) error = SQLITE_IOERR;
    pthread_mutex_lock(&db_recovery_lock);
    if (external) fs->external_recovery_required = true;
    atomic_store_explicit(&fs->blocked_error, error, memory_order_release);
    dsh_lifecycle_sqlite_recovery_required(fs->lifecycle_connection_id, error);
    pthread_mutex_unlock(&db_recovery_lock);
    /* May be called after failed BEGIN on another SQL worker: never sample
     * SQLite here. Its last SQL-worker observations remain separately cached. */
    printk("fakefs recovery blocked: connection=%llu rc=%d external=%d; preserving state\n",
            (unsigned long long) fs->lifecycle_connection_id, error, external);
}
void db_require_recovery(struct fakefs_db *fs, int error) { db_mark_recovery(fs, error, false); }
void db_require_external_recovery(struct fakefs_db *fs, int error) { db_mark_recovery(fs, error, true); }
static bool db_resolve_owned_recovery(struct fakefs_db *fs) {
    pthread_mutex_lock(&db_recovery_lock);
    bool resolved = !fs->external_recovery_required;
    if (resolved) {
        atomic_store_explicit(&fs->blocked_error, SQLITE_OK, memory_order_release);
        dsh_lifecycle_sqlite_recovery_resolved(fs->lifecycle_connection_id);
    }
    pthread_mutex_unlock(&db_recovery_lock);
    return resolved;
}

/* One absolute budget covers mutex acquisition, BEGIN, metadata statements and
 * COMMIT retries. SQLite's busy handler uses that same budget; no nested 5s x
 * 50 retry loops. This cannot preempt a host filesystem call already in flight.
 */
static int db_run(struct fakefs_db *fs, sqlite3_stmt *stmt) {
    for (;;) {
        int result = sqlite3_step(stmt);
        db_observe(fs, result, "step");
        if ((result & 0xff) != SQLITE_BUSY) return result;
#ifdef SQLITE_BUSY_SNAPSHOT
        /* A stale read snapshot cannot become writable by waiting. */
        if (result == SQLITE_BUSY_SNAPSHOT) return result;
#endif
        if (db_now() >= fs->deadline_monotonic_ns) {
            db_observe(fs, SQLITE_BUSY_TIMEOUT, "step_timeout");
            return SQLITE_BUSY_TIMEOUT;
        }
        int reset_result = sqlite3_reset(stmt);
        db_observe(fs, reset_result, "retry_reset");
        if ((reset_result & 0xff) != SQLITE_BUSY && reset_result != SQLITE_OK) return reset_result;
        if (!db_wait(fs->deadline_monotonic_ns)) {
            db_observe(fs, SQLITE_BUSY_TIMEOUT, "retry_timeout");
            return SQLITE_BUSY_TIMEOUT;
        }
    }
}

int db_exec(struct fakefs_db *fs, sqlite3_stmt *stmt) {
    if (fs->transaction_owned && fs->transaction_error != SQLITE_OK)
        return fs->transaction_error;
    ISH_SIGNPOST_SCOPE_BEGIN(fs, "db_exec", _dbe_spid);
    int result = db_record(fs, db_run(fs, stmt), "step_result");
    ISH_SIGNPOST_SCOPE_END(fs, "db_exec", _dbe_spid);
    return result;
}

int db_reset(struct fakefs_db *fs, sqlite3_stmt *stmt) {
    /* reset reports the previous step's result; repeating it would erase the
     * failure rather than finish or roll back the surrounding transaction. */
    return db_record(fs, sqlite3_reset(stmt), "reset");
}

int db_exec_reset(struct fakefs_db *fs, sqlite3_stmt *stmt) {
    int result = db_exec(fs, stmt);
    int reset_result = db_reset(fs, stmt);
    return !db_success(result) ? result : !db_success(reset_result) ? reset_result : result;
}

static int db_prepare_tail_checked(struct fakefs_db *fs, const char *sql, sqlite3_stmt **out, const char **tail) {
    *out = NULL;
    for (;;) {
        int result = sqlite3_prepare_v2(fs->db, sql, -1, out, tail);
        if (result == SQLITE_OK) return SQLITE_OK;
        if (*out) { db_finalize_observed(fs, *out); *out = NULL; }
        if ((result & 0xff) != SQLITE_BUSY) return db_record(fs, result, "prepare_failed");
        if (!db_wait(fs->deadline_monotonic_ns))
            return db_record(fs, SQLITE_BUSY_TIMEOUT, "prepare_timeout");
    }
}

int db_prepare(struct fakefs_db *fs, const char *sql, sqlite3_stmt **out) {
    return db_prepare_tail_checked(fs, sql, out, NULL);
}

static int db_step_checked(struct fakefs_db *fs, sqlite3_stmt *stmt, const char *sql) {
    (void) sql;
    return db_exec(fs, stmt);
}

int db_exec_sql(struct fakefs_db *fs, const char *sql) {
    while (*sql) {
        sqlite3_stmt *stmt = NULL;
        const char *tail = NULL;
        int result = db_prepare_tail_checked(fs, sql, &stmt, &tail);
        if (result != SQLITE_OK) return result;
        sql = tail;
        if (stmt == NULL) continue;
        result = db_exec(fs, stmt);
        int final_result = db_finalize_observed(fs, stmt);
        if (!db_success(final_result)) db_record(fs, final_result, "finalize_failed");
        if (!db_success(result)) return result;
        if (!db_success(final_result)) return final_result;
    }
    return SQLITE_OK;
}

static int db_exec_oneshot(struct fakefs_db *fs, const char *sql) {
    return db_exec_sql(fs, sql);
}

static void db_release(struct fakefs_db *fs) {
    fs->transaction_owned = false;
    sqlite3_mutex_leave(fs->lock);
}

static int db_begin(struct fakefs_db *fs, sqlite3_stmt *statement, const char *phase) {
    if (db_blocked_error(fs) != SQLITE_OK) return SQLITE_IOERR;
    uint64_t deadline = db_deadline();
    for (;;) {
        if (db_blocked_error(fs) != SQLITE_OK) return SQLITE_IOERR;
        int result = sqlite3_mutex_try(fs->lock);
        if (result == SQLITE_OK) break;
        if (!db_wait(deadline)) {
            /* Another worker owns SQLite: never sample its connection here. */
            printk("fakefs SQLite deadline expired: connection=%llu phase=mutex rc=%d\n",
                    (unsigned long long) fs->lifecycle_connection_id, SQLITE_BUSY_TIMEOUT);
            return SQLITE_BUSY_TIMEOUT;
        }
    }
    if (db_blocked_error(fs) != SQLITE_OK) {
        sqlite3_mutex_leave(fs->lock);
        return SQLITE_IOERR;
    }
    fs->deadline_monotonic_ns = deadline;
    fs->transaction_owner = pthread_self();
    fs->transaction_owned = true;
    fs->transaction_error = SQLITE_OK;
    int result = db_exec_reset(fs, statement);
    db_observe(fs, result, phase);
    if (db_success(result)) return SQLITE_OK;
    if (sqlite3_get_autocommit(fs->db)) db_release(fs);
    else db_require_recovery(fs, result);
    return result;
}

int db_begin_read(struct fakefs_db *fs) {
    return db_begin(fs, fs->stmt.begin_deferred, "begin_read");
}
int db_begin_write(struct fakefs_db *fs) {
    return db_begin(fs, fs->stmt.begin_immediate, "begin_write");
}

int db_commit(struct fakefs_db *fs) {
    if (!fs->transaction_owned || !pthread_equal(fs->transaction_owner, pthread_self()))
        return SQLITE_MISUSE;
    int result = fs->transaction_error;
    if (result == SQLITE_OK) {
        result = db_run(fs, fs->stmt.commit);
        int reset_result = sqlite3_reset(fs->stmt.commit);
        if (db_success(result) && !db_success(reset_result)) result = reset_result;
    }
    db_observe(fs, result, "commit");
    if (db_success(result) && sqlite3_get_autocommit(fs->db)) {
        bool resolved = db_resolve_owned_recovery(fs);
        db_release(fs);
        return resolved ? SQLITE_OK : SQLITE_IOERR;
    }
    if (db_success(result)) result = SQLITE_PROTOCOL;
    db_require_recovery(fs, result);
    /* A failed COMMIT can leave the SQLite transaction and file locks active.
     * Preserve ownership: releasing this mutex would admit a second worker into
     * the first worker's transaction. The caller may explicitly roll back only
     * when it knows no irreversible host mutation has occurred. */
    if (sqlite3_get_autocommit(fs->db)) db_release(fs);
    return result;
}

int db_rollback(struct fakefs_db *fs) {
    if (!pthread_equal(fs->transaction_owner, pthread_self()))
        return SQLITE_MISUSE;
    if (!fs->transaction_owned && sqlite3_get_autocommit(fs->db)) {
        fs->transaction_error = SQLITE_OK;
        return db_resolve_owned_recovery(fs) ? SQLITE_OK : SQLITE_IOERR;
    }
    if (!fs->transaction_owned) return SQLITE_MISUSE;
    int result = SQLITE_OK;
    if (!sqlite3_get_autocommit(fs->db)) {
        result = db_run(fs, fs->stmt.rollback);
        int reset_result = sqlite3_reset(fs->stmt.rollback);
        if (db_success(result) && !db_success(reset_result)) result = reset_result;
    }
    db_observe(fs, result, "rollback");
    if (db_success(result) && sqlite3_get_autocommit(fs->db)) {
        fs->transaction_error = SQLITE_OK;
        bool resolved = db_resolve_owned_recovery(fs);
        db_release(fs);
        return resolved ? SQLITE_OK : SQLITE_IOERR;
    }
    if (db_success(result)) result = SQLITE_PROTOCOL;
    db_require_recovery(fs, result);
    if (sqlite3_get_autocommit(fs->db)) db_release(fs);
    return result;
}

static void bind_path(struct fakefs_db *fs, sqlite3_stmt *stmt, int i, const char *path) {
    db_record(fs, sqlite3_bind_blob(stmt, i, path, strlen(path), SQLITE_TRANSIENT), "bind");
}

inode_t path_get_inode(struct fakefs_db *fs, const char *path) {
    // select inode from paths where path = ?
    bind_path(fs, fs->stmt.path_get_inode, 1, path);
    inode_t inode = 0;
    if (db_exec(fs, fs->stmt.path_get_inode) == SQLITE_ROW)
        inode = sqlite3_column_int64(fs->stmt.path_get_inode, 0);
    db_reset(fs, fs->stmt.path_get_inode);
    return inode;
}
bool path_read_stat(struct fakefs_db *fs, const char *path, struct ish_stat *stat, inode_t *inode) {
    // select inode, stat from stats natural join paths where path = ?
    bind_path(fs, fs->stmt.path_read_stat, 1, path);
    bool exists = db_exec(fs, fs->stmt.path_read_stat) == SQLITE_ROW;
    if (exists) {
        if (inode)
            *inode = sqlite3_column_int64(fs->stmt.path_read_stat, 0);
        if (stat) {
            if (sqlite3_column_bytes(fs->stmt.path_read_stat, 1) != sizeof(*stat)) {
                db_record(fs, SQLITE_CORRUPT, "invalid_stat");
                exists = false;
            } else *stat = *(struct ish_stat *) sqlite3_column_blob(fs->stmt.path_read_stat, 1);
        }
    }
    db_reset(fs, fs->stmt.path_read_stat);
    return exists;
}
inode_t path_create(struct fakefs_db *fs, const char *path, struct ish_stat *stat) {
    // insert into stats (stat) values (?)
    db_record(fs, sqlite3_bind_blob(fs->stmt.path_create_stat, 1, stat, sizeof(*stat), SQLITE_TRANSIENT), "bind");
    db_exec_reset(fs, fs->stmt.path_create_stat);
    if (fs->transaction_error != SQLITE_OK) return 0;
    inode_t inode = sqlite3_last_insert_rowid(fs->db);
    // insert or replace into paths values (?, last_insert_rowid())
    bind_path(fs, fs->stmt.path_create_path, 1, path);
    db_exec_reset(fs, fs->stmt.path_create_path);
    return inode;
}

void inode_read_stat_or_die(struct fakefs_db *fs, inode_t inode, struct ish_stat *stat) {
    if (!inode_read_stat_if_exist(fs, inode, stat))
        { memset(stat, 0, sizeof(*stat)); db_record(fs, SQLITE_CORRUPT, "missing_inode"); }
}
bool inode_read_stat_if_exist(struct fakefs_db *fs, inode_t inode, struct ish_stat *stat) {
    // select stat from stats where inode = ?
    db_record(fs, sqlite3_bind_int64(fs->stmt.inode_read_stat, 1, inode), "bind");
    bool exist = db_exec(fs, fs->stmt.inode_read_stat) == SQLITE_ROW;
    if (exist) {
        if (sqlite3_column_bytes(fs->stmt.inode_read_stat, 0) != sizeof(*stat)) {
            db_record(fs, SQLITE_CORRUPT, "invalid_stat");
            exist = false;
        } else *stat = *(struct ish_stat *) sqlite3_column_blob(fs->stmt.inode_read_stat, 0);
    }
    db_reset(fs, fs->stmt.inode_read_stat);
    return exist;
}
void inode_write_stat(struct fakefs_db *fs, inode_t inode, struct ish_stat *stat) {
    // update stats set stat = ? where inode = ?
    db_record(fs, sqlite3_bind_blob(fs->stmt.inode_write_stat, 1, stat, sizeof(*stat), SQLITE_TRANSIENT), "bind");
    db_record(fs, sqlite3_bind_int64(fs->stmt.inode_write_stat, 2, inode), "bind");
    db_exec_reset(fs, fs->stmt.inode_write_stat);
}

void path_link(struct fakefs_db *fs, const char *src, const char *dst) {
    inode_t inode = path_get_inode(fs, src);
    if (inode == 0) {
        db_record(fs, SQLITE_NOTFOUND, "missing_link_source");
        return;
    }
    // insert or replace into paths (path, inode) values (?, ?)
    bind_path(fs, fs->stmt.path_link, 1, dst);
    db_record(fs, sqlite3_bind_int64(fs->stmt.path_link, 2, inode), "bind");
    db_exec_reset(fs, fs->stmt.path_link);
}
inode_t path_unlink(struct fakefs_db *fs, const char *path) {
    inode_t inode = path_get_inode(fs, path);
    if (inode == 0)
        return 0;  // Path not in meta.db — already gone or never tracked
    // delete from paths where path = ?
    bind_path(fs, fs->stmt.path_unlink, 1, path);
    db_exec_reset(fs, fs->stmt.path_unlink);
    return inode;
}
void path_rename(struct fakefs_db *fs, const char *src, const char *dst) {
    // update or replace paths set path = change_prefix(path, ? [len(src)], ? [dst])
    //  where (path >= ? [src plus /] and path < [src plus 0]) or path = ? [src]
    // arguments:
    // 1. length of src
    // 2. dst
    // 3. src plus /
    // 4. src plus 0
    // 5. src
    size_t src_len = strlen(src);
    db_record(fs, sqlite3_bind_int64(fs->stmt.path_rename, 1, src_len), "bind");
    bind_path(fs, fs->stmt.path_rename, 2, dst);
    char src_extra[src_len + 1];
    memcpy(src_extra, src, src_len);
    src_extra[src_len] = '/';
    db_record(fs, sqlite3_bind_blob(fs->stmt.path_rename, 3, src_extra, src_len + 1, SQLITE_TRANSIENT), "bind");
    src_extra[src_len] = '0';
    db_record(fs, sqlite3_bind_blob(fs->stmt.path_rename, 4, src_extra, src_len + 1, SQLITE_TRANSIENT), "bind");
    db_record(fs, sqlite3_bind_blob(fs->stmt.path_rename, 5, src_extra, src_len, SQLITE_TRANSIENT), "bind");
    db_exec_reset(fs, fs->stmt.path_rename);
}



static void sqlite_func_change_prefix(sqlite3_context *context, int argc, sqlite3_value **args) {
    assert(argc == 3);
    const void *in_blob = sqlite3_value_blob(args[0]);
    size_t in_size = sqlite3_value_bytes(args[0]);
    size_t start = sqlite3_value_int64(args[1]);
    const void *replacement = sqlite3_value_blob(args[2]);
    size_t replacement_size = sqlite3_value_bytes(args[2]);
    if (start > in_size || replacement_size > SIZE_MAX - (in_size - start)) {
        sqlite3_result_error(context, "invalid path prefix", -1);
        return;
    }
    size_t out_size = in_size - start + replacement_size;
    char *out_blob = sqlite3_malloc64(out_size ? out_size : 1);
    if (!out_blob) { sqlite3_result_error_nomem(context); return; }
    memcpy(out_blob, replacement, replacement_size);
    memcpy(out_blob + replacement_size, in_blob + start, in_size - start);
    sqlite3_result_blob(context, out_blob, out_size, sqlite3_free);
}

extern int fakefs_rebuild(struct fakefs_db *fs, int root_fd);
extern int fakefs_migrate(struct fakefs_db *fs, int root_fd);

int fake_db_init(struct fakefs_db *fs, const char *db_path, int root_fd) {
    DSH_LIFECYCLE_SCOPE(-1);
    fs->deadline_monotonic_ns = db_deadline();
    fs->transaction_owned = false;
    fs->transaction_error = SQLITE_OK;
    fs->external_recovery_required = false;
    atomic_init(&fs->blocked_error, SQLITE_OK);
    memset(&fs->stmt, 0, sizeof(fs->stmt));
    fs->lock = NULL;
    int err = sqlite3_open_v2(db_path, &fs->db, SQLITE_OPEN_READWRITE, NULL);
    fs->lifecycle_connection_id = dsh_lifecycle_sqlite_open(-1);
    if (err != SQLITE_OK) {
        printk("error opening database: %s\n", sqlite3_errmsg(fs->db));
        int close_result = sqlite3_close(fs->db);
        dsh_lifecycle_sqlite_close(fs->lifecycle_connection_id, close_result);
        if (close_result == SQLITE_OK) fs->db = NULL;
        else db_require_recovery(fs, close_result);
        return _EINVAL;
    }
    unsigned trace_events = SQLITE_TRACE_PROFILE;
#if DEBUG_sql
    trace_events |= SQLITE_TRACE_STMT;
#endif
    sqlite3_extended_result_codes(fs->db, 1);
    sqlite3_trace_v2(fs->db, trace_events, db_lifecycle_trace, fs);
    sqlite3_busy_handler(fs->db, db_busy, fs);
    sqlite3_create_function(fs->db, "change_prefix", 3, SQLITE_UTF8 | SQLITE_DETERMINISTIC, NULL, sqlite_func_change_prefix, NULL, NULL);
    fs->lock = sqlite3_mutex_alloc(SQLITE_MUTEX_FAST);
    if (!fs->lock) goto init_fail;
    if (db_prepare(fs, "begin deferred", &fs->stmt.begin_deferred) != SQLITE_OK) goto init_fail;
    if (db_prepare(fs, "begin immediate", &fs->stmt.begin_immediate) != SQLITE_OK) goto init_fail;
    if (db_prepare(fs, "commit", &fs->stmt.commit) != SQLITE_OK) goto init_fail;
    if (db_prepare(fs, "rollback", &fs->stmt.rollback) != SQLITE_OK) goto init_fail;

    // [T-fakefs-db-init-no-die] Every prepare/step below now fails the mount
    // (return _EIO) instead of die()-ing the whole app on a SQLite error. The
    // caller (fakefs mount) already handles a negative return gracefully.
    if (db_exec_oneshot(fs, "pragma journal_mode=wal") != SQLITE_OK) goto init_fail;
    if (db_exec_oneshot(fs, "pragma foreign_keys=true") != SQLITE_OK) goto init_fail;

    // N18: Apple-friendly sqlite tuning. The fakefs db is read-mostly
    // during normal use (writes happen for chmod / chown / mknod / new
    // files). N17 signpost data showed 78K db_exec calls totaling
    // 122ms = 8% of npm --version user CPU. Three knobs help on macOS:
    //
    //  - PRAGMA mmap_size: lets sqlite read pages directly through
    //    mmap instead of read() syscalls. The OS's unified buffer
    //    cache then serves repeated reads at memcpy speed.
    //  - PRAGMA cache_size (negative => KB of in-process page cache):
    //    sqlite default is 2 MB; bump to 64 MB so the working set fits.
    //  - PRAGMA synchronous=NORMAL: WAL with NORMAL is durable across
    //    process crashes (like FULL) but skips an fsync per commit,
    //    cheap when fakefs writes are infrequent.
    //  - PRAGMA temp_store=MEMORY: keeps sort/temp tables off disk.
    static const char *tuning[] = {
        "pragma mmap_size=268435456",   // 256 MB
        "pragma cache_size=-65536",     // 64 MB in-process page cache
        "pragma synchronous=NORMAL",
        "pragma temp_store=MEMORY",
    };
    for (size_t ti = 0; ti < sizeof(tuning)/sizeof(tuning[0]); ti++) {
        // Tuning pragmas are best-effort: a failure here only loses a perf knob,
        // not correctness, so log and continue rather than fail the mount.
        if (db_exec_oneshot(fs, tuning[ti]) != SQLITE_OK)
            printk("fakefs db init: tuning pragma failed (continuing): %s\n", tuning[ti]);
    }

    err = fakefs_migrate(fs, root_fd);
    if (err < 0)
        goto init_fail;

    // after the filesystem is compressed, transmitted, and uncompressed, the
    // inode numbers will be different. to detect this, the inode of the
    // database file is stored inside the database and compared with the actual
    // database file inode, and if they're different we rebuild the database.
    struct stat statbuf;
    if (stat(db_path, &statbuf) < 0) goto init_fail;
    ino_t db_inode = statbuf.st_ino;
    sqlite3_stmt *statement = NULL;
    if (db_prepare(fs, "select db_inode from meta", &statement) != SQLITE_OK) goto init_fail;
    int inode_rc = db_step_checked(fs, statement, "select db_inode from meta");
    if (inode_rc == SQLITE_ROW) {
        if ((uint64_t) sqlite3_column_int64(statement, 0) != db_inode) {
            db_finalize_observed(fs, statement);
            statement = NULL;
            int err = fakefs_rebuild(fs, root_fd);
            if (err < 0) {
                goto init_fail;
            }
        }
    } else {
        db_finalize_observed(fs, statement);
        goto init_fail;
    }
    if (statement != NULL)
        db_finalize_observed(fs, statement);

    // save current inode
    if (db_prepare(fs, "update meta set db_inode = ?", &statement) != SQLITE_OK) goto init_fail;
    db_record(fs, sqlite3_bind_int64(statement, 1, (int64_t) db_inode), "bind");
    int meta_rc = db_step_checked(fs, statement, "update meta set db_inode = ?");
    if (meta_rc != SQLITE_DONE && meta_rc != SQLITE_ROW && meta_rc != SQLITE_OK) {
        db_finalize_observed(fs, statement);
        goto init_fail;
    }
    db_finalize_observed(fs, statement);

    // delete orphaned stats
    if (db_exec_oneshot(fs, "delete from stats where not exists (select 1 from paths where inode = stats.inode)") != SQLITE_OK)
        goto init_fail;

    // [T-fakefs-db-init-no-die] Each cached statement must prepare successfully;
    // a NULL would crash later at runtime. On any failure, fail the mount.
#define PREPARE_OR_FAIL(field, sql) \
    if (db_prepare(fs, (sql), &fs->stmt.field) != SQLITE_OK) goto init_fail
    PREPARE_OR_FAIL(path_get_inode, "select inode from paths where path = ?");
    PREPARE_OR_FAIL(path_read_stat, "select inode, stat from stats natural join paths where path = ?");
    PREPARE_OR_FAIL(path_create_stat, "insert into stats (stat) values (?)");
    PREPARE_OR_FAIL(path_create_path, "insert or replace into paths values (?, last_insert_rowid())");
    PREPARE_OR_FAIL(inode_read_stat, "select stat from stats where inode = ?");
    PREPARE_OR_FAIL(inode_write_stat, "update stats set stat = ? where inode = ?");
    PREPARE_OR_FAIL(path_link, "insert or replace into paths (path, inode) values (?, ?)");
    PREPARE_OR_FAIL(path_unlink, "delete from paths where path = ?");
    PREPARE_OR_FAIL(path_rename, "update or replace paths set path = change_prefix(path, ?, ?) "
            "where (path >= ? and path < ?) or path = ?");
    PREPARE_OR_FAIL(path_from_inode, "select path from paths where inode = ?");
    PREPARE_OR_FAIL(try_cleanup_inode, "delete from stats where inode = ? and not exists (select 1 from paths where inode = stats.inode)");
#undef PREPARE_OR_FAIL
    return 0;

init_fail:
    // [T-fakefs-db-init-no-die] A SQLite error during init no longer aborts the
    // whole app. Close the half-open db and return an error so the fakefs mount
    // fails gracefully (the caller handles a negative return).
    printk("fakefs db init failed: connection=%llu recovery=%d\n",
            (unsigned long long) fs->lifecycle_connection_id, db_blocked_error(fs));
    if (fakefs_db_recovery_required(fs)) return _EIO;
    if (fs->transaction_owned && db_rollback(fs) != SQLITE_OK) return _EIO;
    if (fake_db_deinit(fs) != SQLITE_OK) db_require_recovery(fs, SQLITE_BUSY);
    return _EIO;
}

int fake_db_deinit(struct fakefs_db *fs) {
    DSH_LIFECYCLE_SCOPE(-1);
    if (fakefs_db_recovery_required(fs)) return db_blocked_error(fs);
    if (fs->transaction_owned) return SQLITE_BUSY;
    if (fs->db) {
        db_finalize_observed(fs, fs->stmt.begin_deferred);
        db_finalize_observed(fs, fs->stmt.begin_immediate);
        db_finalize_observed(fs, fs->stmt.commit);
        db_finalize_observed(fs, fs->stmt.rollback);
        db_finalize_observed(fs, fs->stmt.path_get_inode);
        db_finalize_observed(fs, fs->stmt.path_read_stat);
        db_finalize_observed(fs, fs->stmt.path_create_stat);
        db_finalize_observed(fs, fs->stmt.path_create_path);
        db_finalize_observed(fs, fs->stmt.inode_read_stat);
        db_finalize_observed(fs, fs->stmt.inode_write_stat);
        db_finalize_observed(fs, fs->stmt.path_link);
        db_finalize_observed(fs, fs->stmt.path_unlink);
        db_finalize_observed(fs, fs->stmt.path_rename);
        db_finalize_observed(fs, fs->stmt.path_from_inode);
        db_finalize_observed(fs, fs->stmt.try_cleanup_inode);
        memset(&fs->stmt, 0, sizeof(fs->stmt));
        int close_result = sqlite3_close(fs->db);
        dsh_lifecycle_sqlite_close(fs->lifecycle_connection_id, close_result);
        if (close_result == SQLITE_OK) {
            fs->db = NULL;
            memset(&fs->stmt, 0, sizeof(fs->stmt));
            if (fs->lock) sqlite3_mutex_free(fs->lock);
            fs->lock = NULL;
        } else db_require_recovery(fs, close_result);
        return close_result;
    }
    return SQLITE_OK;
}
