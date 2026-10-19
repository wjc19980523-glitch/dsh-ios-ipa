#import "DSHWorkspaceExportStore.h"
#import "DSHWorkspaceExportCapability.h"
#import "DSHHostBridge.h"
#import "DSHCapability.h"
#import <CommonCrypto/CommonDigest.h>
#import <UIKit/UIKit.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>

static const NSUInteger DSHExportMaxBytes = 512 * 1024 * 1024;
static const NSUInteger DSHExportChunkBytes = 128 * 1024;
static const unsigned long long DSHExportReserve = 32 * 1024 * 1024;
static const NSTimeInterval DSHExportIdle = 300, DSHExportLifetime = 1800;

static NSString *DSHExportHash(NSData *data) {
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, hash);
    NSMutableString *result = [NSMutableString new];
    for (NSUInteger i = 0; i < sizeof(hash); i++) [result appendFormat:@"%02x", hash[i]];
    return result;
}
static BOOL DSHExportMatch(id value, NSString *pattern) {
    if (![value isKindOfClass:NSString.class]) return NO;
    NSRange match = [value rangeOfString:pattern options:NSRegularExpressionSearch];
    // ICU's $ also matches before a final newline. Tokens and hashes must
    // match every byte of the string that will later be sent in HTTP headers.
    return match.location == 0 && match.length == [value length];
}
static BOOL DSHExportSafeText(NSString *value) {
    return [value isKindOfClass:NSString.class] && value.length &&
        ![value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].length &&
        ![value rangeOfString:@"[\\u202a-\\u202e\\u2066-\\u2069\\u200e\\u200f\\u061c]" options:NSRegularExpressionSearch].length;
}
static BOOL DSHExportSafePath(NSString *path) {
    if (!DSHExportSafeText(path) || path.length > 1024 || ![path hasPrefix:@"/root/workspace/"] ||
        ![path isEqualToString:path.stringByStandardizingPath] || [path containsString:@"\\"])
        return NO;
    NSSet *sensitive = [NSSet setWithArray:@[@"id_rsa", @"id_ed25519", @"id_ecdsa", @"credentials", @"credentials.json", @"credentials.yaml"]];
    for (NSString *component in path.pathComponents) {
        NSString *lower = component.lowercaseString;
        if ([component hasPrefix:@"."] || [sensitive containsObject:lower] ||
            [@[@"key", @"pem", @"p12", @"pfx"] containsObject:lower.pathExtension]) return NO;
    }
    return YES;
}
static void DSHExportError(NSError **out, NSInteger status, NSString *code, NSString *message) {
    if (out) *out = [NSError errorWithDomain:@"DSHWorkspaceExport" code:status
                                  userInfo:@{NSLocalizedDescriptionKey:message, @"code":code}];
}

@interface DSHExportSession : NSObject {
@public CC_SHA256_CTX digest;
}
@property NSString *identifier;
@property NSDictionary *metadata;
@property NSString *state;
@property NSString *errorCode;
@property NSURL *directory;
@property NSURL *file;
@property int fd;
@property unsigned long long offset;
@property unsigned long long lastOffset;
@property NSUInteger lastLength;
@property NSString *lastHash;
@property NSDate *created;
@property NSDate *touched;
/// The picker may still be copying this file even after cancellation/expiry.
@property BOOL presentationOutstanding;
@end
@implementation DSHExportSession
- (instancetype)init { if ((self = [super init])) _fd = -1; return self; }
- (void)dealloc { if (_fd >= 0) close(_fd); }
@end

@interface DSHWorkspaceExportStore ()
@property NSURL *directory;
@property NSMutableDictionary<NSString *, DSHExportSession *> *sessions;
@property NSRecursiveLock *lock;
@property (nonatomic, copy) void (^cancelPresentation)(NSString *session);
- (BOOL)session:(NSString *)session belongsToScope:(NSString *)scope;
- (void)requestPresentationCancellation:(NSString *)session;
- (void)rejectPendingConfirmation:(NSString *)session code:(NSString *)code cancelled:(BOOL)cancelled;
@end

@implementation DSHWorkspaceExportStore
+ (NSUInteger)maximumBytes { return DSHExportMaxBytes; }
+ (NSUInteger)maximumChunkBytes { return DSHExportChunkBytes; }
- (instancetype)initWithDirectory:(NSURL *)directory {
    if ((self = [super init])) {
        _directory = directory; _sessions = [NSMutableDictionary new]; _lock = [NSRecursiveLock new];
        _clock = ^{ return NSDate.date; };
        struct stat info;
        if (lstat(directory.fileSystemRepresentation, &info) == 0 && (!S_ISDIR(info.st_mode) || S_ISLNK(info.st_mode))) return nil;
        if (![NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES
                                                    attributes:@{NSFilePosixPermissions:@0700} error:nil]) return nil;
        // This directory is exclusively owned by this service. Never follow or
        // interpret Guest paths while removing interrupted Native staging.
        for (NSURL *child in [NSFileManager.defaultManager contentsOfDirectoryAtURL:directory includingPropertiesForKeys:nil options:0 error:nil])
            if (DSHExportMatch(child.lastPathComponent, @"^export-[0-9a-f]{64}$"))
                [NSFileManager.defaultManager removeItemAtURL:child error:nil];
    }
    return self;
}
- (BOOL)terminal:(DSHExportSession *)s { return [@[@"saved",@"cancelled",@"expired",@"failed"] containsObject:s.state]; }
- (NSDictionary *)snapshot:(DSHExportSession *)s {
    NSMutableDictionary *result = [@{@"session_id":s.identifier, @"state":s.state,
        @"offset":@(s.offset), @"max_chunk_bytes":@(DSHExportChunkBytes), @"name":s.metadata[@"name"],
        @"bytes":s.metadata[@"bytes"], @"sha256":s.metadata[@"sha256"], @"saved":@([s.state isEqualToString:@"saved"])} mutableCopy];
    if (s.errorCode) result[@"error_code"] = s.errorCode;
    return result;
}
- (void)cleanup:(DSHExportSession *)s {
    if (s.fd >= 0) { close(s.fd); s.fd = -1; }
    if (s.directory) [NSFileManager.defaultManager removeItemAtURL:s.directory error:nil];
    s.directory = nil; s.file = nil;
}
- (void)fail:(DSHExportSession *)s code:(NSString *)code {
    s.state = @"failed"; s.errorCode = code; s.touched = self.clock(); [self cleanup:s];
}
- (void)expireSessions {
    [self.lock lock];
    NSDate *now = self.clock();
    for (DSHExportSession *s in self.sessions.allValues) {
        if (![self terminal:s] && ([now timeIntervalSinceDate:s.created] >= DSHExportLifetime ||
                                  [now timeIntervalSinceDate:s.touched] >= DSHExportIdle)) {
            s.state = @"expired"; s.errorCode = @"expired";
            if (s.presentationOutstanding) [self requestPresentationCancellation:s.identifier];
            else [self cleanup:s];
        }
    }
    [self.lock unlock];
}
- (void)requestPresentationCancellation:(NSString *)session {
    void (^cancel)(NSString *) = self.cancelPresentation;
    // Never call UIKit, or synchronously re-enter the service, under the lock.
    if (cancel) dispatch_async(dispatch_get_main_queue(), ^{ cancel(session); });
}
- (void)cancelPendingUI {
    [self.lock lock];
    for (DSHExportSession *s in self.sessions.allValues)
        if ([s.state isEqualToString:@"pending_confirmation"] || [s.state isEqualToString:@"saving"])
            [self cancel:s.identifier error:nil];
    [self.lock unlock];
}
- (BOOL)hasSpace:(unsigned long long)bytes {
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfFileSystemForPath:self.directory.path error:nil];
    return [attrs[NSFileSystemFreeSize] unsignedLongLongValue] >= bytes + DSHExportReserve;
}
- (NSDictionary *)start:(NSDictionary *)metadata error:(NSError **)error {
    [self.lock lock];
    @try {
        [self expireSessions];
        if (![metadata isKindOfClass:NSDictionary.class]) {
            DSHExportError(error,400,@"invalid_request",@"Export metadata must be a dictionary."); return nil;
        }
        NSSet *keys = [NSSet setWithArray:@[@"request_id",@"scope_id",@"workspace",@"source",@"name",@"bytes",@"sha256"]];
        NSString *name = metadata[@"name"], *source = metadata[@"source"], *workspace = metadata[@"workspace"];
        id bytes = metadata[@"bytes"];
        BOOL validBytes = [bytes isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)bytes) != CFBooleanGetTypeID() &&
            [bytes doubleValue] >= 0 && [bytes doubleValue] <= DSHExportMaxBytes && [bytes doubleValue] == (double)[bytes unsignedLongLongValue];
        BOOL validWorkspace = [workspace isKindOfClass:NSString.class] &&
            ([workspace isEqualToString:@"/root/workspace"] || DSHExportSafePath(workspace));
        if (![metadata isKindOfClass:NSDictionary.class] || ![[NSSet setWithArray:metadata.allKeys] isEqualToSet:keys] ||
            !DSHExportMatch(metadata[@"request_id"], @"^[A-Za-z0-9_-]{16,128}$") ||
            !DSHExportMatch(metadata[@"scope_id"], @"^[A-Za-z0-9_-]{16,128}$") ||
            !DSHExportSafePath(source) || !validWorkspace || ![source hasPrefix:[workspace stringByAppendingString:@"/"]] ||
            !DSHExportSafeText(name) || name.length > 128 || ![name isEqualToString:name.lastPathComponent] ||
            [name hasPrefix:@"."] || [name rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"\\/:"]].length ||
            !validBytes || !DSHExportMatch(metadata[@"sha256"], @"^[0-9a-f]{64}$")) {
            DSHExportError(error,400,@"invalid_request",@"Invalid workspace export metadata or disallowed source."); return nil;
        }
        for (DSHExportSession *existing in self.sessions.allValues) {
            if ([existing.metadata[@"scope_id"] isEqual:metadata[@"scope_id"]] &&
                [existing.metadata[@"request_id"] isEqual:metadata[@"request_id"]]) {
                if (![existing.metadata isEqual:metadata]) {
                    DSHExportError(error,409,@"conflict",@"The request identity belongs to different file metadata."); return nil;
                }
                return [self snapshot:existing];
            }
        }
        for (DSHExportSession *existing in self.sessions.allValues)
            if (![self terminal:existing] || existing.presentationOutstanding) { DSHExportError(error,409,@"busy",@"Another workspace export is active."); return nil; }
        if (![self hasSpace:[bytes unsignedLongLongValue]]) {
            DSHExportError(error,507,@"insufficient_storage",@"Not enough local disk space to stage this export."); return nil;
        }
        while (self.sessions.count >= 16) {
            DSHExportSession *oldest;
            for (DSHExportSession *s in self.sessions.allValues) if (!oldest || [s.created compare:oldest.created] == NSOrderedAscending) oldest = s;
            [self.sessions removeObjectForKey:oldest.identifier];
        }
        uint8_t random[32]; arc4random_buf(random,sizeof(random));
        NSMutableString *identifier = [NSMutableString new];
        for (NSUInteger j = 0; j < sizeof(random); j++) [identifier appendFormat:@"%02x",random[j]];
        DSHExportSession *s = [DSHExportSession new];
        s.identifier = identifier; s.metadata = [metadata copy]; s.state = @"pending_confirmation";
        s.created = self.clock(); s.touched = s.created;
        self.sessions[identifier] = s;
        return [self snapshot:s];
    } @finally { [self.lock unlock]; }
}
- (DSHExportSession *)lookup:(NSString *)identifier error:(NSError **)error {
    [self expireSessions];
    DSHExportSession *s = [identifier isKindOfClass:NSString.class] ? self.sessions[identifier] : nil;
    if (!s) DSHExportError(error,404,@"unknown_session",@"Export session is absent or belongs to a previous app launch.");
    return s;
}
- (NSDictionary *)status:(NSString *)session error:(NSError **)error {
    [self.lock lock];
    @try { DSHExportSession *s = [self lookup:session error:error]; return s ? [self snapshot:s] : nil; }
    @finally { [self.lock unlock]; }
}
- (BOOL)session:(NSString *)session belongsToScope:(NSString *)scope {
    [self.lock lock];
    @try {
        DSHExportSession *s = [self lookup:session error:nil];
        return s && [scope isKindOfClass:NSString.class] && [s.metadata[@"scope_id"] isEqualToString:scope];
    } @finally { [self.lock unlock]; }
}
- (void)approve:(NSString *)session granted:(BOOL)granted {
    [self.lock lock];
    @try {
        DSHExportSession *s = [self lookup:session error:nil];
        if (![s.state isEqualToString:@"pending_confirmation"]) return;
        if (!granted) { s.state = @"cancelled"; s.errorCode = @"permission_denied"; return; }
        s.directory = [self.directory URLByAppendingPathComponent:[@"export-" stringByAppendingString:s.identifier] isDirectory:YES];
        if (![NSFileManager.defaultManager createDirectoryAtURL:s.directory withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions:@0700} error:nil]) {
            [self fail:s code:@"staging_failed"]; return;
        }
        s.file = [s.directory URLByAppendingPathComponent:@"upload.partial"];
        s.fd = open(s.file.fileSystemRepresentation, O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600);
        if (s.fd < 0) { [self fail:s code:@"staging_failed"]; return; }
        CC_SHA256_Init(&s->digest);
        s.state = @"receiving"; s.touched = self.clock();
    } @finally { [self.lock unlock]; }
}
- (void)rejectPendingConfirmation:(NSString *)session code:(NSString *)code cancelled:(BOOL)cancelled {
    [self.lock lock];
    @try {
        DSHExportSession *s = [self lookup:session error:nil];
        if (![s.state isEqualToString:@"pending_confirmation"]) return;
        s.state = cancelled ? @"cancelled" : @"failed";
        s.errorCode = code; s.touched = self.clock();
    } @finally { [self.lock unlock]; }
}
- (NSDictionary *)append:(NSData *)data session:(NSString *)session offset:(unsigned long long)offset sha256:(NSString *)sha256 error:(NSError **)error {
    [self.lock lock];
    @try {
        DSHExportSession *s = [self lookup:session error:error]; if (!s) return nil;
        if (![s.state isEqualToString:@"receiving"]) { DSHExportError(error,409,@"invalid_state",@"Export is not accepting data."); return nil; }
        if (!data.length || data.length > DSHExportChunkBytes || !DSHExportMatch(sha256,@"^[0-9a-f]{64}$") || ![DSHExportHash(data) isEqualToString:sha256]) {
            DSHExportError(error,400,@"checksum_mismatch",@"Invalid binary chunk or chunk checksum."); return nil;
        }
        if (s.offset && offset == s.lastOffset && data.length == s.lastLength && [sha256 isEqualToString:s.lastHash]) return [self snapshot:s];
        if (offset != s.offset || data.length > [s.metadata[@"bytes"] unsignedLongLongValue] - s.offset) {
            DSHExportError(error,409,@"offset_mismatch",@"The chunk does not match the next expected offset."); return nil;
        }
        if (![self hasSpace:data.length]) { [self fail:s code:@"insufficient_storage"]; return [self snapshot:s]; }
        const uint8_t *p = data.bytes; NSUInteger remaining = data.length;
        while (remaining) {
            ssize_t n = write(s.fd,p,remaining);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) { [self fail:s code:@"write_failed"]; return [self snapshot:s]; }
            p += n; remaining -= (NSUInteger)n;
        }
        CC_SHA256_Update(&s->digest,data.bytes,(CC_LONG)data.length);
        s.lastOffset = offset; s.lastLength = data.length; s.lastHash = sha256;
        s.offset += data.length; s.touched = self.clock();
        return [self snapshot:s];
    } @finally { [self.lock unlock]; }
}
- (NSDictionary *)finish:(NSString *)session error:(NSError **)error {
    [self.lock lock];
    @try {
        DSHExportSession *s = [self lookup:session error:error]; if (!s) return nil;
        if ([s.state isEqualToString:@"ready"] || [s.state isEqualToString:@"saving"] || [self terminal:s]) return [self snapshot:s];
        if (![s.state isEqualToString:@"receiving"] || s.offset != [s.metadata[@"bytes"] unsignedLongLongValue]) {
            DSHExportError(error,409,@"incomplete",@"The declared file has not been completely received."); return nil;
        }
        CC_SHA256_CTX digest = s->digest; unsigned char hash[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256_Final(hash,&digest);
        NSMutableString *actual = [NSMutableString new];
        for (NSUInteger j = 0; j < sizeof(hash); j++) [actual appendFormat:@"%02x",hash[j]];
        if (![actual isEqualToString:s.metadata[@"sha256"]]) { [self fail:s code:@"checksum_mismatch"]; return [self snapshot:s]; }
        if (fsync(s.fd) != 0) { [self fail:s code:@"sync_failed"]; return [self snapshot:s]; }
        int closed = close(s.fd); s.fd = -1;
        if (closed != 0) { [self fail:s code:@"close_failed"]; return [self snapshot:s]; }
        NSURL *committed = [s.directory URLByAppendingPathComponent:s.metadata[@"name"]];
        if (rename(s.file.fileSystemRepresentation,committed.fileSystemRepresentation) != 0) {
            [self fail:s code:@"commit_failed"]; return [self snapshot:s];
        }
        s.file = committed; s.state = @"ready"; s.touched = self.clock();
        return [self snapshot:s];
    } @finally { [self.lock unlock]; }
}
- (NSURL *)claimForSaving:(NSString *)session {
    [self.lock lock];
    @try {
        DSHExportSession *s = [self lookup:session error:nil];
        if (![s.state isEqualToString:@"ready"]) return nil;
        s.state = @"saving"; s.presentationOutstanding = YES; s.touched = self.clock(); return s.file;
    } @finally { [self.lock unlock]; }
}
- (void)complete:(NSString *)session state:(NSString *)state errorCode:(NSString *)errorCode {
    [self.lock lock];
    @try {
        DSHExportSession *s = [self lookup:session error:nil];
        if (!s.presentationOutstanding) return;
        s.presentationOutstanding = NO;
        // A cancellation or expiry observed first cannot be reversed by a
        // late picker callback. Its source can now be removed after dismissal.
        if ([s.state isEqualToString:@"saving"]) {
            s.state = [state isEqualToString:@"saved"] ? @"saved" : [state isEqualToString:@"cancelled"] ? @"cancelled" : @"failed";
            s.errorCode = errorCode;
        }
        s.touched = self.clock(); [self cleanup:s];
    } @finally { [self.lock unlock]; }
}
- (NSDictionary *)cancel:(NSString *)session error:(NSError **)error {
    [self.lock lock];
    @try {
        DSHExportSession *s = [self lookup:session error:error]; if (!s) return nil;
        if (![self terminal:s]) {
            s.state = @"cancelled"; s.errorCode = @"cancelled"; s.touched = self.clock();
            if (s.presentationOutstanding) [self requestPresentationCancellation:s.identifier];
            else [self cleanup:s];
        }
        return [self snapshot:s];
    } @finally { [self.lock unlock]; }
}
@end

/// Owns UI lifetimes; all map access occurs on the main queue.
@interface DSHWorkspaceExportService : NSObject
@property DSHWorkspaceExportStore *store;
@property NSMutableDictionary<NSString *, DSHWorkspaceExportPresentation *> *presentations;
@property NSMutableSet<NSString *> *confirmations;
@property dispatch_source_t timer;
- (void)installOn:(DSHHostBridge *)bridge;
@end

@implementation DSHWorkspaceExportService
- (DSHHostBridgeResponse *)response:(NSDictionary *)body error:(NSError *)error {
    if (body) return [DSHHostBridgeResponse ok:body];
    return [DSHHostBridgeResponse errorWithStatus:error ? error.code : 500 code:error.userInfo[@"code"] ?: @"unavailable"
        message:error.localizedDescription ?: @"Workspace export is unavailable." recoverable:YES];
}
- (void)confirm:(NSDictionary *)metadata session:(NSString *)session {
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self.confirmations containsObject:session]) return;
        [self.confirmations addObject:session];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
            DSHConfirmationOutcome outcome = [DSHWorkspaceExportCapability confirmSourcePath:metadata[@"source"] name:metadata[@"name"] bytes:[metadata[@"bytes"] unsignedLongLongValue] cancellationCheck:^BOOL {
                return ![[self.store status:session error:nil][@"state"] isEqualToString:@"pending_confirmation"];
            }];
            BOOL enabled = [DSHCapabilityRegistry.shared isEnabled:@"files.export.workspace"];
            if (!enabled) [self.store rejectPendingConfirmation:session code:@"capability_disabled" cancelled:YES];
            else if (outcome == DSHConfirmationGranted) [self.store approve:session granted:YES];
            else if (outcome == DSHConfirmationDeclined) [self.store approve:session granted:NO];
            else if (outcome == DSHConfirmationCancelled) [self.store rejectPendingConfirmation:session code:@"confirmation_cancelled" cancelled:YES];
            else [self.store rejectPendingConfirmation:session code:outcome == DSHConfirmationTimedOut ? @"confirmation_timeout" : @"confirmation_unavailable" cancelled:NO];
            dispatch_async(dispatch_get_main_queue(), ^{ [self.confirmations removeObject:session]; });
        });
    });
}
- (void)present:(NSString *)session name:(NSString *)name {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSURL *file = [self.store claimForSaving:session]; if (!file) return;
        DSHWorkspaceExportPresentation *presentation = [DSHWorkspaceExportCapability presentVerifiedFileURL:file name:name completion:^(NSString *state, NSString *code) {
            [self.store complete:session state:state errorCode:code];
            [self.presentations removeObjectForKey:session];
        }];
        if (!presentation.finished) self.presentations[session] = presentation;
    });
}
- (void)background:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        for (DSHWorkspaceExportPresentation *presentation in self.presentations.allValues) [presentation cancel];
        [self.store cancelPendingUI];
    });
}
- (void)installOn:(DSHHostBridge *)bridge {
    [DSHWorkspaceExportCapability registerCapability];
    self.presentations = [NSMutableDictionary new]; self.confirmations = [NSMutableSet new];
    self.store = [[DSHWorkspaceExportStore alloc] initWithDirectory:[[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES] URLByAppendingPathComponent:@"DSHWorkspaceExports" isDirectory:YES]];
    __weak typeof(self) weakSelf = self;
    self.store.cancelPresentation = ^(NSString *session) { [weakSelf.presentations[session] cancel]; };
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(background:) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(background:) name:UISceneDidEnterBackgroundNotification object:nil];
    self.timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_main_queue());
    dispatch_source_set_timer(self.timer,dispatch_time(DISPATCH_TIME_NOW,30*NSEC_PER_SEC),30*NSEC_PER_SEC,NSEC_PER_SEC);
    dispatch_source_set_event_handler(self.timer, ^{ [weakSelf.store expireSessions]; });
    dispatch_resume(self.timer);
    [bridge registerRoute:@"POST" path:@"/v1/files/workspace-export/start" capability:@"files.export.workspace" handler:^DSHHostBridgeResponse *(DSHHostBridgeRequest *request) {
        NSError *error; NSDictionary *result = [self.store start:request.json ?: @{} error:&error];
        if ([result[@"state"] isEqualToString:@"pending_confirmation"]) [self confirm:request.json session:result[@"session_id"]];
        return [self response:result error:error];
    }];
    [bridge registerBinaryRoute:@"PUT" path:@"/v1/files/workspace-export/chunk" capability:@"files.export.workspace" maximumBytes:DSHExportChunkBytes handler:^DSHHostBridgeResponse *(DSHHostBridgeRequest *request) {
        if (![self.store session:request.headers[@"x-dsh-export-session"] belongsToScope:request.headers[@"x-dsh-export-scope"]])
            return [DSHHostBridgeResponse errorWithStatus:404 code:@"unknown_session" message:@"No export session for this scope." recoverable:NO];
        NSString *rawOffset = request.headers[@"x-dsh-export-offset"];
        if (!DSHExportMatch(rawOffset,@"^(0|[1-9][0-9]{0,9})$")) return [DSHHostBridgeResponse errorWithStatus:400 code:@"invalid_request" message:@"Missing or invalid chunk offset." recoverable:NO];
        NSError *error;
        NSDictionary *result = [self.store append:request.binaryBody ?: NSData.data session:request.headers[@"x-dsh-export-session"] offset:rawOffset.longLongValue sha256:request.headers[@"x-dsh-export-sha256"] error:&error];
        return [self response:result error:error];
    }];
    for (NSString *operation in @[@"status",@"finish",@"cancel"]) {
        [bridge registerRoute:[operation isEqualToString:@"status"] ? @"GET" : @"POST" path:[@"/v1/files/workspace-export/" stringByAppendingString:operation] capability:@"files.export.workspace" handler:^DSHHostBridgeResponse *(DSHHostBridgeRequest *request) {
            NSString *session = request.headers[@"x-dsh-export-session"];
            if (![self.store session:session belongsToScope:request.headers[@"x-dsh-export-scope"]])
                return [DSHHostBridgeResponse errorWithStatus:404 code:@"unknown_session" message:@"No export session for this scope." recoverable:NO];
            NSError *error; NSDictionary *result;
            if ([operation isEqualToString:@"finish"]) {
                result = [self.store finish:session error:&error];
                if ([result[@"state"] isEqualToString:@"ready"]) [self present:session name:result[@"name"]];
            } else if ([operation isEqualToString:@"cancel"]) {
                dispatch_async(dispatch_get_main_queue(), ^{ [self.presentations[session] cancel]; });
                result = [self.store cancel:session error:&error];
            } else result = [self.store status:session error:&error];
            return [self response:result error:error];
        }];
    }
}
- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    if (_timer) dispatch_source_cancel(_timer);
}
@end

@implementation DSHWorkspaceExportStore (Installation)
+ (void)installOnBridge:(DSHHostBridge *)bridge {
    // Route handlers retain the service for this bridge's lifetime.
    DSHWorkspaceExportService *service = [DSHWorkspaceExportService new];
    [service installOn:bridge];
}
@end
