#import "ApolloDuoPostContent.h"
#import "ApolloGalleryFeed.h"
#import "ApolloGalleryImageLoader.h"
#import "ApolloGalleryImageViewer.h"
#import "ApolloGallerySource.h"
#import "ApolloThemeRuntime.h"
#import "ApolloCommon.h"
#import <WebKit/WebKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

typedef NS_ENUM(NSInteger, ApolloDuoPostContentKind) {
    ApolloDuoPostContentKindNone = 0,
    ApolloDuoPostContentKindMedia,
    ApolloDuoPostContentKindWeb,
};

// On an RDKLink: its ApolloDuoPostContentKind, worked out once.
static char kApolloDuoPostContentKindKey;
static void *kApolloDuoPostContentProgressContext = &kApolloDuoPostContentProgressContext;

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

// The post's media as Gallery View items, from the JSON Apollo parsed it from:
// one item for an image, video or GIF, one per picture for a gallery.
static ApolloGalleryFeed *ApolloDuoPostMediaFeed(id link) {
    NSDictionary *post = link ? ApolloGallerySourcePostForLink(link) : nil;
    if (!post) return nil;
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
    objc_setAssociatedObject(link, &kApolloDuoPostContentKindKey, @(kind), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (feedOut) *feedOut = feed;
    return kind;
}

@interface ApolloDuoPostContentViewController () <WKNavigationDelegate, WKUIDelegate, UIGestureRecognizerDelegate>
@property(nonatomic, strong) UIPanGestureRecognizer *edgePan;
@property(nonatomic, weak, readwrite) id link;
@property(nonatomic, readwrite) BOOL showsMedia;
@property(nonatomic, strong) ApolloGalleryFeed *feed;
@property(nonatomic, strong) ApolloGalleryImageViewer *viewer;
@property(nonatomic, strong) UIView *cover;
@property(nonatomic, strong) ApolloGalleryImageRequest *coverRequest;
@property(nonatomic, strong) NSURL *pageURL;
@property(nonatomic, strong) WKWebView *webView;
@property(nonatomic, strong) UIProgressView *progress;
@property(nonatomic, strong) UIVisualEffectView *toolbar;
@property(nonatomic, strong) UIStackView *toolbarButtons;
@property(nonatomic, strong) UIButton *backButton;
@property(nonatomic, strong) UIButton *forwardButton;
@property(nonatomic, strong) UIButton *reloadButton;
@property(nonatomic, strong) UIButton *shareButton;
@property(nonatomic, strong) UIView *edge;
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
    if (_webView) [_webView removeObserver:self forKeyPath:@"estimatedProgress" context:kApolloDuoPostContentProgressContext];
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
        [self installWebView];
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
    if (self.webView) {
        UIEdgeInsets safe = self.view.safeAreaInsets;
        CGSize toolbarSize = CGSizeMake(MIN(bounds.size.width - 32, 5 * 44 + 16), 52);
        self.toolbar.frame = CGRectMake((bounds.size.width - toolbarSize.width) / 2,
                                        bounds.size.height - MAX(safe.bottom, 12) - toolbarSize.height,
                                        toolbarSize.width, toolbarSize.height);
        self.toolbarButtons.frame = CGRectInset(self.toolbar.bounds, 8, 0);
        self.progress.frame = CGRectMake(0, safe.top, bounds.size.width, 2);
        CGFloat reserved = bounds.size.height - CGRectGetMinY(self.toolbar.frame) + 8;
        UIEdgeInsets insets = self.webView.scrollView.contentInset;
        if (fabs(insets.bottom - reserved) > 0.5) {
            insets.bottom = reserved;
            self.webView.scrollView.contentInset = insets;
            UIEdgeInsets indicators = self.webView.scrollView.verticalScrollIndicatorInsets;
            indicators.bottom = reserved;
            self.webView.scrollView.verticalScrollIndicatorInsets = indicators;
        }
    }
}

#pragma mark Media

- (void)embedViewer {
    if (self.viewer || !self.feed) return;
    ApolloGalleryImageViewer *viewer = [[ApolloGalleryImageViewer alloc] initWithFeed:self.feed initialIndex:0];
    viewer.embedded = YES;
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

- (UIButton *)toolbarButton:(NSString *)symbol label:(NSString *)label action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightSemibold];
    [button setImage:[UIImage systemImageNamed:symbol withConfiguration:configuration] forState:UIControlStateNormal];
    button.accessibilityLabel = label;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)installWebView {
    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    configuration.allowsInlineMediaPlayback = YES;
    configuration.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeAll;
    WKWebView *webView = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:configuration];
    webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    // The app's own Back swipe starts at this column's leading edge.
    webView.allowsBackForwardNavigationGestures = NO;
    webView.navigationDelegate = self;
    webView.UIDelegate = self;
    webView.backgroundColor = self.view.backgroundColor;
    [webView addObserver:self forKeyPath:@"estimatedProgress" options:NSKeyValueObservingOptionNew
                 context:kApolloDuoPostContentProgressContext];
    [self.view addSubview:webView];
    self.webView = webView;

    self.progress = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleBar];
    self.progress.progressTintColor = ApolloThemeAccentColor() ?: self.view.tintColor;
    [self.view addSubview:self.progress];

    UIVisualEffect *effect = nil;
    if (@available(iOS 26.0, *)) effect = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
    else effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial];
    self.toolbar = [[UIVisualEffectView alloc] initWithEffect:effect];
    self.toolbar.clipsToBounds = YES;
    self.toolbar.layer.cornerRadius = 26;
    self.toolbar.layer.cornerCurve = kCACornerCurveContinuous;
    self.backButton = [self toolbarButton:@"chevron.backward" label:@"Back" action:@selector(goBack)];
    self.forwardButton = [self toolbarButton:@"chevron.forward" label:@"Forward" action:@selector(goForward)];
    self.reloadButton = [self toolbarButton:@"arrow.clockwise" label:@"Reload" action:@selector(reloadOrStop)];
    self.shareButton = [self toolbarButton:@"square.and.arrow.up" label:@"Share" action:@selector(share)];
    UIButton *browser = [self toolbarButton:@"safari" label:@"Open in Browser" action:@selector(openInBrowser)];
    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[self.backButton, self.forwardButton,
                                                                          self.reloadButton, self.shareButton, browser]];
    buttons.distribution = UIStackViewDistributionFillEqually;
    [self.toolbar.contentView addSubview:buttons];
    self.toolbarButtons = buttons;
    self.toolbar.tintColor = ApolloThemeAccentColor() ?: self.view.tintColor;
    [self.view addSubview:self.toolbar];
    [self updateWebControls];
    [webView loadRequest:[NSURLRequest requestWithURL:self.pageURL]];
    ApolloLog(@"[DuoPostContent] loading the post's page");
}

- (void)updateWebControls {
    self.backButton.enabled = self.webView.canGoBack;
    self.forwardButton.enabled = self.webView.canGoForward;
    UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightSemibold];
    [self.reloadButton setImage:[UIImage systemImageNamed:self.webView.isLoading ? @"xmark" : @"arrow.clockwise"
                                        withConfiguration:configuration] forState:UIControlStateNormal];
    self.reloadButton.accessibilityLabel = self.webView.isLoading ? @"Stop" : @"Reload";
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context != kApolloDuoPostContentProgressContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    float value = (float)self.webView.estimatedProgress;
    self.progress.hidden = value >= 1;
    [self.progress setProgress:value animated:value > self.progress.progress];
}

- (void)goBack { [self.webView goBack]; }
- (void)goForward { [self.webView goForward]; }
- (void)reloadOrStop {
    if (self.webView.isLoading) [self.webView stopLoading];
    else if (self.webView.URL) [self.webView reload];
    else [self.webView loadRequest:[NSURLRequest requestWithURL:self.pageURL]];
    [self updateWebControls];
}
- (NSURL *)currentURL { return self.webView.URL ?: self.pageURL; }
- (void)share {
    UIActivityViewController *sheet = [[UIActivityViewController alloc] initWithActivityItems:@[[self currentURL]]
                                                                        applicationActivities:nil];
    sheet.popoverPresentationController.sourceView = self.shareButton;
    sheet.popoverPresentationController.sourceRect = self.shareButton.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}
- (void)openInBrowser {
    [UIApplication.sharedApplication openURL:[self currentURL] options:@{} completionHandler:nil];
}

- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation { [self updateWebControls]; }
- (void)webView:(WKWebView *)webView didCommitNavigation:(WKNavigation *)navigation { [self updateWebControls]; }
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation { [self updateWebControls]; }
- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error { [self updateWebControls]; }
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self updateWebControls];
}

// Links meant for another app (the App Store, Mail, a phone number) leave
// through the system; the page itself stays.
- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action
    decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSString *scheme = action.request.URL.scheme.lowercaseString;
    if (scheme.length && ![@[@"http", @"https", @"about", @"data", @"blob"] containsObject:scheme]) {
        if (action.navigationType == WKNavigationTypeLinkActivated)
            [UIApplication.sharedApplication openURL:action.request.URL options:@{} completionHandler:nil];
        decisionHandler(WKNavigationActionPolicyCancel);
        return;
    }
    decisionHandler(WKNavigationActionPolicyAllow);
}

// A link that asks for a new window opens in this one.
- (WKWebView *)webView:(WKWebView *)webView createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
   forNavigationAction:(WKNavigationAction *)action windowFeatures:(WKWindowFeatures *)features {
    if (!action.targetFrame.isMainFrame && action.request.URL) [webView loadRequest:action.request];
    return nil;
}

#pragma mark Back

- (void)edgePanned:(UIPanGestureRecognizer *)pan {
    if (self.edgeBack) self.edgeBack(pan);
}

// The same strip the Duo's Back swipe uses on a page.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldReceiveTouch:(UITouch *)touch {
    if (gesture != self.edgePan) return YES;
    return self.edgeBack && [touch locationInView:self.view].x <= 28;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gesture {
    if (gesture != self.edgePan) return YES;
    CGPoint velocity = [self.edgePan velocityInView:self.view];
    return velocity.x > 0 && fabs(velocity.x) > fabs(velocity.y);
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)other {
    return gesture == self.edgePan && other != gesture && [other.view isDescendantOfView:self.view]
        && [other isKindOfClass:UIPanGestureRecognizer.class];
}

#pragma mark Playback

- (void)pausePlayback {
    [self.viewer pausePlayback];
    if (@available(iOS 15.0, *)) [self.webView pauseAllMediaPlaybackWithCompletionHandler:nil];
}

@end
