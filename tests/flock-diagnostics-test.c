/* Actual realfs/sys_flock bodies + real host files/flock/close. No guest image
 * or user data is touched. Host path/close errors are injected explicitly. */
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>
#include "kernel/task.h"
#include "kernel/calls.h"
#include "kernel/fs.h"
#include "kernel/errno.h"
#include "fs/fd.h"
#include "fs/dsh-lifecycle.h"

__thread struct task *current;
static struct fd *guest_file;
static bool fail_path, fail_close;
struct fd *f_get(fd_t number) { return number == 7 || number == 8 ? guest_file : NULL; }
int errno_map(void) { return -errno; }
static int controlled_close(int fd) {
    if (fail_close) { errno = EIO; return -1; }
    return close(fd);
}
#define close controlled_close
#include "production-flock.h"
#undef close

static struct dsh_lifecycle_snapshot snapshot(void) {
    struct dsh_lifecycle_snapshot value;
    dsh_lifecycle_get_snapshot(&value);
    return value;
}
static struct dsh_lifecycle_flock_event last_event(void) {
    struct dsh_lifecycle_snapshot value = snapshot();
    assert(value.native_flock_event_count > 0);
    return value.native_flock_events[value.native_flock_event_count - 1];
}

int main(int argc, char **argv) {
    assert(argc == 2);
    assert(dsh_lifecycle_flock_classify_path(NULL) == DSH_FLOCK_FILE_UNKNOWN);
    assert(dsh_lifecycle_flock_classify_path("") == DSH_FLOCK_FILE_UNKNOWN);
    assert(dsh_lifecycle_flock_classify_path("/private/token-secret/session.lock") == DSH_FLOCK_FILE_SESSION_LOCK);
    assert(dsh_lifecycle_flock_classify_path("session.lock") == DSH_FLOCK_FILE_SESSION_LOCK);
    assert(dsh_lifecycle_flock_classify_path("/private/session.lock-token-secret") == DSH_FLOCK_FILE_OTHER);
    assert(dsh_lifecycle_flock_classify_path("/private/token-secret") == DSH_FLOCK_FILE_OTHER);
    assert(dsh_lifecycle_flock_classify_path("/private/session.lock/") == DSH_FLOCK_FILE_OTHER);
    puts("PASS strict file-category whitelist never retains arbitrary filenames or paths");

    struct task task = {.pid = 22, .tgid = 4};
    current = &task;
    const struct fs_ops fs = {.name = "fake", .flock = realfs_flock};
    struct mount mount = {.fs = &fs};
    struct fd file = {.mount = &mount, .real_fd = open(argv[1], O_CREAT | O_RDWR | O_TRUNC, 0600)};
    assert(file.real_fd >= 0);
    guest_file = &file;
    const char sentinel[] = "configuration-session-workspace-preserved";
    assert(write(file.real_fd, sentinel, sizeof(sentinel)) == sizeof(sentinel));
    struct stat st;
    assert(fstat(file.real_fd, &st) == 0);
    errno = EDOM;
    assert(sys_flock(7, LOCK_EX_ | LOCK_NB_) == 0 && errno == EDOM);
    struct dsh_lifecycle_snapshot value = snapshot();
    assert(value.active_native_flocks == 1);
    struct dsh_lifecycle_flock_snapshot held = value.native_flocks[0];
    assert(held.guest_fd == 7 && held.guest_tgid == 4 && held.owner.guest_pid == 22);
    assert(held.host_fd == file.real_fd && held.identity.file_kind == DSH_FLOCK_FILE_SESSION_LOCK);
    assert(held.identity.device == (uint64_t) st.st_dev && held.identity.inode == (uint64_t) st.st_ino);
    assert(held.identity.fs_kind == DSH_FLOCK_FS_FAKE && held.identity.path_error == 0 && held.identity.stat_error == 0);
    assert(last_event().kind == DSH_FLOCK_ACQUIRED && last_event().lock.guest_fd == 7);
    puts("PASS production sys_flock maps guest fd/TGID to real host fd, inode and session.lock");

    int rival_fd = open(argv[1], O_RDWR);
    assert(rival_fd >= 0);
    struct fd rival = {.mount = &mount, .real_fd = rival_fd};
    uint64_t events_before = value.native_flock_event_total;
    assert(realfs_flock(&rival, LOCK_EX_ | LOCK_NB_) == -1);
    assert(errno == EWOULDBLOCK || errno == EAGAIN);
    assert(snapshot().native_flock_event_total == events_before && snapshot().active_native_flocks == 1);
    uint64_t generation = dsh_lifecycle_request_quiesce();
    assert(!dsh_lifecycle_mark_quiescent(generation));
    dsh_lifecycle_resume();
    assert(sys_flock(8, LOCK_SH_ | LOCK_NB_) == 0);
    held = snapshot().native_flocks[0];
    assert(held.id == value.native_flocks[0].id && held.guest_fd == 8);
    assert(held.started_monotonic_ns == value.native_flocks[0].started_monotonic_ns);
    assert(last_event().kind == DSH_FLOCK_UPDATED && last_event().lock.guest_fd == 8);
    assert(flock(rival_fd, LOCK_SH | LOCK_NB) == 0 && flock(rival_fd, LOCK_UN) == 0);
    assert(sys_flock(8, LOCK_UN_) == 0 && snapshot().active_native_flocks == 0);
    assert(last_event().kind == DSH_FLOCK_UNLOCKED && last_event().lock.guest_fd == 8);
    assert(realfs_close(&rival) == 0);
    puts("PASS genuine contention, shared conversion and explicit unlock preserve host lock semantics");

    fail_path = true;
    errno = ERANGE;
    assert(sys_flock(7, LOCK_EX_ | LOCK_NB_) == 0 && errno == ERANGE);
    held = snapshot().native_flocks[0];
    assert(held.identity.file_kind == DSH_FLOCK_FILE_UNKNOWN && held.identity.path_error == EACCES);
    assert(held.identity.inode == (uint64_t) st.st_ino && held.identity.stat_error == 0);
    fail_path = false;
    assert(realfs_close(&file) == 0 && snapshot().active_native_flocks == 0);
    assert(last_event().kind == DSH_FLOCK_CLOSED && last_event().lock.id == held.id);
    struct fd invalid = {.mount = &mount, .real_fd = -1};
    struct dsh_lifecycle_flock_identity missing = realfs_flock_identity(&invalid);
    /* Linux readlink(/proc/self/fd/-1) reports ENOENT; Darwin F_GETPATH EBADF. */
    assert(missing.stat_error == EBADF && missing.path_error != 0 && missing.file_kind == DSH_FLOCK_FILE_UNKNOWN);
    puts("PASS missing path/stat observations do not change successful flock results or errno");

    uint64_t previous_id = held.id;
    for (unsigned i = 0; i < 100; i++) {
        file.real_fd = open(argv[1], O_RDWR);
        assert(file.real_fd >= 0 && sys_flock(7, LOCK_EX_ | LOCK_NB_) == 0);
        held = snapshot().native_flocks[0];
        assert(held.id > previous_id);
        previous_id = held.id;
        assert(realfs_close(&file) == 0 && snapshot().active_native_flocks == 0);
    }
    value = snapshot();
    assert(value.native_flock_event_count == DSH_LIFECYCLE_SNAPSHOT_ITEMS && value.tracking_overflows == 0);
    for (unsigned i = 1; i < value.native_flock_event_count; i++)
        assert(value.native_flock_events[i].sequence == value.native_flock_events[i - 1].sequence + 1);
    generation = dsh_lifecycle_request_quiesce();
    assert(dsh_lifecycle_mark_quiescent(generation));
    dsh_lifecycle_resume();
    file.real_fd = open(argv[1], O_RDWR);
    char contents[sizeof(sentinel)];
    assert(pread(file.real_fd, contents, sizeof(contents), 0) == sizeof(contents));
    assert(memcmp(contents, sentinel, sizeof(sentinel)) == 0);
    assert(sys_flock(7, LOCK_EX_ | LOCK_NB_) == 0);
    fail_close = true;
    assert(realfs_close(&file) == -EIO && errno == EIO);
    assert(snapshot().active_native_flocks == 1 && snapshot().native_close_failures == 1);
    assert(last_event().kind == DSH_FLOCK_CLOSE_FAILED && last_event().result == EIO);
    generation = dsh_lifecycle_request_quiesce();
    assert(!dsh_lifecycle_mark_quiescent(generation));
    dsh_lifecycle_resume();
    fail_close = false;
    assert(realfs_close(&file) == 0 && snapshot().active_native_flocks == 0);
    assert(last_event().kind == DSH_FLOCK_CLOSED);
    puts("PASS 100 real acquire/close cycles, bounded ordered history, data preservation and failed-close barrier");
    puts("All production flock diagnostic tests passed.");
    return 0;
}
