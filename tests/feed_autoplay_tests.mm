// Runs the production coordinator against UIKit geometry and deterministic
// players. No network, credentials, native Apollo binary, or real media needed.
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <os/log.h>
#import "ApolloTextureDecls.h"
#import "ApolloCommon.h"

static void TestPlayerPlay(AVPlayer *player);

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
- (void)play { TestPlayerPlay(self); }
- (void)pause { self.testRate = 0; }
@end

@interface FeedTestNode : NSObject
@property UIView *view;
@property AVAsset *asset;
@property AVVideoComposition *videoComposition;
@property AVAudioMix *audioMix;
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

static void TestPlayerPlay(AVPlayer *player) {
    _logos_method$FeedAutoplay$AVPlayer$play(player, @selector(play));
}

@interface FeedTestScroll : UIScrollView
@property BOOL testDecelerating;
@end
@implementation FeedTestScroll
- (BOOL)isDecelerating { return self.testDecelerating; }
@end

// Advance the admission budget without sleeping/blocking the test UI thread.
static void NextSlot(void) {
    sNextStartAt = 0;
    for (ApolloFeedAutoplayEntry *entry in sEntries.allObjects) entry.startGrantUntil = 0;
    FeedTick();
}

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
    _logos_orig$FeedAutoplay$AVPlayer$play = [](AVPlayer *p, SEL selector) { FeedTestPlayer *test = (FeedTestPlayer *)p; test.starts++; test.testRate = 1; };
    _logos_orig$FeedAutoplay$AVPlayer$pause = [](AVPlayer *p, SEL selector) { [p pause]; };
    _logos_orig$FeedAutoplay$AVPlayer$setRate$ = [](AVPlayer *p, SEL selector, float rate) { p.rate = rate; };
    _logos_orig$FeedAutoplay$ASVideoNode$play = [](id node, SEL selector) { [(FeedTestNode *)node play]; };
    _logos_orig$FeedAutoplay$LargePostCellNode$cellNodeVisibilityEvent$inScrollView$withCellFrame$ = [](id cell, SEL selector, unsigned long long event, id scroll, CGRect frame) {
        [(FeedTestCell *)cell cellNodeVisibilityEvent:event inScrollView:scroll withCellFrame:frame];
    };
    sEntries = [NSHashTable weakObjectsHashTable];
    static NSMutableArray *owners;
    owners = [NSMutableArray array];
    FeedTestScroll *scroll = [[FeedTestScroll alloc] initWithFrame:window.rootViewController.view.bounds];
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
    CHECK(large.selected && !small.selected, "Most visible media starts first");
    CHECK(large.player.rate > 0 && small.player.rate == 0, "Startup work is staggered across slots");
    NextSlot();
    CHECK(small.selected && small.player.rate > 0 && large.player.rate > 0, "All visible videos autoplay once startup slots drain");
    CHECK(ApolloFeedAutoplay_ShouldAutoUnmute(small.rich), "Muted neighbors do not block automatic audio selection");
    large.player.muted = NO;
    CHECK(!ApolloFeedAutoplay_ShouldAutoUnmute(small.rich), "Automatic unmute cannot steal existing audio");
    large.player.muted = YES;
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
    NextSlot();
    CHECK(large.selected && large.player.rate > 0, "Playback resumes at rest without another scroll event");

    large.visible = NO;
    NextSlot();
    CHECK(![sEntries containsObject:large], "Off-screen cells leave the bounded selection registry");
    CHECK(small.selected && small.player.rate > 0 && large.player.rate == 0, "Off-screen player pauses while another remains playing");
    large.visible = YES;
    [sEntries addObject:large];
    small.player.muted = NO;
    NextSlot();
    CHECK(small.player.rate > 0 && large.player.rate > 0, "Audible playback is preserved alongside muted autoplay");
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
    NextSlot();
    CHECK(large.player.rate == 0, "Pending request cannot bypass native autoplay disabled policy");
    ((FeedTestCell *)large.cell).autoplayEnabled = YES;
    NextSlot();
    CHECK(large.player.rate > 0, "Native eligibility can re-enable playback");
    [large.player pause];
    large.pendingPlay = NO;
    FeedTick();
    CHECK(large.player.rate == 0, "A deliberate pause stays paused at the same position");
    scroll.testDecelerating = YES;
    Settle(scroll);
    NextSlot();
    CHECK(!large.selected, "Even slow deceleration defers player startup");
    scroll.testDecelerating = NO;
    Settle(scroll);
    NextSlot();
    CHECK(large.player.rate > 0, "Player starts after deceleration actually ends");
    [(FeedTestPlayer *)large.player setTestRate:0];
    large.startGrantUntil = 0;
    sNextStartAt = CACurrentMediaTime() + 1;
    _logos_method$FeedAutoplay$AVPlayer$play(large.player, @selector(play));
    CHECK(large.pendingPlay && large.player.rate == 0, "Late asset completions share the startup budget");
    NextSlot();
    CHECK(large.player.rate > 0 && !large.pendingPlay, "Queued completion resumes on the next available slot");
}

@interface FeedTestAsset : AVAsset
@property BOOL ready;
@property NSArray *requestedKeys;
@property (copy) void (^loaded)(void);
@end
@implementation FeedTestAsset
- (AVKeyValueStatus)statusOfValueForKey:(NSString *)key error:(NSError **)error {
    return self.ready ? AVKeyValueStatusLoaded : AVKeyValueStatusUnknown;
}
- (void)loadValuesAsynchronouslyForKeys:(NSArray *)keys completionHandler:(void (^)(void))completion {
    self.requestedKeys = keys;
    self.loaded = completion;
}
@end

static NSUInteger nativePrepares;
static void RunAssetTests(void (^completion)(NSString *failure)) {
    _logos_orig$FeedAutoplay$ASVideoNode$prepareToPlayAsset$withKeys$ = [](id node, SEL selector, AVAsset *asset, NSArray *keys) {
        nativePrepares++;
    };
    ApolloFeedAutoplayEntry *entry = sEntries.allObjects.firstObject;
    FeedTestNode *node = FeedVideo(entry);
    FeedTestAsset *oldAsset = [FeedTestAsset new];
    node.asset = oldAsset;
    _logos_method$FeedAutoplay$ASVideoNode$prepareToPlayAsset$withKeys$(node, @selector(prepareToPlayAsset:withKeys:), oldAsset, @[@"playable"]);
    CHECK(nativePrepares == 0, "Player setup waits for asynchronous metadata");
    CHECK([oldAsset.requestedKeys containsObject:@"duration"] && [oldAsset.requestedKeys containsObject:@"tracks"], "Startup preloads duration and tracks");
    oldAsset.ready = YES;
    _logos_method$FeedAutoplay$ASVideoNode$prepareToPlayAsset$withKeys$(node, @selector(prepareToPlayAsset:withKeys:), oldAsset, @[@"playable"]);
    CHECK(nativePrepares == 0, "Ready metadata cannot duplicate a queued preparation");
    FeedTestAsset *newAsset = [FeedTestAsset new];
    node.asset = newAsset;
    oldAsset.loaded();
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            CHECK(nativePrepares == 0, "Stale asset completion cannot prepare a reused node");
            _logos_method$FeedAutoplay$ASVideoNode$prepareToPlayAsset$withKeys$(node, @selector(prepareToPlayAsset:withKeys:), newAsset, @[@"playable"]);
            // Leave statuses unknown to model a failed load: native failure
            // handling must still run exactly once, with no retry loop.
            newAsset.loaded();
            dispatch_async(dispatch_get_main_queue(), ^{
                @try {
                    CHECK(nativePrepares == 1, "Metadata failure still reaches native preparation/error handling");
                    newAsset.ready = YES;
                    _logos_method$FeedAutoplay$ASVideoNode$prepareToPlayAsset$withKeys$(node, @selector(prepareToPlayAsset:withKeys:), newAsset, @[@"playable"]);
                    CHECK(nativePrepares == 2, "Ready assets prepare immediately without another async round trip");
                    AVMutableComposition *composition = [AVMutableComposition composition];
                    node.asset = composition;
                    _logos_orig$FeedAutoplay$ASVideoNode$constructPlayerItem = [](id n, SEL sel) { return [AVPlayerItem playerItemWithAsset:[AVMutableComposition composition]]; };
                    [composition loadValuesAsynchronouslyForKeys:FeedAssetKeys() completionHandler:^{
                        dispatch_async(dispatch_get_main_queue(), ^{
                            @try {
                                AVPlayerItem *item = _logos_method$FeedAutoplay$ASVideoNode$constructPlayerItem(node, @selector(constructPlayerItem));
                                CHECK(item.asset == composition, "Player item reuses the asynchronously prepared asset");
                                completion(nil);
                            } @catch (NSException *e) { completion(e.reason); }
                        });
                    }];
                } @catch (NSException *e) { completion(e.reason); }
            });
        } @catch (NSException *e) { completion(e.reason); }
    });
}

static void WriteResult(NSString *failure) {
    NSString *result = failure ? [@"FAIL: " stringByAppendingString:failure] : [NSString stringWithFormat:@"PASS: %lu feed autoplay checks", (unsigned long)checks];
    [result writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/result.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSLog(@"%@", result);
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
        @try {
            RunTests(self.window);
            RunAssetTests(^(NSString *failure) { WriteResult(failure); });
        } @catch (NSException *exception) {
            WriteResult(exception.reason);
        }
    });
    return YES;
}
@end

int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(FeedTestApp.class)); }
}
