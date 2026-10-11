/* Verify mount failure preserves live SQLite callback userdata. */
#include <assert.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include "fs/mount.c"
#include "fs/dsh-lifecycle.h"

void ish_printk(const char *format, ...) { (void) format; }
_Noreturn void die(const char *format, ...) { (void) format; abort(); }
const struct fs_ops realfs = {0}, procfs = {0}, devptsfs = {0}, tmpfs = {0};
static int mode, profiles;
static bool reject_umount;
static int profile(unsigned event, void *context, void *statement, void *detail) {
    (void) statement; (void) detail;
    struct fakefs_db *fs = context;
    assert(fs && fs->db && fs->lifecycle_connection_id);
    if (event == SQLITE_TRACE_PROFILE) profiles++;
    return 0;
}
static int fixture_mount(struct mount *mount) {
    if (mode == 0) return _EINVAL;
    if (mode == 1) {
        assert(sqlite3_open(":memory:", &mount->fakefs.db) == SQLITE_OK);
        mount->fakefs.lifecycle_connection_id = dsh_lifecycle_sqlite_open(-1);
        assert(sqlite3_trace_v2(mount->fakefs.db, SQLITE_TRACE_PROFILE, profile, &mount->fakefs) == SQLITE_OK);
        db_require_recovery(&mount->fakefs, SQLITE_IOERR);
        return _EIO;
    }
    return 0;
}
static int fixture_umount(struct mount *mount) { (void) mount; return reject_umount ? _EIO : 0; }
const struct fs_ops fakefs = {.mount = fixture_mount, .umount = fixture_umount};
static void *failed_mount_worker(void *context) {
    (void) context;
    assert(do_mount(&fakefs, "disposable-source", "/failed-thread", "disposable-info", 0) == _EIO);
    return NULL;
}
int main(void) {
    assert(do_mount(&fakefs, "disposable-source", "/failed", "disposable-info", 0) == _EINVAL);
    assert(list_empty(&failed_fakefs_mounts) && list_empty(&mounts));
    mode = 1;
    assert(do_mount(&fakefs, "disposable-source", "/failed", "disposable-info", 0) == _EIO);
    assert(!list_empty(&failed_fakefs_mounts) && list_empty(&mounts));
    pthread_t workers[2];
    for (unsigned i = 0; i < 2; i++) assert(pthread_create(&workers[i], NULL, failed_mount_worker, NULL) == 0);
    for (unsigned i = 0; i < 2; i++) assert(pthread_join(workers[i], NULL) == 0);
    struct dsh_lifecycle_snapshot snapshot;
    dsh_lifecycle_get_snapshot(&snapshot);
    assert(snapshot.open_connections == 3 && snapshot.recovery_blocked_connections == 3);
    uint64_t generation = dsh_lifecycle_request_quiesce();
    assert(!dsh_lifecycle_mark_quiescent(generation));
    dsh_lifecycle_resume();
    unsigned retained_count = 0;
    struct mount *retained, *next;
    list_for_each_entry_safe(&failed_fakefs_mounts, retained, next, mounts) {
        assert(strcmp(retained->info, "disposable-info") == 0);
        assert(sqlite3_exec(retained->fakefs.db, "select 1", NULL, NULL, NULL) == SQLITE_OK);
        retained_count++;
        /* Only this fixture resolves its host-free failure to release memory. */
        atomic_store(&retained->fakefs.blocked_error, SQLITE_OK);
        dsh_lifecycle_sqlite_recovery_resolved(retained->fakefs.lifecycle_connection_id);
        assert(fake_db_deinit(&retained->fakefs) == SQLITE_OK);
        list_remove(&retained->mounts);
        free((void *) retained->point); free((void *) retained->source); free((void *) retained->info); free(retained);
    }
    assert(retained_count == 3 && profiles == 3 && list_empty(&failed_fakefs_mounts));
    mode = 2;
    assert(do_mount(&fakefs, "disposable-source", "/mounted", "disposable-info", 0) == 0);
    struct mount *mounted = list_entry(mounts.next, struct mount, mounts);
    reject_umount = true;
    assert(mount_remove(mounted) == _EIO && !list_empty(&mounts));
    assert(strcmp(mounted->point, "/mounted") == 0);
    reject_umount = false;
    assert(mount_remove(mounted) == 0 && list_empty(&mounts));
    dsh_lifecycle_get_snapshot(&snapshot); assert(snapshot.open_connections == 0);
    puts("PASS failed mount callback userdata retention, isolated failed list and umount error lifetime");
    return 0;
}
