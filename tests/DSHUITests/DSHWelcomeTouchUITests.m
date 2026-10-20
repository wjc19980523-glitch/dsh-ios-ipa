#import <XCTest/XCTest.h>
#import <TargetConditionals.h>

#if TARGET_OS_SIMULATOR
@interface DSHWelcomeTouchUITests : XCTestCase
@property (nonatomic, strong) XCUIApplication *app;
@end

@implementation DSHWelcomeTouchUITests
- (void)setUp {
    self.continueAfterFailure = NO;
    XCUIDevice.sharedDevice.orientation = UIDeviceOrientationPortrait;
    self.app = [XCUIApplication new];
    self.app.launchEnvironment = @{@"DSH_TEST_HOST": @"1", @"DSH_UI_WELCOME_TOUCH_FIXTURE": @"1"};
    [self.app launch];
    XCTAssertTrue([self.app.webViews[@"dsh.welcomeTouchFixture"] waitForExistenceWithTimeout:10],
                  @"the isolated WK fixture must load the actual shipped Welcome binder");
}

- (NSDictionary *)receiptWhere:(BOOL (^)(NSDictionary *cases))condition name:(NSString *)name {
    XCUIElement *element = self.app.staticTexts[@"dsh.welcomeTouchFixture.receipt"];
    NSString *prefix = @"DSH welcome fixture receipt ";
    __block NSDictionary *observed;
    NSPredicate *ready = [NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary *bindings) {
        (void)bindings;
        XCUIElement *receipt = object;
        if (!receipt.exists || ![receipt.label hasPrefix:prefix]) return NO;
        NSData *data = [[receipt.label substringFromIndex:prefix.length] dataUsingEncoding:NSUTF8StringEncoding];
        id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![parsed isKindOfClass:NSDictionary.class] || ![parsed[@"version"] isEqual:@1] ||
            ![parsed[@"cases"] isKindOfClass:NSDictionary.class]) return NO;
        observed = parsed;
        return condition(parsed[@"cases"]);
    }];
    XCTNSPredicateExpectation *complete = [[XCTNSPredicateExpectation alloc] initWithPredicate:ready object:element];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[complete] timeout:10], XCTWaiterResultCompleted,
                   @"real WK input receipt must satisfy %@: %@", name, observed);
    XCUIElement *error = self.app.staticTexts[@"dsh.welcomeTouchFixture.error"];
    XCTAssertFalse(error.exists, @"fixture validation failed: %@", error.exists ? error.label : @"");
    NSData *data = [NSJSONSerialization dataWithJSONObject:observed ?: @{} options:NSJSONWritingSortedKeys error:nil];
    XCTAttachment *attachment = [XCTAttachment attachmentWithData:data uniformTypeIdentifier:@"public.json"];
    attachment.name = [@"welcome-touch-" stringByAppendingString:name];
    attachment.lifetime = XCTAttachmentLifetimeKeepAlways;
    [self addAttachment:attachment];
    NSLog(@"[welcome-touch-fixture] %@", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
    return observed[@"cases"] ?: @{};
}

- (XCUIElement *)button:(NSString *)label {
    XCUIElement *button = self.app.webViews[@"dsh.welcomeTouchFixture"].buttons[label];
    XCTAssertTrue([button waitForExistenceWithTimeout:5], @"fixture button %@ must be present", label);
    XCTAssertTrue(button.hittable);
    return button;
}

- (void)assertCancelledTouch:(NSDictionary *)record ends:(NSUInteger)ends {
    XCTAssertEqual([record[@"trustedEnds"] unsignedIntegerValue], ends);
    XCTAssertEqual([record[@"preventedEnds"] unsignedIntegerValue], ends,
                   @"each valid real touchend must be canceled by the shipped binder");
    XCTAssertEqual([record[@"uncancelableEnds"] unsignedIntegerValue], 0u);
    XCTAssertEqual([record[@"naturalClicks"] unsignedIntegerValue], 0u,
                   @"a natural compatibility click after canceled touchend violates the required WK contract");
    XCTAssertEqual([record[@"ambiguousClicks"] unsignedIntegerValue], 0u);
}

- (void)testWelcomeTouchCancelsCompatibilityClickAndWaitsForPersistence {
    [[self button:@"Original click-only welcome"] tap];
    NSDictionary *cases = [self receiptWhere:^BOOL(NSDictionary *value) {
        return [value[@"original"][@"blockedClicks"] unsignedIntegerValue] == 1;
    } name:@"original-control"];
    XCTAssertEqual([cases[@"original"][@"trustedEnds"] unsignedIntegerValue], 1u);
    XCTAssertEqual([cases[@"original"][@"naturalClicks"] unsignedIntegerValue], 1u);
    XCTAssertEqual([cases[@"original"][@"ackCalls"] unsignedIntegerValue], 0u);
    XCTAssertEqual([cases[@"original"][@"finishes"] unsignedIntegerValue], 0u);

    [[self button:@"Pending welcome fallback"] tap];
    cases = [self receiptWhere:^BOOL(NSDictionary *value) {
        return [value[@"pending"][@"trustedEnds"] unsignedIntegerValue] == 1 &&
               [value[@"pending"][@"ackCalls"] unsignedIntegerValue] == 1;
    } name:@"pending-first-tap"];
    [self assertCancelledTouch:cases[@"pending"] ends:1];
    XCTAssertEqualObjects(cases[@"pending"][@"status"], @"saving");
    XCTAssertEqual([cases[@"pending"][@"settled"] unsignedIntegerValue], 0u);
    XCTAssertEqual([cases[@"pending"][@"finishes"] unsignedIntegerValue], 0u);

    [[self button:@"Pending welcome fallback"] tap];
    cases = [self receiptWhere:^BOOL(NSDictionary *value) {
        return [value[@"pending"][@"trustedEnds"] unsignedIntegerValue] == 2;
    } name:@"pending-second-tap"];
    [self assertCancelledTouch:cases[@"pending"] ends:2];
    XCTAssertEqual([cases[@"pending"][@"ackCalls"] unsignedIntegerValue], 1u);
    XCTAssertEqual([cases[@"pending"][@"finishes"] unsignedIntegerValue], 0u);

    [[self button:@"Fail pending welcome save"] tap];
    cases = [self receiptWhere:^BOOL(NSDictionary *value) {
        return [value[@"pending"][@"controls"] unsignedIntegerValue] == 1 &&
               [value[@"pending"][@"settled"] unsignedIntegerValue] == 1;
    } name:@"pending-refused"];
    [self assertCancelledTouch:cases[@"pending"] ends:2];
    XCTAssertEqualObjects(cases[@"pending"][@"status"], @"error");
    XCTAssertFalse([cases[@"pending"][@"acknowledged"] boolValue]);
    XCTAssertEqual([cases[@"pending"][@"ackCalls"] unsignedIntegerValue], 1u);
    XCTAssertEqual([cases[@"pending"][@"finishes"] unsignedIntegerValue], 0u);

    [[self button:@"Pending welcome fallback"] tap];
    cases = [self receiptWhere:^BOOL(NSDictionary *value) {
        return [value[@"pending"][@"finishes"] unsignedIntegerValue] == 1;
    } name:@"pending-explicit-retry"];
    [self assertCancelledTouch:cases[@"pending"] ends:3];
    XCTAssertEqual([cases[@"pending"][@"ackCalls"] unsignedIntegerValue], 2u);
    XCTAssertEqual([cases[@"pending"][@"settled"] unsignedIntegerValue], 2u);
    XCTAssertTrue([cases[@"pending"][@"acknowledged"] boolValue]);
    [[self button:@"Fail pending welcome save"] tap];
    cases = [self receiptWhere:^BOOL(NSDictionary *value) {
        return [value[@"pending"][@"controls"] unsignedIntegerValue] == 2;
    } name:@"pending-after-real-control"];
    [self assertCancelledTouch:cases[@"pending"] ends:3];
    XCTAssertEqual([cases[@"pending"][@"ackCalls"] unsignedIntegerValue], 2u);
    XCTAssertEqual([cases[@"pending"][@"finishes"] unsignedIntegerValue], 1u);
    XCTAssertEqual([cases[@"original"][@"ackCalls"] unsignedIntegerValue], 0u);
    XCTAssertEqual([cases[@"original"][@"finishes"] unsignedIntegerValue], 0u);
}

- (void)testWelcomeTouchQuickAndSlowTapsDoNotProduceCompatibilityClicks {
    [[self button:@"Quick welcome fallback"] tap];
    NSDictionary *cases = [self receiptWhere:^BOOL(NSDictionary *value) {
        return [value[@"quick"][@"settled"] unsignedIntegerValue] == 1;
    } name:@"quick-unconfirmed"];
    [self assertCancelledTouch:cases[@"quick"] ends:1];
    XCTAssertEqual([cases[@"quick"][@"ackCalls"] unsignedIntegerValue], 1u);
    XCTAssertEqual([cases[@"quick"][@"finishes"] unsignedIntegerValue], 0u);
    XCTAssertFalse([cases[@"quick"][@"acknowledged"] boolValue]);

    [[self button:@"Slow welcome fallback"] pressForDuration:0.2];
    cases = [self receiptWhere:^BOOL(NSDictionary *value) {
        return [value[@"slow"][@"finishes"] unsignedIntegerValue] == 1;
    } name:@"slow-confirmed"];
    [[self button:@"Fail pending welcome save"] tap];
    cases = [self receiptWhere:^BOOL(NSDictionary *value) {
        return [value[@"pending"][@"controls"] unsignedIntegerValue] == 1;
    } name:@"quick-slow-after-real-control"];
    [self assertCancelledTouch:cases[@"quick"] ends:1];
    [self assertCancelledTouch:cases[@"slow"] ends:1];
    XCTAssertEqual([cases[@"slow"][@"ackCalls"] unsignedIntegerValue], 1u);
    XCTAssertEqual([cases[@"slow"][@"settled"] unsignedIntegerValue], 1u);
    XCTAssertTrue([cases[@"slow"][@"acknowledged"] boolValue]);
    XCTAssertEqual([cases[@"quick"][@"finishes"] unsignedIntegerValue], 0u);
}

- (void)testWelcomeTouchFailureAndRejectionRequireAnotherExplicitGesture {
    for (NSString *scenario in @[@"retry-false", @"retry-reject"]) {
        NSString *label = [scenario isEqual:@"retry-false"] ? @"Retry refused welcome save" : @"Retry rejected welcome save";
        [[self button:label] tap];
        NSDictionary *cases = [self receiptWhere:^BOOL(NSDictionary *value) {
            return [value[scenario][@"settled"] unsignedIntegerValue] == 1 &&
                (![scenario isEqual:@"retry-reject"] || [value[scenario][@"rejections"] unsignedIntegerValue] == 1);
        } name:[scenario stringByAppendingString:@"-first"]];
        NSDictionary *record = cases[scenario];
        [self assertCancelledTouch:record ends:1];
        XCTAssertEqualObjects(record[@"status"], @"error");
        XCTAssertEqual([record[@"ackCalls"] unsignedIntegerValue], 1u);
        XCTAssertEqual([record[@"finishes"] unsignedIntegerValue], 0u);
        XCTAssertFalse([record[@"acknowledged"] boolValue]);
        XCTAssertEqual([record[@"rejections"] unsignedIntegerValue], [scenario isEqual:@"retry-reject"] ? 1u : 0u);

        [[self button:label] tap];
        cases = [self receiptWhere:^BOOL(NSDictionary *value) {
            return [value[scenario][@"finishes"] unsignedIntegerValue] == 1;
        } name:[scenario stringByAppendingString:@"-retry"]];
        record = cases[scenario];
        [self assertCancelledTouch:record ends:2];
        XCTAssertEqual([record[@"ackCalls"] unsignedIntegerValue], 2u);
        XCTAssertEqual([record[@"settled"] unsignedIntegerValue], 2u);
        XCTAssertTrue([record[@"acknowledged"] boolValue]);
    }

    XCUIElement *drag = [self button:@"Drag guarded welcome"];
    XCUICoordinate *start = [drag coordinateWithNormalizedOffset:CGVectorMake(0.5, 0.5)];
    CGRect dragFrame = drag.frame;
    CGPoint endPoint = CGPointMake(CGRectGetMinX(dragFrame) - 24, CGRectGetMidY(dragFrame));
    XCTAssertTrue(CGRectContainsPoint(self.app.frame, endPoint), @"the physical drag must end inside the screen");
    XCTAssertFalse(CGRectContainsPoint(dragFrame, endPoint), @"the drag must leave the button");
    [start pressForDuration:0.05 thenDragToCoordinate:
        [start coordinateWithOffset:CGVectorMake(endPoint.x - CGRectGetMidX(dragFrame), 0)]];
    NSDictionary *cases = [self receiptWhere:^BOOL(NSDictionary *value) {
        BOOL moved = [value[@"drag"][@"moves"] unsignedIntegerValue] > 0 ||
                     [value[@"drag"][@"cancels"] unsignedIntegerValue] > 0;
        BOOL released = [value[@"drag"][@"trustedEnds"] unsignedIntegerValue] > 0 ||
                        [value[@"drag"][@"cancels"] unsignedIntegerValue] > 0;
        return moved && released;
    } name:@"drag-rejected"];
    XCTAssertEqual([cases[@"drag"][@"ackCalls"] unsignedIntegerValue], 0u);
    XCTAssertEqual([cases[@"drag"][@"finishes"] unsignedIntegerValue], 0u);

    [[self button:@"Detached welcome fallback"] tap];
    cases = [self receiptWhere:^BOOL(NSDictionary *value) {
        return [value[@"cleaned"][@"trustedEnds"] unsignedIntegerValue] == 1 &&
               [value[@"cleaned"][@"naturalClicks"] unsignedIntegerValue] == 1;
    } name:@"cleaned-real-click"];
    // Observe a subsequent real input before asserting that the retained onclick
    // did not activate the disposed binder after the click capture receipt.
    [[self button:@"Fail pending welcome save"] tap];
    cases = [self receiptWhere:^BOOL(NSDictionary *value) {
        return [value[@"pending"][@"controls"] unsignedIntegerValue] == 1;
    } name:@"cleaned-inactive"];
    XCTAssertTrue([cases[@"cleaned"][@"disposed"] boolValue]);
    XCTAssertEqual([cases[@"cleaned"][@"naturalClicks"] unsignedIntegerValue], 1u);
    XCTAssertEqual([cases[@"cleaned"][@"preventedEnds"] unsignedIntegerValue], 0u);
    XCTAssertEqual([cases[@"cleaned"][@"ackCalls"] unsignedIntegerValue], 0u);
    XCTAssertEqual([cases[@"cleaned"][@"finishes"] unsignedIntegerValue], 0u);
    XCTAssertEqual([cases[@"drag"][@"ackCalls"] unsignedIntegerValue], 0u);
    for (NSString *scenario in @[@"retry-false", @"retry-reject"]) {
        [self assertCancelledTouch:cases[scenario] ends:2];
        XCTAssertEqual([cases[scenario][@"ackCalls"] unsignedIntegerValue], 2u);
        XCTAssertEqual([cases[scenario][@"finishes"] unsignedIntegerValue], 1u);
    }
}
@end
#endif
