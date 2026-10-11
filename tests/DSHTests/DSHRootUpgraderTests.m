#import <XCTest/XCTest.h>
#import "DSHRootUpgrader.h"
#include <errno.h>

// Exercise the production completion decision while replacing only the two
// destructive host actions and the pending-marker store. No Roots is opened.
@interface DSHRootUpgrader (CompletionTesting)
- (NSUserDefaults *)migrationDefaults;
- (int)unmountMigrationRoot;
- (BOOL)destroyPreviousRoot:(NSString *)previous error:(NSError **)error;
- (void)finishMigrationFromRoot:(NSString *)previous
                      exitCode:(int)exitCode
                       sawDone:(BOOL)sawDone
                    completion:(void (^)(BOOL, NSError *_Nullable))completion;
@end

@interface DSHRootUpgraderFixture : DSHRootUpgrader
@property (nonatomic) NSUserDefaults *isolatedDefaults;
@property (nonatomic) int unmountResult;
@property (nonatomic) BOOL destroySucceeds;
@property (nonatomic) BOOL previousRootPresent;
@property (nonatomic) NSUInteger unmountCalls;
@property (nonatomic) NSUInteger destroyCalls;
@property (nonatomic) NSString *destroyedRoot;
@property (nonatomic) NSMutableArray<NSString *> *actions;
@end

@implementation DSHRootUpgraderFixture
- (NSUserDefaults *)migrationDefaults { return self.isolatedDefaults; }
- (int)unmountMigrationRoot {
    self.unmountCalls++;
    [self.actions addObject:@"unmount"];
    return self.unmountResult;
}
- (BOOL)destroyPreviousRoot:(NSString *)previous error:(NSError **)error {
    self.destroyCalls++;
    self.destroyedRoot = previous;
    [self.actions addObject:@"destroy"];
    if (self.destroySucceeds) {
        self.previousRootPresent = NO;
        return YES;
    }
    if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EACCES userInfo:nil];
    return NO;
}
@end

@interface DSHRootUpgraderTests : XCTestCase
@property (nonatomic) DSHRootUpgraderFixture *upgrader;
@property (nonatomic) NSString *defaultsSuite;
@end

@implementation DSHRootUpgraderTests

- (void)setUp {
    [super setUp];
    self.defaultsSuite = [@"DSHRootUpgraderTests." stringByAppendingString:NSUUID.UUID.UUIDString];
    self.upgrader = [DSHRootUpgraderFixture new];
    self.upgrader.isolatedDefaults = [[NSUserDefaults alloc] initWithSuiteName:self.defaultsSuite];
    self.upgrader.actions = [NSMutableArray array];
    self.upgrader.destroySucceeds = YES;
    self.upgrader.previousRootPresent = YES;
    [self.upgrader.isolatedDefaults setObject:@"previous-test-root" forKey:@"DSHPendingMigrationRoot"];
    [self.upgrader.isolatedDefaults setObject:@"synthetic-settings" forKey:@"test-preserved-data"];
}

- (void)tearDown {
    [self.upgrader.isolatedDefaults removePersistentDomainForName:self.defaultsSuite];
    self.upgrader = nil;
    self.defaultsSuite = nil;
    [super tearDown];
}

- (NSError *)finishWithExitCode:(int)exitCode sawDone:(BOOL)sawDone expectedOK:(BOOL)expectedOK {
    __block NSUInteger completionCalls = 0;
    __block NSError *completionError = nil;
    dispatch_block_t finish = ^{
        [self.upgrader finishMigrationFromRoot:@"previous-test-root" exitCode:exitCode sawDone:sawDone
            completion:^(BOOL ok, NSError *error) {
                completionCalls++;
                completionError = error;
                XCTAssertTrue(NSThread.isMainThread);
                XCTAssertEqual(ok, expectedOK);
                [self.upgrader.actions addObject:@"completion"];
            }];
    };
    if (NSThread.isMainThread) finish();
    else dispatch_sync(dispatch_get_main_queue(), finish);
    XCTAssertEqual(completionCalls, 1u);
    XCTAssertEqual(self.upgrader.unmountCalls, 1u);
    XCTAssertEqualObjects([self.upgrader.isolatedDefaults stringForKey:@"test-preserved-data"], @"synthetic-settings");
    return completionError;
}

- (void)assertPreviousRootKept {
    XCTAssertTrue(self.upgrader.previousRootPresent);
    XCTAssertEqual(self.upgrader.destroyCalls, 0u);
    XCTAssertEqualObjects(self.upgrader.pendingMigrationRoot, @"previous-test-root");
    XCTAssertEqualObjects(self.upgrader.actions, (@[@"unmount", @"completion"]));
}

- (void)testBusyUnmountKeepsPreviousRootAndPendingMarker {
    self.upgrader.unmountResult = -EBUSY;
    NSError *error = [self finishWithExitCode:0 sawDone:YES expectedOK:NO];
    XCTAssertEqualObjects(error.domain, NSPOSIXErrorDomain);
    XCTAssertEqual(error.code, EBUSY);
    [self assertPreviousRootKept];
}

- (void)testDetachedMountCleanupErrorStillKeepsPreviousRootAndPendingMarker {
    // EIO can be reported after detachment when fakefs close is uncertain.
    // The completion contract must preserve the source in either mount state.
    self.upgrader.unmountResult = -EIO;
    NSError *error = [self finishWithExitCode:0 sawDone:YES expectedOK:NO];
    XCTAssertEqualObjects(error.domain, NSPOSIXErrorDomain);
    XCTAssertEqual(error.code, EIO);
    [self assertPreviousRootKept];
}

- (void)testSuccessfulUnmountDeletesPreviousRootThenClearsPendingMarker {
    NSError *error = [self finishWithExitCode:0 sawDone:YES expectedOK:YES];
    XCTAssertNil(error);
    XCTAssertEqual(self.upgrader.destroyCalls, 1u);
    XCTAssertEqualObjects(self.upgrader.destroyedRoot, @"previous-test-root");
    XCTAssertFalse(self.upgrader.previousRootPresent);
    XCTAssertNil(self.upgrader.pendingMigrationRoot);
    XCTAssertEqualObjects(self.upgrader.actions, (@[@"unmount", @"destroy", @"completion"]));
}

- (void)testMigrationCommandFailureRetainsPreviousRootAfterSuccessfulUnmount {
    NSError *error = [self finishWithExitCode:17 sawDone:YES expectedOK:NO];
    XCTAssertEqualObjects(error.domain, @"DSH");
    XCTAssertEqual(error.code, 17);
    [self assertPreviousRootKept];
}

- (void)testSuccessfulMigrationKeepsExistingBestEffortDestroySemantics {
    self.upgrader.destroySucceeds = NO;
    NSError *error = [self finishWithExitCode:0 sawDone:YES expectedOK:YES];
    XCTAssertNil(error);
    XCTAssertEqual(self.upgrader.destroyCalls, 1u);
    XCTAssertTrue(self.upgrader.previousRootPresent);
    XCTAssertNil(self.upgrader.pendingMigrationRoot);
    XCTAssertEqualObjects(self.upgrader.actions, (@[@"unmount", @"destroy", @"completion"]));
}

@end
