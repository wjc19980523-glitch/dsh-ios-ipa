// Native confirmation and document-picker result handling for streamed exports.
// The transfer store owns and removes the verified source file. This module
// never reads a guest path or deletes the user's destination copy.

#import <Foundation/Foundation.h>
#import "DSHCallConfirmation.h"

NS_ASSUME_NONNULL_BEGIN

extern DSH_EXPORTED NSString *const DSHCapabilityWorkspaceExport;

typedef void (^DSHWorkspaceExportCompletion)(NSString *state, NSString *_Nullable errorCode);

@interface DSHWorkspaceExportPresentation : NSObject
@property (atomic, readonly, getter=isFinished) BOOL finished;
/// Safe from any queue. Finishes once and dismisses only this export's picker.
- (void)cancel;
@end

@interface DSHWorkspaceExportCapability : NSObject
+ (void)registerCapability;
+ (NSString *)confirmationDetailForSourcePath:(NSString *)sourcePath
                                        name:(NSString *)name
                                       bytes:(unsigned long long)bytes;
/// Call from a background queue. No consent survives a different export.
+ (DSHConfirmationOutcome)confirmSourcePath:(NSString *)sourcePath
                                     name:(NSString *)name
                                    bytes:(unsigned long long)bytes;
+ (DSHConfirmationOutcome)confirmSourcePath:(NSString *)sourcePath
                                     name:(NSString *)name
                                    bytes:(unsigned long long)bytes
                        cancellationCheck:(BOOL (^_Nullable)(void))cancellationCheck;
/// Returns immediately. Keep the presentation alive until completion, which
/// runs once on main with saved/cancelled/timed_out/unavailable/
/// permission_denied/failed. Only a nonempty real picker result yields saved.
/// fileURL must be a verified native regular file whose basename equals name.
+ (DSHWorkspaceExportPresentation *)presentVerifiedFileURL:(NSURL *)fileURL
                                                    name:(NSString *)name
                                              completion:(DSHWorkspaceExportCompletion)completion;
@end

NS_ASSUME_NONNULL_END
