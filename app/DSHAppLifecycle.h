#import <Foundation/Foundation.h>
@class DSHLifecycleCoordinator;
@interface DSHAppLifecycle : NSObject
@property (class, nonatomic, readonly) DSHLifecycleCoordinator *sharedCoordinator;
@end
