#include <stdarg.h>
#include <stdio.h>
#include <limits.h>
#include <string.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/file.h>
#include <sqlite3.h>
#include <unistd.h>
#include <dirent.h>
#include <errno.h>
#include <stdatomic.h>
#if defined(__APPLE__)
#  include <os/lock.h>
#  include <dispatch/dispatch.h>
#  include <mach/mach_time.h>
#  include <Block.h>
#endif
#include "util/signpost.h"

#include "fs/dsh-lifecycle.h"
#include "debug.h"
#include "kernel/errno.h"
#include "kernel/task.h"
#include "fs/fd.h"
#include "fs/dev.h"
#include "fs/inode.h"
#include "fs/real.h"
#define ISH_INTERNAL
#include "fs/fake.h"

// TODO document database

/* ===== Bind Mount Support =====
 * Allows redirecting fakefs paths to external host directories via symlinks.
 * Files under bind-mounted paths get auto-created meta.db entries on access.
 * This avoids the need to copy files into the fakefs data/ directory. */

#define FAKEFS_MAX_BIND_MOUNTS 32

/* Compute a relative symlink target from link_dir to abs_target.
 * link_dir is the absolute path of the directory containing the symlink.
 * abs_target is the absolute path the symlink should point to.
 * Result is written to out (must be PATH_MAX). Returns 0 on success. */
static int compute_relative_path(const char *link_dir, const char *abs_target,
                                  char *out, size_t out_size) {
    /* Find common prefix (up to the last shared '/') */
    size_t common = 0;
    size_t last_slash = 0;
    for (size_t i = 0; link_dir[i] && abs_target[i]; i++) {
        if (link_dir[i] != abs_target[i])
            break;
        common = i + 1;
        if (link_dir[i] == '/')
            last_slash = common;
    }
    /* If both ended at common, check for trailing slash boundary */
    if (link_dir[common] == '\0' && abs_target[common] == '/') {
        last_slash = common;
    } else if (abs_target[common] == '\0' && link_dir[common] == '/') {
        last_slash = common;
    } else {
        common = last_slash;
    }

    /* Count remaining '/' in link_dir after common prefix => number of "../" */
    int ups = 0;
    for (const char *p = link_dir + common; *p; p++) {
        if (*p == '/')
            ups++;
    }
    /* If link_dir doesn't end with '/', the last component is the dir name */
    size_t ld_len = strlen(link_dir);
    if (ld_len > 0 && link_dir[ld_len - 1] != '/')
        ups++;

    out[0] = '\0';
    for (int i = 0; i < ups; i++) {
        if (i == 0)
            strlcpy(out, "..", out_size);
        else
            strlcat(out, "/..", out_size);
    }

    /* Append the remainder of abs_target after common prefix */
    const char *suffix = abs_target + common;
    if (*suffix == '/') suffix++; /* skip leading slash */
    if (*suffix) {
        if (ups > 0) strlcat(out, "/", out_size);
        strlcat(out, suffix, out_size);
    }

    if (out[0] == '\0') {
        strlcpy(out, ".", out_size);
    }

    return 0;
}

struct fakefs_bind_mount {
    char path[PATH_MAX];      /* Linux path prefix, e.g. "/var/minis/offloads" */
    char host_path[PATH_MAX]; /* Resolved host path the symlink points to */
    int  path_len;
    int  host_path_len;
    bool active;
    bool read_only;           /* Reject write syscalls with EROFS at fakefs layer. */
};

static struct fakefs_bind_mount g_bind_mounts[FAKEFS_MAX_BIND_MOUNTS];
struct mount *g_fakefs_mount = NULL;

/* Optional host-provided override hooks for guest↔host path translation.
 * NULL unless host registers via fakefs_set_path_*_hook(). Defined here
 * (before resolve_path() / bind_mount_translate_path() so both directions
 * can consult them). */
static _Atomic(fakefs_path_translate_hook_t) g_path_translate_hook = NULL;
static _Atomic(fakefs_path_reverse_hook_t) g_path_reverse_hook = NULL;

void fakefs_set_path_translate_hook(fakefs_path_translate_hook_t hook) {
    atomic_store_explicit(&g_path_translate_hook, hook, memory_order_release);
}

void fakefs_set_path_reverse_hook(fakefs_path_reverse_hook_t hook) {
    atomic_store_explicit(&g_path_reverse_hook, hook, memory_order_release);
}

/* Absolute host path of the fakefs `data/` directory, registered by the
 * host via fakefs_set_rootfs_data_path() at boot. Used to detect
 * "self-containing" bind mounts in fakefs_bind_mount_resolve_path() —
 * a mount whose host_path is an ancestor of g_rootfs_data_path would
 * cause every rootfs-internal fd to be reverse-mapped under that mount,
 * which is never what the caller wants. Empty string means "no rootfs
 * path registered" (suppression is disabled). */
static char g_rootfs_data_path[PATH_MAX] = {0};
static int g_rootfs_data_path_len = 0;

void fakefs_set_rootfs_data_path(const char *abs_host_path) {
    if (abs_host_path == NULL || abs_host_path[0] == '\0') {
        g_rootfs_data_path[0] = '\0';
        g_rootfs_data_path_len = 0;
        fprintf(stderr, "fakefs: rootfs_data_path cleared\n");
        return;
    }
    /* Strip any trailing slash so prefix arithmetic below works uniformly:
     * the ancestor check compares host_path[hlen] against '/' to enforce
     * a path-component boundary, which fails if g_rootfs_data_path itself
     * ends in '/' (it generally won't, but be defensive). */
    size_t n = strlen(abs_host_path);
    while (n > 1 && abs_host_path[n - 1] == '/') n--;
    if (n + 1 > sizeof(g_rootfs_data_path)) {
        fprintf(stderr,
                "fakefs: rootfs_data_path too long (%zu chars, max %zu) — ignored\n",
                n, sizeof(g_rootfs_data_path) - 1);
        return;
    }
    memcpy(g_rootfs_data_path, abs_host_path, n);
    g_rootfs_data_path[n] = '\0';
    g_rootfs_data_path_len = (int)n;
    fprintf(stderr, "fakefs: rootfs_data_path registered \"%s\" (len=%d)\n",
            g_rootfs_data_path, g_rootfs_data_path_len);
}

/* True if `host_path` is an ancestor of (or equal to) the registered
 * fakefs data directory. Returns false when no rootfs path is
 * registered, so the guard is a no-op until the host opts in. */
static bool fakefs_host_path_contains_rootfs(const char *host_path, int host_path_len) {
    if (g_rootfs_data_path_len == 0)
        return false;
    if (host_path_len > g_rootfs_data_path_len)
        return false;
    if (strncmp(host_path, g_rootfs_data_path, host_path_len) != 0)
        return false;
    /* Either exact match, or g_rootfs_data_path has a '/' immediately
     * after the host_path prefix (proper ancestor). Anything else is a
     * sibling-prefix false positive (e.g. /Users/x vs /Users/xyz). */
    char next = g_rootfs_data_path[host_path_len];
    return next == '/' || next == '\0';
}

/* Translate a resolved host path back to a Linux path for bind mounts.
 * e.g. "/Users/.../MinisChat/minis/<sid>/attachments/file.mp4"
 *   -> "/var/minis/attachments/file.mp4"
 * Returns true and writes to out_path if a match was found.
 *
 * Mounts whose host_path is an ancestor of the registered fakefs
 * `data/` directory are skipped — a "self-containing" mount would
 * otherwise reverse-map every rootfs-internal fd to a guest path under
 * itself, which corrupts execve / fakefs metadata lookups. The
 * suppression is no-op until fakefs_set_rootfs_data_path() is called by
 * the host. */
bool fakefs_bind_mount_resolve_path(const char *resolved, char *out_path, size_t out_size) {
    for (int i = 0; i < FAKEFS_MAX_BIND_MOUNTS; i++) {
        if (!g_bind_mounts[i].active)
            continue;
        int hlen = g_bind_mounts[i].host_path_len;
        /* Skip mounts that contain the rootfs — reverse-mapping a
         * host path inside the fakefs `data/` directory through a
         * mount whose host_path encloses it yields a bogus guest
         * path that breaks execve / metadata lookups. */
        if (fakefs_host_path_contains_rootfs(g_bind_mounts[i].host_path, hlen)) {
            /* Only log once per process per mount slot — otherwise the hot
             * path floods the log on every execve. */
            static bool warned[FAKEFS_MAX_BIND_MOUNTS] = {false};
            if (!warned[i]) {
                warned[i] = true;
                fprintf(stderr,
                        "fakefs_bind_mount_resolve_path: skipping self-containing mount slot[%d] "
                        "host=\"%s\" (ancestor of rootfs data \"%s\") — "
                        "every rootfs fd would otherwise reverse-map into this mount\n",
                        i, g_bind_mounts[i].host_path, g_rootfs_data_path);
            }
            continue;
        }
        /* Try matching as-is first */
        if (strncmp(resolved, g_bind_mounts[i].host_path, hlen) == 0 &&
            (resolved[hlen] == '/' || resolved[hlen] == '\0')) {
            snprintf(out_path, out_size, "%s%s",
                     g_bind_mounts[i].path, resolved + hlen);
            return true;
        }
        /* F_GETPATH resolves /var -> /private/var on iOS.
         * If host_path starts with /var/ but resolved starts with /private/var/,
         * try matching with the /private prefix stripped from resolved. */
        if (strncmp(g_bind_mounts[i].host_path, "/var/", 5) == 0 &&
            strncmp(resolved, "/private/var/", 13) == 0) {
            const char *resolved_no_private = resolved + 8; /* skip "/private" */
            if (strncmp(resolved_no_private, g_bind_mounts[i].host_path, hlen) == 0 &&
                (resolved_no_private[hlen] == '/' || resolved_no_private[hlen] == '\0')) {
                snprintf(out_path, out_size, "%s%s",
                         g_bind_mounts[i].path, resolved_no_private + hlen);
                return true;
            }
        }
    }
    /* Static table miss — fall through to the host-provided reverse hook
     * if one is registered. The hook knows about per-context routes that
     * are not in g_bind_mounts[]. */
    fakefs_path_reverse_hook_t reverse =
        atomic_load_explicit(&g_path_reverse_hook, memory_order_acquire);
    if (reverse != NULL && reverse(resolved, out_path, out_size))
        return true;
    return false;
}

/* Translate a Linux path to a host absolute path if under a bind mount.
 * Handles both leading-slash and no-leading-slash forms.
 * Returns true and writes to out_path if the path is under a bind mount. */
/* Public wrapper for native offload handlers. See fake.h. */
bool fakefs_bind_mount_translate_path(const char *path, char *out_path, size_t out_size);

/* Internal variant exposes whether the match came from the per-context
 * translate hook vs. the static g_bind_mounts[] table. Callers that mutate
 * meta.db need to know — hook-routed paths must NOT be stored in meta.db,
 * since the `paths` table is keyed by guest path globally, while the hook
 * can map the same guest path to different host files per fs_context. */
static bool bind_mount_translate_path_ex(const char *path, char *out_path,
                                         size_t out_size, bool *out_via_hook) {
    if (out_via_hook != NULL) *out_via_hook = false;
    /* Normalize: if path lacks leading /, prepend it for comparison.
     * Bind mount table always stores paths with leading /. */
    char normalized[MAX_PATH];
    const char *cmp_path = path;
    if (path[0] != '/') {
        snprintf(normalized, sizeof(normalized), "/%s", path);
        cmp_path = normalized;
    }
    /* Host-provided hook wins over the static table. The hook sees the
     * normalized (leading-slash) path and the calling task's fs_context. */
    fakefs_path_translate_hook_t hook =
        atomic_load_explicit(&g_path_translate_hook, memory_order_acquire);
    if (hook != NULL) {
        uint64_t ctx = 0;
        if (current != NULL && current->group != NULL)
            ctx = current->group->fs_context;
        if (hook(cmp_path, ctx, out_path, out_size)) {
            if (out_via_hook != NULL) *out_via_hook = true;
            return true;
        }
    }
    for (int i = 0; i < FAKEFS_MAX_BIND_MOUNTS; i++) {
        if (!g_bind_mounts[i].active)
            continue;
        int len = g_bind_mounts[i].path_len;
        if (strncmp(g_bind_mounts[i].path, cmp_path, len) == 0 &&
            (cmp_path[len] == '/' || cmp_path[len] == '\0')) {
            snprintf(out_path, out_size, "%s%s",
                     g_bind_mounts[i].host_path, cmp_path + len);
            return true;
        }
    }
    return false;
}

static bool bind_mount_translate_path(const char *path, char *out_path, size_t out_size) {
    return bind_mount_translate_path_ex(path, out_path, out_size, NULL);
}

/* Check if a path is at or under a bind mount prefix.
 * Handles both "/var/minis/..." and "var/minis/..." (without leading /). */
static bool is_under_bind_mount(const char *path) {
    char normalized[MAX_PATH];
    const char *cmp_path = path;
    if (path[0] != '/') {
        snprintf(normalized, sizeof(normalized), "/%s", path);
        cmp_path = normalized;
    }
    for (int i = 0; i < FAKEFS_MAX_BIND_MOUNTS; i++) {
        if (!g_bind_mounts[i].active)
            continue;
        int len = g_bind_mounts[i].path_len;
        if (strncmp(g_bind_mounts[i].path, cmp_path, len) == 0 &&
            (cmp_path[len] == '/' || cmp_path[len] == '\0'))
            return true;
    }
    return false;
}

/* Return true if `path` is at or under a bind mount that was registered
 * with read_only=true. Used by the fakefs write entry points to reject
 * modifications with EROFS. Root bypasses the DAC access_check path, so
 * relying on the meta.db 0555 mode bits alone is insufficient — we enforce
 * it here instead. */
static bool is_under_readonly_bind_mount(const char *path) {
    char normalized[MAX_PATH];
    const char *cmp_path = path;
    if (path[0] != '/') {
        snprintf(normalized, sizeof(normalized), "/%s", path);
        cmp_path = normalized;
    }
    for (int i = 0; i < FAKEFS_MAX_BIND_MOUNTS; i++) {
        if (!g_bind_mounts[i].active || !g_bind_mounts[i].read_only)
            continue;
        int len = g_bind_mounts[i].path_len;
        if (strncmp(g_bind_mounts[i].path, cmp_path, len) == 0 &&
            (cmp_path[len] == '/' || cmp_path[len] == '\0'))
            return true;
    }
    return false;
}

/* ROLLBACK only reverts SQLite. Complete metadata before changing host files. */
static int fakefs_sql_errno(int rc) {
    switch (rc & 0xff) {
        case SQLITE_BUSY: case SQLITE_LOCKED: return _EBUSY;
        case SQLITE_NOMEM: return _ENOMEM;
        case SQLITE_FULL: return _ENOSPC;
        case SQLITE_READONLY: return _EROFS;
        default: return _EIO;
    }
}
static int fakefs_abort(struct fakefs_db *fs, int error) {
    return db_rollback(fs) == SQLITE_OK ? error : _EIO;
}
static int fakefs_metadata_ready(struct fakefs_db *fs) {
    int rc = db_transaction_error(fs);
    return rc == SQLITE_OK ? 0 : fakefs_abort(fs, fakefs_sql_errno(rc));
}
static int fakefs_finish(struct fakefs_db *fs, bool host_changed) {
    int rc = db_commit(fs);
    if (rc == SQLITE_OK) return 0;
    if (!host_changed) return fakefs_abort(fs, fakefs_sql_errno(rc));
    /* Keep the transaction and evidence; SQL rollback cannot undo APFS effects. */
    db_require_recovery(fs, rc);
    return _EIO;
}

/* The caller owns a write transaction. This probes the host but never mutates it. */
static inode_t bind_mount_ensure_inode_locked(struct fakefs_db *fs, struct mount *mount,
                                             const char *path) {
    inode_t ino = path_get_inode(fs, path);
    if (ino || db_transaction_error(fs) != SQLITE_OK) return ino;
    struct stat st;
    char host[PATH_MAX];
    if (bind_mount_translate_path(path, host, sizeof(host))) {
        if (stat(host, &st) < 0) return 0;
    } else if (fstatat(mount->root_fd, fix_path(path), &st, AT_SYMLINK_NOFOLLOW) < 0) {
        if (fstatat(mount->root_fd, fix_path(path), &st, 0) < 0) return 0;
    }
    struct ish_stat metadata = { .mode = S_ISDIR(st.st_mode) ? S_IFDIR | 0755 :
        S_ISLNK(st.st_mode) ? S_IFLNK | 0777 : S_IFREG | 0644, .uid = 0, .gid = 0, .rdev = 0 };
    return path_create(fs, path, &metadata);
}
static int bind_mount_ensure_inode(struct fakefs_db *fs, struct mount *mount,
                                   const char *path, inode_t *out) {
    int rc = db_begin_write(fs);
    if (rc != SQLITE_OK) return fakefs_sql_errno(rc);
    *out = bind_mount_ensure_inode_locked(fs, mount, path);
    int error = fakefs_metadata_ready(fs);
    return error < 0 ? error : fakefs_finish(fs, false);
}

static int fakefs_host_open_flags(int flags) {
    int out = 0;
    if (flags & O_WRONLY_) out |= O_WRONLY;
    if (flags & O_RDWR_) out |= O_RDWR;
    if (flags & O_CREAT_) out |= O_CREAT;
    if (flags & O_EXCL_) out |= O_EXCL;
    if (flags & O_TRUNC_) out |= O_TRUNC;
    if (flags & O_APPEND_) out |= O_APPEND;
    if (flags & O_NONBLOCK_) out |= O_NONBLOCK;
    return out;
}

static struct fd_ops fakefs_fdops;
static struct fd *fakefs_open(struct mount *mount, const char *path, int flags, int mode) {
    DSH_LIFECYCLE_SCOPE(current ? current->pid : -1);
    struct fakefs_db *fs = &mount->fakefs;
    if (fakefs_db_recovery_required(fs)) return ERR_PTR(_EIO);
    if ((flags & (O_WRONLY_ | O_RDWR_ | O_CREAT_ | O_TRUNC_ | O_APPEND_)) &&
            is_under_readonly_bind_mount(path)) return ERR_PTR(_EROFS);
    char host[PATH_MAX];
    bool via_hook = false;
    bool via_bind = bind_mount_translate_path_ex(path, host, sizeof(host), &via_hook);
    inode_t inode = 0;
    if (!via_hook) {
        int rc = db_begin_write(fs);
        if (rc != SQLITE_OK) return ERR_PTR(fakefs_sql_errno(rc));
        inode = path_get_inode(fs, path);
        if (!inode && (flags & O_CREAT_) && db_transaction_error(fs) == SQLITE_OK) {
            struct ish_stat metadata = { .mode = mode | S_IFREG, .uid = current ? current->euid : 0,
                .gid = current ? current->egid : 0, .rdev = 0 };
            inode = path_create(fs, path, &metadata);
        } else if (!inode && via_bind && db_transaction_error(fs) == SQLITE_OK)
            inode = bind_mount_ensure_inode_locked(fs, mount, path);
        int error = fakefs_metadata_ready(fs);
        if (error < 0) return ERR_PTR(error);
        if (!inode) return ERR_PTR(fakefs_abort(fs, _ENOENT));
    }
    /* Allocate before O_CREAT/O_TRUNC; allocation failure must not change data. */
    struct fd *fd = fd_create(&realfs_fdops);
    if (!fd) return ERR_PTR(via_hook ? _ENOMEM : fakefs_abort(fs, _ENOMEM));
    int real_flags = fakefs_host_open_flags(flags);
    int hostfd = via_bind ? open(host, real_flags, 0666) :
        openat(mount->root_fd, fix_path(path), real_flags, 0666);
    if (hostfd < 0) {
        int error = errno_map();
        free(fd);
        return ERR_PTR(via_hook ? error : fakefs_abort(fs, error));
    }
    fd->real_fd = hostfd;
    fd->dir = NULL;
    if (via_hook) {
        struct stat st;
        fd->fake_inode = fstat(hostfd, &st) == 0 ? (ino_t) st.st_ino : 1;
    } else {
        int error = fakefs_finish(fs, (flags & (O_CREAT_ | O_TRUNC_)) != 0);
        if (error < 0) { fd_close(fd); return ERR_PTR(error); }
        fd->fake_inode = inode;
        fd->ops = &fakefs_fdops;
    }
    if (flags & (O_CREAT_ | O_TRUNC_ | O_WRONLY_ | O_RDWR_ | O_APPEND_))
        fakefs_record_change(path, FAKEFS_CHANGE_OP_WRITE);
    return fd;
}

struct fd *fakefs_open_inode(struct mount *mount, ino_t inode) {
    DSH_LIFECYCLE_SCOPE(current ? current->pid : -1);
    struct fakefs_db *fs = &mount->fakefs;
    int rc = db_begin_read(fs);
    if (rc != SQLITE_OK) return ERR_PTR(fakefs_sql_errno(rc));
    sqlite3_stmt *stmt = fs->stmt.path_from_inode;
    if (sqlite3_bind_int64(stmt, 1, inode) != SQLITE_OK) return ERR_PTR(fakefs_abort(fs, _EIO));
    struct fd *fd = ERR_PTR(_ENOENT);
    while ((rc = db_exec(fs, stmt)) == SQLITE_ROW) {
        const char *path = (const char *) sqlite3_column_text(stmt, 0);
        fd = realfs.open(mount, path, O_RDWR_, 0);
        if (PTR_ERR(fd) == _EISDIR) fd = realfs.open(mount, path, O_RDONLY_, 0);
        if (PTR_ERR(fd) != _ENOENT) break;
    }
    db_reset(fs, stmt);
    int error = fakefs_metadata_ready(fs);
    if (error == 0) error = fakefs_finish(fs, false);
    if (error < 0) { if (!IS_ERR(fd)) fd_close(fd); return ERR_PTR(error); }
    if (IS_ERR(fd)) return fd;
    fd->fake_inode = inode;
    fd->ops = &fakefs_fdops;
    return fd;
}

static int fakefs_link(struct mount *mount, const char *src, const char *dst) {
    DSH_LIFECYCLE_SCOPE(current ? current->pid : -1);
    struct fakefs_db *fs = &mount->fakefs;
    if (fakefs_db_recovery_required(fs)) return _EIO;
    if (is_under_readonly_bind_mount(dst)) return _EROFS;
    char hs[PATH_MAX], hd[PATH_MAX];
    bool sh = false, dh = false;
    bool sb = bind_mount_translate_path_ex(src, hs, sizeof(hs), &sh);
    bool db = bind_mount_translate_path_ex(dst, hd, sizeof(hd), &dh);
    if (sh != dh || sb != db) return _EXDEV;
    if (sh) {
        if (link(hs, hd) < 0) return errno_map();
        fakefs_record_change(dst, FAKEFS_CHANGE_OP_WRITE);
        return 0;
    }
    int rc = db_begin_write(fs);
    if (rc != SQLITE_OK) return fakefs_sql_errno(rc);
    if (sb) bind_mount_ensure_inode_locked(fs, mount, src);
    path_link(fs, src, dst);
    int error = fakefs_metadata_ready(fs);
    if (error < 0) return error;
    error = sb ? (link(hs, hd) < 0 ? errno_map() : 0) : realfs.link(mount, src, dst);
    if (error < 0) return fakefs_abort(fs, error);
    error = fakefs_finish(fs, true);
    if (error == 0 && sb) fakefs_record_change(dst, FAKEFS_CHANGE_OP_WRITE);
    return error;
}

static int fakefs_remove(struct mount *mount, const char *path, bool directory) {
    struct fakefs_db *fs = &mount->fakefs;
    if (fakefs_db_recovery_required(fs)) return _EIO;
    if (is_under_readonly_bind_mount(path)) return _EROFS;
    char host[PATH_MAX];
    bool hook = false;
    bool bind = bind_mount_translate_path_ex(path, host, sizeof(host), &hook);
    if (hook) {
        if ((directory ? rmdir(host) : unlink(host)) < 0) return errno_map();
        fakefs_record_change(path, FAKEFS_CHANGE_OP_UNLINK);
        return 0;
    }
    int rc = db_begin_write(fs);
    if (rc != SQLITE_OK) return fakefs_sql_errno(rc);
    if (bind) bind_mount_ensure_inode_locked(fs, mount, path);
    inode_t inode = path_unlink(fs, path);
    int error = fakefs_metadata_ready(fs);
    if (error < 0) return error;
    if (bind) error = (directory ? rmdir(host) : unlink(host)) < 0 ? errno_map() : 0;
    else error = directory ? realfs.rmdir(mount, path) : realfs.unlink(mount, path);
    if (error < 0) return fakefs_abort(fs, error);
    error = fakefs_finish(fs, true);
    if (error < 0) return error;
    if (bind) fakefs_record_change(path, FAKEFS_CHANGE_OP_UNLINK);
    if (inode) inode_check_orphaned(mount, inode);
    return 0;
}
static int fakefs_unlink(struct mount *mount, const char *path) {
    DSH_LIFECYCLE_SCOPE(current ? current->pid : -1);
    return fakefs_remove(mount, path, false);
}
static int fakefs_rmdir(struct mount *mount, const char *path) {
    DSH_LIFECYCLE_SCOPE(current ? current->pid : -1);
    return fakefs_remove(mount, path, true);
}

static int fakefs_rename(struct mount *mount, const char *src, const char *dst) {
    DSH_LIFECYCLE_SCOPE(current ? current->pid : -1);
    struct fakefs_db *fs = &mount->fakefs;
    if (fakefs_db_recovery_required(fs)) return _EIO;
    if (is_under_readonly_bind_mount(src) || is_under_readonly_bind_mount(dst)) return _EROFS;
    char hs[PATH_MAX], hd[PATH_MAX];
    bool sh = false, dh = false;
    bool sb = bind_mount_translate_path_ex(src, hs, sizeof(hs), &sh);
    bool db = bind_mount_translate_path_ex(dst, hd, sizeof(hd), &dh);
    if (sb != db || sh != dh) return _EXDEV;
    if (sh) {
        if (rename(hs, hd) < 0) return errno_map();
        fakefs_record_change(dst, FAKEFS_CHANGE_OP_RENAME);
        return 0;
    }
    int rc = db_begin_write(fs);
    if (rc != SQLITE_OK) return fakefs_sql_errno(rc);
    if (sb) bind_mount_ensure_inode_locked(fs, mount, src);
    path_rename(fs, src, dst);
    int error = fakefs_metadata_ready(fs);
    if (error < 0) return error;
    error = sb ? (rename(hs, hd) < 0 ? errno_map() : 0) : realfs.rename(mount, src, dst);
    if (error < 0) return fakefs_abort(fs, error);
    error = fakefs_finish(fs, true);
    if (error == 0 && sb) fakefs_record_change(dst, FAKEFS_CHANGE_OP_RENAME);
    return error;
}

static int fakefs_symlink(struct mount *mount, const char *target, const char *link) {
    DSH_LIFECYCLE_SCOPE(current ? current->pid : -1);
    struct fakefs_db *fs = &mount->fakefs;
    if (fakefs_db_recovery_required(fs)) return _EIO;
    if (is_under_readonly_bind_mount(link)) return _EROFS;
    char host[PATH_MAX]; bool hook = false;
    if (bind_mount_translate_path_ex(link, host, sizeof(host), &hook) && hook) return _EPERM;
    int rc = db_begin_write(fs);
    if (rc != SQLITE_OK) return fakefs_sql_errno(rc);
    struct ish_stat metadata = { .mode = S_IFLNK | 0777, .uid = current ? current->euid : 0,
        .gid = current ? current->egid : 0, .rdev = 0 };
    path_create(fs, link, &metadata);
    int error = fakefs_metadata_ready(fs);
    if (error < 0) return error;
    int fd = openat(mount->root_fd, fix_path(link), O_WRONLY | O_CREAT | O_EXCL, 0666);
    if (fd < 0) return fakefs_abort(fs, errno_map());
    size_t length = strlen(target), written = 0;
    while (written < length) {
        ssize_t count = write(fd, target + written, length - written);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { error = count < 0 ? errno_map() : _EIO; break; }
        written += count;
    }
    if (close(fd) < 0 && error == 0) error = errno_map();
    if (error < 0) {
        /* Only undo the file this O_EXCL created; failed cleanup remains blocked. */
        if (unlinkat(mount->root_fd, fix_path(link), 0) == 0) return fakefs_abort(fs, error);
        db_require_recovery(fs, SQLITE_IOERR);
        return _EIO;
    }
    return fakefs_finish(fs, true);
}

static int fakefs_mknod(struct mount *mount, const char *path, mode_t_ mode, dev_t_ dev) {
    DSH_LIFECYCLE_SCOPE(current ? current->pid : -1);
    struct fakefs_db *fs = &mount->fakefs;
    if (fakefs_db_recovery_required(fs)) return _EIO;
    if (is_under_readonly_bind_mount(path)) return _EROFS;
    int rc = db_begin_write(fs);
    if (rc != SQLITE_OK) return fakefs_sql_errno(rc);
    struct ish_stat metadata = { .mode = mode, .uid = current ? current->euid : 0,
        .gid = current ? current->egid : 0, .rdev = (S_ISBLK(mode) || S_ISCHR(mode)) ? dev : 0 };
    if (!path_get_inode(fs, path) && db_transaction_error(fs) == SQLITE_OK) path_create(fs, path, &metadata);
    int error = fakefs_metadata_ready(fs);
    if (error < 0) return error;
    mode_t_ real_mode = 0666 | ((S_ISBLK(mode) || S_ISCHR(mode) || S_ISSOCK(mode)) ? S_IFREG : mode & S_IFMT);
    bool host_created = false;
    error = realfs_mknod_with_effect(mount, path, real_mode, 0, &host_created);
    if (error < 0 && host_created) {
        // The O_EXCL file already exists. A failed close cannot justify SQL
        // rollback or deleting it; preserve the transaction and recovery state.
        db_require_recovery(fs, SQLITE_IOERR);
        return _EIO;
    }
    if (error < 0 && error != _EEXIST) return fakefs_abort(fs, error);
    return fakefs_finish(fs, host_created);
}

static void fakefs_copy_host_stat(struct statbuf *out, const struct stat *in) {
    memset(out, 0, sizeof(*out));
    out->inode = in->st_ino; out->mode = in->st_mode; out->nlink = in->st_nlink;
    out->size = in->st_size; out->blocks = in->st_blocks; out->blksize = in->st_blksize;
    out->atime = in->st_atime; out->mtime = in->st_mtime; out->ctime = in->st_ctime;
#if defined(__APPLE__)
    out->atime_nsec = in->st_atimespec.tv_nsec; out->mtime_nsec = in->st_mtimespec.tv_nsec;
    out->ctime_nsec = in->st_ctimespec.tv_nsec;
#elif defined(__linux__)
    out->atime_nsec = in->st_atim.tv_nsec; out->mtime_nsec = in->st_mtim.tv_nsec;
    out->ctime_nsec = in->st_ctim.tv_nsec;
#endif
}
static int fakefs_stat(struct mount *mount, const char *path, struct statbuf *out) {
    DSH_LIFECYCLE_SCOPE(current ? current->pid : -1);
    struct fakefs_db *fs = &mount->fakefs;
    if (fakefs_db_recovery_required(fs)) return _EIO;
    char host[PATH_MAX]; bool hook = false;
    bool bind = bind_mount_translate_path_ex(path, host, sizeof(host), &hook);
    if (hook) {
        struct stat st;
        if (stat(host, &st) < 0) return errno_map();
        fakefs_copy_host_stat(out, &st);
        out->mode = (st.st_mode & S_IFMT) | (S_ISDIR(st.st_mode) ? 0755 : 0644);
        return 0;
    }
    bool ensured = false;
lookup: ;
    int rc = db_begin_read(fs);
    if (rc != SQLITE_OK) return fakefs_sql_errno(rc);
    struct ish_stat metadata; inode_t inode;
    bool exists = path_read_stat(fs, path, &metadata, &inode);
    int error = fakefs_metadata_ready(fs);
    if (error < 0) return error;
    if (!exists) {
        error = fakefs_abort(fs, _ENOENT);
        if (error != _ENOENT || !bind || ensured) return error;
        inode_t found;
        error = bind_mount_ensure_inode(fs, mount, path, &found);
        if (error < 0) return error;
        if (!found) return _ENOENT;
        ensured = true;
        goto lookup;
    }
    if (bind) {
        struct stat st;
        error = stat(host, &st) < 0 ? errno_map() : 0;
        if (error == 0) fakefs_copy_host_stat(out, &st);
    } else error = realfs.stat(mount, path, out);
    if (error < 0) return fakefs_abort(fs, error);
    error = fakefs_finish(fs, false);
    if (error < 0) return error;
    out->inode = inode; out->mode = metadata.mode;
    out->uid = metadata.uid; out->gid = metadata.gid; out->rdev = metadata.rdev;
    return 0;
}
static int fakefs_fstat(struct fd *fd, struct statbuf *out) {
    DSH_LIFECYCLE_SCOPE(current ? current->pid : -1);
    struct fakefs_db *fs = &fd->mount->fakefs;
    if (fakefs_db_recovery_required(fs)) return _EIO;
    int error = realfs.fstat(fd, out);
    if (error < 0) return error;
    int rc = db_begin_read(fs);
    if (rc != SQLITE_OK) return fakefs_sql_errno(rc);
    struct ish_stat metadata;
    bool exists = inode_read_stat_if_exist(fs, fd->fake_inode, &metadata);
    error = fakefs_metadata_ready(fs);
    if (error == 0) error = fakefs_finish(fs, false);
    if (error < 0) return error;
    if (!exists) {
        char path[MAX_PATH], host[PATH_MAX]; bool hook = false;
        if (realfs_getpath(fd, path) == 0 &&
                bind_mount_translate_path_ex(path, host, sizeof(host), &hook) && hook) {
            out->mode = (out->mode & S_IFMT) | (S_ISDIR(out->mode) ? 0755 : 0644);
            out->uid = out->gid = out->rdev = 0;
            return 0;
        }
        return _ENOENT;
    }
    out->inode = fd->fake_inode; out->mode = metadata.mode;
    out->uid = metadata.uid; out->gid = metadata.gid; out->rdev = metadata.rdev;
    return 0;
}

static void fake_stat_setattr(struct ish_stat *ishstat, struct attr attr) {
    switch (attr.type) {
        case attr_uid:
            ishstat->uid = attr.uid;
            break;
        case attr_gid:
            ishstat->gid = attr.gid;
            break;
        case attr_mode:
            ishstat->mode = (ishstat->mode & S_IFMT) | (attr.mode & ~S_IFMT);
            break;
        case attr_size:
            die("attr_size should be handled by realfs");
    }
}

static int fakefs_setattr(struct mount *mount, const char *path, struct attr attr) {
    DSH_LIFECYCLE_SCOPE(current ? current->pid : -1);
    struct fakefs_db *fs = &mount->fakefs;
    if (fakefs_db_recovery_required(fs)) return _EIO;
    if (is_under_readonly_bind_mount(path)) return _EROFS;
    char host[PATH_MAX]; bool hook = false;
    bool bind = bind_mount_translate_path_ex(path, host, sizeof(host), &hook);
    if (hook) {
        if (attr.type == attr_size) return truncate(host, attr.size) < 0 ? errno_map() : 0;
        if (attr.type == attr_mode) return chmod(host, attr.mode) < 0 ? errno_map() : 0;
        return 0;
    }
    if (attr.type == attr_size) return realfs.setattr(mount, path, attr);
    int rc = db_begin_write(fs);
    if (rc != SQLITE_OK) return fakefs_sql_errno(rc);
    if (bind) bind_mount_ensure_inode_locked(fs, mount, path);
    struct ish_stat metadata; inode_t inode;
    bool exists = path_read_stat(fs, path, &metadata, &inode);
    int error = fakefs_metadata_ready(fs);
    if (error < 0) return error;
    if (!exists) return fakefs_abort(fs, _ENOENT);
    fake_stat_setattr(&metadata, attr);
    inode_write_stat(fs, inode, &metadata);
    error = fakefs_metadata_ready(fs);
    return error < 0 ? error : fakefs_finish(fs, false);
}
static int fakefs_fsetattr(struct fd *fd, struct attr attr) {
    DSH_LIFECYCLE_SCOPE(current ? current->pid : -1);
    struct fakefs_db *fs = &fd->mount->fakefs;
    if (fakefs_db_recovery_required(fs)) return _EIO;
    if (attr.type == attr_size) return realfs.fsetattr(fd, attr);
    int rc = db_begin_write(fs);
    if (rc != SQLITE_OK) return fakefs_sql_errno(rc);
    struct ish_stat metadata;
    bool exists = inode_read_stat_if_exist(fs, fd->fake_inode, &metadata);
    int error = fakefs_metadata_ready(fs);
    if (error < 0) return error;
    if (exists) {
        fake_stat_setattr(&metadata, attr);
        inode_write_stat(fs, fd->fake_inode, &metadata);
        error = fakefs_metadata_ready(fs);
        return error < 0 ? error : fakefs_finish(fs, false);
    }
    error = fakefs_finish(fs, false);
    if (error < 0) return error;
    char path[MAX_PATH], host[PATH_MAX]; bool hook = false;
    if (realfs_getpath(fd, path) != 0 ||
            !bind_mount_translate_path_ex(path, host, sizeof(host), &hook) || !hook) return _ENOENT;
    return attr.type == attr_mode && fchmod(fd->real_fd, attr.mode) < 0 ? errno_map() : 0;
}
static int fakefs_mkdir(struct mount *mount, const char *path, mode_t_ mode) {
    DSH_LIFECYCLE_SCOPE(current ? current->pid : -1);
    struct fakefs_db *fs = &mount->fakefs;
    if (fakefs_db_recovery_required(fs)) return _EIO;
    if (is_under_readonly_bind_mount(path)) return _EROFS;
    char host[PATH_MAX]; bool hook = false;
    bool bind = bind_mount_translate_path_ex(path, host, sizeof(host), &hook);
    if (hook) {
        if (mkdir(host, 0777) < 0) return errno_map();
        fakefs_record_change(path, FAKEFS_CHANGE_OP_WRITE);
        return 0;
    }
    int rc = db_begin_write(fs);
    if (rc != SQLITE_OK) return fakefs_sql_errno(rc);
    struct ish_stat metadata = { .mode = mode | S_IFDIR, .uid = current ? current->euid : 0,
        .gid = current ? current->egid : 0, .rdev = 0 };
    path_create(fs, path, &metadata);
    int error = fakefs_metadata_ready(fs);
    if (error < 0) return error;
    error = bind ? (mkdir(host, 0777) < 0 ? errno_map() : 0) : realfs.mkdir(mount, path, 0777);
    if (error < 0) return fakefs_abort(fs, error);
    error = fakefs_finish(fs, true);
    if (error == 0 && bind) fakefs_record_change(path, FAKEFS_CHANGE_OP_WRITE);
    return error;
}
static ssize_t file_readlink(struct mount *mount, const char *path, char *buf, size_t size) {
    int fd = openat(mount->root_fd, fix_path(path), O_RDONLY);
    if (fd < 0) return errno_map();
    ssize_t result = read(fd, buf, size);
    int error = errno_map();
    close(fd);
    return result < 0 ? error : result;
}
static ssize_t fakefs_readlink(struct mount *mount, const char *path, char *buf, size_t size) {
    DSH_LIFECYCLE_SCOPE(current ? current->pid : -1);
    struct fakefs_db *fs = &mount->fakefs;
    int rc = db_begin_read(fs);
    if (rc != SQLITE_OK) return fakefs_sql_errno(rc);
    struct ish_stat metadata;
    bool exists = path_read_stat(fs, path, &metadata, NULL);
    int error = fakefs_metadata_ready(fs);
    if (error < 0) return error;
    if (!exists) return fakefs_abort(fs, _ENOENT);
    if (!S_ISLNK(metadata.mode)) return fakefs_abort(fs, _EINVAL);
    ssize_t count = realfs.readlink(mount, path, buf, size);
    if (count == _EINVAL) count = file_readlink(mount, path, buf, size);
    error = fakefs_finish(fs, false);
    return error < 0 ? error : count;
}
static int fakefs_readdir(struct fd *fd, struct dir_entry *entry) {
    DSH_LIFECYCLE_SCOPE(current ? current->pid : -1);
    assert(fd->ops == &fakefs_fdops);
    struct fakefs_db *fs = &fd->mount->fakefs;
    if (fakefs_db_recovery_required(fs)) return _EIO;
retry: ;
    int result = realfs_fdops.readdir(fd, entry);
    if (result <= 0) return result;
    char path[MAX_PATH + 1];
    int error = realfs_getpath(fd, path);
    if (error < 0) return error;
    if (strcmp(entry->name, "..") == 0) {
        char *slash = strrchr(path, '/');
        if (slash) *slash = '\0';
    } else if (strcmp(entry->name, ".") != 0) {
        if (strlen(path) + strlen(entry->name) + 2 > sizeof(path)) return _ENAMETOOLONG;
        strcat(path, "/"); strcat(path, entry->name);
    }
    char host[PATH_MAX]; bool hook = false;
    bind_mount_translate_path_ex(path, host, sizeof(host), &hook);
    if (hook) return result;
    int rc = db_begin_read(fs);
    if (rc != SQLITE_OK) return fakefs_sql_errno(rc);
    entry->inode = path_get_inode(fs, path);
    error = fakefs_metadata_ready(fs);
    if (error == 0) error = fakefs_finish(fs, false);
    if (error < 0) return error;
    if (!entry->inode && is_under_bind_mount(path)) {
        inode_t inode;
        error = bind_mount_ensure_inode(fs, fd->mount, path, &inode);
        if (error < 0) return error;
        entry->inode = inode;
    }
    if (!entry->inode) goto retry;
    return result;
}

static struct fd_ops fakefs_fdops;
static void __attribute__((constructor)) init_fake_fdops() {
    fakefs_fdops = realfs_fdops;
    fakefs_fdops.readdir = fakefs_readdir;
}

/* ===== Public Bind Mount API ===== */

/* Create a relative symlink at root_fd/host_link -> host_path.
 * Computes a relative target so openat() can follow the symlink
 * without escaping the sandbox (absolute symlinks fail on iOS). */
static int create_relative_symlink(int root_fd, const char *host_link,
                                    const char *host_path) {
    /* Get the absolute path of root_fd (F_GETPATH resolves symlinks,
     * e.g. /var -> /private/var on iOS) */
    char root_abs[PATH_MAX];
#if defined(__APPLE__)
    int root_path_result = fcntl(root_fd, F_GETPATH, root_abs);
#else
    char proc_path[64];
    snprintf(proc_path, sizeof(proc_path), "/proc/self/fd/%d", root_fd);
    ssize_t root_length = readlink(proc_path, root_abs, sizeof(root_abs) - 1);
    int root_path_result = root_length < 0 ? -1 : 0;
    if (root_length >= 0) root_abs[root_length] = '\0';
#endif
    if (root_path_result != 0) {
        fprintf(stderr, "create_relative_symlink: F_GETPATH failed\n");
        /* Fall back to absolute symlink */
        return symlinkat(host_path, root_fd, host_link);
    }

    /* Resolve host_path too, so both paths use the same prefix
     * (e.g. both /private/var/... instead of mixing /var/... and /private/var/...) */
    char host_real[PATH_MAX];
    if (realpath(host_path, host_real) == NULL) {
        fprintf(stderr, "create_relative_symlink: realpath(%s) failed, falling back\n", host_path);
        return symlinkat(host_path, root_fd, host_link);
    }

    /* Build the absolute path of the symlink's parent directory */
    char link_abs[PATH_MAX];
    size_t root_length_bytes = strlen(root_abs), link_length_bytes = strlen(host_link);
    if (root_length_bytes + link_length_bytes + 2 > sizeof(link_abs)) { errno = ENAMETOOLONG; return -1; }
    memcpy(link_abs, root_abs, root_length_bytes);
    link_abs[root_length_bytes] = '/';
    memcpy(link_abs + root_length_bytes + 1, host_link, link_length_bytes + 1);
    /* Strip the last component to get the parent dir */
    char *last_slash = strrchr(link_abs, '/');
    if (last_slash) *last_slash = '\0';

    /* Compute relative path from link parent dir to host_path */
    char rel_target[PATH_MAX];
    compute_relative_path(link_abs, host_real, rel_target, sizeof(rel_target));

    fprintf(stderr, "create_relative_symlink: \"%s\" -> \"%s\" (relative: \"%s\")\n",
            host_link, host_path, rel_target);

    return symlinkat(rel_target, root_fd, host_link);
}

/* Recursively remove a directory tree relative to dir_fd.
 * Handles non-empty directories that unlinkat(AT_REMOVEDIR) can't delete. */
static void remove_tree_at(int dir_fd, const char *path) {
    int fd = openat(dir_fd, path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    if (fd < 0) {
        /* Not a directory or doesn't exist — try plain unlink */
        unlinkat(dir_fd, path, 0);
        return;
    }
    DIR *dir = fdopendir(fd);
    if (!dir) {
        close(fd);
        unlinkat(dir_fd, path, 0);
        return;
    }
    struct dirent *ent;
    while ((ent = readdir(dir)) != NULL) {
        if (strcmp(ent->d_name, ".") == 0 || strcmp(ent->d_name, "..") == 0)
            continue;
        if (ent->d_type == DT_DIR) {
            remove_tree_at(dirfd(dir), ent->d_name);
        } else {
            unlinkat(dirfd(dir), ent->d_name, 0);
        }
    }
    closedir(dir); /* also closes fd */
    unlinkat(dir_fd, path, AT_REMOVEDIR);
}

int fakefs_bind_mount(const char *linux_path, const char *host_path, bool read_only) {
    DSH_LIFECYCLE_SCOPE(current ? current->pid : -1);
    if (!g_fakefs_mount) return _ENODEV;
    struct fakefs_db *fs = &g_fakefs_mount->fakefs;
    if (fakefs_db_recovery_required(fs)) return _EIO;
    struct stat st;
    if (stat(host_path, &st) < 0) return errno_map();
    bool is_file = S_ISREG(st.st_mode);
    if (!S_ISDIR(st.st_mode) && !is_file) return _ENOENT;
    char resolved[PATH_MAX];
    if (realpath(host_path, resolved)) host_path = resolved;
    int slot = -1;
    bool existing = false;
    for (int i = 0; i < FAKEFS_MAX_BIND_MOUNTS; i++) {
        if (g_bind_mounts[i].active && strcmp(g_bind_mounts[i].path, linux_path) == 0) {
            slot = i; existing = true; break;
        }
        if (!g_bind_mounts[i].active && slot < 0) slot = i;
    }
    if (slot < 0) return _ENOMEM;
    bool change_host = !existing || strcmp(g_bind_mounts[slot].host_path, host_path) != 0;
    uint32_t mode = is_file ? S_IFREG | (read_only ? 0444 : 0644) : S_IFDIR | (read_only ? 0555 : 0755);
    int rc = db_begin_write(fs);
    if (rc != SQLITE_OK) return fakefs_sql_errno(rc);
    inode_t inode = path_get_inode(fs, linux_path);
    struct ish_stat metadata = { .mode = mode, .uid = 0, .gid = 0, .rdev = 0 };
    if (!inode && db_transaction_error(fs) == SQLITE_OK) path_create(fs, linux_path, &metadata);
    else if (inode) {
        inode_read_stat_or_die(fs, inode, &metadata);
        if (db_transaction_error(fs) == SQLITE_OK) {
            metadata.mode = mode;
            inode_write_stat(fs, inode, &metadata);
        }
    }
    int error = fakefs_metadata_ready(fs);
    if (error < 0) return error;
    if (change_host) {
        /* Preserve the existing bind API's replacement behavior, but never do
         * it before BEGIN and all metadata SQL succeeds. Once replacement
         * starts, a failure cannot be presented as a successful SQL rollback. */
        const char *host_link = fix_path(linux_path);
        remove_tree_at(g_fakefs_mount->root_fd, host_link);
        if (create_relative_symlink(g_fakefs_mount->root_fd, host_link, host_path) < 0) {
            db_require_recovery(fs, SQLITE_IOERR);
            return _EIO;
        }
    }
    error = fakefs_finish(fs, change_host);
    if (error < 0) return error;
    struct fakefs_bind_mount *mount = &g_bind_mounts[slot];
    strlcpy(mount->path, linux_path, sizeof(mount->path));
    strlcpy(mount->host_path, host_path, sizeof(mount->host_path));
    mount->path_len = strlen(linux_path); mount->host_path_len = strlen(host_path);
    mount->read_only = read_only; mount->active = true;
    return 0;
}

int fakefs_bind_unmount(const char *linux_path) {
    DSH_LIFECYCLE_SCOPE(current ? current->pid : -1);
    if (!g_fakefs_mount) return _ENODEV;
    if (fakefs_db_recovery_required(&g_fakefs_mount->fakefs)) return _EIO;
    for (int i = 0; i < FAKEFS_MAX_BIND_MOUNTS; i++) {
        if (g_bind_mounts[i].active && strcmp(g_bind_mounts[i].path, linux_path) == 0) {
            if (unlinkat(g_fakefs_mount->root_fd, fix_path(linux_path), 0) < 0) return errno_map();
            g_bind_mounts[i].active = false;
            return 0;
        }
    }
    return _ENOENT;
}

static int fakefs_mount(struct mount *mount) {
    DSH_LIFECYCLE_SCOPE(current ? current->pid : -1);
    char db_path[PATH_MAX];
    strcpy(db_path, mount->source);
    char *basename = strrchr(db_path, '/') + 1;
    assert(strcmp(basename, "data") == 0);
    strcpy(basename, "meta.db");

    // do this now so rebuilding can use root_fd
    int err = realfs.mount(mount);
    if (err < 0)
        return err;

    err = fake_db_init(&mount->fakefs, db_path, mount->root_fd);
    if (err < 0) {
        if (!fakefs_db_recovery_required(&mount->fakefs)) close(mount->root_fd);
        return err;
    }

    /* Store global reference for bind mount API */
    g_fakefs_mount = mount;
    memset(g_bind_mounts, 0, sizeof(g_bind_mounts));

    return 0;
}

static int fakefs_umount(struct mount *mount) {
    DSH_LIFECYCLE_SCOPE(current ? current->pid : -1);
    int rc = fake_db_deinit(&mount->fakefs);
    if (rc != SQLITE_OK) return fakefs_sql_errno(rc);
    // SQLite teardown is irreversible. Retire the descriptor before close:
    // EINTR/EIO may report failure after the host already reused its number.
    int root_fd = mount->root_fd;
    mount->root_fd = -1;
    if (g_fakefs_mount == mount) g_fakefs_mount = NULL;
    if (close(root_fd) < 0) {
        int error = errno_map();
        dsh_lifecycle_native_close_uncertain();
        printk("fakefs unmount close uncertain: connection=%llu error=%d; detaching\n",
                (unsigned long long) mount->fakefs.lifecycle_connection_id, error);
        // Positive errno tells mount_remove to detach, while reporting failure.
        return -error;
    }
    return 0;
}

static void fakefs_inode_orphaned(struct mount *mount, ino_t inode) {
    DSH_LIFECYCLE_SCOPE(current ? current->pid : -1);
    struct fakefs_db *fs = &mount->fakefs;
    int rc = db_begin_write(fs);
    if (rc != SQLITE_OK) {
        printk("fakefs orphan cleanup deferred: connection=%llu rc=%d\n",
                (unsigned long long) fs->lifecycle_connection_id, rc);
        return;
    }
    rc = sqlite3_bind_int64(fs->stmt.try_cleanup_inode, 1, inode);
    if (rc != SQLITE_OK) { fakefs_abort(fs, fakefs_sql_errno(rc)); return; }
    db_exec_reset(fs, fs->stmt.try_cleanup_inode);
    int error = fakefs_metadata_ready(fs);
    if (error == 0) error = fakefs_finish(fs, false);
    if (error < 0) printk("fakefs orphan cleanup failed: connection=%llu error=%d\n",
            (unsigned long long) fs->lifecycle_connection_id, error);
}

const struct fs_ops fakefs = {
    .name = "fake", .magic = 0x66616b65,
    .mount = fakefs_mount,
    .umount = fakefs_umount,
    .statfs = realfs_statfs,
    .open = fakefs_open,
    .readlink = fakefs_readlink,
    .link = fakefs_link,
    .unlink = fakefs_unlink,
    .rename = fakefs_rename,
    .symlink = fakefs_symlink,
    .mknod = fakefs_mknod,

    .close = realfs_close,
    .stat = fakefs_stat,
    .fstat = fakefs_fstat,
    .flock = realfs_flock,
    .setattr = fakefs_setattr,
    .fsetattr = fakefs_fsetattr,
    .getpath = realfs_getpath,
    .utime = realfs_utime,

    .mkdir = fakefs_mkdir,
    .rmdir = fakefs_rmdir,

    .inode_orphaned = fakefs_inode_orphaned,
};

bool fakefs_bind_mount_translate_path(const char *path, char *out_path, size_t out_size) {
    return bind_mount_translate_path(path, out_path, out_size);
}

/* ===== Bind-mount file change notifications =====
 *
 * Lock-protected ring buffer collects (linux_path, op, timestamp) events
 * from realfs hot paths. A dispatch_source coalesces wakeups for a serial
 * consumer queue; the registered handler drains the ring in batches.
 *
 * Ring full → drop oldest event and bump g_dropped_count (observable via
 * fakefs_change_dropped_count()). The producer side is bounded:
 *   lock + memcpy(linux_path, ~64B avg) + atomic_store + merge_data
 * which on Apple Silicon measures around 150–250ns.
 *
 * Implementation is Apple-only: it relies on GCD (dispatch sources),
 * Clang blocks (Block_copy / Block_release), os_unfair_lock and mach
 * time. On non-Apple builds (Linux / x86 iSH), the public API still
 * resolves at link time but every entry point is a no-op so the host
 * never observes events. This matches the upstream iSH stance of
 * keeping fs/fake.c portable while letting Apple-side ports layer
 * platform features on top.
 */

#if defined(__APPLE__)

#define FAKEFS_CHANGE_RING_SIZE 1024  /* must be power of two */

static struct fakefs_change_event g_change_ring[FAKEFS_CHANGE_RING_SIZE];
static _Atomic uint64_t g_change_head = 0;  /* next write slot */
static _Atomic uint64_t g_change_tail = 0;  /* next read slot */
static os_unfair_lock g_change_ring_lock = OS_UNFAIR_LOCK_INIT;
static _Atomic uint64_t g_change_dropped = 0;

static dispatch_queue_t g_change_consumer_queue = NULL;
static dispatch_source_t g_change_consumer_source = NULL;
static fakefs_change_handler_t g_change_handler = NULL;

/* Drain up to `max` events from the ring into `out`. Returns count drained.
 * Called only on the consumer queue. */
static int fakefs_change_drain(struct fakefs_change_event *out, int max) {
    int n = 0;
    os_unfair_lock_lock(&g_change_ring_lock);
    uint64_t head = atomic_load_explicit(&g_change_head, memory_order_acquire);
    uint64_t tail = atomic_load_explicit(&g_change_tail, memory_order_relaxed);
    while (tail < head && n < max) {
        out[n++] = g_change_ring[tail & (FAKEFS_CHANGE_RING_SIZE - 1)];
        tail++;
    }
    atomic_store_explicit(&g_change_tail, tail, memory_order_release);
    os_unfair_lock_unlock(&g_change_ring_lock);
    return n;
}

void fakefs_record_change(const char *linux_path, int op) {
    if (g_change_consumer_source == NULL || linux_path == NULL)
        return;

    os_unfair_lock_lock(&g_change_ring_lock);
    uint64_t head = atomic_load_explicit(&g_change_head, memory_order_relaxed);
    uint64_t tail = atomic_load_explicit(&g_change_tail, memory_order_acquire);
    if (head - tail >= FAKEFS_CHANGE_RING_SIZE) {
        /* Full — drop oldest. */
        atomic_store_explicit(&g_change_tail, tail + 1, memory_order_release);
        atomic_fetch_add_explicit(&g_change_dropped, 1, memory_order_relaxed);
    }
    struct fakefs_change_event *slot = &g_change_ring[head & (FAKEFS_CHANGE_RING_SIZE - 1)];
    strlcpy(slot->linux_path, linux_path, sizeof(slot->linux_path));
    slot->op = op;
    slot->timestamp_ns = (int64_t)mach_absolute_time();
    slot->fs_context = (current != NULL && current->group != NULL)
        ? current->group->fs_context : 0;
    atomic_store_explicit(&g_change_head, head + 1, memory_order_release);
    os_unfair_lock_unlock(&g_change_ring_lock);

    dispatch_source_merge_data(g_change_consumer_source, 1);
}

void fakefs_install_change_consumer(fakefs_change_handler_t handler) {
    if (handler == NULL)
        return;
    if (g_change_consumer_source != NULL) {
        /* Replace handler — supported but unusual. */
        if (g_change_handler) Block_release(g_change_handler);
        g_change_handler = Block_copy(handler);
        return;
    }

    g_change_handler = Block_copy(handler);
    g_change_consumer_queue = dispatch_queue_create(
        "com.openminis.ish.fakechange", DISPATCH_QUEUE_SERIAL);
    g_change_consumer_source = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_DATA_ADD, 0, 0, g_change_consumer_queue);

    dispatch_source_set_event_handler(g_change_consumer_source, ^{
        struct fakefs_change_event batch[64];
        int n;
        while ((n = fakefs_change_drain(batch, 64)) > 0) {
            if (g_change_handler) g_change_handler(batch, n);
            if (n < 64) break;  /* drained everything */
        }
    });
    dispatch_resume(g_change_consumer_source);
}

uint64_t fakefs_change_dropped_count(void) {
    return atomic_load_explicit(&g_change_dropped, memory_order_relaxed);
}

#else /* !__APPLE__ — non-Apple stubs.
       *
       * The host (Swift / ObjC) bridge that consumes these events only
       * exists on Apple. On Linux / x86 iSH builds we still need the
       * three symbols to resolve at link time (callers in fs/fake.c and
       * fs/real.c invoke them unconditionally), but they must do
       * nothing — no ring buffer, no consumer queue, no host wakeups. */

void fakefs_record_change(const char *linux_path, int op) {
    (void)linux_path; (void)op;
}

void fakefs_install_change_consumer(fakefs_change_handler_t handler) {
    (void)handler;
}

uint64_t fakefs_change_dropped_count(void) {
    return 0;
}

#endif /* __APPLE__ */
