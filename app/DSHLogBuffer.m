//
//  DSHLogBuffer.m
//  DSH
//

#import "DSHLogBuffer.h"
#import "DSHHarnessAuth.h"
#import <UIKit/UIKit.h>
#import "DSHStartupMetrics.h"
#include <sys/sysctl.h>
#include <unistd.h>

static BOOL DSHHostStartWasObserved;

DSH_EXPORTED NSNotificationName const DSHLogBufferDidChangeNotification = @"DSHLogBufferDidChangeNotification";

@interface DSHLogBuffer ()
@property (nonatomic) NSMutableArray<NSString *> *storage;
@property (nonatomic) NSUInteger head;   // index of the oldest line when full
@property (nonatomic) BOOL notifyPending;
@property (nonatomic) NSURL *persistentDirectory;
@property (nonatomic) NSURL *persistentFile;
@property (nonatomic) NSFileHandle *persistentHandle;
@property (nonatomic) NSDate *startedAt;
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
        if (![fm createDirectoryAtURL:_persistentDirectory withIntermediateDirectories:YES attributes:nil error:nil])
            return self;

        NSDateFormatter *name = [NSDateFormatter new];
        name.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        name.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
        name.dateFormat = @"yyyyMMdd-HHmmss-SSS";
        _persistentFile = [_persistentDirectory URLByAppendingPathComponent:
                           [NSString stringWithFormat:@"launch-%@-%@-%@.log", [name stringFromDate:_startedAt], DSHLogBuffer.hostLaunchID, NSUUID.UUID.UUIDString]];
        [fm createFileAtPath:_persistentFile.path contents:nil attributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication}];
        _persistentHandle = [NSFileHandle fileHandleForWritingAtPath:_persistentFile.path];

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
        [_persistentHandle writeData:[header dataUsingEncoding:NSUTF8StringEncoding]];
        [self synchronizePersistentDiagnostics];
        [self prunePersistentLogs];
    }
    return self;
}

- (void)dealloc {
    [self.persistentHandle closeFile];
}

- (void)prunePersistentLogs {
    if (self.persistentDirectory == nil)
        return;
    NSArray<NSURL *> *files = [NSFileManager.defaultManager contentsOfDirectoryAtURL:self.persistentDirectory
                                                          includingPropertiesForKeys:nil options:0 error:nil];
    files = [[files filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSURL *url, NSDictionary *bindings) {
        return [url.lastPathComponent hasPrefix:@"launch-"] && [url.pathExtension isEqualToString:@"log"];
    }]] sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        return [b.lastPathComponent compare:a.lastPathComponent];
    }];
    for (NSUInteger i = 10; i < files.count; i++)
        [NSFileManager.defaultManager removeItemAtURL:files[i] error:nil];
}

+ (NSString *)redactedLine:(NSString *)line {
    // The launch token goes first and is removed by value rather than by key:
    // dsh prints it as a query parameter, not as `SOMETHING=secret`, so the
    // key/value heuristic below would walk straight past it. Under dsh 0.2.x
    // this line is written to every launch log and included in diagnostics
    // reports the user can share, so it is the one that matters most.
    NSString *safe = [DSHHarnessAuth redactingTokenInLine:line];
    NSMutableString *mutable = [safe mutableCopy];
    NSArray<NSString *> *keys = @[@"DEEPSEEK_API_KEY", @"DSH_HOST_BRIDGE_TOKEN", @"Authorization: Bearer"];
    for (NSString *key in keys) {
        NSRange search = NSMakeRange(0, mutable.length);
        while (search.length > 0) {
            NSRange hit = [mutable rangeOfString:key options:NSCaseInsensitiveSearch range:search];
            if (hit.location == NSNotFound)
                break;
            NSUInteger valueStart = NSMaxRange(hit);
            while (valueStart < mutable.length && [@" =:\t" containsString:[mutable substringWithRange:NSMakeRange(valueStart, 1)]])
                valueStart++;
            NSUInteger valueEnd = valueStart;
            while (valueEnd < mutable.length && ![NSCharacterSet.whitespaceAndNewlineCharacterSet characterIsMember:[mutable characterAtIndex:valueEnd]])
                valueEnd++;
            [mutable replaceCharactersInRange:NSMakeRange(valueStart, valueEnd - valueStart) withString:@"<redacted>"];
            search = NSMakeRange(MIN(NSMaxRange(hit) + 10, mutable.length), mutable.length - MIN(NSMaxRange(hit) + 10, mutable.length));
        }
    }
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
        line = [DSHLogBuffer redactedLine:line];
        if (self.storage.count < self.capacity) {
            [self.storage addObject:line];
        } else {
            self.storage[self.head] = line;
            self.head = (self.head + 1) % self.capacity;
        }
        if (self.persistentHandle != nil) {
            NSTimeInterval elapsed = -self.startedAt.timeIntervalSinceNow;
            NSString *record = [NSString stringWithFormat:@"+%8.3fs %@\n", elapsed, line];
            [self.persistentHandle writeData:[record dataUsingEncoding:NSUTF8StringEncoding]];
        }
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
    if (self.persistentDirectory == nil)
        return [self.lines componentsJoinedByString:@"\n"];
    [self synchronizePersistentDiagnostics];
    NSArray<NSURL *> *files = [NSFileManager.defaultManager contentsOfDirectoryAtURL:self.persistentDirectory
                                                          includingPropertiesForKeys:nil options:0 error:nil];
    files = [[files filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSURL *url, NSDictionary *bindings) {
        return [url.lastPathComponent hasPrefix:@"launch-"] && [url.pathExtension isEqualToString:@"log"];
    }]] sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        return [b.lastPathComponent compare:a.lastPathComponent];
    }];
    NSMutableString *report = [NSMutableString stringWithString:
        @"DSH diagnostic report\nRecent launches, newest first. Review before sharing.\n"];
    [report appendFormat:@"\n%@\n", DSHStartupMetrics.shared.summary];
    for (NSURL *url in files) {
        NSString *contents = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil];
        if (contents.length)
            [report appendFormat:@"\n===== %@ =====\n%@", url.lastPathComponent, contents];
    }
    return report;
}

- (void)synchronizePersistentDiagnostics {
    @synchronized (self) {
        [self.persistentHandle synchronizeFile];
    }
}

@end
