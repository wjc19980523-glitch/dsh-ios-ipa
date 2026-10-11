#include "kernel/fs.h"
#include "debug.h"
#include "kernel/errno.h"
#include "fs/fake-db.h"

// The value of the user_version pragma is used to decide what needs migrating.

#pragma GCC diagnostic ignored "-Wmissing-field-initializers"
static struct migration {
    const char *sql;
    void (*migrate)(struct fakefs_db *fs);
} migrations[] = {
    // version 1: add another index
    {
        "create index inode_to_path on paths (inode, path);"
    },
    // version 2: add foreign key constraint on paths, create trigger to automatically cleanup stats
    {
        "create table paths_new (path blob primary key, inode integer references stats(inode));"
        "insert into paths_new select * from paths where exists (select 1 from stats where inode = paths.inode);"
        "drop table paths; alter table paths_new rename to paths;"
        "create index inode_to_path on paths (inode, path);"
        "delete from stats where not exists (select 1 from paths where inode = stats.inode);"
        "create trigger delete_path after delete on paths "
        "when not exists (select 1 from paths where inode = old.inode) "
        "begin "
            "delete from stats where not exists (select 1 from paths where inode = old.inode) and inode = old.inode; "
        "end;"
    },
    // version 3: the trigger was a mistake
    {
        "drop trigger delete_path"
    },
};

int fakefs_migrate(struct fakefs_db *fs, int UNUSED(root_fd)) {
    sqlite3_stmt *user_version = NULL;
    int err = db_prepare(fs, "pragma user_version", &user_version);
    if (err != SQLITE_OK) return _EIO;
    err = db_exec(fs, user_version);
    if (err != SQLITE_ROW) { sqlite3_finalize(user_version); return _EIO; }
    int version = sqlite3_column_int(user_version, 0);
    if (sqlite3_finalize(user_version) != SQLITE_OK) return _EIO;

    if (db_begin_write(fs) != SQLITE_OK) return _EIO;
    int versions = sizeof(migrations)/sizeof(migrations[0]);
    while (version < versions) {
        struct migration m = migrations[version];
        if (m.sql != NULL)
            if (db_exec_sql(fs, m.sql) != SQLITE_OK) goto fail;
        if (m.migrate != NULL)
            m.migrate(fs);
        version++;
    }
    // for some reason placeholders aren't allowed in pragmas
    char *pragma_user_version = sqlite3_mprintf("pragma user_version = %d", version);
    if (!pragma_user_version) goto fail;
    err = db_exec_sql(fs, pragma_user_version);
    sqlite3_free(pragma_user_version);
    if (err != SQLITE_OK) goto fail;
    if (db_commit(fs) != SQLITE_OK) goto fail;

    return 0;
fail:
    /* Migration only changes metadata; no host filesystem mutation occurred. */
    db_rollback(fs);
    return _EIO;
}
