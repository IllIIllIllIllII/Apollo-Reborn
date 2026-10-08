#import <Foundation/Foundation.h>
#import "ApolloAwardsStore.h"

static int sFailures;
static int sChecks;
#define CHECK(condition, ...) do { \
    sChecks++; \
    if (!(condition)) { sFailures++; fprintf(stderr, "FAIL line %d: %s\n", __LINE__, \
        [NSString stringWithFormat:__VA_ARGS__].UTF8String); } \
} while (0)

static NSDictionary *Award(NSInteger number) {
    NSString *URL = [NSString stringWithFormat:@"https://i.redd.it/snoovatar/snoo_assets/marketing/test%ld_128.png", (long)number];
    return @{@"id": [NSString stringWithFormat:@"award_test_%ld", (long)number],
             @"name": @"Test award", @"description": @"Test award", @"count": @2,
             @"icon_url": URL, @"icon_width": @128, @"icon_height": @128,
             @"resized_icons": @[@{@"url": URL, @"width": @128, @"height": @128}]};
}

static NSDictionary *Record(id awards, id date) {
    return @{@"awards": awards, @"fetchedDate": date};
}

static void WriteRoot(NSURL *URL, id root) {
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:root format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    CHECK(data != nil && [data writeToURL:URL atomically:YES], @"write fixture");
}

static void WriteRecords(NSURL *URL, NSDictionary *records) {
    WriteRoot(URL, @{@"schemaVersion": @1, @"entries": records});
}

static NSDictionary *ReadRoot(NSURL *URL) {
    NSData *data = [NSData dataWithContentsOfURL:URL];
    return data ? [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:nil] : nil;
}

static void TestLifetimes(NSURL *directory) {
    NSURL *URL = [directory URLByAppendingPathComponent:@"lifetimes/store.plist"];
    ApolloAwardsStore *store = [[ApolloAwardsStore alloc] initWithFileURL:URL];
    NSDate *now = NSDate.date;
    NSArray *awards = @[Award(1)];
    [store storeAwards:awards forFullName:@"T3_ABC" atDate:now];
    CHECK([[store awardsForFullName:@"t3_abc" allowStale:NO now:now] isEqual:awards], @"fresh canonicalized lookup");
    CHECK([store awardsForFullName:@"t3_abc" allowStale:NO now:[now dateByAddingTimeInterval:299]] != nil, @"fresh under five minutes");
    CHECK([store awardsForFullName:@"t3_abc" allowStale:NO now:[now dateByAddingTimeInterval:300]] == nil, @"fresh expires exactly at five minutes");
    CHECK([store awardsForFullName:@"t3_abc" allowStale:YES now:[now dateByAddingTimeInterval:300]] != nil, @"positive stale remains usable");
    CHECK([store awardsForFullName:@"t3_abc" allowStale:YES now:[now dateByAddingTimeInterval:86399]] != nil, @"positive usable under 24 hours");
    CHECK([store awardsForFullName:@"t3_abc" allowStale:YES now:[now dateByAddingTimeInterval:86400]] == nil, @"positive expires exactly at 24 hours");
    CHECK([store awardsForFullName:@"t3_missing" allowStale:YES now:now] == nil, @"missing is unknown, not zero");
    CHECK([store awardsForFullName:@"t3_abc" allowStale:YES now:[now dateByAddingTimeInterval:-61]] == nil, @"far-future timestamp unusable");
    [store storeAwards:@[] forFullName:@"t1_zero" atDate:now];
    NSArray *zero = [store awardsForFullName:@"t1_zero" allowStale:NO now:now];
    CHECK(zero != nil && zero.count == 0, @"explicit fresh zero");
    CHECK([store awardsForFullName:@"t1_zero" allowStale:YES now:[now dateByAddingTimeInterval:300]] == nil, @"zero never used stale");
    CHECK(![NSFileManager.defaultManager fileExistsAtPath:URL.path], @"lookup/store perform no file writes");
    [store save];
    CHECK([NSFileManager.defaultManager fileExistsAtPath:URL.path], @"save creates parent directory");
    NSDictionary *root = ReadRoot(URL);
    CHECK([root[@"schemaVersion"] isEqual:@1], @"versioned schema");
    CHECK([root[@"entries"][@"t3_abc"][@"fetchedDate"] isKindOfClass:NSDate.class], @"timestamp persists");
    ApolloAwardsStore *reloaded = [[ApolloAwardsStore alloc] initWithFileURL:URL];
    [reloaded load];
    CHECK([[reloaded awardsForFullName:@"t3_abc" allowStale:NO now:now] isEqual:awards], @"positive survives reload");
    CHECK([reloaded awardsForFullName:@"t1_zero" allowStale:NO now:now] != nil, @"fresh zero survives reload");
}

static void TestFreshnessInvalidation(NSURL *directory) {
    NSURL *URL = [directory URLByAppendingPathComponent:@"invalidation.plist"];
    ApolloAwardsStore *store = [[ApolloAwardsStore alloc] initWithFileURL:URL];
    NSArray *awards = @[Award(7)];
    [store storeAwards:awards forFullName:@"t3_positive" atDate:NSDate.date];
    [store storeAwards:@[] forFullName:@"t1_zero" atDate:NSDate.date];
    CHECK([[store awardsForFullName:@"t3_positive" allowStale:NO now:NSDate.date] isEqual:awards], @"positive starts fresh before gifting refresh");
    CHECK([store awardsForFullName:@"t1_zero" allowStale:NO now:NSDate.date] != nil, @"zero starts confirmed before gifting refresh");
    [store expireFreshnessForFullName:@"T3_POSITIVE"];
    [store expireFreshnessForFullName:@"t1_zero"];
    CHECK([store awardsForFullName:@"t3_positive" allowStale:NO now:NSDate.date] == nil &&
          [[store awardsForFullName:@"t3_positive" allowStale:YES now:NSDate.date] isEqual:awards],
          @"gifting invalidation forces a fresh read while preserving positive display data");
    CHECK([store awardsForFullName:@"t1_zero" allowStale:NO now:NSDate.date] == nil &&
          [store awardsForFullName:@"t1_zero" allowStale:YES now:NSDate.date] == nil,
          @"gifting invalidation removes zero instead of allowing it to hide the new award");
    [store save];
    ApolloAwardsStore *reloaded = [[ApolloAwardsStore alloc] initWithFileURL:URL];
    [reloaded load];
    CHECK([reloaded awardsForFullName:@"t3_positive" allowStale:NO now:NSDate.date] == nil &&
          [[reloaded awardsForFullName:@"t3_positive" allowStale:YES now:NSDate.date] isEqual:awards],
          @"saved invalidation cannot revive positive freshness after restart");
    CHECK([reloaded awardsForFullName:@"t1_zero" allowStale:YES now:NSDate.date] == nil,
          @"saved invalidation cannot revive a confirmed zero after restart");
}

static void TestMergeAndInvalidData(NSURL *directory) {
    NSURL *URL = [directory URLByAppendingPathComponent:@"merge.plist"];
    NSDate *now = NSDate.date;
    NSDate *older = [now dateByAddingTimeInterval:-30];
    ApolloAwardsStore *store = [[ApolloAwardsStore alloc] initWithFileURL:URL];
    WriteRecords(URL, @{@"t3_same": Record(@[Award(1)], older),
                        @"t1_other": Record(@[Award(2)], now)});
    [store storeAwards:@[Award(3)] forFullName:@"t3_same" atDate:now];
    [store load];
    CHECK([[store awardsForFullName:@"t3_same" allowStale:NO now:now][0][@"id"] isEqual:@"award_test_3"], @"load keeps newer in-memory result");
    CHECK([store awardsForFullName:@"t1_other" allowStale:NO now:now] != nil, @"load merges other keys");
    WriteRecords(URL, @{@"t3_same": Record(@[Award(1)], now)});
    [store load];
    CHECK([[store awardsForFullName:@"t3_same" allowStale:NO now:now][0][@"id"] isEqual:@"award_test_3"], @"equal-date memory wins");
    [store storeAwards:@[Award(4)] forFullName:@"t3_same" atDate:older];
    CHECK([[store awardsForFullName:@"t3_same" allowStale:NO now:now][0][@"id"] isEqual:@"award_test_3"], @"older mutation cannot overwrite memory");
    [@"not a property list" writeToURL:URL atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [store load];
    CHECK([store awardsForFullName:@"t3_same" allowStale:NO now:now] != nil, @"corrupt file preserves memory");

    NSMutableArray *badAwards = [NSMutableArray new];
    for (NSDictionary *change in @[@{@"id": @"award_"}, @{@"id": @"award_test\n"}, @{@"name": @42},
                                    @{@"description": @[]}, @{@"count": @0}, @{@"count": @(-1)}, @{@"count": @1.5},
                                    @{@"count": @YES}, @{@"count": @1000000000}, @{@"icon_width": @64},
                                    @{@"icon_height": @YES}, @{@"resized_icons": @[]},
                                    @{@"resized_icons": @[@{@"url": @"https://evil.example/a_128.png", @"width": @128, @"height": @128}]}]) {
        NSMutableDictionary *award = [Award(1) mutableCopy];
        [award addEntriesFromDictionary:change];
        [badAwards addObject:@[award]];
    }
    for (NSString *URLString in @[@"http://i.redd.it/snoovatar/snoo_assets/marketing/a_128.png",
                                 @"https://evil.example/snoovatar/snoo_assets/marketing/a_128.png",
                                 @"https://u:p@i.redd.it/snoovatar/snoo_assets/marketing/a_128.png",
                                 @"https://i.redd.it:443/snoovatar/snoo_assets/marketing/a_128.png",
                                 @"https://i.redd.it/snoovatar/snoo_assets/marketing/a_128.png?x=1",
                                 @"https://i.redd.it/snoovatar/snoo_assets/marketing/a_128.png#x",
                                 @"https://i.redd.it/snoovatar/snoo_assets/marketing/../a_128.png",
                                 @"https://i.redd.it/snoovatar/snoo_assets/marketing/%61_128.png",
                                 @"https://i.redd.it/untrusted/a_128.png"]) {
        NSMutableDictionary *award = [Award(1) mutableCopy];
        award[@"icon_url"] = URLString;
        award[@"resized_icons"] = @[@{@"url": URLString, @"width": @128, @"height": @128}];
        [badAwards addObject:@[award]];
    }
    [badAwards addObjectsFromArray:@[@[Award(1), Award(1)], @[@"not an award"], @{}, @"bad"]];
    NSMutableDictionary *records = [NSMutableDictionary new];
    [badAwards enumerateObjectsUsingBlock:^(id awards, NSUInteger index, BOOL *stop) {
        (void)stop;
        records[[NSString stringWithFormat:@"t3_bad%lu", (unsigned long)index]] = Record(awards, now);
    }];
    records[@"t3_valid"] = Record(@[Award(1)], now);
    records[@"t3_stale"] = Record(@[Award(2)], [now dateByAddingTimeInterval:-301]);
    records[@"t3_expired"] = Record(@[Award(3)], [now dateByAddingTimeInterval:-86401]);
    records[@"t1_zeroexpired"] = Record(@[], [now dateByAddingTimeInterval:-301]);
    records[@"t3_baddate"] = Record(@[Award(1)], @42);
    records[@"t3_future"] = Record(@[Award(1)], [now dateByAddingTimeInterval:86400]);
    records[@"t2_badkind"] = Record(@[Award(1)], now);
    records[@"t3_bad\n"] = Record(@[Award(1)], now);
    WriteRecords(URL, records);
    store = [[ApolloAwardsStore alloc] initWithFileURL:URL];
    [store load];
    CHECK([store awardsForFullName:@"t3_valid" allowStale:NO now:now] != nil, @"valid record survives neighboring corruption");
    CHECK([store awardsForFullName:@"t3_stale" allowStale:NO now:now] == nil, @"loaded stale requires refresh");
    CHECK([store awardsForFullName:@"t3_stale" allowStale:YES now:now] != nil, @"loaded positive stale usable");
    for (NSString *key in records) {
        if ([key isEqual:@"t3_valid"] || [key isEqual:@"t3_stale"]) continue;
        CHECK([store awardsForFullName:key allowStale:YES now:now] == nil, @"invalid/expired record is unknown for %@", key);
    }
    [store save];
    CHECK([ReadRoot(URL)[@"entries"] count] == 2, @"save prunes expired/corrupt records");
    for (id root in @[@[], @{@"schemaVersion": @2, @"entries": @{}}, @{@"schemaVersion": @YES, @"entries": @{}},
                      @{@"schemaVersion": @1, @"entries": @[]}]) {
        WriteRoot(URL, root);
        ApolloAwardsStore *empty = [[ApolloAwardsStore alloc] initWithFileURL:URL];
        [empty load];
        CHECK([empty awardsForFullName:@"t3_valid" allowStale:YES now:now] == nil, @"invalid schema ignored");
    }
}

static void TestImmutableAndConcurrent(NSURL *directory) {
    ApolloAwardsStore *store = [[ApolloAwardsStore alloc] initWithFileURL:[directory URLByAppendingPathComponent:@"concurrent.plist"]];
    NSDate *now = NSDate.date;
    NSMutableDictionary *award = [Award(1) mutableCopy];
    NSMutableString *name = [@"Original" mutableCopy];
    award[@"name"] = name;
    award[@"extra"] = @"must not persist";
    NSMutableArray *awards = [NSMutableArray arrayWithObject:award];
    [store storeAwards:awards forFullName:@"t3_copy" atDate:now];
    [name setString:@"Changed"];
    award[@"count"] = @99;
    [awards removeAllObjects];
    NSArray *copy = [store awardsForFullName:@"t3_copy" allowStale:NO now:now];
    CHECK([copy[0][@"name"] isEqual:@"Original"] && [copy[0][@"count"] isEqual:@2], @"store deeply snapshots mutable caller data");
    CHECK(copy[0][@"extra"] == nil, @"unknown fields omitted");
    [store storeAwards:(id)@[@{@"count": @1}] forFullName:@"t3_copy" atDate:now];
    CHECK([[store awardsForFullName:@"t3_copy" allowStale:NO now:now] isEqual:copy], @"invalid write preserves positive data");
    dispatch_apply(200, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t index) {
        @autoreleasepool {
            NSString *key = [NSString stringWithFormat:@"t1_%zu", index];
            [store storeAwards:@[Award((NSInteger)index)] forFullName:key atDate:now];
            (void)[store awardsForFullName:@"t3_copy" allowStale:YES now:now];
        }
    });
    NSUInteger surviving = 0;
    for (NSUInteger index = 0; index < 200; index++) {
        if ([store awardsForFullName:[NSString stringWithFormat:@"t1_%lu", (unsigned long)index] allowStale:NO now:now]) surviving++;
    }
    CHECK(surviving == 200, @"concurrent mutations and reads retain all entries");
}

static void TestAnimations(NSURL *directory) {
    NSURL *URL = [directory URLByAppendingPathComponent:@"animations.plist"];
    NSDate *now = NSDate.date;
    ApolloAwardsStore *store = [[ApolloAwardsStore alloc] initWithFileURL:URL];
    NSArray *valid = @[@"https://i.redd.it/snoovatar/snoo_assets/marketing/a.json",
                      @"https://www.redditstatic.com/marketplace-assets/v1/core/awards/3d/a.json"];
    for (NSUInteger index = 0; index < valid.count; index++) {
        NSMutableDictionary *award = [Award(1) mutableCopy];
        NSMutableString *source = [valid[index] mutableCopy];
        award[@"animation_url"] = source;
        NSString *key = [NSString stringWithFormat:@"t3_animated%lu", (unsigned long)index];
        [store storeAwards:@[award] forFullName:key atDate:now];
        [source appendString:@"?changed=1"];
        CHECK([[store awardsForFullName:key allowStale:NO now:now][0][@"animation_url"] isEqual:valid[index]], @"animation deeply copied");
    }
    [store save];
    store = [[ApolloAwardsStore alloc] initWithFileURL:URL];
    [store load];
    for (NSUInteger index = 0; index < valid.count; index++) {
        NSString *key = [NSString stringWithFormat:@"t3_animated%lu", (unsigned long)index];
        CHECK([[store awardsForFullName:key allowStale:NO now:now][0][@"animation_url"] isEqual:valid[index]], @"valid animation survives disk reload");
    }
    NSArray *invalid = @[@42, @[], NSNull.null, @"", @"http://i.redd.it/snoovatar/snoo_assets/marketing/a.json",
        @"https://evil.example/snoovatar/snoo_assets/marketing/a.json",
        @"https://u:p@i.redd.it/snoovatar/snoo_assets/marketing/a.json",
        @"https://i.redd.it:443/snoovatar/snoo_assets/marketing/a.json",
        @"https://i.redd.it/snoovatar/snoo_assets/marketing/a.json?x=1",
        @"https://i.redd.it/snoovatar/snoo_assets/marketing/a.json#x",
        @"https://i.redd.it/snoovatar/snoo_assets/marketing/../a.json",
        @"https://i.redd.it/snoovatar/snoo_assets/marketing/./a.json",
        @"https://i.redd.it/snoovatar/snoo_assets/marketing/%61.json",
        @"https://i.redd.it/snoovatar/snoo_assets/marketing/a_128.png",
        @"https://i.redd.it/untrusted/a.json",
        @"https://www.redditstatic.com/shreddit/assets/marketplace/contributor-program/empty-leaderboard.json",
        [@"https://i.redd.it/snoovatar/snoo_assets/marketing/" stringByAppendingString:
            [[@"a" stringByPaddingToLength:2048 withString:@"a" startingAtIndex:0] stringByAppendingString:@".json"]]];
    NSMutableDictionary *records = [NSMutableDictionary new];
    for (NSUInteger index = 0; index < invalid.count; index++) {
        NSMutableDictionary *award = [Award(1) mutableCopy];
        award[@"animation_url"] = invalid[index];
        NSString *key = [NSString stringWithFormat:@"t3_invalid%lu", (unsigned long)index];
        [store storeAwards:@[award] forFullName:key atDate:now];
        CHECK([[store awardsForFullName:key allowStale:NO now:now] isEqual:@[Award(1)]], @"invalid optional animation preserves static cache entry");
        // NSNull cannot occur in a property list, but the mutation API must
        // also tolerate malformed optional values supplied by a caller.
        if (invalid[index] != NSNull.null) records[key] = Record(@[award], now);
    }
    WriteRecords(URL, records);
    store = [[ApolloAwardsStore alloc] initWithFileURL:URL];
    [store load];
    for (NSString *key in records) {
        CHECK([[store awardsForFullName:key allowStale:NO now:now] isEqual:@[Award(1)]], @"invalid persisted animation omitted on load");
    }
}

static void TestBounds(NSURL *directory) {
    NSURL *URL = [directory URLByAppendingPathComponent:@"bounds.plist"];
    ApolloAwardsStore *store = [[ApolloAwardsStore alloc] initWithFileURL:URL];
    NSDate *now = NSDate.date;
    for (NSUInteger index = 0; index < 550; index++) {
        [store storeAwards:@[Award(1)] forFullName:[NSString stringWithFormat:@"t3_%04lu", (unsigned long)index]
                    atDate:[now dateByAddingTimeInterval:(NSTimeInterval)index - 550]];
    }
    NSUInteger remaining = 0;
    for (NSUInteger index = 0; index < 550; index++) {
        if ([store awardsForFullName:[NSString stringWithFormat:@"t3_%04lu", (unsigned long)index] allowStale:YES now:now]) remaining++;
    }
    CHECK(remaining == 500, @"memory entry limit holds");
    CHECK([store awardsForFullName:@"t3_0000" allowStale:YES now:now] == nil, @"oldest entry evicted");
    CHECK([store awardsForFullName:@"t3_0549" allowStale:YES now:now] != nil, @"newest entry retained");
    [store save];
    CHECK([ReadRoot(URL)[@"entries"] count] == 500, @"disk entry limit holds");

    store = [[ApolloAwardsStore alloc] initWithFileURL:URL];
    NSMutableArray *large = [NSMutableArray new];
    NSString *padding = [@"x" stringByPaddingToLength:1850 withString:@"x" startingAtIndex:0];
    for (NSUInteger index = 0; index < 128; index++) {
        NSMutableDictionary *award = [Award((NSInteger)index) mutableCopy];
        NSString *icon = [NSString stringWithFormat:@"https://i.redd.it/snoovatar/snoo_assets/marketing/%@%lu_128.png", padding, (unsigned long)index];
        award[@"icon_url"] = icon;
        award[@"resized_icons"] = @[@{@"url": icon, @"width": @128, @"height": @128}];
        [large addObject:award];
    }
    for (NSUInteger index = 0; index < 24; index++) {
        [store storeAwards:large forFullName:[NSString stringWithFormat:@"t3_big%lu", (unsigned long)index]
                    atDate:[now dateByAddingTimeInterval:(NSTimeInterval)index - 24]];
    }
    remaining = 0;
    for (NSUInteger index = 0; index < 24; index++) {
        if ([store awardsForFullName:[NSString stringWithFormat:@"t3_big%lu", (unsigned long)index] allowStale:YES now:now]) remaining++;
    }
    CHECK(remaining > 0 && remaining < 24, @"memory byte budget evicts large entries");
    CHECK([store awardsForFullName:@"t3_big23" allowStale:YES now:now] != nil, @"byte eviction retains newest");
    [store save];
    CHECK([NSData dataWithContentsOfURL:URL].length <= 2 * 1024 * 1024, @"persisted file stays within 2 MiB");
    CHECK([ReadRoot(URL)[@"entries"] count] == remaining, @"bounded snapshot successfully saved");
    ApolloAwardsStore *loaded = [[ApolloAwardsStore alloc] initWithFileURL:URL];
    [loaded load];
    CHECK([loaded awardsForFullName:@"t3_big23" allowStale:YES now:now] != nil, @"large bounded snapshot reloads");
    [[NSMutableData dataWithLength:2 * 1024 * 1024 + 1] writeToURL:URL atomically:YES];
    loaded = [[ApolloAwardsStore alloc] initWithFileURL:URL];
    [loaded load];
    CHECK([loaded awardsForFullName:@"t3_big23" allowStale:YES now:now] == nil, @"oversized file ignored");
}

int main(void) {
    @autoreleasepool {
        NSURL *directory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
        [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];
        TestLifetimes(directory);
        TestFreshnessInvalidation(directory);
        TestMergeAndInvalidData(directory);
        TestImmutableAndConcurrent(directory);
        TestAnimations(directory);
        TestBounds(directory);
        [NSFileManager.defaultManager removeItemAtURL:directory error:nil];
        printf("Awards store: %d checks, %d failures\n", sChecks, sFailures);
    }
    return sFailures ? 1 : 0;
}
