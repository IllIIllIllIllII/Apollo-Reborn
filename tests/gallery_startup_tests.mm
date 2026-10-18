#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "ApolloGalleryFeed.h"
#import "ApolloHostedVideo.h"

static NSUInteger checks;
static void Check(BOOL condition, NSString *message) {
    checks++;
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}

// Environment seams only. No account access, image download, or network is
// allowed in this harness; the production feed and source code run below.
static NSString *sUserAgent;
static NSString *ApolloActiveAccountUsername(void) { return nil; }
static id ApolloActiveAccountClient(void) { return nil; }
static id ApolloWebSessionFor(NSString *username) { return nil; }
static NSString *ApolloWebJSONSyntheticBearerTokenForUsername(NSString *username) { return nil; }
static BOOL ApolloShouldBlurNSFWMediaInSubreddit(NSString *subreddit) { return YES; }
static void ApolloLog(NSString *format, ...) {}
#define ApolloLogError ApolloLog
ApolloHostedVideoKind ApolloHostedVideoKindForURL(NSURL *url) { return ApolloHostedVideoNone; }
void ApolloHostedVideoResolve(NSURL *url, void (^completion)(NSURL *, NSURL *, CGSize, BOOL)) {
    Check(NO, @"startup must not resolve a hosted video");
}

#include "GalleryFeedProduction.inc"

@interface UIViewController : NSObject
@property (nonatomic, strong) NSArray *retainedLinks;
@property (nonatomic, strong) id retainedPagination;
@end
@implementation UIViewController @end

@interface GalleryTestLink : NSObject
@property (nonatomic, getter=isNSFW) BOOL NSFW;
@property (nonatomic, getter=isSpoiler) BOOL spoiler;
@property (nonatomic, strong) GalleryTestLink *crosspostParent;
@end
@implementation GalleryTestLink @end

@interface GalleryTestPagination : NSObject
@property (nonatomic, copy) NSString *after;
@end
@implementation GalleryTestPagination @end

@interface ApolloGalleryImageRequest : NSObject
- (void)cancel;
@end
@implementation ApolloGalleryImageRequest
- (void)cancel {}
@end
static NSUInteger warmedImages;
@interface ApolloGalleryImageLoader : NSObject
+ (instancetype)sharedLoader;
- (ApolloGalleryImageRequest *)prefetchThumbnailAtURL:(NSURL *)url;
@end
@implementation ApolloGalleryImageLoader
+ (instancetype)sharedLoader { static id loader; if (!loader) loader = [self new]; return loader; }
- (ApolloGalleryImageRequest *)prefetchThumbnailAtURL:(NSURL *)url {
    warmedImages++;
    return [ApolloGalleryImageRequest new];
}
@end

static Class ApolloClassRDKLink;
static Class ApolloClassPostsViewController;
#include "GallerySourceProduction.inc"

static void WriteWord(id object, const char *name, uintptr_t word) {
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    memcpy((uint8_t *)(__bridge void *)object + ivar_getOffset(ivar), &word, sizeof(word));
}
static void WriteEnum(id object, const char *name, int64_t value, BOOL absent) {
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    uint8_t *base = (uint8_t *)(__bridge void *)object + ivar_getOffset(ivar);
    memcpy(base, &value, sizeof(value));
    base[sizeof(value)] = absent;
}
static UIViewController *Owner(NSArray *links, NSString *after) {
    UIViewController *owner = [ApolloClassPostsViewController new];
    owner.retainedLinks = [links mutableCopy]; // heap-backed NSArray, like native Swift storage
    WriteWord(owner, "links", (uintptr_t)(__bridge void *)owner.retainedLinks);
    if (after) {
        GalleryTestPagination *page = [GalleryTestPagination new];
        page.after = after;
        owner.retainedPagination = page;
    }
    WriteWord(owner, "$__lazy_storage_$_pagination", (uintptr_t)(__bridge void *)owner.retainedPagination);
    WriteEnum(owner, "currentSort", 1, NO);
    WriteEnum(owner, "currentTimeSort", 3, NO);
    return owner;
}
static NSDictionary *Photo(NSString *name) {
    return @{@"name": [@"t3_" stringByAppendingString:name], @"title": name, @"author": @"author",
             @"subreddit": @"test", @"url": [NSString stringWithFormat:@"https://i.redd.it/%@.jpg", name],
             @"over_18": @NO, @"spoiler": @NO};
}
static NSDictionary *Listing(NSArray *posts, NSString *after) {
    NSMutableArray *children = [NSMutableArray array];
    for (NSDictionary *post in posts) [children addObject:@{@"kind": @"t3", @"data": post}];
    return @{@"children": children, @"after": after ?: (id)NSNull.null};
}
static GalleryTestLink *Captured(NSDictionary *post) {
    GalleryTestLink *link = [GalleryTestLink new];
    ApolloGallerySourceRememberPost(link, post);
    return link;
}

@interface GalleryTestFeed : ApolloGalleryFeed
@property (nonatomic, copy) NSArray<NSDictionary *> *pages;
@property (nonatomic, strong) NSMutableArray *requestedCursors;
@end
@implementation GalleryTestFeed
- (void)fetchPageWithCursor:(NSString *)after completion:(void (^)(NSDictionary *, NSString *))completion {
    if (!self.requestedCursors) self.requestedCursors = [NSMutableArray array];
    NSUInteger index = self.requestedCursors.count;
    [self.requestedCursors addObject:after ?: (id)NSNull.null];
    Check(index < self.pages.count, @"feed requested only the supplied pages");
    completion(self.pages[index], nil);
}
@end
static NSRange Load(GalleryTestFeed *feed) {
    __block BOOL completed = NO;
    __block NSRange range = NSMakeRange(NSNotFound, 0);
    [feed loadNextBatchWithCompletion:^(NSRange added, NSString *error) {
        Check(error == nil, @"fixture load succeeds");
        range = added;
        completed = YES;
    }];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2];
    while (!completed && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
    }
    Check(completed, @"load completion reached the main queue");
    return range;
}

static void TestCaptureAndGuards(void) {
    NSMutableDictionary *post = [Photo(@"capture") mutableCopy];
    post[@"selftext"] = @"must not retain";
    post[@"access_token"] = @"must not retain";
    post[@"preview"] = @{@"images": @[@{@"source": @{@"url": @"https://preview.redd.it/a.jpg"},
                                            @"variants": @{@"gif": @{@"source": @{@"url": @"https://i.redd.it/a.gif"}}}}]};
    post[@"media_metadata"] = @{@"image": @{@"s": @{@"u": @"https://i.redd.it/b.jpg"}}};
    post[@"gallery_data"] = @{@"items": @[@{@"media_id": @"image"}]};
    post[@"is_gallery"] = @YES;
    post[@"crosspost_parent_list"] = @[@{@"url": @"https://i.redd.it/parent.jpg", @"over_18": @YES,
                                             @"selftext": @"omit parent text"}];
    NSDictionary *compact = ApolloGallerySourceCompactPost(@{@"kind": @"t3", @"data": post}, YES);
    Check(!compact[@"selftext"] && !compact[@"access_token"], @"capture excludes unrelated and credential fields");
    Check([compact[@"preview"] isEqual:post[@"preview"]] && [compact[@"media_metadata"] isEqual:post[@"media_metadata"]],
          @"capture preserves animation variants and gallery metadata");
    Check([compact[@"gallery_data"] isEqual:post[@"gallery_data"]] && [compact[@"is_gallery"] boolValue], @"capture preserves gallery order");
    Check(!compact[@"crosspost_parent_list"][0][@"selftext"] && [compact[@"crosspost_parent_list"][0][@"over_18"] boolValue],
          @"crosspost capture retains media/flags without unrelated text");
    Check(ApolloGallerySourceCompactPost((id)@"invalid", YES) == nil, @"non-dictionary capture rejected");

    UIViewController *owner = Owner(@[Captured(Photo(@"a"))], @"t3_a");
    Check(ApolloGallerySourceLinks(owner).count == 1, @"class-element array copied through NSArray");
    WriteWord(owner, "links", 1);
    Check(ApolloGallerySourceLinks(owner) == nil, @"small non-pointer array rejected");
    WriteWord(owner, "links", 0x4000000100000000ULL);
    Check(ApolloGallerySourceLinks(owner) == nil, @"Swift bridged/tagged array rejected before messaging");
    WriteWord(owner, "links", (uintptr_t)(__bridge void *)owner.retainedPagination);
    Check(ApolloGallerySourceLinks(owner) == nil, @"non-array object rejected");
    owner = Owner(@[], @"t3_a");
    Check(ApolloGallerySourceLinks(owner) == nil, @"empty source declined");

    owner = Owner(@[Captured(Photo(@"a"))], @"t3_a");
    NSString *after;
    Check(ApolloGallerySourceCursor(owner, &after) && [after isEqualToString:@"t3_a"], @"cursor copied");
    WriteWord(owner, "$__lazy_storage_$_pagination", 1);
    Check(!ApolloGallerySourceCursor(owner, &after), @"lazy-uninitialized sentinel rejected");
    WriteWord(owner, "$__lazy_storage_$_pagination", 0);
    Check(ApolloGallerySourceCursor(owner, &after) && after == nil, @"initialized nil means native exhaustion");
    WriteWord(owner, "$__lazy_storage_$_pagination", (uintptr_t)(__bridge void *)owner.retainedPagination);
    [(GalleryTestPagination *)owner.retainedPagination setAfter:nil];
    Check(!ApolloGallerySourceCursor(owner, &after), @"pending first-page cursor does not reuse old links");

    ApolloGallerySort sort;
    ApolloGalleryTopWindow window;
    for (int64_t raw = 1; raw <= 6; raw++) {
        WriteEnum(owner, "currentSort", raw, NO);
        Check(ApolloGallerySourceSort(owner, &sort, &window), @"supported native sort maps");
    }
    WriteEnum(owner, "currentSort", 6, NO);
    WriteEnum(owner, "currentTimeSort", 1, NO);
    Check(!ApolloGallerySourceSort(owner, &sort, &window), @"This Hour cannot seed Today");
    WriteEnum(owner, "currentTimeSort", 7, NO);
    Check(ApolloGallerySourceSort(owner, &sort, &window) && sort == ApolloGallerySortTop && window == ApolloGalleryTopWindowAll,
          @"Top All Time maps exactly");
    WriteEnum(owner, "currentSort", 1, YES);
    Check(!ApolloGallerySourceSort(owner, &sort, &window), @"absent optional sort declines seed");
}

static void TestSourceCoverageAndFlags(void) {
    GalleryTestLink *first = Captured(Photo(@"first"));
    GalleryTestLink *cold = [GalleryTestLink new];
    UIViewController *owner = Owner(@[first, cold], @"t3_end");
    Check(ApolloGallerySourceSnapshotForOwner(owner) == nil, @"one uncaptured link rejects the whole cursor snapshot");
    ApolloGallerySourceRememberPost(cold, @{@"name": @"t3_text", @"selftext": @"text only"});
    ApolloGallerySourceSnapshot *snapshot = ApolloGallerySourceSnapshotForOwner(owner);
    Check([snapshot.listing[@"children"] count] == 2, @"media-free posts still count toward complete cursor coverage");
    ApolloGalleryPrepareSource(owner);
    first.NSFW = YES;
    first.spoiler = YES;
    ApolloGalleryFeed *feed = [[ApolloGalleryFeed alloc] initWithHomeFeed];
    Check(ApolloGallerySeedFeedFromSource(feed, owner), @"complete matching snapshot seeds immediately");
    Check(feed.items.firstObject.isNSFW && feed.items.firstObject.isSpoiler, @"native flags changed after menu preparation remain live");

    GalleryTestLink *parent = Captured(Photo(@"parent"));
    GalleryTestLink *crosspost = Captured(@{@"name": @"t3_cross", @"crosspost_parent_list": @[Photo(@"parent")]});
    crosspost.crosspostParent = parent;
    owner = Owner(@[crosspost], nil);
    ApolloGalleryPrepareSource(owner);
    parent.NSFW = YES;
    feed = [[ApolloGalleryFeed alloc] initWithHomeFeed];
    Check(ApolloGallerySeedFeedFromSource(feed, owner) && feed.items.firstObject.isNSFW,
          @"crosspost parent flag changes propagate without replacing original media");
    feed = [[ApolloGalleryFeed alloc] initWithHomeFeed];
    feed.sort = ApolloGallerySortNew;
    Check(!ApolloGallerySeedFeedFromSource(feed, owner), @"mismatched sort cannot inherit source cursor");

    NSMutableArray *many = [NSMutableArray array];
    for (NSUInteger i = 0; i < 40; i++) [many addObject:Captured(Photo([NSString stringWithFormat:@"warm%lu", (unsigned long)i]))];
    warmedImages = 0;
    owner = Owner(many, @"t3_last");
    ApolloGalleryPrepareSource(owner);
    ApolloGalleryPrepareSource(owner);
    Check(warmedImages == 24, @"menu warming is bounded and coalesced across repeat preparation");
}

static void TestFeedPaging(void) {
    GalleryTestFeed *feed = [[GalleryTestFeed alloc] initWithHomeFeed];
    NSDictionary *seed = Listing(@[Photo(@"one"), Photo(@"two"), Photo(@"one")], @"t3_end");
    Check([feed seedFromListing:seed] && feed.items.count == 2, @"seed deduplicates media");
    Check([feed.items[0].postTitle isEqualToString:@"one"] && [feed.items[1].postTitle isEqualToString:@"two"], @"seed retains source ordering");
    Check(![feed seedFromListing:seed], @"populated feed cannot be reseeded");
    feed.pages = @[Listing(@[Photo(@"two"), Photo(@"three")], nil)];
    NSRange range = Load(feed);
    Check([feed.requestedCursors.firstObject isEqualToString:@"t3_end"], @"continuation starts after all seeded source posts");
    Check(range.location == 2 && range.length == 1 && feed.items.count == 3 && feed.isExhausted, @"continuation deduplicates and appends exactly once");
    [feed reset];
    Check(feed.items.count == 0 && !feed.isExhausted && !feed.isLoading, @"reset clears seed state");
    feed.pages = @[Listing(@[Photo(@"fresh")], @"t3_fresh"), Listing(@[Photo(@"unused")], nil)];
    feed.requestedCursors = nil;
    range = Load(feed);
    Check(feed.requestedCursors.firstObject == NSNull.null && feed.requestedCursors.count == 1,
          @"first cold page renders without waiting for 24 media or another request");
    Check(range.location == 0 && range.length == 1 && !feed.isExhausted, @"first cold page keeps continuation available");

    feed = [[GalleryTestFeed alloc] initWithHomeFeed];
    Check(![feed seedFromListing:Listing(@[@{@"name": @"t3_text"}], nil)] && !feed.isExhausted,
          @"media-free seed cannot exhaust fresh gallery");
    feed.pages = @[Listing(@[@{@"name": @"t3_text"}], @"t3_text"), Listing(@[Photo(@"found")], @"t3_found"),
                   Listing(@[Photo(@"unused")], nil)];
    range = Load(feed);
    Check(feed.requestedCursors.count == 2 && range.length == 1, @"cold load walks empty page then returns first usable page");
    [feed reset];
    Check([feed seedFromListing:Listing(@[Photo(@"found")], nil)] && feed.isExhausted, @"reset clears dedup keys and nil seed cursor is exhausted");
}

int main(void) {
    @autoreleasepool {
        ApolloClassRDKLink = GalleryTestLink.class;
        ApolloClassPostsViewController = objc_allocateClassPair(UIViewController.class, "GalleryTestPostsController", 0);
        class_addIvar(ApolloClassPostsViewController, "links", sizeof(uintptr_t), 3, "Q");
        class_addIvar(ApolloClassPostsViewController, "$__lazy_storage_$_pagination", sizeof(uintptr_t), 3, "Q");
        class_addIvar(ApolloClassPostsViewController, "currentSort", 9, 3, "[9C]");
        class_addIvar(ApolloClassPostsViewController, "currentTimeSort", 9, 3, "[9C]");
        objc_registerClassPair(ApolloClassPostsViewController);
        TestCaptureAndGuards();
        TestSourceCoverageAndFlags();
        TestFeedPaging();
        printf("gallery_startup_tests: %lu checks passed\n", (unsigned long)checks);
    }
    return 0;
}
