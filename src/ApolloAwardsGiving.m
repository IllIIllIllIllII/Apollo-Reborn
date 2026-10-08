#import "ApolloAwardsGiving.h"
#import "ApolloAwards.h"
#import "ApolloAwardsParsing.h"
#import "ApolloAccountCredentials.h"
#import "ApolloWebSessionIdentity.h"
#import "ApolloWebSessionStore.h"
#import "ApolloWebSessionLoginViewController.h"
#import "ApolloThemeRuntime.h"
#import "ApolloCommon.h"
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <SafariServices/SafariServices.h>
#import <objc/message.h>

// Keep target construction independent of WebKit and of Apollo's private
// initializers. In particular, a comment's ID is never used as a post ID.
static id ApolloAwardsGivingValue(id thing, NSString *key) {
    SEL selector = NSSelectorFromString(key);
    if (![thing respondsToSelector:selector]) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(thing, selector); }
    @catch (__unused NSException *exception) { return nil; }
}

NSURL *ApolloAwardsGivingURLForThing(id thing) {
    NSString *fullName = ApolloAwardsNormalizeFullName(ApolloAwardsGivingValue(thing, @"fullName"));
    if (!fullName) return nil;
    NSString *identifier = [fullName substringFromIndex:3];
    if ([fullName hasPrefix:@"t1_"]) {
        id parent = ApolloAwardsGivingValue(thing, @"linkID");
        if (![parent isKindOfClass:NSString.class]) return nil;
        parent = [parent lowercaseString];
        NSString *parentFullName = ApolloAwardsNormalizeFullName([parent hasPrefix:@"t3_"] ? parent : [@"t3_" stringByAppendingString:parent]);
        if (![parentFullName hasPrefix:@"t3_"]) return nil;
        return [NSURL URLWithString:[NSString stringWithFormat:@"https://sh.reddit.com/comments/%@/_/%@/?context=0",
                                     [parentFullName substringFromIndex:3], identifier]];
    }
    id permalink = ApolloAwardsGivingValue(thing, @"permalink");
    NSURL *url = [permalink isKindOfClass:NSURL.class] ? permalink : nil;
    if ([permalink isKindOfClass:NSString.class]) url = [NSURL URLWithString:permalink];
    NSArray *hosts = @[@"reddit.com", @"www.reddit.com", @"old.reddit.com", @"sh.reddit.com"];
    NSArray *parts = url.path.pathComponents;
    NSUInteger comments = [parts indexOfObject:@"comments"];
    BOOL correctPost = comments != NSNotFound && comments + 1 < parts.count &&
        [parts[comments + 1] isEqualToString:identifier];
    if ([url.scheme.lowercaseString isEqualToString:@"https"] && [hosts containsObject:url.host.lowercaseString] &&
        !url.user && !url.password && !url.port && correctPost) {
        NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
        components.host = @"sh.reddit.com";
        components.query = nil;
        components.fragment = nil;
        return components.URL;
    }
    return [NSURL URLWithString:[NSString stringWithFormat:@"https://sh.reddit.com/comments/%@/", identifier]];
}

@interface ApolloAwardsGivingViewController : UIViewController <WKNavigationDelegate, WKUIDelegate, UIAdaptivePresentationControllerDelegate>
@property (nonatomic, copy) NSString *username;
@property (nonatomic, copy) NSString *fullName;
@property (nonatomic, strong) NSURL *targetURL;
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) WKWebView *identityWebView;
@property (nonatomic, strong) NSHTTPURLResponse *identityResponse;
@property (nonatomic, strong) WKNavigation *contentNavigation;
@property (nonatomic, strong) WKNavigation *identityNavigation;
@property (nonatomic, strong) UIView *browserHost;
@property (nonatomic, strong) UIView *statusView;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UIButton *retryButton;
@property (nonatomic, strong) UIButton *signInButton;
@property (nonatomic) NSUInteger generation;
@property (nonatomic) NSUInteger navigationGeneration;
@property (nonatomic) NSUInteger identityGeneration;
@property (nonatomic) NSUInteger identityNavigationGeneration;
@property (nonatomic) BOOL verifying;
@property (nonatomic) BOOL openedChooser;
@property (nonatomic) BOOL initialIdentityVerified;
@property (nonatomic) BOOL refreshedAfterDismissal;
@property (nonatomic) BOOL finished;
@end

static NSString *ApolloAwardsGivingOpenChooserScript(void) {
    // Verified against Reddit's award-button and post-overflow-menu controllers.
    // This only opens the full chooser; selecting/giving/paying remains a user
    // action in Reddit's UI. Never click the quick-give button or an order form.
    return @"try {"
        "if (!/^t[13]_[a-z0-9]+$/.test(fullName)) return false;"
        "const post=fullName.startsWith('t3_');"
        "const tag=post?'shreddit-post-overflow-menu':'award-button';"
        "const attribute=post?'post-id':'thing-id';"
        "const control=document.querySelector(tag+'['+attribute+'=\"'+fullName+'\"]');"
        "if (!control) return false;"
        "control.scrollIntoView({block:'center'});"
        "await Promise.race([customElements.whenDefined(tag),new Promise(resolve=>setTimeout(resolve,2500))]);"
        "if (!control.isConnected || control.disabled || control.hasAttribute('disabled')) return false;"
        "const controller=control.awardController;"
        "if (!controller || typeof controller.getThingId!=='function' || controller.getThingId()!==fullName ||"
        "typeof controller.activateDialog!=='function') return false;"
        "await controller.activateDialog({animateOnOpen:true,skipQuickGivePopover:true});"
        "return true;"
        "} catch (_) {return false;}";
}

@implementation ApolloAwardsGivingViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Give Award";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.view.tintColor = ApolloThemeAccentColor() ?: self.view.tintColor;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
        target:self action:@selector(close)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
        target:self action:@selector(start)];

    UILabel *instruction = [UILabel new];
    instruction.text = @"Choose an award on Reddit, then confirm. Reddit shows your balance and any cost.";
    instruction.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    instruction.textColor = UIColor.secondaryLabelColor;
    instruction.numberOfLines = 0;
    instruction.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:instruction];
    self.browserHost = [UIView new];
    self.browserHost.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.browserHost];
    [NSLayoutConstraint activateConstraints:@[
        [instruction.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [instruction.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [instruction.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [self.browserHost.topAnchor constraintEqualToAnchor:instruction.bottomAnchor constant:8],
        [self.browserHost.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.browserHost.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.browserHost.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor]
    ]];

    self.statusView = [UIView new];
    self.statusView.backgroundColor = UIColor.systemBackgroundColor;
    self.statusView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.browserHost addSubview:self.statusView];
    [NSLayoutConstraint activateConstraints:@[
        [self.statusView.topAnchor constraintEqualToAnchor:self.browserHost.topAnchor],
        [self.statusView.bottomAnchor constraintEqualToAnchor:self.browserHost.bottomAnchor],
        [self.statusView.leadingAnchor constraintEqualToAnchor:self.browserHost.leadingAnchor],
        [self.statusView.trailingAnchor constraintEqualToAnchor:self.browserHost.trailingAnchor]
    ]];
    self.statusLabel = [UILabel new];
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.statusLabel.textColor = UIColor.labelColor;
    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.retryButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.retryButton setTitle:@"Try Again" forState:UIControlStateNormal];
    [self.retryButton addTarget:self action:@selector(start) forControlEvents:UIControlEventTouchUpInside];
    self.signInButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.signInButton setTitle:@"Sign In to Reddit" forState:UIControlStateNormal];
    [self.signInButton addTarget:self action:@selector(signIn) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[self.spinner, self.statusLabel, self.retryButton, self.signInButton]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentFill;
    stack.spacing = 16;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.statusView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.statusView.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:self.statusView.trailingAnchor constant:-24],
        [stack.centerYAnchor constraintEqualToAnchor:self.statusView.centerYAnchor]
    ]];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(checkActiveAccount)
        name:UIApplicationDidBecomeActiveNotification object:nil];
    [self start];
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    self.navigationController.presentationController.delegate = self;
}

- (BOOL)accountIsCurrent {
    return self.username.length > 0 && [self.username isEqualToString:ApolloActiveWebSessionUsername().lowercaseString];
}

- (void)showStatus:(NSString *)message loading:(BOOL)loading signIn:(BOOL)signIn {
    self.statusLabel.text = message;
    self.statusView.hidden = NO;
    self.webView.userInteractionEnabled = NO;
    self.retryButton.hidden = loading;
    self.signInButton.hidden = !signIn;
    if (loading) [self.spinner startAnimating]; else [self.spinner stopAnimating];
}

- (void)checkActiveAccount {
    if (self.finished || [self accountIsCurrent]) return;
    self.generation++;
    [self.webView stopLoading];
    [self.identityWebView stopLoading];
    [self showStatus:@"The active Apollo account changed. Close this sheet and open Give Award again." loading:NO signIn:NO];
}

- (void)start {
    if (self.finished) return;
    if (![self accountIsCurrent]) {
        [self showStatus:self.username.length ? @"The active Apollo account changed. Close this sheet and open Give Award again."
                                              : @"Add a Reddit account in Apollo before giving an award."
                 loading:NO signIn:NO];
        return;
    }
    self.generation++;
    NSUInteger generation = self.generation;
    self.verifying = NO;
    self.openedChooser = NO;
    self.initialIdentityVerified = NO;
    self.webView.navigationDelegate = nil;
    self.webView.UIDelegate = nil;
    [self.webView stopLoading];
    [self.webView removeFromSuperview];
    self.webView = nil;
    self.identityWebView.navigationDelegate = nil;
    [self.identityWebView stopLoading];
    [self.identityWebView removeFromSuperview];
    self.identityWebView = nil;
    self.identityResponse = nil;
    self.identityNavigation = nil;
    self.contentNavigation = nil;
    ApolloWebSessionEntry *session = ApolloWebSessionPollFor(self.username);
    if (session.cookieHeader.length == 0) {
        [self showStatus:[NSString stringWithFormat:@"Sign in as u/%@ to give awards on Reddit.", self.username] loading:NO signIn:YES];
        return;
    }
    [self showStatus:[NSString stringWithFormat:@"Connecting as u/%@…", self.username] loading:YES signIn:NO];
    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    // The shared persistent jar may belong to another Apollo account. This
    // sheet only receives the selected account's saved feature-session cookies.
    configuration.websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore;
    // www can honor the account's old-Reddit preference, which has no modern
    // award chooser. The explicit modern host and mobile mode keep this sheet
    // usable without changing any account-wide Reddit preferences.
    configuration.defaultWebpagePreferences.preferredContentMode = WKContentModeMobile;
    WKWebView *webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:configuration];
    self.webView = webView;
    // sh's /api/me.json redirects to www without CORS permission. A separate,
    // noninteractive main-document request can verify the exact same private
    // cookie jar without cross-origin JavaScript or the shared login browser.
    WKWebViewConfiguration *identityConfiguration = [WKWebViewConfiguration new];
    identityConfiguration.websiteDataStore = configuration.websiteDataStore;
    self.identityWebView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:identityConfiguration];
    self.identityWebView.navigationDelegate = self;
    self.identityWebView.userInteractionEnabled = NO;
    self.identityWebView.hidden = YES;
    [self.browserHost addSubview:self.identityWebView];
    webView.navigationDelegate = self;
    webView.UIDelegate = self;
    webView.userInteractionEnabled = NO;
    webView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.browserHost insertSubview:webView belowSubview:self.statusView];
    [NSLayoutConstraint activateConstraints:@[
        [webView.topAnchor constraintEqualToAnchor:self.browserHost.topAnchor],
        [webView.bottomAnchor constraintEqualToAnchor:self.browserHost.bottomAnchor],
        [webView.leadingAnchor constraintEqualToAnchor:self.browserHost.leadingAnchor],
        [webView.trailingAnchor constraintEqualToAnchor:self.browserHost.trailingAnchor]
    ]];

    dispatch_group_t group = dispatch_group_create();
    for (NSString *pair in [session.cookieHeader componentsSeparatedByString:@";"]) {
        NSRange separator = [pair rangeOfString:@"="];
        if (separator.location == NSNotFound) continue;
        NSString *name = [[pair substringToIndex:separator.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSString *value = [[pair substringFromIndex:separator.location + 1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!name.length || !value.length) continue;
        NSHTTPCookie *cookie = [NSHTTPCookie cookieWithProperties:@{
            NSHTTPCookieName:name, NSHTTPCookieValue:value, NSHTTPCookieDomain:@".reddit.com",
            NSHTTPCookiePath:@"/", NSHTTPCookieSecure:@"TRUE"
        }];
        if (!cookie) continue;
        dispatch_group_enter(group);
        [configuration.websiteDataStore.httpCookieStore setCookie:cookie completionHandler:^{ dispatch_group_leave(group); }];
    }
    __weak typeof(self) weakSelf = self;
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.finished || generation != strongSelf.generation || ![strongSelf accountIsCurrent]) return;
        [webView loadRequest:[NSURLRequest requestWithURL:strongSelf.targetURL]];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.finished || generation != strongSelf.generation || strongSelf.initialIdentityVerified) return;
        strongSelf.generation++;
        [strongSelf.webView stopLoading];
        [strongSelf.identityWebView stopLoading];
        [strongSelf showStatus:@"Reddit is taking too long to verify this session. Try again later." loading:NO signIn:YES];
    });
}

- (void)signIn {
    if (![self accountIsCurrent] || self.presentedViewController) return;
    self.generation++;
    [self.webView stopLoading];
    [self.identityWebView stopLoading];
    __weak typeof(self) weakSelf = self;
    UIViewController *login = [ApolloWebSessionLoginViewController loginControllerForUsername:self.username completion:^(BOOL success) {
        typeof(self) strongSelf = weakSelf;
        if (success && strongSelf && !strongSelf.finished) [strongSelf start];
    }];
    [self presentViewController:[[UINavigationController alloc] initWithRootViewController:login] animated:YES completion:nil];
}

- (void)close {
    self.finished = YES;
    self.generation++;
    [self.webView stopLoading];
    [self.identityWebView stopLoading];
    [self refreshAwardsAfterDismissal];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)refreshAwardsAfterDismissal {
    if (self.refreshedAfterDismissal) return;
    self.refreshedAfterDismissal = YES;
    ApolloAwardsRefresh(self.fullName);
}

- (void)presentationControllerDidDismiss:(UIPresentationController *)presentationController {
    self.finished = YES;
    self.generation++;
    [self.webView stopLoading];
    [self.identityWebView stopLoading];
    [self refreshAwardsAfterDismissal];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    if (self.finished) return;
    if (![self accountIsCurrent]) { [self checkActiveAccount]; return; }
    if (webView == self.webView) {
        if (self.verifying || navigation != self.contentNavigation) return;
        self.verifying = YES;
        self.identityGeneration = self.generation;
        self.identityNavigationGeneration = self.navigationGeneration;
        self.identityResponse = nil;
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://www.reddit.com/api/me.json"]
                                                              cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:20];
        [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
        self.identityNavigation = [self.identityWebView loadRequest:request];
        return;
    }
    if (webView != self.identityWebView || !self.verifying || navigation != self.identityNavigation) return;
    NSUInteger generation = self.identityGeneration;
    NSUInteger navigationGeneration = self.identityNavigationGeneration;
    WKWebView *contentWebView = self.webView;
    NSHTTPURLResponse *response = self.identityResponse;
    __weak typeof(self) weakSelf = self;
    NSString *script = @"try { return JSON.parse(document.body.textContent); } catch (_) { return null; }";
    [webView callAsyncJavaScript:script arguments:nil inFrame:nil inContentWorld:WKContentWorld.pageWorld completionHandler:^(id result, NSError *error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.finished || generation != strongSelf.generation ||
            navigationGeneration != strongSelf.navigationGeneration || webView != strongSelf.identityWebView ||
            contentWebView != strongSelf.webView) return;
        strongSelf.verifying = NO;
        if (![strongSelf accountIsCurrent]) { [strongSelf checkActiveAccount]; return; }
        ApolloWebSessionIdentityVerdict verdict = ApolloWebSessionClassifyIdentity(strongSelf.username,
            response.statusCode, response.MIMEType, result, error);
        ApolloLog(@"[Awards] Browser identity status=%ld mime=%@ verdict=%ld JSerror=%ld",
            (long)response.statusCode, response.MIMEType ?: @"none", (long)verdict, (long)error.code);
        if (verdict != ApolloWebSessionIdentityMatches) {
            NSString *message = verdict == ApolloWebSessionIdentityUnavailable
                ? [NSString stringWithFormat:@"Sign in as u/%@ to give this award.", strongSelf.username]
                : @"Reddit could not verify this session. Your saved login has been kept. Try again later or sign in on Reddit.";
            [strongSelf showStatus:message loading:NO signIn:YES];
            return;
        }
        strongSelf.statusView.hidden = YES;
        strongSelf.initialIdentityVerified = YES;
        [strongSelf.spinner stopAnimating];
        contentWebView.userInteractionEnabled = YES;
        strongSelf.title = [NSString stringWithFormat:@"Award as u/%@", strongSelf.username];
        if (!strongSelf.openedChooser) {
            strongSelf.openedChooser = YES;
            [contentWebView callAsyncJavaScript:ApolloAwardsGivingOpenChooserScript()
                               arguments:@{@"fullName":strongSelf.fullName} inFrame:nil inContentWorld:WKContentWorld.pageWorld
                       completionHandler:^(id opened, NSError *openError) {
                // A changed Reddit UI stays available for the user's normal
                // menu interaction. Never try another click or order endpoint.
                ApolloLog(@"[Awards] Reddit chooser %@", !openError && [opened isEqual:@YES] ? @"opened" : @"available through Reddit's award menu");
            }];
        }
    }];
}

- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation {
    if (self.finished || webView != self.webView) return;
    self.contentNavigation = navigation;
    self.navigationGeneration++;
    self.verifying = NO;
    [self.identityWebView stopLoading];
    self.identityNavigation = nil;
    [self showStatus:@"Verifying your Reddit account…" loading:YES signIn:NO];
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    if (self.finished || (webView != self.webView && webView != self.identityWebView) || error.code == NSURLErrorCancelled) return;
    if ((webView == self.webView && navigation != self.contentNavigation) ||
        (webView == self.identityWebView && navigation != self.identityNavigation)) return;
    self.verifying = NO;
    ApolloLog(@"[Awards] Browser %@ failed code=%ld", webView == self.identityWebView ? @"identity" : @"content", (long)error.code);
    [self showStatus:@"Reddit could not load. Your saved login has been kept. Try again later." loading:NO signIn:YES];
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self webView:webView didFailNavigation:navigation withError:error];
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationResponse:(WKNavigationResponse *)navigationResponse
    decisionHandler:(void (^)(WKNavigationResponsePolicy))decisionHandler {
    if (webView == self.identityWebView && navigationResponse.isForMainFrame &&
        [navigationResponse.response isKindOfClass:NSHTTPURLResponse.class]) {
        self.identityResponse = (NSHTTPURLResponse *)navigationResponse.response;
    }
    decisionHandler(WKNavigationResponsePolicyAllow);
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    if (self.finished || ![self accountIsCurrent]) {
        decisionHandler(WKNavigationActionPolicyCancel);
        [self checkActiveAccount];
        return;
    }
    NSURL *url = action.request.URL;
    NSString *host = url.host.lowercaseString;
    if (webView == self.identityWebView) {
        BOOL identityURL = [url.scheme.lowercaseString isEqualToString:@"https"] &&
            [host isEqualToString:@"www.reddit.com"] && [url.path isEqualToString:@"/api/me.json"] &&
            !url.user && !url.password && !url.port && !url.query.length && !url.fragment.length;
        decisionHandler(identityURL ? WKNavigationActionPolicyAllow : WKNavigationActionPolicyCancel);
        return;
    }
    BOOL reddit = [url.scheme.lowercaseString isEqualToString:@"https"] &&
        ([host isEqualToString:@"reddit.com"] || [host hasSuffix:@".reddit.com"]);
    if (!action.targetFrame.isMainFrame && action.targetFrame) {
        decisionHandler(WKNavigationActionPolicyAllow); // Reddit's own checkout embeds keep their normal behavior.
        return;
    }
    if (reddit) { decisionHandler(WKNavigationActionPolicyAllow); return; }
    decisionHandler(WKNavigationActionPolicyCancel);
    // A user-selected external help/payment link can use a separate browser;
    // the account-scoped Reddit cookie jar never follows it to another host.
    if (action.navigationType == WKNavigationTypeLinkActivated && [url.scheme.lowercaseString isEqualToString:@"https"] && !self.presentedViewController) {
        [self presentViewController:[[SFSafariViewController alloc] initWithURL:url] animated:YES completion:nil];
    }
}

- (WKWebView *)webView:(WKWebView *)webView createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
    forNavigationAction:(WKNavigationAction *)action windowFeatures:(WKWindowFeatures *)features {
    if (self.finished || ![self accountIsCurrent]) { [self checkActiveAccount]; return nil; }
    NSURL *url = action.request.URL;
    NSString *host = url.host.lowercaseString;
    if ([url.scheme.lowercaseString isEqualToString:@"https"] && ([host isEqualToString:@"reddit.com"] || [host hasSuffix:@".reddit.com"])) {
        [webView loadRequest:action.request];
    } else if ([url.scheme.lowercaseString isEqualToString:@"https"] && !self.presentedViewController) {
        [self presentViewController:[[SFSafariViewController alloc] initWithURL:url] animated:YES completion:nil];
    }
    return nil;
}

@end

UIViewController *ApolloAwardsGivingControllerForThing(id thing) {
    NSURL *target = ApolloAwardsGivingURLForThing(thing);
    if (!target) return nil;
    ApolloAwardsGivingViewController *controller = [ApolloAwardsGivingViewController new];
    controller.targetURL = target;
    controller.fullName = ApolloAwardsNormalizeFullName(ApolloAwardsGivingValue(thing, @"fullName"));
    controller.username = ApolloActiveWebSessionUsername().lowercaseString ?: @"";
    return [[UINavigationController alloc] initWithRootViewController:controller];
}

BOOL ApolloAwardsPresentGiving(id thing, UIViewController *presenter) {
    UIViewController *controller = ApolloAwardsGivingControllerForThing(thing);
    if (!controller || !presenter) return NO;
    [presenter presentViewController:controller animated:YES completion:nil];
    return YES;
}
