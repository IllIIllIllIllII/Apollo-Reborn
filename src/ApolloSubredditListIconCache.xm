#import "ApolloSubredditListIconCache.h"
#import "ApolloCommon.h"
#import <objc/runtime.h>
#import <objc/message.h>

// Native RedditListViewController (1.15.11: sub_1006402dc) installs a
// placeholder BEFORE checking PIN's cache. Even a memory hit then goes through
// downloadImageWithURL:completion: and another main-queue dispatch. Retain the
// final 28pt bitmap so cell configuration can display it in the same turn.
//
// Keep the native downloader, disk cache, HEAD size check, crop, and background
// color. We observe the source URL during row configuration, tag successful PIN
// images, and carry that identity through the native UIGraphicsImageRenderer.
// Only a tagged bitmap assigned to a row bound to that URL enters this cache.
// Placeholders, failed downloads, and late callbacks for a different row cannot
// poison it. No Swift layouts, instruction addresses, or extra requests needed.

@interface ApolloIconCacheList : UIViewController @end
@interface ApolloIconCacheCell : UITableViewCell @end
@interface ApolloIconCacheManager : NSObject @end

static char kSourceURL, kRenderedURL, kBinding;
static NSCache<NSString *, UIImage *> *sImages;
static NSCache<NSString *, NSNumber *> *sListURLs;
static NSUInteger sHits, sMisses, sStores, sRejected;
static NSUInteger sGeneration;

@interface ApolloListIconBinding : NSObject
@property(nonatomic, copy) NSString *url;
@property(nonatomic, copy) NSString *key;
@property(nonatomic, strong) UIImage *placeholder;
@property(nonatomic, strong) UIImage *ready;
@property(nonatomic) NSUInteger generation;
@end
@implementation ApolloListIconBinding @end

// Stack scopes preserve nested calls and never leak across asynchronous work.
typedef struct ApolloIconRowScope {
    __strong NSString *url;
    struct ApolloIconRowScope *parent;
} ApolloIconRowScope;
typedef struct ApolloIconRenderScope {
    __strong NSString *url;
    BOOL ambiguous;
    struct ApolloIconRenderScope *parent;
} ApolloIconRenderScope;
static __thread ApolloIconRowScope *sRowScope;
static __thread ApolloIconRenderScope *sRenderScope;

static id ApolloIconObjectIvar(id object, const char *name) {
    Ivar ivar = object ? class_getInstanceVariable(object_getClass(object), name) : NULL;
    // These two stored properties are ObjC objects, never Swift value types.
    return ivar ? object_getIvar(object, ivar) : nil;
}

static UIImageView *ApolloIconView(id cell) {
    id view = ApolloIconObjectIvar(cell, "subredditIconImageView");
    return [view isKindOfClass:UIImageView.class] ? view : nil;
}

static void ApolloIconObserveURL(NSURL *url) {
    if (!sRowScope || ![NSThread isMainThread] || ![url isKindOfClass:NSURL.class]) return;
    NSString *key = url.absoluteString;
    if (!key.length) return;
    sRowScope->url = key;
    [sListURLs setObject:@YES forKey:key];
}

void ApolloSubredditListIconCacheClear(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ ApolloSubredditListIconCacheClear(); });
        return;
    }
    sGeneration++;
    [sImages removeAllObjects];
    ApolloLog(@"[ListIconCache] cleared rendered icons");
}

#if APOLLO_SIM_BUILD
// Read-only counters for the injected simulator regression harness.
extern "C" NSDictionary *ApolloSubredditListIconCacheDiagnostics(void) {
    return @{ @"hits": @(sHits), @"misses": @(sMisses),
              @"stores": @(sStores), @"rejected": @(sRejected) };
}
#endif

%group ApolloListIconCacheHooks
%hook ApolloIconCacheList
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    ApolloIconRowScope scope = { nil, sRowScope };
    sRowScope = &scope;
    UITableViewCell *cell = nil;
    @try {
        cell = %orig;
    } @finally {
        sRowScope = scope.parent;
    }

    UIImageView *view = ApolloIconView(cell);
    if (!view) return cell;
    objc_setAssociatedObject(view, &kBinding, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!scope.url.length || ApolloMultiredditHasCustomListIcon(view)) return cell;
    UILabel *label = ApolloIconObjectIvar(cell, "redditTitleLabel");
    if (![label isKindOfClass:UILabel.class] || !label.text.length) return cell;

    ApolloListIconBinding *binding = [ApolloListIconBinding new];
    binding.url = scope.url;
    // Same community across accounts shares art. Include the row identity and
    // display traits so two communities sharing a URL don't share their native
    // background color, and a different display scale never reuses a soft icon.
    binding.key = [NSString stringWithFormat:@"%@\n%@\n%ld/%g", label.text.lowercaseString,
                   scope.url, (long)view.traitCollection.userInterfaceStyle,
                   view.traitCollection.displayScale];
    binding.placeholder = view.image;
    binding.generation = sGeneration;
    binding.ready = [sImages objectForKey:binding.key];
    objc_setAssociatedObject(view, &kBinding, binding, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (binding.ready) {
        sHits++;
        view.image = binding.ready;
    } else {
        sMisses++;
    }
    return cell;
}
%end

%hook ApolloIconCacheCell
- (void)prepareForReuse {
    objc_setAssociatedObject(ApolloIconView(self), &kBinding, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    %orig;
}
%end

%hook ApolloIconCacheManager
- (NSString *)cacheKeyForURL:(NSURL *)url processorKey:(NSString *)processorKey {
    if (!processorKey) ApolloIconObserveURL(url);
    return %orig;
}
- (NSUUID *)downloadImageWithURL:(NSURL *)url completion:(void (^)(id))completion {
    ApolloIconObserveURL(url);
    NSString *key = url.absoluteString;
    if (!completion || !key.length || ![sListURLs objectForKey:key]) return %orig;
    // Also catches cold requests started by the native asynchronous HEAD check:
    // their URLs were recorded by cacheKeyForURL during cell configuration.
    void (^wrapped)(id) = ^(id result) {
        SEL selector = @selector(image);
        id image = [result respondsToSelector:selector]
            ? ((id (*)(id, SEL))objc_msgSend)(result, selector) : nil;
        if ([image isKindOfClass:UIImage.class]) {
            objc_setAssociatedObject(image, &kSourceURL, key, OBJC_ASSOCIATION_COPY_NONATOMIC);
        }
        completion(result);
    };
    return %orig(url, wrapped);
}
%end

%hook UIGraphicsImageRenderer
- (UIImage *)imageWithActions:(void (^)(UIGraphicsImageRendererContext *))actions {
    // Native list avatars alone use a 28 x 28 point renderer. Other rendering
    // pays only this bounds check; source-image tagging further narrows it.
    CGSize size = self.format.bounds.size;
    if (![NSThread isMainThread]) return %orig;
    if (size.width != 28.0 || size.height != 28.0) {
        // A nested renderer must not attribute its drawing to an outer icon.
        ApolloIconRenderScope *outer = sRenderScope;
        sRenderScope = NULL;
        @try {
            return %orig;
        } @finally {
            sRenderScope = outer;
        }
    }
    ApolloIconRenderScope scope = { nil, NO, sRenderScope };
    sRenderScope = &scope;
    UIImage *image = nil;
    @try {
        image = %orig;
    } @finally {
        sRenderScope = scope.parent;
    }
    if (scope.url && !scope.ambiguous) {
        objc_setAssociatedObject(image, &kRenderedURL, scope.url, OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    return image;
}
%end

%hook UIImage
- (void)drawInRect:(CGRect)rect {
    if (sRenderScope) {
        NSString *url = objc_getAssociatedObject(self, &kSourceURL);
        if (!url || (sRenderScope->url && ![sRenderScope->url isEqualToString:url])) {
            sRenderScope->ambiguous = YES;
        } else {
            sRenderScope->url = url;
        }
    }
    %orig;
}
%end

%hook UIImageView
- (void)setImage:(UIImage *)image {
    if (!sRowScope && [NSThread isMainThread]) {
        ApolloListIconBinding *binding = objc_getAssociatedObject(self, &kBinding);
        if (binding && !ApolloMultiredditHasCustomListIcon(self)) {
            if (binding.generation != sGeneration) {
                binding.ready = nil;
                binding.generation = sGeneration;
            }
            NSString *url = objc_getAssociatedObject(image, &kRenderedURL);
            if ([url isEqualToString:binding.url]) {
                binding.ready = image;
                CGImageRef bitmap = image.CGImage;
                NSUInteger cost = bitmap ? CGImageGetBytesPerRow(bitmap) * CGImageGetHeight(bitmap) : 0;
                [sImages setObject:image forKey:binding.key cost:cost];
                sStores++;
            } else if (url) {
                // An old account/row's callback still carries the OLD URL even
                // if its captured index path now points at this reused cell.
                sRejected++;
            }
            // Never replace a ready icon with a late placeholder. The baseline
            // also keeps a mismatched callback out of a still-loading row.
            if (binding.ready || url) image = binding.ready ?: binding.placeholder;
        }
    }
    %orig(image);
}
%end
%end

%ctor {
    Class list = NSClassFromString(@"Apollo.RedditListViewController");
    Class cell = NSClassFromString(@"Apollo.RedditListTableViewCell");
    Class manager = NSClassFromString(@"PINRemoteImageManager");
    if (!list || !cell || !manager ||
        !class_getInstanceMethod(manager, @selector(cacheKeyForURL:processorKey:)) ||
        !class_getInstanceMethod(manager, @selector(downloadImageWithURL:completion:))) return;
    sImages = [NSCache new];
    sImages.countLimit = 1500;
    sImages.totalCostLimit = 16 * 1024 * 1024;
    sListURLs = [NSCache new];
    sListURLs.countLimit = 4096;
    %init(ApolloListIconCacheHooks, ApolloIconCacheList = list,
          ApolloIconCacheCell = cell, ApolloIconCacheManager = manager);
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidReceiveMemoryWarningNotification
                                                    object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(__unused NSNotification *note) {
        ApolloSubredditListIconCacheClear();
    }];
    ApolloLog(@"[ListIconCache] ready-icon hooks installed (16 MB, shared across accounts)");
}
