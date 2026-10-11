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
    uint64_t active_operations;
    /* Covered fakefs_ entry scopes, including nesting, not unique syscalls.
     * Counted over the full tracked table, not the truncated item array;
     * an incomplete lower bound when tracking_overflows is nonzero. */
    uint64_t active_fakefs_operations;
    uint64_t open_connections;
    uint64_t active_deferred_transactions;
    uint64_t active_read_transactions;
    uint64_t active_write_transactions;
    uint64_t active_native_flocks;
    uint64_t tracking_overflows;
    uint64_t operations_after_quiesce;
    uint64_t sqlite_busy_observations;
    uint64_t sqlite_error_observations;
    uint64_t native_close_failures;
    int last_sqlite_result;
    unsigned operation_count;
    unsigned transaction_count;
    unsigned native_flock_count;
    struct dsh_lifecycle_operation_snapshot operations[DSH_LIFECYCLE_SNAPSHOT_ITEMS];
    struct dsh_lifecycle_transaction_snapshot transactions[DSH_LIFECYCLE_SNAPSHOT_ITEMS];
    struct dsh_lifecycle_flock_snapshot native_flocks[DSH_LIFECYCLE_SNAPSHOT_ITEMS];
};

/* Diagnostic observation only: these functions DO NOT block or reject work.
 * Tokens must be paired on the same thread. Nested scopes retain guest context
 * so a later admission gate can admit an entire operation before host effects.
 */
DSH_LIFECYCLE_API uint64_t dsh_lifecycle_operation_begin(const char *name, int guest_pid);
DSH_LIFECYCLE_API void dsh_lifecycle_operation_end(uint64_t token);
DSH_LIFECYCLE_API unsigned dsh_lifecycle_operation_depth(void);

DSH_LIFECYCLE_API uint64_t dsh_lifecycle_sqlite_open(int guest_pid);
/* sqlite_txn_state uses SQLite's NONE=0/READ=1/WRITE=2 values; -1 if unavailable.
 * autocommit must be sampled on the SQL worker after the corresponding call.
 */
DSH_LIFECYCLE_API void dsh_lifecycle_sqlite_update(uint64_t connection_id,
        int guest_pid, int autocommit, int sqlite_txn_state, int result, const char *phase);
DSH_LIFECYCLE_API void dsh_lifecycle_sqlite_close(uint64_t connection_id, int result);

/* fd_key identifies the retained emulator fd object, not a reusable host fd.
 * Call only after a successful flock; confirmed final close removes the record.
 * An uncertain close error retains the record and marks the observation unsafe.
 */
DSH_LIFECYCLE_API void dsh_lifecycle_native_flock_update(const void *fd_key,
        int host_fd, int guest_pid, enum dsh_lifecycle_flock_mode mode);
DSH_LIFECYCLE_API void dsh_lifecycle_native_flock_close(const void *fd_key);
DSH_LIFECYCLE_API void dsh_lifecycle_native_flock_close_failed(const void *fd_key);

DSH_LIFECYCLE_API void dsh_lifecycle_get_snapshot(struct dsh_lifecycle_snapshot *snapshot);
/* Intent state only in this diagnostic stage; no runtime gate is connected. */
DSH_LIFECYCLE_API uint64_t dsh_lifecycle_request_quiesce(void);
DSH_LIFECYCLE_API bool dsh_lifecycle_mark_quiescent(uint64_t generation);
DSH_LIFECYCLE_API void dsh_lifecycle_resume(void);

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
