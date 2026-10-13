#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT __attribute__((visibility("default"))) NSErrorDomain const DSHSessionLifecycleInstallerErrorDomain;

typedef NS_ENUM(NSInteger, DSHSessionLifecycleInstallerError) {
    DSHSessionLifecycleInstallerInvalidManifest = 1,
    DSHSessionLifecycleInstallerUnknownSource,
    DSHSessionLifecycleInstallerIOFailure,
    DSHSessionLifecycleInstallerIntegrityFailure,
};

/// Each kind has a compiled-in package and resource whitelist. A manifest
/// cannot turn this installer into an arbitrary guest-file writer.
typedef NS_ENUM(NSUInteger, DSHVerifiedSystemPackage) {
    DSHVerifiedSystemPackageSession,
    DSHVerifiedSystemPackageWebFetch,
};

typedef NS_ENUM(NSUInteger, DSHSessionLifecycleFileType) {
    DSHSessionLifecycleFileRegular,
    DSHSessionLifecycleFileDirectory,
    DSHSessionLifecycleFileSymbolicLink,
    DSHSessionLifecycleFileOther,
};

/// The filesystem seam keeps fault tests independent of a live guest. The
/// production implementation below always uses the guest's normal fakefs APIs.
@interface DSHSessionLifecycleFileInfo : NSObject
@property (nonatomic) DSHSessionLifecycleFileType type;
@property (nonatomic) NSUInteger permissions;
@property (nonatomic) NSUInteger linkCount;
@end

@protocol DSHSessionLifecycleFile <NSObject>
- (nullable NSData *)readDataOfLength:(NSUInteger)length error:(NSError **)error;
/// A short write is an error for this installer, even if the adapter reports no error.
- (NSInteger)writeData:(NSData *)data error:(NSError **)error;
- (BOOL)synchronizeWithError:(NSError **)error;
/// Closing consumes the handle, including when close reports an error.
- (BOOL)closeWithError:(NSError **)error;
@end

@protocol DSHSessionLifecycleFilesystem <NSObject>
/// lstat semantics: nil + NSPOSIXErrorDomain/ENOENT means absent.
- (nullable DSHSessionLifecycleFileInfo *)infoAtPath:(NSString *)path error:(NSError **)error;
- (nullable id<DSHSessionLifecycleFile>)openForReadingAtPath:(NSString *)path error:(NSError **)error;
- (nullable id<DSHSessionLifecycleFile>)createExclusiveFileAtPath:(NSString *)path
                                                   permissions:(NSUInteger)permissions
                                                         error:(NSError **)error;
- (BOOL)renamePath:(NSString *)source toPath:(NSString *)target error:(NSError **)error;
- (BOOL)removeTemporaryFileAtPath:(NSString *)path error:(NSError **)error;
@end

@interface DSHSessionLifecycleInstaller : NSObject
/// Synchronous. Call on the admitted boot worker after kernel startup, with
/// current set to the guest root task and before launching any Harness process.
/// NO is a boot failure; callers must not start Harness after an install error.
+ (BOOL)installBundledPatchWithError:(NSError **)error;
+ (BOOL)installBundledWebFetchPatchWithError:(NSError **)error;

/// Exposed for real-fakefs integration tests as well as fault adapters. This
/// returns an adapter, not a mounted filesystem or an admission permit.
+ (id<DSHSessionLifecycleFilesystem>)guestFilesystem;
- (instancetype)initWithManifest:(NSDictionary *)manifest
                       resources:(NSDictionary<NSString *, NSData *> *)resources
                      filesystem:(id<DSHSessionLifecycleFilesystem>)filesystem;
- (instancetype)initWithManifest:(NSDictionary *)manifest
                       resources:(NSDictionary<NSString *, NSData *> *)resources
                      filesystem:(id<DSHSessionLifecycleFilesystem>)filesystem
                         package:(DSHVerifiedSystemPackage)package;
- (BOOL)installWithError:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
