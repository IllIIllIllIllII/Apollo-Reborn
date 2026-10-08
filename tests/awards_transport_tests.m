#import <Foundation/Foundation.h>
#import "ApolloAwards.h"
#import "ApolloAwardsStore.h"
#import "ApolloAwardsListing.h"
#define ApolloLog(...) do { if (NO) NSLog(__VA_ARGS__); } while (0)
static NSUInteger const kAwardsMaximumQueued = 64;
static NSUInteger const kAwardsMaximumActive = 1;
NSString *const ApolloAwardsCacheDidLoadNotification = @"test-cache-loaded";
static dispatch_queue_t sAwardCacheIOQueue;
static dispatch_group_t sAwardCacheLoadGroup;
static ApolloAwardsStore *store;
static NSCache *failures;
static NSMutableArray *asynchronous;
static NSMutableArray *delayed;
static NSMutableArray *started;
static NSMutableArray *sentRequests;
static NSString *activeUsername;
static NSMutableDictionary *sessions;
static BOOL invalidSession;
static NSUInteger checks;
@interface ApolloWebSessionEntry : NSObject
@property(copy) NSString *cookieHeader;
@end
@implementation ApolloWebSessionEntry
@end
static NSString *ApolloActiveWebSessionUsername(void) { return activeUsername; }
static ApolloWebSessionEntry *ApolloWebSessionPollFor(NSString *username) { return sessions[username]; }
static NSError *ApolloWebJSONAccountSessionError(NSString *username) {
    (void)username;
    return invalidSession ? [NSError errorWithDomain:@"test" code:1 userInfo:nil] : nil;
}
static NSString *const kApolloWebJSONAccountMarkerPrefix = @"apollo-webjson-account=";
// PRODUCTION_MARKER
static ApolloAwardsStore *ApolloAwardsStoreInstance(void) { return store; }
static NSCache *ApolloAwardsFailures(void) { return failures; }
static NSString *ApolloAwardsNormalizeFullName(NSString *name) { return name.lowercaseString; }
static void ApolloAwardsStoreResult(NSString *name, NSArray *awards) { [store storeAwards:awards forFullName:name atDate:NSDate.date]; }
static void testAsync(dispatch_queue_t queue, dispatch_block_t block) { (void)queue; [asynchronous addObject:[block copy]]; }
static void testAfter(dispatch_time_t when, dispatch_queue_t queue, dispatch_block_t block) {
    (void)when; (void)queue; [delayed addObject:[block copy]];
}
static NSString *const defaultUserAgent = @"test-browser";
static NSURL *ApolloWebJSONProbeURL(NSURL *url) { return url; }
@interface TestDataTask : NSObject
@property(copy) NSURLRequest *request;
- (void)resume;
@end
@implementation TestDataTask
- (void)resume { [sentRequests addObject:self.request]; }
@end
@interface TestSession : NSObject
- (TestDataTask *)dataTaskWithRequest:(NSURLRequest *)request;
@end
@implementation TestSession
- (TestDataTask *)dataTaskWithRequest:(NSURLRequest *)request { TestDataTask *task = [TestDataTask new]; task.request = request; return task; }
@end
// PRODUCTION_INTERFACE
static BOOL ApolloAwardsRequestSessionIsCurrent(ApolloAwardsRequest *request);
static void ApolloAwardsFinish(ApolloAwardsRequest *request, NSArray *awards, NSInteger status);
#define dispatch_async testAsync
@implementation ApolloAwardsRequest
- (void)start { [started addObject:self]; }
// PRODUCTION_LOAD
- (void)complete:(NSArray *)awards { self.finished = YES; ApolloAwardsFinish(self, awards, 0); }
@end
#define dispatch_after testAfter
// PRODUCTION_SCHEDULER
#undef dispatch_async
#undef dispatch_after
static void Check(BOOL condition, NSString *message) { checks++; if (!condition) { NSLog(@"FAIL: %@", message); abort(); } }
static void Flush(void) {
    NSUInteger count = 0;
    while (asynchronous.count) {
        Check(count++ < 100, @"callbacks remain bounded");
        dispatch_block_t block = asynchronous.firstObject;
        [asynchronous removeObjectAtIndex:0];
        block();
    }
}
static void Cookie(NSString *user, NSString *cookie) {
    ApolloWebSessionEntry *entry = [ApolloWebSessionEntry new]; entry.cookieHeader = cookie; sessions[user] = entry;
}
static void Reset(void) {
    store = [[ApolloAwardsStore alloc] initWithFileURL:[NSURL URLWithString:@"https://example.invalid/no-disk"]];
    failures = [NSCache new]; asynchronous = [NSMutableArray new]; delayed = [NSMutableArray new]; started = [NSMutableArray new]; sentRequests = [NSMutableArray new];
    sessions = [NSMutableDictionary new]; activeUsername = @"alice"; invalidSession = NO;
    Cookie(@"alice", @"session=alice"); Cookie(@"bob", @"session=bob");
    sAwardRequests = [NSMutableDictionary new]; sAwardQueue = [NSMutableArray new]; sAwardListingWaiters = [NSMutableDictionary new];
    sAwardActive = 0; sAwardBackoffUntil = nil; sAwardNextRequestAt = nil; sAwardDrainScheduled = NO;
    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"ApolloAwardsBackoffUntil"];
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"ShowAwards"];
}
static void Observe(NSString *path, NSString *username) {
    NSString *fragment = username ? [@"#apollo-webjson-account=" stringByAppendingString:username] : @"";
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://www.reddit.com/r/%@.json%@", path, fragment]];
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:url statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:nil];
    NSMutableArray *children = [NSMutableArray new];
    for (NSString *name in @[@"t3_one", @"t3_two", @"t3_three", @"t3_four"]) [children addObject:@{@"kind":@"t3", @"data":@{@"name":name}}];
    ApolloAwardsObserveListingResponse(response, @{@"kind":@"Listing", @"data":@{@"children":children}});
}
int main(void) { @autoreleasepool {
    sAwardCacheLoadGroup = dispatch_group_create(); sAwardCacheIOQueue = dispatch_get_main_queue();
    Reset(); Observe(@"unattributed", nil); Flush(); Check(started.count == 0, @"unattributed OAuth response never borrows active cookie");
    Observe(@"wrong_origin", @"bob"); Flush(); Check(started.count == 0, @"other account's response is ignored");
    Observe(@"switch_before_registration", @"alice"); activeUsername = @"bob"; Flush(); Check(started.count == 0, @"switch before main-queue registration is ignored");

    Reset(); sAwardActive = 1; Observe(@"queued_switch", @"alice"); Flush();
    Check(sAwardQueue.count == 1 && sAwardListingWaiters.count == 4, @"warmup queued with waiters");
    activeUsername = @"bob"; sAwardActive = 0; ApolloAwardsDrain(); Flush();
    Check(started.count == 0 && sAwardQueue.count == 0 && sAwardListingWaiters.count == 0, @"queued old-account request is canceled and releases waiters");

    Reset(); sAwardActive = 1; Observe(@"queued_replacement", @"alice"); Flush(); Cookie(@"alice", @"session=new"); sAwardActive = 0; ApolloAwardsDrain();
    Check(started.count == 0 && sAwardListingWaiters.count == 0, @"queued obsolete cookie never sends");
    Reset(); sAwardActive = 1; Observe(@"queued_invalid", @"alice"); Flush(); invalidSession = YES; sAwardActive = 0; ApolloAwardsDrain();
    Check(started.count == 0, @"known-invalid session never sends");

    Reset(); Observe(@"inflight_switch", @"alice"); Flush(); ApolloAwardsRequest *old = started.firstObject;
    Check([old.sessionUsername isEqual:@"alice"] && [old.sessionCookie isEqual:@"session=alice"], @"request binds exact originating credentials");
    old.pageCounts = @{@"t3_one":@0}; old.challenge = YES; activeUsername = @"bob"; ApolloAwardsFinish(old, nil, 403); Flush();
    Check([store awardsForFullName:@"t3_one" allowStale:YES now:NSDate.date] == nil, @"stale completion cannot seed zero cache");
    Check(!ApolloAwardsBackingOff() && sAwardListingWaiters.count == 0, @"stale refusal cannot back off new account and releases waiters");

    Reset(); Observe(@"same_page", @"alice"); Flush(); old = started.firstObject; activeUsername = @"bob"; ApolloAwardsFinish(old, nil, 200); Flush();
    sAwardNextRequestAt = nil; Observe(@"same_page", @"bob"); Flush(); Check(started.count == 2, @"recent-page suppression is scoped to account");

    Reset(); Observe(@"valid_zeros", @"alice"); Flush(); ApolloAwardsRequest *page = started.firstObject;
    __block NSUInteger callbacks = 0; __block NSArray *received = nil;
    ApolloAwardsFetch(@"t3_one", ^(NSArray *awards) { callbacks++; received = awards; });
    Check(started.count == 1 && callbacks == 0, @"item waits behind its page warmup");
    page.pageCounts = @{@"t3_one":@0}; ApolloAwardsFinish(page, nil, 200); Flush(); sAwardNextRequestAt = nil; ApolloAwardsDrain(); Flush();
    Check(started.count == 1 && callbacks == 1 && received != nil && received.count == 0, @"confirmed zero satisfies waiter without per-item request");

    Reset(); sAwardActive = 1; callbacks = 0; ApolloAwardsFetch(@"t3_one", ^(NSArray *awards) { callbacks++; Check(awards == nil, @"cancellation remains unknown"); });
    ApolloAwardsCancelQueued(@"t3_one"); Check(callbacks == 0, @"cancellation callback stays asynchronous");
    ApolloAwardsFetch(@"t3_one", ^(NSArray *awards) { (void)awards; }); Flush();
    Check(callbacks == 1 && sAwardRequests[@"t3_one"] != nil && sAwardQueue.count == 1, @"old cancellation does not remove new same-item request");

    Reset(); [store storeAwards:@[] forFullName:@"t3_one" atDate:NSDate.date]; [failures setObject:[NSDate dateWithTimeIntervalSinceNow:60] forKey:@"t3_one"];
    ApolloAwardsRefresh(@"t3_one"); Flush();
    Check([store awardsForFullName:@"t3_one" allowStale:YES now:NSDate.date] == nil && [failures objectForKey:@"t3_one"] == nil && started.count == 1,
          @"explicit refresh removes stale negative and transient failure then sends");
    Reset(); sAwardBackoffUntil = [NSDate dateWithTimeIntervalSinceNow:300]; [failures setObject:[NSDate dateWithTimeIntervalSinceNow:60] forKey:@"t3_one"];
    ApolloAwardsRefresh(@"t3_one"); Flush(); Check(started.count == 0 && ApolloAwardsBackingOff(), @"explicit refresh preserves global challenge backoff");

    Reset(); ApolloAwardsFetch(@"t3_one", ^(NSArray *awards) { (void)awards; }); old = started.firstObject;
    ApolloAwardsRefresh(@"t3_one"); Flush(); Check(started.count == 1, @"refresh waits for read that predates giving");
    ApolloAwardsFinish(old, @[], 200); Flush(); sAwardNextRequestAt = nil; ApolloAwardsDrain();
    Check(started.count == 2 && [store awardsForFullName:@"t3_one" allowStale:YES now:NSDate.date] == nil,
          @"pre-giving zero cannot suppress replacement read");

    Reset(); __block NSUInteger oldCalls = 0; __block NSUInteger newCalls = 0;
    ApolloAwardsFetch(@"t3_one", ^(NSArray *awards) { oldCalls++; Check(awards == nil, @"old account result is not published"); }); old = started.firstObject;
    Check([old.sessionUsername isEqual:@"alice"] && [old.sessionCookie isEqual:@"session=alice"], @"exact read prefers eligible captured session");
    activeUsername = @"bob"; ApolloAwardsFetch(@"t3_one", ^(NSArray *awards) { (void)awards; newCalls++; });
    ApolloAwardsRequest *replacement = sAwardRequests[@"t3_one"];
    Check(replacement != old && [replacement.sessionCookie isEqual:@"session=bob"], @"new account receives separate request and credentials");
    ApolloAwardsFinish(old, @[], 200); Flush();
    Check(oldCalls == 1 && newCalls == 0 && sAwardRequests[@"t3_one"] == replacement && [store awardsForFullName:@"t3_one" allowStale:YES now:NSDate.date] == nil,
          @"late old response cannot satisfy or remove replacement request");
    sAwardNextRequestAt = nil; ApolloAwardsDrain(); Check(started.lastObject == replacement, @"replacement starts after old request leaves active slot");
    ApolloAwardsFinish(replacement, @[], 200); Flush(); Check(newCalls == 1, @"replacement callback completes exactly once");

    Reset(); ApolloAwardsFetch(@"t3_one", ^(NSArray *awards) { (void)awards; }); old = started.firstObject;
    old.session = (id)[TestSession new]; [old loadURL:[NSURL URLWithString:@"https://www.reddit.com/svc/shreddit/award-dialog/t3_one"]]; Flush();
    Check(sentRequests.count == 1 && [[sentRequests.firstObject valueForHTTPHeaderField:@"Cookie"] isEqual:@"session=alice"], @"first exact hop sends captured cookie");
    Cookie(@"alice", @"session=replaced"); [old loadURL:[NSURL URLWithString:@"https://www.reddit.com/svc/shreddit/award-leaderboard/t3_one"]]; Flush();
    Check(sentRequests.count == 1 && !ApolloAwardsBackingOff(), @"credential replacement cancels second hop without anonymous fallback or global backoff");

    Reset(); [sessions removeAllObjects]; ApolloAwardsFetch(@"t3_one", ^(NSArray *awards) { (void)awards; }); old = started.firstObject;
    Check(old.sessionCookie == nil && ApolloAwardsRequestSessionIsCurrent(old), @"missing feature session permits anonymous creation");
    old.session = (id)[TestSession new]; [old loadURL:[NSURL URLWithString:@"https://www.reddit.com/svc/shreddit/award-dialog/t3_one"]]; Flush();
    Check(sentRequests.count == 1 && [sentRequests.firstObject valueForHTTPHeaderField:@"Cookie"] == nil, @"anonymous request never gains implicit cookies");
    Cookie(@"alice", @"session=new"); Check(!ApolloAwardsRequestSessionIsCurrent(old), @"newly eligible session makes old anonymous context obsolete");

    Reset(); ApolloAwardsFetch(@"t3_one", ^(NSArray *awards) { (void)awards; }); old = started.firstObject;
    ApolloAwardsFinish(old, nil, 403); Flush(); Check(ApolloAwardsBackingOff() && started.count == 1, @"authenticated refusal retains cooldown and does not retry anonymously");
    printf("Awards transport: %lu checks passed\n", (unsigned long)checks);
} return 0; }
