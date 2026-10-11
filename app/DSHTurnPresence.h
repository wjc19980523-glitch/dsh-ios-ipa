//
//  DSHTurnPresence.h
//  DSH
//
//  iOS suspends an app that is not on screen, and the guest is threads inside
//  this process, so an agent turn does not continue while the user is somewhere
//  else. Today that is silent: the user switches away mid-turn, comes back, and
//  finds a conversation that stopped without saying why.
//
//  Persists whether a turn was in progress and explains an interruption on
//  return. DSHLifecycleCoordinator owns the finite background drain task.
//

#import <Foundation/Foundation.h>

// Same definition as DSHHarnessAuth.h; see there for why a hosted test bundle
// cannot see an unexported C symbol.
#ifndef DSH_EXPORTED
#define DSH_EXPORTED __attribute__((visibility("default")))
#endif

NS_ASSUME_NONNULL_BEGIN

/// Posted on the main thread when the app returns to the foreground having left
/// it mid-turn. The object is the presence instance; there is no user info.
extern DSH_EXPORTED NSNotificationName const DSHTurnWasInterruptedNotification;
extern NSString *const DSHTurnRecoveryStatusKey;

@interface DSHTurnPresence : NSObject

@property (class, nonatomic, readonly) DSHTurnPresence *shared;

/// Starts observing the activity record and the app's lifecycle. Safe to call
/// more than once.
- (void)start;

/// Whether the agent has done something recently enough to count as working.
/// Any activity counts, guest tool calls included — a shell command running in
/// the guest is as much a turn in progress as a capability call is.
@property (nonatomic, readonly, getter=isWorking) BOOL working;

/// Set while the app is in the background having left mid-turn, and cleared
/// once the notice has been shown. Exposed for tests.
@property (nonatomic, readonly) BOOL leftMidTurn;
/// Last persisted interruption time, including an interruption carried across
/// a process termination. Nil after the recovery notice has been consumed.
@property (nonatomic, readonly, nullable) NSDate *interruptedAt;

/// How recent activity has to be to count as working.
@property (class, nonatomic, readonly) NSTimeInterval workingWindow;

/// Tests only: forget the last activity and any pending notice. The instance
/// outlives one test the way it outlives one turn, and in an app that is the
/// point — twenty seconds of memory is what makes the window work.
- (void)resetForTesting;

@end

NS_ASSUME_NONNULL_END
