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
@end
