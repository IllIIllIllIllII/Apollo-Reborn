// ApolloComposerGlassToolbar.xm — the composer's markdown quick bar as a Liquid
// Glass capsule that scrolls sideways, like the Notes formatting bar.
//
// The bar above the keyboard in every composer (new comment, reply, new post,
// chat) is Apollo's QuickBarKeyboardView. Its icon buttons (photo, link, bold,
// italics, subreddit, user, more, plus the GIF chip ApolloMarkdownToolbarGif
// adds) sit in a horizontal UIStackView inside the bar's mainActionButtonsView,
// which Apollo hides while subreddit/user suggestions or the link actions show.
//
// On Liquid Glass builds this moves that stack, unchanged, into a scroll view
// inside a glass capsule placed where the stack was. Apollo's own buttons keep
// their targets, so the photo gating overlay, the GIF chip, the accent tint
// (ApolloComposerToolbarTint) and the ••• glass menu all keep working. The
// capsule lives inside mainActionButtonsView, so it hides with the buttons.
// Classic builds, and any bar whose structure doesn't match, keep the stock bar.
//
// The ••• menu's rows (Preview, Superscript, Quote, Spoiler, ... Text Faces)
// become buttons in the strip too, where ••• was. They are read from the sheet
// Apollo builds for that composer, so each composer shows its own rows. A tap
// captures a fresh ••• sheet without showing it and runs that row, which keeps
// Apollo's own handlers: Preview presents as usual, and rows that open a second
// sheet (Header sizes, Text Faces) open it as a glass menu on the tapped button.
// If any row can't be traced to one of Apollo's actions, ••• stays as it was.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "ApolloCommon.h"
#import "ApolloComposerGlassToolbar.h"
#import "ApolloNativeActionMenus.h"
#import "ApolloActionMenu.h"
#import "ApolloThemeRuntime.h"

static char kGlassToolbarInstalledKey;   // on the bar: @YES once the capsule is in
static char kGlassToolbarPendingKey;     // on the bar: an install is queued
static char kGlassToolbarGaveUpKey;      // on the bar: its structure doesn't match
static char kGlassToolbarAttemptsKey;    // on the bar: installs tried before the buttons existed
static char kGlassToolbarHostedKey;      // on the stack: it lives in the capsule

// Capsule geometry. 44 matches the keyboard bar's glass controls; the side
// margin matches the gap Notes leaves between its capsule and the screen edge.
static const CGFloat kGlassToolbarHeight = 44.0;
static const CGFloat kGlassToolbarSideMargin = 12.0;
static const CGFloat kGlassToolbarContentPadding = 6.0;
static const CGFloat kGlassToolbarItemSpacing = 6.0;
static const CGFloat kGlassToolbarMinimumItemWidth = 40.0;
// Layout passes to wait for Apollo to build the buttons before giving up.
static const NSInteger kGlassToolbarMaxAttempts = 30;

BOOL ApolloComposerGlassToolbarHostsStack(UIStackView *stack) {
    return stack && [objc_getAssociatedObject(stack, &kGlassToolbarHostedKey) boolValue];
}

@interface ApolloComposerGlassScrollView : UIScrollView
@end

@implementation ApolloComposerGlassScrollView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.showsHorizontalScrollIndicator = NO;
        self.showsVerticalScrollIndicator = NO;
        self.alwaysBounceHorizontal = YES;
        self.alwaysBounceVertical = NO;
        self.directionalLockEnabled = YES;
        // Buttons highlight on touch down, as in Notes, and a drag that starts
        // on one still scrolls the bar.
        self.delaysContentTouches = NO;
        self.canCancelContentTouches = YES;
        // A status bar tap belongs to the composer's text, not this strip.
        self.scrollsToTop = NO;
        self.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
        self.clipsToBounds = YES;
        self.backgroundColor = UIColor.clearColor;
    }
    return self;
}

- (BOOL)touchesShouldCancelInContentView:(UIView *)view {
    return YES;
}

@end

// A bar that can't take the capsule keeps the stock look and is not retried.
static void ApolloGlassToolbarGiveUp(UIView *bar, NSString *reason) {
    objc_setAssociatedObject(bar, &kGlassToolbarGaveUpKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloLog(@"[ComposerGlass] kept the stock bar: %@", reason);
}

// Apollo builds the buttons after the bar reaches the window on some paths.
static void ApolloGlassToolbarRetryLater(UIView *bar, NSString *waitingFor) {
    NSInteger attempts = [objc_getAssociatedObject(bar, &kGlassToolbarAttemptsKey) integerValue] + 1;
    objc_setAssociatedObject(bar, &kGlassToolbarAttemptsKey, @(attempts), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (attempts >= kGlassToolbarMaxAttempts) {
        ApolloGlassToolbarGiveUp(bar, [NSString stringWithFormat:@"still waiting for %@ after %ld layout passes",
                                       waitingFor, (long)attempts]);
    }
}

static BOOL ApolloGlassToolbarViewHasControl(UIView *view) {
    if ([view isKindOfClass:UIControl.class]) return YES;
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:UIControl.class]) return YES;
    }
    return NO;
}

// The horizontal stack with the most button slots under `root`. The suggestion
// strip is a collection view whose cells Apollo owns; never look inside it.
static UIStackView *ApolloGlassToolbarFindButtonStack(UIView *root) {
    UIStackView *best = nil;
    NSUInteger bestCount = 0;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    NSUInteger budget = 256;
    while (queue.count > 0 && budget-- > 0) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if ([view isKindOfClass:UICollectionView.class]) continue;
        if ([view isKindOfClass:UIStackView.class]) {
            UIStackView *stack = (UIStackView *)view;
            NSUInteger controls = 0;
            for (UIView *arranged in stack.arrangedSubviews) {
                if (ApolloGlassToolbarViewHasControl(arranged)) controls++;
            }
            if (stack.axis == UILayoutConstraintAxisHorizontal && controls >= 3 && controls > bestCount) {
                best = stack;
                bestCount = controls;
            }
        }
        [queue addObjectsFromArray:view.subviews];
    }
    return best;
}

// Apollo's container for the shortcut buttons (the GIF module anchors to the
// same property), which it hides while suggestions or link actions show.
static UIView *ApolloGlassToolbarActionsView(UIView *bar) {
    SEL selector = @selector(mainActionButtonsView);
    if (![bar respondsToSelector:selector]) return nil;
    id actions = ((id (*)(id, SEL))objc_msgSend)(bar, selector);
    return [actions isKindOfClass:UIView.class] ? actions : nil;
}

// Apollo's hairline along the top of the bar. The capsule floats on its own.
static void ApolloGlassToolbarHideHairline(UIView *bar, UIView *keep) {
    CGFloat width = CGRectGetWidth(bar.bounds);
    if (width <= 0.0) return;
    BOOL found = NO;
    for (UIView *subview in bar.subviews) {
        if (subview == keep || [keep isDescendantOfView:subview]) continue;
        CGRect frame = subview.frame;
        if (CGRectGetHeight(frame) > 0.0 && CGRectGetHeight(frame) <= 1.0
            && CGRectGetWidth(frame) >= width * 0.8 && subview.subviews.count == 0) {
            subview.hidden = YES;
            found = YES;
            ApolloLog(@"[ComposerGlass] hid the bar's top hairline (%@)", NSStringFromClass(subview.class));
        }
    }
    if (!found) ApolloLog(@"[ComposerGlass] no top hairline among the bar's %lu subviews", (unsigned long)bar.subviews.count);
}

#pragma mark - Inline ••• rows

// Apollo's ••• control among the stack's slots, and the slot holding it.
static UIControl *ApolloGlassToolbarMoreControl(UIView *bar, UIStackView *stack, UIView **outSlot) {
    NSString *moreAction = NSStringFromSelector(@selector(moreButtonTapped:));
    for (UIView *arranged in stack.arrangedSubviews) {
        NSMutableArray<UIView *> *candidates = [NSMutableArray arrayWithObject:arranged];
        [candidates addObjectsFromArray:arranged.subviews];
        for (UIView *candidate in candidates) {
            if (![candidate isKindOfClass:UIControl.class]) continue;
            UIControl *control = (UIControl *)candidate;
            BOOL more = [[control actionsForTarget:bar forControlEvent:UIControlEventTouchUpInside] containsObject:moreAction]
                || [control.accessibilityLabel isEqualToString:@"More actions"];
            if (!more) continue;
            if (outSlot) *outSlot = arranged;
            return control;
        }
    }
    return nil;
}

// Apollo's ••• handler. Under a capture it builds the sheet without showing it.
static void ApolloGlassToolbarRunMore(UIView *bar, id sender) {
    SEL selector = @selector(moreButtonTapped:);
    if ([bar respondsToSelector:selector]) ((void (*)(id, SEL, id))objc_msgSend)(bar, selector, sender);
}

// The rows of a captured ••• menu in order, inline sections flattened. Nil when
// a row isn't one of Apollo's actions (a submenu, or a row another feature
// adds), since only Apollo's actions can be run again from a fresh sheet.
static NSArray<UIAction *> *ApolloGlassToolbarMenuRows(UIMenu *menu, NSString **outUnmapped) {
    NSMutableArray<UIAction *> *rows = [NSMutableArray array];
    NSMutableArray<UIMenuElement *> *pending = [menu.children mutableCopy] ?: [NSMutableArray array];
    while (pending.count > 0) {
        UIMenuElement *element = pending.firstObject;
        [pending removeObjectAtIndex:0];
        if ([element isKindOfClass:UIMenu.class] && (((UIMenu *)element).options & UIMenuOptionsDisplayInline)) {
            NSArray *children = ((UIMenu *)element).children;
            [pending replaceObjectsInRange:NSMakeRange(0, 0) withObjectsFromArray:children];
            continue;
        }
        if (![element isKindOfClass:UIAction.class] || ApolloActionMenuNativeKindForElement(element) == NSNotFound) {
            if (outUnmapped) *outUnmapped = element.title ?: NSStringFromClass(element.class);
            return nil;
        }
        [rows addObject:(UIAction *)element];
    }
    return rows;
}

static UIAction *ApolloGlassToolbarRowOfKind(UIMenu *menu, NSUInteger kind) {
    for (UIAction *row in ApolloGlassToolbarMenuRows(menu, NULL)) {
        if (ApolloActionMenuNativeKindForElement(row) == kind) return row;
    }
    return nil;
}

// One inline button's tap: a fresh ••• sheet for the composer as it is now,
// anchored to this button, then that row, as if picked from the menu.
static void ApolloGlassToolbarRunInline(UIView *bar, UIButton *button, NSUInteger kind, NSString *title) {
    if (!bar || !button.window) return;
    id controller = ApolloNativeActionMenuCaptureController(button, ^{
        ApolloGlassToolbarRunMore(bar, button);
    });
    UIMenu *menu = controller ? ApolloNativeActionMenuBuildCaptured(controller) : nil;
    UIAction *row = ApolloGlassToolbarRowOfKind(menu, kind);
    if (row && (row.attributes & UIMenuElementAttributesDisabled)) {
        ApolloLog(@"[ComposerGlass] %@ is disabled right now", title);
        return;
    }
    if (row && ApolloNativeActionMenuHasAction(controller, (uint16_t)kind)) {
        ApolloLog(@"[ComposerGlass] %@ (kind %lu)", title, (unsigned long)kind);
        ApolloNativeActionMenuInvokeAction(controller, (uint16_t)kind);
        return;
    }
    // The row is gone from this sheet: show the whole menu on the button.
    ApolloLog(@"[ComposerGlass] %@ (kind %lu) not in the ••• sheet now (sheet=%@); opening the menu",
              title, (unsigned long)kind, controller ? @"captured" : @"none");
    ApolloGlassToolbarRunMore(bar, button);
}

static UIButton *ApolloGlassToolbarMakeInlineButton(UIView *bar, UIAction *row) {
    NSUInteger kind = ApolloActionMenuNativeKindForElement(row);
    NSString *title = [row.title copy];
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setImage:[row.image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] forState:UIControlStateNormal];
    // ApolloComposerToolbarTint keeps every icon in the bar on the accent.
    button.tintColor = ApolloThemeAccentColor() ?: bar.tintColor;
    button.accessibilityLabel = title;
    button.largeContentTitle = title;
    button.showsLargeContentViewer = YES;
    __weak UIView *weakBar = bar;
    __weak UIButton *weakButton = button;
    [button addAction:[UIAction actionWithHandler:^(__unused UIAction *action) {
        ApolloGlassToolbarRunInline(weakBar, weakButton, kind, title);
    }] forControlEvents:UIControlEventTouchUpInside];
    return button;
}

// Put the ••• rows in the strip where ••• was, then hide •••.
static void ApolloGlassToolbarInlineMoreRows(UIView *bar, UIStackView *stack) {
    UIView *moreSlot = nil;
    UIControl *more = ApolloGlassToolbarMoreControl(bar, stack, &moreSlot);
    if (!more || ![bar respondsToSelector:@selector(moreButtonTapped:)]) {
        ApolloLog(@"[ComposerGlass] no ••• button found; nothing to inline");
        return;
    }
    id controller = ApolloNativeActionMenuCaptureController(more, ^{
        ApolloGlassToolbarRunMore(bar, more);
    });
    UIMenu *menu = controller ? ApolloNativeActionMenuBuildCaptured(controller) : nil;
    NSString *unmapped = nil;
    NSArray<UIAction *> *rows = menu ? ApolloGlassToolbarMenuRows(menu, &unmapped) : nil;
    if (rows.count == 0) {
        ApolloLog(@"[ComposerGlass] kept •••: %@", !controller ? @"its sheet wasn't captured"
                  : !menu ? @"its sheet had no rows"
                  : [NSString stringWithFormat:@"row \"%@\" isn't one of Apollo's actions", unmapped]);
        return;
    }
    NSUInteger index = [stack.arrangedSubviews indexOfObject:moreSlot];
    if (index == NSNotFound) index = stack.arrangedSubviews.count;
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    for (UIAction *row in rows) {
        [stack insertArrangedSubview:ApolloGlassToolbarMakeInlineButton(bar, row) atIndex:index++];
        [titles addObject:row.title ?: @"?"];
    }
    moreSlot.hidden = YES;
    ApolloLog(@"[ComposerGlass] inlined %lu ••• rows: %@", (unsigned long)rows.count, [titles componentsJoinedByString:@", "]);
}

#pragma mark - Install

static void ApolloGlassToolbarInstall(UIView *bar) API_AVAILABLE(ios(26.0)) {
    if (!bar.window || [objc_getAssociatedObject(bar, &kGlassToolbarInstalledKey) boolValue]) return;

    UIView *actions = ApolloGlassToolbarActionsView(bar);
    if (!actions) {
        ApolloGlassToolbarGiveUp(bar, @"no mainActionButtonsView");
        return;
    }
    UIStackView *stack = ApolloGlassToolbarFindButtonStack(actions);
    if (!stack) {
        ApolloGlassToolbarRetryLater(bar, @"the button stack");
        return;
    }
    UIView *host = stack.superview;
    // The capsule must sit inside the container Apollo hides, or it would stay
    // on screen, empty, while the suggestions show.
    if (stack == actions || !host || !(host == actions || [host isDescendantOfView:actions])) {
        ApolloGlassToolbarGiveUp(bar, [NSString stringWithFormat:@"button stack is not inside its container (stack=%@ actions=%@)",
                                       NSStringFromClass(stack.class), NSStringFromClass(actions.class)]);
        return;
    }
    // A parent stack would lay the capsule out as one of its own items.
    if ([host isKindOfClass:UIStackView.class]) {
        ApolloGlassToolbarGiveUp(bar, @"button stack is nested in another stack");
        return;
    }
    // The capsule's height comes from the container's; wait for a laid-out one.
    if (CGRectGetHeight(host.bounds) < 24.0) {
        ApolloGlassToolbarRetryLater(bar, @"a laid-out container");
        return;
    }

    ApolloLog(@"[ComposerGlass] stack before: %lu items distribution=%ld spacing=%.1f size=%.0fx%.0f host=%@ %.0fx%.0f bar=%.0fx%.0f",
              (unsigned long)stack.arrangedSubviews.count, (long)stack.distribution, stack.spacing,
              CGRectGetWidth(stack.bounds), CGRectGetHeight(stack.bounds), NSStringFromClass(host.class),
              CGRectGetWidth(host.bounds), CGRectGetHeight(host.bounds), CGRectGetWidth(bar.bounds), CGRectGetHeight(bar.bounds));

    UIGlassEffect *effect = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
    UIVisualEffectView *glass = [[UIVisualEffectView alloc] initWithEffect:effect];
    glass.translatesAutoresizingMaskIntoConstraints = NO;
    glass.cornerConfiguration = [UICornerConfiguration capsuleConfiguration];
    glass.clipsToBounds = YES;
    glass.accessibilityIdentifier = @"apollo.composerGlassToolbar";

    ApolloComposerGlassScrollView *scroller = [[ApolloComposerGlassScrollView alloc] initWithFrame:CGRectZero];
    [glass.contentView addSubview:scroller];

    // Removing the stack drops only its constraints to the old surroundings;
    // the buttons, their targets and constraints inside the stack all move with it.
    NSUInteger index = [host.subviews indexOfObject:stack];
    [stack removeFromSuperview];
    [host insertSubview:glass atIndex:MIN(index, host.subviews.count)];
    [scroller addSubview:stack];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    objc_setAssociatedObject(stack, &kGlassToolbarHostedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // Size the strip to its buttons instead of the bar's width: even slots,
    // a fixed gap, and room to scroll when they don't fit.
    stack.distribution = UIStackViewDistributionFillEqually;
    stack.spacing = kGlassToolbarItemSpacing;
    ApolloGlassToolbarInlineMoreRows(bar, stack);
    NSMutableArray<NSLayoutConstraint *> *constraints = [NSMutableArray array];
    for (UIView *arranged in stack.arrangedSubviews) {
        NSLayoutConstraint *minimum = [arranged.widthAnchor constraintGreaterThanOrEqualToConstant:kGlassToolbarMinimumItemWidth];
        minimum.priority = UILayoutPriorityRequired - 1;
        [constraints addObject:minimum];
    }

    UILayoutGuide *safe = host.safeAreaLayoutGuide;
    NSLayoutConstraint *height = [glass.heightAnchor constraintEqualToConstant:kGlassToolbarHeight];
    height.priority = UILayoutPriorityDefaultHigh;
    [constraints addObjectsFromArray:@[
        [glass.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:kGlassToolbarSideMargin],
        [glass.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-kGlassToolbarSideMargin],
        [glass.centerYAnchor constraintEqualToAnchor:host.centerYAnchor],
        [glass.heightAnchor constraintLessThanOrEqualToAnchor:host.heightAnchor constant:-2.0],
        height,
        [scroller.leadingAnchor constraintEqualToAnchor:glass.contentView.leadingAnchor],
        [scroller.trailingAnchor constraintEqualToAnchor:glass.contentView.trailingAnchor],
        [scroller.topAnchor constraintEqualToAnchor:glass.contentView.topAnchor],
        [scroller.bottomAnchor constraintEqualToAnchor:glass.contentView.bottomAnchor],
    ]];

    // The content is the stack plus padding, but never narrower than the
    // capsule: a strip that fits sits centered, one that doesn't scrolls from
    // its leading end.
    UILayoutGuide *content = scroller.contentLayoutGuide;
    UILayoutGuide *frame = scroller.frameLayoutGuide;
    NSLayoutConstraint *hug = [content.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:2.0 * kGlassToolbarContentPadding];
    hug.priority = UILayoutPriorityDefaultLow;
    [constraints addObjectsFromArray:@[
        [stack.topAnchor constraintEqualToAnchor:content.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
        [stack.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
        [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:content.leadingAnchor constant:kGlassToolbarContentPadding],
        [stack.trailingAnchor constraintLessThanOrEqualToAnchor:content.trailingAnchor constant:-kGlassToolbarContentPadding],
        [content.heightAnchor constraintEqualToAnchor:frame.heightAnchor],
        [content.widthAnchor constraintGreaterThanOrEqualToAnchor:frame.widthAnchor],
        hug,
    ]];
    [NSLayoutConstraint activateConstraints:constraints];

    ApolloGlassToolbarHideHairline(bar, actions);
    objc_setAssociatedObject(bar, &kGlassToolbarInstalledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [bar layoutIfNeeded];
    ApolloLog(@"[ComposerGlass] installed: capsule=%.0fx%.0f content=%.0f items=%lu",
              CGRectGetWidth(glass.bounds), CGRectGetHeight(glass.bounds), scroller.contentSize.width,
              (unsigned long)stack.arrangedSubviews.count);
}

// Installing moves views and adds constraints, so it never runs inside the
// bar's own layout pass: queue it for the next turn of the run loop.
static void ApolloGlassToolbarScheduleInstall(UIView *bar) {
    if (!bar.window || [objc_getAssociatedObject(bar, &kGlassToolbarInstalledKey) boolValue]
        || [objc_getAssociatedObject(bar, &kGlassToolbarGaveUpKey) boolValue]
        || [objc_getAssociatedObject(bar, &kGlassToolbarPendingKey) boolValue]) return;
    objc_setAssociatedObject(bar, &kGlassToolbarPendingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIView *weakBar = bar;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *strongBar = weakBar;
        if (!strongBar) return;
        objc_setAssociatedObject(strongBar, &kGlassToolbarPendingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (@available(iOS 26.0, *)) ApolloGlassToolbarInstall(strongBar);
    });
}

%group ApolloComposerGlassToolbarHooks

%hook _TtC6Apollo20QuickBarKeyboardView

- (void)didMoveToWindow {
    %orig;
    ApolloGlassToolbarScheduleInstall((UIView *)self);
}

// The buttons can arrive after the bar reaches the window. Until the capsule
// is in, each layout pass queues one more try; afterwards this is a flag read.
- (void)layoutSubviews {
    %orig;
    ApolloGlassToolbarScheduleInstall((UIView *)self);
}

%end

%end

%ctor {
    if (@available(iOS 26.0, *)) {
        if (!IsLiquidGlass()) return;
        if (!objc_getClass("_TtC6Apollo20QuickBarKeyboardView")) {
            ApolloLog(@"[ComposerGlass] QuickBarKeyboardView missing; glass composer bar off");
            return;
        }
        %init(ApolloComposerGlassToolbarHooks);
        ApolloLog(@"[ComposerGlass] glass composer bar hooks installed");
    }
}
