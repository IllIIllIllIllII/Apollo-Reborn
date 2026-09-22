#import "ApolloDuoRail.h"
#import "ApolloDuoSplitView.h"
#import "ApolloCommon.h"
#import <objc/runtime.h>

static char kApolloDuoRailOriginalImageKey;
static char kApolloDuoRailOriginalSelectedImageKey;
static char kApolloDuoRailAppliedImageKey;
static char kApolloDuoRailAppliedSelectedImageKey;

// UIKit and the glass tint hook copy UIImage wrappers. Pointer identity alone
// mistakes a template copy of our reduced raster for a new Apollo source and
// subtracts another two points on the next layout.
static BOOL ApolloDuoRailSameGlyph(UIImage *a, UIImage *b) {
    return a == b || (a && b && a.CGImage && a.CGImage == b.CGImage
        && CGSizeEqualToSize(a.size, b.size) && a.scale == b.scale);
}

static BOOL sApolloDuoUpdatingGlyphs;

static UIImage *ApolloDuoRailImageReducedByTwoPoints(UIImage *source) {
    if (!source || source.size.width <= 2.0 || source.size.height <= 2.0) return source;

    CGSize size = CGSizeMake(source.size.width - 2.0, source.size.height - 2.0);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.opaque = NO;
    format.scale = source.scale;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    UIImage *image = [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {
        [source drawInRect:(CGRect){CGPointZero, size}];
    }];
    return [image imageWithRenderingMode:source.renderingMode];
}

static BOOL ApolloDuoRailHasTrailingTabBar(UITabBarController *controller) {
    if (UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPhone) return NO;
    UITabBar *bar = controller.tabBar;
    if (!controller.isViewLoaded || !bar.window || bar.hidden) return NO;
    CGRect frame = [bar convertRect:bar.bounds toView:controller.view];
    return CGRectGetWidth(frame) < 100.0
        && CGRectGetHeight(frame) > 400.0
        && CGRectGetMaxX(frame) >= CGRectGetWidth(controller.view.bounds) - 2.0;
}

// Sources live on the item for its lifetime. A temporarily hidden tab bar
// (fullscreen media) must not discard them or turn the displayed raster into
// the next source. Only explicit image setters can supply a new source.
static char kApolloDuoRailReducedKey;
static void ApolloDuoRailApplyGlyphs(UITabBarController *controller) {
    if (sApolloDuoUpdatingGlyphs) return;
    // Hiding during presentation is not a change of device layout.
    if (controller.tabBar.hidden || !controller.tabBar.window) return;
    BOOL reduced = ApolloDuoRailHasTrailingTabBar(controller);
    sApolloDuoUpdatingGlyphs = YES;
    for (UITabBarItem *item in controller.tabBar.items) {
        const void *sourceKeys[] = { &kApolloDuoRailOriginalImageKey, &kApolloDuoRailOriginalSelectedImageKey };
        const void *renderKeys[] = { &kApolloDuoRailAppliedImageKey, &kApolloDuoRailAppliedSelectedImageKey };
        objc_setAssociatedObject(item, &kApolloDuoRailReducedKey, @(reduced), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        for (NSUInteger variant = 0; variant < 2; variant++) {
            UIImage *current = variant ? item.selectedImage : item.image;
            id stored = objc_getAssociatedObject(item, sourceKeys[variant]);
            // Ordinary phone tabs need no retained source or raster work.
            if (!stored && !reduced) continue;
            if (!stored) {
                stored = current ?: NSNull.null;
                objc_setAssociatedObject(item, sourceKeys[variant], stored, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            UIImage *source = stored == NSNull.null ? nil : stored;
            UIImage *render = objc_getAssociatedObject(item, renderKeys[variant]);
            if (!render && source && reduced) {
                render = ApolloDuoRailImageReducedByTwoPoints(source);
                objc_setAssociatedObject(item, renderKeys[variant], render, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            UIImage *desired = reduced ? render : source;
            if (!ApolloDuoRailSameGlyph(current, desired)) {
                if (variant) item.selectedImage = desired;
                else item.image = desired;
            }
        }
    }
    sApolloDuoUpdatingGlyphs = NO;
}

static UIImage *ApolloDuoRailAcceptSource(UITabBarItem *item, UIImage *image, BOOL selected) {
    if (sApolloDuoUpdatingGlyphs) return image;
    const void *sourceKey = selected ? &kApolloDuoRailOriginalSelectedImageKey : &kApolloDuoRailOriginalImageKey;
    const void *renderKey = selected ? &kApolloDuoRailAppliedSelectedImageKey : &kApolloDuoRailAppliedImageKey;
    UIImage *render = objc_getAssociatedObject(item, renderKey);
    BOOL reduced = [objc_getAssociatedObject(item, &kApolloDuoRailReducedKey) boolValue];
    if (!reduced && !objc_getAssociatedObject(item, sourceKey)) return image;
    // UIKit republishes the item image when the fullscreen presentation ends.
    // A copy of our output is still output, never a new stock icon.
    if (render && ApolloDuoRailSameGlyph(image, render)) {
        id source = objc_getAssociatedObject(item, sourceKey);
        return reduced ? render : (source == NSNull.null ? nil : source);
    }
    objc_setAssociatedObject(item, sourceKey, image ?: NSNull.null, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    render = reduced ? ApolloDuoRailImageReducedByTwoPoints(image) : nil;
    objc_setAssociatedObject(item, renderKey, render, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return reduced ? render : image;
}

%hook UITabBarItem
- (void)setImage:(UIImage *)image {
    %orig(ApolloDuoRailAcceptSource(self, image, NO));
}
- (void)setSelectedImage:(UIImage *)image {
    %orig(ApolloDuoRailAcceptSource(self, image, YES));
}
%end

void ApolloDuoRailRefreshGlyphs(void) {
    UITabBarController *controller = (UITabBarController *)ApolloMainTabBarController();
    if (![controller isKindOfClass:UITabBarController.class]) return;
    ApolloDuoRailApplyGlyphs(controller);
    [controller.tabBar setNeedsLayout];
    [controller.tabBar layoutIfNeeded];
}

// Refresh native rail geometry and glyphs across scene activation, rotation,
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
    ApolloDuoRailApplyGlyphs((UITabBarController *)self);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    ApolloDuoRailSync();
    ApolloDuoRailApplyGlyphs((UITabBarController *)self);
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
        ApolloDuoRailApplyGlyphs((UITabBarController *)self);
    }];
}

%end

%end

%group ApolloDuoRailTexture

// Keep Texture measurements within the native split and trailing safe area.
%hook ASTableView

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
