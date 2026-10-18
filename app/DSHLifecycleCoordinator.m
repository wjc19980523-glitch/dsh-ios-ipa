#import "DSHLifecycleCoordinator.h"
#import <UIKit/UIKit.h>
#include <math.h>

DSH_EXPORTED NSNotificationName const DSHLifecycleCoordinatorRecoveryDidChangeNotification = @"DSHLifecycleCoordinatorRecoveryDidChange";

@interface DSHUIKitLifecycleTasks : NSObject <DSHLifecycleBackgroundTasks>
@end

@implementation DSHUIKitLifecycleTasks
- (NSUInteger)beginTaskWithName:(NSString *)name expirationHandler:(dispatch_block_t)expiration {
    NSAssert(NSThread.isMainThread, @"Lifecycle background tasks require the main thread");
    return [UIApplication.sharedApplication beginBackgroundTaskWithName:name expirationHandler:expiration];
}
- (void)endTask:(NSUInteger)identifier {
    NSAssert(NSThread.isMainThread, @"Lifecycle background tasks require the main thread");
    [UIApplication.sharedApplication endBackgroundTask:identifier];
}
@end

/// Retained by callbacks so a delayed expiry cannot accidentally end a newer task.
@interface DSHLifecycleCycle : NSObject
@property (nonatomic) uint64_t generation;
@property (nonatomic) uint64_t coreGeneration;
@property (nonatomic) NSTimeInterval startedAt;
@property (nonatomic) NSTimeInterval lastDiagnosticAt;
@property (nonatomic) NSTimeInterval finishedWaitDuration;
@property (nonatomic) BOOL waitFinished;
@property (nonatomic) NSUInteger backgroundTask;
@property (nonatomic) BOOL taskIdentifierReturned;
@property (nonatomic) BOOL endRequested;
@property (nonatomic) BOOL taskEnded;
@property (nonatomic) BOOL expired;
@property (nonatomic) BOOL denied;
@property (nonatomic) BOOL socketsSuspended;
@property (nonatomic) BOOL requiresSessionAcknowledgement;
@property (nonatomic) BOOL sessionAcknowledged;
@property (nonatomic) BOOL sessionCompletionReceived;
@property (nonatomic) BOOL sessionCancelled;
@property (nonatomic) BOOL pollScheduled;
@end
@implementation DSHLifecycleCycle
@end

@interface DSHLifecycleCoordinator ()
@property (nonatomic) id<DSHLifecycleDriver> driver;
@property (nonatomic) id<DSHLifecycleBackgroundTasks> backgroundTasks;
@property (nonatomic, copy) DSHLifecycleScheduler scheduler;
@property (nonatomic, copy) DSHLifecycleClock clock;
@property (nonatomic, readwrite) DSHLifecycleCoordinatorState state;
@property (nonatomic, readwrite) uint64_t generation;
@property (nonatomic, readwrite) uint64_t coreGeneration;
@property (nonatomic, readwrite) NSTimeInterval lastQuiesceWaitDuration;
@property (nonatomic, readwrite) BOOL sessionRecoveryNeedsAttention;
@property (nonatomic, readwrite) BOOL sessionRecoveryAwaitingRegistration;
@property (nonatomic, nullable) DSHLifecycleCycle *cycle;
@property (nonatomic) NSMutableArray<dispatch_block_t> *pendingActions;
@property (nonatomic) BOOL flushingActions;
@property (nonatomic) BOOL pendingBackground;
@property (nonatomic, nullable) DSHLifecycleCycle *pendingBackgroundCycle;
@property (nonatomic) BOOL resumeFinished;
@property (nonatomic) BOOL resumeCancellationRequested;
@property (nonatomic) NSTimeInterval resumeDeadline;
@end

@implementation DSHLifecycleCoordinator

- (instancetype)initWithDriver:(id<DSHLifecycleDriver>)driver {
    return [self initWithDriver:driver backgroundTasks:[DSHUIKitLifecycleTasks new]
                     scheduler:^(NSTimeInterval delay, dispatch_block_t action) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), action);
    } clock:^{ return NSProcessInfo.processInfo.systemUptime; }];
}

- (instancetype)initWithDriver:(id<DSHLifecycleDriver>)driver
                backgroundTasks:(id<DSHLifecycleBackgroundTasks>)backgroundTasks
                      scheduler:(DSHLifecycleScheduler)scheduler
                          clock:(DSHLifecycleClock)clock {
    if ((self = [super init])) {
        _driver = driver;
        _backgroundTasks = backgroundTasks;
        _scheduler = [scheduler copy];
        _clock = [clock copy];
        _state = DSHLifecycleCoordinatorStateRunning;
        _pollInterval = 0.05;
        _sessionResumeTimeout = 15;
        _pendingActions = [NSMutableArray array];
        if ([_driver respondsToSelector:@selector(setSessionRecoveryObserver:)]) {
            __weak typeof(self) weakSelf = self;
            [_driver setSessionRecoveryObserver:^{ [weakSelf sessionRecoveryStateChanged]; }];
        }
    }
    return self;
}

- (void)dealloc {
    if (_cycle || _pendingBackgroundCycle) {
        id<DSHLifecycleDriver> driver = _driver;
        dispatch_block_t cancel = ^{
            if ([driver respondsToSelector:@selector(cancelSessionTransition)]) {
                @try { [driver cancelSessionTransition]; }
                @catch (__unused NSException *exception) { /* No caller text is logged during teardown. */ }
            }
        };
        if (NSThread.isMainThread) cancel();
        else dispatch_async(dispatch_get_main_queue(), cancel);
    }
    for (id entry in @[(id)_cycle ?: NSNull.null, (id)_pendingBackgroundCycle ?: NSNull.null]) {
        if (entry == NSNull.null) continue;
        DSHLifecycleCycle *cycle = entry;
        if (cycle.taskIdentifierReturned && !cycle.taskEnded && cycle.backgroundTask != NSUIntegerMax) {
            id<DSHLifecycleBackgroundTasks> tasks = _backgroundTasks;
            NSUInteger identifier = cycle.backgroundTask;
            if (NSThread.isMainThread) [tasks endTask:identifier];
            else dispatch_async(dispatch_get_main_queue(), ^{ [tasks endTask:identifier]; });
        }
    }
}

- (BOOL)isCurrentCycle:(DSHLifecycleCycle *)cycle {
    return self.cycle == cycle && self.generation == cycle.generation;
}

- (NSDictionary<NSString *, id> *)detailsForCycle:(DSHLifecycleCycle *)cycle {
    NSTimeInterval waited = cycle.waitFinished ? cycle.finishedWaitDuration : MAX(0, self.clock() - cycle.startedAt);
    self.lastQuiesceWaitDuration = waited;
    return @{ @"cycle": @(cycle.generation), @"core_generation": @(cycle.coreGeneration),
              @"session_ack_required": @(cycle.requiresSessionAcknowledgement),
              @"session_acknowledged": @(cycle.sessionAcknowledged),
              @"session_recovery_needs_attention": @(self.sessionRecoveryNeedsAttention),
              @"session_recovery_awaiting_registration": @(self.sessionRecoveryAwaitingRegistration),
              @"wait_ms": @(waited * 1000), @"snapshot": [self.driver diagnosticSnapshot] ?: @{} };
}

- (void)finishWaitForCycle:(DSHLifecycleCycle *)cycle {
    if (cycle.waitFinished) return;
    cycle.finishedWaitDuration = MAX(0, self.clock() - cycle.startedAt);
    cycle.waitFinished = YES;
}

- (void)recordEvent:(NSString *)event cycle:(DSHLifecycleCycle *)cycle {
    [self.driver recordLifecycleEvent:event details:[self detailsForCycle:cycle]];
}

- (void)notifyRecoveryStateChanged {
    [NSNotificationCenter.defaultCenter postNotificationName:DSHLifecycleCoordinatorRecoveryDidChangeNotification object:self];
}

- (void)updateSessionRecoveryPhase {
    BOOL waiting = [self.driver respondsToSelector:@selector(sessionRecoveryAwaitingRegistration)] &&
        [self.driver sessionRecoveryAwaitingRegistration];
    if (waiting == self.sessionRecoveryAwaitingRegistration) return;
    self.sessionRecoveryAwaitingRegistration = waiting;
    [self notifyRecoveryStateChanged];
}

- (void)sessionRecoveryStateChanged {
    NSAssert(NSThread.isMainThread, @"Session recovery observations require main");
    [self updateSessionRecoveryPhase];
    // Never open admission, finish a resume, or authorize background suspend
    // from an observation. Only the ordinary transition owns those boundaries.
    if (self.state != DSHLifecycleCoordinatorStateRunning || !self.sessionRecoveryNeedsAttention ||
        ![self.driver respondsToSelector:@selector(sessionRecoveryConfirmedRunning)] ||
        ![self.driver sessionRecoveryConfirmedRunning]) return;
    self.sessionRecoveryNeedsAttention = NO;
    [self.driver recordLifecycleEvent:@"sessionRecoveryConfirmed" details:@{
        @"cycle": @(self.generation), @"core_generation": @(self.coreGeneration),
        @"session_recovery_needs_attention": @NO, @"session_recovery_awaiting_registration": @NO,
        @"snapshot": [self.driver diagnosticSnapshot] ?: @{}}];
    [self notifyRecoveryStateChanged];
}

- (void)endTaskForCycle:(DSHLifecycleCycle *)cycle {
    cycle.endRequested = YES;
    if (!cycle.taskIdentifierReturned || cycle.taskEnded) return;
    cycle.taskEnded = YES;
    if (cycle.backgroundTask != NSUIntegerMax) [self.backgroundTasks endTask:cycle.backgroundTask];
}

- (void)handleAppBackground {
    NSAssert(NSThread.isMainThread, @"Lifecycle transitions require the main thread");
    if (self.state == DSHLifecycleCoordinatorStateResuming) {
        [self deferBackgroundDuringResume];
        return;
    }
    if (self.state != DSHLifecycleCoordinatorStateRunning) return;

    DSHLifecycleCycle *cycle = self.pendingBackgroundCycle ?: [DSHLifecycleCycle new];
    self.pendingBackgroundCycle = nil;
    cycle.generation = ++self.generation;
    if (!cycle.taskIdentifierReturned) {
        cycle.startedAt = self.clock();
        cycle.lastDiagnosticAt = cycle.startedAt;
        cycle.backgroundTask = NSUIntegerMax;
    }
    cycle.requiresSessionAcknowledgement = [self.driver respondsToSelector:@selector(prepareSessionsForGeneration:completion:)];
    self.cycle = cycle;
    self.state = DSHLifecycleCoordinatorStateQuiescing;
    // Admission closes before any observer, network completion, or guest can
    // begin fresh work; supervision cancellation follows in the same main turn.
    self.coreGeneration = cycle.coreGeneration = [self.driver closeAdmission];
    [self.driver pauseHarnessSupervision];

    __weak typeof(self) weakSelf = self;
    if (!cycle.taskIdentifierReturned) {
        cycle.backgroundTask = [self.backgroundTasks beginTaskWithName:@"dsh.filesystem-quiesce"
                                                expirationHandler:^{
            [weakSelf expireCycle:cycle];
        }];
        cycle.taskIdentifierReturned = YES;
        cycle.denied = cycle.backgroundTask == NSUIntegerMax;
    }
    if (cycle.endRequested) [self endTaskForCycle:cycle];
    if (![self isCurrentCycle:cycle]) {
        [self endTaskForCycle:cycle];
        return;
    }
    // Acquire the finite UIKit assertion before persisting a diagnostic, whose
    // fsync must not consume our initial background allowance without a task.
    [self recordEvent:@"quiesceRequested" cycle:cycle];
    if (cycle.denied) {
        [self cancelPreparationForCycle:cycle];
        [self recordEvent:@"quiesceTaskDenied" cycle:cycle];
    }
    if (cycle.expired && !cycle.denied && !cycle.sessionCancelled) {
        [self cancelPreparationForCycle:cycle];
        [self recordEvent:@"quiesceExpired" cycle:cycle];
    }
    if (!cycle.expired && !cycle.denied && cycle.requiresSessionAcknowledgement) {
        @try {
            [self.driver prepareSessionsForGeneration:cycle.coreGeneration completion:^(BOOL success) {
                dispatch_block_t finish = ^{ [weakSelf completePreparation:success cycle:cycle]; };
                if (NSThread.isMainThread) finish();
                else dispatch_async(dispatch_get_main_queue(), finish);
            }];
        } @catch (__unused NSException *exception) {
            // Exception reason/name can contain caller input. Persist only a
            // fixed event and the ordinary metadata-only lifecycle snapshot.
            [self completePreparation:NO cycle:cycle];
            [self recordEvent:@"sessionQuiesceDriverException" cycle:cycle];
        }
    }
    // Legacy drivers may perform one cached check after task denial. A managed
    // guest never gets a new drain permit or a claimed acknowledgement then.
    if (!cycle.expired && (!cycle.denied || !cycle.requiresSessionAcknowledgement))
        [self attemptQuiesceForCycle:cycle];
}

- (void)deferBackgroundDuringResume {
    if (self.pendingBackground) return;
    self.pendingBackground = YES;
    // Writer restoration may itself hold native locks. Acquire this new
    // background cycle's single finite assertion now, not after a 15s resume.
    DSHLifecycleCycle *cycle = [DSHLifecycleCycle new];
    cycle.generation = self.generation;
    cycle.startedAt = cycle.lastDiagnosticAt = self.clock();
    cycle.backgroundTask = NSUIntegerMax;
    self.pendingBackgroundCycle = cycle;
    __weak typeof(self) weakSelf = self;
    cycle.backgroundTask = [self.backgroundTasks beginTaskWithName:@"dsh.filesystem-quiesce"
        expirationHandler:^{ [weakSelf expireCycle:cycle]; }];
    cycle.taskIdentifierReturned = YES;
    cycle.denied = cycle.backgroundTask == NSUIntegerMax;
    if (cycle.endRequested) [self endTaskForCycle:cycle];
    if (self.pendingBackgroundCycle != cycle) { [self endTaskForCycle:cycle]; return; }
    [self recordEvent:@"backgroundDeferredDuringSessionResume" cycle:cycle];
    if (cycle.denied || cycle.expired) {
        [self cancelSessionResume];
        [self finishSessionResume:NO timedOut:NO cycle:self.cycle generation:self.generation];
    }
}

- (void)cancelSessionTransition {
    if (![self.driver respondsToSelector:@selector(cancelSessionTransition)]) return;
    @try { [self.driver cancelSessionTransition]; }
    @catch (__unused NSException *exception) {
        [self recordEvent:@"sessionCancelDriverException" cycle:self.cycle];
    }
}

- (void)cancelPreparationForCycle:(DSHLifecycleCycle *)cycle {
    if (cycle.sessionCancelled) return;
    cycle.sessionCancelled = YES;
    [self cancelSessionTransition];
}

- (void)cancelSessionResume {
    if (self.resumeCancellationRequested) return;
    self.resumeCancellationRequested = YES;
    [self cancelSessionTransition];
}

- (void)completePreparation:(BOOL)success cycle:(DSHLifecycleCycle *)cycle {
    NSAssert(NSThread.isMainThread, @"Session acknowledgements require the main thread");
    if (![self isCurrentCycle:cycle] || self.state != DSHLifecycleCoordinatorStateQuiescing ||
            cycle.expired || cycle.denied || cycle.sessionCancelled || cycle.sessionCompletionReceived) return;
    cycle.sessionCompletionReceived = YES;
    cycle.sessionAcknowledged = success;
    if (!success) [self cancelPreparationForCycle:cycle];
    [self recordEvent:success ? @"sessionQuiesceAcknowledged" : @"sessionQuiesceFailed" cycle:cycle];
    [self attemptQuiesceForCycle:cycle];
}

- (void)attemptQuiesceForCycle:(DSHLifecycleCycle *)cycle {
    NSAssert(NSThread.isMainThread, @"Lifecycle polling requires the main thread");
    if (![self isCurrentCycle:cycle] || self.state != DSHLifecycleCoordinatorStateQuiescing || cycle.expired) return;
    BOOL mayMark = !cycle.requiresSessionAcknowledgement || cycle.sessionAcknowledged;
    if (mayMark && [self.driver markQuiescentForGeneration:cycle.coreGeneration]) {
        [self finishWaitForCycle:cycle];
        self.state = DSHLifecycleCoordinatorStateQuiesced;
        [self.driver suspendSockets];
        cycle.socketsSuspended = YES;
        [self recordEvent:@"quiesceComplete" cycle:cycle];
        [self endTaskForCycle:cycle];
        return;
    }
    // Preserve current owners while the task is still draining: a later
    // SIGKILL cannot run an expiration callback to explain the retained lock.
    // The driver persists this boundary, so never do it every 50 ms poll.
    NSTimeInterval now = self.clock();
    if (now - cycle.lastDiagnosticAt >= 1) {
        cycle.lastDiagnosticAt = now;
        [self recordEvent:@"quiesceWaiting" cycle:cycle];
    }
    if (cycle.denied || cycle.pollScheduled) return;
    cycle.pollScheduled = YES;
    __weak typeof(self) weakSelf = self;
    self.scheduler(MAX(0.001, self.pollInterval), ^{
        cycle.pollScheduled = NO;
        [weakSelf attemptQuiesceForCycle:cycle];
    });
}

- (void)expireCycle:(DSHLifecycleCycle *)cycle {
    NSAssert(NSThread.isMainThread, @"Lifecycle expiration requires the main thread");
    if (self.pendingBackgroundCycle == cycle && self.state == DSHLifecycleCoordinatorStateResuming) {
        if (cycle.expired) return;
        cycle.expired = YES;
        [self cancelSessionResume];
        [self finishWaitForCycle:cycle];
        [self recordEvent:@"deferredBackgroundExpired" cycle:cycle];
        [self endTaskForCycle:cycle];
        if (cycle.taskIdentifierReturned)
            [self finishSessionResume:NO timedOut:NO cycle:self.cycle generation:self.generation];
        return;
    }
    if (![self isCurrentCycle:cycle] || self.state != DSHLifecycleCoordinatorStateQuiescing || cycle.expired) return;
    cycle.expired = YES;
    [self cancelPreparationForCycle:cycle];
    [self finishWaitForCycle:cycle];
    // Keep admission closed. Expiration cannot authorize force-closing SQLite,
    // dropping a native lock, killing a guest, or starting replacement work.
    [self recordEvent:@"quiesceExpired" cycle:cycle];
    [self endTaskForCycle:cycle];
}

- (void)handleAppForeground {
    NSAssert(NSThread.isMainThread, @"Lifecycle transitions require the main thread");
    self.pendingBackground = NO; // The latest notification says foreground.
    DSHLifecycleCycle *pendingCycle = self.pendingBackgroundCycle;
    self.pendingBackgroundCycle = nil;
    if (pendingCycle) [self endTaskForCycle:pendingCycle];
    if (self.state == DSHLifecycleCoordinatorStateRunning || self.state == DSHLifecycleCoordinatorStateResuming) return;
    DSHLifecycleCycle *cycle = self.cycle;
    uint64_t resumeGeneration = ++self.generation;
    self.state = DSHLifecycleCoordinatorStateResuming;
    self.resumeFinished = NO;
    self.resumeCancellationRequested = NO;
    [self updateSessionRecoveryPhase];
    [self finishWaitForCycle:cycle];
    [self cancelPreparationForCycle:cycle];
    [self.driver beginResume];
    [self endTaskForCycle:cycle];
    if (cycle.socketsSuspended) [self.driver resumeSockets];
    if ([self.driver respondsToSelector:@selector(resumeSessionsWithCompletion:)]) {
        NSTimeInterval timeout = self.sessionResumeTimeout;
        if (!isfinite(timeout) || timeout <= 0) timeout = 15;
        self.resumeDeadline = self.clock() + timeout;
        __weak typeof(self) weakSelf = self;
        self.scheduler(timeout, ^{
            [weakSelf finishSessionResume:NO timedOut:YES cycle:cycle generation:resumeGeneration];
        });
        @try {
            [self.driver resumeSessionsWithCompletion:^(BOOL success) {
                dispatch_block_t finish = ^{
                    typeof(self) self = weakSelf;
                    if (!self) return;
                    [self finishSessionResume:success timedOut:(self.clock() >= self.resumeDeadline)
                                       cycle:cycle generation:resumeGeneration];
                };
                if (NSThread.isMainThread) finish();
                else dispatch_async(dispatch_get_main_queue(), finish);
            }];
        } @catch (__unused NSException *exception) {
            [self recordEvent:@"sessionResumeDriverException" cycle:cycle];
            [self finishSessionResume:NO timedOut:NO cycle:cycle generation:resumeGeneration];
        }
        return;
    }
    [self finishSessionResume:YES timedOut:NO cycle:cycle generation:resumeGeneration];
}

- (void)finishSessionResume:(BOOL)success timedOut:(BOOL)timedOut
                     cycle:(DSHLifecycleCycle *)cycle generation:(uint64_t)generation {
    NSAssert(NSThread.isMainThread, @"Session resume completion requires the main thread");
    if (self.cycle != cycle || self.generation != generation ||
            self.state != DSHLifecycleCoordinatorStateResuming || self.resumeFinished) return;
    self.resumeFinished = YES;
    // HTTP readiness and opening the native UI gate do not establish that
    // session writers recovered. Ignore obsolete callbacks before this write.
    [self updateSessionRecoveryPhase];
    BOOL confirmed = ![self.driver respondsToSelector:@selector(sessionRecoveryConfirmedRunning)] ||
        [self.driver sessionRecoveryConfirmedRunning];
    if (timedOut || !success) self.sessionRecoveryNeedsAttention = YES;
    else if (confirmed) self.sessionRecoveryNeedsAttention = NO;
    if (timedOut || !success) {
        [self cancelSessionResume];
        [self recordEvent:timedOut ? @"sessionResumeTimedOut" : @"sessionResumeFailed" cycle:cycle];
    }
    if (self.pendingBackground) {
        // Keep the gate closed across the transition. No transient health check
        // or deferred native work should run while the latest scene is hidden.
        [self recordEvent:@"sessionResumeReenteredBackground" cycle:cycle];
        self.pendingBackground = NO;
        self.state = DSHLifecycleCoordinatorStateRunning;
        self.cycle = nil;
        [self handleAppBackground];
        return;
    }
    [self.driver openAdmission];
    self.state = DSHLifecycleCoordinatorStateRunning;
    self.cycle = nil;
    [self.driver resumeHarnessSupervision];
    [self recordEvent:@"foregroundResumed" cycle:cycle];
    [self notifyRecoveryStateChanged];
    [self flushPendingActions];
}

- (void)handleAppResume { [self handleAppForeground]; }

- (void)performWhenRunning:(dispatch_block_t)action {
    NSAssert(NSThread.isMainThread, @"Native lifecycle work requires the main thread");
    NSParameterAssert(action != nil);
    if (self.state == DSHLifecycleCoordinatorStateRunning) action();
    else [self.pendingActions addObject:[action copy]];
}

- (void)flushPendingActions {
    if (self.flushingActions) return;
    self.flushingActions = YES;
    while (self.state == DSHLifecycleCoordinatorStateRunning && self.pendingActions.count > 0) {
        dispatch_block_t action = self.pendingActions.firstObject;
        [self.pendingActions removeObjectAtIndex:0];
        action();
        // An action can synchronously background the app. Its remaining peers
        // must stay queued instead of entering native fakefs under a closed gate.
    }
    self.flushingActions = NO;
}

@end
