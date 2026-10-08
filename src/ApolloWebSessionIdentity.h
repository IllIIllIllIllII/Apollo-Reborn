#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ApolloWebSessionIdentityVerdict) {
    ApolloWebSessionIdentityInconclusive,
    ApolloWebSessionIdentityMatches,
    // A confirmed anonymous response, HTTP 401 JSON, or another account.
    ApolloWebSessionIdentityUnavailable
};

typedef NS_ENUM(NSInteger, ApolloWebSessionRecoveryResult) {
    ApolloWebSessionRecoveryInconclusive,
    ApolloWebSessionRecoveryRecovered,
    // The browser positively identified an anonymous session or another user.
    ApolloWebSessionRecoveryRequiresSignIn
};

// Shared by the native and WebKit /api/me.json probes. A challenge, malformed
// response, rate limit, server failure, or network error is never logout proof.
FOUNDATION_EXPORT ApolloWebSessionIdentityVerdict ApolloWebSessionClassifyIdentity(NSString *username,
    NSInteger statusCode, NSString * _Nullable contentType, id _Nullable json, NSError * _Nullable error);

// WebKit returns response metadata with its parsed JSON. Missing/invalid
// metadata (including failed JavaScript or fetch) stays inconclusive.
FOUNDATION_EXPORT ApolloWebSessionIdentityVerdict ApolloWebSessionClassifyBrowserIdentity(NSString *username,
    id _Nullable result, NSError * _Nullable error);

NS_ASSUME_NONNULL_END
