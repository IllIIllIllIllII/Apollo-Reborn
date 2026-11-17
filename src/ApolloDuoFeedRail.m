#import "ApolloDuoFeedRail.h"
#import "ApolloFeedShortcutsAppearance.h"
#import "ApolloGalleryImageLoader.h"
#import "ApolloNativeSubredditIcons.h"
#import "ApolloSubredditInfoCache.h"
#import "ApolloThemeRuntime.h"
#import "UserDefaultConstants.h"
#import "ApolloCommon.h"

// The panel sits 12pt in from the display's top, bottom and leading edges,
// like the subreddit drawer that opens beside it.
static const CGFloat kRailInset = 12;
static const CGFloat kRailColumnWidth = 76;
static const CGFloat kRailGap = 12;
static const CGFloat kRailEdgePadding = 8;
static const CGFloat kRailButtonHeight = 62;
static const CGFloat kRailFavoriteHeight = 60;
static const CGFloat kRailGlyphSize = 24;
static const CGFloat kRailAvatarSize = 32;
static const NSInteger kRailSubredditsTag = -1;
static const NSInteger kRailFavoriteTag = -2;

// A glyph scaled into a square template image, so Apollo's bundled art and SF
// Symbols share one size.
static UIImage *ApolloDuoFeedRailGlyph(UIImage *source) {
    if (!source || source.size.width <= 0 || source.size.height <= 0) return nil;
    CGFloat scale = kRailGlyphSize / MAX(source.size.width, source.size.height);
    CGSize size = CGSizeMake(source.size.width * scale, source.size.height * scale);
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(kRailGlyphSize, kRailGlyphSize)];
    UIImage *image = [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {
        [[source imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]
            drawInRect:CGRectMake((kRailGlyphSize - size.width) / 2, (kRailGlyphSize - size.height) / 2, size.width, size.height)];
    }];
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

// One entry: a glyph (feeds, Subreddits) or a subreddit's icon (favorites)
// over its name, on a rounded highlight while it is what the feed shows.
@interface ApolloDuoFeedRailButton : UIControl
@property(nonatomic, strong) UIView *selection;
@property(nonatomic, strong) UIImageView *icon;
@property(nonatomic, strong) UILabel *initial;
@property(nonatomic, strong) UILabel *label;
@property(nonatomic, copy) NSString *subreddit;
@property(nonatomic, strong) ApolloGalleryImageRequest *iconRequest;
// The subreddit info lookup has been asked for (once, when first in view).
@property(nonatomic) BOOL infoRequested;
@property(nonatomic) BOOL hasIcon;
@property(nonatomic) BOOL avatar;
@property(nonatomic) BOOL chosen;
@end

@implementation ApolloDuoFeedRailButton
- (instancetype)initWithTitle:(NSString *)title {
    if (!(self = [super initWithFrame:CGRectZero])) return nil;
    self.selection = [UIView new];
    self.selection.userInteractionEnabled = NO;
    self.selection.layer.cornerRadius = 14;
    self.selection.layer.cornerCurve = kCACornerCurveContinuous;
    self.selection.hidden = YES;
    [self addSubview:self.selection];
    self.icon = [UIImageView new];
    self.icon.userInteractionEnabled = NO;
    [self addSubview:self.icon];
    self.label = [UILabel new];
    self.label.text = title;
    self.label.textAlignment = NSTextAlignmentCenter;
    self.label.adjustsFontSizeToFitWidth = YES;
    self.label.minimumScaleFactor = 0.75;
    self.label.lineBreakMode = NSLineBreakByTruncatingTail;
    [self addSubview:self.label];
    self.isAccessibilityElement = YES;
    self.accessibilityLabel = title;
    return self;
}
- (instancetype)initWithGlyph:(UIImage *)glyph title:(NSString *)title {
    if (!(self = [self initWithTitle:title])) return nil;
    self.icon.image = ApolloDuoFeedRailGlyph(glyph);
    self.icon.contentMode = UIViewContentModeCenter;
    self.label.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    return self;
}
- (instancetype)initWithSubreddit:(NSString *)subreddit iconURL:(NSURL *)iconURL {
    if (!(self = [self initWithTitle:subreddit])) return nil;
    self.avatar = YES;
    self.subreddit = subreddit;
    BOOL user = [subreddit.lowercaseString hasPrefix:@"u/"];
    self.accessibilityLabel = user ? subreddit : [@"r/" stringByAppendingString:subreddit];
    self.label.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
    self.icon.contentMode = UIViewContentModeScaleAspectFill;
    self.icon.clipsToBounds = YES;
    self.icon.layer.cornerRadius = kRailAvatarSize / 2;
    // Until the icon loads (or for a subreddit without one), its first letter.
    self.initial = [UILabel new];
    NSString *name = user ? [subreddit substringFromIndex:2] : subreddit;
    self.initial.text = name.length ? [name substringToIndex:1].uppercaseString : @"r";
    self.initial.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
    self.initial.textAlignment = NSTextAlignmentCenter;
    self.initial.clipsToBounds = YES;
    self.initial.layer.cornerRadius = kRailAvatarSize / 2;
    [self insertSubview:self.initial belowSubview:self.icon];
    // A followed user has no subreddit info to look up.
    self.infoRequested = user;
    [self loadIconFromURL:iconURL];
    return self;
}
- (void)loadIconFromURL:(NSURL *)url {
    if (!url || self.hasIcon) return;
    self.hasIcon = YES;
    [self.iconRequest cancel];
    __weak ApolloDuoFeedRailButton *weakSelf = self;
    self.iconRequest = [ApolloGalleryImageLoader.sharedLoader loadThumbnailAtURL:url completion:^(UIImage *image) {
        ApolloDuoFeedRailButton *button = weakSelf;
        if (!button || !image) return;
        button.icon.image = image;
        button.initial.hidden = YES;
    }];
}
- (void)dealloc {
    [_iconRequest cancel];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.bounds;
    self.selection.frame = CGRectInset(bounds, 4, 2);
    CGFloat iconSize = self.avatar ? kRailAvatarSize : kRailGlyphSize;
    CGFloat iconTop = self.avatar ? 7 : 11;
    self.icon.frame = CGRectMake((bounds.size.width - iconSize) / 2, iconTop, iconSize, iconSize);
    self.initial.frame = self.icon.frame;
    self.label.frame = CGRectMake(6, CGRectGetMaxY(self.icon.frame) + (self.avatar ? 4 : 6),
                                  bounds.size.width - 12, 14);
}
- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.alpha = highlighted ? 0.55 : 1;
}
- (void)applyAccent:(UIColor *)accent neutral:(UIColor *)neutral secondary:(UIColor *)secondary {
    self.selection.hidden = !self.chosen;
    self.selection.backgroundColor = [accent colorWithAlphaComponent:0.16];
    self.icon.tintColor = self.chosen ? accent : neutral;
    self.label.textColor = self.chosen ? accent : (self.avatar ? secondary : neutral);
    self.initial.textColor = accent;
    self.initial.backgroundColor = [accent colorWithAlphaComponent:0.18];
    self.accessibilityTraits = UIAccessibilityTraitButton | (self.chosen ? UIAccessibilityTraitSelected : 0);
}
@end

@interface ApolloDuoFeedRail () <UIScrollViewDelegate>
@property(nonatomic, strong) UIVisualEffectView *panel;
@property(nonatomic, strong) NSArray<ApolloDuoFeedRailButton *> *feedButtons;
@property(nonatomic, strong) NSArray<ApolloDuoFeedRailButton *> *favoriteButtons;
@property(nonatomic, strong) ApolloDuoFeedRailButton *subredditsButton;
@property(nonatomic, strong) UIScrollView *favorites;
@property(nonatomic, strong) UIView *topSeparator;
@property(nonatomic, strong) UIView *bottomSeparator;
@property(nonatomic, copy) NSArray<NSNumber *> *shortcuts;
@property(nonatomic, copy) NSArray<NSString *> *favoriteNames;
@end

@implementation ApolloDuoFeedRail

+ (CGFloat)reservedWidth { return kRailInset + kRailColumnWidth + kRailGap; }

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _selectedFeed = -1;
    UIVisualEffect *effect = nil;
    if (@available(iOS 26.0, *)) effect = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
    else effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial];
    self.panel = [[UIVisualEffectView alloc] initWithEffect:effect];
    self.panel.clipsToBounds = YES;
    // Follow the display's rounded corners concentrically, as the drawer does.
    if (@available(iOS 26.0, *)) {
        self.panel.cornerConfiguration = [UICornerConfiguration configurationWithUniformRadius:
            [UICornerRadius containerConcentricRadiusWithMinimum:24]];
    } else {
        self.panel.layer.cornerRadius = 24;
        self.panel.layer.cornerCurve = kCACornerCurveContinuous;
    }
    [self addSubview:self.panel];
    self.favorites = [UIScrollView new];
    self.favorites.delegate = self;
    self.favorites.showsVerticalScrollIndicator = NO;
    self.favorites.alwaysBounceVertical = NO;
    [self.panel.contentView addSubview:self.favorites];
    self.topSeparator = [UIView new];
    self.bottomSeparator = [UIView new];
    for (UIView *separator in @[self.topSeparator, self.bottomSeparator]) {
        separator.userInteractionEnabled = NO;
        [self.panel.contentView addSubview:separator];
    }
    UIImageSymbolConfiguration *symbol = [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightSemibold];
    self.subredditsButton = [[ApolloDuoFeedRailButton alloc]
        initWithGlyph:[UIImage systemImageNamed:@"list.bullet" withConfiguration:symbol] title:@"Subreddits"];
    self.subredditsButton.tag = kRailSubredditsTag;
    [self.subredditsButton addTarget:self action:@selector(tapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.panel.contentView addSubview:self.subredditsButton];
    self.accessibilityLabel = @"Feeds";
    for (NSString *name in @[ApolloFavoriteSubredditsUpdatedNotification, ApolloFeedShortcutsChangedNotification]) {
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reloadShortcuts) name:name object:nil];
    }
    [self reloadShortcuts];
    return self;
}

- (void)reloadShortcuts {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self reloadShortcuts]; });
        return;
    }
    NSMutableArray<NSNumber *> *shortcuts = [NSMutableArray array];
    for (NSNumber *index in ApolloFeedShortcutVisibleIndexes()) {
        // Moderator stays in the subreddit list; the column keeps the three
        // feeds everyone has.
        if (index.integerValue <= 2) [shortcuts addObject:index];
    }
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (id name in [NSUserDefaults.standardUserDefaults arrayForKey:UDKeyApolloFavoriteSubreddits] ?: @[]) {
        if ([name isKindOfClass:NSString.class] && [name length]) [names addObject:name];
    }
    BOOL shortcutsChanged = !self.feedButtons || ![shortcuts isEqualToArray:self.shortcuts ?: @[]];
    BOOL favoritesChanged = !self.favoriteButtons || ![names isEqualToArray:self.favoriteNames ?: @[]];
    if (!shortcutsChanged && !favoritesChanged) return;
    if (shortcutsChanged) {
        self.shortcuts = shortcuts;
        for (UIView *view in self.feedButtons) [view removeFromSuperview];
        NSMutableArray<ApolloDuoFeedRailButton *> *buttons = [NSMutableArray array];
        for (NSNumber *index in shortcuts) {
            ApolloDuoFeedRailButton *button = [[ApolloDuoFeedRailButton alloc]
                initWithGlyph:ApolloFeedShortcutTemplateGlyph(index.integerValue)
                        title:ApolloFeedShortcutShortTitle(index.integerValue)];
            button.tag = index.integerValue;
            [button addTarget:self action:@selector(tapped:) forControlEvents:UIControlEventTouchUpInside];
            [self.panel.contentView addSubview:button];
            [buttons addObject:button];
        }
        self.feedButtons = buttons;
    }
    if (favoritesChanged) {
        self.favoriteNames = names;
        for (UIView *view in self.favoriteButtons) [view removeFromSuperview];
        // The subreddit list's own icon cache first, then Apollo's icon
        // tracker. Either way the image itself usually comes out of a cache.
        NSDictionary<NSString *, NSURL *> *icons = names.count
            ? ApolloNativeSubredditIconURLs([NSUserDefaults.standardUserDefaults dataForKey:@"SubredditIconData"]) : @{};
        ApolloSubredditInfoCache *cache = ApolloSubredditInfoCache.sharedCache;
        NSMutableArray<ApolloDuoFeedRailButton *> *buttons = [NSMutableArray array];
        for (NSString *name in names) {
            BOOL user = [name.lowercaseString hasPrefix:@"u/"];
            NSURL *iconURL = user ? nil : ([cache cachedInfoForSubreddit:name].iconURL ?: icons[name.lowercaseString]);
            ApolloDuoFeedRailButton *button = [[ApolloDuoFeedRailButton alloc] initWithSubreddit:name iconURL:iconURL];
            button.tag = kRailFavoriteTag;
            [button addTarget:self action:@selector(tapped:) forControlEvents:UIControlEventTouchUpInside];
            [self.favorites addSubview:button];
            [buttons addObject:button];
        }
        self.favoriteButtons = buttons;
    }
    [self refreshColors];
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat height = MAX(0, self.bounds.size.height - kRailInset * 2);
    self.panel.frame = CGRectMake(kRailInset, kRailInset, kRailColumnWidth, height);
    CGFloat scale = self.window.screen.scale ?: UIScreen.mainScreen.scale;
    CGFloat hairline = 1 / scale;
    CGFloat y = kRailEdgePadding;
    for (ApolloDuoFeedRailButton *button in self.feedButtons) {
        button.frame = CGRectMake(0, y, kRailColumnWidth, kRailButtonHeight);
        y += kRailButtonHeight;
    }
    self.topSeparator.frame = CGRectMake(16, y + 6, kRailColumnWidth - 32, hairline);
    y += 12;
    CGFloat subredditsTop = height - kRailEdgePadding - kRailButtonHeight;
    self.subredditsButton.frame = CGRectMake(0, subredditsTop, kRailColumnWidth, kRailButtonHeight);
    self.bottomSeparator.frame = CGRectMake(16, subredditsTop - 6, kRailColumnWidth - 32, hairline);
    // The favorites scroll between the two separators when they don't fit.
    self.favorites.frame = CGRectMake(0, y, kRailColumnWidth, MAX(0, subredditsTop - 12 - y));
    CGFloat favoriteY = 0;
    for (ApolloDuoFeedRailButton *button in self.favoriteButtons) {
        button.frame = CGRectMake(0, favoriteY, kRailColumnWidth, kRailFavoriteHeight);
        favoriteY += kRailFavoriteHeight;
    }
    self.favorites.contentSize = CGSizeMake(kRailColumnWidth, favoriteY);
    self.favorites.alwaysBounceVertical = favoriteY > self.favorites.bounds.size.height;
    self.topSeparator.hidden = self.favoriteButtons.count == 0;
    [self requestVisibleIcons];
}

// A favorite with no icon on hand asks the subreddit info cache once it is in
// view, as the subreddit list does for its rows. The cache coalesces and keeps
// what it learns, so this costs at most one lookup per subreddit.
- (void)requestVisibleIcons {
    if (!self.window || self.hidden || self.alpha < 0.01) return;
    CGRect visible = self.favorites.bounds;
    for (ApolloDuoFeedRailButton *button in self.favoriteButtons) {
        if (button.hasIcon || button.infoRequested || !CGRectIntersectsRect(button.frame, visible)) continue;
        button.infoRequested = YES;
        __weak ApolloDuoFeedRailButton *weakButton = button;
        [ApolloSubredditInfoCache.sharedCache requestInfoForSubreddit:button.subreddit completion:^(ApolloSubredditInfo *info) {
            if (!info.iconURL) return;
            dispatch_async(dispatch_get_main_queue(), ^{ [weakButton loadIconFromURL:info.iconURL]; });
        }];
    }
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    [self requestVisibleIcons];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self setNeedsLayout];
}

// The panel alone takes touches; the gap beside it passes them on.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return hit == self ? nil : hit;
}

- (void)setSelectedFeed:(NSInteger)selectedFeed {
    if (_selectedFeed == selectedFeed) return;
    _selectedFeed = selectedFeed;
    [self refreshColors];
}

- (void)setSelectedSubreddit:(NSString *)selectedSubreddit {
    if (_selectedSubreddit == selectedSubreddit || [_selectedSubreddit isEqualToString:selectedSubreddit]) return;
    _selectedSubreddit = [selectedSubreddit copy];
    [self refreshColors];
}

- (void)setSubredditsSelected:(BOOL)subredditsSelected {
    if (_subredditsSelected == subredditsSelected) return;
    _subredditsSelected = subredditsSelected;
    [self refreshColors];
}

- (void)refreshColors {
    UIColor *accent = ApolloThemeAccentColor() ?: self.tintColor ?: UIColor.systemBlueColor;
    UIColor *neutral = ApolloNavigationChromeColor() ?: UIColor.labelColor;
    UIColor *secondary = UIColor.secondaryLabelColor;
    UIColor *separator = ApolloThemeSeparatorColor() ?: UIColor.separatorColor;
    self.topSeparator.backgroundColor = separator;
    self.bottomSeparator.backgroundColor = separator;
    for (ApolloDuoFeedRailButton *button in self.feedButtons) {
        button.chosen = button.tag == self.selectedFeed;
        [button applyAccent:accent neutral:neutral secondary:secondary];
    }
    for (ApolloDuoFeedRailButton *button in self.favoriteButtons) {
        button.chosen = self.selectedSubreddit && [button.subreddit caseInsensitiveCompare:self.selectedSubreddit] == NSOrderedSame;
        [button applyAccent:accent neutral:neutral secondary:secondary];
    }
    self.subredditsButton.chosen = self.subredditsSelected;
    [self.subredditsButton applyAccent:accent neutral:neutral secondary:secondary];
}

- (void)tintColorDidChange {
    [super tintColorDidChange];
    [self refreshColors];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    [self refreshColors];
}

- (void)setAlpha:(CGFloat)alpha {
    [super setAlpha:alpha];
    if (alpha > 0.01) [self requestVisibleIcons];
}

- (void)tapped:(ApolloDuoFeedRailButton *)button {
    if (button.tag == kRailSubredditsTag) {
        if (self.toggleSubreddits) self.toggleSubreddits();
    } else if (button.tag == kRailFavoriteTag) {
        if (self.selectSubreddit && button.subreddit.length) self.selectSubreddit(button.subreddit);
    } else if (self.selectFeed) {
        self.selectFeed(button.tag);
    }
}

@end
