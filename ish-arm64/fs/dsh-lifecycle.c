#include "fs/dsh-lifecycle.h"

#include <errno.h>
#include <pthread.h>
#include <stddef.h>
#include <string.h>
#include <time.h>

#define OPERATION_CAPACITY 512
#define CONNECTION_CAPACITY 128
#define FLOCK_CAPACITY 256
#define UNTRACKED_TOKEN (UINT64_C(1) << 63)

struct operation_record {
    bool used;
    struct dsh_lifecycle_operation_snapshot value;
};
struct connection_record {
    bool used;
    struct dsh_lifecycle_transaction_snapshot value;
};
struct flock_record {
    const void *key;
    struct dsh_lifecycle_flock_snapshot value;
};

/* No I/O, SQLite calls, guest locks, callbacks or allocations while held. */
static pthread_mutex_t diagnostic_lock = PTHREAD_MUTEX_INITIALIZER;
static struct operation_record operations[OPERATION_CAPACITY];
static struct connection_record connections[CONNECTION_CAPACITY];
static struct flock_record native_flocks[FLOCK_CAPACITY];
static enum dsh_lifecycle_state lifecycle_state = DSH_LIFECYCLE_RUNNING;
static uint64_t lifecycle_generation;
static uint64_t next_id = 1;
static uint64_t next_thread_id = 1;
static uint64_t active_operations;
static uint64_t open_connections;
static uint64_t tracking_overflows;
static uint64_t operations_after_quiesce;
static uint64_t sqlite_busy_observations;
static uint64_t sqlite_error_observations;
static uint64_t native_close_failures;
static int last_sqlite_result;
static _Thread_local uint64_t thread_id;
static _Thread_local unsigned operation_depth;
static _Thread_local int operation_guest_pid = -1;

static uint64_t monotonic_ns(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0)
        return 0;
    return (uint64_t) ts.tv_sec * UINT64_C(1000000000) + (uint64_t) ts.tv_nsec;
}

static void copy_label(char *destination, size_t size, const char *source) {
    if (source == NULL) source = "unknown";
    size_t length = strlen(source);
    if (length >= size) length = size - 1;
    memcpy(destination, source, length);
    destination[length] = '\0';
}

/* diagnostic_lock must be held. IDs deliberately do not expose host pointers
 * or pthread representation; they are meaningful within this process only. */
static struct dsh_lifecycle_owner owner(int guest_pid) {
    if (thread_id == 0) thread_id = next_thread_id++;
    return (struct dsh_lifecycle_owner) {
        .guest_pid = guest_pid >= 0 ? guest_pid : operation_guest_pid,
        .thread_id = thread_id,
    };
}

static struct connection_record *find_connection(uint64_t id) {
    for (unsigned i = 0; i < CONNECTION_CAPACITY; i++)
        if (connections[i].used && connections[i].value.connection_id == id)
            return &connections[i];
    return NULL;
}

uint64_t dsh_lifecycle_operation_begin(const char *name, int guest_pid) {
    int saved_errno = errno;
    uint64_t now = monotonic_ns();
    pthread_mutex_lock(&diagnostic_lock);
    uint64_t token = next_id++;
    if (operation_depth == 0) operation_guest_pid = guest_pid;
    operation_depth++;
    active_operations++;
    if (lifecycle_state != DSH_LIFECYCLE_RUNNING) operations_after_quiesce++;
    unsigned i;
    for (i = 0; i < OPERATION_CAPACITY; i++) {
        if (operations[i].used) continue;
        operations[i].used = true;
        operations[i].value = (struct dsh_lifecycle_operation_snapshot) {
            .id = token,
            .owner = owner(guest_pid),
            .started_monotonic_ns = now,
            .nesting_depth = operation_depth,
        };
        copy_label(operations[i].value.name, sizeof(operations[i].value.name), name);
        break;
    }
    if (i == OPERATION_CAPACITY) {
        tracking_overflows++;
        token |= UNTRACKED_TOKEN;
    }
    pthread_mutex_unlock(&diagnostic_lock);
    errno = saved_errno;
    return token;
}

void dsh_lifecycle_operation_end(uint64_t token) {
    int saved_errno = errno;
    pthread_mutex_lock(&diagnostic_lock);
    bool found = (token & UNTRACKED_TOKEN) != 0;
    for (unsigned i = 0; !found && i < OPERATION_CAPACITY; i++) {
        if (!operations[i].used || operations[i].value.id != token) continue;
        operations[i].used = false;
        found = true;
    }
    if (found) {
        if (active_operations > 0) active_operations--;
        if (operation_depth > 0) operation_depth--;
        if (operation_depth == 0) operation_guest_pid = -1;
    }
    pthread_mutex_unlock(&diagnostic_lock);
    errno = saved_errno;
}

unsigned dsh_lifecycle_operation_depth(void) {
    return operation_depth;
}

uint64_t dsh_lifecycle_sqlite_open(int guest_pid) {
    int saved_errno = errno;
    uint64_t now = monotonic_ns();
    pthread_mutex_lock(&diagnostic_lock);
    uint64_t id = next_id++;
    open_connections++;
    unsigned i;
    for (i = 0; i < CONNECTION_CAPACITY; i++) {
        if (connections[i].used) continue;
        connections[i].used = true;
        connections[i].value = (struct dsh_lifecycle_transaction_snapshot) {
            .connection_id = id,
            .owner = owner(guest_pid),
            .cached_autocommit = 1,
            .observed_monotonic_ns = now,
        };
        copy_label(connections[i].value.phase, sizeof(connections[i].value.phase), "open");
        break;
    }
    if (i == CONNECTION_CAPACITY) {
        tracking_overflows++;
        id |= UNTRACKED_TOKEN;
    }
    pthread_mutex_unlock(&diagnostic_lock);
    errno = saved_errno;
    return id;
}

void dsh_lifecycle_sqlite_update(uint64_t id, int guest_pid, int autocommit,
        int sqlite_txn_state, int result, const char *phase) {
    int saved_errno = errno;
    uint64_t now = monotonic_ns();
    pthread_mutex_lock(&diagnostic_lock);
    last_sqlite_result = result;
    int primary_result = result & 0xff;
    if (primary_result == 5 || primary_result == 6) sqlite_busy_observations++;
    if (primary_result != 0 && primary_result != 100 && primary_result != 101)
        sqlite_error_observations++;
    struct connection_record *record = find_connection(id);
    if (record != NULL) {
        struct dsh_lifecycle_transaction_snapshot *value = &record->value;
        bool was_active = !value->cached_autocommit || value->mode != DSH_LIFECYCLE_TXN_DEFERRED;
        bool is_active = !autocommit || sqlite_txn_state > 0;
        if (is_active && !was_active) {
            value->started_monotonic_ns = now;
            value->owner = owner(guest_pid);
        }
        value->cached_autocommit = autocommit;
        value->cached_result = result;
        value->observed_monotonic_ns = now;
        if (sqlite_txn_state >= 0)
            value->mode = (enum dsh_lifecycle_transaction_mode) sqlite_txn_state;
        else if (autocommit)
            value->mode = DSH_LIFECYCLE_TXN_DEFERRED;
        if (!is_active) value->started_monotonic_ns = 0;
        copy_label(value->phase, sizeof(value->phase), phase);
    }
    pthread_mutex_unlock(&diagnostic_lock);
    errno = saved_errno;
}

void dsh_lifecycle_sqlite_close(uint64_t id, int result) {
    int saved_errno = errno;
    pthread_mutex_lock(&diagnostic_lock);
    struct connection_record *record = find_connection(id);
    if (result == 0) {
        if (record != NULL) {
            record->used = false;
            if (open_connections > 0) open_connections--;
        } else if ((id & UNTRACKED_TOKEN) != 0 && open_connections > 0) {
            open_connections--;
        }
    } else if (record != NULL) {
        record->value.cached_result = result;
        copy_label(record->value.phase, sizeof(record->value.phase), "close_failed");
    }
    pthread_mutex_unlock(&diagnostic_lock);
    errno = saved_errno;
}

void dsh_lifecycle_native_flock_update(const void *key, int host_fd, int guest_pid,
        enum dsh_lifecycle_flock_mode mode) {
    int saved_errno = errno;
    if (key == NULL) return;
    uint64_t now = monotonic_ns();
    pthread_mutex_lock(&diagnostic_lock);
    unsigned empty = FLOCK_CAPACITY;
    for (unsigned i = 0; i < FLOCK_CAPACITY; i++) {
        if (native_flocks[i].key == key) {
            if (mode == DSH_LIFECYCLE_FLOCK_UNLOCKED) {
                native_flocks[i].key = NULL;
            } else {
                native_flocks[i].value.mode = mode;
                native_flocks[i].value.owner = owner(guest_pid);
            }
            pthread_mutex_unlock(&diagnostic_lock);
            errno = saved_errno;
            return;
        }
        if (native_flocks[i].key == NULL && empty == FLOCK_CAPACITY) empty = i;
    }
    if (mode != DSH_LIFECYCLE_FLOCK_UNLOCKED) {
        if (empty == FLOCK_CAPACITY) {
            tracking_overflows++;
        } else {
            native_flocks[empty].key = key;
            native_flocks[empty].value = (struct dsh_lifecycle_flock_snapshot) {
                .id = next_id++,
                .host_fd = host_fd,
                .mode = mode,
                .owner = owner(guest_pid),
                .started_monotonic_ns = now,
            };
        }
    }
    pthread_mutex_unlock(&diagnostic_lock);
    errno = saved_errno;
}

void dsh_lifecycle_native_flock_close(const void *key) {
    dsh_lifecycle_native_flock_update(key, -1, -1, DSH_LIFECYCLE_FLOCK_UNLOCKED);
}

void dsh_lifecycle_native_flock_close_failed(const void *key) {
    int saved_errno = errno;
    pthread_mutex_lock(&diagnostic_lock);
    for (unsigned i = 0; i < FLOCK_CAPACITY; i++) {
        if (native_flocks[i].key != key || key == NULL) continue;
        native_close_failures++;
        break;
    }
    pthread_mutex_unlock(&diagnostic_lock);
    errno = saved_errno;
}

void dsh_lifecycle_get_snapshot(struct dsh_lifecycle_snapshot *snapshot) {
    int saved_errno = errno;
    if (snapshot == NULL) return;
    memset(snapshot, 0, sizeof(*snapshot));
    pthread_mutex_lock(&diagnostic_lock);
    uint64_t now = monotonic_ns();
    snapshot->state = lifecycle_state;
    snapshot->generation = lifecycle_generation;
    snapshot->sampled_monotonic_ns = now;
    snapshot->active_operations = active_operations;
    snapshot->open_connections = open_connections;
    snapshot->tracking_overflows = tracking_overflows;
    snapshot->operations_after_quiesce = operations_after_quiesce;
    snapshot->sqlite_busy_observations = sqlite_busy_observations;
    snapshot->sqlite_error_observations = sqlite_error_observations;
    snapshot->native_close_failures = native_close_failures;
    snapshot->last_sqlite_result = last_sqlite_result;
    for (unsigned i = 0; i < OPERATION_CAPACITY; i++) {
        if (!operations[i].used) continue;
        if (strncmp(operations[i].value.name, "fakefs_", 7) == 0)
            snapshot->active_fakefs_operations++;
        if (snapshot->operation_count == DSH_LIFECYCLE_SNAPSHOT_ITEMS) continue;
        struct dsh_lifecycle_operation_snapshot *value =
            &snapshot->operations[snapshot->operation_count++];
        *value = operations[i].value;
        value->age_ns = now >= value->started_monotonic_ns ? now - value->started_monotonic_ns : 0;
    }
    for (unsigned i = 0; i < CONNECTION_CAPACITY; i++) {
        if (!connections[i].used || (connections[i].value.cached_autocommit &&
                    connections[i].value.mode == DSH_LIFECYCLE_TXN_DEFERRED)) continue;
        struct dsh_lifecycle_transaction_snapshot *cached = &connections[i].value;
        if (cached->mode == DSH_LIFECYCLE_TXN_WRITE) snapshot->active_write_transactions++;
        else if (cached->mode == DSH_LIFECYCLE_TXN_READ) snapshot->active_read_transactions++;
        else snapshot->active_deferred_transactions++;
        if (snapshot->transaction_count == DSH_LIFECYCLE_SNAPSHOT_ITEMS) continue;
        struct dsh_lifecycle_transaction_snapshot *value =
            &snapshot->transactions[snapshot->transaction_count++];
        *value = *cached;
        value->age_ns = now >= value->started_monotonic_ns ? now - value->started_monotonic_ns : 0;
    }
    for (unsigned i = 0; i < FLOCK_CAPACITY; i++) {
        if (native_flocks[i].key == NULL) continue;
        snapshot->active_native_flocks++;
        if (snapshot->native_flock_count == DSH_LIFECYCLE_SNAPSHOT_ITEMS) continue;
        struct dsh_lifecycle_flock_snapshot *value =
            &snapshot->native_flocks[snapshot->native_flock_count++];
        *value = native_flocks[i].value;
        value->age_ns = now >= value->started_monotonic_ns ? now - value->started_monotonic_ns : 0;
    }
    pthread_mutex_unlock(&diagnostic_lock);
    errno = saved_errno;
}

uint64_t dsh_lifecycle_request_quiesce(void) {
    int saved_errno = errno;
    pthread_mutex_lock(&diagnostic_lock);
    if (lifecycle_state == DSH_LIFECYCLE_RUNNING) {
        lifecycle_state = DSH_LIFECYCLE_QUIESCING;
        lifecycle_generation++;
    }
    uint64_t generation = lifecycle_generation;
    pthread_mutex_unlock(&diagnostic_lock);
    errno = saved_errno;
    return generation;
}

bool dsh_lifecycle_mark_quiescent(uint64_t generation) {
    int saved_errno = errno;
    pthread_mutex_lock(&diagnostic_lock);
    bool clean = lifecycle_state == DSH_LIFECYCLE_QUIESCING &&
        generation == lifecycle_generation && active_operations == 0 &&
        tracking_overflows == 0 && native_close_failures == 0;
    for (unsigned i = 0; clean && i < CONNECTION_CAPACITY; i++)
        if (connections[i].used && (!connections[i].value.cached_autocommit ||
                    connections[i].value.mode != DSH_LIFECYCLE_TXN_DEFERRED)) clean = false;
    for (unsigned i = 0; clean && i < FLOCK_CAPACITY; i++)
        if (native_flocks[i].key != NULL) clean = false;
    if (clean) lifecycle_state = DSH_LIFECYCLE_QUIESCENT;
    pthread_mutex_unlock(&diagnostic_lock);
    errno = saved_errno;
    return clean;
}

void dsh_lifecycle_resume(void) {
    int saved_errno = errno;
    pthread_mutex_lock(&diagnostic_lock);
    lifecycle_state = DSH_LIFECYCLE_RUNNING;
    lifecycle_generation++;
    pthread_mutex_unlock(&diagnostic_lock);
    errno = saved_errno;
}
