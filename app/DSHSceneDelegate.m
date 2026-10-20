//
//  DSHSceneDelegate.m
//  DSH
//

#import "DSHSceneDelegate.h"
#import "DSHRootViewController.h"
#if TARGET_OS_SIMULATOR
#import "DSHWelcomeTouchFixtureViewController.h"
#endif
#import "AppDelegate.h"
#import "AboutViewController.h"
#import "DSHHarness.h"
#import "ISHShellExecutor.h"
#import "DSHLifecycleDiagnostics.h"
#import "DSHAppLifecycle.h"
#import "DSHLifecycleCoordinator.h"

static BOOL DSHSceneIsXCTestHost(void) {
    return [NSProcessInfo.processInfo.environment[@"DSH_TEST_HOST"] isEqualToString:@"1"];
}

@implementation DSHSceneDelegate

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions {
    // Scene-session configuration survives relaunches. Use the current
    // process environment instead of persisting a different test delegate.
    // Hosted tests must not boot the guest or observe fake harness instances.
    if (DSHSceneIsXCTestHost()) {
        self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
#if TARGET_OS_SIMULATOR
        // A dedicated local WK fixture shares the hosted-test isolation: no
        // guest boots, and no fixture exists in a device build.
        BOOL optionalCancelFixture = [NSProcessInfo.processInfo.environment[@"DSH_UI_OPTIONAL_CANCEL_FIXTURE"] isEqualToString:@"1"];
        BOOL welcomeTouchFixture = [NSProcessInfo.processInfo.environment[@"DSH_UI_WELCOME_TOUCH_FIXTURE"] isEqualToString:@"1"];
        self.window.rootViewController = welcomeTouchFixture ? [DSHWelcomeTouchFixtureViewController new] :
            optionalCancelFixture ? [[DSHRootViewController alloc] init] : [UIViewController new];
#else
        self.window.rootViewController = [UIViewController new];
#endif
        [self.window makeKeyAndVisible];
        return;
    }
    (void)DSHAppLifecycle.sharedCoordinator;
    [DSHLifecycleDiagnostics recordEvent:@"sceneWillConnect" harness:DSHHarness.shared];
    UIWindowScene *windowScene = (UIWindowScene *) scene;
    self.window = [[UIWindow alloc] initWithWindowScene:windowScene];
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"recovery"]) {
        // Same escape hatch as iSH: the kernel is not booted, only settings.
        UINavigationController *vc = [[UIStoryboard storyboardWithName:@"About" bundle:nil] instantiateInitialViewController];
        ((AboutViewController *) vc.topViewController).recoveryMode = YES;
        self.window.rootViewController = vc;
    } else {
        self.window.rootViewController = [[DSHRootViewController alloc] init];
    }
    [self.window makeKeyAndVisible];
}

#pragma mark - Backgrounding

// UIKit routes this app through UIScene. One coordinator owns the finite task,
// file-operation admission, socket pairing and foreground health supervision.
- (void)sceneDidEnterBackground:(UIScene *)scene {
    if (DSHSceneIsXCTestHost()) return;
    [DSHAppLifecycle.sharedCoordinator handleAppBackground];
    [DSHLifecycleDiagnostics recordEvent:@"sceneDidEnterBackground" harness:DSHHarness.shared];
}

- (void)sceneWillEnterForeground:(UIScene *)scene {
    if (DSHSceneIsXCTestHost()) return;
    [DSHLifecycleDiagnostics recordEvent:@"sceneWillEnterForeground" harness:DSHHarness.shared];
    [DSHAppLifecycle.sharedCoordinator handleAppForeground];
}

- (void)sceneDidBecomeActive:(UIScene *)scene {
    if (DSHSceneIsXCTestHost()) return;
    [DSHAppLifecycle.sharedCoordinator handleAppForeground];
    [DSHLifecycleDiagnostics recordEvent:@"sceneDidBecomeActive" harness:DSHHarness.shared];
    UIViewController *root = self.window.rootViewController;
    if ([root isKindOfClass:DSHRootViewController.class])
        [(DSHRootViewController *) root sceneDidBecomeActive];
}

- (void)sceneWillResignActive:(UIScene *)scene {
    if (DSHSceneIsXCTestHost()) return;
    [DSHLifecycleDiagnostics recordEvent:@"sceneWillResignActive" harness:DSHHarness.shared];
}

@end
