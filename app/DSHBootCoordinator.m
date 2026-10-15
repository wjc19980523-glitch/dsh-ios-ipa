//
//  DSHBootCoordinator.m
//  DSH
//

#import "DSHBootCoordinator.h"
#import "DSHHarness.h"
#import "DSHRootUpgrader.h"
#import "DSHHostBridge.h"
#import "DSHDeviceCapability.h"
#import "DSHEventKitCapability.h"
#import "DSHHealthCapability.h"
#import "DSHLocationCapability.h"
#import "DSHContactsCapability.h"
#import "DSHNotificationCapability.h"
#import "DSHFilesCapability.h"
#import "DSHPhotosCapability.h"
#import "DSHShareCapability.h"
#import "DSHShortcutsCapability.h"
#import "DSHActivityCapability.h"
#import "DSHStartupMetrics.h"
#import "DSHLifecycleDiagnostics.h"
#import "DSHAppLifecycle.h"
#import "DSHLifecycleCoordinator.h"
#import "DSHGuestSessionLifecycle.h"
#import "DSHSessionLifecycleInstaller.h"
#import "AppDelegate.h"
#import "ISHShellExecutor.h"
#import <UIKit/UIKit.h>
#include "../ish-arm64/fs/dsh-lifecycle.h"

NSNotificationName const DSHBootStateDidChangeNotification = @"DSHBootStateDidChangeNotification";

// -boot lives in iSH's AppDelegate implementation; it is safe to run on any
// single thread because `current` is thread-local.
@interface AppDelegate (DSHBoot)
- (int)boot;
@end

@interface DSHBootCoordinator ()
@property (nonatomic, readwrite) DSHBootPhase phase;
@property (nonatomic, readwrite) double progress;
@property (nonatomic, readwrite, copy) NSString *statusMessage;
@property (nonatomic, readwrite) int bootError;
@property (nonatomic) dispatch_queue_t queue;
@property (nonatomic) BOOL started;
@end

@implementation DSHBootCoordinator

+ (instancetype)shared {
    static DSHBootCoordinator *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [DSHBootCoordinator new]; });
    return shared;
}

- (instancetype)init {
    if (self = [super init]) {
        // Serial and high priority: the whole guest lives on this thread until
        // init is started, and the user is staring at a spinner meanwhile.
        _queue = dispatch_queue_create("app.dsh.boot", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
        _statusMessage = @"Preparing the Linux environment…";
        _progress = -1;
    }
    return self;
}

- (void)setPhase:(DSHBootPhase)phase message:(NSString *)message progress:(double)progress {
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_phase = phase;
        self->_statusMessage = [message copy];
        self->_progress = progress;
        [NSNotificationCenter.defaultCenter postNotificationName:DSHBootStateDidChangeNotification object:self];
    });
}

- (void)start {
    NSAssert(NSThread.isMainThread, @"start on main");
    if (self.started)
        return;
    self.started = YES;
    [DSHLifecycleDiagnostics recordEvent:@"hostBootStarted" harness:DSHHarness.shared];
    [DSHStartupMetrics.shared beginLaunch];
    [DSHHarness.shared.log append:@"[perf] app boot coordinator started"];
    [self setPhase:DSHBootPhaseImportingImage message:@"Preparing the Linux environment…" progress:-1];
    // UIApplication is main-thread-only; grab the delegate here, not on the queue.
    AppDelegate *app = (AppDelegate *) UIApplication.sharedApplication.delegate;

    dispatch_async(self.queue, ^{
        // Native import/mount has no syscall dispatcher. Admit its complete
        // operation before Foundation or fakefs can change any host file.
        DSH_LIFECYCLE_SCOPE(-1);
        NSDate *t0 = NSDate.date;
        // 1. Import the bundled image when this build ships a new one. On a
        //    fresh install this is where the 95 MB root filesystem lands.
        DSHRootUpgrader *upgrader = DSHRootUpgrader.shared;
        [upgrader prepareRootsBeforeBootWithProgress:^(double fraction, NSString *message) {
            [self setPhase:DSHBootPhaseImportingImage
                   message:message.length ? message : @"Installing the Linux image…"
                  progress:fraction];
        }];
        NSTimeInterval imported = -t0.timeIntervalSinceNow;
        [DSHHarness.shared.log append:[NSString stringWithFormat:@"[perf] image preparation %.3fs", imported]];
        [DSHStartupMetrics.shared mark:@"image_ready"];

        // 2. Boot the emulator kernel (mount the fakefs, start init).
        [self setPhase:DSHBootPhaseBootingKernel message:@"Booting the Linux guest…" progress:-1];
        int err = [app boot];
        NSTimeInterval kernelBoot = -t0.timeIntervalSinceNow - imported;
        [DSHHarness.shared.log append:[NSString stringWithFormat:@"[perf] guest kernel boot %.3fs", kernelBoot]];
        [DSHStartupMetrics.shared mark:@"kernel_ready"];
        self.bootError = err;
        [DSHHarness.shared.log append:[NSString stringWithFormat:@"[dsh-ios] guest boot %@ (image %.1fs, total %.1fs)",
                                       err == 0 ? @"ok" : [NSString stringWithFormat:@"failed: %d", err],
                                       imported, -t0.timeIntervalSinceNow]];
        if (err < 0) {
            [self setPhase:DSHBootPhaseFailed
                   message:[NSString stringWithFormat:@"The Linux guest failed to boot (error %d).", err]
                  progress:-1];
            return;
        }

        // From here the kernel is live, so the suspend/resume socket hooks are
        // safe to use. Without this the guest's listening sockets would be
        // freed by iOS on every suspension and never rebuilt, leaving
        // dsh-serve permanently unreachable after the first background cycle.
        [ISHShellExecutor setGuestBooted:YES];

        // Keep the bundled root image and all user paths intact. Install only
        // the hash-verified session backend/controller before Harness exists.
        // Failure is explicit: never launch a partially patched backend.
        NSError *sessionInstallError = nil;
        if (![DSHSessionLifecycleInstaller installBundledPatchWithError:&sessionInstallError]) {
            [DSHHarness.shared.log append:[NSString stringWithFormat:
                @"[lifecycle] session patch install failed code=%ld operation=%@",
                (long)sessionInstallError.code, sessionInstallError.userInfo[@"operation"] ?: @"unknown"]];
            [DSHHarness.shared.log synchronizePersistentDiagnostics];
            [self setPhase:DSHBootPhaseFailed message:@"The session safety update could not be installed. Your data has been preserved." progress:-1];
            return;
        }
        [DSHHarness.shared.log append:@"[lifecycle] session patch verified"];

        NSError *webInstallError = nil;
        if (![DSHSessionLifecycleInstaller installBundledWebFetchPatchWithError:&webInstallError]) {
            [DSHHarness.shared.log append:[NSString stringWithFormat:
                @"[network] web transport patch install failed code=%ld operation=%@",
                (long)webInstallError.code, webInstallError.userInfo[@"operation"] ?: @"unknown"]];
            [DSHHarness.shared.log synchronizePersistentDiagnostics];
            [self setPhase:DSHBootPhaseFailed message:@"The web access update could not be installed. Your data has been preserved." progress:-1];
            return;
        }
        [DSHHarness.shared.log append:@"[network] web transport patch verified"];

        NSError *jobInstallError = nil;
        if (![DSHSessionLifecycleInstaller installBundledJobTrackingPatchWithError:&jobInstallError]) {
            [DSHHarness.shared.log append:[NSString stringWithFormat:@"[dsh-ios] task tracking install failed code=%ld", (long)jobInstallError.code]];
            [self setPhase:DSHBootPhaseFailed message:@"The task tracking update could not be installed. Your data has been preserved." progress:-1];
            return;
        }

        // 3. Migrate user data from a previous root, then let the harness run.
        dispatch_async(dispatch_get_main_queue(), ^{
            [DSHAppLifecycle.sharedCoordinator performWhenRunning:^{
            if (upgrader.pendingMigrationRoot != nil) {
                [self setPhase:DSHBootPhaseMigratingData message:@"Moving your sessions to the new image…" progress:-1];
                [upgrader migrateIfNeededWithCompletion:^(BOOL migrated, NSError *error) {
                    if (error)
                        [DSHHarness.shared.log append:[NSString stringWithFormat:@"[dsh-ios] migration problem: %@", error.localizedDescription]];
                    [self finishReady];
                }];
            } else {
                [self finishReady];
            }
            }];
        });
    });
}

- (void)finishReady {
    [self setPhase:DSHBootPhaseReady message:@"Starting DeepSeek Harness…" progress:-1];
    // The host bridge must be listening before dsh-serve starts: its URL and
    // token reach the guest through the server's environment.
    DSHHostBridge *bridge = DSHHostBridge.shared;
    [DSHDeviceCapability installOn:bridge];
    [DSHEventKitCapability installOn:bridge];
    [DSHHealthCapability installOn:bridge];
    [DSHLocationCapability installOn:bridge];
    [DSHContactsCapability installOn:bridge];
    [DSHNotificationCapability installOn:bridge];
    [DSHFilesCapability installOn:bridge];
    [DSHPhotosCapability installOn:bridge];
    [DSHShareCapability installOn:bridge];
    [DSHShortcutsCapability installOn:bridge];
    [DSHActivityCapability installOn:bridge];
    [DSHGuestSessionLifecycle.shared installOnBridge:bridge];
    if ([bridge start]) {
        NSMutableDictionary *env = [DSHHarness.shared.extraEnvironment mutableCopy];
        [env addEntriesFromDictionary:bridge.guestEnvironment];
        env[@"DSH_SESSION_LIFECYCLE"] = @"1";
        DSHHarness.shared.extraEnvironment = env;
    } else {
        [DSHHarness.shared.log append:@"[lifecycle] session control bridge could not start"];
        [self setPhase:DSHBootPhaseFailed message:@"The session safety service could not start. Please reopen DSH." progress:-1];
        return;
    }
    [DSHStartupMetrics.shared mark:@"bridge_ready"];
    [DSHHarness.shared start];
}

@end
