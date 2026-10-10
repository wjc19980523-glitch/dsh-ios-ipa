//
//  ISHShellExecutor.h
//  iSH
//
//  Shell execution interface with line-by-line output and process completion
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ISHShellExecutorError) {
    ISHShellExecutorErrorNone = 0,
    ISHShellExecutorErrorProcessCreationFailed = -1,
    ISHShellExecutorErrorExecFailed = -2,
    ISHShellExecutorErrorTimeout = -3,
    ISHShellExecutorErrorCancelled = -4,
};

@interface ISHShellExecutionResult : NSObject

/// Exit code of the shell process (0 = success)
@property (nonatomic, readonly) int exitCode;

/// Guest process PID
@property (nonatomic, readonly) int pid;

/// Error code if execution failed
@property (nonatomic, readonly) ISHShellExecutorError error;

/// Complete stdout output (all lines joined)
@property (nonatomic, readonly, copy) NSString *output;

/// Complete stderr output (all lines joined)
@property (nonatomic, readonly, copy) NSString *errorOutput;

/// Execution duration in seconds
@property (nonatomic, readonly) NSTimeInterval duration;

@end

/// Line callback block: called for each line of output
/// @param line The output line (without newline)
/// @param isStdErr YES if from stderr, NO if from stdout
typedef void (^ISHShellLineCallback)(NSString *line, BOOL isStdErr);

/// Completion callback block: called when process exits
/// @param result Execution result containing exit code and outputs
typedef void (^ISHShellCompletionCallback)(ISHShellExecutionResult *result);

@interface ISHShellExecutor : NSObject

/// Execute a shell command with line-by-line output callback
/// @param command Shell command to execute (will be passed to /bin/sh -c)
/// @param lineCallback Called for each line of output (on main queue), can be nil
/// @param completion Called when process exits (on main queue), can be nil
/// @return Guest process PID, or negative error code on failure
+ (int)executeCommand:(NSString *)command
         lineCallback:(nullable ISHShellLineCallback)lineCallback
           completion:(nullable ISHShellCompletionCallback)completion;

/// Execute a shell command with array of arguments
/// @param executable Path to executable (e.g., "/bin/ls")
/// @param arguments Array of arguments (e.g., @[@"-la", @"/tmp"])
/// @param environment Dictionary of environment variables (nil = default)
/// @param lineCallback Called for each line of output (on main queue), can be nil
/// @param completion Called when process exits (on main queue), can be nil
/// @return Guest process PID, or negative error code on failure
+ (int)executeExecutable:(NSString *)executable
               arguments:(nullable NSArray<NSString *> *)arguments
             environment:(nullable NSDictionary<NSString *, NSString *> *)environment
            lineCallback:(nullable ISHShellLineCallback)lineCallback
              completion:(nullable ISHShellCompletionCallback)completion;

/// Execute a shell command and wait synchronously for completion
/// @param command Shell command to execute
/// @param timeout Maximum wait time in seconds (0 = no timeout)
/// @param lineCallback Called for each line of output, can be nil
/// @return Execution result
+ (ISHShellExecutionResult *)executeCommandSync:(NSString *)command
                                        timeout:(NSTimeInterval)timeout
                                   lineCallback:(nullable ISHShellLineCallback)lineCallback;

/// Kill a running process
/// @param pid Guest process PID (returned from execute methods)
/// @param signal Signal to send (default: SIGKILL)
/// @return YES if process was found and signaled
+ (BOOL)killProcess:(int)pid withSignal:(int)signal;

#pragma mark - App lifecycle

/// Marks the guest kernel as booted, enabling the suspend/resume socket hooks.
/// Call once the kernel is up; before that there are no listening sockets to
/// preserve and the hooks' locking assumes a live kernel.
+ (void)setGuestBooted:(BOOL)booted;

/// Must be called when the app is about to be suspended.
///
/// iOS frees the underlying socket of every listening socket the process owns
/// while suspended, leaving the guest's `listen()` fd a socket in name only:
/// `accept()` can never return and a client can never connect. The guest side
/// of that is invisible to the guest, so a server started before the suspend
/// looks alive while being permanently unreachable -- which is what made the
/// harness restart a healthy `dsh-serve` on every return to the foreground.
///
/// This records the listening sockets so they can be recreated on resume.
/// See ish-arm64/fs/sockrestart.c and Apple TN2277.
///
/// @return YES if sockets were recorded. NO if there was nothing to do: the
///         guest is not booted, or a previous suspension has not been resumed
///         yet (a duplicate callback). Each log line says which.
+ (BOOL)handleAppSuspend;

/// Must be called when the app is resumed, before anything tries to use the
/// guest's network. Recreates the sockets recorded by -handleAppSuspend and
/// wakes any thread blocked on accept.
///
/// @return YES only if sockets were actually rebuilt, i.e. a real suspension
///         preceded this call. A plain launch, or the second of iOS's several
///         foreground notifications, returns NO and changes nothing. Callers
///         use this to decide whether the guest's network was invalidated.
+ (BOOL)handleAppResume;

/// Number of suspensions that actually recorded sockets since launch, and the
/// number of matching rebuilds. Equal counts mean every suspend was resumed.
/// Exposed so a bug report can show whether the lifecycle hooks ran at all --
/// which is precisely what could not be told from the earlier logs.
+ (NSUInteger)lifecycleSuspendCount;
+ (NSUInteger)lifecycleResumeCount;

@end

NS_ASSUME_NONNULL_END
