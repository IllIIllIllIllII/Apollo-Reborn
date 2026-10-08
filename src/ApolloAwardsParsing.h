#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

NSString * _Nullable ApolloAwardsNormalizeFullName(NSString * _Nullable value);

// Accept only Reddit's signed leaderboard partial for this exact post/comment.
// The caller must enforce the same host/path restriction on HTTP redirects.
NSURL * _Nullable ApolloAwardsLeaderboardURL(NSString *dialogHTML, NSString *fullName);

// Translate individual award rows to Apollo's legacy JSON shape. nil means a
// failed/unknown response; [] requires Reddit's explicit empty-leaderboard state.
NSArray<NSDictionary *> * _Nullable ApolloAwardsParseLeaderboard(NSString *HTML,
                                                                 NSString *fullName);

typedef NS_ENUM(NSUInteger, ApolloAwardsUnparsedHTMLKind) {
    ApolloAwardsUnparsedHTMLUnknown,
    ApolloAwardsUnparsedHTMLChallenge,
    ApolloAwardsUnparsedHTMLMatchingLeaderboard,
};

// Classify a failed parse for transport policy/diagnostics. A complete matching
// component may have unsupported markup; this never proves zero awards.
ApolloAwardsUnparsedHTMLKind ApolloAwardsClassifyUnparsedHTML(NSString *HTML,
                                                            NSString *fullName);

// Aggregate counts only, for warming known-zero rows from a feed/thread page.
// Positive counts never stand in for the individual leaderboard award types.
// nil means no complete usable component document; uncertain/conflicting rows
// are omitted. An omitted comment count proves zero only with its own empty,
// exactly matching award-button. Posts require an explicit numeric count.
NSDictionary<NSString *, NSNumber *> * _Nullable ApolloAwardsParsePageCounts(NSString *HTML);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
