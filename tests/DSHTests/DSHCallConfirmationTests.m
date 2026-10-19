//
//  DSHCallConfirmationTests.m
//  DSHTests
//
//  The gate every write capability sits behind. These assert the three rules
//  that make blocking a bridge handler on a dialog safe: never wait on a
//  dialog nobody can see, never stack them, and always answer.
//
//  Two of them put a real alert on screen on purpose — that is the only way to
//  prove an unanswered prompt times out rather than hanging. Their titles say
//  "DSH self-test" so that anyone watching a device during a test run can see
//  what it is instead of meeting an unexplained "Allow".
//

#import <XCTest/XCTest.h>
#import <UIKit/UIKit.h>
#import "DSHCallConfirmation.h"
#import "DSHHostBridge.h"
#import "DSHActivityLog.h"

// Exercise the production cancellation/once gate with a presentation double.
// No Files provider or real human authorization is claimed by these tests.
@interface DSHConfirmationPrompt : NSObject
@property (atomic, readonly) BOOL finished;
@property (atomic, readonly) DSHConfirmationOutcome outcome;
@property (nonatomic) dispatch_semaphore_t answered;
- (instancetype)initWithTitle:(NSString *)title detail:(NSString *)detail timeout:(NSTimeInterval)timeout cancellationCheck:(BOOL (^)(void))check;
- (void)start;
- (void)tick;
- (void)allow;
- (void)decline;
- (void)resolve:(DSHConfirmationOutcome)outcome;
@end

@interface DSHCancellationTestPrompt : DSHConfirmationPrompt
@property (nonatomic) BOOL ownedAlertVisible;
@property (nonatomic) NSUInteger ownedDismissalCount;
@end
@implementation DSHCancellationTestPrompt
- (BOOL)presentAlert { self.ownedAlertVisible = YES; return YES; }
- (void)dismissOwnedAlertWithCompletion:(dispatch_block_t)completion {
    if (self.ownedAlertVisible) { self.ownedAlertVisible = NO; self.ownedDismissalCount++; }
    completion();
}
@end

@interface DSHCallConfirmationTests : XCTestCase
@end

@implementation DSHCallConfirmationTests

- (void)tearDown {
    DSHCallConfirmation.automaticallyApproveForTesting = NO;
    DSHCallConfirmation.automaticallyDeclineForTesting = NO;
    [super tearDown];
}

/// Even a decision made without a dialog is a decision, and the record is the
/// only place a user can see that one was made.
- (void)testEveryOutcomeReachesTheActivityRecord {
    [DSHActivityLog.shared resetForTesting];
    DSHCallConfirmation.automaticallyDeclineForTesting = YES;
    [DSHCallConfirmation confirmTitle:@"DSH self-test" detail:@"Not a real request."];
    DSHCallConfirmation.automaticallyDeclineForTesting = NO;

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    DSHActivityEntry *entry = nil;
    while (entry == nil && [deadline timeIntervalSinceNow] > 0) {
        entry = DSHActivityLog.shared.entries.firstObject;
        if (entry == nil)
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    XCTAssertNotNil(entry, @"a decision that skipped the dialog still has to be recorded");
    XCTAssertEqual(entry.outcome, DSHActivityOutcomeDeclined);
    [DSHActivityLog.shared resetForTesting];
}

- (void)testTestHooksShortCircuitWithoutShowingAnything {
    NSUInteger before = DSHCallConfirmation.presentedCount;
    DSHCallConfirmation.automaticallyApproveForTesting = YES;
    XCTAssertEqual([DSHCallConfirmation confirmTitle:@"DSH self-test" detail:@"Not a real request."], DSHConfirmationGranted);
    DSHCallConfirmation.automaticallyApproveForTesting = NO;
    DSHCallConfirmation.automaticallyDeclineForTesting = YES;
    XCTAssertEqual([DSHCallConfirmation confirmTitle:@"DSH self-test" detail:@"Not a real request."], DSHConfirmationDeclined);
    XCTAssertEqual(DSHCallConfirmation.presentedCount, before,
                   @"the test hooks must not put a real alert on screen");
}

/// The bridge handler runs on a background queue. Confirming from there must
/// not deadlock against the main queue that shows the alert — a real risk,
/// since the alert is presented with a dispatch to main while this waits.
- (void)testConfirmingFromABackgroundQueueDoesNotDeadlock {
    XCTestExpectation *done = [self expectationWithDescription:@"answered"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // No foreground UI in a unit-test host, so this must come back
        // Unavailable rather than hang.
        DSHConfirmationOutcome outcome = [DSHCallConfirmation confirmTitle:@"DSH self-test (background)" detail:@"Not a real request — this dismisses itself." timeout:3];
        XCTAssertNotEqual(outcome, DSHConfirmationGranted);
        [done fulfill];
    });
    [self waitForExpectations:@[done] timeout:15];
}

/// Every outcome has to produce a response the model can act on — and the two
/// that mean "try later" have to be marked recoverable, while a decline must
/// not be, or the agent will simply ask again.
- (void)testEveryOutcomeMapsToAnActionableResponse {
    XCTAssertNil([DSHCallConfirmation refusalFor:DSHConfirmationGranted action:@"x"]);

    DSHHostBridgeResponse *declined = [DSHCallConfirmation refusalFor:DSHConfirmationDeclined action:@"copying text"];
    XCTAssertEqual(declined.status, 403);
    XCTAssertEqualObjects(declined.body[@"error"][@"recoverable"], @NO,
                          @"a decline must not invite a retry");
    XCTAssertTrue([declined.body[@"error"][@"message"] containsString:@"copying text"],
                  @"the message should name the action: %@", declined.body[@"error"][@"message"]);

    DSHHostBridgeResponse *timedOut = [DSHCallConfirmation refusalFor:DSHConfirmationTimedOut action:@"copying text"];
    XCTAssertEqual(timedOut.status, 408);
    XCTAssertEqualObjects(timedOut.body[@"error"][@"recoverable"], @YES);

    DSHHostBridgeResponse *unavailable = [DSHCallConfirmation refusalFor:DSHConfirmationUnavailable action:@"copying text"];
    XCTAssertEqual(unavailable.status, 409);
    XCTAssertEqualObjects(unavailable.body[@"error"][@"code"], @"unavailable");
    XCTAssertEqualObjects(unavailable.body[@"error"][@"recoverable"], @YES);
}

/// A loop in the agent must not become a wall of dialogs: while one prompt is
/// up, the rest are refused rather than queued.
- (void)testConcurrentConfirmationsDoNotStack {
    NSUInteger before = DSHCallConfirmation.presentedCount;
    dispatch_group_t group = dispatch_group_create();
    NSLock *lock = [NSLock new];
    NSMutableArray<NSNumber *> *outcomes = [NSMutableArray array];
    for (int i = 0; i < 5; i++) {
        dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            DSHConfirmationOutcome outcome = [DSHCallConfirmation confirmTitle:@"DSH self-test (burst)" detail:@"Not a real request — this dismisses itself." timeout:2];
            [lock lock];
            [outcomes addObject:@(outcome)];
            [lock unlock];
        });
    }
    XCTAssertEqual(dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, (int64_t) (30 * NSEC_PER_SEC))), 0,
                   @"a burst of confirmations must not hang");
    XCTAssertEqual(outcomes.count, 5u);
    for (NSNumber *outcome in outcomes)
        XCTAssertNotEqual(outcome.integerValue, DSHConfirmationGranted,
                          @"nothing may be granted without a human");
    XCTAssertLessThanOrEqual(DSHCallConfirmation.presentedCount - before, 1u,
                             @"at most one alert may be presented at a time");
}

- (DSHCancellationTestPrompt *)promptWithTimeout:(NSTimeInterval)timeout check:(BOOL (^)(void))check {
    return [[DSHCancellationTestPrompt alloc] initWithTitle:@"DSH self-test" detail:@"Not a real request." timeout:timeout cancellationCheck:check];
}

- (void)testCancellingPendingConfirmationDismissesOnlyItsOwnedAlertOnce {
    __block BOOL cancelled = NO;
    DSHCancellationTestPrompt *prompt = [self promptWithTimeout:45 check:^BOOL { return cancelled; }];
    DSHCancellationTestPrompt *unrelated = [self promptWithTimeout:45 check:nil];
    [prompt start]; [unrelated start];
    cancelled = YES;
    [prompt tick];
    [prompt tick]; [prompt allow]; [prompt resolve:DSHConfirmationGranted];
    XCTAssertEqual(prompt.outcome, DSHConfirmationCancelled);
    XCTAssertTrue(prompt.finished);
    XCTAssertEqual(prompt.ownedDismissalCount, 1u);
    XCTAssertFalse(prompt.ownedAlertVisible);
    XCTAssertTrue(unrelated.ownedAlertVisible);
    XCTAssertFalse(unrelated.finished);
    XCTAssertEqual(unrelated.ownedDismissalCount, 0u, @"cancellation cannot dismiss another request's UI");
    [unrelated decline];
}

- (void)testCancellationIsRecheckedBeforeAllowEvenBeforeTheNextPoll {
    __block BOOL cancelled = NO;
    DSHCancellationTestPrompt *prompt = [self promptWithTimeout:45 check:^BOOL { return cancelled; }];
    [prompt start];
    cancelled = YES;
    [prompt allow];
    [prompt allow]; [prompt decline];
    XCTAssertEqual(prompt.outcome, DSHConfirmationCancelled);
    XCTAssertEqual(prompt.ownedDismissalCount, 1u);
    XCTAssertEqual(dispatch_semaphore_wait(prompt.answered, DISPATCH_TIME_NOW), 0l);
    XCTAssertNotEqual(dispatch_semaphore_wait(prompt.answered, DISPATCH_TIME_NOW), 0l, @"the worker receives exactly one terminal answer");
}

- (void)testBackgroundCancelsCancellableConfirmationAndPreservesUnrelatedLegacyPrompt {
    DSHCancellationTestPrompt *prompt = [self promptWithTimeout:45 check:^BOOL { return NO; }];
    DSHCancellationTestPrompt *legacy = [self promptWithTimeout:45 check:nil];
    [prompt start]; [legacy start];
    [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidEnterBackgroundNotification object:nil];
    XCTAssertEqual(prompt.outcome, DSHConfirmationCancelled);
    XCTAssertEqual(prompt.ownedDismissalCount, 1u);
    XCTAssertFalse(legacy.finished);
    XCTAssertTrue(legacy.ownedAlertVisible);
    [legacy decline];
}

- (void)testPeriodicCancellationEndsAPendingConfirmationWithoutWaitingForItsDeadline {
    __block BOOL cancelled = NO;
    DSHCancellationTestPrompt *prompt = [self promptWithTimeout:45 check:^BOOL { return cancelled; }];
    [prompt start];
    cancelled = YES;
    XCTestExpectation *polled = [self expectationWithDescription:@"cancellation polled"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [polled fulfill]; });
    [self waitForExpectations:@[polled] timeout:2];
    XCTAssertTrue(prompt.finished);
    XCTAssertEqual(prompt.outcome, DSHConfirmationCancelled);
    XCTAssertEqual(prompt.ownedDismissalCount, 1u);
}

- (void)testTimeoutRejectsALateAllowAndDoesNotResolveTwice {
    DSHCancellationTestPrompt *prompt = [self promptWithTimeout:0.02 check:nil];
    [prompt start];
    XCTestExpectation *timedOut = [self expectationWithDescription:@"confirmation timed out"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [timedOut fulfill]; });
    [self waitForExpectations:@[timedOut] timeout:2];
    [prompt allow];
    XCTAssertEqual(prompt.outcome, DSHConfirmationTimedOut);
    XCTAssertEqual(prompt.ownedDismissalCount, 1u);
}

- (void)testLegacyPromptWithoutCancellationCheckStillAllowsAndDeclines {
    DSHCancellationTestPrompt *allowed = [self promptWithTimeout:45 check:nil];
    [allowed start]; [allowed allow];
    XCTAssertEqual(allowed.outcome, DSHConfirmationGranted);
    DSHCancellationTestPrompt *declined = [self promptWithTimeout:45 check:nil];
    [declined start]; [declined decline];
    XCTAssertEqual(declined.outcome, DSHConfirmationDeclined);
}

- (void)testCancellationTakesPrecedenceOverTheAutomaticApprovalTestHook {
    DSHCallConfirmation.automaticallyApproveForTesting = YES;
    NSUInteger count = DSHCallConfirmation.presentedCount;
    DSHConfirmationOutcome outcome = [DSHCallConfirmation confirmTitle:@"DSH self-test" detail:@"Not a real request." timeout:45 cancellationCheck:^BOOL { return YES; }];
    XCTAssertEqual(outcome, DSHConfirmationCancelled);
    XCTAssertEqual(DSHCallConfirmation.presentedCount, count);
}

- (void)testCancellationResponseDoesNotPretendTheUserDeclinedOrInviteRetry {
    DSHHostBridgeResponse *response = [DSHCallConfirmation refusalFor:DSHConfirmationCancelled action:@"exporting game.ipa"];
    XCTAssertEqual(response.status, 409);
    XCTAssertEqualObjects(response.body[@"error"][@"code"], @"cancelled");
    XCTAssertEqualObjects(response.body[@"error"][@"recoverable"], @NO);
}

@end
