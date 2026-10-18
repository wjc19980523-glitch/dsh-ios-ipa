#import <Foundation/Foundation.h>

#ifndef DSH_EXPORTED
#define DSH_EXPORTED __attribute__((visibility("default")))
#endif

NS_ASSUME_NONNULL_BEGIN
@class DSHHostBridge;
typedef void (^DSHGuestSessionLifecycleMainScheduler)(dispatch_block_t action);
/// Delivered on main after revalidating the current guest and command identity.
extern DSH_EXPORTED NSNotificationName const DSHGuestSessionLifecycleStateDidChangeNotification;

/// Authenticated, generation-scoped commands for the supervised guest only.
/// The transport never performs guest filesystem work or waits on UIKit.
@interface DSHGuestSessionLifecycle : NSObject
+ (instancetype)shared;
/// Deterministic test seam. Production init uses NSCondition and dispatch_async
/// to main; a supplied scheduler must also execute its actions on main.
- (instancetype)initWithMainScheduler:(DSHGuestSessionLifecycleMainScheduler)scheduler
                           condition:(NSCondition *)condition;
- (void)installOnBridge:(DSHHostBridge *)bridge;
/// Guest notifications and transition commands run on main, so identity
/// changes cannot interleave with a completion after its final validation.
/// Returns a per-launch identity; retain it with the executor's exit callback.
- (uint64_t)managedGuestDidLaunch:(int)pid;
- (void)managedGuestDidExit:(int)pid identity:(uint64_t)identity;
@property (nonatomic, readonly) BOOL registered;
/// A running ACK for this exact live guest/command, after its completion was
/// delivered. Registration, HTTP health, absent guests, and exits are not proof.
@property (nonatomic, readonly) BOOL confirmedRunning;
/// Last supervised group until its matching real exit, including stop-in-flight.
@property (nonatomic, readonly) int managedGuestPID;
@property (nonatomic, readonly) BOOL transitionPending;
@property (nonatomic, readonly, copy) NSDictionary *diagnosticSnapshot;
/// Completions run on main. New transitions, cancellation, and guest identity
/// changes invalidate callbacks that were already queued but not delivered.
- (void)prepareForBackgroundWithCompletion:(void (^)(BOOL))completion;
- (void)resumeWithCompletion:(void (^)(BOOL))completion;
/// Invalidate late acknowledgements, retaining the desired paused state.
- (void)cancelPendingTransition;
@end
NS_ASSUME_NONNULL_END
