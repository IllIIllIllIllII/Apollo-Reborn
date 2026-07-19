// Background unread poller for the modern Reddit Chat mailbox. See the header
// for the architecture summary. Data flow:
//
//   timer/kick -> eligibility gates -> bearer (token_v2, minted when stale)
//     -> GET matrix.redditspace.com/_matrix/client/v3/sync (filtered, ~2 KB)
//     -> ApolloModernChatPublishPolledStatus (badge/switcher UI updates)
//     -> Bark transition push (client-side, only when counts rise)

#import "ApolloChatUnreadPoller.h"
#import "ApolloBarkNotifications.h"
#import "ApolloCommon.h"
#import "ApolloDirectChatWeb.h"
#import "ApolloWebSessionLoginViewController.h"
#import "ApolloWebSessionStore.h"
#import "UserDefaultConstants.h"

#import <UIKit/UIKit.h>

static const NSTimeInterval kChatPollDefaultInterval = 30.0;   // foreground cadence
static const NSTimeInterval kChatPollBearerSlack = 120.0;      // refresh token_v2 this close to expiry
static const NSTimeInterval kChatPollMintBackoff = 15.0 * 60.0;
static const NSTimeInterval kChatPollAuthBackoff = 30.0 * 60.0;
static const NSTimeInterval kChatPollServerBackoff = 5.0 * 60.0;
static const NSTimeInterval kChatPollRequestTimeout = 15.0;

// Matches the modern mailbox webview's Safari persona (ApolloDirectChatWeb.xm)
// so the token_v2 mint looks like the same browser session Reddit harvested.
static NSString *const kChatPollMintUserAgent =
    @"Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 "
    @"(KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1";

// Minimal sync filter: one m.room.message per room for previews, no state, no
// ephemeral traffic. Reddit's com.reddit.* counters always ride at the top
// level regardless of the filter (verified live on full and `since` syncs).
static NSString *const kChatPollSyncFilter =
    @"{\"room\":{\"timeline\":{\"limit\":1,\"types\":[\"m.room.message\"]},"
    @"\"state\":{\"types\":[]},\"ephemeral\":{\"types\":[]},\"account_data\":{\"types\":[]}},"
    @"\"presence\":{\"types\":[]},\"account_data\":{\"types\":[]}}";

// All mutable poller state is confined to the main thread.
static NSTimer *sChatPollTimer = nil;
static BOOL sChatPollInFlight = NO;
static BOOL sChatPollPendingKick = NO;

static NSString *sChatPollBearer = nil;
static NSTimeInterval sChatPollBearerExpiry = 0;
static NSString *sChatPollUsername = nil;      // owner of bearer/since/backoff state

static NSString *sChatPollSinceToken = nil;
static NSString *sChatPollSinceBase = nil;     // homeserver the since token belongs to

static NSTimeInterval sChatPollMintBlockedUntil = 0;
static NSTimeInterval sChatPollAuthBlockedUntil = 0;
static NSTimeInterval sChatPollServerBlockedUntil = 0;

#pragma mark - Small helpers

static NSString *ApolloChatPollCookieValue(NSString *cookieHeader, NSString *name) {
    if (cookieHeader.length == 0 || name.length == 0) return nil;
    NSString *prefix = [name stringByAppendingString:@"="];
    for (NSString *pair in [cookieHeader componentsSeparatedByString:@";"]) {
        NSString *trimmed = [pair stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if ([trimmed hasPrefix:prefix]) return [trimmed substringFromIndex:prefix.length];
    }
    return nil;
}

// token_v2 is a JWT; its payload carries the expiry. 0 when unparseable.
static NSTimeInterval ApolloChatPollJWTExpiry(NSString *jwt) {
    NSArray<NSString *> *parts = [jwt componentsSeparatedByString:@"."];
    if (parts.count < 2) return 0;
    NSString *payload = [[parts[1] stringByReplacingOccurrencesOfString:@"-" withString:@"+"]
                         stringByReplacingOccurrencesOfString:@"_" withString:@"/"];
    NSUInteger remainder = payload.length % 4;
    if (remainder > 0) {
        payload = [payload stringByPaddingToLength:payload.length + (4 - remainder)
                                        withString:@"=" startingAtIndex:0];
    }
    NSData *data = [[NSData alloc] initWithBase64EncodedString:payload options:0];
    if (!data) return 0;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]]) return 0;
    id exp = json[@"exp"];
    return [exp respondsToSelector:@selector(doubleValue)] ? [exp doubleValue] : 0;
}

static NSString *ApolloChatPollHomeserverBase(void) {
    // Hidden debug override so the whole pipeline can be exercised against a
    // local mock homeserver in the simulator. Never set in normal use.
    NSString *override = [[NSUserDefaults standardUserDefaults] stringForKey:UDKeyChatPollerHomeserverOverride];
    if ([override isKindOfClass:[NSString class]] && [override hasPrefix:@"http"]) return override;
    return @"https://matrix.redditspace.com";
}

static void ApolloChatPollResetPerAccountState(void) {
    sChatPollBearer = nil;
    sChatPollBearerExpiry = 0;
    sChatPollSinceToken = nil;
    sChatPollSinceBase = nil;
    sChatPollMintBlockedUntil = 0;
    sChatPollAuthBlockedUntil = 0;
    sChatPollServerBlockedUntil = 0;
}

#pragma mark - token_v2 bearer

// Captures Set-Cookie headers from every hop: Reddit often answers the
// homepage with a redirect whose response already carries the fresh token_v2,
// and NSURLSession only exposes the final response to the completion handler.
@interface ApolloChatPollMintDelegate : NSObject <NSURLSessionTaskDelegate>
@property (nonatomic, strong) NSMutableArray<NSHTTPURLResponse *> *responses;
@end

@implementation ApolloChatPollMintDelegate
- (instancetype)init {
    if ((self = [super init])) _responses = [NSMutableArray array];
    return self;
}
- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
willPerformHTTPRedirection:(NSHTTPURLResponse *)response
        newRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLRequest *))completionHandler {
    @synchronized (self.responses) { [self.responses addObject:response]; }
    completionHandler(request);
}
@end

static NSString *ApolloChatPollTokenFromResponses(NSArray<NSHTTPURLResponse *> *responses) {
    NSURL *redditURL = [NSURL URLWithString:@"https://www.reddit.com/"];
    for (NSHTTPURLResponse *response in responses) {
        NSArray<NSHTTPCookie *> *cookies =
            [NSHTTPCookie cookiesWithResponseHeaderFields:response.allHeaderFields forURL:redditURL];
        for (NSHTTPCookie *cookie in cookies) {
            if ([cookie.name isEqualToString:@"token_v2"] && cookie.value.length > 0) return cookie.value;
        }
    }
    return nil;
}

// Loading the real homepage with the stored cookies is what makes Reddit's
// edge refresh a stale token_v2 via Set-Cookie — the same trick the silent
// re-harvester relies on (ApolloWebSessionLoginViewController.m), minus the
// webview. Completion on the main queue; the fresh token stays in memory only,
// deliberately never written back into the stored session snapshot.
static void ApolloChatPollMintBearer(NSString *username, NSString *cookieHeader,
                                     void (^completion)(NSString *bearer)) {
    // Under the debug homeserver override, mint against the mock too so the
    // whole poller pipeline (including this path) is testable offline.
    NSString *mintBase = [[NSUserDefaults standardUserDefaults] stringForKey:UDKeyChatPollerHomeserverOverride];
    if (![mintBase isKindOfClass:[NSString class]] || ![mintBase hasPrefix:@"http"]) {
        mintBase = @"https://www.reddit.com";
    }
    NSMutableURLRequest *request =
        [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[mintBase stringByAppendingString:@"/"]]];
    request.timeoutInterval = kChatPollRequestTimeout;
    request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    request.HTTPShouldHandleCookies = NO;
    [request setValue:cookieHeader forHTTPHeaderField:@"Cookie"];
    [request setValue:kChatPollMintUserAgent forHTTPHeaderField:@"User-Agent"];
    // Present as a browser page load — Reddit's edge only refreshes token_v2
    // on document requests.
    [request setValue:@"text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
   forHTTPHeaderField:@"Accept"];
    [request setValue:@"en-US,en;q=0.9" forHTTPHeaderField:@"Accept-Language"];

    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    // No cookie STORE (nothing persists, nothing auto-attaches), but leave
    // HTTPShouldSetCookies at YES: setting it to NO makes CFNetwork strip
    // even a manually-set Cookie header from the request (observed live —
    // Reddit answered as if logged out and never refreshed token_v2).
    config.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyNever;
    config.HTTPCookieStorage = nil;
    ApolloChatPollMintDelegate *delegate = [ApolloChatPollMintDelegate new];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config delegate:delegate delegateQueue:nil];

    NSURLSessionDataTask *task = [session dataTaskWithRequest:request
                                            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSMutableArray<NSHTTPURLResponse *> *responses;
        @synchronized (delegate.responses) { responses = [delegate.responses mutableCopy]; }
        if ([response isKindOfClass:[NSHTTPURLResponse class]]) [responses addObject:(NSHTTPURLResponse *)response];
        NSString *token = error ? nil : ApolloChatPollTokenFromResponses(responses);
        // Diagnostic trail for mint failures: per-hop status + which cookie
        // NAMES each hop tried to set (never values).
        NSMutableArray<NSString *> *hops = [NSMutableArray array];
        NSURL *redditURL = [NSURL URLWithString:@"https://www.reddit.com/"];
        for (NSHTTPURLResponse *hop in responses) {
            NSArray<NSHTTPCookie *> *cookies =
                [NSHTTPCookie cookiesWithResponseHeaderFields:hop.allHeaderFields forURL:redditURL];
            [hops addObject:[NSString stringWithFormat:@"%ld:%@", (long)hop.statusCode,
                             [[cookies valueForKey:@"name"] componentsJoinedByString:@","] ?: @""]];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (token.length > 0) {
                ApolloLog(@"[ChatPoller] Minted a fresh token_v2 for u/%@ (expires in %.0f min)",
                          username, (ApolloChatPollJWTExpiry(token) - [NSDate date].timeIntervalSince1970) / 60.0);
            } else {
                ApolloLog(@"[ChatPoller] token_v2 mint failed for u/%@ (%@; hops=%@) — backing off %.0f min",
                          username, error.localizedDescription ?: @"no token in response",
                          [hops componentsJoinedByString:@" -> "],
                          kChatPollMintBackoff / 60.0);
            }
            completion(token);
        });
        [session finishTasksAndInvalidate];
    }];
    [task resume];
}

// Resolve a usable bearer for `username`: cached, straight from the stored
// cookie when its token_v2 is still fresh, else minted. Main queue in and out.
static void ApolloChatPollObtainBearer(NSString *username, NSString *cookieHeader,
                                       void (^completion)(NSString *bearer)) {
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (sChatPollBearer.length > 0 && sChatPollBearerExpiry - now > kChatPollBearerSlack) {
        completion(sChatPollBearer);
        return;
    }
    NSString *stored = ApolloChatPollCookieValue(cookieHeader, @"token_v2");
    if (stored.length > 0) {
        NSTimeInterval expiry = ApolloChatPollJWTExpiry(stored);
        if (expiry - now > kChatPollBearerSlack) {
            sChatPollBearer = stored;
            sChatPollBearerExpiry = expiry;
            completion(stored);
            return;
        }
    }
    if (now < sChatPollMintBlockedUntil) {
        completion(nil);
        return;
    }
    ApolloChatPollMintBearer(username, cookieHeader, ^(NSString *bearer) {
        if (bearer.length > 0) {
            sChatPollBearer = bearer;
            sChatPollBearerExpiry = ApolloChatPollJWTExpiry(bearer);
        } else {
            sChatPollMintBlockedUntil = [NSDate date].timeIntervalSince1970 + kChatPollMintBackoff;
        }
        completion(bearer.length > 0 ? bearer : nil);
    });
}

#pragma mark - Sync response parsing

static NSInteger ApolloChatPollCounter(NSDictionary *payload, NSString *key) {
    id value = payload[key];
    return [value respondsToSelector:@selector(integerValue)] ? MAX(0, [value integerValue]) : -1;
}

// Extract {unreadCount, requestsCount, preview?, unreadRoomId?} from a Matrix
// sync payload. Prefers Reddit's pre-computed counters; falls back to summing
// per-room notification counts when a counter is absent.
static NSDictionary *ApolloChatPollStatusFromSyncPayload(NSDictionary *payload) {
    NSDictionary *rooms = [payload[@"rooms"] isKindOfClass:[NSDictionary class]] ? payload[@"rooms"] : @{};
    NSDictionary *joined = [rooms[@"join"] isKindOfClass:[NSDictionary class]] ? rooms[@"join"] : @{};
    NSDictionary *invited = [rooms[@"invite"] isKindOfClass:[NSDictionary class]] ? rooms[@"invite"] : @{};

    NSInteger unread = ApolloChatPollCounter(payload, @"com.reddit.global_navigation_counter");
    NSInteger requests = ApolloChatPollCounter(payload, @"com.reddit.invites_counter");
    if (requests < 0) requests = (NSInteger)invited.count;

    NSInteger summedUnread = 0;
    NSInteger unreadRoomCount = 0;
    NSString *unreadRoomId = nil;
    NSString *preview = nil;
    NSTimeInterval previewTimestamp = 0;
    for (NSString *roomId in joined) {
        NSDictionary *room = [joined[roomId] isKindOfClass:[NSDictionary class]] ? joined[roomId] : @{};
        NSDictionary *notifications = [room[@"unread_notifications"] isKindOfClass:[NSDictionary class]]
            ? room[@"unread_notifications"] : @{};
        NSInteger count = [notifications[@"notification_count"] respondsToSelector:@selector(integerValue)]
            ? [notifications[@"notification_count"] integerValue] : 0;
        // Reddit marks rooms excluded from its own navigation badge (e.g.
        // muted) — honor that in the fallback sum.
        id counted = notifications[@"com.reddit.is_counted_in_global_navigation_counter"];
        BOOL countsTowardBadge = counted == nil || [counted boolValue];
        if (count <= 0) continue;
        if (countsTowardBadge) summedUnread += count;
        unreadRoomCount++;
        unreadRoomId = unreadRoomCount == 1 ? roomId : nil;

        NSArray *events = [room[@"timeline"] isKindOfClass:[NSDictionary class]]
            ? ([room[@"timeline"][@"events"] isKindOfClass:[NSArray class]] ? room[@"timeline"][@"events"] : @[])
            : @[];
        for (NSDictionary *event in events.reverseObjectEnumerator) {
            if (![event isKindOfClass:[NSDictionary class]]) continue;
            if (![event[@"type"] isEqual:@"m.room.message"]) continue;
            NSString *body = [event[@"content"] isKindOfClass:[NSDictionary class]]
                ? event[@"content"][@"body"] : nil;
            if (![body isKindOfClass:[NSString class]] || body.length == 0) break;
            NSTimeInterval timestamp = [event[@"origin_server_ts"] respondsToSelector:@selector(doubleValue)]
                ? [event[@"origin_server_ts"] doubleValue] : 0;
            if (timestamp >= previewTimestamp) {
                previewTimestamp = timestamp;
                NSString *singleLine = [[body componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]
                                        componentsJoinedByString:@" "];
                preview = singleLine.length > 140 ? [[singleLine substringToIndex:139] stringByAppendingString:@"…"] : singleLine;
            }
            break;
        }
    }
    if (unread < 0) unread = summedUnread;

    NSMutableDictionary *status = [NSMutableDictionary dictionary];
    status[@"unreadCount"] = @(unread);
    status[@"requestsCount"] = @(requests);
    if (preview.length > 0) status[@"preview"] = preview;
    if (unreadRoomId.length > 0) status[@"unreadRoomId"] = unreadRoomId;
    return status;
}

#pragma mark - Bark transition pushes

// Per-account high-water marks of counts already notified about, persisted so
// a relaunch does not re-announce the same unread messages.
static NSDictionary *ApolloChatPollWatermarks(NSString *username) {
    NSDictionary *all = [[NSUserDefaults standardUserDefaults] dictionaryForKey:UDKeyChatUnreadNotifiedWatermarks];
    NSDictionary *entry = all[username.lowercaseString];
    return [entry isKindOfClass:[NSDictionary class]] ? entry : @{};
}

static void ApolloChatPollSaveWatermarks(NSString *username, NSInteger unread, NSInteger requests) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *all = [[defaults dictionaryForKey:UDKeyChatUnreadNotifiedWatermarks] mutableCopy]
        ?: [NSMutableDictionary dictionary];
    all[username.lowercaseString] = @{ @"unread": @(unread), @"requests": @(requests) };
    [defaults setObject:all forKey:UDKeyChatUnreadNotifiedWatermarks];
}

// Bark can be reached directly from the client (a plain POST to the push
// URL), so chat pushes work without any backend involvement. APNs-transport
// users get no chat pushes: the self-hosted backend polls Reddit's OAuth API
// server-side and modern Chat does not exist there.
static void ApolloChatPollNotifyTransitions(NSString *username, NSDictionary *status) {
    NSInteger unread = [status[@"unreadCount"] integerValue];
    NSInteger requests = [status[@"requestsCount"] integerValue];
    NSDictionary *marks = ApolloChatPollWatermarks(username);
    NSInteger unreadMark = [marks[@"unread"] integerValue];
    NSInteger requestsMark = [marks[@"requests"] integerValue];

    if (unread == unreadMark && requests == requestsMark) return;

    if (ApolloBarkConfigured()) {
        if (unread > unreadMark) {
            NSString *title = unread == 1 ? @"New Chat Message"
                : [NSString stringWithFormat:@"%ld Unread Chat Messages", (long)unread];
            NSString *preview = [status[@"preview"] isKindOfClass:[NSString class]] ? status[@"preview"] : nil;
            NSString *roomId = [status[@"unreadRoomId"] isKindOfClass:[NSString class]] ? status[@"unreadRoomId"] : nil;
            // Invalid room paths safely fall back to the Chat entry screen
            // inside ApolloCreateModernChatViewControllerForPath.
            NSString *link = @"apollo://reborn/chat";
            if (roomId.length > 0) {
                NSString *escaped = [roomId stringByAddingPercentEncodingWithAllowedCharacters:
                                     NSCharacterSet.URLPathAllowedCharacterSet];
                if (escaped.length > 0) link = [NSString stringWithFormat:@"apollo://reborn/chat/room/%@", escaped];
            }
            ApolloBarkSendChatNotification(title, preview ?: @"Open Chat to read it.", link);
        }
        if (requests > requestsMark) {
            NSString *title = requests == 1 ? @"New Chat Request"
                : [NSString stringWithFormat:@"%ld New Chat Requests", (long)requests];
            ApolloBarkSendChatNotification(title, @"Someone wants to start a chat with you.",
                                           @"apollo://reborn/chat/requests");
        }
    }
    // Track decreases too, so reading everything re-arms the next push.
    ApolloChatPollSaveWatermarks(username, unread, requests);
}

#pragma mark - The poll itself

static void ApolloChatPollFinish(void) {
    sChatPollInFlight = NO;
    if (sChatPollPendingKick) {
        sChatPollPendingKick = NO;
        ApolloChatUnreadPollerKick();
    }
}

static void ApolloChatPollRunSync(NSString *username, NSString *bearer, BOOL isRetryAfterAuthFailure) {
    NSString *base = ApolloChatPollHomeserverBase();
    NSURLComponents *components = [NSURLComponents componentsWithString:
                                   [base stringByAppendingString:@"/_matrix/client/v3/sync"]];
    NSMutableArray<NSURLQueryItem *> *query = [NSMutableArray arrayWithArray:@[
        [NSURLQueryItem queryItemWithName:@"timeout" value:@"0"],
        [NSURLQueryItem queryItemWithName:@"set_presence" value:@"offline"],
        [NSURLQueryItem queryItemWithName:@"filter" value:kChatPollSyncFilter],
    ]];
    BOOL usedSinceToken = sChatPollSinceToken.length > 0 && [sChatPollSinceBase isEqualToString:base];
    if (usedSinceToken) {
        [query addObject:[NSURLQueryItem queryItemWithName:@"since" value:sChatPollSinceToken]];
    }
    components.queryItems = query;

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:components.URL];
    request.timeoutInterval = kChatPollRequestTimeout;
    request.HTTPShouldHandleCookies = NO;
    [request setValue:[@"Bearer " stringByAppendingString:bearer] forHTTPHeaderField:@"Authorization"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];

    static NSURLSession *session;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        config.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyNever;
        config.HTTPCookieStorage = nil;
        session = [NSURLSession sessionWithConfiguration:config];
    });

    [[session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger statusCode = [response isKindOfClass:[NSHTTPURLResponse class]]
            ? [(NSHTTPURLResponse *)response statusCode] : 0;
        NSDictionary *payload = nil;
        if (!error && statusCode == 200 && data.length > 0) {
            id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([parsed isKindOfClass:[NSDictionary class]]) payload = parsed;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![username isEqualToString:sChatPollUsername]) { ApolloChatPollFinish(); return; }

            // A since token can go stale (server-side retention, token_v2
            // rotation) — the server answers 400 M_UNKNOWN_TOKEN. Recover by
            // dropping it and re-running one full initial sync.
            if (statusCode == 400 && usedSinceToken) {
                ApolloLog(@"[ChatPoller] since token rejected for u/%@ — falling back to a full sync", username);
                sChatPollSinceToken = nil;
                sChatPollSinceBase = nil;
                ApolloChatPollRunSync(username, bearer, isRetryAfterAuthFailure);
                return;
            }

            if (statusCode == 401 || statusCode == 403) {
                sChatPollBearer = nil;
                sChatPollBearerExpiry = 0;
                if (isRetryAfterAuthFailure) {
                    // A freshly-minted bearer was rejected: the stored web
                    // session itself is dead. Try the login module's silent
                    // re-harvest (it has its own cooldown + coalescing); on
                    // success the next kick picks up the refreshed cookies.
                    sChatPollAuthBlockedUntil = [NSDate date].timeIntervalSince1970 + kChatPollAuthBackoff;
                    ApolloLog(@"[ChatPoller] Fresh bearer rejected (HTTP %ld) for u/%@ — pausing polls %.0f min, attempting silent re-harvest",
                              (long)statusCode, username, kChatPollAuthBackoff / 60.0);
                    [ApolloWebSessionLoginViewController attemptSilentReharvestForUsername:username
                                                                                completion:^(BOOL success) {
                        if (!success) return;
                        sChatPollAuthBlockedUntil = 0;
                        ApolloChatUnreadPollerKick();
                    }];
                    ApolloChatPollFinish();
                    return;
                }
                ApolloLog(@"[ChatPoller] Bearer rejected (HTTP %ld) for u/%@ — minting a fresh one",
                          (long)statusCode, username);
                ApolloWebSessionEntry *entry = ApolloWebSessionPollFor(username);
                if (entry.cookieHeader.length == 0) { ApolloChatPollFinish(); return; }
                // Skip the stored-cookie shortcut: it just produced this 401.
                if (sChatPollMintBlockedUntil > [NSDate date].timeIntervalSince1970) { ApolloChatPollFinish(); return; }
                ApolloChatPollMintBearer(username, entry.cookieHeader, ^(NSString *fresh) {
                    if (fresh.length == 0) {
                        sChatPollMintBlockedUntil = [NSDate date].timeIntervalSince1970 + kChatPollMintBackoff;
                        ApolloChatPollFinish();
                        return;
                    }
                    sChatPollBearer = fresh;
                    sChatPollBearerExpiry = ApolloChatPollJWTExpiry(fresh);
                    ApolloChatPollRunSync(username, fresh, YES);
                });
                return;
            }
            if (error || statusCode != 200 || !payload) {
                if (statusCode == 429 || statusCode >= 500) {
                    sChatPollServerBlockedUntil = [NSDate date].timeIntervalSince1970 + kChatPollServerBackoff;
                }
                ApolloLog(@"[ChatPoller] Sync failed for u/%@ (HTTP %ld, %@)",
                          username, (long)statusCode, error.localizedDescription ?: @"unparseable body");
                ApolloChatPollFinish();
                return;
            }

            NSString *nextBatch = [payload[@"next_batch"] isKindOfClass:[NSString class]] ? payload[@"next_batch"] : nil;
            if (nextBatch.length > 0) {
                sChatPollSinceToken = nextBatch;
                sChatPollSinceBase = base;
            }

            NSMutableDictionary *status = [ApolloChatPollStatusFromSyncPayload(payload) mutableCopy];
            status[@"username"] = username;
            status[@"checkedAt"] = @([NSDate date].timeIntervalSince1970 * 1000.0);
            ApolloLog(@"[ChatPoller] u/%@ unread=%@ requests=%@%@", username,
                      status[@"unreadCount"], status[@"requestsCount"],
                      sChatPollSinceToken.length > 0 ? @"" : @" (initial sync)");
            ApolloModernChatPublishPolledStatus(status);
            ApolloChatPollNotifyTransitions(username, status);
            ApolloChatPollFinish();
        });
    }] resume];
}

static void ApolloChatPollTick(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ ApolloChatPollTick(); });
        return;
    }
    if (sChatPollInFlight) { sChatPollPendingKick = YES; return; }
    if (UIApplication.sharedApplication.applicationState == UIApplicationStateBackground) return;

    // Feature gates: modern Chat surface in use AND a stored web session for
    // the active account. With the toggle off this never fires, keeping the
    // API-key path's stock Direct Chat / Modmail behavior byte-identical.
    // Log the gate verdict, but only when it changes — not every 30 s.
    BOOL shouldOpen = ApolloModernChatShouldOpen();
    BOOL available = ApolloModernChatIsAvailable();
    NSString *username = ApolloActiveWebSessionUsername();
    ApolloWebSessionEntry *entry = ApolloWebSessionPollFor(username);
    NSString *gateState = [NSString stringWithFormat:@"open=%d avail=%d user=%@ cookie=%d",
                           shouldOpen, available, username ?: @"-", entry.cookieHeader.length > 0];
    static NSString *sLastGateState = nil;
    if (![gateState isEqualToString:sLastGateState]) {
        sLastGateState = [gateState copy];
        ApolloLog(@"[ChatPoller] Gates: %@", gateState);
    }
    if (!shouldOpen || !available) return;
    if (username.length == 0 || entry.cookieHeader.length == 0) return;

    if (![username isEqualToString:sChatPollUsername]) {
        sChatPollUsername = [username copy];
        ApolloChatPollResetPerAccountState();
    }

    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (now < sChatPollAuthBlockedUntil || now < sChatPollServerBlockedUntil) return;

    sChatPollInFlight = YES;
    ApolloChatPollObtainBearer(username, entry.cookieHeader, ^(NSString *bearer) {
        if (bearer.length == 0 || ![username isEqualToString:sChatPollUsername]) {
            ApolloChatPollFinish();
            return;
        }
        ApolloChatPollRunSync(username, bearer, NO);
    });
}

#pragma mark - Lifecycle

static NSTimeInterval ApolloChatPollInterval(void) {
    // Hidden debug override for faster simulator iteration.
    double override = [[NSUserDefaults standardUserDefaults] doubleForKey:UDKeyChatPollerIntervalOverride];
    return override >= 5.0 ? override : kChatPollDefaultInterval;
}

static void ApolloChatPollStartTimer(void) {
    if (sChatPollTimer) return;
    sChatPollTimer = [NSTimer timerWithTimeInterval:ApolloChatPollInterval() repeats:YES
                                              block:^(__unused NSTimer *timer) { ApolloChatPollTick(); }];
    [[NSRunLoop mainRunLoop] addTimer:sChatPollTimer forMode:NSRunLoopCommonModes];
    ApolloLog(@"[ChatPoller] Started (%.0fs cadence)", ApolloChatPollInterval());
}

static void ApolloChatPollStopTimer(void) {
    [sChatPollTimer invalidate];
    sChatPollTimer = nil;
}

void ApolloChatUnreadPollerKick(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ ApolloChatPollTick(); });
}

__attribute__((constructor))
static void ApolloChatUnreadPollerInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue
                        usingBlock:^(__unused NSNotification *note) {
            ApolloChatPollStartTimer();
            // Small delay so account/session stores settle after activation.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ ApolloChatPollTick(); });
        }];
        [center addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:NSOperationQueue.mainQueue
                        usingBlock:^(__unused NSNotification *note) {
            ApolloChatPollStopTimer();
        }];
        // The activation notification normally fires after this block runs,
        // but don't depend on that ordering — if the app is already active,
        // start now.
        if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
            ApolloChatPollStartTimer();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ ApolloChatPollTick(); });
        }
    });
}
