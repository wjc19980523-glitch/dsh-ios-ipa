#import <Foundation/Foundation.h>
#include <errno.h>
#include "fs/fake-db.h"

/* SQLite results stay explicit at this legacy API boundary. A failed read
 * may roll back; a host mutation must preserve a failed COMMIT for recovery. */
static inline int FileProviderDBErrno(int result) {
    switch (result & 0xff) {
        case SQLITE_BUSY: case SQLITE_LOCKED: return EBUSY;
        case SQLITE_NOMEM: return ENOMEM;
        case SQLITE_FULL: return ENOSPC;
        case SQLITE_READONLY: return EROFS;
        default: return EIO;
    }
}

static inline BOOL FileProviderDBResult(int result, NSError **error) {
    if (result == SQLITE_OK) return YES;
    if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:FileProviderDBErrno(result) userInfo:nil];
    NSLog(@"file provider database operation failed (SQLite %d)", result);
    return NO;
}

static inline int FileProviderDBRollback(struct fakefs_db *db, int result) {
    int rollback = db_rollback(db);
    return rollback == SQLITE_OK ? result : rollback;
}

/* Only use where no irreversible host change has occurred. */
static inline int FileProviderDBFinishRead(struct fakefs_db *db, int result) {
    if (result == SQLITE_OK || result == SQLITE_ROW || result == SQLITE_DONE)
        result = db_transaction_error(db);
    if (result != SQLITE_OK) return FileProviderDBRollback(db, result);
    result = db_commit(db);
    return result == SQLITE_OK ? SQLITE_OK : FileProviderDBRollback(db, result);
}
