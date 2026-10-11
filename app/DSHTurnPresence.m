//
//  DSHTurnPresence.m
//  DSH
//

#import "DSHTurnPresence.h"
#import "DSHActivityLog.h"
#import "DSHHarness.h"
#import <UIKit/UIKit.h>

DSH_EXPORTED NSNotificationName const DSHTurnWasInterruptedNotification = @"DSHTurnWasInterrupted";
NSString *const DSHTurnRecoveryStatusKey = @"status";
static NSString *const kInterruptedAtKey = @"DSHTurnInterruptedAt";

/// Long enough that the gap between two tool calls in one turn does not read as
/// idle, short enough that a turn finished a minute ago does not.
static const NSTimeInterval kWorkingWindow = 20;

@implementation DSHTurnPresence {
    NSDate *_lastActivity;
    BOOL _started;
}

+ (DSHTurnPresence *)shared {
    static DSHTurnPresence *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [DSHTurnPresence new]; });
    return shared;
}

+ (NSTimeInterval)workingWindow { return kWorkingWindow; }

- (void)start {
    if (_started) return;
    _started = YES;
    NSDate *persisted = [NSUserDefaults.standardUserDefaults objectForKey:kInterruptedAtKey];
    if ([persisted isKindOfClass:NSDate.class]) {
        _leftMidTurn = YES;
        _interruptedAt = persisted;
    }
    NSNotificationCenter *centre = NSNotificationCenter.defaultCenter;
    [centre addObserver:self selector:@selector(activityChanged)
                   name:DSHActivityLogDidChangeNotification object:nil];
    [centre addObserver:self selector:@selector(willResignActive)
                   name:UIApplicationDidEnterBackgroundNotification object:nil];
    [centre addObserver:self selector:@selector(didBecomeActive)
                   name:UIApplicationDidBecomeActiveNotification object:nil];
}

- (void)activityChanged {
    DSHActivityEntry *latest = DSHActivityLog.shared.entries.firstObject;
    if (latest == nil) return;
    @synchronized (self) { _lastActivity = latest.date; }
}

- (BOOL)isWorking {
    NSDate *last;
    @synchronized (self) { last = _lastActivity; }
    return last != nil && -last.timeIntervalSinceNow < kWorkingWindow;
}

#pragma mark - Leaving and coming back

- (void)willResignActive {
    if (!self.isWorking) return;
    _leftMidTurn = YES;
    _interruptedAt = NSDate.date;
    [NSUserDefaults.standardUserDefaults setObject:_interruptedAt forKey:kInterruptedAtKey];

    // The lifecycle coordinator owns the one finite filesystem-drain task.
    // Presence only persists the recovery notice; it cannot extend the turn.
}

- (void)didBecomeActive {
    if (!_leftMidTurn) return;
    _leftMidTurn = NO;
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kInterruptedAtKey];
    // Said on the way back rather than on the way out: leaving is a deliberate
    // act and a warning then would be one more thing between the user and the
    // app they are switching to. Coming back to a conversation that stopped is
    // where the explanation is missing.
    NSString *status = DSHHarness.shared.state == DSHHarnessStateReady ? @"server-ready" : @"server-unavailable";
    [NSNotificationCenter.defaultCenter postNotificationName:DSHTurnWasInterruptedNotification
                                                       object:self userInfo:@{DSHTurnRecoveryStatusKey: status}];
    _interruptedAt = nil;
}

- (void)resetForTesting {
    @synchronized (self) { _lastActivity = nil; }
    _leftMidTurn = NO;
    _interruptedAt = nil;
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kInterruptedAtKey];
}

@end
