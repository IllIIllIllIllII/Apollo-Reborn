#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

// Modern Reddit award data, translated to the shape Apollo's RDKAward expects.
// Read-only web requests use an eligible current feature session when present;
// otherwise they can run anonymously. No OAuth API key is required.
// A nil result means unavailable/failed; an empty array means confirmed no awards.
// Completion always runs on main. Requests coalesce and successful data is cached.
void ApolloAwardsFetch(NSString *fullName,
                      void (^completion)(NSArray<NSDictionary *> * _Nullable awards));

void ApolloAwardsPrefetch(NSString *fullName,
                         void (^completion)(NSArray<NSDictionary *> * _Nullable awards));
void ApolloAwardsSetQueuedPriority(NSString *fullName, BOOL visible);
extern NSString *const ApolloAwardsCacheDidLoadNotification;

// Nonblocking, thread-safe lookup used while Apollo constructs display nodes.
// Positive stale data remains usable while a refresh runs; fetches still revalidate.
NSArray<NSDictionary *> * _Nullable ApolloAwardsCached(NSString *fullName);

// Cancel work that has not started when the last visible cell leaves the screen.
void ApolloAwardsCancelQueued(NSString *fullName);

// A single modern feed/thread page can confirm many zero-award rows. This
// opportunistic warmup avoids a dialog + leaderboard request for each one.
void ApolloAwardsObserveListingResponse(NSHTTPURLResponse *response, id object);
// Revalidate this one target after Reddit's giving sheet closes, preserving
// positive stale display data while the request is in flight.
void ApolloAwardsRefresh(NSString *fullName);

#if APOLLO_SIM_BUILD
void ApolloAwardsDebugSeed(NSString *fullName, NSArray<NSDictionary *> * _Nullable awards);
NSString *ApolloAwardsDebugSnapshot(void);
#endif

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
