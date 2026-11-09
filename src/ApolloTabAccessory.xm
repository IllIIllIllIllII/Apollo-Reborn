#import "ApolloTabAccessory.h"
#import "ApolloAutoHideTabBar.h"
#import "ApolloCommon.h"
#import "ApolloCompactTabBarView.h"
#import "ApolloState.h"
#import "ApolloThemeRuntime.h"
#import <objc/runtime.h>

// MARK: - Slot

@interface ApolloTabAccessoryEntry : NSObject
@property (nonatomic) ApolloTabAccessoryOwner owner;
@property (nonatomic, strong) UIView *contentView;
@end

@implementation ApolloTabAccessoryEntry
@end

// Bottom of the stack first; the last entry is the one on screen.
static NSMutableArray<ApolloTabAccessoryEntry *> *sApolloTabAccessoryEntries;
static __weak UITabBarController *sApolloTabAccessoryHost;

static UITabBarController *ApolloTabAccessoryTabBarController(void) {
    UIViewController *controller = ApolloMainTabBarController();
    return [controller isKindOfClass:UITabBarController.class] ? (UITabBarController *)controller : nil;
}

BOOL ApolloTabAccessoryIsSupported(void) {
    if (@available(iOS 26.0, *)) return IsLiquidGlass();
    return NO;
}

BOOL ApolloTabAccessoryIsAvailable(void) {
    if (!ApolloTabAccessoryIsSupported()) return NO;
    UITabBarController *host = ApolloTabAccessoryTabBarController();
    return host && host.viewIfLoaded.window && !host.presentedViewController;
}

static void ApolloTabAccessoryApply(void) {
    if (@available(iOS 26.0, *)) {
        UITabBarController *host = ApolloTabAccessoryTabBarController();
        UITabBarController *previous = sApolloTabAccessoryHost;
        if (previous && previous != host) [previous setBottomAccessory:nil animated:NO];
        sApolloTabAccessoryHost = host;
        if (!host) return;

        ApolloTabAccessoryEntry *top = sApolloTabAccessoryEntries.lastObject;
        UIView *current = host.bottomAccessory.contentView;
        if (current == top.contentView) return;
        UITabAccessory *accessory = top ? [[UITabAccessory alloc] initWithContentView:top.contentView] : nil;
        [host setBottomAccessory:accessory animated:YES];
        // A strip added while the bar is hidden starts in the bar's place.
        if (accessory) [UIView performWithoutAnimation:^{ ApolloTabAccessoryFollowTabBar(host); }];
        ApolloLog(@"[TabAccessory] showing owner=%ld (stack=%lu)", (long)top.owner,
                  (unsigned long)sApolloTabAccessoryEntries.count);
    }
}

BOOL ApolloTabAccessoryShow(ApolloTabAccessoryOwner owner, UIView *contentView) {
    if (!ApolloTabAccessoryIsAvailable()) return NO;
    if (!sApolloTabAccessoryEntries) sApolloTabAccessoryEntries = [NSMutableArray array];
    for (ApolloTabAccessoryEntry *entry in [sApolloTabAccessoryEntries copy]) {
        if (entry.owner == owner) [sApolloTabAccessoryEntries removeObject:entry];
    }
    ApolloTabAccessoryEntry *entry = [ApolloTabAccessoryEntry new];
    entry.owner = owner;
    entry.contentView = contentView;
    [sApolloTabAccessoryEntries addObject:entry];
    ApolloTabAccessoryApply();
    return YES;
}

void ApolloTabAccessoryHide(ApolloTabAccessoryOwner owner) {
    BOOL removed = NO;
    for (ApolloTabAccessoryEntry *entry in [sApolloTabAccessoryEntries copy]) {
        if (entry.owner != owner) continue;
        [sApolloTabAccessoryEntries removeObject:entry];
        removed = YES;
    }
    if (removed) ApolloTabAccessoryApply();
}

// MARK: - Following the tab bar

static char kApolloTabAccessoryMovedKey;

static UIView *ApolloTabAccessoryContainer(UITabBarController *host) {
    if (@available(iOS 26.0, *)) return host.bottomAccessory.contentView.superview;
    return nil;
}

// The bar's glass in `view`'s space, from frames only: Down renders the bar
// shifted through its layer's sublayerTransform, which a converted rect would
// include, and the strip belongs where the bar sits at rest.
static CGRect ApolloTabAccessoryRestingBarRect(UITabBar *tabBar, UIView *view) {
    UIView *platter = ApolloExpandedTabBarPlatter(tabBar);
    if (!platter || ![platter isDescendantOfView:tabBar]) return CGRectNull;
    CGRect rect = platter.frame;
    for (UIView *ancestor = platter.superview; ancestor && ancestor != tabBar; ancestor = ancestor.superview) {
        rect.origin.x += ancestor.frame.origin.x - ancestor.bounds.origin.x;
        rect.origin.y += ancestor.frame.origin.y - ancestor.bounds.origin.y;
    }
    return [tabBar convertRect:rect toView:view];
}

// Idempotent: the offset is measured from the center UIKit set, which a
// transform never changes, so repeated layout passes don't add up.
static void ApolloTabAccessoryPlace(UITabBarController *host) {
    UIView *container = ApolloTabAccessoryContainer(host);
    UIView *space = container.superview;
    UITabBar *tabBar = host.tabBar;
    if (!container || !space || !tabBar) return;

    CGPoint center = container.center;
    CGSize size = container.bounds.size;
    CGFloat dx = 0.0, dy = 0.0;
    if (ApolloTabBarScrollHidesBarAway(host)) {
        // Fade/Down: take the hidden bar's place, centered on its glass, as
        // UIKit does for a hidden tab bar. Only when the bar is below the
        // strip (iPad's bar sits at the top).
        CGRect bar = ApolloTabAccessoryRestingBarRect(tabBar, space);
        if (!CGRectIsNull(bar) && CGRectGetMidY(bar) > center.y) dy = CGRectGetMidY(bar) - center.y;
    } else if (sTabBarHideStyle == ApolloTabBarHideStyleRight) {
        BOOL isInline = NO;
        if (@available(iOS 26.0, *)) {
            isInline = host.bottomAccessory.contentView.traitCollection.tabAccessoryEnvironment ==
                UITabAccessoryEnvironmentInline;
        }
        // UIKit lays the inline strip out beside a leading pill; Right mirrors
        // that pill to the trailing edge, so mirror the strip the same way.
        if (isInline && space.bounds.size.width > 0.0) dx = space.bounds.size.width - 2.0 * center.x;
    }

    BOOL moved = fabs(dx) > 0.5 || fabs(dy) > 0.5;
    BOOL wasMoved = [objc_getAssociatedObject(container, &kApolloTabAccessoryMovedKey) boolValue];
    if (!moved && !wasMoved) return; // leave UIKit's own transforms alone
    CGAffineTransform transform = moved ? CGAffineTransformMakeTranslation(dx, dy) : CGAffineTransformIdentity;
    if (!CGAffineTransformEqualToTransform(container.transform, transform)) {
        container.transform = transform;
        ApolloLog(@"[TabAccessory] following tab bar dx=%.1f dy=%.1f size=%@", dx, dy, NSStringFromCGSize(size));
    }
    objc_setAssociatedObject(container, &kApolloTabAccessoryMovedKey, moved ? @YES : nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

void ApolloTabAccessoryFollowTabBar(UITabBarController *tabBarController) {
    UITabBarController *host = sApolloTabAccessoryHost;
    if (!host || host != tabBarController) return;
    UIView *container = ApolloTabAccessoryContainer(host);
    if (!container) return;
    // Minimize resizes the bar's real glass; UIKit places the strip above it
    // on its next layout pass. Run that pass now so the strip moves in step.
    UIView *group = container.superview.superview ?: container.superview;
    [group setNeedsLayout];
    [group layoutIfNeeded];
    ApolloTabAccessoryPlace(host);
}

// UIKit moves the strip on its own (a new strip, rotation, the inline morph,
// its group layout), sometimes outside any layout pass we could follow; re-place
// it whenever UIKit sets its center or size. Only the strip's transform is
// written here, which never calls back into these setters.
%group ApolloTabAccessoryContainerHooks
%hook ApolloUITabAccessoryContainer
- (void)setCenter:(CGPoint)center {
    %orig;
    UITabBarController *host = sApolloTabAccessoryHost;
    if (host && sApolloTabAccessoryEntries.count && ApolloTabAccessoryContainer(host) == (UIView *)self) {
        ApolloTabAccessoryPlace(host);
    }
}
- (void)setBounds:(CGRect)bounds {
    %orig;
    UITabBarController *host = sApolloTabAccessoryHost;
    if (host && sApolloTabAccessoryEntries.count && ApolloTabAccessoryContainer(host) == (UIView *)self) {
        ApolloTabAccessoryPlace(host);
    }
}
%end
%end

%ctor {
    if (@available(iOS 26.0, *)) {
        // Swift class in UIKitCore; objc_getClass resolves the dotted name.
        Class container = objc_getClass("UIKit._UITabAccessoryContainer");
        if (!container) {
            ApolloLog(@"[TabAccessory] _UITabAccessoryContainer missing; the strip won't follow hide styles");
            return;
        }
        %init(ApolloTabAccessoryContainerHooks, ApolloUITabAccessoryContainer = container);
        ApolloLog(@"[TabAccessory] container hook installed");
    }
}

// MARK: - Progress ring

@interface ApolloTabAccessoryRing : UIView
@property (nonatomic) double progress;
@end

@implementation ApolloTabAccessoryRing {
    CAShapeLayer *_track;
    CAShapeLayer *_fill;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    _track = [CAShapeLayer layer];
    _fill = [CAShapeLayer layer];
    for (CAShapeLayer *layer in @[_track, _fill]) {
        layer.fillColor = UIColor.clearColor.CGColor;
        layer.lineWidth = 3.0;
        layer.lineCap = kCALineCapRound;
        [self.layer addSublayer:layer];
    }
    _fill.strokeEnd = 0.0;
    self.isAccessibilityElement = NO;
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat inset = _track.lineWidth / 2.0;
    CGRect box = CGRectInset(self.bounds, inset, inset);
    // Starts at 12 o'clock and runs clockwise.
    UIBezierPath *path = [UIBezierPath bezierPathWithArcCenter:CGPointMake(CGRectGetMidX(box), CGRectGetMidY(box))
                                                        radius:MIN(box.size.width, box.size.height) / 2.0
                                                    startAngle:-M_PI_2
                                                      endAngle:M_PI * 1.5
                                                     clockwise:YES];
    _track.frame = self.bounds;
    _fill.frame = self.bounds;
    _track.path = path.CGPath;
    _fill.path = path.CGPath;
    [self updateColors];
}

- (void)tintColorDidChange {
    [super tintColorDidChange];
    [self updateColors];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self updateColors];
}

- (void)updateColors {
    UIColor *accent = ApolloThemeAccentColor() ?: self.tintColor;
    _fill.strokeColor = [accent resolvedColorWithTraitCollection:self.traitCollection].CGColor;
    _track.strokeColor = [UIColor.tertiarySystemFillColor resolvedColorWithTraitCollection:self.traitCollection].CGColor;
}

- (void)setProgress:(double)progress {
    double clamped = MIN(1.0, MAX(0.0, progress));
    if (_progress == clamped) return;
    _progress = clamped;
    BOOL animate = self.window && !UIAccessibilityIsReduceMotionEnabled();
    [CATransaction begin];
    [CATransaction setDisableActions:!animate];
    [CATransaction setAnimationDuration:0.25];
    _fill.strokeEnd = clamped;
    [CATransaction commit];
}

@end

// MARK: - Progress content

@implementation ApolloTabAccessoryProgressView {
    ApolloTabAccessoryRing *_ring;
    UILabel *_titleLabel;
    UILabel *_detailLabel;
    UIButton *_stopButton;
    UIStackView *_textStack;
    NSLayoutConstraint *_ringSize;
    BOOL _inline;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    _title = @"";
    _stopAccessibilityLabel = @"Stop";

    _ring = [ApolloTabAccessoryRing new];
    _ring.translatesAutoresizingMaskIntoConstraints = NO;

    _titleLabel = [UILabel new];
    _titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    _titleLabel.font = [UIFont fontWithDescriptor:[_titleLabel.font.fontDescriptor
        fontDescriptorWithSymbolicTraits:UIFontDescriptorTraitBold] size:0];
    _titleLabel.textColor = UIColor.labelColor;
    _detailLabel = [UILabel new];
    _detailLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    _detailLabel.textColor = UIColor.secondaryLabelColor;
    _detailLabel.font = [UIFont monospacedDigitSystemFontOfSize:_detailLabel.font.pointSize weight:UIFontWeightRegular];
    for (UILabel *label in @[_titleLabel, _detailLabel]) {
        label.lineBreakMode = NSLineBreakByTruncatingTail;
        [label setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    }
    _textStack = [[UIStackView alloc] initWithArrangedSubviews:@[_titleLabel, _detailLabel]];
    _textStack.axis = UILayoutConstraintAxisVertical;
    _textStack.spacing = 0.0;

    _stopButton = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *symbol = [UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightSemibold];
    [_stopButton setImage:[UIImage systemImageNamed:@"xmark" withConfiguration:symbol] forState:UIControlStateNormal];
    _stopButton.tintColor = UIColor.labelColor;
    [_stopButton addTarget:self action:@selector(stopTapped) forControlEvents:UIControlEventTouchUpInside];
    _stopButton.hidden = YES;
    _stopButton.accessibilityLabel = _stopAccessibilityLabel;
    [_stopButton setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[_ring, _textStack, _stopButton]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 12.0;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:row];

    _ringSize = [_ring.widthAnchor constraintEqualToConstant:24.0];
    [NSLayoutConstraint activateConstraints:@[
        _ringSize,
        [_ring.heightAnchor constraintEqualToAnchor:_ring.widthAnchor],
        [_stopButton.widthAnchor constraintEqualToConstant:44.0],
        [_stopButton.heightAnchor constraintEqualToConstant:44.0],
        [row.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16.0],
        [row.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-6.0],
        [row.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [row.topAnchor constraintGreaterThanOrEqualToAnchor:self.topAnchor],
        [row.bottomAnchor constraintLessThanOrEqualToAnchor:self.bottomAnchor],
    ]];

    self.isAccessibilityElement = NO;
    if (@available(iOS 26.0, *)) {
        [self registerForTraitChanges:@[UITraitTabAccessoryEnvironment.class]
                           withAction:@selector(updateEnvironment)];
    }
    [self updateEnvironment];
    [self updateText];
    return self;
}

- (void)updateEnvironment {
    BOOL isInline = NO;
    if (@available(iOS 26.0, *)) {
        isInline = self.traitCollection.tabAccessoryEnvironment == UITabAccessoryEnvironmentInline;
    }
    _inline = isInline;
    // Inline, the strip shares a row with the minimized tab bar: one line of
    // text, and no stop button (too small a target there; scrolling back up
    // brings the full strip and the button back).
    _textStack.axis = isInline ? UILayoutConstraintAxisHorizontal : UILayoutConstraintAxisVertical;
    _textStack.spacing = isInline ? 6.0 : 0.0;
    _textStack.alignment = isInline ? UIStackViewAlignmentFirstBaseline : UIStackViewAlignmentFill;
    _stopButton.hidden = isInline || !self.stopHandler;
    _ringSize.constant = isInline ? 20.0 : 24.0;
    ApolloLog(@"[TabAccessory] progress view environment inline=%d", isInline);
}

- (void)updateText {
    _titleLabel.text = self.title;
    _detailLabel.text = self.detail;
    _detailLabel.hidden = self.detail.length == 0;
    self.accessibilityLabel = self.title;
}

- (void)setTitle:(NSString *)title {
    _title = [title copy] ?: @"";
    [self updateText];
}

- (void)setDetail:(NSString *)detail {
    _detail = [detail copy];
    [self updateText];
}

- (void)setProgress:(double)progress {
    _progress = progress;
    _ring.progress = progress;
}

- (void)setStopHandler:(dispatch_block_t)stopHandler {
    _stopHandler = [stopHandler copy];
    _stopButton.hidden = _inline || !stopHandler;
    _stopButton.enabled = YES;
}

- (void)setStopAccessibilityLabel:(NSString *)label {
    _stopAccessibilityLabel = [label copy] ?: @"Stop";
    _stopButton.accessibilityLabel = _stopAccessibilityLabel;
}

- (void)showStoppingWithTitle:(NSString *)title {
    self.title = title;
    _stopButton.enabled = NO;
}

- (void)stopTapped {
    _stopButton.enabled = NO;
    if (self.stopHandler) self.stopHandler();
}

- (NSArray *)accessibilityElements {
    NSMutableArray *elements = [NSMutableArray array];
    for (UIView *view in @[_titleLabel, _detailLabel, _stopButton]) {
        if (!view.hidden) [elements addObject:view];
    }
    return elements;
}

@end
