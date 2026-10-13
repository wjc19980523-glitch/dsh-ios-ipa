//
//  DSHGuestIntegrationTests.m
//  DSHTests
//
//  Runs inside the DSH host app (device or simulator) and talks to the real
//  Linux guest: waits for the supervised dsh-serve to answer, fetches the web
//  UI, and executes the guest-side self test through ISHShellExecutor.
//

#import <XCTest/XCTest.h>
#import <UIKit/UIKit.h>
#import <TargetConditionals.h>
#include <signal.h>
#import "DSHHarness.h"
#import "DSHBootCoordinator.h"
#import "ISHShellExecutor.h"
#import "DSHRootUpgrader.h"
#import "DSHHostBridge.h"
#import "DSHCapability.h"
#import <HealthKit/HealthKit.h>
#import "DSHMockLLMServer.h"
#import "DSHAppLifecycle.h"
#import "DSHLifecycleCoordinator.h"
#import "DSHLifecycleDiagnostics.h"
#include "../../ish-arm64/fs/dsh-lifecycle.h"

@interface DSHGuestIntegrationTests : XCTestCase
@end

@implementation DSHGuestIntegrationTests

- (BOOL)waitForReady {
    DSHHarness *h = DSHHarness.shared;
    if (h.state == DSHHarnessStateReady)
        return YES;
    // App launch is isolated under XCTest. Only the separately selected guest
    // batch may import its fresh simulator root and start the real emulator.
    XCTAssertEqualObjects(NSProcessInfo.processInfo.environment[@"DSH_GUEST_INTEGRATION"], @"1",
                          @"run scripts/run-xctests.sh; guest tests require the explicit integration batch");
    if (![NSProcessInfo.processInfo.environment[@"DSH_GUEST_INTEGRATION"] isEqualToString:@"1"])
        return NO;
    XCTestExpectation *ready = [self expectationForPredicate:
        [NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary *bindings) {
            return h.state == DSHHarnessStateReady || h.state == DSHHarnessStateFailed ||
                   DSHBootCoordinator.shared.phase == DSHBootPhaseFailed;
        }] evaluatedWithObject:h handler:nil];
    [DSHBootCoordinator.shared start];
    [self waitForExpectations:@[ready] timeout:900];
    XCTAssertEqual(h.state, DSHHarnessStateReady, @"guest startup failed: %@", h.lastError);
    return h.state == DSHHarnessStateReady;
}

- (void)testHarnessServesWebUI {
    if (![self waitForReady]) return;
    DSHHarness *h = DSHHarness.shared;
    XCTAssertEqual(h.state, DSHHarnessStateReady);
    XCTAssertNotNil(h.baseURL);
    XCTAssertGreaterThan(h.guestPid, 0);

    XCTestExpectation *fetched = [self expectationWithDescription:@"index"];
    [[NSURLSession.sharedSession dataTaskWithURL:h.authenticatedEntryURL completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        XCTAssertNil(error);
        XCTAssertEqual(((NSHTTPURLResponse *) response).statusCode, 200);
        NSString *html = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        XCTAssertTrue([html containsString:@"__DSH_BOOT__"], @"index should carry the DSH boot manifest");
        [fetched fulfill];
    }] resume];
    [self waitForExpectations:@[fetched] timeout:30];
}

/// Exercise the actual guest exit callback and automatic supervisor relaunch.
- (void)testRealGuestExitRecoversAutomatically {
    if (![self waitForReady]) return;
    DSHHarness *h = DSHHarness.shared;
    int originalPid = h.guestPid;
    NSUInteger originalRestarts = h.restartCount;
    NSUInteger originalAuthentication = h.authenticationGeneration;
    NSString *hostLaunchID = DSHLogBuffer.hostLaunchID;
    XCTAssertGreaterThan(originalPid, 0);

    // Create before SIGKILL so even a fast exit/relaunch cannot be missed.
    // Keep it standalone: a failed injection must not leave a test-case
    // expectation registered for a recovery that cannot occur.
    XCTestExpectation *recovered = [[XCTNSPredicateExpectation alloc] initWithPredicate:
        [NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary *bindings) {
            (void)object; (void)bindings;
            return (h.state == DSHHarnessStateReady && h.guestPid > 0 &&
                    h.guestPid != originalPid && h.authenticationReady) ||
                   h.state == DSHHarnessStateFailed;
        }] object:h];
    BOOL injected = [ISHShellExecutor killProcess:originalPid withSignal:SIGKILL];
    XCTAssertTrue(injected,
                  @"the isolated Harness guest must exist before injecting its exit");
    if (!injected) return;
    // No start/restart/foreground call: the production exit supervisor owns recovery.
    [self waitForExpectations:@[recovered] timeout:300];
    XCTAssertEqual(h.state, DSHHarnessStateReady, @"automatic recovery failed: %@", h.lastError);
    XCTAssertGreaterThan(h.guestPid, 0);
    XCTAssertNotEqual(h.guestPid, originalPid);
    XCTAssertEqual(h.restartCount, originalRestarts + 1);
    XCTAssertGreaterThan(h.authenticationGeneration, originalAuthentication);
    XCTAssertEqualObjects(DSHLogBuffer.hostLaunchID, hostLaunchID, @"guest recovery must keep the host app alive");
    XCTAssertNotNil(h.authenticatedEntryURL);
    if (h.state != DSHHarnessStateReady || h.authenticatedEntryURL == nil) return;

    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    configuration.URLCache = nil;
    configuration.timeoutIntervalForRequest = 20;
    configuration.timeoutIntervalForResource = 25;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];
    XCTestExpectation *fetched = [self expectationWithDescription:@"recovered guest serves authenticated index"];
    [[session dataTaskWithURL:h.authenticatedEntryURL completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        XCTAssertNil(error);
        XCTAssertEqual(((NSHTTPURLResponse *)response).statusCode, 200);
        NSString *html = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        XCTAssertTrue([html containsString:@"__DSH_BOOT__"], @"the new guest must serve the real boot manifest");
        [fetched fulfill];
    }] resume];
    [self waitForExpectations:@[fetched] timeout:30];
    [session finishTasksAndInvalidate];
}

// Runs the production gate, coordinator, socket snapshot/restore and health
// probe against the real guest. UIKit itself remains foreground in Simulator;
// suspension by RunningBoard still requires the Build 25 iPad test matrix.
- (void)testRealGuestQuiescesAndResumesWithoutRelaunch {
    if (![self waitForReady]) return;
    DSHHarness *h = DSHHarness.shared;
    DSHLifecycleCoordinator *coordinator = DSHAppLifecycle.sharedCoordinator;
    NSDictionary *originalEnvironment = h.extraEnvironment;
    // A synthetic session belongs to the real supervised Node, not a separate
    // guest that could not receive its drain grant. This preload is test-only;
    // the production launcher never sets DSH_PROBE_LISTEN.
    NSString *probePath = [@"/tmp/dsh-session-probe-" stringByAppendingFormat:@"%@.mjs", NSUUID.UUID.UUIDString];
    NSString *probe = @"import {Context} from '/usr/local/lib/node_modules/@deepseek-ai/cordis/lib/index.js';\n"
        @"import Sessions from '/usr/local/lib/node_modules/@deepseek-ai/dsh-session/lib/index.js';\n"
        @"import Persistence from '/usr/local/lib/node_modules/@deepseek-ai/dsh-session-persistence-jsonl/lib/index.js';\n"
        @"import {mkdtemp} from 'node:fs/promises';\n"
        @"const root=await mkdtemp('/tmp/dsh-host-session-probe.');\n"
        @"const ctx=new Context(); const sessions=new Sessions(ctx);\n"
        @"const backend=new Persistence(ctx,{root:root+'/sessions',compression:'none'});\n"
        @"const session=sessions.prepare('host-lifecycle-probe',{meta:{cwd:root}});\n"
        @"const handle=await backend.create(session.header);\n"
        @"await handle.append([session.append('session/title',{title:'lifecycle test',messageSeqs:[],source:{kind:'user'}})]);\n"
        @"await handle.flush(); globalThis.dshLifecycleTestSession={ctx,backend,session,handle};\n";
    NSString *encoded = [[probe dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
    XCTestExpectation *installed = [self expectationWithDescription:@"session probe installed"];
    __block BOOL installationSucceeded = NO;
    [ISHShellExecutor executeCommand:[NSString stringWithFormat:@"printf '%%s' '%@' | base64 -d > '%@'", encoded, probePath]
        lineCallback:nil completion:^(ISHShellExecutionResult *result) {
            XCTAssertEqual(result.error, ISHShellExecutorErrorNone);
            XCTAssertEqual(result.exitCode, 0);
            installationSucceeded = result.error == ISHShellExecutorErrorNone && result.exitCode == 0;
            [installed fulfill];
        }];
    [self waitForExpectations:@[installed] timeout:30];
    if (!installationSucceeded) return;
    NSMutableDictionary *probeEnvironment = [originalEnvironment mutableCopy];
    probeEnvironment[@"DSH_PROBE_LISTEN"] = probePath;
    h.extraEnvironment = probeEnvironment;
    [h restart];
    if (![self waitForReady]) {
        h.extraEnvironment = originalEnvironment;
        [h restart];
        [self waitForReady];
        return;
    }
    int pid = h.guestPid;
    NSUInteger restarts = h.restartCount;
    NSUInteger authentication = h.authenticationGeneration;
    @try {
        struct dsh_lifecycle_snapshot before;
        dsh_lifecycle_get_snapshot(&before);
        BOOL heldSessionLease = NO;
        for (unsigned i = 0; i < before.native_flock_count; i++) {
            struct dsh_lifecycle_flock_snapshot lock = before.native_flocks[i];
            if (lock.guest_tgid == pid && lock.identity.file_kind == DSH_FLOCK_FILE_SESSION_LOCK)
                heldSessionLease = YES;
        }
        XCTAssertTrue(heldSessionLease, @"This test must begin with the real native session lease held");
        for (NSUInteger cycle = 0; cycle < 3; cycle++) {
            [coordinator handleAppBackground];
            [coordinator handleAppBackground];
            XCTestExpectation *drained = [self expectationForPredicate:
                [NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary *bindings) {
                    return coordinator.state == DSHLifecycleCoordinatorStateQuiesced;
                }] evaluatedWithObject:coordinator handler:nil];
            [self waitForExpectations:@[drained] timeout:20];
            struct dsh_lifecycle_snapshot snapshot;
            dsh_lifecycle_get_snapshot(&snapshot);
            XCTAssertEqual(snapshot.state, DSH_LIFECYCLE_QUIESCENT, @"Drain evidence: %@",
                           [DSHLifecycleDiagnostics snapshotForHarness:h event:@"integrationDrain"]);
            XCTAssertEqual(snapshot.active_operations, 0u);
            XCTAssertEqual(snapshot.active_read_transactions + snapshot.active_write_transactions +
                           snapshot.active_deferred_transactions, 0u);
            XCTAssertEqual(snapshot.active_native_flocks, 0u);
            XCTAssertFalse(snapshot.session_drain_active);
            XCTAssertEqual(snapshot.recovery_blocked_connections, 0u);

            [coordinator handleAppForeground];
            [coordinator handleAppForeground];
            XCTestExpectation *resumed = [self expectationForPredicate:
                [NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary *bindings) {
                    return coordinator.state == DSHLifecycleCoordinatorStateRunning;
                }] evaluatedWithObject:coordinator handler:nil];
            [self waitForExpectations:@[resumed] timeout:20];
            dsh_lifecycle_get_snapshot(&snapshot);
            BOOL reacquired = NO;
            for (unsigned i = 0; i < snapshot.native_flock_count; i++) {
                struct dsh_lifecycle_flock_snapshot lock = snapshot.native_flocks[i];
                if (lock.guest_tgid == pid && lock.identity.file_kind == DSH_FLOCK_FILE_SESSION_LOCK)
                    reacquired = YES;
            }
            XCTAssertTrue(reacquired, @"Same Node must reacquire its session lease before admission opens");
            XCTestExpectation *healthy = [self expectationWithDescription:@"same guest answers after restore"];
            [h verifyAliveWithCompletion:^(BOOL alive) {
                XCTAssertTrue(alive);
                [healthy fulfill];
            }];
            [self waitForExpectations:@[healthy] timeout:60];
            XCTAssertEqual(h.guestPid, pid);
            XCTAssertEqual(h.restartCount, restarts);
            XCTAssertEqual(h.authenticationGeneration, authentication);
        }
    } @finally {
        // A failed drain assertion must not leave later integration tests
        // parked behind a closed gate.
        [coordinator handleAppForeground];
        XCTestExpectation *running = [self expectationForPredicate:
            [NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary *bindings) {
                return coordinator.state == DSHLifecycleCoordinatorStateRunning;
            }] evaluatedWithObject:coordinator handler:nil];
        [self waitForExpectations:@[running] timeout:20];
        h.extraEnvironment = originalEnvironment;
        [h restart];
        [self waitForReady];
    }
}

- (void)testGuestSelfTestPasses {
    if (![self waitForReady]) return;
    XCTestExpectation *done = [self expectationWithDescription:@"selftest"];
    NSMutableString *out = [NSMutableString string];
    int pid = [ISHShellExecutor executeCommand:@"/usr/local/bin/dsh-selftest 2>&1"
                                  lineCallback:^(NSString *line, BOOL isStdErr) { [out appendFormat:@"%@\n", line]; }
                                    completion:^(ISHShellExecutionResult *result) {
        XCTAssertEqual(result.error, ISHShellExecutorErrorNone);
        XCTAssertEqual(result.exitCode, 0, @"dsh-selftest failed:\n%@\nstdout:%@\nstderr:%@", out, result.output, result.errorOutput);
        XCTAssertTrue([out containsString:@"SELFTEST OK"], @"output: %@", out);
        [done fulfill];
    }];
    XCTAssertGreaterThan(pid, 0);
    [self waitForExpectations:@[done] timeout:180];
}

- (void)testBundledRootImageIsTheInstalledOne {
    // After launch the imported root must match the image in the bundle and
    // no user-data migration may be left pending.
    // The import runs in the background now, so wait for the guest to be up
    // before asking which image is installed.
    if (![self waitForReady]) return;
    DSHRootUpgrader *u = DSHRootUpgrader.shared;
    XCTAssertNotNil(u.bundledRootHash, @"root.tar.gz.sha256 must be in the bundle");
    XCTAssertEqualObjects(u.installedRootHash, u.bundledRootHash);
    XCTAssertNil(u.pendingMigrationRoot);
    // The guest carries the marker the rootfs build wrote for the RootfsPatch overlay.
    XCTestExpectation *done = [self expectationWithDescription:@"overlay"];
    NSMutableString *out = [NSMutableString string];
    [ISHShellExecutor executeCommand:@"cat /ish/overlay-version" lineCallback:^(NSString *line, BOOL isStdErr) {
        [out appendString:line];
    } completion:^(ISHShellExecutionResult *result) {
        XCTAssertEqual(result.exitCode, 0);
        XCTAssertTrue(out.intValue >= 4, @"overlay version %@", out);
        [done fulfill];
    }];
    [self waitForExpectations:@[done] timeout:60];
}

/// The real end-to-end path: the guest reaches the app's bridge over loopback
/// and gets this device's facts back.
- (void)testGuestReachesTheHostBridge {
    if (![self waitForReady]) return;
    DSHHostBridge *bridge = DSHHostBridge.shared;
    XCTAssertTrue(bridge.running, @"the bridge should be listening once the harness started");
    XCTAssertNotNil(bridge.baseURLString);

    NSString *command = [NSString stringWithFormat:
        @"node -e \"fetch('%@/v1/device',{headers:{authorization:'Bearer %@'}})"
        @".then(r=>r.text()).then(t=>console.log('BRIDGE:'+t))"
        @".catch(e=>console.log('BRIDGE-ERR:'+e.message))\" 2>&1",
        bridge.baseURLString, bridge.token];
    XCTestExpectation *done = [self expectationWithDescription:@"bridge"];
    NSMutableString *out = [NSMutableString string];
    [ISHShellExecutor executeCommand:command lineCallback:^(NSString *line, BOOL isStdErr) {
        if (![line containsString:@"expose_wasm"]) [out appendFormat:@"%@\n", line];
    } completion:^(ISHShellExecutionResult *result) {
        XCTAssertEqual(result.exitCode, 0, @"guest fetch failed: %@", out);
        XCTAssertTrue([out containsString:@"BRIDGE:"], @"no bridge answer: %@", out);
        XCTAssertTrue([out containsString:@"systemVersion"], @"unexpected payload: %@", out);
        XCTAssertTrue([out containsString:UIDevice.currentDevice.systemVersion],
                      @"the guest should see this device's iOS version: %@", out);
        [done fulfill];
    }];
    [self waitForExpectations:@[done] timeout:180];
}

/// A guest process without the token must be refused, so the bridge is not an
/// open door for anything else running in the Linux image.
- (void)testGuestWithoutTokenIsRefusedByTheBridge {
    if (![self waitForReady]) return;
    DSHHostBridge *bridge = DSHHostBridge.shared;
    NSString *command = [NSString stringWithFormat:
        @"node -e \"fetch('%@/v1/device').then(r=>console.log('STATUS:'+r.status))"
        @".catch(e=>console.log('ERR:'+e.message))\" 2>&1", bridge.baseURLString];
    XCTestExpectation *done = [self expectationWithDescription:@"unauthorized"];
    NSMutableString *out = [NSMutableString string];
    [ISHShellExecutor executeCommand:command lineCallback:^(NSString *line, BOOL isStdErr) {
        if (![line containsString:@"expose_wasm"]) [out appendFormat:@"%@\n", line];
    } completion:^(ISHShellExecutionResult *result) {
        XCTAssertTrue([out containsString:@"STATUS:401"], @"expected 401, got: %@", out);
        [done fulfill];
    }];
    [self waitForExpectations:@[done] timeout:180];
}

/// dsh must have been handed the bridge coordinates, otherwise the plugin
/// registers no tools.
- (void)testHarnessEnvironmentCarriesBridgeCoordinates {
    if (![self waitForReady]) return;
    NSDictionary *env = DSHHarness.shared.extraEnvironment;
    XCTAssertEqualObjects(env[@"DSH_HOST_BRIDGE_URL"], DSHHostBridge.shared.baseURLString);
    XCTAssertEqualObjects(env[@"DSH_HOST_BRIDGE_TOKEN"], DSHHostBridge.shared.token);
}

/// The whole path, on this device, with no network: an in-app mock model asks
/// for `device_info`, the guest plugin calls the app's bridge, and this
/// device's real facts come back to the model.
- (void)testAgentCallsDeviceInfoThroughTheBridge {
    if (![self waitForReady]) return;
    DSHMockLLMServer *model = [DSHMockLLMServer new];
    XCTAssertNotNil(model, @"mock model server should bind a port");
    model.requestTool = @"device_info";

    DSHHostBridge *bridge = DSHHostBridge.shared;
    // A fresh guest process does not inherit dsh-serve's environment, so pass
    // the bridge coordinates (and the mock model) explicitly.
    NSString *command = [NSString stringWithFormat:
        @"cd /root/workspace && HOME=/root DEEPSEEK_API_KEY=test DEEPSEEK_BASE_URL=%@ "
        @"DSH_HOST_BRIDGE_URL=%@ DSH_HOST_BRIDGE_TOKEN=%@ "
        @"node --expose-internals /usr/local/lib/node_modules/@deepseek-ai/dsh/lib/bin.js "
        @"--profile headless 'What device is this?' 2>&1 | tail -20",
        model.baseURLString, bridge.baseURLString, bridge.token];

    XCTestExpectation *done = [self expectationWithDescription:@"agent"];
    NSMutableString *out = [NSMutableString string];
    [ISHShellExecutor executeCommand:command lineCallback:^(NSString *line, BOOL isStdErr) {
        if (![line containsString:@"expose_wasm"]) [out appendFormat:@"%@\n", line];
    } completion:^(ISHShellExecutionResult *result) {
        [done fulfill];
    }];
    [self waitForExpectations:@[done] timeout:300];
    [model stop];

    XCTAssertGreaterThanOrEqual(model.requestCount, 2u, @"the harness should have called the model at least twice");
    BOOL offered = NO;
    for (NSString *tools in model.offeredToolsPerRequest)
        offered = offered || [tools containsString:@"device_info"];
    XCTAssertTrue(offered, @"device_info was never offered to the model — the plugin did not register it. Output:\n%@", out);
    XCTAssertTrue([out containsString:@"TOOL-RESULT-BEGIN"], @"the tool result never reached the model:\n%@", out);
    XCTAssertTrue([out containsString:@"systemVersion"], @"no device facts in the answer:\n%@", out);
    XCTAssertTrue([out containsString:UIDevice.currentDevice.systemVersion],
                  @"the model should see this device's iOS version (%@):\n%@", UIDevice.currentDevice.systemVersion, out);
}

/// The same whole path for a capability that is off by default and needs iOS's
/// own permission. On a test device neither grant is guaranteed, so this asserts
/// what must hold either way: the tool is offered, the call completes, and the
/// model is told something actionable instead of the turn hanging on a dialog.
- (void)testAgentCallsHealthThroughTheBridge {
#if TARGET_OS_SIMULATOR
    XCTSkipIf([NSProcessInfo.processInfo.environment[@"DSH_GUEST_INTEGRATION"] isEqualToString:@"1"],
              @"HealthKit system authorization requires a manual device test; Health route/refusal unit tests run separately");
#endif
    if (![self waitForReady]) return;
    XCTSkipIf(!HKHealthStore.isHealthDataAvailable, @"HealthKit is unavailable on this destination");
    DSHMockLLMServer *model = [DSHMockLLMServer new];
    XCTAssertNotNil(model);
    model.requestTool = @"health_query";
    model.toolArguments = @"{\"metric\":\"activity\",\"days\":3}";
    [DSHCapabilityRegistry.shared setEnabled:YES forIdentifier:@"health.read"];

    DSHHostBridge *bridge = DSHHostBridge.shared;
    NSString *command = [NSString stringWithFormat:
        @"cd /root/workspace && HOME=/root DEEPSEEK_API_KEY=test DEEPSEEK_BASE_URL=%@ "
        @"DSH_HOST_BRIDGE_URL=%@ DSH_HOST_BRIDGE_TOKEN=%@ "
        @"node --expose-internals /usr/local/lib/node_modules/@deepseek-ai/dsh/lib/bin.js "
        @"--profile headless 'How active have I been?' 2>&1 | tail -25",
        model.baseURLString, bridge.baseURLString, bridge.token];

    XCTestExpectation *done = [self expectationWithDescription:@"health agent"];
    NSMutableString *out = [NSMutableString string];
    [ISHShellExecutor executeCommand:command lineCallback:^(NSString *line, BOOL isStdErr) {
        if (![line containsString:@"expose_wasm"]) [out appendFormat:@"%@\n", line];
    } completion:^(ISHShellExecutionResult *result) {
        [done fulfill];
    }];
    // Generous, but far below a hang: the point is that a missing permission
    // ends the turn quickly rather than blocking on a system dialog.
    [self waitForExpectations:@[done] timeout:300];
    [model stop];
    [DSHCapabilityRegistry.shared setEnabled:NO forIdentifier:@"health.read"];

    BOOL offered = NO;
    for (NSString *tools in model.offeredToolsPerRequest)
        offered = offered || [tools containsString:@"health_query"];
    XCTAssertTrue(offered, @"health_query was never offered to the model:\n%@", out);

    BOOL answered = [out containsString:@"Activity "] || [out containsString:@"steps"];
    BOOL refusedClearly = [out containsString:@"Health access"] || [out containsString:@"permission_denied"]
        || [out containsString:@"Settings"];
    XCTAssertTrue(answered || refusedClearly,
                  @"the model got neither health data nor an actionable refusal:\n%@", out);
}

- (void)testGuestNodeAndDshVersions {
    if (![self waitForReady]) return;
    XCTestExpectation *done = [self expectationWithDescription:@"versions"];
    NSMutableString *out = [NSMutableString string];
    [ISHShellExecutor executeCommand:@"node -v; dsh --version" lineCallback:^(NSString *line, BOOL isStdErr) {
        if (![line containsString:@"expose_wasm"]) [out appendFormat:@"%@\n", line];
    } completion:^(ISHShellExecutionResult *result) {
        XCTAssertEqual(result.exitCode, 0);
        XCTAssertTrue([out containsString:@"v22."], @"node 22 expected: %@", out);
        XCTAssertTrue([out containsString:@"0.2.0-rc.2"], @"bundled dsh 0.2.0-rc.2 expected: %@", out);
        [done fulfill];
    }];
    [self waitForExpectations:@[done] timeout:120];
}

/// iSH lets the guest mount a real iOS directory with `mount -t ios`, and
/// sys_mount checks no privilege, so any process in the image can ask. The
/// picker is genuine consent the first time, but the grant is then saved as a
/// bookmark and silently restored at every launch, where nothing in DSH knows
/// about it or can take it back. DSH does not register the filesystem, so the
/// mount fails at the type lookup, before any picker is raised.
- (void)testTheGuestCannotMountTheHostFilesystem {
    if (![self waitForReady]) return;
    XCTestExpectation *done = [self expectationWithDescription:@"mount"];
    NSMutableString *out = [NSMutableString string];
    // An unregistered filesystem type fails in sys_mount's type lookup with
    // EINVAL, before iosfs_mount runs and before any picker is raised.
    NSString *command = @"mkdir -p /mnt/probe; "
                        @"for t in ios ios-unsafe; do "
                        @"  mount -t $t none /mnt/probe >/dev/null 2>&1; "
                        @"  echo \"RC-$t:$?\"; "
                        @"done; "
                        @"echo \"IOSMOUNTS:$(awk '$3 ~ /^ios/' /proc/mounts | wc -l)\"";
    [ISHShellExecutor executeCommand:command lineCallback:^(NSString *line, BOOL isStdErr) {
        [out appendFormat:@"%@\n", line];
    } completion:^(ISHShellExecutionResult *result) {
        for (NSString *type in @[@"ios", @"ios-unsafe"]) {
            NSString *marker = [NSString stringWithFormat:@"RC-%@:", type];
            XCTAssertTrue([out containsString:marker],
                          @"no result for -t %@ — the probe did not run: %@", type, out);
        }
        XCTAssertTrue([out containsString:@"IOSMOUNTS:0"],
                      @"an ios filesystem is mounted in the guest: %@", out);
        XCTAssertFalse([out containsString:@"RC-ios:0"],
                       @"`mount -t ios` succeeded: %@", out);
        XCTAssertFalse([out containsString:@"RC-ios-unsafe:0"],
                       @"`mount -t ios-unsafe` succeeded: %@", out);
        [done fulfill];
    }];
    [self waitForExpectations:@[done] timeout:180];
}

@end
