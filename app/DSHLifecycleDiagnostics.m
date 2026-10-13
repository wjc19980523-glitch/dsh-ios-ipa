#import "DSHLifecycleDiagnostics.h"
#import "DSHHarness.h"
#import "ISHShellExecutor.h"
#import "DSHGuestSessionLifecycle.h"
#include "../ish-arm64/fs/dsh-lifecycle.h"
#include <unistd.h>
#include <math.h>

static NSSet<NSString *> *diagnosticEventNames(void) {
    static NSSet *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = [NSSet setWithArray:@[@"sceneWillConnect", @"sceneDidEnterBackground", @"sceneWillEnterForeground",
            @"sceneDidBecomeActive", @"sceneWillResignActive", @"quiesceSnapshot", @"diagnosticReportExported",
            @"quiesceRequested", @"quiesceTaskDenied", @"quiesceExpired", @"quiesceWaiting", @"quiesceComplete",
            @"sessionQuiesceDriverException", @"backgroundDeferredDuringSessionResume", @"sessionCancelDriverException",
            @"sessionQuiesceAcknowledged", @"sessionQuiesceFailed", @"deferredBackgroundExpired",
            @"sessionResumeDriverException", @"sessionResumeTimedOut", @"sessionResumeFailed",
            @"sessionResumeReenteredBackground", @"foregroundResumed", @"guestStarted", @"guestExited",
            @"harnessRestartRequested", @"relaunchScheduled", @"healthRestartLimit", @"webContentProcessTerminated",
            @"webInterfaceLoaded", @"incompletePreviousBackground", @"harnessState", @"hostStarted", @"hostBootStarted",
            @"startupPerformance", @"harnessAnswered", @"harnessStartupTimedOut", @"harnessAuthenticationReady",
            @"supervisionPaused", @"supervisionResumed", @"sessionPatchVerified", @"sessionPatchInstallFailed",
            @"harnessLaunchRequested", @"webLoadFailed", @"downloadFailed", @"migrationFailed", @"webPatchVerified", @"webPatchInstallFailed"]];
    });
    return names;
}

static id safeMetadataValue(NSString *key, id value, NSUInteger depth) {
    if (depth > 5) return nil;
    static NSSet *numbers;
    static NSDictionary<NSString *, NSArray<NSString *> *> *enums;
    static NSSet *dictionaries, *arrays;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        numbers = [NSSet setWithArray:@[@"host_pid", @"host_started_epoch", @"guest_pid", @"health_generation",
            @"harness_restart_count", @"authentication_generation", @"suspend_count", @"resume_count",
            @"filesystem_state", @"quiescing", @"quiesce_generation", @"sampled_monotonic_ns",
            @"session_drain_active", @"session_drain_guest_tgid", @"session_drain_generation",
            @"active_operations", @"paused_tty_reads", @"active_fakefs_operations", @"active_fakefs_operations_complete",
            @"active_transactions", @"read_transactions", @"write_transactions", @"deferred_transactions",
            @"oldest_transaction_ms", @"native_flock_count", @"tracking_overflows", @"sqlite_busy_observations",
            @"sqlite_error_observations", @"recovery_blocked_connections", @"last_sqlite_result", @"native_close_failures",
            @"native_flock_event_total", @"native_flock_events_omitted", @"managed_guest_pid", @"guest_identity",
            @"registered", @"generation", @"ack_generation", @"transition_pending", @"poll_pending",
            @"writer_count", @"released_count", @"pending_events", @"cycle", @"core_generation",
            @"session_ack_required", @"session_acknowledged", @"session_recovery_needs_attention", @"wait_ms",
            @"id", @"host_fd", @"thread", @"guest_fd_at_last_lock", @"guest_tgid", @"started_monotonic_ns",
            @"age_ms", @"host_device", @"host_inode", @"identity_stat_errno", @"identity_path_errno",
            @"connection", @"mode", @"cached_autocommit", @"sqlite_result", @"recovery_required", @"recovery_result",
            @"observed_monotonic_ns", @"nesting", @"sequence", @"host_errno", @"actor_guest_pid",
            @"actor_thread", @"exit_code", @"install_error_code", @"attempt", @"attempt_limit", @"details_omitted", @"observed_epoch",
            @"duration_seconds", @"port", @"checkpoint_read_ms", @"checkpoint_hash_ms", @"checkpoint_serialized_bytes",
            @"drain_ms", @"close_ms", @"acquire_ms", @"active_writer_transitions", @"peak_writer_transitions", @"transition_ms", @"progress_generation"]];
        enums = @{@"harness_state": @[@"idle", @"starting", @"ready", @"restarting", @"failed", @"stopped"],
            @"desired_state": @[@"running", @"quiescing"], @"ack_state": @[@"none", @"running", @"quiesced", @"failed", @"exited"],
            @"error_code": @[@"none", @"checkpoint_changed", @"not_materialized", @"ownership_conflict", @"storage_failure", @"close_failure", @"transition_failed"],
            @"file_kind": @[@"session.lock", @"redacted", @"unavailable"],
            @"filesystem_kind": @[@"fake", @"real", @"other", @"unavailable"],
            @"type": @[@"LOCK_SH", @"LOCK_EX"],
            @"host_start_source": @[@"first_observation_sysctl_unavailable", @"kernel_process_start"],
            @"stage": @[@"image_preparation", @"guest_kernel_boot", @"web_interface_loaded"],
            @"phase": @[@"open", @"close_failed", @"sql_profile", @"finalize", @"step", @"step_timeout", @"retry_reset", @"retry_timeout", @"step_result", @"reset", @"prepare_failed", @"prepare_timeout", @"finalize_failed", @"begin_read", @"begin_write", @"commit", @"rollback", @"bind", @"invalid_stat", @"missing_inode", @"missing_link_source"]};
        dictionaries = [NSSet setWithArray:@[@"snapshot", @"guest_session_lifecycle", @"counts", @"lock", @"diagnostics", @"progress_diagnostics"]];
        arrays = [NSSet setWithArray:@[@"operations", @"transactions", @"native_flocks", @"native_flock_events"]];
    });
    if ([numbers containsObject:key]) {
        if (![value isKindOfClass:NSNumber.class] || !isfinite([value doubleValue])) return nil;
        BOOL flag = [@[@"quiescing", @"session_drain_active", @"active_fakefs_operations_complete", @"registered", @"transition_pending", @"poll_pending", @"session_ack_required", @"session_acknowledged", @"session_recovery_needs_attention", @"cached_autocommit", @"recovery_required", @"details_omitted"] containsObject:key];
        if (!flag && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return nil;
        BOOL fractional = [@[@"host_started_epoch", @"observed_epoch", @"wait_ms", @"duration_seconds"] containsObject:key];
        if (!fractional && floor([value doubleValue]) != [value doubleValue]) return nil;
        BOOL signedValue = [@[@"guest_pid", @"managed_guest_pid", @"session_drain_guest_tgid", @"host_fd", @"guest_fd_at_last_lock", @"guest_tgid", @"exit_code", @"install_error_code", @"actor_guest_pid", @"last_sqlite_result", @"sqlite_result", @"recovery_result", @"host_errno"] containsObject:key];
        if (!signedValue && [value doubleValue] < 0) return nil;
        return value;
    }
    if ([key isEqual:@"host_launch_id"]) {
        if (![value isKindOfClass:NSString.class]) return nil;
        return [[NSUUID alloc] initWithUUIDString:value].UUIDString;
    }
    if ([key isEqual:@"event"]) {
        if (![value isKindOfClass:NSString.class]) return nil;
        if ([diagnosticEventNames() containsObject:value] ||
            [@[@"acquired", @"updated", @"unlocked", @"closed", @"close_failed"] containsObject:value]) return value;
        return nil;
    }
    if (enums[key]) return [value isKindOfClass:NSString.class] && [enums[key] containsObject:value] ? value : nil;
    if ([key isEqual:@"entry"]) {
        if (![value isKindOfClass:NSString.class]) return nil;
        NSArray *fixed = @[@"fakefs_open", @"fakefs_open_inode", @"fakefs_link", @"fakefs_unlink", @"fakefs_rmdir", @"fakefs_rename", @"fakefs_symlink", @"fakefs_mknod", @"fakefs_stat", @"fakefs_fstat", @"fakefs_setattr", @"fakefs_fsetattr", @"fakefs_mkdir", @"fakefs_readlink", @"fakefs_readdir", @"fakefs_bind_mount", @"fakefs_bind_unmount", @"fakefs_mount", @"fakefs_umount", @"fakefs_inode_orphaned", @"fake_db_init", @"fake_db_deinit", @"realfs_open", @"realfs_close", @"realfs_stat", @"realfs_fstat", @"realfs_read", @"realfs_write", @"realfs_pread", @"realfs_pwrite", @"realfs_opendir", @"realfs_readdir", @"realfs_telldir", @"realfs_seekdir", @"realfs_lseek", @"realfs_mmap", @"realfs_readlink", @"realfs_getpath", @"realfs_link", @"realfs_unlink", @"realfs_rmdir", @"realfs_rename", @"realfs_symlink", @"realfs_mknod_with_effect", @"realfs_truncate", @"realfs_setattr", @"realfs_fsetattr", @"realfs_utime", @"realfs_mkdir", @"realfs_flock", @"realfs_statfs", @"realfs_mount", @"realfs_fsync", @"realfs_getflags", @"realfs_setflags", @"realfs_ioctl", @"guest_thread_cleanup", @"guest_group_exit", @"guest_wait_cleanup", @"sys_poll"];
        if ([fixed containsObject:value]) return value;
        // Syscall/interrupt labels are generated from numeric IDs, never args.
        if (value.length <= 40 && [[NSRegularExpression regularExpressionWithPattern:@"^guest_(?:syscall_[0-9]{1,10}|interrupt_-?[0-9]{1,10})$" options:0 error:nil] firstMatchInString:value options:0 range:NSMakeRange(0, [value length])]) return value;
        return @"unavailable";
    }
    if ([dictionaries containsObject:key] && [value isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *safe = [NSMutableDictionary new];
        for (id childKey in value) {
            if (![childKey isKindOfClass:NSString.class]) continue;
            if ([@[@"diagnostics", @"progress_diagnostics"] containsObject:key] &&
                ![@[@"checkpoint_read_ms", @"checkpoint_hash_ms", @"checkpoint_serialized_bytes", @"drain_ms", @"close_ms", @"acquire_ms", @"active_writer_transitions", @"peak_writer_transitions", @"transition_ms"] containsObject:childKey]) continue;
            id child = safeMetadataValue(childKey, value[childKey], depth + 1);
            if (child) safe[childKey] = child;
        }
        return safe;
    }
    if ([arrays containsObject:key] && [value isKindOfClass:NSArray.class]) {
        NSMutableArray *safe = [NSMutableArray new];
        for (id item in value) {
            if (safe.count >= 16) break;
            if ([item isKindOfClass:NSDictionary.class]) [safe addObject:safeMetadataValue(@"snapshot", item, depth + 1) ?: @{}];
        }
        return safe;
    }
    // Operation names, free-form errors, URLs, paths and user text deliberately
    // have no fallback. A key that merely looks non-sensitive is not trusted.
    return nil;
}

static NSDictionary *eventSnapshot(NSDictionary *event) {
    return [event[@"snapshot"] isKindOfClass:NSDictionary.class] ? event[@"snapshot"] : event;
}

static BOOL currentFailedACK(NSDictionary *snapshot) {
    NSDictionary *guest = snapshot[@"guest_session_lifecycle"];
    return [guest isKindOfClass:NSDictionary.class] && [guest[@"ack_state"] isEqual:@"failed"] &&
        [guest[@"registered"] boolValue] && [guest[@"generation"] unsignedLongLongValue] > 0 &&
        [guest[@"generation"] isEqual:guest[@"ack_generation"]] &&
        [guest[@"managed_guest_pid"] intValue] > 0 &&
        [guest[@"managed_guest_pid"] isEqual:snapshot[@"guest_pid"]] && [guest[@"guest_identity"] unsignedLongLongValue] > 0;
}

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
        @"harness_restart_count": @(harness.restartCount), @"authentication_generation": @(harness.authenticationGeneration),
        @"suspend_count": @(ISHShellExecutor.lifecycleSuspendCount), @"resume_count": @(ISHShellExecutor.lifecycleResumeCount),
        @"filesystem_state": @(s.state), @"quiescing": @(s.state == DSH_LIFECYCLE_QUIESCING),
        @"quiesce_generation": @(s.generation), @"sampled_monotonic_ns": @(s.sampled_monotonic_ns),
        @"session_drain_active": @(s.session_drain_active),
        @"session_drain_guest_tgid": @(s.session_drain_guest_tgid),
        @"session_drain_generation": @(s.session_drain_generation),
        @"guest_session_lifecycle": DSHGuestSessionLifecycle.shared.diagnosticSnapshot,
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

+ (NSDictionary *)sanitizedEvent:(NSDictionary *)event {
    if (![event isKindOfClass:NSDictionary.class]) return @{};
    NSMutableDictionary *safe = [safeMetadataValue(@"snapshot", event, 0) mutableCopy];
    NSData *encoded = [NSJSONSerialization dataWithJSONObject:safe options:0 error:nil];
    if (encoded.length > 32768) {
        // Keep classification counters/identities, not an unbounded detail dump.
        NSMutableDictionary *snapshot = [eventSnapshot(safe) mutableCopy];
        for (NSString *key in @[@"operations", @"transactions", @"native_flocks", @"native_flock_events"]) [snapshot removeObjectForKey:key];
        snapshot[@"details_omitted"] = @YES;
        if (safe[@"snapshot"]) safe[@"snapshot"] = snapshot; else safe = snapshot;
        if ([NSJSONSerialization dataWithJSONObject:safe options:0 error:nil].length > 32768) {
            // Malformed nested containers cannot evade the per-event byte cap.
            NSMutableDictionary *flat = [NSMutableDictionary new];
            for (NSString *key in snapshot) if (![snapshot[key] isKindOfClass:NSDictionary.class] && ![snapshot[key] isKindOfClass:NSArray.class]) flat[key] = snapshot[key];
            flat[@"details_omitted"] = @YES;
            if (safe[@"snapshot"]) {
                NSMutableDictionary *outer = [NSMutableDictionary new];
                for (NSString *key in safe) if (![safe[key] isKindOfClass:NSDictionary.class] && ![safe[key] isKindOfClass:NSArray.class]) outer[key] = safe[key];
                outer[@"snapshot"] = flat; safe = outer;
            } else safe = flat;
        }
    }
    return safe ?: @{};
}

+ (NSDictionary *)safeEventFromLogLine:(NSString *)line {
    if (![line isKindOfClass:NSString.class] || line.length > 262144) return nil;
    if ([line isEqual:@"[lifecycle] session patch verified"]) return @{@"event": @"sessionPatchVerified"};
    if ([line isEqual:@"[network] web transport patch verified"]) return @{@"event": @"webPatchVerified"};
    for (NSArray *pattern in @[@[@"^\\[lifecycle\\] session patch install failed code=(-?[0-9]+) operation=[^\\r\\n]*$", @"sessionPatchInstallFailed"],
        @[@"^\\[network\\] web transport patch install failed code=(-?[0-9]+) operation=[^\\r\\n]*$", @"webPatchInstallFailed"]]) {
        NSTextCheckingResult *installFailure = [[NSRegularExpression regularExpressionWithPattern:pattern[0] options:0 error:nil]
            firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
        if (installFailure) return @{@"event":pattern[1], @"install_error_code":@([[line substringWithRange:[installFailure rangeAtIndex:1]] longLongValue])};
    }
    NSRange marker = [line rangeOfString:@"[lifecycle] "];
    if (marker.location != NSNotFound) {
        if (marker.location && ![[NSRegularExpression regularExpressionWithPattern:@"^\\+\\s*[0-9.]+s $" options:0 error:nil]
            firstMatchInString:[line substringToIndex:marker.location] options:0 range:NSMakeRange(0, marker.location)]) return nil;
        NSString *body = [line substringFromIndex:NSMaxRange(marker)];
        NSRange start = [body rangeOfString:@"{"];
        if (start.location == NSNotFound) return nil;
        NSString *prefix = [[body substringToIndex:start.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        id object = [NSJSONSerialization JSONObjectWithData:[[body substringFromIndex:start.location] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        if (![object isKindOfClass:NSDictionary.class]) return nil;
        NSMutableDictionary *event = [object mutableCopy];
        if (prefix.length) event[@"event"] = prefix;
        if (![event[@"event"] isKindOfClass:NSString.class] || ![diagnosticEventNames() containsObject:event[@"event"]]) return nil;
        return [self sanitizedEvent:event];
    }
    NSDictionary *fixed = @{@"[dsh-ios] web content process terminated; reloading": @"webContentProcessTerminated",
        @"[dsh-ios] restart requested": @"harnessRestartRequested",
        @"[dsh-ios] giving up after repeated failures": @"healthRestartLimit",
        @"[dsh-ios] persistent crash-loop fuse is open": @"healthRestartLimit",
        @"[perf] app boot coordinator started": @"hostBootStarted",
        @"[dsh-ios] lifecycle: foreground supervision paused": @"supervisionPaused",
        @"[dsh-ios] lifecycle: foreground supervision resumed": @"supervisionResumed",
        @"[lifecycle] session patch verified": @"sessionPatchVerified"};
    if (fixed[line]) return @{@"event": fixed[line]};
    NSDictionary *errorPrefixes = @{@"[dsh-ios] page load failed: ":@"webLoadFailed", @"[dsh-ios] download failed: ":@"downloadFailed", @"[dsh-ios] migration problem: ":@"migrationFailed"};
    for (NSString *prefix in errorPrefixes) if ([line hasPrefix:prefix]) return @{@"event":errorPrefixes[prefix]};
    NSArray *patterns = @[
        @[@"^\\[dsh-ios\\] guest pid ([0-9]+)$", @"guestStarted", @"guest_pid"],
        @[@"^\\[dsh-ios\\] dsh-serve exited with code (-?[0-9]+)\\.$", @"guestExited", @"exit_code"],
        @[@"^\\[dsh-ios\\] relaunching in [0-9]+s \\(attempt ([0-9]+)/[0-9]+\\)$", @"relaunchScheduled", @"attempt"],
        @[@"^\\[dsh-ios\\] health check failed ([0-9]+) time\\(s\\) \\([^\\r\\n]*\\); restarting server$", @"healthRestartLimit", @"attempt"],
        @[@"^\\[perf\\] web interface loaded \\(harness ([0-9.]+)s\\)$", @"webInterfaceLoaded", @"duration_seconds"],
        @[@"^\\[perf\\] image preparation ([0-9.]+)s$", @"startupPerformance", @"duration_seconds"],
        @[@"^\\[perf\\] guest kernel boot ([0-9.]+)s$", @"startupPerformance", @"duration_seconds"],
        @[@"^\\[dsh-ios\\] server answered after ([0-9.]+)s$", @"harnessAnswered", @"duration_seconds"],
        @[@"^\\[dsh-ios\\] The harness did not (?:answer|announce its web URL) within ([0-9]+) seconds\\.$", @"harnessStartupTimedOut", @"duration_seconds"],
        @[@"^\\[dsh-ios\\] harness announced its web URL on port ([0-9]+); authentication token captured$", @"harnessAuthenticationReady", @"port"],
        @[@"^\\[dsh-ios\\] launching [^\\r\\n]+ on port ([0-9]+)$", @"harnessLaunchRequested", @"port"],
        @[@"^\\[dsh-ios\\] state -> (idle|starting|ready|restarting|failed|stopped)$", @"harnessState", @"harness_state"]];
    for (NSArray *pattern in patterns) {
        NSTextCheckingResult *match = [[NSRegularExpression regularExpressionWithPattern:pattern[0] options:0 error:nil] firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
        if (!match) continue;
        NSMutableDictionary *event = [@{@"event": pattern[1]} mutableCopy];
        if (match.numberOfRanges > 1) {
            NSString *value = [line substringWithRange:[match rangeAtIndex:1]];
            event[pattern[2]] = [pattern[2] isEqual:@"harness_state"] ? value : @([value doubleValue]);
        }
        if ([line hasPrefix:@"[perf] image preparation"]) event[@"stage"] = @"image_preparation";
        if ([line hasPrefix:@"[perf] guest kernel boot"]) event[@"stage"] = @"guest_kernel_boot";
        return event;
    }
    return nil;
}

+ (NSArray<NSDictionary<NSString *,NSString *> *> *)findingsForEvents:(NSArray<NSDictionary *> *)events currentHostLaunchID:(NSString *)hostLaunchID {
    hostLaunchID = [[NSUUID alloc] initWithUUIDString:hostLaunchID].UUIDString ?: @"";
    NSMutableArray *findings = [NSMutableArray new];
    NSMutableSet *seen = [NSMutableSet new], *hosts = [NSMutableSet new];
    NSMutableDictionary *lastGuest = [NSMutableDictionary new], *restarts = [NSMutableDictionary new], *latestGuest = [NSMutableDictionary new], *latestCore = [NSMutableDictionary new];
    for (NSDictionary *raw in events) {
        NSDictionary *event = [self sanitizedEvent:raw], *snapshot = eventSnapshot(event);
        if (![event[@"event"] isKindOfClass:NSString.class] || ![diagnosticEventNames() containsObject:event[@"event"]]) continue;
        NSString *host = snapshot[@"host_launch_id"] ?: event[@"host_launch_id"];
        if (!host) continue;
        NSDictionary *guest = snapshot[@"guest_session_lifecycle"];
        if ([guest[@"generation"] unsignedLongLongValue] >= [latestGuest[host][@"generation"] unsignedLongLongValue] && guest) latestGuest[host] = guest;
        if (snapshot[@"quiesce_generation"] &&
            [snapshot[@"quiesce_generation"] unsignedLongLongValue] >= [latestCore[host][@"quiesce_generation"] unsignedLongLongValue]) latestCore[host] = snapshot;
    }
    void (^add)(NSString *, NSString *) = ^(NSString *kind, NSString *detail) {
        if (![seen containsObject:kind]) { [seen addObject:kind]; [findings addObject:@{@"kind":kind, @"detail":detail}]; }
    };
    for (NSDictionary *raw in events) {
        NSDictionary *event = [self sanitizedEvent:raw], *snapshot = eventSnapshot(event);
        if (![event[@"event"] isKindOfClass:NSString.class] || ![diagnosticEventNames() containsObject:event[@"event"]]) continue;
        NSString *host = snapshot[@"host_launch_id"] ?: event[@"host_launch_id"];
        if (!host) continue; // No identity, no cross-process conclusion.
        [hosts addObject:host];
        NSString *name = event[@"event"];
        if ([@[@"guestExited", @"harnessRestartRequested", @"relaunchScheduled", @"healthRestartLimit"] containsObject:name]) restarts[host] = @YES;
        NSNumber *pid = snapshot[@"guest_pid"] ?: event[@"guest_pid"];
        if ([pid intValue] > 0) {
            NSNumber *identity = snapshot[@"guest_session_lifecycle"][@"guest_identity"];
            NSDictionary *previous = lastGuest[host];
            BOOL changed = previous && (![previous[@"pid"] isEqual:pid] ||
                ([previous[@"identity"] unsignedLongLongValue] > 0 && identity.unsignedLongLongValue > 0 && ![previous[@"identity"] isEqual:identity]));
            if (changed && [restarts[host] boolValue]) {
                add(@"guest_restart", @"同一应用进程内记录了服务重启及 guest 进程身份变化；这属于服务恢复。");
                restarts[host] = @NO;
            }
            lastGuest[host] = @{@"pid":pid, @"identity":identity ?: @0};
        }
        if ([name isEqual:@"webContentProcessTerminated"])
            add(@"web_content_terminated", @"已记录页面内容进程终止和重载请求；这条记录本身不能证明应用或服务重启。");
        if ([name isEqual:@"incompletePreviousBackground"])
            add(@"incomplete_background", @"上一应用进程留下未完成的后台协调记录；具体退出原因未确认。");
        if ([name isEqual:@"sessionResumeTimedOut"])
            add(@"session_restore_timeout", @"已记录会话恢复在有限期限内未完成；不能仅凭健康 HTTP 回应认定存储恢复成功。");
        BOOL current = [host isEqual:hostLaunchID];
        BOOL matchingCore = !event[@"core_generation"] || [event[@"core_generation"] isEqual:snapshot[@"quiesce_generation"]];
        if (matchingCore && snapshot[@"active_operations"] && snapshot[@"active_transactions"] &&
            [snapshot[@"filesystem_state"] unsignedIntegerValue] == DSH_LIFECYCLE_QUIESCING &&
            [snapshot[@"active_operations"] unsignedLongLongValue] == 0 && [snapshot[@"active_transactions"] unsignedLongLongValue] == 0 &&
            [snapshot[@"native_flock_count"] unsignedLongLongValue] > 0 && snapshot[@"tracking_overflows"] &&
            [snapshot[@"tracking_overflows"] unsignedLongLongValue] == 0 && [snapshot[@"active_fakefs_operations_complete"] boolValue])
            {
                BOOL latest = current && [snapshot[@"quiesce_generation"] isEqual:latestCore[host][@"quiesce_generation"]] &&
                    [latestCore[host][@"filesystem_state"] unsignedIntegerValue] == DSH_LIFECYCLE_QUIESCING;
                add(latest ? @"file_lock_wait" : @"historical_file_lock_wait",
                    latest ? @"最近后台协调记录中，操作与数据库事务为零，仍有文件锁阻止安全挂起；这不是系统终止原因的证明。" :
                    @"历史后台周期记录了文件锁阻止安全挂起；不能据此断定当前仍持锁或系统如何终止应用。");
            }
        NSDictionary *guest = snapshot[@"guest_session_lifecycle"];
        if (current && [guest[@"generation"] unsignedLongLongValue] > 0 &&
            [guest[@"progress_generation"] isEqual:guest[@"generation"]] && [guest[@"generation"] isEqual:latestGuest[host][@"generation"]] &&
            [guest[@"guest_identity"] isEqual:latestGuest[host][@"guest_identity"]] && [guest[@"managed_guest_pid"] intValue] > 0 &&
            [guest[@"managed_guest_pid"] isEqual:snapshot[@"guest_pid"]] && [guest[@"progress_diagnostics"] count]) {
            NSDictionary *progress = guest[@"progress_diagnostics"];
            NSString *(^timing)(NSString *) = ^NSString *(NSString *key) { return progress[key] ? [NSString stringWithFormat:@"%@ms", progress[key]] : @"未记录"; };
            add(@"session_transition_progress", [NSString stringWithFormat:@"当前 generation 匹配的最近阶段观测：drain %@，读取 %@，哈希 %@，关闭 %@，重获锁 %@。进度不等于 ACK 成功或安全挂起。", timing(@"drain_ms"), timing(@"checkpoint_read_ms"), timing(@"checkpoint_hash_ms"), timing(@"close_ms"), timing(@"acquire_ms")]);
        }
        if (current && currentFailedACK(snapshot) && [guest[@"generation"] isEqual:latestGuest[host][@"generation"]] &&
            [guest[@"guest_identity"] isEqual:latestGuest[host][@"guest_identity"]])
            add(@"session_ack_failed", [NSString stringWithFormat:@"当前代会话存储 ACK 失败（%@）；原数据与待写事件需要保留。", guest[@"error_code"] ?: @"transition_failed"]);
        else if ([guest[@"ack_state"] isEqual:@"failed"])
            add(@"historical_ack", @"存在历史或身份/代次不完整的失败 ACK；不能归因到当前周期。");
    }
    if (hosts.count > 1) add(@"new_host_launch", @"发现不同应用启动 ID；应用经历新启动，具体原因未确认，需匹配系统报告。");
    if (!findings.count) add(@"insufficient_evidence", @"当前保留记录不足以确认异常类别或系统终止原因。");
    return findings;
}
@end
