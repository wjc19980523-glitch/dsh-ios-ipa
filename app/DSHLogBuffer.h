//
//  DSHLogBuffer.h
//  DSH
//
//  Bounded, thread-safe ring of log lines from the guest server process.
//

#import <Foundation/Foundation.h>

// Same definition as DSHHarnessAuth.h; see there for why a hosted test bundle
// cannot see an unexported C symbol.
#ifndef DSH_EXPORTED
#define DSH_EXPORTED __attribute__((visibility("default")))
#endif

NS_ASSUME_NONNULL_BEGIN

extern DSH_EXPORTED NSNotificationName const DSHLogBufferDidChangeNotification;

@interface DSHLogBuffer : NSObject

- (instancetype)initWithCapacity:(NSUInteger)capacity NS_DESIGNATED_INITIALIZER;
- (instancetype)initPersistentWithCapacity:(NSUInteger)capacity;
/// Injectable report directory, also used by persistence tests in isolation.
- (instancetype)initPersistentWithCapacity:(NSUInteger)capacity directory:(NSURL *)directory;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly) NSUInteger capacity;
@property (nonatomic, readonly) NSUInteger count;

/// Appends one line (trailing newlines stripped; noise lines the guest node
/// prints on every start are dropped). Posts DSHLogBufferDidChangeNotification
/// on the main queue.
- (void)append:(NSString *)line;
- (void)clear;

/// Snapshot of the retained lines, oldest first.
@property (nonatomic, readonly, copy) NSArray<NSString *> *lines;
/// The last `n` lines joined by "\n".
- (NSString *)tail:(NSUInteger)n;

/// A shareable report containing this launch and the retained launch logs.
/// Persistent buffers retain at most the ten most recent launches. Ordinary
/// in-memory buffers return their current lines only.
@property (nonatomic, readonly, copy) NSString *diagnosticReport;
@property (nonatomic, readonly, copy) NSString *diagnosticSummary;
@property (nonatomic, readonly) NSUInteger retainedIncidentCount;
/// A real, metadata-only UTF-8 attachment. No automatic upload. The caller
/// removes this URL after the share sheet finishes; stale attachments are
/// also pruned on the next export. Returns nil on an actual write failure.
- (nullable NSURL *)writeDiagnosticAttachmentWithError:(NSError * _Nullable * _Nullable)error;
/// Injectable owned temporary destination for isolated export tests.
- (nullable NSURL *)writeDiagnosticAttachmentInDirectory:(NSURL *)directory error:(NSError * _Nullable * _Nullable)error;
/// Explicitly clears this buffer's local launch reports and pinned incidents;
/// never touches guest files, preferences, credentials or workspaces.
- (void)clearRetainedDiagnostics;

/// Process identity is shared by every buffer in this process and never reused
/// after a system termination. It contains no guest credentials.
@property (class, nonatomic, readonly, copy) NSString *hostLaunchID;
@property (class, nonatomic, readonly) NSDate *hostProcessStartedAt;
@property (class, nonatomic, readonly, copy) NSString *hostProcessStartSource;
/// Flush a lifecycle boundary before iOS can suspend/terminate the process.
- (void)synchronizePersistentDiagnostics;

/// Lines that add nothing for the user (e.g. the V8 flag warning).
+ (BOOL)isNoiseLine:(NSString *)line;

@end

NS_ASSUME_NONNULL_END
