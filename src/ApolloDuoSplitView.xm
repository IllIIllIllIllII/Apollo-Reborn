// Native sidebar/detail containers for the opened Duo. The tab still owns its
// original ApolloNavigationController: URL routing, tab gestures and account
// switching can keep addressing that object. Only its visible contents change
// at an unfold/fold boundary. UIKit owns all column frames and transitions.
#import "ApolloDuoSplitView.h"
#import "ApolloCommon.h"
#import "ApolloDuoRail.h"
#import "ApolloDuoCompatibility.h"
#import "ApolloFeedShortcutsAppearance.h"
#import "settings/CustomAPIViewController.h"
#import <objc/runtime.h>
#import <objc/message.h>

// UINavigationController forbids a UISplitViewController as a stack entry.
// A plain containment host keeps Apollo's tab navigation identity intact while
// the split controller remains a proper child and owns its own column layout.
@interface ApolloDuoSplitHost : UIViewController
@property(nonatomic, strong) UISplitViewController *split;
@end
@implementation ApolloDuoSplitHost
- (void)viewDidLoad {
    [super viewDidLoad];
    [self addChildViewController:self.split];
    UIView *content = self.split.view;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [content.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [content.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];
    [self.split didMoveToParentViewController:self];
}
@end

@interface ApolloDuoSplitState : NSObject
@property(nonatomic, weak) UINavigationController *outer;
@property(nonatomic, strong) UIViewController *root;
@property(nonatomic, strong) UISplitViewController *split;
@property(nonatomic, strong) ApolloDuoSplitHost *host;
@property(nonatomic, strong) UINavigationController *primary;
@property(nonatomic, strong) UINavigationController *secondary;
@property(nonatomic, strong) NSArray<UIViewController *> *lastSettings;
@property(nonatomic, copy) NSString *kind;
@property(nonatomic, copy) NSString *sidebarTitle;
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
    if (state.split && width >= 800.0 && width > sDuoSplitTargetSize.height) {
        UISplitViewController *split = state.split;
        CGFloat primary = MIN(split.maximumPrimaryColumnWidth,
                              MAX(split.minimumPrimaryColumnWidth,
                                  width * split.preferredPrimaryColumnWidthFraction));
        // Account's overview is also a Texture feed, but lives in the primary
        // column. Its row heights must be measured at that column's width.
        if (owner == state.root) return primary;
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
    return state.split && !state.changing ? state.secondary : nav;
}

UIViewController *ApolloDuoSplitRootController(UINavigationController *nav) {
    return ApolloDuoSplitStateForNavigation(nav, NO).root;
}

CGRect ApolloDuoSplitContentFrame(UIViewController *controller, UIView *coordinateView) {
    UINavigationController *nav = [controller isKindOfClass:UINavigationController.class] ? (id)controller : controller.navigationController;
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, NO);
    if (!state.split || nav != state.secondary || !coordinateView.window) return CGRectNull;
    // Modern UIKit can extend the secondary surface beneath the sidebar. Its
    // safe-area guide, rather than its full bounds, is the visible column.
    UIView *view = state.secondary.view;
    UIEdgeInsets insets = view.safeAreaInsets;
    // Center across the whole detail pane, including its trailing navigation
    // strip. Only the leading sidebar is excluded from this alignment band.
    insets.right = 0.0;
    CGRect content = UIEdgeInsetsInsetRect(view.bounds, insets);
    return [coordinateView convertRect:content fromView:view];
}

BOOL ApolloDuoSplitIsSidebarController(UIViewController *controller) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(controller.navigationController, NO);
    return state.split && state.root == controller;
}

BOOL ApolloDuoSplitShowSidebar(UINavigationController *nav) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, NO);
    if (!state.split) return NO;
    [state.split showColumn:UISplitViewControllerColumnPrimary];
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
    split.maximumPrimaryColumnWidth = halfWidth ? CGFLOAT_MAX : 420.0;
    split.preferredPrimaryColumnWidthFraction = halfWidth ? 0.5 : 1.0 / 3.0;
    if (@available(iOS 26.0, *)) {
        // UIKit's default secondary minimum (532pt on this inner display)
        // otherwise caps the primary at 419pt even with a 50% preference.
        split.minimumSecondaryColumnWidth = halfWidth ? 240.0 : UISplitViewControllerAutomaticDimension;
    }
    if (halfWidth) {
        split.preferredDisplayMode = UISplitViewControllerDisplayModeOneBesideSecondary;
        [split showColumn:UISplitViewControllerColumnPrimary];
    }
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
        return state.secondary.viewControllers.firstObject.class != UIViewController.class;
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
    } else if (![state.kind isEqualToString:@"search"]) {
        NSSet *labels = [state.kind isEqualToString:@"inbox"]
            ? [NSSet setWithObjects:@"Inbox (All)", @"Inbox", nil] : [NSSet setWithObject:@"Posts"];
        // A profile may still be fetching its menu. Leave the default pending
        // until its table reloads; do not invent a Posts controller or row index.
        state.needsDefault = !ApolloDuoSplitSelectRow(state.root, labels);
    }
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
    NSArray *detail = stack.count > 1 ? [stack subarrayWithRange:NSMakeRange(1, stack.count - 1)] : @[];
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
    [outer setViewControllers:@[host] animated:NO];
    state.split = split;
    state.root.extendedLayoutIncludesOpaqueBars = YES;
    state.primary = [[outer.class alloc] initWithRootViewController:state.root];
    state.secondary = [[outer.class alloc] init];
    ApolloDuoSplitLink(state.primary, state);
    ApolloDuoSplitLink(state.secondary, state);
    if (detail.count) [state.secondary setViewControllers:detail animated:NO];
    else {
        UIViewController *placeholder = [UIViewController new];
        placeholder.view.backgroundColor = UIColor.systemBackgroundColor;
        [state.secondary setViewControllers:@[placeholder] animated:NO];
    }
    [split setViewController:state.primary forColumn:UISplitViewControllerColumnPrimary];
    [split setViewController:state.secondary forColumn:UISplitViewControllerColumnSecondary];
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

static void ApolloDuoSplitClose(ApolloDuoSplitState *state) {
    if (!state.split || state.changing) return;
    state.changing = YES;
    NSArray *detail = [state.secondary.viewControllers copy];
    if (detail.count && [detail.firstObject class] == UIViewController.class) detail = @[];
    if ([state.kind isEqualToString:@"settings"] && detail.count) state.lastSettings = detail;
    [state.primary setViewControllers:@[] animated:NO];
    [state.secondary setViewControllers:@[] animated:NO];
    [state.outer setOverrideTraitCollection:nil forChildViewController:state.host];
    // The cover display opens these tabs at their overview, not at the
    // detail selected automatically for the unfolded secondary column.
    BOOL overviewOnCover = !ApolloDuoSplitIsUnfolded()
        && ([state.kind isEqualToString:@"account"] || [state.kind isEqualToString:@"settings"]);
    [state.outer setViewControllers:overviewOnCover ? @[state.root]
        : [@[state.root] arrayByAddingObjectsFromArray:detail] animated:NO];
    [state.outer setNavigationBarHidden:state.navigationBarWasHidden animated:NO];
    state.root.navigationItem.title = state.sidebarTitle;
    state.split = nil;
    state.host = nil;
    state.primary = nil;
    state.secondary = nil;
    state.needsDefault = NO;
    state.changing = NO;
    ApolloLog(@"[DuoSplit] restored single-column %@ stack", state.kind);
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
        if (!open) ApolloDuoSplitClose(state);
        else {
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
    if ([state.kind isEqualToString:@"search"] && nav == state.outer && !state.split
        && ApolloDuoSplitShouldOpen((id)nav.tabBarController)) {
        ApolloDuoSplitOpen(state);
    }
    if (!state.split || state.changing || (nav != state.primary && nav != state.outer)) return NO;
    state.needsDefault = NO;
    [state.secondary setViewControllers:@[page] animated:NO];
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
    if (self != state.secondary || (back && nav.viewControllers.count < 2) ||
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
    if (state.split && (self == state.primary || self == state.secondary)) {
        controller.extendedLayoutIncludesOpaqueBars = YES;
    }
    %orig(controller, state.changing ? NO : animated);
    ApolloDuoSplitRememberSettings(self);
}
- (void)setViewControllers:(NSArray<UIViewController *> *)controllers animated:(BOOL)animated {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(self, NO);
    if (state.split && (self == state.primary || self == state.secondary)) {
        // New detail pages default to NO even when existing Apollo pages use
        // YES. Prepare them before UIKit installs the stack, so an opaque
        // theme cannot deduct the vertical tab rail's height from their view.
        // Safe areas already describe the sidebar, navigation bar, and rail.
        for (UIViewController *controller in controllers) {
            controller.extendedLayoutIncludesOpaqueBars = YES;
        }
    }
    %orig(controllers, animated);
}
- (UIViewController *)popViewControllerAnimated:(BOOL)animated {
    ApolloDuoSplitRememberSettings(self);
    UINavigationController *detail = ApolloDuoSplitDetailNavigation(self);
    if (detail != self) return [detail popViewControllerAnimated:animated];
    return %orig(animated);
}
- (NSArray *)popToRootViewControllerAnimated:(BOOL)animated {
    ApolloDuoSplitRememberSettings(self);
    UINavigationController *detail = ApolloDuoSplitDetailNavigation(self);
    if (detail != self) return [detail popToRootViewControllerAnimated:animated];
    return %orig(animated);
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
    } completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        if (sDuoSplitSizeCoordinator != coordinator) return;
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
    if (([kind isEqualToString:@"account"] || [kind isEqualToString:@"settings"])
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
