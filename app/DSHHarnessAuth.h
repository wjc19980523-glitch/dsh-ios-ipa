//
//  DSHHarnessAuth.h
//  DSH
//
//  Everything DSH knows about the dsh web server's launch-token handshake.
//
//  dsh 0.2.x (introduced upstream alongside the plugin-graph rewrite) refuses
//  to serve the web UI to a caller that has not proved it is the one that
//  started the process. On boot it prints
//
//      dsh web: http://127.0.0.1:3181/?token=<43 url-safe chars>
//
//  and every request without the resulting cookie is answered 401, including
//  HEAD. Fetching that URL once with the token in the query string is the
//  whole handshake: the server replies 303 with `location: ./` and a
//  `Set-Cookie: dsh-auth-<hash>=<value>` header, after which the ordinary
//  origin works.
//
//  Two properties drive the design of the iOS side:
//
//   1. The token is per *process*. `processLaunchToken` keeps it in a WeakMap
//      keyed by the server object, so every restart mints a new one and the
//      URL printed by the previous incarnation is dead.
//   2. The signing secret behind the cookie is per *installation*. It is
//      persisted through the harness credentials store, so a cookie that was
//      once accepted stays valid across a restart, as long as the authority
//      (scheme, host and port) is unchanged.
//
//  Together those two mean "authenticate on the way in, and re-authenticate
//  whenever the authority may have changed" -- which is what this file encodes
//  so that the harness, the web view, the readiness probe and the Safari
//  hand-off cannot drift apart.
//
//  The token is a bearer credential for a loopback service. It must never
//  reach the activity log, the diagnostics report, a build artefact, or an
//  upstream issue; -[DSHLogBuffer redactedLine:] is the last line of defence
//  for that, and this file keeps it out of the ordinary paths.
//

/// Marks a plain C symbol as part of the app executable's dynamic symbol table.
///
/// On iOS an executable exports *no* C globals unless asked: everything is
/// hidden by default, and `GCC_SYMBOLS_PRIVATE_EXTERN` only relaxes that for
/// Objective-C classes. DSHTests is hosted by the app (`TEST_HOST` is
/// `DSH.app/DSH`) and links against it through `-bundle_loader`, so every
/// plain-C symbol a test reads -- these two constants, `DSHDisplayValue`,
/// `DSHHarnessStateName`, an `NSNotificationName` -- is invisible to the test
/// bundle without this. The symptom is a link failure, "Undefined symbols for
/// architecture arm64", *after* every source file has compiled cleanly, which
/// is misleading enough to be worth the two lines.
///
/// Guarded so any header can carry it, and so the `-Wl,-exported_symbol` list
/// in AppDSH.xcconfig has exactly one name for each symbol it must match.
#ifndef DSH_EXPORTED
#define DSH_EXPORTED __attribute__((visibility("default")))
#endif

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The query parameter dsh puts its launch token in (`TOKEN_QUERY` upstream).
///
/// Exported because it is a *protocol fact* -- the query key and cookie prefix
/// that dsh 0.2.x uses -- and the tests are entitled to read it rather than
/// restate the string and drift.
extern DSH_EXPORTED NSString *const DSHHarnessTokenQueryKey;
/// Prefix of the cookie dsh sets (`COOKIE_PREFIX` upstream). The full name is
/// `dsh-auth-<base64url(sha256(authority))>`, so the prefix is all we can match
/// without reimplementing the server's hashing.
extern DSH_EXPORTED NSString *const DSHHarnessAuthCookiePrefix;

@interface DSHHarnessAuth : NSObject

/// The launch token carried by the server's `dsh web: ...` announcement, or
/// nil when the line is not that announcement or carries no token.
///
/// Accepts the exact shapes dsh logs: the URL may be followed by trailing text
/// (a terminal colour reset, a period, quotes), which is why this scans the
/// token's own alphabet rather than parsing to end of line.
+ (nullable NSString *)tokenFromServeLogLine:(NSString *)line;

/// Whether a line looks like the server announcing its web URL. Used to mark
/// the moment the port is bound, independently of whether a token was found.
+ (BOOL)isServeAnnouncementLine:(NSString *)line;

/// Rewrites any `token=` value in `line` to `<redacted>`, leaving the rest of
/// the line readable. Idempotent. Returns the line unchanged when it carries
/// nothing sensitive, which is the common case.
+ (NSString *)redactingTokenInLine:(NSString *)line;

/// Builds the authenticated entry URL for `baseURL`: the origin with the
/// launch token attached under `token`.
///
/// Returns nil when there is no token, because handing the caller a bare URL
/// is how the web view ends up loading a 401 body while every health check
/// reports green -- the exact failure this file exists to prevent. Callers
/// that genuinely want the origin (to decide "is this URL ours?") should use
/// -[DSHHarness baseURL] instead.
+ (nullable NSURL *)authenticatedEntryURLWithBaseURL:(NSURL *)baseURL token:(nullable NSString *)token;

/// Whether two URLs address the same authority (scheme, host, port). The auth
/// cookie is authority-bound, so this is the test for "is the cookie I may
/// still hold even applicable? A dsh restart on the same port keeps the cookie
/// valid; a port change does not.
+ (BOOL)url:(nullable NSURL *)a sharesAuthorityWith:(nullable NSURL *)b;

/// Whether two token strings are the same credential. Constant-time-ish
/// comparison that tolerates either side being nil, so a caller can use it to
/// decide "the process restarted" without a nil check of its own.
+ (BOOL)token:(nullable NSString *)a isEqualToToken:(nullable NSString *)b;

@end

NS_ASSUME_NONNULL_END
