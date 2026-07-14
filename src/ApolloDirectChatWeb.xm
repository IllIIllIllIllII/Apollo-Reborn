// Authenticated modern Reddit Chat for API-key-free accounts.
//
// Reddit no longer mirrors current Chat conversations through the legacy
// /message endpoints Apollo uses. The public API also has no modern Chat
// contract, so use Reddit's own authenticated web client inside an isolated
// WKWebView seeded only with the active account's stored Reddit cookies.

#import "ApolloDirectChatWeb.h"
#import "ApolloAccountCredentials.h"
#import "ApolloCommon.h"
#import "ApolloState.h"
#import "ApolloThemeRuntime.h"
#import "ApolloWebSessionStore.h"
#import "UserDefaultConstants.h"

#import <WebKit/WebKit.h>
#import <math.h>
#import <objc/message.h>
#import <objc/runtime.h>

NSString * const ApolloModernChatStatusDidChangeNotification = @"ApolloModernChatStatusDidChangeNotification";
static NSDictionary<NSString *, id> *sApolloModernChatStatus = nil;
static NSObject *ApolloModernChatStatusLock(void) {
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}

static NSString *ApolloDirectChatHex(NSString *hex) {
    return hex.length ? [@"#" stringByAppendingString:hex] : @"#000000";
}

static NSString *ApolloDirectChatHexFromColor(UIColor *color,
                                               UITraitCollection *traits,
                                               NSString *fallback) {
    UIColor *resolved = color;
    if (@available(iOS 13.0, *)) {
        resolved = [color resolvedColorWithTraitCollection:traits ?: UITraitCollection.currentTraitCollection];
    }
    CGFloat red = 0.0, green = 0.0, blue = 0.0, alpha = 0.0;
    if ([resolved getRed:&red green:&green blue:&blue alpha:&alpha]) {
        return [NSString stringWithFormat:@"#%02X%02X%02X",
                (unsigned int)lrint(red * 255.0),
                (unsigned int)lrint(green * 255.0),
                (unsigned int)lrint(blue * 255.0)];
    }
    CGFloat white = 0.0;
    if ([resolved getWhite:&white alpha:&alpha]) {
        unsigned int component = (unsigned int)lrint(white * 255.0);
        return [NSString stringWithFormat:@"#%02X%02X%02X", component, component, component];
    }
    return fallback;
}

// Apollo's AppColorTheme values and role colors were runtime-mapped for Theme
// Builder (docs/theme-builder-RE.md). Reuse that exact palette here so Chat
// follows every stock theme as well as arbitrary Theme Builder colors instead
// of merely switching between Reddit's light and dark appearances.
static NSDictionary<NSString *, NSString *> *ApolloDirectChatThemePalette(UITraitCollection *traits) {
    BOOL dark = traits.userInterfaceStyle == UIUserInterfaceStyleDark;
    NSString *mode = dark ? @"dark" : @"light";

    // Theme Manager V2 already compiles every custom, gallery, imported, and
    // per-appearance theme into semantic runtime tokens. Consume those tokens
    // directly so Chat follows the exact active theme rather than trying to
    // reinterpret the persisted editor model.
    if (ApolloThemeRuntimeIsActive()) {
        return @{
            @"accent": ApolloDirectChatHexFromColor(ApolloThemeRuntimeColor(ApolloThemeTokenAccent), traits, @"#007AFF"),
            @"primary": ApolloDirectChatHexFromColor(ApolloThemeRuntimeColor(ApolloThemeTokenBackground), traits, dark ? @"#131516" : @"#FFFFFF"),
            @"secondary": ApolloDirectChatHexFromColor(ApolloThemeRuntimeColor(ApolloThemeTokenSecondaryBackground), traits, dark ? @"#000000" : @"#F2F3F7"),
            @"tertiary": ApolloDirectChatHexFromColor(ApolloThemeRuntimeColor(ApolloThemeTokenTertiaryBackground), traits, dark ? @"#1A1A1A" : @"#F8F8F8"),
            @"separator": ApolloDirectChatHexFromColor(ApolloThemeRuntimeColor(ApolloThemeTokenSeparator), traits, dark ? @"#232323" : @"#EEEEEF"),
            @"bar": ApolloDirectChatHexFromColor(ApolloThemeRuntimeColor(ApolloThemeTokenBarBackground), traits, dark ? @"#131516" : @"#FBFBFB"),
            @"secondaryText": ApolloDirectChatHexFromColor(ApolloThemeRuntimeColor(ApolloThemeTokenSecondaryLabel), traits, dark ? @"#84878C" : @"#919191"),
            @"text": ApolloDirectChatHexFromColor(ApolloThemeRuntimeColor(ApolloThemeTokenLabel), traits, dark ? @"#F2F2F7" : @"#0D1117"),
            @"mode": mode,
        };
    }

    NSUserDefaults *group = [[NSUserDefaults alloc] initWithSuiteName:@"group.com.christianselig.apollo"];
    NSString *theme = [group stringForKey:@"AppColorTheme"] ?: @"default";
    NSDictionary *accents = @{
        @"default": @{@"light": @"007AFF", @"dark": @"2399FF"},
        @"nefertiti": @{@"light": @"01A200", @"dark": @"01A200"},
        @"fieryStare": @{@"light": @"FF0000", @"dark": @"FD0000"},
        @"spookyPumpkin": @{@"light": @"FF6200", @"dark": @"F25D00"},
        @"solarized": @{@"light": @"268BD2", @"dark": @"268BD2"},
        @"outrun": @{@"light": @"C400A6", @"dark": @"FF00D8"},
        @"sunset": @{@"light": @"FF6600", @"dark": @"FF7D00"},
        @"sepia": @{@"light": @"B88023", @"dark": @"D3AC72"},
        @"monochromatic": @{@"light": @"000000", @"dark": @"FFFFFF"},
        @"navy": @{@"light": @"0058B8", @"dark": @"0060C9"},
        @"skiesOnSkies": @{@"light": @"00B5F2", @"dark": @"01ADE8"},
        @"majesticPurple": @{@"light": @"8800FF", @"dark": @"9C2CFF"},
        @"magentasplosion": @{@"light": @"FF00B2", @"dark": @"E800A2"},
        @"sniffingWalnut": @{@"light": @"A74E00", @"dark": @"A74E00"},
        @"fisherKing": @{@"light": @"808286", @"dark": @"76787D"},
        @"chumbus": @{@"light": @"007AFF", @"dark": @"2399FF"},
        @"dracula": @{@"light": @"9760FF", @"dark": @"AD81FF"},
        @"mint": @{@"light": @"37BB98", @"dark": @"37BB98"},
    };
    NSDictionary *standard = dark
        ? @{@"primary": @"131516", @"secondary": @"000000", @"tertiary": @"1A1A1A", @"separator": @"232323", @"bar": @"131516"}
        : @{@"primary": @"FFFFFF", @"secondary": @"F2F3F7", @"tertiary": @"F8F8F8", @"separator": @"EEEEEF", @"bar": @"FBFBFB"};
    NSDictionary *tinted = @{
        @"solarized": @{
            @"light": @{@"primary": @"FDF6E3", @"secondary": @"E6DFCF", @"tertiary": @"F2ECDA", @"separator": @"E0DCCD", @"bar": @"F1ECDC"},
            @"dark": @{@"primary": @"002B36", @"secondary": @"003745", @"tertiary": @"00181F", @"separator": @"002836", @"bar": @"00171F"},
        },
        @"outrun": @{
            @"light": @{@"primary": @"CFD7E8", @"secondary": @"BAC1D1", @"tertiary": @"C1C8D9", @"separator": @"B5B9C7", @"bar": @"C5CAD9"},
            @"dark": @{@"primary": @"061636", @"secondary": @"081D47", @"tertiary": @"041129", @"separator": @"06214D", @"bar": @"031229"},
        },
        @"sunset": @{
            @"light": @{@"primary": @"FFE3D0", @"secondary": @"F2D8C7", @"tertiary": @"F2D8C7", @"separator": @"E0CBBD", @"bar": @"F1DACB"},
            @"dark": @{@"primary": @"000F29", @"secondary": @"12223D", @"tertiary": @"000F29", @"separator": @"061B40", @"bar": @"000B1F"},
        },
        @"sepia": @{
            @"light": @{@"primary": @"F1EAD9", @"secondary": @"DBD5CA", @"tertiary": @"E6DFCF", @"separator": @"D4CEC0", @"bar": @"E6E0D1"},
            @"dark": @{@"primary": @"211E1A", @"secondary": @"38332C", @"tertiary": @"141310", @"separator": @"29271F", @"bar": @"14130F"},
        },
        @"dracula": @{
            @"light": @{@"primary": @"F8F8F3", @"secondary": @"EDEDE8", @"tertiary": @"F8F8F3", @"separator": @"D7D3E0", @"bar": @"E6E4EB"},
            @"dark": @{@"primary": @"1A1D29", @"secondary": @"222636", @"tertiary": @"1A1D29", @"separator": @"242838", @"bar": @"12141C"},
        },
    };
    NSDictionary *roles = tinted[theme][mode] ?: standard;
    NSString *accent = accents[theme][mode] ?: accents[@"default"][mode];
    return @{
        @"accent": ApolloDirectChatHex(accent),
        @"primary": ApolloDirectChatHex(roles[@"primary"]),
        @"secondary": ApolloDirectChatHex(roles[@"secondary"]),
        @"tertiary": ApolloDirectChatHex(roles[@"tertiary"]),
        @"separator": ApolloDirectChatHex(roles[@"separator"]),
        @"bar": ApolloDirectChatHex(roles[@"bar"]),
        @"secondaryText": dark ? @"#84878C" : @"#919191",
        @"text": dark ? @"#F2F2F7" : @"#0D1117",
        @"mode": mode,
    };
}

static UIColor *ApolloDirectChatPaletteColor(NSDictionary *palette, NSString *key) {
    return ApolloColorFromHexString(palette[key]) ?: UIColor.systemBackgroundColor;
}

UIColor *ApolloModernChatThemeColor(UITraitCollection *traits, NSString *role) {
    return ApolloDirectChatPaletteColor(ApolloDirectChatThemePalette(traits), role);
}

NSDictionary<NSString *, id> *ApolloModernChatCachedStatus(void) {
    @synchronized (ApolloModernChatStatusLock()) {
        return [sApolloModernChatStatus copy];
    }
}

static void ApolloModernChatPublishStatus(NSDictionary<NSString *, id> *status) {
    if (![status isKindOfClass:[NSDictionary class]]) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSDictionary *old = ApolloModernChatCachedStatus();
        BOOL sameUnread = [old[@"hasUnread"] boolValue] == [status[@"hasUnread"] boolValue];
        BOOL samePreview = (!old[@"preview"] && !status[@"preview"]) || [old[@"preview"] isEqual:status[@"preview"]];
        if (sameUnread && samePreview) return;
        @synchronized (ApolloModernChatStatusLock()) {
            sApolloModernChatStatus = [status copy];
        }
        [[NSNotificationCenter defaultCenter] postNotificationName:ApolloModernChatStatusDidChangeNotification object:nil];
    });
}

// The modern Chat app is made of nested web components, so install the same
// variables in the document and every open shadow root. The second half finds
// the visible GIPHY results list by geometry rather than Reddit's generated
// class names, turning its phone-hostile full-width tiles into a stable 2-column
// grid while leaving message GIFs, images, and the emoji picker untouched.
static NSString *ApolloDirectChatEnhancementScript(NSDictionary *palette) {
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:palette options:0 error:nil];
    NSString *json = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding] ?: @"{}";
    NSMutableString *script = [NSMutableString stringWithString:@"(()=>{const palette="];
    [script appendString:json];
    [script appendString:@";"
        "window.__apolloChatPalette=palette;"
        "const roots=()=>{const out=[];const visit=r=>{if(!r||out.includes(r))return;out.push(r);for(const e of r.querySelectorAll('*'))if(e.shadowRoot)visit(e.shadowRoot);};visit(document);return out;};"
        "const css=()=>`:host,:root{"
            "--apollo-chat-accent:${palette.accent};--apollo-chat-bg:${palette.primary};--apollo-chat-surface:${palette.secondary};--apollo-chat-raised:${palette.tertiary};--apollo-chat-border:${palette.separator};--apollo-chat-text:${palette.text};--apollo-chat-muted:${palette.secondaryText};"
            "--color-neutral-background:${palette.primary}!important;--color-neutral-background-container:${palette.secondary}!important;--color-neutral-background-weak:${palette.tertiary}!important;--color-neutral-background-hover:${palette.tertiary}!important;--color-neutral-background-selected:${palette.tertiary}!important;"
            "--color-neutral-border:${palette.separator}!important;--color-neutral-border-weak:${palette.separator}!important;--color-neutral-content:${palette.text}!important;--color-neutral-content-strong:${palette.text}!important;--color-neutral-content-weak:${palette.secondaryText}!important;"
            "--color-primary:${palette.accent}!important;--color-primary-hover:${palette.accent}!important;--color-primary-visited:${palette.accent}!important;--color-primary-background:${palette.accent}!important;--color-secondary:${palette.text}!important;--color-secondary-background:${palette.tertiary}!important;"
            "--color-tone-1:${palette.text}!important;--color-tone-2:${palette.secondaryText}!important;--color-tone-3:${palette.secondaryText}!important;--color-tone-4:${palette.separator}!important;--color-tone-5:${palette.tertiary}!important;--color-tone-6:${palette.secondary}!important;--color-tone-7:${palette.primary}!important;"
            "--newCommunityTheme-body:${palette.primary}!important;--newCommunityTheme-bodyText:${palette.text}!important;--newCommunityTheme-button:${palette.accent}!important;--newCommunityTheme-line:${palette.separator}!important;"
        "}html,body{background-color:var(--apollo-chat-bg)!important;color:var(--apollo-chat-text)!important;}body{accent-color:var(--apollo-chat-accent)!important;}a{color:var(--apollo-chat-accent)!important;}input,textarea,[contenteditable=true]{caret-color:var(--apollo-chat-accent)!important;}::selection{background:var(--apollo-chat-accent)!important;color:var(--apollo-chat-bg)!important;}`;"
        "const themeRoots=()=>{for(const r of roots()){let s=r.querySelector('style[data-apollo-chat-theme]');if(!s){s=document.createElement('style');s.setAttribute('data-apollo-chat-theme','');const target=r===document?(document.head||document.documentElement):r;if(!target)continue;target.appendChild(s);}s.textContent=css();}};"
        "const fixGiphy=()=>{let grids=0;for(const r of roots())for(const container of r.querySelectorAll('.gifs-container')){const media=[...container.querySelectorAll(':scope > img,:scope > video')];if(media.length<2)continue;container.setAttribute('data-apollo-giphy-grid','');container.style.setProperty('display','grid','important');container.style.setProperty('grid-template-columns','repeat(2,minmax(0,1fr))','important');container.style.setProperty('grid-auto-rows','104px','important');container.style.setProperty('gap','6px','important');container.style.setProperty('width','100%','important');container.style.setProperty('height','auto','important');container.style.setProperty('box-sizing','border-box','important');for(const m of media){m.style.setProperty('width','100%','important');m.style.setProperty('min-width','0','important');m.style.setProperty('height','104px','important');m.style.setProperty('max-width','none','important');m.style.setProperty('object-fit','cover','important');m.style.setProperty('margin','0','important');m.style.setProperty('overflow','hidden','important');m.style.setProperty('border-radius','10px','important');}grids++;}return grids;};"
        "const blockRedditHomeLogo=()=>{let blocked=0;for(const r of roots())for(const a of r.querySelectorAll('a[href]')){try{const u=new URL(a.href,location.href);if((u.hostname==='reddit.com'||u.hostname.endsWith('.reddit.com'))&&u.pathname==='/'&&u.search===''&&u.hash===''){const area=(a.parentElement?.textContent||'').trim().toLowerCase();if(area.includes('chats')){a.setAttribute('aria-disabled','true');a.style.setProperty('pointer-events','none','important');a.style.setProperty('cursor','default','important');blocked++;}}}catch(e){}}return blocked;};"
        "const sweep=()=>{themeRoots();return {roots:roots().length,giphyGrids:fixGiphy(),blockedHomeLinks:blockRedditHomeLogo()};};"
        "window.__apolloChatEnhancementSweep=sweep;"
        "if(!window.__apolloChatEnhancementTimer)window.__apolloChatEnhancementTimer=setInterval(()=>window.__apolloChatEnhancementSweep?.(),700);"
        "return sweep();})()"];
    return script;
}

static NSDictionary<NSString *, NSString *> *ApolloDirectChatCookiePairs(NSString *header) {
    NSMutableDictionary<NSString *, NSString *> *pairs = [NSMutableDictionary dictionary];
    for (NSString *component in [header componentsSeparatedByString:@";"]) {
        NSRange equals = [component rangeOfString:@"="];
        if (equals.location == NSNotFound) continue;
        NSString *name = [[component substringToIndex:equals.location]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSString *value = [component substringFromIndex:equals.location + 1];
        if (name.length > 0) pairs[name] = value ?: @"";
    }
    return pairs;
}

@interface ApolloDirectChatWebViewController : UIViewController <WKNavigationDelegate, WKUIDelegate>
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UIView *loadingView;
@property (nonatomic, strong) UILabel *loadingTitleLabel;
@property (nonatomic, strong) UILabel *loadingDetailLabel;
@property (nonatomic, strong) UIImageView *loadingIconView;
@property (nonatomic, copy) NSString *username;
@property (nonatomic, assign) BOOL didRevealChat;
@property (nonatomic, assign) NSUInteger readinessGeneration;
@property (nonatomic, strong) UIColor *originalNavigationTintColor;
@end

@implementation ApolloDirectChatWebViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Reddit Chat";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.view.clipsToBounds = YES;

    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    // The shared persistent jar can belong to a different web-session account.
    // Seed a fresh per-controller store from the active account instead.
    configuration.websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore;
    self.webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:configuration];
    self.webView.customUserAgent = @"Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1";
    self.webView.navigationDelegate = self;
    self.webView.UIDelegate = self;
    self.webView.translatesAutoresizingMaskIntoConstraints = NO;
    self.webView.allowsBackForwardNavigationGestures = YES;
    self.webView.opaque = YES;
    self.webView.backgroundColor = UIColor.systemBackgroundColor;
    self.webView.scrollView.backgroundColor = UIColor.systemBackgroundColor;
    self.webView.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    // Keep Reddit's asynchronous Chat bootstrap hidden; only reveal the mobile
    // Chat document after its request list or composer has actually hydrated.
    self.webView.alpha = 0.0;
    self.webView.userInteractionEnabled = NO;
    [self.view addSubview:self.webView];
    [NSLayoutConstraint activateConstraints:@[
        [self.webView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.webView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        // Keep Reddit's conversation composer below Apollo's navigation bar
        // and above the home indicator/keyboard instead of drawing underneath
        // either chrome surface.
        [self.webView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.webView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
    ]];

    self.loadingView = [UIView new];
    self.loadingView.translatesAutoresizingMaskIntoConstraints = NO;
    self.loadingView.backgroundColor = UIColor.systemBackgroundColor;
    [self.view addSubview:self.loadingView];
    [NSLayoutConstraint activateConstraints:@[
        [self.loadingView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.loadingView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.loadingView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.loadingView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    UIImageView *iconView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"bubble.left.and.bubble.right.fill"]];
    self.loadingIconView = iconView;
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    iconView.tintColor = [UIColor colorWithRed:0.93 green:0.12 blue:0.76 alpha:1.0];
    [NSLayoutConstraint activateConstraints:@[
        [iconView.widthAnchor constraintEqualToConstant:46.0],
        [iconView.heightAnchor constraintEqualToConstant:46.0],
    ]];

    self.loadingTitleLabel = [UILabel new];
    self.loadingTitleLabel.text = @"Opening Reddit Chat";
    self.loadingTitleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    self.loadingTitleLabel.textColor = UIColor.labelColor;
    self.loadingTitleLabel.textAlignment = NSTextAlignmentCenter;

    self.loadingDetailLabel = [UILabel new];
    self.loadingDetailLabel.text = @"Preparing your private session…";
    self.loadingDetailLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    self.loadingDetailLabel.textColor = UIColor.secondaryLabelColor;
    self.loadingDetailLabel.textAlignment = NSTextAlignmentCenter;
    self.loadingDetailLabel.numberOfLines = 2;

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    UIStackView *loadingStack = [[UIStackView alloc] initWithArrangedSubviews:@[
        iconView, self.loadingTitleLabel, self.loadingDetailLabel, self.spinner
    ]];
    loadingStack.translatesAutoresizingMaskIntoConstraints = NO;
    loadingStack.axis = UILayoutConstraintAxisVertical;
    loadingStack.alignment = UIStackViewAlignmentCenter;
    loadingStack.spacing = 10.0;
    [self.loadingView addSubview:loadingStack];
    [NSLayoutConstraint activateConstraints:@[
        [loadingStack.centerXAnchor constraintEqualToAnchor:self.loadingView.centerXAnchor],
        [loadingStack.centerYAnchor constraintEqualToAnchor:self.loadingView.centerYAnchor constant:-24.0],
        [loadingStack.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.loadingView.leadingAnchor constant:30.0],
        [loadingStack.trailingAnchor constraintLessThanOrEqualToAnchor:self.loadingView.trailingAnchor constant:-30.0],
    ]];
    [self.spinner startAnimating];

    UIBarButtonItem *reload = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(apollo_reloadChat)];
    self.navigationItem.rightBarButtonItem = reload;
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(apollo_activeThemeChanged:)
                                                 name:@"com.christianselig.ApolloSpecificThemeChanged"
                                               object:nil];
    [self apollo_applyActiveTheme];
    [self apollo_seedAndLoad];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (!self.originalNavigationTintColor) {
        self.originalNavigationTintColor = self.navigationController.navigationBar.tintColor;
    }
    [self apollo_applyActiveTheme];
}

- (void)viewWillDisappear:(BOOL)animated {
    [self apollo_captureChatStatus];
    [super viewWillDisappear:animated];
    if (self.originalNavigationTintColor) {
        self.navigationController.navigationBar.tintColor = self.originalNavigationTintColor;
    }
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self apollo_applyActiveTheme];
}

- (void)apollo_activeThemeChanged:(NSNotification *)note {
    [self apollo_applyActiveTheme];
}

- (void)apollo_applyActiveTheme {
    NSDictionary *palette = ApolloDirectChatThemePalette(self.traitCollection);
    UIColor *accent = ApolloDirectChatPaletteColor(palette, @"accent");
    UIColor *background = ApolloDirectChatPaletteColor(palette, @"primary");
    UIColor *bar = ApolloDirectChatPaletteColor(palette, @"bar");
    UIColor *separator = ApolloDirectChatPaletteColor(palette, @"separator");
    UIColor *text = ApolloDirectChatPaletteColor(palette, @"text");
    UIColor *secondaryText = ApolloDirectChatPaletteColor(palette, @"secondaryText");

    self.view.backgroundColor = background;
    self.loadingView.backgroundColor = background;
    self.webView.backgroundColor = background;
    self.webView.scrollView.backgroundColor = background;
    self.view.tintColor = accent;
    self.loadingIconView.tintColor = accent;
    self.loadingTitleLabel.textColor = text;
    self.loadingDetailLabel.textColor = secondaryText;
    self.spinner.color = accent;
    self.navigationItem.rightBarButtonItem.tintColor = accent;
    self.navigationController.navigationBar.tintColor = accent;

    UINavigationBarAppearance *appearance = [UINavigationBarAppearance new];
    [appearance configureWithOpaqueBackground];
    appearance.backgroundColor = bar;
    appearance.shadowColor = separator;
    appearance.titleTextAttributes = @{NSForegroundColorAttributeName: text};
    self.navigationItem.standardAppearance = appearance;
    self.navigationItem.scrollEdgeAppearance = appearance;
    self.navigationItem.compactAppearance = appearance;

    if (self.webView.URL) {
        NSString *script = ApolloDirectChatEnhancementScript(palette);
        [self.webView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
            if (error) {
                ApolloLog(@"[DirectChatWeb] Theme injection failed: %@", error);
            } else if ([result isKindOfClass:[NSDictionary class]] && [result[@"giphyGrids"] integerValue] > 0) {
                ApolloLog(@"[DirectChatWeb] Applied Apollo theme and compact GIPHY grid");
            }
        }];
    }
}

- (void)apollo_showLoadingWithDetail:(NSString *)detail {
    self.didRevealChat = NO;
    self.readinessGeneration += 1;
    self.loadingTitleLabel.text = @"Opening Reddit Chat";
    self.loadingDetailLabel.text = detail.length ? detail : @"Preparing your private session…";
    self.loadingView.hidden = NO;
    self.loadingView.alpha = 1.0;
    self.webView.alpha = 0.0;
    self.webView.userInteractionEnabled = NO;
    [self.spinner startAnimating];
}

- (void)apollo_showLoadError:(NSString *)detail {
    self.loadingView.hidden = NO;
    self.loadingView.alpha = 1.0;
    self.loadingTitleLabel.text = @"Chat couldn’t be opened";
    self.loadingDetailLabel.text = detail ?: @"Try refreshing or signing in again.";
    [self.spinner stopAnimating];
}

- (void)apollo_revealChat {
    if (self.didRevealChat || ![self.webView.URL.path hasPrefix:@"/chat"]) return;
    self.didRevealChat = YES;
    [self.spinner stopAnimating];
    self.webView.userInteractionEnabled = YES;
    [UIView animateWithDuration:0.22 animations:^{
        self.webView.alpha = 1.0;
        self.loadingView.alpha = 0.0;
    } completion:^(BOOL finished) {
        self.loadingView.hidden = YES;
    }];
    ApolloLog(@"[DirectChatWeb] Revealed hydrated mobile Chat UI");
    [self apollo_captureChatStatus];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self apollo_captureChatStatus];
    });
}

- (void)apollo_captureChatStatus {
    if (!self.webView.URL || ![self.webView.URL.path hasPrefix:@"/chat"]) return;
    NSString *script =
        @"(()=>{const roots=[];const visit=r=>{if(!r||roots.includes(r))return;roots.push(r);for(const e of r.querySelectorAll('*'))if(e.shadowRoot)visit(e.shadowRoot);};visit(document);"
         "const visible=e=>{const r=e.getBoundingClientRect(),s=getComputedStyle(e);return r.width>0&&r.height>0&&s.display!=='none'&&s.visibility!=='hidden'&&s.opacity!=='0';};"
         "let hasUnread=/^\\(\\d+\\)/.test(document.title);let preview='';"
         "for(const root of roots)for(const e of root.querySelectorAll('*')){if(!visible(e))continue;const cls=typeof e.className==='string'?e.className:'';const marker=(cls+' '+(e.getAttribute('data-testid')||'')+' '+(e.getAttribute('aria-label')||'')).toLowerCase();const text=(e.textContent||'').replace(/\\s+/g,' ').trim();if(!hasUnread&&marker.includes('unread')&&text.toLowerCase()!=='unread'&&!e.matches('input,[role=switch]'))hasUnread=true;if(!preview&&e.children.length===0&&text.length>3&&text.length<160&&/^[^:]{1,40}:\\s+.+/.test(text))preview=text;}"
         "return {hasUnread,preview:preview||null,checkedAt:Date.now()};})()";
    [self.webView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
        if (!error && [result isKindOfClass:[NSDictionary class]]) ApolloModernChatPublishStatus(result);
    }];
}

- (void)apollo_seedAndLoad {
    ApolloWebSessionEntry *session = ApolloActiveWebSession();
    self.username = ApolloActiveWebSessionUsername() ?: @"";
    if (session.cookieHeader.length == 0) {
        [self apollo_showLoadError:@"Sign in to Reddit again, then reopen Direct Chat."];
        ApolloLog(@"[DirectChatWeb] Cannot load: active account has no web session");
        return;
    }
    NSString *detail = self.username.length ? [NSString stringWithFormat:@"Connecting as u/%@…", self.username] : @"Connecting to Reddit…";
    [self apollo_showLoadingWithDetail:detail];

    NSDictionary<NSString *, NSString *> *pairs = ApolloDirectChatCookiePairs(session.cookieHeader);
    WKHTTPCookieStore *store = self.webView.configuration.websiteDataStore.httpCookieStore;
    dispatch_group_t group = dispatch_group_create();
    [pairs enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSString *value, BOOL *stop) {
        NSMutableDictionary *properties = [@{
            NSHTTPCookieName: name,
            NSHTTPCookieValue: value,
            NSHTTPCookieDomain: @".reddit.com",
            NSHTTPCookiePath: @"/",
            NSHTTPCookieSecure: @"TRUE",
            NSHTTPCookieExpires: [NSDate dateWithTimeIntervalSinceNow:24.0 * 60.0 * 60.0],
        } mutableCopy];
        NSHTTPCookie *cookie = [NSHTTPCookie cookieWithProperties:properties];
        if (!cookie) return;
        dispatch_group_enter(group);
        [store setCookie:cookie completionHandler:^{ dispatch_group_leave(group); }];
    }];
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        ApolloLog(@"[DirectChatWeb] Seeded %lu cookies for u/%@; loading mobile Chat Requests",
                  (unsigned long)pairs.count, self.username);
        // `/chat` restores Reddit's last Threads room. `/chat/requests` is the
        // stable modern direct-message request route discovered through the
        // hydrated desktop client, and it accepts the same authenticated Reddit
        // cookies directly. Start mobile/device-width here so none of the old
        // desktop feed/drawer handoff is needed during ordinary use.
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://www.reddit.com/chat/requests"]];
        request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        [self.webView loadRequest:request];
    });
}

- (void)apollo_waitForChatReadinessAttempt:(NSUInteger)attempt generation:(NSUInteger)generation {
    if (generation != self.readinessGeneration || self.didRevealChat) return;
    // The navigation-finished callback fires before Reddit's Chat custom
    // elements finish hydrating. If the Requests route is empty, use Reddit's
    // own Threads/back control before revealing the page. This preserves the
    // authenticated SPA state while taking the user straight to their existing
    // conversations instead of leaving them on a dead-end empty screen.
    NSString *script =
        @"(()=>{const roots=[];const visit=r=>{if(!r||roots.includes(r))return;roots.push(r);for(const e of r.querySelectorAll('*'))if(e.shadowRoot)visit(e.shadowRoot);};visit(document);"
         "const visible=e=>{const r=e.getBoundingClientRect(),s=getComputedStyle(e);return r.width>0&&r.height>0&&s.display!=='none'&&s.visibility!=='hidden'&&s.opacity!=='0';};"
         "const text=e=>(e.textContent||'').replace(/\\s+/g,' ').trim().toLowerCase();"
         "const controls=roots.flatMap(r=>[...r.querySelectorAll('button,a,[role=button],input,textarea,[contenteditable=true],h1,h2,h3,p')]);"
         "const empty=location.pathname.startsWith('/chat/requests')&&controls.some(e=>visible(e)&&text(e)==='no requests yet');"
         "if(empty&&!window.__apolloEmptyRequestsHandled){window.__apolloEmptyRequestsHandled=true;const clickables=roots.flatMap(r=>[...r.querySelectorAll('button,a,[role=button]')]).filter(visible);"
         "let back=clickables.find(e=>{const r=e.getBoundingClientRect();if(r.left>130||r.top>180)return false;const marker=[text(e),e.getAttribute('aria-label'),e.getAttribute('title'),e.getAttribute('data-testid')].filter(Boolean).join(' ').toLowerCase();return /(^|\\s)(back|threads?)(\\s|$)/.test(marker)||!!e.querySelector('[icon-name*=back i],[name*=back i],[aria-label*=back i]');});"
         "if(!back)back=clickables.filter(e=>{const r=e.getBoundingClientRect(),cx=r.left+r.width/2,cy=r.top+r.height/2;return cx<90&&cy>55&&cy<180&&r.width<180&&r.height<100;}).sort((a,b)=>a.getBoundingClientRect().top-b.getBoundingClientRect().top)[0];"
         "if(back){back.click();return 'redirected';}location.replace('/chat');return 'redirected';}"
         "const ready=controls.some(e=>{if(!visible(e))return false;const t=text(e),a=(e.getAttribute('aria-label')||'').trim().toLowerCase();"
         "if(t==='view request'||t==='go to messages'||t==='start new chat'||t==='accept'||t==='additional requests'||t==='threads'||t==='chats')return true;"
         "const room=location.pathname.startsWith('/chat/room/');return room&&(e.matches('input,textarea,[contenteditable=true]')||a==='send message'||a==='message');});return ready?'ready':'waiting';})()";
    __weak typeof(self) weakSelf = self;
    [self.webView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || generation != self.readinessGeneration || self.didRevealChat) return;
        if (!error && [result isEqual:@"ready"]) {
            [self apollo_revealChat];
            return;
        }
        if (!error && [result isEqual:@"redirected"] && attempt == 0) {
            ApolloLog(@"[DirectChatWeb] No pending requests; returning to the Threads list");
        }
        if (attempt >= 59) {
            ApolloLog(@"[DirectChatWeb] Chat readiness probe timed out; revealing current route");
            [self apollo_revealChat];
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self apollo_waitForChatReadinessAttempt:attempt + 1 generation:generation];
        });
    }];
}

- (WKWebView *)webView:(WKWebView *)webView
    createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
               forNavigationAction:(WKNavigationAction *)navigationAction
                    windowFeatures:(WKWindowFeatures *)windowFeatures {
    // Reddit's “Open chat in full screen” control opens a new browsing context.
    // Keep it inside Apollo's isolated, already-authenticated web view.
    if (!navigationAction.targetFrame && navigationAction.request.URL) {
        [webView loadRequest:navigationAction.request];
    }
    return nil;
}

- (void)webView:(WKWebView *)webView
    decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
                    decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *url = navigationAction.request.URL;
    NSString *host = url.host.lowercaseString ?: @"";
    BOOL redditHost = [host isEqualToString:@"reddit.com"] || [host hasSuffix:@".reddit.com"];
    BOOL redditHomeLogo = redditHost && [url.path isEqualToString:@"/"] && url.query.length == 0 && url.fragment.length == 0;
    if (redditHomeLogo && navigationAction.navigationType == WKNavigationTypeLinkActivated) {
        ApolloLog(@"[DirectChatWeb] Blocked Reddit home-logo navigation inside Chat");
        decisionHandler(WKNavigationActionPolicyCancel);
        return;
    }
    decisionHandler(WKNavigationActionPolicyAllow);
}

- (void)apollo_reloadChat {
    if (self.webView.URL) {
        [self apollo_showLoadingWithDetail:@"Refreshing your chat…"];
        [self.webView reloadFromOrigin];
    } else {
        [self apollo_seedAndLoad];
    }
}

- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation {
    if (!self.didRevealChat) [self.spinner startAnimating];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    ApolloLog(@"[DirectChatWeb] Loaded %@%@ for u/%@", webView.URL.host ?: @"unknown host", webView.URL.path ?: @"", self.username);
    BOOL isFullChatRoute = [webView.URL.path isEqualToString:@"/chat"] || [webView.URL.path hasPrefix:@"/chat/"];
    if (isFullChatRoute) {
        // Apply the active Apollo palette before the loading cover is removed;
        // users never see Reddit's stock colors flash during hydration.
        [self apollo_applyActiveTheme];
        [self apollo_waitForChatReadinessAttempt:0 generation:self.readinessGeneration];
        return;
    }
    [self apollo_showLoadError:@"Your Reddit Chat session expired. Sign in again, then retry."];
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    if (error.code != NSURLErrorCancelled)
        [self apollo_showLoadError:@"Check your connection, then tap refresh."];
    ApolloLog(@"[DirectChatWeb] Provisional navigation failed for u/%@: %@", self.username, error.localizedDescription);
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    if (error.code != NSURLErrorCancelled)
        [self apollo_showLoadError:@"Check your connection, then tap refresh."];
    ApolloLog(@"[DirectChatWeb] Navigation failed for u/%@: %@", self.username, error.localizedDescription);
}

@end

BOOL ApolloModernChatIsAvailable(void) {
    return ApolloActiveWebSession() != nil;
}

BOOL ApolloModernChatIsRequiredForActiveAccount(void) {
    // API-key-free synthesized RDKClient accounts deliberately carry an empty
    // authorizationCredential.clientIdentifier. Inspect the active client
    // itself instead of the global default API key, which may belong to a
    // different account in a mixed API/web-session setup.
    Class clientClass = objc_getClass("RDKClient");
    id client = [clientClass respondsToSelector:@selector(sharedClient)]
        ? ((id (*)(id, SEL))objc_msgSend)(clientClass, @selector(sharedClient)) : nil;
    id credential = [client respondsToSelector:@selector(authorizationCredential)]
        ? ((id (*)(id, SEL))objc_msgSend)(client, @selector(authorizationCredential)) : nil;
    NSString *clientIdentifier = [credential respondsToSelector:@selector(clientIdentifier)]
        ? ((id (*)(id, SEL))objc_msgSend)(credential, @selector(clientIdentifier)) : nil;
    return ApolloActiveWebSession() != nil && clientIdentifier.length == 0;
}

BOOL ApolloModernChatShouldOpen(void) {
    if (ApolloModernChatIsRequiredForActiveAccount()) return YES;
    return [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyUseModernRedditChat];
}

UIViewController *ApolloCreateModernChatViewController(void) {
    ApolloDirectChatWebViewController *controller = [ApolloDirectChatWebViewController new];
    // Apollo's translucent tab bar otherwise covers Reddit's composer and send
    // button. This must be set before the navigation push so UIKit reserves the
    // full chat screen and keyboard-safe bottom inset correctly.
    controller.hidesBottomBarWhenPushed = YES;
    return controller;
}

%ctor {
    ApolloLog(@"[DirectChatWeb] module loaded");
}
