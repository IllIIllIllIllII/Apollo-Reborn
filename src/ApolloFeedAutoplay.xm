// Feed-only autoplay arbitration. Keep Apollo's own eligibility/loading path:
// LargePostCellNode's visibility callback starts asset creation only after its
// midpoint test. Passing a nil scroll view skips that part (sub_100307a14),
// while still calling super and the other tweaks' visibility hooks.
//
// RE: sub_100307dd8 updates VideoNodeStatus.enteredVisibleRange, then
// sub_10057b104 creates the asset or plays/pauses an existing node. The four
// Bool fields are also documented in Headers/Swift/VideoNodeStatus.swift.
// ASVideoNode.play constructs a player node; shared players additionally
// receive direct AVPlayer.play calls. Gate both, including late completions.
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "ApolloCommon.h"
#import "ApolloTextureDecls.h"

extern AVPlayer *ApolloVideoUnmute_GetPlayerFromVideoNode(id node);
extern BOOL ApolloPiP_IsOwnedPlayer(AVPlayer *player);
extern BOOL ApolloPiP_ShouldBlockMuteOfPlayer(AVPlayer *player);
extern BOOL ApolloVideoUnmute_IsPresentedFullscreenPlayer(AVPlayer *player);

static char kFeedEntry, kFeedPlayerEntry, kFeedMotion;
static Class sFeedCellClass;
static NSHashTable *sEntries;
static BOOL sTickPending, sReplaying, sCoordinatorPause;

@interface ApolloFeedMotion : NSObject
@property CGPoint offset;
@property CFTimeInterval sampleTime;
@property CFTimeInterval blockedUntil;
@end
@implementation ApolloFeedMotion
@end

@interface ApolloFeedAutoplayEntry : NSObject
@property (nonatomic, weak) id cell;
@property (nonatomic, weak) id rich;
@property (nonatomic, weak) UIScrollView *scroll;
@property (nonatomic, weak) AVPlayer *player;
@property CGRect frame;
@property BOOL visible;
@property BOOL selected;
@property BOOL pendingPlay;
@property BOOL pendingNodePlay;
@property CFTimeInterval manualUntil;
@end
@implementation ApolloFeedAutoplayEntry
@end

static id FeedIvar(id obj, const char *name) {
    Ivar ivar = obj ? class_getInstanceVariable([obj class], name) : NULL;
    return ivar ? object_getIvar(obj, ivar) : nil;
}

static UIView *FeedView(id node) {
    // Never force creation of an off-screen Texture backing view.
    return [node respondsToSelector:@selector(isNodeLoaded)] && [node isNodeLoaded] ? [node view] : nil;
}

static id FeedVideo(ApolloFeedAutoplayEntry *entry) {
    return FeedIvar(entry.rich, "videoNode");
}

static BOOL FeedNativeWantsPlayback(ApolloFeedAutoplayEntry *entry) {
    id rich = entry.rich;
    Ivar ivar = rich ? class_getInstanceVariable([rich class], "videoNodeStatus") : NULL;
    if (!ivar) return NO;
    const uint8_t *status = (const uint8_t *)(__bridge const void *)rich + ivar_getOffset(ivar);
    return status[0] == 1 && status[3] == 1;
}

static UIViewController *FeedController(UIView *view) {
    for (UIResponder *r = view; r; r = r.nextResponder) {
        if ([r isKindOfClass:UIViewController.class]) return (UIViewController *)r;
    }
    return nil;
}

static BOOL FeedIsFrontmost(ApolloFeedAutoplayEntry *entry) {
    UIView *view = FeedView(entry.cell);
    if (!entry.visible || !view.window || view.hidden || !entry.scroll.window) return NO;
    UIViewController *vc = FeedController(view);
    if (!vc) return NO;
    if (vc.navigationController && vc.navigationController.topViewController != vc) return NO;
    for (UIViewController *p = vc; p; p = p.parentViewController) {
        if (p.presentedViewController && !p.presentedViewController.isBeingDismissed) return NO;
        if ([p isKindOfClass:UITabBarController.class]) {
            UIViewController *selected = ((UITabBarController *)p).selectedViewController;
            if (selected != vc && selected != vc.navigationController) return NO;
        }
    }
    return UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
}

static BOOL FeedPlayerIsTransferred(ApolloFeedAutoplayEntry *entry, AVPlayer *player) {
    if (!player) return NO;
    if (ApolloPiP_IsOwnedPlayer(player) || ApolloPiP_ShouldBlockMuteOfPlayer(player)
        || ApolloVideoUnmute_IsPresentedFullscreenPlayer(player)) return YES;
    id video = FeedVideo(entry);
    if (![video respondsToSelector:@selector(playerLayer)]) return NO;
    CALayer *layer = ((id (*)(id, SEL))objc_msgSend)(video, @selector(playerLayer));
    CALayer *owner = FeedView(video).layer;
    // A shared layer moves to comments/fullscreen. Never pause or gate that
    // player's playback just because its original feed cell is still tracked.
    if (!layer.superlayer) return NO;
    for (CALayer *p = layer.superlayer; p; p = p.superlayer) {
        if (p == owner) return NO;
    }
    return YES;
}

static BOOL FeedProtected(ApolloFeedAutoplayEntry *entry, AVPlayer *player) {
    return FeedPlayerIsTransferred(entry, player)
        || entry.manualUntil > CACurrentMediaTime()
        || (player && !player.muted && (player.rate > 0 || player.timeControlStatus == AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate));
}

static void FeedScheduleTick(void);

static BOOL FeedMovingFast(UIScrollView *scroll) {
    ApolloFeedMotion *motion = objc_getAssociatedObject(scroll, &kFeedMotion);
    CFTimeInterval now = CACurrentMediaTime();
    if (!motion) {
        motion = [ApolloFeedMotion new];
        motion.offset = scroll.contentOffset;
        motion.sampleTime = now;
        // Brief dwell also batches the first visible cells before selection.
        motion.blockedUntil = now + 0.18;
        objc_setAssociatedObject(scroll, &kFeedMotion, motion, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CFTimeInterval dt = now - motion.sampleTime;
    // All cells report the same scroll offset. Sample once per interval, not
    // once per cell, including deceleration (pan velocity alone misses it).
    if (dt >= 0.016) {
        CGFloat speed = hypot(scroll.contentOffset.x - motion.offset.x,
                              scroll.contentOffset.y - motion.offset.y) / dt;
        if (speed > 550) motion.blockedUntil = now + 0.18;
        motion.offset = scroll.contentOffset;
        motion.sampleTime = now;
    }
    if (scroll.dragging && fabs([scroll.panGestureRecognizer velocityInView:scroll].y) > 550) {
        motion.blockedUntil = now + 0.18;
    }
    return now < motion.blockedUntil;
}

static void FeedBindPlayer(ApolloFeedAutoplayEntry *entry) {
    AVPlayer *player = ApolloVideoUnmute_GetPlayerFromVideoNode(FeedVideo(entry));
    if (entry.player != player) {
        if (objc_getAssociatedObject(entry.player, &kFeedPlayerEntry) == entry) {
            objc_setAssociatedObject(entry.player, &kFeedPlayerEntry, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        entry.player = player;
        entry.pendingPlay = NO;
    }
    if (player) objc_setAssociatedObject(player, &kFeedPlayerEntry, entry, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static ApolloFeedAutoplayEntry *FeedEntryForVideo(id video) {
    // Parent traversal uses nodes, not views, so asset readiness cannot load
    // an off-screen hierarchy. Comments and fullscreen have no feed ancestor.
    for (id node = video; node && [node respondsToSelector:@selector(supernode)]; node = [node supernode]) {
        if ([node isKindOfClass:sFeedCellClass]) {
            ApolloFeedAutoplayEntry *entry = objc_getAssociatedObject(node, &kFeedEntry);
            if (FeedVideo(entry) == video) return entry;
            return nil;
        }
    }
    return nil;
}

static BOOL FeedAllowsPlay(ApolloFeedAutoplayEntry *entry, AVPlayer *player) {
    if (!entry || !entry.cell || FeedProtected(entry, player)) return YES;
    return entry.selected && FeedIsFrontmost(entry) && !FeedMovingFast(entry.scroll);
}

static void FeedPause(ApolloFeedAutoplayEntry *entry) {
    AVPlayer *player = entry.player;
    if (FeedProtected(entry, player)) return;
    // Native code writes this Bool directly before calling its Swift update
    // helper; there is no property observer. Reset it when we withdraw the
    // feed slot, so the next admitted native pass sees false -> true and
    // resumes through Apollo's own path even at an unchanged scroll offset.
    // Do not reset nodeCreated/assetIsBeingCreated/createdAsset: outstanding
    // asset work still belongs to Apollo and must retain its lifecycle.
    id rich = entry.rich;
    Ivar status = rich ? class_getInstanceVariable([rich class], "videoNodeStatus") : NULL;
    if (status) *((uint8_t *)(__bridge void *)rich + ivar_getOffset(status) + 3) = 0;
    if (!player) return;
    if (player.rate == 0 && player.timeControlStatus != AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate) return;
    entry.pendingPlay = YES;
    sCoordinatorPause = YES;
    [player pause];
    sCoordinatorPause = NO;
}

static CGFloat FeedVisibleArea(ApolloFeedAutoplayEntry *entry) {
    UIView *view = FeedView(FeedVideo(entry)) ?: FeedView(entry.rich);
    UIScrollView *scroll = entry.scroll;
    if (!view.window || !scroll.window || view.hidden) return 0;
    CGRect viewport = UIEdgeInsetsInsetRect(scroll.bounds, scroll.adjustedContentInset);
    CGRect rect = [view convertRect:view.bounds toView:scroll];
    CGRect visible = CGRectIntersection(rect, viewport);
    if (CGRectIsNull(visible) || CGRectIsEmpty(visible)) return 0;
    // Match native eligibility: don't select a clipped sliver whose midpoint
    // Apollo would reject, starving another playable video.
    if (!CGRectContainsPoint(viewport, CGPointMake(CGRectGetMidX(rect), CGRectGetMidY(rect)))) return 0;
    return visible.size.width * visible.size.height;
}

static void FeedReplay(ApolloFeedAutoplayEntry *entry) {
    id cell = entry.cell;
    if (!cell || !FeedIsFrontmost(entry)) return;
    // Native visibility skips movement under 5pt. A timer at rest must still
    // get a real eligibility pass. This CGFloat ivar is verified in the
    // class dump and sub_100307a14 (+124..180); no Swift method addresses.
    Ivar offset = class_getInstanceVariable([cell class], "lastOffsetVisibilityCheck");
    if (!offset) return;
    CGFloat prior = entry.scroll.contentOffset.y - 6;
    memcpy((uint8_t *)(__bridge void *)cell + ivar_getOffset(offset), &prior, sizeof(prior));
    sReplaying = YES;
    ((void (*)(id, SEL, unsigned long long, id, CGRect))objc_msgSend)(cell,
        @selector(cellNodeVisibilityEvent:inScrollView:withCellFrame:), 1, entry.scroll, entry.frame);
    sReplaying = NO;
    FeedBindPlayer(entry);
    if (!FeedNativeWantsPlayback(entry) || !FeedAllowsPlay(entry, entry.player)) return;
    if (entry.pendingNodePlay) {
        entry.pendingNodePlay = NO;
        id video = FeedVideo(entry);
        ((void (*)(id, SEL))objc_msgSend)(video, @selector(play));
    }
    if (entry.pendingPlay && entry.player) {
        entry.pendingPlay = NO;
        [entry.player play];
    }
}

static void FeedTick(void) {
    NSArray<ApolloFeedAutoplayEntry *> *entries = sEntries.allObjects;
    ApolloFeedAutoplayEntry *best = nil;
    CGFloat bestArea = 0;
    BOOL moving = NO;
    BOOL audible = NO;
    for (ApolloFeedAutoplayEntry *entry in entries) {
        if (!entry.cell || !entry.visible) {
            [sEntries removeObject:entry];
        }
        FeedBindPlayer(entry);
        if (!FeedIsFrontmost(entry)) continue;
        if (FeedProtected(entry, entry.player)) audible = YES;
        if (entry.manualUntil > CACurrentMediaTime()) moving = YES;
        if (FeedMovingFast(entry.scroll)) { moving = YES; continue; }
        CGFloat area = FeedVisibleArea(entry);
        // Small hysteresis avoids swapping equally visible neighbors.
        if (entry.selected) area *= 1.10;
        if (area > bestArea) { best = entry; bestArea = area; }
    }
    if (audible) best = nil; // intentional playback uses the feed's slot
    for (ApolloFeedAutoplayEntry *entry in entries) {
        BOOL selected = entry == best;
        if (entry.selected != selected) {
            ApolloLog(@"[FeedAutoplay] %@ feed candidate %p", selected ? @"Selected" : @"Deferred", entry.cell);
        }
        entry.selected = selected;
        if (!selected) FeedPause(entry);
    }
    if (best) FeedReplay(best);
    // No permanent display link or polling while idle. Visibility/player
    // events schedule work; one bounded timer bridges the end of a fling.
    if (moving) FeedScheduleTick();
}

static void FeedScheduleTick(void) {
    if (sTickPending) return;
    sTickPending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        sTickPending = NO;
        FeedTick();
    });
}

%group FeedAutoplay
%hook LargePostCellNode
- (void)cellNodeVisibilityEvent:(unsigned long long)event inScrollView:(id)scrollView withCellFrame:(CGRect)frame {
    if (sReplaying || ![NSThread isMainThread] || ![scrollView isKindOfClass:UIScrollView.class]) {
        %orig;
        return;
    }
    id rich = FeedIvar(self, "richMediaNode") ?: FeedIvar(FeedIvar(self, "crosspostNode"), "richMediaNode");
    id video = FeedIvar(rich, "videoNode");
    if (!video) {
        %orig;
        return;
    }
    ApolloFeedAutoplayEntry *entry = objc_getAssociatedObject(self, &kFeedEntry);
    if (!entry || entry.rich != rich) {
        entry = [ApolloFeedAutoplayEntry new];
        entry.cell = self;
        entry.rich = rich;
        objc_setAssociatedObject(self, &kFeedEntry, entry, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [sEntries addObject:entry];
    }
    entry.scroll = scrollView;
    entry.frame = frame;
    if (event == 0 || event == 1) {
        entry.visible = YES;
        [sEntries addObject:entry];
    }
    if (event == 2) {
        entry.visible = NO;
        entry.selected = NO;
        entry.pendingNodePlay = NO;
        // Texture can retain hundreds of off-screen cell nodes. Weak storage
        // alone would still scan them all; only visible candidates are polled.
        [sEntries removeObject:entry];
    }
    FeedBindPlayer(entry);
    if (event == 2) FeedPause(entry);
    BOOL allowed = FeedAllowsPlay(entry, entry.player);
    if (!allowed && (event == 0 || event == 1)) {
        %orig(event, nil, frame);
        FeedPause(entry);
    } else {
        %orig;
    }
    FeedScheduleTick();
}
%end

%hook ASVideoNode
- (void)play {
    if ([NSThread isMainThread]) {
        ApolloFeedAutoplayEntry *entry = FeedEntryForVideo(self);
        FeedBindPlayer(entry);
        if (entry && !FeedAllowsPlay(entry, entry.player)) {
            entry.pendingNodePlay = YES;
            FeedScheduleTick();
            return;
        }
    }
    %orig;
}
- (void)setPlayer:(AVPlayer *)player {
    %orig;
    if ([NSThread isMainThread]) FeedBindPlayer(FeedEntryForVideo(self));
}
- (void)setPlayerLayer:(AVPlayerLayer *)layer {
    %orig;
    if ([NSThread isMainThread]) FeedBindPlayer(FeedEntryForVideo(self));
}
%end

%hook AVPlayer
- (void)play {
    if ([NSThread isMainThread]) {
        ApolloFeedAutoplayEntry *entry = objc_getAssociatedObject(self, &kFeedPlayerEntry);
        if (entry && !FeedAllowsPlay(entry, self)) {
            entry.pendingPlay = YES;
            FeedScheduleTick();
            return;
        }
    }
    %orig;
}
- (void)pause {
    if ([NSThread isMainThread] && !sCoordinatorPause) {
        ApolloFeedAutoplayEntry *entry = objc_getAssociatedObject(self, &kFeedPlayerEntry);
        entry.pendingPlay = NO;
        entry.pendingNodePlay = NO;
    }
    %orig;
}
- (void)setRate:(float)rate {
    if ([NSThread isMainThread]) {
        ApolloFeedAutoplayEntry *entry = objc_getAssociatedObject(self, &kFeedPlayerEntry);
        if (rate > 0 && entry && !FeedAllowsPlay(entry, self)) {
            entry.pendingPlay = YES;
            FeedScheduleTick();
            return;
        }
        if (rate == 0 && !sCoordinatorPause) {
            entry.pendingPlay = NO;
            entry.pendingNodePlay = NO;
        }
    }
    %orig;
}
%end

%hook RichMediaNode
- (void)muteUnmuteButtonTappedWithSender:(id)sender {
    ApolloFeedAutoplayEntry *entry = FeedEntryForVideo(FeedIvar(self, "videoNode"));
    entry.manualUntil = CACurrentMediaTime() + 1;
    %orig;
    FeedScheduleTick();
}
%end
%end

%ctor {
    sFeedCellClass = objc_getClass("_TtC6Apollo17LargePostCellNode");
    Class video = objc_getClass("ASVideoNode");
    Class rich = objc_getClass("_TtC6Apollo13RichMediaNode");
    if (!sFeedCellClass || !video || !rich
        || !class_getInstanceVariable(sFeedCellClass, "lastOffsetVisibilityCheck")
        || !class_getInstanceVariable(rich, "videoNodeStatus")) return;
    sEntries = [NSHashTable weakObjectsHashTable];
    %init(FeedAutoplay, LargePostCellNode = sFeedCellClass, ASVideoNode = video, RichMediaNode = rich);
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        FeedScheduleTick();
    }];
    ApolloLog(@"[FeedAutoplay] Feed autoplay hooks installed (550pt/s, 180ms settle, one automatic player)");
}
