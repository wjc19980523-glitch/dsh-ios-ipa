#import <XCTest/XCTest.h>
#import "DSHLifecycleCoordinator.h"
#import "DSHRootViewController.h"

@interface DSHRootViewController (SessionRecoveryTests)
- (void)updateSessionRecoveryIssueForCoordinator:(DSHLifecycleCoordinator *)coordinator;
@end

// Keep this UI regression independent of booting the guest or presenting an
// animated window. The alert itself is the real UIKit controller.
@interface DSHSessionRecoveryViewFixture : DSHRootViewController
@property (nonatomic) UIViewController *fixturePresented;
@property (nonatomic) NSUInteger presentations;
@property (nonatomic) NSUInteger dismissals;
@property (nonatomic) BOOL deferDismissal;
@property (nonatomic, copy) dispatch_block_t pendingDismissal;
- (void)finishDismissal;
@end
@implementation DSHSessionRecoveryViewFixture
- (void)loadView { self.view = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 640, 480)]; }
- (void)viewDidLoad {}
- (UIViewController *)presentedViewController { return self.fixturePresented; }
- (void)presentViewController:(UIViewController *)controller animated:(BOOL)animated completion:(void (^)(void))completion {
    self.fixturePresented = controller; self.presentations++;
    if (completion) completion();
}
- (void)dismissViewControllerAnimated:(BOOL)animated completion:(void (^)(void))completion {
    self.dismissals++;
    if (self.deferDismissal) { self.pendingDismissal = completion; return; }
    self.fixturePresented = nil;
    if (completion) completion();
}
- (void)finishDismissal {
    dispatch_block_t completion = self.pendingDismissal;
    self.pendingDismissal = nil; self.fixturePresented = nil;
    if (completion) completion();
}
@end

typedef void (^DSHSessionResult)(BOOL);

@interface DSHSessionScheduledAction : NSObject
@property (nonatomic) NSTimeInterval due;
@property (nonatomic, copy) dispatch_block_t action;
@end
@implementation DSHSessionScheduledAction
@end

@interface DSHSessionTestClock : NSObject
@property (nonatomic) NSTimeInterval now;
@property (nonatomic) NSMutableArray<DSHSessionScheduledAction *> *actions;
- (void)schedule:(NSTimeInterval)delay action:(dispatch_block_t)action;
- (void)advance:(NSTimeInterval)seconds;
@end
@implementation DSHSessionTestClock
- (instancetype)init {
    if ((self = [super init])) { _now = 100; _actions = [NSMutableArray array]; }
    return self;
}
- (void)schedule:(NSTimeInterval)delay action:(dispatch_block_t)action {
    DSHSessionScheduledAction *entry = [DSHSessionScheduledAction new];
    entry.due = self.now + delay; entry.action = action;
    [self.actions addObject:entry];
}
- (void)advance:(NSTimeInterval)seconds {
    NSTimeInterval target = self.now + seconds;
    while (YES) {
        DSHSessionScheduledAction *next = nil;
        for (DSHSessionScheduledAction *entry in self.actions)
            if (entry.due <= target && (!next || entry.due < next.due)) next = entry;
        if (!next) break;
        [self.actions removeObject:next]; self.now = next.due; next.action();
    }
    self.now = target;
}
@end

@interface DSHSessionCoordinatorDriver : NSObject <DSHLifecycleDriver>
@property (nonatomic) NSMutableArray<NSString *> *calls;
@property (nonatomic) NSMutableArray<NSDictionary *> *records;
@property (nonatomic) NSMutableArray<DSHSessionResult> *preparations;
@property (nonatomic) NSMutableArray<NSNumber *> *preparationGenerations;
@property (nonatomic) NSMutableArray<DSHSessionResult> *resumes;
@property (nonatomic) NSMutableArray<NSNumber *> *resumeGenerations;
@property (nonatomic) uint64_t coreGeneration;
@property (nonatomic) BOOL admissionClosed;
@property (nonatomic) BOOL drainPermit;
@property (nonatomic) BOOL activeOperation;
@property (nonatomic) BOOL throwPrepare;
@property (nonatomic) BOOL throwResume;
@property (nonatomic) BOOL throwCancel;
@property (nonatomic, copy) dispatch_block_t sessionRecoveryObserver;
@property (nonatomic) BOOL sessionRecoveryAwaitingRegistration;
@property (nonatomic) BOOL sessionRecoveryConfirmedRunning;
@property (nonatomic) NSUInteger invariants;
@property (nonatomic, weak) DSHLifecycleCoordinator *coordinator;
- (void)completePreparation:(NSUInteger)index success:(BOOL)success;
- (void)completeResume:(NSUInteger)index success:(BOOL)success;
@end
@implementation DSHSessionCoordinatorDriver
- (instancetype)init {
    if ((self = [super init])) {
        _calls = [NSMutableArray array]; _records = [NSMutableArray array];
        _preparations = [NSMutableArray array]; _preparationGenerations = [NSMutableArray array];
        _resumes = [NSMutableArray array]; _resumeGenerations = [NSMutableArray array];
        _sessionRecoveryConfirmedRunning = YES;
    }
    return self;
}
- (void)call:(NSString *)name {
    if (!NSThread.isMainThread) self.invariants++;
    [self.calls addObject:name];
}
- (uint64_t)closeAdmission {
    [self call:@"close"]; self.admissionClosed = YES; self.drainPermit = NO;
    return ++self.coreGeneration;
}
- (BOOL)markQuiescentForGeneration:(uint64_t)generation {
    [self call:@"mark"];
    if (!self.admissionClosed || self.drainPermit) self.invariants++;
    return generation == self.coreGeneration && !self.activeOperation && !self.drainPermit;
}
- (void)beginResume {
    [self call:@"beginResume"];
    if (!self.admissionClosed || self.coordinator.state != DSHLifecycleCoordinatorStateResuming) self.invariants++;
    self.drainPermit = NO; self.coreGeneration++;
}
- (void)openAdmission { [self call:@"open"]; self.admissionClosed = NO; self.drainPermit = NO; }
- (void)suspendSockets {
    [self call:@"socketSuspend"];
    if (!self.admissionClosed || self.drainPermit) self.invariants++;
}
- (void)resumeSockets {
    [self call:@"socketResume"];
    if (!self.admissionClosed || self.coordinator.state != DSHLifecycleCoordinatorStateResuming) self.invariants++;
}
- (void)pauseHarnessSupervision { [self call:@"harnessPause"]; }
- (void)resumeHarnessSupervision {
    [self call:@"harnessResume"];
    if (self.admissionClosed || self.coordinator.state != DSHLifecycleCoordinatorStateRunning) self.invariants++;
}
- (NSDictionary *)diagnosticSnapshot {
    return @{@"admission_closed": @(self.admissionClosed), @"session_drain_active": @(self.drainPermit)};
}
- (void)recordLifecycleEvent:(NSString *)event details:(NSDictionary *)details {
    if (!NSThread.isMainThread) self.invariants++;
    NSMutableDictionary *record = [details mutableCopy]; record[@"event"] = event;
    [self.records addObject:record];
}
- (void)prepareSessionsForGeneration:(uint64_t)generation completion:(DSHSessionResult)completion {
    [self call:@"prepare"];
    if (!self.admissionClosed || ![self.calls containsObject:@"taskBegin"]) self.invariants++;
    if (self.throwPrepare) [NSException raise:@"Sensitive-name-fixture" format:@"must never be persisted"];
    self.drainPermit = YES;
    [self.preparations addObject:[completion copy]];
    [self.preparationGenerations addObject:@(generation)];
}
- (void)cancelSessionTransition {
    [self call:@"cancel"];
    if (self.throwCancel) [NSException raise:@"Sensitive-cancel-fixture" format:@"must never be persisted"];
    self.drainPermit = NO;
}
- (void)resumeSessionsWithCompletion:(DSHSessionResult)completion {
    [self call:@"resumeSessions"];
    if (!self.admissionClosed || self.coordinator.state != DSHLifecycleCoordinatorStateResuming) self.invariants++;
    if (self.throwResume) [NSException raise:@"Sensitive-resume-fixture" format:@"must never be persisted"];
    self.drainPermit = YES;
    [self.resumes addObject:[completion copy]];
    [self.resumeGenerations addObject:@(self.coreGeneration)];
}
- (void)completePreparation:(NSUInteger)index success:(BOOL)success {
    if ([self.preparationGenerations[index] unsignedLongLongValue] == self.coreGeneration) self.drainPermit = NO;
    self.preparations[index](success);
}
- (void)completeResume:(NSUInteger)index success:(BOOL)success {
    if ([self.resumeGenerations[index] unsignedLongLongValue] == self.coreGeneration) self.drainPermit = NO;
    self.resumes[index](success);
}
@end

@interface DSHSessionCoordinatorTasks : NSObject <DSHLifecycleBackgroundTasks>
@property (nonatomic) NSMutableArray<NSString *> *calls;
@property (nonatomic) NSMutableArray<dispatch_block_t> *expirations;
@property (nonatomic) NSMutableArray<NSNumber *> *ended;
@property (nonatomic) NSUInteger begins;
@property (nonatomic) BOOL denied;
@property (nonatomic) BOOL synchronousExpiry;
@end
@implementation DSHSessionCoordinatorTasks
- (instancetype)init {
    if ((self = [super init])) { _expirations = [NSMutableArray array]; _ended = [NSMutableArray array]; }
    return self;
}
- (NSUInteger)beginTaskWithName:(NSString *)name expirationHandler:(dispatch_block_t)expiration {
    [self.calls addObject:@"taskBegin"]; self.begins++;
    [self.expirations addObject:[expiration copy]];
    if (self.synchronousExpiry) expiration();
    return self.denied ? NSUIntegerMax : self.begins;
}
- (void)endTask:(NSUInteger)identifier {
    [self.calls addObject:@"taskEnd"]; [self.ended addObject:@(identifier)];
}
@end

@interface DSHSessionLifecycleCoordinatorTests : XCTestCase
@property (nonatomic) DSHSessionCoordinatorDriver *driver;
@property (nonatomic) DSHSessionCoordinatorTasks *tasks;
@property (nonatomic) DSHSessionTestClock *clock;
@property (nonatomic) DSHLifecycleCoordinator *coordinator;
@end
@implementation DSHSessionLifecycleCoordinatorTests
- (void)setUp {
    [super setUp]; XCTAssertTrue(NSThread.isMainThread);
    self.driver = [DSHSessionCoordinatorDriver new]; self.tasks = [DSHSessionCoordinatorTasks new];
    self.tasks.calls = self.driver.calls; self.clock = [DSHSessionTestClock new];
    DSHSessionTestClock *clock = self.clock;
    self.coordinator = [[DSHLifecycleCoordinator alloc] initWithDriver:self.driver backgroundTasks:self.tasks
        scheduler:^(NSTimeInterval delay, dispatch_block_t action) { [clock schedule:delay action:action]; }
        clock:^{ return clock.now; }];
    self.driver.coordinator = self.coordinator;
}
- (void)tearDown {
    self.driver.throwPrepare = self.driver.throwResume = self.driver.throwCancel = NO;
    if (self.coordinator.state != DSHLifecycleCoordinatorStateRunning) [self.coordinator handleAppForeground];
    if (self.coordinator.state == DSHLifecycleCoordinatorStateResuming)
        [self.driver completeResume:self.driver.resumes.count - 1 success:YES];
    XCTAssertEqual(self.driver.invariants, 0u);
    self.coordinator = nil; [super tearDown];
}
- (NSUInteger)count:(NSString *)name {
    return [self.driver.calls filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF == %@", name]].count;
}
- (NSDictionary *)record:(NSString *)name {
    for (NSDictionary *record in self.driver.records) if ([record[@"event"] isEqual:name]) return record;
    return nil;
}
- (void)quiesce {
    [self.coordinator handleAppBackground]; [self.driver completePreparation:self.driver.preparations.count - 1 success:YES];
    XCTAssertEqual(self.coordinator.state, DSHLifecycleCoordinatorStateQuiesced);
}

- (void)testFiniteTaskPrecedesPreparationAndAcknowledgementGatesAtomicMark {
    [self.coordinator handleAppBackground];
    XCTAssertEqualObjects(self.driver.calls, (@[@"close", @"harnessPause", @"taskBegin", @"prepare"]));
    XCTAssertEqual([self count:@"mark"], 0u); XCTAssertTrue(self.driver.drainPermit);
    [self.clock advance:0.2]; XCTAssertEqual([self count:@"mark"], 0u);
    [self.driver completePreparation:0 success:YES];
    XCTAssertEqual(self.coordinator.state, DSHLifecycleCoordinatorStateQuiesced);
    XCTAssertEqual([self count:@"socketSuspend"], 1u); XCTAssertEqualObjects(self.tasks.ended, (@[@1]));
    XCTAssertNotNil([self record:@"sessionQuiesceAcknowledged"]);
}
- (void)testSessionAcknowledgementCannotOverrideAnActiveCoreOperation {
    self.driver.activeOperation = YES; [self.coordinator handleAppBackground];
    [self.driver completePreparation:0 success:YES];
    XCTAssertEqual(self.coordinator.state, DSHLifecycleCoordinatorStateQuiescing);
    XCTAssertGreaterThan([self count:@"mark"], 0u); XCTAssertEqual([self count:@"socketSuspend"], 0u);
    self.driver.activeOperation = NO; [self.clock advance:0.05];
    XCTAssertEqual(self.coordinator.state, DSHLifecycleCoordinatorStateQuiesced);
}
- (void)testExpiryCancelsPermitAndLateAcknowledgementCannotSuspend {
    [self.coordinator handleAppBackground]; self.tasks.expirations[0]();
    XCTAssertEqual([self count:@"cancel"], 1u); XCTAssertFalse(self.driver.drainPermit);
    [self.driver completePreparation:0 success:YES]; [self.clock advance:20];
    XCTAssertEqual([self count:@"mark"], 0u); XCTAssertEqual([self count:@"socketSuspend"], 0u);
    XCTAssertTrue(self.driver.admissionClosed); XCTAssertEqualObjects(self.tasks.ended, (@[@1]));
    XCTAssertNotNil([self record:@"quiesceExpired"]);
}
- (void)testDeniedBackgroundTaskNeverStartsSessionDrainOrTimers {
    self.tasks.denied = YES; [self.coordinator handleAppBackground];
    XCTAssertEqual([self count:@"prepare"], 0u); XCTAssertEqual([self count:@"cancel"], 1u);
    XCTAssertEqual([self count:@"mark"], 0u); XCTAssertEqual(self.clock.actions.count, 0u);
    XCTAssertTrue(self.driver.admissionClosed); XCTAssertEqual(self.tasks.ended.count, 0u);
    XCTAssertNotNil([self record:@"quiesceTaskDenied"]);
}
- (void)testSynchronousExpiryBeforeIdentifierReturnsNeverGrantsAndEndsOnce {
    self.tasks.synchronousExpiry = YES; [self.coordinator handleAppBackground];
    XCTAssertEqual([self count:@"prepare"], 0u); XCTAssertEqual([self count:@"cancel"], 1u);
    XCTAssertEqualObjects(self.tasks.ended, (@[@1])); XCTAssertEqual(self.clock.actions.count, 0u);
    self.tasks.expirations[0](); XCTAssertEqualObjects(self.tasks.ended, (@[@1]));
}
- (void)testRapidForegroundCancelsPreparationAndIgnoresLateBackgroundAck {
    [self.coordinator handleAppBackground]; [self.coordinator handleAppForeground];
    XCTAssertEqual(self.coordinator.state, DSHLifecycleCoordinatorStateResuming);
    XCTAssertEqual([self count:@"cancel"], 1u); XCTAssertEqual([self count:@"socketResume"], 0u);
    [self.driver completePreparation:0 success:YES];
    XCTAssertEqual([self count:@"mark"], 0u); XCTAssertEqual([self count:@"open"], 0u);
    [self.driver completeResume:0 success:YES];
    XCTAssertEqual(self.coordinator.state, DSHLifecycleCoordinatorStateRunning);
    XCTAssertEqual([self count:@"harnessResume"], 1u);
}
- (void)testDuplicateLifecycleAndGuestCompletionsRemainIdempotent {
    [self.coordinator handleAppBackground]; [self.coordinator handleAppBackground];
    XCTAssertEqual(self.tasks.begins, 1u); XCTAssertEqual([self count:@"prepare"], 1u);
    [self.driver completePreparation:0 success:YES]; [self.driver completePreparation:0 success:YES];
    XCTAssertEqual([self count:@"socketSuspend"], 1u);
    [self.coordinator handleAppForeground]; [self.coordinator handleAppResume];
    XCTAssertEqual([self count:@"resumeSessions"], 1u);
    [self.driver completeResume:0 success:YES]; [self.driver completeResume:0 success:YES];
    [self.clock advance:20]; XCTAssertEqual([self count:@"harnessResume"], 1u);
}
- (void)testAsyncResumeRestoresSocketsBeforeWriterAndKeepsGateClosedUntilReady {
    [self quiesce]; [self.driver.calls removeAllObjects]; [self.coordinator handleAppForeground];
    XCTAssertEqualObjects(self.driver.calls, (@[@"cancel", @"beginResume", @"socketResume", @"resumeSessions"]));
    XCTAssertTrue(self.driver.admissionClosed); XCTAssertEqual([self count:@"harnessResume"], 0u);
    [self.driver completeResume:0 success:YES];
    XCTAssertEqualObjects([self.driver.calls subarrayWithRange:NSMakeRange(4, 2)], (@[@"open", @"harnessResume"]));
    XCTAssertFalse(self.driver.admissionClosed);
}
- (void)testResumeFailureCancelsPermitAndRecoversUIWithoutRestartingHarness {
    [self quiesce]; [self.coordinator handleAppForeground];
    NSUInteger cancellations = [self count:@"cancel"];
    [self.driver completeResume:0 success:NO];
    XCTAssertEqual([self count:@"cancel"], cancellations + 1);
    XCTAssertNotNil([self record:@"sessionResumeFailed"]);
    XCTAssertEqual(self.coordinator.state, DSHLifecycleCoordinatorStateRunning);
    XCTAssertFalse(self.driver.admissionClosed); XCTAssertEqual([self count:@"harnessResume"], 1u);
}
- (void)testResumeDeadlineCancelsAndLateSuccessCannotRunHealthOrNativeWorkTwice {
    self.coordinator.sessionResumeTimeout = 3; [self quiesce];
    __block NSUInteger nativeRuns = 0;
    [self.coordinator performWhenRunning:^{ nativeRuns++; }];
    [self.coordinator handleAppForeground]; [self.clock advance:2.99];
    XCTAssertTrue(self.driver.admissionClosed); XCTAssertEqual(nativeRuns, 0u);
    [self.clock advance:0.01];
    XCTAssertNotNil([self record:@"sessionResumeTimedOut"]); XCTAssertFalse(self.driver.drainPermit);
    XCTAssertEqual(nativeRuns, 1u); XCTAssertEqual([self count:@"harnessResume"], 1u);
    [self.driver completeResume:0 success:YES]; [self.clock advance:20];
    XCTAssertEqual(nativeRuns, 1u); XCTAssertEqual([self count:@"harnessResume"], 1u);
}
- (void)testPreparationExceptionStaysClosedAndDoesNotPersistExceptionContents {
    self.driver.throwPrepare = YES; [self.coordinator handleAppBackground];
    XCTAssertNotNil([self record:@"sessionQuiesceDriverException"]);
    XCTAssertNotNil([self record:@"sessionQuiesceFailed"]);
    XCTAssertEqual([self count:@"mark"], 0u); XCTAssertTrue(self.driver.admissionClosed);
    XCTAssertFalse([[self.driver.records description] containsString:@"Sensitive"]);
    XCTAssertFalse([[self.driver.records description] containsString:@"must never"]);
}
- (void)testResumeExceptionRecordsFailureAndOpensUIWithOneSupervisionResume {
    [self quiesce]; self.driver.throwResume = YES; [self.coordinator handleAppForeground];
    XCTAssertNotNil([self record:@"sessionResumeDriverException"]); XCTAssertNotNil([self record:@"sessionResumeFailed"]);
    XCTAssertTrue(self.coordinator.sessionRecoveryNeedsAttention);
    XCTAssertEqual(self.coordinator.state, DSHLifecycleCoordinatorStateRunning);
    XCTAssertEqual([self count:@"harnessResume"], 1u); XCTAssertFalse(self.driver.admissionClosed);
    [self.clock advance:20]; XCTAssertEqual([self count:@"harnessResume"], 1u);
}
- (void)testBackgroundDuringResumeKeepsGateClosedAndNativeActionsQueuedForNextForeground {
    [self quiesce]; __block NSUInteger nativeRuns = 0;
    [self.coordinator performWhenRunning:^{ XCTAssertFalse(self.driver.admissionClosed); nativeRuns++; }];
    [self.coordinator handleAppForeground]; [self.coordinator handleAppBackground]; [self.coordinator handleAppBackground];
    XCTAssertEqual(self.tasks.begins, 2u, @"new finite assertion must cover writer restoration as soon as the scene backgrounds");
    XCTAssertEqualObjects(self.tasks.ended, (@[@1]));
    XCTAssertEqual([self count:@"prepare"], 1u, @"deferred cycle cannot start another drain during foreground writer restoration");
    [self.driver completeResume:0 success:YES];
    XCTAssertEqual(self.tasks.begins, 2u); XCTAssertEqual(self.coordinator.state, DSHLifecycleCoordinatorStateQuiescing);
    XCTAssertTrue(self.driver.admissionClosed); XCTAssertEqual([self count:@"open"], 0u);
    XCTAssertEqual([self count:@"harnessResume"], 0u); XCTAssertEqual(nativeRuns, 0u);
    [self.driver completePreparation:1 success:YES]; [self.coordinator handleAppForeground];
    [self.driver completeResume:1 success:YES];
    XCTAssertEqual(nativeRuns, 1u); XCTAssertEqual([self count:@"harnessResume"], 1u);
}
- (void)testLatestForegroundCancelsADeferredBackgroundIntentDuringResume {
    [self quiesce]; [self.coordinator handleAppForeground]; [self.coordinator handleAppBackground];
    [self.coordinator handleAppForeground]; [self.driver completeResume:0 success:YES];
    XCTAssertEqual(self.tasks.begins, 2u); XCTAssertEqualObjects(self.tasks.ended, (@[@1, @2]));
    XCTAssertEqual(self.coordinator.state, DSHLifecycleCoordinatorStateRunning);
    XCTAssertEqual([self count:@"harnessResume"], 1u);
}
- (void)testOldResumeCompletionCannotFinishOrCancelANewerTransition {
    self.coordinator.sessionResumeTimeout = 1; [self quiesce]; [self.coordinator handleAppForeground];
    [self.clock advance:1]; [self.coordinator handleAppBackground];
    [self.driver completePreparation:1 success:YES]; [self.coordinator handleAppForeground];
    NSUInteger cancellations = [self count:@"cancel"];
    [self.driver completeResume:0 success:NO];
    XCTAssertEqual([self count:@"cancel"], cancellations); XCTAssertTrue(self.driver.drainPermit);
    XCTAssertEqual(self.coordinator.state, DSHLifecycleCoordinatorStateResuming);
    [self.driver completeResume:1 success:YES]; XCTAssertEqual([self count:@"harnessResume"], 2u);
}
- (void)testWorkerQueueAcknowledgementIsAppliedOnlyOnTheMainQueue {
    [self.coordinator handleAppBackground];
    DSHSessionResult completion = self.driver.preparations[0]; self.driver.drainPermit = NO;
    XCTestExpectation *applied = [self expectationWithDescription:@"ack applied on main queue"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        completion(YES);
        dispatch_async(dispatch_get_main_queue(), ^{
            XCTAssertEqual(self.coordinator.state, DSHLifecycleCoordinatorStateQuiesced);
            [applied fulfill];
        });
    });
    [self waitForExpectations:@[applied] timeout:2];
    XCTAssertEqual(self.driver.invariants, 0u);
}
- (void)testCancellationExceptionDoesNotPreventForegroundUIRecovery {
    [self.coordinator handleAppBackground]; self.driver.throwCancel = YES;
    [self.coordinator handleAppForeground];
    XCTAssertNotNil([self record:@"sessionCancelDriverException"]);
    self.driver.throwCancel = NO; [self.driver completeResume:0 success:YES];
    XCTAssertFalse(self.driver.admissionClosed); XCTAssertEqual([self count:@"harnessResume"], 1u);
    XCTAssertFalse([[self.driver.records description] containsString:@"Sensitive"]);
}
- (void)testOldExpiryAndPreparationAckCannotRevokeANewerBackgroundDrain {
    [self.coordinator handleAppBackground]; [self.coordinator handleAppForeground];
    [self.driver completeResume:0 success:YES]; [self.coordinator handleAppBackground];
    NSUInteger cancellations = [self count:@"cancel"];
    self.tasks.expirations[0](); [self.driver completePreparation:0 success:YES];
    XCTAssertEqual([self count:@"cancel"], cancellations); XCTAssertTrue(self.driver.drainPermit);
    XCTAssertEqual([self count:@"socketSuspend"], 0u);
    [self.driver completePreparation:1 success:YES]; XCTAssertEqual([self count:@"socketSuspend"], 1u);
}
- (void)testInvalidResumeTimeoutUsesTheFiniteDefault {
    self.coordinator.sessionResumeTimeout = 0; [self quiesce]; [self.coordinator handleAppForeground];
    [self.clock advance:14.99]; XCTAssertEqual(self.coordinator.state, DSHLifecycleCoordinatorStateResuming);
    [self.clock advance:0.01]; XCTAssertEqual(self.coordinator.state, DSHLifecycleCoordinatorStateRunning);
    XCTAssertNotNil([self record:@"sessionResumeTimedOut"]);
}
- (void)testDeferredBackgroundTaskDenialCancelsResumeWithoutOpeningTheGate {
    [self quiesce]; [self.coordinator handleAppForeground]; self.tasks.denied = YES;
    [self.coordinator handleAppBackground];
    XCTAssertEqual(self.coordinator.state, DSHLifecycleCoordinatorStateQuiescing);
    XCTAssertEqual(self.tasks.begins, 2u); XCTAssertEqual([self count:@"prepare"], 1u);
    XCTAssertEqual([self count:@"open"], 0u); XCTAssertEqual([self count:@"harnessResume"], 0u);
    XCTAssertTrue(self.driver.admissionClosed); XCTAssertFalse(self.driver.drainPermit);
    [self.driver completeResume:0 success:YES];
    XCTAssertEqual(self.coordinator.state, DSHLifecycleCoordinatorStateQuiescing);
    XCTAssertNotNil([self record:@"quiesceTaskDenied"]);
}
- (void)testDeferredBackgroundExpiryCancelsRestorationAndEndsItsOwnTask {
    [self quiesce]; [self.coordinator handleAppForeground]; [self.coordinator handleAppBackground];
    self.tasks.expirations[1]();
    XCTAssertEqual(self.coordinator.state, DSHLifecycleCoordinatorStateQuiescing);
    XCTAssertEqualObjects(self.tasks.ended, (@[@1, @2])); XCTAssertEqual(self.tasks.begins, 2u);
    XCTAssertEqual([self count:@"prepare"], 1u); XCTAssertEqual([self count:@"harnessResume"], 0u);
    XCTAssertNotNil([self record:@"deferredBackgroundExpired"]); XCTAssertNotNil([self record:@"quiesceExpired"]);
    [self.driver completeResume:0 success:YES]; [self.clock advance:20];
    XCTAssertEqual([self count:@"open"], 0u); XCTAssertTrue(self.driver.admissionClosed);
}
- (void)testSynchronousDeferredExpiryIsSafeBeforeTheSecondTaskIdentifierReturns {
    [self quiesce]; [self.coordinator handleAppForeground]; self.tasks.synchronousExpiry = YES;
    [self.coordinator handleAppBackground];
    XCTAssertEqual(self.tasks.begins, 2u); XCTAssertEqualObjects(self.tasks.ended, (@[@1, @2]));
    XCTAssertEqual(self.coordinator.state, DSHLifecycleCoordinatorStateQuiescing);
    XCTAssertEqual([self count:@"prepare"], 1u); XCTAssertEqual([self count:@"open"], 0u);
    self.tasks.expirations[1](); XCTAssertEqualObjects(self.tasks.ended, (@[@1, @2]));
}
- (void)testResumeTimeoutReusesTheDeferredFiniteTaskForBackgroundDrain {
    self.coordinator.sessionResumeTimeout = 1; [self quiesce];
    __block NSUInteger nativeRuns = 0; [self.coordinator performWhenRunning:^{ nativeRuns++; }];
    [self.coordinator handleAppForeground]; [self.coordinator handleAppBackground]; [self.clock advance:1];
    XCTAssertEqual(self.tasks.begins, 2u); XCTAssertEqual([self count:@"prepare"], 2u);
    XCTAssertEqual(self.coordinator.state, DSHLifecycleCoordinatorStateQuiescing);
    XCTAssertEqual([self count:@"harnessResume"], 0u); XCTAssertEqual(nativeRuns, 0u);
    [self.driver completePreparation:1 success:YES]; [self.coordinator handleAppForeground];
    [self.driver completeResume:1 success:YES];
    XCTAssertEqual(nativeRuns, 1u); XCTAssertEqual([self count:@"harnessResume"], 1u);
}
- (void)testSessionRecoveryFailureRemainsVisibleAcrossNativeUIRecovery {
    XCTAssertFalse(self.coordinator.sessionRecoveryNeedsAttention);
    [self quiesce]; [self.coordinator handleAppForeground];
    [self.driver completeResume:0 success:NO];
    XCTAssertTrue(self.coordinator.sessionRecoveryNeedsAttention);
    XCTAssertEqualObjects([self record:@"sessionResumeFailed"][@"session_recovery_needs_attention"], @YES,
                          @"The warning must be set before observers receive the failure diagnostic");
    XCTAssertEqual(self.coordinator.state, DSHLifecycleCoordinatorStateRunning);
    XCTAssertEqual([self count:@"harnessResume"], 1u);
    [self.coordinator performWhenRunning:^{
        XCTAssertTrue(self.coordinator.sessionRecoveryNeedsAttention,
                      @"Native UI recovery and HTTP supervision cannot clear a writer failure");
    }];
    [self.coordinator handleAppForeground];
    XCTAssertTrue(self.coordinator.sessionRecoveryNeedsAttention);
    [self quiesce];
    XCTAssertTrue(self.coordinator.sessionRecoveryNeedsAttention,
                  @"A successful background release is not a successful foreground restore");
}
- (void)testStaleSuccessCannotClearAttentionBeforeANewGenerationRestoreSucceeds {
    self.coordinator.sessionResumeTimeout = 1;
    [self quiesce]; [self.coordinator handleAppForeground]; [self.clock advance:1];
    XCTAssertTrue(self.coordinator.sessionRecoveryNeedsAttention);
    XCTAssertEqualObjects([self record:@"sessionResumeTimedOut"][@"session_recovery_needs_attention"], @YES);
    [self quiesce]; [self.coordinator handleAppForeground];
    [self.driver completeResume:0 success:YES];
    self.tasks.expirations[0](); [self.driver completePreparation:0 success:YES];
    XCTAssertEqual(self.coordinator.state, DSHLifecycleCoordinatorStateResuming);
    XCTAssertTrue(self.coordinator.sessionRecoveryNeedsAttention);
    [self.driver completeResume:1 success:YES];
    XCTAssertEqual(self.coordinator.state, DSHLifecycleCoordinatorStateRunning);
    XCTAssertFalse(self.coordinator.sessionRecoveryNeedsAttention);
    [self.driver completeResume:0 success:NO]; [self.clock advance:1];
    XCTAssertFalse(self.coordinator.sessionRecoveryNeedsAttention,
                   @"An old failure or timeout cannot overwrite a new successful restore");
}
- (void)testResumeSuccessDeliveredAtTheDeadlineStillNeedsAttention {
    self.coordinator.sessionResumeTimeout = 1;
    [self quiesce]; [self.coordinator handleAppForeground];
    // Model a delayed main-queue callback before its scheduled timeout block.
    self.clock.now += 1;
    [self.driver completeResume:0 success:YES];
    XCTAssertTrue(self.coordinator.sessionRecoveryNeedsAttention);
    XCTAssertNotNil([self record:@"sessionResumeTimedOut"]);
    [self.driver completeResume:0 success:YES];
    XCTAssertTrue(self.coordinator.sessionRecoveryNeedsAttention);
}
- (void)testLateStartupRegistrationNeedsARealCurrentRunningConfirmationToClearAttention {
    self.driver.sessionRecoveryAwaitingRegistration = YES;
    self.driver.sessionRecoveryConfirmedRunning = NO;
    self.coordinator.sessionResumeTimeout = 1;
    [self.coordinator handleAppBackground]; [self.coordinator handleAppForeground];
    XCTAssertTrue(self.coordinator.sessionRecoveryAwaitingRegistration);
    XCTAssertTrue(self.driver.admissionClosed, @"Unregistered startup cannot authorize resume");
    [self.clock advance:1];
    XCTAssertTrue(self.coordinator.sessionRecoveryNeedsAttention);
    XCTAssertTrue(self.coordinator.sessionRecoveryAwaitingRegistration);
    XCTAssertEqualObjects([self record:@"sessionResumeTimedOut"][@"session_recovery_awaiting_registration"], @YES);
    NSUInteger opens = [self count:@"open"], resumes = [self count:@"harnessResume"];
    self.driver.sessionRecoveryAwaitingRegistration = NO;
    self.driver.sessionRecoveryObserver();
    XCTAssertFalse(self.coordinator.sessionRecoveryAwaitingRegistration);
    XCTAssertTrue(self.coordinator.sessionRecoveryNeedsAttention,
                  @"Registration and pre-existing writers must not be treated as recovery success");
    [self.driver completeResume:0 success:YES];
    XCTAssertTrue(self.coordinator.sessionRecoveryNeedsAttention, @"An obsolete callback cannot clear the timeout");
    self.driver.sessionRecoveryConfirmedRunning = YES;
    self.driver.sessionRecoveryObserver();
    XCTAssertFalse(self.coordinator.sessionRecoveryNeedsAttention);
    XCTAssertNotNil([self record:@"sessionRecoveryConfirmed"]);
    XCTAssertEqual([self count:@"open"], opens); XCTAssertEqual([self count:@"harnessResume"], resumes);
}
- (void)testRecoveryObservationCannotCompleteOrOpenABackgroundCycle {
    self.coordinator.sessionResumeTimeout = 1;
    [self quiesce]; [self.coordinator handleAppForeground]; [self.clock advance:1];
    [self.coordinator handleAppBackground];
    NSUInteger opens = [self count:@"open"], resumes = [self count:@"harnessResume"];
    self.driver.sessionRecoveryObserver();
    XCTAssertTrue(self.coordinator.sessionRecoveryNeedsAttention);
    XCTAssertEqual(self.coordinator.state, DSHLifecycleCoordinatorStateQuiescing);
    XCTAssertTrue(self.driver.admissionClosed);
    XCTAssertEqual([self count:@"open"], opens); XCTAssertEqual([self count:@"harnessResume"], resumes);
    [self.driver completePreparation:1 success:YES]; [self.coordinator handleAppForeground];
    [self.driver completeResume:1 success:YES];
    XCTAssertFalse(self.coordinator.sessionRecoveryNeedsAttention);
}
- (void)testSafeAbsentGuestCompletionDoesNotClearAnUnconfirmedWriterFailure {
    [self quiesce]; [self.coordinator handleAppForeground];
    [self.driver completeResume:0 success:NO];
    self.driver.sessionRecoveryConfirmedRunning = NO;
    [self quiesce]; [self.coordinator handleAppForeground];
    [self.driver completeResume:1 success:YES];
    XCTAssertTrue(self.coordinator.sessionRecoveryNeedsAttention,
                  @"Exit/absent completion permits UI progress but cannot prove writer recovery");
    self.driver.sessionRecoveryObserver();
    XCTAssertTrue(self.coordinator.sessionRecoveryNeedsAttention);
}
- (void)testShownStartupWarningUpdatesAndDismissesOnlyAfterConfirmedRecovery {
    self.driver.sessionRecoveryAwaitingRegistration = YES;
    self.driver.sessionRecoveryConfirmedRunning = NO;
    self.coordinator.sessionResumeTimeout = 1;
    [self.coordinator handleAppBackground]; [self.coordinator handleAppForeground]; [self.clock advance:1];
    DSHSessionRecoveryViewFixture *controller = [DSHSessionRecoveryViewFixture new];
    UIWindow *window = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, 640, 480)];
    [window addSubview:controller.view];
    [controller updateSessionRecoveryIssueForCoordinator:self.coordinator];
    UIAlertController *alert = (UIAlertController *)controller.presentedViewController;
    XCTAssertNotNil(alert); XCTAssertEqual(controller.presentations, 1u);
    XCTAssertEqualObjects(alert.title, @"Session recovery is waiting for startup");
    self.driver.sessionRecoveryAwaitingRegistration = NO; self.driver.sessionRecoveryObserver();
    [controller updateSessionRecoveryIssueForCoordinator:self.coordinator];
    XCTAssertEqualObjects(alert.title, @"Session recovery needs attention");
    XCTAssertEqual(controller.presentations, 1u); XCTAssertEqual(controller.dismissals, 0u);
    [self.driver completeResume:0 success:YES];
    [controller updateSessionRecoveryIssueForCoordinator:self.coordinator];
    XCTAssertEqual(controller.dismissals, 0u, @"Stale success cannot hide the warning");
    self.driver.sessionRecoveryConfirmedRunning = YES; self.driver.sessionRecoveryObserver();
    [controller updateSessionRecoveryIssueForCoordinator:self.coordinator];
    XCTAssertNil(controller.presentedViewController); XCTAssertEqual(controller.dismissals, 1u);
    [controller updateSessionRecoveryIssueForCoordinator:self.coordinator];
    XCTAssertEqual(controller.dismissals, 1u);
    [controller.view removeFromSuperview];
}
- (void)testNewFailureDuringWarningDismissalIsPresentedAfterAnimation {
    self.driver.sessionRecoveryConfirmedRunning = NO;
    [self quiesce]; [self.coordinator handleAppForeground]; [self.driver completeResume:0 success:NO];
    DSHSessionRecoveryViewFixture *controller = [DSHSessionRecoveryViewFixture new];
    UIWindow *window = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, 640, 480)];
    [window addSubview:controller.view];
    [controller updateSessionRecoveryIssueForCoordinator:self.coordinator];
    XCTAssertEqual(controller.presentations, 1u);
    controller.deferDismissal = YES;
    self.driver.sessionRecoveryConfirmedRunning = YES;
    self.driver.sessionRecoveryObserver();
    [controller updateSessionRecoveryIssueForCoordinator:self.coordinator];
    XCTAssertNotNil(controller.pendingDismissal); XCTAssertEqual(controller.dismissals, 1u);
    self.driver.sessionRecoveryConfirmedRunning = NO;
    [self quiesce]; [self.coordinator handleAppForeground]; [self.driver completeResume:1 success:NO];
    [controller updateSessionRecoveryIssueForCoordinator:self.coordinator];
    XCTAssertEqual(controller.presentations, 1u, @"UIKit still owns the dismissing alert");
    [controller finishDismissal];
    XCTAssertEqual(controller.presentations, 2u);
    XCTAssertEqualObjects(controller.presentedViewController.title, @"Session recovery needs attention");
    [controller.view removeFromSuperview];
}
- (void)testCoordinatorTeardownCancelsItsDrainAndLateCompletionIsHarmless {
    [self.coordinator handleAppBackground];
    __weak DSHLifecycleCoordinator *weakCoordinator = self.coordinator;
    self.coordinator = nil;
    XCTAssertNil(weakCoordinator); XCTAssertFalse(self.driver.drainPermit);
    XCTAssertEqual([self count:@"cancel"], 1u); XCTAssertEqualObjects(self.tasks.ended, (@[@1]));
    [self.driver completePreparation:0 success:YES]; self.tasks.expirations[0]();
    [self.clock advance:20]; XCTAssertEqual([self count:@"open"], 0u);
}
@end
