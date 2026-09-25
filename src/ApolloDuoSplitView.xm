// Native sidebar/detail containers for the opened Duo. The tab still owns its
// original ApolloNavigationController: URL routing, tab gestures and account
// switching can keep addressing that object. Only its visible contents change
// at an unfold/fold boundary. UIKit owns all column frames and transitions.
#import "ApolloDuoSplitView.h"
#import "ApolloDuoAccount.h"
#import "ApolloThemeRuntime.h"
#import "ApolloCommon.h"
#import "ApolloDuoRail.h"
#import "ApolloDuoCompatibility.h"
#import "ApolloFeedShortcutsAppearance.h"
#import "settings/CustomAPIViewController.h"
#import <objc/runtime.h>
#import <objc/message.h>

// Each account column owns its vertical origin independently. Overview and
// the menu sit below the shared profile header; destinations use the entire
// secondary column without resizing or re-laying out that header.
@interface ApolloDuoAccountColumn : UIViewController
@property(nonatomic, strong) UINavigationController *navigation;
@property(nonatomic, strong) NSLayoutConstraint *topConstraint;
@property(nonatomic) CGFloat contentTop;
@end
@implementation ApolloDuoAccountColumn
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    [self addChildViewController:self.navigation];
    UIView *content = self.navigation.view;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:content];
    self.topConstraint = [content.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:self.contentTop];
    [NSLayoutConstraint activateConstraints:@[
        self.topConstraint,
        [content.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [content.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];
    [self.navigation didMoveToParentViewController:self];
}
- (void)setContentTop:(CGFloat)contentTop {
    _contentTop = contentTop;
    if (fabs(self.topConstraint.constant - contentTop) > 0.5) self.topConstraint.constant = contentTop;
}
@end

// UINavigationController forbids a UISplitViewController as a stack entry.
// A plain containment host keeps Apollo's tab navigation identity intact while
// the split controller remains a proper child and owns its own column layout.
// UIKit can coalesce a newly revealed glass view's initial and final
// transforms in one transaction. Supply explicit endpoints so reveal and
// dismiss still travel across the screen on that first visible frame.
static void ApolloDuoSlideView(UIView *view, CGFloat from, CGFloat to, NSTimeInterval duration, dispatch_block_t completion) {
    [view.layer removeAnimationForKey:@"ApolloDuoSlide"];
    view.transform = CGAffineTransformMakeTranslation(to, 0);
    if (duration <= 0) {
        if (completion) completion();
        return;
    }
    CABasicAnimation *slide = [CABasicAnimation animationWithKeyPath:@"transform.translation.x"];
    slide.fromValue = @(from);
    slide.toValue = @(to);
    slide.duration = duration;
    slide.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [CATransaction begin];
    [CATransaction setCompletionBlock:completion];
    [view.layer addAnimation:slide forKey:@"ApolloDuoSlide"];
    [CATransaction commit];
}

@interface ApolloDuoSplitHost : UIViewController <UISplitViewControllerDelegate>
@property(nonatomic, strong) UISplitViewController *split;
@property(nonatomic, strong) UINavigationController *subredditList;
@property(nonatomic, weak) UINavigationController *postsNavigation;
@property(nonatomic, strong) UIVisualEffectView *listGlass;
@property(nonatomic, strong) UIControl *listDismiss;
@property(nonatomic, strong) UIButton *listButton;
@property(nonatomic) BOOL listVisible;
@property(nonatomic) BOOL postsShowingDetail;
@property(nonatomic) BOOL postsSplitEnabled;
@property(nonatomic) BOOL postsColumnsPaired;
@property(nonatomic) NSUInteger listAnimationGeneration;
@property(nonatomic, strong) UIButton *splitButton;
@property(nonatomic, copy) void (^togglePostsSplit)(void);
@property(nonatomic, strong) NSMapTable *listBackgrounds;
@property(nonatomic, strong) UIButton *listAddButton;
@property(nonatomic, strong) UIButton *listEditButton;
@property(nonatomic) UIEdgeInsets originalListInsets;
- (void)restoreListBackgrounds;
- (void)setListVisible:(BOOL)visible animated:(BOOL)animated;
@property(nonatomic, strong) UIView *accountHeader;
@property(nonatomic, strong) UIView *accountHeaderClip;
@property(nonatomic, strong) ApolloDuoAccountColumn *accountPrimary;
@property(nonatomic, strong) ApolloDuoAccountColumn *accountSecondary;
@property(nonatomic, strong) NSNumber *pendingAccountDetail;
@property(nonatomic, strong) NSNumber *accountDisplayMode;
@property(nonatomic, strong) NSLayoutConstraint *contentTopConstraint;
@property(nonatomic, strong) UIButton *accountsButton;
@property(nonatomic, strong) UIButton *moreButton;
@property(nonatomic, strong) UIButton *sidebarButton;
@property(nonatomic, strong) UIButton *profileBackButton;
@end
@implementation ApolloDuoSplitHost
- (void)viewDidLoad {
    [super viewDidLoad];
    self.split.delegate = self;
    [self addChildViewController:self.split];
    UIView *content = self.split.view;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:content];
    self.contentTopConstraint = [content.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:0];
    [NSLayoutConstraint activateConstraints:@[
        [content.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        self.contentTopConstraint,
        [content.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];
    [self.split didMoveToParentViewController:self];
    if (self.subredditList) {
        self.listDismiss = [UIControl new];
        self.listDismiss.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.12];
        [self.listDismiss addTarget:self action:@selector(dismissList) forControlEvents:UIControlEventTouchUpInside];
        self.listDismiss.hidden = YES;
        [self.view addSubview:self.listDismiss];
        UIVisualEffect *effect;
        if (@available(iOS 26.0, *)) effect = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
        else effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial];
        self.listGlass = [[UIVisualEffectView alloc] initWithEffect:effect];
        self.listGlass.layer.cornerRadius = 28;
        self.listGlass.clipsToBounds = YES;
        self.listGlass.hidden = YES;
        [self.view addSubview:self.listGlass];
        [self addChildViewController:self.subredditList];
        UIView *list = self.subredditList.view;
        list.translatesAutoresizingMaskIntoConstraints = NO;
        [self.listGlass.contentView addSubview:list];
        [NSLayoutConstraint activateConstraints:@[
            [list.topAnchor constraintEqualToAnchor:self.listGlass.contentView.topAnchor],
            [list.bottomAnchor constraintEqualToAnchor:self.listGlass.contentView.bottomAnchor],
            [list.leadingAnchor constraintEqualToAnchor:self.listGlass.contentView.leadingAnchor],
            [list.trailingAnchor constraintEqualToAnchor:self.listGlass.contentView.trailingAnchor]
        ]];
        [self.subredditList didMoveToParentViewController:self];
        self.listButton = [UIButton buttonWithType:UIButtonTypeSystem];
        UIButtonConfiguration *configuration;
        if (@available(iOS 26.0, *)) configuration = [UIButtonConfiguration glassButtonConfiguration];
        else configuration = [UIButtonConfiguration tintedButtonConfiguration];
        configuration.image = [UIImage systemImageNamed:@"list.bullet"];
        configuration.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
        self.listButton.configuration = configuration;
        self.listButton.accessibilityLabel = @"Subreddit List";
        [self.listButton addTarget:self action:@selector(toggleList) forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:self.listButton];
        self.splitButton = [UIButton buttonWithType:UIButtonTypeSystem];
        UIButtonConfiguration *splitConfiguration = [configuration copy];
        splitConfiguration.image = [UIImage systemImageNamed:@"rectangle.split.2x1"];
        self.splitButton.configuration = splitConfiguration;
        self.splitButton.accessibilityLabel = @"Toggle Feed and Comments Split";
        [self.splitButton addTarget:self action:@selector(toggleSplit) forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:self.splitButton];
        [self updateSplitButton];
        self.originalListInsets = self.subredditList.topViewController.additionalSafeAreaInsets;
        [self.subredditList setNavigationBarHidden:YES animated:NO];
        self.listAddButton = [UIButton buttonWithType:UIButtonTypeSystem];
        UIButtonConfiguration *addConfiguration = [configuration copy];
        addConfiguration.image = [UIImage systemImageNamed:@"plus"];
        self.listAddButton.configuration = addConfiguration;
        self.listAddButton.accessibilityLabel = @"Add Subreddit";
        [self.listAddButton addTarget:self action:@selector(addSubreddit) forControlEvents:UIControlEventTouchUpInside];
        [self.listGlass.contentView addSubview:self.listAddButton];
        self.listEditButton = [UIButton buttonWithType:UIButtonTypeSystem];
        UIButtonConfiguration *editConfiguration = [configuration copy];
        editConfiguration.image = nil;
        editConfiguration.title = @"Edit";
        self.listEditButton.configuration = editConfiguration;
        [self.listEditButton addTarget:self action:@selector(editSubreddits) forControlEvents:UIControlEventTouchUpInside];
        [self.listGlass.contentView addSubview:self.listEditButton];
    }
    if (self.accountHeader) {
        self.accountHeaderClip = [UIView new];
        self.accountHeaderClip.clipsToBounds = YES;
        [self.accountHeaderClip addSubview:self.accountHeader];
        [self.view addSubview:self.accountHeaderClip];
        [self.view addSubview:self.accountsButton];
        [self.view addSubview:self.moreButton];
        [self.view addSubview:self.sidebarButton];
        if (self.profileBackButton) [self.view addSubview:self.profileBackButton];
    }
}
- (void)addSubreddit {
    UIViewController *root = self.subredditList.viewControllers.firstObject;
    SEL action = NSSelectorFromString(@"tappedAddBarButtonItem:");
    if ([root respondsToSelector:action]) [UIApplication.sharedApplication sendAction:action to:root from:self.listAddButton forEvent:nil];
}
- (void)editSubreddits {
    UIViewController *root = self.subredditList.viewControllers.firstObject;
    [root setEditing:!root.isEditing animated:YES];
    UIButtonConfiguration *configuration = [self.listEditButton.configuration copy];
    configuration.title = root.isEditing ? @"Done" : @"Edit";
    self.listEditButton.configuration = configuration;
    [self prepareListGlass];
}
- (void)prepareListGlass {
    if (!self.listBackgrounds) self.listBackgrounds = [NSMapTable weakToStrongObjectsMapTable];
    NSMutableArray *views = [NSMutableArray arrayWithObject:self.subredditList.view];
    for (NSUInteger i = 0; i < views.count; i++) [views addObjectsFromArray:((UIView *)views[i]).subviews];
    for (UIView *view in views) {
        BOOL surface = view == self.subredditList.view || view == self.subredditList.topViewController.view
            || [view isKindOfClass:UITableView.class] || [view isKindOfClass:UITableViewCell.class];
        if (!surface) continue;
        if (![self.listBackgrounds objectForKey:view]) [self.listBackgrounds setObject:view.backgroundColor ?: UIColor.clearColor forKey:view];
        view.backgroundColor = UIColor.clearColor;
        if ([view isKindOfClass:UITableViewCell.class]) {
            UITableViewCell *cell = (id)view;
            ApolloDuoSplitPrepareOverlaySurface(cell);
            SEL selector = NSSelectorFromString(@"node");
            if ([cell respondsToSelector:selector]) {
                id node = ((id (*)(id, SEL))objc_msgSend)(cell, selector);
                if (node) [node setValue:UIColor.clearColor forKey:@"backgroundColor"];
            }
        }
    }
}
- (void)restoreListBackgrounds {
    for (UIView *view in self.listBackgrounds) view.backgroundColor = [self.listBackgrounds objectForKey:view];
    self.listBackgrounds = nil;
    self.subredditList.viewControllers.firstObject.additionalSafeAreaInsets = self.originalListInsets;
    [self.subredditList setNavigationBarHidden:NO animated:NO];
}
- (void)updateSplitButton {
    CAShapeLayer *slash = (CAShapeLayer *)[self.splitButton.layer.sublayers filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"name == %@", @"split-disabled-slash"]].firstObject;
    if (!slash) {
        slash = [CAShapeLayer layer];
        slash.name = @"split-disabled-slash";
        UIBezierPath *path = [UIBezierPath bezierPath];
        [path moveToPoint:CGPointMake(12, 32)];
        [path addLineToPoint:CGPointMake(32, 12)];
        slash.path = path.CGPath;
        slash.lineWidth = 2;
        slash.strokeColor = [self.splitButton.tintColor resolvedColorWithTraitCollection:self.splitButton.traitCollection].CGColor;
        [self.splitButton.layer addSublayer:slash];
    }
    slash.hidden = self.postsSplitEnabled;
    self.splitButton.accessibilityValue = self.postsSplitEnabled ? @"On" : @"Off";
}
- (void)toggleSplit {
    if (self.togglePostsSplit) self.togglePostsSplit();
}
- (void)toggleList { [self setListVisible:!self.listVisible animated:YES]; }
- (void)dismissList { [self setListVisible:NO animated:YES]; }
- (void)setListVisible:(BOOL)visible animated:(BOOL)animated {
    if (!self.subredditList || self.listVisible == visible) return;
    [self.view layoutIfNeeded];
    BOOL wasHidden = self.listGlass.hidden;
    CGFloat start = wasHidden ? -self.listGlass.bounds.size.width - 12
        : (self.listGlass.layer.presentationLayer ?: self.listGlass.layer).transform.m41;
    self.listVisible = visible;
    self.listButton.hidden = visible;
    self.splitButton.hidden = visible || self.view.bounds.size.width <= self.view.bounds.size.height;
    if (visible) [self prepareListGlass];
    self.listDismiss.hidden = NO;
    self.listGlass.hidden = NO;
    NSUInteger generation = ++self.listAnimationGeneration;
    NSTimeInterval duration = animated && !UIAccessibilityIsReduceMotionEnabled() ? 0.32 : 0;
    [UIView animateWithDuration:duration animations:^{ self.listDismiss.alpha = visible ? 1 : 0; }];
    __weak typeof(self) weakSelf = self;
    ApolloDuoSlideView(self.listGlass, start, visible ? 0 : -self.listGlass.bounds.size.width - 12, duration, ^{
        if (weakSelf.listAnimationGeneration != generation) return;
        weakSelf.listGlass.hidden = !weakSelf.listVisible;
        weakSelf.listDismiss.hidden = !weakSelf.listVisible;
    });
}
- (void)splitViewController:(UISplitViewController *)splitViewController willChangeToDisplayMode:(UISplitViewControllerDisplayMode)displayMode {
    if (!self.accountHeader) return;
    // The host is outside UIKit's column hierarchy, so a column-only change
    // need not lay it out. Use the announced mode (displayMode still reports
    // the old value here) to move the header mask and sidebar control with it.
    self.accountDisplayMode = @(displayMode);
    void (^layout)(void) = ^{
        [self.view setNeedsLayout];
        [self.view layoutIfNeeded];
    };
    id<UIViewControllerTransitionCoordinator> coordinator = splitViewController.transitionCoordinator;
    if (![coordinator animateAlongsideTransition:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) {
        layout();
    } completion:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) {
        self.accountDisplayMode = @(splitViewController.displayMode);
        layout();
    }]) layout();
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (self.subredditList) {
        CGFloat width = MIN(360, self.view.bounds.size.width - 96);
        self.listDismiss.frame = self.view.bounds;
        self.listAddButton.frame = CGRectMake(12, 12, 44, 44);
        self.listEditButton.frame = CGRectMake(width - 80, 12, 68, 44);
        // Bounds/center stay independent of the presentation transform.
        self.listGlass.bounds = CGRectMake(0, 0, width, self.view.bounds.size.height - 24);
        self.listGlass.center = CGPointMake(12 + width / 2, self.view.bounds.size.height / 2);
        CGFloat top = 24;
        BOOL portrait = self.view.bounds.size.width <= self.view.bounds.size.height;
        // UIKit may return a column wrapper instead of Apollo's navigation
        // controller. Read the retained feed stack, which owns full-screen
        // portrait pushes, so List leaves the native Back button unobstructed.
        BOOL hasBack = self.postsNavigation.viewControllers.count > 1;
        self.listButton.frame = CGRectMake(portrait && hasBack ? 84 : 24, top, 44, 44);
        self.splitButton.hidden = self.listVisible || portrait;
        self.splitButton.frame = CGRectMake(84, top, 44, 44);
    }
    if (!self.accountHeader) return;
    UISplitViewControllerDisplayMode displayMode = self.accountDisplayMode
        ? (UISplitViewControllerDisplayMode)self.accountDisplayMode.integerValue : self.split.displayMode;
    CGFloat headerHeight = ApolloDuoAccountHeaderHeight(self.accountHeader, self.view.bounds.size.width);
    UINavigationController *detail = self.accountSecondary.navigation;
    BOOL hasDetail = self.pendingAccountDetail ? self.pendingAccountDetail.boolValue : detail.viewControllers.count > 1;
    self.accountPrimary.contentTop = headerHeight;
    self.accountSecondary.contentTop = hasDetail ? 0 : headerHeight;
    CGFloat headerWidth = hasDetail ? self.split.primaryColumnWidth : self.view.bounds.size.width;
    if (hasDetail && displayMode == UISplitViewControllerDisplayModeSecondaryOnly) headerWidth = 0;
    self.accountHeaderClip.frame = CGRectMake(0, 0, headerWidth, headerHeight);
    self.accountHeader.frame = CGRectMake(0, 0, self.view.bounds.size.width, headerHeight);
    // Match the other tabs: trailing edge of the visible sidebar, then the
    // leading edge of the content when the sidebar is dismissed.
    CGFloat sidebarWidth = self.split.primaryColumnWidth;
    CGFloat sidebarX = displayMode == UISplitViewControllerDisplayModeSecondaryOnly
        ? (self.profileBackButton ? 84 : 24) : MAX(24, sidebarWidth - 68);
    self.sidebarButton.frame = CGRectMake(sidebarX, MAX(24, self.view.safeAreaInsets.top), 48, 48);
    self.profileBackButton.frame = CGRectMake(24, MAX(24, self.view.safeAreaInsets.top), 48, 48);
    self.moreButton.hidden = hasDetail;
    self.accountsButton.hidden = hasDetail;
    // Match the native rail's 48pt platter and 24pt physical edge inset.
    // The safe-area inset includes the rail and is not its visible center.
    CGFloat railX = self.view.bounds.size.width - 72;
    CGFloat statusBottom = CGRectGetMaxY(self.view.window.windowScene.statusBarManager.statusBarFrame);
    CGFloat railTop = MAX(124, statusBottom + 16);
    self.moreButton.frame = CGRectMake(railX, railTop, 48, 48);
    self.accountsButton.frame = CGRectMake(railX, railTop + 60, 48, 48);
}
@end

@interface ApolloDuoSplitState : NSObject
@property(nonatomic, weak) UINavigationController *outer;
@property(nonatomic, strong) UIViewController *root;
@property(nonatomic, strong) UISplitViewController *split;
@property(nonatomic, strong) ApolloDuoSplitHost *host;
@property(nonatomic, strong) UINavigationController *primary;
@property(nonatomic, strong) UINavigationController *secondary;
@property(nonatomic, strong) UINavigationController *feed;
@property(nonatomic, copy) NSArray *feedActions;
@property(nonatomic, strong) NSArray<UIViewController *> *lastSettings;
@property(nonatomic, copy) NSString *kind;
@property(nonatomic, copy) NSString *sidebarTitle;
// Pages preceding a visited profile stay in their original tab's Back stack.
@property(nonatomic, copy) NSArray<UIViewController *> *profilePrefix;
@property(nonatomic, strong) UIViewController *tabRoot;
@property(nonatomic, copy) NSString *tabKind;
@property(nonatomic) BOOL selectingAccountShortcut;
@property(nonatomic) BOOL changing;
@property(nonatomic) BOOL navigationBarWasHidden;
@property(nonatomic) BOOL needsDefault;
@property(nonatomic) BOOL halfWidthSidebar;
@property(nonatomic, weak) id<UIViewControllerTransitionCoordinator> pendingNavigationTransition;
@end
@implementation ApolloDuoSplitState @end

@interface ApolloDuoSplitReference : NSObject
@property(nonatomic, weak) ApolloDuoSplitState *state;
@end
@implementation ApolloDuoSplitReference @end

static char kDuoSplitState, kDuoSplitReference;
static char kDuoSplitHingeInteraction, kDuoSplitHingeStatus;
static BOOL sDuoSplitUpdateScheduled;
static BOOL sDuoSplitUpdating;
static __weak UITabBarController *sDuoSplitKnownTabs;
static __weak UITabBarController *sDuoSplitResizingTabs;
static CGSize sDuoSplitTargetSize;
static __weak id<UIViewControllerTransitionCoordinator> sDuoSplitSizeCoordinator;

BOOL ApolloDuoSplitIsResizing(void) {
    return sDuoSplitResizingTabs != nil;
}

BOOL ApolloDuoSplitIsUnfolded(void) {
    UITabBarController *tabs = (id)ApolloMainTabBarController();
    if (UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPhone
        || ![tabs isKindOfClass:UITabBarController.class] || !tabs.isViewLoaded) return NO;
    if (tabs != sDuoSplitKnownTabs && ApolloDuoCurrentMode() == ApolloDuoModePhone) return NO;
    CGSize size = tabs == sDuoSplitResizingTabs ? sDuoSplitTargetSize : tabs.view.bounds.size;
    return MIN(size.width, size.height) >= 600.0;
}

BOOL ApolloDuoSplitIsUnfoldedPortrait(void) {
    if (!ApolloDuoSplitIsUnfolded()) return NO;
    UITabBarController *tabs = (id)ApolloMainTabBarController();
    CGSize size = tabs == sDuoSplitResizingTabs ? sDuoSplitTargetSize : tabs.view.bounds.size;
    return size.height > size.width;
}

// Apollo's native navigation delegate tests a 70pt edge band in its view.
// UIKit extends the secondary view under the sidebar and the trailing rail;
// translate only that delegate's location query into the visible pane's band.
static __thread void *sDuoSplitGesture;
static __thread void *sDuoSplitGestureView;
static __thread CGFloat sDuoSplitGestureOffset;

static NSString *ApolloDuoSplitKind(UIViewController *root) {
    NSString *name = NSStringFromClass(root.class);
    if ([name isEqualToString:@"Apollo.RedditListViewController"]) return @"subreddits";
    if ([name isEqualToString:@"Apollo.SettingsViewController"]) return @"settings";
    if ([name isEqualToString:@"Apollo.InboxListViewController"]) return @"inbox";
    if ([name isEqualToString:@"Apollo.ProfileViewController"]) return @"account";
    if ([name isEqualToString:@"Apollo.SearchViewController"]) return @"search";
    return nil;
}

static ApolloDuoSplitState *ApolloDuoSplitStateForNavigation(UINavigationController *nav, BOOL create) {
    ApolloDuoSplitReference *reference = objc_getAssociatedObject(nav, &kDuoSplitReference);
    if (reference.state) return reference.state;
    ApolloDuoSplitState *state = objc_getAssociatedObject(nav, &kDuoSplitState);
    if (!state && create && [nav.parentViewController isKindOfClass:UITabBarController.class]) {
        NSString *kind = ApolloDuoSplitKind(nav.viewControllers.firstObject);
        ApolloLog(@"[DuoSplit] tab root=%@ supported=%d", NSStringFromClass(nav.viewControllers.firstObject.class), kind != nil);
        if (kind) {
            state = [ApolloDuoSplitState new];
            state.outer = nav;
            state.root = nav.viewControllers.firstObject;
            state.kind = kind;
            objc_setAssociatedObject(nav, &kDuoSplitState, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    return state;
}

// Node measurement can run while UIKit is moving the page between navigation
// controllers, before the new safe area exists. Use the destination column's
// width for that one transition, including offscreen rows measured by Texture.
CGFloat ApolloDuoSplitTransitionContentWidth(UIView *view, CGFloat trailingInset) {
    if (!sDuoSplitResizingTabs) return 0.0;
    UIViewController *owner = nil;
    for (UIResponder *responder = view; responder; responder = responder.nextResponder) {
        if ([responder isKindOfClass:UIViewController.class]) {
            owner = (id)responder;
            break;
        }
    }
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(owner.navigationController, NO);
    CGFloat width = sDuoSplitTargetSize.width;
    if (state.feed && state.split && MIN(sDuoSplitTargetSize.width, sDuoSplitTargetSize.height) >= 600) {
        if (owner.navigationController == state.primary) return MIN(360, width - 96);
        BOOL paired = state.host.postsSplitEnabled && sDuoSplitTargetSize.width > sDuoSplitTargetSize.height && (state.secondary.viewControllers.count > 1 || state.feed.viewControllers.count > 1);
        if (paired) width *= 0.5;
        BOOL feedColumn = paired && owner.navigationController == state.feed;
        return MAX(0, width - (!feedColumn && sDuoSplitTargetSize.width > sDuoSplitTargetSize.height ? trailingInset : 0));
    }
    if (state.split && width >= 800.0 && width > sDuoSplitTargetSize.height) {
        UISplitViewController *split = state.split;
        CGFloat primary = MIN(split.maximumPrimaryColumnWidth,
                              MAX(split.minimumPrimaryColumnWidth,
                                  width * split.preferredPrimaryColumnWidthFraction));
        // Ordinary tab roots live in the sidebar. Account's native profile
        // supplies Overview in the secondary pane beneath its shared header.
        if (owner == state.root && ![state.kind isEqualToString:@"account"]) return primary;
        width -= primary;
    }
    // The unfolded portrait layout uses a bottom tab bar. A narrow cover or
    // side window, and the unfolded landscape layout, use the trailing rail.
    BOOL trailingRail = sDuoSplitTargetSize.width > sDuoSplitTargetSize.height
        || sDuoSplitTargetSize.width < 600.0;
    return MAX(0.0, width - (trailingRail ? trailingInset : 0.0));
}

static void ApolloDuoSplitLink(UINavigationController *nav, ApolloDuoSplitState *state) {
    ApolloDuoSplitReference *reference = [ApolloDuoSplitReference new];
    reference.state = state;
    objc_setAssociatedObject(nav, &kDuoSplitReference, reference, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

UINavigationController *ApolloDuoSplitDetailNavigation(UINavigationController *nav) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, NO);
    return state.split && !state.changing ? (state.feed && (!state.host.postsShowingDetail || !state.host.postsSplitEnabled) ? state.feed : state.secondary) : nav;
}

UIViewController *ApolloDuoSplitRootController(UINavigationController *nav) {
    return ApolloDuoSplitStateForNavigation(nav, NO).root;
}

CGRect ApolloDuoSplitContentFrame(UIViewController *controller, UIView *coordinateView) {
    UINavigationController *nav = [controller isKindOfClass:UINavigationController.class] ? (id)controller : controller.navigationController;
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, NO);
    // Settings refreshes offscreen pages too. Their retained view hierarchy
    // still supplies the split geometry even while detached from the window.
    if (!state.split || (nav != state.secondary && nav != state.feed)) return CGRectNull;
    // Modern UIKit can extend the secondary surface beneath the sidebar. Its
    // safe-area guide, rather than its full bounds, is the visible column.
    UIView *view = nav.view;
    UIEdgeInsets insets = view.safeAreaInsets;
    // Center across the whole detail pane, including its trailing navigation
    // strip. Only the leading sidebar is excluded from this alignment band.
    insets.right = 0.0;
    CGRect content = UIEdgeInsetsInsetRect(view.bounds, insets);
    return [coordinateView convertRect:content fromView:view];
}

BOOL ApolloDuoSplitIsAccountFeedController(UIViewController *controller) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(controller.navigationController, NO);
    if (!state.split || ![state.kind isEqualToString:@"account"]
        || ![state.secondary.viewControllers containsObject:controller]) return NO;
    // A real comment thread has depth and linked-comment highlight colors.
    // The profile and shortcut lists instead render independent feed cards.
    return ![NSStringFromClass(controller.class) isEqualToString:@"Apollo.CommentsViewController"];
}

BOOL ApolloDuoSplitIsOwnAccountController(UIViewController *controller) {
    UITabBarController *tabs = (id)ApolloMainTabBarController();
    if (![tabs isKindOfClass:UITabBarController.class] || !controller) return NO;
    for (UIViewController *child in tabs.viewControllers) {
        if (![child isKindOfClass:UINavigationController.class]) continue;
        UINavigationController *navigation = (id)child;
        ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(navigation, NO);
        UIViewController *root = state.split ? (state.tabRoot ?: state.root) : navigation.viewControllers.firstObject;
        if (root == controller && [ApolloDuoSplitKind(root) isEqualToString:@"account"]) return YES;
    }
    return NO;
}

BOOL ApolloDuoSplitSuppressesFeedActions(UIViewController *controller) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(controller.navigationController, NO);
    return state.feed && state.host.postsColumnsPaired && controller.navigationController == state.feed;
}

BOOL ApolloDuoSplitIsSubredditOverlayView(UIView *view) {
    for (UIResponder *responder = view; responder; responder = responder.nextResponder) {
        if (![responder isKindOfClass:UIViewController.class]) continue;
        UIViewController *controller = (id)responder;
        UINavigationController *nav = [controller isKindOfClass:UINavigationController.class] ? (id)controller : controller.navigationController;
        ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, NO);
        return state.feed && state.split && !state.changing && nav == state.primary;
    }
    return NO;
}

UIColor *ApolloDuoSplitOverlayBackground(UIView *view, UIColor *color) {
    if (!NSThread.isMainThread || !color || CGColorGetAlpha(color.CGColor) == 0
        || CGRectGetWidth(view.bounds) < 200 || CGRectGetHeight(view.bounds) < 8
        || [view isKindOfClass:UILabel.class] || [view isKindOfClass:UIImageView.class]
        || [view isKindOfClass:UIControl.class] || !ApolloDuoSplitIsSubredditOverlayView(view)) return color;
    return UIColor.clearColor;
}

void ApolloDuoSplitPrepareOverlaySurface(UIView *surface) {
    if (!ApolloDuoSplitIsSubredditOverlayView(surface)) return;
    ApolloDuoSplitHost *host = nil;
    for (UIResponder *responder = surface; responder; responder = responder.nextResponder) {
        if (![responder isKindOfClass:UIViewController.class]) continue;
        UIViewController *owner = (id)responder;
        host = ApolloDuoSplitStateForNavigation(owner.navigationController, NO).host;
        break;
    }
    if (!host.listBackgrounds) host.listBackgrounds = [NSMapTable weakToStrongObjectsMapTable];
    NSMutableArray *views = [NSMutableArray arrayWithObject:surface];
    for (NSUInteger i = 0; i < views.count; i++) [views addObjectsFromArray:((UIView *)views[i]).subviews];
    for (UIView *view in views) {
        // Preserve icon tiles, controls and the accent divider. Clear the
        // reusable native cell/header surfaces, including editing backgrounds.
        if ([view isKindOfClass:UILabel.class] || [view isKindOfClass:UIImageView.class]
            || [view isKindOfClass:UIControl.class] || view.bounds.size.height < 8) continue;
        if (![host.listBackgrounds objectForKey:view]) [host.listBackgrounds setObject:view.backgroundColor ?: UIColor.clearColor forKey:view];
        view.backgroundColor = UIColor.clearColor;
    }
}

BOOL ApolloDuoSplitIsSidebarController(UIViewController *controller) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(controller.navigationController, NO);
    return state.split && state.root == controller && ![state.kind isEqualToString:@"account"];
}

// A Posts-tab reselect at the feed root reveals the drawer without toggling it
// closed again. Other tabs and the cover display keep their native behavior.
BOOL ApolloDuoSplitRevealPostsList(UINavigationController *nav) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, NO);
    if (!state.split || !state.feed || state.changing) return NO;
    [state.host setListVisible:YES animated:!UIAccessibilityIsReduceMotionEnabled()];
    return YES;
}

BOOL ApolloDuoSplitShowSidebar(UINavigationController *nav) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, NO);
    if (!state.split) return NO;
    if (state.feed) [state.host setListVisible:!state.host.listVisible animated:YES];
    else [state.split showColumn:UISplitViewControllerColumnPrimary];
    return YES;
}

// Never infer Duo merely from a landscape iPhone. Its native trailing tab bar
// or established Duo mode must be present, and two useful columns must fit.
static BOOL ApolloDuoSplitShouldOpen(UITabBarController *tabs) {
    CGSize size = tabs == sDuoSplitResizingTabs ? sDuoSplitTargetSize : tabs.view.bounds.size;
    if (ApolloDuoRailHasVisibleSideBar() || ApolloDuoCurrentMode() == ApolloDuoModeOpen) {
        sDuoSplitKnownTabs = tabs;
    }
    return UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone
        && size.width >= 800.0 && size.width > size.height
        && tabs == sDuoSplitKnownTabs;
}

// Observe the public hinge interaction on the tab container, rather than
// inferring a book posture from window size. A side window can have the same
// aspect ratio as a cover display; neither should acquire a second column.
// Resolve the iOS 27.1 API dynamically so device builds using the 26 SDK keep
// working, as do older iPhones. UIHingeStatusPartiallyOpen is documented as 2.
static BOOL ApolloDuoSplitWantsHalfWidth(UITabBarController *tabs) {
    return [objc_getAssociatedObject(tabs, &kDuoSplitHingeStatus) integerValue] == 2;
}

static void ApolloDuoSplitObserveHinge(UITabBarController *tabs) {
    if (objc_getAssociatedObject(tabs, &kDuoSplitHingeInteraction)) return;
    if (@available(iOS 27.1, *)) {
        Class cls = NSClassFromString(@"UIHingeInteraction");
        if (!cls) return;
        __weak UITabBarController *weakTabs = tabs;
        void (^handler)(id, id) = ^(__unused id interaction, id update) {
            UITabBarController *owner = weakTabs;
            if (!owner) return;
            id hinge = ((id (*)(id, SEL))objc_msgSend)(update, NSSelectorFromString(@"hinge"));
            NSInteger status = hinge ? ((NSInteger (*)(id, SEL))objc_msgSend)(hinge, NSSelectorFromString(@"status")) : 0;
            NSInteger previous = [objc_getAssociatedObject(owner, &kDuoSplitHingeStatus) integerValue];
            if (previous == status) return;
            objc_setAssociatedObject(owner, &kDuoSplitHingeStatus, @(status), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            ApolloLog(@"[DuoSplit] hinge status %ld -> %ld", (long)previous, (long)status);
            // Defer containment work out of UIKit's interaction delivery. The
            // normal update also prepares the tabs that are not selected.
            ApolloDuoSplitScheduleUpdate();
        };
        id<UIInteraction> interaction = ((id (*)(id, SEL, id))objc_msgSend)([cls alloc], NSSelectorFromString(@"initWithUpdateHandler:"), handler);
        objc_setAssociatedObject(tabs, &kDuoSplitHingeInteraction, interaction, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [tabs.view addInteraction:interaction];
    }
}

static void ApolloDuoSplitApplySidebarWidth(ApolloDuoSplitState *state, BOOL halfWidth) {
    UISplitViewController *split = state.split;
    if (!split) return;
    state.halfWidthSidebar = halfWidth;
    // Lift the ordinary sidebar cap in book posture: half of a 951pt inner
    // display is 475.5pt, and retaining the 420pt cap misses the hinge.
    CGSize canvas = sDuoSplitResizingTabs ? sDuoSplitTargetSize : state.host.view.bounds.size;
    BOOL postsLandscape = state.feed && canvas.width > canvas.height;
    CGFloat half = canvas.width * 0.5;
    // UIKit may keep an earlier sidebar width across column replacement.
    // Bound both ends for Posts so its actual divider stays at the midpoint.
    CGFloat maximum = postsLandscape ? half : (state.feed || halfWidth ? CGFLOAT_MAX : 420.0);
    CGFloat minimum = postsLandscape ? half : 240.0;
    if (split.maximumPrimaryColumnWidth != maximum) split.maximumPrimaryColumnWidth = maximum;
    if (split.minimumPrimaryColumnWidth != minimum) split.minimumPrimaryColumnWidth = minimum;
    split.preferredPrimaryColumnWidthFraction = halfWidth ? 0.5 : (state.feed ? 0.5 : 1.0 / 3.0);
    if (@available(iOS 26.0, *)) {
        // UIKit's default secondary minimum (532pt on this inner display)
        // otherwise caps the primary at 419pt even with a 50% preference.
        split.minimumSecondaryColumnWidth = state.feed || halfWidth ? 240.0 : UISplitViewControllerAutomaticDimension;
    }
    if (halfWidth && !state.feed) {
        split.preferredDisplayMode = UISplitViewControllerDisplayModeOneBesideSecondary;
        [split showColumn:UISplitViewControllerColumnPrimary];
    }
}

BOOL ApolloDuoRequiresSubredditEnhancements(void) {
    return ApolloDuoCurrentMode() != ApolloDuoModePhone || ApolloDuoSplitIsUnfolded();
}

static BOOL ApolloDuoPostsUsesSplit(ApolloDuoSplitState *state) {
    CGSize size = sDuoSplitResizingTabs ? sDuoSplitTargetSize : state.host.view.bounds.size;
    return state.host.postsSplitEnabled && size.width > size.height;
}

static void ApolloDuoPostsSyncColumns(ApolloDuoSplitState *state) {
    if (!state.feed || !state.split || state.changing) return;
    ApolloDuoSplitApplySidebarWidth(state, state.halfWidthSidebar);
    if (!state.primary.navigationBarHidden) [state.primary setNavigationBarHidden:YES animated:NO];
    UIViewController *listRoot = state.primary.viewControllers.firstObject;
    UIEdgeInsets currentInsets = listRoot.additionalSafeAreaInsets;
    CGFloat inheritedRight = listRoot.view.safeAreaInsets.right - currentInsets.right;
    CGFloat inheritedTop = listRoot.view.safeAreaInsets.top - currentInsets.top;
    UIEdgeInsets desiredInsets = state.host.originalListInsets;
    desiredInsets.top = 76 - inheritedTop;
    desiredInsets.right = -inheritedRight;
    if (!UIEdgeInsetsEqualToEdgeInsets(currentInsets, desiredInsets)) listRoot.additionalSafeAreaInsets = desiredInsets;
    if (state.host.listVisible) [state.host prepareListGlass];
    // Swift navigation helpers can bypass the ObjC push entry point.
    // Move their destination, not a second copy of the feed, into comments.
    if (ApolloDuoPostsUsesSplit(state) && state.feed.viewControllers.count > 1 && !state.feed.transitionCoordinator) {
        NSArray *pushed = [state.feed.viewControllers subarrayWithRange:NSMakeRange(1, state.feed.viewControllers.count - 1)];
        state.changing = YES;
        [state.feed setViewControllers:@[state.feed.viewControllers.firstObject] animated:NO];
        [state.secondary setViewControllers:[@[state.secondary.viewControllers.firstObject] arrayByAddingObjectsFromArray:pushed] animated:NO];
        state.changing = NO;
    }
    if (!ApolloDuoPostsUsesSplit(state) && state.secondary.viewControllers.count > 1) {
        NSArray *destinations = [state.secondary.viewControllers subarrayWithRange:NSMakeRange(1, state.secondary.viewControllers.count - 1)];
        state.changing = YES;
        [state.secondary setViewControllers:@[state.secondary.viewControllers.firstObject] animated:NO];
        [state.feed setViewControllers:[@[state.feed.viewControllers.firstObject] arrayByAddingObjectsFromArray:destinations] animated:NO];
        state.changing = NO;
    }
    [state.host.viewIfLoaded setNeedsLayout];
    BOOL detail = state.secondary.viewControllers.count > 1;
    BOOL paired = detail && ApolloDuoPostsUsesSplit(state);
    if (state.host.postsShowingDetail == detail && state.host.postsColumnsPaired == paired && state.feed.parentViewController) return;
    state.changing = YES;
    state.host.postsShowingDetail = detail;
    state.host.postsColumnsPaired = paired;
    UINavigationItem *feedItem = state.feed.topViewController.navigationItem;
    if (paired) {
        if (!state.feedActions) state.feedActions = feedItem.rightBarButtonItems ?: @[];
        feedItem.rightBarButtonItems = @[];
    } else if (state.feedActions) {
        feedItem.rightBarButtonItems = state.feedActions;
        state.feedActions = nil;
    }
    UISplitViewController *split = state.split;
    if (detail) {
        [split setViewController:nil forColumn:UISplitViewControllerColumnSecondary];
        [split setViewController:state.feed forColumn:UISplitViewControllerColumnPrimary];
        [split setViewController:state.secondary forColumn:UISplitViewControllerColumnSecondary];
        split.preferredDisplayMode = paired ? UISplitViewControllerDisplayModeOneBesideSecondary : UISplitViewControllerDisplayModeSecondaryOnly;
        if (paired) [split showColumn:UISplitViewControllerColumnPrimary];
        else [split hideColumn:UISplitViewControllerColumnPrimary];
    } else {
        [split setViewController:nil forColumn:UISplitViewControllerColumnPrimary];
        [split setViewController:state.feed forColumn:UISplitViewControllerColumnSecondary];
        split.preferredDisplayMode = UISplitViewControllerDisplayModeSecondaryOnly;
        [split hideColumn:UISplitViewControllerColumnPrimary];
    }
    [state.host.view setNeedsLayout];
    state.changing = NO;
}

// Column creation/removal is containment, not a navigation push. Animate the
// visible right pane across that boundary; deeper pages retain Apollo's own
// navigation transition. The live feed and its scroll position are retained.
static void ApolloDuoPostsSetDetail(ApolloDuoSplitState *state, UIViewController *page, BOOL animated) {
    UIView *surface = state.host.view;
    BOOL entering = page != nil;
    BOOL animate = animated && surface.window && !UIAccessibilityIsReduceMotionEnabled();
    CGRect pane = CGRectMake(surface.bounds.size.width * 0.5, 0,
                             surface.bounds.size.width * 0.5, surface.bounds.size.height);
    UIView *snapshot = !entering && animate ? [surface resizableSnapshotViewFromRect:pane afterScreenUpdates:NO withCapInsets:UIEdgeInsetsZero] : nil;
    [UIView performWithoutAnimation:^{
        state.changing = YES;
        UIViewController *backstop = state.secondary.viewControllers.firstObject;
        [state.secondary setViewControllers:page ? @[backstop, page] : @[backstop] animated:NO];
        state.changing = NO;
        ApolloDuoPostsSyncColumns(state);
        [surface layoutIfNeeded];
    }];
    if (entering && animate) snapshot = [surface resizableSnapshotViewFromRect:pane afterScreenUpdates:YES withCapInsets:UIEdgeInsetsZero];
    if (!snapshot) return;
    snapshot.frame = pane;
    snapshot.userInteractionEnabled = NO;
    [surface insertSubview:snapshot belowSubview:state.host.listDismiss];
    UIView *incoming = entering ? state.secondary.view : nil;
    incoming.alpha = 0;
    surface.userInteractionEnabled = NO;
    ApolloDuoSlideView(snapshot, entering ? pane.size.width : 0,
                       entering ? 0 : pane.size.width, 0.32, ^{
        incoming.alpha = 1;
        [snapshot removeFromSuperview];
        surface.userInteractionEnabled = YES;
    });
}

static UITableView *ApolloDuoSplitFindTable(UIView *view) {
    if ([view isKindOfClass:UITableView.class]) return (id)view;
    for (UIView *child in view.subviews) {
        UITableView *table = ApolloDuoSplitFindTable(child);
        if (table) return table;
    }
    return nil;
}

static BOOL ApolloDuoSplitViewHasLabel(UIView *view, NSSet<NSString *> *labels) {
    if ([view isKindOfClass:UILabel.class] && [labels containsObject:((UILabel *)view).text]) return YES;
    if (view.accessibilityLabel && [labels containsObject:view.accessibilityLabel]) return YES;
    for (UIView *child in view.subviews) {
        if (ApolloDuoSplitViewHasLabel(child, labels)) return YES;
    }
    return NO;
}

static BOOL ApolloDuoSplitSelectRow(UIViewController *root, NSSet<NSString *> *labels) {
    [root loadViewIfNeeded];
    UITableView *table = ApolloDuoSplitFindTable(root.view);
    if (!table || ![table.delegate respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) return NO;
    [table layoutIfNeeded];
    for (NSInteger section = 0; section < MIN(table.numberOfSections, 40); section++) {
        for (NSInteger row = 0; row < MIN([table numberOfRowsInSection:section], 40); row++) {
            NSIndexPath *path = [NSIndexPath indexPathForRow:row inSection:section];
            UIView *content = [table cellForRowAtIndexPath:path];
            BOOL matches = NO;
            if ([table respondsToSelector:NSSelectorFromString(@"nodeForRowAtIndexPath:")]) {
                id node = ((id (*)(id, SEL, id))objc_msgSend)(table, NSSelectorFromString(@"nodeForRowAtIndexPath:"), path);
                // Texture's offscreen shortcut nodes expose their label on
                // the node; their backing views have no accessibility label.
                if ([node respondsToSelector:@selector(accessibilityLabel)]) {
                    matches = [labels containsObject:[node accessibilityLabel] ?: @""];
                }
                if (!content && [node respondsToSelector:@selector(view)]) content = [node view];
            } else if (!content) {
                content = [table.dataSource tableView:table cellForRowAtIndexPath:path];
            }
            if (matches || (content && ApolloDuoSplitViewHasLabel(content, labels))) {
                [table.delegate tableView:table didSelectRowAtIndexPath:path];
                return YES;
            }
        }
    }
    return NO;
}

static UIViewController *ApolloDuoSplitForwardPage(UINavigationController *nav) {
    // Read-only native Swift storage, as used by ForwardSwipeExpiry. Let
    // Apollo's native push bookkeeping consume it; never mutate the array.
    Ivar ivar = class_getInstanceVariable(nav.class, "poppedViewControllers");
    if (!ivar) return nil;
    uintptr_t word = 0;
    memcpy(&word, (const uint8_t *)(__bridge const void *)nav + ivar_getOffset(ivar), sizeof(word));
    if (!word || (word & 0xC000000000000007ull)) return nil;
    id storage = (__bridge id)(void *)word;
    if (![storage respondsToSelector:@selector(firstObject)]) return nil;
    id page = [storage firstObject];
    return [page isKindOfClass:UIViewController.class] ? page : nil;
}

static BOOL ApolloDuoSplitOpenStartupFeed(ApolloDuoSplitState *state) {
    // Native General stores ["subreddit", name], ["multireddit", user, name],
    // or a one-element built-in-feed choice (verified in Apollo's setter).
    NSArray *choice = [NSUserDefaults.standardUserDefaults arrayForKey:@"DefaultRedditToLoad"];
    NSString *kind = [choice.firstObject isKindOfClass:NSString.class] ? [choice.firstObject lowercaseString] : @"home";
    NSString *path = @"/";
    if ([kind isEqualToString:@"subreddit"] && choice.count >= 2 && [choice[1] isKindOfClass:NSString.class]) {
        path = [@"/r/" stringByAppendingString:choice[1]];
    } else if ([kind isEqualToString:@"multireddit"] && choice.count >= 3 &&
               [choice[1] isKindOfClass:NSString.class] && [choice[2] isKindOfClass:NSString.class]) {
        path = [NSString stringWithFormat:@"/user/%@/m/%@", choice[1], choice[2]];
    } else if ([kind containsString:@"popular"]) {
        path = @"/r/popular";
    } else if ([kind isEqualToString:@"all"]) {
        path = @"/r/all";
    }
    if ([path isEqualToString:@"/"]) {
        // Home is a native feed row, but the enhanced list presents it in a
        // separate shortcut control. Searching visible row labels misses it.
        // Use the same visible-index mapping as the shortcut's tap handler.
        UITableView *table = ApolloDuoSplitFindTable(state.root.view);
        NSUInteger row = [ApolloFeedShortcutVisibleIndexes() indexOfObject:@0];
        if (row == NSNotFound || table.numberOfSections == 0 ||
            row >= (NSUInteger)[table numberOfRowsInSection:0] ||
            ![table.delegate respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) return NO;
        [table.delegate tableView:table didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:0]];
        return (state.feed ?: state.secondary).viewControllers.firstObject.class != UIViewController.class;
    }
    NSURLComponents *url = [NSURLComponents componentsWithString:@"https://www.reddit.com"];
    url.path = path;
    return ApolloRouteURLThroughApp(url.URL);
}

static void ApolloDuoSplitOpenDefault(ApolloDuoSplitState *state) {
    if (!state.needsDefault || state.changing || !state.split || state.outer.presentedViewController) return;
    state.needsDefault = NO;
    if ([state.kind isEqualToString:@"settings"]) {
        NSArray *saved = state.lastSettings;
        if (saved.count && ![saved.firstObject parentViewController]) {
            [state.secondary setViewControllers:saved animated:NO];
        } else {
            [state.secondary setViewControllers:@[[[CustomAPIViewController alloc] initWithStyle:UITableViewStyleInsetGrouped]] animated:NO];
        }
    } else if ([state.kind isEqualToString:@"subreddits"]) {
        state.needsDefault = !ApolloDuoSplitOpenStartupFeed(state);
    } else if ([state.kind isEqualToString:@"account"]) {
        // The native profile is already installed as the initial Overview.
    } else if (![state.kind isEqualToString:@"search"]) {
        NSSet *labels = [state.kind isEqualToString:@"inbox"]
            ? [NSSet setWithObjects:@"Inbox (All)", @"Inbox", nil] : [NSSet setWithObject:@"Posts"];
        // A profile may still be fetching its menu. Leave the default pending
        // until its table reloads; do not invent a Posts controller or row index.
        state.needsDefault = !ApolloDuoSplitSelectRow(state.root, labels);
    }
}

extern void ApolloHiddenContentPresentFromProfile(UIViewController *profile);

static void ApolloDuoAccountSetPages(ApolloDuoSplitState *state, NSArray<UIViewController *> *pages) {
    UIView *surface = state.host.view;
    if ([state.secondary.viewControllers isEqualToArray:pages]) return;
    // Size the destination column before Apollo's navigation controller takes
    // its transition snapshots. Only the secondary stack slides; the shared
    // header and shortcuts keep their existing geometry.
    state.host.pendingAccountDetail = @(pages.count > 1);
    [UIView performWithoutAnimation:^{
        [surface setNeedsLayout];
        [surface layoutIfNeeded];
    }];
    // UINavigationController selects a pop when the destination is already in
    // the stack and a push for a new shortcut. Keep Apollo's animator/delegate.
    BOOL animated = surface.window && !UIAccessibilityIsReduceMotionEnabled();
    [state.secondary setViewControllers:pages animated:animated];
    state.host.pendingAccountDetail = nil;
    [state.secondary setNavigationBarHidden:pages.count == 1 animated:animated];

}

static void ApolloDuoAccountSelect(ApolloDuoSplitState *state, NSString *title) {
    if (!state.split || state.changing) return;
    if ([title isEqualToString:@"Overview"]) {
        ApolloDuoAccountSetPages(state, @[state.root]);
        return;
    }
    state.selectingAccountShortcut = YES;
    if ([title isEqualToString:@"Hidden & Deleted"]) ApolloHiddenContentPresentFromProfile(state.root);
    else ApolloDuoSplitSelectRow(state.root, [NSSet setWithObject:title]);
    state.selectingAccountShortcut = NO;
    [state.host.view setNeedsLayout];
}

static void ApolloDuoSplitClose(ApolloDuoSplitState *state, BOOL preserveDetail);
static void ApolloDuoSplitNavigateProfile(ApolloDuoSplitState *state, UIViewController *profile, BOOL forward);

static void ApolloDuoAccountPrepareHost(ApolloDuoSplitState *state, ApolloDuoSplitHost *host) {
    UIViewController *profile = state.root;
    host.accountHeader = ApolloDuoAccountProfileHeader(profile);
    UIButton *sidebar = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *sidebarConfiguration;
    if (@available(iOS 26.0, *)) sidebarConfiguration = [UIButtonConfiguration glassButtonConfiguration];
    else sidebarConfiguration = [UIButtonConfiguration tintedButtonConfiguration];
    sidebarConfiguration.image = [UIImage systemImageNamed:@"sidebar.left"];
    sidebarConfiguration.baseForegroundColor = UIColor.labelColor;
    sidebarConfiguration.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    sidebar.configuration = sidebarConfiguration;
    sidebar.accessibilityLabel = @"Toggle Sidebar";
    __weak ApolloDuoSplitHost *weakHost = host;
    [sidebar addAction:[UIAction actionWithHandler:^(__unused UIAction *action) {
        UISplitViewController *split = weakHost.split;
        if (split.displayMode == UISplitViewControllerDisplayModeSecondaryOnly) {
            [split showColumn:UISplitViewControllerColumnPrimary];
        } else {
            [split hideColumn:UISplitViewControllerColumnPrimary];
        }
    }] forControlEvents:UIControlEventTouchUpInside];
    host.sidebarButton = sidebar;
    if (state.profilePrefix.count) {
        UIButton *back = [UIButton buttonWithType:UIButtonTypeSystem];
        UIButtonConfiguration *backConfiguration = [sidebarConfiguration copy];
        backConfiguration.image = [UIImage systemImageNamed:@"chevron.left"];
        back.configuration = backConfiguration;
        back.accessibilityLabel = @"Back";
        __weak ApolloDuoSplitState *weakProfileState = state;
        [back addAction:[UIAction actionWithHandler:^(__unused UIAction *action) {
            ApolloDuoSplitState *current = weakProfileState;
            if (!current || current.changing) return;
            ApolloDuoSplitNavigateProfile(current, nil, NO);
        }] forControlEvents:UIControlEventTouchUpInside];
        host.profileBackButton = back;
    }
    __weak ApolloDuoSplitState *weakState = state;
    UIButton *accounts = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *configuration;
    if (@available(iOS 26.0, *)) configuration = [UIButtonConfiguration glassButtonConfiguration];
    else configuration = [UIButtonConfiguration tintedButtonConfiguration];
    configuration.baseForegroundColor = UIColor.labelColor;
    configuration.image = [UIImage systemImageNamed:@"person.2" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightRegular]];
    configuration.contentInsets = NSDirectionalEdgeInsetsZero;
    accounts.accessibilityLabel = @"Accounts";
    configuration.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    accounts.configuration = configuration;
    [accounts addAction:[UIAction actionWithHandler:^(__unused UIAction *action) {
        UIViewController *root = weakState.root;
        SEL selector = NSSelectorFromString(@"accountsBarButtonItemTappedWithSender:");
        if ([root respondsToSelector:selector]) ((void (*)(id, SEL, id))objc_msgSend)(root, selector, nil);
    }] forControlEvents:UIControlEventTouchUpInside];
    host.accountsButton = accounts;
    UIButton *more = [UIButton buttonWithType:UIButtonTypeSystem];
    if (@available(iOS 26.0, *)) configuration = [UIButtonConfiguration glassButtonConfiguration];
    else configuration = [UIButtonConfiguration tintedButtonConfiguration];
    Ivar moreIvar = class_getInstanceVariable([profile class], "moreOptionsBarButtonItem");
    UIBarButtonItem *nativeMore = moreIvar ? object_getIvar(profile, moreIvar) : nil;
    configuration.image = nativeMore.image ?: [UIImage systemImageNamed:@"ellipsis"];
    configuration.contentInsets = NSDirectionalEdgeInsetsZero;
    configuration.baseForegroundColor = UIColor.labelColor;
    configuration.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    more.configuration = configuration;
    more.accessibilityLabel = @"More Options";
    UIAction *trophies = [UIAction actionWithTitle:@"Trophies" image:[UIImage systemImageNamed:@"trophy"] identifier:nil handler:^(__unused UIAction *action) {
        ApolloDuoAccountSelect(weakState, @"Trophies");
    }];
    UIMenu *nativeMenu = ApolloProfileMoreMenuForController(profile);
    more.menu = [UIMenu menuWithTitle:@"" children:[(nativeMenu.children ?: @[]) arrayByAddingObject:trophies]];
    more.showsMenuAsPrimaryAction = YES;
    host.moreButton = more;
    accounts.tintColor = UIColor.labelColor;
    more.tintColor = ApolloNavigationChromeColor();
}

static void ApolloDuoSplitOpen(ApolloDuoSplitState *state) {
    UINavigationController *outer = state.outer;
    id<UIViewControllerTransitionCoordinator> transition = outer.transitionCoordinator;
    if (state.split || state.changing || outer.presentedViewController) return;
    if (transition && transition != sDuoSplitSizeCoordinator) {
        // A native push/pop may still own the stack when unfolding begins.
        // Retry at its completion; a layout pass during that transition is
        // too early, and the idle tab may never produce another one.
        if (state.pendingNavigationTransition != transition) {
            state.pendingNavigationTransition = transition;
            __weak ApolloDuoSplitState *weakState = state;
            [transition animateAlongsideTransition:nil
                                       completion:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) {
                weakState.pendingNavigationTransition = nil;
                ApolloDuoSplitScheduleUpdate();
            }];
        }
        return;
    }
    state.changing = YES;
    if ([state.kind isEqualToString:@"subreddits"] && outer.viewControllers.count == 1) {
        UIViewController *forward = ApolloDuoSplitForwardPage(outer);
        if (forward) {
            // goForward calls Apollo's Swift push helper directly with
            // animated:YES. performWithoutAnimation does not change that
            // navigation operation, nor does it reach our ObjC push hook.
            // Reparenting its pages immediately leaves the pending transition
            // owning the outer stack: its completion removes our split host
            // and the tab ends up with no controllers at all.
            // Consume the same forward entry through a genuinely nonanimated
            // push, then build the columns on the next main-queue turn, after
            // native didShow/history bookkeeping has finished.
            [outer pushViewController:forward animated:NO];
            if (outer.topViewController == forward) {
                state.changing = NO;
                ApolloLog(@"[DuoSplit] restored forward page before installing columns");
                ApolloDuoSplitScheduleUpdate();
                return;
            }
        }
    }
    NSArray *stack = [outer.viewControllers copy];
    NSUInteger rootIndex = 0;
    // The most recently opened profile owns the dashboard, regardless of tab.
    for (NSUInteger index = 1; index < stack.count; index++) {
        if ([ApolloDuoSplitKind(stack[index]) isEqualToString:@"account"]) rootIndex = index;
    }
    if (rootIndex) {
        state.tabRoot = state.root;
        state.tabKind = state.kind;
        state.profilePrefix = [stack subarrayWithRange:NSMakeRange(0, rootIndex)];
        state.root = stack[rootIndex];
        state.kind = @"account";
    }
    NSArray *detail = stack.count > rootIndex + 1
        ? [stack subarrayWithRange:NSMakeRange(rootIndex + 1, stack.count - rootIndex - 1)] : @[];
    state.navigationBarWasHidden = outer.navigationBarHidden;
    state.sidebarTitle = state.root.navigationItem.title;
    UISplitViewController *split = [[UISplitViewController alloc] initWithStyle:UISplitViewControllerStyleDoubleColumn];
    // An unfold starts while the outer controller still has the cover
    // display's compact traits. Pin the split itself before attaching either
    // column: a parent override applied afterward is too late and UIKit starts
    // a compact-column merge during viewWillTransitionToSize:.
    if (@available(iOS 17.0, *)) {
        split.traitOverrides.horizontalSizeClass = UIUserInterfaceSizeClassRegular;
    }
    split.preferredSplitBehavior = UISplitViewControllerSplitBehaviorTile;
    split.preferredDisplayMode = UISplitViewControllerDisplayModeOneBesideSecondary;
    split.preferredPrimaryColumnWidthFraction = 1.0 / 3.0;
    split.minimumPrimaryColumnWidth = 240.0;
    split.maximumPrimaryColumnWidth = 420.0;
    split.primaryEdge = UISplitViewControllerPrimaryEdgeLeading;
    split.presentsWithGesture = YES;
    // Release native ownership before reparenting. No view/frame stealing,
    // layout-loop repinning, or replacement of the tab's navigation object.
    ApolloDuoSplitHost *host = [ApolloDuoSplitHost new];
    // Dark/opaque themes make the native tab bar nontranslucent. A plain
    // controller's default layout then subtracts the vertical rail's entire
    // height as though it were a bottom bar, collapsing this host to zero.
    // Match Apollo's native pages and let the split's safe areas own the inset.
    host.extendedLayoutIncludesOpaqueBars = YES;
    host.split = split;
    state.host = host;
    BOOL account = [state.kind isEqualToString:@"account"];
    if (account) ApolloDuoAccountPrepareHost(state, host);
    BOOL posts = [state.kind isEqualToString:@"subreddits"];
    [outer setViewControllers:@[host] animated:NO];
    state.split = split;
    state.root.extendedLayoutIncludesOpaqueBars = YES;
    ApolloDuoAccountShortcuts *shortcuts = account ? [ApolloDuoAccountShortcuts new] : nil;
    shortcuts.profileTable = account ? ApolloDuoSplitFindTable(state.root.view) : nil;
    state.primary = [[outer.class alloc] initWithRootViewController:shortcuts ?: state.root];
    state.secondary = [[outer.class alloc] init];
    ApolloDuoSplitLink(state.primary, state);
    ApolloDuoSplitLink(state.secondary, state);
    if (account) {
        [state.primary setNavigationBarHidden:YES animated:NO];
        [state.secondary setViewControllers:[@[state.root] arrayByAddingObjectsFromArray:detail] animated:NO];
        [state.secondary setNavigationBarHidden:detail.count == 0 animated:NO];
        __weak ApolloDuoSplitState *weakState = state;
        shortcuts.selectShortcut = ^(NSString *title) { ApolloDuoAccountSelect(weakState, title); };
        ApolloDuoAccountConfigureOverviewTable(ApolloDuoSplitFindTable(state.root.view), YES);
    } else if (detail.count) [state.secondary setViewControllers:detail animated:NO];
    else {
        UIViewController *placeholder = [UIViewController new];
        placeholder.view.backgroundColor = UIColor.systemBackgroundColor;
        [state.secondary setViewControllers:@[placeholder] animated:NO];
    }
    if (posts) {
        state.feed = [[outer.class alloc] init];
        ApolloDuoSplitLink(state.feed, state);
        NSArray *feedPages = detail.count ? @[detail.firstObject] : @[[UIViewController new]];
        [state.secondary setViewControllers:@[] animated:NO];
        [state.feed setViewControllers:feedPages animated:NO];
        UIViewController *backstop = [UIViewController new];
        backstop.title = @"Feed";
        NSArray *comments = detail.count > 1 ? [detail subarrayWithRange:NSMakeRange(1, detail.count - 1)] : @[];
        [state.secondary setViewControllers:[@[backstop] arrayByAddingObjectsFromArray:comments] animated:NO];
        // The host may already have loaded while the outer stack was changed.
        // Recreate it with the overlay configured before viewDidLoad.
        ApolloDuoSplitHost *postsHost = [ApolloDuoSplitHost new];
        postsHost.extendedLayoutIncludesOpaqueBars = YES;
        postsHost.split = split;
        postsHost.subredditList = state.primary;
        postsHost.postsNavigation = state.feed;
        postsHost.postsSplitEnabled = ![NSUserDefaults.standardUserDefaults boolForKey:@"ApolloDuoPostsSplitDisabled"];
        split.displayModeButtonVisibility = UISplitViewControllerDisplayModeButtonVisibilityNever;
        split.presentsWithGesture = NO;
        __weak ApolloDuoSplitState *weakPostsState = state;
        postsHost.togglePostsSplit = ^{
            ApolloDuoSplitState *live = weakPostsState;
            live.host.postsSplitEnabled = !live.host.postsSplitEnabled;
            [NSUserDefaults.standardUserDefaults setBool:!live.host.postsSplitEnabled forKey:@"ApolloDuoPostsSplitDisabled"];
            [live.host updateSplitButton];
            ApolloDuoPostsSyncColumns(live);
        };
        if (split.parentViewController) {
            [split willMoveToParentViewController:nil];
            [split.view removeFromSuperview];
            [split removeFromParentViewController];
        }
        state.host = postsHost;
        host = postsHost;
        [outer setViewControllers:@[host] animated:NO];
        state.changing = NO;
        ApolloDuoPostsSyncColumns(state);
        state.changing = YES;
    } else if (account) {
        host.accountPrimary = [ApolloDuoAccountColumn new];
        host.accountPrimary.extendedLayoutIncludesOpaqueBars = YES;
        host.accountPrimary.navigation = state.primary;
        host.accountSecondary = [ApolloDuoAccountColumn new];
        host.accountSecondary.extendedLayoutIncludesOpaqueBars = YES;
        host.accountSecondary.navigation = state.secondary;
        CGFloat height = ApolloDuoAccountHeaderHeight(host.accountHeader, outer.view.bounds.size.width);
        host.accountPrimary.contentTop = height;
        host.accountSecondary.contentTop = detail.count ? 0 : height;
        [split setViewController:host.accountPrimary forColumn:UISplitViewControllerColumnPrimary];
        [split setViewController:host.accountSecondary forColumn:UISplitViewControllerColumnSecondary];
        // UISplitViewController wraps non-navigation columns in its own
        // navigation controllers. Their bars would duplicate the native page
        // bar (and consume the entire vertical rail under opaque themes).
        [(UINavigationController *)host.accountPrimary.parentViewController setNavigationBarHidden:YES animated:NO];
        [(UINavigationController *)host.accountSecondary.parentViewController setNavigationBarHidden:YES animated:NO];
    } else {
        [split setViewController:state.primary forColumn:UISplitViewControllerColumnPrimary];
        [split setViewController:state.secondary forColumn:UISplitViewControllerColumnSecondary];
    }
    ApolloDuoSplitApplySidebarWidth(state, ApolloDuoSplitWantsHalfWidth((id)outer.tabBarController));
    [outer setNavigationBarHidden:YES animated:NO];
    // The compatibility phone can retain a compact horizontal size class on
    // its wide inner display. The width/rail gate above is authoritative.
    [outer setOverrideTraitCollection:[UITraitCollection traitCollectionWithHorizontalSizeClass:UIUserInterfaceSizeClassRegular]
              forChildViewController:host];
    state.needsDefault = detail.count == 0;
    state.changing = NO;
    ApolloLog(@"[DuoSplit] opened native %@ sidebar/detail", state.kind);
    dispatch_async(dispatch_get_main_queue(), ^{ ApolloDuoSplitOpenDefault(state); });
}

static void ApolloDuoSplitClose(ApolloDuoSplitState *state, BOOL preserveDetail) {
    if (!state.split || state.changing) return;
    state.changing = YES;
    NSArray *detail = [state.secondary.viewControllers copy];
    if (state.feed) {
        [state.host restoreListBackgrounds];
        if (state.feedActions) state.feed.viewControllers.firstObject.navigationItem.rightBarButtonItems = state.feedActions;
        NSArray *comments = detail.count > 1 ? [detail subarrayWithRange:NSMakeRange(1, detail.count - 1)] : @[];
        detail = [state.feed.viewControllers arrayByAddingObjectsFromArray:comments];
        [state.feed setViewControllers:@[] animated:NO];
    }
    if ([state.kind isEqualToString:@"account"]) {
        NSMutableArray *pages = [detail mutableCopy];
        [pages removeObjectIdenticalTo:state.root];
        detail = pages;
        ApolloDuoAccountRestoreProfile(state.root);
        ApolloDuoAccountConfigureOverviewTable(ApolloDuoSplitFindTable(state.root.view), NO);
    }
    if (detail.count && [detail.firstObject class] == UIViewController.class) detail = @[];
    if ([state.kind isEqualToString:@"settings"] && detail.count) state.lastSettings = detail;
    [state.primary setViewControllers:@[] animated:NO];
    [state.secondary setViewControllers:@[] animated:NO];
    [state.outer setOverrideTraitCollection:nil forChildViewController:state.host];
    // Settings and Inbox have automatically selected detail pages. Account
    // starts at Overview, so any remaining detail was opened by the user and
    // must stay on top when the split collapses to the cover display.
    BOOL overviewOnCover = !preserveDetail && !state.profilePrefix.count && !ApolloDuoSplitIsUnfolded()
        && ([state.kind isEqualToString:@"settings"] || [state.kind isEqualToString:@"inbox"]);
    NSArray *restored = overviewOnCover ? @[state.root] : [@[state.root] arrayByAddingObjectsFromArray:detail];
    if (state.profilePrefix.count) restored = [state.profilePrefix arrayByAddingObjectsFromArray:restored];
    [state.outer setViewControllers:restored animated:NO];
    [state.outer setNavigationBarHidden:state.navigationBarWasHidden animated:NO];
    // Account switches update the native profile title while the split is open.
    // Restoring its entry-time title would repoint the cover header at the old user.
    if (![state.kind isEqualToString:@"account"]) state.root.navigationItem.title = state.sidebarTitle;
    if (state.profilePrefix.count) {
        state.root = state.tabRoot;
        state.kind = state.tabKind;
        state.tabRoot = nil;
        state.tabKind = nil;
        state.profilePrefix = nil;
    }
    state.split = nil;
    state.host = nil;
    state.primary = nil;
    state.secondary = nil;
    state.feed = nil;
    state.needsDefault = NO;
    state.changing = NO;
    ApolloLog(@"[DuoSplit] restored single-column %@ stack", state.kind);
}

// Reparent the live pages under one visual transition. A snapshot covers the
// intermediate single-column stack, so UIKit cannot flash that layout first.
static void ApolloDuoSplitNavigateProfile(ApolloDuoSplitState *state, UIViewController *profile, BOOL forward) {
    if (!state.split || state.changing) return;
    UINavigationController *outer = state.outer;
    UIView *oldView = state.host.view;
    UIView *snapshot = [oldView snapshotViewAfterScreenUpdates:NO];
    CGRect frame = [oldView convertRect:oldView.bounds toView:outer.view];
    NSArray *prefix = state.profilePrefix;
    [UIView performWithoutAnimation:^{
        ApolloDuoSplitClose(state, YES);
        NSArray *stack = forward ? [outer.viewControllers arrayByAddingObject:profile] : prefix;
        [outer setViewControllers:stack animated:NO];
        ApolloDuoSplitOpen(state);
        [outer.view layoutIfNeeded];
    }];
    UIView *destination = state.host.view;
    if (!snapshot || !destination || UIAccessibilityIsReduceMotionEnabled()) return;
    snapshot.frame = frame;
    snapshot.userInteractionEnabled = NO;
    [outer.view addSubview:snapshot];
    CGFloat direction = forward ? 1 : -1;
    CGFloat width = CGRectGetWidth(frame);
    destination.transform = CGAffineTransformMakeTranslation(direction * width, 0);
    [outer.view bringSubviewToFront:destination];
    [UIView animateWithDuration:0.28 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        destination.transform = CGAffineTransformIdentity;
        snapshot.transform = CGAffineTransformMakeTranslation(-direction * width, 0);
    } completion:^(__unused BOOL finished) {
        [snapshot removeFromSuperview];
        destination.transform = CGAffineTransformIdentity;
    }];
}

static void ApolloDuoSplitUpdate(void) {
    UITabBarController *tabs = (id)ApolloMainTabBarController();
    if (sDuoSplitUpdating || ![tabs isKindOfClass:UITabBarController.class] || !tabs.isViewLoaded) return;
    if (tabs != sDuoSplitKnownTabs && ApolloDuoCurrentMode() == ApolloDuoModePhone
        && !ApolloDuoRailHasVisibleSideBar()) return;
    sDuoSplitUpdating = YES;
    ApolloDuoSplitObserveHinge(tabs);
    BOOL open = ApolloDuoSplitShouldOpen(tabs);
    for (UIViewController *child in tabs.viewControllers) {
        if (![child isKindOfClass:UINavigationController.class]) continue;
        UINavigationController *nav = (id)child;
        ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, open || child == tabs.selectedViewController);
        if (!state) continue;
        BOOL postsOpen = [state.kind isEqualToString:@"subreddits"] && ApolloDuoSplitIsUnfolded();
        if (!open && !postsOpen) ApolloDuoSplitClose(state, NO);
        else {
            // Native Swift pushes can bypass the ObjC push hook. Normalize a
            // newly visited profile before rebuilding its full-width header.
            for (UIViewController *page in [state.secondary.viewControllers copy]) {
                if (page != state.root && [ApolloDuoSplitKind(page) isEqualToString:@"account"]) {
                    ApolloDuoSplitClose(state, YES);
                    break;
                }
            }
            // Search stays full-width until a result is opened. Once it has
            // a detail page, retain the query/results in the sidebar.
            if ([state.kind isEqualToString:@"search"] && !state.split && nav.viewControllers.count < 2) continue;
            ApolloDuoSplitOpen(state);
            BOOL halfWidth = ApolloDuoSplitWantsHalfWidth(tabs);
            if (state.split && state.halfWidthSidebar != halfWidth) {
                // UIKit animates the same column containers; content and
                // navigation chrome move with the divider in both directions.
                [UIView animateWithDuration:0.25 animations:^{
                    ApolloDuoSplitApplySidebarWidth(state, halfWidth);
                    [state.split.view layoutIfNeeded];
                }];
            }
            ApolloDuoSplitOpenDefault(state);
            ApolloDuoPostsSyncColumns(state);
            if ([state.kind isEqualToString:@"account"] && state.split) {
                BOOL overview = state.secondary.topViewController == state.root;
                if (!state.secondary.transitionCoordinator && state.secondary.navigationBarHidden != overview) {
                    [state.secondary setNavigationBarHidden:overview animated:NO];
                }
                if (state.host.moreButton.hidden == overview) [state.host.view setNeedsLayout];
            }
            if ([state.primary.viewControllers.firstObject isKindOfClass:ApolloDuoAccountShortcuts.class]) {
                [(ApolloDuoAccountShortcuts *)state.primary.viewControllers.firstObject refreshProfileMenu];
            }
        }
    }
    sDuoSplitUpdating = NO;
}

void ApolloDuoSplitScheduleUpdate(void) {
    if (sDuoSplitUpdateScheduled) return;
    UITabBarController *tabs = (id)ApolloMainTabBarController();
    if (![tabs isKindOfClass:UITabBarController.class] || !tabs.isViewLoaded) return;
    if (tabs != sDuoSplitKnownTabs && ApolloDuoCurrentMode() == ApolloDuoModePhone
        && !ApolloDuoRailHasVisibleSideBar()) return;
    sDuoSplitUpdateScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        sDuoSplitUpdateScheduled = NO;
        ApolloDuoSplitUpdate();
    });
}

static BOOL ApolloDuoSplitRoutePush(UINavigationController *nav, UIViewController *page) {
    // UIKit pushes column containers while adapting a split. Those are native
    // containment operations, not sidebar selections. Redirecting the secondary
    // navigation controller into its own stack raises a UIKit assertion.
    if ([page isKindOfClass:UINavigationController.class] ||
        [page isKindOfClass:UISplitViewController.class]) return NO;
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, YES);
    if (state.split && !state.changing && [ApolloDuoSplitKind(page) isEqualToString:@"account"]) {
        ApolloDuoSplitNavigateProfile(state, page, YES);
        return YES;
    }
    if (state.feed && !state.changing) {
        state.needsDefault = NO;
        if (nav == state.primary || (nav == state.outer && [NSStringFromClass(page.class) isEqualToString:@"Apollo.PostsViewController"])) {
            [state.feed setViewControllers:@[page] animated:NO];
            [state.secondary setViewControllers:@[state.secondary.viewControllers.firstObject] animated:NO];
            [state.host setListVisible:NO animated:YES];
        } else if (nav == state.feed || nav == state.outer) {
            if (!ApolloDuoPostsUsesSplit(state)) {
                if (nav == state.feed) return NO;
                [state.feed pushViewController:page animated:YES];
                return YES;
            }
            ApolloDuoPostsSetDetail(state, page, YES);
        } else return NO;
        ApolloDuoPostsSyncColumns(state);
        return YES;
    }
    if ([state.kind isEqualToString:@"search"] && nav == state.outer && !state.split
        && ApolloDuoSplitShouldOpen((id)nav.tabBarController)) {
        ApolloDuoSplitOpen(state);
    }
    if (state.split && !state.changing && [state.kind isEqualToString:@"account"]
        && nav == state.secondary && !state.selectingAccountShortcut) {
        // Content links are pushes, not menu replacements. Commit the stack
        // and full-height geometry together before fading in the destination.
        ApolloDuoAccountSetPages(state, [state.secondary.viewControllers arrayByAddingObject:page]);
        return YES;
    }
    if (!state.split || state.changing || (nav != state.primary && nav != state.outer && !state.selectingAccountShortcut)) return NO;
    state.needsDefault = NO;
    if ([state.kind isEqualToString:@"account"]) {
        ApolloDuoAccountSetPages(state, @[state.root, page]);
    } else [state.secondary setViewControllers:@[page] animated:NO];
    if ([state.kind isEqualToString:@"subreddits"]) {
        // A sidebar selection no longer pushes the list off screen, so its
        // usual viewWillAppear deselection never runs. End the tap feedback
        // after UIKit finishes selecting the row; otherwise Home/subreddits
        // retain a solid highlight until the list disappears or is reused.
        __weak UIViewController *weakRoot = state.root;
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *root = weakRoot;
            if (!root || root.isEditing) return;
            UITableView *table = ApolloDuoSplitFindTable(root.viewIfLoaded);
            for (NSIndexPath *path in table.indexPathsForSelectedRows) {
                [table deselectRowAtIndexPath:path animated:YES];
            }
        });
    }
    // The detail column is already present. showColumn:Secondary is not a
    // harmless reveal while an offscreen tab is adapting: UIKit changes its
    // preferredDisplayMode to SecondaryOnly, so Account/Inbox lose their
    // sidebar when the tab next appears. Keep the user's display mode intact.
    ApolloLog(@"[DuoSplit] %@ selection replaced detail with %@", state.kind, NSStringFromClass(page.class));
    return YES;
}

static void ApolloDuoSplitRememberSettings(UINavigationController *nav) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, YES);
    if (state.changing || ![state.kind isEqualToString:@"settings"]) return;
    NSArray *stack = nav.viewControllers;
    if (!state.split && stack.count > 1) state.lastSettings = [stack subarrayWithRange:NSMakeRange(1, stack.count - 1)];
    else if (nav == state.secondary && stack.count) state.lastSettings = [stack copy];
}

@interface ApolloDuoSplitNavigation : UINavigationController @end
%group ApolloDuoSplitNavigationHooks
%hook ApolloDuoSplitNavigation
- (void)setNavigationBarHidden:(BOOL)hidden animated:(BOOL)animated {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(self, NO);
    if (state.feed && !state.changing && self == state.primary) hidden = YES;
    if (state.split && !state.changing && self == state.secondary &&
        [state.kind isEqualToString:@"account"] && state.secondary.topViewController == state.root) {
        hidden = YES;
    }
    %orig(hidden, animated);
}
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gesture {
    UINavigationController *nav = (id)self;
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(self, NO);
    if (!state.split || state.changing) return %orig(gesture);
    Ivar leftIvar = class_getInstanceVariable(nav.class, "leftScreenEdgePanGestureRecognizer");
    Ivar rightIvar = class_getInstanceVariable(nav.class, "rightScreenEdgePanGestureRecognizer");
    BOOL back = leftIvar && object_getIvar(self, leftIvar) == gesture;
    BOOL forward = rightIvar && object_getIvar(self, rightIvar) == gesture;
    if (!back && !forward) return %orig(gesture);
    // The outer controller now contains a host, not a browsable page. Its
    // recognizers must not compete with the detail controller's native pans.
    if ((self != state.secondary && !(self == state.feed && !ApolloDuoPostsUsesSplit(state))) || (back && nav.viewControllers.count < 2) ||
        (forward && !ApolloDuoSplitForwardPage(self))) return NO;
    UIView *view = nav.view;
    CGRect pane = UIEdgeInsetsInsetRect(view.bounds, view.safeAreaInsets);
    CGPoint point = [gesture locationInView:view];
    if (!CGRectContainsPoint(pane, point)) return NO;
    sDuoSplitGesture = (__bridge void *)gesture;
    sDuoSplitGestureView = (__bridge void *)view;
    sDuoSplitGestureOffset = back ? -view.safeAreaInsets.left : view.safeAreaInsets.right;
    BOOL result = %orig(gesture);
    sDuoSplitGesture = NULL;
    sDuoSplitGestureView = NULL;
    sDuoSplitGestureOffset = 0.0;
    return result;
}
- (void)pushViewController:(UIViewController *)controller animated:(BOOL)animated {
    if (ApolloDuoSplitRoutePush(self, controller)) return;
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(self, NO);
    if (state.split && (self == state.primary || self == state.secondary || self == state.feed)) {
        controller.extendedLayoutIncludesOpaqueBars = YES;
    }
    if (state.split && [state.kind isEqualToString:@"account"] && self == state.secondary) {
        [state.secondary setNavigationBarHidden:NO animated:NO];
    }
    %orig(controller, state.changing ? NO : animated);
    [state.host.viewIfLoaded setNeedsLayout];
    ApolloDuoSplitRememberSettings(self);
}
- (void)setViewControllers:(NSArray<UIViewController *> *)controllers animated:(BOOL)animated {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(self, NO);
    if (state.split && (self == state.primary || self == state.secondary || self == state.feed)) {
        // New detail pages default to NO even when existing Apollo pages use
        // YES. Prepare them before UIKit installs the stack, so an opaque
        // theme cannot deduct the vertical tab rail's height from their view.
        // Safe areas already describe the sidebar, navigation bar, and rail.
        for (UIViewController *controller in controllers) {
            controller.extendedLayoutIncludesOpaqueBars = YES;
        }
    }
    %orig(controllers, animated);
    [state.host.viewIfLoaded setNeedsLayout];
}
- (UIViewController *)popViewControllerAnimated:(BOOL)animated {
    ApolloDuoSplitRememberSettings(self);
    UINavigationController *detail = ApolloDuoSplitDetailNavigation(self);
    if (detail != self) return [detail popViewControllerAnimated:animated];
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(self, NO);
    if (state.feed && !state.changing && self == state.secondary && state.secondary.viewControllers.count == 2) {
        UIViewController *page = state.secondary.topViewController;
        ApolloDuoPostsSetDetail(state, nil, animated);
        return page;
    }
    if (state.split && !state.changing && [state.kind isEqualToString:@"account"]
        && self == state.secondary && detail.viewControllers.count > 1
        && detail.interactivePopGestureRecognizer.state != UIGestureRecognizerStateBegan
        && detail.interactivePopGestureRecognizer.state != UIGestureRecognizerStateChanged) {
        UIViewController *page = detail.topViewController;
        ApolloDuoAccountSetPages(state, [detail.viewControllers subarrayWithRange:NSMakeRange(0, detail.viewControllers.count - 1)]);
        return page;
    }
    UIViewController *page = %orig(animated);
    [state.host.viewIfLoaded setNeedsLayout];
    ApolloDuoSplitScheduleUpdate();
    return page;
}
- (NSArray *)popToRootViewControllerAnimated:(BOOL)animated {
    ApolloDuoSplitRememberSettings(self);
    UINavigationController *detail = ApolloDuoSplitDetailNavigation(self);
    if (detail != self) return [detail popToRootViewControllerAnimated:animated];
    NSArray *pages = %orig(animated);
    ApolloDuoSplitScheduleUpdate();
    return pages;
}
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    ApolloDuoSplitScheduleUpdate();
}
%end
%end

%hook UITabBarController
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    if (self != (id)ApolloMainTabBarController() ||
        (self != sDuoSplitKnownTabs && !ApolloDuoRailHasVisibleSideBar() && ApolloDuoCurrentMode() == ApolloDuoModePhone)) {
        %orig(size, coordinator);
        return;
    }
    UINavigationController *selectedNavigation = (id)self.selectedViewController;
    UINavigationController *detailNavigation = [selectedNavigation isKindOfClass:UINavigationController.class]
        ? ApolloDuoSplitDetailNavigation(selectedNavigation) : nil;
    UIViewController *selectedPage = detailNavigation.topViewController;
    BOOL profileSection = NO;
    for (UIViewController *page in detailNavigation.viewControllers) {
        if ([ApolloDuoSplitKind(page) isEqualToString:@"account"] && page != selectedPage) profileSection = YES;
    }
    UITableView *sectionTable = profileSection ? ApolloDuoSplitFindTable(selectedPage.viewIfLoaded) : nil;
    NSIndexPath *anchor = sectionTable.indexPathsForVisibleRows.firstObject;
    CGFloat anchorOffset = anchor ? CGRectGetMinY([sectionTable rectForRowAtIndexPath:anchor])
        - sectionTable.contentOffset.y - sectionTable.adjustedContentInset.top : 0;
    __weak UITableView *weakSectionTable = sectionTable;
    void (^restoreSectionPosition)(void) = ^{
        UITableView *table = weakSectionTable;
        if (!anchor || !table.window || table.dragging || table.decelerating
            || anchor.section >= table.numberOfSections
            || anchor.row >= [table numberOfRowsInSection:anchor.section]) return;
        CGFloat y = CGRectGetMinY([table rectForRowAtIndexPath:anchor])
            - anchorOffset - table.adjustedContentInset.top;
        CGFloat minimum = -table.adjustedContentInset.top;
        CGFloat maximum = MAX(minimum, table.contentSize.height - table.bounds.size.height + table.adjustedContentInset.bottom);
        [table setContentOffset:CGPointMake(table.contentOffset.x, MIN(maximum, MAX(minimum, y))) animated:NO];
    };
    // Install/remove column containers before UIKit forwards the new size to
    // children. Waiting for viewDidLayoutSubviews exposed one full-width frame
    // and the old transition guard then delayed splitting until animation end.
    sDuoSplitResizingTabs = self;
    sDuoSplitTargetSize = size;
    sDuoSplitSizeCoordinator = coordinator;
    ApolloLog(@"[DuoSplit] preparing all tabs for %.0fx%.0f", size.width, size.height);
    [UIView performWithoutAnimation:^{ ApolloDuoSplitUpdate(); }];
    %orig(size, coordinator);
    [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        ApolloDuoSplitUpdate();
        // Texture enqueues row-height updates when the table's width changes.
        // Commit that existing measurement during UIKit's size animation, so
        // the old wrapping does not remain until a second row animation runs.
        [self.view layoutIfNeeded];
        UINavigationController *selected = (id)self.selectedViewController;
        if ([selected isKindOfClass:UINavigationController.class]) {
            UIViewController *page = ApolloDuoSplitDetailNavigation(selected).topViewController;
            UITableView *table = page.isViewLoaded ? ApolloDuoSplitFindTable(page.view) : nil;
            SEL commit = NSSelectorFromString(@"waitUntilAllUpdatesAreCommitted");
            if ([table respondsToSelector:commit]) {
                ((void (*)(id, SEL))objc_msgSend)(table, commit);
                [table layoutIfNeeded];
            }
        }
        restoreSectionPosition();
    } completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        if (sDuoSplitSizeCoordinator != coordinator) return;
        restoreSectionPosition();
        sDuoSplitResizingTabs = nil;
        sDuoSplitSizeCoordinator = nil;
        ApolloDuoSplitScheduleUpdate();
    }];
}
- (void)viewDidLayoutSubviews {
    %orig;
    if (self == (id)ApolloMainTabBarController()) ApolloDuoSplitScheduleUpdate();
}
- (void)setSelectedViewController:(UIViewController *)controller {
    BOOL mainTabs = self == (id)ApolloMainTabBarController();
    if (mainTabs) ApolloDuoSplitUpdate();
    %orig(controller);
    if (mainTabs) ApolloDuoSplitScheduleUpdate();
}
- (void)setSelectedIndex:(NSUInteger)index {
    BOOL mainTabs = self == (id)ApolloMainTabBarController();
    if (mainTabs) ApolloDuoSplitUpdate();
    %orig(index);
    if (mainTabs) ApolloDuoSplitScheduleUpdate();
}
%end

%hook UIPanGestureRecognizer
- (CGPoint)locationInView:(UIView *)view {
    CGPoint point = %orig(view);
    if ((__bridge void *)self == sDuoSplitGesture && (__bridge void *)view == sDuoSplitGestureView) {
        point.x += sDuoSplitGestureOffset;
    }
    return point;
}
%end

// Apollo manually centers its EmptyStateLabel in ASTableView's full bounds.
// In a modern split those bounds extend behind the primary column. Adjust the
// native geometry at its setter, and on safe-area changes (including hinge-only
// changes with no window resize). Keep native vertical placement and sizing.
static char kDuoEmptyStateAdjusted;
static CGFloat ApolloDuoEmptyStateCenterX(UILabel *label, CGFloat nativeX) {
    UIView *parent = label.superview;
    if (!parent) return nativeX;
    UIViewController *owner = nil;
    for (UIResponder *responder = parent; responder; responder = responder.nextResponder) {
        if ([responder isKindOfClass:UIViewController.class]) {
            owner = (id)responder;
            break;
        }
    }
    CGRect pane = ApolloDuoSplitContentFrame(owner, parent);
    if (!CGRectIsNull(pane) && CGRectGetWidth(pane) > 0.0) {
        objc_setAssociatedObject(label, &kDuoEmptyStateAdjusted, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return CGRectGetMidX(pane);
    }
    if ([objc_getAssociatedObject(label, &kDuoEmptyStateAdjusted) boolValue]) {
        objc_setAssociatedObject(label, &kDuoEmptyStateAdjusted, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return CGRectGetMidX(parent.bounds);
    }
    return nativeX;
}

@interface ApolloDuoEmptyStateLabel : UILabel @end
@interface ApolloDuoEmptyStateTable : UITableView @end
%group ApolloDuoEmptyStateHooks
%hook ApolloDuoEmptyStateLabel
- (void)setCenter:(CGPoint)center {
    center.x = ApolloDuoEmptyStateCenterX(self, center.x);
    %orig(center);
}
- (void)setFrame:(CGRect)frame {
    frame.origin.x = ApolloDuoEmptyStateCenterX(self, CGRectGetMidX(frame)) - frame.size.width / 2.0;
    %orig(frame);
}
- (void)safeAreaInsetsDidChange {
    %orig;
    CGPoint center = [(UILabel *)self center];
    CGFloat x = ApolloDuoEmptyStateCenterX(self, center.x);
    if (fabs(center.x - x) > 0.1) [(UILabel *)self setCenter:CGPointMake(x, center.y)];
}
- (void)didMoveToWindow {
    %orig;
    CGPoint center = [(UILabel *)self center];
    CGFloat x = ApolloDuoEmptyStateCenterX(self, center.x);
    if (fabs(center.x - x) > 0.1) [(UILabel *)self setCenter:CGPointMake(x, center.y)];
}
%end
%hook ApolloDuoEmptyStateTable
- (void)safeAreaInsetsDidChange {
    %orig;
    // A label already inside the old safe area does not necessarily receive
    // its own notification when only the sidebar width changes. The table
    // does; refresh the existing label without waiting for another selection.
    Class emptyLabel = NSClassFromString(@"Apollo.EmptyStateLabel");
    for (UIView *view in [(UITableView *)self subviews]) {
        if (![view isKindOfClass:emptyLabel]) continue;
        CGPoint center = view.center;
        CGFloat x = ApolloDuoEmptyStateCenterX((id)view, center.x);
        if (fabs(center.x - x) > 0.1) view.center = CGPointMake(x, center.y);
    }
}
%end
%end

@interface ApolloDuoTabSceneDelegate : NSObject @end
%group ApolloDuoTabSelectionHooks
%hook ApolloDuoTabSceneDelegate
- (BOOL)tabBarController:(UITabBarController *)tabs
 shouldSelectViewController:(UIViewController *)page {
    BOOL allowed = %orig(tabs, page);
    if (!allowed || tabs != (id)ApolloMainTabBarController()
        || ApolloDuoSplitIsUnfolded() || !ApolloDuoCoverChromeIsActive()
        || ![page isKindOfClass:UINavigationController.class]) return allowed;
    UINavigationController *nav = (id)page;
    NSString *kind = ApolloDuoSplitKind(nav.viewControllers.firstObject);
    if (([kind isEqualToString:@"account"] || [kind isEqualToString:@"settings"]
         || [kind isEqualToString:@"inbox"])
        && nav.viewControllers.count > 1 && !nav.transitionCoordinator
        && !tabs.presentedViewController && !nav.presentedViewController) {
        // Only a tab tap returns to the overview. Programmatic selection
        // (including deep links) keeps its requested destination.
        [nav popToRootViewControllerAnimated:NO];
    }
    return allowed;
}
%end
%end

// Friends uses manually positioned tables and a toolbar, rather than a native
// table-controller header. Its original layout assumes the whole window width.
%hook _TtC6Apollo21FriendsViewController
- (void)viewDidLayoutSubviews {
    %orig;
    UIViewController *controller = (id)self;
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(controller.navigationController, NO);
    if (!state.split || controller.navigationController != state.secondary) return;
    UIView *view = controller.view;
    CGRect pane = UIEdgeInsetsInsetRect(view.bounds, view.safeAreaInsets);
    if (pane.size.width <= 0 || pane.size.height <= 44) return;
    Ivar toolbarIvar = class_getInstanceVariable([controller class], "segmentedControlToolbar");
    UIToolbar *toolbar = toolbarIvar ? object_getIvar(self, toolbarIvar) : nil;
    CGRect toolbarFrame = CGRectMake(pane.origin.x, pane.origin.y, pane.size.width, 44);
    if (toolbar && !CGRectEqualToRect(toolbar.frame, toolbarFrame)) toolbar.frame = toolbarFrame;
    Ivar segmentIvar = class_getInstanceVariable([controller class], "typeSegmentedControl");
    UISegmentedControl *segments = segmentIvar ? object_getIvar(self, segmentIvar) : nil;
    if (segments) {
        CGRect frame = segments.frame;
        frame.size.width = MAX(0, pane.size.width - 32);
        if (!CGRectEqualToRect(segments.frame, frame)) segments.frame = frame;
    }

}
- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    UIViewController *controller = (id)self;
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(controller.navigationController, NO);
    if (!state.split || controller.navigationController != state.secondary) return;
    Ivar toolbarIvar = class_getInstanceVariable(controller.class, "segmentedControlToolbar");
    UIView *toolbar = toolbarIvar ? object_getIvar(self, toolbarIvar) : nil;
    CGFloat top = CGRectGetMaxY(toolbar.frame) + 8;
    for (UIView *child in controller.view.subviews) {
        if (![child isKindOfClass:UITableView.class]) continue;
        UITableView *table = (id)child;
        UIEdgeInsets inset = table.contentInset;
        inset.top = MAX(0, top - (table.adjustedContentInset.top - inset.top));
        table.contentInset = inset;
        [table setContentOffset:CGPointMake(0, -table.adjustedContentInset.top) animated:NO];
    }
}

%end

%ctor {
    Class sceneDelegate = NSClassFromString(@"Apollo.SceneDelegate");
    if (sceneDelegate) %init(ApolloDuoTabSelectionHooks, ApolloDuoTabSceneDelegate = sceneDelegate);
    Class navigation = NSClassFromString(@"Apollo.ApolloNavigationController");
    if (navigation) %init(ApolloDuoSplitNavigationHooks, ApolloDuoSplitNavigation = navigation);
    Class emptyLabel = NSClassFromString(@"Apollo.EmptyStateLabel");
    if (emptyLabel) %init(ApolloDuoEmptyStateHooks, ApolloDuoEmptyStateLabel = emptyLabel,
                         ApolloDuoEmptyStateTable = NSClassFromString(@"ASTableView"));
    %init;
}
