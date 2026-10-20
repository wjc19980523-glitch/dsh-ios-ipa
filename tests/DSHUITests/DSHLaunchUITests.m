//
//  DSHLaunchUITests.m
//  DSHUITests
//
//  End-to-end checks on a real device/simulator: the app boots the Linux
//  guest, dsh-serve comes up, the WKWebView shows the DeepSeek Harness UI,
//  and the native controls (terminal, log, menu) work.
//

#import <XCTest/XCTest.h>

static const NSTimeInterval kBootTimeout = 300;   // first launch imports the rootfs

@interface DSHLaunchUITests : XCTestCase
@property (nonatomic) XCUIApplication *app;
@property (nonatomic) NSUInteger guestDialogAttempt;
@end

@implementation DSHLaunchUITests

- (void)setUp {
    self.continueAfterFailure = NO;
    self.app = [[XCUIApplication alloc] init];
#if TARGET_OS_SIMULATOR
    if ([self.name containsString:@"testOptionalCancelTouchSurvivesSuppressedCompatibilityClick"]) {
        self.app.launchEnvironment = @{ @"DSH_TEST_HOST": @"1", @"DSH_UI_OPTIONAL_CANCEL_FIXTURE": @"1" };
        [self.app launch];
        return;
    }
#endif
    // Hosted unit tests use a blank scene; UI tests must launch the real app.
    // Required UI acceptance follows the production input path. Opt in only
    // for a diagnostic run; geometry observation can itself affect WebKit.
    NSString *observeDialogs = [NSProcessInfo.processInfo.environment[@"DSH_UI_DIALOG_DIAGNOSTICS"] isEqual:@"1"] ? @"1" : @"0";
    self.app.launchEnvironment = @{ @"DSH_TEST_HOST": @"0", @"DSH_UI_DIALOG_DIAGNOSTICS": observeDialogs };
    __weak DSHLaunchUITests *weakSelf = self;
    [self addUIInterruptionMonitorWithDescription:@"Refuse DSH system permission requests"
                                          handler:^BOOL(XCUIElement *interruption) {
        (void)interruption;
        XCUIApplication *springboard = [[XCUIApplication alloc] initWithBundleIdentifier:@"com.apple.springboard"];
        if (!springboard.alerts.firstMatch.exists)
            return NO; // App-owned confirmations are exercised explicitly below.
        // A delayed request must not reach XCTest's default Allow/Continue handler.
        [weakSelf declinePendingSystemPermissionAlerts];
        return YES;
    }];
    [self declinePendingSystemPermissionAlerts];
    [self.app launch];
    [self declinePendingSystemPermissionAlerts];
}

- (void)attachScreenshot:(NSString *)name {
    XCTAttachment *att = [XCTAttachment attachmentWithScreenshot:[XCUIScreen.mainScreen screenshot]];
    att.name = name;
    att.lifetime = XCTAttachmentLifetimeKeepAlways;
    [self addAttachment:att];
}

/// Hosted capability tests can leave an unanswered system permission request.
/// Refuse only this app's requests; an unfamiliar system alert is a test failure.
- (void)declinePendingSystemPermissionAlerts {
    XCUIApplication *springboard = [[XCUIApplication alloc] initWithBundleIdentifier:@"com.apple.springboard"];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:15];
    for (NSUInteger count = 0; count < 6 && deadline.timeIntervalSinceNow > 0; count++) {
        XCUIElement *alert = springboard.alerts.firstMatch;
        if (![alert waitForExistenceWithTimeout:MIN(0.5, MAX(0, deadline.timeIntervalSinceNow))])
            return;

        NSString *title = alert.staticTexts.firstMatch.label ?: @"";
        NSString *normalizedTitle = [[[title stringByReplacingOccurrencesOfString:@"“" withString:@"\""]
                                      stringByReplacingOccurrencesOfString:@"”" withString:@"\""] lowercaseString];
        BOOL belongsToApp = [normalizedTitle containsString:@"\"dshios\""] ||
                            [normalizedTitle containsString:@"\"dsh\""];
        NSArray<NSString *> *refusalLabels = @[@"Don't Allow", @"Don’t Allow", @"不允许"];
        XCUIElement *refuse = [alert.buttons matchingPredicate:
                              [NSPredicate predicateWithFormat:@"label IN %@", refusalLabels]].firstMatch;
        if (!belongsToApp || !refuse.exists) {
            [self attachScreenshot:@"unexpected-system-alert"];
            XCTFail(@"Refusing to handle an unfamiliar system alert: %@", title);
            return;
        }

        [refuse tap];
        // A different queued permission may appear immediately after this one.
        XCUIElement *sameAlert = [springboard.alerts containingType:XCUIElementTypeStaticText identifier:title].firstMatch;
        XCTNSPredicateExpectation *gone = [[XCTNSPredicateExpectation alloc]
                                          initWithPredicate:[NSPredicate predicateWithFormat:@"exists == NO"]
                                          object:sameAlert];
        NSTimeInterval remaining = MAX(0, deadline.timeIntervalSinceNow);
        if ([XCTWaiter waitForExpectations:@[gone] timeout:MIN(2, remaining)] != XCTWaiterResultCompleted) {
            [self attachScreenshot:@"permission-alert-did-not-close"];
            XCTFail(@"System permission alert remained after explicitly denying it: %@", title);
            return;
        }
    }
    if (springboard.alerts.firstMatch.exists) {
        [self attachScreenshot:@"permission-alert-limit"];
        XCTFail(@"System permission alerts exceeded the bounded refusal window");
    }
}

/// Only record the known dialog/action's state. Never inspect credential fields.
- (NSDictionary *)guestDialogState:(XCUIElement *)dialog action:(XCUIElement *)action web:(XCUIElement *)web {
    BOOL present = dialog.exists;
    BOOL buttonPresent = present && action.exists;
    return @{@"dialog_present": @(present), @"action_present": @(buttonPresent),
             @"action_enabled": @(buttonPresent && action.enabled),
             @"action_hittable": @(buttonPresent && action.hittable),
             @"action_frame": buttonPresent ? NSStringFromCGRect(action.frame) : @"absent",
             @"web_frame": NSStringFromCGRect(web.frame),
             @"keyboard_present": @(self.app.keyboards.firstMatch.exists),
             @"app_state": @(self.app.state)};
}

- (void)attachGuestDialogState:(NSDictionary *)state phase:(NSString *)phase labels:(NSArray<NSString *> *)labels {
    NSMutableDictionary *record = [state mutableCopy];
    record[@"phase"] = phase;
    record[@"attempt_id"] = @(self.guestDialogAttempt);
    record[@"known_dialog_labels"] = labels;
    record[@"test_host_uptime"] = @(NSProcessInfo.processInfo.systemUptime);
    NSData *data = [NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys error:nil];
    XCTAttachment *attachment = [XCTAttachment attachmentWithData:data uniformTypeIdentifier:@"public.json"];
    attachment.name = [@"guest-dialog-" stringByAppendingString:phase];
    attachment.lifetime = XCTAttachmentLifetimeKeepAlways;
    [self addAttachment:attachment];
    NSLog(@"[ui-dialog] %@", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
}

/// Complete only the named, optional web step using its explicit safe action.
- (void)closeKnownGuestDialogInWebView:(XCUIElement *)web
                              labels:(NSArray<NSString *> *)dialogLabels
                        actionLabels:(NSArray<NSString *> *)actionLabels
                      closureTimeout:(NSTimeInterval)closureTimeout {
    [self declinePendingSystemPermissionAlerts];
    XCUIElement *dialog = [web.otherElements matchingPredicate:
                          [NSPredicate predicateWithFormat:@"label IN %@", dialogLabels]].firstMatch;
    if (![dialog waitForExistenceWithTimeout:10])
        return;
    self.guestDialogAttempt++;
    XCUIElement *action = [dialog.buttons matchingPredicate:
                          [NSPredicate predicateWithFormat:@"label IN %@", actionLabels]].firstMatch;
    // One monotonic budget covers readiness, the tap and closure. In Preview,
    // repeated AX queries can outlive a separate five-second waiter; collecting
    // another full snapshot before tapping then describes a different state.
    // Keep the original closure budget, include readiness in it, and record the
    // actual successful observation without extra AX calls on the critical path.
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + closureTimeout;
    // First-launch workspace initialization can show a transient notification
    // over the web UI. Preserve that warning, then let it finish naturally
    // before the single Welcome tap. This is test input stabilization, not a
    // workspace repair or a bypass of Welcome's persistence acknowledgement.
    // It shares the original deadline; a persistent warning still fails.
    if ([dialogLabels containsObject:@"Preview Notice, web dialog"]) {
        NSArray<NSString *> *startupWarningLabels = @[
            @"无法创建默认工作区，请通过“选择工作区”选择文件夹",
            @"Unable to create default workspace. Use Choose workspace to select a folder."
        ];
        XCUIElement *warning = [[web descendantsMatchingType:XCUIElementTypeAny] matchingPredicate:
                                [NSPredicate predicateWithFormat:@"label IN %@", startupWarningLabels]].firstMatch;
        NSTimeInterval warningStarted = NSProcessInfo.processInfo.systemUptime;
        BOOL warningObserved = warning.exists;
        XCTWaiterResult warningResult = XCTWaiterResultCompleted;
        if (warningObserved) {
            [self attachScreenshot:@"startup-workspace-warning-before-welcome"];
            XCTNSPredicateExpectation *warningGone = [[XCTNSPredicateExpectation alloc]
                                                       initWithPredicate:[NSPredicate predicateWithFormat:@"exists == NO"]
                                                       object:warning];
            warningResult = [XCTWaiter waitForExpectations:@[warningGone]
                                                  timeout:MAX(0, deadline - NSProcessInfo.processInfo.systemUptime)];
        }
        NSTimeInterval warningFinished = NSProcessInfo.processInfo.systemUptime;
        BOOL warningClearedInTime = warningResult == XCTWaiterResultCompleted && warningFinished <= deadline;
        [self attachGuestDialogState:@{@"warning_observed": @(warningObserved),
                                      @"warning_wait_started_uptime": @(warningStarted),
                                      @"warning_wait_finished_uptime": @(warningFinished),
                                      @"waiter_result": @(warningResult),
                                      @"deadline_uptime": @(deadline),
                                      @"cleared_in_time": @(warningClearedInTime)}
                              phase:@"startup-workspace-warning" labels:dialogLabels];
        XCTAssertTrue(warningClearedInTime,
                      @"the observed startup warning must finish within the original Welcome deadline");
    }
    __block NSDictionary *readyState;
    NSPredicate *actionReady = [NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary *bindings) {
        (void)bindings;
        XCUIElement *element = object;
        BOOL exists = element.exists;
        BOOL enabled = exists && element.enabled;
        BOOL hittable = enabled && element.hittable;
        NSTimeInterval observed = NSProcessInfo.processInfo.systemUptime;
        readyState = @{@"action_present": @(exists), @"action_enabled": @(enabled),
                       @"action_hittable": @(hittable), @"observed_uptime": @(observed),
                       @"deadline_uptime": @(deadline), @"within_deadline": @(observed <= deadline)};
        return exists && enabled && hittable && observed <= deadline;
    }];
    XCTNSPredicateExpectation *ready = [[XCTNSPredicateExpectation alloc] initWithPredicate:actionReady object:action];
    XCTWaiterResult readyResult = [XCTWaiter waitForExpectations:@[ready]
                                                       timeout:MAX(0, deadline - NSProcessInfo.processInfo.systemUptime)];
    [self attachGuestDialogState:readyState ?: @{} phase:@"readiness-observation" labels:dialogLabels];
    if (readyResult != XCTWaiterResultCompleted) {
        [self attachGuestDialogState:[self guestDialogState:dialog action:action web:web]
                              phase:@"readiness-timeout-current-state" labels:dialogLabels];
        [self attachScreenshot:@"guest-dialog-readiness-timeout"];
    }
    XCTAssertEqual(readyResult, XCTWaiterResultCompleted,
                   @"the known web dialog needs an enabled, hittable safe action: %@", dialogLabels);
    NSTimeInterval tapStarted = NSProcessInfo.processInfo.systemUptime;
    [action tap];
    NSTimeInterval tapReturned = NSProcessInfo.processInfo.systemUptime;
    NSPredicate *gone = [NSPredicate predicateWithFormat:@"exists == NO"];
    XCTNSPredicateExpectation *closed = [[XCTNSPredicateExpectation alloc] initWithPredicate:gone object:dialog];
    XCTWaiterResult closedResult = [XCTWaiter waitForExpectations:@[closed]
                                                       timeout:MAX(0, deadline - NSProcessInfo.processInfo.systemUptime)];
    NSTimeInterval closureObserved = NSProcessInfo.processInfo.systemUptime;
    BOOL closedInTime = closedResult == XCTWaiterResultCompleted && closureObserved <= deadline;
    NSMutableDictionary *closureState = [[self guestDialogState:dialog action:action web:web] mutableCopy];
    closureState[@"waiter_result"] = @(closedResult);
    closureState[@"tap_started_uptime"] = @(tapStarted);
    closureState[@"tap_returned_uptime"] = @(tapReturned);
    closureState[@"closure_observed_uptime"] = @(closureObserved);
    closureState[@"deadline_uptime"] = @(deadline);
    closureState[@"closed_in_time"] = @(closedInTime);
    [self attachGuestDialogState:closureState
                          phase:closedInTime ? @"closed" : @"closure-timeout"
                         labels:dialogLabels];
    XCTAssertTrue(closedInTime,
                   @"the known web dialog must close within its original deadline: %@", dialogLabels);
    XCTAssertFalse(dialog.exists, @"the known web dialog must close before opening native controls: %@", dialogLabels);
}

/// Fresh CI simulators follow the normal guest onboarding without entering keys.
- (void)completeGuestFirstLaunchOnboardingIfPresent {
    XCUIElement *web = self.app.webViews[@"dsh.webview"];
    XCTAssertTrue([web waitForExistenceWithTimeout:10]);
    // Exact copy/action pairs from the lockfile's ui-settings-models 0.2.0-rc.2
    // WelcomeNotice and DeepSeekOnboardingDialog. Scope every tap to that named
    // web dialog; system Continue/Allow and credential Save are never selected.
    // Real Simulator AX showed Continue disabled in its saving/ACK state beyond
    // 20 seconds under emulation. Still require the exact welcome dialog to close
    // within a finite window before exercising any native controls.
    [self closeKnownGuestDialogInWebView:web
                                 labels:@[@"预览版说明, web dialog", @"Preview Notice, web dialog"]
                           actionLabels:@[@"继续", @"Continue"]
                         closureTimeout:120];
    [self closeKnownGuestDialogInWebView:web
                                 labels:@[@"添加一个 API Key 开始使用, web dialog", @"Add an API key to get started, web dialog"]
                           actionLabels:@[@"稍后配置", @"Configure later"]
                         closureTimeout:20];
}

/// Waits until the harness overlay is gone (server answered and page loaded).
- (void)waitForHarnessReady {
    // Passive readiness queries do not invoke XCTest interruption monitors.
    [self declinePendingSystemPermissionAlerts];
    XCUIElement *overlay = self.app.staticTexts[@"dsh.overlay.message"];
    XCUIElement *dot = self.app.otherElements[@"dsh.statusdot"];
    NSPredicate *ready = [NSPredicate predicateWithFormat:@"exists == YES AND value == 'ready'"];
    XCTestExpectation *server = [self expectationForPredicate:ready evaluatedWithObject:dot handler:nil];
    [self waitForExpectations:@[server] timeout:kBootTimeout];
    NSPredicate *gone = [NSPredicate predicateWithFormat:@"exists == NO OR hittable == NO"];
    XCTestExpectation *e = [self expectationForPredicate:gone evaluatedWithObject:overlay handler:nil];
    [self waitForExpectations:@[e] timeout:kBootTimeout];
    XCTAssertTrue(dot.exists, @"the native status indicator must remain present");
    XCTAssertEqualObjects(dot.value, @"ready", @"status dot should report ready");
    [self completeGuestFirstLaunchOnboardingIfPresent];
}

- (void)testHarnessBootsAndShowsWebUI {
    // Import, migration and Harness startup have different progress wording.
    // Every visible phase should expose progress and a nonempty detail line.
    XCUIElement *progress = self.app.progressIndicators[@"dsh.overlay.progress"];
    XCUIElement *elapsed = self.app.staticTexts[@"dsh.overlay.elapsed"];
    if ([progress waitForExistenceWithTimeout:5]) {
        XCTAssertTrue([elapsed waitForExistenceWithTimeout:5]);
        NSPredicate *hasDetail = [NSPredicate predicateWithFormat:@"label.length > 0"];
        NSPredicate *hasProgress = [NSPredicate predicateWithBlock:^BOOL(id evaluatedObject, NSDictionary *bindings) {
            (void)bindings;
            XCUIElement *element = evaluatedObject;
            return element.value != nil && [[element.value description] length] > 0;
        }];
        XCTestExpectation *detail = [self expectationForPredicate:hasDetail evaluatedWithObject:elapsed handler:nil];
        XCTestExpectation *value = [self expectationForPredicate:hasProgress evaluatedWithObject:progress handler:nil];
        [self waitForExpectations:@[detail, value] timeout:10];
    }
    [self attachScreenshot:@"01-launch"];
    [self waitForHarnessReady];
    [self attachScreenshot:@"02-ready"];

    XCUIElement *web = self.app.webViews.firstMatch;
    XCTAssertTrue([web waitForExistenceWithTimeout:30], @"web view should exist");

    // The first-run notice and normal client both expose buttons. Verify a
    // usable client control without assuming the user's saved language or
    // accepting a brand name in an otherwise noninteractive page.
    NSPredicate *uiUp = [NSPredicate predicateWithBlock:^BOOL(id evaluatedObject, NSDictionary *bindings) {
        (void)bindings;
        XCUIElement *client = evaluatedObject;
        if (!client.exists || !client.isHittable) return NO;
        for (XCUIElement *button in client.buttons.allElementsBoundByIndex) {
            if (button.exists && button.isEnabled && button.isHittable && button.label.length > 0)
                return YES;
        }
        return NO;
    }];
    XCTestExpectation *e = [self expectationForPredicate:uiUp evaluatedWithObject:web handler:nil];
    [self waitForExpectations:@[e] timeout:90];
    [self attachScreenshot:@"03-web-ui"];

    // Title shows the port the server listens on.
    XCUIElement *title = self.app.staticTexts[@"dsh.title"];
    XCTAssertTrue(title.exists);
    XCTAssertTrue([title.label containsString:@":30"], @"title should show the port, got %@", title.label);
}

- (void)testServerLogIsReachableFromMenu {
    [self waitForHarnessReady];
    XCUIElement *menu = self.app.buttons[@"dsh.menu"];
    XCTAssertTrue([menu waitForExistenceWithTimeout:10]);
    [menu tap];
    XCUIElement *logItem = self.app.buttons[@"Server Log"];
    XCTAssertTrue([logItem waitForExistenceWithTimeout:5], @"menu should list Server Log");
    [logItem tap];
    XCUIElement *logView = self.app.textViews[@"dsh.logview"];
    XCTAssertTrue([logView waitForExistenceWithTimeout:10]);
    NSString *text = (NSString *) logView.value;
    XCTAssertTrue([text containsString:@"server answered"], @"log should record readiness, got: %@", text);
    XCTAssertTrue([text containsString:@"dsh web: http://127.0.0.1:"], @"log should carry dsh's own banner, got: %@", text);
    [self attachScreenshot:@"04-log"];
    [self.app.buttons[@"Done"] tap];
}

/// The capabilities screen is the only way a user can turn a bridge capability
/// on, so the switch has to be reachable, ask before granting, and stick.
///
/// This drives `device.info`, the one capability with no system permission
/// behind it. Capabilities that do have one (Health, Calendar, Reminders) put
/// up a sheet owned by another process, which XCUITest cannot reliably dismiss
/// from here; that they can ask at all is asserted in
/// DSHHealthCapabilityTests.testCapabilityCanAskForItsSystemPermission.
- (void)testCapabilitiesScreenTogglesACapability {
    [self waitForHarnessReady];
    XCUIElement *menu = self.app.buttons[@"dsh.menu"];
    XCTAssertTrue([menu waitForExistenceWithTimeout:10]);
    [menu tap];
    XCUIElement *item = self.app.buttons[@"Capabilities"];
    XCTAssertTrue([item waitForExistenceWithTimeout:5], @"menu should list Capabilities");
    [item tap];

    XCUIElement *table = self.app.tables[@"dsh.capabilities"];
    XCTAssertTrue([table waitForExistenceWithTimeout:10]);
    // The sensitive capabilities must at least be listed, or there is no way
    // for a user to reach them — reads in one section, writes in the other.
    XCTAssertTrue([self.app.switches[@"dsh.capability.switch.health.read"] waitForExistenceWithTimeout:10],
                  @"Apple Health should be listed");
    XCTAssertTrue(self.app.switches[@"dsh.capability.switch.calendar.read"].exists,
                  @"Calendar should be listed");
    XCTAssertTrue(self.app.staticTexts[@"What the agent can read"].exists,
                  @"reads and writes should be separated");
    XCTAssertTrue(self.app.staticTexts[@"What the agent can change"].exists);
    [self attachScreenshot:@"05-capabilities"];

    XCUIElement *device = self.app.switches[@"dsh.capability.switch.device.info"];
    XCTAssertTrue([device waitForExistenceWithTimeout:10]);
    NSPredicate *isOn = [NSPredicate predicateWithFormat:@"value == '1'"];
    NSPredicate *isOff = [NSPredicate predicateWithFormat:@"value == '0'"];

    // Switches persist across launches and this app is not reinstalled between
    // runs, so start by normalising rather than assuming a fresh install.
    // Turning something off is immediate — only turning it on asks.
    if ([device.value isEqual:@"1"]) {
        [device tap];
        [self waitForExpectations:@[[self expectationForPredicate:isOff evaluatedWithObject:device handler:nil]] timeout:10];
    }

    [device tap];
    XCUIElement *allow = self.app.alerts.buttons[@"Allow"];
    XCTAssertTrue([allow waitForExistenceWithTimeout:5], @"enabling should ask first, naming what is granted");
    [allow tap];
    [self waitForExpectations:@[[self expectationForPredicate:isOn evaluatedWithObject:device handler:nil]] timeout:10];

    // Cancelling must leave it as it was.
    [device tap];
    [self waitForExpectations:@[[self expectationForPredicate:isOff evaluatedWithObject:device handler:nil]] timeout:10];
    [device tap];
    XCUIElement *cancel = self.app.alerts.buttons[@"Cancel"];
    XCTAssertTrue([cancel waitForExistenceWithTimeout:5]);
    [cancel tap];
    [self waitForExpectations:@[[self expectationForPredicate:isOff evaluatedWithObject:device handler:nil]] timeout:10];

    // device.info ships on; leave it that way.
    [device tap];
    [self.app.alerts.buttons[@"Allow"] tap];
    [self waitForExpectations:@[[self expectationForPredicate:isOn evaluatedWithObject:device handler:nil]] timeout:10];
    [self.app.buttons[@"Done"] tap];
}

/// The Activity screen is where a user checks what the agent has been doing,
/// so it has to be reachable and readable — including on a phone, where its
/// monospaced rows and multi-line details have the least room.
- (void)testActivityScreenIsReachableAndReadable {
    [self waitForHarnessReady];
    XCUIElement *menu = self.app.buttons[@"dsh.menu"];
    XCTAssertTrue([menu waitForExistenceWithTimeout:10]);
    [menu tap];
    XCUIElement *item = self.app.buttons[@"Activity"];
    XCTAssertTrue([item waitForExistenceWithTimeout:5], @"menu should list Activity");
    [item tap];

    XCUIElement *table = self.app.tables[@"dsh.activity"];
    XCTAssertTrue([table waitForExistenceWithTimeout:10]);
    [self attachScreenshot:@"06-activity"];

    // Either there are rows or the empty state explains itself; a blank screen
    // with neither is the failure worth catching.
    BOOL hasRows = table.cells.count > 0;
    XCTAssertTrue(hasRows, @"the table should show rows or an empty-state row");

    // The filters are the point of the screen for anyone looking for trouble.
    // A queued permission may appear after the Activity tap; existence queries
    // alone do not invoke the interruption monitor.
    [self declinePendingSystemPermissionAlerts];
    // The segment is a button in this table header. Its accessibility ancestor
    // is not required to expose the SegmentedControl type on every iOS release.
    XCUIElement *problems = table.buttons[@"Problems"];
    if (![problems waitForExistenceWithTimeout:5]) {
        XCTAttachment *hierarchy = [XCTAttachment attachmentWithString:table.debugDescription];
        hierarchy.name = @"activity-table-accessibility";
        hierarchy.lifetime = XCTAttachmentLifetimeKeepAlways;
        [self addAttachment:hierarchy];
        [self attachScreenshot:@"activity-filter-missing"];
    }
    XCTAssertTrue(problems.exists, @"filters should be reachable");
    XCTAssertTrue(problems.isHittable, @"the Problems filter must be tappable");
    [problems tap];
    NSPredicate *selected = [NSPredicate predicateWithFormat:@"selected == YES"];
    XCTestExpectation *filter = [self expectationForPredicate:selected evaluatedWithObject:problems handler:nil];
    [self waitForExpectations:@[filter] timeout:5];
    XCTAssertTrue([table waitForExistenceWithTimeout:5]);
    [self attachScreenshot:@"07-activity-problems"];

    [self.app.buttons[@"Done"] tap];
}

- (void)testLandscapeKeepsWebViewAndBar {
    [self waitForHarnessReady];
    XCUIDevice.sharedDevice.orientation = UIDeviceOrientationLandscapeLeft;
    sleep(2);
    XCUIElement *web = self.app.webViews.firstMatch;
    XCTAssertTrue([web waitForExistenceWithTimeout:10]);
    CGRect frame = web.frame;
    XCTAssertGreaterThan(frame.size.width, frame.size.height, @"web view should be wider than tall in landscape (%@)", NSStringFromCGRect(frame));
    XCTAssertTrue(self.app.buttons[@"dsh.menu"].isHittable, @"control bar stays reachable in landscape");
    [self attachScreenshot:@"06-landscape"];
    XCUIDevice.sharedDevice.orientation = UIDeviceOrientationPortrait;
    sleep(1);
    XCTAssertTrue(self.app.webViews.firstMatch.exists);
}

- (void)testTerminalOpensAndDismisses {
    [self waitForHarnessReady];
    XCUIElement *terminal = self.app.buttons[@"dsh.terminal"];
    XCTAssertTrue([terminal waitForExistenceWithTimeout:10]);
    [terminal tap];
    // WebKit exposes multiple WebView AX layers for each actual WKWebView.
    // An application-wide index can select the main page's inner WebView.
    XCUIElement *sheet = self.app.otherElements[@"dsh.terminal.sheet"];
    XCTAssertTrue([sheet waitForExistenceWithTimeout:20], @"the native terminal sheet must be presented");
    XCUIElement *termWeb = sheet.webViews.firstMatch;
    XCTAssertTrue([termWeb waitForExistenceWithTimeout:20], @"the terminal sheet needs its own hterm web view");
    sleep(3);
    [self attachScreenshot:@"05-terminal"];
    // Dismissal must remove the terminal and make the main controls usable.
    // Begin at the sheet's top edge. A gesture in hterm's scrollable content
    // scrolls the terminal and does not exercise UIKit's sheet dismissal.
    XCUICoordinate *top = [sheet coordinateWithNormalizedOffset:CGVectorMake(0.5, 0.01)];
    XCUICoordinate *down = [sheet coordinateWithNormalizedOffset:CGVectorMake(0.5, 0.8)];
    [top pressForDuration:0.1 thenDragToCoordinate:down];
    NSPredicate *gone = [NSPredicate predicateWithFormat:@"exists == NO"];
    NSPredicate *usable = [NSPredicate predicateWithFormat:@"hittable == YES AND enabled == YES"];
    XCTestExpectation *dismissed = [self expectationForPredicate:gone evaluatedWithObject:sheet handler:nil];
    XCTestExpectation *bar = [self expectationForPredicate:usable evaluatedWithObject:self.app.buttons[@"dsh.menu"] handler:nil];
    [self waitForExpectations:@[dismissed, bar] timeout:20];
    XCTAssertTrue(self.app.webViews.firstMatch.exists);
}

#if TARGET_OS_SIMULATOR
/// Exercise the shipped binder using real UIKit touches. The local fixture
/// deliberately withholds compatibility click; this tests that boundary and
/// does not attribute the intermittent guest failure to a WebKit heuristic.
- (NSDictionary *)optionalCancelFixtureReceipt:(XCUIElement *)web settled:(NSUInteger)settled {
    NSString *prefix = @"DSH touch fixture receipt ";
    XCUIElement *receipt = [web.staticTexts matchingPredicate:
                           [NSPredicate predicateWithFormat:@"label BEGINSWITH %@", prefix]].firstMatch;
    __block NSDictionary *observed;
    NSPredicate *ready = [NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary *bindings) {
        (void)bindings;
        XCUIElement *element = object;
        if (!element.exists || ![element.label hasPrefix:prefix]) return NO;
        NSString *json = [element.label substringFromIndex:prefix.length];
        id parsed = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding]
                                                   options:0 error:nil];
        if (![parsed isKindOfClass:NSDictionary.class]) return NO;
        for (NSString *key in @[@"original", @"bound", @"drag", @"cleaned", @"beneath",
              @"blockedOriginalClicks", @"trustedEnds", @"dragObserved", @"settled"]) {
            if (![parsed[key] isKindOfClass:NSNumber.class]) return NO;
        }
        observed = parsed;
        return [observed[@"settled"] unsignedIntegerValue] >= settled;
    }];
    XCTNSPredicateExpectation *complete = [[XCTNSPredicateExpectation alloc] initWithPredicate:ready object:receipt];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[complete] timeout:5], XCTWaiterResultCompleted,
                   @"real touch receipt must settle without a retry tap: %@", observed);
    if (observed) {
        NSData *data = [NSJSONSerialization dataWithJSONObject:observed options:NSJSONWritingSortedKeys error:nil];
        XCTAttachment *attachment = [XCTAttachment attachmentWithData:data uniformTypeIdentifier:@"public.json"];
        attachment.name = [NSString stringWithFormat:@"optional-cancel-touch-receipt-%lu", (unsigned long)settled];
        attachment.lifetime = XCTAttachmentLifetimeKeepAlways;
        [self addAttachment:attachment];
        NSLog(@"[optional-cancel-fixture] %@", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
    }
    return observed ?: @{};
}

- (void)testOptionalCancelTouchSurvivesSuppressedCompatibilityClick {
    XCUIElement *web = self.app.webViews[@"dsh.optionalCancelTouchFixture"];
    BOOL fixtureLoaded = [web waitForExistenceWithTimeout:10];
    NSString *failure = @"local WK fixture did not load";
    if (!fixtureLoaded) {
        XCUIElement *error = self.app.staticTexts[@"dsh.optionalCancelTouchFixture.error"];
        if (error.exists) failure = error.label;
    }
    XCTAssertTrue(fixtureLoaded, @"%@", failure);
    XCUIElement *original = web.buttons[@"Original optional cancel"];
    XCTAssertTrue([original waitForExistenceWithTimeout:5]);
    [original tap];
    NSDictionary *receipt = [self optionalCancelFixtureReceipt:web settled:1];
    XCTAssertEqual([receipt[@"original"] unsignedIntegerValue], 0u);
    XCTAssertEqual([receipt[@"blockedOriginalClicks"] unsignedIntegerValue], 1u,
                   @"the old action must fail because its real compatibility click was suppressed");
    XCTAssertEqual([receipt[@"trustedEnds"] unsignedIntegerValue], 1u);

    XCUIElement *bound = web.buttons[@"Bound optional cancel"];
    XCTAssertTrue(bound.hittable);
    [bound tap];
    receipt = [self optionalCancelFixtureReceipt:web settled:2];
    XCTAssertEqual([receipt[@"bound"] unsignedIntegerValue], 1u,
                   @"one real tap must complete the optional action even without compatibility click");
    XCTAssertEqual([receipt[@"beneath"] unsignedIntegerValue], 0u,
                   @"removing the action must not deliver a ghost click to its underlying control");
    XCTAssertFalse(bound.exists);

    XCUIElement *drag = web.buttons[@"Drag guarded optional cancel"];
    XCTAssertTrue(drag.hittable);
    XCUICoordinate *dragStart = [drag coordinateWithNormalizedOffset:CGVectorMake(0.5, 0.5)];
    XCUICoordinate *dragEnd = [dragStart coordinateWithOffset:CGVectorMake(200, 0)];
    [dragStart pressForDuration:0.05 thenDragToCoordinate:dragEnd];
    receipt = [self optionalCancelFixtureReceipt:web settled:3];
    XCTAssertEqual([receipt[@"drag"] unsignedIntegerValue], 0u);
    XCTAssertTrue([receipt[@"dragObserved"] boolValue], @"the real gesture must move or cancel");
    XCTAssertEqual([receipt[@"beneath"] unsignedIntegerValue], 0u);

    XCUIElement *cleaned = web.buttons[@"Cleaned optional cancel"];
    XCTAssertTrue(cleaned.hittable);
    [cleaned tap];
    receipt = [self optionalCancelFixtureReceipt:web settled:4];
    XCTAssertEqual([receipt[@"cleaned"] unsignedIntegerValue], 0u,
                   @"calling cleanup must detach the shipped touch action");
    XCTAssertEqual([receipt[@"original"] unsignedIntegerValue], 0u);
    XCTAssertEqual([receipt[@"bound"] unsignedIntegerValue], 1u);
    XCTAssertEqual([receipt[@"beneath"] unsignedIntegerValue], 0u);
    [self attachScreenshot:@"optional-cancel-real-touch-fixture"];
}
#endif

@end
