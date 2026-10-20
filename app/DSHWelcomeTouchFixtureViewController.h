#import <UIKit/UIKit.h>
#import <TargetConditionals.h>

#if TARGET_OS_SIMULATOR
/// Isolated real-WK input tests; never boots or modifies a user's guest.
@interface DSHWelcomeTouchFixtureViewController : UIViewController
@end
#endif
