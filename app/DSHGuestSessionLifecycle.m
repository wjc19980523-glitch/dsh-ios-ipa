#import "DSHGuestSessionLifecycle.h"
#import "DSHHostBridge.h"
#include <limits.h>
#include <math.h>

static BOOL integerValue(id value, int64_t minimum, int64_t maximum, int64_t *result) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NO;
    double number = [value doubleValue];
    if (!isfinite(number) || floor(number) != number || number < minimum || number > maximum) return NO;
    if (result) *result = (int64_t)number;
    return YES;
}

static NSDictionary *phaseDiagnostics(id presented) {
    if (!presented) return @{};
    NSArray *allowed = @[@"checkpoint_read_ms", @"checkpoint_hash_ms", @"checkpoint_serialized_bytes",
        @"drain_ms", @"close_ms", @"acquire_ms", @"active_writer_transitions", @"peak_writer_transitions", @"transition_ms",
        @"prepared_verified_count", @"background_full_decode_count", @"raw_verified_bytes"];
    if (![presented isKindOfClass:NSDictionary.class] || [presented count] > allowed.count) return nil;
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    for (id key in presented) {
        int64_t value;
        if (![allowed containsObject:key] || !integerValue(presented[key], 0, INT64_C(9007199254740991), &value)) return nil;
        values[key] = @(value);
    }
    return values;
}

@interface DSHGuestSessionTransition : NSObject
@property (nonatomic) uint64_t generation;
@property (nonatomic) uint64_t guestIdentity;
@property (nonatomic) BOOL resolved;
@property (nonatomic) BOOL result;
@property (nonatomic, copy) void (^completion)(BOOL);
@end
@implementation DSHGuestSessionTransition
@end

@interface DSHGuestSessionPoll : NSObject
@property (nonatomic) uint64_t guestIdentity;
@end
@implementation DSHGuestSessionPoll
@end

@interface DSHGuestSessionLifecycle ()
@property (nonatomic) NSCondition *condition;
@property (nonatomic, copy) DSHGuestSessionLifecycleMainScheduler mainScheduler;
@property (nonatomic) int managedPID;
@property (nonatomic) uint64_t guestIdentity;
@property (nonatomic) BOOL guestRegistered;
@property (nonatomic, nullable) DSHGuestSessionPoll *activePoll;
@property (nonatomic) uint64_t commandGeneration;
@property (nonatomic, copy) NSString *desiredState;
@property (nonatomic, nullable) DSHGuestSessionTransition *transition;
@property (nonatomic) uint64_t ackGeneration;
@property (nonatomic, copy) NSString *ackState;
@property (nonatomic, copy) NSDictionary *ackCounts;
@property (nonatomic, copy) NSDictionary *ackDiagnostics;
@property (nonatomic) uint64_t progressGeneration;
@property (nonatomic, copy) NSDictionary *progressDiagnostics;
@property (nonatomic, copy, nullable) NSString *errorCode;
@end

@implementation DSHGuestSessionLifecycle
+ (instancetype)shared {
    static DSHGuestSessionLifecycle *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [self new]; });
    return instance;
}
- (instancetype)init {
    return [self initWithMainScheduler:^(dispatch_block_t action) {
        dispatch_async(dispatch_get_main_queue(), action);
    } condition:[NSCondition new]];
}
- (instancetype)initWithMainScheduler:(DSHGuestSessionLifecycleMainScheduler)scheduler condition:(NSCondition *)condition {
    if ((self = [super init])) {
        _condition = condition;
        _mainScheduler = [scheduler copy];
        _desiredState = @"running";
        _ackState = @"none";
        _ackCounts = @{};
        _ackDiagnostics = @{};
        _progressDiagnostics = @{};
    }
    return self;
}
- (void)installOnBridge:(DSHHostBridge *)bridge {
    __weak typeof(self) weakSelf = self;
    // DSHHostBridge authenticates the bearer token before invoking either
    // infrastructure handler. Never persist request bodies or arbitrary errors.
    [bridge registerRoute:@"POST" path:@"/v1/lifecycle/poll" capability:nil handler:^DSHHostBridgeResponse *(DSHHostBridgeRequest *request) {
        return [weakSelf poll:request] ?: [DSHHostBridgeResponse errorWithStatus:503 code:@"unavailable" message:@"session coordinator unavailable" recoverable:YES];
    }];
    [bridge registerRoute:@"POST" path:@"/v1/lifecycle/ack" capability:nil handler:^DSHHostBridgeResponse *(DSHHostBridgeRequest *request) {
        return [weakSelf acknowledge:request] ?: [DSHHostBridgeResponse errorWithStatus:503 code:@"unavailable" message:@"session coordinator unavailable" recoverable:YES];
    }];
}
- (void)enqueueDelivery:(DSHGuestSessionTransition *)transition {
    self.mainScheduler(^{
        void (^completion)(BOOL) = nil;
        [self.condition lock];
        // Resolving an HTTP ACK is not permission to invoke an obsolete UIKit
        // callback. Revalidate at delivery, including absent/exit fast paths.
        if (self.transition == transition && transition.resolved &&
            transition.generation == self.commandGeneration && transition.guestIdentity == self.guestIdentity) {
            completion = transition.completion;
            self.transition = nil;
        }
        [self.condition unlock];
        if (completion) completion(transition.result);
    });
}
- (uint64_t)managedGuestDidLaunch:(int)pid {
    NSAssert(NSThread.isMainThread, @"managed guest lifecycle on main");
    if (pid <= 0) return 0;
    [self.condition lock];
    self.managedPID = pid;
    self.guestIdentity++; // Same numeric PID can represent a different process.
    self.guestRegistered = NO;
    self.activePoll = nil;
    self.commandGeneration++;
    self.desiredState = @"running";
    self.transition = nil;
    self.ackGeneration = 0;
    self.ackState = @"none";
    self.ackCounts = @{};
    self.ackDiagnostics = @{};
    self.progressGeneration = 0;
    self.progressDiagnostics = @{};
    self.errorCode = nil;
    uint64_t identity = self.guestIdentity;
    [self.condition broadcast];
    [self.condition unlock];
    return identity;
}
- (void)managedGuestDidExit:(int)pid identity:(uint64_t)identity {
    NSAssert(NSThread.isMainThread, @"managed guest lifecycle on main");
    DSHGuestSessionTransition *delivery = nil;
    [self.condition lock];
    if (pid > 0 && pid == self.managedPID && identity > 0 && identity == self.guestIdentity) {
        DSHGuestSessionTransition *pending = self.transition;
        self.managedPID = 0;
        self.guestIdentity++;
        self.guestRegistered = NO;
        self.activePoll = nil;
        self.commandGeneration++;
        self.transition = nil;
        self.ackState = @"exited";
        if (pending) {
            // The exited process cannot reacquire a lease. Carry its pending
            // completion into a new delivery identity, invalidating any ACK
            // callback already queued for that process. A subsequent launch
            // still invalidates this delivery before it can reach the caller.
            delivery = [DSHGuestSessionTransition new];
            delivery.generation = self.commandGeneration;
            delivery.guestIdentity = self.guestIdentity;
            delivery.completion = pending.completion;
            delivery.resolved = YES;
            delivery.result = YES;
            self.transition = delivery;
        }
        [self.condition broadcast];
    }
    [self.condition unlock];
    if (delivery) [self enqueueDelivery:delivery];
}
- (BOOL)registered {
    [self.condition lock]; BOOL value = self.guestRegistered; [self.condition unlock]; return value;
}
- (int)managedGuestPID {
    [self.condition lock]; int value = self.managedPID; [self.condition unlock]; return value;
}
- (BOOL)transitionPending {
    [self.condition lock]; BOOL value = self.transition != nil; [self.condition unlock]; return value;
}
- (NSDictionary *)diagnosticSnapshot {
    [self.condition lock];
    NSDictionary *value = @{@"managed_guest_pid": @(self.managedPID), @"guest_identity": @(self.guestIdentity),
        @"registered": @(self.guestRegistered), @"generation": @(self.commandGeneration),
        @"desired_state": self.desiredState, @"ack_generation": @(self.ackGeneration), @"ack_state": self.ackState,
        @"transition_pending": @(self.transition != nil), @"poll_pending": @(self.activePoll != nil),
        @"counts": self.ackCounts, @"diagnostics": self.ackDiagnostics,
        @"progress_generation": @(self.progressGeneration), @"progress_diagnostics": self.progressDiagnostics,
        @"error_code": self.errorCode ?: @"none"};
    [self.condition unlock];
    return value;
}
- (void)transitionTo:(NSString *)state completion:(void (^)(BOOL))completion {
    NSAssert(NSThread.isMainThread, @"session transitions on main");
    [self.condition lock];
    self.commandGeneration++;
    self.desiredState = state;
    self.progressGeneration = 0;
    self.progressDiagnostics = @{};
    DSHGuestSessionTransition *transition = [DSHGuestSessionTransition new];
    transition.generation = self.commandGeneration;
    transition.guestIdentity = self.guestIdentity;
    transition.completion = completion;
    transition.resolved = self.managedPID <= 0;
    transition.result = transition.resolved;
    self.transition = transition;
    self.errorCode = nil;
    [self.condition broadcast];
    [self.condition unlock];
    if (transition.resolved) [self enqueueDelivery:transition];
}
- (void)prepareForBackgroundWithCompletion:(void (^)(BOOL))completion { [self transitionTo:@"quiescing" completion:completion]; }
- (void)resumeWithCompletion:(void (^)(BOOL))completion { [self transitionTo:@"running" completion:completion]; }
- (void)cancelPendingTransition {
    NSAssert(NSThread.isMainThread, @"session cancellation on main");
    [self.condition lock];
    self.commandGeneration++;
    self.transition = nil;
    [self.condition broadcast];
    [self.condition unlock];
}
- (DSHHostBridgeResponse *)invalid {
    return [DSHHostBridgeResponse errorWithStatus:400 code:@"invalid_request" message:@"invalid lifecycle metadata" recoverable:NO];
}
- (DSHHostBridgeResponse *)stale {
    return [DSHHostBridgeResponse errorWithStatus:409 code:@"lifecycle_stale" message:@"lifecycle identity is no longer current" recoverable:YES];
}
- (DSHHostBridgeResponse *)poll:(DSHHostBridgeRequest *)request {
    int64_t pid, after = -1, wait = 15000;
    NSDictionary *body = request.json;
    if (!integerValue(body[@"pid"], 1, INT_MAX, &pid) ||
        (body[@"after_generation"] && !integerValue(body[@"after_generation"], -1, INT64_C(9007199254740991), &after)) ||
        (body[@"wait_ms"] && !integerValue(body[@"wait_ms"], 0, 15000, &wait))) return self.invalid;
    BOOL hasProgress = body[@"progress_generation"] != nil || body[@"diagnostics"] != nil;
    int64_t progress = 0;
    NSDictionary *diagnostics = hasProgress ? phaseDiagnostics(body[@"diagnostics"]) : nil;
    if (hasProgress && (!body[@"diagnostics"] || !diagnostics ||
        !integerValue(body[@"progress_generation"], 0, INT64_C(9007199254740991), &progress))) return self.invalid;
    [self.condition lock];
    if (pid != self.managedPID || after > (int64_t)self.commandGeneration) { [self.condition unlock]; return self.stale; }
    if (self.activePoll) {
        [self.condition unlock];
        return [DSHHostBridgeResponse errorWithStatus:429 code:@"lifecycle_poll_active" message:@"a lifecycle poll is already pending" recoverable:YES];
    }
    DSHGuestSessionPoll *poll = [DSHGuestSessionPoll new];
    poll.guestIdentity = self.guestIdentity;
    self.activePoll = poll;
    BOOL first = !self.guestRegistered;
    self.guestRegistered = YES;
    if (hasProgress && progress == (int64_t)self.commandGeneration && !first) {
        self.progressGeneration = (uint64_t)progress;
        self.progressDiagnostics = diagnostics;
    }
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:wait / 1000.0];
    while (!first && after == (int64_t)self.commandGeneration && pid == self.managedPID &&
           poll.guestIdentity == self.guestIdentity && self.activePoll == poll && wait > 0)
        if (![self.condition waitUntilDate:deadline]) break;
    // A prior guest's wake must never clear a new guest's outstanding request.
    if (self.activePoll == poll) self.activePoll = nil;
    if (pid != self.managedPID || poll.guestIdentity != self.guestIdentity) { [self.condition unlock]; return self.stale; }
    NSDictionary *answer = @{@"protocol": @1, @"generation": @(self.commandGeneration), @"state": self.desiredState};
    [self.condition unlock];
    return [DSHHostBridgeResponse ok:answer];
}
- (DSHHostBridgeResponse *)acknowledge:(DSHHostBridgeRequest *)request {
    NSDictionary *body = request.json;
    int64_t pid, generation;
    NSString *state = body[@"state"];
    if (!integerValue(body[@"pid"], 1, INT_MAX, &pid) ||
        !integerValue(body[@"generation"], 0, INT64_C(9007199254740991), &generation) ||
        ![state isKindOfClass:NSString.class] || ![@[@"running", @"quiesced", @"failed"] containsObject:state]) return self.invalid;
    NSMutableDictionary *counts = [NSMutableDictionary new];
    for (NSString *key in @[@"writer_count", @"released_count", @"pending_events"]) {
        int64_t value;
        if (!integerValue(body[key], 0, INT64_C(9007199254740991), &value)) return self.invalid;
        counts[key] = @(value);
    }
    if ([counts[@"released_count"] longLongValue] > [counts[@"writer_count"] longLongValue] ||
        ([state isEqual:@"quiesced"] && ![counts[@"released_count"] isEqual:counts[@"writer_count"]])) return self.invalid;
    NSDictionary *diagnostics = phaseDiagnostics(body[@"diagnostics"]);
    if (!diagnostics) return self.invalid;
    NSString *presentedCode = body[@"error_code"];
    NSString *code = [state isEqual:@"failed"] ?
        ([presentedCode isKindOfClass:NSString.class] &&
         [@[@"checkpoint_changed", @"not_materialized", @"ownership_conflict", @"storage_failure", @"close_failure", @"transition_failed"] containsObject:presentedCode]
         ? presentedCode : @"transition_failed") : nil;
    DSHGuestSessionTransition *delivery = nil;
    [self.condition lock];
    BOOL expectedState = [state isEqual:@"failed"] ||
        ([self.desiredState isEqual:@"running"] && [state isEqual:@"running"]) ||
        ([self.desiredState isEqual:@"quiescing"] && [state isEqual:@"quiesced"]);
    if (pid != self.managedPID || !self.guestRegistered || generation != self.commandGeneration || !expectedState) {
        [self.condition unlock]; return self.stale;
    }
    BOOL duplicate = generation == self.ackGeneration && ![self.ackState isEqual:@"none"];
    if (duplicate) {
        BOOL identical = [state isEqual:self.ackState] && [counts isEqual:self.ackCounts] && [diagnostics isEqual:self.ackDiagnostics] &&
            (code == self.errorCode || [code isEqual:self.errorCode]);
        [self.condition unlock];
        return identical ? [DSHHostBridgeResponse ok:@{@"generation": @(generation), @"accepted": @YES}] : self.stale;
    }
    self.ackGeneration = generation;
    self.ackState = state;
    self.ackCounts = [counts copy];
    self.ackDiagnostics = [diagnostics copy];
    self.errorCode = code;
    if (self.transition && !self.transition.resolved) {
        delivery = self.transition;
        delivery.resolved = YES;
        delivery.result = ![state isEqual:@"failed"];
    }
    [self.condition unlock];
    if (delivery) [self enqueueDelivery:delivery];
    return [DSHHostBridgeResponse ok:@{@"generation": @(generation), @"accepted": @YES}];
}
@end
