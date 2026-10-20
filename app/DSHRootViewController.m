//
//  DSHRootViewController.m
//  DSH
//

#import "DSHRootViewController.h"
#import "DSHLifecycleDiagnostics.h"
#import "DSHHarness.h"
#import "DSHBootCoordinator.h"
#import "DSHLogViewController.h"
#import "DSHCapabilitiesViewController.h"
#import "DSHActivityViewController.h"
#import "DSHActivityLog.h"
#import "DSHTurnPresence.h"
#import "DSHRootUpgrader.h"
#import "DSHStartupMetrics.h"
#import "DSHStatusOverlayView.h"
#import "DSHAppLifecycle.h"
#import "DSHLifecycleCoordinator.h"
#import "TerminalViewController.h"
#import "AppDelegate.h"
#import <WebKit/WebKit.h>

static NSString *const kDSHUserAgentSuffix = @" DSH-iOS/1.0";

#if TARGET_OS_SIMULATOR
static BOOL DSHUsesOptionalCancelTouchFixture(void) {
    NSDictionary<NSString *, NSString *> *environment = NSProcessInfo.processInfo.environment;
    return [environment[@"DSH_TEST_HOST"] isEqualToString:@"1"] &&
           [environment[@"DSH_UI_OPTIONAL_CANCEL_FIXTURE"] isEqualToString:@"1"];
}
#endif

// Read-only observation in explicitly opted-in simulator UI tests. Never click,
// read inputs, change the DOM, or relax an onboarding success assertion.
#if TARGET_OS_SIMULATOR
// BEGIN DSH_GUEST_DIALOG_OBSERVER
static NSString *const DSHGuestDialogObservationScript =
@"(() => {\n"
"  'use strict';\n"
"  const bridge = window.webkit?.messageHandlers?.dshGuestDialog;\n"
"  if (!bridge || window.__dshGuestDialogObserver) return;\n"
"  window.__dshGuestDialogObserver = true;\n"
"  const started = performance.now();\n"
"  const kinds = new Map([['Preview Notice', 'welcome'], ['预览版说明', 'welcome'],\n"
"    ['Add an API key to get started', 'api'], ['添加一个 API Key 开始使用', 'api']]);\n"
"  const actions = new Map([['Continue', 'welcome'], ['继续', 'welcome'],\n"
"    ['Configure later', 'api'], ['稍后配置', 'api']]);\n"
"  let sequence = 0, scans = 0, stopped = false, queued = false;\n"
"  let previous = new Map();\n"
"  const instances = new WeakMap();\n"
"  let nextInstance = 0;\n"
"  const instance = element => {\n"
"    if (!element) return 0;\n"
"    if (!instances.has(element)) instances.set(element, ++nextInstance);\n"
"    return instances.get(element);\n"
"  };\n"
"  const known = () => Array.from(document.querySelectorAll('[role=\"dialog\"]')).slice(0, 16)\n"
"    .flatMap(dialog => {\n"
"      const title = dialog.querySelector('h2');\n"
"      const kind = title && kinds.get(title.textContent.trim());\n"
"      if (!kind) return [];\n"
"      const action = Array.from(dialog.querySelectorAll('button')).slice(0, 16)\n"
"        .find(button => actions.get(button.textContent.trim()) === kind);\n"
"      return [{dialog, action, kind}];\n"
"    });\n"
"  const inertAncestor = element => {\n"
"    for (let cursor = element, depth = 0; cursor && depth < 32; cursor = cursor.parentElement, depth++) {\n"
"      if (cursor.inert) return true;\n"
"    }\n"
"    return false;\n"
"  };\n"
"  const state = ({dialog, action, kind}) => {\n"
"    const root = document.getElementById('root');\n"
"    const rect = action?.getBoundingClientRect();\n"
"    const visible = !!rect && rect.width > 0 && rect.height > 0 &&\n"
"      getComputedStyle(action).visibility === 'visible' && getComputedStyle(action).display !== 'none';\n"
"    const hit = visible ? document.elementFromPoint(rect.x + rect.width / 2, rect.y + rect.height / 2) : null;\n"
"    return {ui_dialog: kind, ui_dialog_present: dialog.isConnected,\n"
"      ui_modal_instance: instance(dialog), ui_action_instance: instance(action),\n"
"      ui_root_inert: !!root?.inert, ui_modal_inert: inertAncestor(dialog),\n"
"      ui_modal_under_root: !!root?.contains(dialog), ui_action_enabled: !!action && !action.disabled,\n"
"      ui_action_visible: visible, ui_hit_action: !!action && !!hit && (hit === action || action.contains(hit)),\n"
"      ui_view_width: Math.round(window.innerWidth), ui_view_height: Math.round(window.innerHeight)};\n"
"  };\n"
"  const emit = (phase, record, extra = {}) => {\n"
"    if (stopped || sequence >= 192) return;\n"
"    bridge.postMessage({...record, ...extra, ui_phase: phase, ui_sequence: ++sequence,\n"
"      ui_elapsed_ms: Math.max(0, Math.round(performance.now() - started))});\n"
"  };\n"
"  const stop = () => {\n"
"    if (stopped) return;\n"
"    for (const [kind, record] of previous) emit('finished', record);\n"
"    stopped = true;\n"
"    observer.disconnect();\n"
"    for (const [name, listener, capture] of listeners) window.removeEventListener(name, listener, capture);\n"
"  };\n"
"  const scan = () => {\n"
"    queued = false;\n"
"    if (stopped) return;\n"
"    if (++scans > 512) { stop(); return; }\n"
"    const current = new Map();\n"
"    for (const item of known()) {\n"
"      const record = state(item);\n"
"      current.set(item.kind, record);\n"
"      if (JSON.stringify(record) !== JSON.stringify(previous.get(item.kind)))\n"
"        emit(previous.has(item.kind) ? 'state' : 'started', record);\n"
"    }\n"
"    for (const [kind, record] of previous)\n"
"      if (!current.has(kind)) emit('state', {...record, ui_dialog_present: false});\n"
"    previous = current;\n"
"    if (sequence >= 192) stop();\n"
"  };\n"
"  const scheduleScan = () => {\n"
"    if (!queued && !stopped) { queued = true; requestAnimationFrame(scan); }\n"
"  };\n"
"  const observeEvent = (event, phase) => {\n"
"    if (stopped) return;\n"
"    for (const item of known()) {\n"
"      const record = state(item);\n"
"      const target = event.target;\n"
"      const targetAction = !!item.action && !!target &&\n"
"        (target === item.action || item.action.contains(target));\n"
"      emit(phase, record, {ui_trusted: !!event.isTrusted,\n"
"        ui_default_prevented: !!event.defaultPrevented, ui_target_action: targetAction});\n"
"      queueMicrotask(() => {\n"
"        if (!stopped) emit('after_event', state(item),\n"
"          {ui_trusted: !!event.isTrusted, ui_default_prevented: !!event.defaultPrevented,\n"
"           ui_target_action: targetAction});\n"
"      });\n"
"    }\n"
"  };\n"
"  const listeners = [];\n"
"  for (const name of ['pointerdown', 'pointerup', 'pointercancel', 'touchstart', 'touchend', 'touchcancel', 'click']) {\n"
"    const listener = event => observeEvent(event, name === 'click' ? 'click_capture' : name);\n"
"    listeners.push([name, listener, true]);\n"
"    window.addEventListener(name, listener, {capture: true, passive: true});\n"
"  }\n"
"  const bubble = event => observeEvent(event, 'click_bubble');\n"
"  listeners.push(['click', bubble, false]);\n"
"  window.addEventListener('click', bubble, {passive: true});\n"
"  const observer = new MutationObserver(scheduleScan);\n"
"  observer.observe(document.documentElement, {childList: true, subtree: true,\n"
"    attributes: true, attributeFilter: ['disabled', 'inert', 'hidden', 'aria-hidden', 'style', 'class']});\n"
"  scan();\n"
"  setTimeout(stop, 600000);\n"
"})();\n";
// END DSH_GUEST_DIALOG_OBSERVER

@interface DSHGuestDialogMessageHandler : NSObject <WKScriptMessageHandler>
@property (nonatomic) NSUInteger count;
@end
@implementation DSHGuestDialogMessageHandler
- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message {
    (void)controller;
    if (!message.frameInfo.isMainFrame || ![message.body isKindOfClass:NSDictionary.class] || self.count >= 192) return;
    WKSecurityOrigin *origin = message.frameInfo.securityOrigin;
    if (![origin.protocol isEqual:@"http"] || ![origin.host isEqual:@"127.0.0.1"] ||
        origin.port != DSHHarness.shared.port) return;
    NSDictionary *body = message.body;
    NSMutableDictionary *record = [NSMutableDictionary new];
    for (NSString *key in @[@"ui_dialog", @"ui_phase", @"ui_sequence", @"ui_elapsed_ms", @"ui_modal_instance", @"ui_action_instance",
          @"ui_trusted", @"ui_default_prevented", @"ui_root_inert", @"ui_modal_inert", @"ui_modal_under_root",
          @"ui_action_enabled", @"ui_action_visible", @"ui_hit_action", @"ui_target_action",
          @"ui_dialog_present", @"ui_view_width", @"ui_view_height"]) {
        if (body[key]) record[key] = body[key];
    }
    NSDictionary *safe = [DSHLifecycleDiagnostics sanitizedEvent:record];
    if (!safe[@"ui_dialog"] || !safe[@"ui_phase"]) return;
    record = [safe mutableCopy];
    record[@"event"] = @"guestDialogObserved";
    record[@"ui_native_sequence"] = @(++self.count);
    record[@"ui_host_ms"] = @((uint64_t)(NSProcessInfo.processInfo.systemUptime * 1000));
    NSData *data = [NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys error:nil];
    if (data) [DSHHarness.shared.log append:[@"[lifecycle] " stringByAppendingString:
        [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]]];
    // UI application stdout is not retained by XCTest; use the existing safe,
    // bounded launch report collected after this batch (without an fsync/tap).
}
@end
#endif


@interface DSHRootViewController () <WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate>
@property (nonatomic) WKWebView *webView;
@property (nonatomic) DSHStatusOverlayView *overlay;
@property (nonatomic) UIView *controlBar;
@property (nonatomic) NSLayoutConstraint *controlBarHeight;
@property (nonatomic) UILabel *titleLabel;
@property (nonatomic) UIView *statusDot;
@property (nonatomic) UIButton *menuButton;
@property (nonatomic) UIButton *activityIndicatorButton;
@property (nonatomic) UIButton *terminalButton;
@property (nonatomic, nullable) TerminalViewController *terminalVC;
@property (nonatomic) uint16_t loadedPort;
@property (nonatomic) BOOL pageLoaded;
@property (nonatomic) uint64_t sessionWarningGeneration;
@property (nonatomic, weak, nullable) UIAlertController *sessionRecoveryAlert;
@property (nonatomic) NSUInteger pageLoadGeneration;
/// Authentication generation the in-flight (or last successful) navigation
/// used. The harness bumps its own counter whenever the server mints a new
/// launch token, so a mismatch means the page was loaded with a credential
/// that no longer applies and the next load must redo the handshake.
@property (nonatomic) NSUInteger loadedAuthGeneration;
@property (nonatomic) BOOL sawHarnessContent;
@property (nonatomic) NSMutableDictionary<NSValue *, NSURL *> *downloadDestinations;
#if TARGET_OS_SIMULATOR
- (void)loadOptionalCancelTouchFixture;
#endif
@end

@implementation DSHRootViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorNamed:@"DSHBackground"] ?: UIColor.systemBackgroundColor;
    self.downloadDestinations = [NSMutableDictionary dictionary];

#if TARGET_OS_SIMULATOR
    if (DSHUsesOptionalCancelTouchFixture()) {
        [self loadOptionalCancelTouchFixture];
        return;
    }
#endif
    [self buildWebView];
    [self buildControlBar];
    [self buildOverlay];

    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(harnessStateChanged:) name:DSHHarnessStateDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(logChanged:) name:DSHLogBufferDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(bootStateChanged:) name:DSHBootStateDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(sessionRecoveryChanged:)
              name:DSHLifecycleCoordinatorRecoveryDidChangeNotification object:nil];
    [self observeActivity];
    [DSHTurnPresence.shared start];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(turnWasInterrupted:)
                                               name:DSHTurnWasInterruptedNotification object:nil];
    [self applyHarnessState];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

#pragma mark - Building the view

#if TARGET_OS_SIMULATOR
/// A deterministic compatibility-click suppression boundary, isolated from
/// guest boot. Read the actual shipped binder instead of maintaining a test
/// copy. This does not identify why the guest's intermittent click was absent.
- (void)loadOptionalCancelTouchFixture {
    NSString *path = [NSBundle.mainBundle pathForResource:@"manifest" ofType:@"json"
                                            inDirectory:@"OnboardingInteraction.bundle"];
    NSData *data = path ? [NSData dataWithContentsOfFile:path] : nil;
    NSDictionary *manifest = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSString *beginMarker = @"// BEGIN DSH_OPTIONAL_CANCEL_TOUCH_BINDER";
    NSString *endMarker = @"// END DSH_OPTIONAL_CANCEL_TOUCH_BINDER";
    NSString *binder;
    NSUInteger matches = 0;
    if ([manifest isKindOfClass:NSDictionary.class] && [manifest[@"patches"] isKindOfClass:NSArray.class]) {
        for (id patch in manifest[@"patches"]) {
            if (![patch isKindOfClass:NSDictionary.class] || ![patch[@"replacements"] isKindOfClass:NSArray.class]) continue;
            for (id replacement in patch[@"replacements"]) {
                if (![replacement isKindOfClass:NSDictionary.class]) continue;
                NSString *source = replacement[@"replace"];
                if (![source isKindOfClass:NSString.class]) continue;
                NSRange begin = [source rangeOfString:beginMarker];
                NSRange end = [source rangeOfString:endMarker];
                if (begin.location == NSNotFound && end.location == NSNotFound) continue;
                matches++;
                if (begin.location == NSNotFound || end.location == NSNotFound || NSMaxRange(begin) >= end.location) continue;
                NSRange afterBegin = NSMakeRange(NSMaxRange(begin), source.length - NSMaxRange(begin));
                NSRange afterEnd = NSMakeRange(NSMaxRange(end), source.length - NSMaxRange(end));
                if ([source rangeOfString:beginMarker options:0 range:afterBegin].location != NSNotFound ||
                    [source rangeOfString:endMarker options:0 range:afterEnd].location != NSNotFound) continue;
                binder = [source substringWithRange:NSMakeRange(NSMaxRange(begin), end.location - NSMaxRange(begin))];
            }
        }
    }
    if (matches != 1 || !binder.length || [binder rangeOfString:@"</script" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        UILabel *failure = [UILabel new];
        failure.text = @"Optional cancel fixture: unique shipped binder is missing";
        failure.accessibilityIdentifier = @"dsh.optionalCancelTouchFixture.error";
        failure.numberOfLines = 0;
        failure.frame = self.view.bounds;
        failure.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self.view addSubview:failure];
        return;
    }

    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    configuration.websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore;
    configuration.defaultWebpagePreferences.allowsContentJavaScript = YES;
    self.webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:configuration];
    self.webView.accessibilityIdentifier = @"dsh.optionalCancelTouchFixture";
    self.webView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.webView];
    [NSLayoutConstraint activateConstraints:@[
        [self.webView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.webView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [self.webView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.webView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];
    NSString *header = @"<!doctype html><html><head><meta name='viewport' content='width=device-width,initial-scale=1'>"
        "<style>body{font:17px system-ui;margin:16px;background:white;color:black}"
        "h1{font-size:20px}section{position:relative;width:min(320px,90vw);height:64px;margin:12px auto}"
        "button{position:absolute;inset:0;font:inherit;touch-action:manipulation}"
        ".upper{z-index:2;background:#ddd}.under{z-index:1}#drag{touch-action:none}"
        "pre{white-space:pre-wrap;overflow-wrap:anywhere;font-size:13px}</style></head><body>"
        "<main role='dialog' aria-modal='true' aria-label='Optional cancel touch fixture'><h1>Optional cancel real touch fixture</h1>"
        "<section><button class='under'>Underlying original control</button><button id='original' class='upper'>Original optional cancel</button></section>"
        "<section><button class='under'>Underlying bound control</button><button id='bound' class='upper'>Bound optional cancel</button></section>"
        "<section><button class='under'>Underlying drag control</button><button id='drag' class='upper'>Drag guarded optional cancel</button></section>"
        "<section><button class='under'>Underlying cleaned control</button><button id='cleaned' class='upper'>Cleaned optional cancel</button></section>"
        "<pre id='receipt' aria-live='polite'></pre></main><script>\n'use strict';\n";
    NSString *footer = @"\n(() => {\n"
        "const counts={original:0,bound:0,drag:0,cleaned:0,beneath:0,blockedOriginalClicks:0,trustedEnds:0,dragObserved:false,settled:0};\n"
        "const receipt=document.getElementById('receipt');\n"
        "const render=()=>{receipt.textContent='DSH touch fixture receipt '+JSON.stringify(counts);};\n"
        "const original=document.getElementById('original'),bound=document.getElementById('bound'),drag=document.getElementById('drag'),cleaned=document.getElementById('cleaned');\n"
        "const upper=[original,bound,drag,cleaned];\n"
        "for(const button of document.querySelectorAll('.under'))button.onclick=()=>{counts.beneath++;render();};\n"
        "original.onclick=()=>{counts.original++;render();};\n"
        "let boundCleanup=()=>{};const finishBound=()=>{counts.bound++;boundCleanup();bound.remove();render();};\n"
        "bound.onclick=finishBound;boundCleanup=dshBindOptionalCancelTouch(bound,finishBound);\n"
        "const finishDrag=()=>{counts.drag++;render();};drag.onclick=finishDrag;dshBindOptionalCancelTouch(drag,finishDrag);\n"
        "const finishCleaned=()=>{counts.cleaned++;render();};cleaned.onclick=finishCleaned;dshBindOptionalCancelTouch(cleaned,finishCleaned)();\n"
        "// Block only the explicit upper target. A retargeted ghost click on an underlying control remains observable.\n"
        "window.addEventListener('click',event=>{const target=event.target;if(!(target instanceof Node)||!upper.some(button=>button===target||button.contains(target)))return;"
        "if(original===target||original.contains(target))counts.blockedOriginalClicks++;event.preventDefault();event.stopImmediatePropagation();render();},true);\n"
        "let active=null;window.addEventListener('touchstart',event=>{if(!event.isTrusted)return;active=upper.find(button=>event.composedPath().includes(button))||null;},{capture:true,passive:true});\n"
        "window.addEventListener('touchmove',event=>{if(event.isTrusted&&active===drag)counts.dragObserved=true;},{capture:true,passive:true});\n"
        "const settle=event=>{if(!event.isTrusted||!active)return;if(event.type==='touchend')counts.trustedEnds++;"
        "if(event.type==='touchcancel'&&active===drag)counts.dragObserved=true;active=null;setTimeout(()=>{counts.settled++;render();},650);};\n"
        "window.addEventListener('touchend',settle,{capture:true,passive:true});window.addEventListener('touchcancel',settle,{capture:true,passive:true});\n"
        "render();\n})();\n</script></body></html>";
    [self.webView loadHTMLString:[[header stringByAppendingString:binder] stringByAppendingString:footer] baseURL:nil];
}
#endif

- (void)buildWebView {
    WKWebViewConfiguration *config = [WKWebViewConfiguration new];
    config.allowsInlineMediaPlayback = YES;
    config.websiteDataStore = WKWebsiteDataStore.defaultDataStore;
    config.applicationNameForUserAgent = kDSHUserAgentSuffix;
    config.defaultWebpagePreferences.allowsContentJavaScript = YES;
#if TARGET_OS_SIMULATOR
    NSString *dialogObservation = NSProcessInfo.processInfo.environment[@"DSH_UI_DIALOG_DIAGNOSTICS"];
    BOOL observeDialogs = [dialogObservation isEqual:@"1"];
    if ([dialogObservation isEqual:@"0"] || observeDialogs) {
        // Record the mode actually received by the app; neither mode nor this
        // native metadata event queries the DOM or changes the input path.
        [DSHHarness.shared.log append:[NSString stringWithFormat:
            @"[lifecycle] {\"event\":\"guestDialogObservationMode\",\"ui_observation_enabled\":%@}",
            observeDialogs ? @"true" : @"false"]];
    }
    if (observeDialogs) {
        [config.userContentController addScriptMessageHandler:[DSHGuestDialogMessageHandler new] name:@"dshGuestDialog"];
        [config.userContentController addUserScript:[[WKUserScript alloc] initWithSource:DSHGuestDialogObservationScript
            injectionTime:WKUserScriptInjectionTimeAtDocumentEnd forMainFrameOnly:YES]];
    }
#endif
    self.webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:config];
    self.webView.navigationDelegate = self;
    self.webView.UIDelegate = self;
    self.webView.allowsBackForwardNavigationGestures = NO;
    self.webView.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    self.webView.scrollView.bounces = NO;
    self.webView.opaque = NO;
    self.webView.backgroundColor = UIColor.clearColor;
    self.webView.scrollView.backgroundColor = UIColor.clearColor;
    self.webView.translatesAutoresizingMaskIntoConstraints = NO;
    self.webView.accessibilityIdentifier = @"dsh.webview";
#if DEBUG
    if (@available(iOS 16.4, *))
        self.webView.inspectable = YES;
#endif
    [self.view addSubview:self.webView];
}

- (void)buildControlBar {
    UIView *bar = [UIView new];
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    bar.backgroundColor = UIColor.clearColor;
    bar.accessibilityIdentifier = @"dsh.controlbar";
    self.controlBar = bar;
    [self.view addSubview:bar];

    UIView *dot = [UIView new];
    dot.translatesAutoresizingMaskIntoConstraints = NO;
    dot.layer.cornerRadius = 4;
    dot.backgroundColor = UIColor.systemOrangeColor;
    dot.accessibilityIdentifier = @"dsh.statusdot";
    dot.isAccessibilityElement = YES;
    dot.accessibilityLabel = @"Harness status";
    self.statusDot = dot;

    UILabel *title = [UILabel new];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"DSH";
    title.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightSemibold];
    title.textColor = UIColor.secondaryLabelColor;
    title.accessibilityIdentifier = @"dsh.title";
    self.titleLabel = title;

    // Mirrors iOS's own privacy indicator: something on the device was just
    // used, here is where to look. Hidden until it has something to say.
    UIButton *activity = [self barButtonWithSymbol:@"antenna.radiowaves.left.and.right"
                                            action:@selector(presentActivity)
                                        identifier:@"dsh.activityindicator"];
    activity.accessibilityLabel = @"Recent capability use";
    activity.tintColor = UIColor.systemOrangeColor;
    activity.hidden = YES;
    self.activityIndicatorButton = activity;

    UIButton *terminal = [self barButtonWithSymbol:@"terminal" action:@selector(presentTerminal) identifier:@"dsh.terminal"];
    terminal.accessibilityLabel = @"Terminal";
    self.terminalButton = terminal;

    UIButton *menu = [self barButtonWithSymbol:@"ellipsis.circle" action:nil identifier:@"dsh.menu"];
    menu.accessibilityLabel = @"More";
    menu.showsMenuAsPrimaryAction = YES;
    menu.menu = [self buildMenu];
    self.menuButton = menu;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[dot, title, [UIView new], activity, terminal, menu]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 8;
    [bar addSubview:stack];

    self.controlBarHeight = [bar.heightAnchor constraintEqualToConstant:32];
    [NSLayoutConstraint activateConstraints:@[
        [bar.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [bar.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
        [bar.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
        self.controlBarHeight,
        [stack.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor constant:12],
        [stack.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor constant:-8],
        [stack.topAnchor constraintEqualToAnchor:bar.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:bar.bottomAnchor],
        [dot.widthAnchor constraintEqualToConstant:8],
        [dot.heightAnchor constraintEqualToConstant:8],

        [self.webView.topAnchor constraintEqualToAnchor:bar.bottomAnchor],
        [self.webView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.webView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        // Keep the harness composer above the software keyboard. WKWebView's
        // own viewport updates are not reliable across iOS releases when its
        // scroll view uses contentInsetAdjustmentNever; the keyboard layout
        // guide makes the native contract explicit and is a no-op for a
        // hardware keyboard.
        [self.webView.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],
    ]];
}

- (UIButton *)barButtonWithSymbol:(NSString *)symbol action:(nullable SEL)action identifier:(NSString *)identifier {
    UIButtonConfiguration *conf = [UIButtonConfiguration plainButtonConfiguration];
    conf.image = [UIImage systemImageNamed:symbol withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightMedium]];
    conf.contentInsets = NSDirectionalEdgeInsetsMake(2, 6, 2, 6);
    conf.baseForegroundColor = UIColor.secondaryLabelColor;
    UIButton *button = [UIButton buttonWithConfiguration:conf primaryAction:nil];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.accessibilityIdentifier = identifier;
    if (action)
        [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (UIMenu *)buildMenu {
    __weak typeof(self) weakSelf = self;
    UIAction *reload = [UIAction actionWithTitle:@"Reload" image:[UIImage systemImageNamed:@"arrow.clockwise"] identifier:@"dsh.reload" handler:^(UIAction *a) { [weakSelf reloadWebView]; }];
    UIAction *terminal = [UIAction actionWithTitle:@"Terminal" image:[UIImage systemImageNamed:@"terminal"] identifier:@"dsh.terminal.menu" handler:^(UIAction *a) { [weakSelf presentTerminal]; }];
    UIAction *capabilities = [UIAction actionWithTitle:@"Capabilities" image:[UIImage systemImageNamed:@"switch.2"] identifier:@"dsh.capabilities" handler:^(UIAction *a) { [weakSelf presentCapabilities]; }];
    UIAction *activity = [UIAction actionWithTitle:@"Activity" image:[UIImage systemImageNamed:@"list.bullet.rectangle"] identifier:@"dsh.activity" handler:^(UIAction *a) { [weakSelf presentActivity]; }];
    UIAction *log = [UIAction actionWithTitle:@"Server Log" image:[UIImage systemImageNamed:@"doc.text.magnifyingglass"] identifier:@"dsh.log" handler:^(UIAction *a) { [weakSelf presentLog]; }];
    UIAction *restart = [UIAction actionWithTitle:@"Restart Harness" image:[UIImage systemImageNamed:@"arrow.triangle.2.circlepath"] identifier:@"dsh.restart" handler:^(UIAction *a) { [weakSelf confirmRestart]; }];
    restart.attributes = UIMenuElementAttributesDestructive;
    UIAction *repair = [UIAction actionWithTitle:@"Repair Linux Environment" image:[UIImage systemImageNamed:@"wrench.and.screwdriver"] identifier:@"dsh.repair" handler:^(UIAction *a) { [weakSelf confirmRepair]; }];
    UIAction *safari = [UIAction actionWithTitle:@"Open in Safari" image:[UIImage systemImageNamed:@"safari"] identifier:@"dsh.safari" handler:^(UIAction *a) {
        // Safari has its own cookie jar, so opening the bare origin would land
        // on the same 401 page the web view used to show. Hand it the entry
        // URL instead: Safari performs the token exchange itself and then has
        // the cookie for the authority, exactly like the in-app web view.
        //
        // This does pass the launch token to another application through the
        // URL. That is inherent to the feature — it is a loopback server only
        // this device can reach, and the user asked for this browser — but it
        // is still never logged.
        NSURL *url = DSHHarness.shared.authenticatedEntryURL;
        if (url == nil) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Not ready yet"
                message:@"The harness has not finished announcing its web address. Try again once the interface has loaded."
                preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [weakSelf presentViewController:alert animated:YES completion:nil];
            return;
        }
        [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
    }];
    UIAction *about = [UIAction actionWithTitle:@"About DSH" image:[UIImage systemImageNamed:@"info.circle"] identifier:@"dsh.about" handler:^(UIAction *a) { [weakSelf presentAbout]; }];
    NSMutableArray<UIMenuElement *> *children = [NSMutableArray arrayWithObjects:reload, terminal, nil];
    [children addObjectsFromArray:@[capabilities, activity, log, [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[safari, restart, repair]], about]];
    return [UIMenu menuWithChildren:children];
}

- (void)buildOverlay {
    self.overlay = [[DSHStatusOverlayView alloc] initWithFrame:CGRectZero];
    self.overlay.translatesAutoresizingMaskIntoConstraints = NO;
    __weak typeof(self) weakSelf = self;
    self.overlay.retryHandler = ^{ [DSHHarness.shared restart]; };
    self.overlay.terminalHandler = ^{ [weakSelf presentTerminal]; };
    self.overlay.logHandler = ^{ [weakSelf presentLog]; };
    [self.view addSubview:self.overlay];
    [NSLayoutConstraint activateConstraints:@[
        [self.overlay.topAnchor constraintEqualToAnchor:self.controlBar.bottomAnchor],
        [self.overlay.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.overlay.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.overlay.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}

#pragma mark - Harness state

- (void)harnessStateChanged:(NSNotification *)note {
    [self applyHarnessState];
}

- (void)bootStateChanged:(NSNotification *)note {
    [self applyHarnessState];
}

- (void)logChanged:(NSNotification *)note {
    [self.overlay setLogText:[DSHHarness.shared.log tail:12]];
    [self showSessionRecoveryIssueIfNeeded];
}

- (void)sessionRecoveryChanged:(NSNotification *)note {
    [self showSessionRecoveryIssueIfNeeded];
}

- (void)showSessionRecoveryIssueIfNeeded {
    [self updateSessionRecoveryIssueForCoordinator:DSHAppLifecycle.sharedCoordinator];
}

- (void)updateSessionRecoveryIssueForCoordinator:(DSHLifecycleCoordinator *)coordinator {
    if (!coordinator.sessionRecoveryNeedsAttention) {
        BOOL dismiss = self.sessionRecoveryAlert && self.presentedViewController == self.sessionRecoveryAlert;
        self.sessionRecoveryAlert = nil;
        self.sessionWarningGeneration = 0;
        if (dismiss) {
            __weak typeof(self) weakSelf = self;
            [self dismissViewControllerAnimated:YES completion:^{
                // A newer failed cycle can arrive during the old alert's
                // dismissal. Recheck once UIKit permits presentation again.
                [weakSelf updateSessionRecoveryIssueForCoordinator:coordinator];
            }];
        }
        return;
    }
    NSString *title = coordinator.sessionRecoveryAwaitingRegistration ? @"Session recovery is waiting for startup" : @"Session recovery needs attention";
    NSString *message = coordinator.sessionRecoveryAwaitingRegistration ?
        @"The session control channel has not registered yet, so session writing has not been confirmed safe to resume. Keep DSH open while startup continues. Saved data is preserved; export diagnostics if startup does not finish." :
        @"Session writing has not been confirmed safe to resume. Saved data is preserved; recent content may still be in memory. Keep DSH open and export its diagnostic report before restarting or repairing the environment.";
    if (self.sessionRecoveryAlert) {
        self.sessionRecoveryAlert.title = title;
        self.sessionRecoveryAlert.message = message;
    }
    if (coordinator.state != DSHLifecycleCoordinatorStateRunning ||
        self.sessionWarningGeneration == coordinator.generation || !self.isViewLoaded || !self.view.window ||
        self.presentedViewController != nil) return;
    self.sessionWarningGeneration = coordinator.generation;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message
        preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"View diagnostics" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [weakSelf presentLog];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Keep open" style:UIAlertActionStyleCancel handler:nil]];
    self.sessionRecoveryAlert = alert;
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)applyHarnessState {
    DSHHarness *h = DSHHarness.shared;
    UIColor *dotColor;
    switch (h.state) {
        case DSHHarnessStateReady: dotColor = UIColor.systemGreenColor; break;
        case DSHHarnessStateFailed: dotColor = UIColor.systemRedColor; break;
        case DSHHarnessStateStopped: dotColor = UIColor.systemGrayColor; break;
        default: dotColor = UIColor.systemOrangeColor; break;
    }
    self.statusDot.backgroundColor = dotColor;
    self.statusDot.accessibilityValue = DSHHarnessStateName(h.state);
    self.titleLabel.text = h.port ? [NSString stringWithFormat:@"DSH · :%u", h.port] : @"DSH";

    // Before the guest is up, the boot coordinator owns the overlay.
    DSHBootCoordinator *boot = DSHBootCoordinator.shared;
    self.terminalButton.enabled = boot.phase == DSHBootPhaseReady;
    if (boot.phase != DSHBootPhaseReady) {
        if (boot.phase == DSHBootPhaseFailed) {
            [self.overlay showFailure:boot.statusMessage];
        } else {
            [self.overlay showStarting:boot.statusMessage];
            [self.overlay setDeterminateProgress:boot.progress
                                          detail:boot.progress >= 0
                                                 ? [NSString stringWithFormat:@"%.0f%% · first launch only", boot.progress * 100]
                                                 : @"this takes a moment on first launch"];
        }
        return;
    }

    switch (h.state) {
        case DSHHarnessStateIdle:
        case DSHHarnessStateStarting:
            [self.overlay showStarting:@"Starting DeepSeek Harness…"];
            [self showStartupProgressForHarness:h];
            break;
        case DSHHarnessStateRestarting:
            [self.overlay showStarting:@"Restarting the harness…"];
            [self.overlay setProgressStartedAt:nil expected:0];
            self.pageLoaded = NO;
            break;
        case DSHHarnessStateReady:
            if ([self needsReauthentication])
                [self loadHarness];
            else
                [self.overlay hide];
            break;
        case DSHHarnessStateFailed:
            [self.overlay showFailure:h.lastError ?: @"The harness could not be started."];
            break;
        case DSHHarnessStateStopped:
            [self.overlay showFailure:@"The harness is stopped."];
            break;
    }
}

- (void)showStartupProgressForHarness:(DSHHarness *)harness {
    if (harness.state != DSHHarnessStateStarting) {
        [self.overlay setProgressStartedAt:nil expected:0];
        return;
    }
    __weak DSHHarness *weakHarness = harness;
    [self.overlay setProgressElapsedProvider:^{ return weakHarness.activeStartupDuration; }
                                  expected:harness.expectedStartupDuration];
}

- (void)loadHarness {
    // Never load the bare origin. Under dsh 0.2.x it answers 401 with a
    // one-line plain-text body, which is what "the app shows a blank page and
    // the health checks all report green" looked like. Entering through the
    // authenticated URL is the handshake: the server answers 303 with
    // `location: ./` and the auth cookie, and every later load of the same
    // authority is served normally.
    NSURL *url = DSHHarness.shared.authenticatedEntryURL;
    if (url == nil) {
        // The token has not been announced yet. Say so rather than loading a
        // URL that is known to fail; -applyHarnessState runs again when the
        // harness captures the token or changes state.
        [self.overlay showStarting:@"Authenticating with the harness…"];
        [self showStartupProgressForHarness:DSHHarness.shared];
        return;
    }
    [self.overlay showStarting:@"Loading the interface…"];
    [self.overlay setProgressStartedAt:nil expected:0];
    self.loadedPort = DSHHarness.shared.port;
    self.loadedAuthGeneration = DSHHarness.shared.authenticationGeneration;
    self.pageLoaded = NO;
    self.sawHarnessContent = NO;
    self.pageLoadGeneration++;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    [self.webView loadRequest:req];
}

/// Whenever the harness captures a new launch token — the first boot, a
/// restart, a crash recovery — the page in the web view was authorised by a
/// credential that no longer exists on the server. It may keep working (the
/// cookie is signed with a per-installation secret and survives a restart on
/// the same authority) or it may not (the page was never authenticated, or the
/// port changed). Re-entering through the current entry URL is correct in both
/// cases: when the cookie is still valid the exchange is a cheap redirect,
/// and when it is not this is the only way back in.
- (BOOL)needsReauthentication {
    if (DSHHarness.shared.state != DSHHarnessStateReady)
        return NO;
    if (!self.pageLoaded)
        return YES;
    if (self.loadedPort != DSHHarness.shared.port)
        return YES;
    return self.loadedAuthGeneration != DSHHarness.shared.authenticationGeneration;
}

- (void)sceneDidBecomeActive {
    // After a suspension the page's websocket may be gone; the client
    // reconnects on its own, but a dead server needs a restart + reload.
    // Only the harness decides whether to restart — this path just marks the
    // page stale and lets the harness's retry ladder do its job.
    __weak typeof(self) weakSelf = self;
    [DSHAppLifecycle.sharedCoordinator performWhenRunning:^{
        typeof(self) self = weakSelf;
        [self showSessionRecoveryIssueIfNeeded];
        if (!self || DSHHarness.shared.state != DSHHarnessStateReady || !self.pageLoaded) return;
        [DSHHarness.shared verifyAliveWithCompletion:^(BOOL alive) {
            if (!alive) weakSelf.pageLoaded = NO;
        }];
    }];
}

#pragma mark - Actions

- (void)reloadWebView {
    if (DSHHarness.shared.state == DSHHarnessStateReady)
        [self loadHarness];
    else
        [DSHHarness.shared start];
}

- (void)confirmRestart {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Restart the harness?"
                                                                   message:@"Running agent turns are interrupted; sessions are kept on disk."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Restart" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [DSHHarness.shared restart];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)confirmRepair {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Repair the Linux environment?"
        message:@"On the next launch DSH will reinstall its bundled Linux system and migrate your sessions, credentials and workspace. The current system is kept until migration succeeds."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Repair on Next Launch" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [DSHRootUpgrader.shared scheduleRepairOnNextLaunch];
        [DSHHarness.shared.log append:@"[dsh-ios] Linux environment repair scheduled for next launch"];
        UIAlertController *done = [UIAlertController alertControllerWithTitle:@"Repair scheduled"
            message:@"Close DSH and open it again. Your user data will be migrated after the fresh system boots."
            preferredStyle:UIAlertControllerStyleAlert];
        [done addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:done animated:YES completion:nil];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)presentTerminal {
    // iSH's terminal offers to "install the built-in APK" on first use; our
    // guest ships with apk already, so skip that startup message.
    [NSUserDefaults.standardUserDefaults setInteger:1 forKey:@"Skip Startup Message"];
    if (self.terminalVC == nil) {
        UIStoryboard *sb = [UIStoryboard storyboardWithName:@"Terminal" bundle:nil];
        TerminalViewController *vc = [sb instantiateInitialViewController];
        vc.sceneSession = nil; // never let a shell exit tear down our scene
        vc.modalPresentationStyle = UIModalPresentationPageSheet;
        [vc startNewSession];
        self.terminalVC = vc;
    }
    if (self.terminalVC.presentingViewController != nil)
        return;
    // A WKWebView exposes nested WebView AX nodes; identify the native sheet
    // so UI tests can prove they operate on the terminal, not the main page.
    self.terminalVC.view.accessibilityIdentifier = @"dsh.terminal.sheet";
    [self presentViewController:self.terminalVC animated:YES completion:nil];
}

- (void)presentLog {
    DSHLogViewController *vc = [[DSHLogViewController alloc] initWithLog:DSHHarness.shared.log];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)presentCapabilities {
    DSHCapabilitiesViewController *vc = [DSHCapabilitiesViewController new];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)presentActivity {
    DSHActivityViewController *vc = [DSHActivityViewController new];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)presentAbout {
    DSHHarness *h = DSHHarness.shared;
    NSString *version = [NSString stringWithFormat:@"%@ (%@)",
                         [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"],
                         [NSBundle.mainBundle objectForInfoDictionaryKey:(NSString *) kCFBundleVersionKey]];
    NSString *message = [NSString stringWithFormat:
                         @"DSH %@\n\nDeepSeek Harness running in an Alpine Linux guest (iSH ARM64 emulator) inside this app.\n\nServer: %@\nState: %@\nStartup: %.1fs · restarts: %lu\n\n%@",
                         version, h.baseURL.absoluteString ?: @"–", DSHHarnessStateName(h.state), h.lastStartupDuration,
                         (unsigned long) h.restartCount, DSHStartupMetrics.shared.summary];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"About DSH" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - A turn that did not survive the background

/// Long enough to read once, and it goes away on the next status update anyway.
static const NSTimeInterval kInterruptedNoticeVisible = 8;

- (void)turnWasInterrupted:(NSNotification *)note {
    // The bar, not an alert: the user came back to carry on, and a dialog to
    // dismiss first would be in the way of the thing they returned for.
    BOOL ready = [note.userInfo[DSHTurnRecoveryStatusKey] isEqualToString:@"server-ready"];
    self.titleLabel.text = ready ? @"DSH · checking interrupted turn" : @"DSH · turn interrupted";
    self.titleLabel.accessibilityLabel =
        ready ? @"A turn was interrupted while DSH was away. The server is available; check the conversation before retrying."
              : @"A turn was interrupted while DSH was away and the server is unavailable. DSH is recovering it.";
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(applyHarnessState) object:nil];
    [self performSelector:@selector(applyHarnessState) withObject:nil afterDelay:kInterruptedNoticeVisible];
}

#pragma mark - Capability activity indicator

/// Long enough to notice out of the corner of an eye, short enough that it
/// means "just now" rather than "at some point today".
static const NSTimeInterval kActivityIndicatorVisible = 6;

- (void)observeActivity {
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(activityChanged)
                                               name:DSHActivityLogDidChangeNotification object:nil];
}

- (void)activityChanged {
    DSHActivityEntry *latest = DSHActivityLog.shared.entries.firstObject;
    // Only device capabilities light it up. A shell command in the guest is
    // recorded, but it is not the thing the user needs to be told about.
    if (latest.source != DSHActivitySourceCapability || -latest.date.timeIntervalSinceNow > kActivityIndicatorVisible)
        return;
    [self showActivityIndicatorFor:latest];
}

- (void)showActivityIndicatorFor:(DSHActivityEntry *)entry {
    self.activityIndicatorButton.tintColor = entry.outcome == DSHActivityOutcomeOK
        ? UIColor.systemOrangeColor : UIColor.systemGrayColor;
    self.activityIndicatorButton.accessibilityLabel =
        [NSString stringWithFormat:@"%@ used %@", entry.name, DSHActivityOutcomeName(entry.outcome)];
    if (self.activityIndicatorButton.isHidden) {
        self.activityIndicatorButton.hidden = NO;
        self.activityIndicatorButton.alpha = 0;
        [UIView animateWithDuration:0.2 animations:^{ self.activityIndicatorButton.alpha = 1; }];
    }
    // Each new call restarts the clock, so a busy stretch stays lit throughout
    // rather than flickering once per call.
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(hideActivityIndicator) object:nil];
    [self performSelector:@selector(hideActivityIndicator) withObject:nil afterDelay:kActivityIndicatorVisible];
}

- (void)hideActivityIndicator {
    [UIView animateWithDuration:0.3 animations:^{
        self.activityIndicatorButton.alpha = 0;
    } completion:^(BOOL finished) {
        self.activityIndicatorButton.hidden = YES;
    }];
}

#pragma mark - Keyboard shortcuts

- (NSArray<UIKeyCommand *> *)keyCommands {
    UIKeyCommand *reload = [UIKeyCommand keyCommandWithInput:@"r" modifierFlags:UIKeyModifierCommand action:@selector(reloadWebView)];
    reload.discoverabilityTitle = @"Reload";
    UIKeyCommand *terminal = [UIKeyCommand keyCommandWithInput:@"t" modifierFlags:UIKeyModifierCommand | UIKeyModifierShift action:@selector(presentTerminal)];
    terminal.discoverabilityTitle = @"Terminal";
    return @[reload, terminal];
}

- (BOOL)canBecomeFirstResponder {
    return YES;
}

#pragma mark - WKNavigationDelegate

- (BOOL)isHarnessURL:(NSURL *)url {
    // Authority-based, so the authenticated entry URL (origin + ?token=) is
    // recognised as ours and the navigation policy does not try to hand it to
    // Safari. Handing the token to another app would also be a credential
    // leak; keeping the comparison here means the check cannot drift.
    return [DSHHarness.shared ownsURL:url];
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *url = action.request.URL;
    if (url == nil || [self isHarnessURL:url] || [url.scheme isEqualToString:@"about"] || [url.scheme isEqualToString:@"blob"] || [url.scheme isEqualToString:@"data"]) {
        decisionHandler(WKNavigationActionPolicyAllow);
        return;
    }
    // Anything leaving the local server (docs links, OAuth pages) opens in Safari.
    if ([url.scheme hasPrefix:@"http"] || [url.scheme isEqualToString:@"mailto"]) {
        [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
        decisionHandler(WKNavigationActionPolicyCancel);
        return;
    }
    decisionHandler(WKNavigationActionPolicyAllow);
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationResponse:(WKNavigationResponse *)response decisionHandler:(void (^)(WKNavigationResponsePolicy))decisionHandler {
    if ([response.response isKindOfClass:NSHTTPURLResponse.class]) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *) response.response;
        // An authenticated navigation must not leave a 401 body on screen.
        // Catching it here, before the response is committed, is what makes
        // the recovery invisible: re-enter through the current entry URL
        // instead of rendering "dsh web authentication required".
        if (http.statusCode == 401 || http.statusCode == 407) {
            [DSHHarness.shared.log append:[NSString stringWithFormat:
                @"[dsh-ios] the web view was refused (HTTP %ld) on %@; re-entering through the authenticated URL",
                (long) http.statusCode, response.response.URL.path.length ? response.response.URL.path : @"/"]];
            if ([DSHHarness.shared noteAuthenticationFailureForURL:response.response.URL]) {
                decisionHandler(WKNavigationResponsePolicyCancel);
                [self loadHarness];
                return;
            }
        }
    }
    if (!response.canShowMIMEType) {
        decisionHandler(WKNavigationResponsePolicyDownload);
        return;
    }
    if ([response.response isKindOfClass:NSHTTPURLResponse.class]) {
        NSString *disposition = ((NSHTTPURLResponse *) response.response).allHeaderFields[@"Content-Disposition"];
        if ([disposition.lowercaseString hasPrefix:@"attachment"]) {
            decisionHandler(WKNavigationResponsePolicyDownload);
            return;
        }
    }
    decisionHandler(WKNavigationResponsePolicyAllow);
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    self.pageLoaded = YES;
    [DSHHarness.shared.log append:@"[perf] web interface loaded"];
    [DSHStartupMetrics.shared mark:@"web_ready"];
    [self.overlay hide];
}

/// The client is a single-page app, so the first `didFinish` is the empty
/// shell; the UI only exists once the client plugin has rendered into it. That
/// distinction is what tells a successful login apart from a 401 page that
/// still counts as a finished navigation.
- (void)webView:(WKWebView *)webView didCommitNavigation:(WKNavigation *)navigation {
    __weak typeof(self) weakSelf = self;
    [webView evaluateJavaScript:@"document.documentElement.outerHTML.length"
              completionHandler:^(id result, NSError *error) {
        typeof(self) self = weakSelf;
        if (self == nil || error != nil)
            return;
        NSNumber *length = [result isKindOfClass:NSNumber.class] ? result : nil;
        if (length.integerValue > 4000) {
            self.sawHarnessContent = YES;
            [DSHHarness.shared.log append:[NSString stringWithFormat:
                @"[dsh-ios] web interface rendered (%ld bytes of document)", (long) length.integerValue]];
            [DSHStartupMetrics.shared mark:@"web_rendered"];
        }
    }];
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self handleLoadError:error];
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self handleLoadError:error];
}

- (void)handleLoadError:(NSError *)error {
    if (error.code == NSURLErrorCancelled)
        return;
    self.pageLoaded = NO;
    NSUInteger generation = self.pageLoadGeneration;
    [DSHHarness.shared.log append:[NSString stringWithFormat:@"[dsh-ios] page load failed: %@", error.localizedDescription]];
    [self.overlay showStarting:@"Waiting for the harness…"];
    // The server was answering a moment ago; give it a beat and retry, and
    // let the harness restart it if it is really gone. The harness owns the
    // health-check retry ladder, so a failed page load only asks once and
    // never restarts on its own.
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t) (1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) self = weakSelf;
        if (self == nil || self.pageLoaded || generation != self.pageLoadGeneration)
            return;
        [DSHHarness.shared verifyAliveWithCompletion:^(BOOL alive) {
            if (!alive)
                return;
            // The check may have taken a while; only reload if nothing newer
            // has started a load in the meantime.
            if (self.pageLoaded || generation != self.pageLoadGeneration)
                return;
            [self loadHarness];
        }];
    });
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
    [DSHLifecycleDiagnostics recordEvent:@"webContentProcessTerminated" harness:DSHHarness.shared];
    [DSHHarness.shared.log append:@"[dsh-ios] web content process terminated; reloading"];
    self.pageLoaded = NO;
    if (DSHHarness.shared.state == DSHHarnessStateReady)
        [self loadHarness];
}

- (void)webView:(WKWebView *)webView navigationResponse:(WKNavigationResponse *)navigationResponse didBecomeDownload:(WKDownload *)download {
    download.delegate = self;
}

- (void)webView:(WKWebView *)webView navigationAction:(WKNavigationAction *)navigationAction didBecomeDownload:(WKDownload *)download {
    download.delegate = self;
}

#pragma mark - WKDownloadDelegate

- (void)download:(WKDownload *)download decideDestinationUsingResponse:(NSURLResponse *)response suggestedFilename:(NSString *)suggestedFilename completionHandler:(void (^)(NSURL * _Nullable))completionHandler {
    NSURL *docs = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *dir = [docs URLByAppendingPathComponent:@"Downloads" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *name = suggestedFilename.length ? suggestedFilename : @"download";
    NSURL *dest = [dir URLByAppendingPathComponent:name];
    NSUInteger n = 1;
    while ([NSFileManager.defaultManager fileExistsAtPath:dest.path]) {
        NSString *stem = name.stringByDeletingPathExtension, *ext = name.pathExtension;
        NSString *alt = ext.length ? [NSString stringWithFormat:@"%@-%lu.%@", stem, (unsigned long) n++, ext] : [NSString stringWithFormat:@"%@-%lu", stem, (unsigned long) n++];
        dest = [dir URLByAppendingPathComponent:alt];
    }
    self.downloadDestinations[[NSValue valueWithNonretainedObject:download]] = dest;
    completionHandler(dest);
}

- (void)downloadDidFinish:(WKDownload *)download {
    NSValue *key = [NSValue valueWithNonretainedObject:download];
    NSURL *dest = self.downloadDestinations[key];
    [self.downloadDestinations removeObjectForKey:key];
    if (dest == nil)
        return;
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[dest] applicationActivities:nil];
    share.popoverPresentationController.sourceView = self.menuButton;
    [self presentViewController:share animated:YES completion:nil];
}

- (void)download:(WKDownload *)download didFailWithError:(NSError *)error resumeData:(NSData *)resumeData {
    [self.downloadDestinations removeObjectForKey:[NSValue valueWithNonretainedObject:download]];
    [DSHHarness.shared.log append:[NSString stringWithFormat:@"[dsh-ios] download failed: %@", error.localizedDescription]];
}

#pragma mark - WKUIDelegate

- (WKWebView *)webView:(WKWebView *)webView createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration forNavigationAction:(WKNavigationAction *)navigationAction windowFeatures:(WKWindowFeatures *)windowFeatures {
    // target=_blank: keep local URLs in place, hand external ones to Safari.
    NSURL *url = navigationAction.request.URL;
    if (url == nil)
        return nil;
    if ([self isHarnessURL:url])
        [webView loadRequest:navigationAction.request];
    else
        [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
    return nil;
}

- (void)webView:(WKWebView *)webView runJavaScriptAlertPanelWithMessage:(NSString *)message initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(void))completionHandler {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { completionHandler(); }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)webView:(WKWebView *)webView runJavaScriptConfirmPanelWithMessage:(NSString *)message initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(BOOL))completionHandler {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) { completionHandler(NO); }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { completionHandler(YES); }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)webView:(WKWebView *)webView runJavaScriptTextInputPanelWithPrompt:(NSString *)prompt defaultText:(NSString *)defaultText initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(NSString * _Nullable))completionHandler {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil message:prompt preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) { tf.text = defaultText; }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) { completionHandler(nil); }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { completionHandler(alert.textFields.firstObject.text); }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Status bar

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleDefault;
}

@end
