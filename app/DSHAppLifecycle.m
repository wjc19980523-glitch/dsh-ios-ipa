#import "DSHAppLifecycle.h"
#import "DSHLifecycleCoordinator.h"
#import "DSHLifecycleDiagnostics.h"
#import "DSHHarness.h"
#import "ISHShellExecutor.h"
#include "../ish-arm64/fs/dsh-lifecycle.h"

@interface DSHAppLifecycleDriver : NSObject <DSHLifecycleDriver> @end
@implementation DSHAppLifecycleDriver
- (uint64_t)closeAdmission { return dsh_lifecycle_request_quiesce(); }
- (BOOL)markQuiescentForGeneration:(uint64_t)generation { return dsh_lifecycle_mark_quiescent(generation); }
- (void)beginResume { dsh_lifecycle_begin_resume(); }
- (void)openAdmission { dsh_lifecycle_resume(); }
- (void)suspendSockets { [ISHShellExecutor handleAppSuspend]; }
- (void)resumeSockets { [ISHShellExecutor handleAppResume]; }
- (void)pauseHarnessSupervision { [DSHHarness.shared handleAppBackground]; }
- (void)resumeHarnessSupervision { [DSHHarness.shared handleAppResume]; }
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
