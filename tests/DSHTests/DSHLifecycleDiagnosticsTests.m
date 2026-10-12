#import <XCTest/XCTest.h>
#import "DSHLifecycleDiagnostics.h"
#import "DSHHarness.h"
#include "../../ish-arm64/fs/dsh-lifecycle.h"

@interface DSHLifecycleDiagnosticsTests : XCTestCase @end
@implementation DSHLifecycleDiagnosticsTests
- (void)testLaunchIdentityAndProcessTimestampAreStable {
    XCTAssertGreaterThan(DSHLogBuffer.hostLaunchID.length, 20u);
    XCTAssertEqualObjects(DSHLogBuffer.hostLaunchID, DSHLogBuffer.hostLaunchID);
    XCTAssertLessThanOrEqual(DSHLogBuffer.hostProcessStartedAt.timeIntervalSinceNow, 0);
}
- (void)testSnapshotContainsLifecycleAndLockOwnersWithoutPaths {
    uint64_t op = dsh_lifecycle_operation_begin("fakefs_diagnostic_test", 91);
    NSDictionary *s = [DSHLifecycleDiagnostics snapshotForHarness:DSHHarness.shared event:@"test"];
    XCTAssertEqualObjects(s[@"host_launch_id"], DSHLogBuffer.hostLaunchID);
    XCTAssertEqualObjects(s[@"event"], @"test");
    XCTAssertNotNil(s[@"health_generation"]);
    XCTAssertNotNil(s[@"paused_tty_reads"]);
    XCTAssertGreaterThanOrEqual([s[@"active_operations"] unsignedLongLongValue], 1u);
    XCTAssertGreaterThanOrEqual([s[@"active_fakefs_operations"] unsignedLongLongValue], 1u);
    XCTAssertEqualObjects(s[@"active_fakefs_operations_complete"], @([s[@"tracking_overflows"] unsignedLongLongValue] == 0));
    XCTAssertTrue([s[@"fakefs_operation_counting"] containsString:@"not unique syscalls"]);
    XCTAssertGreaterThan([s[@"operations"] count], 0u);
    XCTAssertNil(s[@"path"]);
    dsh_lifecycle_operation_end(op);
}
- (void)testDiagnosticStateMachineIsIdempotentAndRequiresDrain {
    dsh_lifecycle_resume();
    uint64_t op = dsh_lifecycle_operation_begin("state-test", 92);
    uint64_t generation = dsh_lifecycle_request_quiesce();
    XCTAssertEqual(generation, dsh_lifecycle_request_quiesce());
    XCTAssertFalse(dsh_lifecycle_mark_quiescent(generation));
    dsh_lifecycle_operation_end(op);
    XCTAssertTrue(dsh_lifecycle_mark_quiescent(generation));
    dsh_lifecycle_resume();
    XCTAssertFalse(dsh_lifecycle_mark_quiescent(generation));
}
- (void)testReportPreservesPreviousLaunchAndFlushesNewBoundary {
    NSURL *directory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
    NSFileManager *fm = NSFileManager.defaultManager;
    XCTAssertTrue([fm createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil]);
    NSURL *prior = [directory URLByAppendingPathComponent:@"launch-20000101-prior.log"];
    XCTAssertTrue([@"host_launch_id: prior-launch\n[lifecycle] sceneDidEnterBackground\n" writeToURL:prior atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    @autoreleasepool {
        DSHLogBuffer *log = [[DSHLogBuffer alloc] initPersistentWithCapacity:8 directory:directory];
        [log append:@"[lifecycle] new-launch-boundary"];
        [log synchronizePersistentDiagnostics];
        XCTAssertTrue([log.diagnosticReport containsString:@"prior-launch"]);
        XCTAssertTrue([log.diagnosticReport containsString:@"new-launch-boundary"]);
    }
    DSHLogBuffer *nextReader = [[DSHLogBuffer alloc] initPersistentWithCapacity:8 directory:directory];
    XCTAssertTrue([nextReader.diagnosticReport containsString:@"sceneDidEnterBackground"]);
    XCTAssertTrue([nextReader.diagnosticReport containsString:@"new-launch-boundary"]);
    // Only this test's UUID directory is removed.
    XCTAssertTrue([fm removeItemAtURL:directory error:nil]);
}
- (void)testFlockIdentityAndReleaseHistoryExposeOnlyWhitelistedMetadata {
    int object = 0;
    struct dsh_lifecycle_flock_identity identity = {
        .device = 51, .inode = 123456,
        .file_kind = dsh_lifecycle_flock_classify_path("/private/fixture-api-secret/session.lock"),
        .fs_kind = DSH_FLOCK_FS_FAKE,
    };
    dsh_lifecycle_native_flock_observe(&object, 98, 22, DSH_LIFECYCLE_FLOCK_EXCLUSIVE, &identity);
    dsh_lifecycle_native_flock_guest_fd(&object, 22, 13, 4);
    @try {
        NSDictionary *s = [DSHLifecycleDiagnostics snapshotForHarness:DSHHarness.shared event:@"lock-test"];
        NSDictionary *lock = [s[@"native_flocks"] lastObject];
        XCTAssertEqualObjects(lock[@"file_kind"], @"session.lock");
        XCTAssertEqualObjects(lock[@"guest_fd_at_last_lock"], @13);
        XCTAssertEqualObjects(lock[@"guest_tgid"], @4);
        XCTAssertEqualObjects(lock[@"host_inode"], @123456);
        XCTAssertEqualObjects(lock[@"filesystem_kind"], @"fake");
        XCTAssertEqualObjects(lock[@"identity_path_errno"], @0);
        NSData *json = [NSJSONSerialization dataWithJSONObject:s options:0 error:nil];
        NSString *text = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
        XCTAssertFalse([text containsString:@"fixture-api-secret"]);
        XCTAssertFalse([text containsString:@"/private/"]);
        XCTAssertEqual(dsh_lifecycle_flock_classify_path("/private/session.lock-fixture-api-secret"), DSH_FLOCK_FILE_OTHER);
        NSNumber *identifier = lock[@"id"];
        dsh_lifecycle_native_flock_close(&object);
        s = [DSHLifecycleDiagnostics snapshotForHarness:DSHHarness.shared event:@"released-test"];
        NSDictionary *event = [s[@"native_flock_events"] lastObject];
        XCTAssertEqualObjects(event[@"event"], @"closed");
        XCTAssertEqualObjects(event[@"lock"][@"id"], identifier);
        XCTAssertEqualObjects(event[@"lock"][@"file_kind"], @"session.lock");
        XCTAssertLessThanOrEqual([s[@"native_flock_events"] count], (NSUInteger)DSH_LIFECYCLE_SNAPSHOT_ITEMS);
    } @finally {
        dsh_lifecycle_native_flock_close(&object);
    }
}
- (void)testExportPersistsAnImmediateSnapshotOfCurrentLocks {
    int object = 0;
    struct dsh_lifecycle_flock_identity identity = {.inode = 87654321, .file_kind = DSH_FLOCK_FILE_SESSION_LOCK};
    dsh_lifecycle_native_flock_observe(&object, 99, 23, DSH_LIFECYCLE_FLOCK_EXCLUSIVE, &identity);
    @try {
        struct dsh_lifecycle_snapshot snapshot;
        dsh_lifecycle_get_snapshot(&snapshot);
        uint64_t identifier = snapshot.native_flocks[snapshot.native_flock_count - 1].id;
        NSString *report = [DSHLifecycleDiagnostics reportForHarness:DSHHarness.shared];
        BOOL found = NO;
        for (NSString *line in [report componentsSeparatedByString:@"\n"]) {
            NSRange marker = [line rangeOfString:@"[lifecycle] "];
            if (marker.location == NSNotFound) continue;
            NSData *data = [[line substringFromIndex:NSMaxRange(marker)] dataUsingEncoding:NSUTF8StringEncoding];
            NSDictionary *event = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (![event[@"event"] isEqual:@"diagnosticReportExported"] ||
                ![event[@"host_launch_id"] isEqual:DSHLogBuffer.hostLaunchID]) continue;
            for (NSDictionary *lock in event[@"native_flocks"])
                if ([lock[@"id"] unsignedLongLongValue] == identifier && [lock[@"host_inode"] unsignedLongLongValue] == 87654321)
                    found = YES;
        }
        XCTAssertTrue(found, @"export must capture this lock now, without waiting for a lifecycle notification");
        XCTAssertTrue([DSHHarness.shared.log.diagnosticReport containsString:@"diagnosticReportExported"]);
    } @finally {
        dsh_lifecycle_native_flock_close(&object);
    }
}
@end
