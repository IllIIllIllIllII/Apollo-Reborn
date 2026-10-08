#import "ApolloAwards.h"
#import "ApolloAwardsGiving.h"
#import "ApolloCommon.h"
#import <objc/message.h>
#import <objc/runtime.h>

// Award rendering survived in Apollo: PostInfoNode and CommentCellNode build
// AwardsNode from RDKLink/RDKComment.awards. Feed its existing models, then use
// the same model-update notification as voting. Calling a private Swift
// initializer or changing the node's Swift Array storage would be fragile.
@interface RDKLink : NSObject
@property (nonatomic, copy) NSString *fullName;
@property (nonatomic, strong) NSArray *awards;
@end
@interface RDKComment : NSObject
@property (nonatomic, copy) NSString *fullName;
@property (nonatomic, strong) NSArray *awards;
@end

static char kApolloAwardsModelStateKey;
static char kApolloAwardsRenderedStateKey;
static char kApolloAwardsScheduledKey;
static char kApolloAwardsPendingKey;
static char kApolloAwardsPendingTicketKey;
static char kApolloAwardsModernAwardKey;
static char kApolloAwardsPublishedStateKey;
static char kApolloAwardsRangeKey;
static NSHashTable *sApolloAwardsInterestedNodes;

typedef NS_OPTIONS(NSUInteger, ApolloAwardsNodeRange) {
    ApolloAwardsNodeRangePreload = 1 << 0,
    ApolloAwardsNodeRangeDisplay = 1 << 1,
    ApolloAwardsNodeRangeVisible = 1 << 2,
};

static ApolloAwardsNodeRange ApolloAwardsRangeForNode(id node) {
    return [objc_getAssociatedObject(node, &kApolloAwardsRangeKey) unsignedIntegerValue];
}

static BOOL ApolloAwardsNodeCanRender(id node) {
    return (ApolloAwardsRangeForNode(node) & (ApolloAwardsNodeRangeDisplay | ApolloAwardsNodeRangeVisible)) != 0;
}

// Foundation-only conversion; model getters can run on Texture's background
// layout threads. The bounded cache also keeps those getters from repeatedly
// allocating the same RDKAward/RDKAwardIcon objects.
@interface ApolloAwardsNativeSnapshot : NSObject
@property (nonatomic, copy) NSDictionary *state;
@property (nonatomic, copy) NSArray *awards;
@end
@implementation ApolloAwardsNativeSnapshot
@end

static NSCache *ApolloAwardsNativeCache(void) {
    static NSCache *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSCache new];
        cache.countLimit = 256;
    });
    return cache;
}

static BOOL ApolloAwardsDisplayEnabled(void) {
    // Confirmed in SettingsAppearanceViewController's original read/write
    // closures and in both native post/comment layout paths.
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"ShowAwards"];
}

static id ApolloAwardsObjectIvar(id object, const char *name) {
    if (!object) return nil;
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    return ivar ? object_getIvar(object, ivar) : nil;
}

static id ApolloAwardsModelForNode(id node) {
    return ApolloAwardsObjectIvar(node, "comment") ?: ApolloAwardsObjectIvar(node, "link");
}

static NSString *ApolloAwardsFullName(id model) {
    if (![model respondsToSelector:@selector(fullName)]) return nil;
    id value = ((id (*)(id, SEL))objc_msgSend)(model, @selector(fullName));
    if (![value isKindOfClass:NSString.class] || [value length] < 4) return nil;
    if (![value hasPrefix:@"t1_"] && ![value hasPrefix:@"t3_"]) return nil;
    return value;
}

static ApolloAwardsNativeSnapshot *ApolloAwardsNativeAwards(NSString *fullName, NSArray<NSDictionary *> *data) {
    ApolloAwardsNativeSnapshot *cached = [ApolloAwardsNativeCache() objectForKey:fullName];
    if ([cached.state[@"awards"] isEqual:data]) return cached;

    Class awardClass = objc_getClass("RDKAward");
    Class iconClass = objc_getClass("RDKAwardIcon");
    if (!awardClass || !iconClass) return nil;
    NSMutableArray *awards = [NSMutableArray arrayWithCapacity:data.count];
    @try {
        for (NSDictionary *entry in data) {
            id award = [awardClass new];
            [award setValue:entry[@"id"] forKey:@"identifier"];
            [award setValue:entry[@"name"] forKey:@"name"];
            [award setValue:entry[@"description"] ?: @"" forKey:@"awardDescription"];
            [award setValue:entry[@"count"] forKey:@"count"];
            [award setValue:@YES forKey:@"isEnabled"];
            [award setValue:[NSURL URLWithString:entry[@"icon_url"]] forKey:@"largeIconURL"];
            [award setValue:entry[@"icon_width"] ?: @128 forKey:@"largeIconWidth"];
            NSMutableArray *icons = [NSMutableArray array];
            for (NSDictionary *image in entry[@"resized_icons"]) {
                id icon = [iconClass new];
                [icon setValue:[NSURL URLWithString:image[@"url"]] forKey:@"url"];
                [icon setValue:image[@"width"] forKey:@"width"];
                [icon setValue:image[@"height"] forKey:@"height"];
                [icons addObject:icon];
            }
            [award setValue:icons forKey:@"resizedIcons"];
            // Mantle copies preserve these award objects even when the outer
            // RDKThing loses its associated state. This marker keeps gifting
            // routed to Reddit's current chooser after the cache expires.
            objc_setAssociatedObject(award, &kApolloAwardsModernAwardKey, @YES, OBJC_ASSOCIATION_RETAIN);
            [awards addObject:award];
        }
    } @catch (NSException *exception) {
        ApolloLog(@"[Awards] native model conversion failed (%@)", exception.name);
        return nil;
    }
    ApolloAwardsNativeSnapshot *snapshot = [ApolloAwardsNativeSnapshot new];
    snapshot.state = @{ @"fullName": fullName, @"awards": data };
    snapshot.awards = awards;
    [ApolloAwardsNativeCache() setObject:snapshot forKey:fullName];
    return snapshot;
}

static NSArray *ApolloAwardsCachedForModel(id model, NSArray *original) {
    if (!ApolloAwardsDisplayEnabled()) return original;
    NSString *fullName = ApolloAwardsFullName(model);
    if (!fullName) return original;
    NSArray *data = ApolloAwardsCached(fullName);
    if (!data) return original;
    ApolloAwardsNativeSnapshot *snapshot = ApolloAwardsNativeAwards(fullName, data);
    if (!snapshot) return original;
    objc_setAssociatedObject(model, &kApolloAwardsModelStateKey, snapshot.state, OBJC_ASSOCIATION_RETAIN);
    return snapshot.awards;
}

static void ApolloAwardsRememberRenderedState(id node) {
    if (objc_getAssociatedObject(node, &kApolloAwardsRenderedStateKey)) return;
    // didLoad runs after Swift's initializer has read model.awards. Capture
    // which cached data that initializer saw BEFORE a new request finishes.
    // A replacement node created by our own notification inherits the state
    // on newModel and therefore never starts a notification/rebuild loop.
    id state = objc_getAssociatedObject(ApolloAwardsModelForNode(node), &kApolloAwardsModelStateKey);
    objc_setAssociatedObject(node, &kApolloAwardsRenderedStateKey, state ?: @{}, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL ApolloAwardsNodeHasAwards(id node) {
    id owner = ApolloAwardsObjectIvar(node, "postInfoNode") ?: node;
    return ApolloAwardsObjectIvar(owner, "awardsNode") != nil;
}

static void ApolloAwardsInvalidateVisibleLayout(id node) {
    id owner = ApolloAwardsObjectIvar(node, "postInfoNode") ?: node;
    SEL invalidate = NSSelectorFromString(@"invalidateCalculatedLayout");
    SEL needsLayout = NSSelectorFromString(@"setNeedsLayout");
    for (id target in owner == node ? @[node] : @[owner, node]) {
        if ([target respondsToSelector:invalidate]) ((void (*)(id, SEL))objc_msgSend)(target, invalidate);
        if ([target respondsToSelector:needsLayout]) ((void (*)(id, SEL))objc_msgSend)(target, needsLayout);
    }
}

static void ApolloAwardsApplyDataToNode(id currentNode, NSString *fullName, NSArray<NSDictionary *> *data) {
    // Preload-only nodes warm the cache. Publish when Texture enters its
    // display range, before visibility, when the section's UI is ready.
    if (!data || !ApolloAwardsDisplayEnabled() || !ApolloAwardsNodeCanRender(currentNode)) return;
    id currentModel = ApolloAwardsModelForNode(currentNode);
    if (![ApolloAwardsFullName(currentModel) isEqual:fullName]) return;
    ApolloAwardsNativeSnapshot *snapshot = ApolloAwardsNativeAwards(fullName, data);
    if (!snapshot) return;
    BOOL hasAwardsNode = ApolloAwardsNodeHasAwards(currentNode);
    BOOL alreadyPublished = [objc_getAssociatedObject(currentModel, &kApolloAwardsPublishedStateKey)
                             isEqual:snapshot.state];
    if ([objc_getAssociatedObject(currentNode, &kApolloAwardsRenderedStateKey) isEqual:snapshot.state] &&
        (hasAwardsNode == (data.count > 0) || alreadyPublished)) return;
    // Another cell can read this same model after a fetch finishes but
    // before our didLoad. Its getter updates shared model state, so the
    // state alone cannot prove that OUR initializer built an AwardsNode.
    // If a native variant deliberately omits the node, one publication
    // is enough: the publication marker is never written by the getter.

    if (data.count == 0 && !ApolloAwardsNodeHasAwards(currentNode)) {
        objc_setAssociatedObject(currentNode, &kApolloAwardsRenderedStateKey, snapshot.state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return; // Most rows have no awards; no native rebuild is needed.
    }
    @try {
        // Copy the CURRENT model, not the one captured at fetch start:
        // intervening votes, comment edits and collapse changes must win.
        // Native section controllers require a different model object.
        id updated = [currentModel copy];
        if (!updated || updated == currentModel || ![updated respondsToSelector:@selector(setAwards:)]) return;
        ((void (*)(id, SEL, id))objc_msgSend)(updated, @selector(setAwards:), snapshot.awards);
        objc_setAssociatedObject(updated, &kApolloAwardsModelStateKey, snapshot.state, OBJC_ASSOCIATION_RETAIN);
        objc_setAssociatedObject(updated, &kApolloAwardsPublishedStateKey, snapshot.state, OBJC_ASSOCIATION_RETAIN);
        objc_setAssociatedObject(currentModel, &kApolloAwardsPublishedStateKey, snapshot.state, OBJC_ASSOCIATION_RETAIN);
        objc_setAssociatedObject(currentNode, &kApolloAwardsRenderedStateKey, snapshot.state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [NSNotificationCenter.defaultCenter postNotificationName:@"com.christianselig.ModelObjectUpdated"
                                                          object:currentModel userInfo:@{ @"newModel": updated }];
        ApolloLog(@"[Awards] updated native %@ display (%lu award types)",
                  [fullName hasPrefix:@"t1_"] ? @"comment" : @"post", (unsigned long)data.count);
    } @catch (NSException *exception) {
        ApolloLog(@"[Awards] native display update failed (%@)", exception.name);
    }
}

static void ApolloAwardsUpdateQueuedInterest(NSString *fullName) {
    if (!fullName) return;
    BOOL interested = NO;
    BOOL visible = NO;
    for (id node in sApolloAwardsInterestedNodes.allObjects) {
        if (![ApolloAwardsFullName(ApolloAwardsModelForNode(node)) isEqual:fullName]) continue;
        interested = YES;
        visible |= (ApolloAwardsRangeForNode(node) & ApolloAwardsNodeRangeVisible) != 0;
    }
    if (interested && ApolloAwardsDisplayEnabled()) ApolloAwardsSetQueuedPriority(fullName, visible);
    else ApolloAwardsCancelQueued(fullName);
}

static void ApolloAwardsClearPendingNode(id node) {
    objc_setAssociatedObject(node, &kApolloAwardsPendingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(node, &kApolloAwardsPendingTicketKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloAwardsFetchForNode(id node) {
    if (!ApolloAwardsDisplayEnabled() || !ApolloAwardsRangeForNode(node)) return;
    NSString *fullName = [ApolloAwardsFullName(ApolloAwardsModelForNode(node)) copy];
    if (!fullName) return;
    if ([objc_getAssociatedObject(node, &kApolloAwardsPendingKey) isEqual:fullName]) {
        // A visible entry promotes the existing preload request without
        // adding another callback; leaving visibility can downgrade it.
        ApolloAwardsUpdateQueuedInterest(fullName);
        return;
    }
    NSObject *ticket = [NSObject new];
    objc_setAssociatedObject(node, &kApolloAwardsPendingKey, fullName, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(node, &kApolloAwardsPendingTicketKey, ticket, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    BOOL visiblePriority = (ApolloAwardsRangeForNode(node) & ApolloAwardsNodeRangeVisible) != 0;
    __weak id weakNode = node;
    void (^completion)(NSArray<NSDictionary *> *) = ^(NSArray<NSDictionary *> *data) {
        id currentNode = weakNode;
        if (!currentNode) return;
        // A canceled request delivers asynchronously. A same-row re-entry
        // may already have registered a new request for this very fullname;
        // the old callback must neither clear nor satisfy its pending state.
        if (objc_getAssociatedObject(currentNode, &kApolloAwardsPendingTicketKey) != ticket) return;
        ApolloAwardsClearPendingNode(currentNode);
        // The service retains successful results even if this node left its
        // range or was reused. Only a matching display/visible node updates.
        ApolloAwardsApplyDataToNode(currentNode, fullName, data);
        if (!data && !visiblePriority && (ApolloAwardsRangeForNode(currentNode) & ApolloAwardsNodeRangeVisible)) {
            // A full queue can reject/evict speculative work immediately
            // before the visible entry tries to promote it. Retry once at
            // visible priority; a visible failure never recursively retries.
            ApolloAwardsFetchForNode(currentNode);
        }
    };
    if (visiblePriority) ApolloAwardsFetch(fullName, completion);
    else ApolloAwardsPrefetch(fullName, completion);
}

static void ApolloAwardsSchedulePreload(id node) {
    if (objc_getAssociatedObject(node, &kApolloAwardsScheduledKey)) return;
    NSObject *ticket = [NSObject new];
    objc_setAssociatedObject(node, &kApolloAwardsScheduledKey, ticket, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak id weakNode = node;
    // Start ahead of display, with a short dwell to discard fleeting preload
    // rows. The service owns the bounded, paced queue; visible rows bypass
    // this timer and take priority over speculative work.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        id currentNode = weakNode;
        if (!currentNode) return;
        if (objc_getAssociatedObject(currentNode, &kApolloAwardsScheduledKey) != ticket) return;
        objc_setAssociatedObject(currentNode, &kApolloAwardsScheduledKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloAwardsFetchForNode(currentNode);
    });
}

static void ApolloAwardsRefreshNode(id node) {
    if (!ApolloAwardsDisplayEnabled() || !ApolloAwardsRangeForNode(node)) return;
    NSString *fullName = ApolloAwardsFullName(ApolloAwardsModelForNode(node));
    if (!fullName) return;
    // Disk-backed stale data is usable immediately. Revalidation runs through
    // the normal bounded queue without withholding the existing award row.
    ApolloAwardsApplyDataToNode(node, fullName, ApolloAwardsCached(fullName));
    if (ApolloAwardsRangeForNode(node) & ApolloAwardsNodeRangeVisible) {
        objc_setAssociatedObject(node, &kApolloAwardsScheduledKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloAwardsFetchForNode(node);
    } else {
        ApolloAwardsSchedulePreload(node);
    }
}

#if APOLLO_SIM_BUILD
static void ApolloAwardsLogVisibleEntry(id node) {
    NSString *fullName = ApolloAwardsFullName(ApolloAwardsModelForNode(node));
    if (!fullName) return;
    NSArray *cached = ApolloAwardsCached(fullName);
    NSDictionary *state = cached ? @{ @"fullName": fullName, @"awards": cached } : nil;
    BOOL hasAwardsNode = ApolloAwardsNodeHasAwards(node);
    BOOL sameState = state && [objc_getAssociatedObject(node, &kApolloAwardsRenderedStateKey) isEqual:state];
    BOOL published = state && [objc_getAssociatedObject(ApolloAwardsModelForNode(node), &kApolloAwardsPublishedStateKey) isEqual:state];
    BOOL needsUpdate = cached && (cached.count > 0 || hasAwardsNode) &&
        !(sameState && (hasAwardsNode == (cached.count > 0) || published));
    SEL loadedSelector = NSSelectorFromString(@"isNodeLoaded");
    BOOL loaded = [node respondsToSelector:loadedSelector] && ((BOOL (*)(id, SEL))objc_msgSend)(node, loadedSelector);
    ApolloLog(@"[Awards][visible] %@ cached=%@ types=%lu loaded=%@ nodeHasAwards=%@ needsNativeUpdate=%@",
              fullName, cached ? @"YES" : @"NO", (unsigned long)cached.count, loaded ? @"YES" : @"NO",
              hasAwardsNode ? @"YES" : @"NO", needsUpdate ? @"YES" : @"NO");
}
#endif

static void ApolloAwardsNodeRangeChanged(id node, ApolloAwardsNodeRange range, BOOL entered) {
    if (![NSThread isMainThread]) {
        __weak id weakNode = node;
        dispatch_async(dispatch_get_main_queue(), ^{
            id currentNode = weakNode;
            if (currentNode) ApolloAwardsNodeRangeChanged(currentNode, range, entered);
        });
        return;
    }
    ApolloAwardsNodeRange ranges = ApolloAwardsRangeForNode(node);
    ranges = entered ? (ranges | range) : (ranges & ~range);
    objc_setAssociatedObject(node, &kApolloAwardsRangeKey, @(ranges), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (ranges) [sApolloAwardsInterestedNodes addObject:node];
    else [sApolloAwardsInterestedNodes removeObject:node];
    if (entered) {
        ApolloAwardsRememberRenderedState(node);
#if APOLLO_SIM_BUILD
        if (range == ApolloAwardsNodeRangeVisible) ApolloAwardsLogVisibleEntry(node);
#endif
        ApolloAwardsRefreshNode(node);
    } else {
        if (!ranges) {
            objc_setAssociatedObject(node, &kApolloAwardsScheduledKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            ApolloAwardsClearPendingNode(node);
        }
        // Track each range independently: Texture can deliver display and
        // visible exits while the same row is still useful in preload.
        ApolloAwardsUpdateQueuedInterest(ApolloAwardsFullName(ApolloAwardsModelForNode(node)));
    }
}

static BOOL ApolloAwardsIsModernModel(id model) {
    if (!model) return NO;
    if (objc_getAssociatedObject(model, &kApolloAwardsModelStateKey)) return YES;
    NSString *fullName = ApolloAwardsFullName(model);
    if (fullName && ApolloAwardsCached(fullName)) return YES;
    if (![model respondsToSelector:@selector(awards)]) return NO;
    NSArray *awards = ((id (*)(id, SEL))objc_msgSend)(model, @selector(awards));
    for (id award in awards) {
        if (objc_getAssociatedObject(award, &kApolloAwardsModernAwardKey)) return YES;
    }
    return NO;
}

%hook RDKLink
- (NSArray *)awards {
    NSArray *original = %orig;
    return ApolloAwardsCachedForModel(self, original);
}
%end

%hook RDKComment
- (NSArray *)awards {
    NSArray *original = %orig;
    return ApolloAwardsCachedForModel(self, original);
}
%end

%hook _TtC6Apollo15CommentCellNode
- (void)didLoad {
    ApolloAwardsRememberRenderedState(self);
    %orig;
}
- (void)didEnterPreloadState {
    %orig;
    ApolloAwardsNodeRangeChanged(self, ApolloAwardsNodeRangePreload, YES);
}
- (void)didExitPreloadState {
    ApolloAwardsNodeRangeChanged(self, ApolloAwardsNodeRangePreload, NO);
    %orig;
}
- (void)didEnterDisplayState {
    %orig;
    ApolloAwardsNodeRangeChanged(self, ApolloAwardsNodeRangeDisplay, YES);
}
- (void)didExitDisplayState {
    ApolloAwardsNodeRangeChanged(self, ApolloAwardsNodeRangeDisplay, NO);
    %orig;
}
- (void)didEnterVisibleState {
    %orig;
    ApolloAwardsNodeRangeChanged(self, ApolloAwardsNodeRangeVisible, YES);
}
- (void)didExitVisibleState {
    ApolloAwardsNodeRangeChanged(self, ApolloAwardsNodeRangeVisible, NO);
    %orig;
}
%end

%hook _TtC6Apollo22CommentsHeaderCellNode
- (void)didLoad {
    ApolloAwardsRememberRenderedState(self);
    %orig;
}
- (void)didEnterPreloadState {
    %orig;
    ApolloAwardsNodeRangeChanged(self, ApolloAwardsNodeRangePreload, YES);
}
- (void)didExitPreloadState {
    ApolloAwardsNodeRangeChanged(self, ApolloAwardsNodeRangePreload, NO);
    %orig;
}
- (void)didEnterDisplayState {
    %orig;
    ApolloAwardsNodeRangeChanged(self, ApolloAwardsNodeRangeDisplay, YES);
}
- (void)didExitDisplayState {
    ApolloAwardsNodeRangeChanged(self, ApolloAwardsNodeRangeDisplay, NO);
    %orig;
}
- (void)didEnterVisibleState {
    %orig;
    ApolloAwardsNodeRangeChanged(self, ApolloAwardsNodeRangeVisible, YES);
}
- (void)didExitVisibleState {
    ApolloAwardsNodeRangeChanged(self, ApolloAwardsNodeRangeVisible, NO);
    %orig;
}
%end

%hook _TtC6Apollo19CompactPostCellNode
- (void)didLoad {
    ApolloAwardsRememberRenderedState(self);
    %orig;
}
- (void)didEnterPreloadState {
    %orig;
    ApolloAwardsNodeRangeChanged(self, ApolloAwardsNodeRangePreload, YES);
}
- (void)didExitPreloadState {
    ApolloAwardsNodeRangeChanged(self, ApolloAwardsNodeRangePreload, NO);
    %orig;
}
- (void)didEnterDisplayState {
    %orig;
    ApolloAwardsNodeRangeChanged(self, ApolloAwardsNodeRangeDisplay, YES);
}
- (void)didExitDisplayState {
    ApolloAwardsNodeRangeChanged(self, ApolloAwardsNodeRangeDisplay, NO);
    %orig;
}
- (void)didEnterVisibleState {
    %orig;
    ApolloAwardsNodeRangeChanged(self, ApolloAwardsNodeRangeVisible, YES);
}
- (void)didExitVisibleState {
    ApolloAwardsNodeRangeChanged(self, ApolloAwardsNodeRangeVisible, NO);
    %orig;
}
%end

%hook _TtC6Apollo17LargePostCellNode
- (void)didLoad {
    ApolloAwardsRememberRenderedState(self);
    %orig;
}
- (void)didEnterPreloadState {
    %orig;
    ApolloAwardsNodeRangeChanged(self, ApolloAwardsNodeRangePreload, YES);
}
- (void)didExitPreloadState {
    ApolloAwardsNodeRangeChanged(self, ApolloAwardsNodeRangePreload, NO);
    %orig;
}
- (void)didEnterDisplayState {
    %orig;
    ApolloAwardsNodeRangeChanged(self, ApolloAwardsNodeRangeDisplay, YES);
}
- (void)didExitDisplayState {
    ApolloAwardsNodeRangeChanged(self, ApolloAwardsNodeRangeDisplay, NO);
    %orig;
}
- (void)didEnterVisibleState {
    %orig;
    ApolloAwardsNodeRangeChanged(self, ApolloAwardsNodeRangeVisible, YES);
}
- (void)didExitVisibleState {
    ApolloAwardsNodeRangeChanged(self, ApolloAwardsNodeRangeVisible, NO);
    %orig;
}
%end

%hook _TtC6Apollo25AwardsGivenViewController
- (void)viewDidLoad {
    %orig;
    if (!ApolloAwardsIsModernModel(ApolloAwardsObjectIvar(self, "thingToAward"))) return;
    UIView *button = ApolloAwardsObjectIvar(self, "giveAwardButton");
    if ([button isKindOfClass:UIView.class]) {
        button.hidden = NO;
        button.userInteractionEnabled = YES;
        button.accessibilityElementsHidden = NO;
    }
}
- (void)giveAwardButtonTappedWithSender:(id)sender {
    id thing = ApolloAwardsObjectIvar(self, "thingToAward");
    if (ApolloAwardsPresentGiving(thing, (UIViewController *)self)) return;
    %orig;
}
%end

#if APOLLO_SIM_BUILD
extern "C" NSString *ApolloAwardsDebugSnapshot(void) {
    NSUInteger visibleCount = 0, displayCount = 0, preloadCount = 0;
    for (id node in sApolloAwardsInterestedNodes.allObjects) {
        ApolloAwardsNodeRange ranges = ApolloAwardsRangeForNode(node);
        if (ranges & ApolloAwardsNodeRangeVisible) visibleCount++;
        if (ranges & ApolloAwardsNodeRangeDisplay) displayCount++;
        if (ranges & ApolloAwardsNodeRangePreload) preloadCount++;
    }
    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithObject:
        [NSString stringWithFormat:@"ShowAwards=%@ visibleNodes=%lu displayNodes=%lu preloadNodes=%lu",
         ApolloAwardsDisplayEnabled() ? @"YES" : @"NO", (unsigned long)visibleCount,
         (unsigned long)displayCount, (unsigned long)preloadCount]];
    for (id node in sApolloAwardsInterestedNodes.allObjects) {
        if (!(ApolloAwardsRangeForNode(node) & ApolloAwardsNodeRangeVisible)) continue;
        id model = ApolloAwardsModelForNode(node);
        NSArray *awards = [model respondsToSelector:@selector(awards)]
            ? ((id (*)(id, SEL))objc_msgSend)(model, @selector(awards)) : nil;
        long long total = 0;
        for (id award in awards) {
            @try { total += [[award valueForKey:@"count"] longLongValue]; }
            @catch (__unused NSException *exception) {}
        }
        [lines addObject:[NSString stringWithFormat:@"%@ %@ types=%lu total=%lld nodeHasAwards=%@ pending=%@",
                          NSStringFromClass(object_getClass(node)), ApolloAwardsFullName(model) ?: @"(none)",
                          (unsigned long)awards.count, total, ApolloAwardsNodeHasAwards(node) ? @"YES" : @"NO",
                          objc_getAssociatedObject(node, &kApolloAwardsPendingKey) ? @"YES" : @"NO"]];
    }
    return [lines componentsJoinedByString:@"\n"];
}
#endif

%ctor {
    sApolloAwardsInterestedNodes = [NSHashTable weakObjectsHashTable];
    %init;
    [NSNotificationCenter.defaultCenter addObserverForName:ApolloAwardsCacheDidLoadNotification
                                                    object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(__unused NSNotification *notification) {
        for (id node in sApolloAwardsInterestedNodes.allObjects) ApolloAwardsRefreshNode(node);
    }];
    [NSNotificationCenter.defaultCenter addObserverForName:@"com.christianselig.PostCellAppearanceUpdated"
                                                    object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(__unused NSNotification *notification) {
        // Apollo's notification reloads the feed, but existing comment/header
        // layout caches need explicit invalidation. Native layout reads
        // ShowAwards and omits the awards node when disabled; keep the cached
        // metadata and let that existing layout policy handle both directions.
        for (id node in sApolloAwardsInterestedNodes.allObjects) {
            if (ApolloAwardsNodeCanRender(node)) ApolloAwardsInvalidateVisibleLayout(node);
            if (ApolloAwardsDisplayEnabled()) {
                ApolloAwardsRefreshNode(node);
            } else {
                objc_setAssociatedObject(node, &kApolloAwardsScheduledKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                ApolloAwardsClearPendingNode(node);
                ApolloAwardsUpdateQueuedInterest(ApolloAwardsFullName(ApolloAwardsModelForNode(node)));
            }
        }
    }];
    ApolloLog(@"[Awards] native post/comment display hooks installed");
}
