#import "ApolloDuoRail.h"
#import "ApolloDuoSplitView.h"
#import "ApolloCommon.h"
#import "ApolloThemeRuntime.h"
#import <objc/runtime.h>
#import <objc/message.h>

void ApolloDuoRailRefreshGlyphs(void) {
    UITabBarController *controller = (UITabBarController *)ApolloMainTabBarController();
    if (![controller isKindOfClass:UITabBarController.class]) return;
    [controller.tabBar setNeedsLayout];
    [controller.tabBar layoutIfNeeded];
}

// Refresh native rail geometry across scene activation, rotation,
// and size-class changes. UIKit retains ownership of tab-bar visibility.

@interface _TtC6Apollo22ApolloTabBarController : UITabBarController
@end

struct ApolloDuoSizeRange { CGSize min; CGSize max; };
@interface ASTableView : UITableView
@end

@interface _TtC6Apollo22CommentsViewController : UIViewController
@end

@interface _TtC6Apollo20FloatingActionButton : UIButton
@end

// Apollo moves the comments jump button from scroll handling after the
// controller's layout callbacks have returned. Keep the visible comments
// controller so the button's own final geometry writes can be clamped too.
static __weak UIViewController *sApolloDuoActiveComments;
static BOOL sApolloDuoClampingJumpButton;

%group ApolloDuoRailTabs

%hook _TtC6Apollo22ApolloTabBarController

- (void)viewDidLayoutSubviews {
    %orig;
    ApolloDuoRailSync();
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    ApolloDuoRailSync();
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    %orig;
    ApolloDuoRailSync();
}

- (void)viewWillTransitionToSize:(CGSize)size
       withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    %orig;
    [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        (void)context;
        ApolloDuoRailSync();
    } completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        (void)context;
        ApolloDuoRailSync();
    }];
}

%end

%end

%group ApolloDuoRailTexture

// Keep Texture measurements within the native split and trailing safe area.
%hook ASTableView

- (void)setBackgroundColor:(UIColor *)color {
    // Texture can replay a resolved color from its table node after Apollo
    // has already recolored the cells. The rail exposes that table surface.
    // Keep opaque feed surfaces dynamic; transparent immersive backgrounds
    // continue to show their own banner/page backdrop.
    if (color && ApolloDuoRailFeedContentWidth(self) > 0.0
        && CGColorGetAlpha([color resolvedColorWithTraitCollection:self.traitCollection].CGColor) > 0.01) {
        color = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
            return [(ApolloThemeCardBackgroundColor() ?: UIColor.systemBackgroundColor)
                resolvedColorWithTraitCollection:traits];
        }];
    }
    %orig(color);
}

- (void)didMoveToWindow {
    %orig;
    // Initial node colors may be assigned before the table is marked as a
    // Duo feed. Reapply once it joins the hierarchy, when that scope is known.
    if (self.window && ApolloDuoRailFeedContentWidth(self) > 0.0) {
        self.backgroundColor = self.backgroundColor;
    }
}

- (void)safeAreaInsetsDidChange {
    %orig;
    UITableView *table = (UITableView *)self;
    CGFloat width = ApolloDuoRailFeedContentWidth(table);
    if (width <= 0.0) return;
    static char measuredWidthKey, refreshPendingKey;
    NSNumber *previous = objc_getAssociatedObject(table, &measuredWidthKey);
    objc_setAssociatedObject(table, &measuredWidthKey, @(width), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (previous && fabs(previous.doubleValue - width) < 0.5) return;
    if ([objc_getAssociatedObject(table, &refreshPendingKey) boolValue]) return;
    objc_setAssociatedObject(table, &refreshPendingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // The split sidebar changes the safe area without changing the backing
    // table bounds. Texture's bounds-width cache therefore leaves offscreen
    // rows measured for the old column. Remeasure existing nodes once after
    // UIKit has applied the new insets, without reloading their content.
    __weak UITableView *weakTable = table;
    dispatch_async(dispatch_get_main_queue(), ^{
        UITableView *liveTable = weakTable;
        if (!liveTable) return;
        objc_setAssociatedObject(liveTable, &refreshPendingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!liveTable.window || ApolloDuoRailFeedContentWidth(liveTable) <= 0.0) return;
        SEL relayout = NSSelectorFromString(@"relayoutItems");
        if ([liveTable respondsToSelector:relayout]) {
            [UIView performWithoutAnimation:^{
                ((void (*)(id, SEL))objc_msgSend)(liveTable, relayout);
            }];
        }
    });
}

- (void)didLayoutSubviewsOfTableViewCell:(UITableViewCell *)cell {
    CGFloat width = ApolloDuoRailFeedContentWidth((UITableView *)self);
    if (ApolloDuoSplitIsResizing() && width > 0.0
        && fabs(CGRectGetWidth(cell.contentView.bounds) - width) > 0.5) {
        // Texture's cell callback remeasures the node from contentView.bounds,
        // bypassing the data-controller constraint above. During reparenting
        // UIKit first lays that content view out without its column safe area.
        // Keep the already measured destination layout until UIKit supplies
        // the matching cell width; its next callback then runs normally.
        return;
    }
    %orig(cell);
}

- (void)endUpdatesAnimated:(BOOL)animated completion:(void (^)(BOOL))completion {
    // Folding already has a UIKit transition. Texture otherwise starts its
    // own height animation after remeasuring, making post text settle twice.
    %orig(ApolloDuoSplitIsResizing() ? NO : animated, completion);
}

// Texture caches the table's bounds width, subtracting contentInset but not
// adjustedContentInset/safeAreaInsets. Supply the usable width before nodes
// are measured, rather than clipping or resizing their rendered views later.
- (struct ApolloDuoSizeRange)dataController:(id)dataController
        constrainedSizeForNodeAtIndexPath:(NSIndexPath *)indexPath {
    struct ApolloDuoSizeRange range = %orig(dataController, indexPath);
    CGFloat width = ApolloDuoRailFeedContentWidth((UITableView *)self);
    if (width > 0.0) {
        // On a fold/unfold the native range can still contain the old
        // display width. Both ends must use the destination measurement.
        if (ApolloDuoSplitIsResizing()) {
            range.min.width = range.max.width = width;
        } else {
            range.max.width = MIN(range.max.width, width);
            range.min.width = MIN(range.min.width, range.max.width);
        }
    }
#if APOLLO_SIM_BUILD
    static char traceKey;
    UITableView *table = (UITableView *)self;
    NSString *geometry = [NSString stringWithFormat:@"table=%.1f safe=%.1f/%.1f content=%.1f/%.1f desired=%.1f measured=%.1f resize=%d", table.bounds.size.width, table.safeAreaInsets.left, table.safeAreaInsets.right, table.contentInset.left, table.contentInset.right, width, range.max.width, ApolloDuoSplitIsResizing()];
    if (![objc_getAssociatedObject(self, &traceKey) isEqual:geometry]) {
        objc_setAssociatedObject(self, &traceKey, geometry, OBJC_ASSOCIATION_COPY_NONATOMIC);
        ApolloLog(@"[DuoMeasure] %p %@", self, geometry);
    }
#endif
    return range;
}

- (void)layoutSubviews {
    %orig;
    ApolloDuoRailAlignFeedScrollIndicator((UIScrollView *)self);
}

%end

%end

// Clamp after the concrete comments controller finishes its native layout,
// so each jump-button position remains inside the Duo content edge.
%hook _TtC6Apollo22CommentsViewController

- (void)viewDidLayoutSubviews {
    %orig;
    ApolloDuoCoverAdjustJumpButton((UIViewController *)self);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    sApolloDuoActiveComments = (UIViewController *)self;
    ApolloDuoCoverAdjustJumpButton((UIViewController *)self);
}

- (void)viewWillAppear:(BOOL)animated {
    sApolloDuoActiveComments = (UIViewController *)self;
    %orig(animated);
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig(animated);
    if (sApolloDuoActiveComments == (UIViewController *)self) {
        sApolloDuoActiveComments = nil;
    }
}

%end

// The scroll path sets FloatingActionButton geometry after the comments
// controller's delegate callbacks. Clamp after those writes rather than
// racing them from scrollViewDidScroll:. The guard lets the helper assign the
// corrected frame without recursively entering this hook.
%hook _TtC6Apollo20FloatingActionButton

- (void)setFrame:(CGRect)frame {
    %orig(frame);
    UIViewController *comments = sApolloDuoActiveComments;
    if (!comments || sApolloDuoClampingJumpButton) return;
    sApolloDuoClampingJumpButton = YES;
    ApolloDuoCoverAdjustJumpButton(comments);
    sApolloDuoClampingJumpButton = NO;
}

- (void)setCenter:(CGPoint)center {
    %orig(center);
    UIViewController *comments = sApolloDuoActiveComments;
    if (!comments || sApolloDuoClampingJumpButton) return;
    sApolloDuoClampingJumpButton = YES;
    ApolloDuoCoverAdjustJumpButton(comments);
    sApolloDuoClampingJumpButton = NO;
}

%end

%hook UINavigationController

- (void)pushViewController:(UIViewController *)controller animated:(BOOL)animated {
    ApolloDuoRailPrepareFeedContent(controller);
    %orig(controller, animated);
}

%end

%hook UIViewController

- (void)viewWillAppear:(BOOL)animated {
    ApolloDuoRailPrepareFeedContent(self);
    %orig(animated);
}

%end

%ctor {
    %init;
    Class tabs = objc_getClass("_TtC6Apollo22ApolloTabBarController");
    if (!tabs) {
        ApolloLog(@"[DuoRail] ApolloTabBarController missing; rail inactive");
        return;
    }
    %init(ApolloDuoRailTabs);
    if (objc_getClass("ASTableView")) {
        %init(ApolloDuoRailTexture);
    }
    [[NSNotificationCenter defaultCenter] addObserverForName:UISceneDidActivateNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *notification) {
        ApolloDuoRailSync();
    }];
    ApolloLog(@"[DuoRail] native trailing rail adapters installed");
}
