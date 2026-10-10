//
//  DSHHarness.h
//  DSH
//
//  Supervises the `dsh-serve` process inside the Linux guest: chooses the
//  loopback port, launches the server, waits until it answers HTTP, restarts
//  it with back-off when it dies, and publishes state for the UI.
//

#import <Foundation/Foundation.h>
#import "DSHLogBuffer.h"
#import "DSHReadinessProbe.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, DSHHarnessState) {
    DSHHarnessStateIdle = 0,   // never started
    DSHHarnessStateStarting,   // process launched, waiting for HTTP
    DSHHarnessStateReady,      // HTTP answered; UI may load
    DSHHarnessStateRestarting, // process exited, relaunch scheduled
    DSHHarnessStateFailed,     // gave up (too many crashes / launch error)
    DSHHarnessStateStopped,    // stopped on request
};

NSString *DSHHarnessStateName(DSHHarnessState state);

extern NSNotificationName const DSHHarnessStateDidChangeNotification;

/// Everything DSHHarness needs from the emulator, so tests can fake it.
@protocol DSHGuestProcessLauncher <NSObject>
/// Launches `executable` with `arguments` and `environment` as a child of
/// init. `line` receives every stdout/stderr line; `exit` fires once with the
/// exit code (negative on launch failure). Returns the guest pid, or a
/// negative error code if the process could not be created.
- (int)launchExecutable:(NSString *)executable
              arguments:(NSArray<NSString *> *)arguments
            environment:(NSDictionary<NSString *, NSString *> *)environment
                   line:(void (^)(NSString *line, BOOL isStdErr))line
                   exit:(void (^)(int exitCode))exit;
- (BOOL)killProcess:(int)pid signal:(int)signal;
@end

@interface DSHHarness : NSObject

+ (instancetype)shared;

- (instancetype)initWithLauncher:(id<DSHGuestProcessLauncher>)launcher NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly) DSHHarnessState state;
@property (nonatomic, readonly) uint16_t port;
/// http://127.0.0.1:<port>/ once a port is chosen (may be nil before start).
@property (nonatomic, readonly, nullable) NSURL *baseURL;
@property (nonatomic, readonly) DSHLogBuffer *log;
@property (nonatomic, readonly) NSUInteger restartCount;
@property (nonatomic, readonly, nullable) NSString *lastError;
@property (nonatomic, readonly) int guestPid;
@property (nonatomic, readonly) NSTimeInterval lastStartupDuration;
/// Expected time from launch to first HTTP answer, from previous runs on this
/// device (25 s until measured once). Used for the startup progress estimate.
@property (nonatomic, readonly) NSTimeInterval expectedStartupDuration;
/// When the current launch started (nil when not starting).
@property (nonatomic, readonly, nullable) NSDate *launchStartedAt;

/// Guest command that serves the web UI. Default /usr/local/bin/dsh-serve.
@property (nonatomic, copy) NSString *serverExecutable;
/// Extra environment passed to the server (DSH_PORT is always set).
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *extraEnvironment;
/// First port tried; default 3080. Up to 20 consecutive ports are probed.
@property (nonatomic) uint16_t preferredPort;
/// Seconds to wait for the first HTTP answer before declaring failure. Default 240.
@property (nonatomic) NSTimeInterval startupTimeout;
/// Consecutive crashes tolerated before giving up. Default 4.
@property (nonatomic) NSUInteger maxConsecutiveCrashes;
/// Budget for one foreground health check. Default 15. Deliberately generous:
/// the check runs through an emulated CPU that may be cold or busy right after
/// a resume, and a late answer is not a dead server.
@property (nonatomic) NSTimeInterval healthCheckTimeout;
/// Failed health checks in a row before the server is restarted. Default 3.
/// A single timeout must never cost a 40-second guest reboot.
@property (nonatomic) NSUInteger healthCheckFailuresBeforeRestart;
/// Delay between health-check retries. Default 2.
@property (nonatomic) NSTimeInterval healthCheckRetryDelay;
/// Failures retained across app launches inside the ten-minute crash-loop
/// window. Test harness instances do not write this production state.
@property (nonatomic, readonly) NSUInteger recentPersistentFailureCount;
/// Diagnostic detail of the most recent health check (nil before the first).
@property (nonatomic, readonly, nullable) DSHProbeResult *lastHealthCheck;
/// Consecutive health-check failures observed so far.
@property (nonatomic, readonly) NSUInteger healthCheckFailures;

- (void)start;
- (void)stop;
- (void)restart;

/// Runs a health check; if the server stopped answering while the process is
/// still up (should not happen) it is restarted. Safe to call on foreground.
///
/// Tolerates transient failures: a single timeout — routine right after the
/// app resumes, or while the emulated CPU is loaded — is logged and retried,
/// and only `healthCheckFailuresBeforeRestart` consecutive failures restart the
/// server. A failure that proves the listener is gone (connection refused or a
/// 5xx) restarts immediately, so real crashes still recover on the first try.
- (void)verifyAliveWithCompletion:(nullable void (^)(BOOL alive))completion;

@end

NS_ASSUME_NONNULL_END
