#import "ApolloAwardsListing.h"

static NSString *const kAwardsListingPathPattern = @"\\A/(?:r/[A-Za-z0-9_+]{1,128}/)?(?:(?:best|hot|new|top|rising|controversial)/?|comments/[a-z0-9]{1,16}(?:/[A-Za-z0-9_-]{0,256}){0,2}/?)?\\z";

NSURL *ApolloAwardsListingPageURL(NSURL *URL) {
    NSURLComponents *parts = [NSURLComponents componentsWithURL:URL resolvingAgainstBaseURL:NO];
    if (![parts.scheme.lowercaseString isEqualToString:@"https"] || parts.user || parts.password || parts.port ||
        ![@[@"oauth.reddit.com", @"www.reddit.com", @"reddit.com", @"old.reddit.com"] containsObject:parts.host.lowercaseString]) return nil;
    NSString *path = parts.path;
    if ([path hasSuffix:@".json"]) path = [path substringToIndex:path.length - 5];
    // Apollo and the modern personalized home page can rank entirely different
    // posts. A second home-page read then delays exact per-row reads without
    // warming their cache. Only mirror concrete subreddit/thread pages.
    if (![path hasPrefix:@"/r/"] && ![path hasPrefix:@"/comments/"]) return nil;
    if ([path rangeOfString:@"\\A/r/[A-Za-z0-9_+]{1,128}\\z" options:NSRegularExpressionSearch].location != NSNotFound) {
        path = [path stringByAppendingString:@"/"];
    }
    // Include pagination, but never mirror inbox, profiles, searches, writes,
    // or a URL supplied by post content. Those are different web contracts.
    if ([path rangeOfString:kAwardsListingPathPattern options:NSRegularExpressionSearch].location == NSNotFound) return nil;
    parts.host = @"sh.reddit.com";
    // Reddit's modern site canonicalizes a missing slash with a separate
    // redirect. Author its canonical URL so a warmup remains one round trip.
    parts.path = [path hasSuffix:@"/"] ? path : [path stringByAppendingString:@"/"];
    parts.fragment = nil;
    NSMutableArray *query = [NSMutableArray new];
    NSSet *allowed = [NSSet setWithArray:@[@"after", @"before", @"sort", @"t", @"limit", @"depth", @"context"]];
    for (NSURLQueryItem *item in parts.queryItems) {
        if ([allowed containsObject:item.name] && item.value.length > 0 && item.value.length <= 64 &&
            [item.value rangeOfString:@"\\A[A-Za-z0-9_]+\\z" options:NSRegularExpressionSearch].location != NSNotFound) {
            [query addObject:item];
        }
    }
    parts.queryItems = query.count ? query : nil;
    return parts.URL;
}

static NSArray<NSString *> *ApolloAwardsListingThreadIdentity(NSString *path) {
    NSString *pattern = @"\\A/(?:r/[A-Za-z0-9_+]{1,128}/)?comments/([a-z0-9]{1,16})(?:/[A-Za-z0-9_-]{0,256}(?:/([a-z0-9]{1,16}))?)?/?\\z";
    NSRegularExpression *expression = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
    NSTextCheckingResult *match = [expression firstMatchInString:path options:0 range:NSMakeRange(0, path.length)];
    if (!match) return nil;
    NSRange comment = [match rangeAtIndex:2];
    return @[[path substringWithRange:[match rangeAtIndex:1]],
             comment.location == NSNotFound ? @"" : [path substringWithRange:comment]];
}

BOOL ApolloAwardsListingAllowsRedirect(NSURL *source, NSURL *destination) {
    if (![source isKindOfClass:NSURL.class] || ![destination isKindOfClass:NSURL.class]) return NO;
    NSURLComponents *from = [NSURLComponents componentsWithURL:source resolvingAgainstBaseURL:NO];
    NSURLComponents *to = [NSURLComponents componentsWithURL:destination resolvingAgainstBaseURL:NO];
    for (NSURLComponents *parts in @[from, to]) {
        if (![parts.scheme.lowercaseString isEqualToString:@"https"] || parts.user || parts.password || parts.port ||
            ![@[@"sh.reddit.com", @"www.reddit.com"] containsObject:parts.host.lowercaseString] ||
            ![parts.path isEqualToString:parts.percentEncodedPath] ||
            [parts.path rangeOfString:kAwardsListingPathPattern options:NSRegularExpressionSearch].location == NSNotFound) return NO;
    }
    if (![(from.percentEncodedQuery ?: @"") isEqualToString:(to.percentEncodedQuery ?: @"")]) return NO;
    if ([from.path containsString:@"/comments/"] || [to.path containsString:@"/comments/"]) {
        NSArray *identity = ApolloAwardsListingThreadIdentity(from.path);
        return identity && [identity isEqualToArray:ApolloAwardsListingThreadIdentity(to.path)];
    }
    // NSURL.path normalizes the optional trailing slash on an ordinary feed.
    return [source.path isEqualToString:destination.path];
}

static void ApolloAwardsCollectThingIDs(id object, NSMutableSet *IDs, NSUInteger depth, NSUInteger *visited) {
    if (depth > 24 || *visited >= 2000 || IDs.count >= 500) return;
    (*visited)++;
    if ([object isKindOfClass:NSArray.class]) {
        for (id child in object) ApolloAwardsCollectThingIDs(child, IDs, depth + 1, visited);
    } else if ([object isKindOfClass:NSDictionary.class]) {
        id kind = object[@"kind"];
        id data = object[@"data"];
        if (![data isKindOfClass:NSDictionary.class]) return;
        if ([kind isEqual:@"t1"] || [kind isEqual:@"t3"]) {
            id name = data[@"name"];
            if ([name isKindOfClass:NSString.class] && [name length] <= 19 &&
                [name hasPrefix:[kind stringByAppendingString:@"_"]] &&
                [name rangeOfString:@"\\At[13]_[a-z0-9]{1,16}\\z" options:NSRegularExpressionSearch].location != NSNotFound) [IDs addObject:name];
            ApolloAwardsCollectThingIDs(data[@"replies"], IDs, depth + 1, visited);
        } else if ([kind isEqual:@"Listing"]) {
            ApolloAwardsCollectThingIDs(data[@"children"], IDs, depth + 1, visited);
        }
    }
}

NSSet<NSString *> *ApolloAwardsListingThingIDs(id object) {
    NSMutableSet *IDs = [NSMutableSet new];
    NSUInteger visited = 0;
    ApolloAwardsCollectThingIDs(object, IDs, 0, &visited);
    return [IDs copy];
}
