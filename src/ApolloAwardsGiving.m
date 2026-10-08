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

static BOOL ApolloAwardsGivingIsReferenceURL(NSURL *url) {
    NSString *host = url.host.lowercaseString, *path = url.path.lowercaseString;
    if (![url.scheme.lowercaseString isEqualToString:@"https"] ||
        !([host isEqualToString:@"reddit.com"] || [host hasSuffix:@".reddit.com"])) return NO;
    return [path isEqualToString:@"/help"] || [path hasPrefix:@"/help/"] ||
        [path hasPrefix:@"/policies/"] || [path hasPrefix:@"/wiki/"];
}

@interface ApolloAwardsGivingMessageHandler : NSObject <WKScriptMessageHandler>
@property (nonatomic, weak) id<WKScriptMessageHandler> delegate;
@end
@implementation ApolloAwardsGivingMessageHandler
- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message {
    [self.delegate userContentController:controller didReceiveScriptMessage:message];
}
@end

@interface ApolloAwardsGivingViewController : UIViewController <WKNavigationDelegate, WKUIDelegate, UIAdaptivePresentationControllerDelegate, WKScriptMessageHandler>
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
@property (nonatomic) BOOL initialChooserPresented;
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

static NSString *ApolloAwardsGivingIsolationStyle(void) {
    // Visibility, unlike display:none, leaves the bootstrap page's lazy
    // loaders working. Only the verified dialog portal is ever exposed.
    return @"html,body{background:Canvas!important;color-scheme:light dark;}"
        "body{overflow:hidden!important;}body *{visibility:hidden!important;pointer-events:none!important;}"
        "[data-apollo-award-portal],[data-apollo-award-portal] *{visibility:visible!important;pointer-events:auto!important;}"
        "[data-apollo-award-portal]{position:fixed!important;inset:0!important;width:100%!important;height:100%!important;}"
        "[data-apollo-award-portal] award-dialog{display:block!important;flex:1 1 auto!important;width:100%!important;height:100%!important;min-height:0!important;max-height:none!important;}"
        "[data-apollo-award-portal] award-dialog>rpl-modal-card{height:100%!important;max-height:100%!important;min-height:0!important;border-radius:0!important;}";
}

static NSString *ApolloAwardsGivingIsolateChooserScript(void) {
    // Reddit exposes these refs on rpl-dialog-sheet and rpl-dialog. Keep its
    // actual portal in place so selection, gold top-up and checkout retain
    // their existing component context and event listeners.
    return @"try {"
        "const waitFor=read=>{const value=read();if(value)return Promise.resolve(value);"
        "return new Promise(resolve=>{let timer;const finish=value=>{observer.disconnect();clearTimeout(timer);resolve(value);};"
        "const observer=new MutationObserver(()=>{const value=read();if(value)finish(value);});"
        "observer.observe(document.documentElement,{childList:true,subtree:true,attributes:true});"
        "timer=setTimeout(()=>finish(null),3500);});};"
        "const dialog=await waitFor(()=>document.querySelector('[dialog-id=\"award-dialog\"]'));"
        "if (!dialog) return false;"
        "await Promise.race([customElements.whenDefined(dialog.localName),new Promise(resolve=>setTimeout(resolve,3500))]);"
        "if (dialog.updateComplete) await dialog.updateComplete;"
        "if (dialog.elementRef && dialog.elementRef.updateComplete) await dialog.elementRef.updateComplete;"
        "await new Promise(resolve=>requestAnimationFrame(resolve));"
        "const currentPortal=()=>{try {const portal=dialog.portalContainer,panel=dialog.panelRef&&dialog.panelRef.value,root=dialog.portalShadowRoot;"
        "return dialog.open&&portal&&portal.isConnected&&panel&&panel.isConnected&&root?{portal,panel,root}:null;}catch(_){return null;}};"
        "const mounted=await waitFor(currentPortal);"
        "if (!mounted) return false;const {portal,panel,root}=mounted;"
        "let pageStyle=document.getElementById('apollo-award-isolation');"
        "if (!pageStyle){pageStyle=document.createElement('style');pageStyle.id='apollo-award-isolation';document.documentElement.appendChild(pageStyle);}"
        "pageStyle.textContent=isolationStyle;"
        "const panelCSS='.dialog{position:fixed!important;inset:0!important;width:100%!important;height:100%!important;}"
        ".dialog-overlay,[part=overlay],[part=handle-container]{display:none!important;}"
        ".dialog-panel,[part=panel]{position:fixed!important;inset:0!important;margin:0!important;width:100%!important;"
        "height:100%!important;max-width:none!important;min-width:0!important;max-height:none!important;"
        "border-radius:0!important;transform:none!important;display:flex!important;flex-direction:column!important;"
        "touch-action:auto!important;overflow:hidden!important;}';"
        "let activePortal=null;const styledRoots=new WeakSet();"
        "const prepare=current=>{if(!current)return;const {portal,root}=current;"
        "if(!styledRoots.has(root)){const style=document.createElement('style');style.textContent=panelCSS;root.appendChild(style);styledRoots.add(root);}"
        "const award=portal.querySelector('award-dialog');const awardRoot=award&&award.shadowRoot;"
        "if(awardRoot&&!styledRoots.has(awardRoot)){const style=document.createElement('style');style.textContent=':host,slot{height:100%!important;min-height:0!important;}';awardRoot.appendChild(style);styledRoots.add(awardRoot);}"
        "if(activePortal!==portal){if(activePortal)activePortal.removeAttribute('data-apollo-award-portal');"
        "portal.setAttribute('data-apollo-award-portal','');activePortal=portal;}};"
        "prepare(mounted);"
        "const replacements=new MutationObserver(()=>prepare(currentPortal()));"
        "replacements.observe(document.documentElement,{childList:true,subtree:true});"
        "if(dialog.shadowRoot)replacements.observe(dialog.shadowRoot,{childList:true,subtree:true});"
        "let closed=false;const close=event=>{"
        "if (closed || (event && event.target!==dialog && event.target!==dialog.elementRef)) return;"
        "closed=true;replacements.disconnect();if(activePortal)activePortal.removeAttribute('data-apollo-award-portal');"
        "window.webkit.messageHandlers.apolloAwardSheet.postMessage({action:'close',generation,navigationGeneration});};"
        "dialog.addEventListener(dialog.localName+':hide',close);"
        "dialog.addEventListener(dialog.localName+':after-hide',close);"
        "return true;"
        "} catch (_) {return false;}";
}

@implementation ApolloAwardsGivingViewController

- (void)applyChooserBackground:(UIColor *)color {
    self.view.backgroundColor = color;
    self.navigationController.view.backgroundColor = color;
    self.browserHost.backgroundColor = color;
    self.statusView.backgroundColor = color;
}

- (void)resetChooserBackground {
    // Match Reddit's light/dark modal surface while its actual CSS loads.
    [self applyChooserBackground:[UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
            ? [UIColor colorWithRed:24.0/255.0 green:28.0/255.0 blue:31.0/255.0 alpha:1]
            : UIColor.whiteColor;
    }]];
}

- (void)refreshChooserBackgroundWithCompletion:(void (^)(void))completion {
    WKWebView *webView = self.webView;
    NSUInteger generation = self.generation, navigationGeneration = self.navigationGeneration;
    __weak typeof(self) weakSelf = self;
    // Read the real modal color rather than assuming Reddit will keep today's
    // palette. A one-pixel canvas resolves any CSS color syntax to sRGB bytes.
    NSString *script = @"await new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));"
        "const dialog=document.querySelector('[dialog-id=\"award-dialog\"]');"
        "const portal=dialog&&dialog.portalContainer;const panel=dialog&&dialog.panelRef&&dialog.panelRef.value;"
        "const canvas=document.createElement('canvas');canvas.width=canvas.height=1;const context=canvas.getContext('2d');"
        "for(const element of [portal&&portal.querySelector('award-dialog>rpl-modal-card'),panel]){"
        "if(!element||!context)continue;context.clearRect(0,0,1,1);"
        "context.fillStyle=getComputedStyle(element).backgroundColor;context.fillRect(0,0,1,1);"
        "const rgba=Array.from(context.getImageData(0,0,1,1).data);if(rgba[3]===255)return rgba.slice(0,3);"
        "}return null;";
    [webView callAsyncJavaScript:script arguments:nil inFrame:nil inContentWorld:WKContentWorld.pageWorld completionHandler:^(id result, NSError *error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.finished || webView != strongSelf.webView ||
            generation != strongSelf.generation || navigationGeneration != strongSelf.navigationGeneration) return;
        if (![strongSelf accountIsCurrent]) { [strongSelf checkActiveAccount]; return; }
        if (!error && [result isKindOfClass:NSArray.class] && [result count] == 3) {
            BOOL valid = YES;
            for (id component in result) {
                if (![component isKindOfClass:NSNumber.class] || [component doubleValue] < 0 ||
                    [component doubleValue] > 255) { valid = NO; break; }
            }
            if (valid) [strongSelf applyChooserBackground:[UIColor colorWithRed:[result[0] doubleValue]/255.0
                green:[result[1] doubleValue]/255.0 blue:[result[2] doubleValue]/255.0 alpha:1]];
        }
        if (completion) completion();
    }];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]) {
        [self resetChooserBackground];
        if (self.initialChooserPresented) [self refreshChooserBackgroundWithCompletion:nil];
    }
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Give Award";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.view.tintColor = ApolloThemeAccentColor() ?: self.view.tintColor;
    self.browserHost = [UIView new];
    self.browserHost.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.browserHost];
    [NSLayoutConstraint activateConstraints:@[
        [self.browserHost.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:24],
        [self.browserHost.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.browserHost.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.browserHost.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor]
    ]];

    self.statusView = [UIView new];
    [self resetChooserBackground];
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
    UIButton *cancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [cancelButton setTitle:@"Cancel" forState:UIControlStateNormal];
    [cancelButton addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[self.spinner, self.statusLabel, self.retryButton, self.signInButton, cancelButton]];
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
    if (self.navigationController.presentationController.delegate != self)
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
    self.initialChooserPresented = NO;
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
    ApolloAwardsGivingMessageHandler *bridge = [ApolloAwardsGivingMessageHandler new];
    bridge.delegate = self;
    [configuration.userContentController addScriptMessageHandler:bridge name:@"apolloAwardSheet"];
    NSData *styleData = [NSJSONSerialization dataWithJSONObject:@[ApolloAwardsGivingIsolationStyle()] options:0 error:NULL];
    NSString *styleJSON = [[NSString alloc] initWithData:styleData encoding:NSUTF8StringEncoding];
    NSString *hidePage = [NSString stringWithFormat:@"(()=>{const s=document.createElement('style');s.id='apollo-award-isolation';s.textContent=%@[0];document.documentElement.appendChild(s);})();", styleJSON];
    [configuration.userContentController addUserScript:[[WKUserScript alloc] initWithSource:hidePage
        injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:YES]];
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
        if (!strongSelf || strongSelf.finished || generation != strongSelf.generation || strongSelf.initialChooserPresented) return;
        strongSelf.generation++;
        [strongSelf.webView stopLoading];
        [strongSelf.identityWebView stopLoading];
        [strongSelf showStatus:@"Reddit is taking too long to open the award chooser. Try again later." loading:NO signIn:YES];
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
    if (self.finished) return;
    self.finished = YES;
    self.statusView.hidden = NO;
    self.generation++;
    [self.webView stopLoading];
    [self.identityWebView stopLoading];
    [self refreshAwardsAfterDismissal];
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message {
    if (self.finished || !self.initialIdentityVerified || !message.frameInfo.isMainFrame || message.webView != self.webView ||
        ![message.body isKindOfClass:NSDictionary.class]) return;
    NSDictionary *body = message.body;
    if (![body[@"action"] isEqual:@"close"] || ![body[@"generation"] isKindOfClass:NSNumber.class] ||
        ![body[@"navigationGeneration"] isKindOfClass:NSNumber.class] ||
        [body[@"generation"] unsignedIntegerValue] != self.generation ||
        [body[@"navigationGeneration"] unsignedIntegerValue] != self.navigationGeneration) return;
    [self close];
}

- (void)isolateVerifiedChooser {
    WKWebView *webView = self.webView;
    NSUInteger generation = self.generation, navigationGeneration = self.navigationGeneration;
    __weak typeof(self) weakSelf = self;
    [webView callAsyncJavaScript:ApolloAwardsGivingIsolateChooserScript()
        arguments:@{@"isolationStyle":ApolloAwardsGivingIsolationStyle(), @"generation":@(generation), @"navigationGeneration":@(navigationGeneration)}
        inFrame:nil inContentWorld:WKContentWorld.pageWorld completionHandler:^(id ready, NSError *error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.finished || generation != strongSelf.generation ||
            navigationGeneration != strongSelf.navigationGeneration || webView != strongSelf.webView) return;
        if (![strongSelf accountIsCurrent]) { [strongSelf checkActiveAccount]; return; }
#if APOLLO_SIM_BUILD
        [strongSelf logChooserStructure];
#endif
        if (error || ![ready isEqual:@YES]) {
            [strongSelf showStatus:@"Reddit could not open the award chooser. Try again later." loading:NO signIn:NO];
            ApolloLog(@"[Awards] chooser isolation unavailable");
            return;
        }
        // Fill the native grabber/safe-area insets before showing the web card,
        // so the chooser appears as one continuous sheet surface.
        [strongSelf refreshChooserBackgroundWithCompletion:^{
            strongSelf.statusView.hidden = YES;
            strongSelf.initialChooserPresented = YES;
            [strongSelf.spinner stopAnimating];
            webView.userInteractionEnabled = YES;
            ApolloLog(@"[Awards] isolated Reddit chooser ready");
        }];
    }];
}

#if APOLLO_SIM_BUILD
- (void)logChooserStructure {
    // Structural diagnostics only: no text, links, account attributes, HTML,
    // cookie values, balances or selection/order state leave the web view.
    NSString *script = @"try {const d=document.querySelector('[dialog-id=\"award-dialog\"]');"
        "if(!d)return {dialog:false};const p=d.portalContainer,n=d.panelRef&&d.panelRef.value;"
        "const r=n&&n.getBoundingClientRect();const a=document.querySelector('award-dialog');"
        "return {dialog:true,tag:d.localName,open:!!d.open,variant:d.currentVariant||null,"
        "portal:p?{tag:p.localName,connected:p.isConnected,isolated:p.hasAttribute('data-apollo-award-portal')}:null,"
        "panel:n?{tag:n.localName,part:n.getAttribute('part'),role:n.getAttribute('role'),"
        "width:Math.round(r.width),height:Math.round(r.height),x:Math.round(r.x),y:Math.round(r.y)}:null,"
        "shadow:!!d.portalShadowRoot,viewport:{width:innerWidth,height:innerHeight},"
        "pages:a?Array.from(a.children).slice(0,8).map(x=>({tag:x.localName,slot:['award-selection','selection','leaderboard','gold-top-up'].includes(x.slot)?x.slot:null})):[]};"
        "}catch(_){return {diagnosticUnavailable:true};}";
    [self.webView callAsyncJavaScript:script arguments:nil inFrame:nil inContentWorld:WKContentWorld.pageWorld completionHandler:^(id result, NSError *error) {
        if ([result isKindOfClass:NSDictionary.class]) ApolloLog(@"[Awards][chooser-structure] %@", result);
        else ApolloLog(@"[Awards][chooser-structure] unavailable code=%ld", (long)error.code);
    }];
}
#endif

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
        strongSelf.initialIdentityVerified = YES;
        [strongSelf showStatus:@"Opening award chooser…" loading:YES signIn:NO];
        if (!strongSelf.openedChooser) {
            strongSelf.openedChooser = YES;
            [contentWebView callAsyncJavaScript:ApolloAwardsGivingOpenChooserScript()
                               arguments:@{@"fullName":strongSelf.fullName} inFrame:nil inContentWorld:WKContentWorld.pageWorld
                       completionHandler:^(id opened, NSError *openError) {
                typeof(self) currentSelf = weakSelf;
                if (!currentSelf || currentSelf.finished || generation != currentSelf.generation ||
                    navigationGeneration != currentSelf.navigationGeneration || contentWebView != currentSelf.webView) return;
                if (![currentSelf accountIsCurrent]) { [currentSelf checkActiveAccount]; return; }
                if (openError || ![opened isEqual:@YES]) {
                    [currentSelf showStatus:@"Reddit could not open the award chooser. Try again later." loading:NO signIn:NO];
                    return;
                }
                [currentSelf isolateVerifiedChooser];
            }];
        } else [strongSelf isolateVerifiedChooser];
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
    if (action.navigationType == WKNavigationTypeLinkActivated && ApolloAwardsGivingIsReferenceURL(url)) {
        decisionHandler(WKNavigationActionPolicyCancel);
        if (!self.presentedViewController)
            [self presentViewController:[[SFSafariViewController alloc] initWithURL:url] animated:YES completion:nil];
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
    if (ApolloAwardsGivingIsReferenceURL(url)) {
        if (!self.presentedViewController)
            [self presentViewController:[[SFSafariViewController alloc] initWithURL:url] animated:YES completion:nil];
    } else if ([url.scheme.lowercaseString isEqualToString:@"https"] && ([host isEqualToString:@"reddit.com"] || [host hasSuffix:@".reddit.com"])) {
        [webView loadRequest:action.request];
    } else if ([url.scheme.lowercaseString isEqualToString:@"https"] && !self.presentedViewController) {
        [self presentViewController:[[SFSafariViewController alloc] initWithURL:url] animated:YES completion:nil];
    }
    return nil;
}

@end

static ApolloAwardsGivingViewController *ApolloAwardsGivingContentForThing(id thing) {
    NSURL *target = ApolloAwardsGivingURLForThing(thing);
    if (!target) return nil;
    ApolloAwardsGivingViewController *controller = [ApolloAwardsGivingViewController new];
    controller.targetURL = target;
    controller.fullName = ApolloAwardsNormalizeFullName(ApolloAwardsGivingValue(thing, @"fullName"));
    controller.username = ApolloActiveWebSessionUsername().lowercaseString ?: @"";
    return controller;
}

static void ApolloAwardsConfigureGivingSheet(UINavigationController *navigation) {
    navigation.modalPresentationStyle = UIModalPresentationPageSheet;
    [navigation setNavigationBarHidden:YES animated:NO];
    if (@available(iOS 15.0, *)) {
        UISheetPresentationController *sheet = navigation.sheetPresentationController;
        sheet.detents = @[UISheetPresentationControllerDetent.mediumDetent, UISheetPresentationControllerDetent.largeDetent];
        sheet.selectedDetentIdentifier = UISheetPresentationControllerDetentIdentifierLarge;
        sheet.prefersGrabberVisible = YES;
        sheet.prefersScrollingExpandsWhenScrolledToEdge = YES;
    }
}

UIViewController *ApolloAwardsGivingControllerForThing(id thing) {
    ApolloAwardsGivingViewController *controller = ApolloAwardsGivingContentForThing(thing);
    if (!controller) return nil;
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:controller];
    ApolloAwardsConfigureGivingSheet(navigation);
    return navigation;
}

BOOL ApolloAwardsReplaceSheetWithGiving(id thing, UINavigationController *sheetNavigation) {
    ApolloAwardsGivingViewController *controller = ApolloAwardsGivingContentForThing(thing);
    if (!controller || !sheetNavigation.presentingViewController) return NO;
    [sheetNavigation setViewControllers:@[controller] animated:NO];
    ApolloAwardsConfigureGivingSheet(sheetNavigation);
    return YES;
}

BOOL ApolloAwardsPresentGiving(id thing, UIViewController *presenter) {
    UIViewController *controller = ApolloAwardsGivingControllerForThing(thing);
    if (!controller || !presenter) return NO;
    [presenter presentViewController:controller animated:YES completion:nil];
    return YES;
}
