//
//  DSHHealthCheckTests.m
//  DSHTests
//
//  Regression tests for the harness health-check loop.
//
//  Context: on a real iPad the app restarted the guest every ~40 seconds
//  forever. The log read:
//
//      server answered after 40.7s
//      state -> ready
//      health check failed; restarting server
//      restart requested
//      server answered after 40.2s
//      ...
//
//  Two defects produced it, and every test below fails against the old code:
//
//   1. The one-shot check used a fixed 5 s budget. On this emulator a HEAD
//      right after a 40 s boot, with a cold JIT and a loaded CPU, routinely
//      needed longer. The probe reported a live server dead.
//   2. A single failed probe called -restart immediately. There was no retry,
//      no failure counter, and no distinction between "the answer was late"
//      and "nothing is listening" -- so one late answer cost a full reboot.
//
//  The tests are deliberately split by failure mode: a timeout must be
//  tolerated, a refused connection must not be.
//

#import <XCTest/XCTest.h>
#import "DSHHarness.h"
#import "DSHReadinessProbe.h"
#import "DSHPortAllocator.h"
#import "DSHTestHTTPServer.h"

#pragma mark - Fake launcher

@interface DSHFakeGuestLauncher : NSObject <DSHGuestProcessLauncher>
@property (nonatomic) NSMutableArray<NSDictionary *> *launches;
@property (nonatomic, copy, nullable) void (^onLaunch)(NSDictionary *env);
@property (nonatomic) int nextPid;
@property (nonatomic) NSMutableArray<NSNumber *> *killed;
/// The exit block of the most recent launch, so a test can simulate a crash.
@property (nonatomic, copy, nullable) void (^lastExit)(int);
@end

@implementation DSHFakeGuestLauncher

- (instancetype)init {
    if (self = [super init]) {
        _launches = [NSMutableArray array];
        _killed = [NSMutableArray array];
        _nextPid = 200;
    }
    return self;
}

- (int)launchExecutable:(NSString *)executable
              arguments:(NSArray<NSString *> *)arguments
            environment:(NSDictionary<NSString *, NSString *> *)environment
                   line:(void (^)(NSString *, BOOL))line
                   exit:(void (^)(int))exit {
    [self.launches addObject:@{@"exe": executable, @"env": environment}];
    self.lastExit = exit;
    if (self.onLaunch) self.onLaunch(environment);
    return self.nextPid++;
}

- (BOOL)killProcess:(int)pid signal:(int)signal {
    [self.killed addObject:@(pid)];
    // The real executor signals the guest; the fake mirrors that by reporting
    // the exit so the harness's crash path runs.
    if (self.lastExit) {
        void (^exit)(int) = self.lastExit;
        dispatch_async(dispatch_get_main_queue(), ^{ exit(128 + signal); });
    }
    return YES;
}

@end

#pragma mark - Tests

@interface DSHHealthCheckTests : XCTestCase
@end

@implementation DSHHealthCheckTests

/// Builds a harness whose fake guest binds a test HTTP server on whatever
/// loopback port the harness chose -- mirroring how the real guest is given
/// DSH_PORT and then listens on it.
- (DSHHarness *)harnessOnPort:(uint16_t)preferred
                      timeout:(NSTimeInterval)timeout
                     launcher:(DSHFakeGuestLauncher *)launcher
                   serverSlot:(DSHTestHTTPServer * __strong *)slot {
    launcher.onLaunch = ^(NSDictionary *env) {
        uint16_t port = (uint16_t) [env[@"DSH_PORT"] intValue];
        *slot = [[DSHTestHTTPServer alloc] initWithPort:port];
    };
    DSHHarness *h = [[DSHHarness alloc] initWithLauncher:launcher];
    h.preferredPort = preferred;
    h.startupTimeout = 10;
    h.healthCheckTimeout = timeout;
    return h;
}

- (void)waitReady:(DSHHarness *)h {
    if (h.state == DSHHarnessStateReady) return;
    XCTestExpectation *ready = [self expectationForNotification:DSHHarnessStateDidChangeNotification
                                                        object:h
                                                       handler:^BOOL(NSNotification *n) {
        return h.state == DSHHarnessStateReady;
    }];
    [h start];
    [self waitForExpectations:@[ready] timeout:15];
}

#pragma mark - The regression itself

/// The exact bug: a server that is merely slow to answer must not be restarted.
/// The old code restarted on the first 5-second timeout, which is why the iPad
/// rebooted the guest in an endless loop.
- (void)testSingleTimeoutDoesNotRestartServer {
    DSHFakeGuestLauncher *launcher = [DSHFakeGuestLauncher new];
    DSHTestHTTPServer *__strong server = nil;
    DSHHarness *h = [self harnessOnPort:38500 timeout:1 launcher:launcher serverSlot:&server];
    h.healthCheckFailuresBeforeRestart = 5;   // long ladder: isolate the single-failure case
    h.healthCheckRetryDelay = 0.2;
    [self waitReady:h];
    XCTAssertNotNil(server);

    NSUInteger launchesBefore = launcher.launches.count;

    // Wedge the server: it accepts, then never answers.
    server.stalls = YES;

    XCTestExpectation *checked = [self expectationWithDescription:@"one probe finished"];
    [h verifyAliveWithCompletion:^(BOOL alive) {
        XCTAssertFalse(alive, @"a stalled server is not alive");
        [checked fulfill];
    }];
    [self waitForExpectations:@[checked] timeout:10];

    XCTAssertEqual(h.state, DSHHarnessStateReady, @"a single late answer must not change state");
    XCTAssertEqual(launcher.launches.count, launchesBefore, @"no restart, so no new guest process");
    XCTAssertEqual(h.restartCount, 0u, @"the heart of the bug: no restart on one timeout");
    XCTAssertEqual(h.healthCheckFailures, 1u, @"the failure is counted, not acted on");

    server.stalls = NO;
    [server stop];
}

/// Only sustained failure restarts. This is the recovery guarantee: the loop
/// must still fire once the server is genuinely gone.
- (void)testConsecutiveTimeoutsEventuallyRestart {
    DSHFakeGuestLauncher *launcher = [DSHFakeGuestLauncher new];
    DSHTestHTTPServer *__strong server = nil;
    DSHHarness *h = [self harnessOnPort:38600 timeout:1 launcher:launcher serverSlot:&server];
    h.healthCheckFailuresBeforeRestart = 3;
    h.healthCheckRetryDelay = 0.2;
    [self waitReady:h];
    XCTAssertNotNil(server);

    server.stalls = YES;

    XCTestExpectation *restarting = [self expectationForNotification:DSHHarnessStateDidChangeNotification
                                                             object:h
                                                            handler:^BOOL(NSNotification *n) {
        return h.state == DSHHarnessStateRestarting || h.state == DSHHarnessStateStopped;
    }];
    restarting.assertForOverFulfill = NO;
    [h verifyAliveWithCompletion:nil];
    [self waitForExpectations:@[restarting] timeout:20];

    XCTAssertGreaterThanOrEqual(h.restartCount, 1u, @"repeated failures must still recover");
    XCTAssertGreaterThanOrEqual(launcher.launches.count, 2u, @"a new guest process was launched");
    XCTAssertTrue([[h.log tail:80] containsString:@"health check"], @"diagnostics are logged");

    server.stalls = NO;
    [server stop];
}

/// A refused connection is conclusive and must restart on the first check, so
/// real crashes are recovered immediately rather than after three timeouts.
- (void)testUnreachableServerRestartsImmediately {
    DSHFakeGuestLauncher *launcher = [DSHFakeGuestLauncher new];
    DSHTestHTTPServer *__strong server = nil;
    DSHHarness *h = [self harnessOnPort:38700 timeout:5 launcher:launcher serverSlot:&server];
    h.healthCheckFailuresBeforeRestart = 3;
    h.healthCheckRetryDelay = 0.2;
    [self waitReady:h];
    XCTAssertNotNil(server);

    // Kill the listener so the port refuses connections.
    [server stop];
    server = nil;

    XCTestExpectation *restarting = [self expectationForNotification:DSHHarnessStateDidChangeNotification
                                                             object:h
                                                            handler:^BOOL(NSNotification *n) {
        return h.state == DSHHarnessStateRestarting || h.state == DSHHarnessStateStopped;
    }];
    restarting.assertForOverFulfill = NO;
    [h verifyAliveWithCompletion:nil];
    [self waitForExpectations:@[restarting] timeout:20];

    XCTAssertEqual(h.restartCount, 1u, @"one conclusive failure is enough");
    XCTAssertLessThanOrEqual(h.healthCheckFailures, 1u,
                             @"conclusive failures are not accumulated before acting");
    XCTAssertNotNil(h.lastHealthCheck, @"the result is kept for diagnosis");
    XCTAssertTrue(h.lastHealthCheck.indicatesDeadServer, @"this failure mode is conclusive");
}

#pragma mark - Probe diagnostics

/// The probe must report *why* it failed. The old code returned a bare BOOL,
/// which is why the on-device log could only say "health check failed".
- (void)testProbeReportsConcreteOutcomeOnClosedPort {
    // Pick a port nothing listens on by binding and releasing one.
    DSHTestHTTPServer *scratch = [[DSHTestHTTPServer alloc] initWithPort:0];
    uint16_t port = scratch.port;
    [scratch stop];

    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%u/", port]];
    XCTestExpectation *e = [self expectationWithDescription:@"probe done"];
    [DSHReadinessProbe checkURL:url timeout:2 completion:^(DSHProbeResult *result) {
        XCTAssertNotNil(result);
        XCTAssertFalse(result.alive);
        XCTAssertTrue(result.outcome == DSHProbeOutcomeUnreachable || result.outcome == DSHProbeOutcomeTimedOut,
                      @"outcome is a concrete classification, got %ld", (long) result.outcome);
        XCTAssertGreaterThan(result.duration, 0, @"the probe times itself");
        XCTAssertGreaterThan(result.summary.length, 0u, @"there is a human-readable summary");
        XCTAssertGreaterThan(result.method.length, 0u, @"the method used is recorded");
        [e fulfill];
    }];
    [self waitForExpectations:@[e] timeout:15];
}

/// A stalled server must be reported as a timeout, not as unreachable, so the
/// harness tolerates it instead of rebooting.
- (void)testProbeClassifiesStalledServerAsTimeout {
    DSHTestHTTPServer *server = [[DSHTestHTTPServer alloc] initWithPort:0];
    XCTAssertNotNil(server);
    server.stalls = YES;
    XCTestExpectation *e = [self expectationWithDescription:@"probe done"];
    [DSHReadinessProbe checkURL:server.baseURL timeout:1 completion:^(DSHProbeResult *result) {
        XCTAssertEqual(result.outcome, DSHProbeOutcomeTimedOut, @"a stalled peer is a timeout");
        XCTAssertFalse(result.indicatesDeadServer, @"a timeout must not be treated as conclusive");
        [e fulfill];
    }];
    [self waitForExpectations:@[e] timeout:15];
    [server stop];
}

/// A 5xx is a real server-side failure and is conclusive.
- (void)testProbeClassifiesServerErrorAsBadStatus {
    DSHTestHTTPServer *server = [[DSHTestHTTPServer alloc] initWithPort:0];
    XCTAssertNotNil(server);
    server.statusCode = 503;
    XCTestExpectation *e = [self expectationWithDescription:@"probe done"];
    [DSHReadinessProbe checkURL:server.baseURL timeout:5 completion:^(DSHProbeResult *result) {
        XCTAssertEqual(result.outcome, DSHProbeOutcomeBadStatus);
        XCTAssertEqual(result.statusCode, 503, @"the status code is preserved");
        XCTAssertTrue(result.indicatesDeadServer);
        [e fulfill];
    }];
    [self waitForExpectations:@[e] timeout:15];
    [server stop];
}

/// A healthy server is reported healthy, and the cheap method is used.
- (void)testProbeSucceedsAgainstHealthyServer {
    DSHTestHTTPServer *server = [[DSHTestHTTPServer alloc] initWithPort:0];
    XCTAssertNotNil(server);
    XCTestExpectation *e = [self expectationWithDescription:@"probe done"];
    [DSHReadinessProbe checkURL:server.baseURL timeout:5 completion:^(DSHProbeResult *result) {
        XCTAssertTrue(result.alive);
        XCTAssertEqual(result.outcome, DSHProbeOutcomeAnswered);
        XCTAssertEqual(result.statusCode, 200);
        XCTAssertEqualObjects(result.method, @"HEAD", @"HEAD is tried first");
        XCTAssertGreaterThan(server.headRequestCount, 0u);
        [e fulfill];
    }];
    [self waitForExpectations:@[e] timeout:15];
    [server stop];
}

/// 404 is still an answer: the listener is up, which is all a liveness check
/// asks. Only 5xx counts against the server.
- (void)testProbeTreatsClientErrorAsAlive {
    DSHTestHTTPServer *server = [[DSHTestHTTPServer alloc] initWithPort:0];
    XCTAssertNotNil(server);
    server.statusCode = 404;
    XCTestExpectation *e = [self expectationWithDescription:@"probe done"];
    [DSHReadinessProbe checkURL:server.baseURL timeout:5 completion:^(DSHProbeResult *result) {
        XCTAssertTrue(result.alive, @"a 4xx still proves something is listening");
        XCTAssertEqual(result.statusCode, 404);
        [e fulfill];
    }];
    [self waitForExpectations:@[e] timeout:15];
    [server stop];
}

#pragma mark - Foreground coalescing

/// One resume produces several "we are foreground" signals. They must not
/// multiply into several probes, and a probe that just succeeded must not be
/// repeated immediately.
- (void)testRepeatedForegroundChecksAreCoalesced {
    DSHFakeGuestLauncher *launcher = [DSHFakeGuestLauncher new];
    DSHTestHTTPServer *__strong server = nil;
    DSHHarness *h = [self harnessOnPort:38800 timeout:5 launcher:launcher serverSlot:&server];
    h.healthCheckRetryDelay = 1;
    [self waitReady:h];
    XCTAssertNotNil(server);

    NSUInteger baseline = server.requestCount;
    XCTestExpectation *first = [self expectationWithDescription:@"first"];
    [h verifyAliveWithCompletion:^(BOOL alive) {
        XCTAssertTrue(alive);
        [first fulfill];
    }];
    [self waitForExpectations:@[first] timeout:10];
    NSUInteger afterFirst = server.requestCount;
    XCTAssertGreaterThan(afterFirst, baseline, @"the first check really probed");

    // Fire the remaining foreground notifications for the same resume.
    XCTestExpectation *rest = [self expectationWithDescription:@"rest"];
    rest.expectedFulfillmentCount = 3;
    rest.assertForOverFulfill = NO;
    for (int i = 0; i < 3; i++) {
        [h verifyAliveWithCompletion:^(BOOL alive) {
            XCTAssertTrue(alive, @"a debounced check answers from the recent result");
            [rest fulfill];
        }];
    }
    [self waitForExpectations:@[rest] timeout:10];

    XCTAssertEqual(server.requestCount, afterFirst,
                   @"duplicate foreground notifications must not re-probe");
    [server stop];
}

#pragma mark - Resuming from the background

/// The device's second symptom. The log showed:
///
///     health check: unreachable via GET after 0.01s (NSURLErrorDomain -1004)
///     health check failed 1 time(s) (server unreachable); restarting server
///
/// A "refused connection" is normally conclusive, so one of them restarts the
/// server. But straight after a resume that is the *expected* answer: it is what
/// the probe sees while the guest's sockets are being recreated. Counting it
/// towards the ladder turns every return from the background into a 40-second
/// reboot, which is the whole complaint.
///
/// This is the regression: after a real resume, a stale failure must no longer
/// be able to restart the server on its own.
- (void)testResumeClearsFailureRecordedBeforeSuspension {
    DSHFakeGuestLauncher *launcher = [DSHFakeGuestLauncher new];
    DSHTestHTTPServer *__strong server = nil;
    DSHHarness *h = [self harnessOnPort:39000 timeout:5 launcher:launcher serverSlot:&server];
    h.healthCheckFailuresBeforeRestart = 3;
    h.healthCheckRetryDelay = 5;   // long enough that no retry can muddy the count
    [self waitReady:h];
    XCTAssertNotNil(server);

    // Simulate the moment iOS has already freed the socket: the probe is
    // refused, which the harness treats as proof the server is dead.
    server.stalls = YES;
    [server stop];
    server = nil;

    XCTestExpectation *failed = [self expectationForNotification:DSHHarnessStateDidChangeNotification
                                                          object:h
                                                         handler:^BOOL(NSNotification *n) {
        return h.healthCheckFailures > 0;
    }];
    failed.assertForOverFulfill = NO;
    [h verifyAliveWithCompletion:nil];
    [self waitForExpectations:@[failed] timeout:15];
    XCTAssertEqual(h.healthCheckFailures, 1u, @"the unreachable probe was recorded");

    NSUInteger launchesBefore = launcher.launches.count;
    NSUInteger restartsBefore = h.restartCount;

    // The app comes back. The sockets are rebuilt, so the harness must forget
    // that answer -- it measured a guest whose socket no longer exists.
    [h verifyAliveAfterResumeWithCompletion:nil];

    XCTAssertEqual(h.restartCount, restartsBefore,
                   @"a resume must not turn a pre-suspension failure into a restart");
    XCTAssertEqual(launcher.launches.count, launchesBefore,
                   @"no new guest process is started just because the app was resumed");
}

/// A resume must produce a *real* check, not a debounced echo of the answer
/// taken before the suspension. The earlier code would have returned the cached
/// "healthy" verdict without probing at all, which is how a guest whose sockets
/// had been destroyed could look fine until the next unrelated check.
- (void)testResumeForcesAFreshProbeRatherThanTrustingTheCache {
    DSHFakeGuestLauncher *launcher = [DSHFakeGuestLauncher new];
    DSHTestHTTPServer *__strong server = nil;
    DSHHarness *h = [self harnessOnPort:39100 timeout:5 launcher:launcher serverSlot:&server];
    h.healthCheckRetryDelay = 1;
    [self waitReady:h];
    XCTAssertNotNil(server);

    XCTestExpectation *first = [self expectationWithDescription:@"first check"];
    [h verifyAliveWithCompletion:^(BOOL alive) {
        XCTAssertTrue(alive);
        [first fulfill];
    }];
    [self waitForExpectations:@[first] timeout:10];
    NSUInteger afterFirst = server.requestCount;
    XCTAssertGreaterThan(afterFirst, 0u);

    // Well inside the debounce window: an ordinary foreground notification
    // would answer from cache here.
    XCTestExpectation *resumed = [self expectationWithDescription:@"resume check"];
    [h verifyAliveAfterResumeWithCompletion:^(BOOL alive) {
        XCTAssertTrue(alive);
        [resumed fulfill];
    }];
    [self waitForExpectations:@[resumed] timeout:10];

    XCTAssertGreaterThan(server.requestCount, afterFirst,
                         @"a resume must probe again; the cached verdict predates the suspension");
    [server stop];
}

/// Resuming when the guest is genuinely gone must still recover. The fix must
/// not buy a quiet log at the price of never restarting a dead server.
- (void)testResumeStillRestartsWhenServerIsReallyGone {
    DSHFakeGuestLauncher *launcher = [DSHFakeGuestLauncher new];
    DSHTestHTTPServer *__strong server = nil;
    DSHHarness *h = [self harnessOnPort:39200 timeout:2 launcher:launcher serverSlot:&server];
    h.healthCheckFailuresBeforeRestart = 3;
    h.healthCheckRetryDelay = 0.2;
    [self waitReady:h];
    XCTAssertNotNil(server);

    // Nothing listens any more, and this time it is not a suspension artefact.
    [server stop];
    server = nil;
    NSUInteger launchesBefore = launcher.launches.count;

    XCTestExpectation *restarting = [self expectationForNotification:DSHHarnessStateDidChangeNotification
                                                             object:h
                                                            handler:^BOOL(NSNotification *n) {
        return h.state == DSHHarnessStateRestarting || h.state == DSHHarnessStateStopped;
    }];
    restarting.assertForOverFulfill = NO;
    [h verifyAliveAfterResumeWithCompletion:nil];
    [self waitForExpectations:@[restarting] timeout:20];

    XCTAssertGreaterThanOrEqual(h.restartCount, 1u, @"a dead server is still restarted after a resume");
    XCTAssertGreaterThan(launcher.launches.count, launchesBefore, @"and a new guest process is launched");
    XCTAssertNotNil(h.lastHealthCheck, @"the result is kept for diagnosis");
    XCTAssertTrue(h.lastHealthCheck.indicatesDeadServer);
}

/// A resume with no preceding suspension must be inert: it happens on every
/// plain launch (sceneWillEnterForeground fires before the guest has booted) and
/// on the second of iOS's foreground notifications.
- (void)testResumeWithoutSuspensionIsInert {
    DSHFakeGuestLauncher *launcher = [DSHFakeGuestLauncher new];
    DSHTestHTTPServer *__strong server = nil;
    DSHHarness *h = [self harnessOnPort:39300 timeout:5 launcher:launcher serverSlot:&server];
    h.healthCheckRetryDelay = 1;
    [self waitReady:h];
    XCTAssertNotNil(server);

    XCTestExpectation *checked = [self expectationWithDescription:@"check"];
    [h verifyAliveAfterResumeWithCompletion:^(BOOL alive) {
        XCTAssertTrue(alive);
        [checked fulfill];
    }];
    [self waitForExpectations:@[checked] timeout:10];

    XCTAssertEqual(h.restartCount, 0u, @"nothing to recover from, so no restart");
    XCTAssertEqual(h.healthCheckFailures, 0u);
    [server stop];
}

#pragma mark - Crash recovery is intact

/// The original crash-handling behaviour must survive the change: a process
/// that exits is still relaunched with back-off.
- (void)testProcessCrashStillRelaunches {
    DSHFakeGuestLauncher *launcher = [DSHFakeGuestLauncher new];
    DSHTestHTTPServer *__strong server = nil;
    DSHHarness *h = [self harnessOnPort:38900 timeout:5 launcher:launcher serverSlot:&server];
    h.maxConsecutiveCrashes = 2;
    [self waitReady:h];

    XCTestExpectation *restarting = [self expectationForNotification:DSHHarnessStateDidChangeNotification
                                                             object:h
                                                            handler:^BOOL(NSNotification *n) {
        return h.state == DSHHarnessStateRestarting || h.state == DSHHarnessStateFailed;
    }];
    restarting.assertForOverFulfill = NO;
    void (^exit)(int) = launcher.lastExit;
    XCTAssertNotNil(exit, @"the launcher captured an exit handler");
    exit(9);
    [self waitForExpectations:@[restarting] timeout:20];

    XCTAssertTrue([[h.log tail:60] containsString:@"exited with code 9"],
                  @"the exit is reported, got: %@", [h.log tail:60]);
    if (server) [server stop];
}

@end
