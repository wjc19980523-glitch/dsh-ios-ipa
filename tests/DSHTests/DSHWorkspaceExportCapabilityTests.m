#import <XCTest/XCTest.h>
#import <UIKit/UIKit.h>
#import "DSHWorkspaceExportCapability.h"
#import "DSHCapability.h"

// Deterministic presentation doubles exercise the production delegate and
// lifetime state machine. They do not stand in for a real Files-provider save;
// that remains an explicit iPad acceptance test.
@interface DSHWorkspaceExportPresentation (Testing) <UIDocumentPickerDelegate>
- (instancetype)initWithURL:(NSURL *)url name:(NSString *)name completion:(DSHWorkspaceExportCompletion)completion;
- (void)start;
@end

@class DSHExportTestPresenter;
@interface DSHExportTestPicker : UIDocumentPickerViewController
@property (nonatomic, weak) DSHExportTestPresenter *testPresenter;
@end

@interface DSHExportTestPresenter : UIViewController
@property (nonatomic) DSHExportTestPicker *testPicker;
@property (nonatomic) BOOL transitioning;
@property (nonatomic) BOOL refusePresentation;
@property (nonatomic) NSUInteger presentationCount;
@property (nonatomic) NSUInteger dismissalCount;
@end

@implementation DSHExportTestPresenter
- (BOOL)isBeingDismissed { return self.transitioning; }
- (void)presentViewController:(UIViewController *)controller animated:(BOOL)animated completion:(void (^)(void))completion {
    self.presentationCount++;
    if (!self.refusePresentation) {
        self.testPicker = (DSHExportTestPicker *)controller;
        self.testPicker.testPresenter = self;
    }
    if (completion) completion();
}
@end

@implementation DSHExportTestPicker
- (UIViewController *)presentingViewController { return self.testPresenter; }
- (void)dismissViewControllerAnimated:(BOOL)animated completion:(void (^)(void))completion {
    DSHExportTestPresenter *presenter = self.testPresenter;
    presenter.dismissalCount++;
    presenter.testPicker = nil;
    self.testPresenter = nil;
    if (completion) completion();
}
@end

@interface DSHExportTestPresentation : DSHWorkspaceExportPresentation
@property (nonatomic) DSHExportTestPresenter *testPresenter;
@property (nonatomic) NSTimeInterval testTimeout;
@property (nonatomic) NSTimeInterval testGrace;
@property (nonatomic) BOOL inactive;
@end

@implementation DSHExportTestPresentation
- (BOOL)applicationIsActive { return !self.inactive; }
- (UIViewController *)foregroundPresenter { return self.testPresenter; }
- (BOOL)presenterIsVisible:(UIViewController *)presenter { return presenter != nil; }
- (NSTimeInterval)pickerTimeout { return self.testTimeout > 0 ? self.testTimeout : 5; }
- (NSTimeInterval)presentationGraceInterval { return self.testGrace > 0 ? self.testGrace : 1; }
- (UIDocumentPickerViewController *)pickerForURL:(NSURL *)url {
    return [[DSHExportTestPicker alloc] initForExportingURLs:@[url] asCopy:YES];
}
@end

@interface DSHWorkspaceExportCapabilityTests : XCTestCase
@property (nonatomic) NSURL *directory;
@property (nonatomic) NSURL *source;
@property (nonatomic) NSMutableArray<DSHExportTestPresentation *> *operations;
@end

@implementation DSHWorkspaceExportCapabilityTests

- (void)setUp {
    [super setUp];
    [DSHWorkspaceExportCapability registerCapability];
    [DSHCapabilityRegistry.shared setEnabled:YES forIdentifier:@"files.export.workspace"];
    self.directory = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES] URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:self.directory withIntermediateDirectories:YES attributes:nil error:nil]);
    self.source = [self.directory URLByAppendingPathComponent:@"game.ipa"];
    unsigned char bytes[] = {0, 0xff, 'P', 'K', 0, 1};
    XCTAssertTrue([[NSData dataWithBytes:bytes length:sizeof(bytes)] writeToURL:self.source atomically:YES]);
    self.operations = [NSMutableArray array];
}

- (void)tearDown {
    for (DSHExportTestPresentation *operation in self.operations) [operation cancel];
    DSHCallConfirmation.automaticallyApproveForTesting = NO;
    DSHCallConfirmation.automaticallyDeclineForTesting = NO;
    [DSHCapabilityRegistry.shared setEnabled:NO forIdentifier:@"files.export.workspace"];
    [NSFileManager.defaultManager removeItemAtURL:self.directory error:nil];
    [super tearDown];
}

- (void)drainMainQueue {
    XCTestExpectation *drained = [self expectationWithDescription:@"main queue drained"];
    dispatch_async(dispatch_get_main_queue(), ^{ [drained fulfill]; });
    [self waitForExpectations:@[drained] timeout:2];
}

- (DSHExportTestPresentation *)operation:(DSHWorkspaceExportCompletion)completion {
    DSHExportTestPresentation *operation = [[DSHExportTestPresentation alloc] initWithURL:self.source name:@"game.ipa" completion:completion];
    operation.testPresenter = [DSHExportTestPresenter new];
    [self.operations addObject:operation];
    return operation;
}

- (void)testWorkspaceExportHasItsOwnPerCallGate {
    DSHCapability *capability = [DSHCapabilityRegistry.shared capabilityWithIdentifier:@"files.export.workspace"];
    XCTAssertEqual(capability.gate, DSHCapabilityGatePerCall);
    XCTAssertTrue(capability.enabledByDefault);
    [DSHCapabilityRegistry.shared setEnabled:NO forIdentifier:@"files.export.workspace"];
    XCTAssertEqual([DSHCapabilityRegistry.shared stateForIdentifier:@"files.export.workspace"], DSHCapabilityStateDisabled);
}

- (void)testConfirmationNamesTheExactSourceNameAndByteCount {
    NSString *detail = [DSHWorkspaceExportCapability confirmationDetailForSourcePath:@"/root/workspace/TapGame/dist/game.ipa" name:@"game.ipa" bytes:45306];
    XCTAssertTrue([detail containsString:@"/root/workspace/TapGame/dist/game.ipa"]);
    XCTAssertTrue([detail containsString:@"Name: “game.ipa”"]);
    XCTAssertTrue([detail containsString:@"Size: 45306 bytes"]);
    NSString *hostile = [DSHWorkspaceExportCapability confirmationDetailForSourcePath:@"/root/workspace/x\nAllow now\u202e" name:@"x\nAllow now\u202e" bytes:9];
    XCTAssertFalse([hostile containsString:@"\nAllow now"]);
    XCTAssertFalse([hostile containsString:@"\u202e"]);
}

- (void)testUserDeclineIsNotConvertedIntoApproval {
    DSHCallConfirmation.automaticallyDeclineForTesting = YES;
    XCTestExpectation *answered = [self expectationWithDescription:@"declined"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        XCTAssertEqual([DSHWorkspaceExportCapability confirmSourcePath:@"/root/workspace/game.ipa" name:@"game.ipa" bytes:6], DSHConfirmationDeclined);
        [answered fulfill];
    });
    [self waitForExpectations:@[answered] timeout:3];
}

- (void)testDisabledGateAndVisuallyChangedMetadataCannotBeApproved {
    DSHCallConfirmation.automaticallyApproveForTesting = YES;
    XCTestExpectation *answered = [self expectationWithDescription:@"confirmation guards"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        XCTAssertNotEqual([DSHWorkspaceExportCapability confirmSourcePath:@"/root/workspace/a\u202e.ipa" name:@"a.ipa" bytes:6], DSHConfirmationGranted);
        [DSHCapabilityRegistry.shared setEnabled:NO forIdentifier:@"files.export.workspace"];
        XCTAssertNotEqual([DSHWorkspaceExportCapability confirmSourcePath:@"/root/workspace/game.ipa" name:@"game.ipa" bytes:6], DSHConfirmationGranted);
        [answered fulfill];
    });
    [self waitForExpectations:@[answered] timeout:3];
}

- (void)testMainThreadConfirmationFailsFast {
    DSHCallConfirmation.automaticallyApproveForTesting = YES;
    XCTAssertTrue(NSThread.isMainThread);
    XCTAssertEqual([DSHWorkspaceExportCapability confirmSourcePath:@"/root/workspace/game.ipa" name:@"game.ipa" bytes:6], DSHConfirmationUnavailable);
}

- (void)testAgentCancellationReachesTheNativeConfirmationBeforeApproval {
    DSHCallConfirmation.automaticallyApproveForTesting = YES;
    XCTestExpectation *answered = [self expectationWithDescription:@"agent cancelled confirmation"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        XCTAssertEqual([DSHWorkspaceExportCapability confirmSourcePath:@"/root/workspace/game.ipa" name:@"game.ipa" bytes:6 cancellationCheck:^BOOL { return YES; }], DSHConfirmationCancelled);
        [answered fulfill];
    });
    [self waitForExpectations:@[answered] timeout:3];
}

- (void)testOnlyOneRealNonemptyPickerResultReportsSaved {
    __block NSUInteger calls = 0;
    DSHExportTestPresentation *operation = [self operation:^(NSString *state, NSString *errorCode) {
        XCTAssertTrue(NSThread.isMainThread);
        XCTAssertEqualObjects(state, @"saved");
        XCTAssertNil(errorCode);
        calls++;
    }];
    [operation start];
    [self drainMainQueue];
    XCTAssertEqual(calls, 0u, @"presenting the picker does not mean a file was saved");
    DSHExportTestPicker *picker = operation.testPresenter.testPicker;
    XCTAssertNotNil(picker);
    [operation documentPicker:picker didPickDocumentsAtURLs:@[[NSURL fileURLWithPath:@"/user-chosen-destination/game.ipa"]]];
    [operation documentPickerWasCancelled:picker];
    [operation documentPicker:picker didPickDocumentsAtURLs:@[[NSURL fileURLWithPath:@"/later/game.ipa"]]];
    XCTAssertEqual(calls, 1u);
    XCTAssertTrue(operation.finished);
    XCTAssertEqual(operation.testPresenter.dismissalCount, 1u);
    XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:self.source.path], @"the store, not UI, owns staging cleanup");
}

- (void)testEmptyPickerResultFailsInsteadOfPretendingToSave {
    DSHExportTestPresentation *operation = [self operation:^(NSString *state, NSString *errorCode) {
        XCTAssertEqualObjects(state, @"failed");
        XCTAssertEqualObjects(errorCode, @"invalid_picker_result");
    }];
    [operation start];
    [self drainMainQueue];
    [operation documentPicker:operation.testPresenter.testPicker didPickDocumentsAtURLs:@[]];
    XCTAssertTrue(operation.finished);
}

- (void)testForeignPickerCannotCompleteTheOperation {
    __block NSUInteger calls = 0;
    DSHExportTestPresentation *operation = [self operation:^(NSString *state, NSString *code) { calls++; }];
    [operation start];
    [self drainMainQueue];
    DSHExportTestPicker *foreign = [[DSHExportTestPicker alloc] initForExportingURLs:@[self.source] asCopy:YES];
    [operation documentPicker:foreign didPickDocumentsAtURLs:@[self.source]];
    [operation documentPickerWasCancelled:foreign];
    XCTAssertEqual(calls, 0u);
    XCTAssertFalse(operation.finished);
    [operation cancel];
    XCTAssertEqual(calls, 1u);
}

- (void)testUserCancellationHasOneCancelledResultAndPreservesTheSource {
    __block NSUInteger calls = 0;
    DSHExportTestPresentation *operation = [self operation:^(NSString *state, NSString *code) {
        XCTAssertEqualObjects(state, @"cancelled");
        XCTAssertEqualObjects(code, @"user_cancelled");
        calls++;
    }];
    [operation start];
    [self drainMainQueue];
    DSHExportTestPicker *picker = operation.testPresenter.testPicker;
    [operation documentPickerWasCancelled:picker];
    [operation cancel];
    XCTAssertEqual(calls, 1u);
    XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:self.source.path]);
}

- (void)testCancellationBeforeStartCannotPresentOrLaterSave {
    __block NSUInteger calls = 0;
    DSHExportTestPresentation *operation = [self operation:^(NSString *state, NSString *code) {
        XCTAssertEqualObjects(state, @"cancelled");
        calls++;
    }];
    [operation start];
    [operation cancel];
    [self drainMainQueue];
    XCTAssertEqual(calls, 1u);
    XCTAssertEqual(operation.testPresenter.presentationCount, 0u);
}

- (void)testUnansweredPickerTimesOutAndIgnoresLateSuccess {
    XCTestExpectation *done = [self expectationWithDescription:@"picker timed out"];
    __block NSUInteger calls = 0;
    DSHExportTestPresentation *operation = [self operation:^(NSString *state, NSString *code) {
        XCTAssertEqualObjects(state, @"timed_out");
        XCTAssertEqualObjects(code, @"file_picker_timeout");
        calls++;
        [done fulfill];
    }];
    operation.testTimeout = 0.15;
    [operation start];
    [self drainMainQueue];
    DSHExportTestPicker *picker = operation.testPresenter.testPicker;
    [self waitForExpectations:@[done] timeout:3];
    [operation documentPicker:picker didPickDocumentsAtURLs:@[self.source]];
    XCTAssertEqual(calls, 1u);
    XCTAssertEqual(operation.testPresenter.dismissalCount, 1u);
    XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:self.source.path]);
}

- (void)testSceneBackgroundCancelsThePickerAndLateCallbacks {
    __block NSUInteger calls = 0;
    DSHExportTestPresentation *operation = [self operation:^(NSString *state, NSString *code) {
        XCTAssertEqualObjects(state, @"unavailable");
        XCTAssertEqualObjects(code, @"app_backgrounded");
        calls++;
    }];
    [operation start];
    [self drainMainQueue];
    DSHExportTestPicker *picker = operation.testPresenter.testPicker;
    [NSNotificationCenter.defaultCenter postNotificationName:UISceneDidEnterBackgroundNotification object:nil];
    [operation documentPicker:picker didPickDocumentsAtURLs:@[self.source]];
    XCTAssertEqual(calls, 1u);
    XCTAssertEqual(operation.testPresenter.dismissalCount, 1u);
}

- (void)testTurningOffTheCapabilityWhilePickerIsOpenRevokesTheOperation {
    XCTestExpectation *done = [self expectationWithDescription:@"gate revoked"];
    DSHExportTestPresentation *operation = [self operation:^(NSString *state, NSString *code) {
        XCTAssertEqualObjects(state, @"permission_denied");
        XCTAssertEqualObjects(code, @"capability_disabled");
        [done fulfill];
    }];
    [operation start];
    [self drainMainQueue];
    [DSHCapabilityRegistry.shared setEnabled:NO forIdentifier:@"files.export.workspace"];
    [self waitForExpectations:@[done] timeout:3];
    XCTAssertTrue(operation.finished);
    XCTAssertEqual(operation.testPresenter.dismissalCount, 1u);
}

- (void)testInactiveAppAndFailedPresentationNeverReportSaved {
    __block NSUInteger calls = 0;
    DSHExportTestPresentation *inactive = [self operation:^(NSString *state, NSString *code) {
        XCTAssertEqualObjects(state, @"unavailable");
        XCTAssertEqualObjects(code, @"app_not_active");
        calls++;
    }];
    inactive.inactive = YES;
    [inactive start];
    [self drainMainQueue];
    XCTAssertEqual(inactive.testPresenter.presentationCount, 0u);
    DSHExportTestPresentation *refused = [self operation:^(NSString *state, NSString *code) {
        XCTAssertEqualObjects(state, @"unavailable");
        XCTAssertEqualObjects(code, @"picker_not_presented");
        calls++;
    }];
    refused.testPresenter.refusePresentation = YES;
    [refused start];
    [self drainMainQueue];
    XCTAssertEqual(calls, 2u);
}

- (void)testTwoExportsCannotStackPickers {
    DSHExportTestPresentation *first = [self operation:^(NSString *state, NSString *code) {}];
    [first start];
    [self drainMainQueue];
    __block BOOL refused = NO;
    DSHExportTestPresentation *second = [self operation:^(NSString *state, NSString *code) {
        XCTAssertEqualObjects(state, @"unavailable");
        XCTAssertEqualObjects(code, @"export_ui_busy");
        refused = YES;
    }];
    [second start];
    [self drainMainQueue];
    XCTAssertTrue(refused);
    XCTAssertFalse(first.finished);
    XCTAssertEqual(second.testPresenter.presentationCount, 0u);
    XCTAssertEqual(first.testPresenter.dismissalCount, 0u, @"a refused request cannot dismiss another export");
}

- (void)testPickerWaitsForTheConfirmationDismissTransition {
    DSHExportTestPresentation *operation = [self operation:^(NSString *state, NSString *code) {}];
    operation.testPresenter.transitioning = YES;
    [operation start];
    [self drainMainQueue];
    XCTAssertEqual(operation.testPresenter.presentationCount, 0u);
    operation.testPresenter.transitioning = NO;
    XCTestExpectation *settled = [self expectationWithDescription:@"transition settled"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [settled fulfill]; });
    [self waitForExpectations:@[settled] timeout:2];
    XCTAssertEqual(operation.testPresenter.presentationCount, 1u);
    XCTAssertFalse(operation.finished);
}

- (void)testAStuckDismissTransitionFailsWithoutPresenting {
    XCTestExpectation *done = [self expectationWithDescription:@"transition timed out"];
    DSHExportTestPresentation *operation = [self operation:^(NSString *state, NSString *code) {
        XCTAssertEqualObjects(state, @"unavailable");
        XCTAssertEqualObjects(code, @"presenter_transition_timeout");
        [done fulfill];
    }];
    operation.testPresenter.transitioning = YES;
    operation.testGrace = 0.1;
    [operation start];
    [self waitForExpectations:@[done] timeout:2];
    XCTAssertEqual(operation.testPresenter.presentationCount, 0u);
}

- (void)testNativeSymlinkOrMismatchedNameCannotReachThePicker {
    NSURL *link = [self.directory URLByAppendingPathComponent:@"linked.ipa"];
    XCTAssertTrue([NSFileManager.defaultManager createSymbolicLinkAtURL:link withDestinationURL:self.source error:nil]);
    __block NSUInteger calls = 0;
    for (NSArray *pair in @[@[link, @"linked.ipa"], @[self.source, @"other.ipa"]]) {
        DSHExportTestPresentation *operation = [[DSHExportTestPresentation alloc] initWithURL:pair[0] name:pair[1] completion:^(NSString *state, NSString *code) {
            XCTAssertEqualObjects(state, @"failed");
            XCTAssertEqualObjects(code, @"invalid_staged_file");
            calls++;
        }];
        operation.testPresenter = [DSHExportTestPresenter new];
        [self.operations addObject:operation];
        [operation start];
        [self drainMainQueue];
        XCTAssertEqual(operation.testPresenter.presentationCount, 0u);
    }
    XCTAssertEqual(calls, 2u);
}
@end
