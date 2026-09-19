// Runs the production coordinator against UIKit geometry and deterministic
// players. No network, credentials, native Apollo binary, or real media needed.
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <os/log.h>
#import "ApolloTextureDecls.h"
#import "ApolloCommon.h"

@interface FeedTestPlayer : AVPlayer
@property float testRate;
@property BOOL testMuted;
@property BOOL pipOwned;
@property BOOL nativePipOwned;
@property BOOL fullscreenOwned;
@property NSUInteger starts;
@end
@implementation FeedTestPlayer
- (float)rate { return self.testRate; }
- (void)setRate:(float)value { self.testRate = value; }
- (BOOL)isMuted { return self.testMuted; }
- (void)setMuted:(BOOL)value { self.testMuted = value; }
- (AVPlayerTimeControlStatus)timeControlStatus { return self.testRate > 0 ? AVPlayerTimeControlStatusPlaying : AVPlayerTimeControlStatusPaused; }
- (void)play { self.starts++; self.testRate = 1; }
- (void)pause { self.testRate = 0; }
@end

@interface FeedTestNode : NSObject
@property UIView *view;
@property FeedTestPlayer *player;
@property CALayer *playerLayer;
@property (nonatomic, weak) id supernode;
- (BOOL)isNodeLoaded;
- (void)play;
@end
@implementation FeedTestNode
- (BOOL)isNodeLoaded { return YES; }
- (void)play { [self.player play]; }
@end

@interface FeedTestRich : NSObject {
@public
    FeedTestNode *videoNode;
    uint8_t videoNodeStatus[4];
}
@end
@implementation FeedTestRich
@end

@interface FeedTestCell : FeedTestNode {
@public
    CGFloat lastOffsetVisibilityCheck;
    FeedTestRich *richMediaNode;
}
@property BOOL autoplayEnabled;
- (void)cellNodeVisibilityEvent:(unsigned long long)event inScrollView:(UIScrollView *)scroll withCellFrame:(CGRect)frame;
@end
@implementation FeedTestCell
- (void)cellNodeVisibilityEvent:(unsigned long long)event inScrollView:(UIScrollView *)scroll withCellFrame:(CGRect)frame {
    // Native eligibility/transition contract verified in sub_100307dd8.
    if (!scroll || !self.autoplayEnabled || event > 1) return;
    if (!richMediaNode->videoNodeStatus[3]) {
        richMediaNode->videoNodeStatus[3] = 1;
        [richMediaNode->videoNode.player play];
    }
}
@end

AVPlayer *ApolloVideoUnmute_GetPlayerFromVideoNode(id node) { return [node player]; }
BOOL ApolloPiP_IsOwnedPlayer(AVPlayer *player) { return [(FeedTestPlayer *)player pipOwned]; }
BOOL ApolloPiP_ShouldBlockMuteOfPlayer(AVPlayer *player) { return [(FeedTestPlayer *)player nativePipOwned]; }
BOOL ApolloVideoUnmute_IsPresentedFullscreenPlayer(AVPlayer *player) { return [(FeedTestPlayer *)player fullscreenOwned]; }
os_log_t ApolloFixLog(void) { return OS_LOG_DEFAULT; }

#include "FeedAutoplayCore.inc"

static NSUInteger checks;
#define CHECK(condition, message) do { \
    if (!(condition)) { \
        @throw [NSException exceptionWithName:@"FeedAutoplayTestFailure" reason:@message userInfo:nil]; \
    } \
    checks++; \
} while (0)

static ApolloFeedAutoplayEntry *MakeEntry(UIScrollView *scroll, NSMutableArray *owners, CGRect rect) {
    FeedTestCell *cell = [FeedTestCell new];
    cell.autoplayEnabled = YES;
    cell.view = [[UIView alloc] initWithFrame:rect];
    [scroll addSubview:cell.view];
    cell->richMediaNode = [FeedTestRich new];
    cell->richMediaNode->videoNodeStatus[0] = 1;
    FeedTestNode *video = [FeedTestNode new];
    video.view = [[UIView alloc] initWithFrame:cell.view.bounds];
    [cell.view addSubview:video.view];
    video.player = [FeedTestPlayer new];
    video.player.muted = YES;
    video.playerLayer = [CALayer layer];
    [video.view.layer addSublayer:video.playerLayer];
    cell->richMediaNode->videoNode = video;
    ApolloFeedAutoplayEntry *entry = [ApolloFeedAutoplayEntry new];
    entry.cell = cell;
    entry.rich = cell->richMediaNode;
    entry.scroll = scroll;
    entry.frame = rect;
    entry.visible = YES;
    [owners addObject:cell];
    [owners addObject:entry];
    [sEntries addObject:entry];
    objc_setAssociatedObject(cell, &kFeedEntry, entry, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    video.supernode = cell;
    return entry;
}

static void Settle(UIScrollView *scroll) {
    ApolloFeedMotion *motion = objc_getAssociatedObject(scroll, &kFeedMotion);
    motion.blockedUntil = 0;
    motion.offset = scroll.contentOffset;
    motion.sampleTime = CACurrentMediaTime();
}

static void RunTests(UIWindow *window) {
    sFeedCellClass = FeedTestCell.class;
    _logos_orig$FeedAutoplay$AVPlayer$play = [](AVPlayer *p, SEL selector) { [p play]; };
    _logos_orig$FeedAutoplay$AVPlayer$pause = [](AVPlayer *p, SEL selector) { [p pause]; };
    _logos_orig$FeedAutoplay$AVPlayer$setRate$ = [](AVPlayer *p, SEL selector, float rate) { p.rate = rate; };
    _logos_orig$FeedAutoplay$ASVideoNode$play = [](id node, SEL selector) { [(FeedTestNode *)node play]; };
    _logos_orig$FeedAutoplay$LargePostCellNode$cellNodeVisibilityEvent$inScrollView$withCellFrame$ = [](id cell, SEL selector, unsigned long long event, id scroll, CGRect frame) {
        [(FeedTestCell *)cell cellNodeVisibilityEvent:event inScrollView:scroll withCellFrame:frame];
    };
    sEntries = [NSHashTable weakObjectsHashTable];
    NSMutableArray *owners = [NSMutableArray array];
    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:window.rootViewController.view.bounds];
    scroll.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    scroll.contentSize = CGSizeMake(scroll.bounds.size.width, 3000);
    [window.rootViewController.view addSubview:scroll];
    ApolloFeedAutoplayEntry *large = MakeEntry(scroll, owners, CGRectMake(0, 50, 300, 250));
    ApolloFeedAutoplayEntry *small = MakeEntry(scroll, owners, CGRectMake(0, 360, 300, 150));
    _logos_method$FeedAutoplay$LargePostCellNode$cellNodeVisibilityEvent$inScrollView$withCellFrame$(large.cell,
        @selector(cellNodeVisibilityEvent:inScrollView:withCellFrame:), 0, scroll, large.frame);
    CHECK(!FeedNativeWantsPlayback(large) && large.player.rate == 0, "Visibility hook defers native asset-start eligibility at the source");
    FeedTick();
    CHECK(!large.selected && !small.selected, "Initial dwell admits no player");
    Settle(scroll);
    FeedTick();
    CHECK(large.selected && !small.selected, "Most visible media gets the slot");
    CHECK(large.player.rate > 0 && small.player.rate == 0, "Only one automatic player starts");
    NSUInteger starts = [(FeedTestPlayer *)large.player starts];
    FeedTick();
    CHECK([(FeedTestPlayer *)large.player starts] == starts, "Idle ticks do not restart playback");

    ApolloFeedMotion *motion = objc_getAssociatedObject(scroll, &kFeedMotion);
    motion.sampleTime = CACurrentMediaTime() - 0.03;
    scroll.contentOffset = CGPointMake(0, 30);
    FeedTick();
    CHECK(!large.selected && large.player.rate == 0, "Fast scrolling pauses automatic playback");
    CHECK(!FeedNativeWantsPlayback(large), "Withdrawn slot resets native visibility eligibility");
    CHECK(!FeedAllowsPlay(large, large.player), "Late player completion is refused during fast scrolling");
    _logos_method$FeedAutoplay$AVPlayer$play(large.player, @selector(play));
    CHECK(large.pendingPlay && large.player.rate == 0, "Actual player play hook defers late completion");
    _logos_method$FeedAutoplay$AVPlayer$setRate$(large.player, @selector(setRate:), 1);
    CHECK(large.player.rate == 0, "Direct positive-rate starts cannot bypass arbitration");
    _logos_method$FeedAutoplay$ASVideoNode$play(FeedVideo(large), @selector(play));
    CHECK(large.pendingNodePlay && large.player.rate == 0, "Node play hook avoids constructing a passed video's player node");
    _logos_method$FeedAutoplay$AVPlayer$pause(large.player, @selector(pause));
    CHECK(!large.pendingPlay && !large.pendingNodePlay, "Actual pause hook cancels queued starts");
    large.pendingPlay = YES;
    _logos_method$FeedAutoplay$AVPlayer$setRate$(large.player, @selector(setRate:), 0);
    CHECK(!large.pendingPlay, "Explicit zero-rate pause cancels queued starts");
    CHECK([(FeedTestPlayer *)large.player starts] == starts, "Passing videos do not start during a fling");
    Settle(scroll);
    FeedTick();
    CHECK(large.selected && large.player.rate > 0, "Playback resumes at rest without another scroll event");

    large.visible = NO;
    FeedTick();
    CHECK(![sEntries containsObject:large], "Off-screen cells leave the bounded selection registry");
    CHECK(small.selected && small.player.rate > 0 && large.player.rate == 0, "Off-screen former winner yields its slot");
    large.visible = YES;
    [sEntries addObject:large];
    small.player.muted = NO;
    FeedTick();
    CHECK(small.player.rate > 0 && large.player.rate == 0, "Audible playback is preserved and consumes the slot");
    small.player.muted = YES;
    [(FeedTestPlayer *)small.player setPipOwned:YES];
    FeedTick();
    CHECK(small.player.rate > 0, "PiP-owned playback is never paused");
    small.player.rate = 0;
    _logos_method$FeedAutoplay$AVPlayer$play(small.player, @selector(play));
    CHECK(small.player.rate > 0, "PiP play requests bypass feed restrictions");
    [(FeedTestPlayer *)small.player setPipOwned:NO];
    [(FeedTestPlayer *)small.player setNativePipOwned:YES];
    FeedTick();
    CHECK(small.player.rate > 0, "Inline system PiP and background handoff remain protected");
    [(FeedTestPlayer *)small.player setNativePipOwned:NO];
    [(FeedTestPlayer *)small.player setFullscreenOwned:YES];
    FeedTick();
    CHECK(small.player.rate > 0, "Fullscreen-owned playback is never paused");
    [(FeedTestPlayer *)small.player setFullscreenOwned:NO];
    CALayer *externalLayer = [CALayer layer];
    [externalLayer addSublayer:((FeedTestNode *)FeedVideo(small)).playerLayer];
    FeedTick();
    CHECK(small.player.rate > 0, "Shared layer transferred to comments is never paused");
    [((FeedTestNode *)FeedVideo(small)).view.layer addSublayer:((FeedTestNode *)FeedVideo(small)).playerLayer];

    [small.player pause];
    large.visible = NO;
    small.visible = NO;
    FeedTick();
    CHECK(!large.selected && !small.selected && !FeedAllowsPlay(small, small.player), "Off-screen candidates cannot autoplay");
    large.visible = YES;
    [sEntries addObject:large];
    ((FeedTestCell *)large.cell).autoplayEnabled = NO;
    large.pendingPlay = YES;
    FeedTick();
    CHECK(large.player.rate == 0, "Pending request cannot bypass native autoplay disabled policy");
    ((FeedTestCell *)large.cell).autoplayEnabled = YES;
    FeedTick();
    CHECK(large.player.rate > 0, "Native eligibility can re-enable playback");
    [large.player pause];
    large.pendingPlay = NO;
    FeedTick();
    CHECK(large.player.rate == 0, "A deliberate pause stays paused at the same position");
}

@interface FeedTestApp : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end
@implementation FeedTestApp
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [UIViewController new];
    [self.window makeKeyAndVisible];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        NSString *result;
        @try {
            RunTests(self.window);
            result = [NSString stringWithFormat:@"PASS: %lu feed autoplay checks", (unsigned long)checks];
        } @catch (NSException *exception) {
            result = [@"FAIL: " stringByAppendingString:exception.reason];
        }
        [result writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/result.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSLog(@"%@", result);
    });
    return YES;
}
@end

int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(FeedTestApp.class)); }
}
