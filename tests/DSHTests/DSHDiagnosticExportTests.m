#import <XCTest/XCTest.h>
#import "DSHLogBuffer.h"
#import "DSHLifecycleDiagnostics.h"

@interface DSHLogBuffer (DiagnosticExportReadTests)
- (nullable NSDictionary *)incidentAtURL:(NSURL *)url;
@end

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
    XCTAssertFalse(([[self kinds:@[first, second]] containsObject:@"guest_restart"]));
    XCTAssertTrue(([[self kinds:@[first, @{@"event":@"guestExited", @"host_launch_id":host, @"exit_code":@9}, second]] containsObject:@"guest_restart"]));
}
- (void)testSamePIDRequiresTwoKnownDifferentGuestIdentities {
    NSString *host = DSHLogBuffer.hostLaunchID;
    NSDictionary *(^event)(NSNumber *) = ^NSDictionary *(NSNumber *identity) { return @{@"event":@"guestStarted", @"host_launch_id":host, @"guest_pid":@101, @"guest_session_lifecycle":@{@"guest_identity":identity}}; };
    NSDictionary *restart = @{@"event":@"harnessRestartRequested", @"host_launch_id":host};
    XCTAssertTrue(([[self kinds:@[event(@1), restart, event(@2)]] containsObject:@"guest_restart"]));
    XCTAssertFalse(([[self kinds:@[event(@0), restart, event(@2)]] containsObject:@"guest_restart"]));
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
    XCTAssertTrue(([[self kinds:@[@{@"event":@"quiesceWaiting", @"core_generation":@7, @"snapshot":snapshot}]] containsObject:@"file_lock_wait"]));
    XCTAssertFalse(([[self kinds:@[@{@"event":@"quiesceWaiting", @"core_generation":@8, @"snapshot":snapshot}]] containsObject:@"file_lock_wait"]));
    NSMutableDictionary *incomplete = [snapshot mutableCopy]; incomplete[@"tracking_overflows"] = @1;
    XCTAssertFalse(([[self kinds:@[@{@"event":@"quiesceWaiting", @"snapshot":incomplete}]] containsObject:@"file_lock_wait"]));
    incomplete = [snapshot mutableCopy]; [incomplete removeObjectForKey:@"active_operations"];
    XCTAssertFalse(([[self kinds:@[@{@"event":@"quiesceWaiting", @"snapshot":incomplete}]] containsObject:@"file_lock_wait"]));
    incomplete = [snapshot mutableCopy]; incomplete[@"native_flock_count"] = @-1;
    XCTAssertFalse(([[self kinds:@[@{@"event":@"quiesceWaiting", @"snapshot":incomplete}]] containsObject:@"file_lock_wait"]));
}
- (void)testFailedACKRequiresCurrentGenerationAndGuestIdentity {
    NSString *host = DSHLogBuffer.hostLaunchID;
    NSDictionary *guest = @{@"generation":@7, @"ack_generation":@7, @"ack_state":@"failed", @"registered":@YES, @"managed_guest_pid":@101, @"guest_identity":@3, @"error_code":@"ownership_conflict"};
    NSDictionary *current = @{@"event":@"sessionResumeFailed", @"host_launch_id":host, @"guest_pid":@101, @"guest_session_lifecycle":guest};
    XCTAssertTrue(([[self kinds:@[current]] containsObject:@"session_ack_failed"]));
    NSMutableDictionary *staleGuest = [guest mutableCopy]; staleGuest[@"ack_generation"] = @6;
    NSMutableDictionary *stale = [current mutableCopy]; stale[@"guest_session_lifecycle"] = staleGuest;
    XCTAssertFalse(([[self kinds:@[stale]] containsObject:@"session_ack_failed"]));
    XCTAssertTrue(([[self kinds:@[stale]] containsObject:@"historical_ack"]));
    NSMutableDictionary *newGuest = [guest mutableCopy]; newGuest[@"generation"] = @8; newGuest[@"ack_generation"] = @8; newGuest[@"ack_state"] = @"running";
    NSMutableDictionary *newer = [current mutableCopy]; newer[@"guest_session_lifecycle"] = newGuest;
    XCTAssertFalse(([[self kinds:@[current, newer]] containsObject:@"session_ack_failed"]));
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
    XCTAssertTrue(([[self kinds:@[@{@"event":@"sceneDidBecomeActive"}]] containsObject:@"insufficient_evidence"]));
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
    XCTAssertTrue(([[self kinds:@[event]] containsObject:@"session_transition_progress"]));
    NSString *summary = [[DSHLifecycleDiagnostics findingsForEvents:@[event] currentHostLaunchID:DSHLogBuffer.hostLaunchID] description];
    XCTAssertFalse([summary containsString:@"999ms"]);
    NSDictionary *safe = [DSHLifecycleDiagnostics sanitizedEvent:event];
    XCTAssertNil(safe[@"guest_session_lifecycle"][@"progress_diagnostics"][@"host_pid"]);
    XCTAssertNil(safe[@"guest_session_lifecycle"][@"progress_diagnostics"][@"session_id"]);
    NSMutableDictionary *old = [guest mutableCopy]; old[@"progress_generation"] = @8;
    NSMutableDictionary *staleEvent = [event mutableCopy]; staleEvent[@"guest_session_lifecycle"] = old;
    XCTAssertFalse(([[self kinds:@[staleEvent]] containsObject:@"session_transition_progress"]));
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
- (void)testPreparedProofCountersAreNumericAndIsolatedFromPathsOrContents {
    NSDictionary *counters = @{@"prepared_verified_count":@4, @"background_full_decode_count":@0, @"raw_verified_bytes":@4096,
        @"raw_path":@"/root/private-proof", @"raw_contents":@"private-proof-body", @"session_id":@"private-proof-session"};
    NSDictionary *event = @{@"event":@"quiesceWaiting", @"host_launch_id":DSHLogBuffer.hostLaunchID,
        @"guest_session_lifecycle":@{@"diagnostics":counters, @"progress_generation":@9, @"progress_diagnostics":counters}};
    NSDictionary *safe = [DSHLifecycleDiagnostics sanitizedEvent:event];
    NSDictionary *expected = @{@"prepared_verified_count":@4, @"background_full_decode_count":@0, @"raw_verified_bytes":@4096};
    XCTAssertEqualObjects(safe[@"guest_session_lifecycle"][@"diagnostics"], expected);
    XCTAssertEqualObjects(safe[@"guest_session_lifecycle"][@"progress_diagnostics"], expected);
    DSHLogBuffer *log = self.persistentLog;
    [self appendEvent:event toLog:log];
    NSString *report = log.diagnosticReport;
    for (NSString *secret in @[@"private-proof", @"private-proof-body", @"private-proof-session"]) XCTAssertFalse([report containsString:secret]);
    for (NSString *key in expected) {
        for (id invalid in @[@YES, @-1, @0.5, @"private-proof-value"]) {
            NSMutableDictionary *values = [expected mutableCopy]; values[key] = invalid;
            NSDictionary *filtered = [DSHLifecycleDiagnostics sanitizedEvent:@{@"event":@"quiesceWaiting", @"guest_session_lifecycle":@{@"diagnostics":values}}];
            XCTAssertNil(filtered[@"guest_session_lifecycle"][@"diagnostics"][key]);
        }
    }
}
- (void)testLargeIndividuallyValidContextAndEventMergeProducesABoundedReadablePin {
    // Both inputs fit the public sanitizer's cap. Together they exceeded it
    // before the post-enrichment guard, making the one-event pin >128 KiB.
    NSArray *keys = @[@"host_pid", @"host_started_epoch", @"guest_pid", @"health_generation", @"harness_restart_count", @"authentication_generation", @"suspend_count", @"resume_count",
        @"filesystem_state", @"quiescing", @"quiesce_generation", @"sampled_monotonic_ns", @"session_drain_active", @"session_drain_guest_tgid", @"session_drain_generation", @"active_operations",
        @"paused_tty_reads", @"active_fakefs_operations", @"active_fakefs_operations_complete", @"active_transactions", @"read_transactions", @"write_transactions", @"deferred_transactions", @"oldest_transaction_ms",
        @"native_flock_count", @"tracking_overflows", @"sqlite_busy_observations", @"sqlite_error_observations", @"recovery_blocked_connections", @"last_sqlite_result", @"native_close_failures", @"native_flock_event_total",
        @"native_flock_events_omitted", @"managed_guest_pid", @"guest_identity", @"registered", @"generation", @"ack_generation", @"transition_pending", @"poll_pending",
        @"writer_count", @"released_count", @"pending_events", @"cycle", @"core_generation", @"session_ack_required", @"session_acknowledged", @"session_recovery_needs_attention",
        @"wait_ms", @"id", @"host_fd", @"thread", @"guest_fd_at_last_lock", @"guest_tgid", @"started_monotonic_ns", @"age_ms",
        @"host_device", @"host_inode", @"identity_stat_errno", @"identity_path_errno", @"connection", @"mode", @"cached_autocommit", @"sqlite_result"];
    NSMutableDictionary *fields = [NSMutableDictionary new];
    for (NSString *key in keys) fields[key] = @1;
    NSMutableArray *details = [NSMutableArray new];
    for (NSUInteger i = 0; i < 16; i++) [details addObject:[fields copy]];
    NSDictionary *context = @{@"event":@"sceneDidEnterBackground", @"host_launch_id":DSHLogBuffer.hostLaunchID,
        @"health_generation":@7, @"guest_session_lifecycle":@{@"native_flocks":details}};
    NSDictionary *trigger = @{@"event":@"quiesceExpired", @"cycle":@1, @"native_flocks":details};
    NSDictionary *safeContext = [DSHLifecycleDiagnostics sanitizedEvent:context];
    NSDictionary *safeTrigger = [DSHLifecycleDiagnostics sanitizedEvent:trigger];
    XCTAssertLessThanOrEqual([NSJSONSerialization dataWithJSONObject:safeContext options:0 error:nil].length, 32768u);
    XCTAssertLessThanOrEqual([NSJSONSerialization dataWithJSONObject:safeTrigger options:0 error:nil].length, 32768u);
    NSMutableDictionary *merged = [safeTrigger mutableCopy]; merged[@"guest_session_lifecycle"] = safeContext[@"guest_session_lifecycle"];
    XCTAssertGreaterThan([NSJSONSerialization dataWithJSONObject:merged options:0 error:nil].length, 32768u, @"The fixture must exercise post-enrichment growth");
    DSHLogBuffer *log = self.persistentLog;
    [self appendEvent:context toLog:log]; [self appendEvent:trigger toLog:log];
    XCTAssertEqual(log.retainedIncidentCount, 1u);
    NSURL *pin = [self filesWithPrefix:@"incident-"].firstObject;
    NSData *data = [NSData dataWithContentsOfURL:pin];
    XCTAssertNotNil(data); if (!data) return;
    XCTAssertLessThanOrEqual(data.length, 128u * 1024u);
    DSHLogBuffer *reader = self.persistentLog;
    NSDictionary *reopened = [reader incidentAtURL:pin];
    XCTAssertNotNil(reopened);
    XCTAssertEqualObjects(reopened[@"trigger"][@"event"], @"quiesceExpired");
    XCTAssertEqualObjects(reopened[@"terminal"][@"event"], @"quiesceExpired");
    XCTAssertTrue([reader.diagnosticReport containsString:@"quiesceExpired"]);
}
- (void)testWebFetchMetadataUsesFixedResultsErrorsAndSafeIntegerCounters {
    NSDictionary *valid = @{@"event":@"webFetchCompleted", @"guest_pid":@101, @"web_request_sequence":@0,
        @"web_duration_ms":@9007199254740991LL, @"web_result":@"success", @"web_error":@"none"};
    XCTAssertEqualObjects([DSHLifecycleDiagnostics sanitizedEvent:valid], valid);
    NSArray *errors = @[@"none", @"invalid_url", @"blocked_url", @"redirect_blocked", @"unsupported_content", @"too_large", @"timeout", @"aborted", @"dns", @"tls", @"connection_refused", @"proxy", @"other"];
    for (NSString *error in errors) {
        NSMutableDictionary *event = [valid mutableCopy]; event[@"web_result"] = @"failure"; event[@"web_error"] = error;
        NSDictionary *safe = [DSHLifecycleDiagnostics sanitizedEvent:event];
        XCTAssertEqualObjects(safe[@"web_result"], @"failure"); XCTAssertEqualObjects(safe[@"web_error"], error);
    }
    for (NSString *key in @[@"guest_pid", @"web_request_sequence", @"web_duration_ms"]) {
        for (id invalid in @[@YES, @-1, @0.5, @9007199254740992LL, @"private-counter", NSDecimalNumber.notANumber]) {
            NSMutableDictionary *event = [valid mutableCopy]; event[key] = invalid;
            XCTAssertNil([DSHLifecycleDiagnostics sanitizedEvent:event][key]);
        }
    }
    NSMutableDictionary *zeroPID = [valid mutableCopy]; zeroPID[@"guest_pid"] = @0;
    XCTAssertNil([DSHLifecycleDiagnostics sanitizedEvent:zeroPID][@"guest_pid"]);
    // Reading an HTTP error page can complete successfully at this boundary;
    // retain its numeric status without reclassifying the provider result.
    NSMutableDictionary *readableHTTPError = [valid mutableCopy]; readableHTTPError[@"web_http_status"] = @503;
    NSDictionary *httpSafe = [DSHLifecycleDiagnostics sanitizedEvent:readableHTTPError];
    XCTAssertEqualObjects(httpSafe[@"web_result"], @"success"); XCTAssertEqualObjects(httpSafe[@"web_http_status"], @503);
    for (id invalid in @[@YES, @99, @600, @200.5, @"private-http-status", NSDecimalNumber.notANumber]) {
        readableHTTPError[@"web_http_status"] = invalid;
        XCTAssertNil([DSHLifecycleDiagnostics sanitizedEvent:readableHTTPError][@"web_http_status"]);
    }
    NSMutableDictionary *unknown = [valid mutableCopy]; unknown[@"web_result"] = @"private-result"; unknown[@"web_error"] = @"/root/private-error";
    NSDictionary *filtered = [DSHLifecycleDiagnostics sanitizedEvent:unknown];
    XCTAssertNil(filtered[@"web_result"]); XCTAssertNil(filtered[@"web_error"]);
}
- (void)testWebFetchMetadataSurvivesDiskReopenAndTextAttachmentWithoutSensitiveValues {
    DSHLogBuffer *log = self.persistentLog;
    NSDictionary *failure = @{@"event":@"webFetchCompleted", @"guest_pid":@101, @"web_request_sequence":@41, @"web_duration_ms":@1234,
        @"web_result":@"failure", @"web_error":@"connection_refused", @"url":@"https://private-web-host/private-url?token=private-query",
        @"path":@"/root/private-web-path", @"message":@"private-web-message", @"body":@"private-web-body", @"credential":@"private-web-credential"};
    [self appendEvent:failure toLog:log];
    [self appendEvent:@{@"event":@"webFetchCompleted", @"guest_pid":@101, @"web_request_sequence":@42, @"web_duration_ms":@10, @"web_result":@"success", @"web_error":@"none", @"web_http_status":@503} toLog:log];
    [self appendEvent:@{@"event":@"webFetchCompleted", @"guest_pid":@101, @"web_request_sequence":@43, @"web_duration_ms":@20, @"web_result":@"private-web-result", @"web_error":@"private-web-error"} toLog:log];
    [log synchronizePersistentDiagnostics];
    DSHLogBuffer *reader = self.persistentLog;
    NSError *error = nil;
    NSURL *file = [reader writeDiagnosticAttachmentInDirectory:[self.directory URLByAppendingPathComponent:@"exports" isDirectory:YES] error:&error];
    XCTAssertNotNil(file); XCTAssertNil(error); XCTAssertEqualObjects(file.pathExtension, @"txt");
    NSString *text = [NSString stringWithContentsOfURL:file encoding:NSUTF8StringEncoding error:&error];
    XCTAssertNotNil(text); XCTAssertNil(error);
    NSMutableDictionary<NSNumber *, NSDictionary *> *completed = [NSMutableDictionary new];
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        NSDictionary *event = [DSHLifecycleDiagnostics safeEventFromLogLine:line];
        if ([event[@"event"] isEqual:@"webFetchCompleted"]) completed[event[@"web_request_sequence"]] = event;
    }
    XCTAssertEqual(completed.count, 3u);
    XCTAssertEqualObjects(completed[@41][@"guest_pid"], @101);
    XCTAssertEqualObjects(completed[@41][@"web_duration_ms"], @1234);
    XCTAssertEqualObjects(completed[@41][@"web_result"], @"failure");
    XCTAssertEqualObjects(completed[@41][@"web_error"], @"connection_refused");
    XCTAssertEqualObjects(completed[@41][@"host_launch_id"], DSHLogBuffer.hostLaunchID);
    XCTAssertEqualObjects(completed[@42][@"web_result"], @"success");
    XCTAssertEqualObjects(completed[@42][@"web_error"], @"none");
    XCTAssertEqualObjects(completed[@42][@"web_http_status"], @503);
    XCTAssertNil(completed[@43][@"web_result"]); XCTAssertNil(completed[@43][@"web_error"]);
    for (NSString *secret in @[@"private-web-host", @"private-url", @"private-query", @"private-web-path", @"private-web-message", @"private-web-body", @"private-web-credential", @"private-web-result", @"private-web-error"]) {
        XCTAssertFalse([text containsString:secret]);
        for (NSURL *url in [self filesWithPrefix:@"launch-"])
            XCTAssertFalse([[NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil] containsString:secret]);
    }
}
@end
