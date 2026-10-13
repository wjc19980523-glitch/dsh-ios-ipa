#import <Foundation/Foundation.h>
@class DSHHarness;
NS_ASSUME_NONNULL_BEGIN
/// Metadata only, with a strict lock-file category whitelist. No arbitrary
/// filenames, paths, request URLs, credentials, or file contents.
@interface DSHLifecycleDiagnostics : NSObject
+ (NSDictionary *)snapshotForHarness:(DSHHarness *)harness event:(NSString *)event;
+ (void)recordEvent:(NSString *)event harness:(DSHHarness *)harness;
+ (NSString *)reportForHarness:(DSHHarness *)harness;
/// Untrusted log text is never copied into the local/shareable report. Only
/// fixed event names, numeric metadata and enumerated values survive.
+ (nullable NSDictionary *)safeEventFromLogLine:(NSString *)line;
+ (NSDictionary *)sanitizedEvent:(NSDictionary *)event;
/// Conservative observations only. These do not diagnose a system kill or
/// drive recovery. Historical hosts and stale ACK generations stay separate.
+ (NSArray<NSDictionary<NSString *, NSString *> *> *)findingsForEvents:(NSArray<NSDictionary *> *)events
                                                 currentHostLaunchID:(NSString *)hostLaunchID;
@end
NS_ASSUME_NONNULL_END
