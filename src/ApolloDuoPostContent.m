#import "ApolloDuoPostContent.h"
#import "ApolloFeedMediaMenu.h"
#import "ApolloFrameRate.h"
#import "ApolloGalleryFeed.h"
#import "ApolloGalleryImageLoader.h"
#import "ApolloGalleryImageViewer.h"
#import "ApolloGallerySource.h"
#import "ApolloState.h"
#import "ApolloThemeRuntime.h"
#import "ApolloCommon.h"
#import <SafariServices/SafariServices.h>
#import <objc/message.h>
#import <objc/runtime.h>

typedef NS_ENUM(NSInteger, ApolloDuoPostContentKind) {
    ApolloDuoPostContentKindNone = 0,
    ApolloDuoPostContentKindMedia,
    ApolloDuoPostContentKindWeb,
};

// On an RDKLink: its ApolloDuoPostContentKind, worked out once.
static char kApolloDuoPostContentKindKey;

static id ApolloDuoPostObject(id link, SEL selector) {
    return [link respondsToSelector:selector] ? ((id (*)(id, SEL))objc_msgSend)(link, selector) : nil;
}

static BOOL ApolloDuoPostIsSelf(id link) {
    return [link respondsToSelector:@selector(selfPost)] && ((BOOL (*)(id, SEL))objc_msgSend)(link, @selector(selfPost));
}

// A page for the column: an http(s) address off Reddit's own hosts. Reddit's
// posts, galleries and media open in Apollo, never in a browser.
static NSURL *ApolloDuoPostWebURL(id link) {
    if (!link || ApolloDuoPostIsSelf(link)) return nil;
    NSURL *url = ApolloDuoPostObject(link, @selector(URL));
    if (![url isKindOfClass:NSURL.class]) return nil;
    NSString *scheme = url.scheme.lowercaseString;
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) return nil;
    NSString *host = url.host.lowercaseString;
    if (!host.length || [host isEqualToString:@"reddit.com"] || [host hasSuffix:@".reddit.com"]
        || [host isEqualToString:@"redd.it"] || [host hasSuffix:@".redd.it"]) return nil;
    return url;
}

// A text post's pictures, which Reddit lists in its media_metadata, as a
// gallery in the order its text shows them. Emotes and GIPHY embeds (ids with
// a "|") stay in the text. nil for anything else.
static NSDictionary *ApolloDuoPostTextPicturesAsGallery(NSDictionary *post, id link) {
    if (!ApolloDuoPostIsSelf(link) || [post[@"is_gallery"] boolValue]) return nil;
    NSDictionary *metadata = post[@"media_metadata"];
    if (![metadata isKindOfClass:NSDictionary.class] || !metadata.count) return nil;
    NSMutableArray<NSString *> *pictures = [NSMutableArray array];
    for (id mediaID in metadata) {
        if (![mediaID isKindOfClass:NSString.class] || ![mediaID length] || [mediaID containsString:@"|"]) continue;
        NSDictionary *media = metadata[mediaID];
        NSString *kind = [media isKindOfClass:NSDictionary.class] ? media[@"e"] : nil;
        if ([kind isEqual:@"Image"] || [kind isEqual:@"AnimatedImage"]) [pictures addObject:mediaID];
    }
    if (!pictures.count) return nil;
    // The text names each picture by its id (in a preview.redd.it address or a
    // bare image reference); one it doesn't name goes last.
    NSString *text = ApolloDuoPostObject(link, @selector(selfText));
    if (![text isKindOfClass:NSString.class]) text = @"";
    [pictures sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSUInteger first = [text rangeOfString:a].location, second = [text rangeOfString:b].location;
        if (first != second) return first < second ? NSOrderedAscending : NSOrderedDescending;
        return [a compare:b];
    }];
    NSMutableArray<NSDictionary *> *order = [NSMutableArray arrayWithCapacity:pictures.count];
    for (NSString *mediaID in pictures) [order addObject:@{@"media_id": mediaID}];
    NSMutableDictionary *gallery = [post mutableCopy];
    gallery[@"is_gallery"] = @YES;
    gallery[@"gallery_data"] = @{@"items": order};
    return gallery;
}

// The post's media as Gallery View items, from the JSON Apollo parsed it from:
// one item for an image, video or GIF, one per picture for a gallery or a
// text post's pictures.
static ApolloGalleryFeed *ApolloDuoPostMediaFeed(id link) {
    NSDictionary *post = link ? ApolloGallerySourcePostForLink(link) : nil;
    if (!post) return nil;
    post = ApolloDuoPostTextPicturesAsGallery(post, link) ?: post;
    NSString *subreddit = ApolloDuoPostObject(link, @selector(subreddit));
    ApolloGalleryFeed *feed = [[ApolloGalleryFeed alloc]
        initWithSubreddit:[subreddit isKindOfClass:NSString.class] ? subreddit : @""];
    // No cursor: the feed is complete as seeded and never loads a page.
    BOOL seeded = [feed seedFromListing:@{@"children": @[@{@"kind": @"t3", @"data": post}], @"after": NSNull.null}];
    return seeded && feed.items.count ? feed : nil;
}

static ApolloDuoPostContentKind ApolloDuoPostContentKindForLink(id link, ApolloGalleryFeed **feedOut) {
    if (!link) return ApolloDuoPostContentKindNone;
    NSNumber *cached = objc_getAssociatedObject(link, &kApolloDuoPostContentKindKey);
    if (cached && !feedOut) return (ApolloDuoPostContentKind)cached.integerValue;
    ApolloGalleryFeed *feed = ApolloDuoPostMediaFeed(link);
    ApolloDuoPostContentKind kind = feed ? ApolloDuoPostContentKindMedia
        : ApolloDuoPostWebURL(link) ? ApolloDuoPostContentKindWeb : ApolloDuoPostContentKindNone;
    // A post opened from a link has its JSON only once its comments load, so
    // nothing to show isn't final until then.
    if (kind != ApolloDuoPostContentKindNone || ApolloGallerySourcePostForLink(link))
        objc_setAssociatedObject(link, &kApolloDuoPostContentKindKey, @(kind), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (feedOut) *feedOut = feed;
    return kind;
}

// The column's media as the feed menu's items, or nil when one of them has no
// file to save yet (a hosted video still to resolve).
static NSArray<ApolloSaveAllMediaItem *> *ApolloDuoPostSaveItems(NSArray<ApolloGalleryItem *> *items) {
    NSMutableArray<ApolloSaveAllMediaItem *> *saves = [NSMutableArray arrayWithCapacity:items.count];
    for (ApolloGalleryItem *item in items) {
        BOOL video = item.kind == ApolloGalleryMediaKindVideo;
        NSURL *url = video ? (item.videoDownloadURL ?: item.videoURL) : item.imageURL;
        if (!url || (video && item.needsHostedVideoResolution)) return nil;
        // An animation served only as MP4 saves as a video.
        if (!video && [url.pathExtension.lowercaseString isEqualToString:@"mp4"]) video = YES;
        [saves addObject:[[ApolloSaveAllMediaItem alloc] initWithURL:url isVideo:video]];
    }
    return saves.count ? saves : nil;
}

// The column's videos follow Settings > Media > Unmute Videos in Comments:
// Always plays them with sound, Remember keeps the last choice made in a
// column, and Default starts them muted.
static NSString *const kApolloDuoPostContentMutedKey = @"ApolloDuoPostContentVideosMuted";

static BOOL ApolloDuoPostContentStartsMuted(void) {
    if (sUnmuteCommentsVideos == 2) return NO;
    if (sUnmuteCommentsVideos != 1) return YES;
    id stored = [NSUserDefaults.standardUserDefaults objectForKey:kApolloDuoPostContentMutedKey];
    return stored ? [stored boolValue] : YES;
}

@interface ApolloDuoPostContentViewController () <SFSafariViewControllerDelegate, UIGestureRecognizerDelegate>
@property(nonatomic, strong) UIPanGestureRecognizer *edgePan;
@property(nonatomic, weak, readwrite) id link;
@property(nonatomic, readwrite) BOOL showsMedia;
@property(nonatomic, strong) ApolloGalleryFeed *feed;
@property(nonatomic, strong) ApolloGalleryImageViewer *viewer;
@property(nonatomic, strong) UIView *cover;
@property(nonatomic, strong) ApolloGalleryImageRequest *coverRequest;
@property(nonatomic, strong) NSURL *pageURL;
@property(nonatomic, strong) SFSafariViewController *safari;
@property(nonatomic, strong) UIView *edge;
// The feed's hold menu while it is up (ApolloFeedMediaMenu).
@property(nonatomic, strong) id menuSession;
// The feed card's video: its player and item (to hand the place back only to
// the same clip) and where it was when the post opened.
@property(nonatomic, weak) AVPlayer *feedPlayer;
@property(nonatomic, weak) AVPlayerItem *feedPlayerItem;
@property(nonatomic) CMTime feedPlaybackTime;
@end

@implementation ApolloDuoPostContentViewController

+ (BOOL)hasContentForLink:(id)link {
    return ApolloDuoPostContentKindForLink(link, NULL) != ApolloDuoPostContentKindNone;
}

+ (instancetype)contentForLink:(id)link {
    ApolloGalleryFeed *feed = nil;
    ApolloDuoPostContentKind kind = ApolloDuoPostContentKindForLink(link, &feed);
    if (kind == ApolloDuoPostContentKindNone) return nil;
    if (kind == ApolloDuoPostContentKindMedia && !feed) feed = ApolloDuoPostMediaFeed(link);
    ApolloDuoPostContentViewController *content = [[self alloc] initWithNibName:nil bundle:nil];
    content.link = link;
    content.feed = kind == ApolloDuoPostContentKindMedia ? feed : nil;
    content.showsMedia = content.feed != nil;
    content.pageURL = content.feed ? nil : ApolloDuoPostWebURL(link);
    if (!content.feed && !content.pageURL) return nil;
    return content;
}

- (void)dealloc {
    [_coverRequest cancel];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.clipsToBounds = YES;
    if (self.showsMedia) {
        self.view.backgroundColor = UIColor.blackColor;
        ApolloGalleryItem *first = self.feed.items.firstObject;
        // Apollo blurs NSFW (per the account and Tag Filters) and spoiler media
        // until it is tapped; the column does the same before playing anything.
        if (first.shouldBlurThumbnail) [self installCover:first];
        else [self embedViewer];
    } else {
        self.view.backgroundColor = ApolloThemePageBackgroundColor() ?: UIColor.systemBackgroundColor;
        [self installSafari];
    }
    // Back from the leading edge, as on the page this column covers. The
    // pager's and the page's own drags wait for it to fail there.
    self.edgePan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(edgePanned:)];
    self.edgePan.maximumNumberOfTouches = 1;
    self.edgePan.delegate = self;
    [self.view addGestureRecognizer:self.edgePan];
    self.edge = [UIView new];
    self.edge.userInteractionEnabled = NO;
    self.edge.backgroundColor = ApolloThemeSeparatorColor() ?: UIColor.separatorColor;
    [self.view addSubview:self.edge];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect bounds = self.view.bounds;
    CGFloat hairline = 1 / (self.view.window.screen.scale ?: UIScreen.mainScreen.scale);
    self.edge.frame = CGRectMake(CGRectGetMaxX(bounds) - hairline, 0, hairline, bounds.size.height);
    [self.view bringSubviewToFront:self.edge];
}

#pragma mark Media

- (void)embedViewer {
    if (self.viewer || !self.feed) return;
    ApolloGalleryImageViewer *viewer = [[ApolloGalleryImageViewer alloc] initWithFeed:self.feed
                                                                      initialIndex:self.startIndex];
    viewer.embedded = YES;
    // What the feed card already shows: its pictures until the full-size ones
    // land, and its video from where it was.
    [self.feedImages enumerateKeysAndObjectsUsingBlock:^(NSNumber *index, UIImage *image, __unused BOOL *stop) {
        [viewer setPlaceholderImage:image forItemAtIndex:index.integerValue];
    }];
    AVPlayer *feedPlayer = self.feedPlayer;
    if (feedPlayer && feedPlayer.currentItem == self.feedPlayerItem) {
        viewer.initialPlaybackTime = CMTIME_IS_VALID(feedPlayer.currentTime) ? feedPlayer.currentTime : self.feedPlaybackTime;
    } else if (CMTIME_IS_VALID(self.feedPlaybackTime)) {
        viewer.initialPlaybackTime = self.feedPlaybackTime;
    }
    viewer.embeddedVideosMuted = @(ApolloDuoPostContentStartsMuted());
    viewer.embeddedMuteChanged = ^(BOOL muted) {
        if (sUnmuteCommentsVideos == 1) [NSUserDefaults.standardUserDefaults setBool:muted forKey:kApolloDuoPostContentMutedKey];
    };
    // Holding the media opens the feed's menu for it.
    __weak ApolloDuoPostContentViewController *weakSelf = self;
    viewer.embeddedMenu = ^UIMenu *(NSInteger index, UIView *sourceView) {
        ApolloDuoPostContentViewController *content = weakSelf;
        NSArray<ApolloSaveAllMediaItem *> *items = ApolloDuoPostSaveItems(content.feed.items);
        if (!content || index < 0 || (!content.link && !items)) return nil;
        ApolloFeedMediaMenuSessionDidEnd(content.menuSession);
        content.menuSession = ApolloFeedMediaMenuSession(content.link, (NSUInteger)index, content.feed.items.count > 1,
                                                         content, sourceView, items);
        return ApolloFeedMediaMenuForSession(content.menuSession);
    };
    viewer.embeddedMenuDidEnd = ^{
        ApolloDuoPostContentViewController *content = weakSelf;
        id session = content.menuSession;
        content.menuSession = nil;
        ApolloFeedMediaMenuSessionDidEnd(session);
    };
    [self addChildViewController:viewer];
    viewer.view.frame = self.view.bounds;
    viewer.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view insertSubview:viewer.view atIndex:0];
    [viewer didMoveToParentViewController:self];
    self.viewer = viewer;
    ApolloLog(@"[DuoPostContent] showing %lu media item(s)", (unsigned long)self.feed.items.count);
}

- (void)installCover:(ApolloGalleryItem *)item {
    UIView *cover = [[UIView alloc] initWithFrame:self.view.bounds];
    cover.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    cover.backgroundColor = UIColor.blackColor;
    UIImageView *thumbnail = [[UIImageView alloc] initWithFrame:cover.bounds];
    thumbnail.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    thumbnail.contentMode = UIViewContentModeScaleAspectFill;
    thumbnail.clipsToBounds = YES;
    [cover addSubview:thumbnail];
    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThickMaterialDark]];
    blur.frame = cover.bounds;
    blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [cover addSubview:blur];
    UILabel *title = [UILabel new];
    title.text = item.isSpoiler ? @"Spoiler" : @"NSFW";
    title.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
    UILabel *detail = [UILabel new];
    detail.text = @"Tap to Show";
    detail.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    for (UILabel *label in @[title, detail]) {
        label.textColor = UIColor.whiteColor;
        label.textAlignment = NSTextAlignmentCenter;
    }
    detail.textColor = [UIColor colorWithWhite:1 alpha:0.7];
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[title, detail]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 4;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [cover addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:cover.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:cover.centerYAnchor],
    ]];
    cover.isAccessibilityElement = YES;
    cover.accessibilityLabel = [NSString stringWithFormat:@"%@, hidden", title.text];
    cover.accessibilityTraits = UIAccessibilityTraitButton;
    cover.accessibilityHint = @"Shows the media";
    [cover addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(reveal)]];
    [self.view addSubview:cover];
    self.cover = cover;
    if (item.thumbnailURL) {
        self.coverRequest = [ApolloGalleryImageLoader.sharedLoader loadThumbnailAtURL:item.thumbnailURL completion:^(UIImage *image) {
            thumbnail.image = image;
        }];
    }
}

- (void)reveal {
    UIView *cover = self.cover;
    self.cover = nil;
    [self embedViewer];
    [self.view bringSubviewToFront:cover];
    [UIView animateWithDuration:UIAccessibilityIsReduceMotionEnabled() ? 0 : 0.2 animations:^{
        cover.alpha = 0;
    } completion:^(__unused BOOL finished) {
        [cover removeFromSuperview];
    }];
}

#pragma mark Web

// Apollo's in-app browser is Safari's own view controller; the column embeds
// the same, with Safari's toolbar and Reader. It enters Reader by itself, as
// Apollo's does, when Settings > General > Safari > Always Use Reader Mode is on.
- (void)installSafari {
    SFSafariViewControllerConfiguration *configuration = [SFSafariViewControllerConfiguration new];
    configuration.entersReaderIfAvailable = [NSUserDefaults.standardUserDefaults boolForKey:@"AlwaysUseReaderMode"];
    SFSafariViewController *safari = [[SFSafariViewController alloc] initWithURL:self.pageURL configuration:configuration];
    safari.delegate = self;
    [self addChildViewController:safari];
    safari.view.frame = self.view.bounds;
    safari.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view insertSubview:safari.view atIndex:0];
    [safari didMoveToParentViewController:self];
    self.safari = safari;
    ApolloLog(@"[DuoPostContent] loading the post's page in Safari (reader %d)", configuration.entersReaderIfAvailable);
}

// Done leaves the post, as it leaves Apollo's in-app browser.
- (void)safariViewControllerDidFinish:(SFSafariViewController *)controller {
    if (self.done) self.done();
}

#pragma mark Back

- (void)edgePanned:(UIPanGestureRecognizer *)pan {
    ApolloFullFrameRateFollowGesture(pan, 0.5);
    if (self.edgeBack) self.edgeBack(pan);
}

// The same strip the Duo's Back swipe uses on a page. Over media a rightward
// swipe anywhere goes Back, as it does across a post's comments, unless the
// media takes it (paging back through an album, a zoomed picture, the video
// controls). A page in Safari keeps its touches in Safari's own process; the
// only ones the column sees start in the 24pt strip Safari leaves to the app
// along its leading edge.
static const CGFloat kApolloDuoPostContentBackStrip = 28;

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldReceiveTouch:(UITouch *)touch {
    if (gesture != self.edgePan) return YES;
    if (!self.edgeBack) return NO;
    if ([touch locationInView:self.view].x <= kApolloDuoPostContentBackStrip) return YES;
    return self.showsMedia && ![touch.view isKindOfClass:UIControl.class];
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gesture {
    if (gesture != self.edgePan) return YES;
    CGPoint velocity = [self.edgePan velocityInView:self.view];
    if (velocity.x <= 0 || fabs(velocity.x) <= fabs(velocity.y)) return NO;
    CGPoint start = [self.edgePan locationInView:self.view];
    start.x -= [self.edgePan translationInView:self.view].x;
    if (start.x <= kApolloDuoPostContentBackStrip) return YES;
    return !self.viewer || ![self.viewer ownsRightwardDragAtPoint:[self.view convertPoint:start toView:self.viewer.view]];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)other {
    return gesture == self.edgePan && other != gesture && [other.view isDescendantOfView:self.view]
        && [other isKindOfClass:UIPanGestureRecognizer.class];
}

#pragma mark Playback

- (void)continueFromPlayer:(AVPlayer *)player {
    self.feedPlayer = player;
    self.feedPlayerItem = player.currentItem;
    self.feedPlaybackTime = player.currentItem ? player.currentTime : kCMTimeInvalid;
    if (CMTIME_IS_VALID(self.feedPlaybackTime))
        ApolloLog(@"[DuoPostContent] continuing the card's video at %.1fs", CMTimeGetSeconds(self.feedPlaybackTime));
}

- (void)pausePlayback {
    // The card's player picks up from here when the post closes.
    CMTime time = self.viewer.currentPlaybackTime;
    AVPlayer *feedPlayer = self.feedPlayer;
    if (feedPlayer && feedPlayer.currentItem == self.feedPlayerItem && CMTIME_IS_VALID(time) && CMTimeGetSeconds(time) > 0) {
        [feedPlayer seekToTime:time toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
    }
    [self.viewer pausePlayback];
}

- (void)cancelEdgeBack {
    // Turning an active recognizer off ends it as cancelled, so the Back it
    // drives settles before the column leaves the screen.
    if (self.edgePan.state != UIGestureRecognizerStateBegan && self.edgePan.state != UIGestureRecognizerStateChanged) return;
    self.edgePan.enabled = NO;
    self.edgePan.enabled = YES;
    ApolloLog(@"[DuoPostContent] cancelled the column's Back swipe before it left");
}

@end
