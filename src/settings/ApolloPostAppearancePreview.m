#import "ApolloPostAppearancePreview.h"
#import "ApolloClasses.h"
#import "ApolloCommon.h"
#import "ApolloSwiftRuntime.h"
#import <objc/message.h>

// Texture is shipped inside Apollo, not linked into the tweak. Keep its ABI
// declarations local and obtain every concrete class from the shared table.
typedef struct { CGSize min; CGSize max; } ApolloPreviewSizeRange;
@interface NSObject (ApolloPostPreviewTexture)
- (id)layoutThatFits:(ApolloPreviewSizeRange)range;
- (CGSize)size;
- (UIView *)view;
- (NSArray *)subnodes;
- (void)setFrame:(CGRect)frame;
- (void)layoutIfNeeded;
- (void)setURL:(NSURL *)url;
- (void)setDefaultImage:(UIImage *)image;
- (void)setImage:(UIImage *)image;
@end

// Apollo 1.15.11's Objective-C initializers trap. These are the two Swift
// designated initializers called by PostSectionController's native factory.
// The link and allocated self are consumed (+1). The result is returned +1.
// See docs/post-appearance-preview-native.md for the call-site evidence.
typedef void * __attribute__((swiftcall)) (*ApolloPreviewPostInit)(
    void *link, BOOL isOnProfile, BOOL inSpecificSubreddit, BOOL isRead,
    BOOL isInModQueue, void *self __attribute__((swift_context)));

static ApolloPreviewPostInit NativePostInitializer(BOOL compact) {
    static ApolloPreviewPostInit entries[2];
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class classes[] = { ApolloClassLargePostCellNode, ApolloClassCompactPostCellNode };
        const uintptr_t anchors[] = { 0x308558, 0x7e2cac };
        const uintptr_t initializers[] = { 0x302488, 0x7dd384 };
        const uint32_t prologues[2][13] = {
            { 0xa9ba6ffc, 0xa90167fa, 0xa9025ff8, 0xa90357f6, 0xa9044ff4, 0xa9057bfd,
              0x910143fd, 0xd10243ff, 0xaa0403f9, 0xaa0303fc, 0xaa0203f7, 0xaa0103f5, 0xaa0003f8 },
            { 0xa9ba6ffc, 0xa90167fa, 0xa9025ff8, 0xa90357f6, 0xa9044ff4, 0xa9057bfd,
              0x910143fd, 0xd104c3ff, 0xaa1403f9, 0xaa0403f4, 0xaa0303f5, 0xaa0203f8, 0xaa0103f6 }
        };
        for (NSUInteger i = 0; i < 2; i++) {
            Method method = class_getInstanceMethod(classes[i], @selector(init));
            const uint8_t *anchor = method ? (const uint8_t *)method_getImplementation(method) : NULL;
            Dl_info image;
            if (!anchor || !dladdr(anchor, &image) || !image.dli_fbase ||
                anchor - (const uint8_t *)image.dli_fbase != anchors[i]) {
                ApolloLog(@"[PostAppearance] native %@ initializer unavailable", i ? @"compact" : @"large");
                continue;
            }
            const uint8_t *entry = (const uint8_t *)image.dli_fbase + initializers[i];
            if (memcmp(entry, prologues[i], sizeof(prologues[i])) != 0) {
                ApolloLog(@"[PostAppearance] native post initializer signature mismatch");
                continue;
            }
            entries[i] = (ApolloPreviewPostInit)entry;
        }
    });
    return entries[compact ? 1 : 0];
}

// These feed decorations have trapping ObjC initializers too. Keep the same
// binary/entry-point guards as the post constructors. Their native nodes own
// text, colors, line thickness and layout; only the sample page number is ours.
static void *DecorationInitializer(Class cls, uintptr_t anchorOffset, uintptr_t entryOffset,
                                   const uint32_t *prologue, size_t length) {
    Method method = class_getInstanceMethod(cls, @selector(init));
    const uint8_t *anchor = method ? (const uint8_t *)method_getImplementation(method) : NULL;
    Dl_info image;
    if (!anchor || !dladdr(anchor, &image) || !image.dli_fbase ||
        anchor - (const uint8_t *)image.dli_fbase != anchorOffset) return NULL;
    const uint8_t *entry = (const uint8_t *)image.dli_fbase + entryOffset;
    return memcmp(entry, prologue, length) == 0 ? (void *)entry : NULL;
}

static id MakeCompactSeparator(void) {
    typedef void * __attribute__((swiftcall)) (*Init)(double, double, void * __attribute__((swift_context)));
    static Init initialize;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const uint32_t bytes[] = { 0xd102c3ff, 0x6d0423e9, 0xa9056ffc, 0xa90667fa };
        initialize = (Init)DecorationInitializer(ApolloClassThinSeparatorCellNode, 0x3ad118,
            0x3aca34, bytes, sizeof(bytes));
    });
    // The compact feed's thin-separator token passes these exact insets.
    return initialize ? CFBridgingRelease(initialize(16, 0,
        (__bridge_retained void *)[ApolloClassThinSeparatorCellNode alloc])) : nil;
}

static id MakePageDivider(BOOL compact) {
    typedef void * __attribute__((swiftcall)) (*Init)(NSInteger, BOOL, void * __attribute__((swift_context)));
    static Init initialize;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const uint32_t bytes[] = { 0xd10283ff, 0xa9046ffc, 0xa90567fa, 0xa9065ff8 };
        initialize = (Init)DecorationInitializer(ApolloClassPageDividerCellNode, 0x4184a0,
            0x417edc, bytes, sizeof(bytes));
    });
    // Apollo labels the boundary after the first page as PAGE 2.
    return initialize ? CFBridgingRelease(initialize(2, compact,
        (__bridge_retained void *)[ApolloClassPageDividerCellNode alloc])) : nil;
}

static id SampleLink(BOOL textPost) {
    // The reserved URL is only model metadata for Apollo's image classifier.
    // Its network node is cleared before entering a view hierarchy; the image
    // comes from the bundled photo, never from a request or the user's account.
    NSString *url = @"https://apollo-preview.invalid/sample.jpg";
    NSDictionary *source = @{ @"url": url, @"width": @1280, @"height": @853 };
    NSMutableDictionary *data = [@{
        @"id": textPost ? @"previewtext" : @"previewimage",
        @"name": textPost ? @"t3_previewtext" : @"t3_previewimage",
        @"title": textPost ? @"See how text posts look with your settings" : @"Make Apollo yours — preview your post style live",
        @"author": @"TheBean31415", @"subreddit": @"ApolloReborn", @"subreddit_id": @"t5_preview",
        @"url": url, @"thumbnail": url, @"domain": @"i.redd.it", @"post_hint": @"image",
        @"permalink": @"/r/ApolloReborn/comments/preview/sample/",
        @"score": @1200, @"ups": @1200, @"downs": @0, @"num_comments": @128,
        @"created_utc": @([NSDate date].timeIntervalSince1970 - 7200),
        @"is_self": @NO, @"over_18": @NO, @"likes": NSNull.null,
        @"link_flair_text": @"Discussion", @"author_flair_text": @"Explorer",
        @"preview": @{ @"enabled": @YES, @"images": @[@{ @"source": source,
            @"resolutions": @[source], @"variants": @{}, @"id": @"preview" }] }
    } mutableCopy];
    // A fictional community award uses the bundled Apollo Reborn illustration;
    // Apollo's real AwardsNode still owns its size, count, spacing and visibility.
    NSString *awardPath = ApolloBundledResourcePath(@"ApolloRebornPreviewIcon", @"png");
    if (!textPost && [[NSFileManager defaultManager] fileExistsAtPath:awardPath]) {
        NSString *awardURL = [NSURL fileURLWithPath:awardPath].absoluteString;
        data[@"all_awardings"] = @[@{ @"id": @"award_preview", @"name": @"Apollo Reborn", @"count": @1,
            @"award_type": @"community", @"coin_price": @500, @"is_enabled": @YES,
            @"icon_url": awardURL, @"icon_width": @200, @"icon_height": @200,
            @"resized_icons": @[@{ @"url": awardURL, @"width": @200, @"height": @200 }] }];
    }
    if (textPost) {
        data[@"is_self"] = @YES;
        data[@"url"] = @"https://www.reddit.com/r/ApolloReborn/comments/previewtext/sample/";
        data[@"domain"] = @"self.ApolloReborn";
        data[@"thumbnail"] = @"self";
        data[@"selftext"] = @"Adjust the appearance settings below and watch your preview update.";
        [data removeObjectForKey:@"post_hint"];
        [data removeObjectForKey:@"preview"];
    }
    if (![ApolloClassRDKObjectBuilder respondsToSelector:@selector(objectFromJSON:)]) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(ApolloClassRDKObjectBuilder,
        @selector(objectFromJSON:), @{ @"kind": @"t3", @"data": data });
}

static void SupplyLocalImage(id node, UIImage *image) {
    if (!node) return;
    if ([node respondsToSelector:@selector(setURL:)]) [node setURL:nil];
    if ([node respondsToSelector:@selector(setDefaultImage:)]) [node setDefaultImage:image];
    if ([node respondsToSelector:@selector(setImage:)]) [node setImage:image];
}

static void SupplyAwardImage(id awards) {
    UIImage *icon = [UIImage imageWithContentsOfFile:ApolloBundledResourcePath(@"ApolloRebornPreviewIcon", @"png")];
    for (id child in [awards subnodes]) {
        if ([child respondsToSelector:@selector(setURL:)]) SupplyLocalImage(child, icon);
    }
}

static id MakePost(BOOL compact, BOOL textPost) {
    ApolloPreviewPostInit initialize = NativePostInitializer(compact);
    id link = SampleLink(textPost);
    Class cls = compact ? ApolloClassCompactPostCellNode : ApolloClassLargePostCellNode;
    if (!initialize || !link || !cls) return nil;
    // Mixed-feed context is essential: Apollo then honors Always Show Usernames
    // and Show Subreddit at Top exactly as it does on Home/All/Popular.
    id node = CFBridgingRelease(initialize((__bridge_retained void *)link, NO, NO, NO, NO,
        (__bridge_retained void *)[cls alloc]));
    static UIImage *photo, *icon;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        photo = [UIImage imageWithContentsOfFile:ApolloBundledResourcePath(@"PostAppearancePreview", @"jpg")];
        icon = [UIImage imageWithContentsOfFile:ApolloBundledResourcePath(@"ApolloRebornPreviewIcon", @"png")];
    });
    if (!textPost) {
        id media = ApolloReadObjectIvar(node, compact ? "thumbnailNode" : "richMediaNode");
        SupplyLocalImage(ApolloReadObjectIvar(media, "thumbnailNode"), photo);
    }
    SupplyLocalImage(ApolloReadObjectIvar(node, "upperSubredditIconNode"), icon);
    SupplyLocalImage(ApolloReadObjectIvar(ApolloReadObjectIvar(node, "postInfoNode"), "subredditIconNode"), icon);
    return node;
}

@interface ApolloPostAppearancePreview ()
@property (nonatomic, copy) NSArray *nodes;
@property (nonatomic, strong) UILabel *unavailableLabel;
@end

@implementation ApolloPostAppearancePreview
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        self.clipsToBounds = YES;
    }
    return self;
}

- (void)refresh {
    for (UIView *view in self.subviews) [view removeFromSuperview];
    self.unavailableLabel = nil;
    NSMutableArray *nodes = [NSMutableArray array];
    id photoPost = MakePost(self.compact, NO);
    if (photoPost) [nodes addObject:photoPost];
    // A second real compact node makes the text-thumbnail preference visible.
    if (self.compact && photoPost) {
        id textPost = MakePost(YES, YES);
        if (textPost) {
            id separator = MakeCompactSeparator();
            if (separator) [nodes addObject:separator];
            [nodes addObject:textPost];
        }
    }
    if (photoPost && [[NSUserDefaults standardUserDefaults] boolForKey:@"ShowPageEndings"]) {
        id divider = MakePageDivider(self.compact);
        if (divider) [nodes addObject:divider];
    }
    self.nodes = nodes;
    for (id node in nodes) {
        // Measuring materializes Texture's automatically managed subnodes.
        // Supply the fixture award before the hierarchy starts image loading.
        CGFloat width = CGRectGetWidth(self.bounds) > 0 ? CGRectGetWidth(self.bounds) : CGRectGetWidth(UIScreen.mainScreen.bounds);
        CGSize size = [[node layoutThatFits:(ApolloPreviewSizeRange){ CGSizeMake(width, 0), CGSizeMake(width, CGFLOAT_MAX) }] size];
        [node setFrame:(CGRect){ CGPointZero, size }];
        UIView *view = [node view];
        [node layoutIfNeeded];
        SupplyAwardImage(ApolloReadObjectIvar(ApolloReadObjectIvar(node, "postInfoNode"), "awardsNode"));
        view.userInteractionEnabled = NO;
        [self addSubview:view];
    }
    if (nodes.count == 0) {
        // Fail closed on an unsupported binary, never substitute an inaccurate
        // imitation for the preview. The appearance controls remain usable.
        UILabel *label = [UILabel new];
        label.text = @"Post preview is unavailable in this version of Apollo.";
        label.numberOfLines = 0;
        label.textColor = UIColor.secondaryLabelColor;
        label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
        [self addSubview:label];
        self.unavailableLabel = label;
    }
    [self setNeedsLayout];
    if (self.heightDidChange) self.heightDidChange();
}

- (CGFloat)arrangeForWidth:(CGFloat)width apply:(BOOL)apply {
    if (width <= 0) return 1;
    if (self.unavailableLabel) {
        CGFloat height = [self.unavailableLabel sizeThatFits:CGSizeMake(MAX(1, width - 32), CGFLOAT_MAX)].height + 32;
        if (apply) self.unavailableLabel.frame = CGRectMake(16, 16, MAX(1, width - 32), height - 32);
        return height;
    }
    CGFloat y = 0;
    for (id node in self.nodes) {
        // Both dimensions and every child position are Texture's native result.
        // Never copy inset/font/thumbnail/vote constants into this container.
        CGSize size = [[node layoutThatFits:(ApolloPreviewSizeRange){ CGSizeMake(width, 0), CGSizeMake(width, CGFLOAT_MAX) }] size];
        if (!isfinite(size.height) || size.height < 0) continue;
        if (apply) {
            [node setFrame:CGRectMake(0, y, width, size.height)];
            [node layoutIfNeeded];
        }
        y += size.height;
    }
    return MAX(1, y);
}

- (CGFloat)heightForWidth:(CGFloat)width { return [self arrangeForWidth:width apply:NO]; }
- (void)layoutSubviews {
    [super layoutSubviews];
    [self arrangeForWidth:CGRectGetWidth(self.bounds) apply:YES];
}
@end
