#import <Foundation/Foundation.h>
#import "ApolloAwardsListing.h"

static int sFailures;
static int sChecks;
#define CHECK(condition, ...) do { \
    sChecks++; \
    if (!(condition)) { sFailures++; fprintf(stderr, "FAIL line %d: %s\n", __LINE__, \
        [NSString stringWithFormat:__VA_ARGS__].UTF8String); } \
} while (0)

static NSURL *Page(NSString *URL) {
    return ApolloAwardsListingPageURL([NSURL URLWithString:URL]);
}

static NSDictionary *Thing(NSString *kind, id name) {
    return @{@"kind": kind, @"data": @{@"name": name}};
}

static NSDictionary *Listing(NSArray *children) {
    return @{@"kind": @"Listing", @"data": @{@"children": children}};
}

static void TestReadRoutes(void) {
    NSDictionary *routes = @{
        @"/r/test/hot": @"/r/test/hot/", @"/r/test/new/": @"/r/test/new/", @"/r/test/top.json": @"/r/test/top/",
        @"/r/test/rising/.json": @"/r/test/rising/", @"/r/test/controversial/": @"/r/test/controversial/",
        @"/r/test/best": @"/r/test/best/", @"/r/test/best.json": @"/r/test/best/",
        @"/r/apollo/": @"/r/apollo/", @"/r/apollo": @"/r/apollo/",
        @"/r/apollo.json": @"/r/apollo/", @"/r/apollo/.json": @"/r/apollo/",
        @"/r/apollo/hot.json": @"/r/apollo/hot/", @"/r/apollo/best": @"/r/apollo/best/",
        @"/r/Apollo_Reborn+ios/new": @"/r/Apollo_Reborn+ios/new/",
        @"/comments/abc123": @"/comments/abc123/",
        @"/comments/abc123/title.json": @"/comments/abc123/title/",
        @"/r/test/comments/abc123/title/def456/": @"/r/test/comments/abc123/title/def456/",
        @"/r/test/comments/abc123//def456.json": @"/r/test/comments/abc123//def456/"
    };
    for (NSString *route in routes) {
        NSURL *URL = Page([@"https://oauth.reddit.com" stringByAppendingString:route]);
        NSString *path = URL ? [NSURLComponents componentsWithURL:URL resolvingAgainstBaseURL:NO].path : nil;
        NSString *expected = [routes[route] hasSuffix:@"/"] ? routes[route] : [routes[route] stringByAppendingString:@"/"];
        CHECK(URL && [path isEqualToString:expected], @"ordinary read route %@", route);
        if (URL) CHECK([URL.host isEqualToString:@"sh.reddit.com"] &&
                       [URL.scheme isEqualToString:@"https"], @"read remains on modern HTTPS Reddit %@", route);
    }
    for (NSString *host in @[@"oauth.reddit.com", @"www.reddit.com", @"reddit.com", @"old.reddit.com", @"WWW.REDDIT.COM"]) {
        CHECK([Page([NSString stringWithFormat:@"https://%@/r/test/new.json", host]).host isEqualToString:@"sh.reddit.com"],
              @"approved original host %@", host);
    }
}

static void TestURLScope(void) {
    NSArray *rejected = @[
        @"http://www.reddit.com/r/test/new", @"ftp://www.reddit.com/r/test/new", @"/r/test/new",
        @"https://evil.example/r/test/new", @"https://www.reddit.com.evil.example/r/test/new",
        @"https://reddit.com./r/test/new", @"https://redd.it/r/test/new", @"https://sh.reddit.com/r/test/new",
        @"https://user@www.reddit.com/r/test/new", @"https://user:secret@www.reddit.com/r/test/new",
        @"https://www.reddit.com:443/r/test/new", @"https://www.reddit.com:8443/r/test/new",
        @"https://www.reddit.com/api/submit", @"https://www.reddit.com/api/comment.json",
        @"https://www.reddit.com/message/inbox.json", @"https://www.reddit.com/user/someone/overview.json",
        @"https://www.reddit.com/user/someone/m/custom.json", @"https://www.reddit.com/search.json?q=awards",
        @"https://www.reddit.com/r/test/search.json", @"https://www.reddit.com/r/test/about.json",
        @"https://www.reddit.com/r/test/wiki/index.json", @"https://www.reddit.com/prefs.json",
        @"https://www.reddit.com/comments/ABC123", @"https://www.reddit.com/comments/abc.def",
        @"https://www.reddit.com/comments/abc/title/comment/extra",
        @"https://www.reddit.com/r/test/../new", @"https://www.reddit.com/r/test/%2e%2e/new",
        @"https://www.reddit.com/r/test%3fprivate/new", @"https://www.reddit.com/r/test/new%0A",
        @"https://www.reddit.com/r/test/new.json.json", @"https://www.reddit.com/r/test/new/extra"
    ];
    for (NSString *URL in rejected) CHECK(Page(URL) == nil, @"reject unrelated or unsafe URL %@", URL);
    for (NSString *path in @[@"/", @"/.json", @"/best", @"/best.json", @"/hot/", @"/new.json", @"/top", @"/rising/", @"/controversial/"]) {
        CHECK(Page([@"https://www.reddit.com" stringByAppendingString:path]) == nil,
              @"personalized root feed cannot delay exact reads %@", path);
    }

    NSString *longSubreddit = [@"a" stringByPaddingToLength:129 withString:@"a" startingAtIndex:0];
    CHECK(Page([NSString stringWithFormat:@"https://www.reddit.com/r/%@/new", longSubreddit]) == nil, @"bound subreddit path");
    CHECK(Page(@"https://www.reddit.com/comments/12345678901234567") == nil, @"bound post ID path");
    NSString *longSlug = [@"a" stringByPaddingToLength:257 withString:@"a" startingAtIndex:0];
    CHECK(Page([NSString stringWithFormat:@"https://www.reddit.com/comments/abc/%@", longSlug]) == nil, @"bound title slug");
}

static void TestQueryAndActorMarkers(void) {
    NSURL *URL = Page(@"https://www.reddit.com/r/test/top.json?after=t3_abc&before=t3_def&sort=new&t=week&limit=100&depth=8&context=3&raw_json=1&access_token=secret&cookie=secret&redirect_uri=https%3A%2F%2Fevil.example#apollo-webjson-account=somebody");
    CHECK([URL.query isEqualToString:@"after=t3_abc&before=t3_def&sort=new&t=week&limit=100&depth=8&context=3"],
          @"preserve pagination/selection only, omit transport credentials and unrelated parameters");
    CHECK(URL.fragment == nil, @"web-session response account marker never reaches the mirrored URL");
    CHECK(Page(@"https://www.reddit.com/r/test/new.json#apollo-webjson-probe") != nil, @"internal marker alone does not disqualify a real listing response");
    CHECK(Page(@"https://www.reddit.com/r/test/new.json#apollo-webjson-probe").fragment == nil, @"old probe marker stripped before transport assigns its own");
    CHECK([Page(@"https://www.reddit.com/r/test/new?after=t3_%61bc&sort=new").query isEqualToString:@"after=t3_abc&sort=new"],
          @"accepted cursor uses canonical decoded query value");
    CHECK(Page(@"https://www.reddit.com/r/test/new?sort=&after=&limit=").query == nil, @"empty selections omitted");
    CHECK(Page(@"https://www.reddit.com/r/test/new?sort&after&limit").query == nil, @"valueless selections omitted");
    CHECK(Page(@"https://www.reddit.com/r/test/new?after=t3_abc%26cookie%3Dsecret&sort=new%0A&limit=%2Fapi%2Fsubmit").query == nil,
          @"invalid values cannot add another parameter or route");
    NSString *longCursor = [@"a" stringByPaddingToLength:65 withString:@"a" startingAtIndex:0];
    CHECK(Page([NSString stringWithFormat:@"https://www.reddit.com/r/test/new?after=%@", longCursor]).query == nil, @"query value length bounded");
}

static void TestThingIdentity(void) {
    NSDictionary *comment = @{@"kind": @"t1", @"data": @{@"name": @"t1_comment", @"replies": Listing(@[Thing(@"t1", @"t1_reply")])}};
    id response = @[Listing(@[Thing(@"t3", @"t3_post")]), Listing(@[comment, Thing(@"t1", @"t1_comment")])];
    NSSet *IDs = ApolloAwardsListingThingIDs(response);
    CHECK(([IDs isEqualToSet:[NSSet setWithArray:@[@"t3_post", @"t1_comment", @"t1_reply"]]]), @"thread pair and nested replies retain actual unique thing IDs");
    CHECK([ApolloAwardsListingThingIDs(Listing(@[Thing(@"t3", @"t3_1234567890123456")])) containsObject:@"t3_1234567890123456"], @"largest valid thing ID");
    for (id invalid in @[@"t1_wrong", @"t2_user", @"t3_", @"t3_UPPER", @"t3_a/b", @"t3_é", @"t3_abc\n", @"t3_12345678901234567", @42, NSNull.null]) {
        CHECK(ApolloAwardsListingThingIDs(Listing(@[Thing(@"t3", invalid)])).count == 0, @"ignore malformed/mismatched fullname %@", invalid);
    }
    CHECK(ApolloAwardsListingThingIDs(Thing(@"t1", @"t3_wrong")).count == 0, @"comment kind cannot introduce a post ID");
    CHECK(ApolloAwardsListingThingIDs(Thing(@"more", @"t1_hidden")).count == 0, @"more-comment placeholder is not an actual comment");
    CHECK(ApolloAwardsListingThingIDs(@{@"kind": @"t3", @"data": @{@"id": @"abc"}}).count == 0, @"do not synthesize IDs from unrelated short fields");
}

static void TestCanonicalRedirects(void) {
    NSURL *post = [NSURL URLWithString:@"https://sh.reddit.com/comments/1q02umz/?sort=new#apollo-webjson-probe"];
    NSURL *canonical = [NSURL URLWithString:@"https://sh.reddit.com/r/awards/comments/1q02umz/i_will_award_every_comment_yes/?sort=new"];
    CHECK(ApolloAwardsListingAllowsRedirect(post, canonical), @"observed same-host canonical subreddit/title redirect");
    CHECK(ApolloAwardsListingAllowsRedirect(canonical, [NSURL URLWithString:@"https://www.reddit.com/r/awards/comments/1q02umz/changed_title/?sort=new"]), @"host/title change retains same post");
    NSURL *comment = [NSURL URLWithString:@"https://sh.reddit.com/comments/1q02umz//nwutqka/?context=3"];
    CHECK(ApolloAwardsListingAllowsRedirect(comment, [NSURL URLWithString:@"https://www.reddit.com/r/awards/comments/1q02umz/title/nwutqka/?context=3"]), @"comment canonicalization retains both post and comment");
    CHECK(ApolloAwardsListingAllowsRedirect([NSURL URLWithString:@"https://sh.reddit.com/new"], [NSURL URLWithString:@"https://www.reddit.com/new/"]), @"feed permits optional trailing slash and modern host hop");
    for (NSString *URL in @[
        @"https://evil.example/r/awards/comments/1q02umz/title/?sort=new",
        @"https://oauth.reddit.com/comments/1q02umz/?sort=new",
        @"https://old.reddit.com/comments/1q02umz/?sort=new",
        @"http://sh.reddit.com/comments/1q02umz/?sort=new",
        @"https://u:p@sh.reddit.com/comments/1q02umz/?sort=new",
        @"https://sh.reddit.com:443/comments/1q02umz/?sort=new",
        @"https://sh.reddit.com/login/?sort=new",
        @"https://sh.reddit.com/comments/other/title/?sort=new",
        @"https://sh.reddit.com/comments/1q02umz/title/nwutqka/?sort=new",
        @"https://sh.reddit.com/comments/1q02umz/title/?sort=top",
        @"https://sh.reddit.com/comments/1q02umz/title/?sort=new&context=3",
        @"https://sh.reddit.com/comments/1q02umz/title/",
        @"https://sh.reddit.com/comments/%31q02umz/title/?sort=new",
        @"https://sh.reddit.com/comments/1q02umz/title/extra/segment/?sort=new"
    ]) CHECK(!ApolloAwardsListingAllowsRedirect(post, [NSURL URLWithString:URL]), @"reject redirect outside exact scoped post request %@", URL);
    CHECK(!ApolloAwardsListingAllowsRedirect(comment, [NSURL URLWithString:@"https://sh.reddit.com/r/awards/comments/1q02umz/title/other/?context=3"]), @"different comment rejected");
    CHECK(!ApolloAwardsListingAllowsRedirect(comment, [NSURL URLWithString:@"https://sh.reddit.com/r/awards/comments/1q02umz/title/?context=3"]), @"comment cannot redirect to whole post");
    CHECK(!ApolloAwardsListingAllowsRedirect([NSURL URLWithString:@"https://sh.reddit.com/new/"], [NSURL URLWithString:@"https://sh.reddit.com/hot/"]), @"feed sort cannot change");
    CHECK(!ApolloAwardsListingAllowsRedirect([NSURL URLWithString:@"https://sh.reddit.com/r/one/new/"], [NSURL URLWithString:@"https://sh.reddit.com/r/two/new/"]), @"feed subreddit cannot change");
    CHECK(!ApolloAwardsListingAllowsRedirect([NSURL URLWithString:@"https://evil.example/comments/1q02umz/?sort=new"], canonical), @"source host also validated");
    CHECK(!ApolloAwardsListingAllowsRedirect([NSURL URLWithString:@"http://sh.reddit.com/comments/1q02umz/?sort=new"], canonical), @"source HTTPS also validated");
    CHECK(!ApolloAwardsListingAllowsRedirect(nil, canonical) && !ApolloAwardsListingAllowsRedirect(post, nil), @"missing redirect URL rejected");
    NSURL *badComment = [NSURL URLWithString:@"https://sh.reddit.com/comments/1q02umz/title/not_a_comment_id/"];
    CHECK(!ApolloAwardsListingAllowsRedirect(badComment, badComment), @"same malformed comment identity is still invalid");
}

static void TestUnrelatedAndMalformedJSON(void) {
    NSDictionary *unrelated = Thing(@"t3", @"t3_sidebar");
    NSDictionary *post = @{@"kind": @"t3", @"data": @{@"name": @"t3_main", @"sidebar": unrelated,
        @"crosspost_parent_list": @[unrelated], @"preview": unrelated, @"all_awardings": @[unrelated]}};
    id response = @{@"kind": @"Listing", @"data": @{@"children": @[post], @"sidebar": unrelated}, @"other": unrelated};
    CHECK([ApolloAwardsListingThingIDs(response) isEqualToSet:[NSSet setWithObject:@"t3_main"]], @"ignore metadata/sidebar things outside children/replies");
    CHECK(ApolloAwardsListingThingIDs(@{@"anything": Listing(@[unrelated])}).count == 0, @"unknown JSON wrapper does not expand collection scope");
    CHECK(ApolloAwardsListingThingIDs(@{@"kind": @"listing", @"data": @{@"children": @[unrelated]}}).count == 0, @"Listing kind is exact");
    for (id malformed in @[NSNull.null, @42, @"", @[], @{},
            @{@"kind": @"Listing", @"data": @[]}, @{@"kind": @"Listing", @"data": NSNull.null},
            @{@"kind": @42, @"data": @{@"children": @[unrelated]}},
            @{@"kind": @"Listing", @"data": @{@"children": @"not children"}}]) {
        CHECK(ApolloAwardsListingThingIDs(malformed).count == 0, @"malformed JSON contributes no IDs %@", malformed);
    }
    CHECK(ApolloAwardsListingThingIDs(nil).count == 0, @"nil JSON contributes no IDs");
    NSDictionary *emptyReply = @{@"kind": @"t1", @"data": @{@"name": @"t1_main", @"replies": @""}};
    CHECK([ApolloAwardsListingThingIDs(emptyReply) isEqualToSet:[NSSet setWithObject:@"t1_main"]], @"ordinary empty reply string preserves parent");
}

static void TestResourceBounds(void) {
    NSMutableArray *rows = [NSMutableArray new];
    for (NSUInteger index = 0; index < 700; index++) [rows addObject:Thing(@"t3", [NSString stringWithFormat:@"t3_%lu", (unsigned long)index])];
    NSSet *IDs = ApolloAwardsListingThingIDs(Listing(rows));
    CHECK(IDs.count == 500 && [IDs containsObject:@"t3_0"] && ![IDs containsObject:@"t3_699"], @"collect bounded first 500 real rows");
    id nested = Thing(@"t3", @"t3_deep");
    for (NSUInteger depth = 0; depth < 25; depth++) nested = @[nested];
    CHECK(ApolloAwardsListingThingIDs(nested).count == 0, @"excessive nesting bounded");
    rows = [NSMutableArray new];
    for (NSUInteger index = 0; index < 2100; index++) [rows addObject:NSNull.null];
    [rows addObject:Thing(@"t3", @"t3_beyondvisitbudget")];
    CHECK(ApolloAwardsListingThingIDs(Listing(rows)).count == 0, @"large malformed listing bounded before late content");
    NSMutableArray *source = [NSMutableArray arrayWithObject:Thing(@"t3", @"t3_first")];
    IDs = ApolloAwardsListingThingIDs(Listing(source));
    [source addObject:Thing(@"t3", @"t3_later")];
    CHECK([IDs isEqualToSet:[NSSet setWithObject:@"t3_first"]], @"result is a collection snapshot independent of later listing mutation");
}

int main(void) {
    @autoreleasepool {
        TestReadRoutes();
        TestURLScope();
        TestQueryAndActorMarkers();
        TestCanonicalRedirects();
        TestThingIdentity();
        TestUnrelatedAndMalformedJSON();
        TestResourceBounds();
        printf("Awards listing tests: %d checks, %d failures\n", sChecks, sFailures);
    }
    return sFailures == 0 ? 0 : 1;
}
