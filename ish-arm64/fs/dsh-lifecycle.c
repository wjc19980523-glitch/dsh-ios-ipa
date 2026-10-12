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
    bool paused_fileless;
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
static pthread_cond_t admission_changed = PTHREAD_COND_INITIALIZER;
static bool admission_enabled;
static struct operation_record operations[OPERATION_CAPACITY];
static struct connection_record connections[CONNECTION_CAPACITY];
static struct flock_record native_flocks[FLOCK_CAPACITY];
static struct dsh_lifecycle_flock_event flock_events[DSH_LIFECYCLE_SNAPSHOT_ITEMS];
static uint64_t flock_event_total;
static enum dsh_lifecycle_state lifecycle_state = DSH_LIFECYCLE_RUNNING;
static uint64_t lifecycle_generation;
static uint64_t last_resume_monotonic_ns;
static uint64_t next_id = 1;
static uint64_t next_thread_id = 1;
static uint64_t active_operations;
static uint64_t paused_fileless_operations;
static uint64_t open_connections;
static uint64_t tracking_overflows;
static uint64_t operations_after_quiesce;
static uint64_t sqlite_busy_observations;
static uint64_t sqlite_error_observations;
static uint64_t native_close_failures;
static int last_sqlite_result;
static bool session_drain_active;
static int session_drain_guest_tgid = -1;
static uint64_t session_drain_generation;
static _Thread_local uint64_t thread_id;
static _Thread_local unsigned operation_depth;
static _Thread_local int operation_guest_pid = -1;
static _Thread_local uint64_t paused_tty_token;
static _Thread_local struct dsh_lifecycle_guest_context guest_context = {-1, -1};

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

/* A pre-existing flock critical section may span multiple guest syscalls.
 * Its known owner must be able to finish the protected work and unlock; parking
 * it would itself preserve the host lock. Such work prevents quiescence until
 * the actual unlock/close is observed. We never release/recreate those locks.
 */
static bool owns_existing_critical_section(int guest_pid) {
    for (unsigned i = 0; i < FLOCK_CAPACITY; i++) {
        if (!native_flocks[i].key) continue;
        struct dsh_lifecycle_owner o = native_flocks[i].value.owner;
        if ((thread_id && o.thread_id == thread_id) || (guest_pid >= 0 && o.guest_pid == guest_pid)) return true;
    }
    for (unsigned i = 0; i < CONNECTION_CAPACITY; i++) {
        if (!connections[i].used) continue;
        struct dsh_lifecycle_transaction_snapshot *t = &connections[i].value;
        if (thread_id && t->owner.thread_id == thread_id &&
                (t->recovery_required || !t->cached_autocommit || t->mode != DSH_LIFECYCLE_TXN_DEFERRED)) return true;
    }
    return false;
}

/* The dispatcher establishes both immutable guest identifiers. Matching the
 * PID too prevents a host caller reusing a pthread from inheriting its group. */
static bool has_session_drain(int guest_pid) {
    return session_drain_active && session_drain_generation == lifecycle_generation &&
        (lifecycle_state == DSH_LIFECYCLE_QUIESCING || lifecycle_state == DSH_LIFECYCLE_RESUMING) &&
        guest_pid > 0 && guest_context.guest_pid == guest_pid &&
        guest_context.guest_tgid == session_drain_guest_tgid;
}

static void await_admission(int guest_pid) {
    while (admission_enabled && lifecycle_state != DSH_LIFECYCLE_RUNNING &&
            operation_depth == 0 && !owns_existing_critical_section(guest_pid) &&
            !has_session_drain(guest_pid))
        pthread_cond_wait(&admission_changed, &diagnostic_lock);
}

static uint64_t record_operation_begin(const char *name, int guest_pid) {
    uint64_t now = monotonic_ns();
    uint64_t token = next_id++;
    if (operation_depth == 0) operation_guest_pid = guest_pid;
    operation_depth++;
    active_operations++;
    if (lifecycle_state != DSH_LIFECYCLE_RUNNING) operations_after_quiesce++;
    unsigned i;
    for (i = 0; i < OPERATION_CAPACITY; i++) {
        if (operations[i].used) continue;
        operations[i].used = true;
        operations[i].paused_fileless = false;
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
    return token;
}

uint64_t dsh_lifecycle_operation_begin(const char *name, int guest_pid) {
    int saved_errno = errno;
    pthread_mutex_lock(&diagnostic_lock);
    await_admission(guest_pid);
    uint64_t token = record_operation_begin(name, guest_pid);
    pthread_mutex_unlock(&diagnostic_lock);
    errno = saved_errno;
    return token;
}

uint64_t dsh_lifecycle_try_operation_begin(const char *name, int guest_pid) {
    int saved_errno = errno;
    pthread_mutex_lock(&diagnostic_lock);
    uint64_t token = 0;
    // Native launch callers must never create fresh work merely because their
    // thread or init PID happens to own an unrelated old critical section.
    if (!admission_enabled || lifecycle_state == DSH_LIFECYCLE_RUNNING || operation_depth)
        token = record_operation_begin(name, guest_pid);
    pthread_mutex_unlock(&diagnostic_lock);
    errno = saved_errno;
    return token;
}

void dsh_lifecycle_operation_end(uint64_t token) {
    int saved_errno = errno;
    pthread_mutex_lock(&diagnostic_lock);
    bool found = (token & UNTRACKED_TOKEN) != 0;
    bool paused = false;
    for (unsigned i = 0; !found && i < OPERATION_CAPACITY; i++) {
        if (!operations[i].used || operations[i].value.id != token) continue;
        paused = operations[i].paused_fileless;
        operations[i].used = false;
        found = true;
    }
    if (found) {
        if (paused) {
            if (paused_fileless_operations > 0) paused_fileless_operations--;
            if (paused_tty_token == token) paused_tty_token = 0;
        } else {
            if (active_operations > 0) active_operations--;
            if (operation_depth > 0) operation_depth--;
        }
        if (operation_depth == 0) operation_guest_pid = -1;
    }
    pthread_mutex_unlock(&diagnostic_lock);
    errno = saved_errno;
}

unsigned dsh_lifecycle_operation_depth(void) {
    return operation_depth;
}

uint64_t dsh_lifecycle_pause_tty_read(void) {
    int saved_errno = errno;
    pthread_mutex_lock(&diagnostic_lock);
    uint64_t token = 0;
    if (operation_depth == 1 && !paused_tty_token && !tracking_overflows &&
            !native_close_failures && !owns_existing_critical_section(operation_guest_pid)) {
        for (unsigned i = 0; i < OPERATION_CAPACITY; i++) {
            struct operation_record *record = &operations[i];
            if (!record->used || record->paused_fileless ||
                    record->value.owner.thread_id != thread_id ||
                    record->value.nesting_depth != 1) continue;
            record->paused_fileless = true;
            token = paused_tty_token = record->value.id;
            active_operations--;
            paused_fileless_operations++;
            operation_depth = 0;
            operation_guest_pid = -1;
            break;
        }
    }
    pthread_mutex_unlock(&diagnostic_lock);
    errno = saved_errno;
    return token;
}

void dsh_lifecycle_resume_tty_read(uint64_t token) {
    int saved_errno = errno;
    if (!token) return;
    pthread_mutex_lock(&diagnostic_lock);
    if (paused_tty_token == token && operation_depth == 0) {
        // tty_read has returned with all of its locks released. Unlike a new
        // critical-section owner, a fileless reader has no work to drain and
        // must wait through both Quiescent and Resuming before guest copyout.
        while (admission_enabled && lifecycle_state != DSH_LIFECYCLE_RUNNING)
            pthread_cond_wait(&admission_changed, &diagnostic_lock);
        for (unsigned i = 0; i < OPERATION_CAPACITY; i++) {
            struct operation_record *record = &operations[i];
            if (!record->used || !record->paused_fileless || record->value.id != token) continue;
            record->paused_fileless = false;
            record->value.started_monotonic_ns = monotonic_ns();
            operation_guest_pid = record->value.owner.guest_pid;
            operation_depth = 1;
            active_operations++;
            paused_fileless_operations--;
            paused_tty_token = 0;
            break;
        }
    }
    pthread_mutex_unlock(&diagnostic_lock);
    errno = saved_errno;
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

enum dsh_lifecycle_flock_file_kind dsh_lifecycle_flock_classify_path(const char *path) {
    if (path == NULL || *path == '\0') return DSH_FLOCK_FILE_UNKNOWN;
    const char *slash = strrchr(path, '/');
    return strcmp(slash ? slash + 1 : path, "session.lock") == 0
        ? DSH_FLOCK_FILE_SESSION_LOCK : DSH_FLOCK_FILE_OTHER;
}

/* diagnostic_lock held; bounded memory only, no callbacks or I/O. */
static void flock_event(const struct dsh_lifecycle_flock_snapshot *value,
        enum dsh_lifecycle_flock_event_kind kind, int result, uint64_t now) {
    struct dsh_lifecycle_flock_event *event = &flock_events[flock_event_total % DSH_LIFECYCLE_SNAPSHOT_ITEMS];
    *event = (struct dsh_lifecycle_flock_event) {
        .sequence = ++flock_event_total, .observed_monotonic_ns = now,
        .kind = kind, .result = result, .actor = owner(operation_guest_pid), .lock = *value,
    };
    event->lock.age_ns = now >= value->started_monotonic_ns ? now - value->started_monotonic_ns : 0;
}

void dsh_lifecycle_native_flock_update(const void *key, int host_fd, int guest_pid,
        enum dsh_lifecycle_flock_mode mode) {
    dsh_lifecycle_native_flock_observe(key, host_fd, guest_pid, mode, NULL);
}

void dsh_lifecycle_native_flock_observe(const void *key, int host_fd, int guest_pid,
        enum dsh_lifecycle_flock_mode mode, const struct dsh_lifecycle_flock_identity *identity) {
    int saved_errno = errno;
    if (key == NULL) return;
    uint64_t now = monotonic_ns();
    pthread_mutex_lock(&diagnostic_lock);
    unsigned empty = FLOCK_CAPACITY;
    for (unsigned i = 0; i < FLOCK_CAPACITY; i++) {
        if (native_flocks[i].key == key) {
            if (mode == DSH_LIFECYCLE_FLOCK_UNLOCKED) {
                flock_event(&native_flocks[i].value, DSH_FLOCK_UNLOCKED, 0, now);
                native_flocks[i].key = NULL;
            } else {
                native_flocks[i].value.mode = mode;
                native_flocks[i].value.owner = owner(guest_pid);
                native_flocks[i].value.guest_fd = -1;
                native_flocks[i].value.guest_tgid = -1;
                if (identity) native_flocks[i].value.identity = *identity;
                flock_event(&native_flocks[i].value, DSH_FLOCK_UPDATED, 0, now);
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
                .guest_fd = -1, .guest_tgid = -1,
            };
            if (identity) native_flocks[empty].value.identity = *identity;
            flock_event(&native_flocks[empty].value, DSH_FLOCK_ACQUIRED, 0, now);
        }
    }
    pthread_mutex_unlock(&diagnostic_lock);
    errno = saved_errno;
}

void dsh_lifecycle_native_flock_guest_fd(const void *key, int guest_pid, int guest_fd, int guest_tgid) {
    int saved_errno = errno;
    pthread_mutex_lock(&diagnostic_lock);
    for (unsigned i = 0; key && i < FLOCK_CAPACITY; i++) {
        struct dsh_lifecycle_flock_snapshot *value = &native_flocks[i].value;
        if (native_flocks[i].key != key || value->owner.guest_pid != guest_pid) continue;
        value->guest_fd = guest_fd;
        value->guest_tgid = guest_tgid;
        /* Fill the just-recorded acquisition/update too. A concurrent close
         * or conversion by a different actor must not be relabelled. */
        unsigned count = flock_event_total < DSH_LIFECYCLE_SNAPSHOT_ITEMS
            ? (unsigned) flock_event_total : DSH_LIFECYCLE_SNAPSHOT_ITEMS;
        for (unsigned n = 0; n < count; n++) {
            struct dsh_lifecycle_flock_event *event = &flock_events[(flock_event_total - 1 - n) % DSH_LIFECYCLE_SNAPSHOT_ITEMS];
            if (event->lock.id != value->id || event->lock.owner.thread_id != value->owner.thread_id ||
                    (event->kind != DSH_FLOCK_ACQUIRED && event->kind != DSH_FLOCK_UPDATED)) continue;
            event->lock.guest_fd = guest_fd;
            event->lock.guest_tgid = guest_tgid;
            break;
        }
        break;
    }
    pthread_mutex_unlock(&diagnostic_lock);
    errno = saved_errno;
}

void dsh_lifecycle_native_flock_close(const void *key) {
    int saved_errno = errno;
    pthread_mutex_lock(&diagnostic_lock);
    for (unsigned i = 0; key && i < FLOCK_CAPACITY; i++) {
        if (native_flocks[i].key != key) continue;
        flock_event(&native_flocks[i].value, DSH_FLOCK_CLOSED, 0, monotonic_ns());
        native_flocks[i].key = NULL;
        break;
    }
    pthread_mutex_unlock(&diagnostic_lock);
    errno = saved_errno;
}

void dsh_lifecycle_native_flock_close_failed(const void *key) {
    dsh_lifecycle_native_flock_close_error(key, errno);
}

void dsh_lifecycle_native_flock_close_error(const void *key, int error) {
    int saved_errno = errno;
    pthread_mutex_lock(&diagnostic_lock);
    for (unsigned i = 0; i < FLOCK_CAPACITY; i++) {
        if (native_flocks[i].key != key || key == NULL) continue;
        native_close_failures++;
        flock_event(&native_flocks[i].value, DSH_FLOCK_CLOSE_FAILED, error, monotonic_ns());
        break;
    }
    pthread_mutex_unlock(&diagnostic_lock);
    errno = saved_errno;
}

void dsh_lifecycle_native_close_uncertain(void) {
    int saved_errno = errno;
    pthread_mutex_lock(&diagnostic_lock);
    native_close_failures++;
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
    snapshot->last_resume_monotonic_ns = last_resume_monotonic_ns;
    snapshot->active_operations = active_operations;
    snapshot->paused_fileless_operations = paused_fileless_operations;
    snapshot->open_connections = open_connections;
    snapshot->tracking_overflows = tracking_overflows;
    snapshot->operations_after_quiesce = operations_after_quiesce;
    snapshot->sqlite_busy_observations = sqlite_busy_observations;
    snapshot->sqlite_error_observations = sqlite_error_observations;
    snapshot->native_close_failures = native_close_failures;
    snapshot->session_drain_active = session_drain_active;
    snapshot->session_drain_guest_tgid = session_drain_guest_tgid;
    snapshot->session_drain_generation = session_drain_generation;
    snapshot->last_sqlite_result = last_sqlite_result;
    snapshot->native_flock_event_total = flock_event_total;
    snapshot->native_flock_event_count = flock_event_total < DSH_LIFECYCLE_SNAPSHOT_ITEMS
        ? (unsigned) flock_event_total : DSH_LIFECYCLE_SNAPSHOT_ITEMS;
    uint64_t first_event = flock_event_total - snapshot->native_flock_event_count;
    for (unsigned i = 0; i < snapshot->native_flock_event_count; i++)
        snapshot->native_flock_events[i] = flock_events[(first_event + i) % DSH_LIFECYCLE_SNAPSHOT_ITEMS];
    for (unsigned i = 0; i < OPERATION_CAPACITY; i++) {
        if (!operations[i].used || operations[i].paused_fileless) continue;
        if (strncmp(operations[i].value.name, "fakefs_", 7) == 0)
            snapshot->active_fakefs_operations++;
        if (snapshot->operation_count == DSH_LIFECYCLE_SNAPSHOT_ITEMS) continue;
        struct dsh_lifecycle_operation_snapshot *value =
            &snapshot->operations[snapshot->operation_count++];
        *value = operations[i].value;
        value->age_ns = now >= value->started_monotonic_ns ? now - value->started_monotonic_ns : 0;
    }
    for (unsigned i = 0; i < CONNECTION_CAPACITY; i++) {
        if (!connections[i].used) continue;
        struct dsh_lifecycle_transaction_snapshot *cached = &connections[i].value;
        if (cached->recovery_required) snapshot->recovery_blocked_connections++;
        bool active = !cached->cached_autocommit || cached->mode != DSH_LIFECYCLE_TXN_DEFERRED;
        if (!active && !cached->recovery_required) continue;
        if (active) {
            if (cached->mode == DSH_LIFECYCLE_TXN_WRITE) snapshot->active_write_transactions++;
            else if (cached->mode == DSH_LIFECYCLE_TXN_READ) snapshot->active_read_transactions++;
            else snapshot->active_deferred_transactions++;
            uint64_t age = now >= cached->started_monotonic_ns ? now - cached->started_monotonic_ns : 0;
            if (age > snapshot->oldest_transaction_age_ns) snapshot->oldest_transaction_age_ns = age;
        }
        if (snapshot->transaction_count == DSH_LIFECYCLE_SNAPSHOT_ITEMS) continue;
        struct dsh_lifecycle_transaction_snapshot *value =
            &snapshot->transactions[snapshot->transaction_count++];
        *value = *cached;
        value->age_ns = active && value->started_monotonic_ns && now >= value->started_monotonic_ns
            ? now - value->started_monotonic_ns : 0;
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
    if (lifecycle_state == DSH_LIFECYCLE_RUNNING || lifecycle_state == DSH_LIFECYCLE_RESUMING) {
        lifecycle_state = DSH_LIFECYCLE_QUIESCING;
        lifecycle_generation++;
        session_drain_active = false;
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
        tracking_overflows == 0 && native_close_failures == 0 && !session_drain_active;
    for (unsigned i = 0; clean && i < CONNECTION_CAPACITY; i++)
        if (connections[i].used && (connections[i].value.recovery_required || !connections[i].value.cached_autocommit ||
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
    if (lifecycle_state != DSH_LIFECYCLE_RUNNING) {
        lifecycle_state = DSH_LIFECYCLE_RUNNING;
        lifecycle_generation++;
        last_resume_monotonic_ns = monotonic_ns();
    }
    session_drain_active = false;
    pthread_cond_broadcast(&admission_changed);
    pthread_mutex_unlock(&diagnostic_lock);
    errno = saved_errno;
}

void dsh_lifecycle_enable_admission_gate(void) {
    pthread_mutex_lock(&diagnostic_lock);
    admission_enabled = true;
    pthread_mutex_unlock(&diagnostic_lock);
}

void dsh_lifecycle_begin_resume(void) {
    pthread_mutex_lock(&diagnostic_lock);
    if (lifecycle_state != DSH_LIFECYCLE_RUNNING && lifecycle_state != DSH_LIFECYCLE_RESUMING) {
        lifecycle_state = DSH_LIFECYCLE_RESUMING;
        lifecycle_generation++;
        session_drain_active = false;
    }
    pthread_mutex_unlock(&diagnostic_lock);
}

void dsh_lifecycle_checkpoint(int guest_pid) {
    int saved_errno = errno;
    pthread_mutex_lock(&diagnostic_lock);
    await_admission(guest_pid);
    pthread_mutex_unlock(&diagnostic_lock);
    errno = saved_errno;
}

void dsh_lifecycle_thread_exit(void) {
    pthread_mutex_lock(&diagnostic_lock);
    // pthread_exit skips C cleanup attributes. Its outer task cleanup runs only
    // after do_exit has released fds, so it can retire these operation permits.
    // SQL/host-lock observations are deliberately retained if not really ended.
    for (unsigned i = 0; i < OPERATION_CAPACITY; i++) {
        if (operations[i].used && operations[i].value.owner.thread_id == thread_id) {
            if (operations[i].paused_fileless && paused_fileless_operations > 0)
                paused_fileless_operations--;
            operations[i].used = false;
        }
    }
    active_operations = active_operations >= operation_depth ? active_operations - operation_depth : 0;
    operation_depth = 0;
    operation_guest_pid = -1;
    paused_tty_token = 0;
    guest_context = (struct dsh_lifecycle_guest_context) {-1, -1};
    pthread_mutex_unlock(&diagnostic_lock);
}

struct dsh_lifecycle_guest_context dsh_lifecycle_exchange_guest_context(
        struct dsh_lifecycle_guest_context context) {
    struct dsh_lifecycle_guest_context previous = guest_context;
    /* Treat partially populated/native identities conservatively. */
    guest_context = context.guest_pid > 0 && context.guest_tgid > 0 ? context :
        (struct dsh_lifecycle_guest_context) {-1, -1};
    return previous;
}

bool dsh_lifecycle_grant_session_drain(int guest_tgid, uint64_t generation) {
    int saved_errno = errno;
    pthread_mutex_lock(&diagnostic_lock);
    bool accepted = false;
    if (guest_tgid > 0 && generation != 0 && generation == lifecycle_generation &&
            (lifecycle_state == DSH_LIFECYCLE_QUIESCING || lifecycle_state == DSH_LIFECYCLE_RESUMING)) {
        if (session_drain_generation != generation) {
            session_drain_guest_tgid = guest_tgid;
            session_drain_generation = generation;
            session_drain_active = true;
            accepted = true;
        } else accepted = session_drain_active && session_drain_guest_tgid == guest_tgid;
        if (accepted) pthread_cond_broadcast(&admission_changed);
    }
    pthread_mutex_unlock(&diagnostic_lock);
    errno = saved_errno;
    return accepted;
}

bool dsh_lifecycle_revoke_session_drain(int guest_tgid, uint64_t generation) {
    int saved_errno = errno;
    pthread_mutex_lock(&diagnostic_lock);
    bool matched = guest_tgid > 0 && generation == lifecycle_generation &&
        generation == session_drain_generation && guest_tgid == session_drain_guest_tgid;
    if (matched) session_drain_active = false;
    pthread_mutex_unlock(&diagnostic_lock);
    errno = saved_errno;
    return matched;
}

void dsh_lifecycle_sqlite_recovery_required(uint64_t connection_id, int result) {
    int saved_errno = errno;
    pthread_mutex_lock(&diagnostic_lock);
    struct connection_record *connection = find_connection(connection_id);
    if (connection) {
        if (!connection->value.recovery_required) connection->value.recovery_result = result;
        connection->value.recovery_required = true;
        connection->value.cached_result = result;
    } else tracking_overflows++;
    pthread_mutex_unlock(&diagnostic_lock);
    errno = saved_errno;
}

void dsh_lifecycle_sqlite_recovery_resolved(uint64_t connection_id) {
    int saved_errno = errno;
    pthread_mutex_lock(&diagnostic_lock);
    struct connection_record *connection = find_connection(connection_id);
    if (connection && thread_id && connection->value.owner.thread_id == thread_id) {
        connection->value.recovery_required = false;
        connection->value.recovery_result = 0;
    }
    pthread_mutex_unlock(&diagnostic_lock);
    errno = saved_errno;
}
