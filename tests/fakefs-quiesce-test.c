/* Real fakefs + SQLite + lifecycle admission. The authorizer only supplies
 * deterministic barriers; it returns SQLITE_OK and never replaces DB results. */
#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "fs/fake.c"

__thread struct task *current;
int errno_map(void) { return -errno; }
void ish_printk(const char *format, ...) { (void) format; }
_Noreturn void die(const char *format, ...) { (void) format; abort(); }
struct fd *fd_create(const struct fd_ops *ops) {
    struct fd *fd = calloc(1, sizeof(*fd));
    if (fd) { fd->ops = ops; fd->refcount = 1; }
    return fd;
}
int fd_close(struct fd *fd) { int error = close(fd->real_fd); free(fd); return error; }
int realfs_getpath(struct fd *fd, char *path) { (void) fd; path[0] = 0; return 0; }
static int no_entries(struct fd *fd, struct dir_entry *entry) { (void) fd; (void) entry; return 0; }
const struct fd_ops realfs_fdops = { .readdir = no_entries };
const struct fs_ops realfs = {0};
int realfs_statfs(struct mount *mount, struct statfsbuf *stat) { (void) mount; (void) stat; return _ENOSYS; }
int realfs_close(struct fd *fd) { return close(fd->real_fd) < 0 ? -errno : 0; }
int realfs_utime(struct mount *mount, const char *path, struct timespec a, struct timespec m) {
    (void) mount; (void) path; (void) a; (void) m; return _ENOSYS;
}
int realfs_flock(struct fd *fd, int op) { return flock(fd->real_fd, op) < 0 ? -errno : 0; }
int realfs_mknod_with_effect(struct mount *mount, const char *path, mode_t_ mode,
        dev_t_ dev, bool *host_created) {
    (void) mount; (void) path; (void) mode; (void) dev; (void) host_created;
    assert(false); // These four scenarios exercise open, never mknod.
    return _ENOSYS;
}
void inode_check_orphaned(struct mount *mount, ino_t inode) { (void) mount; (void) inode; }

enum phase { BEFORE, DURING, PRECOMMIT, CANCEL };
static enum phase test_phase;
static pthread_mutex_t control = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t changed = PTHREAD_COND_INITIALIZER;
static bool barrier_reached, barrier_release;
struct worker {
    struct mount *mount;
    const char *path;
    bool attempted, finished;
    int result;
};

static struct timespec deadline(unsigned milliseconds) {
    struct timespec end;
    assert(clock_gettime(CLOCK_REALTIME, &end) == 0);
    end.tv_sec += milliseconds / 1000;
    end.tv_nsec += (long) (milliseconds % 1000) * 1000000;
    if (end.tv_nsec >= 1000000000) { end.tv_sec++; end.tv_nsec -= 1000000000; }
    return end;
}
static bool await_flag(bool *flag, unsigned milliseconds) {
    struct timespec end = deadline(milliseconds);
    assert(pthread_mutex_lock(&control) == 0);
    int error = 0;
    while (!*flag && error == 0) error = pthread_cond_timedwait(&changed, &control, &end);
    assert(error == 0 || error == ETIMEDOUT);
    bool value = *flag;
    assert(pthread_mutex_unlock(&control) == 0);
    return value;
}
static void set_flag(bool *flag) {
    assert(pthread_mutex_lock(&control) == 0);
    *flag = true;
    assert(pthread_cond_broadcast(&changed) == 0);
    assert(pthread_mutex_unlock(&control) == 0);
}
static int authorize(void *context, int action, const char *first,
        const char *second, const char *database, const char *trigger) {
    (void) context; (void) second; (void) database; (void) trigger;
    bool at_point = (test_phase == PRECOMMIT && action == SQLITE_TRANSACTION && first && !strcmp(first, "COMMIT")) ||
        ((test_phase == DURING || test_phase == CANCEL) && action == SQLITE_READ && first && !strcmp(first, "paths"));
    if (at_point && !barrier_reached) {
        set_flag(&barrier_reached);
        assert(await_flag(&barrier_release, 5000));
    }
    return SQLITE_OK;
}
static void *create_file(void *argument) {
    struct worker *worker = argument;
    set_flag(&worker->attempted);
    struct fd *fd = fakefs_open(worker->mount, worker->path, O_CREAT_ | O_RDWR_, 0644);
    worker->result = IS_ERR(fd) ? PTR_ERR(fd) : fd_close(fd);
    dsh_lifecycle_thread_exit();
    set_flag(&worker->finished);
    return NULL;
}
static struct dsh_lifecycle_snapshot snapshot(void) {
    struct dsh_lifecycle_snapshot value;
    dsh_lifecycle_get_snapshot(&value);
    return value;
}
static void sql(sqlite3 *database, const char *text) {
    assert(sqlite3_exec(database, text, NULL, NULL, NULL) == SQLITE_OK);
}
static void fixture(struct fakefs_db *fs, const char *name) {
    sqlite3 *database = NULL;
    assert(sqlite3_open(name, &database) == SQLITE_OK);
    sql(database, "create table meta (db_inode integer); insert into meta values (0);"
        "create table stats (inode integer primary key, stat blob);"
        "create table paths (path blob primary key, inode integer references stats(inode));"
        "pragma user_version=3;");
    struct stat st;
    assert(stat(name, &st) == 0);
    sqlite3_stmt *save = NULL;
    assert(sqlite3_prepare_v2(database, "update meta set db_inode=?", -1, &save, NULL) == SQLITE_OK);
    assert(sqlite3_bind_int64(save, 1, st.st_ino) == SQLITE_OK);
    assert(sqlite3_step(save) == SQLITE_DONE);
    assert(sqlite3_finalize(save) == SQLITE_OK);
    assert(sqlite3_close(database) == SQLITE_OK);
    assert(fake_db_init(fs, name, -1) == 0);
}
static int visible_paths(sqlite3 *database) {
    sqlite3_stmt *query = NULL;
    assert(sqlite3_prepare_v2(database, "select count(*) from paths", -1, &query, NULL) == SQLITE_OK);
    assert(sqlite3_step(query) == SQLITE_ROW);
    int count = sqlite3_column_int(query, 0);
    assert(sqlite3_finalize(query) == SQLITE_OK);
    return count;
}
static bool host_exists(struct mount *mount, const char *name) {
    int result = faccessat(mount->root_fd, name, F_OK, 0);
    assert(result == 0 || errno == ENOENT);
    return result == 0;
}
static void assert_sentinel(struct mount *mount) {
    char bytes[16] = {0};
    int fd = openat(mount->root_fd, "sentinel", O_RDONLY);
    assert(fd >= 0 && read(fd, bytes, sizeof(bytes)) == 9);
    assert(close(fd) == 0 && !strcmp(bytes, "preserved"));
}
static const char *user_paths[] = {"/config.yml", "/api-key.fixture", "/session.fixture", "/workspace.fixture"};
static inode_t user_inodes[4];
static void seed_user_data(struct mount *mount) {
    for (unsigned i = 0; i < 4; i++) {
        struct fd *fd = fakefs_open(mount, user_paths[i], O_CREAT_ | O_RDWR_, 0600);
        assert(!IS_ERR(fd));
        user_inodes[i] = fd->fake_inode;
        assert(write(fd->real_fd, "synthetic-preserved", 19) == 19);
        assert(fd_close(fd) == 0);
    }
}
static void assert_user_data(struct mount *mount, sqlite3 *observer) {
    for (unsigned i = 0; i < 4; i++) {
        char bytes[32] = {0};
        int fd = openat(mount->root_fd, user_paths[i] + 1, O_RDONLY);
        assert(fd >= 0 && read(fd, bytes, sizeof(bytes)) == 19);
        assert(close(fd) == 0 && !strcmp(bytes, "synthetic-preserved"));
        sqlite3_stmt *query = NULL;
        assert(sqlite3_prepare_v2(observer,
            "select inode, stat from stats natural join paths where path=?", -1, &query, NULL) == SQLITE_OK);
        assert(sqlite3_bind_blob(query, 1, user_paths[i], (int) strlen(user_paths[i]), SQLITE_STATIC) == SQLITE_OK);
        assert(sqlite3_step(query) == SQLITE_ROW && (inode_t) sqlite3_column_int64(query, 0) == user_inodes[i]);
        assert(sqlite3_column_bytes(query, 1) == sizeof(struct ish_stat));
        struct ish_stat metadata;
        memcpy(&metadata, sqlite3_column_blob(query, 1), sizeof(metadata));
        assert(metadata.mode == (S_IFREG | 0600) && metadata.uid == 0 && metadata.gid == 0);
        assert(sqlite3_finalize(query) == SQLITE_OK);
    }
}
int main(int argc, char **argv) {
    assert(argc == 4);
    alarm(30);
    if (!strcmp(argv[1], "before")) test_phase = BEFORE;
    else if (!strcmp(argv[1], "during")) test_phase = DURING;
    else if (!strcmp(argv[1], "precommit")) test_phase = PRECOMMIT;
    else { assert(!strcmp(argv[1], "cancel")); test_phase = CANCEL; }
    struct mount mount = {0};
    fixture(&mount.fakefs, argv[2]);
    mount.root_fd = open(argv[3], O_RDONLY | O_DIRECTORY);
    assert(mount.root_fd >= 0);
    int sentinel = openat(mount.root_fd, "sentinel", O_CREAT | O_EXCL | O_WRONLY, 0600);
    assert(sentinel >= 0 && write(sentinel, "preserved", 9) == 9 && close(sentinel) == 0);
    seed_user_data(&mount);
    sqlite3 *observer = NULL;
    assert(sqlite3_open_v2(argv[2], &observer, SQLITE_OPEN_READONLY, NULL) == SQLITE_OK);
    assert(sqlite3_set_authorizer(mount.fakefs.db, authorize, NULL) == SQLITE_OK);
    dsh_lifecycle_enable_admission_gate();
    uint64_t generation = test_phase == BEFORE ? dsh_lifecycle_request_quiesce() : 0;
    struct worker original = {.mount = &mount, .path = "/primary"};
    struct worker later = {.mount = &mount, .path = "/late"};
    pthread_t original_thread, later_thread;
    assert(pthread_create(&original_thread, NULL, create_file, &original) == 0);
    assert(await_flag(&original.attempted, 5000));
    if (test_phase == BEFORE) {
        assert(!await_flag(&original.finished, 50));
        assert(snapshot().active_operations == 0 && snapshot().transaction_count == 0);
        assert(!host_exists(&mount, "primary") && visible_paths(observer) == 4);
    } else {
        assert(await_flag(&barrier_reached, 5000));
        generation = dsh_lifecycle_request_quiesce();
        struct dsh_lifecycle_snapshot value = snapshot();
        assert(value.active_operations == 1 && value.transaction_count == 1);
        assert(test_phase == PRECOMMIT ? host_exists(&mount, "primary") : !host_exists(&mount, "primary"));
        assert(visible_paths(observer) == 4); // Only the four original user rows are visible.
        assert(!dsh_lifecycle_mark_quiescent(generation));
    }
    assert(pthread_create(&later_thread, NULL, create_file, &later) == 0);
    assert(await_flag(&later.attempted, 5000) && !await_flag(&later.finished, 50));
    assert(!host_exists(&mount, "late"));
    assert(snapshot().active_operations == (test_phase == BEFORE ? 0 : 1));
    assert_sentinel(&mount);
    assert_user_data(&mount, observer);
    if (test_phase == CANCEL) {
        // Cancel quiescing while an old SQLite transaction still owns its
        // permit. It must drain in Resuming; fresh work remains parked.
        dsh_lifecycle_begin_resume();
        assert(snapshot().state == DSH_LIFECYCLE_RESUMING);
        set_flag(&barrier_release);
        assert(await_flag(&original.finished, 5000));
        assert(original.result == 0 && host_exists(&mount, "primary") && visible_paths(observer) == 5);
        assert(snapshot().active_operations == 0 && snapshot().transaction_count == 0);
        assert(!dsh_lifecycle_mark_quiescent(generation));
    } else {
        if (test_phase != BEFORE) {
            set_flag(&barrier_release);
            assert(await_flag(&original.finished, 5000));
            assert(original.result == 0 && host_exists(&mount, "primary"));
            assert(visible_paths(observer) == 5);
        }
        assert(dsh_lifecycle_mark_quiescent(generation));
        assert(snapshot().state == DSH_LIFECYCLE_QUIESCENT);
        dsh_lifecycle_begin_resume();
    }
    assert(!await_flag(&later.finished, 50));
    assert(!host_exists(&mount, "late") && snapshot().state == DSH_LIFECYCLE_RESUMING);
    if (test_phase == BEFORE) assert(!host_exists(&mount, "primary"));
    dsh_lifecycle_resume();
    assert(await_flag(&original.finished, 5000) && await_flag(&later.finished, 5000));
    assert(pthread_join(original_thread, NULL) == 0 && pthread_join(later_thread, NULL) == 0);
    assert(original.result == 0 && later.result == 0);
    assert(host_exists(&mount, "primary") && host_exists(&mount, "late"));
    assert(visible_paths(observer) == 6);
    assert_sentinel(&mount);
    assert_user_data(&mount, observer);
    struct dsh_lifecycle_snapshot value = snapshot();
    assert(value.state == DSH_LIFECYCLE_RUNNING && value.active_operations == 0 && value.transaction_count == 0);
    assert(value.recovery_blocked_connections == 0);
    assert(sqlite3_close(observer) == SQLITE_OK);
    assert(fake_db_deinit(&mount.fakefs) == SQLITE_OK && close(mount.root_fd) == 0);
    assert(snapshot().open_connections == 0);
    alarm(0);
    printf("PASS real fakefs/SQLite background %s: old transaction drains, new host effects wait, data preserved\n", argv[1]);
    return 0;
}
