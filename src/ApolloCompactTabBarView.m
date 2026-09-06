#import "ApolloCompactTabBarView.h"
#import "ApolloImmersiveHeaderBackground.h"
#import "ApolloThemeRuntime.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>

UIView *ApolloExpandedTabBarPlatter(UITabBar *tabBar) {
    // iOS 27 uses _UITabBarItemPlatterView, a subclass of the iOS 26 platter.
    // Matching an exact class name silently rejected Down on iOS 27. Resolve
    // the shared base once and accept its subclasses in both consumers, so
    // finding the frame and copying the icons cannot disagree about the owner.
    static Class platterClass;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        platterClass = NSClassFromString(@"UIKit._UITabBarPlatterView");
    });
    for (UIView *child in tabBar.subviews) {
        if ([child isKindOfClass:platterClass] &&
            child.bounds.size.width > tabBar.bounds.size.width * 0.5) return child;
    }
    return nil;
}

// Copy semantic content, not rendered UIKit pixels. The native tab foreground
// contains blend/vibrancy operations whose screenshots can be blank before a
// render pass, or white when detached from their original glass compositor.
static NSUInteger ApolloCompactCopyForeground(UIView *source, UIView *destination,
    UIView *coordinateView, CGRect expandedFrame, UIColor *color, UITabBarItem *item) {
    if (source.hidden || source.alpha < 0.01 || CGRectIsEmpty(source.bounds)) return 0;
    UIView *copy = nil;
    if ([source isKindOfClass:UIImageView.class]) {
        UIImageView *original = (UIImageView *)source;
        UIImage *image = original.highlighted ? original.highlightedImage ?: original.image : original.image;
        if (!image) return 0;
        BOOL avatar = [objc_getAssociatedObject(item,
            NSSelectorFromString(@"apollo_profileTabAvatarIconActive")) boolValue];
        UIImageView *imageCopy = [[UIImageView alloc] initWithImage:[image imageWithRenderingMode:
            avatar ? UIImageRenderingModeAlwaysOriginal : UIImageRenderingModeAlwaysTemplate]];
        imageCopy.contentMode = original.contentMode;
        imageCopy.tintColor = color;
        imageCopy.clipsToBounds = original.clipsToBounds;
        imageCopy.layer.cornerRadius = original.layer.cornerRadius;
        copy = imageCopy;
    } else if ([source isKindOfClass:UILabel.class]) {
        UILabel *original = (UILabel *)source;
        if (original.text.length == 0 && original.attributedText.length == 0) return 0;
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
        label.font = original.font;
        label.textAlignment = original.textAlignment;
        label.numberOfLines = original.numberOfLines;
        label.lineBreakMode = original.lineBreakMode;
        label.adjustsFontSizeToFitWidth = original.adjustsFontSizeToFitWidth;
        label.minimumScaleFactor = original.minimumScaleFactor;
        label.baselineAdjustment = original.baselineAdjustment;
        if (original.attributedText.length) {
            NSMutableAttributedString *text = [original.attributedText mutableCopy];
            [text addAttribute:NSForegroundColorAttributeName value:color range:NSMakeRange(0, text.length)];
            label.attributedText = text;
        } else label.text = original.text;
        label.textColor = color;
        copy = label;
    } else if ([NSStringFromClass(source.class) containsString:@"BadgeView"]) {
        // Badges are an independent color surface, not templated tab glyphs.
        UIView *badge = [[UIView alloc] initWithFrame:source.bounds];
        badge.backgroundColor = item.badgeColor ?: UIColor.systemRedColor;
        badge.layer.cornerRadius = MIN(source.bounds.size.width, source.bounds.size.height) * 0.5;
        NSMutableArray<UIView *> *labels = [source.subviews mutableCopy];
        while (labels.count) {
            UIView *child = labels.lastObject;
            [labels removeLastObject];
            if ([child isKindOfClass:UILabel.class]) {
                ApolloCompactCopyForeground(child, badge, source, source.bounds, UIColor.whiteColor, item);
            } else [labels addObjectsFromArray:child.subviews];
        }
        copy = badge;
    }
    if (copy) {
        CGRect frame = [coordinateView convertRect:source.bounds fromView:source];
        frame = CGRectOffset(frame, -expandedFrame.origin.x, -expandedFrame.origin.y);
        copy.bounds = (CGRect){CGPointZero, source.bounds.size};
        copy.center = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
        copy.transform = CGAffineTransformMakeScale(frame.size.width / source.bounds.size.width,
            frame.size.height / source.bounds.size.height);
        copy.userInteractionEnabled = NO;
        copy.isAccessibilityElement = NO;
        [destination addSubview:copy];
        return 1;
    }
    NSUInteger count = 0;
    for (UIView *child in source.subviews) {
        count += ApolloCompactCopyForeground(child, destination, coordinateView, expandedFrame, color, item);
    }
    return count;
}

static NSArray<UIView *> *ApolloCompactTabButtons(UIView *content) {
    NSMutableArray<UIView *> *buttons = [NSMutableArray array];
    for (UIView *child in content.subviews) {
        if ([NSStringFromClass(child.class) isEqualToString:@"_UITabButton"]) [buttons addObject:child];
    }
    return buttons;
}

static UITabBarItem *ApolloCompactTabItemForButton(UIView *button, UITabBar *tabBar) {
    // Match the native ownership paths already used by ApolloUserAvatars:
    // the normal button is registered on the item, while the selected-content
    // duplicate carries its own item ivar. Subview paint order is not identity.
    SEL selector = NSSelectorFromString(@"_tabBarButton");
    for (UITabBarItem *item in tabBar.items) {
        if ([item respondsToSelector:selector] &&
            ((id (*)(id, SEL))objc_msgSend)(item, selector) == button) return item;
    }
    Ivar ivar = class_getInstanceVariable(button.class, "_item") ?:
        class_getInstanceVariable(button.class, "item");
    id item = ivar ? object_getIvar(button, ivar) : nil;
    if ([item isKindOfClass:UITabBarItem.class] &&
        [tabBar.items indexOfObjectIdenticalTo:item] != NSNotFound) return item;
    return nil;
}

@interface ApolloCompactTabBarView ()
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIVisualEffectView *glassView;
@property (nonatomic, strong) UIView *expandedBackground;
@property (nonatomic, strong) UIView *expandedContent;
@property (nonatomic, readwrite) CGSize expandedContentSize;
@end

@implementation ApolloCompactTabBarView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.backgroundColor = UIColor.clearColor;
    self.clipsToBounds = NO;
    self.isAccessibilityElement = YES;
    self.accessibilityTraits = UIAccessibilityTraitButton;
    self.accessibilityHint = @"Expand tab bar";
    _title = @"";

    // This control is created only for Liquid Glass tab bars. Reuse the
    // regular native glass material, including its touch response. UIKit's
    // capsule configuration follows the owner's animated bounds changes.
    UIVisualEffectView *glass = [[UIVisualEffectView alloc]
        initWithEffect:ApolloImmersiveGlassEffect(nil, 0.0, YES)];
    _glassView = glass;
    glass.translatesAutoresizingMaskIntoConstraints = NO;
    glass.userInteractionEnabled = YES;
    if (@available(iOS 26.0, *)) {
        glass.cornerConfiguration = [UICornerConfiguration capsuleConfiguration];
    }
    [self addSubview:glass];
    // Let the effect receive the press so UIKit supplies its native glass
    // response. The ancestor recognizer also handles the extended hit area;
    // cancellation prevents UIControl tracking from sending a second action.
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(apollo_compactTapped:)];
    tap.cancelsTouchesInView = YES;
    [self addGestureRecognizer:tap];

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
    // Content inside the effect receives UIKit's native glass vibrancy and
    // foreground adaptation as the scrolled content changes behind it.
    [glass.contentView addSubview:_titleLabel];
    // Keep the ordinary foreground outside the effect from the start. At the
    // native handoff only this content fades: fading a glass effect or any
    // ancestor changes its compositing and produces a brightness pulse.
    // Its bounds stay expanded; only its outer scale changes.
    _expandedContent = [[UIView alloc] initWithFrame:CGRectZero];
    _expandedContent.userInteractionEnabled = NO;
    _expandedContent.isAccessibilityElement = NO;
    _expandedContent.clipsToBounds = NO;
    _expandedContent.alpha = 0.0;
    glass.contentView.clipsToBounds = NO;
    [self addSubview:_expandedContent];
    _expandedBackground = [[UIView alloc] initWithFrame:CGRectZero];
    _expandedBackground.userInteractionEnabled = NO;
    _expandedBackground.alpha = 0.0;
    [glass.contentView addSubview:_expandedBackground];

    [NSLayoutConstraint activateConstraints:@[
        [glass.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [glass.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [glass.topAnchor constraintEqualToAnchor:self.topAnchor],
        [glass.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [_titleLabel.leadingAnchor constraintEqualToAnchor:glass.contentView.leadingAnchor constant:18.0],
        [_titleLabel.trailingAnchor constraintEqualToAnchor:glass.contentView.trailingAnchor constant:-18.0],
        [_titleLabel.centerYAnchor constraintEqualToAnchor:glass.contentView.centerYAnchor],
    ]];
    return self;
}

- (void)setTitle:(NSString *)title {
    if ([_title isEqualToString:title]) return;
    _title = [title copy] ?: @"";
    self.titleLabel.text = _title;
    self.accessibilityLabel = _title;
}

- (BOOL)accessibilityActivate {
    if (!self.enabled) return NO;
    [self sendActionsForControlEvents:UIControlEventTouchUpInside];
    return YES;
}

- (void)apollo_compactTapped:(UITapGestureRecognizer *)tap {
    if (self.enabled && tap.state == UIGestureRecognizerStateRecognized) {
        [self sendActionsForControlEvents:UIControlEventTouchUpInside];
    }
}

- (CGFloat)titleAlpha {
    return self.titleLabel.alpha;
}

- (void)setTitleAlpha:(CGFloat)titleAlpha {
    self.titleLabel.alpha = titleAlpha;
}

- (BOOL)captureExpandedContentFromTabBar:(UITabBar *)tabBar expandedFrame:(CGRect)expandedFrame {
    if (!tabBar.superview || CGRectIsNull(expandedFrame) || CGRectIsEmpty(expandedFrame)) return NO;
    UIView *normal = nil, *selected = nil, *lens = nil;
    UIView *platter = ApolloExpandedTabBarPlatter(tabBar);
    // These are sibling content-only owners in UIKit 26/27. Capturing the
    // platter itself would also freeze the native glass and liquid lens.
    for (UIView *child in platter.subviews) {
        NSString *name = NSStringFromClass(child.class);
        if ([name hasSuffix:@"SelectedContentView"]) selected = child;
        else if ([name containsString:@"_UITabBarPlatterView"] &&
                 [name hasSuffix:@"ContentView"]) normal = child;
        else if ([name isEqualToString:@"_UILiquidLensView"]) lens = child;
    }
    if (!normal || !selected || !lens || normal.hidden || selected.hidden) return NO;
    CGRect (^relativeFrame)(UIView *) = ^CGRect(UIView *view) {
        CGRect frame = [tabBar.superview convertRect:view.bounds fromView:view];
        return CGRectOffset(frame, -expandedFrame.origin.x, -expandedFrame.origin.y);
    };
    CGRect selectedFrame = CGRectIntersection((CGRect){CGPointZero, expandedFrame.size}, relativeFrame(lens));
    if (CGRectIsNull(selectedFrame) || CGRectIsEmpty(selectedFrame)) return NO;
    NSArray<UIView *> *normalButtons = ApolloCompactTabButtons(normal);
    NSArray<UIView *> *selectedButtons = ApolloCompactTabButtons(selected);
    if (normalButtons.count == 0 || normalButtons.count != tabBar.items.count ||
        selectedButtons.count != normalButtons.count) return NO;
    UIView *content = [[UIView alloc] initWithFrame:(CGRect){CGPointZero, expandedFrame.size}];
    UIView *normalCopy = [[UIView alloc] initWithFrame:content.bounds];
    UIView *selectedCopy = [[UIView alloc] initWithFrame:content.bounds];
    UIColor *accent = ApolloThemeAccentColor() ?: tabBar.tintColor;
    for (UIView *button in normalButtons) {
        UITabBarItem *item = ApolloCompactTabItemForButton(button, tabBar);
        if (!item || !ApolloCompactCopyForeground(button, normalCopy,
            tabBar.superview, expandedFrame, UIColor.labelColor, item)) return NO;
    }
    for (UIView *button in selectedButtons) {
        UITabBarItem *item = ApolloCompactTabItemForButton(button, tabBar);
        if (!item || !ApolloCompactCopyForeground(button, selectedCopy,
            tabBar.superview, expandedFrame, accent, item)) return NO;
    }
    // Match UIKit's selected-content lens without capturing its compositor:
    // complementary masks ensure there is exactly one copy of every glyph.
    UIBezierPath *selection = [UIBezierPath bezierPathWithRoundedRect:selectedFrame
        cornerRadius:MIN(selectedFrame.size.width, selectedFrame.size.height) * 0.5];
    UIBezierPath *unselected = [UIBezierPath bezierPathWithRect:content.bounds];
    [unselected appendPath:selection];
    CAShapeLayer *normalMask = [CAShapeLayer layer];
    normalMask.frame = content.bounds;
    normalMask.path = unselected.CGPath;
    normalMask.fillRule = kCAFillRuleEvenOdd;
    normalCopy.layer.mask = normalMask;
    CAShapeLayer *selectedMask = [CAShapeLayer layer];
    selectedMask.frame = content.bounds;
    selectedMask.path = selection.CGPath;
    selectedCopy.layer.mask = selectedMask;
    UIView *highlight = [[UIView alloc] initWithFrame:selectedFrame];
    highlight.layer.cornerRadius = MIN(selectedFrame.size.width, selectedFrame.size.height) * 0.5;
    highlight.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        BOOL dark = traits.userInterfaceStyle == UIUserInterfaceStyleDark;
        // The native selected lens darkens the surrounding glass in both
        // appearances. Match its measured contrast so exchanging materials
        // does not flash a lighter capsule behind the selected icon.
        return [UIColor colorWithWhite:0.0 alpha:dark ? 0.50 : 0.075];
    }];
    [content addSubview:normalCopy];
    [content addSubview:selectedCopy];
    for (UIView *old in self.expandedBackground.subviews) [old removeFromSuperview];
    [self.expandedBackground addSubview:highlight];
    for (UIView *old in self.expandedContent.subviews) [old removeFromSuperview];
    [self.expandedContent addSubview:content];
    self.expandedContentSize = expandedFrame.size;
    [self setNeedsLayout];
    return YES;
}

- (void)setExpansionProgress:(CGFloat)expansionProgress {
    // Preserve slight geometric overshoot so a reversal starts from the
    // actual displayed size; only opacity is restricted to its valid range.
    _expansionProgress = expansionProgress;
    CGFloat foregroundAlpha = MIN(1.0, MAX(0.0, (expansionProgress - 0.15) / 0.60));
    self.expandedContent.alpha = foregroundAlpha * (1.0 - self.nativeHandoffProgress);
    self.expandedBackground.alpha = foregroundAlpha;
    self.titleAlpha = MIN(1.0, MAX(0.0, (0.35 - expansionProgress) / 0.25));
    // The owner drives frame + progress per display-link tick. Resolve the
    // native capsule's constraints and foreground geometry in this same tick.
    [self setNeedsLayout];
    [self layoutIfNeeded];
}

- (void)setNativeHandoffProgress:(CGFloat)progress {
    _nativeHandoffProgress = MIN(1.0, MAX(0.0, progress));
    // Swap materials at full opacity, then dissolve only the ordinary copied
    // foreground over native glyphs. The copied selection backing leaves with
    // its glass so it cannot darken UIKit's real selected-tab lens.
    self.glassView.hidden = _nativeHandoffProgress > 0.0;
    self.expandedContent.alpha = (1.0 - _nativeHandoffProgress) *
        MIN(1.0, MAX(0.0, (self.expansionProgress - 0.15) / 0.60));
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (self.expandedContentSize.width <= 0.0) return;
    CGFloat scale = self.bounds.size.width / self.expandedContentSize.width;
    self.expandedContent.bounds = (CGRect){CGPointZero, self.expandedContentSize};
    self.expandedContent.center = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    self.expandedContent.transform = CGAffineTransformMakeScale(scale, scale);
    self.expandedBackground.bounds = self.expandedContent.bounds;
    self.expandedBackground.center = self.expandedContent.center;
    self.expandedBackground.transform = self.expandedContent.transform;
}

- (CGSize)compactSize {
    CGSize text = [self.titleLabel sizeThatFits:CGSizeMake(240.0, 44.0)];
    return CGSizeMake(MAX(96.0, ceil(text.width) + 36.0), MAX(32.0, ceil(text.height) + 14.0));
}

// Safari's visual capsule is shorter than a comfortable touch target. Keep
// its glass at the measured size while allowing a 44-point expansion tap.
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    CGRect hitRect = CGRectInset(self.bounds, 0.0, -MAX(0.0, (44.0 - self.bounds.size.height) / 2.0));
    return CGRectContainsPoint(hitRect, point);
}

@end
