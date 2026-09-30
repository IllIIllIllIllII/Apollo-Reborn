// In-app update check. A sideloaded app can't replace itself (iOS only runs code
// signed by the user's own certificate, which lives in their sideloader), so this
// finds the newest release in release-manifest.json and hands the user off to
// AltStore / SideStore / Feather (or the IPA download) for the actual update.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

__BEGIN_DECLS

// Call on every foreground. Once a day at most (and only if automatic checks are
// on and this is a sideloaded release variant) fetches the manifest; if a newer,
// not-skipped version exists it prompts once per launch, only over the base app UI.
void ApolloUpdateCheckIfNeeded(void);

// Manual "Check for Updates": always fetches and always reports the outcome.
// `statusChanged` fires on the main queue when the check starts and finishes so
// a row can re-read ApolloUpdateStatusText().
void ApolloUpdateCheckNow(void (^_Nullable statusChanged)(void));

// Row detail text: "Checking…", "v3.9.0 available", "Up to date", or nil before any check.
NSString *_Nullable ApolloUpdateStatusText(void);

// NO for jailbroken .deb installs, which update through their package manager.
BOOL ApolloUpdateChecksAvailable(void);

__END_DECLS

NS_ASSUME_NONNULL_END
