#import <Foundation/Foundation.h>
#import "ApolloUpdateManifest.h"

static int sFailures = 0;

#define CHECK(cond, ...) do { \
    if (!(cond)) { sFailures++; fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, [NSString stringWithFormat:__VA_ARGS__].UTF8String); } \
} while (0)

static NSDictionary *SampleManifest(void) {
    return @{
        @"release": @{
            @"tag": @"v1.15.11_3.9.0",
            @"name": @"v3.9.0 - Headline",
            @"url": @"https://github.com/Apollo-Reborn/Apollo-Reborn/releases/tag/v1.15.11_3.9.0",
            @"tweakVersion": @"3.9.0",
        },
        @"variants": @{
            @"standard": @{
                @"sourceURL": @"https://raw.githubusercontent.com/Apollo-Reborn/Apollo-Reborn/main/apps.json",
                @"directDownloadURL": @"https://github.com/Apollo-Reborn/Apollo-Reborn/releases/download/v1.15.11_3.9.0/Apollo-Reborn-3.9.0.ipa",
                @"size": @96696713,
            },
            @"glass": @{
                @"sourceURL": @"http://insecure.example/apps_glass.json",
                @"directDownloadURL": @"javascript:alert(1)",
            },
        },
    };
}

static void TestVersionCompare(void) {
    CHECK(ApolloUpdateCompareVersions(@"3.8.5", @"3.9.0") == NSOrderedAscending, @"3.8.5 < 3.9.0");
    CHECK(ApolloUpdateCompareVersions(@"3.10.0", @"3.9.0") == NSOrderedDescending, @"3.10.0 > 3.9.0 (numeric, not lexical)");
    CHECK(ApolloUpdateCompareVersions(@"v3.9.0", @"3.9.0") == NSOrderedSame, @"leading v ignored");
    CHECK(ApolloUpdateCompareVersions(@"3.9", @"3.9.0") == NSOrderedSame, @"missing component is 0");
    CHECK(ApolloUpdateCompareVersions(@"3.9.0-4", @"3.9.0") == NSOrderedSame, @"dpkg revision ignored");
    CHECK(ApolloUpdateCompareVersions(@"3.9.1", @"3.9.0-4") == NSOrderedDescending, @"patch beats revision");
    CHECK(ApolloUpdateCompareVersions(@"4.0.0", @"3.99.99") == NSOrderedDescending, @"major wins");
    CHECK(ApolloUpdateCompareVersions(@"3.9.0b", @"3.9.0") == NSOrderedSame, @"lettered suffix reads as 0 tail");
}

static void TestVariantKeys(void) {
    CHECK([ApolloUpdateManifestKeyForBuildVariant(@"ipa") isEqualToString:@"standard"], @"ipa");
    CHECK([ApolloUpdateManifestKeyForBuildVariant(@"ipa-noext") isEqualToString:@"noExtensions"], @"ipa-noext");
    CHECK([ApolloUpdateManifestKeyForBuildVariant(@"glass") isEqualToString:@"glass"], @"glass");
    CHECK([ApolloUpdateManifestKeyForBuildVariant(@"glass-noext") isEqualToString:@"noExtensionsGlass"], @"glass-noext");
    CHECK([ApolloUpdateManifestKeyForBuildVariant(@"glassicons") isEqualToString:@"glassIcons"], @"glassicons");
    CHECK([ApolloUpdateManifestKeyForBuildVariant(@"glassicons-noext") isEqualToString:@"noExtensionsGlassIcons"], @"glassicons-noext");
    CHECK(ApolloUpdateManifestKeyForBuildVariant(@"deb-rootless") == nil, @"deb has no IPA variant");
    CHECK(ApolloUpdateManifestKeyForBuildVariant(@"unknown") == nil, @"unknown");
    CHECK(ApolloUpdateManifestKeyForBuildVariant(nil) == nil, @"nil");
}

static void TestManifestParse(void) {
    ApolloUpdateInfo *info = ApolloUpdateInfoFromManifest(SampleManifest(), @"standard");
    CHECK(info != nil, @"parses");
    CHECK([info.version isEqualToString:@"3.9.0"], @"version %@", info.version);
    CHECK([info.releaseName isEqualToString:@"v3.9.0 - Headline"], @"name");
    CHECK([info.releaseURL.host isEqualToString:@"github.com"], @"release url");
    CHECK([info.sourceURL.lastPathComponent isEqualToString:@"apps.json"], @"source url");
    CHECK([info.downloadURL.lastPathComponent isEqualToString:@"Apollo-Reborn-3.9.0.ipa"], @"download url");

    ApolloUpdateInfo *noVariant = ApolloUpdateInfoFromManifest(SampleManifest(), nil);
    CHECK(noVariant != nil && noVariant.sourceURL == nil && noVariant.downloadURL == nil, @"nil variant leaves URLs unset");

    ApolloUpdateInfo *unknown = ApolloUpdateInfoFromManifest(SampleManifest(), @"nonexistent");
    CHECK(unknown != nil && unknown.sourceURL == nil, @"unknown variant key leaves URLs unset");

    ApolloUpdateInfo *insecure = ApolloUpdateInfoFromManifest(SampleManifest(), @"glass");
    CHECK(insecure != nil && insecure.sourceURL == nil && insecure.downloadURL == nil, @"non-https URLs dropped");

    CHECK(ApolloUpdateInfoFromManifest(nil, @"standard") == nil, @"nil manifest");
    CHECK(ApolloUpdateInfoFromManifest(@[@1], @"standard") == nil, @"array manifest");
    CHECK(ApolloUpdateInfoFromManifest(@{@"release": @{}}, @"standard") == nil, @"missing tweakVersion");
    CHECK(ApolloUpdateInfoFromManifest(@{@"release": @{@"tweakVersion": @"latest"}}, nil) == nil, @"non-numeric version");
    CHECK(ApolloUpdateInfoFromManifest(@{@"release": @{@"tweakVersion": @3}}, nil) == nil, @"wrong-typed version");
}

static void TestSideloaderURLs(void) {
    NSURL *source = [NSURL URLWithString:@"https://raw.githubusercontent.com/Apollo-Reborn/Apollo-Reborn/main/apps_noext.json"];

    NSURL *alt = ApolloUpdateSideloaderSourceURL(ApolloUpdateSideloaderAltStore, source);
    CHECK([alt.scheme isEqualToString:@"altstore-classic"] && [alt.host isEqualToString:@"source"], @"altstore %@", alt);
    CHECK([alt.absoluteString containsString:@"url=https"], @"altstore carries the source %@", alt);

    NSURL *side = ApolloUpdateSideloaderSourceURL(ApolloUpdateSideloaderSideStore, source);
    CHECK([side.scheme isEqualToString:@"sidestore"] && [side.host isEqualToString:@"source"], @"sidestore %@", side);

    NSURL *feather = ApolloUpdateSideloaderSourceURL(ApolloUpdateSideloaderFeather, source);
    CHECK([feather.absoluteString isEqualToString:
           @"feather://source/https://raw.githubusercontent.com/Apollo-Reborn/Apollo-Reborn/main/apps_noext.json"],
          @"feather %@", feather);

    NSURL *flare = ApolloUpdateSideloaderSourceURL(ApolloUpdateSideloaderFlareStore, source);
    CHECK(flare != nil && [flare.absoluteString isEqualToString:
          @"flarestore://addRepo=https://raw.githubusercontent.com/Apollo-Reborn/Apollo-Reborn/main/apps_noext.json"],
          @"flarestore %@", flare);

    // The source must round-trip out of the query intact.
    NSURLComponents *parsed = [NSURLComponents componentsWithURL:side resolvingAgainstBaseURL:NO];
    NSString *roundTrip = nil;
    for (NSURLQueryItem *item in parsed.queryItems) if ([item.name isEqualToString:@"url"]) roundTrip = item.value;
    CHECK([roundTrip isEqualToString:source.absoluteString], @"round trip %@", roundTrip);
}

static void TestInstallURLs(void) {
    NSURL *ipa = [NSURL URLWithString:@"https://github.com/Apollo-Reborn/Apollo-Reborn/releases/download/v1.15.11_3.9.0/Apollo-Reborn-3.9.0-GLASS.ipa"];
    NSURL *feather = ApolloUpdateSideloaderInstallURL(ApolloUpdateSideloaderFeather, ipa, @"ar1");
    CHECK([feather.absoluteString isEqualToString:[@"feather://install/" stringByAppendingString:ipa.absoluteString]], @"feather install %@ (no nonce)", feather);
    NSURL *flare = ApolloUpdateSideloaderInstallURL(ApolloUpdateSideloaderFlareStore, ipa, nil);
    CHECK([flare.absoluteString isEqualToString:[@"flarestore://downloadApp=" stringByAppendingString:ipa.absoluteString]], @"flarestore install %@", flare);
    NSURL *flareA = ApolloUpdateSideloaderInstallURL(ApolloUpdateSideloaderFlareStore, ipa, @"ar1");
    NSURL *flareB = ApolloUpdateSideloaderInstallURL(ApolloUpdateSideloaderFlareStore, ipa, @"ar2");
    CHECK([flareA.absoluteString isEqualToString:[@"flarestore://downloadApp=" stringByAppendingString:[ipa.absoluteString stringByAppendingString:@"#ar1"]]], @"flarestore nonce fragment %@", flareA);
    CHECK(![flareA isEqual:flareB], @"different nonces give different links");
    CHECK(ApolloUpdateSideloaderInstallURL(ApolloUpdateSideloaderAltStore, ipa, @"x") == nil, @"altstore has no documented install link");
    CHECK(ApolloUpdateSideloaderInstallURL(ApolloUpdateSideloaderSideStore, ipa, @"x") == nil, @"sidestore has no documented install link");
}

int main(void) {
    @autoreleasepool {
        TestVersionCompare();
        TestVariantKeys();
        TestManifestParse();
        TestSideloaderURLs();
        TestInstallURLs();
    }
    if (sFailures) {
        fprintf(stderr, "update_manifest_tests: %d check(s) failed\n", sFailures);
        return 1;
    }
    printf("update_manifest_tests: all checks passed\n");
    return 0;
}
