#import <XCTest/XCTest.h>
#import <CommonCrypto/CommonDigest.h>
#import "DSHSessionLifecycleInstaller.h"
#include <errno.h>

static NSString *const DSHInstallerTestPackage = @"/usr/local/lib/node_modules/@deepseek-ai/dsh-session-persistence-jsonl/lib/index.js";
static NSString *const DSHInstallerTestController = @"/usr/local/share/dsh/session-lifecycle.mjs";
static NSString *const DSHInstallerTestCore = @"/usr/local/share/dsh/session-lifecycle-core.mjs";
static NSString *const DSHInstallerTestCheckpoint = @"/usr/local/share/dsh/session-checkpoint-core.mjs";
static NSString *const DSHInstallerTestOnboarding = @"/usr/local/lib/node_modules/@deepseek-ai/dsh-client-ui-settings-models/lib/client.js";

static NSData *DSHInstallerTestData(NSString *text) { return [text dataUsingEncoding:NSUTF8StringEncoding]; }
static NSString *DSHInstallerTestHash(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hash = [NSMutableString string];
    for (NSUInteger i = 0; i < sizeof(digest); i++) [hash appendFormat:@"%02x", digest[i]];
    return hash;
}

@class DSHInstallerMemoryFilesystem;
@interface DSHInstallerMemoryFile : NSObject <DSHSessionLifecycleFile>
@property (nonatomic) DSHInstallerMemoryFilesystem *filesystem;
@property (nonatomic) NSString *path;
@property (nonatomic) BOOL writable;
@property (nonatomic) BOOL closed;
@property (nonatomic) NSUInteger offset;
@end

@interface DSHInstallerMemoryFilesystem : NSObject <DSHSessionLifecycleFilesystem>
@property (nonatomic) NSMutableDictionary<NSString *, NSData *> *files;
@property (nonatomic) NSMutableSet<NSString *> *directories;
@property (nonatomic) NSMutableDictionary<NSString *, DSHSessionLifecycleFileInfo *> *overrides;
@property (nonatomic) NSMutableArray<NSString *> *createdPaths;
@property (nonatomic) NSMutableArray<NSString *> *renamedTargets;
@property (nonatomic) NSMutableArray<NSString *> *removedPaths;
@property (nonatomic) NSUInteger writeCalls;
@property (nonatomic) NSUInteger openHandles;
@property (nonatomic) NSString *failureOperation;
@property (nonatomic) NSString *failureTarget;
@property (nonatomic) NSUInteger failuresRemaining;
@property (nonatomic, copy) void (^onCreate)(void);
@property (nonatomic, copy) void (^onCloseRead)(NSString *path);
- (BOOL)failOperation:(NSString *)operation path:(NSString *)path error:(NSError **)error;
@end

@implementation DSHInstallerMemoryFile
- (NSData *)readDataOfLength:(NSUInteger)length error:(NSError **)error {
    if ([self.filesystem failOperation:@"read" path:self.path error:error]) return nil;
    NSData *data = self.filesystem.files[self.path] ?: [NSData data];
    NSUInteger amount = MIN(length, data.length - self.offset);
    NSData *part = [data subdataWithRange:NSMakeRange(self.offset, amount)];
    self.offset += amount;
    return part;
}
- (NSInteger)writeData:(NSData *)data error:(NSError **)error {
    self.filesystem.writeCalls++;
    if ([self.filesystem failOperation:@"write" path:self.path error:error]) return -1;
    if ([self.filesystem failOperation:@"shortWrite" path:self.path error:nil]) {
        NSUInteger count = data.length ? data.length - 1 : 0;
        self.filesystem.files[self.path] = [data subdataWithRange:NSMakeRange(0, count)];
        return count;
    }
    self.filesystem.files[self.path] = [data copy];
    if ([self.filesystem failOperation:@"corruptWrite" path:self.path error:nil])
        self.filesystem.files[self.path] = DSHInstallerTestData(@"silently corrupted temporary");
    return data.length;
}
- (BOOL)synchronizeWithError:(NSError **)error {
    return ![self.filesystem failOperation:self.writable ? @"fsync" : @"fsyncDirectory" path:self.path error:error];
}
- (BOOL)closeWithError:(NSError **)error {
    NSAssert(!self.closed, @"Fixture handles must close exactly once");
    self.closed = YES;
    self.filesystem.openHandles--;
    BOOL success = ![self.filesystem failOperation:self.writable ? @"closeWrite" : @"closeRead" path:self.path error:error];
    if (!self.writable && self.filesystem.onCloseRead) self.filesystem.onCloseRead(self.path);
    return success;
}
@end

@implementation DSHInstallerMemoryFilesystem
- (instancetype)init {
    if ((self = [super init])) {
        _files = [NSMutableDictionary dictionary];
        _directories = [NSMutableSet setWithObject:@"/"];
        _overrides = [NSMutableDictionary dictionary];
        _createdPaths = [NSMutableArray array];
        _renamedTargets = [NSMutableArray array];
        _removedPaths = [NSMutableArray array];
        for (NSString *path in @[DSHInstallerTestPackage, DSHInstallerTestController, DSHInstallerTestCore, DSHInstallerTestCheckpoint]) {
            NSString *parent = path.stringByDeletingLastPathComponent;
            while (parent.length > 1) { [_directories addObject:parent]; parent = parent.stringByDeletingLastPathComponent; }
        }
    }
    return self;
}
- (BOOL)failOperation:(NSString *)operation path:(NSString *)path error:(NSError **)error {
    BOOL matches = [path isEqual:self.failureTarget] ||
        [path hasPrefix:[self.failureTarget ?: @"<none>" stringByAppendingString:@".dsh-session-"]];
    if (!self.failuresRemaining || ![operation isEqual:self.failureOperation] || !matches) return NO;
    self.failuresRemaining--;
    if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EIO userInfo:nil];
    return YES;
}
- (DSHSessionLifecycleFileInfo *)infoAtPath:(NSString *)path error:(NSError **)error {
    if ([self failOperation:@"lstat" path:path error:error]) return nil;
    if (self.overrides[path]) return self.overrides[path];
    if (!self.files[path] && ![self.directories containsObject:path]) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOENT userInfo:nil];
        return nil;
    }
    DSHSessionLifecycleFileInfo *info = [DSHSessionLifecycleFileInfo new];
    info.type = self.files[path] ? DSHSessionLifecycleFileRegular : DSHSessionLifecycleFileDirectory;
    info.permissions = self.files[path] ? 0644 : 0755;
    info.linkCount = 1;
    return info;
}
- (id<DSHSessionLifecycleFile>)openForReadingAtPath:(NSString *)path error:(NSError **)error {
    if ([self failOperation:@"openRead" path:path error:error]) return nil;
    if (!self.files[path] && ![self.directories containsObject:path]) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOENT userInfo:nil];
        return nil;
    }
    DSHInstallerMemoryFile *file = [DSHInstallerMemoryFile new];
    file.filesystem = self; file.path = path;
    self.openHandles++;
    return file;
}
- (id<DSHSessionLifecycleFile>)createExclusiveFileAtPath:(NSString *)path
                                           permissions:(NSUInteger)permissions error:(NSError **)error {
    if ([self failOperation:@"create" path:path error:error]) return nil;
    if (self.files[path] || self.overrides[path]) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EEXIST userInfo:nil];
        return nil;
    }
    [self.createdPaths addObject:path];
    self.files[path] = [NSData data];
    DSHInstallerMemoryFile *file = [DSHInstallerMemoryFile new];
    file.filesystem = self; file.path = path; file.writable = YES;
    self.openHandles++;
    if (self.onCreate) self.onCreate();
    return file;
}
- (BOOL)renamePath:(NSString *)source toPath:(NSString *)target error:(NSError **)error {
    if ([self failOperation:@"rename" path:target error:error]) return NO;
    self.files[target] = self.files[source];
    [self.files removeObjectForKey:source];
    [self.renamedTargets addObject:target];
    return YES;
}
- (BOOL)removeTemporaryFileAtPath:(NSString *)path error:(NSError **)error {
    [self.removedPaths addObject:path];
    [self.files removeObjectForKey:path];
    return YES;
}
@end

@interface DSHSessionLifecycleInstallerTests : XCTestCase
@property (nonatomic) DSHInstallerMemoryFilesystem *filesystem;
@property (nonatomic) NSDictionary *manifest;
@property (nonatomic) NSDictionary<NSString *, NSData *> *resources;
@property (nonatomic) NSDictionary<NSString *, NSData *> *userSentinels;
@property (nonatomic) NSData *original;
@property (nonatomic) NSData *patched;
@property (nonatomic) NSData *onboardingPrevious;
@end

@implementation DSHSessionLifecycleInstallerTests
- (void)setUp {
    [super setUp];
    self.filesystem = [DSHInstallerMemoryFilesystem new];
    self.original = DSHInstallerTestData(@"export const state = 'original';\n");
    self.patched = DSHInstallerTestData(@"export const state = 'patched';\n");
    self.filesystem.files[DSHInstallerTestPackage] = self.original;
    self.resources = @{
        @"session-lifecycle.mjs": DSHInstallerTestData(@"import './session-lifecycle-core.mjs';\n"),
        @"session-lifecycle-core.mjs": DSHInstallerTestData(@"export const core = 1;\n"),
        @"session-checkpoint-core.mjs": DSHInstallerTestData(@"export const checkpoint = 1;\n"),
    };
    self.manifest = @{
        @"schema": @1,
        @"patches": @[@{
            @"target": DSHInstallerTestPackage,
            @"original_sha256": DSHInstallerTestHash(self.original),
            @"patched_sha256": DSHInstallerTestHash(self.patched),
            @"replacements": @[@{ @"find": @"'original'", @"replace": @"'patched'", @"count": @1 }],
        }],
        @"files": @[
            @{ @"source": @"session-lifecycle.mjs", @"target": DSHInstallerTestController,
               @"sha256": DSHInstallerTestHash(self.resources[@"session-lifecycle.mjs"]) },
            @{ @"source": @"session-lifecycle-core.mjs", @"target": DSHInstallerTestCore,
               @"sha256": DSHInstallerTestHash(self.resources[@"session-lifecycle-core.mjs"]) },
            @{ @"source": @"session-checkpoint-core.mjs", @"target": DSHInstallerTestCheckpoint,
               @"sha256": DSHInstallerTestHash(self.resources[@"session-checkpoint-core.mjs"]) },
        ],
    };
    // These are synthetic bytes, never a real API key or a user's filesystem.
    self.userSentinels = @{
        @"/root/.dsh/settings.json": DSHInstallerTestData(@"synthetic-api-key-and-config"),
        @"/root/.dsh/sessions/example/session.jsonl": DSHInstallerTestData(@"synthetic-session-history\n"),
        @"/root/.dsh/profiles/web/cordis.patch.yml": DSHInstallerTestData(@"synthetic-language-en"),
        @"/root/workspace/notes.txt": DSHInstallerTestData(@"synthetic-workspace"),
        @"/opt/custom-workspace/untracked.txt": DSHInstallerTestData(@"synthetic-custom-workspace"),
    };
    [self.filesystem.files addEntriesFromDictionary:self.userSentinels];
}
- (void)tearDown {
    for (NSString *path in self.userSentinels)
        XCTAssertEqualObjects(self.filesystem.files[path], self.userSentinels[path], @"user sentinel changed: %@", path);
    XCTAssertEqual(self.filesystem.openHandles, 0u, @"installer leaked an adapter handle");
    for (NSString *removed in self.filesystem.removedPaths)
        XCTAssertTrue([removed containsString:@".dsh-session-"], @"only owned temporary files may be removed");
    [super tearDown];
}
- (BOOL)install:(NSError **)error {
    return [[[DSHSessionLifecycleInstaller alloc] initWithManifest:self.manifest resources:self.resources
        filesystem:self.filesystem] installWithError:error];
}
- (void)primeControllers {
    self.filesystem.files[DSHInstallerTestController] = self.resources[@"session-lifecycle.mjs"];
    self.filesystem.files[DSHInstallerTestCore] = self.resources[@"session-lifecycle-core.mjs"];
    self.filesystem.files[DSHInstallerTestCheckpoint] = self.resources[@"session-checkpoint-core.mjs"];
}
- (void)setFailure:(NSString *)operation target:(NSString *)target {
    self.filesystem.failureOperation = operation;
    self.filesystem.failureTarget = target;
    self.filesystem.failuresRemaining = 1;
}
- (void)testInstallsResourcesBeforePackageAndIsIdempotent {
    NSError *error = nil;
    XCTAssertTrue([self install:&error], @"%@", error);
    XCTAssertNil(error);
    XCTAssertEqualObjects(self.filesystem.renamedTargets,
        (@[DSHInstallerTestController, DSHInstallerTestCore, DSHInstallerTestCheckpoint, DSHInstallerTestPackage]));
    XCTAssertEqualObjects(self.filesystem.files[DSHInstallerTestPackage], self.patched);
    NSUInteger writes = self.filesystem.writeCalls;
    XCTAssertTrue([self install:&error], @"%@", error);
    XCTAssertEqual(self.filesystem.writeCalls, writes);
    XCTAssertEqual(self.filesystem.createdPaths.count, 4u);
}
- (void)testUnknownPackageDoesNotWriteAnyFile {
    self.filesystem.files[DSHInstallerTestPackage] = DSHInstallerTestData(@"user customized or newer package");
    NSDictionary *before = [self.filesystem.files copy];
    NSError *error = nil;
    XCTAssertFalse([self install:&error]);
    XCTAssertEqual(error.code, DSHSessionLifecycleInstallerUnknownSource);
    XCTAssertEqualObjects(self.filesystem.files, before);
    XCTAssertEqual(self.filesystem.createdPaths.count, 0u);
}
- (void)testResourceHashFailurePreventsAllWrites {
    self.resources = @{ @"session-lifecycle.mjs": DSHInstallerTestData(@"corrupt bundle") };
    NSError *error = nil;
    XCTAssertFalse([self install:&error]);
    XCTAssertEqual(error.code, DSHSessionLifecycleInstallerIntegrityFailure);
    XCTAssertEqual(self.filesystem.createdPaths.count, 0u);
    XCTAssertEqualObjects(self.filesystem.files[DSHInstallerTestPackage], self.original);
}
- (void)testUnknownControllerIsNotOverwritten {
    self.filesystem.files[DSHInstallerTestCore] = DSHInstallerTestData(@"custom controller");
    NSDictionary *before = [self.filesystem.files copy];
    NSError *error = nil;
    XCTAssertFalse([self install:&error]);
    XCTAssertEqual(error.code, DSHSessionLifecycleInstallerUnknownSource);
    XCTAssertEqualObjects(self.filesystem.files, before);
    XCTAssertEqual(self.filesystem.createdPaths.count, 0u);
}
- (void)testAlreadyPatchedPackageStillValidatesAndRestoresMissingResources {
    self.filesystem.files[DSHInstallerTestPackage] = self.patched;
    NSError *error = nil;
    XCTAssertTrue([self install:&error], @"%@", error);
    XCTAssertEqualObjects(self.filesystem.renamedTargets, (@[DSHInstallerTestController, DSHInstallerTestCore, DSHInstallerTestCheckpoint]));
    self.resources = @{};
    XCTAssertFalse([self install:&error]);
    XCTAssertEqual(error.code, DSHSessionLifecycleInstallerIntegrityFailure);
}
- (void)testRejectsTraversalAndUserTargets {
    for (NSString *target in @[@"/root/.dsh/settings.json", @"/lib/../root/.dsh/settings.json",
                              @"/usr/local/share/dsh/../../../../root/.dsh/settings.json"]) {
        NSMutableDictionary *manifest = [self.manifest mutableCopy];
        NSMutableArray *files = [manifest[@"files"] mutableCopy];
        NSMutableDictionary *file = [files[0] mutableCopy];
        file[@"target"] = target; files[0] = file; manifest[@"files"] = files;
        DSHSessionLifecycleInstaller *installer = [[DSHSessionLifecycleInstaller alloc]
            initWithManifest:manifest resources:self.resources filesystem:self.filesystem];
        NSError *error = nil;
        XCTAssertFalse([installer installWithError:&error]);
        XCTAssertEqual(error.code, DSHSessionLifecycleInstallerInvalidManifest);
        XCTAssertEqual(self.filesystem.createdPaths.count, 0u);
    }
}
- (void)testRejectsUnknownSchemaDuplicateResourcesAndMalformedReplacement {
    NSMutableDictionary *schema = [self.manifest mutableCopy];
    schema[@"schema"] = @2;
    NSMutableDictionary *duplicate = [self.manifest mutableCopy];
    duplicate[@"files"] = @[self.manifest[@"files"][0], self.manifest[@"files"][0], self.manifest[@"files"][2]];
    NSMutableDictionary *malformed = [self.manifest mutableCopy];
    NSMutableDictionary *patch = [malformed[@"patches"][0] mutableCopy];
    patch[@"replacements"] = @[@{ @"find": @"", @"replace": @"x", @"count": @1 }];
    malformed[@"patches"] = @[patch];
    for (NSDictionary *manifest in @[schema, duplicate, malformed]) {
        DSHSessionLifecycleInstaller *installer = [[DSHSessionLifecycleInstaller alloc]
            initWithManifest:manifest resources:self.resources filesystem:self.filesystem];
        NSError *error = nil;
        XCTAssertFalse([installer installWithError:&error]);
        XCTAssertEqual(error.code, DSHSessionLifecycleInstallerInvalidManifest);
        XCTAssertEqual(self.filesystem.createdPaths.count, 0u);
    }
}
- (void)testRejectsSymlinkAtTargetOrAncestorAndHardLinkedPackage {
    for (NSString *path in @[DSHInstallerTestPackage, @"/usr/local/lib/node_modules/@deepseek-ai", DSHInstallerTestController]) {
        DSHSessionLifecycleFileInfo *info = [DSHSessionLifecycleFileInfo new];
        info.type = DSHSessionLifecycleFileSymbolicLink; info.linkCount = 1;
        self.filesystem.overrides[path] = info;
        NSError *error = nil;
        XCTAssertFalse([self install:&error]);
        XCTAssertEqual(error.code, DSHSessionLifecycleInstallerUnknownSource);
        XCTAssertEqual(self.filesystem.createdPaths.count, 0u);
        [self.filesystem.overrides removeAllObjects];
    }
    DSHSessionLifecycleFileInfo *info = [DSHSessionLifecycleFileInfo new];
    info.type = DSHSessionLifecycleFileRegular; info.linkCount = 2;
    self.filesystem.overrides[DSHInstallerTestPackage] = info;
    XCTAssertFalse([self install:nil]);
    XCTAssertEqual(self.filesystem.createdPaths.count, 0u);
}
- (void)testRejectsReplacementCountAndPatchedHashMismatchBeforeWrites {
    for (NSString *field in @[@"count", @"patched_sha256"]) {
        NSMutableDictionary *manifest = [self.manifest mutableCopy];
        NSMutableDictionary *patch = [manifest[@"patches"][0] mutableCopy];
        if ([field isEqual:@"count"]) {
            NSMutableDictionary *replacement = [patch[@"replacements"][0] mutableCopy];
            replacement[@"count"] = @2;
            patch[@"replacements"] = @[replacement];
        } else patch[@"patched_sha256"] = DSHInstallerTestHash(DSHInstallerTestData(@"wrong expected result"));
        manifest[@"patches"] = @[patch];
        DSHSessionLifecycleInstaller *installer = [[DSHSessionLifecycleInstaller alloc]
            initWithManifest:manifest resources:self.resources filesystem:self.filesystem];
        NSError *error = nil;
        XCTAssertFalse([installer installWithError:&error]);
        XCTAssertEqual(error.code, DSHSessionLifecycleInstallerIntegrityFailure);
        XCTAssertEqual(self.filesystem.createdPaths.count, 0u);
    }
}
- (void)testPackageIOFailuresPreserveOriginalAndRetrySuccessfully {
    [self primeControllers];
    for (NSString *operation in @[@"openRead", @"read", @"closeRead", @"create", @"write", @"shortWrite",
                                  @"fsync", @"closeWrite", @"corruptWrite", @"rename"]) {
        self.filesystem.files[DSHInstallerTestPackage] = self.original;
        [self setFailure:operation target:DSHInstallerTestPackage];
        NSError *error = nil;
        XCTAssertFalse([self install:&error], @"fault %@ was not propagated", operation);
        XCTAssertNotNil(error);
        XCTAssertEqualObjects(self.filesystem.files[DSHInstallerTestPackage], self.original, @"%@", operation);
        XCTAssertEqual(self.filesystem.openHandles, 0u, @"%@", operation);
        XCTAssertTrue([self install:&error], @"retry %@ failed: %@", operation, error);
        XCTAssertNil(error);
        XCTAssertEqualObjects(self.filesystem.files[DSHInstallerTestPackage], self.patched);
    }
}
- (void)testResourceFailureNeverCommitsPackageAndRetryCompletes {
    [self setFailure:@"rename" target:DSHInstallerTestCore];
    NSError *error = nil;
    XCTAssertFalse([self install:&error]);
    XCTAssertEqualObjects(self.filesystem.files[DSHInstallerTestPackage], self.original);
    XCTAssertEqualObjects(self.filesystem.files[DSHInstallerTestController], self.resources[@"session-lifecycle.mjs"]);
    XCTAssertNil(self.filesystem.files[DSHInstallerTestCore]);
    XCTAssertFalse([self.filesystem.renamedTargets containsObject:DSHInstallerTestPackage]);
    XCTAssertTrue([self install:&error], @"%@", error);
    XCTAssertEqualObjects(self.filesystem.files[DSHInstallerTestPackage], self.patched);
}
- (void)testPreflightStatFailureDoesNotCreateDirectoriesOrWriteFiles {
    [self setFailure:@"lstat" target:@"/usr/local/share/dsh"];
    NSDictionary *before = [self.filesystem.files copy];
    NSError *error = nil;
    XCTAssertFalse([self install:&error]);
    XCTAssertEqual(error.code, DSHSessionLifecycleInstallerIOFailure);
    XCTAssertEqualObjects(self.filesystem.files, before);
    XCTAssertEqual(self.filesystem.createdPaths.count, 0u);
    [self.filesystem.directories removeObject:@"/usr/local/share/dsh"];
    XCTAssertFalse([self install:&error]);
    XCTAssertEqual(self.filesystem.createdPaths.count, 0u);
}
- (void)testTargetChangedAfterPreflightIsNotOverwritten {
    [self primeControllers];
    NSData *customized = DSHInstallerTestData(@"changed after source preflight");
    __weak DSHInstallerMemoryFilesystem *filesystem = self.filesystem;
    self.filesystem.onCreate = ^{ filesystem.files[DSHInstallerTestPackage] = customized; };
    NSError *error = nil;
    XCTAssertFalse([self install:&error]);
    XCTAssertEqual(error.code, DSHSessionLifecycleInstallerUnknownSource);
    XCTAssertEqualObjects(self.filesystem.files[DSHInstallerTestPackage], customized);
    XCTAssertFalse([self.filesystem.renamedTargets containsObject:DSHInstallerTestPackage]);
}

- (void)prepareKnownPreviousRelease {
    NSData *previousPackage = DSHInstallerTestData(@"export const state = 'previous release';\n");
    NSData *previousController = DSHInstallerTestData(@"previous controller\n");
    NSData *previousCore = DSHInstallerTestData(@"previous core\n");
    self.filesystem.files[DSHInstallerTestPackage] = previousPackage;
    self.filesystem.files[DSHInstallerTestController] = previousController;
    self.filesystem.files[DSHInstallerTestCore] = previousCore;
    NSMutableDictionary *manifest = [self.manifest mutableCopy];
    NSMutableDictionary *patch = [manifest[@"patches"][0] mutableCopy];
    patch[@"previous_sha256"] = @[DSHInstallerTestHash(previousPackage)];
    patch[@"original_source"] = @{@"source": @"session-backend-original.js", @"sha256": DSHInstallerTestHash(self.original)};
    manifest[@"patches"] = @[patch];
    NSMutableArray *files = [NSMutableArray array];
    for (NSDictionary *file in manifest[@"files"]) {
        NSMutableDictionary *entry = [file mutableCopy];
        NSData *previous = self.filesystem.files[file[@"target"]];
        if (previous) entry[@"previous_sha256"] = @[DSHInstallerTestHash(previous)];
        [files addObject:entry];
    }
    manifest[@"files"] = files;
    self.manifest = manifest;
    NSMutableDictionary *resources = [self.resources mutableCopy];
    resources[@"session-backend-original.js"] = self.original;
    self.resources = resources;
}
- (void)testKnownPreviousReleaseUpgradesFromPinnedOriginalAndIsIdempotent {
    [self prepareKnownPreviousRelease];
    NSError *error = nil;
    XCTAssertTrue([self install:&error], @"%@", error);
    XCTAssertEqualObjects(self.filesystem.files[DSHInstallerTestPackage], self.patched);
    XCTAssertEqualObjects(self.filesystem.renamedTargets, (@[DSHInstallerTestController, DSHInstallerTestCore, DSHInstallerTestCheckpoint, DSHInstallerTestPackage]));
    NSUInteger writes = self.filesystem.writeCalls;
    XCTAssertTrue([self install:&error], @"%@", error);
    XCTAssertEqual(self.filesystem.writeCalls, writes);
}
- (void)testInterruptedKnownUpgradeResumesWithoutTouchingUserFiles {
    [self prepareKnownPreviousRelease];
    NSData *previousPackage = self.filesystem.files[DSHInstallerTestPackage];
    [self setFailure:@"rename" target:DSHInstallerTestCore];
    NSError *error = nil;
    XCTAssertFalse([self install:&error]);
    XCTAssertEqualObjects(self.filesystem.files[DSHInstallerTestPackage], previousPackage);
    XCTAssertEqualObjects(self.filesystem.files[DSHInstallerTestController], self.resources[@"session-lifecycle.mjs"]);
    XCTAssertTrue([self install:&error], @"%@", error);
    XCTAssertEqualObjects(self.filesystem.files[DSHInstallerTestPackage], self.patched);
}
- (void)testUpgradeRejectsCorruptCanonicalBaseBeforeAnyWrite {
    [self prepareKnownPreviousRelease];
    NSMutableDictionary *resources = [self.resources mutableCopy];
    resources[@"session-backend-original.js"] = DSHInstallerTestData(@"not the pinned source");
    self.resources = resources;
    NSDictionary *before = [self.filesystem.files copy];
    NSError *error = nil;
    XCTAssertFalse([self install:&error]);
    XCTAssertEqual(error.code, DSHSessionLifecycleInstallerIntegrityFailure);
    XCTAssertEqualObjects(self.filesystem.files, before);
    XCTAssertEqual(self.filesystem.createdPaths.count, 0u);
}
- (void)testPreviousReleaseRequiresCanonicalBaseAndRejectsUnknownPackage {
    [self prepareKnownPreviousRelease];
    NSMutableDictionary *manifest = [self.manifest mutableCopy];
    NSMutableDictionary *patch = [manifest[@"patches"][0] mutableCopy];
    [patch removeObjectForKey:@"original_source"];
    manifest[@"patches"] = @[patch];
    NSDictionary *valid = self.manifest;
    self.manifest = manifest;
    XCTAssertFalse([self install:nil]);
    XCTAssertEqual(self.filesystem.createdPaths.count, 0u);
    self.manifest = valid;
    self.filesystem.files[DSHInstallerTestPackage] = DSHInstallerTestData(@"unrecognized release");
    XCTAssertFalse([self install:nil]);
    XCTAssertEqual(self.filesystem.createdPaths.count, 0u);
}
- (void)testUpgradeDoesNotOverwriteControllerChangedAfterPreflight {
    [self prepareKnownPreviousRelease];
    NSData *changed = DSHInstallerTestData(@"externally changed controller");
    __weak DSHInstallerMemoryFilesystem *filesystem = self.filesystem;
    self.filesystem.onCreate = ^{ filesystem.files[DSHInstallerTestController] = changed; };
    XCTAssertFalse([self install:nil]);
    XCTAssertEqualObjects(self.filesystem.files[DSHInstallerTestController], changed);
    XCTAssertFalse([self.filesystem.renamedTargets containsObject:DSHInstallerTestPackage]);
}
- (void)testUpgradeRejectsMalformedPreviousHashLists {
    [self prepareKnownPreviousRelease];
    NSDictionary *valid = self.manifest;
    for (id hashes in @[@"not an array", @[@"invalid"], @[DSHInstallerTestHash(self.original), DSHInstallerTestHash(self.original)]]) {
        NSMutableDictionary *manifest = [valid mutableCopy];
        NSMutableDictionary *patch = [manifest[@"patches"][0] mutableCopy];
        patch[@"previous_sha256"] = hashes;
        manifest[@"patches"] = @[patch]; self.manifest = manifest;
        XCTAssertFalse([self install:nil]);
        XCTAssertEqual(self.filesystem.createdPaths.count, 0u);
    }
}
- (void)prepareWebTransportFixture {
    NSString *package = @"/usr/local/lib/node_modules/@deepseek-ai/dsh-web-fetch-http/lib/index.js";
    NSString *resource = @"/usr/local/share/dsh/web-fetch-transport.mjs";
    NSString *parent = package.stringByDeletingLastPathComponent;
    while (parent.length > 1) { [self.filesystem.directories addObject:parent]; parent = parent.stringByDeletingLastPathComponent; }
    self.filesystem.files[package] = self.original;
    NSData *module = DSHInstallerTestData(@"export const webTransport = 1;\n");
    self.resources = @{@"web-fetch-transport.mjs": module};
    NSMutableDictionary *patch = [self.manifest[@"patches"][0] mutableCopy];
    patch[@"target"] = package;
    self.manifest = @{@"schema": @1, @"patches": @[patch], @"files": @[
        @{@"source": @"web-fetch-transport.mjs", @"target": resource, @"sha256": DSHInstallerTestHash(module)}]};
}
- (BOOL)installWeb:(NSError **)error {
    return [[[DSHSessionLifecycleInstaller alloc] initWithManifest:self.manifest resources:self.resources
        filesystem:self.filesystem package:DSHVerifiedSystemPackageWebFetch] installWithError:error];
}
- (void)testWebTransportHasItsOwnFixedWhitelistAndCommitOrder {
    [self prepareWebTransportFixture];
    NSError *error = nil;
    XCTAssertTrue([self installWeb:&error], @"%@", error);
    XCTAssertEqualObjects(self.filesystem.renamedTargets, (@[@"/usr/local/share/dsh/web-fetch-transport.mjs",
        @"/usr/local/lib/node_modules/@deepseek-ai/dsh-web-fetch-http/lib/index.js"]));
    NSUInteger writes = self.filesystem.writeCalls;
    XCTAssertTrue([self installWeb:&error]);
    XCTAssertEqual(self.filesystem.writeCalls, writes);
}
- (void)testSessionAndWebManifestsCannotCrossPackageWhitelists {
    XCTAssertFalse([self installWeb:nil]);
    [self prepareWebTransportFixture];
    XCTAssertFalse([self install:nil]);
    XCTAssertEqual(self.filesystem.createdPaths.count, 0u);
}
- (void)testWebFailurePreservesOriginalPackageAndRetryCompletes {
    [self prepareWebTransportFixture];
    NSString *package = @"/usr/local/lib/node_modules/@deepseek-ai/dsh-web-fetch-http/lib/index.js";
    NSString *resource = @"/usr/local/share/dsh/web-fetch-transport.mjs";
    [self setFailure:@"rename" target:resource];
    XCTAssertFalse([self installWeb:nil]);
    XCTAssertEqualObjects(self.filesystem.files[package], self.original);
    XCTAssertTrue([self installWeb:nil]);
    XCTAssertEqualObjects(self.filesystem.files[package], self.patched);
}
- (void)testUnknownPackageKindNeverWrites {
    DSHSessionLifecycleInstaller *installer = [[DSHSessionLifecycleInstaller alloc] initWithManifest:self.manifest
        resources:self.resources filesystem:self.filesystem package:(DSHVerifiedSystemPackage)99];
    XCTAssertFalse([installer installWithError:nil]);
    XCTAssertEqual(self.filesystem.createdPaths.count, 0u);
}

- (void)prepareJobTrackingFixture {
    NSString *package = @"/usr/local/lib/dsh-plugins/dsh-host-bridge/index.js";
    NSString *directory = package.stringByDeletingLastPathComponent;
    NSString *parent = directory;
    while (parent.length > 1) { [self.filesystem.directories addObject:parent]; parent = parent.stringByDeletingLastPathComponent; }
    self.filesystem.files[package] = self.original;
    self.resources = @{@"development-tools.mjs": DSHInstallerTestData(@"export const development = 1;"),
                       @"job-tracking.mjs": DSHInstallerTestData(@"export const tracking = 1;"),
                       @"job-ledger.mjs": DSHInstallerTestData(@"export const ledger = 1;"),
                       @"workspace-export.mjs": DSHInstallerTestData(@"export const workspaceExport = 1;")};
    NSMutableDictionary *patch = [self.manifest[@"patches"][0] mutableCopy];
    patch[@"target"] = package;
    NSMutableArray *files = [NSMutableArray array];
    for (NSString *name in @[@"development-tools.mjs", @"job-ledger.mjs", @"workspace-export.mjs", @"job-tracking.mjs"])
        [files addObject:@{@"source": name, @"target": [directory stringByAppendingPathComponent:name],
            @"sha256": DSHInstallerTestHash(self.resources[name])}];
    self.manifest = @{@"schema": @1, @"patches": @[patch], @"files": files};
}
- (BOOL)installJobs:(NSError **)error {
    return [[[DSHSessionLifecycleInstaller alloc] initWithManifest:self.manifest resources:self.resources
        filesystem:self.filesystem package:DSHVerifiedSystemPackageJobTracking] installWithError:error];
}
- (void)testJobTrackingInstallsResourcesBeforeBridgeAndIsIdempotent {
    [self prepareJobTrackingFixture];
    NSError *error = nil;
    XCTAssertTrue([self installJobs:&error], @"%@", error);
    XCTAssertEqualObjects(self.filesystem.renamedTargets, (@[
        @"/usr/local/lib/dsh-plugins/dsh-host-bridge/development-tools.mjs",
        @"/usr/local/lib/dsh-plugins/dsh-host-bridge/job-ledger.mjs",
        @"/usr/local/lib/dsh-plugins/dsh-host-bridge/workspace-export.mjs",
        @"/usr/local/lib/dsh-plugins/dsh-host-bridge/job-tracking.mjs",
        @"/usr/local/lib/dsh-plugins/dsh-host-bridge/index.js"]));
    NSUInteger writes = self.filesystem.writeCalls;
    XCTAssertTrue([self installJobs:&error]);
    XCTAssertEqual(self.filesystem.writeCalls, writes);
}
- (void)testJobTrackingManifestCannotWriteSessionOrWebPackages {
    NSDictionary *sessionManifest = self.manifest;
    NSDictionary *sessionResources = self.resources;
    [self prepareJobTrackingFixture];
    // Keep the jobs schema and bridge patch valid so the foreign session
    // resources are rejected by their whitelist, not by the four-file count.
    NSMutableDictionary *foreignSession = [self.manifest mutableCopy];
    NSMutableArray *foreignFiles = [sessionManifest[@"files"] mutableCopy];
    [foreignFiles addObject:self.manifest[@"files"][3]];
    foreignSession[@"files"] = foreignFiles;
    self.manifest = foreignSession;
    NSMutableDictionary *foreignResources = [self.resources mutableCopy];
    [foreignResources addEntriesFromDictionary:sessionResources];
    self.resources = foreignResources;
    NSError *error = nil;
    XCTAssertFalse([self installJobs:&error]);
    XCTAssertEqualObjects(error.domain, @"DSHSessionLifecycleInstaller");
    XCTAssertEqual(error.code, DSHSessionLifecycleInstallerInvalidManifest);
    XCTAssertEqualObjects(error.userInfo[@"operation"], @"file whitelist");
    XCTAssertEqualObjects(error.userInfo[@"target"], @"manifest");
    [self prepareJobTrackingFixture];
    // Session expects three resources; exercise its whitelist with a matched
    // count, independently of the expanded jobs schema.
    NSDictionary *completeJobsManifest = self.manifest;
    NSMutableDictionary *sessionShape = [self.manifest mutableCopy];
    sessionShape[@"files"] = [self.manifest[@"files"] subarrayWithRange:NSMakeRange(0,3)];
    self.manifest = sessionShape;
    XCTAssertFalse([self install:&error]);
    XCTAssertEqual(error.code, DSHSessionLifecycleInstallerInvalidManifest);
    XCTAssertEqualObjects(error.userInfo[@"operation"], @"file whitelist");
    self.manifest = completeJobsManifest;
    // Match the web installer's resource count so this exercises its resource
    // whitelist, rather than passing because an unrelated schema check failed.
    NSDictionary *jobsManifest = self.manifest;
    NSMutableDictionary *webShape = [jobsManifest mutableCopy];
    webShape[@"files"] = @[jobsManifest[@"files"][0]];
    self.manifest = webShape;
    XCTAssertFalse([self installWeb:&error]);
    XCTAssertEqual(error.code, DSHSessionLifecycleInstallerInvalidManifest);
    XCTAssertEqualObjects(error.userInfo[@"operation"], @"file whitelist");
    XCTAssertEqualObjects(error.userInfo[@"target"], @"manifest");
    // Also prove that otherwise-valid tracking resources cannot authorize
    // writing either protected package through a forged patch target.
    for (NSString *target in @[
        @"/usr/local/lib/node_modules/@deepseek-ai/dsh-session-persistence-jsonl/lib/index.js",
        @"/usr/local/lib/node_modules/@deepseek-ai/dsh-web-fetch-http/lib/index.js"]) {
        NSMutableDictionary *foreign = [jobsManifest mutableCopy];
        NSMutableDictionary *patch = [jobsManifest[@"patches"][0] mutableCopy];
        patch[@"target"] = target; foreign[@"patches"] = @[patch]; self.manifest = foreign;
        XCTAssertFalse([self installJobs:&error]);
        XCTAssertEqual(error.code, DSHSessionLifecycleInstallerInvalidManifest);
        XCTAssertEqualObjects(error.userInfo[@"operation"], @"package whitelist");
        XCTAssertEqualObjects(error.userInfo[@"target"], @"manifest");
    }
    XCTAssertEqual(self.filesystem.createdPaths.count, 0u);
}
- (void)testUnknownBridgeIsPreservedWithoutAnyTrackingResourceWrites {
    [self prepareJobTrackingFixture];
    NSString *package = @"/usr/local/lib/dsh-plugins/dsh-host-bridge/index.js";
    NSData *unknown = DSHInstallerTestData(@"user-customized-bridge");
    self.filesystem.files[package] = unknown;
    NSError *error = nil;
    XCTAssertFalse([self installJobs:&error]);
    XCTAssertEqualObjects(error.domain, @"DSHSessionLifecycleInstaller");
    XCTAssertEqual(error.code, DSHSessionLifecycleInstallerUnknownSource);
    XCTAssertEqualObjects(error.userInfo[@"operation"], @"unrecognized package hash");
    XCTAssertEqualObjects(error.userInfo[@"target"], package);
    XCTAssertEqualObjects(self.filesystem.files[package], unknown);
    XCTAssertEqual(self.filesystem.createdPaths.count, 0u);
}
- (void)testUnknownDevelopmentHelperIsPreservedWithoutAnyTrackingResourceWrites {
    [self prepareJobTrackingFixture];
    NSString *helper = @"/usr/local/lib/dsh-plugins/dsh-host-bridge/development-tools.mjs";
    NSData *unknown = DSHInstallerTestData(@"user-customized-development-helper");
    self.filesystem.files[helper] = unknown;
    NSError *error = nil;
    XCTAssertFalse([self installJobs:&error]);
    XCTAssertEqual(error.code, DSHSessionLifecycleInstallerUnknownSource);
    XCTAssertEqualObjects(error.userInfo[@"operation"], @"unrecognized existing controller");
    XCTAssertEqualObjects(error.userInfo[@"target"], helper);
    XCTAssertEqualObjects(self.filesystem.files[helper], unknown);
    XCTAssertEqual(self.filesystem.createdPaths.count, 0u);
}
- (void)testKnownTrackingControllerUpgradeCommitsHelperFirstAndPreservesLedger {
    [self prepareJobTrackingFixture];
    NSString *prefix = @"/usr/local/lib/dsh-plugins/dsh-host-bridge/";
    NSString *controller = [prefix stringByAppendingString:@"job-tracking.mjs"];
    NSString *ledger = [prefix stringByAppendingString:@"job-ledger.mjs"];
    self.filesystem.files[[prefix stringByAppendingString:@"index.js"]] = self.patched;
    self.filesystem.files[ledger] = self.resources[@"job-ledger.mjs"];
    NSData *previous = DSHInstallerTestData(@"known-old-tracking-controller");
    self.filesystem.files[controller] = previous;
    NSMutableDictionary *manifest = [self.manifest mutableCopy];
    NSMutableArray *files = [self.manifest[@"files"] mutableCopy];
    NSMutableDictionary *record = [files[3] mutableCopy];
    record[@"previous_sha256"] = @[DSHInstallerTestHash(previous)];
    files[3] = record; manifest[@"files"] = files; self.manifest = manifest;
    XCTAssertTrue([self installJobs:nil]);
    XCTAssertEqualObjects(self.filesystem.renamedTargets, (@[
        [prefix stringByAppendingString:@"development-tools.mjs"],
        [prefix stringByAppendingString:@"workspace-export.mjs"], controller]));
    XCTAssertEqualObjects(self.filesystem.files[ledger], self.resources[@"job-ledger.mjs"]);
}
- (void)prepareOnboardingFixture {
    NSString *parent = DSHInstallerTestOnboarding.stringByDeletingLastPathComponent;
    while (parent.length > 1) { [self.filesystem.directories addObject:parent]; parent = parent.stringByDeletingLastPathComponent; }
    self.filesystem.files[DSHInstallerTestOnboarding] = self.original;
    NSMutableDictionary *patch = [self.manifest[@"patches"][0] mutableCopy];
    patch[@"target"] = DSHInstallerTestOnboarding;
    self.manifest = @{@"schema": @1, @"patches": @[patch], @"files": @[]};
    self.resources = @{};
}
- (BOOL)installOnboarding:(NSError **)error {
    return [[[DSHSessionLifecycleInstaller alloc] initWithManifest:self.manifest resources:self.resources
        filesystem:self.filesystem package:DSHVerifiedSystemPackageOnboardingInteraction] installWithError:error];
}
- (void)testOnboardingInstallsOnlyItsPinnedModuleAndIsIdempotent {
    [self prepareOnboardingFixture];
    NSError *error = nil;
    XCTAssertTrue([self installOnboarding:&error], @"%@", error);
    XCTAssertNil(error);
    XCTAssertEqualObjects(self.filesystem.renamedTargets, (@[DSHInstallerTestOnboarding]));
    XCTAssertEqualObjects(self.filesystem.files[DSHInstallerTestOnboarding], self.patched);
    XCTAssertEqualObjects(self.filesystem.files[DSHInstallerTestPackage], self.original);
    NSUInteger writes = self.filesystem.writeCalls;
    XCTAssertTrue([self installOnboarding:&error], @"%@", error);
    XCTAssertNil(error);
    XCTAssertEqual(self.filesystem.writeCalls, writes);
    XCTAssertEqual(self.filesystem.createdPaths.count, 1u);
}
- (void)testOnboardingAndSessionKindsCannotCrossPackageTargets {
    NSDictionary *sessionManifest = self.manifest;
    NSDictionary *sessionResources = self.resources;
    [self prepareOnboardingFixture];
    NSDictionary *valid = self.manifest;
    for (NSString *target in @[
        DSHInstallerTestPackage,
        @"/usr/local/lib/node_modules/@deepseek-ai/dsh-web-fetch-http/lib/index.js",
        @"/usr/local/lib/dsh-plugins/dsh-host-bridge/index.js",
        @"/root/.dsh/settings.json",
        [DSHInstallerTestOnboarding stringByAppendingString:@".other"],
        [DSHInstallerTestOnboarding stringByAppendingString:@"/../client.js"]]) {
        NSMutableDictionary *manifest = [valid mutableCopy];
        NSMutableDictionary *patch = [valid[@"patches"][0] mutableCopy];
        patch[@"target"] = target; manifest[@"patches"] = @[patch]; self.manifest = manifest;
        NSError *error = nil;
        XCTAssertFalse([self installOnboarding:&error], @"%@", target);
        XCTAssertEqual(error.code, DSHSessionLifecycleInstallerInvalidManifest);
        XCTAssertEqualObjects(error.userInfo[@"operation"], @"package whitelist");
    }
    // Give the session kind its valid resources and schema so rejection tests
    // the target whitelist rather than an unrelated resource-count check.
    NSMutableDictionary *foreign = [sessionManifest mutableCopy];
    NSMutableDictionary *patch = [sessionManifest[@"patches"][0] mutableCopy];
    patch[@"target"] = DSHInstallerTestOnboarding; foreign[@"patches"] = @[patch];
    DSHSessionLifecycleInstaller *installer = [[DSHSessionLifecycleInstaller alloc]
        initWithManifest:foreign resources:sessionResources filesystem:self.filesystem package:DSHVerifiedSystemPackageSession];
    NSError *error = nil;
    XCTAssertFalse([installer installWithError:&error]);
    XCTAssertEqualObjects(error.userInfo[@"operation"], @"package whitelist");
    XCTAssertEqual(self.filesystem.createdPaths.count, 0u);
    XCTAssertEqualObjects(self.filesystem.files[DSHInstallerTestOnboarding], self.original);
}
- (void)testOnboardingRejectsAdditionalFilesAndResourcesBeforeWrites {
    [self prepareOnboardingFixture];
    NSDictionary *valid = self.manifest;
    NSData *extra = DSHInstallerTestData(@"unexpected helper");
    NSMutableDictionary *manifest = [valid mutableCopy];
    manifest[@"files"] = @[@{@"source": @"helper.mjs", @"target": @"/usr/local/share/dsh/helper.mjs",
                              @"sha256": DSHInstallerTestHash(extra)}];
    self.manifest = manifest;
    NSError *error = nil;
    XCTAssertFalse([self installOnboarding:&error]);
    XCTAssertEqual(error.code, DSHSessionLifecycleInstallerInvalidManifest);
    XCTAssertEqualObjects(error.userInfo[@"operation"], @"schema");
    self.manifest = valid;
    self.resources = @{@"helper.mjs": extra};
    XCTAssertFalse([self installOnboarding:&error]);
    XCTAssertEqual(error.code, DSHSessionLifecycleInstallerInvalidManifest);
    XCTAssertEqualObjects(error.userInfo[@"operation"], @"resource whitelist");
    XCTAssertEqual(self.filesystem.createdPaths.count, 0u);
    XCTAssertEqual(self.filesystem.writeCalls, 0u);
    XCTAssertEqualObjects(self.filesystem.files[DSHInstallerTestOnboarding], self.original);
}
- (void)testOnboardingRejectsUnknownSourceAndInvalidPatchResultBeforeWrites {
    [self prepareOnboardingFixture];
    NSDictionary *valid = self.manifest;
    for (NSString *fault in @[@"unknown source", @"count", @"hash"]) {
        self.filesystem.files[DSHInstallerTestOnboarding] = [fault isEqual:@"unknown source"] ?
            DSHInstallerTestData(@"custom or newer onboarding module") : self.original;
        NSMutableDictionary *manifest = [valid mutableCopy];
        NSMutableDictionary *patch = [valid[@"patches"][0] mutableCopy];
        if ([fault isEqual:@"count"]) {
            NSMutableDictionary *replacement = [patch[@"replacements"][0] mutableCopy];
            replacement[@"count"] = @2; patch[@"replacements"] = @[replacement];
        } else if ([fault isEqual:@"hash"]) {
            patch[@"patched_sha256"] = DSHInstallerTestHash(DSHInstallerTestData(@"unmatched result"));
        }
        manifest[@"patches"] = @[patch]; self.manifest = manifest;
        NSDictionary *before = [self.filesystem.files copy];
        NSError *error = nil;
        XCTAssertFalse([self installOnboarding:&error], @"%@", fault);
        XCTAssertEqual(error.code, [fault isEqual:@"unknown source"] ?
            DSHSessionLifecycleInstallerUnknownSource : DSHSessionLifecycleInstallerIntegrityFailure);
        XCTAssertEqualObjects(self.filesystem.files, before, @"%@", fault);
        XCTAssertEqual(self.filesystem.createdPaths.count, 0u);
        XCTAssertEqual(self.filesystem.writeCalls, 0u);
    }
}
- (void)testOnboardingAtomicFailuresPreserveOriginalAndAllowRetry {
    [self prepareOnboardingFixture];
    for (NSString *operation in @[@"create", @"write", @"shortWrite", @"fsync", @"closeWrite", @"corruptWrite", @"rename"]) {
        self.filesystem.files[DSHInstallerTestOnboarding] = self.original;
        NSDictionary *before = [self.filesystem.files copy];
        [self setFailure:operation target:DSHInstallerTestOnboarding];
        NSError *error = nil;
        XCTAssertFalse([self installOnboarding:&error], @"fault %@ was not propagated", operation);
        XCTAssertNotNil(error);
        XCTAssertEqualObjects(self.filesystem.files, before, @"%@ left a changed target or temporary", operation);
        XCTAssertEqual(self.filesystem.openHandles, 0u, @"%@", operation);
        XCTAssertTrue([self installOnboarding:&error], @"retry %@ failed: %@", operation, error);
        XCTAssertNil(error);
        XCTAssertEqualObjects(self.filesystem.files[DSHInstallerTestOnboarding], self.patched);
        XCTAssertEqualObjects(self.filesystem.files[DSHInstallerTestPackage], self.original);
    }
}
- (void)testActualOnboardingBundleHasOnlyItsPinnedInlinePatch {
    NSURL *bundle = [NSBundle.mainBundle URLForResource:@"OnboardingInteraction" withExtension:@"bundle"];
    XCTAssertNotNil(bundle);
    NSData *data = bundle ? [NSData dataWithContentsOfURL:[bundle URLByAppendingPathComponent:@"manifest.json"]] : nil;
    XCTAssertNotNil(data);
    if (!data) return;
    NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    XCTAssertEqualObjects(manifest[@"schema"], @1);
    XCTAssertEqualObjects(manifest[@"files"], @[]);
    XCTAssertEqual([manifest[@"patches"] count], 1u);
    NSDictionary *patch = [manifest[@"patches"] firstObject];
    XCTAssertEqualObjects(patch[@"target"], DSHInstallerTestOnboarding);
    XCTAssertEqual([patch[@"original_sha256"] length], 64u);
    XCTAssertEqual([patch[@"patched_sha256"] length], 64u);
    XCTAssertNotEqualObjects(patch[@"original_sha256"], patch[@"patched_sha256"]);
    XCTAssertGreaterThan([patch[@"replacements"] count], 0u);
    NSDictionary *base = patch[@"original_source"];
    XCTAssertTrue([base isKindOfClass:NSDictionary.class]);
    if (![base isKindOfClass:NSDictionary.class]) return;
    XCTAssertEqualObjects(base, (@{@"source": @"onboarding-client-original.js",
        @"sha256": @"7674ed0ba2eef60fa7db91b4bf8cea4dc23e1f0a2f3dd1e6a2a67ad4c0d005fa"}));
    XCTAssertEqualObjects(patch[@"original_sha256"], base[@"sha256"]);
    XCTAssertEqualObjects(patch[@"previous_sha256"],
        (@[@"b687b66611b19ac8ebb793bc128c4c56675fc0fc6c7df8f7ddae6195134339b5"]));
    NSData *canonical = [NSData dataWithContentsOfURL:[bundle URLByAppendingPathComponent:@"onboarding-client-original.js"]];
    XCTAssertNotNil(canonical);
    XCTAssertEqual(canonical.length, 186641u);
    XCTAssertEqualObjects(DSHInstallerTestHash(canonical), base[@"sha256"]);
}

// Actual bundled canonical bytes are required. These tests must not skip when
// the future Onboarding upgrade resource/manifest has not been integrated.
- (NSData *)applyOnboardingReplacements:(NSArray *)replacements toData:(NSData *)original {
    NSString *text = [[NSString alloc] initWithData:original encoding:NSUTF8StringEncoding];
    XCTAssertNotNil(text);
    if (!text) return nil;
    for (NSDictionary *replacement in replacements) {
        NSString *find = replacement[@"find"], *value = replacement[@"replace"];
        NSUInteger count = [text componentsSeparatedByString:find].count - 1;
        XCTAssertEqual(count, [replacement[@"count"] unsignedIntegerValue]);
        if (count != [replacement[@"count"] unsignedIntegerValue]) return nil;
        text = [text stringByReplacingOccurrencesOfString:find withString:value];
    }
    return [text dataUsingEncoding:NSUTF8StringEncoding];
}
- (BOOL)prepareActualOnboardingUpgradeFixture {
    NSURL *bundle = [NSBundle.mainBundle URLForResource:@"OnboardingInteraction" withExtension:@"bundle"];
    NSData *manifestData = bundle ? [NSData dataWithContentsOfURL:[bundle URLByAppendingPathComponent:@"manifest.json"]] : nil;
    NSData *canonical = bundle ? [NSData dataWithContentsOfURL:[bundle URLByAppendingPathComponent:@"onboarding-client-original.js"]] : nil;
    XCTAssertNotNil(manifestData); XCTAssertNotNil(canonical);
    if (!manifestData || !canonical) return NO;
    NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:nil];
    XCTAssertEqualObjects(manifest[@"files"], @[]);
    XCTAssertEqual([manifest[@"patches"] count], 1u);
    NSDictionary *patch = [manifest[@"patches"] firstObject];
    NSArray *replacements = patch[@"replacements"];
    XCTAssertGreaterThan(replacements.count, 3u, @"retain the three original API touch patches and add the explicit Welcome change");
    if (replacements.count <= 3) return NO;
    XCTAssertEqual(canonical.length, 186641u);
    XCTAssertEqualObjects(DSHInstallerTestHash(canonical), @"7674ed0ba2eef60fa7db91b4bf8cea4dc23e1f0a2f3dd1e6a2a67ad4c0d005fa");
    NSData *previous = [self applyOnboardingReplacements:[replacements subarrayWithRange:NSMakeRange(0, 3)] toData:canonical];
    XCTAssertEqual(previous.length, 191089u);
    XCTAssertEqualObjects(DSHInstallerTestHash(previous), @"b687b66611b19ac8ebb793bc128c4c56675fc0fc6c7df8f7ddae6195134339b5");
    NSData *patched = [self applyOnboardingReplacements:replacements toData:canonical];
    XCTAssertNotNil(patched);
    XCTAssertEqualObjects(DSHInstallerTestHash(patched), patch[@"patched_sha256"]);
    if (!previous || !patched) return NO;
    self.manifest = manifest;
    self.resources = @{@"onboarding-client-original.js": canonical};
    self.original = canonical; self.onboardingPrevious = previous; self.patched = patched;
    NSString *parent = DSHInstallerTestOnboarding.stringByDeletingLastPathComponent;
    while (parent.length > 1) { [self.filesystem.directories addObject:parent]; parent = parent.stringByDeletingLastPathComponent; }
    self.filesystem.files[DSHInstallerTestOnboarding] = previous;
    return YES;
}
- (void)testActualOnboardingFreshAndBuild29UpgradeAreExactAndIdempotent {
    if (![self prepareActualOnboardingUpgradeFixture]) return;
    NSDictionary *peers = [self.filesystem.files copy];
    for (NSData *source in @[self.original, self.onboardingPrevious]) {
        self.filesystem.files[DSHInstallerTestOnboarding] = source;
        NSUInteger writes = self.filesystem.writeCalls, renames = self.filesystem.renamedTargets.count;
        NSError *error = nil;
        XCTAssertTrue([self installOnboarding:&error], @"%@", error);
        XCTAssertNil(error);
        XCTAssertEqualObjects(self.filesystem.files[DSHInstallerTestOnboarding], self.patched);
        XCTAssertEqual(self.filesystem.writeCalls, writes + 1);
        XCTAssertEqualObjects([self.filesystem.renamedTargets subarrayWithRange:NSMakeRange(renames, 1)], (@[DSHInstallerTestOnboarding]));
        writes = self.filesystem.writeCalls;
        XCTAssertTrue([self installOnboarding:&error], @"%@", error);
        XCTAssertNil(error);
        XCTAssertEqual(self.filesystem.writeCalls, writes);
    }
    for (NSString *path in peers)
        if (![path isEqual:DSHInstallerTestOnboarding]) XCTAssertEqualObjects(self.filesystem.files[path], peers[path]);
}
- (void)testOnboardingUpgradeResourceWhitelistAndHashFailEvenWhenAlreadyCurrent {
    if (![self prepareActualOnboardingUpgradeFixture]) return;
    NSDictionary *valid = self.resources;
    NSData *canonical = valid[@"onboarding-client-original.js"];
    NSArray *invalid = @[@{}, @{@"onboarding-client-original.js": DSHInstallerTestData(@"corrupt")},
        @{@"onboarding-client-original.js": [NSMutableData dataWithLength:4 * 1024 * 1024 + 1]},
        @{@"onboarding-client-original.js": (id)@"wrong type"},
        @{@"session-backend-original.js": canonical},
        @{@"onboarding-client-original.js": canonical, @"unexpected.mjs": canonical}];
    for (NSData *source in @[self.onboardingPrevious, self.patched]) for (NSDictionary *resources in invalid) {
        self.filesystem.files[DSHInstallerTestOnboarding] = source;
        self.resources = resources;
        NSDictionary *before = [self.filesystem.files copy]; NSError *error = nil;
        XCTAssertFalse([self installOnboarding:&error]); XCTAssertNotNil(error);
        XCTAssertEqualObjects(self.filesystem.files, before);
        XCTAssertEqual(self.filesystem.writeCalls, 0u); XCTAssertEqual(self.filesystem.createdPaths.count, 0u);
    }
    self.resources = valid;
}
- (void)testOnboardingUpgradeRequiresOnlyPinnedBaseAndKnownBuild29Previous {
    if (![self prepareActualOnboardingUpgradeFixture]) return;
    NSDictionary *valid = self.manifest;
    NSArray *badBases = @[@{},
        @{@"source": @"onboarding-client-original.js", @"sha256": DSHInstallerTestHash(self.original), @"unexpected": @YES},
        @{@"source": @"session-backend-original.js", @"sha256": DSHInstallerTestHash(self.original)},
        @{@"source": @"onboarding-client-original.js", @"sha256": DSHInstallerTestHash(self.onboardingPrevious)}];
    NSArray *badPrevious = @[@[], @[@"invalid"], @[@"7674ed0ba2eef60fa7db91b4bf8cea4dc23e1f0a2f3dd1e6a2a67ad4c0d005fa"],
        @[@"b687b66611b19ac8ebb793bc128c4c56675fc0fc6c7df8f7ddae6195134339b5", @"b687b66611b19ac8ebb793bc128c4c56675fc0fc6c7df8f7ddae6195134339b5"]];
    NSMutableArray *patches = [NSMutableArray array];
    for (id base in badBases) { NSMutableDictionary *p = [valid[@"patches"][0] mutableCopy]; p[@"original_source"] = base; [patches addObject:p]; }
    for (id previous in badPrevious) { NSMutableDictionary *p = [valid[@"patches"][0] mutableCopy]; p[@"previous_sha256"] = previous; [patches addObject:p]; }
    NSMutableDictionary *missingBase = [valid[@"patches"][0] mutableCopy]; [missingBase removeObjectForKey:@"original_source"]; [patches addObject:missingBase];
    NSMutableDictionary *missingPrevious = [valid[@"patches"][0] mutableCopy]; [missingPrevious removeObjectForKey:@"previous_sha256"]; [patches addObject:missingPrevious];
    NSMutableDictionary *wrongOriginal = [valid[@"patches"][0] mutableCopy]; wrongOriginal[@"original_sha256"] = DSHInstallerTestHash(self.onboardingPrevious); [patches addObject:wrongOriginal];
    for (NSDictionary *patch in patches) {
        NSMutableDictionary *manifest = [valid mutableCopy]; manifest[@"patches"] = @[patch]; self.manifest = manifest;
        self.resources = patch[@"original_source"] ? @{@"onboarding-client-original.js": self.original} : @{};
        self.filesystem.files[DSHInstallerTestOnboarding] = self.original;
        NSDictionary *before = [self.filesystem.files copy]; NSError *error = nil;
        XCTAssertFalse([self installOnboarding:&error]); XCTAssertNotNil(error);
        XCTAssertEqualObjects(self.filesystem.files, before);
        XCTAssertEqual(self.filesystem.createdPaths.count, 0u); XCTAssertEqual(self.filesystem.writeCalls, 0u);
    }
}
- (void)testOnboardingUpgradeCannotCrossTargetsOrInstallAdditionalGuestFiles {
    NSDictionary *session = self.manifest, *sessionResources = self.resources;
    if (![self prepareActualOnboardingUpgradeFixture]) return;
    NSDictionary *valid = self.manifest;
    for (NSString *target in @[DSHInstallerTestPackage, @"/usr/local/lib/node_modules/@deepseek-ai/dsh-web-fetch-http/lib/index.js",
                              @"/usr/local/lib/dsh-plugins/dsh-host-bridge/index.js", @"/root/.dsh/settings.json"]) {
        NSMutableDictionary *p = [valid[@"patches"][0] mutableCopy]; p[@"target"] = target;
        NSMutableDictionary *m = [valid mutableCopy]; m[@"patches"] = @[p]; self.manifest = m;
        NSError *error = nil; XCTAssertFalse([self installOnboarding:&error]);
        XCTAssertEqualObjects(error.userInfo[@"operation"], @"package whitelist");
    }
    NSMutableDictionary *extra = [valid mutableCopy];
    extra[@"files"] = @[@{@"source": @"helper.mjs", @"target": @"/usr/local/share/dsh/helper.mjs", @"sha256": DSHInstallerTestHash(self.original)}];
    self.manifest = extra; NSError *error = nil;
    XCTAssertFalse([self installOnboarding:&error]); XCTAssertEqualObjects(error.userInfo[@"operation"], @"schema");
    // Give Session its valid schema/resources; only the forbidden canonical name differs.
    NSMutableDictionary *foreign = [session mutableCopy], *patch = [session[@"patches"][0] mutableCopy];
    patch[@"original_source"] = @{@"source": @"onboarding-client-original.js", @"sha256": patch[@"original_sha256"]};
    patch[@"previous_sha256"] = @[@"b687b66611b19ac8ebb793bc128c4c56675fc0fc6c7df8f7ddae6195134339b5"];
    foreign[@"patches"] = @[patch];
    DSHSessionLifecycleInstaller *installer = [[DSHSessionLifecycleInstaller alloc] initWithManifest:foreign resources:sessionResources filesystem:self.filesystem package:DSHVerifiedSystemPackageSession];
    XCTAssertFalse([installer installWithError:&error]);
    XCTAssertEqualObjects(error.userInfo[@"operation"], @"upgrade base whitelist");
    // Web and Jobs also get their complete valid file whitelists before testing
    // that an Onboarding original_source cannot authorize their package kind.
    NSArray *targets = @[@"/usr/local/lib/node_modules/@deepseek-ai/dsh-web-fetch-http/lib/index.js",
                         @"/usr/local/lib/dsh-plugins/dsh-host-bridge/index.js"];
    NSArray *kinds = @[@(DSHVerifiedSystemPackageWebFetch), @(DSHVerifiedSystemPackageJobTracking)];
    NSArray *fileMaps = @[@{@"web-fetch-transport.mjs": @"/usr/local/share/dsh/web-fetch-transport.mjs"}, @{
        @"development-tools.mjs": @"/usr/local/lib/dsh-plugins/dsh-host-bridge/development-tools.mjs",
        @"job-tracking.mjs": @"/usr/local/lib/dsh-plugins/dsh-host-bridge/job-tracking.mjs",
        @"job-ledger.mjs": @"/usr/local/lib/dsh-plugins/dsh-host-bridge/job-ledger.mjs",
        @"workspace-export.mjs": @"/usr/local/lib/dsh-plugins/dsh-host-bridge/workspace-export.mjs"}];
    for (NSUInteger i = 0; i < targets.count; i++) {
        NSMutableDictionary *m = [valid mutableCopy], *p = [valid[@"patches"][0] mutableCopy];
        NSMutableDictionary *resources = [self.resources mutableCopy]; NSMutableArray *files = [NSMutableArray array];
        NSDictionary *mapping = fileMaps[i];
        for (NSString *source in mapping) {
            NSData *bytes = DSHInstallerTestData(@"valid peer fixture"); resources[source] = bytes;
            [files addObject:@{@"source": source, @"target": mapping[source], @"sha256": DSHInstallerTestHash(bytes)}];
            NSString *parent = [mapping[source] stringByDeletingLastPathComponent];
            while (parent.length > 1) { [self.filesystem.directories addObject:parent]; parent = parent.stringByDeletingLastPathComponent; }
        }
        p[@"target"] = targets[i]; m[@"patches"] = @[p]; m[@"files"] = files;
        self.filesystem.files[targets[i]] = self.original;
        NSString *parent = [targets[i] stringByDeletingLastPathComponent];
        while (parent.length > 1) { [self.filesystem.directories addObject:parent]; parent = parent.stringByDeletingLastPathComponent; }
        DSHSessionLifecycleInstaller *peer = [[DSHSessionLifecycleInstaller alloc] initWithManifest:m resources:resources filesystem:self.filesystem package:[kinds[i] unsignedIntegerValue]];
        XCTAssertFalse([peer installWithError:&error]);
        XCTAssertEqualObjects(error.userInfo[@"operation"], @"upgrade base whitelist");
    }
    XCTAssertEqual(self.filesystem.createdPaths.count, 0u); XCTAssertEqual(self.filesystem.writeCalls, 0u);
    XCTAssertEqualObjects(self.filesystem.files[DSHInstallerTestOnboarding], self.onboardingPrevious);
}
- (void)testOnboardingUpgradeRejectsUnknownAndLinkedSourcesBeforeWrites {
    if (![self prepareActualOnboardingUpgradeFixture]) return;
    self.filesystem.files[DSHInstallerTestOnboarding] = DSHInstallerTestData(@"user edited or newer client");
    NSDictionary *before = [self.filesystem.files copy]; NSError *error = nil;
    XCTAssertFalse([self installOnboarding:&error]); XCTAssertEqual(error.code, DSHSessionLifecycleInstallerUnknownSource);
    XCTAssertEqualObjects(self.filesystem.files, before);
    self.filesystem.files[DSHInstallerTestOnboarding] = self.onboardingPrevious;
    for (NSString *path in @[DSHInstallerTestOnboarding, @"/usr/local/lib/node_modules/@deepseek-ai"]) {
        DSHSessionLifecycleFileInfo *info = [DSHSessionLifecycleFileInfo new]; info.type = DSHSessionLifecycleFileSymbolicLink; info.linkCount = 1;
        self.filesystem.overrides[path] = info;
        XCTAssertFalse([self installOnboarding:&error]); XCTAssertEqual(error.code, DSHSessionLifecycleInstallerUnknownSource);
        [self.filesystem.overrides removeAllObjects];
    }
    DSHSessionLifecycleFileInfo *hardlink = [DSHSessionLifecycleFileInfo new]; hardlink.type = DSHSessionLifecycleFileRegular; hardlink.linkCount = 2;
    self.filesystem.overrides[DSHInstallerTestOnboarding] = hardlink;
    XCTAssertFalse([self installOnboarding:&error]); XCTAssertEqual(error.code, DSHSessionLifecycleInstallerUnknownSource);
    XCTAssertEqual(self.filesystem.createdPaths.count, 0u); XCTAssertEqual(self.filesystem.writeCalls, 0u);
    XCTAssertEqualObjects(self.filesystem.files[DSHInstallerTestOnboarding], self.onboardingPrevious);
}
- (void)testOnboardingUpgradeDoesNotOverwriteTargetChangedAfterPreflight {
    if (![self prepareActualOnboardingUpgradeFixture]) return;
    NSData *changed = DSHInstallerTestData(@"changed after preflight");
    __weak DSHInstallerMemoryFilesystem *filesystem = self.filesystem;
    self.filesystem.onCreate = ^{ filesystem.files[DSHInstallerTestOnboarding] = changed; };
    NSError *error = nil; XCTAssertFalse([self installOnboarding:&error]);
    XCTAssertEqual(error.code, DSHSessionLifecycleInstallerUnknownSource);
    XCTAssertEqualObjects(self.filesystem.files[DSHInstallerTestOnboarding], changed);
    XCTAssertFalse([self.filesystem.renamedTargets containsObject:DSHInstallerTestOnboarding]);
    XCTAssertEqual(self.filesystem.openHandles, 0u);
    // Idempotence still rechecks the installed target; no write exists to act
    // as a final race guard on this path.
    self.filesystem.onCreate = nil;
    self.filesystem.files[DSHInstallerTestOnboarding] = self.patched;
    NSUInteger writes = self.filesystem.writeCalls;
    __block NSUInteger reads = 0;
    self.filesystem.onCloseRead = ^(NSString *path) {
        if ([path isEqual:DSHInstallerTestOnboarding] && ++reads == 1) filesystem.files[path] = changed;
    };
    XCTAssertFalse([self installOnboarding:&error]);
    XCTAssertEqual(error.code, DSHSessionLifecycleInstallerUnknownSource);
    XCTAssertEqualObjects(self.filesystem.files[DSHInstallerTestOnboarding], changed);
    XCTAssertEqual(self.filesystem.writeCalls, writes);
    XCTAssertEqual(self.filesystem.openHandles, 0u);
}
- (void)testOnboardingUpgradeIOFailuresPreserveBuild29AndAllowExplicitRetry {
    if (![self prepareActualOnboardingUpgradeFixture]) return;
    for (NSString *operation in @[@"openRead", @"read", @"closeRead", @"create", @"write", @"shortWrite", @"fsync", @"closeWrite", @"corruptWrite", @"rename"]) {
        self.filesystem.files[DSHInstallerTestOnboarding] = self.onboardingPrevious;
        NSDictionary *before = [self.filesystem.files copy];
        [self setFailure:operation target:DSHInstallerTestOnboarding]; NSError *error = nil;
        XCTAssertFalse([self installOnboarding:&error], @"%@", operation); XCTAssertNotNil(error);
        XCTAssertEqualObjects(self.filesystem.files, before, @"%@", operation);
        XCTAssertEqual(self.filesystem.openHandles, 0u);
        XCTAssertTrue([self installOnboarding:&error], @"%@ retry: %@", operation, error); XCTAssertNil(error);
        XCTAssertEqualObjects(self.filesystem.files[DSHInstallerTestOnboarding], self.patched);
    }
}
- (void)testOnboardingUpgradeValidatesCanonicalPatchEvenOnIdempotentPath {
    if (![self prepareActualOnboardingUpgradeFixture]) return;
    NSDictionary *valid = self.manifest;
    for (NSData *source in @[self.onboardingPrevious, self.patched]) for (NSString *fault in @[@"count", @"hash"]) {
        self.filesystem.files[DSHInstallerTestOnboarding] = source;
        NSMutableDictionary *m = [valid mutableCopy], *p = [valid[@"patches"][0] mutableCopy];
        if ([fault isEqual:@"hash"]) p[@"patched_sha256"] = DSHInstallerTestHash(DSHInstallerTestData(@"wrong new hash"));
        else { NSMutableArray *r = [p[@"replacements"] mutableCopy]; NSMutableDictionary *first = [r[0] mutableCopy]; first[@"count"] = @2; r[0] = first; p[@"replacements"] = r; }
        m[@"patches"] = @[p]; self.manifest = m;
        NSDictionary *before = [self.filesystem.files copy]; NSError *error = nil;
        XCTAssertFalse([self installOnboarding:&error]); XCTAssertNotNil(error);
        XCTAssertEqualObjects(self.filesystem.files, before);
        XCTAssertEqual(self.filesystem.createdPaths.count, 0u); XCTAssertEqual(self.filesystem.writeCalls, 0u);
    }
}

- (void)testActualBundledManifestInstallsItsPinnedCanonicalPackage {
    NSURL *bundle = [NSBundle.mainBundle URLForResource:@"SessionLifecycle" withExtension:@"bundle"];
    XCTAssertNotNil(bundle);
    NSData *manifestData = [NSData dataWithContentsOfURL:[bundle URLByAppendingPathComponent:@"manifest.json"]];
    XCTAssertNotNil(manifestData);
    if (!manifestData) return;
    NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:nil];
    NSDictionary *patch = [manifest[@"patches"] firstObject];
    NSDictionary *base = patch[@"original_source"];
    XCTAssertEqualObjects(base[@"source"], @"session-backend-original.js");
    NSMutableDictionary *resources = [NSMutableDictionary dictionary];
    for (NSString *name in @[@"session-lifecycle.mjs", @"session-lifecycle-core.mjs", @"session-checkpoint-core.mjs", @"session-backend-original.js"]) {
        NSData *data = [NSData dataWithContentsOfURL:[bundle URLByAppendingPathComponent:name]];
        XCTAssertNotNil(data, @"missing actual bundle resource %@", name);
        if (!data) return;
        resources[name] = data;
    }
    XCTAssertEqualObjects(DSHInstallerTestHash(resources[@"session-backend-original.js"]), patch[@"original_sha256"]);
    self.manifest = manifest; self.resources = resources;
    self.filesystem.files[DSHInstallerTestPackage] = resources[@"session-backend-original.js"];
    NSError *error = nil;
    XCTAssertTrue([self install:&error], @"actual bundled manifest failed: %@", error);
    XCTAssertEqualObjects(DSHInstallerTestHash(self.filesystem.files[DSHInstallerTestPackage]), patch[@"patched_sha256"]);
    NSUInteger writes = self.filesystem.writeCalls;
    XCTAssertTrue([self install:&error], @"actual bundled idempotence failed: %@", error);
    XCTAssertEqual(self.filesystem.writeCalls, writes);
}
- (void)testAlreadyCurrentPeerChangedDuringInstallPreventsPackageCommit {
    [self primeControllers];
    [self.filesystem.files removeObjectForKey:DSHInstallerTestCore];
    NSData *changed = DSHInstallerTestData(@"changed current peer during core install");
    __weak DSHInstallerMemoryFilesystem *filesystem = self.filesystem;
    self.filesystem.onCreate = ^{ filesystem.files[DSHInstallerTestController] = changed; };
    XCTAssertFalse([self install:nil]);
    XCTAssertEqualObjects(self.filesystem.files[DSHInstallerTestPackage], self.original);
    XCTAssertEqualObjects(self.filesystem.files[DSHInstallerTestController], changed);
    XCTAssertFalse([self.filesystem.renamedTargets containsObject:DSHInstallerTestPackage]);
}
@end
