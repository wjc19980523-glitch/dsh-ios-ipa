//
//  DSHTestHTTPServer.h
//  DSHTests
//
//  Tiny loopback HTTP server (answers every request with 200) so unit tests
//  can drive DSHReadinessProbe / DSHHarness without the Linux guest.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DSHTestHTTPServer : NSObject
/// Binds 127.0.0.1:port (0 = ephemeral) and starts accepting. Returns nil on failure.
- (nullable instancetype)initWithPort:(uint16_t)port;
@property (nonatomic, readonly) uint16_t port;
@property (nonatomic, readonly) NSURL *baseURL;
@property (atomic) NSInteger statusCode;   // default 200
@property (atomic, readonly) NSUInteger requestCount;
/// Accept the connection but never write a response. Simulates the emulator's
/// guest being wedged mid-boot, which is what a too-short health-check timeout
/// misreads as "the server is dead".
@property (atomic) BOOL stalls;
/// Count of requests that arrived with a HEAD method, so tests can assert the
/// probe actually used the cheap method.
@property (atomic, readonly) NSUInteger headRequestCount;
/// Count of requests that arrived with a GET method (the fallback path).
@property (atomic, readonly) NSUInteger getRequestCount;

#pragma mark - Launch-token authentication (models dsh 0.2.x)

/// When set, the server behaves like dsh 0.2.x before a caller has completed
/// the handshake:
///
///   * any request without the auth cookie is answered 401, `HEAD` included;
///   * a `GET /?token=<launchToken>` is answered 303 with `location: ./` and a
///     `Set-Cookie` for `DSHHarnessAuthCookiePrefix`;
///   * any later request carrying that cookie is served normally.
///
/// `launchToken` is deliberately separate from `statusCode`, which keeps its
/// role for the tests that only care about a bare status.
@property (atomic) BOOL requiresLaunchToken;
/// The token this "process" accepts. Changing it models a restart: the old
/// cookie is still accepted (dsh signs it with a per-installation secret), but
/// the old `?token=` URL is not.
@property (atomic, copy, nullable) NSString *launchToken;
/// How many times the token exchange itself succeeded (a 303 was issued), so a
/// test can tell "authenticated once" from "re-authenticated after a restart".
@property (atomic, readonly) NSUInteger tokenExchangeCount;
/// How many requests were refused with 401, so a test can prove the client
/// really did try unauthenticated first.
@property (atomic, readonly) NSUInteger unauthorizedCount;
/// The cookie value handed out by the last successful exchange.
@property (atomic, readonly, copy, nullable) NSString *issuedCookieValue;

- (void)stop;
@end

NS_ASSUME_NONNULL_END
