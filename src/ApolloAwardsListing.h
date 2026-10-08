#import <Foundation/Foundation.h>

// Pure helpers: mirror only ordinary feed/thread reads, and retain only the
// thing IDs in their actual JSON response. A sidebar's unrelated content must
// never become evidence that an Apollo row has no awards.
FOUNDATION_EXPORT NSURL *ApolloAwardsListingPageURL(NSURL *URL);
// Canonical redirects may add a subreddit/title slug, but must preserve the
// exact post/comment identity and query on Reddit's modern HTTPS hosts.
// The transport separately enforces its maximum of two redirects.
FOUNDATION_EXPORT BOOL ApolloAwardsListingAllowsRedirect(NSURL *source, NSURL *destination);
FOUNDATION_EXPORT NSSet<NSString *> *ApolloAwardsListingThingIDs(id object);
