#import "ApolloAwards.h"
#import "ApolloAwardsParsing.h"
#import "ApolloCommon.h"
#import "ApolloAwardsStore.h"
#import "ApolloAwardsListing.h"
#import "ApolloWebJSON.h"
#import "ApolloWebSessionStore.h"
#import "ApolloWebTextDecoding.h"
#import "Defaults.h"

// Reddit's legacy JSON leaves all_awardings empty. Its public award dialog
// supplies a signed link to the server-rendered leaderboard, whose rows carry
// exact per-type counts. Prefer a valid current feature session to reduce
// anonymous refusals; a request created without one remains anonymous.
// Accept is significant: without the partial-HTML media type Reddit sends 406.
static NSUInteger const kAwardsMaximumResponseBytes = 512 * 1024;
// A compact iPad viewport can contain many short comment/post rows. Leave
// room for that visible set; cells cancel queued work when they scroll away.
static NSUInteger const kAwardsMaximumQueued = 64;
static NSUInteger const kAwardsMaximumActive = 1;
NSString *const ApolloAwardsCacheDidLoadNotification = @"ApolloAwardsCacheDidLoad";

static dispatch_queue_t sAwardCacheIOQueue;
static dispatch_group_t sAwardCacheLoadGroup;

// Disk I/O never runs in Texture's model getters. Load once at startup and
// wait for that load before deciding a network request is necessary.
static ApolloAwardsStore *ApolloAwardsStoreInstance(void) {
    static ApolloAwardsStore *store;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURL *directory = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory
                                                               inDomains:NSUserDomainMask].firstObject;
        NSURL *file = [[directory URLByAppendingPathComponent:@"ApolloReborn" isDirectory:YES]
                      URLByAppendingPathComponent:@"awards-v1.plist"];
        store = [[ApolloAwardsStore alloc] initWithFileURL:file];
        sAwardCacheIOQueue = dispatch_queue_create("app.apolloreborn.awards-cache", DISPATCH_QUEUE_SERIAL);
        sAwardCacheLoadGroup = dispatch_group_create();
        dispatch_group_enter(sAwardCacheLoadGroup);
        dispatch_async(sAwardCacheIOQueue, ^{
            [store load];
            dispatch_group_leave(sAwardCacheLoadGroup);
            dispatch_async(dispatch_get_main_queue(), ^{
                [NSNotificationCenter.defaultCenter postNotificationName:ApolloAwardsCacheDidLoadNotification object:nil];
            });
        });
    });
    return store;
}

static void ApolloAwardsStoreResult(NSString *fullName, NSArray<NSDictionary *> *awards) {
    [ApolloAwardsStoreInstance() storeAwards:awards forFullName:fullName atDate:NSDate.date];
    // Coalesce writes without postponing the save indefinitely while scrolling.
    static BOOL saveScheduled;
    if (saveScheduled) return;
    saveScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        saveScheduled = NO;
        dispatch_async(sAwardCacheIOQueue, ^{ [ApolloAwardsStoreInstance() save]; });
    });
}

static NSCache *ApolloAwardsFailures(void) {
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; cache.countLimit = 500; });
    return cache;
}

NSArray<NSDictionary *> *ApolloAwardsCached(NSString *fullName) {
    NSString *key = ApolloAwardsNormalizeFullName(fullName);
    if (!key) return nil;
    return [ApolloAwardsStoreInstance() awardsForFullName:key allowStale:YES now:NSDate.date];
}

@interface ApolloAwardsRequest : NSObject <NSURLSessionDataDelegate>
@property (nonatomic, copy) NSString *fullName;
@property (nonatomic, strong) NSMutableArray *callbacks;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSMutableData *body;
@property (nonatomic, strong) NSHTTPURLResponse *response;
@property (nonatomic) BOOL leaderboard;
@property (nonatomic) BOOL visiblePriority;
@property (nonatomic) BOOL finished;
@property (nonatomic, strong) NSURL *listingURL;
@property (nonatomic, copy) NSSet<NSString *> *listingIDs;
@property (nonatomic, copy) NSString *sessionUsername;
@property (nonatomic, copy) NSString *sessionCookie;
@property (nonatomic, copy) NSDictionary<NSString *, NSNumber *> *pageCounts;
@property (nonatomic) BOOL challenge;
@property (nonatomic) NSUInteger listingRedirects;
- (void)start;
@end

// Scheduling is main-thread-only; immutable cache entries can be read by
// Texture's background model/layout queues. Keep the queue bounded while
// scrolling and share work among multiple visible instances of the same thing.
static NSMutableDictionary<NSString *, ApolloAwardsRequest *> *sAwardRequests;
static NSMutableArray<ApolloAwardsRequest *> *sAwardQueue;
static NSMutableDictionary<NSString *, ApolloAwardsRequest *> *sAwardListingWaiters;
static NSUInteger sAwardActive;
static NSDate *sAwardBackoffUntil;
static NSDate *sAwardNextRequestAt;
static BOOL sAwardDrainScheduled;
static BOOL sAwardWaitingForCache;
static void ApolloAwardsDrain(void);

static NSString *ApolloAwardsEligibleCookie(NSString *username) {
    ApolloWebSessionEntry *entry = username.length ? ApolloWebSessionPollFor(username) : nil;
    return entry.cookieHeader.length && !ApolloWebJSONAccountSessionError(username) ? entry.cookieHeader : nil;
}

// Main queue only: every read belongs to its originating account context and
// exact credential snapshot. Never substitute a newly active account, or
// retry a challenged authenticated read anonymously.
static BOOL ApolloAwardsRequestSessionIsCurrent(ApolloAwardsRequest *request) {
    NSString *username = request.sessionUsername ?: @"";
    if (![username isEqualToString:ApolloActiveWebSessionUsername().lowercaseString ?: @""]) return NO;
    NSString *cookie = ApolloAwardsEligibleCookie(username);
    if (![(request.sessionCookie ?: @"") isEqualToString:cookie ?: @""]) return NO;
    return !request.listingURL || cookie.length > 0;
}

static BOOL ApolloAwardsBackingOff(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        id saved = [NSUserDefaults.standardUserDefaults objectForKey:@"ApolloAwardsBackoffUntil"];
        if ([saved isKindOfClass:NSDate.class]) sAwardBackoffUntil = saved;
    });
    return sAwardBackoffUntil.timeIntervalSinceNow > 0;
}

#if APOLLO_SIM_BUILD
void ApolloAwardsDebugSeed(NSString *fullName, NSArray<NSDictionary *> *awards) {
    if (!ApolloAwardsNormalizeFullName(fullName) || !awards) return;
    ApolloAwardsStoreResult(fullName, awards);
}
#endif

static void ApolloAwardsDeliver(ApolloAwardsRequest *request, NSArray *awards) {
    for (NSString *fullName in request.listingIDs) {
        if (sAwardListingWaiters[fullName] == request) [sAwardListingWaiters removeObjectForKey:fullName];
    }
    NSArray *callbacks = [request.callbacks copy];
    [request.callbacks removeAllObjects];
    if (sAwardRequests[request.fullName] == request) [sAwardRequests removeObjectForKey:request.fullName];
    for (void (^callback)(NSArray *) in callbacks) callback(awards);
}

void ApolloAwardsCancelQueued(NSString *fullName) {
    void (^cancel)(void) = ^{
        ApolloAwardsRequest *request = sAwardRequests[fullName];
        if (!request || ![sAwardQueue containsObject:request]) return;
        [sAwardQueue removeObject:request];
        ApolloAwardsDeliver(request, nil);
    };
    if (NSThread.isMainThread) cancel();
    else dispatch_async(dispatch_get_main_queue(), cancel);
}

static void ApolloAwardsFinish(ApolloAwardsRequest *request, NSArray *awards, NSInteger status) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSArray *deliveredAwards = awards;
        if (!ApolloAwardsRequestSessionIsCurrent(request)) {
            // An already-sent read may finish after an account change. Ignore
            // both its data and its backoff signal, then release its waiters.
            deliveredAwards = nil;
            ApolloLog(@"[Awards] discarded read after session changed");
        } else if (request.listingURL) {
            NSUInteger zeros = 0;
            for (NSString *fullName in request.listingIDs) {
                if (sAwardListingWaiters[fullName] == request) [sAwardListingWaiters removeObjectForKey:fullName];
                NSNumber *count = request.pageCounts[fullName];
                if (count && count.unsignedLongLongValue == 0) {
                    // Never assign an aggregate total to a representative
                    // award type. Only explicit zeros fill the exact cache.
                    ApolloAwardsStoreResult(fullName, @[]);
                    zeros++;
                }
            }
            ApolloLog(@"[Awards] page warmup: %lu confirmed zero rows (HTTP %ld)", (unsigned long)zeros, (long)status);
            if (request.challenge || status == 429 || status == 403 || status == 401) {
                sAwardBackoffUntil = [NSDate dateWithTimeIntervalSinceNow:300];
                [NSUserDefaults.standardUserDefaults setObject:sAwardBackoffUntil forKey:@"ApolloAwardsBackoffUntil"];
            }
        } else if (awards) {
            ApolloAwardsStoreResult(request.fullName, awards);
            [ApolloAwardsFailures() removeObjectForKey:request.fullName];
            ApolloLog(@"[Awards] loaded %@: %lu award types", request.fullName, (unsigned long)awards.count);
        } else {
            [ApolloAwardsFailures() setObject:[NSDate dateWithTimeIntervalSinceNow:60]
                                      forKey:request.fullName];
            if (status == 429 || status == 403 || status == 401 || status == 200) {
                // A public endpoint refusal is not an expired user session.
                // Pause this feature instead of probing each visible row.
                // A CAPTCHA/challenge may itself use HTTP 200. Unknown HTML
                // also means the web contract changed; stop probing all rows.
                sAwardBackoffUntil = [NSDate dateWithTimeIntervalSinceNow:300];
                [NSUserDefaults.standardUserDefaults setObject:sAwardBackoffUntil forKey:@"ApolloAwardsBackoffUntil"];
            }
            ApolloLog(@"[Awards] unavailable %@ (HTTP %ld)", request.fullName, (long)status);
        }
        if (sAwardActive > 0) sAwardActive--;
        sAwardNextRequestAt = [NSDate dateWithTimeIntervalSinceNow:0.75];
        ApolloAwardsDeliver(request, deliveredAwards);
        ApolloAwardsDrain();
    });
}

@implementation ApolloAwardsRequest

- (void)start {
#if APOLLO_SIM_BUILD
    ApolloLog(@"[Awards][fetch] %@ priority=%@ mode=%@", self.listingURL ? @"listing warmup" : self.fullName,
              self.visiblePriority ? @"visible" : @"preload", self.sessionCookie.length ? @"session" : @"anonymous");
#endif
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.HTTPCookieStorage = nil;
    config.HTTPShouldSetCookies = NO;
    config.URLCredentialStorage = nil;
    config.URLCache = nil;
    config.timeoutIntervalForRequest = 8;
    config.timeoutIntervalForResource = 12;
    NSOperationQueue *queue = [NSOperationQueue new];
    queue.maxConcurrentOperationCount = 1;
    self.session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:queue];
    if (self.listingURL) {
        [self loadURL:self.listingURL];
        return;
    }
    NSString *url = [@"https://www.reddit.com/svc/shreddit/award-dialog/" stringByAppendingString:self.fullName];
    [self loadURL:[NSURL URLWithString:url]];
}

- (void)loadURL:(NSURL *)url {
    // The leaderboard is a second GET after the dialog. Recheck on main at
    // every hop so a session switched during the first read never travels on.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!ApolloAwardsRequestSessionIsCurrent(self)) { [self complete:nil]; return; }
        self.body = [NSMutableData new];
        self.response = nil;
        // Mark internal requests so the main transport cannot replace these
        // headers or add credentials to an intentionally anonymous snapshot.
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:ApolloWebJSONProbeURL(url)
            cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:8];
        [request setValue:self.listingURL ? @"text/html" : @"text/vnd.reddit.partial+html, text/html;q=0.9" forHTTPHeaderField:@"Accept"];
        [request setValue:@"en-US,en;q=0.9" forHTTPHeaderField:@"Accept-Language"];
        [request setValue:self.listingURL ? defaultUserAgent : @"ApolloReborn-awards-readonly/1.0"
            forHTTPHeaderField:@"User-Agent"];
        if (self.sessionCookie.length) [request setValue:self.sessionCookie forHTTPHeaderField:@"Cookie"];
        [[self.session dataTaskWithRequest:request] resume];
    });
}

- (void)complete:(NSArray *)awards {
    if (self.finished) return;
    self.finished = YES;
    NSInteger status = self.response.statusCode;
    [self.session invalidateAndCancel];
    self.session = nil;
    self.body = nil;
    ApolloAwardsFinish(self, awards, status);
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
    completionHandler:(void (^)(NSURLRequest *))completionHandler {
    // Modern pages can add a canonical subreddit/title slug and switch their
    // sh/www host. Keep both hops bounded and preserve the actual post/comment
    // identity and query. Cookies never follow login or unrelated URLs.
    NSURL *URL = request.URL;
    BOOL canonicalPage = self.listingURL && self.listingRedirects < 2 &&
        ApolloAwardsListingAllowsRedirect(response.URL, URL);
#if APOLLO_SIM_BUILD
    if (self.listingURL) ApolloLog(@"[Awards][redirect] %@ -> %@ pathMatch=%d queryMatch=%d accepted=%d",
        response.URL.host, URL.host, [URL.path isEqualToString:response.URL.path],
        [(URL.query ?: @"") isEqualToString:(response.URL.query ?: @"")], canonicalPage);
#endif
    if (!canonicalPage) { completionHandler(nil); return; }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!ApolloAwardsRequestSessionIsCurrent(self)) { completionHandler(nil); return; }
        self.listingRedirects++;
        NSMutableURLRequest *redirect = [request mutableCopy];
        redirect.URL = ApolloWebJSONProbeURL(URL);
        [redirect setValue:self.sessionCookie forHTTPHeaderField:@"Cookie"];
        completionHandler(redirect);
    });
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task
    didReceiveResponse:(NSURLResponse *)response
    completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    self.response = [response isKindOfClass:NSHTTPURLResponse.class] ? (id)response : nil;
    BOOL accepted = self.response.statusCode == 200 &&
        [response.MIMEType.lowercaseString containsString:@"html"] &&
        response.expectedContentLength <= (int64_t)(self.listingURL ? 4 * 1024 * 1024 : kAwardsMaximumResponseBytes);
    completionHandler(accepted ? NSURLSessionResponseAllow : NSURLSessionResponseCancel);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    if (self.body.length + data.length > (self.listingURL ? 4 * 1024 * 1024 : kAwardsMaximumResponseBytes)) {
        [task cancel];
        return;
    }
    [self.body appendData:data];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (self.finished) return;
    if (error || self.response.statusCode != 200) {
        if (error) ApolloLog(@"[Awards] %@ transport error %@/%ld (%@)", self.listingURL ? @"listing warmup" : self.fullName,
                            error.domain, (long)error.code, self.leaderboard ? @"leaderboard" : @"dialog");
        [self complete:nil];
        return;
    }
    NSString *html = ApolloWebTextFromData(self.body, self.response, NULL);
    if (self.listingURL) {
        self.pageCounts = ApolloAwardsParsePageCounts(html);
        self.challenge = ApolloAwardsClassifyUnparsedHTML(html, self.listingIDs.anyObject) == ApolloAwardsUnparsedHTMLChallenge;
        [self complete:nil];
    } else if (self.leaderboard) {
        NSArray *awards = ApolloAwardsParseLeaderboard(html, self.fullName);
        if (!awards) {
            ApolloLog(@"[Awards] unrecognized leaderboard for %@", self.fullName);
        }
        [self complete:awards];
    } else {
        NSURL *url = ApolloAwardsLeaderboardURL(html, self.fullName);
        if (!url) {
            ApolloLog(@"[Awards] unrecognized dialog for %@", self.fullName);
            [self complete:nil];
            return;
        }
        self.leaderboard = YES;
        [self loadURL:url];
    }
}

@end

static void ApolloAwardsDrain(void) {
    // Keep waiting work in the real queue/map so visibility changes can
    // promote, downgrade, or cancel it even during the startup disk read.
    if (dispatch_group_wait(sAwardCacheLoadGroup, DISPATCH_TIME_NOW) != 0) {
        if (!sAwardWaitingForCache) {
            sAwardWaitingForCache = YES;
            dispatch_group_notify(sAwardCacheLoadGroup, dispatch_get_main_queue(), ^{
                sAwardWaitingForCache = NO;
                ApolloAwardsDrain();
            });
        }
        return;
    }
    NSTimeInterval delay = sAwardNextRequestAt.timeIntervalSinceNow;
    if (delay > 0) {
        if (!sAwardDrainScheduled) {
            sAwardDrainScheduled = YES;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                sAwardDrainScheduled = NO;
                ApolloAwardsDrain();
            });
        }
        return;
    }
    while (sAwardQueue.count > 0 && sAwardActive < kAwardsMaximumActive) {
        // Visible rows jump ahead of speculative preload work, preserving
        // arrival order within each priority. An in-flight GET is left alone.
        NSUInteger index = [sAwardQueue indexOfObjectPassingTest:^BOOL(ApolloAwardsRequest *candidate, NSUInteger idx, BOOL *stop) {
            return candidate.visiblePriority && !sAwardListingWaiters[candidate.fullName];
        }];
        if (index == NSNotFound) index = [sAwardQueue indexOfObjectPassingTest:^BOOL(ApolloAwardsRequest *candidate, NSUInteger idx, BOOL *stop) {
            return !sAwardListingWaiters[candidate.fullName];
        }];
        if (index == NSNotFound) return;
        ApolloAwardsRequest *request = sAwardQueue[index];
        [sAwardQueue removeObjectAtIndex:index];
        if (![NSUserDefaults.standardUserDefaults boolForKey:@"ShowAwards"] ||
            ApolloAwardsBackingOff() || !ApolloAwardsRequestSessionIsCurrent(request)) {
            ApolloAwardsDeliver(request, nil);
            continue;
        }
        NSArray *cached = request.listingURL ? nil : [ApolloAwardsStoreInstance() awardsForFullName:request.fullName allowStale:NO now:NSDate.date];
        if (cached) { ApolloAwardsDeliver(request, cached); continue; }
        sAwardActive++;
        [request start];
    }
}

static void ApolloAwardsEnqueue(NSString *fullName, BOOL visiblePriority, void (^completion)(NSArray<NSDictionary *> *)) {
    if (!completion) return;
    NSString *key = ApolloAwardsNormalizeFullName(fullName);
    ApolloAwardsStoreInstance();
    // Callbacks stay asynchronous on main, while requests are registered
    // immediately there so lifecycle cancellation cannot miss deferred work.
    void (^deliver)(NSArray *) = ^(NSArray *awards) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(awards); });
    };
    void (^enqueue)(void) = ^{
        if (!key || ![NSUserDefaults.standardUserDefaults boolForKey:@"ShowAwards"]) {
            deliver(nil);
            return;
        }
        NSArray *cached = [ApolloAwardsStoreInstance() awardsForFullName:key allowStale:NO now:NSDate.date];
        if (cached) { deliver(cached); return; }
        NSDate *failedUntil = [ApolloAwardsFailures() objectForKey:key];
        if (failedUntil.timeIntervalSinceNow > 0 || ApolloAwardsBackingOff()) {
            deliver(nil);
            return;
        }
#if APOLLO_SIM_BUILD
        if ([NSProcessInfo.processInfo.environment[@"APOLLO_AWARDS_NETWORK_DISABLED"] boolValue]) {
            deliver(nil);
            return;
        }
#endif
        if (!sAwardRequests) {
            sAwardRequests = [NSMutableDictionary new];
            sAwardQueue = [NSMutableArray new];
        }
        NSString *username = ApolloActiveWebSessionUsername().lowercaseString ?: @"";
        NSString *cookie = ApolloAwardsEligibleCookie(username);
        ApolloAwardsRequest *request = sAwardRequests[key];
        if (request && ApolloAwardsRequestSessionIsCurrent(request) &&
            [(request.sessionCookie ?: @"") isEqualToString:cookie ?: @""]) {
            [request.callbacks addObject:[deliver copy]];
            if (visiblePriority) request.visiblePriority = YES;
            return;
        }
        if (request && [sAwardQueue containsObject:request]) {
            [sAwardQueue removeObject:request];
            ApolloAwardsDeliver(request, nil);
        }
        if (sAwardQueue.count >= kAwardsMaximumQueued) {
            NSUInteger index = [sAwardQueue indexOfObjectPassingTest:^BOOL(ApolloAwardsRequest *candidate, NSUInteger idx, BOOL *stop) {
                return !candidate.visiblePriority;
            }];
            // Speculative work never displaces a currently visible request.
            if (index == NSNotFound && !visiblePriority) { deliver(nil); return; }
            ApolloAwardsRequest *oldest = sAwardQueue[index == NSNotFound ? 0 : index];
            [sAwardQueue removeObject:oldest];
            ApolloAwardsDeliver(oldest, nil);
        }
        request = [ApolloAwardsRequest new];
        request.fullName = key;
        request.sessionUsername = username;
        request.sessionCookie = cookie;
        request.visiblePriority = visiblePriority;
        request.callbacks = [NSMutableArray arrayWithObject:[deliver copy]];
        sAwardRequests[key] = request;
        [sAwardQueue addObject:request];
        ApolloAwardsDrain();
    };
    if (NSThread.isMainThread) enqueue();
    else dispatch_async(dispatch_get_main_queue(), enqueue);
}

void ApolloAwardsFetch(NSString *fullName, void (^completion)(NSArray<NSDictionary *> *)) {
    ApolloAwardsEnqueue(fullName, YES, completion);
}

void ApolloAwardsPrefetch(NSString *fullName, void (^completion)(NSArray<NSDictionary *> *)) {
    ApolloAwardsEnqueue(fullName, NO, completion);
}

void ApolloAwardsSetQueuedPriority(NSString *fullName, BOOL visible) {
    void (^update)(void) = ^{ sAwardRequests[fullName].visiblePriority = visible; };
    if (NSThread.isMainThread) update();
    else dispatch_async(dispatch_get_main_queue(), update);
}

void ApolloAwardsRefresh(NSString *fullName) {
    NSString *key = ApolloAwardsNormalizeFullName(fullName);
    if (!key) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        ApolloAwardsRequest *inFlight = sAwardRequests[key] ?: sAwardListingWaiters[key];
        if (inFlight) {
            // A read begun before giving must finish before the replacement
            // read, or an old response could overwrite the new award count.
            [inFlight.callbacks addObject:[^(__unused NSArray *result) { ApolloAwardsRefresh(key); } copy]];
            return;
        }
        [ApolloAwardsStoreInstance() expireFreshnessForFullName:key];
        [ApolloAwardsFailures() removeObjectForKey:key];
        dispatch_async(sAwardCacheIOQueue, ^{ [ApolloAwardsStoreInstance() save]; });
        ApolloAwardsFetch(key, ^(NSArray *result) {
            if (result) [NSNotificationCenter.defaultCenter postNotificationName:ApolloAwardsCacheDidLoadNotification object:nil];
        });
    });
}

void ApolloAwardsObserveListingResponse(NSHTTPURLResponse *response, id object) {
    if (response.statusCode != 200) return;
    NSString *username = ApolloWebJSONAccountFromURL(response.URL).lowercaseString;
    // A serializer does not expose the original OAuth client. Without exact
    // attribution, keep the existing anonymous per-thing path rather than
    // attaching the active account's browser cookie to an unrelated response.
    if (!username.length) return;
    NSURL *URL = ApolloAwardsListingPageURL(response.URL);
    if (!URL) return;
    NSSet *IDs = ApolloAwardsListingThingIDs(object);
    if (IDs.count < 4) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (![NSUserDefaults.standardUserDefaults boolForKey:@"ShowAwards"] || ApolloAwardsBackingOff()) return;
#if APOLLO_SIM_BUILD
        if ([NSProcessInfo.processInfo.environment[@"APOLLO_AWARDS_NETWORK_DISABLED"] boolValue]) return;
#endif
        // Modern pages honor the signed-in account's access and preferences.
        // Auxiliary web sessions leave an API-key account's transport intact.
        if (![username isEqualToString:ApolloActiveWebSessionUsername().lowercaseString]) return;
        ApolloWebSessionEntry *entry = ApolloWebSessionPollFor(username);
        if (!entry.cookieHeader.length || ApolloWebJSONAccountSessionError(username)) return;
        static NSCache *recentPages;
        if (!recentPages) { recentPages = [NSCache new]; recentPages.countLimit = 128; }
        NSString *key = [NSString stringWithFormat:@"listing:%@:%@", username, URL.absoluteString];
        if ([(NSDate *)[recentPages objectForKey:key] timeIntervalSinceNow] > 0 || sAwardQueue.count >= kAwardsMaximumQueued) return;
        NSMutableSet *missing = [NSMutableSet new];
        for (NSString *fullName in IDs) {
            if (!sAwardListingWaiters[fullName] &&
                ![ApolloAwardsStoreInstance() awardsForFullName:fullName allowStale:NO now:NSDate.date]) [missing addObject:fullName];
        }
        if (missing.count < 4) return;
        if (!sAwardRequests) {
            sAwardRequests = [NSMutableDictionary new];
            sAwardQueue = [NSMutableArray new];
        }
        if (!sAwardListingWaiters) sAwardListingWaiters = [NSMutableDictionary new];
        ApolloAwardsRequest *request = [ApolloAwardsRequest new];
        request.fullName = key;
        request.callbacks = [NSMutableArray new];
        request.visiblePriority = YES;
        request.listingURL = URL;
        request.listingIDs = [missing copy];
        request.sessionUsername = username;
        request.sessionCookie = entry.cookieHeader;
        for (NSString *fullName in missing) sAwardListingWaiters[fullName] = request;
        [recentPages setObject:[NSDate dateWithTimeIntervalSinceNow:300] forKey:key];
        sAwardRequests[key] = request;
        [sAwardQueue insertObject:request atIndex:0];
        ApolloAwardsDrain();
    });
}

__attribute__((constructor)) static void ApolloAwardsInitializeCache(void) {
    @autoreleasepool { ApolloAwardsStoreInstance(); }
}
