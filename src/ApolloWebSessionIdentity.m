#import "ApolloWebSessionIdentity.h"
#import <math.h>

ApolloWebSessionIdentityVerdict ApolloWebSessionClassifyIdentity(NSString *username,
    NSInteger statusCode, NSString *contentType, id json, NSError *error) {
    if (error || username.length == 0) return ApolloWebSessionIdentityInconclusive;
    NSString *mime = [[[contentType componentsSeparatedByString:@";"] firstObject]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].lowercaseString;
    // Reddit's edge can serve CAPTCHA/block pages with either successful or
    // error statuses. Those pages say nothing about the stored login.
    if ([mime isEqualToString:@"text/html"] || [mime isEqualToString:@"application/xhtml+xml"]) {
        return ApolloWebSessionIdentityInconclusive;
    }
    if (statusCode == 401 && [mime isEqualToString:@"application/json"]) {
        return ApolloWebSessionIdentityUnavailable;
    }
    if (statusCode != 200 || ![json isKindOfClass:[NSDictionary class]]) {
        return ApolloWebSessionIdentityInconclusive;
    }
    // /api/me.json returns {} for an anonymous session. A different response
    // shape is not equivalent to that explicit signed-out result.
    if ([json count] == 0) return ApolloWebSessionIdentityUnavailable;
    id user = json[@"data"];
    id name = [user isKindOfClass:[NSDictionary class]] ? user[@"name"] : nil;
    if (![name isKindOfClass:[NSString class]] || [name length] == 0) {
        return ApolloWebSessionIdentityInconclusive;
    }
    return [name caseInsensitiveCompare:username] == NSOrderedSame
        ? ApolloWebSessionIdentityMatches : ApolloWebSessionIdentityUnavailable;
}

ApolloWebSessionIdentityVerdict ApolloWebSessionClassifyBrowserIdentity(NSString *username,
    id result, NSError *error) {
    if (error || ![result isKindOfClass:[NSDictionary class]]) return ApolloWebSessionIdentityInconclusive;
    id status = result[@"status"];
    id contentType = result[@"contentType"];
    if (![status isKindOfClass:[NSNumber class]] || ![contentType isKindOfClass:[NSString class]]) {
        return ApolloWebSessionIdentityInconclusive;
    }
    double number = [status doubleValue];
    if (!isfinite(number) || number < 100 || number > 599 || number != floor(number)) {
        return ApolloWebSessionIdentityInconclusive;
    }
    return ApolloWebSessionClassifyIdentity(username, [status integerValue], contentType, result[@"json"], nil);
}
