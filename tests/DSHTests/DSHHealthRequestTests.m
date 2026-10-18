#import <XCTest/XCTest.h>
#import "DSHHarness.h"
#import "DSHStatusOverlayView.h"
#import "DSHRootViewController.h"

@interface DSHStatusOverlayView (StartupProgressFixture)
- (void)tick;
@end
@interface DSHRootViewController (StartupProgressFixture)
- (void)showStartupProgressForHarness:(DSHHarness *)harness;
@end

/// Deliberately permits callbacks after cancellation: this models a result
/// already queued by URLSession when the scene leaves the foreground.
@interface DSHManualHealthRequest : NSObject <DSHProbeRequest>
@property (nonatomic) BOOL cancelled;
@property (nonatomic, copy) void (^completion)(DSHProbeResult *);
- (void)answer:(DSHProbeOutcome)outcome;
@end

@implementation DSHManualHealthRequest
- (void)cancel { self.cancelled = YES; }
- (void)answer:(DSHProbeOutcome)outcome {
    DSHProbeResult *result = [DSHProbeResult new];
    [result setValue:@(outcome) forKey:@"outcome"];
    [result setValue:@"GET" forKey:@"method"];
    [result setValue:@0.01 forKey:@"duration"];
    if (outcome == DSHProbeOutcomeAnswered) [result setValue:@200 forKey:@"statusCode"];
    if (outcome == DSHProbeOutcomeBadStatus) [result setValue:@503 forKey:@"statusCode"];
    self.completion(result);
}
@end

@interface DSHScheduledHealthAction : NSObject
@property (nonatomic) NSTimeInterval due;
@property (nonatomic, copy) dispatch_block_t action;
@end
@implementation DSHScheduledHealthAction
@end

@interface DSHManualHealthClock : NSObject
@property (nonatomic) NSTimeInterval now;
@property (nonatomic) NSMutableArray<DSHScheduledHealthAction *> *actions;
- (void)schedule:(NSTimeInterval)delay action:(dispatch_block_t)action;
- (void)advance:(NSTimeInterval)seconds;
@end
@implementation DSHManualHealthClock
- (instancetype)init {
    if ((self = [super init])) { _now = 100; _actions = [NSMutableArray array]; }
    return self;
}
- (void)schedule:(NSTimeInterval)delay action:(dispatch_block_t)action {
    DSHScheduledHealthAction *entry = [DSHScheduledHealthAction new];
    entry.due = self.now + MAX(0, delay);
    entry.action = action;
    [self.actions addObject:entry];
}
- (void)advance:(NSTimeInterval)seconds {
    NSTimeInterval target = self.now + seconds;
    while (YES) {
        DSHScheduledHealthAction *next = nil;
        for (DSHScheduledHealthAction *entry in self.actions)
            if (entry.due <= target && (next == nil || entry.due < next.due)) next = entry;
        if (next == nil) break;
        [self.actions removeObject:next];
        self.now = next.due;
        next.action();
    }
    self.now = target;
}
@end

@interface DSHManualHealthLauncher : NSObject <DSHGuestProcessLauncher>
@property (nonatomic) NSUInteger launches;
@property (nonatomic) NSUInteger kills;
@property (nonatomic) BOOL emitsToken;
@property (nonatomic, copy) void (^exitHandler)(int);
@end
@implementation DSHManualHealthLauncher
- (instancetype)init { if ((self = [super init])) _emitsToken = YES; return self; }
- (int)launchExecutable:(NSString *)executable arguments:(NSArray<NSString *> *)arguments
            environment:(NSDictionary<NSString *,NSString *> *)environment
                   line:(void (^)(NSString *, BOOL))line exit:(void (^)(int))exit {
    self.launches++;
    self.exitHandler = exit;
    if (self.emitsToken)
        line([NSString stringWithFormat:@"dsh web: http://127.0.0.1:%@/?token=manual-token-%lu",
              environment[@"DSH_PORT"], (unsigned long)self.launches], NO);
    return 800 + (int)self.launches;
}
- (BOOL)killProcess:(int)pid signal:(int)signal { self.kills++; return YES; }
@end

/// Startup HTTP is outside these state-machine tests; the production launcher,
/// token parsing, launch generation, and supervision code still execute.
@interface DSHHealthFixtureHarness : DSHHarness
@end
@implementation DSHHealthFixtureHarness
- (void)startReadinessPoll {
    if (self.authenticatedEntryURL != nil) [self setValue:@(DSHHarnessStateReady) forKey:@"state"];
}
@end

@interface DSHHarness (StartupDurationFixture)
- (DSHReadinessProbe *)readinessProbeForURL:(NSURL *)url interval:(NSTimeInterval)interval timeout:(NSTimeInterval)timeout;
@end

/// Deliver the actual Harness readiness callback with independently controlled
/// probe elapsed/monotonic time, including an already queued stale response.
@interface DSHManualStartupProbe : DSHReadinessProbe
@property (nonatomic, copy) DSHReadinessHandler fixtureHandler;
@property (nonatomic) NSTimeInterval fixtureTimeout;
@property (nonatomic) NSTimeInterval fixtureInterval;
@property (nonatomic) BOOL fixtureCancelled;
- (void)answerReadyWithProbeElapsed:(NSTimeInterval)elapsed;
@end
@implementation DSHManualStartupProbe
- (void)startWithHandler:(DSHReadinessHandler)handler { self.fixtureHandler = handler; }
- (void)cancel { self.fixtureCancelled = YES; }
- (void)answerReadyWithProbeElapsed:(NSTimeInterval)elapsed { self.fixtureHandler(YES, elapsed); }
@end

@interface DSHStartupDurationFixtureHarness : DSHHarness
@property (nonatomic) NSMutableArray<DSHManualStartupProbe *> *startupProbes;
@end
@implementation DSHStartupDurationFixtureHarness
- (DSHReadinessProbe *)readinessProbeForURL:(NSURL *)url interval:(NSTimeInterval)interval timeout:(NSTimeInterval)timeout {
    if (!self.startupProbes) self.startupProbes = [NSMutableArray array];
    DSHManualStartupProbe *probe = [[DSHManualStartupProbe alloc] initWithURL:url interval:interval timeout:timeout];
    probe.fixtureTimeout = timeout; probe.fixtureInterval = interval;
    [self.startupProbes addObject:probe];
    return probe;
}
@end

@interface DSHStartupDurationTests : XCTestCase
@property (nonatomic) DSHManualHealthClock *clock;
@property (nonatomic) DSHManualHealthLauncher *launcher;
@property (nonatomic) DSHStartupDurationFixtureHarness *harness;
@property (nonatomic) id priorActiveEstimate;
@property (nonatomic) id priorLegacyEstimate;
@end
@implementation DSHStartupDurationTests
- (void)setUp {
    [super setUp]; XCTAssertTrue(NSThread.isMainThread);
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    self.priorActiveEstimate = [defaults objectForKey:@"DSHExpectedActiveStartupDuration.1"];
    self.priorLegacyEstimate = [defaults objectForKey:@"DSHExpectedStartupDuration"];
    [defaults removeObjectForKey:@"DSHExpectedActiveStartupDuration.1"];
    [defaults setDouble:2.8 forKey:@"DSHExpectedStartupDuration"];
    self.clock = [DSHManualHealthClock new]; self.launcher = [DSHManualHealthLauncher new];
    self.launcher.emitsToken = NO;
    DSHManualHealthClock *clock = self.clock;
    self.harness = [[DSHStartupDurationFixtureHarness alloc] initWithLauncher:self.launcher
        healthProbeFactory:^id<DSHProbeRequest>(NSURL *url, NSTimeInterval timeout, void (^completion)(DSHProbeResult *)) {
            DSHManualHealthRequest *request = [DSHManualHealthRequest new]; request.completion = completion; return request;
        } scheduler:^(NSTimeInterval delay, dispatch_block_t action) { [clock schedule:delay action:action]; }
        clock:^{ return clock.now; }];
    self.harness.startupTimeout = 600;
}
- (void)tearDown {
    [self.harness stop]; self.harness = nil;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (self.priorActiveEstimate) [defaults setObject:self.priorActiveEstimate forKey:@"DSHExpectedActiveStartupDuration.1"];
    else [defaults removeObjectForKey:@"DSHExpectedActiveStartupDuration.1"];
    if (self.priorLegacyEstimate) [defaults setObject:self.priorLegacyEstimate forKey:@"DSHExpectedStartupDuration"];
    else [defaults removeObjectForKey:@"DSHExpectedStartupDuration"];
    [super tearDown];
}
- (void)announceToken:(NSString *)token {
    [self.harness ingestServerLineForTesting:[NSString stringWithFormat:
        @"dsh web: http://127.0.0.1:%u/?token=%@", self.harness.port, token]];
}
- (void)testActiveStartupIncludesTheWaitBeforeTokenAndDiscardsLegacyProbeEstimates {
    XCTAssertEqualWithAccuracy(self.harness.expectedStartupDuration, 180, 0.001);
    [self.harness start]; [self.clock advance:60];
    XCTAssertEqual(self.harness.state, DSHHarnessStateStarting);
    XCTAssertEqual(self.harness.startupProbes.count, 0u, @"Token gating is unchanged");
    [self announceToken:@"duration-token-1"];
    DSHManualStartupProbe *probe = self.harness.startupProbes.lastObject;
    XCTAssertEqualWithAccuracy(probe.fixtureTimeout, 540, 0.001);
    XCTAssertEqualWithAccuracy(probe.fixtureInterval, 0.25, 0.001);
    [self.clock advance:3]; [probe answerReadyWithProbeElapsed:3];
    XCTAssertEqual(self.harness.state, DSHHarnessStateReady);
    XCTAssertEqualWithAccuracy(self.harness.lastStartupDuration, 63, 0.001);
    XCTAssertEqualWithAccuracy(self.harness.expectedStartupDuration, 63, 0.001);
    XCTAssertTrue([[self.harness.log tail:20] containsString:@"63.0s of active startup"]);
}
- (void)testActiveStartupExcludesBackgroundAndIgnoresTheCancelledProbe {
    [self.harness start]; [self.clock advance:40]; [self announceToken:@"duration-token-pause"];
    DSHManualStartupProbe *old = self.harness.startupProbes.lastObject;
    [self.clock advance:2]; [self.harness handleAppBackground]; [self.clock advance:300];
    XCTAssertTrue(old.fixtureCancelled);
    [self.harness handleAppResume];
    DSHManualStartupProbe *current = self.harness.startupProbes.lastObject;
    XCTAssertNotEqual(old, current);
    XCTAssertEqualWithAccuracy(current.fixtureTimeout, 558, 0.001, @"Background time cannot consume the existing startup budget");
    [old answerReadyWithProbeElapsed:2];
    XCTAssertEqual(self.harness.state, DSHHarnessStateStarting);
    XCTAssertEqualWithAccuracy(self.harness.lastStartupDuration, 0, 0.001);
    [self.clock advance:3]; [current answerReadyWithProbeElapsed:3];
    XCTAssertEqual(self.harness.state, DSHHarnessStateReady);
    XCTAssertEqualWithAccuracy(self.harness.lastStartupDuration, 45, 0.001);
    XCTAssertEqualWithAccuracy(self.harness.expectedStartupDuration, 45, 0.001);
    XCTAssertEqual(self.launcher.launches, 1u); XCTAssertEqual(self.launcher.kills, 0u);
}
- (void)testReplacementGuestStartsANewMeasurementAndSmoothsOnlyActiveSamples {
    [self.harness start]; [self.clock advance:60]; [self announceToken:@"duration-token-first"];
    DSHManualStartupProbe *old = self.harness.startupProbes.lastObject;
    [self.clock advance:3]; [old answerReadyWithProbeElapsed:3];
    [self.harness restart]; [self.clock advance:0.5];
    XCTAssertEqual(self.launcher.launches, 2u);
    [self.clock advance:10]; [self announceToken:@"duration-token-second"];
    DSHManualStartupProbe *current = self.harness.startupProbes.lastObject;
    XCTAssertNotEqual(old, current); XCTAssertEqualWithAccuracy(current.fixtureTimeout, 590, 0.001);
    [old answerReadyWithProbeElapsed:3];
    XCTAssertEqual(self.harness.state, DSHHarnessStateStarting);
    XCTAssertEqualWithAccuracy(self.harness.lastStartupDuration, 63, 0.001);
    [self.clock advance:2]; [current answerReadyWithProbeElapsed:2];
    XCTAssertEqual(self.harness.state, DSHHarnessStateReady);
    XCTAssertEqualWithAccuracy(self.harness.lastStartupDuration, 12, 0.001);
    XCTAssertEqualWithAccuracy(self.harness.expectedStartupDuration, 37.5, 0.001);
}
- (void)testOverlayProgressFreezesInBackgroundAndContinuesFromActiveTime {
    DSHStatusOverlayView *overlay = [[DSHStatusOverlayView alloc] initWithFrame:CGRectMake(0, 0, 640, 480)];
    DSHRootViewController *controller = [DSHRootViewController new];
    [controller setValue:overlay forKey:@"overlay"];
    [overlay showStarting:@"Starting"];
    [self.harness start]; [self.clock advance:40];
    [controller showStartupProgressForHarness:self.harness];
    UILabel *label = [overlay valueForKey:@"elapsedLabel"];
    UIProgressView *progress = [overlay valueForKey:@"progress"];
    XCTAssertEqualObjects(label.text, @"40 s elapsed · about 140 s left");
    XCTAssertEqualWithAccuracy(progress.progress, 0.2, 0.0001);
    [self.harness handleAppBackground]; [self.clock advance:300]; [overlay tick];
    XCTAssertEqualObjects(label.text, @"40 s elapsed · about 140 s left");
    XCTAssertEqualWithAccuracy(progress.progress, 0.2, 0.0001);
    [self.harness handleAppResume]; [self.clock advance:3]; [overlay tick];
    XCTAssertEqualObjects(label.text, @"43 s elapsed · about 137 s left");
    XCTAssertEqualWithAccuracy(progress.progress, 0.215, 0.0001);
    XCTAssertEqual(self.launcher.launches, 1u); XCTAssertEqual(self.launcher.kills, 0u);
    [overlay showFailure:@"test finished"];
}
- (void)testPublicActiveDurationFreezesWhenReadyAndResetsOutsideTheCurrentAttempt {
    XCTAssertEqualWithAccuracy(self.harness.activeStartupDuration, 0, 0.001);
    [self.harness start]; [self.clock advance:60]; [self announceToken:@"progress-duration-token"];
    [self.clock advance:3]; [self.harness.startupProbes.lastObject answerReadyWithProbeElapsed:3];
    XCTAssertEqualWithAccuracy(self.harness.activeStartupDuration, 63, 0.001);
    [self.clock advance:100];
    XCTAssertEqualWithAccuracy(self.harness.activeStartupDuration, 63, 0.001, @"Ready is a completed sample, not a running timer");
    [self.harness stop];
    XCTAssertEqualWithAccuracy(self.harness.activeStartupDuration, 0, 0.001);
    [self.harness start];
    XCTAssertEqualWithAccuracy(self.harness.activeStartupDuration, 0, 0.001);
    [self.clock advance:4];
    XCTAssertEqualWithAccuracy(self.harness.activeStartupDuration, 4, 0.001);
}
- (void)testOverlayModeChangesReleaseTheProviderAndKeepTheDateAPIUsable {
    DSHStatusOverlayView *overlay = [[DSHStatusOverlayView alloc] initWithFrame:CGRectMake(0, 0, 640, 480)];
    NSArray<dispatch_block_t> *changes = @[
        ^{ [overlay setProgressStartedAt:[NSDate dateWithTimeIntervalSinceNow:-10] expected:100]; },
        ^{ [overlay setDeterminateProgress:0.5 detail:@"Installed"]; },
        ^{ [overlay showStarting:@"Loading the interface"]; },
        ^{ [overlay showFailure:@"Failed"]; },
        ^{ overlay.hidden = YES; [overlay hide]; }
    ];
    for (dispatch_block_t change in changes) {
        [overlay showStarting:@"Starting"];
        __block NSUInteger reads = 0;
        NSObject *owner = [NSObject new];
        __weak NSObject *weakOwner = owner;
        [overlay setProgressElapsedProvider:^{ reads++; return [owner isKindOfClass:NSObject.class] ? 17.0 : 0.0; } expected:100];
        owner = nil;
        XCTAssertNotNil(weakOwner); XCTAssertEqual(reads, 1u);
        change(); [overlay tick];
        XCTAssertEqual(reads, 1u, @"A previous phase's elapsed callback must never be read again");
        XCTAssertNil(weakOwner, @"Mode changes must release the copied provider");
    }
    [overlay showStarting:@"Legacy date estimate"];
    [overlay setProgressStartedAt:[NSDate dateWithTimeIntervalSinceNow:-10] expected:100];
    UILabel *label = [overlay valueForKey:@"elapsedLabel"];
    UIProgressView *progress = [overlay valueForKey:@"progress"];
    XCTAssertTrue([label.text hasPrefix:@"10 s elapsed"]);
    XCTAssertEqualWithAccuracy(progress.progress, 0.09, 0.005);
    [overlay showFailure:@"test finished"];
}
- (void)testRootProgressProviderDoesNotRetainTheHarnessOrUseAnIdleTimer {
    DSHStatusOverlayView *overlay = [[DSHStatusOverlayView alloc] initWithFrame:CGRectMake(0, 0, 640, 480)];
    DSHRootViewController *controller = [DSHRootViewController new];
    [controller setValue:overlay forKey:@"overlay"];
    [overlay showStarting:@"Starting"];
    [controller showStartupProgressForHarness:self.harness];
    UIProgressView *progress = [overlay valueForKey:@"progress"];
    XCTAssertEqualWithAccuracy(progress.alpha, 0, 0.001, @"Idle has no active startup estimate");
    [self.harness start]; [self.clock advance:5];
    [controller showStartupProgressForHarness:self.harness];
    __weak DSHHarness *weakHarness = self.harness;
    [self.harness stop]; self.harness = nil;
    XCTAssertNil(weakHarness, @"The overlay must not own the lifecycle being observed");
    [overlay tick];
    XCTAssertTrue([[((UILabel *)[overlay valueForKey:@"elapsedLabel"]) text] hasPrefix:@"0 s elapsed"]);
    [overlay showFailure:@"test finished"];
}
@end

@interface DSHHealthRequestTests : XCTestCase
@property (nonatomic) DSHManualHealthClock *clock;
@property (nonatomic) DSHManualHealthLauncher *launcher;
@property (nonatomic) NSMutableArray<DSHManualHealthRequest *> *requests;
@property (nonatomic) DSHHarness *harness;
@end

@implementation DSHHealthRequestTests

- (void)setUp {
    [super setUp];
    self.clock = [DSHManualHealthClock new];
    self.launcher = [DSHManualHealthLauncher new];
    self.requests = [NSMutableArray array];
    self.harness = [self newHarnessOfClass:DSHHealthFixtureHarness.class];
    [self.harness start];
    XCTAssertEqual(self.harness.state, DSHHarnessStateReady);
}

- (void)tearDown {
    [self.harness stop];
    self.harness = nil;
    self.requests = nil;
    self.clock = nil;
    self.launcher = nil;
    [super tearDown];
}

- (DSHHarness *)newHarnessOfClass:(Class)harnessClass {
    NSMutableArray<DSHManualHealthRequest *> *requests = self.requests;
    DSHManualHealthClock *clock = self.clock;
    DSHHarness *h = [[harnessClass alloc] initWithLauncher:self.launcher
        healthProbeFactory:^id<DSHProbeRequest>(NSURL *url, NSTimeInterval timeout, void (^completion)(DSHProbeResult *)) {
            DSHManualHealthRequest *request = [DSHManualHealthRequest new];
            request.completion = completion;
            [requests addObject:request];
            return request;
        } scheduler:^(NSTimeInterval delay, dispatch_block_t action) {
            [clock schedule:delay action:action];
        } clock:^NSTimeInterval { return clock.now; }];
    h.startupTimeout = 60;
    h.healthCheckRetryDelay = 2;
    h.healthCheckFailuresBeforeRestart = 3;
    return h;
}

- (void)drainMainQueue {
    XCTestExpectation *done = [self expectationWithDescription:@"main-queue exit callback"];
    dispatch_async(dispatch_get_main_queue(), ^{ [done fulfill]; });
    [self waitForExpectations:@[done] timeout:5];
}

- (void)testCancelledOldResultsCannotFinishTheNewForegroundRequest {
    __block NSUInteger oldCallbacks = 0;
    [self.harness verifyAliveWithCompletion:^(BOOL alive) { oldCallbacks++; }];
    DSHManualHealthRequest *old = self.requests.lastObject;
    NSUInteger oldID = self.harness.healthCheckGeneration;
    [self.harness handleAppBackground];
    XCTAssertTrue(old.cancelled);
    [self.harness handleAppResume];
    DSHManualHealthRequest *current = self.requests.lastObject;
    XCTAssertNotEqual(old, current);
    XCTAssertGreaterThan(self.harness.healthCheckGeneration, oldID);
    __block NSUInteger currentCallbacks = 0;
    [self.harness verifyAliveWithCompletion:^(BOOL alive) {
        XCTAssertTrue(alive);
        currentCallbacks++;
    }];
    [old answer:DSHProbeOutcomeUnreachable];
    [old answer:DSHProbeOutcomeAnswered];
    [old answer:DSHProbeOutcomeTimedOut];
    XCTAssertEqual(oldCallbacks, 0u, @"callbacks from the old scene were invalidated");
    XCTAssertEqual(currentCallbacks, 0u, @"A must not finish B's callbacks");
    XCTAssertNil(self.harness.lastHealthCheck);
    XCTAssertEqual(self.harness.healthCheckFailures, 0u);
    XCTAssertEqual(self.harness.restartCount, 0u);
    XCTAssertEqual(self.launcher.kills, 0u);
    [current answer:DSHProbeOutcomeAnswered];
    XCTAssertEqual(currentCallbacks, 1u);
    DSHProbeResult *answer = self.harness.lastHealthCheck;
    [old answer:DSHProbeOutcomeBadStatus];
    XCTAssertEqual(self.harness.lastHealthCheck, answer);
    XCTAssertEqual(currentCallbacks, 1u);
    XCTAssertEqual(self.harness.state, DSHHarnessStateReady);
}

- (void)testDuplicateResumeAndActiveNotificationsCoalesceOneRequest {
    NSUInteger authentication = self.harness.authenticationGeneration;
    int guestPID = self.harness.guestPid;
    uint16_t port = self.harness.port;
    [self.harness handleAppBackground];
    [self.harness handleAppResume];
    NSUInteger requestID = self.harness.healthCheckGeneration;
    [self.harness handleAppResume];
    __block NSUInteger callbacks = 0;
    [self.harness verifyAliveAfterResumeWithCompletion:^(BOOL alive) { XCTAssertTrue(alive); callbacks++; }];
    [self.harness verifyAliveWithCompletion:^(BOOL alive) { XCTAssertTrue(alive); callbacks++; }];
    XCTAssertEqual(self.requests.count, 1u);
    XCTAssertEqual(self.harness.healthCheckGeneration, requestID);
    [self.requests.lastObject answer:DSHProbeOutcomeAnswered];
    XCTAssertEqual(callbacks, 2u);
    [self.harness verifyAliveAfterResumeWithCompletion:^(BOOL alive) { XCTAssertTrue(alive); callbacks++; }];
    XCTAssertEqual(self.requests.count, 1u, @"the fresh successful result is reused");
    XCTAssertEqual(callbacks, 3u);
    XCTAssertEqual(self.launcher.launches, 1u);
    XCTAssertEqual(self.harness.authenticationGeneration, authentication);
    XCTAssertEqual(self.harness.guestPid, guestPID);
    XCTAssertEqual(self.harness.port, port);
    [self.clock advance:2.1];
    [self.harness verifyAliveWithCompletion:nil];
    XCTAssertEqual(self.requests.count, 2u, @"the monotonic debounce expires");
}

- (void)testResumeRefusalRetriesAndRecoversWithoutRestartingNode {
    [self.harness handleAppBackground];
    [self.harness handleAppResume];
    __block NSUInteger callbacks = 0;
    [self.harness verifyAliveWithCompletion:^(BOOL alive) { XCTAssertTrue(alive); callbacks++; }];
    DSHManualHealthRequest *first = self.requests.lastObject;
    [first answer:DSHProbeOutcomeUnreachable];
    XCTAssertEqual(self.harness.healthCheckFailures, 1u);
    XCTAssertEqual(self.harness.restartCount, 0u);
    XCTAssertEqual(callbacks, 0u);
    // A duplicated completion from the same attempt cannot consume a retry.
    [first answer:DSHProbeOutcomeBadStatus];
    XCTAssertEqual(self.harness.healthCheckFailures, 1u);
    [self.clock advance:2];
    XCTAssertEqual(self.requests.count, 2u);
    [self.requests.lastObject answer:DSHProbeOutcomeAnswered];
    XCTAssertEqual(callbacks, 1u);
    XCTAssertEqual(self.launcher.launches, 1u);
    XCTAssertEqual(self.launcher.kills, 0u);
    XCTAssertEqual(self.harness.healthCheckFailures, 0u);
}

- (void)testPersistentResumeServerErrorsHaveAFiniteRecoveryLadder {
    [self.harness handleAppBackground];
    [self.harness handleAppResume];
    __block NSUInteger callbacks = 0;
    [self.harness verifyAliveWithCompletion:^(BOOL alive) { XCTAssertFalse(alive); callbacks++; }];
    [self.requests.lastObject answer:DSHProbeOutcomeBadStatus];
    XCTAssertEqual(self.harness.restartCount, 0u);
    [self.clock advance:2];
    [self.requests.lastObject answer:DSHProbeOutcomeBadStatus];
    XCTAssertEqual(self.harness.restartCount, 0u);
    [self.clock advance:2];
    [self.requests.lastObject answer:DSHProbeOutcomeBadStatus];
    XCTAssertEqual(callbacks, 1u);
    XCTAssertEqual(self.harness.restartCount, 1u);
    XCTAssertEqual(self.launcher.kills, 1u);
    [self.clock advance:0.5];
    XCTAssertEqual(self.launcher.launches, 2u);
    XCTAssertEqual(self.harness.state, DSHHarnessStateReady);
}

- (void)testBackgroundInvalidatesAPendingRetryWithoutTouchingItsReplacement {
    [self.harness verifyAliveWithCompletion:nil];
    [self.requests.lastObject answer:DSHProbeOutcomeTimedOut];
    [self.harness handleAppBackground];
    [self.clock advance:1];
    XCTAssertEqual(self.requests.count, 1u);
    [self.harness handleAppResume];
    DSHManualHealthRequest *replacement = self.requests.lastObject;
    [self.clock advance:2];
    XCTAssertEqual(self.requests.count, 2u, @"the old retry must not start a third request");
    [replacement answer:DSHProbeOutcomeAnswered];
    XCTAssertEqual(self.harness.restartCount, 0u);
    XCTAssertEqual(self.launcher.kills, 0u);
}

- (void)testStoppingSettlesOnlyItsOwnCallbacksAndIgnoresLateResults {
    __block NSUInteger callbacks = 0;
    [self.harness verifyAliveWithCompletion:^(BOOL alive) { XCTAssertFalse(alive); callbacks++; }];
    DSHManualHealthRequest *old = self.requests.lastObject;
    [self.harness stop];
    XCTAssertEqual(callbacks, 1u);
    XCTAssertTrue(old.cancelled);
    [self.harness start];
    __block NSUInteger newCallbacks = 0;
    [self.harness verifyAliveWithCompletion:^(BOOL alive) { XCTAssertTrue(alive); newCallbacks++; }];
    [old answer:DSHProbeOutcomeUnreachable];
    XCTAssertEqual(newCallbacks, 0u);
    [self.requests.lastObject answer:DSHProbeOutcomeAnswered];
    XCTAssertEqual(newCallbacks, 1u);
    XCTAssertEqual(callbacks, 1u);
    XCTAssertEqual(self.harness.restartCount, 0u);
}

- (void)testStartupDeadlineCountsOnlyForegroundTime {
    [self.harness stop];
    self.launcher.emitsToken = NO;
    self.harness = [self newHarnessOfClass:DSHHarness.class];
    self.harness.startupTimeout = 10;
    NSUInteger killsBefore = self.launcher.kills;
    [self.harness start];
    [self.clock advance:2];
    [self.harness handleAppBackground];
    [self.clock advance:60];
    XCTAssertEqual(self.harness.state, DSHHarnessStateStarting);
    XCTAssertEqual(self.launcher.kills, killsBefore);
    [self.harness handleAppResume];
    [self.harness handleAppResume];
    [self.clock advance:7];
    XCTAssertEqual(self.harness.state, DSHHarnessStateStarting);
    [self.clock advance:1];
    XCTAssertEqual(self.launcher.kills, killsBefore + 1);
    XCTAssertEqual(self.harness.state, DSHHarnessStateRestarting);
    XCTAssertEqual(self.harness.restartCount, 1u);
}

- (void)testGuestExitInForegroundStillRelaunches {
    self.launcher.exitHandler(137);
    [self drainMainQueue];
    XCTAssertEqual(self.harness.state, DSHHarnessStateRestarting);
    XCTAssertEqual(self.harness.guestPid, 0);
    [self.clock advance:1];
    XCTAssertEqual(self.launcher.launches, 2u);
    XCTAssertEqual(self.harness.state, DSHHarnessStateReady);
    XCTAssertEqual(self.harness.restartCount, 1u);
}

- (void)testGuestExitInBackgroundDefersRelaunchUntilForeground {
    [self.harness handleAppBackground];
    self.launcher.exitHandler(137);
    [self drainMainQueue];
    [self.clock advance:60];
    XCTAssertEqual(self.launcher.launches, 1u);
    XCTAssertEqual(self.harness.state, DSHHarnessStateRestarting);
    [self.harness handleAppResume];
    [self.harness handleAppResume];
    [self.clock advance:1];
    XCTAssertEqual(self.launcher.launches, 2u);
    XCTAssertEqual(self.harness.restartCount, 1u);
    XCTAssertEqual(self.harness.state, DSHHarnessStateReady);
}

- (void)testOrdinaryRefusalStillRecoversImmediatelyOutsideResume {
    [self.harness verifyAliveWithCompletion:nil];
    [self.requests.lastObject answer:DSHProbeOutcomeUnreachable];
    XCTAssertEqual(self.harness.restartCount, 1u);
    XCTAssertEqual(self.launcher.kills, 1u);
    [self.clock advance:0.5];
    XCTAssertEqual(self.launcher.launches, 2u);
}

- (void)testOldGuestExitCannotRetireTheReplacementProcess {
    void (^oldExit)(int) = self.launcher.exitHandler;
    [self.harness restart];
    [self.clock advance:0.5];
    int newPID = self.harness.guestPid;
    oldExit(137);
    [self drainMainQueue];
    XCTAssertEqual(self.harness.guestPid, newPID);
    XCTAssertEqual(self.harness.state, DSHHarnessStateReady);
    XCTAssertEqual(self.harness.restartCount, 1u);
    XCTAssertEqual(self.launcher.launches, 2u);
}

- (void)testBackgroundingFromFailureCompletionPreventsAutomaticRestart {
    [self.harness verifyAliveWithCompletion:^(BOOL alive) {
        XCTAssertFalse(alive);
        [self.harness handleAppBackground];
    }];
    [self.requests.lastObject answer:DSHProbeOutcomeUnreachable];
    [self.clock advance:60];
    XCTAssertEqual(self.harness.restartCount, 0u);
    XCTAssertEqual(self.launcher.kills, 0u);
    XCTAssertEqual(self.launcher.launches, 1u);
    [self.harness handleAppResume];
    [self.requests.lastObject answer:DSHProbeOutcomeAnswered];
    XCTAssertEqual(self.harness.state, DSHHarnessStateReady);
}

- (void)testProbeCancellationSettlesExactlyOnceOnTheMainQueue {
    __block NSUInteger callbacks = 0;
    id<DSHProbeRequest> request = [DSHReadinessProbe requestURL:[NSURL URLWithString:@"http://127.0.0.1:1/"]
        timeout:30 completion:^(DSHProbeResult *result) {
            XCTAssertTrue(NSThread.isMainThread);
            XCTAssertEqual(result.outcome, DSHProbeOutcomeCancelled);
            callbacks++;
        }];
    [request cancel];
    [request cancel];
    XCTAssertEqual(callbacks, 1u);
    [self drainMainQueue];
    XCTAssertEqual(callbacks, 1u);
}

@end
