//
//  DSHTestHTTPServer.m
//  DSHTests
//

#import "DSHTestHTTPServer.h"
#import "DSHHarnessAuth.h"
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

@interface DSHTestHTTPServer ()
@property (nonatomic) int listenFD;
@property (nonatomic) dispatch_source_t source;
@property (nonatomic) dispatch_queue_t queue;
@property (nonatomic, readwrite) uint16_t port;
@property (atomic, readwrite) NSUInteger requestCount;
@property (atomic, readwrite) NSUInteger headRequestCount;
@property (atomic, readwrite) NSUInteger getRequestCount;
@property (atomic, readwrite) NSUInteger tokenExchangeCount;
@property (atomic, readwrite) NSUInteger unauthorizedCount;
@property (atomic, copy, readwrite, nullable) NSString *issuedCookieValue;
@property (nonatomic) NSString *cookieName;
@property (nonatomic) NSMutableSet<NSString *> *validCookieValues;
/// Sockets accepted while stalling, kept open so the client waits.
@property (nonatomic) NSMutableArray<NSNumber *> *stalledClients;
@end

@implementation DSHTestHTTPServer

- (instancetype)initWithPort:(uint16_t)port {
    if (self = [super init]) {
        _statusCode = 200;
        _stalledClients = [NSMutableArray array];
        // Cookies ignore TCP ports. Give every fixture its own installation
        // identity so NSURLSession's shared store cannot authenticate another
        // test's loopback server with a cookie left by a previous fixture.
        _cookieName = [DSHHarnessAuthCookiePrefix stringByAppendingString:NSUUID.UUID.UUIDString];
        _validCookieValues = [NSMutableSet set];
        _queue = dispatch_queue_create("dsh.test.http", DISPATCH_QUEUE_CONCURRENT);
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0)
            return nil;
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
        struct sockaddr_in addr = { .sin_len = sizeof(addr), .sin_family = AF_INET, .sin_port = htons(port), .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
        if (bind(fd, (struct sockaddr *) &addr, sizeof(addr)) < 0 || listen(fd, 16) < 0) {
            close(fd);
            return nil;
        }
        socklen_t len = sizeof(addr);
        getsockname(fd, (struct sockaddr *) &addr, &len);
        _port = ntohs(addr.sin_port);
        _listenFD = fd;
        _source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, fd, 0, _queue);
        __weak typeof(self) weakSelf = self;
        dispatch_source_set_event_handler(_source, ^{ [weakSelf acceptOne]; });
        dispatch_resume(_source);
    }
    return self;
}

- (NSURL *)baseURL {
    return [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%u/", self.port]];
}

- (void)acceptOne {
    int client = accept(self.listenFD, NULL, NULL);
    if (client < 0)
        return;
    self.requestCount++;
    if (self.stalls) {
        // Hold the socket open without answering. The connection is
        // established, so the client sees a live peer that never speaks --
        // exactly the shape of a timeout rather than a refusal.
        @synchronized (self.stalledClients) {
            [self.stalledClients addObject:@(client)];
        }
        return;
    }
    NSInteger status = self.statusCode;
    dispatch_async(self.queue, ^{
        char buf[4096];
        // Read the request head (best effort), then answer.
        ssize_t n = recv(client, buf, sizeof(buf) - 1, 0);
        NSString *request = nil;
        if (n > 0) {
            buf[n] = '\0';
            request = [NSString stringWithUTF8String:buf] ?: @"";
            if (strncmp(buf, "HEAD ", 5) == 0) self.headRequestCount++;
            else if (strncmp(buf, "GET ", 4) == 0) self.getRequestCount++;
        }

        if (self.requiresLaunchToken) {
            if (![self answerLaunchTokenRequest:request client:client])
                return;
        }

        NSString *body = @"ok";
        NSString *head = [NSString stringWithFormat:@"HTTP/1.1 %ld %@\r\nContent-Type: text/plain\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n%@",
                          (long) status, status == 200 ? @"OK" : @"Error", (unsigned long) body.length, body];
        const char *bytes = head.UTF8String;
        send(client, bytes, strlen(bytes), 0);
        close(client);
    });
}

/// Models dsh 0.2.x's authorizeIndex/writeUnauthorized pair on the first line
/// of the request. Returns YES when the caller still needs an ordinary answer
/// (it authenticated), NO when this method has already written the response.
- (BOOL)answerLaunchTokenRequest:(nullable NSString *)request client:(int)client {
    NSString *method = @"GET";
    NSString *target = @"/";
    NSArray<NSString *> *parts = [request componentsSeparatedByString:@" "];
    if (parts.count >= 2) {
        method = parts[0];
        target = parts[1];
    }

    NSString *cookie = [self cookieFromRequest:request];
    BOOL validCookie;
    @synchronized (self) {
        validCookie = cookie != nil && [self.validCookieValues containsObject:cookie];
    }
    if (validCookie) {
        // Already authenticated. The cookie survives a restart because dsh
        // signs it with a per-installation secret, so this is the steady state.
        return YES;
    }

    // The handshake: an exact token match on a GET mints the cookie.
    NSURLComponents *components = [NSURLComponents componentsWithString:[@"http://127.0.0.1" stringByAppendingString:target]];
    NSString *offered = nil;
    NSUInteger tokenParameters = 0;
    for (NSURLQueryItem *item in components.queryItems) {
        if ([item.name isEqualToString:DSHHarnessTokenQueryKey]) {
            tokenParameters++;
            offered = item.value;
        }
    }
    if ([method isEqualToString:@"GET"] && offered.length > 0 && self.launchToken.length > 0 &&
        tokenParameters == 1 && [offered isEqualToString:self.launchToken]) {
        NSString *value = [NSUUID UUID].UUIDString;
        @synchronized (self) {
            self.issuedCookieValue = value;
            [self.validCookieValues addObject:value];
            self.tokenExchangeCount++;
        }
        // 303 + `location: ./`, exactly as dsh answers the correct token.
        NSString *head = [NSString stringWithFormat:
            @"HTTP/1.1 303 See Other\r\n"
             "location: ./\r\n"
             "set-cookie: %@=%@; Max-Age=2592000; Path=/; Expires=Thu, 01 Jan 2099 00:00:00 GMT; HttpOnly; SameSite=Strict\r\n"
             "Content-Length: 0\r\nConnection: close\r\n\r\n",
            self.cookieName, value];
        send(client, head.UTF8String, strlen(head.UTF8String), 0);
        close(client);
        return NO;
    }

    // Everything else is refused, HEAD included, with dsh's own status. The
    // body is omitted for HEAD but the status is not.
    self.unauthorizedCount++;
    NSString *body = @"dsh web authentication required; reopen the URL printed by dsh web.\n";
    NSString *head = ([method isEqualToString:@"HEAD"])
        ? @"HTTP/1.1 401 Unauthorized\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\n"
        : [NSString stringWithFormat:@"HTTP/1.1 401 Unauthorized\r\nContent-Type: text/plain\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n%@",
                                     (unsigned long) body.length, body];
    send(client, head.UTF8String, strlen(head.UTF8String), 0);
    close(client);
    return NO;
}

- (nullable NSString *)cookieFromRequest:(nullable NSString *)request {
    if (request.length == 0)
        return nil;
    for (NSString *line in [request componentsSeparatedByString:@"\r\n"]) {
        if (![line.lowercaseString hasPrefix:@"cookie:"]) continue;
        for (NSString *part in [[line substringFromIndex:7] componentsSeparatedByString:@";"]) {
            NSString *pair = [part stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            NSString *prefix = [self.cookieName stringByAppendingString:@"="];
            if ([pair hasPrefix:prefix]) return [pair substringFromIndex:prefix.length];
        }
    }
    return nil;
}

- (void)stop {
    if (self.source) {
        dispatch_source_cancel(self.source);
        self.source = nil;
    }
    if (self.listenFD >= 0) {
        close(self.listenFD);
        self.listenFD = -1;
    }
    @synchronized (self.stalledClients) {
        for (NSNumber *fd in self.stalledClients)
            close(fd.intValue);
        [self.stalledClients removeAllObjects];
    }
}

- (void)dealloc {
    [self stop];
}

@end
