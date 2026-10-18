// Regular phones borrow the actual native Subreddits controller while the
// compact panel is visible. The Posts tab keeps its original navigation
// controller, and regains the list before any destination is installed.
#import "ApolloCompactSubredditPanel.h"
#import "ApolloState.h"
#import "ApolloCommon.h"
#import "ApolloClasses.h"
#import "ApolloNavigationActions.h"
#import "ApolloThemeRuntime.h"
#import "ApolloNavigationTitlePresentation.h"
#import <objc/runtime.h>

@class ApolloCompactSubredditPanel;
static char kCompactPanelOwner, kCompactPanelOuter, kCompactPanelRetiredNavigation, kCompactPanelBackSwipe, kCompactPanelFeedHistory;
static NSUInteger sCompactPanelAccountGeneration;
static NSUInteger sCompactPanelActiveSurfaceOwners;
static NSHashTable<UINavigationController *> *sCompactPanelNavigations;

@interface ApolloCompactPanelFeedHistory : NSObject
@property(nonatomic, weak) UIViewController *list;
@property(nonatomic, strong) UIViewController *feed;
@property(nonatomic) NSUInteger accountGeneration;
@property(nonatomic) BOOL returningToList;
@property(nonatomic) BOOL updatingStack;
@property(nonatomic) BOOL pendingReveal;
@end
@implementation ApolloCompactPanelFeedHistory @end

// The popup temporarily owns Apollo's actual Add and Edit/Done items. Keep
// their native target/action and editing lifecycle; do not create alternate
// controls or leave the same items attached to a second hidden bar.
static char kCompactPanelListBar, kCompactPanelSavedLeftItems, kCompactPanelSavedRightItems;

static BOOL CompactPanelIsSubredditList(UIViewController *controller) {
    return ApolloClassRedditListViewController
        && [controller isKindOfClass:ApolloClassRedditListViewController];
}

static UIBarButtonItem *CompactPanelAddItem(UIViewController *controller) {
    Ivar ivar = class_getInstanceVariable(controller.class, "addBarButtonItem");
    if (!ivar) ivar = class_getInstanceVariable(controller.class, "_addBarButtonItem");
    id value = ivar ? object_getIvar(controller, ivar) : nil;
    return [value isKindOfClass:UIBarButtonItem.class] ? value : nil;
}

static void CompactPanelRefreshNavigationItems(UIViewController *controller) {
    UINavigationBar *bar = objc_getAssociatedObject(controller, &kCompactPanelListBar);
    if (!bar) return;
    UIBarButtonItem *add = CompactPanelAddItem(controller);
    UIBarButtonItem *edit = controller.editButtonItem;
    ApolloNavigationActionsSetNativeEditingAccent(edit, IsLiquidGlass() && controller.isEditing);
    UINavigationItem *nativeItem = controller.navigationItem;
    if (nativeItem.leftBarButtonItems.count) nativeItem.leftBarButtonItems = nil;
    if (nativeItem.rightBarButtonItems.count) nativeItem.rightBarButtonItems = nil;
    UINavigationItem *popupItem = bar.topItem;
    NSArray *left = add ? @[add] : @[];
    NSArray *right = edit ? @[edit] : @[];
    if (![popupItem.leftBarButtonItems ?: @[] isEqualToArray:left]) popupItem.leftBarButtonItems = left;
    if (![popupItem.rightBarButtonItems ?: @[] isEqualToArray:right]) popupItem.rightBarButtonItems = right;
}

static void CompactPanelSetNavigationBar(UIViewController *controller, UINavigationBar *bar) {
    UINavigationBar *previous = objc_getAssociatedObject(controller, &kCompactPanelListBar);
    if (bar == previous) return;
    if (previous) {
        // Release the standalone owner's items before putting the controller
        // back in the Posts tab's native navigation stack.
        ApolloNavigationActionsSetNativeEditingAccent(controller.editButtonItem, NO);
        previous.topItem.leftBarButtonItems = nil;
        previous.topItem.rightBarButtonItems = nil;
        [previous setItems:@[] animated:NO];
        controller.navigationItem.leftBarButtonItems = objc_getAssociatedObject(controller, &kCompactPanelSavedLeftItems);
        controller.navigationItem.rightBarButtonItems = objc_getAssociatedObject(controller, &kCompactPanelSavedRightItems);
        objc_setAssociatedObject(controller, &kCompactPanelSavedLeftItems, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(controller, &kCompactPanelSavedRightItems, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    objc_setAssociatedObject(controller, &kCompactPanelListBar, bar, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!bar) return;
    objc_setAssociatedObject(controller, &kCompactPanelSavedLeftItems,
                             controller.navigationItem.leftBarButtonItems ?: @[], OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(controller, &kCompactPanelSavedRightItems,
                             controller.navigationItem.rightBarButtonItems ?: @[], OBJC_ASSOCIATION_COPY_NONATOMIC);
    UINavigationItem *item = [[UINavigationItem alloc] initWithTitle:@""];
    item.hidesBackButton = YES;
    [bar setItems:@[item] animated:NO];
    CompactPanelRefreshNavigationItems(controller);
}

static BOOL CompactPanelIsFeed(UIViewController *controller) {
    return [NSStringFromClass(controller.class) isEqualToString:@"Apollo.PostsViewController"];
}

static ApolloCompactPanelFeedHistory *CompactPanelHistory(UINavigationController *navigation, BOOL create) {
    ApolloCompactPanelFeedHistory *history = objc_getAssociatedObject(navigation, &kCompactPanelFeedHistory);
    if (!history && create) {
        history = [ApolloCompactPanelFeedHistory new];
        objc_setAssociatedObject(navigation, &kCompactPanelFeedHistory, history, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!sCompactPanelNavigations) sCompactPanelNavigations = [NSHashTable weakObjectsHashTable];
        [sCompactPanelNavigations addObject:navigation];
    }
    return history;
}

static void CompactPanelRememberFeed(UINavigationController *navigation) {
    if (UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPhone
        || objc_getAssociatedObject(navigation, &kCompactPanelOuter)) return;
    NSArray *stack = navigation.viewControllers;
    if (stack.count < 2 || !CompactPanelIsSubredditList(stack.firstObject)
        || !CompactPanelIsFeed(stack[1])) return;
    ApolloCompactPanelFeedHistory *history = CompactPanelHistory(navigation, YES);
    history.list = stack.firstObject;
    history.feed = stack[1];
    history.accountGeneration = sCompactPanelAccountGeneration;
}

static void CompactPanelPrepareRetainedFeed(UINavigationController *navigation) {
    if (!sCompactSubredditListEnabled
        || UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPhone
        || objc_getAssociatedObject(navigation, &kCompactPanelOuter)) return;
    ApolloCompactPanelFeedHistory *history = CompactPanelHistory(navigation, NO);
    if (!history.feed || history.accountGeneration != sCompactPanelAccountGeneration
        || navigation.viewControllers.count != 1 || navigation.topViewController != history.list
        || history.feed.parentViewController || navigation.transitionCoordinator
        || navigation.presentedViewController || navigation.tabBarController.presentedViewController) return;
    // Prepare while the Posts tab is offscreen (or before its appearance).
    // Reuse the real feed and its reading position; never synthesize a Home
    // page or bring a feed across an account/root replacement.
    history.updatingStack = YES;
    history.pendingReveal = YES;
    [navigation setViewControllers:@[history.list, history.feed] animated:NO];
    history.updatingStack = NO;
}

@interface ApolloCompactPanelReference : NSObject
@property(nonatomic, weak) ApolloCompactSubredditPanel *panel;
@end
@implementation ApolloCompactPanelReference @end

@interface ApolloCompactPanelSwipe : NSObject
@property(nonatomic, weak) UIViewController *list;
@property(nonatomic, weak) UIViewController *feed;
@end
@implementation ApolloCompactPanelSwipe @end

@interface ApolloCompactSubredditPanel : UIViewController
@property(nonatomic, weak) UINavigationController *outer;
@property(nonatomic, strong) UIViewController *list;
@property(nonatomic, strong) UIViewController *backSource;
@property(nonatomic, strong) UINavigationController *listNavigation;
@property(nonatomic, strong) UIView *panelView;
@property(nonatomic, strong) UIVisualEffectView *material;
@property(nonatomic, strong) UINavigationBar *bar;
@property(nonatomic, strong) UIControl *dimming;
@property(nonatomic, strong) NSMapTable<UIView *, id> *backgrounds;
@property(nonatomic, strong) NSMapTable<UIScrollView *, NSNumber *> *scrollStates;
@property(nonatomic, strong) NSMapTable<UIGestureRecognizer *, NSNumber *> *gestureStates;
@property(nonatomic) UIEdgeInsets listInsets;
@property(nonatomic) BOOL usesGlass;
@property(nonatomic) BOOL updatingSurfaces;
@property(nonatomic) BOOL registeredSurfaceOwner;
@property(nonatomic) BOOL changingNavigation;
@property(nonatomic) BOOL performingOuterUpdate;
@property(nonatomic) BOOL closing;
@property(nonatomic) BOOL revealed;
@property(nonatomic) NSUInteger dismissalGeneration;
- (void)closeWithPage:(UIViewController *)page animated:(BOOL)animated;
- (void)cancelForNavigationChange;
- (void)restoreList;
- (void)unregisterSurfaceOwner;
- (void)updateAppearance;
@end

static ApolloCompactSubredditPanel *CompactPanelForObject(id object) {
    return ((ApolloCompactPanelReference *)objc_getAssociatedObject(object, &kCompactPanelOwner)).panel;
}

BOOL ApolloCompactSubredditPanelOwnsNavigation(UINavigationController *navigation) {
    ApolloCompactSubredditPanel *panel = CompactPanelForObject(navigation);
    return panel && !panel.changingNavigation;
}

BOOL ApolloCompactSubredditPanelIsUpdatingNavigation(UINavigationController *navigation) {
    ApolloCompactSubredditPanel *panel = objc_getAssociatedObject(navigation, &kCompactPanelOuter);
    return panel.performingOuterUpdate;
}

static ApolloCompactSubredditPanel *CompactPanelForView(UIView *view) {
    for (UIResponder *responder = view; responder; responder = responder.nextResponder) {
        ApolloCompactSubredditPanel *panel = CompactPanelForObject(responder);
        if (panel && !panel.changingNavigation) return panel;
    }
    return nil;
}

static BOOL CompactPanelOwnsSurface(UIView *view, ApolloCompactSubredditPanel *panel) {
    if ([view isKindOfClass:UIControl.class] || [view isKindOfClass:UILabel.class]
        || [view isKindOfClass:UIImageView.class] || [view isKindOfClass:UIVisualEffectView.class]) return NO;
    for (UIView *ancestor = view.superview; ancestor && ancestor != panel.listNavigation.view; ancestor = ancestor.superview) {
        if ([ancestor isKindOfClass:UIControl.class] || [ancestor isKindOfClass:UIVisualEffectView.class]) return NO;
    }
    if (view == panel.list.view || view == panel.listNavigation.view
        || [view isKindOfClass:UITableView.class] || [view isKindOfClass:UITableViewCell.class]
        || [view isKindOfClass:UITableViewHeaderFooterView.class]) return YES;
    NSString *name = NSStringFromClass(view.class);
    if ([name containsString:@"TableViewWrapper"] || [name containsString:@"TableViewCellContentView"]
        || [name containsString:@"SectionBackground"] || [name containsString:@"TableViewHeaderFooterContentView"]
        || [name isEqualToString:@"Apollo.RecreatedTableSectionHeaderView"]) return YES;
    if ([view.superview isKindOfClass:UITableView.class]) return ((UITableView *)view.superview).backgroundView == view;
    if ([view.superview isKindOfClass:UITableViewCell.class]) {
        UITableViewCell *cell = (id)view.superview;
        return cell.backgroundView == view || cell.selectedBackgroundView == view;
    }
    return NO;
}

BOOL ApolloCompactSubredditPanelContainsView(UIView *view) { return CompactPanelForView(view) != nil; }
BOOL ApolloCompactSubredditPanelUsesGlass(UIView *view) { return CompactPanelForView(view).usesGlass; }

UIColor *ApolloCompactSubredditPanelBackground(UIView *view, UIColor *color) {
    // This is reached by every UIView color write. The default/no-panel path
    // must not inspect the responder chain at all.
    if (!NSThread.isMainThread || sCompactPanelActiveSurfaceOwners == 0) return color;
    ApolloCompactSubredditPanel *panel = CompactPanelForView(view);
    if (!panel.usesGlass || panel.updatingSurfaces || !CompactPanelOwnsSurface(view, panel)) return color;
    [panel.backgrounds setObject:color ?: (id)NSNull.null forKey:view];
    return UIColor.clearColor;
}

void ApolloCompactSubredditPanelPrepareSurface(UIView *surface) {
    ApolloCompactSubredditPanel *panel = CompactPanelForView(surface);
    if (!panel.usesGlass || panel.updatingSurfaces) return;
    panel.updatingSurfaces = YES;
    NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:surface];
    for (NSUInteger i = 0; i < pending.count; i++) {
        UIView *view = pending[i];
        if ([view isKindOfClass:UIControl.class] || [view isKindOfClass:UIVisualEffectView.class]) continue;
        [pending addObjectsFromArray:view.subviews];
        if (!CompactPanelOwnsSurface(view, panel)) continue;
        if (![panel.backgrounds objectForKey:view])
            [panel.backgrounds setObject:view.backgroundColor ?: (id)NSNull.null forKey:view];
        view.backgroundColor = UIColor.clearColor;
    }
    panel.updatingSurfaces = NO;
}

@implementation ApolloCompactSubredditPanel
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    self.view.accessibilityViewIsModal = YES;
    self.backgrounds = [NSMapTable weakToStrongObjectsMapTable];
    self.dimming = [UIControl new];
    self.dimming.backgroundColor = [UIColor colorWithWhite:0 alpha:0.16];
    [self.dimming addTarget:self action:@selector(dismissPanel) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.dimming];
    self.panelView = [UIView new];
    self.panelView.layer.cornerRadius = 28;
    self.panelView.clipsToBounds = YES;
    [self.view addSubview:self.panelView];
    self.material = [[UIVisualEffectView alloc] initWithEffect:nil];
    self.material.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.panelView addSubview:self.material];
    self.bar = [UINavigationBar new];
    self.bar.translatesAutoresizingMaskIntoConstraints = NO;
    UINavigationBarAppearance *appearance = [UINavigationBarAppearance new];
    [appearance configureWithTransparentBackground];
    self.bar.standardAppearance = appearance;
    self.bar.scrollEdgeAppearance = appearance;
    self.bar.compactAppearance = appearance;
    [self.bar setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];
    [self.material.contentView addSubview:self.bar];
    [self addChildViewController:self.listNavigation];
    UIView *content = self.listNavigation.view;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [self.material.contentView addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [self.bar.topAnchor constraintEqualToAnchor:self.material.contentView.topAnchor constant:12],
        [self.bar.leadingAnchor constraintEqualToAnchor:self.material.contentView.leadingAnchor constant:12],
        [self.bar.trailingAnchor constraintEqualToAnchor:self.material.contentView.trailingAnchor constant:-20],
        [content.topAnchor constraintEqualToAnchor:self.bar.bottomAnchor constant:8],
        [content.leadingAnchor constraintEqualToAnchor:self.material.contentView.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:self.material.contentView.trailingAnchor],
        [content.bottomAnchor constraintEqualToAnchor:self.material.contentView.bottomAnchor]
    ]];
    [self.listNavigation didMoveToParentViewController:self];
    CompactPanelSetNavigationBar(self.list, self.bar);
    [self updateAppearance];
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self selector:@selector(settingsChanged:) name:@"ApolloCompactSubredditListDidChange" object:nil];
    [center addObserver:self selector:@selector(settingsChanged:) name:@"ApolloSubredditPanelStyleDidChange" object:nil];
    [center addObserver:self selector:@selector(settingsChanged:) name:@"com.christianselig.ApolloSpecificThemeChanged" object:nil];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.dimming.frame = self.view.bounds;
    CGRect available = UIEdgeInsetsInsetRect(self.view.bounds, self.view.safeAreaInsets);
    CGFloat width = MIN(300, MIN(available.size.width * 0.72, MAX(0, available.size.width - 48)));
    CGFloat top = MAX(CGRectGetMinY(self.view.bounds) + 8, CGRectGetMinY(available) - 8);
    CGFloat bottom = MIN(CGRectGetMaxY(self.view.bounds) - 8, CGRectGetMaxY(available) + 8);
    CGRect frame = CGRectMake(CGRectGetMinX(available) + 12, top, width, MAX(0, bottom - top));
    // Bounds/center keep the entrance transform separate from layout.
    self.panelView.bounds = CGRectMake(0, 0, frame.size.width, frame.size.height);
    self.panelView.center = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
    self.material.frame = self.panelView.bounds;
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (!self.revealed) {
        [self.view layoutIfNeeded];
        self.panelView.transform = CGAffineTransformMakeTranslation(-self.panelView.bounds.size.width - 24, 0);
        self.dimming.alpha = 0;
    }
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.revealed || self.closing) return;
    self.revealed = YES;
    [self.view layoutIfNeeded];
    [UIView animateWithDuration:UIAccessibilityIsReduceMotionEnabled() ? 0 : 0.28
                          delay:0 options:UIViewAnimationOptionCurveEaseInOut
                     animations:^{ self.panelView.transform = CGAffineTransformIdentity; self.dimming.alpha = 1; }
                     completion:nil];
}
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (self.isViewLoaded && [self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection])
        [self updateAppearance];
}
- (void)settingsChanged:(NSNotification *)notification {
    if (!sCompactSubredditListEnabled) [self closeWithPage:nil animated:YES];
    else [self updateAppearance];
}
- (void)restoreSurfaceColors {
    self.updatingSurfaces = YES;
    for (UIView *view in self.backgrounds) {
        id value = [self.backgrounds objectForKey:view];
        view.backgroundColor = value == NSNull.null ? nil : value;
    }
    [self.backgrounds removeAllObjects];
    self.updatingSurfaces = NO;
}
- (void)updateAppearance {
    if (self.closing) return;
    [self restoreSurfaceColors];
    self.usesGlass = sSubredditPanelGlassEnabled;
    UIVisualEffect *effect = nil;
    if (self.usesGlass) {
        if (@available(iOS 26.0, *)) effect = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
        else effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial];
    }
    self.material.effect = effect;
    self.material.backgroundColor = self.usesGlass ? UIColor.clearColor
        : (ApolloThemeSubredditListBackgroundColor() ?: UIColor.systemBackgroundColor);
    self.bar.tintColor = ApolloNavigationChromeColor();
    CompactPanelRefreshNavigationItems(self.list);
    self.bar.topItem.title = @"";
    ApolloCompactSubredditPanelPrepareSurface(self.listNavigation.view);
}
- (void)dismissPanel { [self closeWithPage:nil animated:YES]; }
- (BOOL)accessibilityPerformEscape { [self dismissPanel]; return YES; }
- (void)unregisterSurfaceOwner {
    if (!self.registeredSurfaceOwner) return;
    self.registeredSurfaceOwner = NO;
    if (sCompactPanelActiveSurfaceOwners > 0) --sCompactPanelActiveSurfaceOwners;
}
- (void)restoreList {
    if (self.changingNavigation) return;
    self.changingNavigation = YES;
    if (self.list.isEditing) [self.list setEditing:NO animated:NO];
    CompactPanelSetNavigationBar(self.list, nil);
    [self restoreSurfaceColors];
    self.list.additionalSafeAreaInsets = self.listInsets;
    objc_setAssociatedObject(self.listNavigation, &kCompactPanelRetiredNavigation, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self.listNavigation setViewControllers:@[] animated:NO];
    objc_setAssociatedObject(self.list, &kCompactPanelOwner, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self.listNavigation, &kCompactPanelOwner, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self unregisterSurfaceOwner];
    UINavigationController *outer = self.outer;
    NSArray *stack = outer.viewControllers;
    NSUInteger backIndex = [stack indexOfObjectIdenticalTo:self.backSource];
    if (outer && backIndex != NSNotFound) {
        NSMutableArray *restored = [stack mutableCopy];
        restored[backIndex] = self.list;
        self.performingOuterUpdate = YES;
        [UIView performWithoutAnimation:^{
            [outer setViewControllers:restored animated:NO];
            [outer.navigationBar layoutIfNeeded];
            ApolloNavigationTitlePresentationSynchronize(outer.navigationBar);
        }];
        self.performingOuterUpdate = NO;
    }
    for (UIScrollView *scroll in self.scrollStates) scroll.scrollEnabled = [self.scrollStates objectForKey:scroll].boolValue;
    for (UIGestureRecognizer *gesture in self.gestureStates) gesture.enabled = [self.gestureStates objectForKey:gesture].boolValue;
    [self.scrollStates removeAllObjects];
    [self.gestureStates removeAllObjects];
}
- (void)cancelForNavigationChange {
    // Invalidate both the slide completion and UIKit's dismissal completion
    // before releasing the borrowed controller. A newer account/URL stack
    // always wins over a destination selected in the outgoing panel.
    ++self.dismissalGeneration;
    self.closing = YES;
    [self.panelView.layer removeAllAnimations];
    [self.dimming.layer removeAllAnimations];
    [self restoreList];
    objc_setAssociatedObject(self.outer, &kCompactPanelOuter, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (self.presentingViewController && !self.isBeingDismissed)
        [self dismissViewControllerAnimated:NO completion:nil];
}
- (void)closeWithPage:(UIViewController *)page animated:(BOOL)animated {
    if (self.closing) return;
    self.closing = YES;
    NSUInteger generation = ++self.dismissalGeneration;
    void (^finish)(void) = ^{
        if (self.dismissalGeneration != generation) return;
        UINavigationController *outer = self.outer;
        [self restoreList];
        [self dismissViewControllerAnimated:NO completion:^{
            if (self.dismissalGeneration != generation) return;
            // Keep the outer association until this point: another native
            // stack replacement can arrive after restoration but before this
            // callback and must still be able to cancel the queued page.
            objc_setAssociatedObject(outer, &kCompactPanelOuter, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (page && outer) {
                BOOL feed = [NSStringFromClass(page.class) isEqualToString:@"Apollo.PostsViewController"];
                if (feed) [outer setViewControllers:@[self.list, page] animated:animated];
                else [outer pushViewController:page animated:animated];
                [UIView performWithoutAnimation:^{
                    [outer.navigationBar layoutIfNeeded];
                    ApolloNavigationTitlePresentationSynchronize(outer.navigationBar);
                }];
            }
        }];
    };
    if (!animated || UIAccessibilityIsReduceMotionEnabled()) { finish(); return; }
    [UIView animateWithDuration:0.24 delay:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseInOut
                     animations:^{
        self.panelView.transform = CGAffineTransformMakeTranslation(-self.panelView.bounds.size.width - 24, 0);
        self.dimming.alpha = 0;
    } completion:^(__unused BOOL finished) { finish(); }];
}
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    // A tab/account replacement can dismiss the panel without its button.
    if ((self.isBeingDismissed || !self.presentingViewController) && !self.closing)
        [self cancelForNavigationChange];
}
- (void)dealloc {
    [self unregisterSurfaceOwner];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}
@end

static BOOL CompactPanelInteractiveNavigation(UINavigationController *navigation) {
    if (navigation.transitionCoordinator.isInteractive) return YES;
    for (UIGestureRecognizer *gesture in navigation.view.gestureRecognizers) {
        if ([gesture isKindOfClass:UIScreenEdgePanGestureRecognizer.class]
            && (gesture.state == UIGestureRecognizerStateBegan || gesture.state == UIGestureRecognizerStateChanged)) return YES;
    }
    return NO;
}

static BOOL CompactPanelCanReveal(UINavigationController *navigation) {
    if (!NSThread.isMainThread || !sCompactSubredditListEnabled
        || UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPhone) return NO;
    NSArray *stack = navigation.viewControllers;
    return stack.count == 2 && CompactPanelIsSubredditList(stack.firstObject)
        && !navigation.presentedViewController && !navigation.tabBarController.presentedViewController
        && !navigation.transitionCoordinator && navigation.viewIfLoaded.window;
}

static void CompactPanelRevealPending(UINavigationController *navigation) {
    ApolloCompactPanelFeedHistory *history = CompactPanelHistory(navigation, NO);
    if (!history.pendingReveal || !sCompactSubredditListEnabled
        || history.accountGeneration != sCompactPanelAccountGeneration
        || navigation.tabBarController.selectedViewController != navigation
        || navigation.viewControllers.firstObject != history.list
        || navigation.topViewController != history.feed) return;
    ApolloCompactSubredditPanelReveal(navigation);
}

static void CompactPanelSchedulePendingReveal(UINavigationController *navigation) {
    ApolloCompactPanelFeedHistory *history = CompactPanelHistory(navigation, NO);
    if (!sCompactSubredditListEnabled || !history.feed
        || (!history.pendingReveal && !(navigation.viewControllers.count == 1 && navigation.topViewController == history.list))) return;
    NSUInteger accountGeneration = history.accountGeneration;
    __weak UINavigationController *weakNavigation = navigation;
    __weak UIViewController *weakList = history.list;
    __weak UIViewController *weakFeed = history.feed;
    void (^reveal)(void) = ^{
        UINavigationController *current = weakNavigation;
        ApolloCompactPanelFeedHistory *currentHistory = CompactPanelHistory(current, NO);
        if (!current || !sCompactSubredditListEnabled || accountGeneration != sCompactPanelAccountGeneration
            || currentHistory.list != weakList || currentHistory.feed != weakFeed
            || current.viewControllers.firstObject != weakList
            || current.tabBarController.selectedViewController != current) return;
        CompactPanelPrepareRetainedFeed(current);
        CompactPanelRevealPending(current);
    };
    id<UIViewControllerTransitionCoordinator> coordinator = navigation.transitionCoordinator;
    if (coordinator && [coordinator animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        UINavigationController *current = weakNavigation;
        if (context.isCancelled) {
            // A cancelled return from a deeper page stays on that page. A
            // cancelled tab switch can retain its offscreen preparation.
            ApolloCompactPanelFeedHistory *currentHistory = CompactPanelHistory(current, NO);
            if (currentHistory.list == weakList && currentHistory.feed == weakFeed
                && current.topViewController != weakFeed) currentHistory.pendingReveal = NO;
            return;
        }
        // The coordinator is detached after its completion callbacks finish.
        dispatch_async(dispatch_get_main_queue(), reveal);
    }]) return;
    dispatch_async(dispatch_get_main_queue(), reveal);
}

static UIViewController *CompactPanelFeedForRootReturn(UINavigationController *navigation) {
    if (!sCompactSubredditListEnabled
        || UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPhone
        || navigation.transitionCoordinator || navigation.presentedViewController
        || navigation.tabBarController.presentedViewController || !navigation.viewIfLoaded.window) return nil;
    NSArray *stack = navigation.viewControllers;
    return stack.count > 2 && CompactPanelIsSubredditList(stack.firstObject)
        && CompactPanelIsFeed(stack[1]) ? stack[1] : nil;
}

BOOL ApolloCompactSubredditPanelReveal(UINavigationController *navigation) {
    if (objc_getAssociatedObject(navigation, &kCompactPanelOuter)) return YES;
    if (!CompactPanelCanReveal(navigation) || CompactPanelInteractiveNavigation(navigation)) return NO;
    NSArray *stack = navigation.viewControllers;
    CompactPanelRememberFeed(navigation);
    CompactPanelHistory(navigation, NO).pendingReveal = NO;
    ApolloCompactSubredditPanel *panel = [ApolloCompactSubredditPanel new];
    panel.outer = navigation;
    panel.list = stack.firstObject;
    // A native Back item is derived from the preceding navigation item.
    // Borrowing the real root must not turn the visible feed into a nav root,
    // which removes Back and makes UIKit recenter/rebuild its title. Retain
    // that position with equivalent native back metadata, not a drawn bar.
    panel.backSource = [UIViewController new];
    UINavigationItem *sourceItem = panel.list.navigationItem;
    UINavigationItem *backItem = panel.backSource.navigationItem;
    backItem.title = sourceItem.title;
    backItem.backButtonTitle = sourceItem.backButtonTitle;
    backItem.backButtonDisplayMode = sourceItem.backButtonDisplayMode;
    backItem.backBarButtonItem = sourceItem.backBarButtonItem;
    if (@available(iOS 16.0, *)) backItem.backAction = sourceItem.backAction;
    panel.listInsets = panel.list.additionalSafeAreaInsets;
    panel.modalPresentationStyle = UIModalPresentationOverFullScreen;
    panel.modalPresentationCapturesStatusBarAppearance = NO;
    panel.scrollStates = [NSMapTable weakToStrongObjectsMapTable];
    panel.gestureStates = [NSMapTable weakToStrongObjectsMapTable];
    // A modal blocks new touches; stop existing feed deceleration and Apollo's
    // ancestor bar-hide recognizers too. Restore exactly their previous state.
    NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:navigation.topViewController.view];
    for (NSUInteger i = 0; i < pending.count; i++) {
        UIView *view = pending[i];
        [pending addObjectsFromArray:view.subviews];
        if (![view isKindOfClass:UIScrollView.class]) continue;
        UIScrollView *scroll = (id)view;
        [panel.scrollStates setObject:@(scroll.scrollEnabled) forKey:scroll];
        [scroll setContentOffset:scroll.contentOffset animated:NO];
        scroll.scrollEnabled = NO;
    }
    for (UIGestureRecognizer *gesture in navigation.view.gestureRecognizers) {
        [panel.gestureStates setObject:@(gesture.enabled) forKey:gesture];
        gesture.enabled = NO;
    }
    objc_setAssociatedObject(navigation, &kCompactPanelOuter, panel, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    panel.changingNavigation = YES;
    panel.performingOuterUpdate = YES;
    [UIView performWithoutAnimation:^{
        [navigation setViewControllers:@[panel.backSource, stack.lastObject] animated:NO];
        [navigation.navigationBar layoutIfNeeded];
        ApolloNavigationTitlePresentationSynchronize(navigation.navigationBar);
    }];
    panel.performingOuterUpdate = NO;
    panel.list.additionalSafeAreaInsets = UIEdgeInsetsZero;
    panel.listNavigation = [[navigation.class alloc] initWithRootViewController:panel.list];
    [panel.listNavigation setNavigationBarHidden:YES animated:NO];
    ApolloCompactPanelReference *reference = [ApolloCompactPanelReference new];
    reference.panel = panel;
    objc_setAssociatedObject(panel.list, &kCompactPanelOwner, reference, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(panel.listNavigation, &kCompactPanelOwner, reference, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    panel.registeredSurfaceOwner = YES;
    ++sCompactPanelActiveSurfaceOwners;
    panel.changingNavigation = NO;
    [navigation presentViewController:panel animated:NO completion:nil];
    ApolloLog(@"[CompactSubreddits] presenting native list over feed");
    return YES;
}

@interface ApolloCompactPanelNavigation : UINavigationController @end
%group ApolloCompactPanelNavigationHooks
%hook ApolloCompactPanelNavigation
- (void)didReceiveMemoryWarning {
    %orig;
    ApolloCompactPanelFeedHistory *history = CompactPanelHistory(self, NO);
    UIViewController *feed = history.feed;
    // Apollo can discard its forward stack under memory pressure. Do not keep
    // a popped feed alive solely for the off -> on Compact List convenience.
    // A feed still owned by native navigation (or an active panel) is intact.
    if (feed && !feed.parentViewController && ![((UINavigationController *)self).viewControllers containsObject:feed]) {
        history.feed = nil;
        history.pendingReveal = NO;
    }
}
- (void)viewWillAppear:(BOOL)animated {
    CompactPanelPrepareRetainedFeed(self);
    %orig(animated);
}
- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    CompactPanelRememberFeed(self);
    CompactPanelSchedulePendingReveal(self);
}
- (void)navigationController:(UINavigationController *)navigation didShowViewController:(UIViewController *)controller animated:(BOOL)animated {
    %orig(navigation, controller, animated);
    CompactPanelRememberFeed(navigation);
    CompactPanelSchedulePendingReveal(navigation);
}
- (void)screenEdgePanned:(UIPanGestureRecognizer *)gesture {
    UINavigationController *navigation = (id)self;
    if (gesture.state == UIGestureRecognizerStateBegan) {
        CompactPanelRememberFeed(navigation);
        objc_setAssociatedObject(gesture, &kCompactPanelBackSwipe, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        Ivar left = class_getInstanceVariable(navigation.class, "leftScreenEdgePanGestureRecognizer");
        if (left && object_getIvar(navigation, left) == gesture)
            CompactPanelHistory(navigation, NO).returningToList = YES;
        if (left && object_getIvar(navigation, left) == gesture && CompactPanelCanReveal(navigation)
            && [NSStringFromClass(navigation.topViewController.class) isEqualToString:@"Apollo.PostsViewController"]) {
            // Apollo's own shouldBegin has already accepted this pan, including
            // its Disable Navigation Gestures preference. Claim it before the
            // native handler creates an interactive pop; never take over a pop
            // already in progress, or alter comments' Back/forward gestures.
            ApolloCompactPanelSwipe *swipe = [ApolloCompactPanelSwipe new];
            swipe.list = navigation.viewControllers.firstObject;
            swipe.feed = navigation.topViewController;
            objc_setAssociatedObject(gesture, &kCompactPanelBackSwipe, swipe, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    ApolloCompactPanelSwipe *swipe = objc_getAssociatedObject(gesture, &kCompactPanelBackSwipe);
    if (!swipe) {
        %orig(gesture);
        if (gesture.state == UIGestureRecognizerStateEnded || gesture.state == UIGestureRecognizerStateCancelled
            || gesture.state == UIGestureRecognizerStateFailed)
            CompactPanelHistory(navigation, NO).returningToList = NO;
        return;
    }
    if (gesture.state == UIGestureRecognizerStateEnded
        || gesture.state == UIGestureRecognizerStateCancelled || gesture.state == UIGestureRecognizerStateFailed) {
        objc_setAssociatedObject(gesture, &kCompactPanelBackSwipe, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        CompactPanelHistory(navigation, NO).returningToList = NO;
        CGFloat distance = [gesture translationInView:navigation.view].x;
        CGFloat velocity = [gesture velocityInView:navigation.view].x;
        BOOL completed = distance >= 44 || (distance >= 8 && velocity >= 350);
        if (gesture.state == UIGestureRecognizerStateEnded && completed
            && navigation.viewControllers.firstObject == swipe.list && navigation.topViewController == swipe.feed)
            ApolloCompactSubredditPanelReveal(navigation);
    }
}
- (UIViewController *)popViewControllerAnimated:(BOOL)animated {
    if (ApolloCompactSubredditPanelReveal(self)) return nil;
    CompactPanelRememberFeed(self);
    ApolloCompactPanelFeedHistory *history = CompactPanelHistory(self, NO);
    BOOL wasReturning = history.returningToList;
    history.returningToList = YES;
    UIViewController *popped = %orig(animated);
    history.returningToList = wasReturning;
    return popped;
}
- (NSArray<UIViewController *> *)popToRootViewControllerAnimated:(BOOL)animated {
    if (ApolloCompactSubredditPanelReveal(self)) return @[];
    CompactPanelRememberFeed(self);
    ApolloCompactPanelFeedHistory *history = CompactPanelHistory(self, NO);
    UIViewController *feed = CompactPanelFeedForRootReturn(self);
    if (feed) {
        // Finish the native return on its real feed, then show the root list
        // in the panel. Do not briefly navigate to a full-page compact list.
        history.pendingReveal = YES;
        NSArray *popped = [(UINavigationController *)self popToViewController:feed animated:animated];
        CompactPanelSchedulePendingReveal(self);
        return popped;
    }
    BOOL wasReturning = history.returningToList;
    history.returningToList = YES;
    NSArray *popped = %orig(animated);
    history.returningToList = wasReturning;
    return popped;
}
- (NSArray<UIViewController *> *)popToViewController:(UIViewController *)controller animated:(BOOL)animated {
    if (controller == ((UINavigationController *)self).viewControllers.firstObject
        && ApolloCompactSubredditPanelReveal(self)) return @[];
    CompactPanelRememberFeed(self);
    ApolloCompactPanelFeedHistory *history = CompactPanelHistory(self, NO);
    UIViewController *feed = controller == ((UINavigationController *)self).viewControllers.firstObject
        ? CompactPanelFeedForRootReturn(self) : nil;
    if (feed) {
        history.pendingReveal = YES;
        NSArray *popped = [(UINavigationController *)self popToViewController:feed animated:animated];
        CompactPanelSchedulePendingReveal(self);
        return popped;
    }
    BOOL wasReturning = history.returningToList;
    history.returningToList = YES;
    NSArray *popped = %orig(controller, animated);
    history.returningToList = wasReturning;
    return popped;
}
- (void)goBack {
    if (ApolloCompactSubredditPanelReveal(self)) return;
    CompactPanelRememberFeed(self);
    ApolloCompactPanelFeedHistory *history = CompactPanelHistory(self, NO);
    BOOL wasReturning = history.returningToList;
    history.returningToList = YES;
    %orig;
    history.returningToList = wasReturning;
}
- (void)pushViewController:(UIViewController *)controller animated:(BOOL)animated {
    // An asynchronous native selection may still hold the temporary nav after
    // its list was restored. It must never populate that retired stack.
    if ([objc_getAssociatedObject(self, &kCompactPanelRetiredNavigation) boolValue]) return;
    ApolloCompactSubredditPanel *panel = CompactPanelForObject(self);
    if (panel && !panel.changingNavigation) {
        if (!panel.closing) [panel closeWithPage:controller animated:animated];
        return;
    }
    ApolloCompactSubredditPanel *outerPanel = objc_getAssociatedObject(self, &kCompactPanelOuter);
    if (outerPanel && !outerPanel.performingOuterUpdate) [outerPanel cancelForNavigationChange];
    CompactPanelHistory(self, NO).pendingReveal = NO;
    %orig(controller, animated);
    CompactPanelRememberFeed(self);
}
- (void)setViewControllers:(NSArray<UIViewController *> *)controllers animated:(BOOL)animated {
    ApolloCompactSubredditPanel *panel = objc_getAssociatedObject(self, &kCompactPanelOuter);
    if (panel && !panel.performingOuterUpdate) {
        // Native account/URL routing may rebuild the Posts stack while the
        // modal is visible. Release its real root before UIKit reparents it.
        [panel cancelForNavigationChange];
    }
    ApolloCompactPanelFeedHistory *history = CompactPanelHistory(self, NO);
    BOOL ownedUpdate = panel.performingOuterUpdate || history.updatingStack || history.returningToList;
    if (!ownedUpdate && history.feed
        && (controllers.firstObject != history.list || ![controllers containsObject:history.feed])) {
        history.feed = nil;
        history.list = nil;
        history.pendingReveal = NO;
    }
    %orig(controllers, animated);
    if (!ownedUpdate) CompactPanelRememberFeed(self);
}
- (void)setNavigationBarHidden:(BOOL)hidden animated:(BOOL)animated {
    ApolloCompactSubredditPanel *panel = CompactPanelForObject(self);
    %orig(panel && !panel.changingNavigation ? YES : hidden, animated);
}
%end
%end

@interface ApolloCompactPanelList : UIViewController @end
%group ApolloCompactPanelListHooks
%hook ApolloCompactPanelList
- (void)viewWillAppear:(BOOL)animated {
    CompactPanelRefreshNavigationItems(self);
    %orig(animated);
}
- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    CompactPanelRefreshNavigationItems(self);
}
- (void)viewDidLayoutSubviews {
    %orig;
    CompactPanelRefreshNavigationItems(self);
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    %orig(previous);
    CompactPanelRefreshNavigationItems(self);
}
- (void)setEditing:(BOOL)editing animated:(BOOL)animated {
    %orig(editing, animated);
    CompactPanelRefreshNavigationItems(self);
}
%end
%end

%group ApolloCompactPanelSurfaceHooks
%hook UIView
- (void)setBackgroundColor:(UIColor *)color {
    %orig(ApolloCompactSubredditPanelBackground(self, color));
}
%end
%end

%ctor {
    Class navigation = ApolloClassApolloNavigationController;
    if (navigation) %init(ApolloCompactPanelNavigationHooks, ApolloCompactPanelNavigation = navigation);
    Class list = ApolloClassRedditListViewController;
    if (list) {
        %init(ApolloCompactPanelListHooks, ApolloCompactPanelList = list);
        %init(ApolloCompactPanelSurfaceHooks);
    }
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    for (NSString *name in @[@"com.christianselig.RedditCurrentAccountChanged", @"com.christianselig.RedditAccountChanged"]) {
        [center addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
            ++sCompactPanelAccountGeneration;
            for (UINavigationController *nav in sCompactPanelNavigations.allObjects) {
                ApolloCompactPanelFeedHistory *history = CompactPanelHistory(nav, NO);
                history.feed = nil;
                history.list = nil;
                history.pendingReveal = NO;
                ApolloCompactSubredditPanel *panel = objc_getAssociatedObject(nav, &kCompactPanelOuter);
                [panel cancelForNavigationChange];
            }
        }];
    }
    [center addObserverForName:@"ApolloCompactSubredditListDidChange" object:nil queue:NSOperationQueue.mainQueue
                  usingBlock:^(__unused NSNotification *note) {
        for (UINavigationController *nav in sCompactPanelNavigations.allObjects) {
            ApolloCompactPanelFeedHistory *history = CompactPanelHistory(nav, NO);
            if (!sCompactSubredditListEnabled) {
                // Undo only an offscreen preparation that has not been shown.
                // Turning the option off must not unexpectedly return to a feed.
                if (history.pendingReveal && nav.viewControllers.count == 2
                    && nav.viewControllers.firstObject == history.list && nav.topViewController == history.feed) {
                    history.updatingStack = YES;
                    [nav setViewControllers:@[history.list] animated:NO];
                    history.updatingStack = NO;
                }
                history.pendingReveal = NO;
                continue;
            }
            CompactPanelPrepareRetainedFeed(nav);
            CompactPanelRevealPending(nav);
        }
    }];
}
