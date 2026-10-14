#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "ApolloClasses.h"
#import "ApolloCommon.h"
#import "ApolloMemoryDiagnostics.h"
#import "ApolloSubredditListIcons.h"

// Native stand-ins only. The runner separately compiles the complete production
// Logos source with the internal generator and the real archive parser.
static NSUInteger sAssertions;
static NSUInteger sFailures;
static void Check(BOOL condition, NSString *message) {
    sAssertions++;
    if (!condition) {
        sFailures++;
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    }
}

static void PumpUntil(BOOL (^condition)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2.0];
    do {
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.002]];
    } while (!condition() && [deadline timeIntervalSinceNow] > 0);
}

static void DrainMainQueue(void) {
    __block BOOL complete = NO;
    dispatch_async(dispatch_get_main_queue(), ^{ complete = YES; });
    PumpUntil(^BOOL { return complete; });
}

@interface IconTestResult : NSObject
@property(nonatomic, strong) UIImage *image;
@end
@implementation IconTestResult
@end

@interface IconTestRequest : NSObject
@property(nonatomic, copy) NSString *key;
@property(nonatomic, copy) void (^completion)(id);
@end
@implementation IconTestRequest
@end

@interface PINMemoryCache : NSObject
@property(nonatomic, strong) NSMutableDictionary<NSString *, id> *objects;
@property(nonatomic) NSUInteger costLimit;
@property(nonatomic) NSUInteger lastStoredCost;
- (id)objectForKey:(NSString *)key;
- (void)setObject:(id)object forKey:(NSString *)key withCost:(NSUInteger)cost;
- (void)removeAllObjects;
@end
@implementation PINMemoryCache
- (instancetype)init {
    if ((self = [super init])) _objects = [NSMutableDictionary dictionary];
    return self;
}
- (id)objectForKey:(NSString *)key { return self.objects[key]; }
- (void)setObject:(id)object forKey:(NSString *)key withCost:(NSUInteger)cost {
    self.objects[key] = object;
    self.lastStoredCost = cost;
}
- (void)removeAllObjects {
    [self.objects removeAllObjects];
    self.lastStoredCost = 0;
}
@end

@interface PINDiskCache : NSObject {
    NSMutableDictionary<NSString *, id> *_stored;
}
@property(nonatomic, readonly) NSDictionary<NSString *, id> *objects;
@property(nonatomic) NSUInteger byteLimit;
@property(nonatomic) NSTimeInterval ageLimit;
@property(nonatomic, strong) NSMutableArray<NSString *> *readKeys;
@property(atomic) NSUInteger storedObjects;
@property(atomic) NSUInteger clearCount;
@property(atomic) BOOL writeStarted;
@property(atomic, strong) dispatch_semaphore_t blockedWriteGate;
- (void)objectForKeyAsync:(NSString *)key completion:(void (^)(id, NSString *, id))completion;
- (void)setObject:(id)object forKey:(NSString *)key;
- (void)removeAllObjects;
@end
@implementation PINDiskCache
- (instancetype)init {
    if ((self = [super init])) {
        _stored = [NSMutableDictionary dictionary];
        _readKeys = [NSMutableArray array];
    }
    return self;
}
- (NSDictionary<NSString *, id> *)objects {
    @synchronized (self) { return [_stored copy]; }
}
- (void)objectForKeyAsync:(NSString *)key completion:(void (^)(id, NSString *, id))completion {
    [self.readKeys addObject:key];
    id object = self.objects[key];
    dispatch_async(dispatch_get_main_queue(), ^{ completion(self, key, object); });
}
- (void)setObject:(id)object forKey:(NSString *)key {
    dispatch_semaphore_t gate = self.blockedWriteGate;
    if (gate) {
        self.writeStarted = YES;
        dispatch_semaphore_wait(gate, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    }
    @synchronized (self) {
        _stored[key] = object;
        self.storedObjects++;
    }
}
- (void)removeAllObjects {
    @synchronized (self) {
        [_stored removeAllObjects];
        self.clearCount++;
    }
}
@end

@interface PINCache : NSObject
@property(nonatomic, copy) NSString *name;
@property(nonatomic, strong) PINMemoryCache *memoryCache;
@property(nonatomic, strong) PINDiskCache *diskCache;
- (instancetype)initWithName:(NSString *)name;
@end
static PINCache *sDedicatedCache;
@implementation PINCache
- (instancetype)initWithName:(NSString *)name {
    if ((self = [super init])) {
        _name = [name copy];
        _memoryCache = [PINMemoryCache new];
        _diskCache = [PINDiskCache new];
        sDedicatedCache = self;
    }
    return self;
}
@end

@interface PINRemoteImageManager : NSObject
@property(nonatomic, strong) NSMutableDictionary<NSString *, UIImage *> *memory;
@property(nonatomic, strong) NSMutableArray<IconTestRequest *> *pending;
@property(nonatomic, strong) NSMutableArray<NSURL *> *warmURLs;
@property(nonatomic) NSUInteger synchronousReads;
@property(nonatomic, strong) NSMutableDictionary<NSString *, UIImage *> *downloads;
@property(nonatomic) NSUInteger nativeDownloads;
- (NSString *)cacheKeyForURL:(NSURL *)URL processorKey:(NSString *)processorKey;
- (id)synchronousImageFromCacheWithCacheKey:(NSString *)key options:(NSUInteger)options;
- (void)imageFromCacheWithCacheKey:(NSString *)key options:(NSUInteger)options completion:(void (^)(id))completion;
- (void)imageFromCacheWithURL:(NSURL *)URL processorKey:(NSString *)processorKey options:(NSUInteger)options completion:(void (^)(id))completion;
- (void)completeKey:(NSString *)key image:(UIImage *)image;
- (NSUUID *)downloadImageWithURL:(NSURL *)URL completion:(void (^)(id))completion;
@end

@implementation PINRemoteImageManager
- (instancetype)init {
    if ((self = [super init])) {
        _memory = [NSMutableDictionary dictionary];
        _pending = [NSMutableArray array];
        _warmURLs = [NSMutableArray array];
        _downloads = [NSMutableDictionary dictionary];
    }
    return self;
}
- (NSString *)cacheKeyForURL:(NSURL *)URL processorKey:(NSString *)processorKey {
    return processorKey ? [NSString stringWithFormat:@"%@|%@", URL.absoluteString, processorKey] : URL.absoluteString;
}
- (id)synchronousImageFromCacheWithCacheKey:(NSString *)key options:(NSUInteger)options {
    self.synchronousReads++;
    IconTestResult *result = [IconTestResult new];
    result.image = self.memory[key];
    return result;
}
- (void)imageFromCacheWithCacheKey:(NSString *)key options:(NSUInteger)options completion:(void (^)(id))completion {
    IconTestRequest *request = [IconTestRequest new];
    request.key = key;
    request.completion = completion;
    [self.pending addObject:request];
}
- (void)imageFromCacheWithURL:(NSURL *)URL processorKey:(NSString *)processorKey options:(NSUInteger)options completion:(void (^)(id))completion {
    [self.warmURLs addObject:URL];
    // Warming is deliberately inert: restoration must use the actual cell
    // request's key, and disk completions remain under the test's control.
    completion([IconTestResult new]);
}
- (void)completeKey:(NSString *)key image:(UIImage *)image {
    DrainMainQueue();
    NSMutableArray *matching = [NSMutableArray array];
    for (IconTestRequest *request in [self.pending copy]) {
        if ([request.key isEqualToString:key]) {
            [matching addObject:request];
            [self.pending removeObject:request];
        }
    }
    // PIN is permitted to deliver disk results from a background queue.
    dispatch_sync(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        for (IconTestRequest *request in matching) {
            IconTestResult *result = [IconTestResult new];
            result.image = image;
            request.completion(result);
        }
    });
}
- (NSUUID *)downloadImageWithURL:(NSURL *)URL completion:(void (^)(id))completion {
    self.nativeDownloads++;
    IconTestResult *result = [IconTestResult new];
    result.image = self.downloads[URL.absoluteString];
    if (completion) completion(result);
    return [NSUUID UUID];
}
@end

@interface ASPINRemoteImageDownloader : NSObject
+ (instancetype)sharedDownloader;
- (PINRemoteImageManager *)sharedPINRemoteImageManager;
@end
@implementation ASPINRemoteImageDownloader
+ (instancetype)sharedDownloader {
    static ASPINRemoteImageDownloader *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [self new]; });
    return instance;
}
- (PINRemoteImageManager *)sharedPINRemoteImageManager {
    static PINRemoteImageManager *manager;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ manager = [PINRemoteImageManager new]; });
    return manager;
}
@end

@interface IconTestImageView : UIImageView
@end
@implementation IconTestImageView
- (UITraitCollection *)traitCollection {
    return [UITraitCollection traitCollectionWithDisplayScale:3.0];
}
@end

@interface RedditListTableViewCell : UITableViewCell {
@public
    UIImageView *subredditIconImageView;
}
@property(nonatomic) NSUInteger nativeReuseCalls;
@end
@implementation RedditListTableViewCell
- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"icon-test"])) {
        subredditIconImageView = [IconTestImageView new];
    }
    return self;
}
- (void)prepareForReuse {
    self.nativeReuseCalls++;
    [super prepareForReuse];
}
@end

@interface RedditListViewController : UIViewController
@property(nonatomic, strong) RedditListTableViewCell *testCell;
@property(nonatomic, strong) NSURL *testURL;
@property(nonatomic, strong) UIImage *placeholder;
@property(nonatomic) NSUInteger nativeConfigurations;
@property(nonatomic) BOOL processedRequestFirst;
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath;
@end
@implementation RedditListViewController
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; }
- (void)viewDidAppear:(BOOL)animated { [super viewDidAppear:animated]; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    self.nativeConfigurations++;
    RedditListTableViewCell *cell = self.testCell ?: [RedditListTableViewCell new];
    cell->subredditIconImageView.image = self.placeholder;
    PINRemoteImageManager *manager = [[ASPINRemoteImageDownloader sharedDownloader] sharedPINRemoteImageManager];
    if (self.processedRequestFirst) {
        [manager cacheKeyForURL:[NSURL URLWithString:@"https://icons.invalid/unrelated.png"] processorKey:@"thumbnail"];
    }
    if (self.testURL) [manager cacheKeyForURL:self.testURL processorKey:nil];
    return cell;
}
@end

Class ApolloClassRedditListTableViewCell;
Class ApolloClassRedditListViewController;
// Match ApolloClasses.m's position before the hook object in the link order.
__attribute__((constructor)) static void ResolveMockNativeClasses(void) {
    ApolloClassRedditListTableViewCell = objc_getClass("RedditListTableViewCell");
    ApolloClassRedditListViewController = objc_getClass("RedditListViewController");
}
void ApolloLogEmit(os_log_type_t type, NSString *format, ...) {}
static void (^sPurgeHandler)(void);
void ApolloMemoryRegisterPurgeHandler(NSString *name, void (^handler)(void)) {
    if ([name isEqualToString:@"subreddit-list-icons"]) sPurgeHandler = [handler copy];
}

static NSURL *URL(NSString *name) {
    return [NSURL URLWithString:[NSString stringWithFormat:@"https://icons.invalid/%@.png", name]];
}
static void ClearDedicatedCache(void) {
    NSUInteger previous = sDedicatedCache.diskCache.clearCount;
    ApolloSubredditListIconsClearCache();
    PumpUntil(^BOOL { return sDedicatedCache.diskCache.clearCount > previous; });
}
static UIImage *SolidImage(UIColor *color) {
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = 1;
    return [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(28, 28) format:format]
        imageWithActions:^(UIGraphicsImageRendererContext *context) {
            [color setFill];
            CGContextFillRect(context.CGContext, CGRectMake(0, 0, 28, 28));
        }];
}
static UIImage *TransparentImage(void) {
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = 1;
    format.opaque = NO;
    return [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(28, 28) format:format]
        imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {}];
}
static void SeedMetadata(NSArray *entries, NSArray *favorites) {
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:entries requiringSecureCoding:YES error:NULL];
    [[NSUserDefaults standardUserDefaults] setVolatileDomain:@{
        @"SubredditIconData": data, @"FavoriteSubreddits": favorites ?: @[]
    } forName:NSArgumentDomain];
}
static RedditListTableViewCell *Configure(RedditListViewController *controller, NSURL *url,
                                          RedditListTableViewCell *cell) {
    controller.testURL = url;
    controller.testCell = cell;
    return (RedditListTableViewCell *)[controller tableView:nil cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
}
static void Pixel(UIImage *image, NSUInteger x, NSUInteger y, uint8_t rgba[4]) {
    size_t width = CGImageGetWidth(image.CGImage), height = CGImageGetHeight(image.CGImage);
    if (!image || x >= width || y >= height) {
        memset(rgba, 0, 4);
        Check(NO, @"pixel sample is within a successfully restored bitmap");
        return;
    }
    NSMutableData *bytes = [NSMutableData dataWithLength:width * height * 4];
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(bytes.mutableBytes, width, height, 8, width * 4,
        space, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image.CGImage);
    memcpy(rgba, (uint8_t *)bytes.mutableBytes + (y * width + x) * 4, 4);
    CGContextRelease(context);
    CGColorSpaceRelease(space);
}

int main(void) {
    @autoreleasepool {
        PINRemoteImageManager *manager = [[ASPINRemoteImageDownloader sharedDownloader] sharedPINRemoteImageManager];
        UIImage *red = SolidImage(UIColor.redColor);
        UIImage *green = SolidImage(UIColor.greenColor);
        UIImage *placeholder = SolidImage(UIColor.grayColor);
        SeedMetadata(@[
            @[@"memory", URL(@"memory"), NSNull.null],
            @[@"disk", URL(@"disk"), NSNull.null],
            @[@"other", URL(@"other"), NSNull.null],
            @[@"fill", URL(@"fill"), @"00FF00"],
            @[@"empty", URL(@"empty"), @""],
            @[@"transparent", URL(@"transparent"), NSNull.null],
            @[@"sharedone", URL(@"shared"), @"FF0000"],
            @[@"sharedtwo", URL(@"shared"), @"00FF00"]
        ], @[@"memory"]);
        manager.memory[URL(@"memory").absoluteString] = red;
        manager.memory[URL(@"other").absoluteString] = green;
        RedditListViewController *controller = [RedditListViewController new];
        controller.placeholder = placeholder;

        // First list construction can beat the asynchronous tracker decode.
        RedditListTableViewCell *cold = Configure(controller, URL(@"memory"), nil);
        RedditListTableViewCell *coldReused = Configure(controller, URL(@"memory"), nil);
        [coldReused prepareForReuse];
        RedditListTableViewCell *coldShortcut = Configure(controller, URL(@"memory"), nil);
        Configure(controller, nil, coldShortcut);
        PumpUntil(^BOOL { return manager.warmURLs.count > 0 && cold->subredditIconImageView.image != placeholder; });
        Check(cold->subredditIconImageView.image != placeholder, @"cold-start cell is restored when metadata arrives");
        Check(coldReused->subredditIconImageView.image == placeholder, @"cold metadata arrival respects prepareForReuse");
        Check(coldShortcut->subredditIconImageView.image == placeholder, @"cold metadata arrival respects no-icon reconfiguration");
        Check([sDedicatedCache.diskCache.readKeys.firstObject isEqual:URL(@"memory").absoluteString],
              @"favorite icons warm before the alphabetical list");
        Check([sDedicatedCache.name isEqualToString:@"ApolloRebornSubredditListIcons-v1"],
              @"subreddit artwork uses its own persistent cache namespace");
        Check(sDedicatedCache.memoryCache.costLimit == 4 * 1024 * 1024 &&
              sDedicatedCache.diskCache.byteLimit == 12 * 1024 * 1024,
              @"dedicated icon cache has explicit memory and disk budgets");
        Check(sDedicatedCache.diskCache.ageLimit == 0, @"persistent icons use size eviction rather than expiring between app launches");

        controller.processedRequestFirst = YES;
        ClearDedicatedCache();
        NSUInteger reads = manager.synchronousReads;
        RedditListTableViewCell *first = Configure(controller, URL(@"memory"), nil);
        Check(first->subredditIconImageView.image != placeholder, @"memory hit is visible before cellForRow returns");
        Check(manager.synchronousReads == reads + 1, @"processed requests do not steal the row's original cache key");
        UIImage *rendered = first->subredditIconImageView.image;
        Check(CGSizeEqualToSize(rendered.size, CGSizeMake(28, 28)), @"rendered icon keeps native 28-point geometry");
        Check(rendered.scale == 3 && CGImageGetWidth(rendered.CGImage) == 84, @"rendered icon uses the image view's display scale");
        uint8_t rgba[4];
        Pixel(rendered, 0, 0, rgba);
        Check(rgba[3] == 0, @"rendered icon clips corners to the native circle");
        Pixel(rendered, 42, 42, rgba);
        Check(rgba[0] > 240 && rgba[1] < 10 && rgba[3] > 240, @"memory restoration draws the cached artwork");

        RedditListViewController *otherAccount = [RedditListViewController new];
        otherAccount.placeholder = placeholder;
        RedditListTableViewCell *accountCell = Configure(otherAccount, URL(@"memory"), nil);
        Check(accountCell->subredditIconImageView.image != placeholder, @"new account controller immediately reuses the shared cached icon");
        UIImage *before = accountCell->subredditIconImageView.image;
        Configure(otherAccount, URL(@"memory"), accountCell);
        Check(accountCell->subredditIconImageView.image != placeholder && accountCell->subredditIconImageView.image != before,
              @"re-entering or reconfiguring an existing row restores before display");

        [manager.memory removeObjectForKey:URL(@"memory").absoluteString];
        RedditListTableViewCell *independent = Configure(otherAccount, URL(@"memory"), nil);
        Check(independent->subredditIconImageView.image != placeholder,
              @"dedicated icon memory survives general media cache eviction");
        Check(sPurgeHandler != nil, @"dedicated icon memory participates in memory-warning purging");
        PumpUntil(^BOOL { return sDedicatedCache.diskCache.objects[URL(@"memory").absoluteString] != nil; });
        if (sPurgeHandler) sPurgeHandler();
        Check(sDedicatedCache.memoryCache.objects.count == 0 && sDedicatedCache.diskCache.objects.count > 0,
              @"memory warning drops decoded thumbnails while retaining their disk copies");
        RedditListTableViewCell *persisted = Configure(otherAccount, URL(@"memory"), nil);
        PumpUntil(^BOOL { return persisted->subredditIconImageView.image != placeholder; });
        Check(persisted->subredditIconImageView.image != placeholder,
              @"dedicated disk restores the icon when both memory caches are empty");
        Check(sDedicatedCache.memoryCache.lastStoredCost > 0,
              @"restored disk thumbnail is charged against its decoded-memory budget");

        ClearDedicatedCache();
        RedditListTableViewCell *disk = Configure(controller, URL(@"disk"), nil);
        Check(disk->subredditIconImageView.image == placeholder, @"uncached disk path initially preserves native placeholder");
        [manager completeKey:URL(@"disk").absoluteString image:red];
        DrainMainQueue();
        Check(disk->subredditIconImageView.image != placeholder, @"asynchronous disk hit updates the still-bound cell");

        ClearDedicatedCache();
        RedditListTableViewCell *reused = Configure(controller, URL(@"disk"), nil);
        [reused prepareForReuse];
        [manager completeKey:URL(@"disk").absoluteString image:red];
        DrainMainQueue();
        Check(reused->subredditIconImageView.image == placeholder, @"prepareForReuse rejects delayed artwork");
        Check(reused.nativeReuseCalls == 1, @"reuse hook preserves the native method");

        ClearDedicatedCache();
        RedditListTableViewCell *reconfigured = Configure(controller, URL(@"disk"), nil);
        Configure(controller, URL(@"other"), reconfigured);
        UIImage *otherImage = reconfigured->subredditIconImageView.image;
        [manager completeKey:URL(@"disk").absoluteString image:red];
        DrainMainQueue();
        Check(reconfigured->subredditIconImageView.image == otherImage, @"reconfiguration rejects a previous community's late result");

        ClearDedicatedCache();
        RedditListTableViewCell *shortcut = Configure(controller, URL(@"disk"), nil);
        Configure(controller, nil, shortcut);
        [manager completeKey:URL(@"disk").absoluteString image:red];
        DrainMainQueue();
        Check(shortcut->subredditIconImageView.image == placeholder, @"no-request shortcut invalidates any old icon binding");
        ClearDedicatedCache();
        RedditListTableViewCell *miss = Configure(controller, URL(@"disk"), nil);
        [manager completeKey:URL(@"disk").absoluteString image:nil];
        DrainMainQueue();
        Check(miss->subredditIconImageView.image == placeholder, @"a complete cache miss retains native placeholder behavior");
        manager.memory[URL(@"unknown").absoluteString] = red;
        manager.memory[URL(@"shared").absoluteString] = red;
        Check(Configure(controller, URL(@"unknown"), nil)->subredditIconImageView.image == placeholder,
              @"unknown tracker metadata preserves native rendering");
        Check(Configure(controller, URL(@"shared"), nil)->subredditIconImageView.image == placeholder,
              @"shared URL with conflicting community colors preserves native rendering");

        manager.memory[URL(@"fill").absoluteString] = TransparentImage();
        manager.memory[URL(@"empty").absoluteString] = TransparentImage();
        manager.memory[URL(@"transparent").absoluteString] = TransparentImage();
        Pixel(Configure(controller, URL(@"fill"), nil)->subredditIconImageView.image, 42, 42, rgba);
        Check(rgba[1] > 240 && rgba[0] < 10 && rgba[3] > 240, @"transparent icon receives its native tracker background color");
        Pixel(Configure(controller, URL(@"empty"), nil)->subredditIconImageView.image, 42, 42, rgba);
        Check(rgba[0] < 10 && rgba[1] < 10 && rgba[2] < 10 && rgba[3] > 240,
              @"present empty color string follows native black parsing");
        Pixel(Configure(controller, URL(@"transparent"), nil)->subredditIconImageView.image, 42, 42, rgba);
        Check(rgba[3] == 0, @"absent optional color preserves transparency");

        UIGraphicsImageRendererFormat *wideFormat = [UIGraphicsImageRendererFormat defaultFormat];
        wideFormat.scale = 1;
        ClearDedicatedCache();
        manager.memory[URL(@"memory").absoluteString] = [[[UIGraphicsImageRenderer alloc]
            initWithSize:CGSizeMake(84, 28) format:wideFormat] imageWithActions:^(UIGraphicsImageRendererContext *context) {
                [UIColor.redColor setFill]; CGContextFillRect(context.CGContext, CGRectMake(0, 0, 28, 28));
                [UIColor.greenColor setFill]; CGContextFillRect(context.CGContext, CGRectMake(28, 0, 28, 28));
                [UIColor.blueColor setFill]; CGContextFillRect(context.CGContext, CGRectMake(56, 0, 28, 28));
            }];
        Pixel(Configure(controller, URL(@"memory"), nil)->subredditIconImageView.image, 18, 42, rgba);
        Check(rgba[1] > 240 && rgba[0] < 10 && rgba[2] < 10, @"wide artwork uses centered aspect-fill rather than a stretch");

        ClearDedicatedCache();
        RedditListTableViewCell *downloadedCell = Configure(controller, URL(@"disk"), nil);
        manager.downloads[URL(@"disk").absoluteString] = green;
        NSUInteger nativeDownloads = manager.nativeDownloads;
        __block NSUInteger callbacks = 0;
        __block UIImage *callbackImage;
        NSUUID *requestToken = [manager downloadImageWithURL:URL(@"disk") completion:^(IconTestResult *result) {
            callbacks++;
            callbackImage = result.image;
        }];
        Check(requestToken != nil && manager.nativeDownloads == nativeDownloads + 1 && callbacks == 1 && callbackImage == green,
              @"download hook preserves the native request and original callback result");
        DrainMainQueue();
        UIImage *thumbnail = sDedicatedCache.memoryCache.objects[URL(@"disk").absoluteString];
        Check([thumbnail isKindOfClass:UIImage.class] && CGImageGetWidth(thumbnail.CGImage) == 112 &&
              CGImageGetHeight(thumbnail.CGImage) == 112 && thumbnail.scale == 1,
              @"completed native download stores only a bounded 112-pixel square thumbnail");
        Check(downloadedCell->subredditIconImageView.image != placeholder,
              @"completed native download refreshes its still-bound visible list row");
        PumpUntil(^BOOL { return sDedicatedCache.diskCache.objects[URL(@"disk").absoluteString] == thumbnail; });
        NSUInteger storedBefore = sDedicatedCache.diskCache.storedObjects;
        manager.downloads[URL(@"feedphoto").absoluteString] = red;
        [manager downloadImageWithURL:URL(@"feedphoto") completion:^(IconTestResult *result) {
            callbacks++;
            Check(result.image == red, @"unrelated feed download callback remains unchanged");
        }];
        DrainMainQueue();
        Check(sDedicatedCache.diskCache.storedObjects == storedBefore, @"unrelated feed downloads cannot enter the dedicated icon cache");
        [manager.downloads removeObjectForKey:URL(@"disk").absoluteString];
        [manager downloadImageWithURL:URL(@"disk") completion:^(IconTestResult *result) {
            callbacks++;
            Check(result.image == nil, @"failed native download preserves its original empty result");
        }];
        DrainMainQueue();
        Check(sDedicatedCache.diskCache.storedObjects == storedBefore && callbacks == 3,
              @"failed downloads do not overwrite a cached icon or duplicate callbacks");

        // Queue an old disk read, then clear before its promotion reaches main.
        [sDedicatedCache.memoryCache removeAllObjects];
        RedditListTableViewCell *clearedDuringDisk = Configure(controller, URL(@"disk"), nil);
        ClearDedicatedCache();
        Check(sDedicatedCache.memoryCache.objects.count == 0 && sDedicatedCache.diskCache.objects.count == 0,
              @"clear-cache removes both memory and persistent icons");
        Check(clearedDuringDisk->subredditIconImageView.image == placeholder,
              @"clear-cache rejects a disk result already in flight");

        // Queue a clear before a native completion's main-queue cache write.
        Configure(controller, URL(@"disk"), nil);
        manager.downloads[URL(@"disk").absoluteString] = green;
        NSUInteger clearsBefore = sDedicatedCache.diskCache.clearCount;
        ApolloSubredditListIconsClearCache();
        [manager downloadImageWithURL:URL(@"disk") completion:^(IconTestResult *result) {
            callbacks++;
            Check(result.image == green, @"clear-cache does not swallow an in-flight native callback");
        }];
        PumpUntil(^BOOL { return sDedicatedCache.diskCache.clearCount > clearsBefore; });
        DrainMainQueue();
        Check(sDedicatedCache.memoryCache.objects.count == 0 && sDedicatedCache.diskCache.objects.count == 0,
              @"clear-cache rejects a native image write already in flight");

        // Simulate a slow UIImage encode already executing on the disk queue.
        // Clearing must follow it, even though the encode finishes afterwards.
        ClearDedicatedCache();
        dispatch_semaphore_t writeGate = dispatch_semaphore_create(0);
        sDedicatedCache.diskCache.blockedWriteGate = writeGate;
        sDedicatedCache.diskCache.writeStarted = NO;
        manager.memory[URL(@"disk").absoluteString] = green;
        Configure(controller, URL(@"disk"), nil);
        PumpUntil(^BOOL { return sDedicatedCache.diskCache.writeStarted; });
        Check(sDedicatedCache.diskCache.writeStarted, @"slow-write fixture reaches the real storage queue");
        clearsBefore = sDedicatedCache.diskCache.clearCount;
        ApolloSubredditListIconsClearCache();
        DrainMainQueue();
        Check(sDedicatedCache.diskCache.clearCount == clearsBefore,
              @"clear-cache is ordered after an already-running disk write");
        sDedicatedCache.diskCache.blockedWriteGate = nil;
        dispatch_semaphore_signal(writeGate);
        PumpUntil(^BOOL { return sDedicatedCache.diskCache.clearCount > clearsBefore; });
        Check(sDedicatedCache.memoryCache.objects.count == 0 && sDedicatedCache.diskCache.objects.count == 0,
              @"a slow disk write finishing after clear was requested cannot resurrect icons");
        [manager.memory removeObjectForKey:URL(@"disk").absoluteString];

        [sDedicatedCache.diskCache.readKeys removeAllObjects];
        [manager.warmURLs removeAllObjects];
        [controller viewWillAppear:NO];
        DrainMainQueue();
        Check(sDedicatedCache.diskCache.readKeys.count == 0 && manager.warmURLs.count == 0,
              @"unchanged tracker archive is not warmed again on every entry");
        NSMutableArray *many = [NSMutableArray array];
        for (NSUInteger n = 0; n < 80; n++) {
            NSString *name = [NSString stringWithFormat:@"community%02lu", (unsigned long)n];
            [many addObject:@[name, URL(name), NSNull.null]];
        }
        SeedMetadata(many, @[@"community79"]);
        [controller viewWillAppear:NO];
        PumpUntil(^BOOL { return sDedicatedCache.diskCache.readKeys.count >= 64; });
        Check(sDedicatedCache.diskCache.readKeys.count == 64, @"warm-up is bounded for large subscription lists");
        Check([sDedicatedCache.diskCache.readKeys.firstObject isEqual:URL(@"community79").absoluteString],
              @"favorites retain warm-up priority in large lists");
        Check(![sDedicatedCache.diskCache.readKeys containsObject:URL(@"community78").absoluteString],
              @"warm-up uses a stable alphabetical slice after favorites");
        [sDedicatedCache.diskCache.readKeys removeAllObjects];
        SeedMetadata(@[@[@"obsolete", URL(@"obsolete"), NSNull.null]], @[]);
        [controller viewWillAppear:NO];
        SeedMetadata(@[@[@"latest", URL(@"latest"), NSNull.null]], @[]);
        [controller viewWillAppear:NO];
        PumpUntil(^BOOL { return sDedicatedCache.diskCache.readKeys.count > 0; });
        Check(sDedicatedCache.diskCache.readKeys.count == 1 &&
              [sDedicatedCache.diskCache.readKeys.firstObject isEqual:URL(@"latest").absoluteString],
              @"a newer tracker snapshot cancels superseded metadata warming");
        Check(controller.nativeConfigurations > 0, @"production cell hook still executes the native configuration");
        printf("Subreddit list icon hooks: %lu assertions, %lu failures\n",
            (unsigned long)sAssertions, (unsigned long)sFailures);
        return sFailures ? 1 : 0;
    }
}
