#import <UIKit/UIKit.h>
#import <objc/message.h>
#include <atomic>

#import "ApolloClasses.h"
#import "ApolloCommon.h"
#import "ApolloNativeSubredditIcons.h"
#import "ApolloSubredditListIcons.h"
#import "ApolloMemoryDiagnostics.h"
#import "ApolloSwiftRuntime.h"

// Apollo 1.15.11: RedditListViewController's icon helper (0x1006402dc)
// installs a placeholder BEFORE looking in PIN's cache. Even a memory hit is
// delivered through an async callback that looks up the row again by index.
// Fill the returned cell before UIKit displays it. Keep tiny square thumbnails
// in a separate PINCache: Apollo caps its shared media disk cache at 50 MB, so
// feed images otherwise evict subreddit icons. The cold path reads disk
// asynchronously; it never starts another
// download or an /about request. Native loading still handles actual misses.
//
// Capture the cache key Apollo asks for while configuring the cell. Resolving
// names from section/row indices here would break moderator filters, expanded
// multireddits and the Following section's remapping. The scoped request also
// leaves letter placeholders, feed shortcuts and hidden icons alone.
@interface NSObject (ApolloSubredditListPINCache)
- (id)sharedDownloader;
- (id)sharedPINRemoteImageManager;
- (id)synchronousImageFromCacheWithCacheKey:(NSString *)key options:(NSUInteger)options;
- (void)imageFromCacheWithCacheKey:(NSString *)key options:(NSUInteger)options completion:(void (^)(id result))completion;
- (void)imageFromCacheWithURL:(NSURL *)URL processorKey:(NSString *)processorKey options:(NSUInteger)options completion:(void (^)(id result))completion;
- (id)initWithName:(NSString *)name;
- (id)objectForKey:(NSString *)key;
- (void)objectForKeyAsync:(NSString *)key completion:(void (^)(id cache, NSString *key, id object))completion;
- (void)setObject:(id)object forKey:(NSString *)key;
- (void)setObject:(id)object forKey:(NSString *)key withCost:(NSUInteger)cost;
- (void)setCostLimit:(NSUInteger)limit;
- (void)setByteLimit:(NSUInteger)limit;
- (void)setAgeLimit:(NSTimeInterval)limit;
- (void)removeAllObjects;
@end

struct ApolloListIconCapture {
    __strong id manager;
    __strong NSURL *URL;
    __strong NSString *cacheKey;
};
static __thread ApolloListIconCapture *sListIconCapture;
static Class sListIconDownloaderClass;
static const void *kListIconBindingKey = &kListIconBindingKey;

// Main-thread snapshots. Reading the tracker archive and warming disk entries
// happen away from cell construction. Keep this bounded: opening a list must
// not decode thousands of subscribed communities just to show its first page.
static NSData *sListIconTrackerBlob;
static NSDictionary<NSString *, id> *sListIconColors = @{};
static dispatch_queue_t sListIconMetadataQueue;
static NSUInteger sListIconMetadataGeneration;
static NSUInteger sListIconMemoryHits;
static NSUInteger sListIconDiskHits;
static NSHashTable<UIImageView *> *sListIconMetadataWaiters;
static NSHashTable<UIImageView *> *sListIconViews;
static NSCache<NSString *, NSNumber *> *sListIconRequestedURLs;
static id sListIconCache;
static dispatch_queue_t sListIconStorageQueue;
static std::atomic<NSUInteger> sListIconCacheGeneration{0};

@interface ApolloListIconBinding : NSObject
@property(nonatomic, strong) id manager;
@property(nonatomic, strong) NSURL *URL;
@property(nonatomic, copy) NSString *cacheKey;
@end
@implementation ApolloListIconBinding
@end

static void ApolloListIconRestoreView(UIImageView *view, ApolloListIconBinding *binding);

static NSUInteger ApolloListIconImageCost(UIImage *image) {
    return image.CGImage ? CGImageGetBytesPerRow(image.CGImage) * CGImageGetHeight(image.CGImage) : 1;
}

static UIImage *ApolloListIconMemoryImage(NSURL *URL) {
    id image = [ApolloSendObject(sListIconCache, @selector(memoryCache)) objectForKey:URL.absoluteString];
    return [image isKindOfClass:UIImage.class] ? image : nil;
}

static void ApolloListIconReadDisk(NSURL *URL, void (^completion)(UIImage *)) {
    NSUInteger generation = sListIconCacheGeneration;
    // Read disk directly: PINCache's convenience read promotes UIImage objects
    // with cost=0, which would bypass our memory budget after a cold launch.
    [ApolloSendObject(sListIconCache, @selector(diskCache)) objectForKeyAsync:URL.absoluteString
        completion:^(__unused id cache, NSString *key, id object) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != sListIconCacheGeneration) return;
            UIImage *image = [object isKindOfClass:UIImage.class] ? object : nil;
            if (image) [ApolloSendObject(sListIconCache, @selector(memoryCache))
                setObject:image forKey:key withCost:ApolloListIconImageCost(image)];
            if (completion) completion(image);
        });
    }];
}

static void ApolloListIconRemember(NSURL *URL, UIImage *image) {
    if (!image || image.size.width <= 0 || image.size.height <= 0) return;
    // Keep a square, unrounded source at up to 4x the native 28pt diameter.
    // Color and display scale are applied per row, so communities sharing an
    // image URL cannot poison each other's backgrounds. Never retain originals.
    CGFloat side = 112;
    CGFloat ratio = side / MIN(image.size.width, image.size.height);
    CGSize size = CGSizeMake(image.size.width * ratio, image.size.height * ratio);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = 1;
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side) format:format];
    UIImage *thumbnail = [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {
        [image drawInRect:CGRectMake((side - size.width) / 2, (side - size.height) / 2, size.width, size.height)];
    }];
    // Publish memory immediately. Serialize disk writes and clearing ourselves:
    // PINCache's async operations run concurrently, and an old UIImage encode
    // could otherwise finish AFTER Clear Tweak Caches and repopulate the disk.
    [ApolloSendObject(sListIconCache, @selector(memoryCache)) setObject:thumbnail
        forKey:URL.absoluteString withCost:ApolloListIconImageCost(thumbnail)];
    NSUInteger generation = sListIconCacheGeneration;
    dispatch_async(sListIconStorageQueue, ^{
        if (generation != sListIconCacheGeneration) return;
        [ApolloSendObject(sListIconCache, @selector(diskCache)) setObject:thumbnail forKey:URL.absoluteString];
    });
}

void ApolloSubredditListIconsClearCache(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        sListIconCacheGeneration++;
        [sListIconRequestedURLs removeAllObjects];
        [ApolloSendObject(sListIconCache, @selector(memoryCache)) removeAllObjects];
        if (sListIconStorageQueue) dispatch_async(sListIconStorageQueue, ^{
            [ApolloSendObject(sListIconCache, @selector(diskCache)) removeAllObjects];
        });
    });
}

static UIImage *ApolloListIconResultImage(id result) {
    id image = ApolloSendObject(result, @selector(image));
    return [image isKindOfClass:UIImage.class] ? image : nil;
}

static id ApolloListIconManager(void) {
    id downloader = ApolloSendObject(sListIconDownloaderClass, @selector(sharedDownloader));
    return ApolloSendObject(downloader, @selector(sharedPINRemoteImageManager));
}

static UIColor *ApolloListIconColor(id hex) {
    if (![hex isKindOfClass:NSString.class]) return nil;
    // Match Apollo's tracker parser, including its handling of a present but
    // unparseable color. The archive stores RGB hex without a '#' prefix.
    unsigned long long value = 0;
    [[NSScanner scannerWithString:[hex stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet]] scanHexLongLong:&value];
    return [UIColor colorWithRed:((value >> 16) & 255) / 255.0
                           green:((value >> 8) & 255) / 255.0
                            blue:(value & 255) / 255.0 alpha:1.0];
}

static UIImage *ApolloListIconDisplayImage(UIImage *image, UIColor *background, CGFloat scale) {
    if (!image || image.size.width <= 0 || image.size.height <= 0) return nil;
    // Match native helper 0x1007ad000: 28pt circle, optional tracker key color,
    // centered aspect-fill. UIImageView's intrinsic size drives row layout.
    const CGFloat side = 28.0;
    CGFloat ratio = side / MIN(image.size.width, image.size.height);
    CGSize size = CGSizeMake(image.size.width * ratio, image.size.height * ratio);
    CGRect rect = CGRectMake((side - size.width) / 2.0, (side - size.height) / 2.0,
                             size.width, size.height);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = scale > 0 ? scale : 1.0;
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc]
        initWithSize:CGSizeMake(side, side) format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGRect circle = CGRectMake(0, 0, side, side);
        CGContextAddEllipseInRect(context.CGContext, circle);
        CGContextClip(context.CGContext);
        if (background) {
            [background setFill];
            CGContextFillRect(context.CGContext, circle);
        }
        [image drawInRect:rect];
    }];
}

static void ApolloListIconRefreshMetadata(void) {
    NSData *blob = [[NSUserDefaults standardUserDefaults] objectForKey:@"SubredditIconData"];
    if (![blob isKindOfClass:NSData.class]) blob = nil;
    if (blob == sListIconTrackerBlob || [blob isEqual:sListIconTrackerBlob]) return;
    sListIconTrackerBlob = blob;
    NSUInteger generation = ++sListIconMetadataGeneration;
    NSArray *favorites = [[NSUserDefaults standardUserDefaults] stringArrayForKey:@"FavoriteSubreddits"] ?: @[];
    dispatch_async(sListIconMetadataQueue, ^{
        NSArray<NSArray *> *entries = ApolloNativeSubredditIconArtworkEntries(blob);
        NSMutableDictionary *colors = [NSMutableDictionary dictionary];
        NSMutableSet *ambiguousURLs = [NSMutableSet set];
        NSMutableDictionary *URLsByName = [NSMutableDictionary dictionary];
        for (NSArray *entry in entries) {
            URLsByName[entry[0]] = entry[1];
            NSString *key = [entry[1] absoluteString];
            if (colors[key] && ![colors[key] isEqual:entry[2]]) [ambiguousURLs addObject:key];
            colors[key] = entry[2];
        }
        // Colors belong to communities, not URLs. If two communities reuse an
        // asset with different fills, only Apollo's live tracker can choose.
        [colors removeObjectsForKeys:ambiguousURLs.allObjects];
        NSMutableOrderedSet<NSURL *> *warmURLs = [NSMutableOrderedSet orderedSet];
        for (NSString *name in favorites) {
            NSURL *URL = URLsByName[name.lowercaseString];
            if (URL) [warmURLs addObject:URL];
            if (warmURLs.count >= 64) break;
        }
        // A–Z is the normal first page after Favorites. A stable order also
        // avoids warming a different arbitrary slice of the archive each time.
        for (NSString *name in [[URLsByName allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
            if (warmURLs.count >= 64) break;
            [warmURLs addObject:URLsByName[name]];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != sListIconMetadataGeneration) return;
            sListIconColors = [colors copy];
            // Cold launch can build the first cells before the archive read
            // finishes. Revisit those exact views; never reload the table or
            // resolve a possibly different account's row by index path.
            NSArray *waitingViews = sListIconMetadataWaiters.allObjects;
            [sListIconMetadataWaiters removeAllObjects];
            for (UIImageView *view in waitingViews) {
                ApolloListIconBinding *binding = objc_getAssociatedObject(view, kListIconBindingKey);
                if (binding) ApolloListIconRestoreView(view, binding);
            }
            id manager = ApolloListIconManager();
            if (![manager respondsToSelector:@selector(imageFromCacheWithURL:processorKey:options:completion:)]) return;
            for (NSURL *URL in warmURLs) {
                NSUInteger cacheGeneration = sListIconCacheGeneration;
                ApolloListIconReadDisk(URL, ^(UIImage *saved) {
                    if (saved) return;
                    [manager imageFromCacheWithURL:URL processorKey:nil options:0 completion:^(id result) {
                        UIImage *image = ApolloListIconResultImage(result);
                        if (!image) return;
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (cacheGeneration == sListIconCacheGeneration) ApolloListIconRemember(URL, image);
                        });
                    }];
                });
            }
            ApolloLog(@"[SubredditListIcons] warming up to %lu disk-cached icons (no network)", (unsigned long)warmURLs.count);
        });
    });
}

static void ApolloListIconRestoreView(UIImageView *view, ApolloListIconBinding *binding) {
    id colorHex = sListIconColors[binding.URL.absoluteString];
    // Unknown metadata belongs to a newly discovered icon. Let Apollo draw it
    // until its tracker has persisted the URL AND the optional background color.
    if (!colorHex) {
        [sListIconMetadataWaiters addObject:view];
        return;
    }
    UIColor *background = ApolloListIconColor(colorHex);
    UIImage *saved = ApolloListIconMemoryImage(binding.URL);
    if (saved) {
        view.image = ApolloListIconDisplayImage(saved, background, view.traitCollection.displayScale);
        sListIconMemoryHits++;
        return;
    }
    id result = [binding.manager synchronousImageFromCacheWithCacheKey:binding.cacheKey options:0];
    UIImage *image = ApolloListIconResultImage(result);
    if (image) {
        ApolloListIconRemember(binding.URL, image);
        view.image = ApolloListIconDisplayImage(image, background, view.traitCollection.displayScale);
        sListIconMemoryHits++;
        return;
    }
    __weak UIImageView *weakView = view;
    NSUInteger generation = sListIconCacheGeneration;
    void (^apply)(UIImage *) = ^(UIImage *diskImage) {
        UIImageView *strongView = weakView;
        if (!strongView || objc_getAssociatedObject(strongView, kListIconBindingKey) != binding ||
            generation != sListIconCacheGeneration) return;
        strongView.image = ApolloListIconDisplayImage(diskImage, background, strongView.traitCollection.displayScale);
        sListIconDiskHits++;
    };
    ApolloListIconReadDisk(binding.URL, ^(UIImage *diskImage) {
        if (diskImage) { apply(diskImage); return; }
        [binding.manager imageFromCacheWithCacheKey:binding.cacheKey options:0 completion:^(id cachedResult) {
            UIImage *diskImage = ApolloListIconResultImage(cachedResult);
            if (!diskImage) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation != sListIconCacheGeneration) return;
                ApolloListIconRemember(binding.URL, diskImage);
                apply(diskImage);
            });
        }];
    });
}

static void ApolloListIconRestore(UITableViewCell *cell, ApolloListIconCapture *capture) {
    if (![cell isKindOfClass:ApolloClassRedditListTableViewCell]) return;
    UIImageView *view = ApolloObjectIvar(cell, "subredditIconImageView");
    if (![view isKindOfClass:UIImageView.class]) return;
    // Replace the token even for rows without an icon request. A completion
    // belongs to this configuration of this view, never merely its index path.
    ApolloListIconBinding *binding = nil;
    if (capture->cacheKey && capture->URL) {
        binding = [ApolloListIconBinding new];
        binding.manager = capture->manager;
        binding.URL = capture->URL;
        binding.cacheKey = capture->cacheKey;
    }
    [sListIconMetadataWaiters removeObject:view];
    if (binding) [sListIconViews addObject:view];
    else [sListIconViews removeObject:view];
    objc_setAssociatedObject(view, kListIconBindingKey, binding, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (binding) ApolloListIconRestoreView(view, binding);
}

%group ApolloSubredditListIconHooks
%hook PINRemoteImageManager
- (NSString *)cacheKeyForURL:(NSURL *)URL processorKey:(NSString *)processorKey {
    NSString *key = %orig;
    if (sListIconCapture && !processorKey && !sListIconCapture->cacheKey && key && URL) {
        sListIconCapture->manager = self;
        sListIconCapture->URL = URL;
        sListIconCapture->cacheKey = key;
        [sListIconRequestedURLs setObject:@YES forKey:URL.absoluteString];
    }
    return key;
}
- (NSUUID *)downloadImageWithURL:(NSURL *)URL completion:(void (^)(id result))completion {
    if (![sListIconRequestedURLs objectForKey:URL.absoluteString]) return %orig;
    NSUInteger generation = sListIconCacheGeneration;
    return %orig(URL, ^(id result) {
        UIImage *image = ApolloListIconResultImage(result);
        if (image) dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != sListIconCacheGeneration) return;
            ApolloListIconRemember(URL, image);
            for (UIImageView *view in sListIconViews.allObjects) {
                ApolloListIconBinding *binding = objc_getAssociatedObject(view, kListIconBindingKey);
                if ([binding.URL isEqual:URL]) ApolloListIconRestoreView(view, binding);
            }
        });
        if (completion) completion(result);
    });
}
%end

%hook RedditListViewController
- (void)viewWillAppear:(BOOL)animated {
    ApolloListIconRefreshMetadata();
    %orig;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    ApolloListIconCapture capture = {};
    ApolloListIconCapture *previous = sListIconCapture;
    sListIconCapture = &capture;
    UITableViewCell *cell;
    @try {
        cell = %orig;
    } @finally {
        sListIconCapture = previous;
    }
    ApolloListIconRestore(cell, &capture);
    return cell;
}
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    ApolloLog(@"[SubredditListIcons] restored from memory=%lu disk=%lu", (unsigned long)sListIconMemoryHits, (unsigned long)sListIconDiskHits);
}
%end

%hook RedditListTableViewCell
- (void)prepareForReuse {
    UIImageView *view = ApolloObjectIvar(self, "subredditIconImageView");
    if (view) {
        [sListIconMetadataWaiters removeObject:view];
        [sListIconViews removeObject:view];
        objc_setAssociatedObject(view, kListIconBindingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    %orig;
}
%end
%end

%ctor {
    Class manager = objc_getClass("PINRemoteImageManager");
    Class cacheClass = objc_getClass("PINCache");
    sListIconDownloaderClass = objc_getClass("ASPINRemoteImageDownloader");
    if (!cacheClass || !ApolloClassRedditListViewController || !ApolloClassRedditListTableViewCell ||
        ![manager instancesRespondToSelector:@selector(cacheKeyForURL:processorKey:)] ||
        ![manager instancesRespondToSelector:@selector(synchronousImageFromCacheWithCacheKey:options:)] ||
        ![manager instancesRespondToSelector:@selector(imageFromCacheWithCacheKey:options:completion:)] ||
        ![manager instancesRespondToSelector:@selector(downloadImageWithURL:completion:)]) return;
    sListIconMetadataQueue = dispatch_queue_create("com.apollofix.subreddit-list-icons", DISPATCH_QUEUE_SERIAL);
    sListIconStorageQueue = dispatch_queue_create_with_target("com.apollofix.subreddit-list-icons.disk",
        DISPATCH_QUEUE_SERIAL, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    sListIconMetadataWaiters = [NSHashTable weakObjectsHashTable];
    sListIconViews = [NSHashTable weakObjectsHashTable];
    sListIconRequestedURLs = [NSCache new];
    sListIconRequestedURLs.countLimit = 2048;
    sListIconCache = [[cacheClass alloc] initWithName:@"ApolloRebornSubredditListIcons-v1"];
    [ApolloSendObject(sListIconCache, @selector(memoryCache)) setCostLimit:4 * 1024 * 1024];
    [ApolloSendObject(sListIconCache, @selector(diskCache)) setByteLimit:12 * 1024 * 1024];
    [ApolloSendObject(sListIconCache, @selector(diskCache)) setAgeLimit:0];
    ApolloMemoryRegisterPurgeHandler(@"subreddit-list-icons", ^{
        [ApolloSendObject(sListIconCache, @selector(memoryCache)) removeAllObjects];
    });
    %init(ApolloSubredditListIconHooks, PINRemoteImageManager = manager,
          RedditListViewController = ApolloClassRedditListViewController,
          RedditListTableViewCell = ApolloClassRedditListTableViewCell);
    // Run after all ctors, including the pending native-URL refresh, but early
    // enough that disk hits can be ready before the first list presentation.
    dispatch_async(dispatch_get_main_queue(), ^{ ApolloListIconRefreshMetadata(); });
    ApolloLog(@"[SubredditListIcons] cache restoration hooks installed");
}
