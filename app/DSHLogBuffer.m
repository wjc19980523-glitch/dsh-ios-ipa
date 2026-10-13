//
//  DSHLogBuffer.m
//  DSH
//

#import "DSHLogBuffer.h"
#import "DSHHarnessAuth.h"
#import <UIKit/UIKit.h>
#import "DSHStartupMetrics.h"
#import "DSHLifecycleDiagnostics.h"
#include <sys/sysctl.h>
#include <unistd.h>
#include <math.h>

static BOOL DSHHostStartWasObserved;
static const NSUInteger DSHLaunchBytes = 256 * 1024;
static const NSUInteger DSHIncidentBytes = 128 * 1024;
static const NSUInteger DSHIncidentLimit = 4;
static const NSUInteger DSHEventWindow = 32;
static const NSUInteger DSHPostIncidentEvents = 8;

static NSData *diagnosticJSON(id object) {
    return [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys error:nil];
}

static NSArray<NSURL *> *diagnosticFiles(NSURL *directory, NSString *prefix, NSString *extension) {
    if (!directory) return @[];
    NSArray *files = [NSFileManager.defaultManager contentsOfDirectoryAtURL:directory
        includingPropertiesForKeys:@[NSURLIsRegularFileKey, NSURLIsSymbolicLinkKey] options:0 error:nil] ?: @[];
    return [[files filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSURL *url, NSDictionary *bindings) {
        NSNumber *regular = nil, *symlink = nil;
        [url getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
        [url getResourceValue:&symlink forKey:NSURLIsSymbolicLinkKey error:nil];
        return regular.boolValue && !symlink.boolValue && [url.lastPathComponent hasPrefix:prefix] && [url.pathExtension isEqual:extension];
    }]] sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) { return [a.lastPathComponent compare:b.lastPathComponent]; }];
}

DSH_EXPORTED NSNotificationName const DSHLogBufferDidChangeNotification = @"DSHLogBufferDidChangeNotification";

@interface DSHLogBuffer ()
@property (nonatomic) NSMutableArray<NSString *> *storage;
@property (nonatomic) NSUInteger head;   // index of the oldest line when full
@property (nonatomic) BOOL notifyPending;
@property (nonatomic) NSURL *persistentDirectory;
@property (nonatomic) NSURL *persistentFile;
@property (nonatomic) NSFileHandle *persistentHandle;
@property (nonatomic) NSDate *startedAt;
@property (nonatomic) NSMutableArray<NSDictionary *> *diagnosticEvents;
@property (nonatomic) NSMutableArray<NSDictionary *> *historicalEvents;
@property (nonatomic) NSMutableSet<NSString *> *incidentKeys;
@property (nonatomic) NSMutableSet<NSString *> *terminalIncidentKeys;
@property (nonatomic) NSMutableDictionary<NSString *, NSURL *> *incidentFilesByKey;
@property (nonatomic) NSMutableDictionary *pendingIncident;
@property (nonatomic) NSURL *pendingIncidentFile;
@property (nonatomic) NSString *pendingIncidentKey;
@property (nonatomic) NSUInteger remainingIncidentEvents;
@property (nonatomic) NSUInteger persistentBytes;
@property (nonatomic) NSUInteger omittedFreeText;
@property (nonatomic) NSString *persistentHeader;
@property (nonatomic) BOOL diagnosticWriteFailed;
@property (nonatomic) NSString *cachedDiagnosticSummary;
@property (nonatomic) NSDictionary *lastContextSnapshot;
@end

@implementation DSHLogBuffer

+ (NSString *)hostLaunchID {
    static NSString *identity;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ identity = NSUUID.UUID.UUIDString; });
    return identity;
}

+ (NSDate *)hostProcessStartedAt {
    static NSDate *started;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        struct kinfo_proc process = {0};
        size_t size = sizeof(process);
        int mib[] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
        if (sysctl(mib, 4, &process, &size, NULL, 0) == 0 && size && process.kp_proc.p_starttime.tv_sec) {
            struct timeval time = process.kp_proc.p_starttime;
            started = [NSDate dateWithTimeIntervalSince1970:time.tv_sec + time.tv_usec / 1000000.0];
        } else {
            // Some sandbox versions disallow KERN_PROC. Preserve an explicitly
            // labelled observation rather than inventing a kernel timestamp.
            started = NSDate.date;
            DSHHostStartWasObserved = YES;
        }
    });
    return started;
}

+ (NSString *)hostProcessStartSource {
    (void)self.hostProcessStartedAt;
    return DSHHostStartWasObserved ? @"first_observation_sysctl_unavailable" : @"kernel_process_start";
}

- (instancetype)initWithCapacity:(NSUInteger)capacity {
    if (self = [super init]) {
        _capacity = MAX(capacity, 1);
        _storage = [NSMutableArray arrayWithCapacity:_capacity];
        _diagnosticEvents = [NSMutableArray new];
        _historicalEvents = [NSMutableArray new];
        _incidentKeys = [NSMutableSet new];
        _terminalIncidentKeys = [NSMutableSet new];
        _incidentFilesByKey = [NSMutableDictionary new];
    }
    return self;
}

- (instancetype)initPersistentWithCapacity:(NSUInteger)capacity {
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    return [self initPersistentWithCapacity:capacity directory:[support URLByAppendingPathComponent:@"Diagnostics" isDirectory:YES]];
}

- (instancetype)initPersistentWithCapacity:(NSUInteger)capacity directory:(NSURL *)directory {
    if (self = [self initWithCapacity:capacity]) {
        _startedAt = NSDate.date;
        NSFileManager *fm = NSFileManager.defaultManager;
        _persistentDirectory = directory;
        if (![fm createDirectoryAtURL:_persistentDirectory withIntermediateDirectories:YES attributes:nil error:nil]) {
            _diagnosticWriteFailed = YES;
            return self;
        }
        [self prunePersistentLogs];

        // Read the preceding host before creating this launch file. A new ID
        // alone never proves a crash, a kill, or 0xDEAD10CC.
        NSArray *priorEvents = [self savedEvents];
        NSUInteger historyStart = priorEvents.count > 64 ? priorEvents.count - 64 : 0;
        [_historicalEvents addObjectsFromArray:[priorEvents subarrayWithRange:NSMakeRange(historyStart, priorEvents.count - historyStart)]];
        for (NSURL *url in diagnosticFiles(_persistentDirectory, @"incident-", @"json")) {
            NSDictionary *incident = [self incidentAtURL:url];
            if (incident[@"trigger"]) [_historicalEvents addObject:incident[@"trigger"]];
            if (incident[@"terminal"]) [_historicalEvents addObject:incident[@"terminal"]];
        }
        NSDictionary *prior = nil, *priorSnapshot = nil;
        for (NSDictionary *candidate in priorEvents.reverseObjectEnumerator) {
            NSDictionary *snapshot = candidate[@"snapshot"] ?: candidate;
            if (snapshot[@"filesystem_state"] && snapshot[@"host_launch_id"]) { prior = candidate; priorSnapshot = snapshot; break; }
        }
        BOOL incomplete = priorSnapshot[@"filesystem_state"] &&
            [priorSnapshot[@"filesystem_state"] unsignedIntegerValue] == 1 &&
            ![priorSnapshot[@"host_launch_id"] isEqual:DSHLogBuffer.hostLaunchID];

        NSDateFormatter *name = [NSDateFormatter new];
        name.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        name.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
        name.dateFormat = @"yyyyMMdd-HHmmss-SSS";
        _persistentFile = [_persistentDirectory URLByAppendingPathComponent:
                           [NSString stringWithFormat:@"launch-%@-%@-%@.log", [name stringFromDate:_startedAt], DSHLogBuffer.hostLaunchID, NSUUID.UUID.UUIDString]];
        [fm createFileAtPath:_persistentFile.path contents:nil attributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication}];
        _persistentHandle = [NSFileHandle fileHandleForWritingAtPath:_persistentFile.path];
        if (!_persistentHandle) _diagnosticWriteFailed = YES;

        NSDictionary *info = NSBundle.mainBundle.infoDictionary;
        UIDevice *device = UIDevice.currentDevice;
        NSString *header = [NSString stringWithFormat:
            @"DSH startup diagnostics\n"
             "started: %@\n"
             "host_launch_id: %@\n"
             "host_pid: %d\n"
             "host_process_started_at: %@\n"
             "host_process_start_source: %@\n"
             "app: %@ (%@)\n"
             "device: %@\n"
             "system: %@ %@\n"
             "locale: %@\n\n",
            [NSISO8601DateFormatter stringFromDate:_startedAt timeZone:NSTimeZone.localTimeZone formatOptions:NSISO8601DateFormatWithInternetDateTime],
            DSHLogBuffer.hostLaunchID, getpid(),
            [NSISO8601DateFormatter stringFromDate:DSHLogBuffer.hostProcessStartedAt timeZone:NSTimeZone.localTimeZone formatOptions:NSISO8601DateFormatWithInternetDateTime],
            DSHLogBuffer.hostProcessStartSource,
            info[@"CFBundleShortVersionString"] ?: @"?", info[(NSString *)kCFBundleVersionKey] ?: @"?",
            device.model ?: @"?", device.systemName ?: @"iOS", device.systemVersion ?: @"?",
            NSLocale.currentLocale.localeIdentifier ?: @"?"];
        _persistentHeader = header;
        [self writePersistentData:[header dataUsingEncoding:NSUTF8StringEncoding]];
        [self retainSafeEvent:@{@"event": @"hostStarted", @"host_launch_id": DSHLogBuffer.hostLaunchID,
            @"host_pid": @(getpid()), @"host_started_epoch": @(DSHLogBuffer.hostProcessStartedAt.timeIntervalSince1970)}];
        if (incomplete) {
            NSMutableDictionary *event = [prior mutableCopy];
            event[@"event"] = @"incompletePreviousBackground";
            [self retainSafeEvent:event];
        }
        [self synchronizePersistentDiagnostics];
        [self prunePersistentLogs];
    }
    return self;
}

- (void)dealloc {
    @try { [self.persistentHandle closeFile]; } @catch (__unused NSException *exception) {}
}

- (void)prunePersistentLogs {
    if (self.persistentDirectory == nil)
        return;
    NSArray<NSURL *> *files = diagnosticFiles(self.persistentDirectory, @"launch-", @"log");
    for (NSUInteger i = 0; files.count > i + 10; i++) [NSFileManager.defaultManager removeItemAtURL:files[i] error:nil];
    files = diagnosticFiles(self.persistentDirectory, @"incident-", @"json");
    for (NSUInteger i = 0; files.count > i + DSHIncidentLimit; i++) [NSFileManager.defaultManager removeItemAtURL:files[i] error:nil];
}

- (void)writePersistentData:(NSData *)data {
    if (!data.length || !self.persistentHandle) return;
    @try {
        [self.persistentHandle writeData:data];
        self.persistentBytes += data.length;
    } @catch (__unused NSException *exception) { self.diagnosticWriteFailed = YES; }
}

- (NSArray<NSDictionary *> *)eventsInFile:(NSURL *)url {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:url.path];
    if (!handle) return @[];
    NSString *text = nil, *header = nil;
    @try {
        unsigned long long length = [handle seekToEndOfFile];
        [handle seekToFileOffset:0];
        header = [[NSString alloc] initWithData:[handle readDataOfLength:1024] encoding:NSUTF8StringEncoding];
        [handle seekToFileOffset:length > DSHLaunchBytes ? length - DSHLaunchBytes : 0];
        NSData *data = [handle readDataOfLength:DSHLaunchBytes];
        // A legacy file can end in the middle of a UTF-8 character when its
        // bounded tail is selected. Skip that incomplete first line only.
        if (length > DSHLaunchBytes) {
            const uint8_t *bytes = data.bytes;
            NSUInteger offset = 0;
            while (offset < data.length && bytes[offset] != '\n') offset++;
            data = offset < data.length ? [data subdataWithRange:NSMakeRange(offset + 1, data.length - offset - 1)] : NSData.data;
        }
        text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    } @catch (__unused NSException *exception) { self.diagnosticWriteFailed = YES; }
    @try { [handle closeFile]; } @catch (__unused NSException *exception) {}
    NSString *host = nil;
    for (NSString *line in [header componentsSeparatedByString:@"\n"]) {
        if ([line hasPrefix:@"host_launch_id: "]) host = [[NSUUID alloc] initWithUUIDString:[line substringFromIndex:16]].UUIDString;
    }
    NSMutableArray *events = [NSMutableArray new];
    if (host) [events addObject:@{@"event": @"hostStarted", @"host_launch_id": host}];
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        NSDictionary *parsed = [DSHLifecycleDiagnostics safeEventFromLogLine:line];
        if (!parsed) continue;
        NSMutableDictionary *event = [parsed mutableCopy];
        if (!event[@"host_launch_id"] && !event[@"snapshot"][@"host_launch_id"] && host) event[@"host_launch_id"] = host;
        [events addObject:event];
        if (events.count > 256) [events removeObjectAtIndex:0];
    }
    return events;
}

- (NSDictionary *)incidentAtURL:(NSURL *)url {
    NSNumber *size = nil;
    [url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
    if (size.unsignedLongLongValue > DSHIncidentBytes) return nil;
    id value = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:url] ?: NSData.data options:0 error:nil];
    if (![value isKindOfClass:NSDictionary.class] || ![value[@"events"] isKindOfClass:NSArray.class]) return nil;
    NSMutableArray *events = [NSMutableArray new];
    for (id raw in value[@"events"]) {
        if (events.count == DSHEventWindow + DSHPostIncidentEvents) break;
        NSDictionary *event = [DSHLifecycleDiagnostics sanitizedEvent:raw];
        if (event[@"event"]) [events addObject:event];
    }
    // The key is never exported; regenerate it from safe fixed metadata.
    NSDictionary *trigger = [DSHLifecycleDiagnostics sanitizedEvent:value[@"trigger"]];
    NSDictionary *terminal = [DSHLifecycleDiagnostics sanitizedEvent:value[@"terminal"]];
    NSMutableDictionary *safe = [@{@"events":events} mutableCopy];
    if (trigger[@"event"]) safe[@"trigger"] = trigger;
    if (terminal[@"event"]) safe[@"terminal"] = terminal;
    return safe;
}

- (NSArray<NSDictionary *> *)savedEvents {
    NSMutableArray *events = [NSMutableArray new];
    for (NSURL *url in diagnosticFiles(self.persistentDirectory, @"launch-", @"log")) [events addObjectsFromArray:[self eventsInFile:url]];
    return events;
}

- (NSArray<NSDictionary *> *)allDiagnosticEvents {
    // UI refreshes must not repeatedly read megabytes from disk. Historical
    // windows are read once at buffer initialization; export reads the files.
    NSMutableArray *events = [self.historicalEvents mutableCopy];
    [events addObjectsFromArray:self.diagnosticEvents];
    NSMutableOrderedSet *unique = [NSMutableOrderedSet orderedSetWithArray:events];
    return [unique.array sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSNumber *ta = a[@"observed_epoch"], *tb = b[@"observed_epoch"];
        if (ta && tb) return [ta compare:tb];
        if (ta) return NSOrderedDescending;
        if (tb) return NSOrderedAscending;
        return NSOrderedSame;
    }];
}

- (BOOL)isIncidentEvent:(NSDictionary *)event {
    if ([@[@"quiesceTaskDenied", @"quiesceExpired", @"deferredBackgroundExpired", @"sessionQuiesceFailed",
        @"sessionResumeFailed", @"sessionResumeTimedOut", @"sessionQuiesceDriverException", @"sessionResumeDriverException",
        @"guestExited", @"healthRestartLimit", @"webContentProcessTerminated", @"incompletePreviousBackground", @"sessionPatchInstallFailed", @"webPatchInstallFailed"] containsObject:event[@"event"]]) return YES;
    NSDictionary *snapshot = event[@"snapshot"] ?: event;
    return [event[@"event"] isEqual:@"quiesceWaiting"] && [event[@"wait_ms"] doubleValue] >= 1000 &&
        [snapshot[@"native_flock_count"] unsignedLongLongValue] > 0;
}

- (void)writePendingIncident {
    if (!self.pendingIncidentFile || !self.pendingIncident) return;
    NSMutableArray *events = self.pendingIncident[@"events"];
    NSData *data = diagnosticJSON(self.pendingIncident);
    while (data.length > DSHIncidentBytes && events.count > 1) {
        // The explicit trigger is never evicted to make room for aftermath.
        NSUInteger index = [events.firstObject isEqual:self.pendingIncident[@"trigger"]] ? 1 : 0;
        [events removeObjectAtIndex:index];
        data = diagnosticJSON(self.pendingIncident);
    }
    if (!data || ![data writeToURL:self.pendingIncidentFile options:NSDataWritingAtomic | NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication error:nil]) self.diagnosticWriteFailed = YES;
}

- (void)retainSafeEvent:(NSDictionary *)raw {
    NSMutableDictionary *event = [[DSHLifecycleDiagnostics sanitizedEvent:raw] mutableCopy];
    if (!event[@"event"]) return;
    NSDictionary *context = event[@"snapshot"] ?: event;
    BOOL explicitContext = [context[@"host_launch_id"] isEqual:DSHLogBuffer.hostLaunchID] && context[@"health_generation"];
    if (explicitContext) self.lastContextSnapshot = context;
    else if (!event[@"host_launch_id"] && !event[@"snapshot"]) {
        // Fixed textual companions follow a structured native hook. Carry its
        // identity so one real exit/health/WebContent event cannot consume two
        // pinned slots merely because its companion line omits the PID.
        for (NSString *key in @[@"guest_pid", @"health_generation", @"authentication_generation", @"harness_restart_count", @"guest_session_lifecycle"])
            if (!event[key] && self.lastContextSnapshot[key]) event[key] = self.lastContextSnapshot[key];
    }
    if (!event[@"host_launch_id"] && !event[@"snapshot"][@"host_launch_id"]) event[@"host_launch_id"] = DSHLogBuffer.hostLaunchID;
    event[@"observed_epoch"] = @(NSDate.date.timeIntervalSince1970);
    self.cachedDiagnosticSummary = nil;
    [self.diagnosticEvents addObject:event];
    if (self.diagnosticEvents.count > DSHEventWindow) [self.diagnosticEvents removeObjectAtIndex:0];
    NSData *json = diagnosticJSON(event);
    NSString *line = [NSString stringWithFormat:@"[lifecycle] %@\n", [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] ?: @"{}"];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (self.persistentBytes + data.length > DSHLaunchBytes && self.persistentFile) {
        NSMutableData *bounded = [[self.persistentHeader dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
        NSMutableArray *records = [NSMutableArray new];
        NSUInteger bytes = bounded.length;
        for (NSDictionary *retained in self.diagnosticEvents.reverseObjectEnumerator) {
            NSData *record = [[NSString stringWithFormat:@"[lifecycle] %@\n", [[NSString alloc] initWithData:diagnosticJSON(retained) encoding:NSUTF8StringEncoding]] dataUsingEncoding:NSUTF8StringEncoding];
            if (bytes + record.length > DSHLaunchBytes) break;
            [records insertObject:record atIndex:0]; bytes += record.length;
        }
        for (NSData *record in records) [bounded appendData:record];
        @try { [self.persistentHandle closeFile]; } @catch (__unused NSException *exception) {}
        self.persistentHandle = nil;
        if (![bounded writeToURL:self.persistentFile options:NSDataWritingAtomic | NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication error:nil]) self.diagnosticWriteFailed = YES;
        else {
            self.persistentHandle = [NSFileHandle fileHandleForWritingAtPath:self.persistentFile.path];
            @try { [self.persistentHandle seekToEndOfFile]; } @catch (__unused NSException *exception) { self.diagnosticWriteFailed = YES; }
            self.persistentBytes = bounded.length;
        }
    } else [self writePersistentData:data];
    if (self.remainingIncidentEvents && self.pendingIncident) {
        NSMutableArray *window = self.pendingIncident[@"events"];
        [window addObject:event];
        while (window.count > DSHEventWindow + DSHPostIncidentEvents) [window removeObjectAtIndex:[window.firstObject isEqual:self.pendingIncident[@"trigger"]] ? 1 : 0];
        self.remainingIncidentEvents--;
        [self writePendingIncident];
    }
    if (![self isIncidentEvent:event]) return;
    NSDictionary *snapshot = event[@"snapshot"] ?: event;
    NSString *host = snapshot[@"host_launch_id"] ?: event[@"host_launch_id"];
    NSString *key = event[@"cycle"] ? [NSString stringWithFormat:@"%@/cycle/%@", host, event[@"cycle"]] :
        [NSString stringWithFormat:@"%@/%@/%@/%@", host, event[@"event"], snapshot[@"guest_pid"] ?: @0, snapshot[@"health_generation"] ?: @0];
    BOOL terminal = ![event[@"event"] isEqual:@"quiesceWaiting"];
    NSString *terminalKey = [key stringByAppendingFormat:@"/%@", event[@"event"]];
    if ([self.incidentKeys containsObject:key]) {
        if (!terminal || [self.terminalIncidentKeys containsObject:terminalKey]) return;
        NSURL *existing = self.incidentFilesByKey[key];
        if (![self.pendingIncidentKey isEqual:key]) {
            NSDictionary *saved = existing ? [self incidentAtURL:existing] : nil;
            if (!saved) return; // This old window has already been evicted.
            self.pendingIncident = [saved mutableCopy];
            self.pendingIncident[@"events"] = [saved[@"events"] mutableCopy];
            self.pendingIncidentFile = existing;
            self.pendingIncidentKey = key;
        }
        [self.terminalIncidentKeys addObject:terminalKey];
        self.pendingIncident[@"terminal"] = event;
        NSMutableArray *window = self.pendingIncident[@"events"];
        if (![window.lastObject isEqual:event]) [window addObject:event];
        while (window.count > DSHEventWindow + DSHPostIncidentEvents) [window removeObjectAtIndex:[window.firstObject isEqual:self.pendingIncident[@"trigger"]] ? 1 : 0];
        self.remainingIncidentEvents = DSHPostIncidentEvents;
        [self.historicalEvents addObject:event];
        if (self.historicalEvents.count > 80) [self.historicalEvents removeObjectAtIndex:0];
        [self writePendingIncident];
        return;
    }
    [self.incidentKeys addObject:key];
    // Keys only deduplicate the current bounded set, never grow with uptime.
    if (self.incidentKeys.count > 64) {
        [self.incidentKeys removeAllObjects]; [self.incidentKeys addObject:key];
        [self.terminalIncidentKeys removeAllObjects]; [self.incidentFilesByKey removeAllObjects];
    }
    [self.historicalEvents addObject:event];
    if (self.historicalEvents.count > 72) [self.historicalEvents removeObjectAtIndex:0];
    self.pendingIncident = [@{@"schema":@1, @"trigger":event, @"events":[self.diagnosticEvents mutableCopy]} mutableCopy];
    self.pendingIncidentKey = key;
    if (terminal) { self.pendingIncident[@"terminal"] = event; [self.terminalIncidentKeys addObject:terminalKey]; }
    self.remainingIncidentEvents = DSHPostIncidentEvents;
    if (self.persistentDirectory) {
        self.pendingIncidentFile = [self.persistentDirectory URLByAppendingPathComponent:
            [NSString stringWithFormat:@"incident-%020.0f-%@.json", NSDate.date.timeIntervalSince1970 * 1000, NSUUID.UUID.UUIDString]];
        self.incidentFilesByKey[key] = self.pendingIncidentFile;
        [self writePendingIncident];
        [self prunePersistentLogs];
    }
}

+ (NSString *)redactedLine:(NSString *)line {
    NSString *safe = [DSHHarnessAuth redactingTokenInLine:line];
    NSMutableString *mutable = [safe mutableCopy];
    // The live view is transient and is not the shareable metadata report.
    // Redact quoted values before shortening them: consuming only their first
    // whitespace-delimited word would expose the rest of a quoted credential.
    NSArray *patterns = @[
        @"(?i)(Bearer\\s+)[A-Za-z0-9._~+/-]+={0,2}",
        @"(?i)(Authorization\\\"?\\s*[:=]\\s*)[^\\r\\n]*",
        @"(?i)((?:[A-Z0-9_]*API[ _-]?KEY|[A-Z0-9_]*TOKEN|password|secret)\\\"?\\s*[:=]\\s*)(?:\\\"[^\\\"]*\\\"|'[^']*'|[^\\s,}]+)"];
    for (NSString *pattern in patterns) {
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
        [regex replaceMatchesInString:mutable options:0 range:NSMakeRange(0, mutable.length) withTemplate:@"$1<redacted>"];
    }
    NSRegularExpression *paths = [NSRegularExpression regularExpressionWithPattern:@"(?<![:/A-Za-z0-9])/(?:[^\\s\\\"'<>]+)|[A-Za-z]:\\\\[^\\s\\\"'<>]+" options:0 error:nil];
    [paths replaceMatchesInString:mutable options:0 range:NSMakeRange(0, mutable.length) withTemplate:@"<redacted-path>"];
    return mutable;
}

+ (BOOL)isNoiseLine:(NSString *)line {
    if (line.length == 0)
        return YES;
    if ([line containsString:@"disabling flag --expose_wasm"])
        return YES;
    return NO;
}

- (void)append:(NSString *)rawLine {
    NSString *line = [rawLine stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
    if ([DSHLogBuffer isNoiseLine:line])
        return;
    @synchronized (self) {
        // Parse the original JSON before live-view path redaction changes it;
        // the structured sanitizer has no string fallback and drops all paths.
        NSDictionary *event = [DSHLifecycleDiagnostics safeEventFromLogLine:line];
        if (line.length > 16384) line = [[line substringToIndex:16384] stringByAppendingString:@" [truncated]"];
        line = [DSHLogBuffer redactedLine:line];
        if (self.storage.count < self.capacity) {
            [self.storage addObject:line];
        } else {
            self.storage[self.head] = line;
            self.head = (self.head + 1) % self.capacity;
        }
        if (event) [self retainSafeEvent:event]; else self.omittedFreeText++;
        if (self.notifyPending)
            return;
        self.notifyPending = YES;
    }
    // Coalesce bursts of lines into one UI update per run-loop turn.
    dispatch_async(dispatch_get_main_queue(), ^{
        @synchronized (self) { self.notifyPending = NO; }
        [NSNotificationCenter.defaultCenter postNotificationName:DSHLogBufferDidChangeNotification object:self];
    });
}

- (void)clear {
    @synchronized (self) {
        [self.storage removeAllObjects];
        self.head = 0;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:DSHLogBufferDidChangeNotification object:self];
    });
}

- (NSUInteger)count {
    @synchronized (self) { return self.storage.count; }
}

- (NSArray<NSString *> *)lines {
    @synchronized (self) {
        if (self.storage.count < self.capacity || self.head == 0)
            return [self.storage copy];
        NSMutableArray *ordered = [NSMutableArray arrayWithCapacity:self.capacity];
        [ordered addObjectsFromArray:[self.storage subarrayWithRange:NSMakeRange(self.head, self.capacity - self.head)]];
        [ordered addObjectsFromArray:[self.storage subarrayWithRange:NSMakeRange(0, self.head)]];
        return ordered;
    }
}

- (NSString *)tail:(NSUInteger)n {
    NSArray<NSString *> *all = self.lines;
    if (all.count > n)
        all = [all subarrayWithRange:NSMakeRange(all.count - n, n)];
    return [all componentsJoinedByString:@"\n"];
}

- (NSString *)diagnosticReport {
    @synchronized (self) {
        [self synchronizePersistentDiagnostics];
        NSMutableString *report = [NSMutableString stringWithString:
            @"DSH local metadata diagnostic report\n"
             "Stored locally; no automatic upload. Review before sharing.\n"
             "Scope: whitelisted native lifecycle/status/performance metadata only.\n"
             "Guest free-form output, user content, URLs, paths and credentials are not included; current free-form output can be viewed in Server Log.\n"
             "Retention: at most 10 new launch files (256 KiB each), 4 pinned incident windows (128 KiB each), 32 events before/at trigger and 8 afterwards. Legacy logs are read through a bounded 256 KiB tail. Older evidence can be evicted.\n"
             "A new host launch ID does not establish a system termination reason.\n\n"];
        [report appendFormat:@"%@\n\n", self.diagnosticSummary];
        NSRegularExpression *version = [NSRegularExpression regularExpressionWithPattern:@"^[0-9]+(?:\\.[0-9]+)*$" options:0 error:nil];
        NSMutableArray *versions = [NSMutableArray new];
        for (id raw in @[NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"", NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"] ?: @"", UIDevice.currentDevice.systemVersion ?: @""]) {
            NSString *value = [raw isKindOfClass:NSString.class] ? raw : @"";
            [versions addObject:value.length <= 32 && [version firstMatchInString:value options:0 range:NSMakeRange(0, value.length)] ? value : @"unavailable"];
        }
        [report appendFormat:@"app: %@ build %@\ndevice_family: %@\nsystem_version: %@\n", versions[0], versions[1], UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad ? @"iPad" : @"iPhone/other", versions[2]];
        [report appendFormat:@"omitted_free_text_this_buffer: %lu\nlocal_write_failed: %@\n", (unsigned long)self.omittedFreeText, self.diagnosticWriteFailed ? @"yes" : @"no"];
        NSArray *launches = DSHStartupMetrics.shared.recentLaunches;
        [report appendString:@"Startup stages (seconds from launch):\n"];
        for (NSUInteger i = 0; i < MIN(launches.count, 5u); i++) {
            id launch = launches[i];
            if (![launch isKindOfClass:NSDictionary.class]) continue;
            NSDictionary *stages = [launch[@"stages"] isKindOfClass:NSDictionary.class] ? launch[@"stages"] : @{};
            for (NSString *stage in @[@"image_ready", @"kernel_ready", @"bridge_ready", @"harness_ready", @"web_ready"]) {
                id value = stages[stage];
                if ([value isKindOfClass:NSNumber.class] && isfinite([value doubleValue])) [report appendFormat:@"%lu %@: %.3f\n", (unsigned long)i + 1, stage, [value doubleValue]];
            }
        }
        for (NSURL *url in diagnosticFiles(self.persistentDirectory, @"incident-", @"json")) {
            [report appendString:@"\n===== pinned incident (metadata only) =====\n"];
            NSDictionary *incident = [self incidentAtURL:url];
            for (NSDictionary *event in incident[@"events"])
                [report appendFormat:@"[lifecycle] %@\n", [[NSString alloc] initWithData:diagnosticJSON(event) encoding:NSUTF8StringEncoding]];
            if (incident[@"terminal"] && ![incident[@"events"] containsObject:incident[@"terminal"]])
                [report appendFormat:@"[lifecycle] %@\n", [[NSString alloc] initWithData:diagnosticJSON(incident[@"terminal"]) encoding:NSUTF8StringEncoding]];
        }
        for (NSDictionary *event in [self savedEvents])
            [report appendFormat:@"[lifecycle] %@\n", [[NSString alloc] initWithData:diagnosticJSON(event) encoding:NSUTF8StringEncoding]];
        [report appendString:@"\n===== current metadata window =====\n"];
        for (NSDictionary *event in self.diagnosticEvents)
            [report appendFormat:@"[lifecycle] %@\n", [[NSString alloc] initWithData:diagnosticJSON(event) encoding:NSUTF8StringEncoding]];
        return report;
    }
}

- (NSString *)diagnosticSummary {
    @synchronized (self) {
        if (self.cachedDiagnosticSummary) return self.cachedDiagnosticSummary;
        NSMutableArray *lines = [NSMutableArray arrayWithObject:@"Local observations / 本地观察（保守分类）:"];
        for (NSDictionary *finding in [DSHLifecycleDiagnostics findingsForEvents:self.allDiagnosticEvents currentHostLaunchID:DSHLogBuffer.hostLaunchID])
            [lines addObject:[NSString stringWithFormat:@"- %@: %@", finding[@"kind"], finding[@"detail"]]];
        self.cachedDiagnosticSummary = [lines componentsJoinedByString:@"\n"];
        return self.cachedDiagnosticSummary;
    }
}

- (NSUInteger)retainedIncidentCount {
    @synchronized (self) { return diagnosticFiles(self.persistentDirectory, @"incident-", @"json").count; }
}

- (NSURL *)writeDiagnosticAttachmentWithError:(NSError **)error {
    NSURL *directory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"DSHDiagnosticAttachments"] isDirectory:YES];
    return [self writeDiagnosticAttachmentInDirectory:directory error:error];
}

- (NSURL *)writeDiagnosticAttachmentInDirectory:(NSURL *)directory error:(NSError **)error {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication} error:error]) return nil;
    NSArray *files = diagnosticFiles(directory, @"DSH-diagnostics-", @"txt");
    for (NSUInteger i = 0; i < files.count; i++) {
        NSDate *modified = nil;
        [files[i] getResourceValue:&modified forKey:NSURLContentModificationDateKey error:nil];
        if (i + 2 < files.count || -modified.timeIntervalSinceNow > 24 * 60 * 60) [fm removeItemAtURL:files[i] error:nil];
    }
    NSURL *url = [directory URLByAppendingPathComponent:[NSString stringWithFormat:@"DSH-diagnostics-%@.txt", NSUUID.UUID.UUIDString]];
    if (![[self.diagnosticReport dataUsingEncoding:NSUTF8StringEncoding] writeToURL:url options:NSDataWritingAtomic | NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication error:error]) return nil;
    return url;
}

- (void)clearRetainedDiagnostics {
    @synchronized (self) {
        @try { [self.persistentHandle closeFile]; } @catch (__unused NSException *exception) {}
        self.persistentHandle = nil;
        for (NSURL *url in diagnosticFiles(self.persistentDirectory, @"launch-", @"log")) [NSFileManager.defaultManager removeItemAtURL:url error:nil];
        for (NSURL *url in diagnosticFiles(self.persistentDirectory, @"incident-", @"json")) [NSFileManager.defaultManager removeItemAtURL:url error:nil];
        [self.diagnosticEvents removeAllObjects]; [self.incidentKeys removeAllObjects];
        [self.terminalIncidentKeys removeAllObjects]; [self.incidentFilesByKey removeAllObjects];
        [self.historicalEvents removeAllObjects];
        self.cachedDiagnosticSummary = nil;
        self.lastContextSnapshot = nil;
        self.pendingIncident = nil; self.pendingIncidentFile = nil; self.pendingIncidentKey = nil; self.remainingIncidentEvents = 0;
        self.omittedFreeText = 0; self.persistentBytes = 0;
        if (self.persistentFile) {
            [NSFileManager.defaultManager createFileAtPath:self.persistentFile.path contents:nil attributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication}];
            self.persistentHandle = [NSFileHandle fileHandleForWritingAtPath:self.persistentFile.path];
            [self writePersistentData:[self.persistentHeader dataUsingEncoding:NSUTF8StringEncoding]];
        }
        [self clear];
    }
}

- (void)synchronizePersistentDiagnostics {
    @synchronized (self) {
        @try { [self.persistentHandle synchronizeFile]; } @catch (__unused NSException *exception) { self.diagnosticWriteFailed = YES; }
    }
}

@end
