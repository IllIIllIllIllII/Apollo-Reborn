#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "ApolloCommon.h"
#import "ApolloAutomaticBackupViewController.h"
#import "ApolloReportViewController.h"
#import "ApolloSpinnerViewController.h"

// A recognized hold owns that touch through its release. Keep this marker
// until the next tab touch (or an explicit shortcut), since Glass can deliver
// its selection callback after the hold recognizer has already ended.
static char kApolloSettingsHoldConsumedTouch;
static void ApolloClearConsumedSettingsTouch(UITabBarController *controller) {
    if (controller) objc_setAssociatedObject(controller, &kApolloSettingsHoldConsumedTouch, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Liquid Glass replaces the legacy tab buttons. Locate the live controls
// through the tab bar hierarchy, using the controller order for their identity.
static void ApolloCollectTabButtons(UIView *view, NSMutableArray<UIView *> *buttons) {
    if (view.hidden || view.alpha <= 0.01) return;
    NSString *name = NSStringFromClass(view.class);
    if ([view isKindOfClass:UIControl.class] &&
        ([name containsString:@"TabButton"] || [name containsString:@"TabBarButton"])) {
        if (!view.hidden && view.alpha > 0.01) [buttons addObject:view];
        return;
    }
    for (UIView *child in view.subviews) ApolloCollectTabButtons(child, buttons);
}

static UIView *ApolloSettingsTabView(UITabBarController *controller) {
    NSUInteger index = NSNotFound;
    for (NSUInteger i = 0; i < controller.viewControllers.count; i++) {
        UIViewController *child = controller.viewControllers[i];
        UIViewController *root = [child isKindOfClass:UINavigationController.class]
            ? ((UINavigationController *)child).viewControllers.firstObject : child;
        if ([NSStringFromClass(root.class) containsString:@"SettingsViewController"]) { index = i; break; }
    }
    if (index == NSNotFound) return nil;
    NSMutableArray<UIView *> *buttons = [NSMutableArray array];
    ApolloCollectTabButtons(controller.tabBar, buttons);
    [buttons sortUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
        CGFloat ax = [a convertPoint:CGPointMake(CGRectGetMidX(a.bounds), CGRectGetMidY(a.bounds)) toView:controller.tabBar].x;
        CGFloat bx = [b convertPoint:CGPointMake(CGRectGetMidX(b.bounds), CGRectGetMidY(b.bounds)) toView:controller.tabBar].x;
        return ax < bx ? NSOrderedAscending : ax > bx ? NSOrderedDescending : NSOrderedSame;
    }];
    // Glass renders a second set of buttons inside its selection lens.
    // Collapse those copies by their shared on-screen item position.
    NSMutableArray<UIView *> *items = [NSMutableArray array];
    CGFloat previousX = -CGFLOAT_MAX;
    for (UIView *button in buttons) {
        CGFloat x = [button convertPoint:CGPointMake(CGRectGetMidX(button.bounds), CGRectGetMidY(button.bounds)) toView:controller.tabBar].x;
        if (fabs(x - previousX) > 2) { [items addObject:button]; previousX = x; }
    }
    buttons = items;
    if (buttons.count != controller.viewControllers.count) return nil;
    if (controller.tabBar.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft) index = buttons.count - 1 - index;
    return buttons[index];
}

static void ApolloPushSettingsShortcut(UITabBarController *controller, UIViewController *screen) {
    if (!controller) return;
    ApolloClearConsumedSettingsTouch(controller);
    UINavigationController *nav = nil;
    for (UIViewController *child in controller.viewControllers) {
        if (![child isKindOfClass:UINavigationController.class]) continue;
        UINavigationController *candidate = (UINavigationController *)child;
        if ([NSStringFromClass(candidate.viewControllers.firstObject.class) containsString:@"SettingsViewController"]) {
            nav = candidate;
            break;
        }
    }
    if (!nav) return;

    // Prepare the destination before revealing the Settings tab. Selecting the
    // tab first and then animating a push briefly exposes its previous page.
    // Reuse an existing destination, preserving its state and avoiding duplicates.
    UIViewController *destination = screen;
    for (UIViewController *existing in nav.viewControllers) {
        if ([existing isMemberOfClass:screen.class]) {
            destination = existing;
            break;
        }
    }
    [UIView performWithoutAnimation:^{
        if (destination != screen) {
            if (nav.topViewController != destination) [nav popToViewController:destination animated:NO];
        } else {
            [nav pushViewController:destination animated:NO];
        }
        controller.selectedViewController = nav;
        [nav.view layoutIfNeeded];
    }];
    ApolloLog(@"[SettingsTabMenu] Opened directly %@ reused=%d", NSStringFromClass(destination.class), destination != screen);
}

static void ApolloPresentSettingsTabMenu(UITabBarController *controller) {
    if (controller.presentedViewController) return;
    UIView *tab = ApolloSettingsTabView(controller);
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:nil message:nil
        preferredStyle:UIAlertControllerStyleActionSheet];
    __weak UITabBarController *weakController = controller;
    [menu addAction:[UIAlertAction actionWithTitle:@"Backup Settings" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [weakController dismissViewControllerAnimated:YES completion:^{
            ApolloPushSettingsShortcut(weakController, [[ApolloAutomaticBackupViewController alloc] initWithStyle:UITableViewStyleInsetGrouped]);
        }];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Feature Requests" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        // Present after the sheet has dismissed, using the same browser as About.
        [weakController dismissViewControllerAnimated:YES completion:^{
            UIViewController *selected = weakController.selectedViewController;
            UIViewController *presenter = [selected isKindOfClass:UINavigationController.class]
                ? ((UINavigationController *)selected).topViewController : selected;
            if (presenter) ApolloPresentWebURLFromViewController(presenter, [NSURL URLWithString:@"https://apolloreborn.fider.io/"]);
        }];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Bug Reports" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [weakController dismissViewControllerAnimated:YES completion:^{
            ApolloPushSettingsShortcut(weakController, [[ApolloReportViewController alloc] init]);
        }];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Spinner" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [weakController dismissViewControllerAnimated:YES completion:^{
            // Intentionally not a settings route: only this hold menu opens it.
            ApolloPushSettingsShortcut(weakController, [[ApolloSpinnerViewController alloc] init]);
        }];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    menu.popoverPresentationController.sourceView = tab ?: controller.tabBar;
    menu.popoverPresentationController.sourceRect = (tab ?: controller.tabBar).bounds;
    [controller presentViewController:menu animated:YES completion:nil];
    ApolloLog(@"[SettingsTabMenu] Presented shortcuts");
}

// Admit only touches on Settings. Account-tab gestures never enter this
// recognizer, and ordinary Settings taps retain UIKit's normal behavior.
@interface ApolloSettingsTabHold : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, weak) UITabBarController *controller;
@property (nonatomic, strong) UILongPressGestureRecognizer *gesture;
@end
@implementation ApolloSettingsTabHold
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldReceiveTouch:(UITouch *)touch {
    ApolloClearConsumedSettingsTouch(self.controller);
    UIView *tab = ApolloSettingsTabView(self.controller);
    BOOL accepts = tab.window && CGRectContainsPoint(tab.bounds, [touch locationInView:tab]);
    ApolloLog(@"[SettingsTabMenu] Settings touch=%d target=%@", accepts, tab);
    return accepts;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    // UIKit's glass selection gesture begins on touch-down. It may coexist
    // with this Settings-only hold without suppressing its recognition.
    return YES;
}
- (void)held:(UILongPressGestureRecognizer *)gesture {
    ApolloLog(@"[SettingsTabMenu] Hold state=%ld", (long)gesture.state);
    if (gesture.state == UIGestureRecognizerStateBegan) {
        objc_setAssociatedObject(self.controller, &kApolloSettingsHoldConsumedTouch, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloPresentSettingsTabMenu(self.controller);
    }
}
@end

static char kApolloSettingsTabHold;
%hook _TtC6Apollo22ApolloTabBarController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    UITabBarController *controller = (UITabBarController *)self;
    ApolloLog(@"[SettingsTabMenu] Installing hold on %@", controller.tabBar);
    ApolloSettingsTabHold *hold = objc_getAssociatedObject(self, &kApolloSettingsTabHold);
    if (!hold) {
        hold = [ApolloSettingsTabHold new];
        hold.controller = controller;
        hold.gesture = [[UILongPressGestureRecognizer alloc] initWithTarget:hold action:@selector(held:)];
        hold.gesture.minimumPressDuration = 0.5;
        hold.gesture.delegate = hold;
        objc_setAssociatedObject(self, &kApolloSettingsTabHold, hold, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (hold.gesture.view != controller.tabBar) [controller.tabBar addGestureRecognizer:hold.gesture];
}
%end

// Veto the release before Apollo's delegate can switch tabs or pop an already
// selected Settings stack. Ordinary taps and intentional menu navigation pass.
%hook _TtC6Apollo13SceneDelegate
- (BOOL)tabBarController:(UITabBarController *)controller shouldSelectViewController:(UIViewController *)viewController {
    UIViewController *root = [viewController isKindOfClass:UINavigationController.class]
        ? ((UINavigationController *)viewController).viewControllers.firstObject : viewController;
    if ([objc_getAssociatedObject(controller, &kApolloSettingsHoldConsumedTouch) boolValue]
        && [NSStringFromClass(root.class) containsString:@"SettingsViewController"]) {
        ApolloLog(@"[SettingsTabMenu] Consumed hold release without selecting Settings");
        return NO;
    }
    return %orig(controller, viewController);
}
%end
