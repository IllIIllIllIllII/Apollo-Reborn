// ApolloTabBarStyle — Inbox badge style and the classic inactive tab icon tint.
//
// UIKit keeps owning badge and icon geometry, tab transitions, and
// accessibility. The only layout-time work is placing the unread dot, which
// looks up the tab icons under the badge's own tab platter or bar.
//
// Inbox badge. ApolloChatsFilter keeps Apollo's real value and routes every
// Inbox badge write through ApolloInboxBadgeDisplayValue; dot mode displays
// it as @"". Neither tab bar honors UITabBarItem.badgeColor or the
// appearance badge colors for Apollo's badge (verified on the iOS 27 sim),
// so the style is applied by the badge view itself — _UIBadgeView (classic)
// and _UIBarBadgeView (Liquid Glass) — at the setters UIKit already calls:
//   - setBadgeColor: (UIKit re-sends red on every tab switch) swaps in the
//     accent and the matching black/white text;
//   - traitCollectionDidChange: re-resolves both, as the badge caches them;
//   - an empty badge is drawn as a dot, centered on its tab icon's top-right
//     corner in setFrame:. The glass badge is sized down in sizeThatFits:;
//     the classic badge's shape is a stretched image, so it keeps UIKit's
//     size and is masked to a circle at its center.
// Apollo badges only the Inbox tab, so every tab badge is styled. On the Duo
// side rail the glass tab platter is hosted outside UITabBar, so a badge
// counts as a tab badge when it sits in either.
//
// Inactive icon tint (classic). Apollo supplies its tab icons pre-colored
// (AlwaysOriginal: grey unselected, accent selected), so UIKit's tint
// properties never reach them. With the tint on, unselected images are
// templated and the tab bar appearances' normal-state iconColor carries the
// muted accent; selected images, titles, and the profile avatar icon are
// untouched. Turning it off restores Apollo's images and clears the color.

#import "ApolloTabBarStyle.h"

#import <objc/runtime.h>

#import "ApolloClasses.h"
#import "ApolloCommon.h"
#import "ApolloState.h"
#import "ApolloThemeRuntime.h"
#import "UserDefaultConstants.h"

#define TabBarStyleLog(fmt, ...) ApolloLog(@"[TabBarStyle] " fmt, ##__VA_ARGS__)

static NSString *const kApolloThemeChangedNotification = @"com.christianselig.ApolloSpecificThemeChanged";

static void ApolloTabBarCollectViews(UIView *view, Class cls, NSMutableArray *result) {
    if ([view isKindOfClass:cls]) {
        [result addObject:view];
        return;
    }
    for (UIView *subview in view.subviews) ApolloTabBarCollectViews(subview, cls, result);
}

static NSArray<UITabBar *> *ApolloTabBarAllTabBars(void) {
    NSMutableArray<UITabBar *> *tabBars = [NSMutableArray array];
    for (UIWindow *window in ApolloAllWindows()) ApolloTabBarCollectViews(window, UITabBar.class, tabBars);
    return tabBars;
}

#pragma mark - Inbox badge

NSString *ApolloInboxBadgeDisplayValue(NSString *value) {
    if (sInboxBadgeShowUnreadCount || value.length == 0) return value;
    return @"";
}

// The private badge views, declared for the setters both classes share.
@interface ApolloTabBadgeView : UIView
- (NSString *)text;
- (UIColor *)badgeColor;
- (void)setBadgeColor:(UIColor *)color;
- (NSDictionary *)textAttributes;
- (void)setTextAttributes:(NSDictionary *)attributes;
- (UIColor *)textColor;
- (void)setTextColor:(UIColor *)color;
@end

static const CGFloat kApolloTabBadgeDotSize = 10.0;
static char kApolloTabBadgeUIKitFillKey;
static char kApolloTabBadgeUIKitInkKey;
static BOOL sApolloTabBadgeApplying;

// The view the badge's tab buttons live under: the glass tab platter (inside
// UITabBar, or hosted beside it on the Duo side rail), else the classic UITabBar.
static UIView *ApolloTabBadgeHost(UIView *badge) {
    Class platterClass = ApolloClassUITabBarItemPlatterView;
    for (UIView *view = badge.superview; view; view = view.superview) {
        if (platterClass && [view isKindOfClass:platterClass]) return view;
        if ([view isKindOfClass:UITabBar.class]) return view;
    }
    return nil;
}

static BOOL ApolloTabBadgeIsInTabBar(UIView *badge) {
    return ApolloTabBadgeHost(badge) != nil;
}

static UIImageView *ApolloTabBadgeButtonIcon(UIView *view) {
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:UIImageView.class] && ((UIImageView *)subview).image) return (UIImageView *)subview;
        UIImageView *nested = ApolloTabBadgeButtonIcon(subview);
        if (nested) return nested;
    }
    return nil;
}

static void ApolloTabBadgeCollectButtons(UIView *view, NSMutableArray<UIView *> *buttons) {
    if ((ApolloClassUITabButton && [view isKindOfClass:ApolloClassUITabButton]) ||
        (ApolloClassUITabBarButton && [view isKindOfClass:ApolloClassUITabBarButton])) {
        [buttons addObject:view];
        return;
    }
    for (UIView *subview in view.subviews) ApolloTabBadgeCollectButtons(subview, buttons);
}

// The top-right corner of the tab icon nearest to `reference`, both in
// `space` coordinates. NO when the host has no icons yet.
static BOOL ApolloTabBadgeIconCorner(UIView *badge, UIView *space, CGPoint reference, CGPoint *outCorner) {
    UIView *host = ApolloTabBadgeHost(badge);
    if (!host || !space) return NO;
    NSMutableArray<UIView *> *buttons = [NSMutableArray array];
    ApolloTabBadgeCollectButtons(host, buttons);

    BOOL found = NO;
    CGFloat best = CGFLOAT_MAX;
    for (UIView *button in buttons) {
        UIImageView *icon = ApolloTabBadgeButtonIcon(button);
        if (!icon) continue;
        CGRect frame = [icon convertRect:icon.bounds toView:space];
        CGPoint corner = CGPointMake(CGRectGetMaxX(frame), CGRectGetMinY(frame));
        CGFloat distance = hypot(corner.x - reference.x, corner.y - reference.y);
        if (distance < best) {
            best = distance;
            *outCorner = corner;
            found = YES;
        }
    }
    return found;
}

static BOOL ApolloTabBadgeShowsDot(ApolloTabBadgeView *badge) {
    return badge.text.length == 0 && ApolloTabBadgeIsInTabBar(badge);
}

// UIKit's proposed frame, moved so the dot is centered on the icon's corner.
// A glass dot never rises above UIKit's top: ApolloLiquidGlass.xm keeps glass
// badges at y >= 6 so the scaled selected-tab copy doesn't clip them.
static CGRect ApolloTabBadgeDotFrame(ApolloTabBadgeView *badge, CGRect proposed, BOOL glass) {
    if (!ApolloTabBadgeShowsDot(badge) || !badge.superview) return proposed;
    CGPoint corner;
    CGPoint reference = CGPointMake(CGRectGetMidX(proposed), CGRectGetMidY(proposed));
    if (!ApolloTabBadgeIconCorner(badge, badge.superview, reference, &corner)) return proposed;
    CGSize size = proposed.size;
    CGFloat y = corner.y - size.height / 2.0;
    if (glass) y = MAX(y, CGRectGetMinY(proposed));
    return CGRectMake(corner.x - size.width / 2.0, y, size.width, size.height);
}

static UIColor *ApolloTabBadgeAccent(UITraitCollection *traits) {
    return [(ApolloThemeAccentColor() ?: UIColor.systemRedColor) resolvedColorWithTraitCollection:traits];
}

// Glass badges take a text color; classic badges take text attributes.
static UIColor *ApolloTabBadgeInk(ApolloTabBadgeView *badge) {
    if ([badge respondsToSelector:@selector(textColor)]) return badge.textColor;
    return badge.textAttributes[NSForegroundColorAttributeName];
}

static void ApolloTabBadgeSetInk(ApolloTabBadgeView *badge, UIColor *ink, NSDictionary *uikitAttributes) {
    if ([badge respondsToSelector:@selector(setTextColor:)]) {
        badge.textColor = ink;
        return;
    }
    NSMutableDictionary *attributes = [uikitAttributes ?: @{} mutableCopy];
    if (ink) attributes[NSForegroundColorAttributeName] = ink;
    else [attributes removeObjectForKey:NSForegroundColorAttributeName];
    badge.textAttributes = attributes;
}

// Applies the accent (resolved for the badge's own traits) or puts UIKit's
// last values back. UIKit's values are recorded by the setter hooks.
static void ApolloTabBadgeApply(ApolloTabBadgeView *badge) {
    if (!ApolloTabBadgeIsInTabBar(badge)) return;

    BOOL glass = [badge respondsToSelector:@selector(setTextColor:)];
    id uikitFill = objc_getAssociatedObject(badge, &kApolloTabBadgeUIKitFillKey);
    id uikitInk = objc_getAssociatedObject(badge, &kApolloTabBadgeUIKitInkKey);
    if (!uikitFill) uikitFill = badge.badgeColor;
    if (!uikitInk) {
        uikitInk = glass ? badge.textColor : badge.textAttributes;
        if (uikitInk) objc_setAssociatedObject(badge, &kApolloTabBadgeUIKitInkKey, uikitInk, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    UIColor *fill = uikitFill;
    UIColor *ink = glass ? uikitInk : ((NSDictionary *)uikitInk)[NSForegroundColorAttributeName];
    if (sInboxBadgeUseThemeAccent) {
        fill = ApolloTabBadgeAccent(badge.traitCollection);
        ink = ApolloColorIsLight(fill) ? UIColor.blackColor : UIColor.whiteColor;
    }

    sApolloTabBadgeApplying = YES;
    if (fill && ![badge.badgeColor isEqual:fill]) badge.badgeColor = fill;
    if (![ApolloTabBadgeInk(badge) isEqual:ink]) {
        ApolloTabBadgeSetInk(badge, ink, glass ? nil : uikitInk);
    }
    sApolloTabBadgeApplying = NO;
}

static void ApolloTabBadgeRecordFill(ApolloTabBadgeView *badge, UIColor *color) {
    if (sApolloTabBadgeApplying) return;
    objc_setAssociatedObject(badge, &kApolloTabBadgeUIKitFillKey, color, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (sInboxBadgeUseThemeAccent) ApolloTabBadgeApply(badge);
}

static void ApolloTabBadgeRecordInk(ApolloTabBadgeView *badge, id inkOrAttributes) {
    if (sApolloTabBadgeApplying) return;
    objc_setAssociatedObject(badge, &kApolloTabBadgeUIKitInkKey, inkOrAttributes, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (sInboxBadgeUseThemeAccent) ApolloTabBadgeApply(badge);
}

// The classic dot: a circle mask at the center of UIKit's badge, which
// setFrame: has centered on the icon's corner.
static void ApolloTabBadgeUpdateClassicDotMask(ApolloTabBadgeView *badge) {
    if (!ApolloTabBadgeShowsDot(badge)) {
        if (badge.maskView) badge.maskView = nil;
        return;
    }
    CGFloat half = kApolloTabBadgeDotSize / 2.0;
    UIView *mask = badge.maskView ?: [[UIView alloc] init];
    mask.backgroundColor = UIColor.blackColor;
    mask.layer.cornerRadius = half;
    mask.frame = CGRectMake(CGRectGetMidX(badge.bounds) - half, CGRectGetMidY(badge.bounds) - half,
                            kApolloTabBadgeDotSize, kApolloTabBadgeDotSize);
    if (badge.maskView != mask) badge.maskView = mask;
}

static CGSize ApolloTabBadgeFittedSize(ApolloTabBadgeView *badge, CGSize fitted) {
    if (ApolloTabBadgeShowsDot(badge)) {
        return CGSizeMake(kApolloTabBadgeDotSize, kApolloTabBadgeDotSize);
    }
    return fitted;
}

// Walks whole windows: the Duo side rail's badges are outside UITabBar.
static void ApolloTabBadgeRefreshAll(void) {
    Class badgeClass = IsLiquidGlass() ? ApolloClassUIBarBadgeView : ApolloClassUIBadgeView;
    if (!badgeClass) return;
    NSMutableArray<ApolloTabBadgeView *> *badges = [NSMutableArray array];
    for (UIWindow *window in ApolloAllWindows()) ApolloTabBarCollectViews(window, badgeClass, badges);
    for (ApolloTabBadgeView *badge in badges) {
        if (!ApolloTabBadgeIsInTabBar(badge)) continue;
        ApolloTabBadgeApply(badge);
        [badge invalidateIntrinsicContentSize];
        [badge setNeedsLayout];
        [badge.superview setNeedsLayout];
    }
}

%group ApolloTabBadgeClassic

%hook _UIBadgeView

- (void)setBadgeColor:(UIColor *)color {
    %orig;
    ApolloTabBadgeRecordFill((ApolloTabBadgeView *)self, color);
}

- (void)setTextAttributes:(NSDictionary *)attributes {
    %orig;
    ApolloTabBadgeRecordInk((ApolloTabBadgeView *)self, attributes);
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    %orig;
    if (sInboxBadgeUseThemeAccent) ApolloTabBadgeApply((ApolloTabBadgeView *)self);
}

- (void)setFrame:(CGRect)frame {
    %orig(ApolloTabBadgeDotFrame((ApolloTabBadgeView *)self, frame, NO));
}

// The mask view sits outside the hierarchy, so sizing it here drives no layout.
- (void)layoutSubviews {
    %orig;
    ApolloTabBadgeUpdateClassicDotMask((ApolloTabBadgeView *)self);
}

%end

%end

%group ApolloTabBadgeGlass

%hook _UIBarBadgeView

- (void)setBadgeColor:(UIColor *)color {
    %orig;
    ApolloTabBadgeRecordFill((ApolloTabBadgeView *)self, color);
}

- (void)setTextColor:(UIColor *)color {
    %orig;
    ApolloTabBadgeRecordInk((ApolloTabBadgeView *)self, color);
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    %orig;
    if (sInboxBadgeUseThemeAccent) ApolloTabBadgeApply((ApolloTabBadgeView *)self);
}

- (CGSize)sizeThatFits:(CGSize)size {
    return ApolloTabBadgeFittedSize((ApolloTabBadgeView *)self, %orig);
}

- (void)setFrame:(CGRect)frame {
    %orig(ApolloTabBadgeDotFrame((ApolloTabBadgeView *)self, frame, YES));
}

%end

%end

#pragma mark - Inactive icon tint (classic)

static CGFloat ApolloTabBarLinearComponent(CGFloat value) {
    return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4);
}

static CGFloat ApolloTabBarLuminance(UIColor *color) {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if (![color getRed:&r green:&g blue:&b alpha:&a]) return 0;
    return 0.2126 * ApolloTabBarLinearComponent(r)
         + 0.7152 * ApolloTabBarLinearComponent(g)
         + 0.0722 * ApolloTabBarLinearComponent(b);
}

// A muted shade of the accent: its hue shifted 10 degrees, saturation cut to
// 30% (20% around green), at a luminance tied to the accent's. Returns nil
// for an achromatic accent (Monochromatic, Fisher King, Chumbus): there is no
// hue to mute, and the formula would land on the selected color itself.
static UIColor *ApolloInactiveTabIconColor(UITraitCollection *traits) {
    UIColor *accent = [ApolloThemeAccentColor() resolvedColorWithTraitCollection:traits];
    CGFloat r = 0, g = 0, b = 0, alpha = 0;
    if (!accent || ![accent getRed:&r green:&g blue:&b alpha:&alpha]) return nil;
    if (MAX(r, MAX(g, b)) - MIN(r, MIN(g, b)) < 0.08) return nil;

    CGFloat hue = 0, saturation = 0, brightness = 0;
    [accent getHue:&hue saturation:&saturation brightness:&brightness alpha:&alpha];

    BOOL dark = traits.userInterfaceStyle == UIUserInterfaceStyleDark;
    CGFloat target = ApolloTabBarLuminance(accent) * (0.287441 / 0.248283) * (dark ? 0.85 : 1.20);
    // On a light bar, stay at least 2.5:1 against white so pale accents
    // (Skies on Skies, Mint) don't fade out.
    target = MIN(target, dark ? 1.0 : 0.37);

    CGFloat greenDistance = fabs(hue - 120.0 / 360.0);
    greenDistance = MIN(greenDistance, 1.0 - greenDistance);
    CGFloat greenWeight = MAX(0.0, 1.0 - greenDistance / (60.0 / 360.0));
    greenWeight = greenWeight * greenWeight * (3.0 - 2.0 * greenWeight);

    CGFloat mutedSaturation = saturation * (0.30 - 0.10 * greenWeight);
    CGFloat mutedHue = fmod(hue - 10.0 / 360.0 + 1.0, 1.0);

    CGFloat low = 0.0, high = 1.0;
    for (NSInteger i = 0; i < 16; i++) {
        CGFloat mid = (low + high) / 2.0;
        UIColor *candidate = [UIColor colorWithHue:mutedHue saturation:mutedSaturation brightness:mid alpha:alpha];
        if (ApolloTabBarLuminance(candidate) < target) low = mid;
        else high = mid;
    }
    return [UIColor colorWithHue:mutedHue saturation:mutedSaturation brightness:(low + high) / 2.0 alpha:alpha];
}

static char kApolloTabBarIconTintOwnedKey;
static char kApolloTabBarOriginalIconKey;
static UIColor *sApolloTabBarIconTint;

static BOOL ApolloTabBarIsOurs(id object) {
    return object && [objc_getAssociatedObject(object, &kApolloTabBarIconTintOwnedKey) boolValue];
}

static void ApolloTabBarMarkOurs(id object) {
    objc_setAssociatedObject(object, &kApolloTabBarIconTintOwnedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// nil when the tint is off or the accent is achromatic in both appearances.
static UIColor *ApolloTabBarCurrentIconTint(void) {
    if (!sTintInactiveTabIcons || !ApolloTabBarIconTintAvailable()) return nil;
    if (sApolloTabBarIconTint) return sApolloTabBarIconTint;

    UITraitCollection *light = [UITraitCollection traitCollectionWithUserInterfaceStyle:UIUserInterfaceStyleLight];
    UITraitCollection *dark = [UITraitCollection traitCollectionWithUserInterfaceStyle:UIUserInterfaceStyleDark];
    if (!ApolloInactiveTabIconColor(light) && !ApolloInactiveTabIconColor(dark)) return nil;

    UIColor *tint = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return ApolloInactiveTabIconColor(traits) ?: [UIColor.systemGrayColor resolvedColorWithTraitCollection:traits];
    }];
    ApolloTabBarMarkOurs(tint);
    sApolloTabBarIconTint = tint;
    return tint;
}

// The profile avatar icon keeps its own colors (ApolloUserAvatars.xm).
static BOOL ApolloTabBarItemShowsAvatar(UITabBarItem *item) {
    return [objc_getAssociatedObject(item, @selector(apollo_profileTabAvatarIconActive)) boolValue];
}

// The image to install for an item: a template of Apollo's image while the
// tint is on (remembering the original), otherwise the image as given.
static UIImage *ApolloTabBarIconImage(UITabBarItem *item, UIImage *image) {
    if (ApolloTabBarIsOurs(image)) return image;
    objc_setAssociatedObject(item, &kApolloTabBarOriginalIconKey, image, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!image || !ApolloTabBarCurrentIconTint() || ApolloTabBarItemShowsAvatar(item) ||
        image.renderingMode == UIImageRenderingModeAlwaysTemplate) {
        return image;
    }
    UIImage *templated = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    ApolloTabBarMarkOurs(templated);
    return templated;
}

static NSArray<UITabBarItemAppearance *> *ApolloTabBarItemAppearances(UITabBarAppearance *appearance) {
    return @[ appearance.stackedLayoutAppearance,
              appearance.inlineLayoutAppearance,
              appearance.compactInlineLayoutAppearance ];
}

// Returns the appearance unchanged when it already matches, so re-assigning
// it from our own refresh is a no-op.
static UITabBarAppearance *ApolloTabBarAppearanceWithIconTint(UITabBarAppearance *appearance) {
    if (!appearance || !ApolloTabBarIconTintAvailable()) return appearance;

    UIColor *tint = ApolloTabBarCurrentIconTint();
    BOOL stale = NO;
    for (UITabBarItemAppearance *item in ApolloTabBarItemAppearances(appearance)) {
        UIColor *current = item.normal.iconColor;
        if (tint ? current != tint : ApolloTabBarIsOurs(current)) { stale = YES; break; }
    }
    if (!stale) return appearance;

    UITabBarAppearance *updated = [appearance copy];
    for (UITabBarItemAppearance *item in ApolloTabBarItemAppearances(updated)) {
        if (tint) item.normal.iconColor = tint;
        else if (ApolloTabBarIsOurs(item.normal.iconColor)) item.normal.iconColor = nil;
    }
    return updated;
}

static void ApolloTabBarApplyIconTint(UITabBar *tabBar) {
    UIColor *tint = ApolloTabBarCurrentIconTint();
    for (UITabBarItem *item in tabBar.items) {
        UIImage *current = item.image;
        UIImage *original = objc_getAssociatedObject(item, &kApolloTabBarOriginalIconKey);
        if (tint && !ApolloTabBarIsOurs(current)) item.image = current;   // templated by the hook
        else if (!tint && ApolloTabBarIsOurs(current) && original) item.image = original;
    }

    UITabBarAppearance *standard = tabBar.standardAppearance;
    UITabBarAppearance *tintedStandard = ApolloTabBarAppearanceWithIconTint(standard);
    if (tintedStandard != standard) tabBar.standardAppearance = tintedStandard;
    if (@available(iOS 15.0, *)) {
        UITabBarAppearance *scrollEdge = tabBar.scrollEdgeAppearance;
        UITabBarAppearance *tintedScrollEdge = ApolloTabBarAppearanceWithIconTint(scrollEdge);
        if (tintedScrollEdge != scrollEdge) tabBar.scrollEdgeAppearance = tintedScrollEdge;
    }
    // Tab buttons only re-read their appearance data on layout.
    [tabBar setNeedsLayout];
}

static void ApolloTabBarRefreshIconTint(void) {
    if (!ApolloTabBarIconTintAvailable()) return;
    NSArray<UITabBar *> *tabBars = ApolloTabBarAllTabBars();
    for (UITabBar *tabBar in tabBars) ApolloTabBarApplyIconTint(tabBar);
    TabBarStyleLog(@"icon tint %@ on %lu tab bar(s)",
                   ApolloTabBarCurrentIconTint() ? @"applied" : @"cleared", (unsigned long)tabBars.count);
}

BOOL ApolloTabBarIconTintAvailable(void) {
    return !IsLiquidGlass();
}

void ApolloTabBarIconTintSetEnabled(BOOL enabled) {
    if (sTintInactiveTabIcons == enabled) return;
    sTintInactiveTabIcons = enabled;
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:UDKeyTintInactiveTabIcons];
    ApolloTabBarRefreshIconTint();
}

%group ApolloTabBarIconTintClassic

%hook UITabBarItem

- (void)setImage:(UIImage *)image {
    %orig(ApolloTabBarIconImage((UITabBarItem *)self, image));
}

%end

%hook UITabBar

- (void)setStandardAppearance:(UITabBarAppearance *)appearance {
    %orig(ApolloTabBarAppearanceWithIconTint(appearance));
}

- (void)setScrollEdgeAppearance:(UITabBarAppearance *)appearance {
    %orig(ApolloTabBarAppearanceWithIconTint(appearance));
}

- (void)didMoveToWindow {
    %orig;
    if (((UIView *)self).window && sTintInactiveTabIcons) ApolloTabBarApplyIconTint((UITabBar *)self);
}

%end

%end

#pragma mark - Setup

%ctor {
    if (ApolloTabBarIconTintAvailable()) {
        %init(ApolloTabBarIconTintClassic);
        if (ApolloClassUIBadgeView) %init(ApolloTabBadgeClassic);
    } else if (ApolloClassUIBarBadgeView) {
        %init(ApolloTabBadgeGlass);
    }

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserverForName:ApolloInboxBadgeChangedNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(__unused NSNotification *note) {
        // ChatsFilter re-displays the value; restyle the badges already shown.
        ApolloTabBadgeRefreshAll();
    }];
    [center addObserverForName:kApolloThemeChangedNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(__unused NSNotification *note) {
        // Apollo finishes applying the theme after posting; rebuild on the next turn.
        dispatch_async(dispatch_get_main_queue(), ^{
            sApolloTabBarIconTint = nil;
            if (sInboxBadgeUseThemeAccent) ApolloTabBadgeRefreshAll();
            if (sTintInactiveTabIcons) ApolloTabBarRefreshIconTint();
        });
    }];
    TabBarStyleLog(@"module loaded (icon tint %@)", ApolloTabBarIconTintAvailable() ? @"available" : @"unavailable");
}
