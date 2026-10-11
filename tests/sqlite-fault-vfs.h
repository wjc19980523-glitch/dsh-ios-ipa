/* Disposable-test VFS: delegates SQLite's real VFS and fails one real xWrite. */
#ifndef DSH_SQLITE_FAULT_VFS_H
#define DSH_SQLITE_FAULT_VFS_H
#include <sqlite3.h>
#include <stdatomic.h>
#include <string.h>
struct fault_file { sqlite3_file base; sqlite3_file *real; };
static sqlite3_vfs *fault_parent;
static sqlite3_vfs fault_vfs;
static atomic_bool fault_next_write;
#define REAL(f) (((struct fault_file *) (f))->real)
static int fault_close(sqlite3_file *f) { return REAL(f)->pMethods->xClose(REAL(f)); }
static int fault_read(sqlite3_file *f, void *b, int n, sqlite3_int64 o) { return REAL(f)->pMethods->xRead(REAL(f), b, n, o); }
static int fault_write(sqlite3_file *f, const void *b, int n, sqlite3_int64 o) {
    if (atomic_exchange(&fault_next_write, false)) return SQLITE_IOERR_WRITE;
    return REAL(f)->pMethods->xWrite(REAL(f), b, n, o);
}
static int fault_truncate(sqlite3_file *f, sqlite3_int64 n) { return REAL(f)->pMethods->xTruncate(REAL(f), n); }
static int fault_sync(sqlite3_file *f, int flags) { return REAL(f)->pMethods->xSync(REAL(f), flags); }
static int fault_size(sqlite3_file *f, sqlite3_int64 *n) { return REAL(f)->pMethods->xFileSize(REAL(f), n); }
static int fault_lock(sqlite3_file *f, int n) { return REAL(f)->pMethods->xLock(REAL(f), n); }
static int fault_unlock(sqlite3_file *f, int n) { return REAL(f)->pMethods->xUnlock(REAL(f), n); }
static int fault_reserved(sqlite3_file *f, int *n) { return REAL(f)->pMethods->xCheckReservedLock(REAL(f), n); }
static int fault_control(sqlite3_file *f, int op, void *p) { return REAL(f)->pMethods->xFileControl(REAL(f), op, p); }
static int fault_sector(sqlite3_file *f) { return REAL(f)->pMethods->xSectorSize(REAL(f)); }
static int fault_device(sqlite3_file *f) { return REAL(f)->pMethods->xDeviceCharacteristics(REAL(f)); }
static int fault_shmmap(sqlite3_file *f, int p, int n, int w, void volatile **out) {
    return REAL(f)->pMethods->xShmMap(REAL(f), p, n, w, out);
}
static int fault_shmlock(sqlite3_file *f, int o, int n, int flags) { return REAL(f)->pMethods->xShmLock(REAL(f), o, n, flags); }
static void fault_shmbarrier(sqlite3_file *f) { REAL(f)->pMethods->xShmBarrier(REAL(f)); }
static int fault_shmunmap(sqlite3_file *f, int d) { return REAL(f)->pMethods->xShmUnmap(REAL(f), d); }
static int fault_fetch(sqlite3_file *f, sqlite3_int64 o, int n, void **out) {
    if (REAL(f)->pMethods->iVersion < 3 || !REAL(f)->pMethods->xFetch) { *out = NULL; return SQLITE_OK; }
    return REAL(f)->pMethods->xFetch(REAL(f), o, n, out);
}
static int fault_unfetch(sqlite3_file *f, sqlite3_int64 o, void *p) {
    if (REAL(f)->pMethods->iVersion < 3 || !REAL(f)->pMethods->xUnfetch) return SQLITE_OK;
    return REAL(f)->pMethods->xUnfetch(REAL(f), o, p);
}
static const sqlite3_io_methods fault_methods = {3, fault_close, fault_read, fault_write, fault_truncate,
    fault_sync, fault_size, fault_lock, fault_unlock, fault_reserved, fault_control, fault_sector,
    fault_device, fault_shmmap, fault_shmlock, fault_shmbarrier, fault_shmunmap, fault_fetch, fault_unfetch};
static int fault_open(sqlite3_vfs *vfs, const char *name, sqlite3_file *file, int flags, int *out) {
    (void) vfs;
    struct fault_file *wrapped = (struct fault_file *) file;
    wrapped->real = (sqlite3_file *) ((char *) file + sizeof(*wrapped));
    memset(wrapped->real, 0, fault_parent->szOsFile);
    int rc = fault_parent->xOpen(fault_parent, name, wrapped->real, flags, out);
    if (rc == SQLITE_OK) wrapped->base.pMethods = &fault_methods;
    return rc;
}
static void fault_vfs_install(void) {
    fault_parent = sqlite3_vfs_find(NULL); assert(fault_parent);
    fault_vfs = *fault_parent;
    fault_vfs.zName = "dsh-disposable-fault-test";
    fault_vfs.szOsFile = sizeof(struct fault_file) + fault_parent->szOsFile;
    fault_vfs.xOpen = fault_open;
    assert(sqlite3_vfs_register(&fault_vfs, 1) == SQLITE_OK);
}
#endif
