#import "settings/ApolloSpinnerViewController.h"

#import <CoreHaptics/CoreHaptics.h>
#import <QuartzCore/QuartzCore.h>
#import "ApolloCommon.h"
#import "ApolloThemeRuntime.h"
#import "UserDefaultConstants.h"
#import "settings/ApolloSpinnerArtwork.gen.h"

// Keep the original icon geometry as vector paths, then rasterize once at the
// display's scale. Rotation never redraws the artwork or parses SVGs per frame.
static UIImage *ApolloSpinnerArtwork(CGFloat scale, NSInteger icon, UIUserInterfaceStyle style) {
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = scale;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(360, 360) format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGContextRef ctx = context.CGContext;
        CGContextScaleCTM(ctx, 360.0 / 1280.0, 360.0 / 1280.0);
        BOOL dark = style == UIUserInterfaceStyleDark;
        switch (icon) {
            case 1: HeliosSpinnerDraw(ctx, dark); break;
            case 2: StanleySpinnerDraw(ctx, dark); break;
            default: ApolloSpinnerDraw(ctx, dark); break;
        }
    }];
}

@class ApolloSpinnerViewController;

// CADisplayLink retains its target. This weak intermediary lets a popped page
// deallocate even if UIKit interrupts its normal disappearance callbacks.
@interface ApolloSpinnerDisplayTarget : NSObject
@property (nonatomic, weak) ApolloSpinnerViewController *owner;
- (void)tick:(CADisplayLink *)link;
@end

@interface ApolloSpinnerViewController ()
@property (nonatomic, strong) UIControl *spinSurface;
@property (nonatomic, strong) UIImageView *artwork;
@property (nonatomic, strong) UIView *artworkContainer;
@property (nonatomic) NSInteger selectedIcon;
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, strong) CHHapticEngine *hapticEngine;
@property (nonatomic, copy) NSArray<id<CHHapticPatternPlayer>> *hapticPlayers;
@property (nonatomic) BOOL engineRunning;
@property (nonatomic) BOOL visible;
@property (nonatomic) BOOL dragging;
@property (nonatomic) CGFloat angle;
@property (nonatomic) CGFloat angularVelocity;
@property (nonatomic) CGPoint previousTouch;
@property (nonatomic) CGPoint gestureStartTouch;
@property (nonatomic) CFTimeInterval previousFrame;
@property (nonatomic) CFTimeInterval lastHaptic;
@property (nonatomic) CGFloat hapticTravel;
@property (nonatomic) CGFloat motionStartAngle;
@property (nonatomic) CGFloat motionTargetAngle;
@property (nonatomic) CFTimeInterval motionDuration;
@property (nonatomic) CGFloat lastMotionAngle;
@property (nonatomic) CFTimeInterval motionElapsed;
@property (nonatomic) BOOL grabbed;
@property (nonatomic) BOOL hubGesture;
- (void)tick:(CADisplayLink *)link;
@end

@implementation ApolloSpinnerDisplayTarget
- (void)tick:(CADisplayLink *)link { [self.owner tick:link]; }
@end

@implementation ApolloSpinnerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    NSInteger savedIcon = [NSUserDefaults.standardUserDefaults integerForKey:UDKeySpinnerSelectedIcon];
    self.selectedIcon = savedIcon >= 0 && savedIcon < 3 ? savedIcon : 0;
    self.title = @"";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.view.backgroundColor = ApolloThemePageBackgroundColor() ?: UIColor.systemGroupedBackgroundColor;

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.delaysContentTouches = NO;
    scroll.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];
    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 20;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];
    UIStackView *visual = [[UIStackView alloc] init];
    visual.axis = UILayoutConstraintAxisVertical;
    visual.alignment = UIStackViewAlignmentCenter;
    visual.spacing = 20;
    [stack addArrangedSubview:visual];

    self.spinSurface = [[UIControl alloc] init];
    self.spinSurface.accessibilityIdentifier = @"apollo.spinner.surface";
    self.spinSurface.isAccessibilityElement = YES;
    self.spinSurface.accessibilityTraits = UIAccessibilityTraitButton;
    self.spinSurface.accessibilityHint = @"Use the Spin accessibility action to spin the icon.";
    self.spinSurface.accessibilityCustomActions = @[
        [[UIAccessibilityCustomAction alloc] initWithName:@"Spin" target:self selector:@selector(accessibilitySpin)]
    ];
    [self.spinSurface addTarget:self action:@selector(grabSpinner) forControlEvents:UIControlEventTouchDown];
    [self.spinSurface addTarget:self action:@selector(releaseGrab)
              forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragSpinner:)];
    pan.maximumNumberOfTouches = 1;
    [self.spinSurface addGestureRecognizer:pan];
    [scroll.panGestureRecognizer requireGestureRecognizerToFail:pan];
    [visual addArrangedSubview:self.spinSurface];

    // Press scale and rotation have separate owners. Touches lift the mascot
    // without translating it or interrupting the spin.
    self.artworkContainer = [[UIView alloc] init];
    self.artworkContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.artworkContainer.userInteractionEnabled = NO;
    [self.spinSurface addSubview:self.artworkContainer];
    self.artwork = [[UIImageView alloc] initWithImage:ApolloSpinnerArtwork(self.traitCollection.displayScale, self.selectedIcon, self.traitCollection.userInterfaceStyle)];
    self.artwork.translatesAutoresizingMaskIntoConstraints = NO;
    self.artwork.contentMode = UIViewContentModeScaleAspectFit;
    self.artwork.isAccessibilityElement = NO;
    self.artwork.layer.shadowColor = UIColor.blackColor.CGColor;
    self.artwork.layer.shadowOpacity = 0.18;
    self.artwork.layer.shadowRadius = 10;
    self.artwork.layer.shadowOffset = CGSizeMake(0, 7);
    [self.artworkContainer addSubview:self.artwork];

    [self updateIconMenu];

    // The mascot alone occupies the center in both orientations.
    NSLayoutConstraint *center = [stack.centerYAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.centerYAnchor];
    // Keep the same 300-point play surface centered even when its transparent
    // padding extends beyond the short landscape safe area.
    scroll.clipsToBounds = NO;
    NSLayoutConstraint *preferredSide = [self.spinSurface.widthAnchor constraintEqualToConstant:300];
    // Beat the UIImageView's intrinsic compression resistance,
    // while still allowing narrow screens to constrain the play surface.
    preferredSide.priority = UILayoutPriorityRequired - 1;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.contentLayoutGuide.heightAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.heightAnchor],
        [stack.centerXAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.centerXAnchor],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-48], center,
        [scroll.contentLayoutGuide.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor],
        [visual.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [self.spinSurface.widthAnchor constraintLessThanOrEqualToAnchor:visual.widthAnchor], preferredSide,
        [self.spinSurface.heightAnchor constraintEqualToAnchor:self.spinSurface.widthAnchor],
        [self.artworkContainer.centerXAnchor constraintEqualToAnchor:self.spinSurface.centerXAnchor],
        [self.artworkContainer.centerYAnchor constraintEqualToAnchor:self.spinSurface.centerYAnchor],
        [self.artworkContainer.widthAnchor constraintEqualToAnchor:self.spinSurface.widthAnchor],
        [self.artworkContainer.heightAnchor constraintEqualToAnchor:self.spinSurface.heightAnchor],
        [self.artwork.centerXAnchor constraintEqualToAnchor:self.artworkContainer.centerXAnchor],
        [self.artwork.centerYAnchor constraintEqualToAnchor:self.artworkContainer.centerYAnchor],
        [self.artwork.widthAnchor constraintEqualToAnchor:self.artworkContainer.widthAnchor multiplier:1.2],
        [self.artwork.heightAnchor constraintEqualToAnchor:self.artwork.widthAnchor]
    ]];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(catchSpinner)
                                               name:UIApplicationWillResignActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(catchSpinner)
                                               name:UIAccessibilityReduceMotionStatusDidChangeNotification object:nil];
}

- (void)updateIconMenu {
    NSArray<NSString *> *names = @[@"Apollo", @"Helios", @"Stanley"];
    NSMutableArray<UIAction *> *actions = [NSMutableArray array];
    __weak typeof(self) weakSelf = self;
    [names enumerateObjectsUsingBlock:^(NSString *name, NSUInteger index, BOOL *stop) {
        UIAction *action = [UIAction actionWithTitle:name image:nil identifier:nil handler:^(__unused UIAction *action) {
            typeof(self) self = weakSelf;
            if (!self || self.selectedIcon == (NSInteger)index) return;
            self.selectedIcon = index;
            [NSUserDefaults.standardUserDefaults setInteger:index forKey:UDKeySpinnerSelectedIcon];
            UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
            [feedback impactOccurredWithIntensity:0.65];
            // Swapping the image preserves the active spin and its endpoint.
            self.artwork.image = ApolloSpinnerArtwork(self.traitCollection.displayScale, index, self.traitCollection.userInterfaceStyle);
            [self updateIconMenu];
            ApolloLog(@"[Spinner] Selected icon %@", name);
        }];
        action.state = self.selectedIcon == (NSInteger)index ? UIMenuElementStateOn : UIMenuElementStateOff;
        [actions addObject:action];
    }];
    UIMenu *menu = [UIMenu menuWithTitle:@"" children:actions];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"Icon ▾" menu:menu];
    self.navigationItem.rightBarButtonItem.accessibilityLabel = @"Choose spinner icon";
    self.navigationItem.rightBarButtonItem.accessibilityValue = names[self.selectedIcon];
    self.spinSurface.accessibilityLabel = [names[self.selectedIcon] stringByAppendingString:@" spinner"];
}

- (BOOL)accessibilitySpin {
    [self spin];
    return YES;
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]
        || self.traitCollection.displayScale != previousTraitCollection.displayScale) {
        // Replace only the rasterized artwork, preserving the active gesture,
        // rotation and its planned upright endpoint when appearance changes.
        self.artwork.image = ApolloSpinnerArtwork(self.traitCollection.displayScale,
            self.selectedIcon, self.traitCollection.userInterfaceStyle);
        self.view.backgroundColor = ApolloThemePageBackgroundColor() ?: UIColor.systemGroupedBackgroundColor;
        ApolloLog(@"[Spinner] Appearance changed to %@", self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark ? @"dark" : @"light");
    }
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    self.visible = YES;
    ApolloLog(@"[Spinner] Page visible; haptics supported=%d", CHHapticEngine.capabilitiesForHardware.supportsHaptics);
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    self.visible = NO;
    [self catchSpinner];
}

- (void)dealloc {
    [_displayLink invalidate];
    [_hapticEngine stopWithCompletionHandler:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Spin physics

- (void)grabSpinner {
    self.grabbed = YES;
    CGFloat scale = UIAccessibilityIsReduceMotionEnabled() ? 1.02 : 1.10;
    [UIView animateWithDuration:0.16 delay:0
                       options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                    animations:^{ self.artworkContainer.transform = CGAffineTransformMakeScale(scale, scale); }
                    completion:nil];
    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [feedback impactOccurred];
    [self prepareHaptics];
}

- (void)releaseGrab {
    self.grabbed = NO;
    if (!self.visible || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
        [self.artworkContainer.layer removeAllAnimations];
        self.artworkContainer.transform = CGAffineTransformIdentity;
    } else {
        [UIView animateWithDuration:UIAccessibilityIsReduceMotionEnabled() ? 0.15 : 0.55
                              delay:0 usingSpringWithDamping:0.72 initialSpringVelocity:0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                         animations:^{ self.artworkContainer.transform = CGAffineTransformIdentity; }
                         completion:nil];
    }
    // A tap only releases the visual grab; existing angular momentum survives.
    if (!self.dragging && !self.displayLink) [self stopHaptics];
}

- (void)spin {
    if (!self.visible || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    self.dragging = NO;
    CGFloat limit = UIAccessibilityIsReduceMotionEnabled() ? 7 : 36;
    self.angularVelocity = MIN(limit, MAX(10, fabs(self.angularVelocity) + 7)) * (self.angularVelocity < 0 ? -1 : 1);
    [self prepareHaptics];
    [self coastToUpright];

    ApolloLog(@"[Spinner] Spin started");
}

- (void)catchSpinner {
    [self freezeMotion];
    [self releaseGrab];
    if (!self.visible || UIApplication.sharedApplication.applicationState != UIApplicationStateActive || fabs(self.angle) < 0.001) {
        self.angle = 0;
        self.artwork.transform = CGAffineTransformIdentity;
        return;
    }
    // Releasing a stationary drag also returns upright. Merely tapping the
    // mascot never calls this path and never cancels angular momentum.
    [self beginMotionTo:0 duration:MAX(0.18, fabs(self.angle) / 6)];
    [self prepareHaptics];
}

- (void)freezeMotion {
    self.dragging = NO;
    self.angularVelocity = 0;
    self.previousFrame = 0;
    self.hapticTravel = 0;
    [self.displayLink invalidate];
    self.displayLink = nil;

    [self stopHaptics];
}

- (void)coastToUpright {
    if (fabs(self.angularVelocity) < 0.08) { [self catchSpinner]; return; }
    CGFloat direction = self.angularVelocity < 0 ? -1 : 1;
    // Even a gentle deliberate flick has enough energy to finish one turn,
    // rather than crawling or reversing to reach upright. Above this small
    // floor the actual release speed controls the speed and number of turns.
    CGFloat speed = MAX(7, fabs(self.angularVelocity));
    // Every release has the same short slowdown. Flick strength changes how
    // far it turns within that time, rather than extending the animation.
    // Reference recording: visible motion runs from about 1.9s to 4.4s.
    CFTimeInterval duration = 2.5;
    // Cubic ease-out integrates to initialSpeed * duration / 3. Match that
    // distance when choosing a full turn so the slower tail does not boost
    // the release speed just to cover the old constant-deceleration distance.
    CGFloat projected = self.angle + direction * speed * duration / 3;
    CGFloat target = round(projected / (2 * M_PI)) * (2 * M_PI);
    if ((target - self.angle) * direction <= 0.15) target += direction * 2 * M_PI;
    // Plan the terminal angle at release. A single deceleration reaches zero
    // speed exactly at that upright angle; there is no second homing phase,
    // spring-back, or angle correction after the spin has stopped.
    [self beginMotionTo:target duration:duration];
}

- (void)beginMotionTo:(CGFloat)target duration:(CFTimeInterval)duration {
    self.motionStartAngle = self.angle;
    self.motionTargetAngle = target;
    self.motionDuration = duration;
    self.lastMotionAngle = self.angle;
    self.motionElapsed = 0;
    self.previousFrame = 0;

    [self startDisplayLink];
}

- (void)startDisplayLink {
    if (self.displayLink) return;
    ApolloSpinnerDisplayTarget *target = [[ApolloSpinnerDisplayTarget alloc] init];
    target.owner = self;
    self.previousFrame = 0;
    self.displayLink = [CADisplayLink displayLinkWithTarget:target selector:@selector(tick:)];
    [self.displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

- (void)tick:(CADisplayLink *)link {
    if (!self.visible || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
        [self catchSpinner];
        return;
    }
    if (!self.previousFrame) { self.previousFrame = link.timestamp; return; }
    CFTimeInterval dt = MIN(link.timestamp - self.previousFrame, 1.0 / 15.0);
    self.previousFrame = link.timestamp;
    self.motionElapsed += dt;
    CGFloat t = MIN(1, self.motionElapsed / self.motionDuration);
    CGFloat distance = self.motionTargetAngle - self.motionStartAngle;
    // Brake more strongly early, then linger through the final rotation.
    // Position, velocity and acceleration all reach their resting values
    // continuously at the planned upright endpoint (no separate snap).
    CGFloat remaining = 1 - t;
    CGFloat angle = self.motionStartAngle + distance * (1 - remaining * remaining * remaining);
    self.angularVelocity = 3 * distance * remaining * remaining / self.motionDuration;
    [self rotateBy:angle - self.lastMotionAngle];
    self.lastMotionAngle = angle;
    if (t >= 1) {
        [self freezeMotion];
        self.angle = 0;
        self.artwork.transform = CGAffineTransformIdentity;
        ApolloLog(@"[Spinner] Settled upright at 0 degrees");
    }
}

- (void)dragSpinner:(UIPanGestureRecognizer *)pan {
    if (!self.visible || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    if (pan.state != UIGestureRecognizerStateBegan && !self.dragging) return;
    CGPoint point = [pan locationInView:self.spinSurface];
    if (pan.state == UIGestureRecognizerStateBegan) {
        [self freezeMotion];
        self.dragging = YES;
        if (!self.grabbed) [self grabSpinner];
        [self.artworkContainer.layer removeAllAnimations];
        // Recover the movement before the pan recognizer crossed its threshold.
        CGPoint translation = [pan translationInView:self.spinSurface];
        self.previousTouch = CGPointMake(point.x - translation.x, point.y - translation.y);
        self.gestureStartTouch = self.previousTouch;
        self.hubGesture = hypot(self.previousTouch.x - CGRectGetMidX(self.spinSurface.bounds),
                                self.previousTouch.y - CGRectGetMidY(self.spinSurface.bounds)) < 45;

        [self prepareHaptics];
    }
    if (pan.state == UIGestureRecognizerStateBegan || pan.state == UIGestureRecognizerStateChanged) {
        CGPoint center = CGPointMake(CGRectGetMidX(self.spinSurface.bounds), CGRectGetMidY(self.spinSurface.bounds));
        CGFloat x = point.x - center.x, y = point.y - center.y;
        CGFloat px = self.previousTouch.x - center.x, py = self.previousTouch.y - center.y;
        CGFloat radius = hypot(x, y);
        CGFloat delta;
        CGPoint velocity = [pan velocityInView:self.spinSurface];
        if (!self.hubGesture && radius > 30 && hypot(px, py) > 30) {
            delta = atan2(y, x) - atan2(py, px);
            delta = atan2(sin(delta), cos(delta)); // Seam at +/- pi is not a full revolution.
        } else {
            // A swipe through the hub still feels useful without the angular
            // singularity throwing the mascot around as the radius approaches 0.
            CGPoint movement = CGPointMake(point.x - self.previousTouch.x, point.y - self.previousTouch.y);
            delta = [self linearAngularVelocityForVelocity:movement];
        }
        self.angularVelocity = [self angularVelocityForTouch:point velocity:velocity];
        CGFloat limit = UIAccessibilityIsReduceMotionEnabled() ? 7 : 36;
        self.angularVelocity = MAX(-limit, MIN(limit, self.angularVelocity));
        [self rotateBy:delta];
        self.previousTouch = point;
        // Rotation is the dominant gesture: there is deliberately no position
        // offset, so trying to flick never drags the mascot away from its hub.
        CGFloat scale = UIAccessibilityIsReduceMotionEnabled() ? 1.02 : 1.10;
        self.artworkContainer.transform = CGAffineTransformMakeScale(scale, scale);
    } else if (pan.state == UIGestureRecognizerStateEnded) {
        self.dragging = NO;
        CGPoint velocity = [pan velocityInView:self.spinSurface];
        CGFloat release = [self angularVelocityForTouch:point velocity:velocity];
        CGFloat limit = UIAccessibilityIsReduceMotionEnabled() ? 7 : 36;
        self.angularVelocity = MAX(-limit, MIN(limit, release));
        // Holding the finger still before release should catch, not relaunch.
        if (hypot(velocity.x, velocity.y) < 20
            || fabs(self.angularVelocity) < 0.08) {
            [self catchSpinner];
        } else {
            [self coastToUpright];
            ApolloLog(@"[Spinner] Flick released at %.2f rad/s", self.angularVelocity);
        }
        [self releaseGrab];
    } else if (pan.state == UIGestureRecognizerStateCancelled || pan.state == UIGestureRecognizerStateFailed) {
        [self catchSpinner];
    }
}

// Near the hub, use the side where the finger first grabbed the icon.
// UIKit's downward-positive coordinates make right-side downward motion
// clockwise, left-side downward motion counterclockwise, and vice versa above
// and below the hub. Use the same mapping while dragging and when releasing.
- (CGFloat)linearAngularVelocityForVelocity:(CGPoint)velocity {
    CGFloat x = self.gestureStartTouch.x - CGRectGetMidX(self.spinSurface.bounds);
    CGFloat y = self.gestureStartTouch.y - CGRectGetMidY(self.spinSurface.bounds);
    CGFloat lever = MAX(50, self.spinSurface.bounds.size.width * 0.3);
    if (fabs(velocity.x) >= fabs(velocity.y)) return (y > 0 ? -velocity.x : velocity.x) / lever;
    return (x < 0 ? -velocity.y : velocity.y) / lever;
}

- (CGFloat)angularVelocityForTouch:(CGPoint)point velocity:(CGPoint)velocity {
    CGFloat x = point.x - CGRectGetMidX(self.spinSurface.bounds);
    CGFloat y = point.y - CGRectGetMidY(self.spinSurface.bounds);
    CGFloat radius = hypot(x, y);
    CGFloat linear = [self linearAngularVelocityForVelocity:velocity];
    if (self.hubGesture || radius <= 30) return linear;
    CGFloat angular = (x * velocity.y - y * velocity.x) / (radius * radius);
    // Long, hard flicks can end far outside the icon, reducing the measured
    // angular speed. Boost their magnitude without ever replacing the torque's
    // sign: doing so used to reverse a right-side downward flick on release.
    if (fabs(angular) < fabs(linear) * 0.25) {
        return fabs(angular) > 0.0001 ? copysign(fabs(linear), angular) : linear;
    }
    return angular;
}

- (void)rotateBy:(CGFloat)delta {
    self.angle = remainder(self.angle + delta, M_PI * 2);
    self.artwork.transform = CGAffineTransformMakeRotation(self.angle);
    // Distance, not a timer: tactile detents remain attached to the artwork
    // when dragging backwards, changing speed, or coasting to a stop.
    self.hapticTravel += fabs(delta);
    if (self.hapticTravel >= M_PI / 6) {
        self.hapticTravel = fmod(self.hapticTravel, M_PI / 6);
        [self playHaptic];
    }
}

#pragma mark - Haptics (no audio session or sound)

- (void)prepareHaptics {
    if (!CHHapticEngine.capabilitiesForHardware.supportsHaptics || self.engineRunning) return;
    NSError *error = nil;
    if (!self.hapticEngine) {
        self.hapticEngine = [[CHHapticEngine alloc] initAndReturnError:&error];
        if (!self.hapticEngine) {
            ApolloLog(@"[Spinner] Could not create haptic engine (%ld)", (long)error.code);
            return;
        }
        self.hapticEngine.playsHapticsOnly = YES;
        __weak typeof(self) weakSelf = self;
        __weak CHHapticEngine *weakEngine = self.hapticEngine;
        self.hapticEngine.stoppedHandler = ^(CHHapticEngineStoppedReason reason) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!weakEngine || weakSelf.hapticEngine != weakEngine) return;
                weakSelf.engineRunning = NO;
                ApolloLog(@"[Spinner] Haptic engine stopped (%ld)", (long)reason);
            });
        };
        self.hapticEngine.resetHandler = ^{
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!weakEngine || weakSelf.hapticEngine != weakEngine) return;
                weakSelf.engineRunning = NO;
                weakSelf.hapticPlayers = nil;
                // Recreate players only while the user is still interacting.
                if (weakSelf.visible && (weakSelf.dragging || weakSelf.displayLink)) [weakSelf prepareHaptics];
            });
        };
    }
    if (![self.hapticEngine startAndReturnError:&error]) {
        ApolloLog(@"[Spinner] Could not start haptics (%ld)", (long)error.code);
        return;
    }
    self.engineRunning = YES;
    if (self.hapticPlayers.count == 3) return;
    NSMutableArray *players = [NSMutableArray array];
    for (NSNumber *strength in @[@0.10, @0.15, @0.22]) {
        CHHapticEventParameter *intensity = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:strength.floatValue];
        CHHapticEventParameter *sharpness = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:0.45];
        CHHapticEvent *event = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticTransient parameters:@[intensity, sharpness] relativeTime:0];
        CHHapticPattern *pattern = [[CHHapticPattern alloc] initWithEvents:@[event] parameters:@[] error:&error];
        id<CHHapticPatternPlayer> player = pattern ? [self.hapticEngine createPlayerWithPattern:pattern error:&error] : nil;
        if (!player) {
            ApolloLog(@"[Spinner] Could not prepare haptic pattern (%ld)", (long)error.code);
            [self stopHaptics];
            return;
        }
        [players addObject:player];
    }
    self.hapticPlayers = players;
}

- (void)playHaptic {
    CFTimeInterval now = CACurrentMediaTime();
    if (!self.engineRunning || self.hapticPlayers.count != 3 || now - self.lastHaptic < 0.03) return;
    self.lastHaptic = now;
    CGFloat speed = fabs(self.angularVelocity);
    NSUInteger index = speed > 12 ? 2 : speed > 5 ? 1 : 0;
    NSError *error = nil;
    if (![self.hapticPlayers[index] startAtTime:CHHapticTimeImmediate error:&error]) {
        ApolloLog(@"[Spinner] Haptic playback interrupted (%ld)", (long)error.code);
        [self stopHaptics];
    }
}

- (void)stopHaptics {
    // Discard a stopped engine rather than allowing an asynchronous stop from
    // the previous interaction to race a new start on the same engine.
    self.hapticEngine.stoppedHandler = ^(__unused CHHapticEngineStoppedReason reason) {};
    self.hapticEngine.resetHandler = ^{};
    [self.hapticEngine stopWithCompletionHandler:nil];
    self.hapticEngine = nil;
    self.hapticPlayers = nil;
    self.engineRunning = NO;
    self.lastHaptic = 0;
}

@end
