// True Black Keyboard (issue #148): paints the system keyboard's backdrop pure black for OLED.
//
// The keyboard is drawn in-process by UIKitCore, so we can restyle it from here. The backdrop
// (UIKBBackdropView, a UIVisualEffectView) loses its blur/glass effect and gets a black fill.
// Under a light-mode app the keyboard is also built with the dark render config so the keycaps
// and glyphs match the dark-mode keyboard. Which appearance(s) get this is a user mode
// (UDKeyTrueBlackKeyboardMode). All hooks fail soft — if UIKitCore renames a class the
// keyboard just looks stock.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "ApolloCommon.h"
#import "UserDefaultConstants.h"

// 0 Off, 1 Dark Only, 2 Light Only, 3 Always.
static BOOL TrueBlackKeyboardAppliesTo(UIUserInterfaceStyle style) {
    switch ([[NSUserDefaults standardUserDefaults] integerForKey:UDKeyTrueBlackKeyboardMode]) {
        case 1: return style == UIUserInterfaceStyleDark;
        case 2: return style != UIUserInterfaceStyleDark;
        case 3: return YES;
        default: return NO;
    }
}

// The app's own appearance (Apollo may override it per window), read from its first
// normal-level window; the keyboard's own traits follow the keyboard config, not the app.
static UIUserInterfaceStyle AppInterfaceStyle(void) {
    for (UIWindow *window in ApolloAllWindows()) {
        if (window.windowLevel == UIWindowLevelNormal) return window.traitCollection.userInterfaceStyle;
    }
    return UIUserInterfaceStyleUnspecified;
}

static const void *kEdgeFillKey = &kEdgeFillKey;
// Height left uncovered at the top so the keyboard's rounded top corners stay rounded.
static const CGFloat kTopCornerClearance = 44;

// The backdrop's edges are a hair tighter than the screen's (bottom corners, and the sides on
// some devices), so a sliver of the app can show at the edge of a black keyboard. A black strip
// behind the backdrop, extended a few points past the sides and bottom (the screen clips it),
// fills that. It starts below the top corners, so they keep their rounded shape.
// Auto Layout constraints rather than frame writes, so nothing here can loop during layout.
static void UpdateEdgeFill(UIVisualEffectView *backdrop, BOOL show) {
    UIView *fill = objc_getAssociatedObject(backdrop, kEdgeFillKey);
    if (!show) {
        fill.hidden = YES;
        return;
    }
    UIView *host = backdrop.superview;
    if (!host) return;
    if (!fill || fill.superview != host) {
        [fill removeFromSuperview];
        fill = [[UIView alloc] init];
        fill.backgroundColor = UIColor.blackColor;
        fill.userInteractionEnabled = NO;
        fill.translatesAutoresizingMaskIntoConstraints = NO;
        [host insertSubview:fill belowSubview:backdrop];
        [NSLayoutConstraint activateConstraints:@[
            [fill.leadingAnchor constraintEqualToAnchor:backdrop.leadingAnchor constant:-4],
            [fill.trailingAnchor constraintEqualToAnchor:backdrop.trailingAnchor constant:4],
            [fill.bottomAnchor constraintEqualToAnchor:backdrop.bottomAnchor constant:4],
            [fill.topAnchor constraintEqualToAnchor:backdrop.topAnchor constant:kTopCornerClearance],
        ]];
        objc_setAssociatedObject(backdrop, kEdgeFillKey, fill, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    fill.hidden = NO;
}

static void ApplyTrueBlack(UIVisualEffectView *backdrop) {
    BOOL applies = TrueBlackKeyboardAppliesTo(AppInterfaceStyle());
    UpdateEdgeFill(backdrop, applies);
    if (!applies) return;
    if (backdrop.effect) backdrop.effect = nil;
    backdrop.backgroundColor = UIColor.blackColor;
    backdrop.contentView.backgroundColor = UIColor.blackColor;
    for (UIView *sub in backdrop.subviews) {
        // Any private glass/blur layer view UIKit adds beside the content view.
        if (sub != backdrop.contentView) sub.hidden = YES;
    }
}

// Black backdrop under a light-mode app: the light keycaps/glyphs (emoji, mic, return key)
// would look wrong or vanish on black, so build the dark keyboard config instead.
%hook UIKBRenderConfig

+ (id)configForAppearance:(long long)appearance inputMode:(id)inputMode traitEnvironment:(id)traitEnvironment {
    if (appearance != UIKeyboardAppearanceDark &&
        TrueBlackKeyboardAppliesTo(AppInterfaceStyle()) && AppInterfaceStyle() != UIUserInterfaceStyleDark) {
        return %orig(UIKeyboardAppearanceDark, inputMode, traitEnvironment);
    }
    return %orig;
}

%end

%hook UIKBBackdropView

- (void)didMoveToWindow {
    %orig;
    ApplyTrueBlack((UIVisualEffectView *)self);
}

- (void)layoutSubviews {
    %orig;
    // Idempotent colour/effect writes only — no geometry, so no rotation loop.
    ApplyTrueBlack((UIVisualEffectView *)self);
}

- (void)_setRenderConfig:(id)config {
    %orig;
    ApplyTrueBlack((UIVisualEffectView *)self);
}

%end
