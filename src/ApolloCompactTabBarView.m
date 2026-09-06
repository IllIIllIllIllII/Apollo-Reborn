#import "ApolloCompactTabBarView.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

UIView *ApolloExpandedTabBarPlatter(UITabBar *tabBar) {
    // iOS 27 uses _UITabBarItemPlatterView, a subclass of the iOS 26 platter.
    // Matching an exact class name silently rejected Down on iOS 27. Resolve
    // the shared base once and accept its subclasses in both consumers, so
    // reading and animating the geometry cannot disagree about the owner.
    static Class platterClass;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        platterClass = NSClassFromString(@"UIKit._UITabBarPlatterView");
    });
    for (UIView *child in tabBar.subviews) {
        if ([child isKindOfClass:platterClass]) return child;
    }
    return nil;
}

static void ApolloCollectNativeForeground(UIView *view, NSMutableArray<UIView *> *views,
                                          NSMutableArray<NSNumber *> *alphas) {
    if ([view isKindOfClass:UIControl.class] ||
        [NSStringFromClass(view.class) containsString:@"BadgeView"]) {
        [views addObject:view];
        [alphas addObject:@(view.alpha)];
        return;
    }
    for (UIView *child in view.subviews) ApolloCollectNativeForeground(child, views, alphas);
}

// Track only native foreground visibility. The actual platter, selected
// lens, icons and labels stay in UIKit's hierarchy for the entire transition.
@interface ApolloCompactTabBarView ()
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, weak) UITabBar *nativeTabBar;
@property (nonatomic, weak) UIView *nativePlatter;
@property (nonatomic, copy) NSArray<UIView *> *foregroundViews;
@property (nonatomic, copy) NSArray<NSNumber *> *foregroundAlphas;
@property (nonatomic, copy) NSArray<UIView *> *contentOwners;
@property (nonatomic, copy) NSArray<UIView *> *selectionViews;
@property (nonatomic, copy) NSArray<NSNumber *> *selectionHidden;
@property (nonatomic, weak) UIView *selectionLens;
@property (nonatomic, assign) CGFloat selectionLensAlpha;
@property (nonatomic, assign) CGRect nativeExpandedFrame;
@property (nonatomic, assign) CGRect nativeBarBounds;
@property (nonatomic, assign) BOOL applyingNativeFrame;
- (CGRect)nativeBoundsForProposedBounds:(CGRect)bounds;
- (CGPoint)nativeCenterForProposedCenter:(CGPoint)center;
@end

@interface ApolloCompactPlatterOwner : NSObject
@property (nonatomic, weak) ApolloCompactTabBarView *view;
@end
@implementation ApolloCompactPlatterOwner
@end
static char ApolloCompactPlatterOwnerKey;

CGRect ApolloCompactNativePlatterBounds(UIView *platter, CGRect proposedBounds) {
    ApolloCompactPlatterOwner *owner = objc_getAssociatedObject(platter, &ApolloCompactPlatterOwnerKey);
    return owner.view ? [owner.view nativeBoundsForProposedBounds:proposedBounds] : proposedBounds;
}
CGPoint ApolloCompactNativePlatterCenter(UIView *platter, CGPoint proposedCenter) {
    ApolloCompactPlatterOwner *owner = objc_getAssociatedObject(platter, &ApolloCompactPlatterOwnerKey);
    return owner.view ? [owner.view nativeCenterForProposedCenter:proposedCenter] : proposedCenter;
}

@implementation ApolloCompactTabBarView
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.isAccessibilityElement = YES;
    self.accessibilityTraits = UIAccessibilityTraitButton;
    self.accessibilityHint = @"Expand tab bar";
    _title = @"";
    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    _titleLabel.textColor = UIColor.labelColor;
    _titleLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption1]
        scaledFontForFont:[UIFont systemFontOfSize:12.0 weight:UIFontWeightMedium]
        maximumPointSize:17.0];
    _titleLabel.adjustsFontForContentSizeCategory = YES;
    _titleLabel.numberOfLines = 1;
    _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _titleLabel.isAccessibilityElement = NO;
    _titleLabel.alpha = 0.0;
    [self addSubview:_titleLabel];
    [NSLayoutConstraint activateConstraints:@[
        [_titleLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:18.0],
        [_titleLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-18.0],
        [_titleLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    ]];
    return self;
}

- (void)setTitle:(NSString *)title {
    _title = [title copy] ?: @"";
    self.titleLabel.text = _title;
    self.accessibilityLabel = _title;
}
- (BOOL)accessibilityActivate {
    if (!self.enabled) return NO;
    [self sendActionsForControlEvents:UIControlEventTouchUpInside];
    return YES;
}
- (CGFloat)titleAlpha { return self.titleLabel.alpha; }
- (void)setTitleAlpha:(CGFloat)alpha { self.titleLabel.alpha = alpha; }
- (void)setExpansionProgress:(CGFloat)progress {
    _expansionProgress = progress;
    self.titleAlpha = MIN(1.0, MAX(0.0, (0.35 - progress) / 0.25));
}

- (BOOL)prepareNativeTabBar:(UITabBar *)tabBar {
    UIView *platter = ApolloExpandedTabBarPlatter(tabBar);
    if (!platter || !tabBar.superview) return NO;
    if (self.nativePlatter == platter) return YES;
    [self restoreNativeTabBar];
    NSMutableArray<UIView *> *views = [NSMutableArray array];
    NSMutableArray<NSNumber *> *alphas = [NSMutableArray array];
    NSMutableArray<UIView *> *contentOwners = [NSMutableArray array];
    NSMutableArray<UIView *> *selection = [NSMutableArray array];
    NSMutableArray<NSNumber *> *hidden = [NSMutableArray array];
    BOOL foundContent = NO;
    for (UIView *child in platter.subviews) {
        NSString *name = NSStringFromClass(child.class);
        BOOL content = [name hasSuffix:@"ContentView"];
        if ([name isEqualToString:@"_UILiquidLensView"] || [name hasSuffix:@"DestOutView"]) {
            [selection addObject:child];
            [hidden addObject:@(child.hidden)];
            if ([name isEqualToString:@"_UILiquidLensView"]) {
                self.selectionLens = child;
                self.selectionLensAlpha = child.alpha;
            }
        } else if (content || [name hasSuffix:@"BadgeContainerView"]) {
            [contentOwners addObject:child];
            // SelectedContentView is a capture source for the lens, not a
            // second visible row. Fade its lens once, keeping that source
            // intact. For normal items fade the button, not its vibrant
            // image/label: UIKit renders those leaves at full strength for
            // every nonzero alpha (verified on iOS 27).
            if ([name hasSuffix:@"BadgeContainerView"]) {
                // Badges may arrive asynchronously while compact. Owning
                // their container also fades badges added after capture.
                [views addObject:child];
                [alphas addObject:@(child.alpha)];
            } else if (![name hasSuffix:@"SelectedContentView"]) {
                ApolloCollectNativeForeground(child, views, alphas);
            }
            foundContent |= content;
        }
    }
    if (!foundContent || views.count == 0) return NO;
    self.nativeTabBar = tabBar;
    self.nativePlatter = platter;
    self.nativeExpandedFrame = platter.frame;
    self.nativeBarBounds = tabBar.bounds;
    self.foregroundViews = views;
    self.foregroundAlphas = alphas;
    self.contentOwners = contentOwners;
    self.selectionViews = selection;
    self.selectionHidden = hidden;
    ApolloCompactPlatterOwner *owner = [ApolloCompactPlatterOwner new];
    owner.view = self;
    objc_setAssociatedObject(platter, &ApolloCompactPlatterOwnerKey, owner, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return YES;
}

- (BOOL)ownsNativeTabBar:(UITabBar *)tabBar {
    UIView *platter = self.nativePlatter;
    if (self.nativeTabBar != tabBar || !platter || platter.superview != tabBar ||
        platter != ApolloExpandedTabBarPlatter(tabBar)) return NO;
    for (UIView *view in self.foregroundViews) {
        if (![view isDescendantOfView:platter]) return NO;
    }
    for (UIView *view in self.contentOwners) {
        if (view.superview != platter) return NO;
    }
    for (UIView *view in self.selectionViews) {
        if (view.superview != platter) return NO;
    }
    return self.foregroundViews.count > 0;
}

- (CGRect)nativeBoundsForProposedBounds:(CGRect)bounds {
    if (self.applyingNativeFrame) return bounds;
    CGRect expanded = self.nativeExpandedFrame;
    CGPoint center = CGPointMake(CGRectGetMidX(expanded), CGRectGetMidY(expanded));
    expanded.size = bounds.size;
    expanded.origin = CGPointMake(center.x - bounds.size.width * 0.5, center.y - bounds.size.height * 0.5);
    self.nativeExpandedFrame = expanded;
    self.nativeBarBounds = self.nativeTabBar.bounds;
    return (CGRect){bounds.origin, self.bounds.size};
}

- (CGPoint)nativeCenterForProposedCenter:(CGPoint)center {
    if (self.applyingNativeFrame) return center;
    CGRect expanded = self.nativeExpandedFrame;
    expanded.origin = CGPointMake(center.x - expanded.size.width * 0.5, center.y - expanded.size.height * 0.5);
    self.nativeExpandedFrame = expanded;
    return [self.nativeTabBar convertPoint:self.center fromView:self.superview];
}

- (CGRect)expandedFrame {
    UITabBar *bar = self.nativeTabBar;
    CGRect frame = self.nativeExpandedFrame;
    // Preserve native side margins when the containing bar changes size.
    frame.size.width += bar.bounds.size.width - self.nativeBarBounds.size.width;
    return bar.superview ? [bar.superview convertRect:frame fromView:bar] : CGRectNull;
}

- (void)applyNativeFrame:(CGRect)frame expansionProgress:(CGFloat)progress {
    self.expansionProgress = progress;
    self.frame = frame;
    self.applyingNativeFrame = YES;
    self.nativePlatter.frame = [self.nativeTabBar convertRect:frame fromView:self.nativeTabBar.superview];
    self.applyingNativeFrame = NO;
    [self.nativePlatter layoutIfNeeded];
    // Native labels keep their font size as the items redistribute. Wait for
    // sufficient width before revealing them, avoiding crowded glyphs during
    // the narrow part of the morph. They are fully visible before settling.
    CGFloat foreground = MIN(1.0, MAX(0.0, (progress - 0.70) / 0.25));
    // Keep the destination-out mask opaque: fading it exposes the normal
    // selected item underneath the lens. Only the lens and normal buttons
    // dissolve; the selected capture source stays at native opacity.
    for (NSUInteger i = 0; i < self.selectionViews.count; i++) {
        self.selectionViews[i].hidden = self.selectionHidden[i].boolValue || foreground == 0.0;
    }
    self.selectionLens.alpha = self.selectionLensAlpha * foreground;
    for (NSUInteger i = 0; i < self.foregroundViews.count; i++) {
        self.foregroundViews[i].alpha = self.foregroundAlphas[i].doubleValue * foreground;
    }
    [self layoutIfNeeded];
}

- (void)restoreNativeTabBar {
    UIView *platter = self.nativePlatter;
    UITabBar *bar = self.nativeTabBar;
    if (platter) {
        objc_setAssociatedObject(platter, &ApolloCompactPlatterOwnerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (bar && platter.superview == bar) {
        CGRect frame = self.nativeExpandedFrame;
        frame.size.width += bar.bounds.size.width - self.nativeBarBounds.size.width;
        platter.frame = frame;
    }
    for (NSUInteger i = 0; i < self.foregroundViews.count; i++) {
        self.foregroundViews[i].alpha = self.foregroundAlphas[i].doubleValue;
    }
    for (NSUInteger i = 0; i < self.selectionViews.count; i++) {
        self.selectionViews[i].hidden = self.selectionHidden[i].boolValue;
    }
    self.selectionLens.alpha = self.selectionLensAlpha;
    self.nativePlatter = nil;
    self.nativeTabBar = nil;
    self.foregroundViews = nil;
    self.foregroundAlphas = nil;
    self.contentOwners = nil;
    self.selectionViews = nil;
    self.selectionHidden = nil;
    self.selectionLens = nil;
}

- (void)dealloc {
    // The owner reference is weak, but release any remaining geometry guard
    // when the containing controller disappears without another layout pass.
    [self restoreNativeTabBar];
}

- (CGSize)compactSize {
    CGSize text = [self.titleLabel sizeThatFits:CGSizeMake(240.0, 44.0)];
    return CGSizeMake(MAX(96.0, ceil(text.width) + 36.0), MAX(32.0, ceil(text.height) + 14.0));
}
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    CGRect hitRect = CGRectInset(self.bounds, 0.0, -MAX(0.0, (44.0 - self.bounds.size.height) / 2.0));
    return CGRectContainsPoint(hitRect, point);
}
@end
