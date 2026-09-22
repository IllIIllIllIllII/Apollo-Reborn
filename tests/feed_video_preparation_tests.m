#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
@interface UIScrollView : NSObject
@property BOOL tracking, dragging, decelerating;
@property id window;
@end
@implementation UIScrollView
@end
static BOOL sFeedVideoScrollSmoothing = YES;
#include "Preparation.inc"

#define CHECK(c) do { if (!(c)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #c); exit(1); } } while (0)

// Hold metadata completion so cancellation/same-asset reentry can be driven
// deterministically, including a completion which arrives after cancellation.
@interface HeldAsset : AVAsset
@property NSMutableArray *completions;
@property BOOL playable;
@property AVKeyValueStatus keyStatus;
@property NSArray *requestedKeys;
@end
@implementation HeldAsset
- (instancetype)init { if ((self = [super init])) { _completions = [NSMutableArray new]; _playable = YES; _keyStatus = AVKeyValueStatusLoaded; } return self; }
- (BOOL)isPlayable { return _playable; }
- (AVKeyValueStatus)statusOfValueForKey:(NSString *)key error:(NSError **)error { return _keyStatus; }
- (void)loadValuesAsynchronouslyForKeys:(NSArray *)keys completionHandler:(void (^)(void))completion {
    self.requestedKeys = keys;
    [self.completions addObject:[completion copy]];
}
@end

@interface TestNode : NSObject {
@public
    id _player;
}
@property AVAsset *asset;
@property id supernode;
@property UIScrollView *scrollView;
@property BOOL visible;
@property BOOL inPreloadState;
@property NSInteger preloads;
@property NSInteger plays;
@property CFTimeInterval playedAt;
@property NSInteger attaches;
@property AVPlayerItem *attachedItem;
@end
@implementation TestNode
- (BOOL)isVisible { return self.visible; }
- (BOOL)isInPreloadState { return self.inPreloadState; }
- (void)didEnterPreloadState {
    if (ApolloDeferFeedVideoWork(self, &kFeedDeferredPreload, @selector(didEnterPreloadState), @selector(isInPreloadState))) return;
    self.preloads++;
}
- (void)play {
    if (ApolloDeferFeedVideoWork(self, &kFeedDeferredPlay, @selector(play), @selector(isVisible))) return;
    self.plays++;
    self.playedAt = CACurrentMediaTime();
}
- (id)videoComposition { CHECK(NSThread.isMainThread); return nil; }
- (id)audioMix { CHECK(NSThread.isMainThread); return nil; }
- (void)setCurrentItem:(id)item { CHECK(NSThread.isMainThread); self.attaches++; self.attachedItem = item; }
- (void)setPlayer:(id)player { CHECK(NSThread.isMainThread); _player = player; }
- (id)delegate { return nil; }
- (id)image { return @YES; }
- (id)URL { return nil; }
- (id)constructPlayerItem { CHECK(NO); return nil; } // old worker path must never run
@end

@interface TestCell : TestNode
@end
@implementation TestCell
@end

static NSURL *WriteVideoFixture(void) {
    NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"apollo-preparation-%@.mov", NSUUID.UUID.UUIDString]]];
    NSError *error;
    AVAssetWriter *writer = [[AVAssetWriter alloc] initWithURL:url fileType:AVFileTypeQuickTimeMovie error:&error];
    CHECK(writer && !error);
    AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
        outputSettings:@{AVVideoCodecKey: AVVideoCodecTypeH264, AVVideoWidthKey: @32, AVVideoHeightKey: @32}];
    AVAssetWriterInputPixelBufferAdaptor *adaptor = [AVAssetWriterInputPixelBufferAdaptor
        assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input sourcePixelBufferAttributes:nil];
    [writer addInput:input];
    CHECK([writer startWriting]);
    [writer startSessionAtSourceTime:kCMTimeZero];
    CVPixelBufferRef pixel;
    CHECK(CVPixelBufferCreate(NULL, 32, 32, kCVPixelFormatType_32BGRA, NULL, &pixel) == kCVReturnSuccess);
    CVPixelBufferLockBaseAddress(pixel, 0);
    memset(CVPixelBufferGetBaseAddress(pixel), 127, CVPixelBufferGetDataSize(pixel));
    CVPixelBufferUnlockBaseAddress(pixel, 0);
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while (!input.readyForMoreMediaData && deadline.timeIntervalSinceNow > 0) [NSThread sleepForTimeInterval:0.01];
    CHECK(input.readyForMoreMediaData);
    CHECK([adaptor appendPixelBuffer:pixel withPresentationTime:kCMTimeZero]);
    CVPixelBufferRelease(pixel);
    [input markAsFinished];
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    [writer finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(finished); }];
    CHECK(dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) == 0);
    CHECK(writer.status == AVAssetWriterStatusCompleted);
    return url;
}

int main(void) {
    @autoreleasepool {
        sFeedVideoPrewarmAvailable = YES;
        HeldAsset *asset = [HeldAsset new];
        TestNode *node = [TestNode new];
        node.asset = asset;
        CHECK(ApolloFeedVideoPrewarmPlayer((id)node, asset, @[@"playable"]));
        CHECK([asset.requestedKeys containsObject:@"tracks"]);
        CHECK([asset.requestedKeys containsObject:@"duration"]);
        id first = objc_getAssociatedObject(node, kApolloFeedVideoPrewarmAssetKey);
        CHECK(ApolloFeedVideoPrewarmPlayer((id)node, asset, @[@"playable"]));
        CHECK(asset.completions.count == 1); // coalesced
        ApolloCancelFeedVideoPreparation(node);
        CHECK(((ApolloFeedVideoPreparation *)first).cancelled);
        CHECK(ApolloFeedVideoPrewarmPlayer((id)node, asset, @[@"playable"]));
        id second = objc_getAssociatedObject(node, kApolloFeedVideoPrewarmAssetKey);
        CHECK(first != second); // same-asset reentry has a fresh generation
        ((void (^)(void))asset.completions[0])();
        dispatch_sync(ApolloFeedVideoPrewarmQueue(), ^{});
        CHECK(node.asset == asset && node.attaches == 0);
        CHECK(objc_getAssociatedObject(node, kApolloFeedVideoPrewarmAssetKey) == second);
        ApolloCancelFeedVideoPreparation(node);
        ((void (^)(void))asset.completions[1])();
        dispatch_sync(ApolloFeedVideoPrewarmQueue(), ^{});
        CHECK(node.attaches == 0);
        asset.keyStatus = AVKeyValueStatusFailed;
        CHECK(!ApolloFeedVideoPrewarmPlayer((id)node, asset, @[@"playable"]));
        asset.keyStatus = AVKeyValueStatusLoaded;
        asset.playable = NO;
        CHECK(!ApolloFeedVideoPrewarmPlayer((id)node, asset, @[@"playable"]));
        asset.playable = YES;
        node->_player = @YES;
        CHECK(!ApolloFeedVideoPrewarmPlayer((id)node, asset, @[@"playable"]));
        node->_player = nil;
        __weak TestNode *weakNode;
        @autoreleasepool {
            TestNode *temporary = [TestNode new]; temporary.asset = asset; weakNode = temporary;
            CHECK(ApolloFeedVideoPrewarmPlayer((id)temporary, asset, @[@"playable"]));
        }
        CHECK(!weakNode); // queued preparation never keeps a cell alive
        ((void (^)(void))asset.completions.lastObject)();
        dispatch_sync(ApolloFeedVideoPrewarmQueue(), ^{});
        // HeldAsset stores completions only for this test; break that test cycle.
        [asset.completions removeAllObjects];
        sFeedScrollingCellClass = TestCell.class;
        UIScrollView *scroll = [UIScrollView new]; scroll.window = @YES; scroll.decelerating = YES;
        TestCell *feedNode = [TestCell new]; feedNode.scrollView = scroll; feedNode.visible = YES;
        TestNode *crosspost = [TestNode new]; crosspost.supernode = feedNode;
        TestNode *nestedVideo = [TestNode new]; nestedVideo.supernode = crosspost;
        CHECK(ApolloVideoFeedScroll(nestedVideo) == scroll);
        TestNode *commentsVideo = [TestNode new]; commentsVideo.visible = YES;
        CHECK(!ApolloDeferFeedVideoWork(commentsVideo, &kFeedDeferredPlay, @selector(play), @selector(isVisible)));
        CHECK(ApolloDeferFeedVideoWork(feedNode, &kFeedDeferredPlay, @selector(play), @selector(isVisible)));
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.06]];
        CHECK(feedNode.plays == 0); // transient cells get a short dwell
        // Repeated visibility callbacks coalesce without resetting the dwell.
        CHECK(ApolloDeferFeedVideoWork(feedNode, &kFeedDeferredPlay, @selector(play), @selector(isVisible)));
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.20]];
        CHECK(feedNode.plays == 1 && scroll.decelerating); // no settle required
        scroll.decelerating = NO;
        scroll.dragging = YES;
        TestCell *another = [TestCell new]; another.scrollView = scroll; another.visible = YES;
        TestCell *third = [TestCell new]; third.scrollView = scroll; third.visible = YES;
        [another play]; [third play];
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.40]];
        CHECK(another.plays == 1 && third.plays == 1 && scroll.dragging);
        CHECK(fabs(another.playedAt - third.playedAt) >= 0.099); // burst is spread out
        CHECK(!objc_getAssociatedObject(another, &kFeedDeferredPlay));
        scroll.dragging = YES;
        CHECK(ApolloDeferFeedVideoWork(feedNode, &kFeedDeferredPlay, @selector(play), @selector(isVisible)));
        objc_setAssociatedObject(feedNode, &kFeedDeferredPlay, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        scroll.dragging = NO;
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.12]];
        CHECK(feedNode.plays == 1); // native pause/exit cancellation
        scroll.tracking = YES;
        CHECK(ApolloDeferFeedVideoWork(feedNode, &kFeedDeferredPlay, @selector(play), @selector(isVisible)));
        feedNode.visible = NO; scroll.tracking = NO;
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.12]];
        CHECK(feedNode.plays == 1); // no late autoplay after leaving the screen
        feedNode.visible = YES; scroll.tracking = YES;
        CHECK(ApolloDeferFeedVideoWork(feedNode, &kFeedDeferredPlay, @selector(play), @selector(isVisible)));
        sFeedVideoScrollSmoothing = NO;
        CHECK(!ApolloDeferFeedVideoWork(feedNode, &kFeedDeferredPlay, @selector(play), @selector(isVisible)));
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.12]];
        CHECK(feedNode.plays == 1); // disabling does not leave a duplicate replay
        sFeedVideoScrollSmoothing = YES;
        // Asset/resource-loader setup is admitted during motion as well;
        // allowing play alone would still leave new videos waiting for assets.
        feedNode.inPreloadState = YES;
        [feedNode didEnterPreloadState];
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.30]];
        CHECK(feedNode.preloads == 1 && scroll.tracking);
        [feedNode didEnterPreloadState];
        feedNode.inPreloadState = NO;
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.20]];
        CHECK(feedNode.preloads == 1); // exit before admission discards setup
        // Stopping early removes the dwell, but not inter-operation spacing.
        sNextFeedVideoStart = 0;
        [feedNode play];
        scroll.tracking = NO;
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.08]];
        CHECK(feedNode.plays == 2);
        NSURL *fixture = WriteVideoFixture();
        AVURLAsset *realAsset = [AVURLAsset URLAssetWithURL:fixture options:nil];
        dispatch_semaphore_t loaded = dispatch_semaphore_create(0);
        [realAsset loadValuesAsynchronouslyForKeys:@[@"playable"] completionHandler:^{ dispatch_semaphore_signal(loaded); }];
        CHECK(dispatch_semaphore_wait(loaded, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) == 0);
        TestNode *live = [TestNode new]; live.asset = realAsset;
        CHECK(ApolloFeedVideoPrewarmPlayer((id)live, realAsset, @[@"playable"]));
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
        while (!live.attaches && deadline.timeIntervalSinceNow > 0) {
            [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        }
        CHECK(live.attaches == 1 && live->_player);
        CHECK(live.asset == realAsset && live.attachedItem.asset == realAsset);
        CHECK([realAsset statusOfValueForKey:@"duration" error:nil] == AVKeyValueStatusLoaded);
        CHECK([realAsset statusOfValueForKey:@"tracks" error:nil] == AVKeyValueStatusLoaded);
        [[NSFileManager defaultManager] removeItemAtURL:fixture error:nil];
        puts("PASS: metadata preload, duplicate coalescing, cancellation, same-asset reentry, stale completion, native failure guards, node lifetime, real player attachment, prepared asset reuse, playback during dragging/deceleration, start pacing, reentry, exit/pause cancellation, toggle-off, crossposts and comments scope");
    }
    return 0;
}
