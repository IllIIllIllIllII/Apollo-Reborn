#import "ApolloActionMenuPresenter.h"
#import "ApolloNativeActionMenus.h"
#import "ApolloCommon.h"
#import <objc/runtime.h>

@interface ApolloMenuActionHandler : NSObject
@property (nonatomic, copy, nullable) void (^invoke)(UIAlertAction *action);
@end
@implementation ApolloMenuActionHandler
@end

static char kApolloMenuActionHandler;
static char kApolloPresentedActionMenuContexts;

BOOL ApolloActionMenuIsPresented(UIViewController *presenter) {
    NSHashTable<UIAlertController *> *contexts = objc_getAssociatedObject(presenter, &kApolloPresentedActionMenuContexts);
    return contexts.allObjects.count > 0;
}

UIAlertAction *ApolloMenuAction(NSString *title, UIAlertActionStyle style,
                                void (^handler)(UIAlertAction *action)) {
    UIAlertAction *action = [UIAlertAction actionWithTitle:title style:style handler:handler];
    ApolloMenuActionHandler *registered = [ApolloMenuActionHandler new];
    registered.invoke = handler;
    objc_setAssociatedObject(action, &kApolloMenuActionHandler, registered, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return action;
}

static ApolloMenuActionHandler *ApolloMenuHandler(UIAlertAction *action) {
    return objc_getAssociatedObject(action, &kApolloMenuActionHandler);
}

static UIView *ApolloMenuSource(UIViewController *presenter, UIAlertController *sheet, CGRect *rect) {
    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    UIView *source = popover.sourceView;
    *rect = popover.sourceRect;
    UIBarButtonItem *item = popover.barButtonItem;
    if (item) {
        if (item.customView.window) {
            source = item.customView;
            *rect = source.bounds;
        } else {
            // UIBarButtonItem exposes no public backing view. Use its owning
            // bar's public geometry rather than reading UIKit's private views.
            UINavigationController *navigation = presenter.navigationController;
            BOOL inToolbar = [presenter.toolbarItems containsObject:item];
            source = inToolbar ? navigation.toolbar : navigation.navigationBar;
            BOOL leading = [presenter.navigationItem.leftBarButtonItems containsObject:item];
            *rect = CGRectMake(leading ? 24.0 : MAX(0.0, source.bounds.size.width - 24.0),
                               CGRectGetMidY(source.bounds), 1.0, 1.0);
        }
    }
    if (!source.window) {
        source = presenter.view;
        *rect = CGRectMake(CGRectGetMidX(source.bounds), CGRectGetMidY(source.bounds), 1.0, 1.0);
    }
    return source;
}

void ApolloPresentActionMenu(UIViewController *presenter, UIAlertController *sheet) {
    if (sheet.preferredStyle != UIAlertControllerStyleActionSheet || !ApolloNativeActionMenusActive()) {
        [presenter presentViewController:sheet animated:YES completion:nil];
        return;
    }

    // This is an opt-in adapter for our own menus, not a global alert hook.
    // Fail closed to the original sheet if a future caller forgets to register
    // even one handler, rather than displaying an action that silently does nothing.
    for (UIAlertAction *action in sheet.actions) {
        if (!ApolloMenuHandler(action)) {
            ApolloLog(@"[ActionMenuPresenter] unregistered action; using original sheet");
            [presenter presentViewController:sheet animated:YES completion:nil];
            return;
        }
    }

    // Retain the original model through dismissal too: some callbacks keep a
    // weak reference to their sheet to distinguish a classic presentation.
    // The sheet never owns the UIMenu, so this does not create a cycle.
    UIAlertController *context = sheet;
    __block BOOL choseAction = NO;
    __weak UIViewController *weakPresenter = presenter;
    void (^afterDismissal)(dispatch_block_t) = ^(dispatch_block_t action) {
        dispatch_block_t retainedAction = ^{
            // The native presenter releases its menu before running the queued
            // callback. Keep weak-sheet references valid until that callback ends.
            __attribute__((objc_precise_lifetime)) UIAlertController *model = context;
            action();
            (void)model;
        };
        if (!ApolloNativeActionMenuPerformAfterDismissal(context, retainedAction)) {
            dispatch_async(dispatch_get_main_queue(), retainedAction);
        }
    };

    NSMutableArray<UIMenuElement *> *children = [NSMutableArray array];
    UIAlertAction *cancelAction = nil;
    for (UIAlertAction *action in sheet.actions) {
        if (action.style == UIAlertActionStyleCancel) {
            cancelAction = action;
            continue;
        }
        ApolloMenuActionHandler *handler = ApolloMenuHandler(action);
        NSString *title = action.title ?: @"";
        // Older mixed-action menus express toggle state in their title.
        // Display that state in the native checkmark column instead.
        BOOL checked = [title hasPrefix:@"✓ "] || [title hasSuffix:@" ✓"];
        if ([title hasPrefix:@"✓ "]) title = [title substringFromIndex:2];
        if ([title hasSuffix:@" ✓"]) title = [title substringToIndex:title.length - 2];
        UIAction *native = [UIAction actionWithTitle:title image:nil identifier:nil handler:^(__unused UIAction *selected) {
            choseAction = YES;
            afterDismissal(^{
                if (weakPresenter.viewIfLoaded.window && handler.invoke) handler.invoke(action);
            });
        }];
        native.attributes = (action.style == UIAlertActionStyleDestructive ? UIMenuElementAttributesDestructive : 0)
            | (action.enabled ? 0 : UIMenuElementAttributesDisabled);
        native.state = checked ? UIMenuElementStateOn : UIMenuElementStateOff;
        [children addObject:native];
    }

    NSString *title = sheet.title ?: @"";
    NSString *message = sheet.message;
    if (message.length) {
        if (title.length + message.length <= 180) {
            title = title.length ? [NSString stringWithFormat:@"%@\n%@", title, message] : message;
        } else {
            // A menu heading cannot reliably show a paragraph at every text
            // size. Keep the complete explanation readable in an ordinary alert.
            NSString *detailsTitle = sheet.title;
            UIAction *details = [UIAction actionWithTitle:@"Details…" image:[UIImage systemImageNamed:@"info.circle"]
                identifier:nil handler:^(__unused UIAction *selected) {
                choseAction = YES;
                afterDismissal(^{
                    UIViewController *owner = weakPresenter;
                    if (!owner.viewIfLoaded.window) return;
                    UIAlertController *info = [UIAlertController alertControllerWithTitle:detailsTitle
                        message:message preferredStyle:UIAlertControllerStyleAlert];
                    [info addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
                    [owner presentViewController:info animated:YES completion:nil];
                });
            }];
            UIMenu *actions = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:children];
            children = [NSMutableArray arrayWithObjects:actions,
                [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[details]], nil];
        }
    }

    UIMenu *menu = [UIMenu menuWithTitle:title children:children];
    NSHashTable<UIAlertController *> *contexts = objc_getAssociatedObject(presenter, &kApolloPresentedActionMenuContexts);
    if (!contexts) {
        // The native menu owns each model. Weak entries let abandoned queued
        // requests disappear without creating a presenter-to-model retain cycle.
        contexts = [NSHashTable weakObjectsHashTable];
        objc_setAssociatedObject(presenter, &kApolloPresentedActionMenuContexts, contexts, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [contexts addObject:context];
    dispatch_block_t didEnd = ^{
        // Native didEnd runs after the dismissal animation has completed.
        [contexts removeObject:context];
        // UIKit may signal willEnd before delivering a selected action. Defer
        // the cancellation decision one turn so picking cannot also cancel.
        dispatch_async(dispatch_get_main_queue(), ^{
            ApolloMenuActionHandler *handler = ApolloMenuHandler(cancelAction);
            if (!choseAction && handler.invoke) handler.invoke(cancelAction);
        });
    };
    CGRect rect;
    UIView *source = ApolloMenuSource(presenter, sheet, &rect);
    BOOL atPoint = !CGRectIsEmpty(rect) && !CGRectEqualToRect(rect, source.bounds);
    BOOL shown = atPoint
        ? ApolloNativeActionMenuPresentCapturedAtPoint(menu, source, CGPointMake(CGRectGetMidX(rect), CGRectGetMidY(rect)), context, didEnd)
        : ApolloNativeActionMenuPresentCaptured(menu, source, context, didEnd);
    if (shown) {
        ApolloLog(@"[ActionMenuPresenter] opened native menu (%lu actions)", (unsigned long)sheet.actions.count);
    } else {
        [contexts removeObject:context];
        [presenter presentViewController:sheet animated:YES completion:nil];
    }
}
