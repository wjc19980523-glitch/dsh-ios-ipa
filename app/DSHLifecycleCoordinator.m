#import "DSHLifecycleCoordinator.h"
#import <UIKit/UIKit.h>

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
@property (nonatomic, nullable) DSHLifecycleCycle *cycle;
@property (nonatomic) NSMutableArray<dispatch_block_t> *pendingActions;
@property (nonatomic) BOOL flushingActions;
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
        _pendingActions = [NSMutableArray array];
    }
    return self;
}

- (void)dealloc {
    DSHLifecycleCycle *cycle = _cycle;
    if (cycle.taskIdentifierReturned && !cycle.taskEnded && cycle.backgroundTask != NSUIntegerMax) {
        id<DSHLifecycleBackgroundTasks> tasks = _backgroundTasks;
        NSUInteger identifier = cycle.backgroundTask;
        if (NSThread.isMainThread) [tasks endTask:identifier];
        else dispatch_async(dispatch_get_main_queue(), ^{ [tasks endTask:identifier]; });
    }
}

- (BOOL)isCurrentCycle:(DSHLifecycleCycle *)cycle {
    return self.cycle == cycle && self.generation == cycle.generation;
}

- (NSDictionary<NSString *, id> *)detailsForCycle:(DSHLifecycleCycle *)cycle {
    NSTimeInterval waited = cycle.waitFinished ? cycle.finishedWaitDuration : MAX(0, self.clock() - cycle.startedAt);
    self.lastQuiesceWaitDuration = waited;
    return @{ @"cycle": @(cycle.generation), @"core_generation": @(cycle.coreGeneration),
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

- (void)endTaskForCycle:(DSHLifecycleCycle *)cycle {
    cycle.endRequested = YES;
    if (!cycle.taskIdentifierReturned || cycle.taskEnded) return;
    cycle.taskEnded = YES;
    if (cycle.backgroundTask != NSUIntegerMax) [self.backgroundTasks endTask:cycle.backgroundTask];
}

- (void)handleAppBackground {
    NSAssert(NSThread.isMainThread, @"Lifecycle transitions require the main thread");
    if (self.state != DSHLifecycleCoordinatorStateRunning) return;

    DSHLifecycleCycle *cycle = [DSHLifecycleCycle new];
    cycle.generation = ++self.generation;
    cycle.startedAt = self.clock();
    cycle.lastDiagnosticAt = cycle.startedAt;
    cycle.backgroundTask = NSUIntegerMax;
    self.cycle = cycle;
    self.state = DSHLifecycleCoordinatorStateQuiescing;
    // Admission closes before any observer, network completion, or guest can
    // begin fresh work; supervision cancellation follows in the same main turn.
    self.coreGeneration = cycle.coreGeneration = [self.driver closeAdmission];
    [self.driver pauseHarnessSupervision];

    __weak typeof(self) weakSelf = self;
    cycle.backgroundTask = [self.backgroundTasks beginTaskWithName:@"dsh.filesystem-quiesce"
                                                expirationHandler:^{
        [weakSelf expireCycle:cycle];
    }];
    cycle.taskIdentifierReturned = YES;
    cycle.denied = cycle.backgroundTask == NSUIntegerMax;
    if (cycle.endRequested) [self endTaskForCycle:cycle];
    if (![self isCurrentCycle:cycle]) {
        [self endTaskForCycle:cycle];
        return;
    }
    // Acquire the finite UIKit assertion before persisting a diagnostic, whose
    // fsync must not consume our initial background allowance without a task.
    [self recordEvent:@"quiesceRequested" cycle:cycle];
    if (cycle.denied) [self recordEvent:@"quiesceTaskDenied" cycle:cycle];
    // Even a denied assertion gets one nonblocking cached check. It cannot
    // authorize a timer that assumes the app has further background runtime.
    if (!cycle.expired) [self attemptQuiesceForCycle:cycle];
}

- (void)attemptQuiesceForCycle:(DSHLifecycleCycle *)cycle {
    NSAssert(NSThread.isMainThread, @"Lifecycle polling requires the main thread");
    if (![self isCurrentCycle:cycle] || self.state != DSHLifecycleCoordinatorStateQuiescing || cycle.expired) return;
    if ([self.driver markQuiescentForGeneration:cycle.coreGeneration]) {
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
    if (cycle.denied) return;
    __weak typeof(self) weakSelf = self;
    self.scheduler(MAX(0.001, self.pollInterval), ^{ [weakSelf attemptQuiesceForCycle:cycle]; });
}

- (void)expireCycle:(DSHLifecycleCycle *)cycle {
    NSAssert(NSThread.isMainThread, @"Lifecycle expiration requires the main thread");
    if (![self isCurrentCycle:cycle] || self.state != DSHLifecycleCoordinatorStateQuiescing || cycle.expired) return;
    cycle.expired = YES;
    [self finishWaitForCycle:cycle];
    // Keep admission closed. Expiration cannot authorize force-closing SQLite,
    // dropping a native lock, killing a guest, or starting replacement work.
    [self recordEvent:@"quiesceExpired" cycle:cycle];
    [self endTaskForCycle:cycle];
}

- (void)handleAppForeground {
    NSAssert(NSThread.isMainThread, @"Lifecycle transitions require the main thread");
    if (self.state == DSHLifecycleCoordinatorStateRunning || self.state == DSHLifecycleCoordinatorStateResuming) return;
    DSHLifecycleCycle *cycle = self.cycle;
    ++self.generation;
    self.state = DSHLifecycleCoordinatorStateResuming;
    [self finishWaitForCycle:cycle];
    [self.driver beginResume];
    [self endTaskForCycle:cycle];
    if (cycle.socketsSuspended) [self.driver resumeSockets];
    [self.driver openAdmission];
    self.state = DSHLifecycleCoordinatorStateRunning;
    self.cycle = nil;
    [self.driver resumeHarnessSupervision];
    [self recordEvent:@"foregroundResumed" cycle:cycle];
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
