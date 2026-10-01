#import "ApolloUpdateManifest.h"

@implementation ApolloUpdateInfo
@end

NSString *ApolloUpdateManifestKeyForBuildVariant(NSString *buildVariant) {
    // ARBuildVariant values stamped by scripts/build_release_variants.sh.
    static NSDictionary<NSString *, NSString *> *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            @"ipa":              @"standard",
            @"ipa-noext":        @"noExtensions",
            @"glass":            @"glass",
            @"glass-noext":      @"noExtensionsGlass",
            @"glassicons":       @"glassIcons",
            @"glassicons-noext": @"noExtensionsGlassIcons",
        };
    });
    return buildVariant.length ? map[buildVariant] : nil;
}

// Numeric prefix of each dot-separated component: "3.8.5" -> [3, 8, 5].
static NSArray<NSNumber *> *ApolloUpdateVersionComponents(NSString *version) {
    NSString *v = [version stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([v hasPrefix:@"v"]) v = [v substringFromIndex:1];
    NSRange dash = [v rangeOfString:@"-" options:NSBackwardsSearch];
    if (dash.location != NSNotFound) {
        NSString *revision = [v substringFromIndex:dash.location + 1];
        NSCharacterSet *nonDigits = [NSCharacterSet characterSetWithCharactersInString:@"0123456789"].invertedSet;
        if (revision.length > 0 && [revision rangeOfCharacterFromSet:nonDigits].location == NSNotFound) {
            v = [v substringToIndex:dash.location];
        }
    }
    NSMutableArray<NSNumber *> *components = [NSMutableArray array];
    for (NSString *part in [v componentsSeparatedByString:@"."]) {
        [components addObject:@(part.integerValue)];  // stops at the first non-digit, 0 if none
    }
    return components;
}

NSComparisonResult ApolloUpdateCompareVersions(NSString *a, NSString *b) {
    NSArray<NSNumber *> *ca = ApolloUpdateVersionComponents(a);
    NSArray<NSNumber *> *cb = ApolloUpdateVersionComponents(b);
    NSUInteger count = MAX(ca.count, cb.count);
    for (NSUInteger i = 0; i < count; i++) {
        NSInteger x = i < ca.count ? ca[i].integerValue : 0;
        NSInteger y = i < cb.count ? cb[i].integerValue : 0;
        if (x < y) return NSOrderedAscending;
        if (x > y) return NSOrderedDescending;
    }
    return NSOrderedSame;
}

static NSString *ApolloUpdateString(id value) {
    return [value isKindOfClass:NSString.class] && [(NSString *)value length] > 0 ? value : nil;
}

// https only: these URLs get handed to other apps and Safari.
static NSURL *ApolloUpdateHTTPSURL(id value) {
    NSString *string = ApolloUpdateString(value);
    NSURL *url = string ? [NSURL URLWithString:string] : nil;
    return [url.scheme.lowercaseString isEqualToString:@"https"] && url.host.length ? url : nil;
}

ApolloUpdateInfo *ApolloUpdateInfoFromManifest(id manifest, NSString *variantKey) {
    if (![manifest isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *release = [manifest[@"release"] isKindOfClass:NSDictionary.class] ? manifest[@"release"] : nil;
    NSString *version = ApolloUpdateString(release[@"tweakVersion"]);
    if (!version || [version rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet].location == NSNotFound) {
        return nil;
    }

    ApolloUpdateInfo *info = [ApolloUpdateInfo new];
    info.version = version;
    info.releaseName = ApolloUpdateString(release[@"name"]);
    info.releaseURL = ApolloUpdateHTTPSURL(release[@"url"]);

    NSDictionary *variants = [manifest[@"variants"] isKindOfClass:NSDictionary.class] ? manifest[@"variants"] : nil;
    NSDictionary *variant = variantKey && [variants[variantKey] isKindOfClass:NSDictionary.class] ? variants[variantKey] : nil;
    info.sourceURL = ApolloUpdateHTTPSURL(variant[@"sourceURL"]);
    info.downloadURL = ApolloUpdateHTTPSURL(variant[@"directDownloadURL"]);
    return info;
}

NSURL *ApolloUpdateSideloaderSourceURL(ApolloUpdateSideloader sideloader, NSURL *sourceURL) {
    if (sideloader == ApolloUpdateSideloaderFlareStore) {
        // FlareStore's documented add-repo path (Settings > URL Schemes): flarestore://addRepo=<url>
        return [NSURL URLWithString:[@"flarestore://addRepo=" stringByAppendingString:sourceURL.absoluteString]];
    }
    if (sideloader == ApolloUpdateSideloaderFeather) {
        // Feather takes the source URL as the path: feather://source/https://...
        return [NSURL URLWithString:[@"feather://source/" stringByAppendingString:sourceURL.absoluteString]];
    }
    // AltStore Classic and SideStore share the source?url= shape (DISTRIBUTION.md).
    NSURLComponents *components = [NSURLComponents new];
    components.scheme = sideloader == ApolloUpdateSideloaderAltStore ? @"altstore-classic" : @"sidestore";
    components.host = @"source";
    components.queryItems = @[[NSURLQueryItem queryItemWithName:@"url" value:sourceURL.absoluteString]];
    return components.URL;
}

NSURL *ApolloUpdateSideloaderInstallURL(ApolloUpdateSideloader sideloader, NSURL *ipaURL, NSString *nonce) {
    switch (sideloader) {
        case ApolloUpdateSideloaderFeather:
            // Feather downloads the IPA into its Library (no progress UI for URL downloads).
            return [NSURL URLWithString:[@"feather://install/" stringByAppendingString:ipaURL.absoluteString]];
        case ApolloUpdateSideloaderFlareStore: {
            // FlareStore's documented downloadApp path (Settings > URL Schemes): it pre-fills its
            // import field with the IPA, then shows a download bar once the arrow is tapped. Used
            // over viewApp, which matches the bundle id across every added repo (it opened a
            // third-party mirror's copy, not ours). Verified on device: FlareStore ignores a link
            // identical to the last one it received (even one dropped by a cold launch), so each
            // hand-off carries a unique fragment; URLSession never sends it, and the field and
            // download still work with it.
            NSString *link = ipaURL.absoluteString;
            if (nonce.length > 0) {
                NSURLComponents *components = [NSURLComponents componentsWithURL:ipaURL resolvingAgainstBaseURL:NO];
                components.fragment = nonce;
                link = components.URL.absoluteString ?: link;
            }
            return [NSURL URLWithString:[@"flarestore://downloadApp=" stringByAppendingString:link]];
        }
        default:
            return nil;
    }
}
