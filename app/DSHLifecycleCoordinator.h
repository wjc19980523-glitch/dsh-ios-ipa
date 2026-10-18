#import <Foundation/Foundation.h>

#ifndef DSH_EXPORTED
#define DSH_EXPORTED __attribute__((visibility("default")))
#endif

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, DSHLifecycleCoordinatorState) {
    DSHLifecycleCoordinatorStateRunning = 0,
    DSHLifecycleCoordinatorStateQuiescing,
    DSHLifecycleCoordinatorStateQuiesced,
    DSHLifecycleCoordinatorStateResuming,
};
extern DSH_EXPORTED NSNotificationName const DSHLifecycleCoordinatorRecoveryDidChangeNotification;

/// The driver bridges the coordinator to the filesystem gate, socket repair,
/// Harness, and metadata-only diagnostics. Every method runs on the main queue.
/// None may wait for a guest thread, transaction, or SQLite mutex.
@protocol DSHLifecycleDriver <NSObject>
/// Atomically closes admission and returns the core's quiesce generation.
- (uint64_t)closeAdmission;
/// Uses the core's atomic check: no admitted operations, cached transactions,
/// retained native locks, or uncertain tracking may remain.
- (BOOL)markQuiescentForGeneration:(uint64_t)generation;
/// Enters Resuming while admission stays closed throughout socket restoration.
- (void)beginResume;
- (void)openAdmission;
- (void)suspendSockets;
- (void)resumeSockets;
- (void)pauseHarnessSupervision;
- (void)resumeHarnessSupervision;
/// Cached observations only; never inspect SQLite or acquire a host file lock.
- (NSDictionary<NSString *, id> *)diagnosticSnapshot;
/// details includes wait_ms, cycle, core_generation, and the cached snapshot.
- (void)recordLifecycleEvent:(NSString *)event details:(NSDictionary<NSString *, id> *)details;
@optional
/// The managed guest stops new persistence writes and drains/ closes stable
/// writer handles. Grant its exact group synchronously before returning, then
/// complete only after an authenticated acknowledgement and permit revocation.
/// Completion may arrive on any queue; the coordinator checks its cycle.
- (void)prepareSessionsForGeneration:(uint64_t)generation completion:(void (^)(BOOL success))completion;
/// Revoke the current transition permit and invalidate late guest responses.
/// Never force-close a guest fd or remove/replace its lock file.
- (void)cancelSessionTransition;
/// Runs while Resuming admission remains closed, after socket restoration.
/// Reacquire stable writer locks, revoke the new group permit, then complete.
/// Failure leaves guest persistence fail-closed until its own recovery succeeds.
- (void)resumeSessionsWithCompletion:(void (^)(BOOL success))completion;
/// Recovery observations run on main and only describe the current authenticated
/// guest/command. They also cover a real ACK after a finite resume timed out.
- (void)setSessionRecoveryObserver:(dispatch_block_t)observer;
- (BOOL)sessionRecoveryAwaitingRegistration;
- (BOOL)sessionRecoveryConfirmedRunning;
@end

/// UIKit's background task is a finite opportunity to finish already admitted
/// work. Tests supply this interface without asking UIKit to enter background.
@protocol DSHLifecycleBackgroundTasks <NSObject>
/// NSUIntegerMax means that UIKit denied the request.
- (NSUInteger)beginTaskWithName:(NSString *)name expirationHandler:(dispatch_block_t)expiration;
- (void)endTask:(NSUInteger)identifier;
@end

typedef void (^DSHLifecycleScheduler)(NSTimeInterval delay, dispatch_block_t action);
typedef NSTimeInterval (^DSHLifecycleClock)(void);

@interface DSHLifecycleCoordinator : NSObject

- (instancetype)initWithDriver:(id<DSHLifecycleDriver>)driver;
- (instancetype)initWithDriver:(id<DSHLifecycleDriver>)driver
                backgroundTasks:(id<DSHLifecycleBackgroundTasks>)backgroundTasks
                      scheduler:(DSHLifecycleScheduler)scheduler
                          clock:(DSHLifecycleClock)clock NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly) DSHLifecycleCoordinatorState state;
/// Local cycle identity; foregrounding invalidates all old polls and expiry callbacks.
@property (nonatomic, readonly) uint64_t generation;
@property (nonatomic, readonly) uint64_t coreGeneration;
@property (nonatomic, readonly) NSTimeInterval lastQuiesceWaitDuration;
/// A failed or timed-out session restore still needs attention even when the
/// UI and HTTP service recover. Only a current successful restore clears it.
@property (nonatomic, readonly) BOOL sessionRecoveryNeedsAttention;
/// Distinguishes startup's missing control registration from a registered
/// writer restore. Neither registration nor UI readiness clears attention.
@property (nonatomic, readonly) BOOL sessionRecoveryAwaitingRegistration;
/// Default 0.05 seconds. A poll only reads cached state and attempts the atomic mark.
@property (nonatomic) NSTimeInterval pollInterval;
/// Default 15 seconds; bounds asynchronous foreground writer/lock restoration.
@property (nonatomic) NSTimeInterval sessionResumeTimeout;

/// Duplicate notifications in a background cycle have no effect.
- (void)handleAppBackground;
/// Restores sockets under the closed gate, then opens it and resumes supervision.
- (void)handleAppForeground;
/// Equivalent spelling for callers that already use handleAppResume.
- (void)handleAppResume;

/// Native main-thread work must not enter the closed filesystem gate. Runs
/// immediately while Running; otherwise preserves the action until a resume
/// has opened admission and resumed Harness supervision. Each action runs once.
- (void)performWhenRunning:(dispatch_block_t)action;

@end

NS_ASSUME_NONNULL_END
