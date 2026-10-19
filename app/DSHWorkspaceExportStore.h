#import <Foundation/Foundation.h>
@class DSHHostBridge;

NS_ASSUME_NONNULL_BEGIN

/// Bounded Native staging only. Guest paths are metadata, never iOS paths.
@interface DSHWorkspaceExportStore : NSObject
- (instancetype)initWithDirectory:(NSURL *)directory;
@property (nonatomic, copy) NSDate *(^clock)(void);
+ (NSUInteger)maximumBytes;
+ (NSUInteger)maximumChunkBytes;
- (nullable NSDictionary *)start:(NSDictionary *)metadata error:(NSError **)error;
- (nullable NSDictionary *)status:(NSString *)session error:(NSError **)error;
- (void)approve:(NSString *)session granted:(BOOL)granted;
- (nullable NSDictionary *)append:(NSData *)data session:(NSString *)session
                          offset:(unsigned long long)offset sha256:(NSString *)sha256 error:(NSError **)error;
- (nullable NSDictionary *)finish:(NSString *)session error:(NSError **)error;
/// Atomically claims one ready file for presentation; repeat calls return nil.
- (nullable NSURL *)claimForSaving:(NSString *)session;
- (void)complete:(NSString *)session state:(NSString *)state errorCode:(nullable NSString *)errorCode;
- (nullable NSDictionary *)cancel:(NSString *)session error:(NSError **)error;
- (void)expireSessions;
- (void)cancelPendingUI;
@end

@interface DSHWorkspaceExportStore (Installation)
+ (void)installOnBridge:(DSHHostBridge *)bridge;
@end

NS_ASSUME_NONNULL_END
