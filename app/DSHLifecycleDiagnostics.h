#import <Foundation/Foundation.h>
@class DSHHarness;
NS_ASSUME_NONNULL_BEGIN
/// Metadata only, with a strict lock-file category whitelist. No arbitrary
/// filenames, paths, request URLs, credentials, or file contents.
@interface DSHLifecycleDiagnostics : NSObject
+ (NSDictionary *)snapshotForHarness:(DSHHarness *)harness event:(NSString *)event;
+ (void)recordEvent:(NSString *)event harness:(DSHHarness *)harness;
+ (NSString *)reportForHarness:(DSHHarness *)harness;
@end
NS_ASSUME_NONNULL_END
