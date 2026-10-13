#import <XCTest/XCTest.h>
#import "DSHLogBuffer.h"
#import "DSHLifecycleDiagnostics.h"

@interface DSHDiagnosticExportTests : XCTestCase
@property (nonatomic) NSURL *directory;
@end

@implementation DSHDiagnosticExportTests
- (void)setUp {
    [super setUp];
    self.directory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:self.directory withIntermediateDirectories:YES attributes:nil error:nil]);
}
- (void)tearDown {
    XCTAssertTrue([NSFileManager.defaultManager removeItemAtURL:self.directory error:nil]);
    [super tearDown];
}
- (DSHLogBuffer *)persistentLog {
    return [[DSHLogBuffer alloc] initPersistentWithCapacity:8 directory:self.directory];
}
- (void)appendEvent:(NSDictionary *)event toLog:(DSHLogBuffer *)log {
    NSData *data = [NSJSONSerialization dataWithJSONObject:event options:0 error:nil];
    XCTAssertNotNil(data);
    [log append:[@"[lifecycle] " stringByAppendingString:[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]]];
}
- (NSArray<NSURL *> *)filesWithPrefix:(NSString *)prefix {
    NSMutableArray *found = [NSMutableArray new];
    for (NSURL *url in [NSFileManager.defaultManager contentsOfDirectoryAtURL:self.directory includingPropertiesForKeys:nil options:0 error:nil])
        if ([url.lastPathComponent hasPrefix:prefix]) [found addObject:url];
    return found;
}
- (NSDictionary *)lockSnapshotForHost:(NSString *)host generation:(NSUInteger)generation {
    return @{@"host_launch_id":host, @"guest_pid":@101, @"filesystem_state":@1, @"quiesce_generation":@(generation),
        @"active_operations":@0, @"active_fakefs_operations":@0, @"active_fakefs_operations_complete":@YES,
        @"active_transactions":@0, @"native_flock_count":@1, @"tracking_overflows":@0,
        @"native_flocks":@[@{@"id":@17, @"file_kind":@"session.lock", @"type":@"LOCK_EX", @"age_ms":@12000,
            @"guest_pid":@110, @"guest_tgid":@101, @"filesystem_kind":@"fake"}]};
}
- (NSSet<NSString *> *)kinds:(NSArray<NSDictionary *> *)events {
    NSMutableSet *kinds = [NSMutableSet new];
    for (NSDictionary *finding in [DSHLifecycleDiagnostics findingsForEvents:events currentHostLaunchID:DSHLogBuffer.hostLaunchID]) [kinds addObject:finding[@"kind"]];
    return kinds;
}
- (void)testAttachmentIsARealUTF8TextFileAndExcludesFreeTextSecretsAndPaths {
    DSHLogBuffer *log = self.persistentLog;
    [log append:@"DEEPSEEK_API_KEY=credential-sentinel /root/private-workspace/body.txt"];
    [log append:@"user-body-sentinel without any credential keyword"];
    [log append:@"[dsh-ios] page load failed: url=https://sensitive-host/path?token=secret-token"];
    [self appendEvent:@{@"event":@"sessionResumeFailed", @"host_launch_id":DSHLogBuffer.hostLaunchID,
        @"url":@"https://secret-host", @"api_key":@"secret-json", @"body":@"body-json", @"path":@"/private/session-id",
        @"guest_session_lifecycle":@{@"diagnostics":@{@"checkpoint_hash_ms":@12, @"checkpoint_serialized_bytes":@1024, @"session_id":@"session-secret"}}} toLog:log];
    NSError *error = nil;
    NSURL *output = [log writeDiagnosticAttachmentInDirectory:[self.directory URLByAppendingPathComponent:@"exports" isDirectory:YES] error:&error];
    XCTAssertNotNil(output); XCTAssertNil(error); XCTAssertEqualObjects(output.pathExtension, @"txt");
    NSString *report = [NSString stringWithContentsOfURL:output encoding:NSUTF8StringEncoding error:&error];
    XCTAssertNotNil(report); XCTAssertNil(error);
    for (NSString *secret in @[@"credential-sentinel", @"private-workspace", @"user-body-sentinel", @"sensitive-host", @"secret-token", @"secret-json", @"body-json", @"session-id", @"session-secret"])
        XCTAssertFalse([report containsString:secret], @"Attachment leaked synthetic sentinel %@", secret);
    XCTAssertTrue([report containsString:@"Guest free-form output"]);
    XCTAssertTrue([report containsString:@"webLoadFailed"], @"Failure category remains visible even though its arbitrary error text is omitted");
    XCTAssertTrue([report containsString:@"checkpoint_hash_ms"]);
    XCTAssertTrue([report containsString:@"checkpoint_serialized_bytes"]);
    [log synchronizePersistentDiagnostics];
    for (NSURL *url in [self filesWithPrefix:@"launch-"]) {
        NSString *disk = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil];
        XCTAssertFalse([disk containsString:@"user-body-sentinel"]);
        XCTAssertFalse([disk containsString:@"credential-sentinel"]);
        XCTAssertFalse([disk containsString:@"private-workspace"]);
    }
}
- (void)testLegacyRawLogsAreSanitizedAgainAtExport {
    NSString *prior = NSUUID.UUID.UUIDString;
    NSURL *url = [self.directory URLByAppendingPathComponent:@"launch-20000101-legacy.log"];
    NSString *legacy = [NSString stringWithFormat:@"host_launch_id: %@\nAuthorization: Bearer legacy-token\nuser-body-legacy\n+ 1.0s [lifecycle] {\"event\":\"sceneDidEnterBackground\",\"host_launch_id\":\"%@\",\"path\":\"/root/legacy-secret\"}\n", prior, prior];
    XCTAssertTrue([legacy writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    NSString *report = self.persistentLog.diagnosticReport;
    XCTAssertTrue([report containsString:prior]);
    XCTAssertTrue([report containsString:@"sceneDidEnterBackground"]);
    for (NSString *secret in @[@"legacy-token", @"user-body-legacy", @"legacy-secret"]) XCTAssertFalse([report containsString:secret]);
}
- (void)testAttachmentFailureIsExplicitAndLeavesExistingFilesUnchanged {
    NSURL *sentinel = [self.directory URLByAppendingPathComponent:@"owned-sentinel.txt"];
    XCTAssertTrue([@"sentinel" writeToURL:sentinel atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    NSError *error = nil;
    XCTAssertNil([self.persistentLog writeDiagnosticAttachmentInDirectory:sentinel error:&error]);
    XCTAssertNotNil(error);
    XCTAssertEqualObjects([NSString stringWithContentsOfURL:sentinel encoding:NSUTF8StringEncoding error:nil], @"sentinel");
}
- (void)testTemporaryAttachmentsHaveABoundedCount {
    DSHLogBuffer *log = self.persistentLog;
    NSURL *exports = [self.directory URLByAppendingPathComponent:@"exports" isDirectory:YES];
    for (NSUInteger i = 0; i < 8; i++) XCTAssertNotNil([log writeDiagnosticAttachmentInDirectory:exports error:nil]);
    XCTAssertLessThanOrEqual([NSFileManager.defaultManager contentsOfDirectoryAtURL:exports includingPropertiesForKeys:nil options:0 error:nil].count, 3u);
}
- (void)testOneAbnormalCycleIsPinnedOnceAndItsWindowStopsGrowing {
    DSHLogBuffer *log = self.persistentLog;
    for (NSUInteger i = 0; i < 40; i++) [self appendEvent:@{@"event":@"sceneDidBecomeActive", @"health_generation":@(i)} toLog:log];
    NSDictionary *incident = @{@"event":@"quiesceExpired", @"cycle":@7, @"core_generation":@7, @"snapshot":[self lockSnapshotForHost:DSHLogBuffer.hostLaunchID generation:7]};
    [self appendEvent:incident toLog:log];
    for (NSUInteger i = 0; i < 30; i++) [self appendEvent:incident toLog:log];
    XCTAssertEqual(log.retainedIncidentCount, 1u);
    NSURL *file = [self filesWithPrefix:@"incident-"].firstObject;
    NSData *frozen = [NSData dataWithContentsOfURL:file];
    NSDictionary *saved = [NSJSONSerialization JSONObjectWithData:frozen options:0 error:nil];
    XCTAssertLessThanOrEqual([saved[@"events"] count], 40u);
    XCTAssertEqualObjects(saved[@"trigger"][@"event"], @"quiesceExpired");
    for (NSUInteger i = 0; i < 100; i++) [self appendEvent:@{@"event":@"sceneDidBecomeActive", @"health_generation":@(i + 100)} toLog:log];
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:file], frozen, @"Ordinary events cannot keep rewriting a closed incident window");
}
- (void)testIncidentAndLaunchStorageRemainBoundedAndOrdinaryLaunchRotationKeepsThePin {
    DSHLogBuffer *log = self.persistentLog;
    for (NSUInteger cycle = 1; cycle <= 12; cycle++) {
        [self appendEvent:@{@"event":@"sessionResumeTimedOut", @"cycle":@(cycle), @"snapshot":[self lockSnapshotForHost:DSHLogBuffer.hostLaunchID generation:cycle]} toLog:log];
    }
    XCTAssertEqual(log.retainedIncidentCount, 4u);
    NSURL *pin = [self filesWithPrefix:@"incident-"].lastObject;
    for (NSUInteger launch = 0; launch < 12; launch++) @autoreleasepool { (void)self.persistentLog; }
    XCTAssertLessThanOrEqual([self filesWithPrefix:@"launch-"].count, 10u);
    XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:pin.path]);
    for (NSURL *file in [self filesWithPrefix:@"incident-"]) {
        NSNumber *size = nil; [file getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        XCTAssertLessThanOrEqual(size.unsignedLongLongValue, 128u * 1024u);
    }
}
- (void)testLargeMetadataCompactsTheCurrentLaunchWithoutLosingNewestBoundary {
    DSHLogBuffer *log = self.persistentLog;
    NSMutableArray *locks = [NSMutableArray new];
    for (NSUInteger i = 0; i < 16; i++) [locks addObject:@{@"id":@(i), @"file_kind":@"session.lock", @"type":@"LOCK_EX", @"age_ms":@1000, @"host_inode":@123456789, @"guest_pid":@101}];
    for (NSUInteger i = 0; i < 180; i++) [self appendEvent:@{@"event":@"diagnosticReportExported", @"health_generation":@(i), @"native_flocks":locks, @"native_flock_events":locks} toLog:log];
    [self appendEvent:@{@"event":@"foregroundResumed", @"health_generation":@999} toLog:log];
    [log synchronizePersistentDiagnostics];
    for (NSURL *file in [self filesWithPrefix:@"launch-"]) {
        NSNumber *size = nil; [file getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        XCTAssertLessThanOrEqual(size.unsignedLongLongValue, 256u * 1024u);
    }
    XCTAssertTrue([log.diagnosticReport containsString:@"foregroundResumed"]);
}
- (void)testNewHostIsUnconfirmedAndCannotBeMistakenForGuestRestart {
    NSString *prior = NSUUID.UUID.UUIDString;
    NSArray *events = @[@{@"event":@"guestStarted", @"host_launch_id":prior, @"guest_pid":@101},
        @{@"event":@"guestStarted", @"host_launch_id":DSHLogBuffer.hostLaunchID, @"guest_pid":@102}];
    NSSet *kinds = [self kinds:events];
    XCTAssertTrue([kinds containsObject:@"new_host_launch"]);
    XCTAssertFalse([kinds containsObject:@"guest_restart"]);
    NSString *summary = [[[DSHLifecycleDiagnostics findingsForEvents:events currentHostLaunchID:DSHLogBuffer.hostLaunchID] valueForKey:@"detail"] componentsJoinedByString:@"\n"];
    XCTAssertFalse([summary containsString:@"DEAD10CC"]);
    XCTAssertTrue([summary containsString:@"未确认"]);
}
- (void)testGuestRestartRequiresSameHostAndExplicitRestartEvidence {
    NSString *host = DSHLogBuffer.hostLaunchID;
    NSDictionary *first = @{@"event":@"guestStarted", @"host_launch_id":host, @"guest_pid":@101};
    NSDictionary *second = @{@"event":@"guestStarted", @"host_launch_id":host, @"guest_pid":@102};
    XCTAssertFalse([[self kinds:@[first, second]] containsObject:@"guest_restart"]);
    XCTAssertTrue([[self kinds:@[first, @{@"event":@"guestExited", @"host_launch_id":host, @"exit_code":@9}, second]] containsObject:@"guest_restart"]);
}
- (void)testSamePIDRequiresTwoKnownDifferentGuestIdentities {
    NSString *host = DSHLogBuffer.hostLaunchID;
    NSDictionary *(^event)(NSNumber *) = ^NSDictionary *(NSNumber *identity) { return @{@"event":@"guestStarted", @"host_launch_id":host, @"guest_pid":@101, @"guest_session_lifecycle":@{@"guest_identity":identity}}; };
    NSDictionary *restart = @{@"event":@"harnessRestartRequested", @"host_launch_id":host};
    XCTAssertTrue([[self kinds:@[event(@1), restart, event(@2)]] containsObject:@"guest_restart"]);
    XCTAssertFalse([[self kinds:@[event(@0), restart, event(@2)]] containsObject:@"guest_restart"]);
}
- (void)testWebContentTerminationIsSeparateFromHostAndGuestRestart {
    DSHLogBuffer *log = self.persistentLog;
    [log append:@"[dsh-ios] guest pid 101"];
    [log append:@"[dsh-ios] web content process terminated; reloading"];
    XCTAssertTrue([log.diagnosticSummary containsString:@"web_content_terminated"]);
    XCTAssertFalse([log.diagnosticSummary containsString:@"guest_restart"]);
    XCTAssertFalse([log.diagnosticSummary containsString:@"new_host_launch"]);
}
- (void)testLockClassificationNeedsCompleteCountersAndMatchingGeneration {
    NSString *host = DSHLogBuffer.hostLaunchID;
    NSDictionary *snapshot = [self lockSnapshotForHost:host generation:7];
    XCTAssertTrue([[self kinds:@[@{@"event":@"quiesceWaiting", @"core_generation":@7, @"snapshot":snapshot}]] containsObject:@"file_lock_wait"]);
    XCTAssertFalse([[self kinds:@[@{@"event":@"quiesceWaiting", @"core_generation":@8, @"snapshot":snapshot}]] containsObject:@"file_lock_wait"]);
    NSMutableDictionary *incomplete = [snapshot mutableCopy]; incomplete[@"tracking_overflows"] = @1;
    XCTAssertFalse([[self kinds:@[@{@"event":@"quiesceWaiting", @"snapshot":incomplete}]] containsObject:@"file_lock_wait"]);
    incomplete = [snapshot mutableCopy]; [incomplete removeObjectForKey:@"active_operations"];
    XCTAssertFalse([[self kinds:@[@{@"event":@"quiesceWaiting", @"snapshot":incomplete}]] containsObject:@"file_lock_wait"]);
    incomplete = [snapshot mutableCopy]; incomplete[@"native_flock_count"] = @-1;
    XCTAssertFalse([[self kinds:@[@{@"event":@"quiesceWaiting", @"snapshot":incomplete}]] containsObject:@"file_lock_wait"]);
}
- (void)testFailedACKRequiresCurrentGenerationAndGuestIdentity {
    NSString *host = DSHLogBuffer.hostLaunchID;
    NSDictionary *guest = @{@"generation":@7, @"ack_generation":@7, @"ack_state":@"failed", @"registered":@YES, @"managed_guest_pid":@101, @"guest_identity":@3, @"error_code":@"ownership_conflict"};
    NSDictionary *current = @{@"event":@"sessionResumeFailed", @"host_launch_id":host, @"guest_pid":@101, @"guest_session_lifecycle":guest};
    XCTAssertTrue([[self kinds:@[current]] containsObject:@"session_ack_failed"]);
    NSMutableDictionary *staleGuest = [guest mutableCopy]; staleGuest[@"ack_generation"] = @6;
    NSMutableDictionary *stale = [current mutableCopy]; stale[@"guest_session_lifecycle"] = staleGuest;
    XCTAssertFalse([[self kinds:@[stale]] containsObject:@"session_ack_failed"]);
    XCTAssertTrue([[self kinds:@[stale]] containsObject:@"historical_ack"]);
    NSMutableDictionary *newGuest = [guest mutableCopy]; newGuest[@"generation"] = @8; newGuest[@"ack_generation"] = @8; newGuest[@"ack_state"] = @"running";
    NSMutableDictionary *newer = [current mutableCopy]; newer[@"guest_session_lifecycle"] = newGuest;
    XCTAssertFalse([[self kinds:@[current, newer]] containsObject:@"session_ack_failed"]);
}
- (void)testPreviousUnfinishedBackgroundAndResumeTimeoutAreVisibleWithoutClaimingSystemKill {
    NSString *oldHost = NSUUID.UUID.UUIDString;
    NSDictionary *old = @{@"event":@"quiesceExpired", @"host_launch_id":oldHost, @"cycle":@5, @"snapshot":[self lockSnapshotForHost:oldHost generation:5]};
    NSString *record = [NSString stringWithFormat:@"host_launch_id: %@\n[lifecycle] %@\n", oldHost, [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:old options:0 error:nil] encoding:NSUTF8StringEncoding]];
    XCTAssertTrue([record writeToURL:[self.directory URLByAppendingPathComponent:@"launch-20000101-previous.log"] atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    DSHLogBuffer *log = self.persistentLog;
    XCTAssertTrue([log.diagnosticSummary containsString:@"incomplete_background"]);
    XCTAssertTrue([log.diagnosticSummary containsString:@"new_host_launch"]);
    XCTAssertTrue([log.diagnosticSummary containsString:@"historical_file_lock_wait"]);
    [self appendEvent:@{@"event":@"sessionResumeTimedOut", @"host_launch_id":DSHLogBuffer.hostLaunchID, @"cycle":@1} toLog:log];
    XCTAssertTrue([log.diagnosticSummary containsString:@"session_restore_timeout"]);
    XCTAssertGreaterThanOrEqual(log.retainedIncidentCount, 1u);
}
- (void)testExplicitDiagnosticDeletionIsIdempotentAndKeepsUnrelatedSentinels {
    NSURL *sentinel = [self.directory URLByAppendingPathComponent:@"unrelated-user-sentinel.txt"];
    XCTAssertTrue([@"unchanged" writeToURL:sentinel atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    DSHLogBuffer *log = self.persistentLog;
    [self appendEvent:@{@"event":@"quiesceExpired", @"cycle":@3} toLog:log];
    XCTAssertEqual(log.retainedIncidentCount, 1u);
    [log clearRetainedDiagnostics]; [log clearRetainedDiagnostics];
    XCTAssertEqual(log.retainedIncidentCount, 0u); XCTAssertEqual(log.count, 0u);
    XCTAssertFalse([log.diagnosticReport containsString:@"quiesceExpired"]);
    XCTAssertEqualObjects([NSString stringWithContentsOfURL:sentinel encoding:NSUTF8StringEncoding error:nil], @"unchanged");
}
- (void)testUnknownEventsAndEmbeddedUserTextAreNotAcceptedAsLifecycleEvidence {
    XCTAssertNil([DSHLifecycleDiagnostics safeEventFromLogLine:@"user quoted [lifecycle] {\"event\":\"quiesceExpired\"}"]);
    XCTAssertNil([DSHLifecycleDiagnostics safeEventFromLogLine:@"[lifecycle] {\"event\":\"secret-event-name\",\"body\":\"secret-body\"}"]);
    XCTAssertNil([DSHLifecycleDiagnostics safeEventFromLogLine:@"[lifecycle] malformed"]);
    XCTAssertTrue([[self kinds:@[@{@"event":@"sceneDidBecomeActive"}]] containsObject:@"insufficient_evidence"]);
}
- (void)testNativeOperationAndSQLPhaseLabelsUseFixedWhitelists {
    NSDictionary *event = [DSHLifecycleDiagnostics sanitizedEvent:@{@"event":@"quiesceWaiting", @"operations":@[@{@"entry":@"fakefs_open"}, @{@"entry":@"guest_syscall_93"}, @{@"entry":@"/root/private-name"}], @"transactions":@[@{@"phase":@"step_timeout"}, @{@"phase":@"user-secret-phase"}]}];
    XCTAssertEqualObjects(event[@"operations"][0][@"entry"], @"fakefs_open");
    XCTAssertEqualObjects(event[@"operations"][1][@"entry"], @"guest_syscall_93");
    XCTAssertEqualObjects(event[@"operations"][2][@"entry"], @"unavailable");
    XCTAssertEqualObjects(event[@"transactions"][0][@"phase"], @"step_timeout");
    XCTAssertNil(event[@"transactions"][1][@"phase"]);
}
- (void)testWaitingPinIsUpgradedWithTheRealExpirationAfterItsInitialWindowCloses {
    DSHLogBuffer *log = self.persistentLog;
    NSDictionary *snapshot = [self lockSnapshotForHost:DSHLogBuffer.hostLaunchID generation:5];
    for (NSUInteger second = 1; second <= 20; second++)
        [self appendEvent:@{@"event":@"quiesceWaiting", @"cycle":@5, @"core_generation":@5, @"wait_ms":@(second * 1000), @"snapshot":snapshot} toLog:log];
    [self appendEvent:@{@"event":@"quiesceExpired", @"cycle":@5, @"core_generation":@5, @"wait_ms":@30000, @"snapshot":snapshot} toLog:log];
    XCTAssertEqual(log.retainedIncidentCount, 1u);
    NSURL *pin = [self filesWithPrefix:@"incident-"].firstObject;
    NSDictionary *saved = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:pin] options:0 error:nil];
    XCTAssertEqualObjects(saved[@"trigger"][@"event"], @"quiesceWaiting");
    XCTAssertEqualObjects(saved[@"terminal"][@"event"], @"quiesceExpired");
    XCTAssertEqualObjects(saved[@"terminal"][@"wait_ms"], @30000);
    XCTAssertLessThanOrEqual([saved[@"events"] count], 40u);
    for (NSUInteger launch = 0; launch < 12; launch++) @autoreleasepool { (void)self.persistentLog; }
    XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:pin.path]);
    XCTAssertTrue([self.persistentLog.diagnosticReport containsString:@"quiesceExpired"]);
}
- (void)testProgressTimingNeedsCurrentGuestAndGenerationAndNeverReusesOldACKTiming {
    NSDictionary *guest = @{@"generation":@9, @"ack_generation":@8, @"ack_state":@"running", @"guest_identity":@3, @"managed_guest_pid":@101,
        @"diagnostics":@{@"drain_ms":@999}, @"progress_generation":@9, @"progress_diagnostics":@{@"checkpoint_read_ms":@20, @"checkpoint_hash_ms":@30, @"checkpoint_serialized_bytes":@1000, @"host_pid":@123, @"session_id":@"private-session"}};
    NSDictionary *event = @{@"event":@"quiesceWaiting", @"host_launch_id":DSHLogBuffer.hostLaunchID, @"guest_pid":@101, @"guest_session_lifecycle":guest};
    XCTAssertTrue([[self kinds:@[event]] containsObject:@"session_transition_progress"]);
    NSString *summary = [[DSHLifecycleDiagnostics findingsForEvents:@[event] currentHostLaunchID:DSHLogBuffer.hostLaunchID] description];
    XCTAssertFalse([summary containsString:@"999ms"]);
    NSDictionary *safe = [DSHLifecycleDiagnostics sanitizedEvent:event];
    XCTAssertNil(safe[@"guest_session_lifecycle"][@"progress_diagnostics"][@"host_pid"]);
    XCTAssertNil(safe[@"guest_session_lifecycle"][@"progress_diagnostics"][@"session_id"]);
    NSMutableDictionary *old = [guest mutableCopy]; old[@"progress_generation"] = @8;
    NSMutableDictionary *staleEvent = [event mutableCopy]; staleEvent[@"guest_session_lifecycle"] = old;
    XCTAssertFalse([[self kinds:@[staleEvent]] containsObject:@"session_transition_progress"]);
}
- (void)testTransientLiveViewRedactsQuotedCredentialsAndFilesystemPaths {
    DSHLogBuffer *log = [[DSHLogBuffer alloc] initWithCapacity:8];
    [log append:@"{\"API_KEY\":\"quoted secret value\",\"DSH_HOST_BRIDGE_TOKEN\":\"bridge-secret\"}"];
    [log append:@"Authorization: Bearer bearer-secret /root/private-file"];
    [log append:@"failed to open /home/alice/private-session.json"];
    NSString *text = [log.lines componentsJoinedByString:@"\n"];
    for (NSString *secret in @[@"quoted secret value", @"bridge-secret", @"bearer-secret", @"private-file", @"alice", @"private-session"])
        XCTAssertFalse([text containsString:secret]);
    XCTAssertTrue([text containsString:@"<redacted>"]);
}
- (void)testBootPatchFailuresKeepOnlyTheNumericCodeAndPinTheEvidence {
    DSHLogBuffer *log = self.persistentLog;
    [log append:@"[network] web transport patch verified"];
    [log append:@"[network] web transport patch install failed code=7 operation=rename /root/private-network-session"];
    [log append:@"[lifecycle] session patch install failed code=9 operation=write /root/private-storage-session"];
    NSString *report = log.diagnosticReport;
    XCTAssertTrue([report containsString:@"webPatchVerified"]);
    XCTAssertTrue([report containsString:@"webPatchInstallFailed"]);
    XCTAssertTrue([report containsString:@"sessionPatchInstallFailed"]);
    XCTAssertTrue([report containsString:@"install_error_code"]);
    XCTAssertFalse([report containsString:@"private-network-session"]);
    XCTAssertFalse([report containsString:@"private-storage-session"]);
    XCTAssertEqual(log.retainedIncidentCount, 2u);
}
- (void)testStructuredExitAndItsFixedTextCompanionDoNotConsumeTwoPinnedSlots {
    DSHLogBuffer *log = self.persistentLog;
    [self appendEvent:@{@"event":@"guestExited", @"host_launch_id":DSHLogBuffer.hostLaunchID, @"guest_pid":@101, @"health_generation":@7} toLog:log];
    [log append:@"[dsh-ios] dsh-serve exited with code 9."];
    XCTAssertEqual(log.retainedIncidentCount, 1u);
    XCTAssertTrue([log.diagnosticReport containsString:@"exit_code"]);
}
@end
