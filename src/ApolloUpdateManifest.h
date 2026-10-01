// Parsing half of the in-app update check: release-manifest.json -> the
// installed build's variant. Foundation-only so tests/run_update_manifest_tests.sh
// can compile it on the host; the fetch + UI live in ApolloUpdateChecker.{h,m}.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// The newest published release, resolved for the installed build variant.
@interface ApolloUpdateInfo : NSObject
@property (nonatomic, copy) NSString *version;                    // "3.9.0"
@property (nonatomic, copy, nullable) NSString *releaseName;      // GitHub release title
@property (nonatomic, strong, nullable) NSURL *releaseURL;        // release notes page
// nil when the installed build isn't a known release variant.
@property (nonatomic, strong, nullable) NSURL *sourceURL;         // that variant's AltStore-style source
@property (nonatomic, strong, nullable) NSURL *downloadURL;       // that variant's IPA
@end

typedef NS_ENUM(NSInteger, ApolloUpdateSideloader) {
    ApolloUpdateSideloaderAltStore,
    ApolloUpdateSideloaderSideStore,
    ApolloUpdateSideloaderFeather,
    ApolloUpdateSideloaderFlareStore,
};

#ifdef __cplusplus
extern "C" {
#endif

// release-manifest.json variant key for a stamped ARBuildVariant ("ipa" ->
// "standard", "glass-noext" -> "noExtensionsGlass", ...). nil for .deb, dev and
// unrecognized builds, which have no sideloaded IPA to update.
NSString *_Nullable ApolloUpdateManifestKeyForBuildVariant(NSString *_Nullable buildVariant);

// Numeric dotted compare of tweak versions. Tolerates a leading "v" and a dpkg
// "-<digits>" revision; a non-numeric component reads as 0 (no pre-release
// ordering — releases here are plain x.y.z).
NSComparisonResult ApolloUpdateCompareVersions(NSString *a, NSString *b);

// nil when `manifest` isn't a usable release-manifest.json. `variantKey` may be
// nil, in which case sourceURL/downloadURL stay unset. Non-https URLs are dropped.
ApolloUpdateInfo *_Nullable ApolloUpdateInfoFromManifest(id _Nullable manifest,
                                                         NSString *_Nullable variantKey);

// The URL that asks `sideloader` to add the given AltStore-style source.
NSURL *_Nullable ApolloUpdateSideloaderSourceURL(ApolloUpdateSideloader sideloader, NSURL *sourceURL);

// The URL that makes `sideloader` take `ipaURL` straight away, whether or not the source is
// added (Feather's feather://install/ downloads it; FlareStore's downloadApp= pre-fills its
// import field). nil for sideloaders without one; callers fall back to the source link.
// `nonce` (FlareStore only, may be nil) becomes the link's fragment so repeated hand-offs differ:
// FlareStore ignores a link identical to the last one it received.
NSURL *_Nullable ApolloUpdateSideloaderInstallURL(ApolloUpdateSideloader sideloader, NSURL *ipaURL,
                                                  NSString *_Nullable nonce);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
