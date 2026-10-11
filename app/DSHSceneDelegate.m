//
//  DSHSceneDelegate.m
//  DSH
//

#import "DSHSceneDelegate.h"
#import "DSHRootViewController.h"
#import "AppDelegate.h"
#import "AboutViewController.h"
#import "DSHHarness.h"
#import "ISHShellExecutor.h"
#import "DSHLifecycleDiagnostics.h"

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
        self.window.rootViewController = [UIViewController new];
        [self.window makeKeyAndVisible];
        return;
    }
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

// This app declares UIApplicationSceneManifest in Info.plist, so it runs the
// UIScene lifecycle. Since iOS 13 UIKit stops calling
// -applicationDidEnterBackground: and -applicationWillEnterForeground: for such
// apps and posts the equivalent UISceneDelegate callbacks instead. The socket
// hooks below therefore have to live *here*: while they were only in
// DSHAppDelegate they never ran on device, so the guest's listening sockets were
// never recorded or rebuilt and every return from the background cost a full
// ~40-second harness restart.
- (void)sceneDidEnterBackground:(UIScene *)scene {
    if (DSHSceneIsXCTestHost()) return;
    [DSHLifecycleDiagnostics recordEvent:@"sceneDidEnterBackground" harness:DSHHarness.shared];
    [DSHHarness.shared handleAppBackground];
    // iOS frees the backing socket of every listening fd this process owns
    // while it is suspended. Without this, the guest's dsh-serve keeps a
    // listen() fd that looks valid but can never accept again: the app returns
    // to the foreground, the health check correctly finds nothing listening, and
    // the harness reboots a guest that was never broken.
    // Recording the sockets here lets -sceneWillEnterForeground rebuild them.
    [ISHShellExecutor handleAppSuspend];
    [DSHLifecycleDiagnostics recordEvent:@"socketSuspend" harness:DSHHarness.shared];
}

- (void)sceneWillEnterForeground:(UIScene *)scene {
    if (DSHSceneIsXCTestHost()) return;
    [DSHLifecycleDiagnostics recordEvent:@"sceneWillEnterForeground" harness:DSHHarness.shared];
    [ISHShellExecutor handleAppResume];
    [DSHHarness.shared handleAppResume];
}

- (void)sceneDidBecomeActive:(UIScene *)scene {
    if (DSHSceneIsXCTestHost()) return;
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
