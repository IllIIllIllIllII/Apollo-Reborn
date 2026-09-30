#import "ApolloUpdateChecker.h"
#import "ApolloUpdateManifest.h"
#import "ApolloUpdatePromptViewController.h"
#import "ApolloCommon.h"
#import "UIWindow+Apollo.h"
#import "UserDefaultConstants.h"
#import "Version.h"
#import <UIKit/UIKit.h>

static NSString *const kUpdateManifestURL =
    @"https://raw.githubusercontent.com/Apollo-Reborn/Apollo-Reborn/main/release-manifest.json";
static const NSTimeInterval kUpdateCheckInterval = 24 * 60 * 60;

// Main-thread state.
static ApolloUpdateInfo *sAvailableUpdate;   // newer than the installed build, else nil
static BOOL sUpToDate;                       // last fetch found nothing newer
static BOOL sChecking;
static BOOL sPromptPending;                  // an auto-prompt retry chain is running
static NSString *sPromptedVersion;           // already prompted for this version this launch

static NSString *ApolloUpdateInstalledVersion(void) {
    NSString *version = @(TWEAK_VERSION);
    return [version hasPrefix:@"v"] ? [version substringFromIndex:1] : version;
}

// Sim builds carry no ARBuildVariant stamp and the manifest matches the current
// version, so let the sim script inject both to exercise the update UI.
static NSString *ApolloUpdateRawVariant(void) {
#if APOLLO_SIM_BUILD
    const char *override = getenv("APOLLO_UPDATE_BUILD_VARIANT");
    if (override && *override) return @(override);
#endif
    return ApolloBuildVariant();
}

// A .deb's ARVariant marker ("deb-rootful"/"deb-rootless") is also baked into IPAs
// that had the .deb injected without a release stamp (local and test builds). Only a
// real jailbreak install resolves that marker from outside the app bundle; those users
// update through their package manager, so the feature stays off for them.
static BOOL ApolloUpdateIsJailbreakInstall(void) {
    if (![ApolloUpdateRawVariant() hasPrefix:@"deb-"]) return NO;
#if APOLLO_SIM_BUILD
    const char *override = getenv("APOLLO_UPDATE_BUILD_VARIANT");
    if (override && *override) return YES;   // the override models a package-manager install
#endif
    NSString *marker = ApolloBundledResourcePath(@"ARVariant", @"txt");
    return marker.length > 0 && ![marker hasPrefix:[NSBundle mainBundle].bundlePath];
}

// The variant used to pick the manifest entry. An unstamped sideloaded IPA (injected
// .deb) is treated as the standard build so the hand-off still works.
static NSString *ApolloUpdateBuildVariant(void) {
    NSString *variant = ApolloUpdateRawVariant();
    if ([variant hasPrefix:@"deb-"] && !ApolloUpdateIsJailbreakInstall()) return @"ipa";
    return variant;
}

BOOL ApolloUpdateChecksAvailable(void) {
    return !ApolloUpdateIsJailbreakInstall();
}

#pragma mark - Fetch

static void ApolloUpdateFetchLatest(void (^completion)(ApolloUpdateInfo *latest)) {
    NSURL *url = [NSURL URLWithString:kUpdateManifestURL];
#if APOLLO_SIM_BUILD
    const char *override = getenv("APOLLO_UPDATE_MANIFEST_URL");
    if (override && *override) url = [NSURL URLWithString:@(override)];
#endif
    NSString *variantKey = ApolloUpdateManifestKeyForBuildVariant(ApolloUpdateBuildVariant());

    // Ephemeral with a fixed User-Agent: no cookies, no cache on disk, and the
    // default CFNetwork UA (app name + OS build) isn't sent to GitHub.
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    config.HTTPShouldSetCookies = NO;
    config.timeoutIntervalForRequest = 15;
    config.HTTPAdditionalHeaders = @{@"User-Agent": @"Apollo-Reborn"};
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];

    [[session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? [(NSHTTPURLResponse *)response statusCode] : 0;
        ApolloUpdateInfo *latest = nil;
        // A file:// URL (sim override only) has no HTTP status.
        if (data && !error && (status == 200 || url.isFileURL)) {
            latest = ApolloUpdateInfoFromManifest([NSJSONSerialization JSONObjectWithData:data options:0 error:NULL],
                                                  variantKey);
        }
        ApolloLog(@"[update] fetch status=%ld error=%@ latest=%@ variant=%@",
                  (long)status, error.localizedDescription ?: @"none", latest.version ?: @"none", variantKey ?: @"none");
        dispatch_async(dispatch_get_main_queue(), ^{ completion(latest); });
    }] resume];
    [session finishTasksAndInvalidate];
}

static void ApolloUpdateApplyResult(ApolloUpdateInfo *latest) {
    BOOL newer = ApolloUpdateCompareVersions(ApolloUpdateInstalledVersion(), latest.version) == NSOrderedAscending;
    sAvailableUpdate = newer ? latest : nil;
    sUpToDate = !newer;
    [[NSUserDefaults standardUserDefaults] setObject:[NSDate date] forKey:UDKeyUpdateLastCheck];
}

#pragma mark - Presentation

// Manual checks present over whatever is on top. Automatic prompts additionally
// require that nothing modal is showing (What's New, share sheets, composers).
static UIViewController *ApolloUpdatePresenter(BOOL onlyOverBaseUI) {
    UIViewController *top = nil;
    for (UIWindow *window in ApolloAllWindows()) {
        if (window.isKeyWindow) { top = [window visibleViewController]; break; }
    }
    if (!top || top.isBeingPresented || top.isBeingDismissed || top.presentedViewController) return nil;
    if (onlyOverBaseUI) {
        for (UIViewController *vc = top; vc; vc = vc.parentViewController) {
            if (vc.presentingViewController) return nil;
        }
    }
    return top;
}

static void ApolloUpdateShowAlert(NSString *title, NSString *message) {
    UIViewController *presenter = ApolloUpdatePresenter(NO);
    if (!presenter) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

static void ApolloUpdatePresentSheet(ApolloUpdateInfo *info, UIViewController *presenter, BOOL offerSkip) {
    ApolloUpdatePromptViewController *sheet =
        [[ApolloUpdatePromptViewController alloc] initWithInfo:info
                                              installedVersion:ApolloUpdateInstalledVersion()
                                                     offerSkip:offerSkip];
    sheet.onSkip = ^{
        [[NSUserDefaults standardUserDefaults] setObject:info.version forKey:UDKeyUpdateSkippedVersion];
    };
    [sheet presentOverViewController:presenter];
}

#pragma mark - Automatic check

// Retries because What's New and other launch UI may still be on screen; if
// every attempt is blocked, forget the check time so the next foreground retries.
static void ApolloUpdateAttemptPrompt(ApolloUpdateInfo *info, NSArray<NSNumber *> *delays) {
    if (delays.count == 0) {
        sPromptPending = NO;
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:UDKeyUpdateLastCheck];
        return;
    }
    NSTimeInterval delay = delays.firstObject.doubleValue;
    NSArray<NSNumber *> *rest = [delays subarrayWithRange:NSMakeRange(1, delays.count - 1)];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (sAvailableUpdate != info) { sPromptPending = NO; return; }  // superseded by a manual check
        UIViewController *presenter = ApolloUpdatePresenter(YES);
        if (!presenter) { ApolloUpdateAttemptPrompt(info, rest); return; }
        sPromptPending = NO;
        sPromptedVersion = info.version;
        ApolloLog(@"[update] prompting for %@", info.version);
        ApolloUpdatePresentSheet(info, presenter, YES);
    });
}

static void ApolloUpdateMaybePrompt(void) {
    ApolloUpdateInfo *info = sAvailableUpdate;
    if (!info || sPromptPending || [sPromptedVersion isEqualToString:info.version]) return;
    if ([[[NSUserDefaults standardUserDefaults] stringForKey:UDKeyUpdateSkippedVersion] isEqualToString:info.version]) return;
    sPromptPending = YES;
    ApolloUpdateAttemptPrompt(info, @[@4, @6, @10]);
}

void ApolloUpdateCheckIfNeeded(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
#if APOLLO_SIM_BUILD
        // APOLLO_UPDATE_RESET=1 forgets the daily throttle and skipped version, once per launch.
        static dispatch_once_t resetOnce;
        dispatch_once(&resetOnce, ^{
            if (!getenv("APOLLO_UPDATE_RESET")) return;
            [defaults removeObjectForKey:UDKeyUpdateLastCheck];
            [defaults removeObjectForKey:UDKeyUpdateSkippedVersion];
        });
#endif
        if (![defaults boolForKey:UDKeyAutomaticUpdateChecks]) { ApolloLog(@"[update] auto check: off"); return; }
        // Only sideloaded release variants have an IPA to hand off.
        if (!ApolloUpdateManifestKeyForBuildVariant(ApolloUpdateBuildVariant())) {
            ApolloLog(@"[update] auto check: no release variant (%@)", ApolloUpdateBuildVariant());
            return;
        }

        if (sAvailableUpdate) { ApolloUpdateMaybePrompt(); return; }
        if (sChecking) return;
        NSTimeInterval sinceLast = -[[defaults objectForKey:UDKeyUpdateLastCheck] timeIntervalSinceNow];
        if ([defaults objectForKey:UDKeyUpdateLastCheck] && sinceLast >= 0 && sinceLast < kUpdateCheckInterval) {
            ApolloLog(@"[update] auto check: throttled (%.0f min since last)", sinceLast / 60);
            return;
        }

        ApolloLog(@"[update] auto check: fetching");
        sChecking = YES;
        ApolloUpdateFetchLatest(^(ApolloUpdateInfo *latest) {
            sChecking = NO;
            if (!latest) return;  // stay due; retried on the next foreground
            ApolloUpdateApplyResult(latest);
            ApolloUpdateMaybePrompt();
        });
    });
}

#pragma mark - Manual check

void ApolloUpdateCheckNow(void (^statusChanged)(void)) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (sChecking) return;
        sChecking = YES;
        if (statusChanged) statusChanged();
        ApolloUpdateFetchLatest(^(ApolloUpdateInfo *latest) {
            sChecking = NO;
            if (latest) ApolloUpdateApplyResult(latest);
            if (statusChanged) statusChanged();

            if (!latest) {
                ApolloUpdateShowAlert(@"Couldn't Check for Updates", @"Check your connection and try again.");
            } else if (sAvailableUpdate) {
                sPromptedVersion = sAvailableUpdate.version;  // the auto prompt needn't repeat this
                UIViewController *presenter = ApolloUpdatePresenter(NO);
                if (presenter) ApolloUpdatePresentSheet(sAvailableUpdate, presenter, NO);
            } else {
                ApolloUpdateShowAlert(@"You're Up to Date",
                                      [NSString stringWithFormat:@"Apollo-Reborn %@ is the latest version.",
                                       ApolloUpdateInstalledVersion()]);
            }
        });
    });
}

NSString *ApolloUpdateStatusText(void) {
    if (sChecking) return @"Checking…";
    if (sAvailableUpdate) return [NSString stringWithFormat:@"v%@ available", sAvailableUpdate.version];
    return sUpToDate ? @"Up to date" : nil;
}
