#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "ApolloCommon.h"
#import "ApolloAutomaticBackupViewController.h"
#import "ApolloReportViewController.h"
#import "ApolloSpinnerViewController.h"

// Match the account switcher's medium impact for deliberate menu actions.
static void ApolloSettingsMenuHaptic(void) {
    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [feedback impactOccurred];
}

// A recognized hold owns that touch through its release. Keep this marker
// until the next tab touch (or an explicit shortcut), since Glass can deliver
// its selection callback after the hold recognizer has already ended.
static char kApolloSettingsHoldConsumedTouch;
static char kApolloSettingsMenuBackdrop;
static void ApolloClearConsumedSettingsTouch(UITabBarController *controller) {
    if (controller) objc_setAssociatedObject(controller, &kApolloSettingsHoldConsumedTouch, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Identify the native item rather than waiting for Glass's normal and lens
// copies to finish animating into matching positions after the bar expands.
static id ApolloSettingsObjectForSelector(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return [object respondsToSelector:selector] ? ((id (*)(id, SEL))objc_msgSend)(object, selector) : nil;
}

static UIView *ApolloFindSettingsItemView(UIView *view, UITabBarItem *settingsItem) {
    if (view.hidden || view.alpha <= 0.01) return nil;
    id item = ApolloSettingsObjectForSelector(view, @"item");
    if (item == settingsItem || ApolloSettingsObjectForSelector(item, @"_linkedTabBarItem") == settingsItem) return view;
    for (UIView *child in view.subviews) {
        UIView *match = ApolloFindSettingsItemView(child, settingsItem);
        if (match) return match;
    }
    return nil;
}

static UIView *ApolloSettingsTabView(UITabBarController *controller) {
    UITabBarItem *settingsItem = nil;
    for (UIViewController *child in controller.viewControllers) {
        UIViewController *root = [child isKindOfClass:UINavigationController.class]
            ? ((UINavigationController *)child).viewControllers.firstObject : child;
        if ([NSStringFromClass(root.class) containsString:@"SettingsViewController"]) {
            NSUInteger index = [controller.viewControllers indexOfObjectIdenticalTo:child];
            settingsItem = index < controller.tabBar.items.count ? controller.tabBar.items[index] : child.tabBarItem;
            break;
        }
    }
    if (!settingsItem) return nil;
    UIView *button = ApolloSettingsObjectForSelector(settingsItem, @"_tabBarButton");
    if ([button isKindOfClass:UIView.class] && [button isDescendantOfView:controller.tabBar] &&
        !button.hidden && button.alpha > 0.01) return button;
    Ivar viewIvar = class_getInstanceVariable(settingsItem.class, "_view");
    UIView *itemView = viewIvar ? object_getIvar(settingsItem, viewIvar) : nil;
    if ([itemView isKindOfClass:UIView.class] && [itemView isDescendantOfView:controller.tabBar] &&
        !itemView.hidden && itemView.alpha > 0.01) return itemView;
    return ApolloFindSettingsItemView(controller.tabBar, settingsItem);
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
    // Mark only our menu; other alerts keep their native presentation.
    objc_setAssociatedObject(menu, &kApolloSettingsMenuBackdrop, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UITabBarController *weakController = controller;
    [menu addAction:[UIAlertAction actionWithTitle:@"Backup Settings" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        ApolloSettingsMenuHaptic();
        [weakController dismissViewControllerAnimated:YES completion:^{
            ApolloPushSettingsShortcut(weakController, [[ApolloAutomaticBackupViewController alloc] initWithStyle:UITableViewStyleInsetGrouped]);
        }];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Feature Requests" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        ApolloSettingsMenuHaptic();
        // Present after the sheet has dismissed, using the same browser as About.
        [weakController dismissViewControllerAnimated:YES completion:^{
            UIViewController *selected = weakController.selectedViewController;
            UIViewController *presenter = [selected isKindOfClass:UINavigationController.class]
                ? ((UINavigationController *)selected).topViewController : selected;
            if (presenter) ApolloPresentWebURLFromViewController(presenter, [NSURL URLWithString:@"https://apolloreborn.fider.io/"]);
        }];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Bug Reports" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        ApolloSettingsMenuHaptic();
        [weakController dismissViewControllerAnimated:YES completion:^{
            ApolloPushSettingsShortcut(weakController, [[ApolloReportViewController alloc] init]);
        }];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Spinner" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        ApolloSettingsMenuHaptic();
        [weakController dismissViewControllerAnimated:YES completion:^{
            // Intentionally not a settings route: only this hold menu opens it.
            ApolloPushSettingsShortcut(weakController, [[ApolloSpinnerViewController alloc] init]);
        }];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    menu.popoverPresentationController.sourceView = tab ?: controller.tabBar;
    menu.popoverPresentationController.sourceRect = (tab ?: controller.tabBar).bounds;
    ApolloSettingsMenuHaptic();
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

// Glass action-sheet popovers have a transparent backdrop. Match the account
// switcher's 40% black scrim without changing UIKit's outside-tap handling.
%hook UIAlertController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    if (!IsLiquidGlass() || !objc_getAssociatedObject(self, &kApolloSettingsMenuBackdrop)) return;
    UIView *container = self.presentationController.containerView;
    if (!container) return;
    UIView *backdrop = [[UIView alloc] initWithFrame:container.bounds];
    backdrop.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    backdrop.userInteractionEnabled = NO;
    backdrop.backgroundColor = [UIColor colorWithWhite:0 alpha:0.4];
    backdrop.alpha = 0;
    [container insertSubview:backdrop atIndex:0];
    objc_setAssociatedObject(self, &kApolloSettingsMenuBackdrop, backdrop, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (![self.transitionCoordinator animateAlongsideTransition:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) {
        backdrop.alpha = 1;
    } completion:nil]) backdrop.alpha = 1;
}
- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    id value = objc_getAssociatedObject(self, &kApolloSettingsMenuBackdrop);
    if (![value isKindOfClass:UIView.class]) return;
    UIView *backdrop = value;
    if (![self.transitionCoordinator animateAlongsideTransition:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) {
        backdrop.alpha = 0;
    } completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        if (context.isCancelled) backdrop.alpha = 1;
        else [backdrop removeFromSuperview];
    }]) [backdrop removeFromSuperview];
}
%end
