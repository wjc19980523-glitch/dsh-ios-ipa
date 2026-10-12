#ifndef FS_DSH_LIFECYCLE_H
#define FS_DSH_LIFECYCLE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define DSH_LIFECYCLE_API __attribute__((visibility("default")))
#define DSH_LIFECYCLE_SNAPSHOT_ITEMS 16
#define DSH_LIFECYCLE_OPERATION_NAME_SIZE 48

enum dsh_lifecycle_state {
    DSH_LIFECYCLE_RUNNING = 0,
    DSH_LIFECYCLE_QUIESCING = 1,
    DSH_LIFECYCLE_QUIESCENT = 2,
    DSH_LIFECYCLE_RESUMING = 3,
};

enum dsh_lifecycle_transaction_mode {
    DSH_LIFECYCLE_TXN_DEFERRED = 0,
    DSH_LIFECYCLE_TXN_READ = 1,
    DSH_LIFECYCLE_TXN_WRITE = 2,
};

enum dsh_lifecycle_flock_mode {
    DSH_LIFECYCLE_FLOCK_UNLOCKED = 0,
    DSH_LIFECYCLE_FLOCK_SHARED = 1,
    DSH_LIFECYCLE_FLOCK_EXCLUSIVE = 2,
};

/* A strict whitelist, never an arbitrary basename or path. */
enum dsh_lifecycle_flock_file_kind {
    DSH_FLOCK_FILE_UNKNOWN = 0,
    DSH_FLOCK_FILE_SESSION_LOCK = 1,
    DSH_FLOCK_FILE_OTHER = 2,
};
enum dsh_lifecycle_flock_fs_kind {
    DSH_FLOCK_FS_UNKNOWN = 0,
    DSH_FLOCK_FS_FAKE = 1,
    DSH_FLOCK_FS_REAL = 2,
    DSH_FLOCK_FS_OTHER = 3,
};
struct dsh_lifecycle_flock_identity {
    uint64_t device;
    uint64_t inode;
    enum dsh_lifecycle_flock_file_kind file_kind;
    enum dsh_lifecycle_flock_fs_kind fs_kind;
    int stat_error;             /* Host errno, zero when observed successfully. */
    int path_error;
};
enum dsh_lifecycle_flock_event_kind {
    DSH_FLOCK_ACQUIRED = 0,
    DSH_FLOCK_UPDATED = 1,
    DSH_FLOCK_UNLOCKED = 2,
    DSH_FLOCK_CLOSED = 3,
    DSH_FLOCK_CLOSE_FAILED = 4,
};

struct dsh_lifecycle_owner {
    int guest_pid;              /* -1 when no guest task is available. */
    uint64_t thread_id;         /* Stable, process-local diagnostic ID. */
};

struct dsh_lifecycle_operation_snapshot {
    uint64_t id;
    char name[DSH_LIFECYCLE_OPERATION_NAME_SIZE]; /* Function name, never a path. */
    struct dsh_lifecycle_owner owner;
    uint64_t started_monotonic_ns;
    uint64_t age_ns;
    unsigned nesting_depth;
};

struct dsh_lifecycle_transaction_snapshot {
    uint64_t connection_id;
    struct dsh_lifecycle_owner owner;
    enum dsh_lifecycle_transaction_mode mode;
    int cached_autocommit;
    int cached_result;
    bool recovery_required;
    int recovery_result;
    char phase[24];
    uint64_t started_monotonic_ns;
    uint64_t observed_monotonic_ns;
    uint64_t age_ns;
};

struct dsh_lifecycle_flock_snapshot {
    uint64_t id;
    int host_fd;
    enum dsh_lifecycle_flock_mode mode;
    struct dsh_lifecycle_owner owner;
    uint64_t started_monotonic_ns;
    uint64_t age_ns;
    int guest_fd;              /* Last successful flock's guest fd; -1 if unknown. */
    int guest_tgid;            /* Thread group of that caller, not the host PID. */
    struct dsh_lifecycle_flock_identity identity;
};
struct dsh_lifecycle_flock_event {
    uint64_t sequence;
    uint64_t observed_monotonic_ns;
    enum dsh_lifecycle_flock_event_kind kind;
    int result;               /* Host errno for a failed close. */
    struct dsh_lifecycle_owner actor;
    struct dsh_lifecycle_flock_snapshot lock;
};

/* All SQLite values below are cached observations made by the SQL worker.
 * Snapshotting never calls SQLite, enters its mutex, or probes host locks.
 * Counters include nested operations; item arrays contain at most 16 records.
 * tracking_overflows is cumulative and prevents claiming verified quiescence.
 */
struct dsh_lifecycle_snapshot {
    enum dsh_lifecycle_state state;
    uint64_t generation;
    uint64_t sampled_monotonic_ns;
    uint64_t last_resume_monotonic_ns;
    uint64_t active_operations;
    /* Covered fakefs_ entry scopes, including nesting, not unique syscalls.
     * Counted over the full tracked table, not the truncated item array;
     * an incomplete lower bound when tracking_overflows is nonzero. */
    uint64_t active_fakefs_operations;
    uint64_t paused_fileless_operations;
    uint64_t open_connections;
    uint64_t active_deferred_transactions;
    uint64_t active_read_transactions;
    uint64_t active_write_transactions;
    uint64_t oldest_transaction_age_ns;
    uint64_t recovery_blocked_connections;
    uint64_t active_native_flocks;
    uint64_t tracking_overflows;
    uint64_t operations_after_quiesce;
    uint64_t sqlite_busy_observations;
    uint64_t sqlite_error_observations;
    uint64_t native_close_failures;
    /* A host-authenticated Harness thread group may finish its cooperative
     * persistence drain while admission is closed. An active permit always
     * prevents verified quiescence, even when all observed counters are zero. */
    bool session_drain_active;
    int session_drain_guest_tgid;
    uint64_t session_drain_generation;
    int last_sqlite_result;
    unsigned operation_count;
    unsigned transaction_count;
    unsigned native_flock_count;
    uint64_t native_flock_event_total;
    unsigned native_flock_event_count;
    struct dsh_lifecycle_operation_snapshot operations[DSH_LIFECYCLE_SNAPSHOT_ITEMS];
    struct dsh_lifecycle_transaction_snapshot transactions[DSH_LIFECYCLE_SNAPSHOT_ITEMS];
    struct dsh_lifecycle_flock_snapshot native_flocks[DSH_LIFECYCLE_SNAPSHOT_ITEMS];
    /* Last 16 transitions, oldest first. Intentional history wrap does not
     * affect admission or tracking_overflows; active locks remain separate. */
    struct dsh_lifecycle_flock_event native_flock_events[DSH_LIFECYCLE_SNAPSHOT_ITEMS];
};

/* Tokens must be paired on the same thread. With admission enabled, outer
 * scopes wait before host effects and kernel locks; nested scopes finish the
 * operation already admitted. Without admission these only observe work.
 */
DSH_LIFECYCLE_API uint64_t dsh_lifecycle_operation_begin(const char *name, int guest_pid);
DSH_LIFECYCLE_API void dsh_lifecycle_operation_end(uint64_t token);
DSH_LIFECYCLE_API unsigned dsh_lifecycle_operation_depth(void);
/* Only the common stream-read boundary may call these after retaining a known
 * tty_dev fd and releasing the fdtable lock. A pause is refused unless exactly
 * one tracked permit is owned and no SQLite/native-flock uncertainty exists.
 * The tty read uses private kernel memory. Resume the SAME token after tty_read
 * has released its locks, before fd release, guest copyout or signal cleanup.
 * A nonzero token reserves its original record while excluded from active
 * operations; zero means the caller must retain its normal permit.
 */
DSH_LIFECYCLE_API uint64_t dsh_lifecycle_pause_tty_read(void);
DSH_LIFECYCLE_API void dsh_lifecycle_resume_tty_read(uint64_t token);

DSH_LIFECYCLE_API uint64_t dsh_lifecycle_sqlite_open(int guest_pid);
/* sqlite_txn_state uses SQLite's NONE=0/READ=1/WRITE=2 values; -1 if unavailable.
 * autocommit must be sampled on the SQL worker after the corresponding call.
 */
DSH_LIFECYCLE_API void dsh_lifecycle_sqlite_update(uint64_t connection_id,
        int guest_pid, int autocommit, int sqlite_txn_state, int result, const char *phase);
DSH_LIFECYCLE_API void dsh_lifecycle_sqlite_close(uint64_t connection_id, int result);
DSH_LIFECYCLE_API void dsh_lifecycle_sqlite_recovery_required(uint64_t connection_id, int result);
DSH_LIFECYCLE_API void dsh_lifecycle_sqlite_recovery_resolved(uint64_t connection_id);

/* fd_key identifies the retained emulator fd object, not a reusable host fd.
 * Call only after a successful flock; confirmed final close removes the record.
 * An uncertain close error retains the record and marks the observation unsafe.
 */
DSH_LIFECYCLE_API void dsh_lifecycle_native_flock_update(const void *fd_key,
        int host_fd, int guest_pid, enum dsh_lifecycle_flock_mode mode);
/* Host identity is collected by realfs, outside diagnostic/SQLite mutexes.
 * This core only copies fixed-size metadata. No path is retained. */
DSH_LIFECYCLE_API enum dsh_lifecycle_flock_file_kind dsh_lifecycle_flock_classify_path(const char *path);
DSH_LIFECYCLE_API void dsh_lifecycle_native_flock_observe(const void *fd_key,
        int host_fd, int guest_pid, enum dsh_lifecycle_flock_mode mode,
        const struct dsh_lifecycle_flock_identity *identity);
DSH_LIFECYCLE_API void dsh_lifecycle_native_flock_guest_fd(const void *fd_key,
        int guest_pid, int guest_fd, int guest_tgid);
DSH_LIFECYCLE_API void dsh_lifecycle_native_flock_close(const void *fd_key);
DSH_LIFECYCLE_API void dsh_lifecycle_native_flock_close_failed(const void *fd_key);
DSH_LIFECYCLE_API void dsh_lifecycle_native_flock_close_error(const void *fd_key, int error);
/* An untracked/native descriptor close has uncertain ownership. Do not retry
 * that descriptor number; retain a process-local diagnostic safety barrier. */
DSH_LIFECYCLE_API void dsh_lifecycle_native_close_uncertain(void);

DSH_LIFECYCLE_API void dsh_lifecycle_get_snapshot(struct dsh_lifecycle_snapshot *snapshot);
/* State transitions and quiescence validation are atomic with admission. */
DSH_LIFECYCLE_API uint64_t dsh_lifecycle_request_quiesce(void);
DSH_LIFECYCLE_API bool dsh_lifecycle_mark_quiescent(uint64_t generation);
DSH_LIFECYCLE_API void dsh_lifecycle_resume(void);
/* The app enables admission once, before starting any guest work. CLI tools
 * keep diagnostic-only semantics unless a lifecycle test explicitly enables it.
 * An outer permit MUST precede guest/kernel locks and host effects. Nested
 * scopes drain using that permit; no new scope waits mid-transaction.
 */
DSH_LIFECYCLE_API void dsh_lifecycle_enable_admission_gate(void);
DSH_LIFECYCLE_API void dsh_lifecycle_begin_resume(void);
DSH_LIFECYCLE_API void dsh_lifecycle_checkpoint(int guest_pid);
DSH_LIFECYCLE_API void dsh_lifecycle_thread_exit(void);
/* Trusted kernel task-loop, syscall and thread-cleanup entries install this
 * thread-local identity before guest/kernel locks. Native callers without a
 * matching guest PID do not gain a drain permit. Nested syscall entry restores
 * the task-loop context; the loop refreshes it from the live task each round. */
struct dsh_lifecycle_guest_context { int guest_pid; int guest_tgid; };
DSH_LIFECYCLE_API struct dsh_lifecycle_guest_context dsh_lifecycle_exchange_guest_context(
        struct dsh_lifecycle_guest_context context);
static inline void dsh_lifecycle_restore_guest_context(struct dsh_lifecycle_guest_context *context) {
    (void)dsh_lifecycle_exchange_guest_context(*context);
}
/* Host-only policy: the caller must authenticate and register this exact live
 * Harness guest group before granting, and revoke on acknowledgement, expiry
 * or cancellation. The guest persistence controller stops new business writes
 * before acknowledging. No file name, guest-supplied group, or native thread
 * identity grants admission. These APIs never release a SQL/native file lock.
 * Grants are valid only in the current Quiescing/Resuming generation. Revoking
 * seals that generation against regrant; stale callbacks cannot affect a new
 * cycle. begin_resume invalidates the old grant; grant again with its new core
 * generation for Node-only writer/lock reacquisition, then resume normally. */
DSH_LIFECYCLE_API bool dsh_lifecycle_grant_session_drain(int guest_tgid, uint64_t generation);
DSH_LIFECYCLE_API bool dsh_lifecycle_revoke_session_drain(int guest_tgid, uint64_t generation);
/* Native main-thread callers must fail/defer instead of blocking UIKit. */
DSH_LIFECYCLE_API uint64_t dsh_lifecycle_try_operation_begin(const char *name, int guest_pid);

struct dsh_lifecycle_scope { uint64_t token; };
static inline void dsh_lifecycle_scope_end(struct dsh_lifecycle_scope *scope) {
    dsh_lifecycle_operation_end(scope->token);
}
#define DSH_LIFECYCLE_SCOPE(guest_pid) \
    struct dsh_lifecycle_scope _dsh_lifecycle_scope \
        __attribute__((cleanup(dsh_lifecycle_scope_end))) = \
        { dsh_lifecycle_operation_begin(__func__, (guest_pid)) }

#ifdef __cplusplus
}
#endif
#endif
