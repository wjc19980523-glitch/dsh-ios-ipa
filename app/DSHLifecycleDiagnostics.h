#import <Foundation/Foundation.h>
@class DSHHarness;
NS_ASSUME_NONNULL_BEGIN
/// Metadata only. No file names, request URLs, credentials, or file contents.
@interface DSHLifecycleDiagnostics : NSObject
+ (NSDictionary *)snapshotForHarness:(DSHHarness *)harness event:(NSString *)event;
+ (void)recordEvent:(NSString *)event harness:(DSHHarness *)harness;
@end
NS_ASSUME_NONNULL_END
