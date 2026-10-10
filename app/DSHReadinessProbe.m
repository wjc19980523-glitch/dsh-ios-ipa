//
//  DSHReadinessProbe.m
//  DSH
//

#import "DSHReadinessProbe.h"

#pragma mark - Result

@interface DSHProbeResult ()
@property (nonatomic, readwrite) DSHProbeOutcome outcome;
@property (nonatomic, readwrite) NSInteger statusCode;
@property (nonatomic, readwrite) NSTimeInterval duration;
@property (nonatomic, readwrite, copy) NSString *method;
@property (nonatomic, readwrite, nullable) NSError *error;
@end

@implementation DSHProbeResult

- (BOOL)alive {
    return self.outcome == DSHProbeOutcomeAnswered;
}

- (BOOL)indicatesDeadServer {
    // A timeout is not evidence of a dead server: on this emulator the guest
    // can be mid-boot, mid-GC, or competing with the UI for the CPU and still
    // be perfectly healthy. Only a refused/reset connection or a real 5xx
    // proves nothing is serving.
    return self.outcome == DSHProbeOutcomeUnreachable || self.outcome == DSHProbeOutcomeBadStatus;
}

- (NSString *)summary {
    switch (self.outcome) {
        case DSHProbeOutcomeAnswered:
            return [NSString stringWithFormat:@"HTTP %ld via %@ in %.2fs", (long) self.statusCode, self.method, self.duration];
        case DSHProbeOutcomeTimedOut:
            return [NSString stringWithFormat:@"timeout via %@ after %.2fs (no answer within budget)", self.method, self.duration];
        case DSHProbeOutcomeUnreachable:
            return [NSString stringWithFormat:@"unreachable via %@ after %.2fs (%@ %ld)", self.method, self.duration,
                                              self.error.domain, (long) self.error.code];
        case DSHProbeOutcomeBadStatus:
            return [NSString stringWithFormat:@"HTTP %ld via %@ in %.2fs (server-side error)", (long) self.statusCode,
                                              self.method, self.duration];
        case DSHProbeOutcomeCancelled:
            return @"cancelled before it completed";
    }
    return @"unknown";
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<DSHProbeResult %@>", self.summary];
}

@end

#pragma mark - Probe

@interface DSHReadinessProbe ()
@property (nonatomic) NSURL *url;
@property (nonatomic) NSTimeInterval interval;
@property (nonatomic) NSTimeInterval timeout;
@property (nonatomic, copy, nullable) DSHReadinessHandler handler;
@property (nonatomic) NSDate *startedAt;
@property (nonatomic) NSUInteger generation;
@property (nonatomic, readwrite, getter=isRunning) BOOL running;
@end

@implementation DSHReadinessProbe

+ (NSURLSession *)ephemeralSession {
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.timeoutIntervalForRequest = 3;
    config.timeoutIntervalForResource = 3;
    config.requestCachePolicy = NSURLRequestReloadIgnoringLocalAndRemoteCacheData;
    config.waitsForConnectivity = NO;
    return [NSURLSession sessionWithConfiguration:config];
}

- (instancetype)initWithURL:(NSURL *)url interval:(NSTimeInterval)interval timeout:(NSTimeInterval)timeout {
    if (self = [super init]) {
        _url = url;
        _interval = MAX(interval, 0.05);
        _timeout = timeout;
        _session = [DSHReadinessProbe ephemeralSession];
    }
    return self;
}

- (void)startWithHandler:(DSHReadinessHandler)handler {
    NSAssert(NSThread.isMainThread, @"start on main");
    [self cancel];
    self.handler = handler;
    self.startedAt = NSDate.date;
    self.running = YES;
    self.generation++;
    [self probeWithGeneration:self.generation];
}

- (void)cancel {
    NSAssert(NSThread.isMainThread, @"cancel on main");
    if (!self.running)
        return;
    self.running = NO;
    self.generation++;
    DSHReadinessHandler handler = self.handler;
    self.handler = nil;
    if (handler)
        handler(NO, -self.startedAt.timeIntervalSinceNow);
}

- (void)finish:(BOOL)ready {
    if (!self.running)
        return;
    self.running = NO;
    self.generation++;
    DSHReadinessHandler handler = self.handler;
    self.handler = nil;
    if (handler)
        handler(ready, -self.startedAt.timeIntervalSinceNow);
}

- (void)probeWithGeneration:(NSUInteger)generation {
    if (generation != self.generation || !self.running)
        return;
    if (self.timeout > 0 && -self.startedAt.timeIntervalSinceNow > self.timeout) {
        [self finish:NO];
        return;
    }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:self.url];
    req.HTTPMethod = @"HEAD";
    req.cachePolicy = NSURLRequestReloadIgnoringLocalAndRemoteCacheData;
    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        BOOL ok = NO;
        if ([response isKindOfClass:NSHTTPURLResponse.class]) {
            NSInteger code = ((NSHTTPURLResponse *) response).statusCode;
            // HEAD may be refused with 405 by some servers; any HTTP answer
            // still proves the listener is up.
            ok = code > 0 && code < 500;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (self == nil || generation != self.generation || !self.running)
                return;
            if (ok) {
                [self finish:YES];
                return;
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t) (self.interval * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [weakSelf probeWithGeneration:generation];
            });
        });
    }];
    [task resume];
}

#pragma mark - One-shot check

/// Classify a transport error. Foundation reports a timeout as
/// NSURLErrorTimedOut; a listener that is not bound surfaces as "cannot
/// connect to host" / "connection refused" / "network connection lost".
static DSHProbeOutcome DSHProbeOutcomeForError(NSError *error) {
    if (error == nil)
        return DSHProbeOutcomeAnswered;
    switch (error.code) {
        case NSURLErrorTimedOut:
            return DSHProbeOutcomeTimedOut;
        case NSURLErrorCancelled:
            return DSHProbeOutcomeCancelled;
        case NSURLErrorCannotConnectToHost:
        case NSURLErrorCannotFindHost:
        case NSURLErrorNetworkConnectionLost:
        case NSURLErrorNotConnectedToInternet:
        case NSURLErrorDNSLookupFailed:
        case NSURLErrorResourceUnavailable:
            return DSHProbeOutcomeUnreachable;
        default:
            break;
    }
    // Connection-level errno wrapped by CFNetwork (ECONNREFUSED etc.) lands in
    // NSPOSIXErrorDomain; treat the whole transport domain as unreachable.
    if ([error.domain isEqualToString:NSPOSIXErrorDomain])
        return DSHProbeOutcomeUnreachable;
    return DSHProbeOutcomeUnreachable;
}

/// One request round with a hard deadline enforced by us rather than trusting
/// the session, so a stalled socket cannot outlive the budget.
+ (void)performRequestWithMethod:(NSString *)method
                             url:(NSURL *)url
                    connectTimeout:(NSTimeInterval)connectTimeout
                     totalTimeout:(NSTimeInterval)totalTimeout
                      completion:(void (^)(NSURLResponse * _Nullable, NSError * _Nullable, NSTimeInterval))completion {
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    // The per-request interval only bounds idle time between packets; a server
    // that dribbles bytes can keep a request alive far longer than the budget
    // the caller asked for. Both are set, and a wall-clock watchdog on top
    // guarantees the caller's number is respected.
    config.timeoutIntervalForRequest = connectTimeout;
    config.timeoutIntervalForResource = totalTimeout;
    config.requestCachePolicy = NSURLRequestReloadIgnoringLocalAndRemoteCacheData;
    config.waitsForConnectivity = NO;
    // A HEAD against a just-resumed server can otherwise reuse a socket the
    // kernel already tore down during suspension, which surfaces as a bogus
    // failure on the first request after foregrounding.
    config.HTTPShouldUsePipelining = NO;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = method;
    req.cachePolicy = NSURLRequestReloadIgnoringLocalAndRemoteCacheData;
    req.timeoutInterval = totalTimeout;

    NSDate *t0 = NSDate.date;
    __block BOOL settled = NO;

    NSURLSessionDataTask *task = [session dataTaskWithRequest:req
                                           completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (settled) return;
        settled = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(response, error, -t0.timeIntervalSinceNow);
            [session finishTasksAndInvalidate];
        });
    }];
    [task resume];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t) (totalTimeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (settled) return;
        settled = YES;
        [task cancel];
        [session invalidateAndCancel];
        NSError *timeout = [NSError errorWithDomain:NSURLErrorDomain
                                              code:NSURLErrorTimedOut
                                          userInfo:@{NSLocalizedDescriptionKey: @"health check exceeded its deadline"}];
        completion(nil, timeout, -t0.timeIntervalSinceNow);
    });
}

+ (void)checkURL:(NSURL *)url
         timeout:(NSTimeInterval)timeout
      completion:(void (^)(DSHProbeResult *result))completion {
    NSParameterAssert(completion != nil);
    // Give the connection attempt a slice of the budget and the whole budget
    // for the exchange; a caller passing 0 means "no limit", which we clamp to
    // something finite because an unbounded health check would hang the retry
    // ladder that depends on it.
    NSTimeInterval total = timeout > 0 ? timeout : 30;
    NSTimeInterval connect = MIN(MAX(total * 0.6, 3.0), total);

    [self performRequestWithMethod:@"HEAD"
                               url:url
                    connectTimeout:connect
                      totalTimeout:total
                        completion:^(NSURLResponse *response, NSError *error, NSTimeInterval elapsed) {
        DSHProbeResult *result = [DSHProbeResult new];
        result.method = @"HEAD";
        result.duration = elapsed;
        result.error = error;

        if ([response isKindOfClass:NSHTTPURLResponse.class]) {
            NSInteger code = ((NSHTTPURLResponse *) response).statusCode;
            result.statusCode = code;
            result.outcome = code >= 500 ? DSHProbeOutcomeBadStatus : DSHProbeOutcomeAnswered;
            completion(result);
            return;
        }

        // No HTTP answer from HEAD. A 4xx/405-style refusal never reaches here
        // (that is a response), so this is a transport-level failure. Retry
        // once with GET before calling it: some servers and proxies drop HEAD
        // outright, and a false "dead" verdict would restart a healthy guest.
        if (error.code == NSURLErrorCancelled) {
            result.outcome = DSHProbeOutcomeCancelled;
            completion(result);
            return;
        }

        NSTimeInterval remaining = total - elapsed;
        if (remaining < 1.0) {
            // No budget left for a second attempt; report what we have.
            result.outcome = DSHProbeOutcomeForError(error);
            completion(result);
            return;
        }

        [self performRequestWithMethod:@"GET"
                                   url:url
                        connectTimeout:MIN(MAX(remaining * 0.6, 3.0), remaining)
                          totalTimeout:remaining
                            completion:^(NSURLResponse *retryResponse, NSError *retryError, NSTimeInterval retryElapsed) {
            DSHProbeResult *retry = [DSHProbeResult new];
            retry.method = @"GET";
            retry.duration = elapsed + retryElapsed;
            retry.error = retryError;
            if ([retryResponse isKindOfClass:NSHTTPURLResponse.class]) {
                NSInteger code = ((NSHTTPURLResponse *) retryResponse).statusCode;
                retry.statusCode = code;
                retry.outcome = code >= 500 ? DSHProbeOutcomeBadStatus : DSHProbeOutcomeAnswered;
            } else {
                // Prefer the GET diagnosis unless it was merely late, in which
                // case the HEAD timeout is the more informative story.
                DSHProbeOutcome head = DSHProbeOutcomeForError(error);
                DSHProbeOutcome get = DSHProbeOutcomeForError(retryError);
                retry.outcome = (get == DSHProbeOutcomeCancelled && head != DSHProbeOutcomeCancelled) ? head : get;
                if (retry.error == nil)
                    retry.error = error;
            }
            completion(retry);
        }];
    }];
}

@end
