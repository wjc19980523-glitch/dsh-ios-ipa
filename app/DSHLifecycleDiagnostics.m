#import "DSHLifecycleDiagnostics.h"
#import "DSHHarness.h"
#import "ISHShellExecutor.h"
#include "../ish-arm64/fs/dsh-lifecycle.h"
#include <unistd.h>

static NSDictionary *flockDetails(struct dsh_lifecycle_flock_snapshot f) {
    NSString *file = f.identity.file_kind == DSH_FLOCK_FILE_SESSION_LOCK ? @"session.lock" :
        f.identity.file_kind == DSH_FLOCK_FILE_OTHER ? @"redacted" : @"unavailable";
    NSString *fs = f.identity.fs_kind == DSH_FLOCK_FS_FAKE ? @"fake" :
        f.identity.fs_kind == DSH_FLOCK_FS_REAL ? @"real" :
        f.identity.fs_kind == DSH_FLOCK_FS_OTHER ? @"other" : @"unavailable";
    return @{@"id": @(f.id), @"host_fd": @(f.host_fd), @"guest_pid": @(f.owner.guest_pid),
        @"thread": @(f.owner.thread_id), @"guest_fd_at_last_lock": @(f.guest_fd), @"guest_tgid": @(f.guest_tgid),
        @"type": f.mode == DSH_LIFECYCLE_FLOCK_SHARED ? @"LOCK_SH" : @"LOCK_EX",
        @"started_monotonic_ns": @(f.started_monotonic_ns), @"age_ms": @(f.age_ns / 1000000),
        @"file_kind": file, @"filesystem_kind": fs,
        @"host_device": @(f.identity.device), @"host_inode": @(f.identity.inode),
        @"identity_stat_errno": @(f.identity.stat_error), @"identity_path_errno": @(f.identity.path_error)};
}

@implementation DSHLifecycleDiagnostics
+ (NSDictionary *)snapshotForHarness:(DSHHarness *)harness event:(NSString *)event {
    struct dsh_lifecycle_snapshot s;
    dsh_lifecycle_get_snapshot(&s);
    NSMutableArray *transactions = [NSMutableArray new], *operations = [NSMutableArray new], *flocks = [NSMutableArray new], *flockEvents = [NSMutableArray new];
    for (unsigned i = 0; i < s.transaction_count; i++) {
        struct dsh_lifecycle_transaction_snapshot t = s.transactions[i];
        [transactions addObject:@{@"connection": @(t.connection_id), @"guest_pid": @(t.owner.guest_pid),
            @"thread": @(t.owner.thread_id), @"mode": @(t.mode), @"age_ms": @(t.age_ns / 1000000),
            @"cached_autocommit": @(t.cached_autocommit), @"sqlite_result": @(t.cached_result),
            @"recovery_required": @(t.recovery_required),
            @"recovery_result": @(t.recovery_result),
            @"observed_monotonic_ns": @(t.observed_monotonic_ns), @"phase": @(t.phase)}];
    }
    for (unsigned i = 0; i < s.operation_count; i++) {
        struct dsh_lifecycle_operation_snapshot o = s.operations[i];
        [operations addObject:@{@"id": @(o.id), @"entry": @(o.name), @"guest_pid": @(o.owner.guest_pid),
            @"thread": @(o.owner.thread_id), @"age_ms": @(o.age_ns / 1000000), @"nesting": @(o.nesting_depth)}];
    }
    for (unsigned i = 0; i < s.native_flock_count; i++) {
        [flocks addObject:flockDetails(s.native_flocks[i])];
    }
    for (unsigned i = 0; i < s.native_flock_event_count; i++) {
        struct dsh_lifecycle_flock_event e = s.native_flock_events[i];
        NSArray *names = @[@"acquired", @"updated", @"unlocked", @"closed", @"close_failed"];
        [flockEvents addObject:@{@"sequence": @(e.sequence), @"event": names[e.kind],
            @"observed_monotonic_ns": @(e.observed_monotonic_ns), @"host_errno": @(e.result),
            @"actor_guest_pid": @(e.actor.guest_pid), @"actor_thread": @(e.actor.thread_id),
            @"lock": flockDetails(e.lock)}];
    }
    return @{@"event": event, @"host_launch_id": DSHLogBuffer.hostLaunchID,
        @"host_pid": @(getpid()), @"host_started_epoch": @(DSHLogBuffer.hostProcessStartedAt.timeIntervalSince1970),
        @"host_start_source": DSHLogBuffer.hostProcessStartSource,
        @"guest_pid": @(harness.guestPid), @"harness_state": DSHHarnessStateName(harness.state),
        @"health_generation": @(harness.healthCheckGeneration),
        @"suspend_count": @(ISHShellExecutor.lifecycleSuspendCount), @"resume_count": @(ISHShellExecutor.lifecycleResumeCount),
        @"filesystem_state": @(s.state), @"quiescing": @(s.state == DSH_LIFECYCLE_QUIESCING),
        @"quiesce_generation": @(s.generation), @"sampled_monotonic_ns": @(s.sampled_monotonic_ns),
        @"active_operations": @(s.active_operations), @"paused_tty_reads": @(s.paused_fileless_operations),
        @"active_fakefs_operations": @(s.active_fakefs_operations),
        @"active_fakefs_operations_complete": @(s.tracking_overflows == 0),
        @"fakefs_operation_counting": @"covered fakefs_ entry scopes; includes nesting, not unique syscalls",
        @"active_transactions": @(s.active_deferred_transactions + s.active_read_transactions + s.active_write_transactions),
        @"read_transactions": @(s.active_read_transactions), @"write_transactions": @(s.active_write_transactions),
        @"deferred_transactions": @(s.active_deferred_transactions), @"oldest_transaction_ms": @(s.oldest_transaction_age_ns / 1000000),
        @"native_flock_count": @(s.active_native_flocks), @"tracking_overflows": @(s.tracking_overflows),
        @"sqlite_busy_observations": @(s.sqlite_busy_observations), @"sqlite_error_observations": @(s.sqlite_error_observations),
        @"recovery_blocked_connections": @(s.recovery_blocked_connections),
        @"last_sqlite_result": @(s.last_sqlite_result), @"native_close_failures": @(s.native_close_failures),
        @"sqlite_observation": @"cached on SQL owner thread; snapshot never calls SQLite",
        @"flock_identity_observation": @"cached at successful host flock; file_kind is a strict whitelist; guest fd is from last successful flock, not a live fdtable probe",
        @"native_flock_event_total": @(s.native_flock_event_total),
        @"native_flock_events_omitted": @(s.native_flock_event_total - s.native_flock_event_count),
        @"native_flock_events": flockEvents,
        @"operations": operations, @"transactions": transactions, @"native_flocks": flocks};
}
+ (void)recordEvent:(NSString *)event harness:(DSHHarness *)harness {
    NSData *data = [NSJSONSerialization dataWithJSONObject:[self snapshotForHarness:harness event:event] options:NSJSONWritingSortedKeys error:nil];
    if (data) [harness.log append:[@"[lifecycle] " stringByAppendingString:[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]]];
    [harness.log synchronizePersistentDiagnostics];
}
+ (NSString *)reportForHarness:(DSHHarness *)harness {
    [self recordEvent:@"diagnosticReportExported" harness:harness];
    return harness.log.diagnosticReport;
}
@end
