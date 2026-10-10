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

@implementation DSHSceneDelegate

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions {
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
    // iOS frees the backing socket of every listening fd this process owns
    // while it is suspended. Without this, the guest's dsh-serve keeps a
    // listen() fd that looks valid but can never accept again: the app returns
    // to the foreground, the health check correctly finds nothing listening, and
    // the harness reboots a guest that was never broken.
    // Recording the sockets here lets -sceneWillEnterForeground rebuild them.
    [ISHShellExecutor handleAppSuspend];
}

- (void)sceneWillEnterForeground:(UIScene *)scene {
    // Order matters. Rebuild the guest's listening sockets, then tell the
    // harness that its last answer describes sockets that no longer exist.
    if (![ISHShellExecutor handleAppResume]) {
        // Nothing was suspended, so the guest's sockets were never torn down and
        // there is no reason to distrust the last health check yet. Let the
        // debounce and the ordinary ladder handle it, exactly as before.
        return;
    }
    // handleAppResume returns YES only when it actually rebuilt sockets, i.e.
    // after a real suspension. At that point a cached "unreachable" is an
    // artefact of the suspension and must not count as a failure — see
    // -[DSHHarness verifyAliveAfterResumeWithCompletion:]. The probe itself is
    // trustworthy, so this still costs a restart if the server is genuinely
    // gone.
    [DSHHarness.shared verifyAliveAfterResumeWithCompletion:nil];
}

- (void)sceneDidBecomeActive:(UIScene *)scene {
    UIViewController *root = self.window.rootViewController;
    if ([root isKindOfClass:DSHRootViewController.class])
        [(DSHRootViewController *) root sceneDidBecomeActive];
}

@end
