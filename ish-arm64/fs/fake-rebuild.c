#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>
#include <limits.h>
#include "fs/fake-db.h"
#include "kernel/errno.h"
#include "util/list.h"
#include "debug.h"

struct entry {
    inode_t inode;
    ino_t real_inode;
    char *path;
    struct list chain;
};
struct relink {
    char *source, *target;
    struct list chain;
};

/* Rebuild every metadata row before changing a host link. Host changes cannot
 * be undone by SQL rollback. A link is staged beside its target then renamed,
 * so a failed linkat never destroys the original target. */
int fakefs_rebuild(struct fakefs_db *fs, int root_fd) {
    sqlite3_stmt *get_paths = NULL, *read_stat = NULL, *write_path = NULL, *write_stat = NULL;
    struct list hashtable[2000];
    struct list links;
    list_init(&links);
    for (size_t i = 0; i < sizeof(hashtable) / sizeof(hashtable[0]); i++) list_init(&hashtable[i]);
    bool host_changed = false;
    int rc = db_begin_write(fs);
    if (rc != SQLITE_OK) return _EIO;
    rc = db_exec_sql(fs,
        "create table paths_old (path blob primary key, inode integer);"
        "create table stats_old (inode integer primary key, stat blob);"
        "insert into paths_old select * from paths;"
        "insert into stats_old select * from stats;"
        "delete from paths; delete from stats;");
    if (rc != SQLITE_OK) goto finish;
#define PREPARE(statement, sql) do { \
    rc = db_prepare(fs, sql, &statement); \
    if (rc != SQLITE_OK) goto finish; \
} while (0)
#define BIND(call) do { rc = (call); if (rc != SQLITE_OK) goto finish; } while (0)
    PREPARE(get_paths, "select path, inode from paths_old");
    PREPARE(read_stat, "select stat from stats_old where inode = ?");
    PREPARE(write_path, "insert into paths (path, inode) values (?, ?)");
    PREPARE(write_stat, "replace into stats (inode, stat) values (?, ?)");
    while ((rc = db_exec(fs, get_paths)) == SQLITE_ROW) {
        const char *path = (const char *) sqlite3_column_text(get_paths, 0);
        inode_t inode = sqlite3_column_int64(get_paths, 1);
        if (!path) { rc = SQLITE_CORRUPT; goto finish; }
        struct stat st;
        if (fstatat(root_fd, fix_path(path), &st, 0) < 0) {
            if (errno == ENOENT) continue;
            rc = SQLITE_IOERR; goto finish;
        }
        BIND(sqlite3_bind_int64(read_stat, 1, inode));
        rc = db_exec(fs, read_stat);
        if (rc == SQLITE_DONE) { db_reset(fs, read_stat); continue; }
        if (rc != SQLITE_ROW) goto finish;
        if (sqlite3_column_bytes(read_stat, 0) != sizeof(struct ish_stat)) {
            rc = SQLITE_CORRUPT; goto finish;
        }
        struct ish_stat metadata;
        memcpy(&metadata, sqlite3_column_blob(read_stat, 0), sizeof(metadata));
        rc = db_reset(fs, read_stat);
        if (rc != SQLITE_OK) goto finish;
        struct list *bucket = &hashtable[inode % (sizeof(hashtable) / sizeof(hashtable[0]))];
        struct entry *entry, *canonical = NULL;
        list_for_each_entry(bucket, entry, chain) if (entry->inode == inode) { canonical = entry; break; }
        ino_t real_inode = st.st_ino;
        if (canonical) {
            real_inode = canonical->real_inode;
            if (real_inode != st.st_ino) {
                struct relink *link = calloc(1, sizeof(*link));
                if (!link) { rc = SQLITE_NOMEM; goto finish; }
                link->source = strdup(canonical->path); link->target = strdup(path);
                if (!link->source || !link->target) {
                    free(link->source); free(link->target); free(link); rc = SQLITE_NOMEM; goto finish;
                }
                list_add(&links, &link->chain);
            }
        } else {
            entry = calloc(1, sizeof(*entry));
            if (!entry) { rc = SQLITE_NOMEM; goto finish; }
            entry->path = strdup(path);
            if (!entry->path) { free(entry); rc = SQLITE_NOMEM; goto finish; }
            entry->inode = inode; entry->real_inode = real_inode;
            list_add(bucket, &entry->chain);
        }
        BIND(sqlite3_bind_int64(write_stat, 1, real_inode));
        BIND(sqlite3_bind_blob(write_stat, 2, &metadata, sizeof(metadata), SQLITE_TRANSIENT));
        rc = db_exec_reset(fs, write_stat);
        if (rc != SQLITE_DONE) goto finish;
        BIND(sqlite3_bind_blob(write_path, 1, path, strlen(path), SQLITE_TRANSIENT));
        BIND(sqlite3_bind_int64(write_path, 2, real_inode));
        rc = db_exec_reset(fs, write_path);
        if (rc != SQLITE_DONE) goto finish;
    }
    if (rc != SQLITE_DONE) goto finish;
    rc = db_reset(fs, get_paths);
    if (rc != SQLITE_OK) goto finish;
    rc = db_exec_sql(fs, "drop table paths_old; drop table stats_old;");
    if (rc != SQLITE_OK) goto finish;
    struct relink *link;
    unsigned serial = 0;
    list_for_each_entry(&links, link, chain) {
        char temporary[PATH_MAX];
        const char *target = fix_path(link->target);
        const char *slash = strrchr(target, '/');
        size_t parent_length = slash ? (size_t) (slash - target + 1) : 0;
        if (parent_length + 80 >= sizeof(temporary)) { rc = SQLITE_TOOBIG; goto finish; }
        memcpy(temporary, target, parent_length);
        bool staged = false;
        for (unsigned attempt = 0; attempt < 128; attempt++) {
            snprintf(temporary + parent_length, sizeof(temporary) - parent_length,
                    ".dsh-link-%llu-%u", (unsigned long long) fs->lifecycle_connection_id, serial++);
            if (linkat(root_fd, fix_path(link->source), root_fd, temporary, 0) == 0) { staged = true; break; }
            if (errno != EEXIST) break;
        }
        if (!staged) { rc = SQLITE_IOERR; goto finish; }
        if (renameat(root_fd, temporary, root_fd, target) < 0) {
            if (unlinkat(root_fd, temporary, 0) < 0) host_changed = true;
            rc = SQLITE_IOERR; goto finish;
        }
        host_changed = true;
    }
    rc = SQLITE_OK;
finish:;
    /* Finish every statement before COMMIT. Reset/finalize errors must not be
     * erased, and PROFILE observations must see the resulting read-lock state. */
    sqlite3_stmt *statements[] = { get_paths, read_stat, write_path, write_stat };
    for (size_t i = 0; i < sizeof(statements) / sizeof(statements[0]); i++) {
        if (!statements[i]) continue;
        int reset_rc = db_reset(fs, statements[i]);
        int final_rc = sqlite3_finalize(statements[i]);
        if (rc == SQLITE_OK && reset_rc != SQLITE_OK) rc = reset_rc;
        if (rc == SQLITE_OK && final_rc != SQLITE_OK) rc = final_rc;
    }
    for (size_t i = 0; i < sizeof(hashtable) / sizeof(hashtable[0]); i++) {
        struct entry *entry, *next;
        list_for_each_entry_safe(&hashtable[i], entry, next, chain) {
            list_remove(&entry->chain); free(entry->path); free(entry);
        }
    }
    struct relink *item, *next;
    list_for_each_entry_safe(&links, item, next, chain) {
        list_remove(&item->chain); free(item->source); free(item->target); free(item);
    }
    if (rc == SQLITE_OK) rc = db_commit(fs);
    if (rc == SQLITE_OK) return 0;
    if (host_changed) db_require_recovery(fs, rc);
    else db_rollback(fs);
    return _EIO;
#undef PREPARE
#undef BIND
}
