// ApolloPostActionBar.xm — Liquid Glass styles for the post's action row at the
// top of a thread (CommentsQuickBarNode: upvote, downvote, save, reply, share,
// edit), chosen in Settings → Display & Navigation → Post Actions:
//  - Classic: Apollo's row.
//  - Capsule: every action evenly spaced in one glass capsule across the
//    content margins.
// In Capsule an active vote is a filled circle and the separators around the
// row are gone. The buttons stay Apollo's nodes: after Texture lays the row out
// they are re-spaced over a glass view drawn behind them, so voting,
// three-state voting and the stats-row touch handling keep working.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "ApolloClasses.h"
#import "ApolloCommon.h"
#import "ApolloState.h"
#import "ApolloSwiftRuntime.h"

@class ASDisplayNode;

typedef NS_ENUM(NSInteger, ApolloPostActionBarStyle) {
    ApolloPostActionBarStyleClassic = 0,
    ApolloPostActionBarStyleCapsule = 1,
};

// Posted by the Post Actions setting (CustomAPIViewController.m) when it changes.
static NSString *const ApolloPostActionBarStyleDidChangeNotification = @"ApolloPostActionBarStyleDidChange";

static const CGFloat kApolloPostActionBarCapsuleHeight = 44.0;
// Room above and below an active vote/save circle inside the capsule.
static const CGFloat kApolloPostActionBarVoteInset = 4.0;

static char kApolloPostActionBarGlassKey;
static char kApolloPostActionBarRadiusKey;
static char kApolloPostActionBarExtentKey;

static NSHashTable *sApolloPostActionBars;

// ASDisplayNode is only forward-declared here; message it through id.
static id ApolloPostActionBarNode(id object, const char *ivar) {
    return object ? ApolloObjectIvar(object, ivar) : nil;
}

static UIView *ApolloPostActionBarNodeView(id node) {
    if (!node || ![[node valueForKey:@"nodeLoaded"] boolValue]) return nil;
    id view = [node valueForKey:@"view"];
    return [view isKindOfClass:[UIView class]] ? view : nil;
}

// Apollo bounces a tapped button and its background with transform
// animations, and a transformed layer's frame is its scaled bounding box. So
// sizes come from bounds and placement from position (the center: nodes keep
// the default anchor point), which a transform leaves alone.
static CGSize ApolloPostActionBarSize(id node) {
    return [[node valueForKey:@"bounds"] CGRectValue].size;
}

static CGPoint ApolloPostActionBarPosition(id node) {
    return [[node valueForKey:@"position"] CGPointValue];
}

static BOOL ApolloPostActionBarNodeVisible(id node) {
    if (!node || [[node valueForKey:@"hidden"] boolValue]) return NO;
    return ApolloPostActionBarSize(node).width > 1.0;
}

static NSInteger ApolloPostActionBarCurrentStyle(void) {
    if (@available(iOS 26.0, *)) {
        // A saved 2 is the retired Split style: show Capsule.
        if (IsLiquidGlass()) return MAX(0, MIN(sPostActionBarStyle, ApolloPostActionBarStyleCapsule));
    }
    return ApolloPostActionBarStyleClassic;
}

static UIVisualEffectView *ApolloPostActionBarGlass(UIView *host) {
    UIVisualEffectView *glass = objc_getAssociatedObject(host, &kApolloPostActionBarGlassKey);
    if (glass) return glass;
    if (@available(iOS 26.0, *)) {
        glass = [[UIVisualEffectView alloc] initWithEffect:[UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular]];
        glass.cornerConfiguration = [UICornerConfiguration capsuleConfiguration];
    } else {
        return nil;
    }
    glass.userInteractionEnabled = NO;
    glass.clipsToBounds = YES;
    [host insertSubview:glass atIndex:0];
    objc_setAssociatedObject(host, &kApolloPostActionBarGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return glass;
}

static id ApolloPostActionBarHeader(id bar) {
    Class headerClass = ApolloClassCommentsHeaderCellNode;
    for (id node = [bar valueForKey:@"supernode"]; node; node = [node valueForKey:@"supernode"]) {
        if (headerClass && [node isKindOfClass:headerClass]) return node;
    }
    return nil;
}

#pragma mark - Layout

// An active vote (or save) fills Apollo's background node; make it a circle.
static void ApolloPostActionBarRoundBackground(id button, BOOL glass) {
    id background = ApolloPostActionBarNode(button, "backgroundNode");
    if (!background) return;
    NSNumber *original = objc_getAssociatedObject(background, &kApolloPostActionBarRadiusKey);
    if (!original) {
        original = [background valueForKey:@"cornerRadius"];
        objc_setAssociatedObject(background, &kApolloPostActionBarRadiusKey, original, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CGSize size = ApolloPostActionBarSize(background);
    // Before the button lays out its background has no size; its own layout
    // pass (below) rounds it then.
    if (glass && (size.width <= 0.0 || size.height <= 0.0)) return;
    CGFloat radius = glass ? MIN(size.width, size.height) / 2.0 : original.doubleValue;
    if (fabs([[background valueForKey:@"cornerRadius"] doubleValue] - radius) > 0.25) {
        [background setValue:@(radius) forKey:@"cornerRadius"];
    }
}

static void ApolloPostActionBarCenter(id button, CGFloat centerX, CGFloat centerY) {
    CGSize size = ApolloPostActionBarSize(button);
    // Whole-point edges, as Texture lays out.
    CGPoint position = CGPointMake(round(centerX - size.width / 2.0) + size.width / 2.0,
                                   round(centerY - size.height / 2.0) + size.height / 2.0);
    if (!CGPointEqualToPoint(ApolloPostActionBarPosition(button), position)) {
        [button setValue:[NSValue valueWithCGPoint:position] forKey:@"position"];
    }
}

static void ApolloPostActionBarSpread(NSArray *buttons, CGFloat minX, CGFloat maxX, CGFloat centerY) {
    if (buttons.count == 0) return;
    CGFloat slot = (maxX - minX) / buttons.count;
    for (NSUInteger index = 0; index < buttons.count; index++) {
        ApolloPostActionBarCenter(buttons[index], minX + slot * (index + 0.5), centerY);
    }
}

// fresh: Texture has just laid the row out, so the buttons sit where Apollo
// put them. Otherwise they may already be re-spaced, and the row's extent comes
// from the last fresh layout.
static void ApolloPostActionBarApply(id bar, BOOL fresh) {
    UIView *host = ApolloPostActionBarNodeView(bar);
    if (!host) return;
    BOOL glass = ApolloPostActionBarCurrentStyle() != ApolloPostActionBarStyleClassic;

    id up = ApolloPostActionBarNode(bar, "upvoteButton");
    id down = ApolloPostActionBarNode(bar, "downvoteButton");
    NSMutableArray *actions = [NSMutableArray array];
    for (NSString *name in @[ @"saveButton", @"replyButton", @"shareButton", @"editButton" ]) {
        id button = ApolloPostActionBarNode(bar, name.UTF8String);
        if (ApolloPostActionBarNodeVisible(button)) [actions addObject:button];
    }
    UIVisualEffectView *capsule = objc_getAssociatedObject(host, &kApolloPostActionBarGlassKey);

    id header = ApolloPostActionBarHeader(bar);
    for (NSString *name in @[ @"quickBarSeparatorNode", @"commentsSeparatorNode" ]) {
        id separator = ApolloPostActionBarNode(header, name.UTF8String);
        if (separator && [[separator valueForKey:@"hidden"] boolValue] != glass) {
            [separator setValue:@(glass) forKey:@"hidden"];
        }
    }
    for (id button in @[ up ?: NSNull.null, down ?: NSNull.null ]) {
        if (button != NSNull.null) ApolloPostActionBarRoundBackground(button, glass);
    }
    for (id button in actions) ApolloPostActionBarRoundBackground(button, glass);

    if (!glass || !ApolloPostActionBarNodeVisible(up) || !ApolloPostActionBarNodeVisible(down)) {
        capsule.hidden = YES;
        return;
    }

    // Apollo spaces the row between the post's content margins.
    NSMutableArray *all = [NSMutableArray arrayWithObjects:up, down, nil];
    [all addObjectsFromArray:actions];
    CGFloat minX = CGFLOAT_MAX, maxX = -CGFLOAT_MAX, circle = 0.0;
    for (id button in all) {
        CGSize size = ApolloPostActionBarSize(button);
        CGFloat centerX = ApolloPostActionBarPosition(button).x;
        minX = MIN(minX, centerX - size.width / 2.0);
        maxX = MAX(maxX, centerX + size.width / 2.0);
        // A circle fills its button, and the button is sized before its background.
        circle = MAX(circle, size.height);
        id background = ApolloPostActionBarNode(button, "backgroundNode");
        if (background) circle = MAX(circle, ApolloPostActionBarSize(background).height);
    }
    NSValue *extent = objc_getAssociatedObject(bar, &kApolloPostActionBarExtentKey);
    if (fresh || !extent) {
        objc_setAssociatedObject(bar, &kApolloPostActionBarExtentKey, [NSValue valueWithCGPoint:CGPointMake(minX, maxX)],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        minX = extent.CGPointValue.x;
        maxX = extent.CGPointValue.y;
    }
    // Taller than the row when it has to be: the capsule always clears the
    // circles, overhanging the row equally above and below.
    CGFloat height = MAX(kApolloPostActionBarCapsuleHeight, circle + 2.0 * kApolloPostActionBarVoteInset);
    CGFloat centerY = CGRectGetMidY(host.bounds);
    CGFloat top = round(centerY - height / 2.0);

    capsule = ApolloPostActionBarGlass(host);
    capsule.hidden = NO;
    capsule.frame = CGRectMake(minX, top, maxX - minX, height);
    ApolloPostActionBarSpread(all, minX, maxX, centerY);
}

static void ApolloPostActionBarRefreshAll(void) {
    for (id bar in sApolloPostActionBars.allObjects) {
        [bar setNeedsLayout];
        ApolloPostActionBarApply(bar, NO);
    }
}

static BOOL ApolloPostActionBarIsRegistered(id bar) {
    // Texture can lay out nodes that haven't loaded off the main thread; the
    // bar's main-thread pass styles those.
    return NSThread.isMainThread && bar && [sApolloPostActionBars containsObject:bar];
}

%hook _TtC6Apollo20CommentsQuickBarNode

- (void)didLoad {
    %orig;
    if (!sApolloPostActionBars) sApolloPostActionBars = [NSHashTable weakObjectsHashTable];
    [sApolloPostActionBars addObject:self];
}

// Texture has applied the row's frames by now; re-space them for the style.
- (void)layoutDidFinish {
    %orig;
    if (NSThread.isMainThread) ApolloPostActionBarApply(self, YES);
}

// A bar Texture laid out before it loaded comes on screen without a main-thread
// layout pass of its own.
- (void)didEnterVisibleState {
    %orig;
    ApolloPostActionBarApply(self, NO);
}

%end

%hook _TtC6Apollo19DualStateButtonNode

// A post opened with its vote or save already active: round the background
// once the button has sized it.
- (void)layoutDidFinish {
    %orig;
    id button = (id)self;
    id bar = [button valueForKey:@"supernode"];
    if (ApolloPostActionBarIsRegistered(bar)) {
        ApolloPostActionBarRoundBackground(button, ApolloPostActionBarCurrentStyle() != ApolloPostActionBarStyleClassic);
    }
}

// A vote flips Apollo's model synchronously; restyle once its node updates.
- (void)sendActionsForControlEvents:(NSUInteger)events withEvent:(id)event {
    %orig;
    id button = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        id bar = [button valueForKey:@"supernode"];
        if (ApolloPostActionBarIsRegistered(bar)) ApolloPostActionBarApply(bar, NO);
    });
}

%end

%ctor {
    %init;
    [[NSNotificationCenter defaultCenter] addObserverForName:ApolloPostActionBarStyleDidChangeNotification
                                                      object:nil
                                                       queue:NSOperationQueue.mainQueue
                                                  usingBlock:^(__unused NSNotification *note) {
        ApolloPostActionBarRefreshAll();
    }];
}
