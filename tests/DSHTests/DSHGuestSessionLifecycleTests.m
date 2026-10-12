#import <XCTest/XCTest.h>
#import "DSHGuestSessionLifecycle.h"
#import "DSHHostBridge.h"
#import "DSHHarness.h"
#import "DSHLogBuffer.h"

// Protocol tests call the actual route handlers. Authentication is tested
// separately through a real, private loopback bridge below.
@interface DSHGuestSessionLifecycle (ProtocolTests)
- (DSHHostBridgeResponse *)poll:(DSHHostBridgeRequest *)request;
- (DSHHostBridgeResponse *)acknowledge:(DSHHostBridgeRequest *)request;
@end

@interface DSHSessionRequestFixture : DSHHostBridgeRequest
@property (nonatomic, copy) NSDictionary *fixtureJSON;
@end
@implementation DSHSessionRequestFixture
- (NSDictionary *)json { return self.fixtureJSON; }
@end

@interface DSHSessionMainQueueFixture : NSObject
@property (nonatomic) NSLock *lock;
@property (nonatomic) NSMutableArray *actions;
- (void)enqueue:(dispatch_block_t)action;
- (void)drain;
@end
@implementation DSHSessionMainQueueFixture
- (instancetype)init {
    if ((self = [super init])) { _lock = [NSLock new]; _actions = [NSMutableArray new]; }
    return self;
}
- (void)enqueue:(dispatch_block_t)action {
    [self.lock lock]; [self.actions addObject:[action copy]]; [self.lock unlock];
}
- (void)drain {
    dispatch_block_t drain = ^{
        [self.lock lock]; NSArray *actions = [self.actions copy]; [self.actions removeAllObjects]; [self.lock unlock];
        for (dispatch_block_t action in actions) action();
    };
    if (NSThread.isMainThread) drain(); else dispatch_sync(dispatch_get_main_queue(), drain);
}
@end

// Pause an old request after NSCondition wakes but before its handler can
// finish. This deterministically lets a new guest own a different poll.
@interface DSHSessionDelayedWakeCondition : NSCondition
@property (nonatomic) BOOL delayNextWake; // Accessed while the condition is locked.
@property (nonatomic) dispatch_semaphore_t delayed;
@property (nonatomic) dispatch_semaphore_t releaseWake;
@end
@implementation DSHSessionDelayedWakeCondition
- (instancetype)init {
    if ((self = [super init])) {
        _delayed = dispatch_semaphore_create(0); _releaseWake = dispatch_semaphore_create(0);
    }
    return self;
}
- (BOOL)waitUntilDate:(NSDate *)date {
    BOOL signalled = [super waitUntilDate:date];
    if (self.delayNextWake) {
        self.delayNextWake = NO;
        [super unlock];
        dispatch_semaphore_signal(self.delayed);
        dispatch_semaphore_wait(self.releaseWake, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
        [super lock];
    }
    return signalled;
}
@end

@interface DSHGuestSessionLifecycleTests : XCTestCase
@property (nonatomic) DSHGuestSessionLifecycle *manager;
@property (nonatomic) DSHSessionMainQueueFixture *mainQueue;
@property (nonatomic) DSHHostBridge *bridge;
@end

@implementation DSHGuestSessionLifecycleTests
- (void)setUp {
    [super setUp];
    self.mainQueue = [DSHSessionMainQueueFixture new];
    [self useCondition:[NSCondition new]];
}
- (void)tearDown {
    [self.bridge stop];
    [self.manager cancelPendingTransition];
    [self.mainQueue drain];
    [super tearDown];
}
- (void)useCondition:(NSCondition *)condition {
    DSHSessionMainQueueFixture *queue = self.mainQueue;
    self.manager = [[DSHGuestSessionLifecycle alloc] initWithMainScheduler:^(dispatch_block_t action) {
        [queue enqueue:action];
    } condition:condition];
}
- (DSHHostBridgeRequest *)request:(NSDictionary *)body {
    DSHSessionRequestFixture *request = [DSHSessionRequestFixture new];
    request.fixtureJSON = body; return request;
}
- (DSHHostBridgeResponse *)pollPID:(int)pid after:(int64_t)generation wait:(NSInteger)wait {
    return [self.manager poll:[self request:@{@"pid": @(pid), @"after_generation": @(generation), @"wait_ms": @(wait)}]];
}
- (uint64_t)generation { return [self.manager.diagnosticSnapshot[@"generation"] unsignedLongLongValue]; }
- (void)exitPID:(int)pid {
    uint64_t identity = [self.manager.diagnosticSnapshot[@"guest_identity"] unsignedLongLongValue];
    [self.manager managedGuestDidExit:pid identity:identity];
}
- (void)registerPID:(int)pid {
    [self.manager managedGuestDidLaunch:pid];
    XCTAssertEqual([self pollPID:pid after:-1 wait:0].status, 200);
    XCTAssertTrue(self.manager.registered);
}
- (NSMutableDictionary *)ackPID:(int)pid generation:(uint64_t)generation state:(NSString *)state {
    return [@{@"pid": @(pid), @"generation": @(generation), @"state": state,
        @"writer_count": @2, @"released_count": [state isEqual:@"quiesced"] ? @2 : @0, @"pending_events": @3} mutableCopy];
}
- (DSHHostBridgeResponse *)sendACK:(NSDictionary *)body {
    return [self.manager acknowledge:[self request:body]];
}
- (void)waitForPoll {
    XCTNSPredicateExpectation *pending = [[XCTNSPredicateExpectation alloc]
        initWithPredicate:[NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary *bindings) {
            return [((DSHGuestSessionLifecycle *)object).diagnosticSnapshot[@"poll_pending"] boolValue];
        }] object:self.manager];
    [self waitForExpectations:@[pending] timeout:3];
}
- (NSDictionary *)post:(NSString *)path token:(NSString *)token body:(NSDictionary *)body status:(NSInteger *)statusOut {
    NSURL *url = [NSURL URLWithString:[self.bridge.baseURLString stringByAppendingString:path]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST"; request.timeoutInterval = 5;
    if (token) [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    XCTestExpectation *done = [self expectationWithDescription:@"authenticated lifecycle HTTP"];
    __block NSInteger status = 0; __block NSDictionary *answer = nil;
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        status = ((NSHTTPURLResponse *)response).statusCode;
        if (data) answer = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        [done fulfill];
    }] resume];
    [self waitForExpectations:@[done] timeout:8];
    if (statusOut) *statusOut = status;
    return answer;
}

- (void)testBridgeRejectsMissingAndWrongTokenBeforeEitherHandler {
    self.bridge = [DSHHostBridge new];
    [self.manager installOnBridge:self.bridge];
    XCTAssertTrue([self.bridge start]);
    [self.manager managedGuestDidLaunch:101];
    NSDictionary *before = self.manager.diagnosticSnapshot;
    NSInteger status;
    for (NSString *path in @[@"/v1/lifecycle/poll", @"/v1/lifecycle/ack"]) {
        [self post:path token:nil body:@{@"pid": @101, @"wait_ms": @0} status:&status];
        XCTAssertEqual(status, 401);
        [self post:path token:@"wrong-lifecycle-token" body:@{@"pid": @101, @"wait_ms": @0} status:&status];
        XCTAssertEqual(status, 401);
    }
    XCTAssertEqualObjects(self.manager.diagnosticSnapshot, before);
    [self post:@"/v1/lifecycle/poll" token:self.bridge.token body:@{@"pid": @102, @"wait_ms": @0} status:&status];
    XCTAssertEqual(status, 409); XCTAssertFalse(self.manager.registered);
    [self post:@"/v1/lifecycle/poll" token:self.bridge.token body:@{@"pid": @101, @"wait_ms": @0} status:&status];
    XCTAssertEqual(status, 200); XCTAssertTrue(self.manager.registered);
}

- (void)testUnknownPIDAndUnregisteredACKCannotResolveTransition {
    [self.manager managedGuestDidLaunch:101];
    __block NSUInteger callbacks = 0;
    [self.manager prepareForBackgroundWithCompletion:^(BOOL success) { callbacks++; }];
    XCTAssertEqual([self pollPID:102 after:-1 wait:0].status, 409);
    XCTAssertEqual([self sendACK:[self ackPID:101 generation:self.generation state:@"quiesced"]].status, 409);
    XCTAssertEqual([self pollPID:101 after:-1 wait:0].status, 200);
    XCTAssertEqual([self sendACK:[self ackPID:102 generation:self.generation state:@"quiesced"]].status, 409);
    [self.mainQueue drain]; XCTAssertEqual(callbacks, 0u); XCTAssertTrue(self.manager.transitionPending);
}

- (void)testStaleACKAndCancelCannotCompleteNewTransition {
    [self registerPID:101];
    __block NSUInteger obsolete = 0, current = 0;
    [self.manager prepareForBackgroundWithCompletion:^(BOOL success) { obsolete++; }];
    uint64_t oldGeneration = self.generation;
    [self.manager cancelPendingTransition];
    XCTAssertEqualObjects(self.manager.diagnosticSnapshot[@"desired_state"], @"quiescing");
    [self.manager resumeWithCompletion:^(BOOL success) { XCTAssertTrue(success); current++; }];
    XCTAssertGreaterThan(self.generation, oldGeneration);
    XCTAssertEqual([self sendACK:[self ackPID:101 generation:oldGeneration state:@"quiesced"]].status, 409);
    XCTAssertEqual([self sendACK:[self ackPID:101 generation:self.generation state:@"running"]].status, 200);
    [self.mainQueue drain]; XCTAssertEqual(obsolete, 0u); XCTAssertEqual(current, 1u);
}

- (void)testNewTransitionInvalidatesACKAlreadyQueuedToMain {
    [self registerPID:101];
    __block NSUInteger obsolete = 0, current = 0;
    [self.manager prepareForBackgroundWithCompletion:^(BOOL success) { obsolete++; }];
    XCTAssertEqual([self sendACK:[self ackPID:101 generation:self.generation state:@"quiesced"]].status, 200);
    XCTAssertEqual(obsolete, 0u);
    [self.manager resumeWithCompletion:^(BOOL success) { XCTAssertTrue(NSThread.isMainThread); XCTAssertTrue(success); current++; }];
    [self.mainQueue drain]; XCTAssertEqual(obsolete, 0u); XCTAssertTrue(self.manager.transitionPending);
    XCTAssertEqual([self sendACK:[self ackPID:101 generation:self.generation state:@"running"]].status, 200);
    [self.mainQueue drain]; XCTAssertEqual(current, 1u); XCTAssertFalse(self.manager.transitionPending);
}

- (void)testCancelInvalidatesACKAlreadyQueuedToMain {
    [self registerPID:101];
    __block NSUInteger callbacks = 0;
    [self.manager prepareForBackgroundWithCompletion:^(BOOL success) { callbacks++; }];
    XCTAssertEqual([self sendACK:[self ackPID:101 generation:self.generation state:@"quiesced"]].status, 200);
    [self.manager cancelPendingTransition];
    [self.mainQueue drain]; XCTAssertEqual(callbacks, 0u); XCTAssertFalse(self.manager.transitionPending);
}

- (void)testSameNumericPIDRelaunchInvalidatesACKAndQueuedCompletion {
    [self registerPID:101];
    __block NSUInteger callbacks = 0;
    [self.manager prepareForBackgroundWithCompletion:^(BOOL success) { callbacks++; }];
    uint64_t oldGeneration = self.generation;
    NSNumber *identity = self.manager.diagnosticSnapshot[@"guest_identity"];
    XCTAssertEqual([self sendACK:[self ackPID:101 generation:oldGeneration state:@"quiesced"]].status, 200);
    [self.manager managedGuestDidLaunch:101];
    XCTAssertNotEqualObjects(self.manager.diagnosticSnapshot[@"guest_identity"], identity);
    XCTAssertFalse(self.manager.registered);
    XCTAssertEqual([self pollPID:101 after:-1 wait:0].status, 200);
    XCTAssertEqual([self sendACK:[self ackPID:101 generation:oldGeneration state:@"quiesced"]].status, 409);
    [self.mainQueue drain]; XCTAssertEqual(callbacks, 0u);
}

- (void)testFirstACKIsFinalAndOnlyExactMetadataDuplicateIsAccepted {
    [self registerPID:101];
    __block NSUInteger callbacks = 0;
    [self.manager prepareForBackgroundWithCompletion:^(BOOL success) { XCTAssertTrue(success); callbacks++; }];
    NSMutableDictionary *ack = [self ackPID:101 generation:self.generation state:@"quiesced"];
    XCTAssertEqual([self sendACK:ack].status, 200);
    NSDictionary *accepted = self.manager.diagnosticSnapshot;
    XCTAssertEqual([self sendACK:ack].status, 200);
    NSMutableDictionary *changed = [ack mutableCopy]; changed[@"pending_events"] = @4;
    XCTAssertEqual([self sendACK:changed].status, 409);
    changed = [ack mutableCopy]; changed[@"state"] = @"failed"; changed[@"error_code"] = @"close_failure";
    XCTAssertEqual([self sendACK:changed].status, 409);
    XCTAssertEqualObjects(self.manager.diagnosticSnapshot, accepted);
    [self.mainQueue drain]; XCTAssertEqual(callbacks, 1u);
    XCTAssertEqual([self sendACK:ack].status, 200);
    [self.mainQueue drain]; XCTAssertEqual(callbacks, 1u);
}

- (void)testFailedACKCannotBeReplacedBySuccessInSameGeneration {
    [self registerPID:101];
    __block NSUInteger callbacks = 0;
    [self.manager prepareForBackgroundWithCompletion:^(BOOL success) { XCTAssertFalse(success); callbacks++; }];
    NSMutableDictionary *failed = [self ackPID:101 generation:self.generation state:@"failed"];
    failed[@"error_code"] = @"storage_failure";
    XCTAssertEqual([self sendACK:failed].status, 200);
    XCTAssertEqual([self sendACK:failed].status, 200);
    XCTAssertEqual([self sendACK:[self ackPID:101 generation:self.generation state:@"quiesced"]].status, 409);
    [self.mainQueue drain]; XCTAssertEqual(callbacks, 1u);
    XCTAssertEqualObjects(self.manager.diagnosticSnapshot[@"error_code"], @"storage_failure");
}

- (void)testACKRequiresSafeIntegerCountsAndCompleteLeaseRelease {
    [self registerPID:101];
    [self.manager prepareForBackgroundWithCompletion:^(BOOL success) {}];
    NSDictionary *before = self.manager.diagnosticSnapshot;
    for (NSString *key in @[@"writer_count", @"released_count", @"pending_events"]) {
        NSMutableDictionary *missing = [self ackPID:101 generation:self.generation state:@"quiesced"];
        [missing removeObjectForKey:key]; XCTAssertEqual([self sendACK:missing].status, 400);
        for (id invalid in @[@YES, @-1, @0.5, @9007199254740992LL, @"2", NSNull.null]) {
            NSMutableDictionary *ack = [self ackPID:101 generation:self.generation state:@"quiesced"];
            ack[key] = invalid; XCTAssertEqual([self sendACK:ack].status, 400);
        }
    }
    NSMutableDictionary *partial = [self ackPID:101 generation:self.generation state:@"quiesced"];
    partial[@"released_count"] = @1; XCTAssertEqual([self sendACK:partial].status, 400);
    partial[@"released_count"] = @3; XCTAssertEqual([self sendACK:partial].status, 400);
    XCTAssertEqualObjects(self.manager.diagnosticSnapshot, before);
    NSMutableDictionary *valid = [self ackPID:101 generation:self.generation state:@"quiesced"];
    valid[@"pending_events"] = @9007199254740991LL;
    XCTAssertEqual([self sendACK:valid].status, 200, @"paused in-memory events need not be zero");
}

- (void)testPollAndACKRejectBooleanOrFractionalIdentity {
    [self registerPID:101];
    for (id invalid in @[@YES, @0.5, @"101", NSNull.null]) {
        NSDictionary *poll = @{@"pid": invalid, @"wait_ms": @0};
        XCTAssertEqual([self.manager poll:[self request:poll]].status, 400);
        NSMutableDictionary *ack = [self ackPID:101 generation:self.generation state:@"running"];
        ack[@"pid"] = invalid; XCTAssertEqual([self sendACK:ack].status, 400);
        ack = [self ackPID:101 generation:self.generation state:@"running"];
        ack[@"generation"] = invalid; XCTAssertEqual([self sendACK:ack].status, 400);
    }
    XCTAssertEqual([self pollPID:101 after:self.generation + 1 wait:0].status, 409);
    XCTAssertEqual([self pollPID:101 after:-2 wait:0].status, 400);
    XCTAssertEqual([self pollPID:101 after:-1 wait:-1].status, 400);
    XCTAssertEqual([self pollPID:101 after:-1 wait:15001].status, 400);
}

- (void)testTransitionWakesLongPollAndConcurrentPollIsRejected {
    [self registerPID:101];
    int64_t generation = self.generation;
    XCTestExpectation *done = [self expectationWithDescription:@"long poll wakes"];
    __block DSHHostBridgeResponse *answer;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        answer = [self pollPID:101 after:generation wait:15000]; [done fulfill];
    });
    [self waitForPoll];
    XCTAssertEqual([self pollPID:101 after:generation wait:0].status, 429);
    [self.manager prepareForBackgroundWithCompletion:^(BOOL success) {}];
    [self waitForExpectations:@[done] timeout:3];
    XCTAssertEqual(answer.status, 200); XCTAssertEqualObjects(answer.body[@"state"], @"quiescing");
    XCTAssertEqualObjects(answer.body[@"generation"], @(self.generation));
    XCTAssertFalse([self.manager.diagnosticSnapshot[@"poll_pending"] boolValue]);
}

- (void)testCancellationWakesPollAndRetainsDesiredPause {
    [self registerPID:101];
    __block NSUInteger callbacks = 0;
    [self.manager prepareForBackgroundWithCompletion:^(BOOL success) { callbacks++; }];
    int64_t generation = self.generation;
    XCTestExpectation *done = [self expectationWithDescription:@"cancel wakes poll"];
    __block DSHHostBridgeResponse *answer;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        answer = [self pollPID:101 after:generation wait:15000]; [done fulfill];
    });
    [self waitForPoll];
    [self.manager cancelPendingTransition];
    [self waitForExpectations:@[done] timeout:3];
    XCTAssertEqual(answer.status, 200); XCTAssertEqualObjects(answer.body[@"state"], @"quiescing");
    XCTAssertGreaterThan([answer.body[@"generation"] longLongValue], generation);
    [self.mainQueue drain]; XCTAssertEqual(callbacks, 0u);
}

- (void)testOldGuestPollCannotClearNewGuestsOutstandingPoll {
    DSHSessionDelayedWakeCondition *condition = [DSHSessionDelayedWakeCondition new];
    [self useCondition:condition]; [self registerPID:101];
    int64_t oldGeneration = self.generation;
    XCTestExpectation *oldDone = [self expectationWithDescription:@"old poll retires"];
    __block DSHHostBridgeResponse *oldAnswer;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        oldAnswer = [self pollPID:101 after:oldGeneration wait:15000]; [oldDone fulfill];
    });
    [self waitForPoll];
    [condition lock]; condition.delayNextWake = YES; [condition unlock];
    [self.manager managedGuestDidLaunch:202];
    long delayed = dispatch_semaphore_wait(condition.delayed, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
    XCTAssertEqual(delayed, 0L);
    XCTAssertEqual([self pollPID:202 after:-1 wait:0].status, 200);
    int64_t newGeneration = self.generation;
    XCTestExpectation *newDone = [self expectationWithDescription:@"new poll remains owned"];
    __block DSHHostBridgeResponse *newAnswer;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        newAnswer = [self pollPID:202 after:newGeneration wait:15000]; [newDone fulfill];
    });
    [self waitForPoll];
    dispatch_semaphore_signal(condition.releaseWake);
    [self waitForExpectations:@[oldDone] timeout:3];
    XCTAssertEqual(oldAnswer.status, 409);
    XCTAssertTrue([self.manager.diagnosticSnapshot[@"poll_pending"] boolValue]);
    XCTAssertEqual([self pollPID:202 after:newGeneration wait:0].status, 429);
    [self.manager resumeWithCompletion:^(BOOL success) {}];
    [self waitForExpectations:@[newDone] timeout:3];
    XCTAssertEqual(newAnswer.status, 200);
}

- (void)testActualManagedExitCompletesPendingTransitionOnce {
    [self registerPID:101];
    __block NSUInteger callbacks = 0;
    [self.manager prepareForBackgroundWithCompletion:^(BOOL success) {
        XCTAssertTrue(NSThread.isMainThread); XCTAssertTrue(success); callbacks++;
    }];
    [self exitPID:102]; [self.mainQueue drain]; XCTAssertEqual(callbacks, 0u);
    [self exitPID:101]; [self exitPID:101];
    [self.mainQueue drain]; XCTAssertEqual(callbacks, 1u); XCTAssertFalse(self.manager.registered);
    XCTAssertEqualObjects(self.manager.diagnosticSnapshot[@"managed_guest_pid"], @0);
}

- (void)testNewGuestInvalidatesAlreadyQueuedExitCompletion {
    [self registerPID:101];
    __block NSUInteger callbacks = 0;
    [self.manager prepareForBackgroundWithCompletion:^(BOOL success) { callbacks++; }];
    [self exitPID:101];
    [self.manager managedGuestDidLaunch:202];
    [self.mainQueue drain]; XCTAssertEqual(callbacks, 0u);
    XCTAssertEqualObjects(self.manager.diagnosticSnapshot[@"managed_guest_pid"], @202);
}

- (void)testOldExitForReusedPIDCannotRetireNewGuestOrCompleteItsTransition {
    uint64_t oldIdentity = [self.manager managedGuestDidLaunch:101];
    uint64_t newIdentity = [self.manager managedGuestDidLaunch:101];
    XCTAssertGreaterThan(newIdentity, oldIdentity);
    XCTAssertEqual([self pollPID:101 after:-1 wait:0].status, 200);
    __block NSUInteger callbacks = 0;
    [self.manager prepareForBackgroundWithCompletion:^(BOOL success) { XCTAssertTrue(success); callbacks++; }];
    NSDictionary *before = self.manager.diagnosticSnapshot;
    [self.manager managedGuestDidExit:101 identity:oldIdentity];
    [self.mainQueue drain];
    XCTAssertEqualObjects(self.manager.diagnosticSnapshot, before);
    XCTAssertEqual(callbacks, 0u); XCTAssertTrue(self.manager.transitionPending);
    [self.manager managedGuestDidExit:101 identity:newIdentity];
    [self.mainQueue drain];
    XCTAssertEqual(callbacks, 1u); XCTAssertFalse(self.manager.transitionPending);
    XCTAssertEqualObjects(self.manager.diagnosticSnapshot[@"managed_guest_pid"], @0);
}

- (void)testExitReplacesQueuedFailedACKWithOneSafeCompletion {
    [self registerPID:101];
    __block NSUInteger callbacks = 0;
    [self.manager prepareForBackgroundWithCompletion:^(BOOL success) { XCTAssertTrue(success); callbacks++; }];
    NSMutableDictionary *ack = [self ackPID:101 generation:self.generation state:@"failed"];
    ack[@"error_code"] = @"close_failure";
    XCTAssertEqual([self sendACK:ack].status, 200);
    [self exitPID:101];
    [self.mainQueue drain]; XCTAssertEqual(callbacks, 1u);
}

- (void)testAbsentGuestCompletionIsInvalidatedByLaunchBeforeDelivery {
    __block NSUInteger callbacks = 0;
    [self.manager prepareForBackgroundWithCompletion:^(BOOL success) { callbacks++; }];
    [self.manager managedGuestDidLaunch:101];
    [self.mainQueue drain]; XCTAssertEqual(callbacks, 0u);
    [self exitPID:101];
    [self.manager resumeWithCompletion:^(BOOL success) { XCTAssertTrue(success); callbacks++; }];
    [self.mainQueue drain]; XCTAssertEqual(callbacks, 1u);
}

- (void)testDefaultSchedulerDeliversAbsentGuestCompletionOnMain {
    DSHGuestSessionLifecycle *manager = [DSHGuestSessionLifecycle new];
    XCTestExpectation *done = [self expectationWithDescription:@"production main scheduler"];
    [manager resumeWithCompletion:^(BOOL success) {
        XCTAssertTrue(NSThread.isMainThread); XCTAssertTrue(success); [done fulfill];
    }];
    [self waitForExpectations:@[done] timeout:3];
    XCTAssertFalse(manager.transitionPending);
}

- (void)testGuestErrorEnumIsPreservedAndUntrustedDetailsAreNotLogged {
    [self registerPID:101];
    for (NSString *code in @[@"checkpoint_changed", @"not_materialized", @"ownership_conflict", @"storage_failure", @"close_failure", @"transition_failed"]) {
        __block NSUInteger callbacks = 0;
        [self.manager prepareForBackgroundWithCompletion:^(BOOL success) { XCTAssertFalse(success); callbacks++; }];
        NSMutableDictionary *ack = [self ackPID:101 generation:self.generation state:@"failed"];
        ack[@"error_code"] = code;
        XCTAssertEqual([self sendACK:ack].status, 200);
        XCTAssertEqualObjects(self.manager.diagnosticSnapshot[@"error_code"], code);
        [self.mainQueue drain]; XCTAssertEqual(callbacks, 1u);
    }
    self.bridge = [DSHHostBridge new]; [self.manager installOnBridge:self.bridge];
    XCTAssertTrue([self.bridge start]);
    [self.manager prepareForBackgroundWithCompletion:^(BOOL success) { XCTAssertFalse(success); }];
    NSString *secret = [@"private-api-key-session-path-" stringByAppendingString:NSUUID.UUID.UUIDString];
    NSMutableDictionary *ack = [self ackPID:101 generation:self.generation state:@"failed"];
    ack[@"error_code"] = secret; ack[@"error_message"] = secret; ack[@"path"] = secret;
    NSInteger status;
    NSDictionary *answer = [self post:@"/v1/lifecycle/ack" token:self.bridge.token body:ack status:&status];
    XCTAssertEqual(status, 200);
    XCTAssertEqualObjects(self.manager.diagnosticSnapshot[@"error_code"], @"transition_failed");
    NSData *data = [NSJSONSerialization dataWithJSONObject:@[answer, self.manager.diagnosticSnapshot] options:0 error:nil];
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    XCTAssertFalse([json containsString:secret]);
    XCTAssertFalse([DSHHarness.shared.log.diagnosticReport containsString:secret]);
    [self.mainQueue drain];
}
@end
