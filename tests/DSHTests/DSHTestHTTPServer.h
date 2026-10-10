//
//  DSHTestHTTPServer.h
//  DSHTests
//
//  Tiny loopback HTTP server (answers every request with 200) so unit tests
//  can drive DSHReadinessProbe / DSHHarness without the Linux guest.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DSHTestHTTPServer : NSObject
/// Binds 127.0.0.1:port (0 = ephemeral) and starts accepting. Returns nil on failure.
- (nullable instancetype)initWithPort:(uint16_t)port;
@property (nonatomic, readonly) uint16_t port;
@property (nonatomic, readonly) NSURL *baseURL;
@property (atomic) NSInteger statusCode;   // default 200
@property (atomic, readonly) NSUInteger requestCount;
/// Accept the connection but never write a response. Simulates the emulator's
/// guest being wedged mid-boot, which is what a too-short health-check timeout
/// misreads as "the server is dead".
@property (atomic) BOOL stalls;
/// Count of requests that arrived with a HEAD method, so tests can assert the
/// probe actually used the cheap method.
@property (atomic, readonly) NSUInteger headRequestCount;
/// Count of requests that arrived with a GET method (the fallback path).
@property (atomic, readonly) NSUInteger getRequestCount;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
