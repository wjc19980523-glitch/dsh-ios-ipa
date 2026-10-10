//
//  DSHHarnessAuthenticationTests.m
//  DSHTests
//
//  Regression tests for the dsh 0.2.x launch-token handshake.
//
//  Context: dsh 0.2.x refuses to serve its web UI to anyone who has not fetched
//  the URL it prints on boot, which carries a per-process `?token=`. Every
//  other request — including HEAD — is answered 401. Nothing on the iOS side
//  knew about that, so:
//
//    * DSHHarness.baseURL was the bare origin, DSHReadinessProbe called a 401
//      "answered", and the boot was declared successful the moment the server
//      started refusing. The web view then loaded the 401 body and sat on it,
//      with a green status dot;
//    * the token was printed by the server into the guest log, which the app
//      mirrors into its ring buffer, its on-disk launch logs and the
//      diagnostics report the user can share;
//    * nothing ever re-authenticated, because nothing had authenticated.
//
//  Split by failure mode, as with the other harness suites: capture, the
//  handshake URL, the classification of a refusal, re-authentication after a
//  restart, and the token never reaching durable storage.
//

#import <XCTest/XCTest.h>
#import "DSHHarness.h"
#import "DSHHarnessAuth.h"
#import "DSHLogBuffer.h"
#import "DSHReadinessProbe.h"
#import "DSHTestHTTPServer.h"

#pragma mark - Fake launcher

/// A launcher that can emit server output. Real guests are asynchronous, but a
/// test needs to drive a token announcement at a chosen moment: the whole point
/// of the handshake is *when* the token arrives relative to the readiness wait.
@interface DSHScriptedGuestLauncher : NSObject <DSHGuestProcessLauncher>
@property (nonatomic) int nextPid;
@property (nonatomic, copy, nullable) void (^lineHandler)(NSString *line, BOOL isStdErr);
@property (nonatomic, copy, nullable) void (^exitHandler)(int);
@property (nonatomic, copy, nullable) void (^onLaunch)(NSDictionary *environment);
@end

@implementation DSHScriptedGuestLauncher

- (instancetype)init {
    if (self = [super init]) {
        _nextPid = 400;
    }
    return self;
}

- (int)launchExecutable:(NSString *)executable
              arguments:(NSArray<NSString *> *)arguments
            environment:(NSDictionary<NSString *, NSString *> *)environment
                   line:(void (^)(NSString *, BOOL))line
                   exit:(void (^)(int))exit {
    self.lineHandler = line;
    self.exitHandler = exit;
    if (self.onLaunch)
        self.onLaunch(environment);
    return self.nextPid++;
}

- (BOOL)killProcess:(int)pid signal:(int)signal {
    return YES;
}

/// Emits a line with no newline, exactly as the executor delivers them.
- (void)emit:(NSString *)line {
    if (self.lineHandler)
        self.lineHandler(line, NO);
}

@end

#pragma mark - Tests

@interface DSHHarnessAuthenticationTests : XCTestCase
@end

@implementation DSHHarnessAuthenticationTests

#pragma mark - Capturing the token

/// The exact shape dsh 0.2.x prints. A terminal colour reset, a trailing period
/// or quotes are all real possibilities, which is why the token's own alphabet
/// bounds the match rather than end-of-line.
- (void)testTokenIsCapturedFromTheRealAnnouncementLine {
    NSUInteger generation = DSHHarness.shared.authenticationGeneration;
    [DSHHarness.shared ingestServerLineForTesting:
        @"dsh web: http://127.0.0.1:3181/?token=YuwxTPdJwdXRh7ZNdh18oT1tMy-JiTpFWjgNntE65X4"];
    XCTAssertEqualObjects(DSHHarness.shared.launchToken,
                          @"YuwxTPdJwdXRh7ZNdh18oT1tMy-JiTpFWjgNntE65X4",
                          @"the 43-character token must be taken verbatim");
    XCTAssertGreaterThan(DSHHarness.shared.authenticationGeneration, generation,
                         @"capturing a token is an authentication event");
}

/// Trailing junk after the URL must not become part of the credential. The
/// prefix here is a terminal colour reset (ESC followed by "[32m"), which is
/// why the token's own alphabet bounds the match rather than end-of-line.
- (void)testTokenCaptureStopsAtTheTokenAlphabet {
    NSString *esc = @"\x1b";
    NSString *line = [NSString stringWithFormat:@"%@32mdsh web: http://127.0.0.1:3181/?token=abc-DEF_123%@0m done.",
                      esc, esc];
    [DSHHarness.shared ingestServerLineForTesting:line];
    XCTAssertEqualObjects(DSHHarness.shared.launchToken, @"abc-DEF_123",
                          @"a colour reset or trailing prose must not join the token");
}

/// The redaction is the security property this whole file leans on: the
/// announcement line is stored in the ring buffer, appended to the on-disk
/// launch log and included in a report the user can paste into an issue.
- (void)testAnnouncementLineIsRedactedBeforeStorage {
    NSString *raw = @"dsh web: http://127.0.0.1:3181/?token=YuwxTPdJwdXRh7ZNdh18oT1tMy-JiTpFWjgNntE65X4";
    NSString *redacted = [DSHHarnessAuth redactingTokenInLine:raw];
    XCTAssertFalse([redacted containsString:@"YuwxTPdJwdXRh7ZNdh18oT1tMy"],
                   @"the credential must not survive redaction: %@", redacted);
    XCTAssertTrue([redacted containsString:@"127.0.0.1:3181"],
                  @"the port stays readable; it is what makes the log useful");
}

/// Redaction is idempotent, so a line that has already been through it can pass
/// through again (the log buffer redacts unconditionally) without damage.
- (void)testRedactionIsIdempotent {
    NSString *once = [DSHHarnessAuth redactingTokenInLine:
        @"dsh web: http://127.0.0.1:3181/?token=abcdef123456"];
    NSString *twice = [DSHHarnessAuth redactingTokenInLine:once];
    XCTAssertEqualObjects(once, twice);
}

/// A line with nothing sensitive must come back untouched — the redactor runs
/// on every line the guest prints.
- (void)testUnrelatedLinesAreUnchanged {
    NSString *line = @"dsh web: server listening, no token in this one";
    XCTAssertEqualObjects([DSHHarnessAuth redactingTokenInLine:line], line);
    XCTAssertNil([DSHHarnessAuth tokenFromServeLogLine:@"dsh: booting plugins"]);
}

/// The log buffer is the last line of defence: even if a token reaches it by a
/// path that forgot to redact, it must not be persisted.
- (void)testLogBufferRedactsLaunchTokens {
    DSHLogBuffer *log = [[DSHLogBuffer alloc] initWithCapacity:8];
    [log append:@"dsh web: http://127.0.0.1:3181/?token=YuwxTPdJwdXRh7ZNdh18oT1tMy-JiTpFWjgNntE65X4"];
    NSString *tail = [log tail:8];
    XCTAssertFalse([tail containsString:@"YuwxTPdJwdXRh7ZNdh18oT1tMy"],
                   @"a launch token must never be retained, got: %@", tail);
    XCTAssertTrue([tail containsString:@"<redacted>"], @"and the redaction is visible, got: %@", tail);
}

#pragma mark - The entry URL

/// The URL the web view loads must carry the token: the server answers 401 to
/// everything else, so a bare origin is a page that cannot load.
- (void)testEntryURLAttachesTheToken {
    NSURL *base = [NSURL URLWithString:@"http://127.0.0.1:3181/"];
    NSURL *entry = [DSHHarnessAuth authenticatedEntryURLWithBaseURL:base token:@"abc123"];
    XCTAssertEqualObjects(entry.absoluteString, @"http://127.0.0.1:3181/?token=abc123");
}

/// A restart with no new token yet must not produce an entry URL. Returning the
/// bare origin here is what made the app load a 401 body.
- (void)testEntryURLIsNilWithoutAToken {
    NSURL *base = [NSURL URLWithString:@"http://127.0.0.1:3181/"];
    XCTAssertNil([DSHHarnessAuth authenticatedEntryURLWithBaseURL:base token:nil]);
    XCTAssertNil([DSHHarnessAuth authenticatedEntryURLWithBaseURL:base token:@""]);
}

/// A stale token from a previous incarnation must be replaced, not appended: a
/// duplicate `token` parameter is a request the server refuses.
- (void)testEntryURLReplacesAnOldToken {
    NSURL *base = [NSURL URLWithString:@"http://127.0.0.1:3181/?token=old"];
    NSURL *entry = [DSHHarnessAuth authenticatedEntryURLWithBaseURL:base token:@"new"];
    XCTAssertEqualObjects(entry.absoluteString, @"http://127.0.0.1:3181/?token=new");
}

/// The cookie is authority-bound, so "same authority" is the test for whether a
/// held cookie still applies. A restarted harness on the same port keeps it.
- (void)testAuthorityComparisonIgnoresTheQueryAndTheToken {
    NSURL *bare = [NSURL URLWithString:@"http://127.0.0.1:3181/"];
    NSURL *entry = [NSURL URLWithString:@"http://127.0.0.1:3181/?token=whatever"];
    NSURL *otherPort = [NSURL URLWithString:@"http://127.0.0.1:3182/?token=whatever"];
    XCTAssertTrue([DSHHarnessAuth url:entry sharesAuthorityWith:bare]);
    XCTAssertTrue([DSHHarnessAuth url:bare sharesAuthorityWith:entry]);
    XCTAssertFalse([DSHHarnessAuth url:entry sharesAuthorityWith:otherPort],
                   @"a different port is a different authority and a different cookie");
    XCTAssertFalse([DSHHarnessAuth url:bare sharesAuthorityWith:nil]);
}

#pragma mark - 401 is not "ready"

/// The core misclassification. Before this change a 401 counted as
/// DSHProbeOutcomeAnswered, so the boot was declared healthy the instant the
/// server started refusing to serve anything.
- (void)testProbeDoesNotCallUnauthorizedReady {
    DSHTestHTTPServer *server = [[DSHTestHTTPServer alloc] initWithPort:0];
    XCTAssertNotNil(server);
    server.statusCode = 401;
    XCTestExpectation *done = [self expectationWithDescription:@"probe"];
    [DSHReadinessProbe checkURL:server.baseURL timeout:5 completion:^(DSHProbeResult *result) {
        XCTAssertEqual(result.outcome, DSHProbeOutcomeUnauthorized);
        XCTAssertEqual(result.statusCode, 401, @"the status is preserved for the log");
        XCTAssertFalse(result.alive, @"a 401 is not a served page");
        XCTAssertTrue(result.requiresAuthentication, @"the caller must be told to authenticate");
        XCTAssertFalse(result.indicatesDeadServer,
                       @"the listener is up; restarting it would throw away a healthy guest");
        XCTAssertTrue([result.summary containsString:@"authentication"],
                      @"the log should say why, got: %@", result.summary);
        [done fulfill];
    }];
    [self waitForExpectations:@[done] timeout:15];
    [server stop];
}

/// 404 must stay "alive": this check answers "is something listening", and
/// widening the 401 rule must not turn every client error into a failure.
- (void)testClientErrorOtherThanUnauthorizedIsStillAlive {
    DSHTestHTTPServer *server = [[DSHTestHTTPServer alloc] initWithPort:0];
    XCTAssertNotNil(server);
    server.statusCode = 404;
    XCTestExpectation *done = [self expectationWithDescription:@"probe"];
    [DSHReadinessProbe checkURL:server.baseURL timeout:5 completion:^(DSHProbeResult *result) {
        XCTAssertEqual(result.outcome, DSHProbeOutcomeAnswered);
        XCTAssertTrue(result.alive);
        XCTAssertFalse(result.requiresAuthentication);
        [done fulfill];
    }];
    [self waitForExpectations:@[done] timeout:15];
    [server stop];
}

/// A 303 is what the token exchange itself returns, so it must count as served.
- (void)testRedirectCountsAsServed {
    DSHTestHTTPServer *server = [[DSHTestHTTPServer alloc] initWithPort:0];
    XCTAssertNotNil(server);
    server.statusCode = 303;
    XCTestExpectation *done = [self expectationWithDescription:@"probe"];
    [DSHReadinessProbe checkURL:server.baseURL timeout:5 completion:^(DSHProbeResult *result) {
        XCTAssertTrue(result.alive, @"the handshake redirect is a served page");
        XCTAssertEqual(result.statusCode, 303);
        [done fulfill];
    }];
    [self waitForExpectations:@[done] timeout:15];
    [server stop];
}

/// 5xx is still conclusive, and still not an authentication problem.
- (void)testServerErrorStaysConclusive {
    DSHTestHTTPServer *server = [[DSHTestHTTPServer alloc] initWithPort:0];
    XCTAssertNotNil(server);
    server.statusCode = 503;
    XCTestExpectation *done = [self expectationWithDescription:@"probe"];
    [DSHReadinessProbe checkURL:server.baseURL timeout:5 completion:^(DSHProbeResult *result) {
        XCTAssertEqual(result.outcome, DSHProbeOutcomeBadStatus);
        XCTAssertTrue(result.indicatesDeadServer);
        XCTAssertFalse(result.requiresAuthentication);
        [done fulfill];
    }];
    [self waitForExpectations:@[done] timeout:15];
    [server stop];
}

#pragma mark - The boot waits for the handshake

/// The regression at the heart of the boot. A server that binds its port but
/// never announces a token is not ready, and must not be reported ready just
/// because the port accepts connections: under dsh 0.2.x that state is
/// indistinguishable from a server that will refuse every request.
- (void)testBootIsNotReadyBeforeTheTokenArrives {
    DSHScriptedGuestLauncher *launcher = [DSHScriptedGuestLauncher new];
    DSHHarness *h = [[DSHHarness alloc] initWithLauncher:launcher];
    h.preferredPort = 39400;
    h.startupTimeout = 5;

    __block DSHTestHTTPServer *server = nil;
    launcher.onLaunch = ^(NSDictionary *env) {
        server = [[DSHTestHTTPServer alloc] initWithPort:(uint16_t) [env[@"DSH_PORT"] intValue]];
        // Bind a listener that refuses everything, like a pre-handshake dsh.
        server.statusCode = 401;
    };

    [h start];
    XCTAssertEqual(h.state, DSHHarnessStateStarting);
    XCTAssertNil(h.authenticatedEntryURL, @"no token, no entry URL");
    XCTAssertFalse(h.authenticationReady);

    // Let a few poll intervals elapse. The bare origin is answering 401 the
    // whole time; a 401 must never be mistaken for a healthy boot.
    XCTestExpectation *waited = [self expectationWithDescription:@"a moment of refusal"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t) (1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [waited fulfill];
    });
    [self waitForExpectations:@[waited] timeout:5];
    XCTAssertEqual(h.state, DSHHarnessStateStarting,
                   @"a refusing server is not a ready server");

    // Now the announcement arrives, and the boot completes through the
    // authenticated URL.
    XCTestExpectation *ready = [self expectationForNotification:DSHHarnessStateDidChangeNotification
                                                         object:h
                                                        handler:^BOOL(NSNotification *n) {
        return h.state == DSHHarnessStateReady;
    }];
    server.statusCode = 200;   // the authenticated entry URL is served
    [launcher emit:@"dsh web: http://127.0.0.1:39400/?token=boot-token-0001"];
    [self waitForExpectations:@[ready] timeout:20];

    XCTAssertEqualObjects(h.launchToken, @"boot-token-0001");
    XCTAssertNotNil(h.authenticatedEntryURL);
    // Parenthesise the nested message send, the way DSHCoreTests.m already
    // does for the same shape. XCTAssertEqualObjects is a variadic macro that
    // stringifies its arguments and appends __VA_ARGS__; a bare
    // `[NSString stringWithFormat:..., h.port]` as the second argument makes
    // clang report "expected identifier or '('" at the inner call's closing
    // paren, followed by a cascade of bogus brace errors.
    XCTAssertEqualObjects(h.authenticatedEntryURL.absoluteString,
                          ([NSString stringWithFormat:@"http://127.0.0.1:%u/?token=boot-token-0001",
                                                      h.port]));
    [server stop];
}

/// If the token never comes, the launch must still fail on schedule rather than
/// waiting out the whole budget in silence — and the error must name what
/// actually went wrong.
- (void)testBootFailsWhenNoTokenIsEverAnnounced {
    DSHScriptedGuestLauncher *launcher = [DSHScriptedGuestLauncher new];
    DSHHarness *h = [[DSHHarness alloc] initWithLauncher:launcher];
    h.preferredPort = 39410;
    h.startupTimeout = 2;
    h.maxConsecutiveCrashes = 1;
    launcher.onLaunch = ^(NSDictionary *env) { /* binds nothing, prints nothing */ };

    XCTestExpectation *failed = [self expectationForNotification:DSHHarnessStateDidChangeNotification
                                                          object:h
                                                         handler:^BOOL(NSNotification *n) {
        return h.state == DSHHarnessStateRestarting || h.state == DSHHarnessStateFailed;
    }];
    failed.assertForOverFulfill = NO;
    [h start];
    [self waitForExpectations:@[failed] timeout:20];

    XCTAssertTrue([[h.log tail:120] containsString:@"did not announce its web URL"],
                  @"the failure must name the missing handshake, got:\n%@", [h.log tail:120]);
}

#pragma mark - Re-authentication

/// A restart mints a new token, so the old one is dead the moment the old
/// process goes away. The harness must drop it, and the UI must be able to tell
/// that the credential it authenticated with is no longer current.
- (void)testRestartInvalidatesTheTokenAndBumpsTheGeneration {
    DSHScriptedGuestLauncher *launcher = [DSHScriptedGuestLauncher new];
    DSHHarness *h = [[DSHHarness alloc] initWithLauncher:launcher];
    h.preferredPort = 39420;
    h.startupTimeout = 60;
    __block DSHTestHTTPServer *server = nil;
    launcher.onLaunch = ^(NSDictionary *env) {
        server = [[DSHTestHTTPServer alloc] initWithPort:(uint16_t) [env[@"DSH_PORT"] intValue]];
    };

    [h start];
    [launcher emit:@"dsh web: http://127.0.0.1:39420/?token=first-token"];
    XCTAssertEqualObjects(h.launchToken, @"first-token");
    NSUInteger generationAfterFirst = h.authenticationGeneration;

    [h restart];
    XCTAssertNil(h.launchToken, @"a stopped server has no valid token");
    XCTAssertNil(h.authenticatedEntryURL, @"and therefore no entry URL");
    XCTAssertFalse(h.authenticationReady);

    // The replacement process announces its own token.
    XCTestExpectation *again = [self expectationWithDescription:@"relaunched"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t) (1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [launcher emit:@"dsh web: http://127.0.0.1:39420/?token=second-token"];
        [again fulfill];
    });
    [self waitForExpectations:@[again] timeout:10];

    XCTAssertEqualObjects(h.launchToken, @"second-token", @"the new process's token replaces the old");
    XCTAssertGreaterThan(h.authenticationGeneration, generationAfterFirst,
                         @"the generation moves so a web view can notice it must redo the handshake");
    if (server) [server stop];
}

/// The web view asks the harness to record a refusal, which is how it signals
/// "the credential I have is not current" without reloading on its own.
- (void)testAuthenticationFailureIsRecordedWithTheTokenRedacted {
    DSHScriptedGuestLauncher *launcher = [DSHScriptedGuestLauncher new];
    DSHHarness *h = [[DSHHarness alloc] initWithLauncher:launcher];
    h.preferredPort = 39430;
    h.startupTimeout = 60;
    [h start];
    [launcher emit:@"dsh web: http://127.0.0.1:39430/?token=re-auth-token"];

    NSUInteger before = h.authenticationGeneration;
    XCTAssertTrue([h noteAuthenticationFailureForURL:h.baseURL],
                  @"a token is available, so a retry is possible");
    XCTAssertGreaterThan(h.authenticationGeneration, before);

    NSString *tail = [h.log tail:60];
    XCTAssertFalse([tail containsString:@"re-auth-token"], @"the credential is never logged:\n%@", tail);
    XCTAssertTrue([tail containsString:@"re-authenticating"], @"but the event is:\n%@", tail);
}

/// With no token there is nothing to retry with, and the harness must say so
/// instead of pretending a reload would help.
- (void)testAuthenticationFailureWithoutATokenReportsItCannotRetry {
    DSHScriptedGuestLauncher *launcher = [DSHScriptedGuestLauncher new];
    DSHHarness *h = [[DSHHarness alloc] initWithLauncher:launcher];
    h.preferredPort = 39440;
    h.startupTimeout = 60;
    [h start];

    XCTAssertFalse([h noteAuthenticationFailureForURL:h.baseURL]);
    XCTAssertTrue([[h.log tail:40] containsString:@"has not announced a token yet"],
                  @"the reason must be in the log, got:\n%@", [h.log tail:40]);
}

#pragma mark - The whole handshake, against a server that behaves like dsh

/// End to end through a server that actually implements dsh 0.2.x's contract:
/// refuse everything with 401 until the token URL is fetched, then answer 303
/// with the cookie and serve normally after that.
///
/// This is the test that would have caught the original defect, because the
/// original defect was precisely "the app never fetched the token URL".
- (void)testFullHandshakeAgainstADshLikeServer {
    DSHScriptedGuestLauncher *launcher = [DSHScriptedGuestLauncher new];
    __block DSHTestHTTPServer *server = nil;
    DSHHarness *h = [[DSHHarness alloc] initWithLauncher:launcher];
    h.preferredPort = 39460;
    h.startupTimeout = 20;

    launcher.onLaunch = ^(NSDictionary *env) {
        server = [[DSHTestHTTPServer alloc] initWithPort:(uint16_t) [env[@"DSH_PORT"] intValue]];
        server.requiresLaunchToken = YES;
        server.launchToken = @"handshake-token-1";
    };
    [h start];
    [launcher emit:@"dsh web: http://127.0.0.1:39460/?token=handshake-token-1"];

    XCTAssertNotNil(server);
    XCTAssertNotNil(h.authenticatedEntryURL, @"the announcement produces an entry URL");

    // 1. The bare origin is refused, exactly as dsh refuses it. This is what
    //    the health check must not call "ready".
    XCTestExpectation *refused = [self expectationWithDescription:@"bare origin refused"];
    [[NSURLSession.sharedSession dataTaskWithURL:h.baseURL completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        XCTAssertEqual(((NSHTTPURLResponse *) response).statusCode, 401);
        XCTAssertGreaterThan(server.unauthorizedCount, 0u);
        [refused fulfill];
    }] resume];
    [self waitForExpectations:@[refused] timeout:10];

    // 2. The entry URL completes the exchange and is served.
    XCTestExpectation *served = [self expectationWithDescription:@"entry URL served"];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.defaultSessionConfiguration];
    [[session dataTaskWithURL:h.authenticatedEntryURL completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        XCTAssertNil(error);
        XCTAssertEqual(((NSHTTPURLResponse *) response).statusCode, 200,
                       @"after the exchange the server serves the UI");
        [served fulfill];
    }] resume];
    [self waitForExpectations:@[served] timeout:10];
    XCTAssertEqual(server.tokenExchangeCount, 1u, @"the token URL is what mints the cookie");
    XCTAssertNotNil(server.issuedCookieValue, @"and a cookie came back");

    // 3. The cookie is reused: a second load of the origin now works, which is
    //    what lets the web view survive a page reload without re-doing this.
    XCTestExpectation *withCookie = [self expectationWithDescription:@"origin with cookie"];
    [[session dataTaskWithURL:h.baseURL completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        XCTAssertEqual(((NSHTTPURLResponse *) response).statusCode, 200);
        [withCookie fulfill];
    }] resume];
    [self waitForExpectations:@[withCookie] timeout:10];
    XCTAssertEqual(server.tokenExchangeCount, 1u, @"no second exchange was needed");
    [session invalidateAndCancel];
    [server stop];
}

/// A restart regenerates the token. The entry URL must follow it, and the old
/// URL — which is now just a wrong credential — must not be reused.
- (void)testHandshakeRedoesAfterARestartWithANewToken {
    DSHScriptedGuestLauncher *launcher = [DSHScriptedGuestLauncher new];
    __block DSHTestHTTPServer *server = nil;
    DSHHarness *h = [[DSHHarness alloc] initWithLauncher:launcher];
    h.preferredPort = 39470;
    h.startupTimeout = 60;

    launcher.onLaunch = ^(NSDictionary *env) {
        server = [[DSHTestHTTPServer alloc] initWithPort:(uint16_t) [env[@"DSH_PORT"] intValue]];
        server.requiresLaunchToken = YES;
        // Each "process" accepts only its own token.
        server.launchToken = @"token-generation-1";
    };
    [h start];
    [launcher emit:@"dsh web: http://127.0.0.1:39470/?token=token-generation-1"];
    NSURL *firstEntry = h.authenticatedEntryURL;
    XCTAssertEqualObjects(firstEntry.absoluteString, @"http://127.0.0.1:39470/?token=token-generation-1");

    [h restart];
    // The replacement process mints a different token, and the server follows:
    // the old token is no longer accepted.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t) (0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        server.launchToken = @"token-generation-2";
        [launcher emit:@"dsh web: http://127.0.0.1:39470/?token=token-generation-2"];
    });

    XCTestExpectation *updated = [self expectationWithDescription:@"new entry URL"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t) (1.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        XCTAssertEqualObjects(h.authenticatedEntryURL.absoluteString,
                              @"http://127.0.0.1:39470/?token=token-generation-2",
                              @"the web view must be handed the current token, not the dead one");
        [updated fulfill];
    });
    [self waitForExpectations:@[updated] timeout:10];

    if (server) [server stop];
}

/// An exchange with the wrong token must not authenticate anything. Without
/// this, "it got past 401" could be explained by the server being lax rather
/// than by the client doing the right thing.
- (void)testWrongTokenIsRefused {
    DSHTestHTTPServer *server = [[DSHTestHTTPServer alloc] initWithPort:0];
    XCTAssertNotNil(server);
    server.requiresLaunchToken = YES;
    server.launchToken = @"the-right-one";

    NSURL *wrong = [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%u/?token=the-wrong-one", server.port]];
    XCTestExpectation *done = [self expectationWithDescription:@"refused"];
    [[NSURLSession.sharedSession dataTaskWithURL:wrong completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        XCTAssertEqual(((NSHTTPURLResponse *) response).statusCode, 401);
        XCTAssertEqual(server.tokenExchangeCount, 0u);
        XCTAssertNil(server.issuedCookieValue);
        [done fulfill];
    }] resume];
    [self waitForExpectations:@[done] timeout:10];
    [server stop];
}

/// HEAD is refused too. The readiness poll uses HEAD, so a server that only
/// protected GET would look healthy to the poll while refusing the page — the
/// exact shape of the original misdiagnosis.
- (void)testHeadIsAlsoRefusedWithoutTheToken {
    DSHTestHTTPServer *server = [[DSHTestHTTPServer alloc] initWithPort:0];
    XCTAssertNotNil(server);
    server.requiresLaunchToken = YES;
    server.launchToken = @"some-token";

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:server.baseURL];
    req.HTTPMethod = @"HEAD";
    XCTestExpectation *done = [self expectationWithDescription:@"head refused"];
    [[NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        XCTAssertEqual(((NSHTTPURLResponse *) response).statusCode, 401);
        [done fulfill];
    }] resume];
    [self waitForExpectations:@[done] timeout:10];
    [server stop];
}

/// Open in Safari hands the entry URL to another app, so the URL it builds must
/// be the authenticated one — a bare origin there is the same 401 page.
- (void)testSafariHandoffUsesTheAuthenticatedURL {
    DSHScriptedGuestLauncher *launcher = [DSHScriptedGuestLauncher new];
    DSHHarness *h = [[DSHHarness alloc] initWithLauncher:launcher];
    h.preferredPort = 39450;
    h.startupTimeout = 60;
    [h start];
    [launcher emit:@"dsh web: http://127.0.0.1:39450/?token=safari-token"];

    NSURL *handoff = h.authenticatedEntryURL;
    XCTAssertNotNil(handoff, @"Safari needs a URL it can actually open");
    XCTAssertEqualObjects([NSURLComponents componentsWithURL:handoff resolvingAgainstBaseURL:NO]
                              .queryItems.firstObject.value,
                          @"safari-token");
}

@end
