#import <Foundation/Foundation.h>
#import "ApolloAwardsParsing.h"

static int sFailures;
static int sChecks;
#define CHECK(condition, ...) do { \
    sChecks++; \
    if (!(condition)) { sFailures++; fprintf(stderr, "FAIL line %d: %s\n", __LINE__, \
        [NSString stringWithFormat:__VA_ARGS__].UTF8String); } \
} while (0)

static NSString *Replace(NSString *value, NSString *before, NSString *after) {
    return [value stringByReplacingOccurrencesOfString:before withString:after];
}

static NSString *Dialog(NSString *source) {
    return [NSString stringWithFormat:@"<faceplate-partial name='AwardLeaderboard_fixture' src='%@'></faceplate-partial>", source];
}

static void TestNames(void) {
    CHECK([ApolloAwardsNormalizeFullName(@"T3_1CSS0WS") isEqualToString:@"t3_1css0ws"], @"normalize fullnames");
    CHECK([ApolloAwardsNormalizeFullName(@"t1_abc123") isEqualToString:@"t1_abc123"], @"comment fullname");
    for (id bad in @[@"", @"abc", @"t2_abc", @" t3_abc", @"t3_a/b", @"t3_abc\n", @"t3_é", @"t3_", @42]) {
        CHECK(ApolloAwardsNormalizeFullName(bad) == nil, @"reject invalid fullname %@", bad);
    }
    CHECK(ApolloAwardsNormalizeFullName(nil) == nil, @"nil fullname");
}

static void TestURLs(NSString *fixture) {
    NSURL *URL = ApolloAwardsLeaderboardURL(fixture, @"t3_1q02umz");
    CHECK([URL.host isEqualToString:@"www.reddit.com"], @"real dialog yields scoped host");
    CHECK([URL.path hasSuffix:@"/award-leaderboard"], @"real dialog path");
    CHECK(ApolloAwardsLeaderboardURL(fixture, @"t1_1q02umz") == nil, @"mismatched expected thing");
    CHECK(ApolloAwardsLeaderboardURL([fixture stringByAppendingString:fixture], @"t3_1q02umz") == nil, @"ambiguous partials");
    NSString *path = @"/svc/shreddit/partial/Ab_123/award-leaderboard?params=thingId%3Dt3_1q02umz&amp;sig=v1.test";
    CHECK(ApolloAwardsLeaderboardURL(Dialog(path), @"t3_1q02umz") != nil, @"HTML attribute entity decoding");
    CHECK(ApolloAwardsLeaderboardURL(Dialog([@"https://www.reddit.com" stringByAppendingString:path]), @"t3_1q02umz") != nil, @"absolute scoped URL");
    NSArray *bad = @[
        [@"https://evil.example" stringByAppendingString:path],
        [@"https://sh.reddit.com" stringByAppendingString:path],
        [@"//www.reddit.com" stringByAppendingString:path],
        [@"http://www.reddit.com" stringByAppendingString:path],
        [@"https://user@www.reddit.com" stringByAppendingString:path],
        [@"https://www.reddit.com:444" stringByAppendingString:path],
        [path stringByAppendingString:@"#fragment"],
        Replace(path, @"&amp;sig=v1.test", @""),
        Replace(path, @"&amp;sig=v1.test", @"&amp;sig="),
        [path stringByAppendingString:@"&amp;sig=v1.duplicate"],
        [path stringByAppendingString:@"&amp;extra=1"],
        Replace(path, @"thingId%3Dt3_1q02umz", @"thingId%3Dt1_1q02umz"),
        Replace(path, @"thingId%3Dt3_1q02umz", @"thingId%3Dt3_1q02umz%26thingId%3Dt3_other"),
        Replace(path, @"/Ab_123/", @"/../"),
        Replace(path, @"/Ab_123/", @"/%41b_123/"),
        Replace(path, @"award-leaderboard?", @"award-gold-purchase?"),
    ];
    for (NSString *value in bad) CHECK(ApolloAwardsLeaderboardURL(Dialog(value), @"t3_1q02umz") == nil, @"reject unsafe partial %@", value);
    CHECK(ApolloAwardsLeaderboardURL(@"<html>Blocked</html>", @"t3_1q02umz") == nil, @"challenge has no partial");
    CHECK(ApolloAwardsLeaderboardURL(@"<faceplate-partial", @"t3_1q02umz") == nil, @"truncated dialog");
}

static void TestLeaderboard(NSString *fixture, NSString *empty) {
    NSArray *awards = ApolloAwardsParseLeaderboard(fixture, @"t3_1q02umz");
    CHECK(awards.count == 8, @"all eight real award types");
    NSInteger total = 0;
    for (NSDictionary *award in awards) total += [award[@"count"] integerValue];
    CHECK(total == 54, @"live total must be 54, got %ld", (long)total);
    CHECK([awards[0][@"count"] integerValue] == 15, @"representative icon does not inherit total54 or gold225");
    CHECK([awards[3][@"count"] integerValue] == 16, @"free award keeps own count");
    CHECK([awards[0][@"icon_url"] hasSuffix:@"wholesome_v1_128.png"], @"animation gets static placeholder");
    CHECK([awards[0][@"icon_width"] integerValue] == 128, @"actual 128px source dimensions");
    CHECK([awards[0][@"resized_icons"] count] == 1, @"legacy resized icon list");
    CHECK([awards[0][@"resized_icons"][0][@"width"] integerValue] == 128, @"no fabricated 40px asset");
    CHECK([awards[0][@"name"] isEqualToString:@"Wholesome Seal"], @"animated description is its name");
    CHECK([awards[1][@"name"] isEqualToString:@"Diamonds are Forever"], @"static alt is its name");
    NSString *animation = @"https://i.redd.it/snoovatar/snoo_assets/marketing/XA2-yELORko_Wholesome_Seal.json";
    CHECK([awards[0][@"animation_url"] isEqual:animation], @"explicit lottie source retained as optional metadata");
    CHECK(awards[1][@"animation_url"] == nil, @"static PNG never gains an inferred animation");
    NSString *staticCDN = @"https://www.redditstatic.com/marketplace-assets/v1/core/awards/3d/wholesome.json";
    NSArray *changedAnimation = ApolloAwardsParseLeaderboard(Replace(fixture, animation, staticCDN), @"t3_1q02umz");
    CHECK([changedAnimation[0][@"animation_url"] isEqual:staticCDN], @"award JSON allowed on scoped static CDN");
    NSArray *badAnimations = @[
        @"", @"http://i.redd.it/snoovatar/snoo_assets/marketing/a.json",
        @"https://evil.example/snoovatar/snoo_assets/marketing/a.json",
        @"https://u:p@i.redd.it/snoovatar/snoo_assets/marketing/a.json",
        @"https://i.redd.it:443/snoovatar/snoo_assets/marketing/a.json",
        @"https://i.redd.it/snoovatar/snoo_assets/marketing/a.json?x=1",
        @"https://i.redd.it/snoovatar/snoo_assets/marketing/a.json#x",
        @"https://i.redd.it/snoovatar/snoo_assets/marketing/../a.json",
        @"https://i.redd.it/snoovatar/snoo_assets/marketing/./a.json",
        @"https://i.redd.it/snoovatar/snoo_assets/marketing/%61.json",
        @"https://i.redd.it/snoovatar/snoo_assets/marketing/a.png",
        @"https://i.redd.it/untrusted/a.json",
        @"https://www.redditstatic.com/shreddit/assets/marketplace/contributor-program/empty-leaderboard.json",
        [@"https://i.redd.it/snoovatar/snoo_assets/marketing/" stringByAppendingString:
            [[@"a" stringByPaddingToLength:2048 withString:@"a" startingAtIndex:0] stringByAppendingString:@".json"]]
    ];
    for (NSString *bad in badAnimations) {
        NSArray *parsed = ApolloAwardsParseLeaderboard(Replace(fixture, animation, bad), @"t3_1q02umz");
        CHECK(parsed.count == 8 && parsed[0][@"animation_url"] == nil &&
              [parsed[0][@"icon_url"] isEqual:awards[0][@"icon_url"]], @"invalid optional animation preserves static award %@", bad);
    }

    NSArray *zero = ApolloAwardsParseLeaderboard(empty, @"t1_oqylf69");
    CHECK(zero != nil && zero.count == 0, @"real explicit empty state");
    CHECK(ApolloAwardsParseLeaderboard(empty, @"t1_other") == nil, @"empty state still checks identity");
    CHECK(ApolloAwardsParseLeaderboard(fixture, @"t3_other") == nil, @"positive response checks identity");
    CHECK(ApolloAwardsParseLeaderboard(@"<html>Blocked due to network policy</html>", @"t3_1q02umz") == nil, @"blocked is not zero");
    CHECK(ApolloAwardsParseLeaderboard(@"<award-leaderboard thing-id='t3_1q02umz'></award-leaderboard>", @"t3_1q02umz") == nil, @"unknown empty layout is not zero");
    CHECK(ApolloAwardsParseLeaderboard(Replace(fixture, @"</award-leaderboard>", @""), @"t3_1q02umz") == nil, @"truncated component");
    CHECK(ApolloAwardsParseLeaderboard([fixture stringByAppendingString:fixture], @"t3_1q02umz") == nil, @"duplicate component");
    CHECK(ApolloAwardsParseLeaderboard(Replace(fixture, @"award_diamonds_are_forever", @"award_wholesome_seal_2"), @"t3_1q02umz") == nil, @"duplicate award IDs rejected");
    CHECK(ApolloAwardsParseLeaderboard(Replace(fixture, @"<report-award award-id=\"award_diamonds_are_forever\"", @"<unknown-award award-id=\"award_diamonds_are_forever\""), @"t3_1q02umz") == nil, @"mixed unknown row fails instead of dropping award");
    CHECK(ApolloAwardsParseLeaderboard(Replace(fixture, @"thing-id=\"t3_1q02umz\" subreddit", @"thing-id=\"t3_other\" subreddit"), @"t3_1q02umz") == nil, @"per-row identity checked");

    for (NSString *bad in @[@"0", @"-1", @"1.5", @"1k", @"15x", @"01", @"1,50", @"9999999999", @"", @"+15"]) {
        NSString *changed = Replace(fixture, @">15</span>", [NSString stringWithFormat:@">%@</span>", bad]);
        CHECK(ApolloAwardsParseLeaderboard(changed, @"t3_1q02umz") == nil, @"reject inexact count %@", bad);
    }
    NSArray *thousands = ApolloAwardsParseLeaderboard(Replace(fixture, @">15</span>", @">1,234</span>"), @"t3_1q02umz");
    CHECK([thousands[0][@"count"] integerValue] == 1234, @"exact thousands separator");
    NSArray *escaped = ApolloAwardsParseLeaderboard(Replace(fixture, @"Diamonds are Forever", @"A &amp; B &#x1F3C6;"), @"t3_1q02umz");
    CHECK([escaped[1][@"name"] isEqualToString:@"A & B 🏆"], @"HTML entities decoded once");

    CHECK(ApolloAwardsParseLeaderboard(Replace(fixture, @"https://i.redd.it/", @"https://evil.example/"), @"t3_1q02umz") == nil, @"external image refused");
    CHECK(ApolloAwardsParseLeaderboard(Replace(fixture, @"_128.png", @"_128.json"), @"t3_1q02umz") == nil, @"animation URL refused as image");
    CHECK(ApolloAwardsParseLeaderboard(Replace(fixture, @"placeholder-src=", @"missing-placeholder="), @"t3_1q02umz") == nil, @"missing animation placeholder");
    NSString *mixed = Replace(fixture, @"</award-leaderboard>", @"<award-dialog-leaderboard-entrypoint thing-id='t3_1q02umz' pane-name='zero_state:x'></award-dialog-leaderboard-entrypoint></award-leaderboard>");
    CHECK(ApolloAwardsParseLeaderboard(mixed, @"t3_1q02umz") == nil, @"mixed positive and empty state refused");
}

static void TestFailureClassification(void) {
    NSString *challenge = @"<html><head><title>Reddit - Prove your humanity</title></head><body><form><div class='g-recaptcha'></div></form></body></html>";
    CHECK(ApolloAwardsClassifyUnparsedHTML(challenge, @"t3_abc") == ApolloAwardsUnparsedHTMLChallenge, @"explicit challenge distinguished");
    CHECK(ApolloAwardsClassifyUnparsedHTML(Replace(challenge, @"g-recaptcha", @"ordinary"), @"t3_abc") == ApolloAwardsUnparsedHTMLUnknown, @"title alone is not proof of challenge");
    CHECK(ApolloAwardsClassifyUnparsedHTML(@"<html><body>Prove your humanity</body></html>", @"t3_abc") == ApolloAwardsUnparsedHTMLUnknown, @"freeform body text does not classify challenge");
    NSString *unsupported = @"<award-leaderboard thing-id='t3_abc'><new-format></new-format></award-leaderboard>";
    CHECK(ApolloAwardsClassifyUnparsedHTML(unsupported, @"t3_abc") == ApolloAwardsUnparsedHTMLMatchingLeaderboard, @"complete matching unsupported component distinguished");
    CHECK(ApolloAwardsParseLeaderboard(unsupported, @"t3_abc") == nil, @"classification never converts unsupported markup to zero");
    CHECK(ApolloAwardsClassifyUnparsedHTML(unsupported, @"t3_other") == ApolloAwardsUnparsedHTMLUnknown, @"classification checks identity");
    CHECK(ApolloAwardsClassifyUnparsedHTML([unsupported stringByAppendingString:unsupported], @"t3_abc") == ApolloAwardsUnparsedHTMLUnknown, @"ambiguous components remain unknown");
    CHECK(ApolloAwardsClassifyUnparsedHTML(Replace(unsupported, @"</award-leaderboard>", @""), @"t3_abc") == ApolloAwardsUnparsedHTMLUnknown, @"truncated component remains unknown");
}

static void TestPageCounts(NSString *fixture) {
    NSDictionary *counts = ApolloAwardsParsePageCounts(fixture);
    NSDictionary *expected = @{@"t3_1q02umz": @54, @"t3_zero": @0, @"t1_oqylf69": @0,
                               @"t1_nwutqka": @18, @"t1_nwuvrk0": @3};
    CHECK([counts isEqual:expected], @"real component attributes produce exact aggregate counts and only confirmed zeros");
    CHECK(ApolloAwardsParsePageCounts(@"<html>Blocked</html>") == nil, @"unrelated page is not a zero map");
    CHECK(ApolloAwardsParsePageCounts(@"<award-button thing-id='t1_abc'></award-button>") == nil, @"button alone cannot prove any count");
    NSString *comment = @"<shreddit-comment thingid='t1_abc'><award-button thing-id='t1_abc'></award-button></shreddit-comment>";
    CHECK([ApolloAwardsParsePageCounts(comment)[@"t1_abc"] isEqual:@0], @"omitted comment count requires owned empty button");
    CHECK(ApolloAwardsParsePageCounts(@"<shreddit-comment thingid='t1_abc'></shreddit-comment><award-button thing-id='t1_abc'></award-button>")[@"t1_abc"] == nil, @"flattened sibling button is not proof of zero");
    CHECK(ApolloAwardsParsePageCounts(Replace(comment, @"<award-button", @"<award-button award-id=''"))[@"t1_abc"] == nil, @"present empty award-id remains uncertain");
    CHECK(ApolloAwardsParsePageCounts(Replace(comment, @"<award-button", @"<award-button icon-url=''"))[@"t1_abc"] == nil, @"present empty icon-url remains uncertain");
    CHECK(ApolloAwardsParsePageCounts(Replace(comment, @"thing-id='t1_abc'", @"thing-id='t1_other'"))[@"t1_abc"] == nil, @"button identity must match");
    NSString *nested = @"<shreddit-comment thingid='t1_parent'><shreddit-comment thingid='t1_child'><award-button thing-id='t1_parent'></award-button></shreddit-comment></shreddit-comment>";
    CHECK(ApolloAwardsParsePageCounts(nested).count == 0, @"parent cannot borrow reply's button");
    NSString *duplicateButton = Replace(comment, @"</shreddit-comment>", @"<award-button thing-id='t1_abc'></award-button></shreddit-comment>");
    CHECK(ApolloAwardsParsePageCounts(duplicateButton)[@"t1_abc"] == nil, @"ambiguous own buttons do not infer zero");
    CHECK([ApolloAwardsParsePageCounts([comment stringByAppendingString:comment])[@"t1_abc"] isEqual:@0], @"agreeing duplicates are harmless");
    NSString *positive = @"<shreddit-comment thingid='t1_abc' award-count='2'></shreddit-comment>";
    CHECK(ApolloAwardsParsePageCounts([comment stringByAppendingString:positive])[@"t1_abc"] == nil, @"conflicting duplicates removed");
    CHECK(ApolloAwardsParsePageCounts([[comment stringByAppendingString:positive] stringByAppendingString:comment])[@"t1_abc"] == nil, @"later duplicate cannot erase conflict");
    NSString *invalidDuplicate = @"<shreddit-comment thingid='t1_abc' award-count='bad'></shreddit-comment>";
    CHECK(ApolloAwardsParsePageCounts([comment stringByAppendingString:invalidDuplicate])[@"t1_abc"] == nil, @"malformed duplicate invalidates earlier zero");
    CHECK(ApolloAwardsParsePageCounts([invalidDuplicate stringByAppendingString:comment])[@"t1_abc"] == nil, @"malformed duplicate conflict is order independent");
    CHECK(ApolloAwardsParsePageCounts(Replace(comment, @"</shreddit-comment>", @"")) == nil, @"truncated component not recovered as zero");
    CHECK(ApolloAwardsParsePageCounts([comment stringByAppendingString:@"<shreddit-comment thingid='t1_truncated'>"]) == nil, @"one complete component does not conceal truncated neighbor");
    for (NSString *invalid in @[@"", @"-1", @"1.5", @"01", @"1k", @"1,234", @"1000000000", @" 0", @"0\n"]) {
        NSString *source = [NSString stringWithFormat:@"<shreddit-comment thingid='t1_abc' award-count='%@'><award-button thing-id='t1_abc'></award-button></shreddit-comment>", invalid];
        CHECK(ApolloAwardsParsePageCounts(source)[@"t1_abc"] == nil, @"invalid present count is never treated as omitted: %@", invalid);
    }
    CHECK([ApolloAwardsParsePageCounts(Replace(positive, @"'2'", @"'999999999'"))[@"t1_abc"] isEqual:@999999999], @"bounded exact count maximum");
    CHECK(ApolloAwardsParsePageCounts(@"<shreddit-post id='t3_abc' award-count='0' award-id='award_positive'></shreddit-post>")[@"t3_abc"] == nil, @"positive post metadata contradicts zero");
    CHECK(ApolloAwardsParsePageCounts(@"<shreddit-comment thingid='t1_abc' award-count='0'><award-button thing-id='t1_abc' award-id='award_positive'></award-button></shreddit-comment>")[@"t1_abc"] == nil, @"positive comment metadata contradicts zero");
    CHECK(ApolloAwardsParsePageCounts(@"<shreddit-post id='t1_abc' award-count='0'></shreddit-post><shreddit-comment thingid='t3_abc' award-count='0'></shreddit-comment>").count == 0, @"component kind must match fullname");
}

static void TestPageSizeBounds(NSString *leaderboard) {
    NSString *row = @"<shreddit-post id='t3_abc' award-count='0'></shreddit-post>";
    NSString *padding = [@"x" stringByPaddingToLength:3 * 1024 * 1024 withString:@"x" startingAtIndex:0];
    NSString *page = [NSString stringWithFormat:@"<html><body><!--%@-->%@</body></html>", padding, row];
    CHECK([ApolloAwardsParsePageCounts(page)[@"t3_abc"] isEqual:@0], @"complete full page between 2 and 4 MiB remains parseable");
    NSString *partial = [NSString stringWithFormat:@"<!--%@-->%@", padding, leaderboard];
    CHECK(ApolloAwardsParseLeaderboard(partial, @"t3_1q02umz") == nil, @"full-page allowance does not widen the compact leaderboard limit");
    padding = [@"x" stringByPaddingToLength:4 * 1024 * 1024 withString:@"x" startingAtIndex:0];
    page = [NSString stringWithFormat:@"<html><body><!--%@-->%@</body></html>", padding, row];
    CHECK(ApolloAwardsParsePageCounts(page) == nil, @"page beyond 4 MiB is refused before parsing");
    padding = [@"é" stringByPaddingToLength:3 * 1024 * 1024 withString:@"é" startingAtIndex:0];
    page = [NSString stringWithFormat:@"<html><body><!--%@-->%@</body></html>", padding, row];
    CHECK(page.length < 4 * 1024 * 1024 && ApolloAwardsParsePageCounts(page) == nil,
          @"page cap checks UTF-8 bytes as well as NSString length");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) return 2;
        NSString *directory = [NSString stringWithUTF8String:argv[1]];
        NSString *(^read)(NSString *) = ^NSString *(NSString *name) {
            return [NSString stringWithContentsOfFile:[directory stringByAppendingPathComponent:name]
                                            encoding:NSUTF8StringEncoding error:nil];
        };
        NSString *dialog = read(@"dialog.html");
        NSString *leaderboard = read(@"leaderboard.html");
        NSString *empty = read(@"empty.html");
        NSString *pageCounts = read(@"page-counts.html");
        if (!dialog || !leaderboard || !empty || !pageCounts) { fprintf(stderr, "Missing fixtures\n"); return 2; }
        TestNames();
        TestURLs(dialog);
        TestLeaderboard(leaderboard, empty);
        TestFailureClassification();
        TestPageCounts(pageCounts);
        TestPageSizeBounds(leaderboard);
        printf("Awards parsing: %d checks, %d failures\n", sChecks, sFailures);
        return sFailures ? 1 : 0;
    }
}
