#import "DSHLifecycleDiagnostics.h"
#import "DSHHarness.h"
#import "ISHShellExecutor.h"
#include "../ish-arm64/fs/dsh-lifecycle.h"
#include <unistd.h>

@implementation DSHLifecycleDiagnostics
+ (NSDictionary *)snapshotForHarness:(DSHHarness *)harness event:(NSString *)event {
    struct dsh_lifecycle_snapshot s;
    dsh_lifecycle_get_snapshot(&s);
    NSMutableArray *transactions = [NSMutableArray new], *operations = [NSMutableArray new], *flocks = [NSMutableArray new];
    uint64_t oldest = 0;
    for (unsigned i = 0; i < s.transaction_count; i++) {
        struct dsh_lifecycle_transaction_snapshot t = s.transactions[i];
        oldest = MAX(oldest, t.age_ns);
        [transactions addObject:@{@"connection": @(t.connection_id), @"guest_pid": @(t.owner.guest_pid),
            @"thread": @(t.owner.thread_id), @"mode": @(t.mode), @"age_ms": @(t.age_ns / 1000000),
            @"cached_autocommit": @(t.cached_autocommit), @"sqlite_result": @(t.cached_result),
            @"observed_monotonic_ns": @(t.observed_monotonic_ns), @"phase": @(t.phase)}];
    }
    for (unsigned i = 0; i < s.operation_count; i++) {
        struct dsh_lifecycle_operation_snapshot o = s.operations[i];
        [operations addObject:@{@"id": @(o.id), @"entry": @(o.name), @"guest_pid": @(o.owner.guest_pid),
            @"thread": @(o.owner.thread_id), @"age_ms": @(o.age_ns / 1000000), @"nesting": @(o.nesting_depth)}];
    }
    for (unsigned i = 0; i < s.native_flock_count; i++) {
        struct dsh_lifecycle_flock_snapshot f = s.native_flocks[i];
        [flocks addObject:@{@"id": @(f.id), @"host_fd": @(f.host_fd), @"guest_pid": @(f.owner.guest_pid),
            @"thread": @(f.owner.thread_id), @"type": f.mode == DSH_LIFECYCLE_FLOCK_SHARED ? @"LOCK_SH" : @"LOCK_EX",
            @"started_monotonic_ns": @(f.started_monotonic_ns), @"age_ms": @(f.age_ns / 1000000)}];
    }
    // KVC preserves this diagnostic-only commit's compatibility with the old
    // supervisor; commit 2 exposes the request identity as a public property.
    NSString *generationKey = [harness respondsToSelector:NSSelectorFromString(@"healthCheckGeneration")]
        ? @"healthCheckGeneration" : @"healthCheckRetryGeneration";
    return @{@"event": event, @"host_launch_id": DSHLogBuffer.hostLaunchID,
        @"host_pid": @(getpid()), @"host_started_epoch": @(DSHLogBuffer.hostProcessStartedAt.timeIntervalSince1970),
        @"host_start_source": DSHLogBuffer.hostProcessStartSource,
        @"guest_pid": @(harness.guestPid), @"harness_state": DSHHarnessStateName(harness.state),
        @"health_generation": [harness valueForKey:generationKey] ?: @0,
        @"suspend_count": @(ISHShellExecutor.lifecycleSuspendCount), @"resume_count": @(ISHShellExecutor.lifecycleResumeCount),
        @"filesystem_state": @(s.state), @"quiescing": @(s.state == DSH_LIFECYCLE_QUIESCING),
        @"quiesce_generation": @(s.generation), @"sampled_monotonic_ns": @(s.sampled_monotonic_ns),
        @"active_fakefs_operations": @(s.active_fakefs_operations),
        @"active_fakefs_operations_complete": @(s.tracking_overflows == 0),
        @"fakefs_operation_counting": @"covered fakefs_ entry scopes; includes nesting, not unique syscalls",
        @"active_operations": @(s.active_operations), @"active_transactions": @(s.active_deferred_transactions + s.active_read_transactions + s.active_write_transactions),
        @"read_transactions": @(s.active_read_transactions), @"write_transactions": @(s.active_write_transactions),
        @"deferred_transactions": @(s.active_deferred_transactions), @"oldest_transaction_ms": @(oldest / 1000000),
        @"native_flock_count": @(s.active_native_flocks), @"tracking_overflows": @(s.tracking_overflows),
        @"sqlite_busy_observations": @(s.sqlite_busy_observations), @"sqlite_error_observations": @(s.sqlite_error_observations),
        @"last_sqlite_result": @(s.last_sqlite_result), @"native_close_failures": @(s.native_close_failures),
        @"sqlite_observation": @"cached on SQL owner thread; snapshot never calls SQLite",
        @"operations": operations, @"transactions": transactions, @"native_flocks": flocks};
}
+ (void)recordEvent:(NSString *)event harness:(DSHHarness *)harness {
    NSData *data = [NSJSONSerialization dataWithJSONObject:[self snapshotForHarness:harness event:event] options:NSJSONWritingSortedKeys error:nil];
    if (data) [harness.log append:[@"[lifecycle] " stringByAppendingString:[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]]];
    [harness.log synchronizePersistentDiagnostics];
}
@end
