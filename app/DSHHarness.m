//
//  DSHHarness.m
//  DSH
//

#import "DSHHarness.h"
#import "DSHActivityLog.h"
#import "DSHHarnessAuth.h"
#import "DSHPortAllocator.h"
#import "DSHReadinessProbe.h"
#import "DSHGuestLauncher.h"
#import "DSHStartupMetrics.h"
#import "DSHGuestSessionLifecycle.h"
#import "DSHLifecycleDiagnostics.h"

// Both exported to match DSHHarness.h: DSHTests reads the state name and
// observes the notification through the app's own symbol, not a copy.
DSH_EXPORTED NSNotificationName const DSHHarnessStateDidChangeNotification = @"DSHHarnessStateDidChangeNotification";
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

/// Callbacks and cancellation belong to this one foreground check, including
/// its bounded retries. An old request can never finish a replacement check.
@interface DSHHealthOperation : NSObject
@property (nonatomic) NSUInteger requestID;
@property (nonatomic) NSUInteger launchGeneration;
@property (nonatomic) NSUInteger lifecycleGeneration;
@property (nonatomic) NSUInteger attemptID;
@property (nonatomic) NSUInteger failures;
@property (nonatomic) BOOL recoveringFromResume;
@property (nonatomic) NSMutableArray<void (^)(BOOL)> *completions;
@property (nonatomic, nullable) id<DSHProbeRequest> request;
@end

@implementation DSHHealthOperation
@end

DSH_EXPORTED NSString *DSHHarnessStateName(DSHHarnessState state) {
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
@property (nonatomic, copy) DSHHealthProbeFactory healthProbeFactory;
@property (nonatomic, copy) DSHHarnessScheduler scheduler;
@property (nonatomic, copy) DSHHarnessClock clock;
@property (nonatomic, nullable) DSHHealthOperation *healthOperation;
@property (nonatomic) NSUInteger nextHealthRequestID;
@property (nonatomic) NSUInteger lifecycleGeneration;
@property (nonatomic) BOOL appBackgrounded;
@property (nonatomic) BOOL resumeCheckStarted;
@property (nonatomic) BOOL recoveryCheckPending;
@property (nonatomic) NSUInteger startupSupervisorGeneration;
@property (nonatomic) NSTimeInterval startupElapsedBeforePause;
@property (nonatomic) NSTimeInterval startupActiveStartedAt;
@property (nonatomic) BOOL relaunchPending;
@property (nonatomic) NSUInteger relaunchGeneration;
@property (nonatomic) NSTimeInterval relaunchDelay;
@property (nonatomic) BOOL tracksPersistentFailures;
/// Consecutive failed health checks since the server last proved healthy.
@property (nonatomic, readwrite) NSUInteger healthCheckFailures;
/// Last probe result, kept for the UI and for tests.
@property (nonatomic, readwrite, nullable) DSHProbeResult *lastHealthCheck;
/// When the last health check finished; used to coalesce the several
/// foreground notifications iOS delivers for one resume.
@property (nonatomic) NSTimeInterval lastHealthCheckAt;
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

- (void)runHealthCheck:(DSHHealthOperation *)operation;
- (void)finishHealthCheck:(DSHHealthOperation *)operation succeeded:(BOOL)succeeded;
- (void)invalidateHealthCheckDeliveringFailure:(BOOL)deliver;
- (void)schedulePendingRelaunch;
- (NSTimeInterval)remainingStartupBudget;
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
    return [self initWithLauncher:launcher healthProbeFactory:^id<DSHProbeRequest>(NSURL *url, NSTimeInterval timeout, void (^completion)(DSHProbeResult *)) {
        return [DSHReadinessProbe requestURL:url timeout:timeout completion:completion];
    } scheduler:^(NSTimeInterval delay, dispatch_block_t action) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAX(0, delay) * NSEC_PER_SEC)), dispatch_get_main_queue(), action);
    } clock:^NSTimeInterval { return NSProcessInfo.processInfo.systemUptime; }];
}

- (instancetype)initWithLauncher:(id<DSHGuestProcessLauncher>)launcher
              healthProbeFactory:(DSHHealthProbeFactory)factory
                       scheduler:(DSHHarnessScheduler)scheduler
                           clock:(DSHHarnessClock)clock {
    if (self = [super init]) {
        _launcher = launcher;
        _healthProbeFactory = [factory copy];
        _scheduler = [scheduler copy];
        _clock = [clock copy];
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
        // warming, so a 5-second budget for a single GET was optimistic enough
        // to be wrong: it reported healthy servers dead and rebooted a working
        // guest in a loop.
        _healthCheckTimeout = 15;
        _healthCheckFailuresBeforeRestart = 3;
        _healthCheckRetryDelay = 2;
        _state = DSHHarnessStateIdle;
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
    BOOL forCurrentLaunch = generation == self.launchGeneration;
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
    if (self.appBackgrounded) {
        self.relaunchPending = YES;
        self.relaunchDelay = 0;
        return;
    }
    [self launch];
}

- (void)stop {
    NSAssert(NSThread.isMainThread, @"stop on main");
    [DSHActivityLog.shared markUnconfirmedGuestTasksUnknown];
    self.userStopped = YES;
    self.launchGeneration++;
    self.startupSupervisorGeneration++;
    self.relaunchGeneration++;
    self.relaunchPending = NO;
    [self invalidateHealthCheckDeliveringFailure:YES];
    [self.probe cancel];
    self.probe = nil;
    self.healthCheckFailures = 0;
    // The token belongs to the process being torn down. Keeping it would let
    // the UI replay a URL that is about to start returning 401.
    self.launchToken = nil;
    self.awaitingAuthentication = NO;
    if (self.guestPid > 0) {
        if ([self.extraEnvironment[@"DSH_SESSION_LIFECYCLE"] isEqual:@"1"])
            [DSHGuestSessionLifecycle.shared cancelPendingTransition];
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
    self.relaunchPending = YES;
    self.relaunchDelay = 0.5;
    [self schedulePendingRelaunch];
}

- (void)launch {
    if (self.appBackgrounded || self.userStopped) return;
    self.launchGeneration++;
    self.startupSupervisorGeneration++;
    self.relaunchGeneration++;
    self.relaunchPending = NO;
    [self invalidateHealthCheckDeliveringFailure:YES];
    self.healthCheckFailures = 0;
    self.lastHealthCheckAt = 0;
    self.lastHealthCheck = nil;
    self.startupElapsedBeforePause = 0;
    self.startupActiveStartedAt = self.clock();
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
    BOOL sessionManaged = [env[@"DSH_SESSION_LIFECYCLE"] isEqual:@"1"];
    __block int launchedPID = 0;
    __block uint64_t sessionGuestIdentity = 0;
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
            // Only the real exit callback can report death. Stop/timeout can
            // retire a launch before it has released its native descriptors.
            if (sessionManaged) [DSHGuestSessionLifecycle.shared managedGuestDidExit:launchedPID identity:sessionGuestIdentity];
            [weakSelf processExitedWithCode:exitCode generation:generation];
        });
    }];
    launchedPID = pid;
    if (pid < 0) {
        self.lastError = [NSString stringWithFormat:@"Could not start %@ (error %d).", self.serverExecutable, pid];
        [self.log append:[@"[dsh-ios] " stringByAppendingString:self.lastError]];
        self.guestPid = 0;
        self.awaitingAuthentication = NO;
        [self scheduleRelaunchAfterFailure];
        return;
    }
    self.guestPid = pid;
    if (sessionManaged)
        sessionGuestIdentity = [DSHGuestSessionLifecycle.shared managedGuestDidLaunch:pid];
    [DSHLifecycleDiagnostics recordEvent:@"guestStarted" harness:self];
    [self.log append:[NSString stringWithFormat:@"[dsh-ios] guest pid %d", pid]];

    // One supervisor for the whole boot. It only reports success once the
    // server has both announced its token and served the authenticated entry
    // URL; the poll itself is started by -startReadinessPoll when the token
    // arrives, and by the deadline below if it never does.
    [self armStartupDeadlineForGeneration:generation];
}

#pragma mark - Foreground-only supervision

- (void)handleAppBackground {
    NSAssert(NSThread.isMainThread, @"background on main");
    if (self.appBackgrounded) return;
    if (self.state == DSHHarnessStateStarting)
        self.startupElapsedBeforePause += MAX(0, self.clock() - self.startupActiveStartedAt);
    self.appBackgrounded = YES;
    self.lifecycleGeneration++;
    self.startupSupervisorGeneration++;
    self.relaunchGeneration++;
    self.resumeCheckStarted = NO;
    self.recoveryCheckPending = YES;
    self.lastHealthCheckAt = 0;
    self.healthCheckFailures = 0;
    // These callers belong to the page/lifecycle we just left. A cancellation
    // must not mark the still-loaded page as broken or finish a later check.
    [self invalidateHealthCheckDeliveringFailure:NO];
    [self.probe cancel];
    self.probe = nil;
    [self.log append:@"[dsh-ios] lifecycle: foreground supervision paused"];
}

- (void)handleAppResume {
    NSAssert(NSThread.isMainThread, @"resume on main");
    if (!self.appBackgrounded) return;
    self.appBackgrounded = NO;
    self.startupSupervisorGeneration++;
    self.startupActiveStartedAt = self.clock();
    [self.log append:@"[dsh-ios] lifecycle: foreground supervision resumed"];
    if (self.relaunchPending && !self.userStopped) {
        [self schedulePendingRelaunch];
    } else if (self.state == DSHHarnessStateStarting) {
        [self armStartupDeadlineForGeneration:self.launchGeneration];
        [self startReadinessPoll];
    } else if (self.state == DSHHarnessStateReady) {
        [self verifyAliveAfterResumeWithCompletion:nil];
    }
}

- (NSTimeInterval)remainingStartupBudget {
    NSTimeInterval elapsed = self.startupElapsedBeforePause;
    if (!self.appBackgrounded) elapsed += MAX(0, self.clock() - self.startupActiveStartedAt);
    return self.startupTimeout - elapsed;
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
    if (self.appBackgrounded || url == nil || self.state != DSHHarnessStateStarting || self.probe != nil)
        return;

    NSUInteger generation = self.launchGeneration;
    NSUInteger supervisorGeneration = self.startupSupervisorGeneration;
    NSTimeInterval remaining = [self remainingStartupBudget];
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
        if (self == nil || generation != self.launchGeneration ||
            supervisorGeneration != self.startupSupervisorGeneration || self.appBackgrounded)
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
    if (self.appBackgrounded) return;
    NSTimeInterval remaining = MAX(0, [self remainingStartupBudget]);
    NSUInteger supervisorGeneration = self.startupSupervisorGeneration;
    __weak typeof(self) weakSelf = self;
    self.scheduler(remaining, ^{
        typeof(self) self = weakSelf;
        if (self == nil || generation != self.launchGeneration ||
            supervisorGeneration != self.startupSupervisorGeneration || self.appBackgrounded)
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
    if (self.appBackgrounded || generation != self.launchGeneration || self.state != DSHHarnessStateStarting)
        return;
    self.awaitingAuthentication = NO;
    self.lastError = [NSString stringWithFormat:@"The harness did not answer within %.0f seconds.", self.startupTimeout];
    [self.log append:[@"[dsh-ios] " stringByAppendingString:self.lastError]];
    self.launchGeneration++;   // the kill below must not count as a second failure
    self.startupSupervisorGeneration++;
    [self invalidateHealthCheckDeliveringFailure:YES];
    [self.probe cancel];
    self.probe = nil;
    if (self.guestPid > 0) {
        if ([self.extraEnvironment[@"DSH_SESSION_LIFECYCLE"] isEqual:@"1"])
            [DSHGuestSessionLifecycle.shared cancelPendingTransition];
        [self.launcher killProcess:self.guestPid signal:SIGKILL];
    }
    self.guestPid = 0;
    [self scheduleRelaunchAfterFailure];
}

- (void)processExitedWithCode:(int)exitCode generation:(NSUInteger)generation {
    if (generation != self.launchGeneration)
        return; // an older incarnation; already superseded
    [DSHActivityLog.shared markUnconfirmedGuestTasksUnknown];
    [DSHLifecycleDiagnostics recordEvent:@"guestExited" harness:self];
    self.guestPid = 0;
    // Retire this launch before cancelling its probe so the probe's handler
    // does not count the same death as a startup timeout too.
    self.launchGeneration++;
    self.startupSupervisorGeneration++;
    [self invalidateHealthCheckDeliveringFailure:YES];
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
        [DSHLifecycleDiagnostics recordEvent:@"healthRestartLimit" harness:self];
        [self.log append:@"[dsh-ios] giving up after repeated failures"];
        self.state = DSHHarnessStateFailed;
        return;
    }
    NSTimeInterval delay = MIN(pow(2, (double) (self.consecutiveCrashes - 1)), 30);
    [self.log append:[NSString stringWithFormat:@"[dsh-ios] relaunching in %.0fs (attempt %lu/%lu)", delay,
                      (unsigned long) self.consecutiveCrashes, (unsigned long) self.maxConsecutiveCrashes]];
    self.state = DSHHarnessStateRestarting;
    self.restartCount++;
    self.relaunchPending = YES;
    self.relaunchDelay = delay;
    [self schedulePendingRelaunch];
}

- (void)schedulePendingRelaunch {
    if (self.appBackgrounded || self.userStopped || !self.relaunchPending) return;
    NSUInteger generation = self.launchGeneration;
    NSUInteger relaunchGeneration = ++self.relaunchGeneration;
    __weak typeof(self) weakSelf = self;
    self.scheduler(self.relaunchDelay, ^{
        typeof(self) self = weakSelf;
        if (self == nil || self.appBackgrounded || self.userStopped ||
            generation != self.launchGeneration || relaunchGeneration != self.relaunchGeneration || !self.relaunchPending)
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

- (NSUInteger)healthCheckGeneration {
    return self.nextHealthRequestID;
}

- (void)verifyAliveAfterResumeWithCompletion:(void (^)(BOOL))completion {
    if (self.appBackgrounded) [self handleAppResume];
    if (!self.resumeCheckStarted) {
        self.resumeCheckStarted = YES;
        self.recoveryCheckPending = YES;
        self.lastHealthCheckAt = 0;
        self.healthCheckFailures = 0;
        [self invalidateHealthCheckDeliveringFailure:NO];
    }
    [self verifyAliveWithCachedAnswer:YES completion:completion];
}

- (void)verifyAliveWithCachedAnswer:(BOOL)trustCachedAnswer completion:(void (^)(BOOL))completion {
    NSAssert(NSThread.isMainThread, @"health check on main");
    if (self.appBackgrounded) return;
    if (self.userStopped || self.state != DSHHarnessStateReady || self.authenticatedEntryURL == nil) {
        if (completion) completion(NO);
        return;
    }
    if (self.healthOperation != nil) {
        if (completion) [self.healthOperation.completions addObject:[completion copy]];
        return;
    }
    if (trustCachedAnswer && self.lastHealthCheck.alive && self.lastHealthCheckAt > 0 &&
        self.healthCheckFailures == 0 && self.clock() - self.lastHealthCheckAt < kHealthCheckDebounce) {
        if (completion) completion(YES);
        return;
    }
    DSHHealthOperation *operation = [DSHHealthOperation new];
    operation.requestID = ++self.nextHealthRequestID;
    operation.launchGeneration = self.launchGeneration;
    operation.lifecycleGeneration = self.lifecycleGeneration;
    operation.recoveringFromResume = self.recoveryCheckPending;
    operation.completions = [NSMutableArray array];
    if (completion) [operation.completions addObject:[completion copy]];
    self.recoveryCheckPending = NO;
    self.healthOperation = operation;
    [self runHealthCheck:operation];
}

- (BOOL)isCurrentHealthCheck:(DSHHealthOperation *)operation {
    return !self.appBackgrounded && self.healthOperation == operation &&
        operation.launchGeneration == self.launchGeneration &&
        operation.lifecycleGeneration == self.lifecycleGeneration &&
        self.state == DSHHarnessStateReady && !self.userStopped;
}

- (void)runHealthCheck:(DSHHealthOperation *)operation {
    if (![self isCurrentHealthCheck:operation]) return;
    NSURL *url = self.authenticatedEntryURL;
    if (url == nil) {
        [self finishHealthCheck:operation succeeded:NO];
        return;
    }
    NSUInteger attemptID = ++operation.attemptID;
    __weak typeof(self) weakSelf = self;
    id<DSHProbeRequest> request = self.healthProbeFactory(url, self.healthCheckTimeout, ^(DSHProbeResult *result) {
        typeof(self) self = weakSelf;
        // In particular, do not call a global "finish" here. This may be a
        // cancelled A completing after the new foreground's B has started.
        if (self == nil || ![self isCurrentHealthCheck:operation] || operation.attemptID != attemptID) return;
        operation.attemptID++;
        operation.request = nil;
        self.lastHealthCheck = result;
        self.lastHealthCheckAt = self.clock();
        [self.log append:[NSString stringWithFormat:@"[dsh-ios] health check #%lu: %@",
                          (unsigned long)operation.requestID, result.summary]];

        if (result.requiresAuthentication && [self noteAuthenticationFailureForURL:url]) {
            [self finishHealthCheck:operation succeeded:NO];
            return;
        }
        if (result.outcome == DSHProbeOutcomeCancelled) {
            [self finishHealthCheck:operation succeeded:NO];
            return;
        }
        if (result.alive) {
            self.healthCheckFailures = 0;
            [self finishHealthCheck:operation succeeded:YES];
            return;
        }
        operation.failures++;
        self.healthCheckFailures = operation.failures;
        NSUInteger limit = MAX((NSUInteger)1, self.healthCheckFailuresBeforeRestart);
        // Socket restoration and the guest's event loop can lag foregrounding.
        // Refusal and 5xx get a bounded ladder here, never an immediate reboot.
        if (operation.recoveringFromResume) limit = MAX((NSUInteger)2, limit);
        BOOL conclusive = result.indicatesDeadServer && !operation.recoveringFromResume;
        if (conclusive || operation.failures >= limit) {
            [DSHLifecycleDiagnostics recordEvent:@"healthRestartLimit" harness:self];
            [self.log append:[NSString stringWithFormat:@"[dsh-ios] health check failed %lu time(s) (%@); restarting server",
                              (unsigned long)operation.failures, result.summary]];
            NSUInteger launch = self.launchGeneration;
            NSUInteger lifecycle = self.lifecycleGeneration;
            [self finishHealthCheck:operation succeeded:NO];
            // A completion may stop/restart/background the harness itself.
            if (!self.appBackgrounded && !self.userStopped && self.state == DSHHarnessStateReady &&
                launch == self.launchGeneration && lifecycle == self.lifecycleGeneration &&
                self.nextHealthRequestID == operation.requestID) [self restart];
            return;
        }
        [self.log append:[NSString stringWithFormat:@"[dsh-ios] health check failed (%@); retrying in %.1fs (attempt %lu/%lu)",
                          result.summary, self.healthCheckRetryDelay,
                          (unsigned long)operation.failures, (unsigned long)limit]];
        NSUInteger retryID = operation.attemptID;
        self.scheduler(self.healthCheckRetryDelay, ^{
            typeof(self) self = weakSelf;
            if (self == nil || ![self isCurrentHealthCheck:operation] || retryID != operation.attemptID) return;
            [self runHealthCheck:operation];
        });
    });
    // Injection may settle synchronously; do not attach that already-finished
    // request to a replacement operation or retry.
    if ([self isCurrentHealthCheck:operation] && operation.attemptID == attemptID) operation.request = request;
    else [request cancel];
}

- (void)finishHealthCheck:(DSHHealthOperation *)operation succeeded:(BOOL)succeeded {
    if (self.healthOperation != operation) return;
    self.healthOperation = nil;
    operation.attemptID++;
    NSArray<void (^)(BOOL)> *callbacks = [operation.completions copy];
    [operation.completions removeAllObjects];
    for (void (^callback)(BOOL) in callbacks) callback(succeeded);
}

- (void)invalidateHealthCheckDeliveringFailure:(BOOL)deliver {
    DSHHealthOperation *operation = self.healthOperation;
    if (operation == nil) return;
    self.healthOperation = nil;
    operation.attemptID++;
    NSArray<void (^)(BOOL)> *callbacks = [operation.completions copy];
    [operation.completions removeAllObjects];
    [operation.request cancel];
    operation.request = nil;
    if (deliver) for (void (^callback)(BOOL) in callbacks) callback(NO);
}

@end
