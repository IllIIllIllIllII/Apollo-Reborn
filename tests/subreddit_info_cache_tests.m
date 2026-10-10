#import <Foundation/Foundation.h>
#import <math.h>

static NSUInteger checks;
static void Check(BOOL condition, NSString *label) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", label.UTF8String);
        exit(1);
    }
    checks++;
}

static NSString *ApolloActiveAccountUsername(void) { return @"TestAccount"; }
static NSString *ApolloActiveAccountRedditBearerToken(void) { return nil; }
static NSString *sUserAgent = @"ApolloSubredditInfoTests/1.0";
#define ApolloLog(...) do {} while (0)

// INSERT_PRODUCTION_MODEL
// INSERT_PRODUCTION_CONSTANTS

@interface SubredditInfoHarness : NSObject
@property(nonatomic, strong) NSMutableDictionary<NSString *, ApolloSubredditInfo *> *diskInfo;
- (ApolloSubredditInfo *)infoFromResponseData:(NSData *)data fallbackSubredditName:(NSString *)name;
- (NSDictionary *)dictionaryForInfo:(ApolloSubredditInfo *)info;
- (ApolloSubredditInfo *)infoFromDictionary:(NSDictionary *)dict fallbackSubredditName:(NSString *)name;
- (BOOL)isFreshInfo:(ApolloSubredditInfo *)info;
- (NSURLRequest *)requestForSubreddit:(NSString *)name;
- (void)pruneDiskInfoLocked;
@end

@implementation SubredditInfoHarness
// INSERT_PRODUCTION_METHODS
@end

static ApolloSubredditInfo *Parse(SubredditInfoHarness *cache, NSDictionary *fields) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"data": fields} options:0 error:NULL];
    Check(data != nil, @"fixture is valid JSON");
    return [cache infoFromResponseData:data fallbackSubredditName:@"example"];
}

static ApolloSubredditInfo *CheckArtworkPriority(SubredditInfoHarness *cache) {
    NSString *modernIcon = @"https://styles.redditmedia.com/communityIcon.png";
    NSString *legacyIcon = @"https://b.thumbs.redditmedia.com/icon.png";
    NSString *mobileBanner = @"https://styles.redditmedia.com/mobileBanner.png";
    NSString *desktopBanner = @"https://styles.redditmedia.com/bannerBackgroundImage.png";
    NSString *legacyBanner = @"https://b.thumbs.redditmedia.com/banner.png";
    NSMutableDictionary *fields = [@{
        @"community_icon": modernIcon, @"icon_img": legacyIcon,
        @"mobile_banner_image": mobileBanner,
        @"banner_background_image": desktopBanner, @"banner_img": legacyBanner,
    } mutableCopy];
    ApolloSubredditInfo *info = Parse(cache, fields);
    Check([info.iconURL.absoluteString isEqualToString:modernIcon], @"current icon wins over legacy icon");
    Check([info.bannerURL.absoluteString isEqualToString:mobileBanner], @"mobile banner wins over desktop and legacy");

    fields[@"community_icon"] = [NSNull null];
    fields[@"mobile_banner_image"] = @"";
    ApolloSubredditInfo *fallback = Parse(cache, fields);
    Check([fallback.iconURL.absoluteString isEqualToString:legacyIcon], @"missing modern icon uses legacy icon");
    Check([fallback.bannerURL.absoluteString isEqualToString:desktopBanner], @"missing mobile banner uses desktop banner");
    fields[@"banner_background_image"] = [NSNull null];
    Check([Parse(cache, fields).bannerURL.absoluteString isEqualToString:legacyBanner],
          @"missing modern banners use legacy banner");
    return info;
}

static void CheckMetadataMigration(SubredditInfoHarness *cache, ApolloSubredditInfo *fresh) {
    NSMutableDictionary *stored = [[cache dictionaryForInfo:fresh] mutableCopy];
    ApolloSubredditInfo *restored = [cache infoFromDictionary:stored fallbackSubredditName:@"example"];
    Check([cache isFreshInfo:restored] && restored.assetSelectionVersion == 1,
          @"new metadata persists with the current artwork version");

    [stored removeObjectForKey:@"assetSelectionVersion"];
    ApolloSubredditInfo *legacy = [cache infoFromDictionary:stored fallbackSubredditName:@"example"];
    Check(![cache isFreshInfo:legacy], @"old artwork refreshes before its normal TTL expires");
    cache.diskInfo = [@{@"example": legacy} mutableCopy];
    for (NSUInteger launch = 0; launch < 2; launch++) {
        [cache pruneDiskInfoLocked];
        Check(cache.diskInfo[@"example"] == legacy, @"migration retains the entry for failed-fetch fallback");
        NSDictionary *saved = [cache dictionaryForInfo:cache.diskInfo[@"example"]];
        Check([saved[@"assetSelectionVersion"] isEqual:@0], @"saving cannot mark old artwork as refreshed");
        legacy = [cache infoFromDictionary:saved fallbackSubredditName:@"example"];
        Check(![cache isFreshInfo:legacy], @"saved old artwork still needs a refresh on relaunch");
        Check(fabs([legacy.fetchedAt timeIntervalSinceDate:fresh.fetchedAt]) < 0.001,
              @"migration preserves the original age");
        Check([legacy.iconURL isEqual:fresh.iconURL] && [legacy.bannerURL isEqual:fresh.bannerURL],
              @"cached artwork remains available offline");
        cache.diskInfo[@"example"] = legacy;
    }
    cache.diskInfo[@"example"] = fresh;
    [cache pruneDiskInfoLocked];
    restored = [cache infoFromDictionary:[cache dictionaryForInfo:cache.diskInfo[@"example"]]
                  fallbackSubredditName:@"example"];
    Check([cache isFreshInfo:restored], @"a successful refresh persists as fresh");
}

static void CheckNativeIconMigration(void) {
    NSString *suite = [@"com.apollofix.tests.icons." stringByAppendingString:NSUUID.UUID.UUIDString];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    NSData *oldIcons = [@"old icons" dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *unrelated = @{@"ShowSubredditIconsForPosts": @NO, @"UnrelatedPreference": @"preserve"};
    NSMutableDictionary *initial = [unrelated mutableCopy];
    initial[@"SubredditIconData"] = oldIcons;
    [defaults setPersistentDomain:initial forName:suite];
    Check(ApolloSubredditMigrateNativeIconCache(defaults), @"native icon cache resets once");
    NSMutableDictionary *expected = [unrelated mutableCopy];
    expected[@"ApolloSubredditNativeIconCacheVersion"] = @1;
    Check([[defaults persistentDomainForName:suite] isEqual:expected],
          @"migration removes derived icons and preserves unrelated preferences");

    NSData *newIcons = [@"current icons" dataUsingEncoding:NSUTF8StringEncoding];
    [defaults setObject:newIcons forKey:@"SubredditIconData"];
    NSUserDefaults *nextLaunch = [[NSUserDefaults alloc] initWithSuiteName:suite];
    Check(!ApolloSubredditMigrateNativeIconCache(nextLaunch), @"completed migration does not repeat");
    expected[@"SubredditIconData"] = newIcons;
    Check([[nextLaunch persistentDomainForName:suite] isEqual:expected],
          @"repopulated icons survive subsequent launches");
    [defaults removePersistentDomainForName:suite];
}

int main(void) {
    @autoreleasepool {
        SubredditInfoHarness *cache = [SubredditInfoHarness new];
        ApolloSubredditInfo *fresh = CheckArtworkPriority(cache);
        CheckMetadataMigration(cache, fresh);
        CheckNativeIconMigration();
        Check([cache requestForSubreddit:@"example"].cachePolicy == NSURLRequestReloadIgnoringLocalCacheData,
              @"metadata refresh bypasses stale HTTP responses");
        printf("PASS: %lu subreddit info cache checks\n", (unsigned long)checks);
    }
}
