#import "DSHSessionLifecycleInstaller.h"
#import <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <sys/stat.h>
// Import Apple headers before the guest's compatibility macros.
#include "../ish-arm64/kernel/fs.h"
#include "../ish-arm64/fs/fd.h"
#include "../ish-arm64/fs/path.h"

__attribute__((visibility("default"))) NSErrorDomain const DSHSessionLifecycleInstallerErrorDomain = @"DSHSessionLifecycleInstaller";
static NSString *const DSHSessionPackagePath = @"/usr/local/lib/node_modules/@deepseek-ai/dsh-session-persistence-jsonl/lib/index.js";
static NSString *const DSHWebFetchPackagePath = @"/usr/local/lib/node_modules/@deepseek-ai/dsh-web-fetch-http/lib/index.js";
static NSString *const DSHJobTrackingPackagePath = @"/usr/local/lib/dsh-plugins/dsh-host-bridge/index.js";
static NSUInteger const DSHSessionMaximumFileSize = 4 * 1024 * 1024;

@implementation DSHSessionLifecycleFileInfo
@end

static NSError *DSHSessionPOSIXError(int code) {
    return [NSError errorWithDomain:NSPOSIXErrorDomain code:code < 0 ? -code : code userInfo:nil];
}

static BOOL DSHSessionError(NSError **error, DSHSessionLifecycleInstallerError code,
                            NSString *operation, NSString *target, NSError *underlying) {
    if (error) {
        NSMutableDictionary *details = [@{
            NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Session lifecycle install failed (%@).", operation],
            @"operation": operation,
            @"target": target ?: @"manifest",
        } mutableCopy];
        if (underlying) details[NSUnderlyingErrorKey] = underlying;
        *error = [NSError errorWithDomain:DSHSessionLifecycleInstallerErrorDomain code:code userInfo:details];
    }
    return NO;
}

static NSString *DSHSessionSHA256(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:64];
    for (NSUInteger i = 0; i < sizeof(digest); i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

static BOOL DSHSessionIsHash(id value) {
    if (![value isKindOfClass:NSString.class] || [value length] != 64) return NO;
    return [value rangeOfCharacterFromSet:
        [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location == NSNotFound;
}

static BOOL DSHPreviousHashesAreValid(id value) {
    if (!value) return YES;
    if (![value isKindOfClass:NSArray.class] || [value count] > 8) return NO;
    NSMutableSet *seen = [NSMutableSet set];
    for (id hash in value) {
        if (!DSHSessionIsHash(hash) || [seen containsObject:hash]) return NO;
        [seen addObject:hash];
    }
    return YES;
}

@interface DSHSessionGuestFile : NSObject <DSHSessionLifecycleFile> {
    struct fd *_file;
}
- (instancetype)initWithFile:(struct fd *)file;
@end

@implementation DSHSessionGuestFile
- (instancetype)initWithFile:(struct fd *)file {
    if ((self = [super init])) _file = file;
    return self;
}
- (NSData *)readDataOfLength:(NSUInteger)length error:(NSError **)error {
    if (!_file || !_file->ops->read) { if (error) *error = DSHSessionPOSIXError(EBADF); return nil; }
    NSMutableData *data = [NSMutableData dataWithLength:length];
    ssize_t count = _file->ops->read(_file, data.mutableBytes, length);
    if (count < 0) { if (error) *error = DSHSessionPOSIXError((int)count); return nil; }
    data.length = (NSUInteger)count;
    return data;
}
- (NSInteger)writeData:(NSData *)data error:(NSError **)error {
    if (!_file || !_file->ops->write) { if (error) *error = DSHSessionPOSIXError(EBADF); return -1; }
    ssize_t count = _file->ops->write(_file, data.bytes, data.length);
    if (count < 0 && error) *error = DSHSessionPOSIXError((int)count);
    return count;
}
- (BOOL)synchronizeWithError:(NSError **)error {
    int result = _file && _file->ops->fsync ? _file->ops->fsync(_file) : -ENOTSUP;
    if (result < 0 && error) *error = DSHSessionPOSIXError(result);
    return result == 0;
}
- (BOOL)closeWithError:(NSError **)error {
    if (!_file) { if (error) *error = DSHSessionPOSIXError(EBADF); return NO; }
    struct fd *file = _file;
    _file = NULL; // fd_close consumes the description even on error.
    int result = fd_close(file);
    if (result < 0 && error) *error = DSHSessionPOSIXError(result);
    return result == 0;
}
- (void)dealloc { if (_file) fd_close(_file); }
@end

@interface DSHSessionGuestFilesystem : NSObject <DSHSessionLifecycleFilesystem>
@end
@implementation DSHSessionGuestFilesystem
- (DSHSessionLifecycleFileInfo *)infoAtPath:(NSString *)path error:(NSError **)error {
    struct statbuf value;
    int result = generic_statat(AT_PWD, path.UTF8String, &value, false);
    if (result < 0) { if (error) *error = DSHSessionPOSIXError(result); return nil; }
    DSHSessionLifecycleFileInfo *info = [DSHSessionLifecycleFileInfo new];
    info.type = S_ISREG(value.mode) ? DSHSessionLifecycleFileRegular :
        S_ISDIR(value.mode) ? DSHSessionLifecycleFileDirectory :
        S_ISLNK(value.mode) ? DSHSessionLifecycleFileSymbolicLink : DSHSessionLifecycleFileOther;
    info.permissions = value.mode & 0777;
    info.linkCount = value.nlink;
    return info;
}
- (id<DSHSessionLifecycleFile>)openForReadingAtPath:(NSString *)path error:(NSError **)error {
    // generic_open has no O_NOFOLLOW support. The installer rejects links in
    // every path component before each operation, during the pre-Harness boot
    // window; do not pass a flag the guest would silently ignore.
    struct fd *file = generic_open(path.UTF8String, O_RDONLY_, 0);
    if (IS_ERR(file)) { if (error) *error = DSHSessionPOSIXError(PTR_ERR(file)); return nil; }
    return [[DSHSessionGuestFile alloc] initWithFile:file];
}
- (id<DSHSessionLifecycleFile>)createExclusiveFileAtPath:(NSString *)path
                                           permissions:(NSUInteger)permissions error:(NSError **)error {
    struct fd *file = generic_open(path.UTF8String, O_WRONLY_ | O_CREAT_ | O_EXCL_, (int)permissions);
    if (IS_ERR(file)) { if (error) *error = DSHSessionPOSIXError(PTR_ERR(file)); return nil; }
    return [[DSHSessionGuestFile alloc] initWithFile:file];
}
- (BOOL)renamePath:(NSString *)source toPath:(NSString *)target error:(NSError **)error {
    int result = generic_renameat(AT_PWD, source.UTF8String, AT_PWD, target.UTF8String);
    if (result < 0 && error) *error = DSHSessionPOSIXError(result);
    return result == 0;
}
- (BOOL)removeTemporaryFileAtPath:(NSString *)path error:(NSError **)error {
    int result = generic_unlinkat(AT_PWD, path.UTF8String);
    if (result < 0 && error) *error = DSHSessionPOSIXError(result);
    return result == 0;
}
@end

@interface DSHSessionLifecycleInstaller ()
+ (BOOL)installBundledPackage:(DSHVerifiedSystemPackage)package error:(NSError **)error;
@property (nonatomic, copy) NSDictionary *manifest;
@property (nonatomic, copy) NSDictionary<NSString *, NSData *> *resources;
@property (nonatomic) id<DSHSessionLifecycleFilesystem> filesystem;
@property (nonatomic) DSHVerifiedSystemPackage package;
@end

@implementation DSHSessionLifecycleInstaller
+ (id<DSHSessionLifecycleFilesystem>)guestFilesystem { return [DSHSessionGuestFilesystem new]; }
+ (BOOL)installBundledPatchWithError:(NSError **)error {
    return [self installBundledPackage:DSHVerifiedSystemPackageSession error:error];
}
+ (BOOL)installBundledWebFetchPatchWithError:(NSError **)error {
    return [self installBundledPackage:DSHVerifiedSystemPackageWebFetch error:error];
}
+ (BOOL)installBundledJobTrackingPatchWithError:(NSError **)error {
    return [self installBundledPackage:DSHVerifiedSystemPackageJobTracking error:error];
}
+ (BOOL)installBundledPackage:(DSHVerifiedSystemPackage)package error:(NSError **)error {
    BOOL session = package == DSHVerifiedSystemPackageSession;
    BOOL jobs = package == DSHVerifiedSystemPackageJobTracking;
    NSURL *bundle = [NSBundle.mainBundle URLForResource:session ? @"SessionLifecycle" : jobs ? @"JobTracking" : @"WebFetchTransport" withExtension:@"bundle"];
    NSError *underlying = nil;
    NSData *manifestData = bundle ? [NSData dataWithContentsOfURL:[bundle URLByAppendingPathComponent:@"manifest.json"]
        options:0 error:&underlying] : nil;
    if (!manifestData) return DSHSessionError(error, DSHSessionLifecycleInstallerInvalidManifest, @"read manifest", nil, underlying);
    id manifest = [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:&underlying];
    if (![manifest isKindOfClass:NSDictionary.class])
        return DSHSessionError(error, DSHSessionLifecycleInstallerInvalidManifest, @"parse manifest", nil, underlying);
    NSMutableDictionary *resources = [NSMutableDictionary dictionary];
    // Flat, fixed resource names: manifest input never becomes an arbitrary URL.
    NSArray *sources = session ? @[@"session-lifecycle.mjs", @"session-lifecycle-core.mjs", @"session-checkpoint-core.mjs", @"session-backend-original.js"] : jobs ? @[@"job-tracking.mjs", @"job-ledger.mjs"] : @[@"web-fetch-transport.mjs"];
    for (NSString *source in sources) {
        NSData *data = [NSData dataWithContentsOfURL:[bundle URLByAppendingPathComponent:source]];
        if (data) resources[source] = data;
    }
    return [[[self alloc] initWithManifest:manifest resources:resources filesystem:self.guestFilesystem package:package] installWithError:error];
}
- (instancetype)initWithManifest:(NSDictionary *)manifest resources:(NSDictionary<NSString *,NSData *> *)resources
                      filesystem:(id<DSHSessionLifecycleFilesystem>)filesystem {
    return [self initWithManifest:manifest resources:resources filesystem:filesystem package:DSHVerifiedSystemPackageSession];
}
- (instancetype)initWithManifest:(NSDictionary *)manifest resources:(NSDictionary<NSString *,NSData *> *)resources
                      filesystem:(id<DSHSessionLifecycleFilesystem>)filesystem package:(DSHVerifiedSystemPackage)package {
    if ((self = [super init])) { _manifest = [manifest copy]; _resources = [resources copy]; _filesystem = filesystem; _package = package; }
    return self;
}

- (BOOL)validatePath:(NSString *)path allowMissing:(BOOL)allowMissing info:(DSHSessionLifecycleFileInfo **)result error:(NSError **)error {
    NSArray *parts = [path componentsSeparatedByString:@"/"];
    NSString *prefix = @"";
    for (NSUInteger i = 1; i < parts.count; i++) {
        prefix = [prefix stringByAppendingFormat:@"/%@", parts[i]];
        NSError *underlying = nil;
        DSHSessionLifecycleFileInfo *info = [self.filesystem infoAtPath:prefix error:&underlying];
        BOOL last = i == parts.count - 1;
        if (!info) {
            if (last && allowMissing && [underlying.domain isEqualToString:NSPOSIXErrorDomain] && underlying.code == ENOENT) {
                if (result) *result = nil;
                return YES;
            }
            return DSHSessionError(error, DSHSessionLifecycleInstallerIOFailure, @"lstat", path, underlying);
        }
        if ((!last && info.type != DSHSessionLifecycleFileDirectory) ||
            (last && (info.type != DSHSessionLifecycleFileRegular || info.linkCount != 1)))
            return DSHSessionError(error, DSHSessionLifecycleInstallerUnknownSource, @"reject link or nonregular system path", path, nil);
        if (last && result) *result = info;
    }
    return YES;
}

- (NSData *)readPath:(NSString *)path error:(NSError **)error {
    NSError *underlying = nil;
    id<DSHSessionLifecycleFile> file = [self.filesystem openForReadingAtPath:path error:&underlying];
    if (!file) { DSHSessionError(error, DSHSessionLifecycleInstallerIOFailure, @"open read", path, underlying); return nil; }
    NSMutableData *data = [NSMutableData data];
    BOOL valid = YES;
    while (YES) {
        NSData *part = [file readDataOfLength:64 * 1024 error:&underlying];
        if (!part) { valid = DSHSessionError(error, DSHSessionLifecycleInstallerIOFailure, @"read", path, underlying); break; }
        if (!part.length) break;
        if (part.length > DSHSessionMaximumFileSize - data.length) {
            valid = DSHSessionError(error, DSHSessionLifecycleInstallerUnknownSource, @"oversized source", path, nil); break;
        }
        [data appendData:part];
    }
    NSError *closeError = nil;
    if (![file closeWithError:&closeError] && valid)
        valid = DSHSessionError(error, DSHSessionLifecycleInstallerIOFailure, @"close read", path, closeError);
    return valid ? data : nil;
}

- (BOOL)validateExpectedHash:(NSString *)expectedHash atPath:(NSString *)path error:(NSError **)error {
    DSHSessionLifecycleFileInfo *info = nil;
    if (![self validatePath:path allowMissing:YES info:&info error:error]) return NO;
    if (!info && !expectedHash) return YES;
    if (!info || !expectedHash)
        return DSHSessionError(error, DSHSessionLifecycleInstallerUnknownSource, @"target changed during install", path, nil);
    NSData *existing = [self readPath:path error:error];
    if (!existing) return NO;
    if (![DSHSessionSHA256(existing) isEqual:expectedHash])
        return DSHSessionError(error, DSHSessionLifecycleInstallerUnknownSource, @"target changed during install", path, nil);
    return YES;
}

- (BOOL)atomicInstall:(NSData *)data atPath:(NSString *)path expectedHash:(NSString *)expectedHash
          permissions:(NSUInteger)permissions error:(NSError **)error {
    if (![self validateExpectedHash:expectedHash atPath:path error:error]) return NO;
    NSString *temporary = [path stringByAppendingFormat:@".dsh-session-%@.tmp", NSUUID.UUID.UUIDString];
    NSError *underlying = nil;
    id<DSHSessionLifecycleFile> file = [self.filesystem createExclusiveFileAtPath:temporary permissions:permissions error:&underlying];
    if (!file) return DSHSessionError(error, DSHSessionLifecycleInstallerIOFailure, @"create temporary", path, underlying);
    NSInteger written = [file writeData:data error:&underlying];
    BOOL valid = written >= 0 && (NSUInteger)written == data.length;
    if (!valid) DSHSessionError(error, DSHSessionLifecycleInstallerIOFailure, @"short or failed write", path, underlying);
    if (valid && ![file synchronizeWithError:&underlying])
        valid = DSHSessionError(error, DSHSessionLifecycleInstallerIOFailure, @"fsync temporary", path, underlying);
    NSError *closeError = nil;
    if (![file closeWithError:&closeError] && valid)
        valid = DSHSessionError(error, DSHSessionLifecycleInstallerIOFailure, @"close temporary", path, closeError);
    if (valid) {
        NSData *stored = [self readPath:temporary error:error];
        valid = stored != nil;
        if (valid && ![DSHSessionSHA256(stored) isEqualToString:DSHSessionSHA256(data)])
            valid = DSHSessionError(error, DSHSessionLifecycleInstallerIntegrityFailure, @"verify temporary", path, nil);
    }
    if (valid) valid = [self validateExpectedHash:expectedHash atPath:path error:error];
    if (valid && ![self.filesystem renamePath:temporary toPath:path error:&underlying])
        valid = DSHSessionError(error, DSHSessionLifecycleInstallerIOFailure, @"rename temporary", path, underlying);
    if (!valid) {
        // Remove only the exclusive temporary created by this attempt. Never
        // unlink a target or roll back an ambiguous fakefs transaction failure.
        [self.filesystem removeTemporaryFileAtPath:temporary error:nil];
        return NO;
    }
    // There is no separate success marker. Every boot verifies all final
    // contents again, including after an interrupted rename or system restart.
    return YES;
}

- (BOOL)installWithError:(NSError **)error {
    if (error) *error = nil;
    if (![self.manifest isKindOfClass:NSDictionary.class] || ![self.resources isKindOfClass:NSDictionary.class] || !self.filesystem)
        return DSHSessionError(error, DSHSessionLifecycleInstallerInvalidManifest, @"installer inputs", nil, nil);
    if (self.package != DSHVerifiedSystemPackageSession && self.package != DSHVerifiedSystemPackageWebFetch && self.package != DSHVerifiedSystemPackageJobTracking)
        return DSHSessionError(error, DSHSessionLifecycleInstallerInvalidManifest, @"package kind", nil, nil);
    BOOL session = self.package == DSHVerifiedSystemPackageSession;
    BOOL jobs = self.package == DSHVerifiedSystemPackageJobTracking;
    NSString *packagePath = session ? DSHSessionPackagePath : jobs ? DSHJobTrackingPackagePath : DSHWebFetchPackagePath;
    id patches = self.manifest[@"patches"], files = self.manifest[@"files"];
    if (![self.manifest[@"schema"] isEqual:@1] || ![patches isKindOfClass:NSArray.class] || [patches count] != 1 ||
        ![files isKindOfClass:NSArray.class] || [files count] != (session ? 3 : jobs ? 2 : 1))
        return DSHSessionError(error, DSHSessionLifecycleInstallerInvalidManifest, @"schema", nil, nil);
    NSDictionary *allowed = session ? @{
        @"session-lifecycle.mjs": @"/usr/local/share/dsh/session-lifecycle.mjs",
        @"session-lifecycle-core.mjs": @"/usr/local/share/dsh/session-lifecycle-core.mjs",
        @"session-checkpoint-core.mjs": @"/usr/local/share/dsh/session-checkpoint-core.mjs",
    } : jobs ? @{
        @"job-tracking.mjs": @"/usr/local/lib/dsh-plugins/dsh-host-bridge/job-tracking.mjs",
        @"job-ledger.mjs": @"/usr/local/lib/dsh-plugins/dsh-host-bridge/job-ledger.mjs",
    } : @{ @"web-fetch-transport.mjs": @"/usr/local/share/dsh/web-fetch-transport.mjs" };
    NSMutableSet *seen = [NSMutableSet set];
    NSMutableArray *resourcePlans = [NSMutableArray array];
    // Complete all bundle, target and original-source validation before writes.
    for (id record in files) {
        if (![record isKindOfClass:NSDictionary.class])
            return DSHSessionError(error, DSHSessionLifecycleInstallerInvalidManifest, @"file entry", nil, nil);
        id source = record[@"source"], target = record[@"target"], hash = record[@"sha256"];
        if (![source isKindOfClass:NSString.class] || ![target isKindOfClass:NSString.class] ||
            ![allowed[source] isEqual:target] || [seen containsObject:source] || !DSHSessionIsHash(hash) ||
            !DSHPreviousHashesAreValid(record[@"previous_sha256"]))
            return DSHSessionError(error, DSHSessionLifecycleInstallerInvalidManifest, @"file whitelist", nil, nil);
        [seen addObject:source];
        id data = self.resources[source];
        if (![data isKindOfClass:NSData.class] || [data length] > DSHSessionMaximumFileSize || ![DSHSessionSHA256(data) isEqual:hash])
            return DSHSessionError(error, DSHSessionLifecycleInstallerIntegrityFailure, @"bundle resource hash", target, nil);
        DSHSessionLifecycleFileInfo *info = nil;
        if (![self validatePath:target allowMissing:YES info:&info error:error]) return NO;
        if (info) {
            NSData *existing = [self readPath:target error:error];
            if (!existing) return NO;
            NSString *existingHash = DSHSessionSHA256(existing);
            if ([existingHash isEqual:hash]) continue;
            if (![record[@"previous_sha256"] containsObject:existingHash])
                return DSHSessionError(error, DSHSessionLifecycleInstallerUnknownSource, @"unrecognized existing controller", target, nil);
            [resourcePlans addObject:@{ @"target": target, @"data": data, @"expected": existingHash,
                                       @"permissions": @(info.permissions) }];
        } else [resourcePlans addObject:@{ @"target": target, @"data": data, @"permissions": @0644 }];
    }
    id patch = [patches firstObject];
    if (![patch isKindOfClass:NSDictionary.class] || ![patch[@"target"] isEqual:packagePath] ||
        !DSHSessionIsHash(patch[@"original_sha256"]) || !DSHSessionIsHash(patch[@"patched_sha256"]) ||
        !DSHPreviousHashesAreValid(patch[@"previous_sha256"]) ||
        ![patch[@"replacements"] isKindOfClass:NSArray.class] || ![patch[@"replacements"] count])
        return DSHSessionError(error, DSHSessionLifecycleInstallerInvalidManifest, @"package whitelist", nil, nil);
    DSHSessionLifecycleFileInfo *packageInfo = nil;
    if (![self validatePath:packagePath allowMissing:NO info:&packageInfo error:error]) return NO;
    NSData *original = [self readPath:packagePath error:error];
    if (!original) return NO;
    NSString *currentHash = DSHSessionSHA256(original);
    BOOL alreadyPatched = [currentHash isEqual:patch[@"patched_sha256"]];
    BOOL recognizedPrevious = [patch[@"previous_sha256"] containsObject:currentHash];
    if (!alreadyPatched && ![currentHash isEqual:patch[@"original_sha256"]] && !recognizedPrevious)
        return DSHSessionError(error, DSHSessionLifecycleInstallerUnknownSource, @"unrecognized package hash", packagePath, nil);
    NSData *base = original;
    id baseRecord = patch[@"original_source"];
    // An upgrade starts from a pinned copy of the original system module;
    // never try to reverse arbitrary source or trust an unknown installed hash.
    if (baseRecord || [patch[@"previous_sha256"] count]) {
        if (!session || ![baseRecord isKindOfClass:NSDictionary.class] ||
            ![baseRecord[@"source"] isEqual:@"session-backend-original.js"] ||
            ![baseRecord[@"sha256"] isEqual:patch[@"original_sha256"]])
            return DSHSessionError(error, DSHSessionLifecycleInstallerInvalidManifest, @"upgrade base whitelist", nil, nil);
        NSData *canonical = self.resources[@"session-backend-original.js"];
        if (![canonical isKindOfClass:NSData.class] || canonical.length > DSHSessionMaximumFileSize ||
            ![DSHSessionSHA256(canonical) isEqual:patch[@"original_sha256"]])
            return DSHSessionError(error, DSHSessionLifecycleInstallerIntegrityFailure, @"upgrade base hash", nil, nil);
        if (!alreadyPatched) base = canonical;
    }
    NSString *text = [[NSString alloc] initWithData:base encoding:NSUTF8StringEncoding];
    if (!text) return DSHSessionError(error, DSHSessionLifecycleInstallerUnknownSource, @"package UTF-8", packagePath, nil);
    // Validate every replacement even on the idempotent path.
    for (id replacement in patch[@"replacements"]) {
        if (![replacement isKindOfClass:NSDictionary.class] || ![replacement[@"find"] isKindOfClass:NSString.class] ||
            ![replacement[@"find"] length] || ![replacement[@"replace"] isKindOfClass:NSString.class] ||
            ![replacement[@"count"] isKindOfClass:NSNumber.class] || [replacement[@"count"] unsignedIntegerValue] < 1 ||
            [replacement[@"count"] unsignedIntegerValue] > DSHSessionMaximumFileSize ||
            [replacement[@"count"] doubleValue] != [replacement[@"count"] unsignedIntegerValue])
            return DSHSessionError(error, DSHSessionLifecycleInstallerInvalidManifest, @"replacement entry", nil, nil);
        if (alreadyPatched) continue;
        NSString *find = replacement[@"find"];
        NSUInteger count = [text componentsSeparatedByString:find].count - 1;
        if (count != [replacement[@"count"] unsignedIntegerValue])
            return DSHSessionError(error, DSHSessionLifecycleInstallerIntegrityFailure, @"replacement count", packagePath, nil);
        NSUInteger replacementLength = [replacement[@"replace"] lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        NSUInteger findLength = [find lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        NSUInteger textLength = [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        if (replacementLength > DSHSessionMaximumFileSize ||
            (replacementLength > findLength && count > (DSHSessionMaximumFileSize - textLength) / (replacementLength - findLength)))
            return DSHSessionError(error, DSHSessionLifecycleInstallerInvalidManifest, @"oversized replacement", nil, nil);
        text = [text stringByReplacingOccurrencesOfString:find withString:replacement[@"replace"]];
    }
    NSData *patched = alreadyPatched ? original : [text dataUsingEncoding:NSUTF8StringEncoding];
    if (patched.length > DSHSessionMaximumFileSize || ![DSHSessionSHA256(patched) isEqual:patch[@"patched_sha256"]])
        return DSHSessionError(error, DSHSessionLifecycleInstallerIntegrityFailure, @"patched package hash", packagePath, nil);
    for (NSDictionary *plan in resourcePlans)
        if (![self atomicInstall:plan[@"data"] atPath:plan[@"target"] expectedHash:plan[@"expected"]
                    permissions:[plan[@"permissions"] unsignedIntegerValue] error:error]) return NO;
    // Recheck even resources that were already current at preflight. Installing
    // a peer must not commit a package whose import changed in the meantime.
    for (NSDictionary *record in files)
        if (![self validateExpectedHash:record[@"sha256"] atPath:record[@"target"] error:error]) return NO;
    // The package rename is the final commit point: its new import can only
    // become visible after both controller files were verified and fsynced.
    if (!alreadyPatched && ![self atomicInstall:patched atPath:packagePath expectedHash:currentHash
                                  permissions:packageInfo.permissions error:error]) return NO;
    return YES;
}
@end
