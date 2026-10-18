#import "DSHAppLifecycle.h"
#import "DSHLifecycleCoordinator.h"
#import "DSHLifecycleDiagnostics.h"
#import "DSHHarness.h"
#import "DSHGuestSessionLifecycle.h"
#import "ISHShellExecutor.h"
#include "../ish-arm64/fs/dsh-lifecycle.h"

@interface DSHAppLifecycleDriver : NSObject <DSHLifecycleDriver>
@property (nonatomic) int drainPID;
@property (nonatomic) uint64_t drainGeneration;
@property (nonatomic, copy) dispatch_block_t sessionRecoveryObserver;
@end
@implementation DSHAppLifecycleDriver
- (instancetype)init {
    if ((self = [super init])) [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(sessionRecoveryChanged:) name:DSHGuestSessionLifecycleStateDidChangeNotification
        object:DSHGuestSessionLifecycle.shared];
    return self;
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)sessionRecoveryChanged:(NSNotification *)notification {
    if (self.sessionRecoveryObserver) self.sessionRecoveryObserver();
}
- (BOOL)sessionRecoveryAwaitingRegistration {
    DSHGuestSessionLifecycle *sessions = DSHGuestSessionLifecycle.shared;
    return sessions.managedGuestPID > 0 && !sessions.registered;
}
- (BOOL)sessionRecoveryConfirmedRunning { return DSHGuestSessionLifecycle.shared.confirmedRunning; }
- (uint64_t)closeAdmission { return dsh_lifecycle_request_quiesce(); }
- (BOOL)markQuiescentForGeneration:(uint64_t)generation { return dsh_lifecycle_mark_quiescent(generation); }
- (void)beginResume { dsh_lifecycle_begin_resume(); }
- (void)openAdmission { dsh_lifecycle_resume(); }
- (void)suspendSockets { [ISHShellExecutor handleAppSuspend]; }
- (void)resumeSockets { [ISHShellExecutor handleAppResume]; }
- (void)pauseHarnessSupervision { [DSHHarness.shared handleAppBackground]; }
- (void)resumeHarnessSupervision { [DSHHarness.shared handleAppResume]; }
- (void)cancelSessionTransition {
    [DSHGuestSessionLifecycle.shared cancelPendingTransition];
    if (self.drainPID > 0)
        dsh_lifecycle_revoke_session_drain(self.drainPID, self.drainGeneration);
    self.drainPID = 0;
}
- (void)runSessionTransitionForGeneration:(uint64_t)generation background:(BOOL)background
                              completion:(void (^)(BOOL))completion {
    [self cancelSessionTransition];
    // Only the patched, supervised Node group is eligible. An HTTP client's
    // claimed PID and the lock's basename never authorize a core drain grant.
    DSHHarness *harness = DSHHarness.shared;
    // Harness can retire guestPid before SIGTERM/SIGKILL has actually finished.
    // Keep its last host-supervised group eligible to drain normal exit/close;
    // the manager clears it only for a matching real process incarnation.
    int pid = [harness.extraEnvironment[@"DSH_SESSION_LIFECYCLE"] isEqual:@"1"] ?
        DSHGuestSessionLifecycle.shared.managedGuestPID : 0;
    if (pid > 0) {
        if (!dsh_lifecycle_grant_session_drain(pid, generation)) { completion(NO); return; }
        self.drainPID = pid;
        self.drainGeneration = generation;
    }
    __weak typeof(self) weakSelf = self;
    void (^finished)(BOOL) = ^(BOOL success) {
        typeof(self) self = weakSelf;
        if (!self) return;
        if (pid > 0) {
            if (self.drainPID != pid || self.drainGeneration != generation) return;
            dsh_lifecycle_revoke_session_drain(pid, generation);
            self.drainPID = 0;
        }
        completion(success);
    };
    if (background) [DSHGuestSessionLifecycle.shared prepareForBackgroundWithCompletion:finished];
    else [DSHGuestSessionLifecycle.shared resumeWithCompletion:finished];
}
- (void)prepareSessionsForGeneration:(uint64_t)generation completion:(void (^)(BOOL))completion {
    [self runSessionTransitionForGeneration:generation background:YES completion:completion];
}
- (void)resumeSessionsWithCompletion:(void (^)(BOOL))completion {
    struct dsh_lifecycle_snapshot snapshot;
    dsh_lifecycle_get_snapshot(&snapshot);
    [self runSessionTransitionForGeneration:snapshot.generation background:NO completion:completion];
}
- (NSDictionary *)diagnosticSnapshot {
    return [DSHLifecycleDiagnostics snapshotForHarness:DSHHarness.shared event:@"quiesceSnapshot"];
}
- (void)recordLifecycleEvent:(NSString *)event details:(NSDictionary *)details {
    NSData *json = [NSJSONSerialization dataWithJSONObject:details options:NSJSONWritingSortedKeys error:nil];
    if (json) [DSHHarness.shared.log append:[NSString stringWithFormat:@"[lifecycle] %@ %@", event,
        [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding]]];
    [DSHHarness.shared.log synchronizePersistentDiagnostics];
}
@end

@implementation DSHAppLifecycle
+ (DSHLifecycleCoordinator *)sharedCoordinator {
    static DSHLifecycleCoordinator *coordinator;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dsh_lifecycle_enable_admission_gate();
        coordinator = [[DSHLifecycleCoordinator alloc] initWithDriver:[DSHAppLifecycleDriver new]];
    });
    return coordinator;
}
@end
