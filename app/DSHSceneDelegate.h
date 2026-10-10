//
//  DSHSceneDelegate.h
//  DSH
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// The app's window scene.
///
/// This delegate owns the suspend/resume half of the guest's lifecycle: with a
/// UIApplicationSceneManifest in Info.plist, UIKit routes backgrounding here and
/// never calls the equivalent UIApplicationDelegate methods, so the socket
/// preservation hooks live in DSHSceneDelegate.m rather than DSHAppDelegate.m.
@interface DSHSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, nullable) UIWindow *window;
@end

NS_ASSUME_NONNULL_END
