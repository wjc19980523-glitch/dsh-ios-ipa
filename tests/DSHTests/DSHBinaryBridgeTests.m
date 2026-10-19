#import <XCTest/XCTest.h>
#import "DSHHostBridge.h"
#import "DSHCapability.h"
#include <arpa/inet.h>
#include <sys/socket.h>
#include <unistd.h>

@interface DSHBinaryBridgeTests : XCTestCase
@property DSHHostBridge *bridge;
@end
@implementation DSHBinaryBridgeTests
- (void)setUp {
    [super setUp]; self.bridge=[DSHHostBridge new]; XCTAssertTrue([self.bridge start]);
    [DSHCapabilityRegistry.shared registerCapability:[[DSHCapability alloc] initWithIdentifier:@"tests.binary.export" title:@"test" details:@"test" gate:DSHCapabilityGateEnabledOnly enabledByDefault:YES available:YES]];
    [DSHCapabilityRegistry.shared setEnabled:YES forIdentifier:@"tests.binary.export"];
    [self.bridge registerBinaryRoute:@"PUT" path:@"/test/binary" capability:@"tests.binary.export" maximumBytes:128*1024 handler:^DSHHostBridgeResponse *(DSHHostBridgeRequest *request) {
        XCTAssertNil(request.json); XCTAssertNotNil(request.binaryBody);
        return [DSHHostBridgeResponse ok:@{@"bytes":@(request.binaryBody.length),@"first":@(((const uint8_t *)request.binaryBody.bytes)[0])}];
    }];
}
- (void)tearDown { [self.bridge stop]; [super tearDown]; }
- (NSDictionary *)request:(NSData *)body token:(NSString *)token type:(NSString *)type {
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:[self.bridge.baseURLString stringByAppendingString:@"/test/binary"]]];
    request.HTTPMethod=@"PUT"; request.HTTPBody=body; request.timeoutInterval=8;
    if(token) [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    [request setValue:type forHTTPHeaderField:@"Content-Type"];
    XCTestExpectation *done=[self expectationWithDescription:@"binary response"];
    __block NSDictionary *result;
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data,NSURLResponse *response,NSError *error) {
        XCTAssertNil(error); result=@{@"status":@(((NSHTTPURLResponse *)response).statusCode),@"body":data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] ?: @{} : @{}}; [done fulfill];
    }] resume];
    [self waitForExpectations:@[done] timeout:12]; return result;
}
- (void)testActualBinaryWithNulAndNonUTF8CrossesSocketWithoutJSON {
    const uint8_t raw[]={0xff,0x00,0x80,0x7f,0x01};
    NSDictionary *result=[self request:[NSData dataWithBytes:raw length:sizeof(raw)] token:self.bridge.token type:@"application/octet-stream"];
    XCTAssertEqualObjects(result[@"status"],@200); XCTAssertEqualObjects(result[@"body"][@"bytes"],@5); XCTAssertEqualObjects(result[@"body"][@"first"],@255);
}
- (void)testBinaryRouteRetainsAuthenticationAndCapabilityGate {
    NSData *data=[NSData dataWithBytes:"x" length:1];
    XCTAssertEqualObjects([self request:data token:nil type:@"application/octet-stream"][@"status"],@401);
    [DSHCapabilityRegistry.shared setEnabled:NO forIdentifier:@"tests.binary.export"];
    XCTAssertEqualObjects([self request:data token:self.bridge.token type:@"application/octet-stream"][@"status"],@403);
}
- (void)testBinaryRouteRejectsWrongContentTypeAndOversizedBody {
    NSData *data=[NSData dataWithBytes:"x" length:1];
    XCTAssertEqualObjects([self request:data token:self.bridge.token type:@"application/json"][@"status"],@400);
    XCTAssertEqualObjects([self request:[NSMutableData dataWithLength:128*1024+1] token:self.bridge.token type:@"application/octet-stream"][@"status"],@413);
}
- (void)testDisconnectedUploaderDoesNotTerminateTheHostWhenReplying {
    XCTestExpectation *entered=[self expectationWithDescription:@"request reached handler"];
    dispatch_semaphore_t release=dispatch_semaphore_create(0);
    [self.bridge registerBinaryRoute:@"PUT" path:@"/test/disconnect" capability:@"tests.binary.export" maximumBytes:1 handler:^DSHHostBridgeResponse *(DSHHostBridgeRequest *request) {
        [entered fulfill];
        dispatch_semaphore_wait(release,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC));
        return [DSHHostBridgeResponse status:200 contentType:@"application/octet-stream" rawBody:[NSMutableData dataWithLength:256*1024]];
    }];
    int fd=socket(AF_INET,SOCK_STREAM,0); XCTAssertGreaterThanOrEqual(fd,0); if(fd<0) return;
    struct sockaddr_in address={.sin_len=sizeof(address),.sin_family=AF_INET,.sin_port=htons(self.bridge.port),.sin_addr.s_addr=htonl(INADDR_LOOPBACK)};
    int connected=connect(fd,(struct sockaddr *)&address,sizeof(address)); XCTAssertEqual(connected,0);
    if(connected!=0) { close(fd); return; }
    NSString *header=[NSString stringWithFormat:@"PUT /test/disconnect HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer %@\r\nContent-Type: application/octet-stream\r\nContent-Length: 1\r\n\r\nx",self.bridge.token];
    NSData *bytes=[header dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertEqual(send(fd,bytes.bytes,bytes.length,0),(ssize_t)bytes.length);
    [self waitForExpectations:@[entered] timeout:4];
    struct linger reset={.l_onoff=1,.l_linger=0}; setsockopt(fd,SOL_SOCKET,SO_LINGER,&reset,sizeof(reset)); close(fd);
    dispatch_semaphore_signal(release);
    XCTestExpectation *settled=[self expectationWithDescription:@"disconnected reply settled"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC/10),dispatch_get_main_queue(),^{[settled fulfill];});
    [self waitForExpectations:@[settled] timeout:2];
    XCTAssertEqualObjects([self request:[NSData dataWithBytes:"z" length:1] token:self.bridge.token type:@"application/octet-stream"][@"status"],@200);
}
@end
