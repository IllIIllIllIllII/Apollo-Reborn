#import "ApolloDuoSplitDivider.h"
#import "ApolloDuoDividerGeometry.h"
#import "ApolloThemeRuntime.h"
#import "ApolloCommon.h"

// A hairline separates the columns. Until the first resize, a short dimmed
// line marks the grip; after it, nothing does. Holding anywhere along the
// separator raises a Liquid Glass pill around the line at full strength, at
// the finger's height; it follows the finger and stays briefly after the
// columns settle. Tapping the separator raises it too. While the pill shows,
// a plain drag on it moves the divider without the hold.
// The line matches iOS's own multitasking grabber on the Duo (10 x 140 px at
// 3x). The pill leaves 6 points of glass all around it.
static const CGSize kApolloDuoDividerLineSize = {10.0 / 3.0, 140.0 / 3.0};
static const CGSize kApolloDuoDividerPillSize = {10.0 / 3.0 + 12, 140.0 / 3.0 + 12};
// The grip's own touch target, tall enough for the whole pill.
static const CGSize kApolloDuoDividerGripSize = {44, 68};
// A hold or tap this close to the separator, at any height, reaches it too.
// Narrow enough to leave the columns' content to its own taps.
static const CGFloat kApolloDuoDividerSeparatorReach = 12;
static const CGFloat kApolloDuoDividerRestAlpha = 0.5;
static const NSTimeInterval kApolloDuoDividerLinger = 2.0;
static const NSTimeInterval kApolloDuoDividerSettle = 0.2;
// The longest glide between two touch bursts; a longer gap (the finger
// resting) catches up within this.
static const NSTimeInterval kApolloDuoDividerGlideLimit = 0.08;

// Whole-pixel origins keep the line's edges even; at a half point its left
// edge rendered cut off and its right edge soft.
static CGFloat ApolloDuoDividerPixelFloor(CGFloat value, CGFloat scale) {
    return scale > 0 ? floor(value * scale) / scale : value;
}

@interface ApolloDuoSplitDivider () <UIGestureRecognizerDelegate>
@property(nonatomic) BOOL dragging;
@property(nonatomic) BOOL available;
@property(nonatomic) BOOL pillShown;
@property(nonatomic) NSUInteger lingerGeneration;
@property(nonatomic) CGFloat divider;
@property(nonatomic) CGFloat trailingInset;
@property(nonatomic) CGFloat startingWidth;
@property(nonatomic) CGFloat touchOffset;
// The grip's center height while raised by a touch; NAN centers it.
@property(nonatomic) CGFloat gripY;
@property(nonatomic) CGSize startingSize;
@property(nonatomic) int lastLimit;
@property(nonatomic) CFTimeInterval lastGlide;
@property(nonatomic) CFTimeInterval glideInterval;
@property(nonatomic, strong) UILongPressGestureRecognizer *press;
@property(nonatomic, strong) UIPanGestureRecognizer *pan;
@property(nonatomic, strong) UIView *resting;
@property(nonatomic, strong) UIView *halo;
@property(nonatomic, strong) UIView *restLine;
@property(nonatomic, strong) UIView *line;
@property(nonatomic, strong) UIVisualEffectView *pill;
@property(nonatomic, strong) UIView *separator;
@property(nonatomic, strong) UITapGestureRecognizer *reset;
@property(nonatomic, strong) UITapGestureRecognizer *reveal;
@property(nonatomic, strong) UIView *overlay;
@property(nonatomic, strong) UIImpactFeedbackGenerator *impact;
@property(nonatomic, strong) UISelectionFeedbackGenerator *selection;
@property(nonatomic, strong) CADisplayLink *displayLink;
@property(nonatomic) CGFloat appliedWidth;
@end

@implementation ApolloDuoSplitDivider
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.clearColor;
        self.opaque = NO;
        self.isAccessibilityElement = YES;
        self.accessibilityLabel = @"Feed and thread divider";
        self.accessibilityTraits = UIAccessibilityTraitAdjustable;
        self.accessibilityCustomActions = @[[[UIAccessibilityCustomAction alloc] initWithName:@"Equal widths" target:self selector:@selector(resetWidth)]];
        // The recognizers live on the superview (see didMoveToSuperview).
        self.press = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(moved:)];
        self.press.minimumPressDuration = 0.25;
        self.press.allowableMovement = 10;
        self.press.delegate = self;
        self.pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(moved:)];
        self.pan.maximumNumberOfTouches = 1;
        self.pan.delegate = self;
        self.reset = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(doubleTapped:)];
        self.reset.numberOfTapsRequired = 2;
        self.reset.delegate = self;
        [self.reset requireGestureRecognizerToFail:self.press];
        self.reveal = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(revealed:)];
        self.reveal.delegate = self;
        [self.reveal requireGestureRecognizerToFail:self.press];
        self.gripY = NAN;
        self.accessibilityHint = @"Swipe up or down to change the feed width. Use the Equal widths action to restore the default.";
        self.impact = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        self.selection = [UISelectionFeedbackGenerator new];
        [self buildGrip];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(cancel) name:UIApplicationWillResignActiveNotification object:nil];
    }
    return self;
}
- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    for (UIGestureRecognizer *gesture in [self recognizers]) [gesture.view removeGestureRecognizer:gesture];
    [_separator removeFromSuperview];
}
- (NSArray<UIGestureRecognizer *> *)recognizers { return @[self.press, self.pan, self.reset, self.reveal]; }
// The recognizers sit on the superview and take only touches on the grip or
// along the separator, so a hold works while the grip is hidden and other
// taps reach the content under it. The separator is the superview's too,
// below the grip, so the grip's glide doesn't move it.
- (void)willMoveToSuperview:(UIView *)superview {
    [super willMoveToSuperview:superview];
    for (UIGestureRecognizer *gesture in [self recognizers]) [gesture.view removeGestureRecognizer:gesture];
    [self.separator removeFromSuperview];
}
- (void)didMoveToSuperview {
    [super didMoveToSuperview];
    if (!self.superview) return;
    for (UIGestureRecognizer *gesture in [self recognizers]) [self.superview addGestureRecognizer:gesture];
    [self.superview insertSubview:self.separator belowSubview:self];
}
- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window) {
        [self cancel];
        [self showPill:NO animated:NO];
    } else {
        [self layoutGrip];
    }
}
// The resting line and halo dim as one group, so the halo never shows
// through the line. Grabbing crossfades them to the pill's own line, kept
// apart because glass under a translucent parent renders wrong. The pill has
// no effect until grabbed; its line sits in the content view, above the glass.
- (void)buildGrip {
    self.separator = [UIView new];
    self.separator.userInteractionEnabled = NO;
    self.separator.hidden = YES;
    self.resting = [UIView new];
    self.resting.userInteractionEnabled = NO;
    self.resting.layer.allowsGroupOpacity = YES;
    self.resting.alpha = [self restingAlpha];
    [self addSubview:self.resting];
    self.halo = [UIView new];
    self.halo.layer.cornerRadius = (kApolloDuoDividerLineSize.width + 2) / 2;
    [self.resting addSubview:self.halo];
    self.restLine = [self lineView];
    [self.resting addSubview:self.restLine];
    self.pill = [[UIVisualEffectView alloc] initWithEffect:nil];
    self.pill.userInteractionEnabled = NO;
    self.pill.clipsToBounds = YES;
    if (@available(iOS 26.0, *)) self.pill.cornerConfiguration = [UICornerConfiguration capsuleConfiguration];
    else self.pill.layer.cornerRadius = kApolloDuoDividerPillSize.width / 2;
    [self addSubview:self.pill];
    self.line = [self lineView];
    self.line.alpha = 0;
    [self.pill.contentView addSubview:self.line];
    [self layoutGrip];
    [self refreshColors];
}
- (UIView *)lineView {
    UIView *line = [UIView new];
    line.layer.cornerRadius = kApolloDuoDividerLineSize.width / 2;
    line.backgroundColor = UIColor.labelColor;
    return line;
}
// Zero until the grip is in a window, which lays it out again.
- (CGFloat)pixelScale { return self.traitCollection.displayScale; }
// The resting line sits exactly under the pill's, and the halo is a point
// wider all around.
- (void)layoutGrip {
    CGFloat scale = [self pixelScale];
    CGRect (^centered)(CGSize, CGSize) = ^CGRect(CGSize size, CGSize container) {
        return CGRectMake(ApolloDuoDividerPixelFloor((container.width - size.width) / 2, scale),
                          ApolloDuoDividerPixelFloor((container.height - size.height) / 2, scale), size.width, size.height);
    };
    CGSize grip = kApolloDuoDividerGripSize;
    self.resting.frame = CGRectMake(0, 0, grip.width, grip.height);
    self.pill.frame = centered(kApolloDuoDividerPillSize, grip);
    self.line.frame = centered(kApolloDuoDividerLineSize, kApolloDuoDividerPillSize);
    self.restLine.frame = CGRectOffset(self.line.frame, self.pill.frame.origin.x, self.pill.frame.origin.y);
    self.halo.frame = CGRectInset(self.restLine.frame, -1, -1);
}
// The grip's center for a divider at `x`, with its origin on a whole pixel.
- (CGPoint)gripCenterAtX:(CGFloat)x {
    CGFloat scale = [self pixelScale];
    CGFloat halfWidth = kApolloDuoDividerGripSize.width / 2, halfHeight = kApolloDuoDividerGripSize.height / 2;
    CGRect bounds = self.superview.bounds;
    CGFloat y = CGRectGetMidY(bounds);
    if (!isnan(self.gripY) && bounds.size.height > 2 * halfHeight)
        y = MAX(halfHeight, MIN(bounds.size.height - halfHeight, self.gripY));
    return CGPointMake(ApolloDuoDividerPixelFloor(x - halfWidth, scale) + halfWidth,
                       ApolloDuoDividerPixelFloor(y - halfHeight, scale) + halfHeight);
}
// Raises the grip at the touch's height, or centers it again (NAN).
- (void)moveGripToY:(CGFloat)y {
    self.gripY = y;
    [self.layer removeAnimationForKey:@"position"];
    self.center = [self gripCenterAtX:self.divider];
}
- (void)refreshColors {
    self.halo.backgroundColor = ApolloThemeCardBackgroundColor() ?: UIColor.secondarySystemBackgroundColor;
    self.separator.backgroundColor = ApolloThemeSeparatorColor() ?: UIColor.separatorColor;
}
- (CGFloat)restingAlpha { return self.hidesHandleAtRest ? 0 : kApolloDuoDividerRestAlpha; }
// A hidden grip lets taps through to the content under it; a visible one
// keeps them, so tapping the handle never opens what's beneath.
- (void)updateInteraction { self.userInteractionEnabled = self.pillShown || !self.hidesHandleAtRest; }
- (void)setHidesHandleAtRest:(BOOL)hides {
    if (_hidesHandleAtRest == hides) return;
    _hidesHandleAtRest = hides;
    [self updateInteraction];
    // While the pill shows, its fade restores the resting state.
    if (self.pillShown) return;
    [UIView animateWithDuration:self.window ? 0.25 : 0 delay:0 options:UIViewAnimationOptionBeginFromCurrentState
                     animations:^{ self.resting.alpha = [self restingAlpha]; } completion:nil];
}
- (void)tintColorDidChange {
    [super tintColorDidChange];
    [self refreshColors];
}
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self layoutGrip];
    [self refreshColors];
}
- (UIVisualEffect *)pillEffect {
    if (@available(iOS 26.0, *)) return [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial];
}
// Setting the effect inside an animation materializes the glass. Hiding also
// voids a pending linger.
- (void)showPill:(BOOL)shown animated:(BOOL)animated {
    if (!shown) self.lingerGeneration++;
    if (shown == self.pillShown) return;
    self.pillShown = shown;
    [self updateInteraction];
    UIVisualEffect *effect = shown ? [self pillEffect] : nil;
    void (^change)(void) = ^{
        self.pill.effect = effect;
        self.line.alpha = shown ? 1 : 0;
        self.resting.alpha = shown ? 0 : [self restingAlpha];
    };
    // Once hidden, the grip returns to the middle, where the resting line sits.
    void (^recenter)(BOOL) = ^(BOOL finished) {
        if (!shown && !self.pillShown && !self.dragging) [self moveGripToY:NAN];
    };
    if (animated) [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionBeginFromCurrentState animations:change completion:recenter];
    else { change(); recenter(YES); }
}
// Hides the pill after the settle and linger, unless a newer grab or hide
// comes first.
- (void)lingerThenHide {
    NSUInteger generation = ++self.lingerGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((kApolloDuoDividerSettle + kApolloDuoDividerLinger) * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ApolloDuoSplitDivider *strongSelf = weakSelf;
        if (!strongSelf || strongSelf.lingerGeneration != generation || strongSelf.dragging) return;
        [strongSelf showPill:NO animated:YES];
        ApolloLog(@"[DuoDivider] pill hidden");
    });
}
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gesture {
    if (gesture == self.pan && (!self.pillShown || self.dragging)) return NO;
    return self.available && self.window && (!self.canBegin || self.canBegin());
}
// Every touch in the superview asks; only those starting on the grip or
// along the separator count.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldReceiveTouch:(UITouch *)touch {
    if (!self.available) return NO;
    CGPoint point = [touch locationInView:self.superview];
    BOOL onGrip = CGRectContainsPoint(self.frame, point);
    BOOL onSeparator = fabs(point.x - self.divider) <= kApolloDuoDividerSeparatorReach;
    // Resetting needs a visible handle: a hidden one would hold back taps on
    // the content under it while waiting for a second tap.
    if (gesture == self.reset) return onGrip && self.userInteractionEnabled;
    // A tap only raises a hidden handle; a raised one leaves taps to resetting.
    if (gesture == self.reveal) return onSeparator && self.hidesHandleAtRest && !self.pillShown;
    if (gesture == self.pan) return onGrip && self.pillShown;
    if (!onGrip && !onSeparator) return NO;
    [self.impact prepare];
    return YES;
}
// While the pill shows, a drag that starts on it is the divider's, not an
// enclosing view's. Near the separator, a hold or tap is the divider's before
// the content's own long presses and taps.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)other {
    if (gesture == self.pan) return [other isKindOfClass:UIPanGestureRecognizer.class];
    BOOL content = other.view != self.superview && [other.view isDescendantOfView:self.superview];
    if (gesture == self.press) return content && ![other isKindOfClass:UIPanGestureRecognizer.class];
    if (gesture == self.reveal) return content && [other isKindOfClass:UITapGestureRecognizer.class];
    return NO;
}
- (void)updateWithDivider:(CGFloat)x trailingInset:(CGFloat)inset enabled:(BOOL)enabled {
    self.available = enabled;
    self.trailingInset = inset;
    if (self.dragging && (!enabled || !CGSizeEqualToSize(self.startingSize, self.superview.bounds.size))) {
        // Layout callbacks never resize columns recursively.
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf cancel]; });
    }
    self.hidden = !enabled;
    if (!enabled) [self showPill:NO animated:NO];
    // The separator follows the columns' actual edge, even mid-drag.
    CGFloat scale = [self pixelScale], hairline = scale > 0 ? 1.0 / scale : 0.5;
    self.separator.hidden = !enabled;
    self.separator.frame = CGRectMake(ApolloDuoDividerPixelFloor(x - hairline / 2, scale), 0, hairline, self.superview.bounds.size.height);
    self.bounds = (CGRect){CGPointZero, kApolloDuoDividerGripSize};
    // A drag places the grip itself, gliding it with the finger.
    if (!self.dragging) {
        self.divider = x;
        self.center = [self gripCenterAtX:x];
    }
    self.accessibilityValue = [NSString stringWithFormat:@"Feed %.0f percent, thread %.0f percent", x / MAX(1, self.superview.bounds.size.width) * 100, 100 - x / MAX(1, self.superview.bounds.size.width) * 100];
}
// The divider is still usable at the size the drag began in.
- (BOOL)dragStillValid {
    return self.available && self.window && (!self.canBegin || self.canBegin())
        && CGSizeEqualToSize(self.startingSize, self.superview.bounds.size);
}
- (void)beginDrag {
    self.dragging = YES;
    self.startingWidth = self.divider;
    self.startingSize = self.superview.bounds.size;
    self.lastLimit = ApolloDuoDividerLimit(self.divider, self.startingSize.width, self.trailingInset, 0);
    self.lastGlide = 0;
    self.glideInterval = 1.0 / 60.0;
    [self showPill:YES animated:YES];
    // A clear overlay above the native side rail keeps other touches off the
    // columns while they resize. Keep the gesture view in its original
    // hierarchy; moving it would cancel the held touch.
    self.overlay = [[UIView alloc] initWithFrame:self.window.bounds];
    self.overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.window addSubview:self.overlay];
    [self.impact impactOccurred];
    [self dragTo:self.divider feedback:NO];
    self.appliedWidth = self.divider;
    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(resizeFrame:)];
    [self.displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    ApolloLog(@"[DuoDivider] grabbed at %.1f", self.divider);
}
- (void)dragTo:(CGFloat)x feedback:(BOOL)feedback {
    CGFloat width = self.startingSize.width;
    self.divider = ApolloDuoDividerClamp(x, width, self.trailingInset);
    [self glideTo:[self gripCenterAtX:self.divider]];
    // Moving has no haptics; reaching a width limit still bumps.
    int limit = ApolloDuoDividerLimit(self.divider, width, self.trailingInset, self.lastLimit);
    if (feedback && limit && limit != self.lastLimit) [self.impact impactOccurredWithIntensity:1.0];
    self.lastLimit = limit;
}
// Each column reflow holds the main thread for its whole layout, so touches
// arrive in bursts. Move the grip on the render server, over the usual time
// between bursts, so it keeps gliding while a reflow runs instead of jumping
// when it ends.
- (void)glideTo:(CGPoint)center {
    CFTimeInterval now = CACurrentMediaTime(), gap = now - self.lastGlide;
    BOOL first = self.lastGlide <= 0;
    // Touches under 4 ms apart belong to the same burst.
    if (first || gap >= 0.004) {
        if (!first) self.glideInterval = (self.glideInterval + MIN(kApolloDuoDividerGlideLimit, gap)) / 2.0;
        self.lastGlide = now;
    }
    NSTimeInterval duration = first || UIAccessibilityIsReduceMotionEnabled() ? 0 : MAX(1.0 / 60.0, self.glideInterval);
    if (duration <= 0) {
        [self.layer removeAnimationForKey:@"position"];
        self.center = center;
        return;
    }
    [UIView animateWithDuration:duration delay:0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveLinear
                                | UIViewAnimationOptionAllowUserInteraction
                     animations:^{ self.center = center; } completion:nil];
}
// Coalesce touch samples to one UIKit width change per display frame. The
// same clock promptly cancels a hold if navigation/presentation changes.
- (void)resizeFrame:(CADisplayLink *)link {
    if (![self dragStillValid]) { [self cancel]; return; }
    if (fabs(self.appliedWidth - self.divider) < 0.5) return;
    self.appliedWidth = self.divider;
    if (self.changeWidth) self.changeWidth(self.divider, NO);
}
// The hold, or a plain drag while the pill shows.
- (void)moved:(UIGestureRecognizer *)gesture {
    CGFloat x = [gesture locationInView:self.superview].x;
    if (gesture.state == UIGestureRecognizerStateBegan) {
        // A hold raises the pill at the finger's height; a drag on the pill keeps it.
        if (gesture == self.press) [self moveGripToY:[gesture locationInView:self.superview].y];
        self.touchOffset = x - self.divider;
        [self beginDrag];
        if (gesture == self.pan) ApolloLog(@"[DuoDivider] dragged without a hold");
    } else if (gesture.state == UIGestureRecognizerStateChanged && self.dragging) {
        if (![self dragStillValid]) { [self cancel]; return; }
        [self dragTo:x - self.touchOffset feedback:YES];
    } else if (gesture.state == UIGestureRecognizerStateEnded && self.dragging) {
        if (![self dragStillValid]) { [self cancel]; return; }
        [self dragTo:x - self.touchOffset feedback:NO];
        CGFloat target = ApolloDuoDividerSnap(self.divider, self.startingSize.width, self.trailingInset);
        self.dragging = NO;
        self.divider = target;
        if (self.changeWidth) self.changeWidth(target, YES);
        [self.impact impactOccurredWithIntensity:0.7];
        [self finishDrag];
        [UIView animateWithDuration:UIAccessibilityIsReduceMotionEnabled() ? 0 : kApolloDuoDividerSettle delay:0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseOut
                         animations:^{ self.center = [self gripCenterAtX:target]; } completion:nil];
        [self lingerThenHide];
        ApolloLog(@"[DuoDivider] committed %.1f", target);
    } else if (gesture.state == UIGestureRecognizerStateCancelled || gesture.state == UIGestureRecognizerStateFailed) {
        [self cancel];
    }
}
- (void)finishDrag {
    [self.displayLink invalidate]; self.displayLink = nil;
    [self.overlay removeFromSuperview]; self.overlay = nil;
}
- (void)cancel {
    if (!self.dragging) return;
    self.dragging = NO;
    self.press.enabled = NO; self.press.enabled = YES;
    self.pan.enabled = NO; self.pan.enabled = YES;
    self.divider = self.startingWidth;
    [self.layer removeAnimationForKey:@"position"];
    self.center = [self gripCenterAtX:self.divider];
    if (self.changeWidth) self.changeWidth(self.startingWidth, NO);
    [self finishDrag];
    [self showPill:NO animated:NO];
    ApolloLog(@"[DuoDivider] cancelled");
}
- (void)adjustBy:(CGFloat)delta {
    if (!self.available || (self.canBegin && !self.canBegin())) return;
    [self cancel];
    CGFloat width = self.superview.bounds.size.width;
    CGFloat target = ApolloDuoDividerClamp(self.divider + delta * width, width, self.trailingInset);
    if (self.changeWidth) self.changeWidth(target, YES);
    [self.selection selectionChanged];
}
- (void)accessibilityIncrement { [self adjustBy:0.05]; }
- (void)accessibilityDecrement { [self adjustBy:-0.05]; }
// Raises the pill where the separator was tapped, for a plain drag.
- (void)revealed:(UITapGestureRecognizer *)tap {
    if (tap.state != UIGestureRecognizerStateRecognized || self.dragging) return;
    [self moveGripToY:[tap locationInView:self.superview].y];
    [self showPill:YES animated:YES];
    [self lingerThenHide];
    ApolloLog(@"[DuoDivider] raised by a tap at %.0f", self.center.y);
}
// No accessibilityActivate: a VoiceOver double-tap must not silently discard the
// saved width. Resetting stays on the explicit Equal widths custom action.
- (void)doubleTapped:(UITapGestureRecognizer *)tap {
    if (tap.state == UIGestureRecognizerStateRecognized) [self resetWidth];
}
- (BOOL)resetWidth { [self adjustBy:0.5 - self.divider / MAX(1, self.superview.bounds.size.width)]; return YES; }
@end
