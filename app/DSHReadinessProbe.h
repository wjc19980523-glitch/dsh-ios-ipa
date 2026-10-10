//
//  DSHReadinessProbe.h
//  DSH
//
//  Polls an HTTP URL until it answers, then reports success once. Used to
//  find out when the guest's dsh web server is accepting connections.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^DSHReadinessHandler)(BOOL ready, NSTimeInterval elapsed);

/// Why a one-shot health check did or did not succeed. The distinction matters:
/// only `Unreachable` and `BadStatus` mean the guest is really in trouble, while
/// `TimedOut` and `Cancelled` are routinely produced by a just-resumed app on a
/// loaded device and must not, on their own, trigger a restart.
typedef NS_ENUM(NSInteger, DSHProbeOutcome) {
    /// The server answered with a status below 400. The web UI is being served
    /// to whoever asked, which for 127.0.0.1 means this app.
    DSHProbeOutcomeAnswered = 0,
    /// The request exceeded its budget. On this emulator a cold JIT plus a
    /// busy CPU can push a trivial HEAD well past a few seconds.
    DSHProbeOutcomeTimedOut,
    /// The connection was refused, reset, or could not be established: no
    /// listener is bound, so the server is genuinely gone.
    DSHProbeOutcomeUnreachable,
    /// The server answered but reported a server-side error (status >= 500).
    DSHProbeOutcomeBadStatus,
    /// The check was superseded or the app went away before it finished.
    DSHProbeOutcomeCancelled,
    /// dsh 0.2.x refused the request because it carried no (or a stale)
    /// authentication cookie.
    ///
    /// This is deliberately not "answered": the listener is up, so nothing is
    /// dead and a restart would throw away a healthy guest, but the web UI is
    /// NOT being served to this caller. Collapsing it into `Answered` — which
    /// is what the probe did before dsh 0.2.x introduced launch tokens — meant
    /// a WKWebView pointed at a bare URL would load a 401 body forever while
    /// every health check reported green.
    ///
    /// The caller that owns an authentication flow must treat this as "check
    /// your credentials and try again", not as "the server is gone".
    DSHProbeOutcomeUnauthorized,
};

/// Everything a health check learned, so failures can be told apart in the log
/// instead of collapsing into a bare "did not answer".
@interface DSHProbeResult : NSObject

@property (nonatomic, readonly) DSHProbeOutcome outcome;
/// HTTP status code, or 0 when no response was received.
@property (nonatomic, readonly) NSInteger statusCode;
/// Wall-clock duration of the request in seconds.
@property (nonatomic, readonly) NSTimeInterval duration;
/// HTTP method actually used ("HEAD", or "GET" after the HEAD fallback).
@property (nonatomic, readonly, copy) NSString *method;
/// Underlying transport error, when there was one.
@property (nonatomic, readonly, nullable) NSError *error;

/// YES when the server is demonstrably serving. A 401 is not "serving": the
/// listener is alive but it is refusing this caller.
@property (nonatomic, readonly) BOOL alive;
/// YES when the failure mode indicates the listener is actually gone, rather
/// than the check merely being late or the credentials merely being stale.
/// Drives the restart/retry decision.
@property (nonatomic, readonly) BOOL indicatesDeadServer;
/// YES when the server answered but demanded authentication. The caller should
/// re-run its authentication flow rather than restart anything.
@property (nonatomic, readonly) BOOL requiresAuthentication;
/// Short human-readable classification for the activity log.
@property (nonatomic, readonly, copy) NSString *summary;

@end

@interface DSHReadinessProbe : NSObject

- (instancetype)initWithURL:(NSURL *)url
                   interval:(NSTimeInterval)interval
                    timeout:(NSTimeInterval)timeout NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// URLSession used for probing; replaceable for tests.
@property (nonatomic) NSURLSession *session;

/// Starts polling. `handler` fires exactly once on the main queue: `ready=YES`
/// as soon as the URL responds with 2xx/3xx, `ready=NO` after `timeout`
/// seconds or after -cancel.
///
/// The URL must be one the app is authorised to fetch. Under dsh 0.2.x the
/// bare origin answers 401 to everything without a valid auth cookie, so the
/// readiness wait needs the authenticated entry URL (see
/// -[DSHHarness authenticatedEntryURL]); pointed at a bare origin this poll
/// would never succeed and the boot would be declared timed out.
- (void)startWithHandler:(DSHReadinessHandler)handler;
- (void)cancel;

@property (nonatomic, readonly, getter=isRunning) BOOL running;

/// One-shot check with full diagnostics. `completion` runs on the main queue.
/// A HEAD request is tried first (cheap, and the bundled frontend answers it);
/// if HEAD fails in a way that suggests method rejection rather than a dead
/// listener, the check retries once with GET before giving up.
+ (void)checkURL:(NSURL *)url
         timeout:(NSTimeInterval)timeout
       completion:(void (^)(DSHProbeResult *result))completion;

@end

NS_ASSUME_NONNULL_END
