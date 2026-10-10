//
//  DSHHarnessAuth.m
//  DSH
//
//  See DSHHarnessAuth.h for why this exists.
//

#import "DSHHarnessAuth.h"

// DSH_EXPORTED (see the header) is what lets the DSHTests bundle resolve these
// against the host app. Without it the sources compile and the link fails.
DSH_EXPORTED NSString *const DSHHarnessTokenQueryKey = @"token";
DSH_EXPORTED NSString *const DSHHarnessAuthCookiePrefix = @"dsh-auth-";

/// The token is base64url over 32 random bytes: 43 characters from
/// [A-Za-z0-9_-]. Scanning that alphabet rather than reading to end of line is
/// deliberate -- dsh's announcement can be followed by a terminal reset
/// sequence, a full stop, or nothing at all.
static NSString *const kTokenAlphabet = @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-";

@implementation DSHHarnessAuth

+ (nullable NSString *)tokenFromServeLogLine:(NSString *)line {
    if (line.length == 0)
        return nil;
    // Cheap reject first: the announcement always spells the parameter out.
    NSRange key = [line rangeOfString:[DSHHarnessTokenQueryKey stringByAppendingString:@"="]
                              options:NSCaseInsensitiveSearch];
    if (key.location == NSNotFound)
        return nil;

    NSUInteger start = NSMaxRange(key);
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:kTokenAlphabet];
    NSRange rest = NSMakeRange(start, line.length - start);
    NSRange tokenRange = [line rangeOfCharacterFromSet:allowed.invertedSet options:0 range:rest];
    NSUInteger end = tokenRange.location == NSNotFound ? line.length : tokenRange.location;

    if (end <= start)
        return nil;
    return [line substringWithRange:NSMakeRange(start, end - start)];
}

+ (BOOL)isServeAnnouncementLine:(NSString *)line {
    if (line.length == 0)
        return NO;
    return [line rangeOfString:@"dsh web" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

+ (NSString *)redactingTokenInLine:(NSString *)line {
    if (line.length == 0)
        return line;
    NSRange key = [line rangeOfString:[DSHHarnessTokenQueryKey stringByAppendingString:@"="]
                              options:NSCaseInsensitiveSearch];
    if (key.location == NSNotFound)
        return line;

    NSMutableString *safe = [line mutableCopy];
    NSRange search = NSMakeRange(0, safe.length);
    while (search.length > 0) {
        NSRange hit = [safe rangeOfString:[DSHHarnessTokenQueryKey stringByAppendingString:@"="]
                                  options:NSCaseInsensitiveSearch
                                    range:search];
        if (hit.location == NSNotFound)
            break;
        NSUInteger start = NSMaxRange(hit);
        NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:kTokenAlphabet];
        NSRange rest = NSMakeRange(start, safe.length - start);
        NSRange stop = [safe rangeOfCharacterFromSet:allowed.invertedSet options:0 range:rest];
        NSUInteger end = stop.location == NSNotFound ? safe.length : stop.location;
        if (end > start)
            [safe replaceCharactersInRange:NSMakeRange(start, end - start) withString:@"<redacted>"];
        // Step past this occurrence; a line only ever carries one, but looping
        // keeps this correct for a diagnostic dump of several concatenated.
        NSUInteger next = MIN(NSMaxRange(hit) + 1, safe.length);
        search = NSMakeRange(next, safe.length - next);
    }
    return safe;
}

+ (nullable NSURL *)authenticatedEntryURLWithBaseURL:(NSURL *)baseURL token:(nullable NSString *)token {
    if (baseURL == nil || token.length == 0)
        return nil;
    NSURLComponents *components = [NSURLComponents componentsWithURL:baseURL resolvingAgainstBaseURL:NO];
    if (components == nil)
        return nil;
    NSMutableArray<NSURLQueryItem *> *items = [components.queryItems mutableCopy] ?: [NSMutableArray array];
    // Replace rather than append: a stale token from a previous incarnation
    // must not be preserved alongside the current one, or the server would see
    // two values for `token` and refuse.
    [items filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSURLQueryItem *item, NSDictionary *bindings) {
        return ![item.name isEqualToString:DSHHarnessTokenQueryKey];
    }]];
    [items addObject:[NSURLQueryItem queryItemWithName:DSHHarnessTokenQueryKey value:token]];
    components.queryItems = items;
    return components.URL;
}

+ (BOOL)url:(nullable NSURL *)a sharesAuthorityWith:(nullable NSURL *)b {
    if (a == nil || b == nil)
        return NO;
    if (![a.scheme isEqualToString:b.scheme])
        return NO;
    if (![a.host isEqualToString:b.host])
        return NO;
    // A nil port and an explicit default port are the same authority. dsh
    // always listens on a real port, so the default fallback is defensive.
    NSNumber *defaultPort = [a.scheme.lowercaseString isEqualToString:@"https"] ? @443 : @80;
    NSNumber *pa = a.port ?: defaultPort;
    NSNumber *pb = b.port ?: defaultPort;
    return [pa isEqualToNumber:pb];
}

+ (BOOL)token:(nullable NSString *)a isEqualToToken:(nullable NSString *)b {
    if (a == nil && b == nil)
        return YES;
    if (a == nil || b == nil)
        return NO;
    return [a isEqualToString:b];
}

@end
