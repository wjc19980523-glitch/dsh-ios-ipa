//
//  DSHSceneLifecycleTests.m
//  DSHTests
//
//  Regression tests for the suspend/resume wiring and for the lifecycle
//  diagnostics that make it observable.
//
//  Context: the guest's listening sockets have to be recorded before iOS
//  suspends the app and rebuilt afterwards (see ish-arm64/fs/sockrestart.c and
//  Apple TN2277). That was wired into DSHAppDelegate's
//  -applicationDidEnterBackground: / -applicationWillEnterForeground:, but the
//  app declares UIApplicationSceneManifest in Info.plist, so UIKit runs the
//  UIScene lifecycle and never calls those two methods. On device the hooks
//  therefore never ran, and every return from the background cost a full
//  ~40-second harness restart.
//
//  What these tests can and cannot prove is worth stating plainly. They verify
//  that the UISceneDelegate adopts the two callbacks, that they reach
//  ISHShellExecutor, and that the executor's bookkeeping and logging behave. They
//  do NOT exercise sockrestart_on_suspend()/_on_resume() themselves: those need a
//  live guest kernel, which a simulator-hosted unit test does not have -- the
//  guest is only booted on a device. The end-to-end path is a real-iPad check.
//

#import <XCTest/XCTest.h>
#import <UIKit/UIKit.h>
#import "DSHSceneDelegate.h"
#import "ISHShellExecutor.h"

@interface DSHSceneLifecycleTests : XCTestCase
@end

@implementation DSHSceneLifecycleTests

#pragma mark - The callbacks are adopted by the scene delegate

/// The delegate must actually implement the two UIScene callbacks. Declaring
/// them in a category, or in the wrong class, is the failure this catches.
- (void)testSceneDelegateAdoptsBackgroundAndForegroundCallbacks {
    XCTAssertTrue([DSHSceneDelegate instancesRespondToSelector:@selector(sceneDidEnterBackground:)],
                  @"without sceneDidEnterBackground: the guest's sockets are never recorded");
    XCTAssertTrue([DSHSceneDelegate instancesRespondToSelector:@selector(sceneWillEnterForeground:)],
                  @"without sceneWillEnterForeground: the sockets are never rebuilt");
}

/// The whole point of the move: the callbacks must be gone from the application
/// delegate. Leaving them there is harmless at runtime and actively misleading
/// during a bug hunt, because reading DSHAppDelegate.c suggests the wiring is
/// present when it never runs.
- (void)testApplicationDelegateNoLongerClaimsTheLifecycleHooks {
    Class appDelegate = NSClassFromString(@"DSHAppDelegate");
    XCTAssertNotNil(appDelegate, @"DSHAppDelegate is compiled into the test host");
    XCTAssertFalse([appDelegate instancesRespondToSelector:@selector(applicationDidEnterBackground:)],
                   @"with a UIScene manifest UIKit never calls this; it must not look like the live path");
    XCTAssertFalse([appDelegate instancesRespondToSelector:@selector(applicationWillEnterForeground:)],
                   @"with a UIScene manifest UIKit never calls this; it must not look like the live path");
}

/// Info.plist must still point at this delegate, or none of the above runs.
- (void)testInfoPlistStillRoutesTheSceneToThisDelegate {
    id manifest = [NSBundle.mainBundle objectForInfoDictionaryKey:@"UIApplicationSceneManifest"];
    XCTAssertTrue([manifest isKindOfClass:NSDictionary.class], @"the app runs the scene lifecycle");

    NSArray *configs = manifest[@"UISceneConfigurations"][@"UIWindowSceneSessionRoleApplication"];
    XCTAssertTrue([configs isKindOfClass:NSArray.class]);
    XCTAssertGreaterThan(configs.count, 0u);

    NSString *name = configs.firstObject[@"UISceneDelegateClassName"];
    XCTAssertEqualObjects(name, @"DSHSceneDelegate",
                          @"UIApplicationSceneManifest names the class UIKit instantiates");
    XCTAssertNotNil(NSClassFromString(name), @"and that class exists in the built app");
}

#pragma mark - The executor's bookkeeping

/// A resume that no suspension preceded must report that it did nothing. Every
/// plain launch produces one, and the scene delegate uses this answer to decide
/// whether the guest's network was invalidated at all.
- (void)testResumeWithoutSuspensionReportsNoRebuild {
    NSUInteger suspendsBefore = [ISHShellExecutor lifecycleSuspendCount];
    NSUInteger resumesBefore = [ISHShellExecutor lifecycleResumeCount];

    // The guest is not booted in this process, so both hooks are no-ops and
    // neither counter may move.
    XCTAssertFalse([ISHShellExecutor handleAppResume], @"nothing was suspended, so nothing is rebuilt");
    XCTAssertEqual([ISHShellExecutor lifecycleResumeCount], resumesBefore);
    XCTAssertEqual([ISHShellExecutor lifecycleSuspendCount], suspendsBefore);
}

/// The hooks must be inert before the kernel is up: there are no listening
/// sockets yet, and sockrestart's list operations assume a live kernel.
- (void)testHooksAreInertBeforeTheGuestBoots {
    [ISHShellExecutor setGuestBooted:NO];

    XCTAssertFalse([ISHShellExecutor handleAppSuspend], @"no kernel, no sockets to record");
    XCTAssertFalse([ISHShellExecutor handleAppResume], @"no kernel, nothing to rebuild");
    XCTAssertEqual([ISHShellExecutor lifecycleSuspendCount], 0u);
    XCTAssertEqual([ISHShellExecutor lifecycleResumeCount], 0u);
}

/// -setGuestBooted: must be idempotent: the boot coordinator can report success
/// once, but a rebuild or a retry must not toggle the flag off underneath a
/// live guest.
- (void)testBootFlagIsIdempotent {
    [ISHShellExecutor setGuestBooted:YES];
    [ISHShellExecutor setGuestBooted:YES];
    // Nothing to assert directly -- the flag is private -- but a double set must
    // not crash and must leave the hooks callable. A resume with no suspension
    // still answers NO, which is the observable behaviour either way.
    XCTAssertFalse([ISHShellExecutor handleAppResume]);
    [ISHShellExecutor setGuestBooted:NO];
}

@end
