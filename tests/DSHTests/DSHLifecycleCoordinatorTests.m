#import <XCTest/XCTest.h>
#import "DSHLifecycleCoordinator.h"

@interface DSHLifecycleScheduledAction : NSObject
@property (nonatomic) NSTimeInterval due;
@property (nonatomic, copy) dispatch_block_t action;
@end
@implementation DSHLifecycleScheduledAction
@end

@interface DSHLifecycleTestClock : NSObject
@property (nonatomic) NSTimeInterval now;
@property (nonatomic) NSMutableArray<DSHLifecycleScheduledAction *> *actions;
- (void)schedule:(NSTimeInterval)delay action:(dispatch_block_t)action;
- (void)advance:(NSTimeInterval)seconds;
@end
@implementation DSHLifecycleTestClock
- (instancetype)init {
    if ((self = [super init])) { _now = 100; _actions = [NSMutableArray array]; }
    return self;
}
- (void)schedule:(NSTimeInterval)delay action:(dispatch_block_t)action {
    DSHLifecycleScheduledAction *entry = [DSHLifecycleScheduledAction new];
    entry.due = self.now + delay;
    entry.action = action;
    [self.actions addObject:entry];
}
- (void)advance:(NSTimeInterval)seconds {
    NSTimeInterval target = self.now + seconds;
    while (YES) {
        DSHLifecycleScheduledAction *next = nil;
        for (DSHLifecycleScheduledAction *entry in self.actions)
            if (entry.due <= target && (next == nil || entry.due < next.due)) next = entry;
        if (!next) break;
        [self.actions removeObject:next];
        self.now = next.due;
        next.action();
    }
    self.now = target;
}
@end

@interface DSHLifecycleTestDriver : NSObject <DSHLifecycleDriver>
@property (nonatomic) NSMutableArray<NSString *> *calls;
@property (nonatomic) NSMutableArray<NSDictionary *> *records;
@property (nonatomic) NSUInteger activeOperations;
@property (nonatomic) NSUInteger activeTransactions;
@property (nonatomic) NSUInteger activeFlocks;
@property (nonatomic) NSUInteger unsafeObservations;
@property (nonatomic) NSUInteger recoveryBlockedConnections;
@property (nonatomic) NSUInteger atomicMarkFailures;
@property (nonatomic) NSUInteger markAttempts;
@property (nonatomic) uint64_t coreGeneration;
@property (nonatomic) BOOL admissionClosed;
@property (nonatomic) NSUInteger invariantViolations;
@property (nonatomic, weak) DSHLifecycleCoordinator *coordinator;
@end
@implementation DSHLifecycleTestDriver
- (instancetype)init {
    if ((self = [super init])) { _calls = [NSMutableArray array]; _records = [NSMutableArray array]; }
    return self;
}
- (uint64_t)closeAdmission {
    [self.calls addObject:@"close"];
    self.admissionClosed = YES;
    return ++self.coreGeneration;
}
- (BOOL)markQuiescentForGeneration:(uint64_t)generation {
    [self.calls addObject:@"mark"];
    self.markAttempts++;
    if (!self.admissionClosed) self.invariantViolations++;
    if (self.atomicMarkFailures > 0) { self.atomicMarkFailures--; return NO; }
    return generation == self.coreGeneration && self.activeOperations == 0 && self.activeTransactions == 0 &&
           self.activeFlocks == 0 && self.unsafeObservations == 0 && self.recoveryBlockedConnections == 0;
}
- (void)beginResume {
    [self.calls addObject:@"beginResume"];
    if (!self.admissionClosed || self.coordinator.state != DSHLifecycleCoordinatorStateResuming)
        self.invariantViolations++;
}
- (void)openAdmission { [self.calls addObject:@"open"]; self.admissionClosed = NO; }
- (void)suspendSockets {
    [self.calls addObject:@"socketSuspend"];
    if (!self.admissionClosed || self.coordinator.state != DSHLifecycleCoordinatorStateQuiesced)
        self.invariantViolations++;
}
- (void)resumeSockets {
    [self.calls addObject:@"socketResume"];
    if (!self.admissionClosed || self.coordinator.state != DSHLifecycleCoordinatorStateResuming)
        self.invariantViolations++;
}
- (void)pauseHarnessSupervision { [self.calls addObject:@"harnessBackground"]; }
- (void)resumeHarnessSupervision {
    [self.calls addObject:@"harnessResume"];
    if (self.admissionClosed) self.invariantViolations++;
}
- (NSDictionary *)diagnosticSnapshot {
    return @{ @"active_operations": @(self.activeOperations), @"active_transactions": @(self.activeTransactions),
              @"native_flock_count": @(self.activeFlocks), @"unsafe": @(self.unsafeObservations),
              @"recovery_blocked_connections": @(self.recoveryBlockedConnections),
              @"admission_closed": @(self.admissionClosed) };
}
- (void)recordLifecycleEvent:(NSString *)event details:(NSDictionary *)details {
    NSMutableDictionary *record = [details mutableCopy];
    record[@"event"] = event;
    record[@"task_begun"] = @([self.calls containsObject:@"taskBegin"]);
    [self.records addObject:record];
}
@end

@interface DSHLifecycleTestTasks : NSObject <DSHLifecycleBackgroundTasks>
@property (nonatomic) NSMutableArray<NSString *> *calls;
@property (nonatomic) NSMutableArray<dispatch_block_t> *expirations;
@property (nonatomic) NSMutableArray<NSNumber *> *ended;
@property (nonatomic) NSUInteger begins;
@property (nonatomic) BOOL deny;
@property (nonatomic) BOOL expireDuringBegin;
@end
@implementation DSHLifecycleTestTasks
- (instancetype)init {
    if ((self = [super init])) { _expirations = [NSMutableArray array]; _ended = [NSMutableArray array]; }
    return self;
}
- (NSUInteger)beginTaskWithName:(NSString *)name expirationHandler:(dispatch_block_t)expiration {
    [self.calls addObject:@"taskBegin"];
    self.begins++;
    [self.expirations addObject:[expiration copy]];
    if (self.expireDuringBegin) expiration();
    return self.deny ? NSUIntegerMax : self.begins;
}
- (void)endTask:(NSUInteger)identifier {
    [self.calls addObject:@"taskEnd"];
    [self.ended addObject:@(identifier)];
}
@end

@interface DSHLifecycleCoordinatorTests : XCTestCase
@property (nonatomic) DSHLifecycleTestDriver *driver;
@property (nonatomic) DSHLifecycleTestTasks *tasks;
@property (nonatomic) DSHLifecycleTestClock *clock;
@property (nonatomic) DSHLifecycleCoordinator *coordinator;
@end

@implementation DSHLifecycleCoordinatorTests
- (void)setUp {
    [super setUp];
    XCTAssertTrue(NSThread.isMainThread);
    self.driver = [DSHLifecycleTestDriver new];
    self.tasks = [DSHLifecycleTestTasks new];
    self.tasks.calls = self.driver.calls;
    self.clock = [DSHLifecycleTestClock new];
    DSHLifecycleTestClock *clock = self.clock;
    self.coordinator = [[DSHLifecycleCoordinator alloc] initWithDriver:self.driver backgroundTasks:self.tasks
                                                           scheduler:^(NSTimeInterval delay, dispatch_block_t action) {
        [clock schedule:delay action:action];
    } clock:^{ return clock.now; }];
    self.driver.coordinator = self.coordinator;
}
- (void)tearDown {
    XCTAssertEqual(self.driver.invariantViolations, 0u);
    self.coordinator = nil;
    [super tearDown];
}
- (NSUInteger)countCall:(NSString *)name {
    return [self.driver.calls filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF == %@", name]].count;
}
- (NSDictionary *)recordNamed:(NSString *)name {
    for (NSDictionary *record in self.driver.records)
        if ([record[@"event"] isEqual:name]) return record;
    return nil;
}

- (void)testForegroundNotificationsBeforeBackgroundHaveNoEffects {
    [self.coordinator handleAppForeground];
    [self.coordinator handleAppResume];
    XCTAssertEqual(self.coordinator.state, DSHLifecycleCoordinatorStateRunning);
    XCTAssertEqual(self.coordinator.generation, 0u);
    XCTAssertEqual(self.driver.calls.count, 0u);
}

- (void)testRequestedDiagnosticIsPersistedAfterTheFiniteTaskHasBegun {
    self.driver.activeOperations = 1;
    [self.coordinator handleAppBackground];
    NSDictionary *requested = [self recordNamed:@"quiesceRequested"];
    XCTAssertEqualObjects(requested[@"task_begun"], @YES,
                          @"persisting a diagnostic must not consume initial runtime before acquiring the finite task");
    XCTAssertTrue(self.driver.admissionClosed);
    XCTAssertEqual(self.tasks.begins, 1u);
    [self.coordinator handleAppForeground];
}

- (void)testSafeBackgroundAndForegroundUseTheClosedGateInOrder {
    [self.coordinator handleAppBackground];
    XCTAssertEqualObjects(self.driver.calls, (@[@"close", @"harnessBackground", @"taskBegin", @"mark", @"socketSuspend", @"taskEnd"]));
    XCTAssertEqual(self.coordinator.state, DSHLifecycleCoordinatorStateQuiesced);
    XCTAssertTrue(self.driver.admissionClosed);
    XCTAssertEqualObjects(self.tasks.ended, (@[@1]));
    XCTAssertNotNil([self recordNamed:@"quiesceComplete"]);

    [self.clock advance:30];
    XCTAssertTrue(self.driver.admissionClosed, @"ending the task never reopens the background gate");
    [self.driver.calls removeAllObjects];
    [self.coordinator handleAppForeground];
    XCTAssertEqualObjects(self.driver.calls, (@[@"beginResume", @"socketResume", @"open", @"harnessResume"]));
    XCTAssertEqual(self.coordinator.state, DSHLifecycleCoordinatorStateRunning);
    XCTAssertFalse(self.driver.admissionClosed);
    XCTAssertEqual(self.tasks.ended.count, 1u);
    XCTAssertEqualWithAccuracy(self.coordinator.lastQuiesceWaitDuration, 0, 0.001,
                              @"time safely quiesced is not time spent waiting for a drain");
}

- (void)testDuplicateBackgroundAndForegroundNotificationsAreIdempotent {
    [self.coordinator handleAppBackground];
    uint64_t generation = self.coordinator.generation;
    [self.coordinator handleAppBackground];
    XCTAssertEqual(self.coordinator.generation, generation);
    XCTAssertEqual(self.tasks.begins, 1u);
    XCTAssertEqual([self countCall:@"socketSuspend"], 1u);
    [self.coordinator handleAppForeground];
    [self.coordinator handleAppForeground];
    [self.coordinator handleAppResume];
    XCTAssertEqual([self countCall:@"beginResume"], 1u);
    XCTAssertEqual([self countCall:@"socketResume"], 1u);
    XCTAssertEqual([self countCall:@"harnessResume"], 1u);
    XCTAssertEqual(self.tasks.ended.count, 1u);
}

- (void)testPendingOperationsDrainAsynchronouslyWithoutBlockingTheMainThread {
    self.driver.activeOperations = 1;
    [self.coordinator handleAppBackground];
    XCTAssertEqual(self.coordinator.state, DSHLifecycleCoordinatorStateQuiescing);
    XCTAssertEqual(self.clock.actions.count, 1u);
    XCTAssertEqual([self countCall:@"socketSuspend"], 0u);
    XCTAssertEqual(self.tasks.ended.count, 0u);
    [self.clock advance:0.1];
    XCTAssertEqual(self.coordinator.state, DSHLifecycleCoordinatorStateQuiescing);
    self.driver.activeOperations = 0;
    [self.clock advance:0.05];
    XCTAssertEqual(self.coordinator.state, DSHLifecycleCoordinatorStateQuiesced);
    XCTAssertEqual([self countCall:@"socketSuspend"], 1u);
    XCTAssertEqual(self.tasks.ended.count, 1u);
    XCTAssertEqualWithAccuracy([[self recordNamed:@"quiesceComplete"][@"wait_ms"] doubleValue], 150, 0.001);
}

- (void)testTransactionsNativeFlocksAndUncertainTrackingEachPreventSafeSuspension {
    self.driver.activeTransactions = 1;
    [self.coordinator handleAppBackground];
    [self.clock advance:0.05];
    XCTAssertEqual([self countCall:@"socketSuspend"], 0u);
    self.driver.activeTransactions = 0;
    self.driver.activeFlocks = 1;
    [self.clock advance:0.05];
    XCTAssertEqual([self countCall:@"socketSuspend"], 0u);
    self.driver.activeFlocks = 0;
    self.driver.unsafeObservations = 1;
    [self.clock advance:0.05];
    XCTAssertEqual([self countCall:@"socketSuspend"], 0u);
    self.driver.unsafeObservations = 0;
    [self.clock advance:0.05];
    XCTAssertEqual([self countCall:@"socketSuspend"], 1u);
}

- (void)testZeroSnapshotCannotOverrideAnAtomicCoreMarkFailure {
    self.driver.atomicMarkFailures = 2;
    [self.coordinator handleAppBackground];
    XCTAssertEqual(self.driver.activeOperations, 0u);
    XCTAssertEqual(self.coordinator.state, DSHLifecycleCoordinatorStateQuiescing);
    [self.clock advance:0.05];
    XCTAssertEqual([self countCall:@"socketSuspend"], 0u);
    [self.clock advance:0.05];
    XCTAssertEqual([self countCall:@"socketSuspend"], 1u);
    XCTAssertEqual(self.driver.markAttempts, 3u);
}

- (void)testRecoveryBlockedConnectionPreventsQuiescenceEvenWithNoActiveTransaction {
    self.driver.recoveryBlockedConnections = 1;
    [self.coordinator handleAppBackground];
    [self.clock advance:1];
    XCTAssertEqual(self.driver.activeTransactions, 0u);
    XCTAssertEqual(self.coordinator.state, DSHLifecycleCoordinatorStateQuiescing);
    XCTAssertEqual([self countCall:@"socketSuspend"], 0u);
    self.driver.recoveryBlockedConnections = 0;
    [self.clock advance:0.05];
    XCTAssertEqual(self.coordinator.state, DSHLifecycleCoordinatorStateQuiesced);
}

- (void)testWaitingDiagnosticsPersistFreshOwnersAtMostOncePerSecond {
    self.driver.activeTransactions = 1;
    [self.coordinator handleAppBackground];
    XCTAssertEqual(self.driver.records.count, 1u); // initial boundary
    [self.clock advance:0.99];
    XCTAssertNil([self recordNamed:@"quiesceWaiting"]);
    [self.clock advance:0.07];
    NSDictionary *first = [self recordNamed:@"quiesceWaiting"];
    XCTAssertNotNil(first);
    XCTAssertGreaterThanOrEqual([first[@"wait_ms"] doubleValue], 1000);
    XCTAssertEqualObjects(first[@"snapshot"][@"active_transactions"], @1);
    NSUInteger records = self.driver.records.count;
    self.driver.activeTransactions = 0;
    self.driver.activeFlocks = 2;
    [self.clock advance:0.98];
    XCTAssertEqual(self.driver.records.count, records);
    [self.clock advance:0.08];
    XCTAssertEqual(self.driver.records.count, records + 1);
    NSDictionary *latest = self.driver.records.lastObject;
    XCTAssertEqualObjects(latest[@"event"], @"quiesceWaiting");
    XCTAssertEqualObjects(latest[@"snapshot"][@"active_transactions"], @0);
    XCTAssertEqualObjects(latest[@"snapshot"][@"native_flock_count"], @2);
    [self.coordinator handleAppForeground];
}

- (void)testExpiryLogsWaitAndCachedSnapshotWithoutForcingCleanupOrOpeningTheGate {
    self.driver.activeTransactions = 1;
    self.driver.activeFlocks = 1;
    [self.coordinator handleAppBackground];
    [self.clock advance:0.2];
    self.tasks.expirations[0]();
    XCTAssertEqual(self.coordinator.state, DSHLifecycleCoordinatorStateQuiescing);
    XCTAssertTrue(self.driver.admissionClosed);
    XCTAssertEqual(self.tasks.ended.count, 1u);
    XCTAssertEqual([self countCall:@"socketSuspend"], 0u);
    XCTAssertEqual([self countCall:@"open"], 0u);
    XCTAssertEqual([self countCall:@"harnessResume"], 0u);
    NSDictionary *record = [self recordNamed:@"quiesceExpired"];
    XCTAssertEqualWithAccuracy([record[@"wait_ms"] doubleValue], 200, 0.001);
    XCTAssertEqualObjects(record[@"snapshot"][@"active_transactions"], @1);
    XCTAssertEqualObjects(record[@"snapshot"][@"native_flock_count"], @1);
    NSUInteger attempts = self.driver.markAttempts;
    self.driver.activeTransactions = self.driver.activeFlocks = 0;
    [self.clock advance:10];
    self.tasks.expirations[0]();
    XCTAssertEqual(self.driver.markAttempts, attempts);
    XCTAssertEqual(self.tasks.ended.count, 1u);
}

- (void)testForegroundDuringDrainInvalidatesThePollAndDoesNotRepairUncapturedSockets {
    self.driver.activeOperations = 1;
    [self.coordinator handleAppBackground];
    [self.driver.calls removeAllObjects];
    [self.coordinator handleAppForeground];
    XCTAssertEqualObjects(self.driver.calls, (@[@"beginResume", @"taskEnd", @"open", @"harnessResume"]));
    NSUInteger attempts = self.driver.markAttempts;
    self.driver.activeOperations = 0;
    [self.clock advance:1];
    self.tasks.expirations[0]();
    XCTAssertEqual(self.driver.markAttempts, attempts);
    XCTAssertEqual([self countCall:@"socketSuspend"], 0u);
    XCTAssertEqual(self.coordinator.state, DSHLifecycleCoordinatorStateRunning);
}

- (void)testOldPollAndExpiryCannotEndOrSuspendANewerBackgroundCycle {
    self.driver.activeOperations = 1;
    [self.coordinator handleAppBackground];
    uint64_t oldGeneration = self.coordinator.generation;
    [self.coordinator handleAppForeground];
    [self.coordinator handleAppBackground];
    XCTAssertGreaterThan(self.coordinator.generation, oldGeneration);
    XCTAssertEqual(self.tasks.begins, 2u);
    XCTAssertEqualObjects(self.tasks.ended, (@[@1]));
    self.tasks.expirations[0]();
    [self.clock advance:0.05];
    XCTAssertEqualObjects(self.tasks.ended, (@[@1]));
    XCTAssertEqual([self countCall:@"socketSuspend"], 0u);
    self.driver.activeOperations = 0;
    [self.clock advance:0.05];
    XCTAssertEqualObjects(self.tasks.ended, (@[@1, @2]));
    XCTAssertEqual([self countCall:@"socketSuspend"], 1u);
    XCTAssertEqual(self.driver.markAttempts, 4u); // one per cycle + only the new polls
}

- (void)testDeniedTaskStillClosesAdmissionAndAttemptsOnlyOneDrain {
    self.tasks.deny = YES;
    self.driver.activeOperations = 1;
    [self.coordinator handleAppBackground];
    [self.coordinator handleAppBackground];
    XCTAssertTrue(self.driver.admissionClosed);
    XCTAssertEqual(self.driver.markAttempts, 1u);
    XCTAssertEqual(self.clock.actions.count, 0u);
    XCTAssertEqual(self.tasks.begins, 1u);
    XCTAssertEqual(self.tasks.ended.count, 0u);
    XCTAssertNotNil([self recordNamed:@"quiesceTaskDenied"]);
    XCTAssertEqualObjects([self recordNamed:@"quiesceTaskDenied"][@"snapshot"][@"active_operations"], @1);
    XCTAssertEqualObjects([self recordNamed:@"quiesceTaskDenied"][@"snapshot"][@"admission_closed"], @YES);
    self.driver.activeOperations = 0;
    [self.clock advance:1];
    XCTAssertEqual(self.driver.markAttempts, 1u);
    [self.coordinator handleAppForeground];
    XCTAssertEqual([self countCall:@"harnessResume"], 1u);
    XCTAssertEqual(self.tasks.ended.count, 0u);
}

- (void)testDeniedTaskCanFinishAnAlreadySafeDrainWithoutEndingAnInvalidIdentifier {
    self.tasks.deny = YES;
    [self.coordinator handleAppBackground];
    XCTAssertEqual(self.coordinator.state, DSHLifecycleCoordinatorStateQuiesced);
    XCTAssertEqual([self countCall:@"socketSuspend"], 1u);
    XCTAssertEqual(self.tasks.ended.count, 0u);
    XCTAssertEqual(self.clock.actions.count, 0u);
    [self.coordinator handleAppForeground];
    XCTAssertEqual([self countCall:@"socketResume"], 1u);
}

- (void)testSynchronousExpiryBeforeTaskIdentifierReturnsEndsTheCorrectTaskExactlyOnce {
    self.tasks.expireDuringBegin = YES;
    self.driver.activeOperations = 1;
    [self.coordinator handleAppBackground];
    XCTAssertEqualObjects(self.tasks.ended, (@[@1]));
    XCTAssertEqual(self.driver.markAttempts, 0u);
    XCTAssertEqual(self.clock.actions.count, 0u);
    XCTAssertTrue(self.driver.admissionClosed);
    XCTAssertNotNil([self recordNamed:@"quiesceExpired"]);
    [self.coordinator handleAppForeground];
    self.tasks.expirations[0]();
    XCTAssertEqualObjects(self.tasks.ended, (@[@1]));
}

- (void)testExpiredCycleCanResumeAndASecondCycleGetsOneFreshFiniteTask {
    self.driver.activeOperations = 1;
    [self.coordinator handleAppBackground];
    self.tasks.expirations[0]();
    [self.coordinator handleAppForeground];
    self.driver.activeOperations = 0;
    [self.coordinator handleAppBackground];
    [self.coordinator handleAppBackground];
    XCTAssertEqual(self.tasks.begins, 2u);
    XCTAssertEqualObjects(self.tasks.ended, (@[@1, @2]));
    XCTAssertEqual(self.coordinator.state, DSHLifecycleCoordinatorStateQuiesced);
    XCTAssertEqual([self countCall:@"harnessBackground"], 2u);
    XCTAssertEqual([self countCall:@"harnessResume"], 1u);
}

- (void)testResumeFallbackAfterExpiryRestoresOnceWhenWillEnterForegroundWasMissed {
    self.driver.activeTransactions = 1;
    [self.coordinator handleAppBackground];
    self.tasks.expirations[0]();
    [self.driver.calls removeAllObjects];
    [self.coordinator handleAppResume];
    [self.coordinator handleAppResume];
    [self.coordinator handleAppForeground];
    XCTAssertEqualObjects(self.driver.calls, (@[@"beginResume", @"open", @"harnessResume"]));
    XCTAssertEqual(self.coordinator.state, DSHLifecycleCoordinatorStateRunning);
    XCTAssertEqualObjects(self.tasks.ended, (@[@1]));
    [self.clock advance:1];
    XCTAssertEqual([self countCall:@"socketSuspend"], 0u);
}

- (void)testNativeWorkRunsSynchronouslyWhenAlreadyRunning {
    __block NSUInteger runs = 0;
    [self.coordinator performWhenRunning:^{
        XCTAssertTrue(NSThread.isMainThread);
        XCTAssertFalse(self.driver.admissionClosed);
        runs++;
    }];
    XCTAssertEqual(runs, 1u);
    XCTAssertEqual(self.tasks.begins, 0u);
}

- (void)testNativeWorkWaitsForAnOpenedGateAndRunsOnceAfterSupervisionResumes {
    [self.coordinator handleAppBackground];
    __block NSUInteger runs = 0;
    [self.coordinator performWhenRunning:^{
        XCTAssertFalse(self.driver.admissionClosed);
        XCTAssertEqualObjects(self.driver.calls.lastObject, @"harnessResume");
        [self.driver.calls addObject:@"nativeJob"];
        runs++;
    }];
    [self.clock advance:10];
    XCTAssertEqual(runs, 0u);
    [self.coordinator handleAppForeground];
    XCTAssertEqual(runs, 1u);
    [self.coordinator handleAppResume];
    [self.coordinator handleAppForeground];
    XCTAssertEqual(runs, 1u);
    XCTAssertEqual([self countCall:@"nativeJob"], 1u);
}

- (void)testNativeWorkReenteringBackgroundDefersItsRemainingPeers {
    [self.coordinator handleAppBackground];
    NSMutableArray<NSNumber *> *ran = [NSMutableArray array];
    __weak DSHLifecycleCoordinator *coordinator = self.coordinator;
    [self.coordinator performWhenRunning:^{
        [ran addObject:@1];
        [coordinator handleAppBackground];
    }];
    [self.coordinator performWhenRunning:^{ [ran addObject:@2]; }];
    [self.coordinator performWhenRunning:^{ [ran addObject:@3]; }];
    [self.coordinator handleAppForeground];
    XCTAssertEqualObjects(ran, (@[@1]));
    XCTAssertTrue(self.driver.admissionClosed);
    XCTAssertEqual(self.coordinator.state, DSHLifecycleCoordinatorStateQuiesced);
    XCTAssertEqual(self.tasks.begins, 2u);
    [self.clock advance:1];
    XCTAssertEqualObjects(ran, (@[@1]));
    [self.coordinator handleAppForeground];
    [self.coordinator handleAppResume];
    XCTAssertEqualObjects(ran, (@[@1, @2, @3]));
    XCTAssertEqual([self countCall:@"harnessResume"], 2u);
}

@end
