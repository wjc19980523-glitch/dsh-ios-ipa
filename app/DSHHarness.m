//
//  DSHHarness.m
//  DSH
//

#import "DSHHarness.h"
#import "DSHHarnessAuth.h"
#import "DSHPortAllocator.h"
#import "DSHReadinessProbe.h"
#import "DSHGuestLauncher.h"
#import "DSHStartupMetrics.h"

NSNotificationName const DSHHarnessStateDidChangeNotification = @"DSHHarnessStateDidChangeNotification";
static NSString *const kExpectedStartupKey = @"DSHExpectedStartupDuration";
// Only seeds the progress overlay's estimate before the first successful boot
// has been measured; -expectedStartupDuration replaces it with a smoothed real
// sample afterwards. dsh 0.2.x takes about three minutes on an emulated CPU,
// so the old 25s (a 0.1.x figure) made the bar sit at 100% for minutes.
static const NSTimeInterval kDefaultExpectedStartup = 180;
static NSString *const kRecentFailuresKey = @"DSHHarnessRecentFailures.1";
static const NSTimeInterval kPersistentFailureWindow = 10 * 60;
/// One resume produces several "we are foreground now" signals. Within this
/// window a fresh check adds nothing but load.
static const NSTimeInterval kHealthCheckDebounce = 2;

NSString *DSHHarnessStateName(DSHHarnessState state) {
    switch (state) {
        case DSHHarnessStateIdle: return @"idle";
        case DSHHarnessStateStarting: return @"starting";
        case DSHHarnessStateReady: return @"ready";
        case DSHHarnessStateRestarting: return @"restarting";
        case DSHHarnessStateFailed: return @"failed";
        case DSHHarnessStateStopped: return @"stopped";
    }
    return @"?";
}

@interface DSHHarness ()
@property (nonatomic) id<DSHGuestProcessLauncher> launcher;
@property (nonatomic, readwrite) DSHHarnessState state;
@property (nonatomic, readwrite) uint16_t port;
@property (nonatomic, readwrite) DSHLogBuffer *log;
@property (nonatomic, readwrite) NSUInteger restartCount;
@property (nonatomic, readwrite, nullable) NSString *lastError;
@property (nonatomic, readwrite) int guestPid;
@property (nonatomic, readwrite) NSTimeInterval lastStartupDuration;
@property (nonatomic) NSUInteger consecutiveCrashes;
@property (nonatomic) NSUInteger launchGeneration;
@property (nonatomic, nullable) DSHReadinessProbe *probe;
@property (nonatomic) BOOL userStopped;
@property (nonatomic) NSDate *lastLaunchAt;
@property (nonatomic) BOOL healthCheckInFlight;
@property (nonatomic) NSMutableArray<void (^)(BOOL)> *healthCheckCompletions;
@property (nonatomic) BOOL tracksPersistentFailures;
/// Consecutive failed health checks since the server last proved healthy.
@property (nonatomic, readwrite) NSUInteger healthCheckFailures;
/// Generation the pending health-check retry belongs to, so a restart or a new
/// launch cancels it instead of piling on.
@property (nonatomic) NSUInteger healthCheckRetryGeneration;
/// Last probe result, kept for the UI and for tests.
@property (nonatomic, readwrite, nullable) DSHProbeResult *lastHealthCheck;
/// When the last health check finished; used to coalesce the several
/// foreground notifications iOS delivers for one resume.
@property (nonatomic) NSDate *lastHealthCheckAt;
/// Launch token of the current server process, captured from the `dsh web:`
/// announcement. Regenerated on every (re)start, never logged.
@property (nonatomic, readwrite, nullable) NSString *launchToken;
/// Bumped whenever a new token is captured. The web view keeps the generation
/// it last authenticated with so a restart is detectable.
@property (nonatomic, readwrite) NSUInteger authenticationGeneration;
/// Whether the current launch is waiting for its authenticated URL before the
/// readiness poll may be trusted to report success.
@property (nonatomic) BOOL awaitingAuthentication;
/// Generation of the launch whose token we are waiting for, so a token printed
/// by a process that has already been replaced is discarded.
@property (nonatomic) NSUInteger tokenGeneration;

- (void)runHealthCheck;
- (void)finishHealthCheckWithResult:(nullable DSHProbeResult *)result completionsSucceeded:(BOOL)succeeded;
/// Shared body of the two public entry points; see DSHHarness.h for what
/// `trustCachedAnswer` means.
- (void)verifyAliveWithCachedAnswer:(BOOL)trustCachedAnswer completion:(void (^)(BOOL))completion;
@end

@implementation DSHHarness

+ (instancetype)shared {
    static DSHHarness *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[DSHHarness alloc] initWithLauncher:[DSHGuestLauncher new]];
    });
    return shared;
}

- (instancetype)initWithLauncher:(id<DSHGuestProcessLauncher>)launcher {
    if (self = [super init]) {
        _launcher = launcher;
        _log = [[DSHLogBuffer alloc] initPersistentWithCapacity:1000];
        _serverExecutable = @"/usr/local/bin/dsh-serve";
        _extraEnvironment = @{};
        _preferredPort = 3080;
        // Budget for the whole guest boot, not for one request: the probe fails
        // only when its wall clock exceeds this (see -[DSHReadinessProbe tick]);
        // each individual request is capped at 3s.
        //
        // dsh 0.2.x needs far more time than 0.1.x did. The older image booted
        // and served in ~30s on an emulated CPU, so 240s looked generous. The
        // 0.2.x image scans 289 @deepseek-ai packages (71 of them client
        // packages) and composes the web plugin graph before it binds, which
        // costs roughly 180s on the CI runner -- and a real iPad is slower than
        // that runner, not faster. 240s left about 25% headroom and would have
        // reported a healthy but slow guest as dead, killing it and restarting
        // in a loop. 600s keeps the failure mode (a genuinely hung guest) while
        // removing the false one.
        _startupTimeout = 600;
        _maxConsecutiveCrashes = 4;
        // The guest boots in about three minutes on a real iPad under dsh
        // 0.2.x (see _startupTimeout above; it was ~40s under 0.1.x).
        // Immediately afterwards the emulated CPU is cold and the JIT is still
        // warming, so a 5-second budget for a single HEAD was optimistic enough
        // to be wrong: it reported healthy servers dead and rebooted a working
        // guest in a loop.
        _healthCheckTimeout = 15;
        _healthCheckFailuresBeforeRestart = 3;
        _healthCheckRetryDelay = 2;
        _state = DSHHarnessStateIdle;
        _healthCheckCompletions = [NSMutableArray array];
        _tracksPersistentFailures = [launcher isKindOfClass:DSHGuestLauncher.class];
    }
    return self;
}

- (NSTimeInterval)expectedStartupDuration {
    double stored = [NSUserDefaults.standardUserDefaults doubleForKey:kExpectedStartupKey];
    return stored > 1 ? stored : kDefaultExpectedStartup;
}

- (NSDate *)launchStartedAt {
    return self.state == DSHHarnessStateStarting ? self.lastLaunchAt : nil;
}

- (NSURL *)baseURL {
    if (self.port == 0)
        return nil;
    return [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%u/", self.port]];
}

- (NSURL *)authenticatedEntryURL {
    return [DSHHarnessAuth authenticatedEntryURLWithBaseURL:self.baseURL token:self.launchToken];
}

- (BOOL)authenticationReady {
    return self.authenticatedEntryURL != nil;
}

- (BOOL)ownsURL:(NSURL *)url {
    return [DSHHarnessAuth url:url sharesAuthorityWith:self.baseURL];
}

- (BOOL)noteAuthenticationFailureForURL:(NSURL *)url {
    if (self.launchToken.length == 0) {
        [self.log append:@"[dsh-ios] the server asked for authentication but has not announced a token yet"];
        return NO;
    }
    // The cookie is authority-bound and is accepted again after a restart on
    // the same port, so a 401 usually means the page was loaded from a stale
    // entry URL (an old token) or the web content process was reused across a
    // restart. Either way the fix is the same: go through the current entry
    // URL again.
    self.authenticationGeneration++;
    [self.log append:[NSString stringWithFormat:@"[dsh-ios] re-authenticating: the server refused this page (token %@)",
                      self.launchToken.length ? @"present" : @"absent"]];
    return YES;
}

/// Captures the launch token out of a server log line. Split out so the log
/// handler stays readable, and so the token is never part of what is stored.
///
/// Returns the line, redacted if it carried the credential, for the caller to
/// pass to the log buffer.
- (NSString *)handleServerLine:(NSString *)line generation:(NSUInteger)generation {
    if (![DSHHarnessAuth isServeAnnouncementLine:line])
        return line;

    NSString *token = [DSHHarnessAuth tokenFromServeLogLine:line];
    // A fake launcher emits this synchronously, so it can arrive while `launch`
    // is still on the stack with the generation not yet published; the real
    // launcher is asynchronous but the ordering must not matter either way.
    // The token therefore belongs to the launch in progress whenever one is in
    // progress, and is recorded against the current generation so the bookkeeping
    // stays consistent with what a later stale-line guard will compare to.
    BOOL forCurrentLaunch = self.awaitingAuthentication || generation == self.launchGeneration;
    if (token.length > 0 && forCurrentLaunch &&
        ![DSHHarnessAuth token:self.launchToken isEqualToToken:token]) {
        self.launchToken = token;
        self.authenticationGeneration++;
        self.tokenGeneration = self.launchGeneration;
        if (self.awaitingAuthentication) {
            [DSHStartupMetrics.shared mark:@"auth_token"];
            self.awaitingAuthentication = NO;
            [self startReadinessPoll];
        }
        [self.log append:[NSString stringWithFormat:@"[dsh-ios] harness announced its web URL on port %u; authentication token captured",
                          self.port]];
    }
    // Never let the credential reach the ring buffer, the on-disk launch log,
    // or a diagnostics report that the user might share.
    return [DSHHarnessAuth redactingTokenInLine:line];
}

- (void)ingestServerLineForTesting:(NSString *)line {
    [self.log append:[self handleServerLine:line generation:self.launchGeneration]];
}

- (void)setState:(DSHHarnessState)state {
    if (_state == state)
        return;
    _state = state;
    [self.log append:[NSString stringWithFormat:@"[dsh-ios] state -> %@", DSHHarnessStateName(state)]];
    [NSNotificationCenter.defaultCenter postNotificationName:DSHHarnessStateDidChangeNotification object:self];
}

#pragma mark - Control

- (void)start {
    NSAssert(NSThread.isMainThread, @"start on main");
    self.userStopped = NO;
    if (self.state == DSHHarnessStateStarting || self.state == DSHHarnessStateReady)
        return;
    if (self.recentPersistentFailureCount >= self.maxConsecutiveCrashes) {
        self.lastError = @"The harness failed repeatedly across recent launches. Use Restart Harness to try again, or Repair Linux Environment if it continues.";
        [self.log append:@"[dsh-ios] persistent crash-loop fuse is open"];
        self.state = DSHHarnessStateFailed;
        return;
    }
    self.consecutiveCrashes = 0;
    [self launch];
}

- (void)stop {
    NSAssert(NSThread.isMainThread, @"stop on main");
    self.userStopped = YES;
    self.launchGeneration++;
    self.healthCheckRetryGeneration++;
    [self.probe cancel];
    self.probe = nil;
    self.healthCheckInFlight = NO;
    self.healthCheckFailures = 0;
    // The token belongs to the process being torn down. Keeping it would let
    // the UI replay a URL that is about to start returning 401.
    self.launchToken = nil;
    self.awaitingAuthentication = NO;
    // Anyone waiting on a check that will now never run must be told.
    NSArray<void (^)(BOOL)> *completions = [self.healthCheckCompletions copy];
    [self.healthCheckCompletions removeAllObjects];
    for (void (^callback)(BOOL) in completions)
        callback(NO);
    if (self.guestPid > 0) {
        [self.launcher killProcess:self.guestPid signal:SIGTERM];
        self.guestPid = 0;
    }
    self.state = DSHHarnessStateStopped;
}

- (void)restart {
    NSAssert(NSThread.isMainThread, @"restart on main");
    [self.log append:@"[dsh-ios] restart requested"];
    [self stop];
    self.userStopped = NO;
    self.consecutiveCrashes = 0;
    [self clearPersistentFailures];
    self.restartCount++;
    // Give the old process a moment to release the port.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t) (0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!self.userStopped)
            [self launch];
    });
}

- (void)launch {
    self.launchGeneration++;
    self.healthCheckRetryGeneration++;
    self.healthCheckInFlight = NO;
    self.healthCheckFailures = 0;
    NSUInteger generation = self.launchGeneration;

    // Keep the previous port if it is still free so a restart lands on the
    // same URL; otherwise pick a fresh one.
    uint16_t port = self.port;
    if (port == 0 || ![DSHPortAllocator isLoopbackPortFree:port])
        port = [DSHPortAllocator freeLoopbackPortStartingAt:self.preferredPort span:20];
    if (port == 0) {
        self.lastError = @"No free loopback port between 3080 and 3099.";
        [self.log append:[@"[dsh-ios] " stringByAppendingString:self.lastError]];
        self.state = DSHHarnessStateFailed;
        return;
    }
    self.port = port;
    self.lastError = nil;
    self.lastLaunchAt = NSDate.date;
    // A restart mints a new token, and the old one is dead the moment the old
    // process exits. Clearing it here is what makes the app re-authenticate
    // instead of replaying a URL that now returns 401.
    self.launchToken = nil;
    self.awaitingAuthentication = YES;
    self.state = DSHHarnessStateStarting;

    NSMutableDictionary *env = [self.extraEnvironment mutableCopy];
    env[@"DSH_PORT"] = [NSString stringWithFormat:@"%u", port];
    [self.log append:[NSString stringWithFormat:@"[dsh-ios] launching %@ on port %u", self.serverExecutable, port]];

    __weak typeof(self) weakSelf = self;
    int pid = [self.launcher launchExecutable:self.serverExecutable
                                    arguments:@[]
                                  environment:env
                                         line:^(NSString *line, BOOL isStdErr) {
        typeof(self) self = weakSelf;
        if (self == nil)
            return;
        // The token is captured here and stripped from the line before it can
        // reach any durable store.
        [self.log append:[self handleServerLine:line generation:generation]];
    } exit:^(int exitCode) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf processExitedWithCode:exitCode generation:generation];
        });
    }];
    if (pid < 0) {
        self.lastError = [NSString stringWithFormat:@"Could not start %@ (error %d).", self.serverExecutable, pid];
        [self.log append:[@"[dsh-ios] " stringByAppendingString:self.lastError]];
        self.guestPid = 0;
        self.awaitingAuthentication = NO;
        [self scheduleRelaunchAfterFailure];
        return;
    }
    self.guestPid = pid;
    [self.log append:[NSString stringWithFormat:@"[dsh-ios] guest pid %d", pid]];

    // One supervisor for the whole boot. It only reports success once the
    // server has both announced its token and served the authenticated entry
    // URL; the poll itself is started by -startReadinessPoll when the token
    // arrives, and by the deadline below if it never does.
    [self armStartupDeadlineForGeneration:generation];
}

/// There is no readiness poll until there is an authenticated URL to poll.
/// Waiting for the token first is not an optimisation: the bare origin answers
/// 401 under dsh 0.2.x, so polling it would either spin for the whole boot
/// budget or -- with the old `< 500` classification -- declare the app ready
/// the instant the server started refusing, and the web view would then load a
/// 401 body and stay there.
- (void)startReadinessPoll {
    NSAssert(NSThread.isMainThread, @"poll on main");
    NSURL *url = self.authenticatedEntryURL;
    if (url == nil || self.state != DSHHarnessStateStarting || self.probe != nil)
        return;

    NSUInteger generation = self.launchGeneration;
    NSTimeInterval remaining = self.startupTimeout - -self.lastLaunchAt.timeIntervalSinceNow;
    if (remaining <= 0) {
        [self startupTimedOutForGeneration:generation];
        return;
    }

    __weak typeof(self) weakSelf = self;
    // A shorter interval trims up to 250 ms from the visible startup tail
    // without adding meaningful work during the multi-minute guest boot.
    self.probe = [[DSHReadinessProbe alloc] initWithURL:url interval:0.25 timeout:remaining];
    [self.probe startWithHandler:^(BOOL ready, NSTimeInterval elapsed) {
        typeof(self) self = weakSelf;
        if (self == nil || generation != self.launchGeneration)
            return;
        if (ready) {
            self.lastStartupDuration = elapsed;
            // Smooth the estimate for next time (EMA, weight on the new sample).
            double prev = [NSUserDefaults.standardUserDefaults doubleForKey:kExpectedStartupKey];
            double next = prev > 1 ? prev * 0.5 + elapsed * 0.5 : elapsed;
            [NSUserDefaults.standardUserDefaults setDouble:next forKey:kExpectedStartupKey];
            self.consecutiveCrashes = 0;
            [self clearPersistentFailures];
            [self.log append:[NSString stringWithFormat:@"[dsh-ios] server answered after %.1fs", elapsed]];
            [DSHStartupMetrics.shared mark:@"harness_ready"];
            self.state = DSHHarnessStateReady;
        } else if (self.state == DSHHarnessStateStarting) {
            [self startupTimedOutForGeneration:generation];
        }
    }];
}

/// If the server never announces a token there is nothing to poll, and the
/// launch must still fail on schedule rather than waiting forever. Under dsh
/// 0.2.x that is a real failure mode worth naming precisely, because it is not
/// a timeout -- the process is up but never came far enough to bind.
- (void)armStartupDeadlineForGeneration:(NSUInteger)generation {
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t) (self.startupTimeout * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        typeof(self) self = weakSelf;
        if (self == nil || generation != self.launchGeneration)
            return;
        if (self.awaitingAuthentication && self.state == DSHHarnessStateStarting) {
            self.lastError = [NSString stringWithFormat:
                              @"The harness did not announce its web URL within %.0f seconds.", self.startupTimeout];
            [self.log append:[@"[dsh-ios] " stringByAppendingString:self.lastError]];
            [self startupTimedOutForGeneration:generation];
        }
    });
}

- (void)startupTimedOutForGeneration:(NSUInteger)generation {
    if (generation != self.launchGeneration || self.state != DSHHarnessStateStarting)
        return;
    self.awaitingAuthentication = NO;
    self.lastError = [NSString stringWithFormat:@"The harness did not answer within %.0f seconds.", self.startupTimeout];
    [self.log append:[@"[dsh-ios] " stringByAppendingString:self.lastError]];
    self.launchGeneration++;   // the kill below must not count as a second failure
    [self.probe cancel];
    self.probe = nil;
    if (self.guestPid > 0)
        [self.launcher killProcess:self.guestPid signal:SIGKILL];
    self.guestPid = 0;
    [self scheduleRelaunchAfterFailure];
}

- (void)processExitedWithCode:(int)exitCode generation:(NSUInteger)generation {
    if (generation != self.launchGeneration)
        return; // an older incarnation; already superseded
    self.guestPid = 0;
    // Retire this launch before cancelling its probe so the probe's handler
    // does not count the same death as a startup timeout too.
    self.launchGeneration++;
    [self.probe cancel];
    self.probe = nil;
    if (self.userStopped) {
        self.state = DSHHarnessStateStopped;
        return;
    }
    self.lastError = [NSString stringWithFormat:@"dsh-serve exited with code %d.", exitCode];
    [self.log append:[@"[dsh-ios] " stringByAppendingString:self.lastError]];
    // A long-lived server that dies is a fresh incident, not a crash loop.
    if (-self.lastLaunchAt.timeIntervalSinceNow > 120)
        self.consecutiveCrashes = 0;
    [self scheduleRelaunchAfterFailure];
}

- (void)scheduleRelaunchAfterFailure {
    self.consecutiveCrashes++;
    [self recordPersistentFailure];
    if (self.consecutiveCrashes > self.maxConsecutiveCrashes) {
        [self.log append:@"[dsh-ios] giving up after repeated failures"];
        self.state = DSHHarnessStateFailed;
        return;
    }
    NSTimeInterval delay = MIN(pow(2, (double) (self.consecutiveCrashes - 1)), 30);
    [self.log append:[NSString stringWithFormat:@"[dsh-ios] relaunching in %.0fs (attempt %lu/%lu)", delay,
                      (unsigned long) self.consecutiveCrashes, (unsigned long) self.maxConsecutiveCrashes]];
    self.state = DSHHarnessStateRestarting;
    self.restartCount++;
    NSUInteger generation = self.launchGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t) (delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.userStopped || generation != self.launchGeneration)
            return;
        [self launch];
    });
}

- (NSArray<NSDate *> *)recentPersistentFailures {
    if (!self.tracksPersistentFailures) return @[];
    NSArray *raw = [NSUserDefaults.standardUserDefaults arrayForKey:kRecentFailuresKey] ?: @[];
    NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-kPersistentFailureWindow];
    return [raw filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id value, NSDictionary *bindings) {
        return [value isKindOfClass:NSDate.class] && [value compare:cutoff] != NSOrderedAscending;
    }]];
}

- (NSUInteger)recentPersistentFailureCount {
    return self.recentPersistentFailures.count;
}

- (void)recordPersistentFailure {
    if (!self.tracksPersistentFailures) return;
    NSMutableArray *failures = [self.recentPersistentFailures mutableCopy];
    [failures addObject:NSDate.date];
    [NSUserDefaults.standardUserDefaults setObject:failures forKey:kRecentFailuresKey];
}

- (void)clearPersistentFailures {
    if (self.tracksPersistentFailures)
        [NSUserDefaults.standardUserDefaults removeObjectForKey:kRecentFailuresKey];
}

- (void)verifyAliveWithCompletion:(void (^)(BOOL))completion {
    [self verifyAliveWithCachedAnswer:YES completion:completion];
}

- (void)verifyAliveAfterResumeWithCompletion:(void (^)(BOOL))completion {
    [self verifyAliveWithCachedAnswer:NO completion:completion];
}

- (void)verifyAliveWithCachedAnswer:(BOOL)trustCachedAnswer completion:(void (^)(BOOL))completion {
    // A bare origin is not enough to answer "is the UI usable?": dsh 0.2.x
    // answers 401 there. Requiring the authenticated URL means a caller is
    // told "not ready" while the app is still waiting for the token, instead
    // of being told "alive" about a page that cannot load.
    if (self.state != DSHHarnessStateReady || self.authenticatedEntryURL == nil) {
        if (completion) completion(NO);
        return;
    }
    if (!trustCachedAnswer) {
        // A resume invalidates the previous answer: it described sockets that
        // iOS had already deregistered. In particular a "connection refused"
        // recorded just before suspension must not count towards the failure
        // ladder now, or one background cycle could restart a healthy guest.
        // Clearing the in-flight flag too, since the caller is asking for a
        // check that is known to be actionable; any probe still outstanding
        // reports into a generation that no longer matches and is dropped.
        self.healthCheckFailures = 0;
        self.healthCheckInFlight = NO;
        [self.healthCheckCompletions removeAllObjects];
    } else if (self.lastHealthCheckAt != nil &&
               self.healthCheckFailures == 0 &&
               -self.lastHealthCheckAt.timeIntervalSinceNow < kHealthCheckDebounce) {
        // Both UIApplicationDelegate and UISceneDelegate report foregrounding,
        // and the web view's error path adds a third caller. Coalesce them so
        // one resume cannot race several probes into several restarts, and so a
        // probe that already ran a moment ago is not repeated while its answer
        // is still valid: iOS delivers willEnterForeground and
        // sceneDidBecomeActive within milliseconds of each other, and the
        // second one used to start a fresh 5-second countdown against a server
        // the first one had just confirmed.
        if (completion) completion(YES);
        return;
    }
    if (completion)
        [self.healthCheckCompletions addObject:[completion copy]];
    if (self.healthCheckInFlight)
        return;
    self.healthCheckInFlight = YES;
    [self runHealthCheck];
}

- (void)runHealthCheck {
    NSUInteger generation = self.launchGeneration;
    NSUInteger retryGeneration = self.healthCheckRetryGeneration;
    // Probe the authenticated entry URL, not the bare origin: under dsh 0.2.x
    // the origin answers 401 to everything, so a check aimed there can only
    // ever prove that a listener exists -- never that the UI is usable, which
    // is the question the health check is actually asked.
    NSURL *url = self.authenticatedEntryURL ?: self.baseURL;
    if (url == nil) {
        [self finishHealthCheckWithResult:nil completionsSucceeded:NO];
        return;
    }
    __weak typeof(self) weakSelf = self;
    [DSHReadinessProbe checkURL:url timeout:self.healthCheckTimeout completion:^(DSHProbeResult *result) {
        typeof(self) self = weakSelf;
        if (self == nil)
            return;
        // A restart, a stop, or a fresh launch invalidates this answer.
        if (generation != self.launchGeneration || retryGeneration != self.healthCheckRetryGeneration) {
            [self finishHealthCheckWithResult:result completionsSucceeded:NO];
            return;
        }
        self.lastHealthCheck = result;
        self.lastHealthCheckAt = NSDate.date;
        [self.log append:[NSString stringWithFormat:@"[dsh-ios] health check: %@", result.summary]];

        // A 401 is neither "the UI is up" nor "the server is gone": the
        // listener answered, so the process is healthy, but it is withholding
        // the interface. Retrying on the failure ladder would restart a
        // working guest after three tries; reporting success would let a page
        // that cannot load count as loaded. Re-authenticating is the only
        // correct response, and it costs one navigation.
        if (result.requiresAuthentication && [self noteAuthenticationFailureForURL:url]) {
            // Answer the caller honestly: the UI is not usable until the web
            // view has been back through the entry URL.
            [self finishHealthCheckWithResult:result completionsSucceeded:NO];
            return;
        }

        if (result.alive) {
            self.healthCheckFailures = 0;
            [self finishHealthCheckWithResult:result completionsSucceeded:YES];
            return;
        }

        self.healthCheckFailures++;
        NSUInteger failures = self.healthCheckFailures;

        // A refused connection or a 5xx proves nothing is serving; waiting for
        // two more failures would only delay recovery.
        BOOL conclusive = result.indicatesDeadServer;
        if (conclusive || failures >= self.healthCheckFailuresBeforeRestart) {
            [self.log append:[NSString stringWithFormat:@"[dsh-ios] health check failed %lu time(s) (%@); restarting server",
                              (unsigned long) failures, conclusive ? @"server unreachable" : @"repeated timeouts"]];
            [self finishHealthCheckWithResult:result completionsSucceeded:NO];
            [self restart];
            return;
        }

        [self.log append:[NSString stringWithFormat:@"[dsh-ios] health check failed (%@); retrying in %.1fs (attempt %lu/%lu)",
                          result.summary, self.healthCheckRetryDelay,
                          (unsigned long) failures, (unsigned long) self.healthCheckFailuresBeforeRestart]];
        NSUInteger retryFor = retryGeneration;
        NSUInteger launchFor = generation;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t) (self.healthCheckRetryDelay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (self == nil || self.userStopped) return;
            if (launchFor != self.launchGeneration) return;
            if (retryFor != self.healthCheckRetryGeneration) return;
            if (self.state != DSHHarnessStateReady) return;
            if (!self.healthCheckInFlight) return;
            [self runHealthCheck];
        });
    }];
}

/// Delivers the pending completions and clears the in-flight flag. Kept in one
/// place so every exit path from a health check releases the coalescing lock;
/// leaving it set would silently disable all future checks.
- (void)finishHealthCheckWithResult:(nullable DSHProbeResult *)result completionsSucceeded:(BOOL)succeeded {
    self.healthCheckInFlight = NO;
    NSArray<void (^)(BOOL)> *completions = [self.healthCheckCompletions copy];
    [self.healthCheckCompletions removeAllObjects];
    for (void (^callback)(BOOL) in completions)
        callback(succeeded);
}

@end
