#import "DSHWelcomeTouchFixtureViewController.h"

#if TARGET_OS_SIMULATOR
#import <WebKit/WebKit.h>
#include <math.h>

static NSString *const DSHWelcomeFixturePrefix = @"DSH welcome fixture receipt ";
static NSString *const DSHWelcomeFixtureFooter =
@"// CONDITIONAL REAL-WK FIXTURE ONLY. Append after the SAME manifest helper.\n"
"// No DOM writes, layout/style reads, synthetic input, eval or automatic retry.\n"
"(() => {\n"
"  'use strict';\n"
"  const ids = ['original', 'quick', 'slow', 'pending', 'retry-false', 'retry-reject', 'drag', 'cleaned'];\n"
"  const cases = new Map();\n"
"  let resolvePending = null;\n"
"  const buttons = new Map(ids.map(id => {\n"
"    const button = document.getElementById('welcome-' + id);\n"
"    if (button === null || button.tagName !== 'BUTTON') throw new Error('Welcome fixture button missing');\n"
"    return [id, button];\n"
"  }));\n"
"  const resolveButton = document.getElementById('welcome-resolve-false');\n"
"  if (resolveButton === null || resolveButton.tagName !== 'BUTTON') throw new Error('Welcome fixture control missing');\n"
"\n"
"  function snapshot(record) {\n"
"    return {\n"
"      version: 1, scenario: record.id,\n"
"      touchStarts: record.touchStarts, trustedEnds: record.trustedEnds,\n"
"      moves: record.moves, cancels: record.cancels,\n"
"      naturalClicks: record.naturalClicks, blockedClicks: record.blockedClicks,\n"
"      preventedEnds: record.preventedEnds, uncancelableEnds: record.uncancelableEnds,\n"
"      ackCalls: record.ackCalls, finishes: record.finishes,\n"
"      rejections: record.rejections, settled: record.settled, controls: record.controls,\n"
"      status: record.state.status, acknowledged: record.state.acknowledged,\n"
"      disposed: record.disposed,\n"
"      ambiguousClicks: record.binding?.inspect().ambiguousClicks ?? 0,\n"
"    };\n"
"  }\n"
"  function publish(record) {\n"
"    // Only fixed enum + finite nonnegative counters + booleans leave the page.\n"
"    window.webkit.messageHandlers.dshWelcomeFixture.postMessage(snapshot(record));\n"
"  }\n"
"  function create(id) {\n"
"    const record = {id, state: {status: 'ready', acknowledged: false},\n"
"      touchStarts: 0, trustedEnds: 0, moves: 0, cancels: 0,\n"
"      naturalClicks: 0, blockedClicks: 0, preventedEnds: 0, uncancelableEnds: 0,\n"
"      ackCalls: 0, finishes: 0, rejections: 0, settled: 0, controls: 0,\n"
"      disposed: false, binding: null};\n"
"    cases.set(id, record);\n"
"    return record;\n"
"  }\n"
"  function observe(record, button) {\n"
"    button.addEventListener('touchstart', event => {\n"
"      if (event.isTrusted) {record.touchStarts++; publish(record);}\n"
"    }, {passive: true});\n"
"    button.addEventListener('touchmove', event => {\n"
"      if (event.isTrusted) {record.moves++; publish(record);}\n"
"    }, {passive: true});\n"
"    // Installed AFTER binder, so defaultPrevented is the actual final decision.\n"
"    button.addEventListener('touchend', event => {\n"
"      if (!event.isTrusted) return;\n"
"      record.trustedEnds++;\n"
"      if (event.defaultPrevented) record.preventedEnds++;\n"
"      if (!event.cancelable) record.uncancelableEnds++;\n"
"      publish(record);\n"
"    }, {passive: true});\n"
"    for (const type of ['touchcancel', 'pointercancel']) button.addEventListener(type, event => {\n"
"      if (event.isTrusted) {record.cancels++; publish(record);}\n"
"    }, {passive: true});\n"
"    button.addEventListener('click', event => {\n"
"      if (!event.isTrusted) return;\n"
"      record.naturalClicks++;\n"
"      if (record.id === 'original') {\n"
"        record.blockedClicks++;\n"
"        event.preventDefault();\n"
"        event.stopImmediatePropagation();\n"
"      }\n"
"      publish(record);\n"
"    }, {capture: true});\n"
"  }\n"
"  function answer(record) {\n"
"    const count = record.ackCalls;\n"
"    if (record.id === 'pending' && count === 1) return new Promise(resolve => {resolvePending = resolve;});\n"
"    if (record.id === 'retry-reject' && count === 1) return Promise.reject(new Error('controlled fixture reject'));\n"
"    if (record.id === 'quick') return false;\n"
"    if (record.id === 'retry-false' && count === 1) return false;\n"
"    return true;\n"
"  }\n"
"  for (const id of ids) {\n"
"    const record = create(id), button = buttons.get(id);\n"
"    if (id === 'original') {\n"
"      // The capture listener below withholds the REAL compatibility click.\n"
"      // Original click-only action is never invoked by touchend or script.\n"
"      button.onclick = event => {\n"
"        if (!event.isTrusted) return;\n"
"        record.ackCalls++;\n"
"        publish(record);\n"
"      };\n"
"    } else {\n"
"      record.binding = dshBindWelcomeTouch(button, {\n"
"        getState: () => record.state,\n"
"        acknowledge: () => {\n"
"          record.ackCalls++;\n"
"          record.state.status = 'saving';\n"
"          publish(record);\n"
"          return Promise.resolve().then(() => answer(record)).then(confirmed => {\n"
"            record.state.acknowledged = confirmed === true;\n"
"            record.state.status = confirmed === true ? 'ready' : 'error';\n"
"            return confirmed === true;\n"
"          }, () => {\n"
"            record.state.status = 'error';\n"
"            throw new Error('controlled fixture reject');\n"
"          }).finally(() => {\n"
"            record.settled++;\n"
"            publish(record);\n"
"          });\n"
"        },\n"
"        finish: () => {record.finishes++; publish(record);},\n"
"        onRejected: () => {record.rejections++; publish(record);},\n"
"      });\n"
"      button.onclick = event => { void record.binding.onClick(event); };\n"
"      if (id === 'cleaned') {record.binding.cleanup(); record.disposed = true;}\n"
"    }\n"
"    observe(record, button);\n"
"    publish(record);\n"
"  }\n"
"  resolveButton.onclick = event => {\n"
"    if (!event.isTrusted) return;\n"
"    const record = cases.get('pending');\n"
"    record.controls++;\n"
"    if (resolvePending !== null) {\n"
"      const resolve = resolvePending;\n"
"      resolvePending = null;\n"
"      resolve(false);\n"
"    }\n"
"    // A real control interaction also re-publishes every accumulated count;\n"
"    // Native can confirm no late natural click appeared before the next step.\n"
"    for (const item of cases.values()) publish(item);\n"
"  };\n"
"})();\n";

@interface DSHWelcomeFixtureMessageHandler : NSObject <WKScriptMessageHandler>
@property (nonatomic, weak) WKWebView *webView;
@property (nonatomic) NSUInteger count;
@property (nonatomic, copy) void (^onRecord)(NSDictionary *record);
@property (nonatomic, copy) void (^onFailure)(NSString *reason);
@end

@implementation DSHWelcomeFixtureMessageHandler
- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message {
    (void)controller;
    if (message.webView != self.webView || !message.frameInfo.isMainFrame) return;
    WKSecurityOrigin *origin = message.frameInfo.securityOrigin;
    if (origin.host.length || origin.port ||
        ![@[@"", @"about", @"file"] containsObject:origin.protocol ?: @""]) return;
    if (++self.count > 512) {
        if (self.onFailure) self.onFailure(@"Welcome fixture message limit exceeded");
        return;
    }
    NSDictionary *record = message.body;
    NSArray *counters = @[@"touchStarts", @"trustedEnds", @"moves", @"cancels", @"naturalClicks",
        @"blockedClicks", @"preventedEnds", @"uncancelableEnds", @"ackCalls", @"finishes",
        @"rejections", @"settled", @"controls", @"ambiguousClicks"];
    NSMutableSet *keys = [NSMutableSet setWithArray:counters];
    [keys addObjectsFromArray:@[@"version", @"scenario", @"status", @"acknowledged", @"disposed"]];
    BOOL valid = [record isKindOfClass:NSDictionary.class] &&
        [[NSSet setWithArray:record.allKeys] isEqual:keys] && [record[@"version"] isEqual:@1] &&
        CFGetTypeID((__bridge CFTypeRef)record[@"version"]) != CFBooleanGetTypeID() &&
        [@[@"original", @"quick", @"slow", @"pending", @"retry-false", @"retry-reject", @"drag", @"cleaned"]
            containsObject:record[@"scenario"] ?: NSNull.null] &&
        [@[@"ready", @"saving", @"error"] containsObject:record[@"status"] ?: NSNull.null];
    for (NSString *key in counters) {
        id value = valid ? record[key] : nil;
        double number = [value isKindOfClass:NSNumber.class] &&
            CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID() ? [value doubleValue] : NAN;
        valid = valid && isfinite(number) && number >= 0 && number <= 1000000 && floor(number) == number;
    }
    for (NSString *key in @[@"acknowledged", @"disposed"]) {
        id value = valid ? record[key] : nil;
        valid = valid && [value isKindOfClass:NSNumber.class] &&
            CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
    }
    if (!valid) {
        if (self.onFailure) self.onFailure(@"Invalid Welcome fixture receipt");
        return;
    }
    if (self.onRecord) self.onRecord([record copy]);
}
@end

@interface DSHWelcomeTouchFixtureViewController ()
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) UILabel *receipt;
@property (nonatomic, strong) UILabel *failure;
@property (nonatomic, strong) NSMutableDictionary *cases;
@property (nonatomic, strong) DSHWelcomeFixtureMessageHandler *handler;
@end

@implementation DSHWelcomeTouchFixtureViewController

- (NSString *)shippedWelcomeBinder {
    NSString *path = [NSBundle.mainBundle pathForResource:@"manifest" ofType:@"json"
                                            inDirectory:@"OnboardingInteraction.bundle"];
    NSData *data = path ? [NSData dataWithContentsOfFile:path] : nil;
    NSDictionary *manifest = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![manifest isKindOfClass:NSDictionary.class] || ![manifest[@"patches"] isKindOfClass:NSArray.class]) return nil;
    NSString *beginMarker = @"// BEGIN DSH_WELCOME_TOUCH_BINDER";
    NSString *endMarker = @"// END DSH_WELCOME_TOUCH_BINDER";
    NSString *binder;
    NSUInteger matches = 0;
    for (id patch in manifest[@"patches"]) {
        if (![patch isKindOfClass:NSDictionary.class] || ![patch[@"replacements"] isKindOfClass:NSArray.class]) return nil;
        for (id replacement in patch[@"replacements"]) {
            if (![replacement isKindOfClass:NSDictionary.class]) return nil;
            NSString *source = replacement[@"replace"];
            if (![source isKindOfClass:NSString.class]) return nil;
            NSRange begin = [source rangeOfString:beginMarker], end = [source rangeOfString:endMarker];
            if (begin.location == NSNotFound && end.location == NSNotFound) continue;
            if (begin.location == NSNotFound || end.location == NSNotFound || NSMaxRange(begin) >= end.location) return nil;
            NSRange afterBegin = NSMakeRange(NSMaxRange(begin), source.length - NSMaxRange(begin));
            NSRange afterEnd = NSMakeRange(NSMaxRange(end), source.length - NSMaxRange(end));
            if ([source rangeOfString:beginMarker options:0 range:afterBegin].location != NSNotFound ||
                [source rangeOfString:endMarker options:0 range:afterEnd].location != NSNotFound) return nil;
            matches++;
            binder = [source substringWithRange:NSMakeRange(NSMaxRange(begin), end.location - NSMaxRange(begin))];
        }
    }
    return matches == 1 && binder.length && [binder rangeOfString:@"</script" options:NSCaseInsensitiveSearch].location == NSNotFound ? binder : nil;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.whiteColor;
    self.cases = [NSMutableDictionary dictionary];
    self.receipt = [UILabel new];
    self.receipt.accessibilityIdentifier = @"dsh.welcomeTouchFixture.receipt";
    self.receipt.numberOfLines = 0;
    self.receipt.font = [UIFont monospacedSystemFontOfSize:9 weight:UIFontWeightRegular];
    self.receipt.text = [DSHWelcomeFixturePrefix stringByAppendingString:@"{\"version\":1,\"cases\":{}}"];
    self.receipt.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.receipt];
    self.failure = [UILabel new];
    self.failure.accessibilityIdentifier = @"dsh.welcomeTouchFixture.error";
    self.failure.hidden = YES;
    self.failure.numberOfLines = 0;
    self.failure.frame = CGRectMake(12, 40, 600, 80);
    [self.view addSubview:self.failure];
    NSString *binder = [self shippedWelcomeBinder];
    if (!binder) {
        self.failure.text = @"Unique shipped Welcome binder is missing";
        self.failure.hidden = NO;
        return;
    }
    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    configuration.websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore;
    configuration.defaultWebpagePreferences.allowsContentJavaScript = YES;
    self.handler = [DSHWelcomeFixtureMessageHandler new];
    __weak DSHWelcomeTouchFixtureViewController *weakSelf = self;
    self.handler.onRecord = ^(NSDictionary *record) {
        DSHWelcomeTouchFixtureViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.cases[record[@"scenario"]] = record;
        NSData *json = [NSJSONSerialization dataWithJSONObject:@{@"version": @1, @"cases": strongSelf.cases}
                                                     options:NSJSONWritingSortedKeys error:nil];
        if (json) {
            NSString *text = [DSHWelcomeFixturePrefix stringByAppendingString:
                              [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding]];
            strongSelf.receipt.text = text;
            strongSelf.receipt.accessibilityLabel = text;
        }
    };
    self.handler.onFailure = ^(NSString *reason) {
        weakSelf.failure.text = reason;
        weakSelf.failure.hidden = NO;
    };
    [configuration.userContentController addScriptMessageHandler:self.handler name:@"dshWelcomeFixture"];
    self.webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:configuration];
    self.handler.webView = self.webView;
    self.webView.accessibilityIdentifier = @"dsh.welcomeTouchFixture";
    self.webView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.webView];
    [self.view bringSubviewToFront:self.failure];
    [NSLayoutConstraint activateConstraints:@[
        [self.webView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.webView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.webView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.webView.bottomAnchor constraintEqualToAnchor:self.receipt.topAnchor constant:-8],
        [self.receipt.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.receipt.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [self.receipt.heightAnchor constraintEqualToConstant:180],
        [self.receipt.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
    ]];
    NSString *header = @"<!doctype html><html><head><meta name='viewport' content='width=device-width,initial-scale=1'>"
        "<style>body{font:17px system-ui;margin:16px;background:white;color:black}h2{font-size:20px}"
        ".grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:12px}"
        "button{font:inherit;min-height:64px;border:0;border-radius:12px;background:#0f1115;color:white;touch-action:manipulation}"
        "button:hover{background:#43454a}#welcome-drag{touch-action:none}</style></head><body>"
        "<div id='root' inert>Isolated background</div>"
        "<main role='dialog' aria-modal='true' aria-label='Welcome real input fixture'><h2>Preview Notice</h2><div class='grid'>"
        "<button id='welcome-original'>Original click-only welcome</button>"
        "<button id='welcome-quick'>Quick welcome fallback</button>"
        "<button id='welcome-slow'>Slow welcome fallback</button>"
        "<button id='welcome-pending'>Pending welcome fallback</button>"
        "<button id='welcome-resolve-false'>Fail pending welcome save</button>"
        "<button id='welcome-retry-false'>Retry refused welcome save</button>"
        "<button id='welcome-retry-reject'>Retry rejected welcome save</button>"
        "<button id='welcome-drag'>Drag guarded welcome</button>"
        "<button id='welcome-cleaned'>Detached welcome fallback</button>"
        "</div></main><script>\n'use strict';\n";
    NSString *html = [NSString stringWithFormat:@"%@%@\n%@\n</script></body></html>", header, binder, DSHWelcomeFixtureFooter];
    [self.webView loadHTMLString:html baseURL:nil];
}

- (void)dealloc {
    [self.webView.configuration.userContentController removeScriptMessageHandlerForName:@"dshWelcomeFixture"];
}
@end
#endif
