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
#import "ApolloWebSessionLoginViewController.h"
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

// Theme Builder V2's typography choices are all Apple system designs. Convert
// the active UIFont design into its CSS system-family counterpart so the web
// clients follow the same per-theme font without bundling or downloading font
// files. Font weight and italic styling remain controlled by Reddit's markup.
static NSString *ApolloDirectChatThemeFontFamily(void) {
    UIFont *base = [UIFont systemFontOfSize:16.0];
    UIFont *active = ApolloThemeRuntimeFont(base) ?: base;
    NSString *identity = [NSString stringWithFormat:@"%@ %@",
                          active.fontName ?: @"", active.familyName ?: @""].lowercaseString;
    if ([identity containsString:@"rounded"]) {
        return @"ui-rounded,\"SF Pro Rounded\",-apple-system,BlinkMacSystemFont,sans-serif";
    }
    if ([identity containsString:@"newyork"] || [identity containsString:@"new york"] ||
        [identity containsString:@"serif"]) {
        return @"ui-serif,\"New York\",Georgia,serif";
    }
    if ([identity containsString:@"mono"]) {
        return @"ui-monospace,\"SF Mono\",Menlo,monospace";
    }
    return @"-apple-system,BlinkMacSystemFont,\"SF Pro Text\",\"Helvetica Neue\",sans-serif";
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
            @"font": ApolloDirectChatThemeFontFamily(),
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
        @"font": ApolloDirectChatThemeFontFamily(),
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
        NSMutableDictionary *merged = old ? [old mutableCopy] : [NSMutableDictionary dictionary];
        NSString *surface = [status[@"surface"] isKindOfClass:[NSString class]] ? status[@"surface"] : @"threads";
        BOOL routeUnread = [status[@"hasUnread"] boolValue];
        if ([surface isEqualToString:@"requests"]) {
            merged[@"hasRequests"] = @([status[@"hasRequests"] boolValue]);
        } else {
            merged[@"hasThreadUnread"] = @(routeUnread);
            merged[@"threadUnreadCount"] = [status[@"unreadCount"] isKindOfClass:[NSNumber class]]
                ? status[@"unreadCount"] : @0;
            if ([status[@"preview"] isKindOfClass:[NSString class]]) merged[@"preview"] = status[@"preview"];
            else [merged removeObjectForKey:@"preview"];
        }
        BOOL hasThreadUnread = [merged[@"hasThreadUnread"] boolValue];
        BOOL hasRequests = [merged[@"hasRequests"] boolValue];
        merged[@"hasUnread"] = @(hasThreadUnread || hasRequests);
        merged[@"checkedAt"] = status[@"checkedAt"] ?: @([[NSDate date] timeIntervalSince1970] * 1000.0);

        NSArray<NSString *> *meaningfulKeys = @[
            @"hasUnread", @"hasThreadUnread", @"hasRequests", @"threadUnreadCount", @"preview"
        ];
        BOOL changed = NO;
        for (NSString *key in meaningfulKeys) {
            id before = old[key];
            id after = merged[key];
            if ((before || after) && ![before isEqual:after]) {
                changed = YES;
                break;
            }
        }
        if (!changed) return;
        @synchronized (ApolloModernChatStatusLock()) {
            sApolloModernChatStatus = [merged copy];
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
        "window.__apolloChatPalette=palette;window.__apolloChatShadowRoots=window.__apolloChatShadowRoots||[];"
        "const roots=()=>{const out=[];const visit=r=>{if(!r||out.includes(r))return;out.push(r);for(const e of r.querySelectorAll('*'))if(e.shadowRoot)visit(e.shadowRoot);};visit(document);for(const r of window.__apolloChatShadowRoots)visit(r);return out;};"
        "const mailRoute=()=>location.pathname.startsWith('/mail/');"
        "const chatListRoute=()=>/^\\/chat\\/?$/.test(location.pathname);"
        // Reddit renders both mailbox surfaces smaller than Apollo's native
        // typography. Enlarge text through WebKit autosizing instead of page
        // zoom so rows still reflow at the real device width. Modmail stays more
        // conservative because its dense editor already has large controls;
        // Chat starts at 108% on compact phones and gradually reaches 116%.
        "const textScale=()=>{const w=document.documentElement?.clientWidth||innerWidth||375;if(mailRoute())return Math.min(112,Math.max(100,100+(w-350)*0.15));return Math.min(116,Math.max(108,108+(w-350)*0.12));};"
        // Reddit wraps the entire Modmail thread in p-md (roughly 17 points on
        // a current-size iPhone). Remove that artificial outer gutter so the
        // subject, messages, and composer use the whole screen. Preserve only
        // WebKit's real safe area on landscape/notched devices. Scope this by
        // route so the modern Chat layout remains untouched.
        // Reddit reserves 57 points for its own header even after we hide that
        // header. Zeroing the source variable lets every current mailbox shell
        // (including its nested shadow-root layout) fill the WKWebView without
        // imposing a fixed height that would fight the iOS keyboard viewport.
        "const mailLayout=()=>mailRoute()?':host,:root,shreddit-app{--shreddit-header-height:0px!important;--shreddit-header-large-height:0px!important;}#main-content.flex.gap-md.p-md{padding-left:env(safe-area-inset-left,0px)!important;padding-right:env(safe-area-inset-right,0px)!important;padding-bottom:0!important;box-sizing:border-box!important;}rpl-inbox-row .title{font-weight:600!important;color:var(--apollo-chat-text)!important;}':'';"
        // Reddit's Chat media button is the only composer control that combines
        // a touch tooltip with a native file-input chooser. Mobile WebKit can
        // leave that tooltip's :hover/:focus presentation stuck after the
        // chooser closes. RPL renders the body and arrow in two nested shadow
        // roots, so hiding only role=tooltip leaves a small black diamond above
        // the icon. Suppress both visual pieces on the touch-only Chat surface.
        // The :host(.tooltip) guard restricts the arrow rule to tooltip poppers;
        // menu/popover arrows and aria-label/aria-describedby stay untouched.
        "const chatTouchLayout=()=>mailRoute()?'':'@media (hover:none),(pointer:coarse){[role=tooltip],:host(.tooltip) .popup--arrow[part=arrow]{display:none!important;}}';"
        "const css=()=>`:host,:root{"
            "--apollo-chat-accent:${palette.accent};--apollo-chat-bg:${palette.primary};--apollo-chat-surface:${palette.secondary};--apollo-chat-raised:${palette.tertiary};--apollo-chat-border:${palette.separator};--apollo-chat-text:${palette.text};--apollo-chat-muted:${palette.secondaryText};--apollo-chat-font:${palette.font};"
            "--font-sans:var(--apollo-chat-font)!important;--font-family-sans:var(--apollo-chat-font)!important;font-family:var(--apollo-chat-font)!important;"
            "--color-neutral-background:${palette.primary}!important;--color-neutral-background-container:${palette.secondary}!important;--color-neutral-background-strong:${palette.secondary}!important;--color-neutral-background-strong-hover:${palette.tertiary}!important;--color-neutral-background-weak:${palette.tertiary}!important;--color-neutral-background-hover:${palette.tertiary}!important;--color-neutral-background-selected:${palette.tertiary}!important;--color-neutral-background-disabled:${palette.tertiary}!important;"
            "--color-neutral-border:${palette.separator}!important;--color-neutral-border-weak:${palette.separator}!important;--color-neutral-border-medium:${palette.separator}!important;--color-neutral-border-strong:${palette.separator}!important;--color-neutral-content:${palette.text}!important;--color-neutral-content-strong:${palette.text}!important;--color-neutral-content-weak:${palette.secondaryText}!important;--color-neutral-content-disabled:${palette.secondaryText}!important;"
            "--color-primary:${palette.accent}!important;--color-primary-hover:${palette.accent}!important;--color-primary-visited:${palette.accent}!important;--color-primary-background:${palette.accent}!important;--color-secondary:${palette.text}!important;--color-secondary-background:${palette.tertiary}!important;"
            "--color-tone-1:${palette.text}!important;--color-tone-2:${palette.secondaryText}!important;--color-tone-3:${palette.secondaryText}!important;--color-tone-4:${palette.separator}!important;--color-tone-5:${palette.tertiary}!important;--color-tone-6:${palette.secondary}!important;--color-tone-7:${palette.primary}!important;"
            "--newCommunityTheme-body:${palette.primary}!important;--newCommunityTheme-bodyText:${palette.text}!important;--newCommunityTheme-button:${palette.accent}!important;--newCommunityTheme-line:${palette.separator}!important;"
        "}html,body,button,input,textarea,select{font-family:var(--apollo-chat-font)!important;}html,body{background-color:var(--apollo-chat-bg)!important;color:var(--apollo-chat-text)!important;-webkit-text-size-adjust:${textScale()}%!important;text-size-adjust:${textScale()}%!important;}body{accent-color:var(--apollo-chat-accent)!important;}a{color:var(--apollo-chat-accent)!important;}input,textarea,[contenteditable=true]{caret-color:var(--apollo-chat-accent)!important;font-size:16px!important;}::selection{background:var(--apollo-chat-accent)!important;color:var(--apollo-chat-bg)!important;}"
        "shreddit-app{--page-y-padding:0px!important;padding-top:0!important;}header.v2.hui{display:none!important;}modmail-mailbox-wrapper{top:0!important;margin-top:0!important;}${mailLayout()}${chatTouchLayout()}`;"
        "const themeRoot=r=>{if(!r)return;let s=r.querySelector('style[data-apollo-chat-theme]');if(!s){s=document.createElement('style');s.setAttribute('data-apollo-chat-theme','');const target=r===document?(document.head||document.documentElement):r;if(!target)return;target.appendChild(s);}const next=css();if(s.textContent!==next)s.textContent=next;};"
        "let sweepScheduled=false;const scheduleSweep=()=>{if(sweepScheduled)return;sweepScheduled=true;requestAnimationFrame(()=>{sweepScheduled=false;window.__apolloChatEnhancementSweep?.();});};window.__apolloChatScheduleSweep=scheduleSweep;"
        // Tapping Send media currently lets Reddit focus the contenteditable
        // message field on pointer-down before it clicks the hidden file input.
        // iOS begins animating the keyboard, shrinks visualViewport, scrolls the
        // conversation, then immediately reverses all of that for the native
        // chooser. Mark only a genuine Send-media control gesture and blur only
        // text entries focused during that short gesture. The button click and
        // file input are never cancelled, so Photo Library / Camera / Files keep
        // running through Reddit's own implementation. Install this in every
        // captured shadow root too: current Chat nests the composer controls.
        "window.__apolloChatMediaGestureUntil=window.__apolloChatMediaGestureUntil||0;"
        "const mediaControlForEvent=event=>{if(mailRoute())return null;for(const node of event.composedPath?.()||[]){if(!(node instanceof Element)||!node.matches?.('button,[role=button]'))continue;const marker=[node.getAttribute('aria-label'),node.getAttribute('title'),node.getAttribute('data-testid'),node.getAttribute('data-control-name'),node.textContent].filter(Boolean).join(' ').replace(/\\s+/g,' ').trim().toLowerCase();if(marker.includes('send media')||/(^|[\\s_-])(media|image|photo)([\\s_-]|$)/.test(marker))return node;}return null;};"
        "const isChatTextEntry=node=>!!node?.matches?.('textarea,[contenteditable=true],[role=textbox],input:not([type=file]):not([type=button]):not([type=submit])');"
        "const deepActiveElement=root=>{let node=root?.activeElement||document.activeElement;while(node?.shadowRoot?.activeElement)node=node.shadowRoot.activeElement;return node;};"
        "const blurMediaGestureTextEntry=root=>{const active=deepActiveElement(root);if(!isChatTextEntry(active))return false;active.blur?.();return true;};"
        "const installChatInteractionHooks=root=>{if(!root||root.__apolloChatInteractionHooks)return;try{Object.defineProperty(root,'__apolloChatInteractionHooks',{value:true,configurable:true});const beginMediaGesture=event=>{const control=mediaControlForEvent(event);if(!control)return;window.__apolloChatMediaGestureUntil=Date.now()+1600;const title=control.getAttribute?.('title');if(title&&!control.hasAttribute('aria-label')&&!control.hasAttribute('aria-labelledby'))control.setAttribute('aria-label',title);control.removeAttribute?.('title');control.blur?.();blurMediaGestureTextEntry(root);queueMicrotask(()=>blurMediaGestureTextEntry(root));requestAnimationFrame(()=>blurMediaGestureTextEntry(root));};const rejectMediaGestureFocus=event=>{if(Date.now()>window.__apolloChatMediaGestureUntil)return;const target=event.composedPath?.()[0]||event.target;if(!isChatTextEntry(target))return;target.blur?.();queueMicrotask(()=>blurMediaGestureTextEntry(root));};root.addEventListener('pointerdown',beginMediaGesture,true);root.addEventListener('touchstart',beginMediaGesture,{capture:true,passive:true});root.addEventListener('click',beginMediaGesture,true);root.addEventListener('focusin',rejectMediaGestureFocus,true);}catch(e){console.debug('[ApolloFix][DirectChatWeb] Chat media interaction hook failed',e);}};"
        "const observeRoot=r=>{if(!r)return;installChatInteractionHooks(r);if(r.__apolloChatObserver)return;try{Object.defineProperty(r,'__apolloChatObserver',{value:new MutationObserver(()=>window.__apolloChatScheduleSweep?.()),configurable:true});r.__apolloChatObserver.observe(r,{childList:true,subtree:true});}catch(e){}};"
        "const themeRoots=()=>{for(const r of roots()){themeRoot(r);observeRoot(r);}};"
        // Patch attachShadow at document start. Reddit constructs the thread
        // composer as an SPA transition, so waiting for the periodic sweep
        // made its font and spacing visibly jump after the thread appeared.
        "window.__apolloChatNewShadowRoot=root=>{if(!window.__apolloChatShadowRoots.includes(root))window.__apolloChatShadowRoots.push(root);themeRoot(root);observeRoot(root);scheduleSweep();};"
        "if(!Element.prototype.__apolloChatOriginalAttachShadow){const original=Element.prototype.attachShadow;Object.defineProperty(Element.prototype,'__apolloChatOriginalAttachShadow',{value:original});Element.prototype.attachShadow=function(init){const root=original.call(this,init);window.__apolloChatNewShadowRoot?.(root);return root;};}"
        "const fixGiphy=()=>{let grids=0;for(const r of roots())for(const container of r.querySelectorAll('.gifs-container')){const media=[...container.querySelectorAll(':scope > img,:scope > video')];if(media.length<2)continue;container.setAttribute('data-apollo-giphy-grid','');container.style.setProperty('display','grid','important');container.style.setProperty('grid-template-columns','repeat(2,minmax(0,1fr))','important');container.style.setProperty('grid-auto-rows','104px','important');container.style.setProperty('gap','6px','important');container.style.setProperty('width','100%','important');container.style.setProperty('height','auto','important');container.style.setProperty('box-sizing','border-box','important');for(const m of media){m.style.setProperty('width','100%','important');m.style.setProperty('min-width','0','important');m.style.setProperty('height','104px','important');m.style.setProperty('max-width','none','important');m.style.setProperty('object-fit','cover','important');m.style.setProperty('margin','0','important');m.style.setProperty('overflow','hidden','important');m.style.setProperty('border-radius','10px','important');}grids++;}return grids;};"
        // Reddit appends each next GIPHY page to the existing dropdown, then
        // resets that same element's scrollTop to zero. Remember a recent real
        // scroll and restore it only when the results height has grown. Small
        // positions are allowed to reach zero normally, while closing/reopening
        // the picker or changing the search query clears the remembered state.
        "const giphyQuery=dropdown=>dropdown.querySelector('faceplate-search-input,input,textarea')?.value||'';"
        "const giphyScrollState=dropdown=>{let state=dropdown.__apolloGiphyScrollState;if(state)return state;state={top:0,height:dropdown.scrollHeight,at:0,query:giphyQuery(dropdown),open:false};Object.defineProperty(dropdown,'__apolloGiphyScrollState',{value:state,configurable:true});const reset=()=>{state.top=0;state.height=dropdown.scrollHeight;state.at=0;state.query=giphyQuery(dropdown);};dropdown.addEventListener('input',reset,true);dropdown.addEventListener('scroll',()=>{if(!state.open)return;const query=giphyQuery(dropdown);if(query!==state.query){reset();return;}const top=dropdown.scrollTop,height=dropdown.scrollHeight,now=Date.now();if(top>8){if(!state.at||now-state.at>5000||height<=state.height+20)state.height=height;state.top=top;state.at=now;}else if(top<=1&&state.top<=16){state.top=0;state.height=height;state.at=0;}window.__apolloChatScheduleSweep?.();},{passive:true});return state;};"
        "const fixGiphyScroll=()=>{let restored=0;for(const r of roots())for(const dropdown of r.querySelectorAll('.gifs-dropdown')){const state=giphyScrollState(dropdown),rect=dropdown.getBoundingClientRect(),style=getComputedStyle(dropdown),open=rect.width>0&&rect.height>0&&style.display!=='none'&&style.visibility!=='hidden',query=giphyQuery(dropdown),top=dropdown.scrollTop,height=dropdown.scrollHeight,now=Date.now();if(!open){state.open=false;continue;}if(!state.open||query!==state.query){state.open=true;state.query=query;state.top=top;state.height=height;state.at=top>8?now:0;continue;}if(top<=1&&state.top>16&&now-state.at<5000&&height>state.height+20){const target=Math.min(state.top,Math.max(0,height-dropdown.clientHeight));state.top=target;state.height=height;state.at=now;dropdown.scrollTop=target;restored++;}else if(top<=1&&state.at&&now-state.at>=5000){state.top=0;state.height=height;state.at=0;}}return restored;};"
        // Reddit's conversation-profile header combines its width and height
        // utility classes incorrectly for the stock square Snoovatar. Keep the
        // supplied height, but derive width from a 1:1 aspect ratio. Restrict
        // this to the large user-avatar wrapper and Reddit's default-avatar
        // path so custom avatars and every message/header avatar stay native.
        "const fixDefaultProfileAvatars=()=>{if(mailRoute())return 0;let fixed=0;for(const r of roots())for(const img of r.querySelectorAll('img')){let u;try{u=new URL(img.currentSrc||img.src,location.href);}catch(e){continue;}const redditStatic=u.hostname==='redditstatic.com'||u.hostname.endsWith('.redditstatic.com');if(!redditStatic||!u.pathname.startsWith('/avatars/defaults/'))continue;const avatar=img.closest('.user-avatar');if(!avatar)continue;const inner=img.parentElement,shell=inner?.parentElement;if(!inner||!shell||!avatar.contains(shell))continue;shell.style.setProperty('width','auto','important');shell.style.setProperty('aspect-ratio','1 / 1','important');shell.style.setProperty('flex','0 0 auto','important');inner.style.setProperty('width','100%','important');inner.style.setProperty('height','100%','important');img.style.setProperty('display','block','important');img.style.setProperty('width','100%','important');img.style.setProperty('height','100%','important');img.style.setProperty('aspect-ratio','1 / 1','important');img.style.setProperty('object-fit','cover','important');fixed++;}return fixed;};"
        // Reddit's Threads list hard-codes its semantic row text to 12px. At
        // iPhone width that still resolves to only 13.7 points after our page
        // text adjustment, noticeably smaller than Apollo and Reddit's own
        // conversation view. Enlarge only the stable list-row classes; room
        // messages keep their already-correct native sizing.
        "const fixChatListTypography=()=>{if(!chatListRoute())return 0;let fixed=0;for(const r of roots()){for(const e of r.querySelectorAll('.room-name')){e.style.setProperty('font-size','15px','important');e.style.setProperty('line-height','20px','important');fixed++;}for(const e of r.querySelectorAll('.last-message')){e.style.setProperty('font-size','14px','important');e.style.setProperty('line-height','20px','important');fixed++;}for(const e of r.querySelectorAll('.last-message-time')){e.style.setProperty('font-size','12px','important');e.style.setProperty('line-height','20px','important');fixed++;}}return fixed;};"
        // The embedded Inbox supplies native Messages / Requests / Threads
        // navigation. Reddit's root Chat list still renders its own header,
        // filter chips, and Requests / Threads rows above the first room. A
        // negative native crop made those rows invisible at rest but exposed
        // them during WebKit's restored edge bounce. Remove the redundant DOM
        // chrome instead, and repeat on every sweep in case Reddit virtualizes
        // or replaces the list after a status update.
        "const fixEmbeddedMessagesChrome=()=>{if(!window.__apolloEmbeddedInboxMessages||!chatListRoute())return 0;let hidden=0;const hide=e=>{if(!e)return;if(e.style.getPropertyValue('display')!=='none'||e.style.getPropertyPriority('display')!=='important'){e.style.setProperty('display','none','important');}hidden++;};for(const r of roots()){for(const e of r.querySelectorAll('li[data-testid=\"requests-button\"],li[data-testid=\"threads-button\"],rs-rooms-nav-filter-chips'))hide(e);if(r instanceof ShadowRoot&&r.host?.tagName==='RS-ROOMS-NAV'){const home=r.querySelector('a[aria-label=\"Go to Reddit home\"]');let header=home;while(header?.parentElement)header=header.parentElement;hide(header);}}return hidden;};"
        // Reddit disables scroll chaining on its virtualized list, which also
        // suppresses WebKit's edge stretch. Restore ordinary touch scrolling
        // on every actual overflow container. UIKit separately enables bounce
        // on the WKChildScrollView created for these elements after hydration.
        "const fixChatScrollPhysics=()=>{if(mailRoute())return 0;let fixed=0;for(const r of roots())for(const e of r.querySelectorAll('*')){const s=getComputedStyle(e),scrollable=(s.overflowY==='auto'||s.overflowY==='scroll')&&(e.scrollHeight>e.clientHeight+1);if(!scrollable&&e.tagName!=='RS-VIRTUAL-SCROLL'&&e.tagName!=='RS-THREADS-VIEW')continue;e.style.setProperty('overscroll-behavior-y','auto','important');e.style.setProperty('-webkit-overflow-scrolling','touch','important');fixed++;}return fixed;};"
        "const blockRedditHomeLogo=()=>{let blocked=0;for(const r of roots())for(const a of r.querySelectorAll('a[href]')){try{const u=new URL(a.href,location.href);if((u.hostname==='reddit.com'||u.hostname.endsWith('.reddit.com'))&&u.pathname==='/'&&u.search===''&&u.hash===''){const area=(a.parentElement?.textContent||'').trim().toLowerCase(),rect=a.getBoundingClientRect();if(area.includes('chats')||rect.top<180){a.setAttribute('aria-disabled','true');a.style.setProperty('pointer-events','none','important');a.style.setProperty('cursor','default','important');blocked++;}}}catch(e){}}return blocked;};"
        // Reddit currently leaves Preview genuinely disabled even after the
        // reply textarea contains text. Preserve its own preview renderer and
        // click handler; only repair the enabled state from the real input.
        "const fixModmailPreview=()=>{if(!mailRoute())return 0;const all=roots().flatMap(r=>[...r.querySelectorAll('*')]);const visible=e=>{const b=e.getBoundingClientRect(),s=getComputedStyle(e);return b.width>0&&b.height>0&&s.display!=='none'&&s.visibility!=='hidden';};const textarea=all.find(e=>e.tagName==='TEXTAREA'&&visible(e)&&e.type!=='hidden');const preview=all.find(e=>e.tagName==='BUTTON'&&(e.textContent||'').trim()==='Preview'&&visible(e));if(!textarea||!preview)return 0;const sync=()=>{const hasText=(textarea.value||'').trim().length>0;if(hasText){if(preview.disabled){preview.disabled=false;preview.removeAttribute('disabled');preview.style.setProperty('pointer-events','auto','important');preview.dataset.apolloPreviewEnabled='true';}}else if(preview.dataset.apolloPreviewEnabled==='true'){preview.disabled=true;preview.setAttribute('disabled','');preview.style.removeProperty('pointer-events');delete preview.dataset.apolloPreviewEnabled;}};if(!textarea.dataset.apolloPreviewListener){textarea.dataset.apolloPreviewListener='true';textarea.addEventListener('input',sync);textarea.addEventListener('change',sync);}sync();return preview.dataset.apolloPreviewEnabled==='true'?1:0;};"
        // The sticky Modmail subject card sits above Reddit's Markdown Help
        // dialog. Fit only that dialog into the actual visual viewport so its
        // close button and final help rows are both reachable on every iPhone.
        "const fitMarkdownHelp=()=>{if(!mailRoute())return 0;const all=roots().flatMap(r=>[...r.querySelectorAll('*')]);let fitted=0;for(const dialog of all.filter(e=>e.tagName==='FACEPLATE-MODAL'||e.getAttribute?.('role')==='dialog')){const text=(dialog.textContent||'').replace(/\\s+/g,' ').trim();if(!text.includes('Markdown Help')&&!text.includes('Markdown is a way to quickly format text'))continue;const viewport=Math.round(window.visualViewport?.height||window.innerHeight||0);let top=96;for(const e of all){if(e===dialog||dialog.contains(e))continue;const b=e.getBoundingClientRect(),label=(e.textContent||'').replace(/\\s+/g,' ').trim();if(label&&b.width>innerWidth*0.8&&b.height>=60&&b.height<=180&&b.top>=0&&b.top<=32&&b.bottom>top)top=Math.ceil(b.bottom+8);}top=Math.min(top,Math.max(96,viewport-220));const height=Math.max(212,viewport-top-8);dialog.style.setProperty('position','fixed','important');dialog.style.setProperty('top',top+'px','important');dialog.style.setProperty('right','12px','important');dialog.style.setProperty('bottom','auto','important');dialog.style.setProperty('left','12px','important');dialog.style.setProperty('width','auto','important');dialog.style.setProperty('height',height+'px','important');dialog.style.setProperty('max-height','none','important');dialog.style.setProperty('overflow','auto','important');dialog.style.setProperty('-webkit-overflow-scrolling','touch','important');dialog.style.setProperty('transform','none','important');dialog.style.setProperty('z-index','2147483647','important');dialog.style.setProperty('box-sizing','border-box','important');fitted++;}return fitted;};"
        "const sweep=()=>{themeRoots();const giphyGrids=fixGiphy();return {roots:roots().length,giphyGrids,giphyScrollRestores:fixGiphyScroll(),defaultProfileAvatars:fixDefaultProfileAvatars(),chatListTypography:fixChatListTypography(),embeddedMessagesChrome:fixEmbeddedMessagesChrome(),chatScrollers:fixChatScrollPhysics(),blockedHomeLinks:blockRedditHomeLogo(),previewFixes:fixModmailPreview(),markdownDialogs:fitMarkdownHelp()};};"
        "window.__apolloChatEnhancementSweep=sweep;"
        "if(!window.__apolloChatViewportHooks){window.__apolloChatViewportHooks=true;window.addEventListener('resize',()=>window.__apolloChatScheduleSweep?.());window.visualViewport?.addEventListener('resize',()=>window.__apolloChatScheduleSweep?.());document.addEventListener('DOMContentLoaded',()=>window.__apolloChatScheduleSweep?.(),{once:true});}"
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

// Reuse only the WebKit process pool for an unchanged active session. Reddit
// stores the Chat filter (Direct / Group) in website data, so sharing a data
// store made a Threads filter leak into Messages and standalone Chat. Each
// visible controller therefore keeps its own non-persistent cookie/data store;
// only the process is shared, and a username or cookie change creates a new
// process pool.
@interface ApolloModernMailboxWebContext : NSObject
@property (nonatomic, copy) NSString *username;
@property (nonatomic, copy) NSString *cookieHeader;
@property (nonatomic, strong) WKProcessPool *processPool;
@end

@implementation ApolloModernMailboxWebContext
@end

static ApolloModernMailboxWebContext *sApolloModernMailboxWebContext = nil;

static ApolloModernMailboxWebContext *ApolloModernMailboxContextForActiveSession(void) {
    ApolloWebSessionEntry *session = ApolloActiveWebSession();
    NSString *username = ApolloActiveWebSessionUsername().lowercaseString ?: @"";
    if (session.cookieHeader.length == 0) return nil;

    BOOL unchanged = [sApolloModernMailboxWebContext.username isEqualToString:username] &&
        [sApolloModernMailboxWebContext.cookieHeader isEqualToString:session.cookieHeader];
    if (unchanged) return sApolloModernMailboxWebContext;

    ApolloModernMailboxWebContext *context = [ApolloModernMailboxWebContext new];
    context.username = username;
    context.cookieHeader = session.cookieHeader;
    context.processPool = [WKProcessPool new];
    sApolloModernMailboxWebContext = context;
    ApolloLog(@"[DirectChatWeb] Created account-isolated reusable WebKit process pool for u/%@", username);
    return context;
}

static void ApolloSeedModernMailboxCookies(NSString *cookieHeader,
                                           WKHTTPCookieStore *store,
                                           dispatch_block_t completion) {
    NSDictionary<NSString *, NSString *> *pairs = ApolloDirectChatCookiePairs(cookieHeader ?: @"");
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
    dispatch_group_notify(group, dispatch_get_main_queue(), completion ?: ^{});
}

static NSString *ApolloModernMailboxUserAgent(void) {
    return @"Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1";
}

static void *ApolloDirectChatWebViewURLContext = &ApolloDirectChatWebViewURLContext;

typedef NS_ENUM(NSUInteger, ApolloModernMailboxKind) {
    ApolloModernMailboxKindChat = 0,
    ApolloModernMailboxKindModmail,
};

@interface ApolloDirectChatWebViewController : UIViewController <WKNavigationDelegate, WKUIDelegate>
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UIView *loadingView;
@property (nonatomic, strong) UILabel *loadingTitleLabel;
@property (nonatomic, strong) UILabel *loadingDetailLabel;
@property (nonatomic, strong) UIImageView *loadingIconView;
@property (nonatomic, strong) UIButton *reauthenticateButton;
@property (nonatomic, copy) NSString *username;
// A validated same-origin Reddit path supplied by a notification deep link.
// Keeping only the path (never an arbitrary URL) preserves the isolated
// cookie store's security boundary.
@property (nonatomic, copy) NSString *initialDestinationPath;
@property (nonatomic, assign) BOOL didRevealChat;
@property (nonatomic, assign) NSUInteger readinessGeneration;
@property (nonatomic, assign) BOOL modmailThreadTransitionPending;
@property (nonatomic, assign) NSUInteger modmailThreadTransitionGeneration;
// A fresh, isolated WKWebView can leave Reddit's Modmail bundle waiting
// forever when /mail/all is its very first document. Prime the authenticated
// reddit.com client through the known-good Chat route, then replace it with
// Modmail before revealing anything to the user.
@property (nonatomic, assign) BOOL modmailWarmupPending;
@property (nonatomic, strong) UIColor *originalNavigationTintColor;
@property (nonatomic, assign) BOOL didCaptureOriginalNavigationTintColor;
@property (nonatomic, assign) ApolloModernMailboxKind mailboxKind;
// A native Reddit destination opened from this mailbox lives in a different
// tab's navigation controller. This flag marks the temporary return path.
@property (nonatomic, assign) BOOL nativeReturnPathActive;
// Missing/expired web sessions are recoverable in place. Keep the prompt state
// on the mailbox controller so an automatic first offer never turns into a
// cancel/re-present loop; the visible button remains available for later retry.
@property (nonatomic, assign) BOOL authenticationRequired;
@property (nonatomic, assign) BOOL authenticationPromptVisible;
@property (nonatomic, assign) BOOL authenticationPromptAutomaticallyOffered;
// The All Inbox owns the visible tabs and navigation chrome. In embedded mode
// the web controller supplies only the conversation content beneath them.
@property (nonatomic, assign) BOOL embeddedInInbox;
@property (nonatomic, assign) ApolloModernChatInboxSection embeddedInboxSection;
@property (nonatomic, strong) NSLayoutConstraint *webViewTopConstraint;
@property (nonatomic, strong) NSLayoutConstraint *webViewBottomConstraint;
@property (nonatomic, strong) ApolloModernMailboxWebContext *webContext;
@property (nonatomic, strong) NSDate *loadStartedAt;
@property (nonatomic, assign) NSUInteger bounceConfiguredScrollViewCount;
@property (nonatomic, assign) CGFloat lastAppliedBottomScrollAllowance;
@property (nonatomic, assign) NSUInteger bottomScrollAllowanceGeneration;
- (BOOL)apollo_urlMatchesMailboxRoute:(NSURL *)url;
- (BOOL)apollo_isModmailConversationURL:(NSURL *)url;
- (void)apollo_beginModmailThreadTransitionToURL:(NSURL *)url;
- (void)apollo_waitForModmailThreadStabilityAttempt:(NSUInteger)attempt
                                         generation:(NSUInteger)generation
                                      lastSignature:(NSString *)lastSignature
                                      stableSamples:(NSUInteger)stableSamples;
- (void)apollo_finishModmailThreadTransitionForGeneration:(NSUInteger)generation;
- (void)apollo_revealChat;
- (void)apollo_routeURLOutsideMailbox:(NSURL *)url;
- (void)apollo_prepareForMailboxReturnAnimated:(BOOL)animated;
- (void)apollo_showAuthenticationError:(NSString *)detail automaticallyPrompt:(BOOL)automaticallyPrompt;
- (void)apollo_presentAuthenticationPrompt;
- (void)apollo_showEmbeddedInboxSection:(ApolloModernChatInboxSection)section;
- (void)apollo_clearEmbeddedChatTypeFiltersForGeneration:(NSUInteger)generation
                                               completion:(void (^)(BOOL changed))completion;
- (void)apollo_applyEmbeddedInboxFilterAttempt:(NSUInteger)attempt generation:(NSUInteger)generation;
- (void)apollo_alignEmbeddedMessagesForGeneration:(NSUInteger)generation
                                        completion:(dispatch_block_t)completion;
- (void)apollo_alignEmbeddedThreadsForGeneration:(NSUInteger)generation
                                       completion:(dispatch_block_t)completion;
- (void)apollo_updateEmbeddedWebChromeForURL:(NSURL *)url;
- (void)apollo_enableNativeScrollBounce;
- (void)apollo_applyEmbeddedBottomScrollAllowance:(CGFloat)bottomAllowance;
@end

// A CSS overflow scroller inside WKWebView is represented by a private
// WKChildScrollView that does not exist yet when the WKWebView itself is
// created. Configuring only webView.scrollView therefore leaves Reddit's real
// conversation list with a hard edge. Walk the public UIView hierarchy and
// apply normal iOS bounce behavior to every scroll view after hydration too.
//
static NSUInteger ApolloConfigureEmbeddedScrollViews(UIView *view) {
    if (!view) return 0;
    NSUInteger configured = 0;
    if ([view isKindOfClass:[UIScrollView class]]) {
        UIScrollView *scrollView = (UIScrollView *)view;
        scrollView.bounces = YES;
        scrollView.alwaysBounceVertical = YES;
        configured += 1;
    }
    for (UIView *subview in view.subviews) {
        configured += ApolloConfigureEmbeddedScrollViews(subview);
    }
    return configured;
}

static NSString *ApolloValidatedModernMailboxPath(ApolloModernMailboxKind kind,
                                                   NSString *candidate) {
    if (![candidate isKindOfClass:[NSString class]] || candidate.length == 0) return nil;

    NSString *decoded = [candidate stringByRemovingPercentEncoding] ?: candidate;
    if (![decoded hasPrefix:@"/"] || [decoded hasPrefix:@"//"] ||
        [decoded containsString:@"\\"] || [decoded containsString:@".."] ||
        [decoded containsString:@"?"] || [decoded containsString:@"#"]) {
        return nil;
    }

    BOOL valid = kind == ApolloModernMailboxKindModmail
        ? ([decoded isEqualToString:@"/mail"] || [decoded hasPrefix:@"/mail/"])
        : ([decoded isEqualToString:@"/chat"] || [decoded hasPrefix:@"/chat/"]);
    return valid ? decoded : nil;
}

static const void *kApolloMailboxReturnControllerKey = &kApolloMailboxReturnControllerKey;
static const void *kApolloMailboxReturnAnchorKey = &kApolloMailboxReturnAnchorKey;

static ApolloDirectChatWebViewController *ApolloMailboxReturnController(UINavigationController *navigationController) {
    return objc_getAssociatedObject(navigationController, kApolloMailboxReturnControllerKey);
}

static UIViewController *ApolloMailboxReturnAnchor(UINavigationController *navigationController) {
    return objc_getAssociatedObject(navigationController, kApolloMailboxReturnAnchorKey);
}

static void ApolloClearMailboxReturn(UINavigationController *navigationController) {
    ApolloDirectChatWebViewController *mailbox = ApolloMailboxReturnController(navigationController);
    mailbox.nativeReturnPathActive = NO;
    objc_setAssociatedObject(navigationController, kApolloMailboxReturnControllerKey,
                             nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(navigationController, kApolloMailboxReturnAnchorKey,
                             nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloStoreMailboxReturn(UINavigationController *navigationController,
                                     ApolloDirectChatWebViewController *mailbox,
                                     UIViewController *anchor) {
    ApolloClearMailboxReturn(navigationController);
    mailbox.nativeReturnPathActive = YES;
    mailbox.hidesBottomBarWhenPushed = YES;
    objc_setAssociatedObject(navigationController, kApolloMailboxReturnControllerKey,
                             mailbox, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(navigationController, kApolloMailboxReturnAnchorKey,
                             anchor, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL ApolloReturnToMailboxFromNavigationController(UINavigationController *navigationController) {
    ApolloDirectChatWebViewController *mailbox = ApolloMailboxReturnController(navigationController);
    UINavigationController *mailboxNavigationController = mailbox.navigationController;
    UITabBarController *tabBarController = navigationController.tabBarController ?: mailbox.tabBarController;
    if (!mailbox || !mailboxNavigationController || !tabBarController ||
        ![mailboxNavigationController.viewControllers containsObject:mailbox]) {
        ApolloClearMailboxReturn(navigationController);
        return NO;
    }

    ApolloClearMailboxReturn(navigationController);
    [mailbox apollo_prepareForMailboxReturnAnimated:NO];
    tabBarController.selectedViewController = mailboxNavigationController;
    ApolloLog(@"[DirectChatWeb] Native Back returned to preserved %@ without mutating Inbox navigation",
              mailbox.mailboxKind == ApolloModernMailboxKindModmail ? @"Modmail" : @"Chat");
    return YES;
}

@implementation ApolloDirectChatWebViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.mailboxKind == ApolloModernMailboxKindModmail ? @"Moderator Mail" : @"Reddit Chat";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.view.clipsToBounds = YES;

    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    self.webContext = ApolloModernMailboxContextForActiveSession();
    // Each controller gets a fresh private data store. Reusing that store made
    // Reddit's selected Group chip survive when navigating from Threads to
    // Messages, which is both confusing and capable of hiding real messages.
    configuration.websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore;
    configuration.processPool = self.webContext.processPool ?: [WKProcessPool new];
    self.webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:configuration];
    self.webView.customUserAgent = ApolloModernMailboxUserAgent();
    self.webView.navigationDelegate = self;
    self.webView.UIDelegate = self;
    [self.webView addObserver:self
                  forKeyPath:@"URL"
                     options:NSKeyValueObservingOptionNew
                     context:ApolloDirectChatWebViewURLContext];
    self.webView.translatesAutoresizingMaskIntoConstraints = NO;
    self.webView.allowsBackForwardNavigationGestures = YES;
    self.webView.opaque = YES;
    self.webView.backgroundColor = UIColor.systemBackgroundColor;
    self.webView.scrollView.backgroundColor = UIColor.systemBackgroundColor;
    self.webView.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    // WKWebView only enables the familiar iOS stretch/bounce when content is
    // taller than its frame by default. Chat's empty and short lists should
    // still feel native when pulled at either edge.
    self.webView.scrollView.bounces = YES;
    self.webView.scrollView.alwaysBounceVertical = YES;
    // Keep Reddit's asynchronous Chat bootstrap hidden; only reveal the mobile
    // Chat document after its request list or composer has actually hydrated.
    self.webView.alpha = 0.0;
    self.webView.userInteractionEnabled = NO;
    [self.view addSubview:self.webView];
    // The parent Inbox view already ends below its native controls and above
    // Apollo's tab bar. Use those exact embedded bounds rather than adding a
    // second safe-area inset. On Messages, crop Reddit's redundant Chats,
    // Requests, and Threads navigation rows so the first conversation begins
    // beneath Apollo's tabs. The dedicated Threads route contains real reply
    // threads and is not cropped. Conversation rooms retain their web header
    // because it contains the participant and Back control.
    NSLayoutYAxisAnchor *webTopAnchor = self.embeddedInInbox
        ? self.view.topAnchor : self.view.safeAreaLayoutGuide.topAnchor;
    NSLayoutYAxisAnchor *webBottomAnchor = self.embeddedInInbox
        ? self.view.bottomAnchor : self.view.safeAreaLayoutGuide.bottomAnchor;
    CGFloat initialTopOffset = 0.0;
    if (self.embeddedInInbox) {
        // Requests has a useful "Additional requests" row and empty state just
        // below its duplicate title, while Messages has a much taller
        // Chats/Requests/Threads header. The Messages value is only a safe
        // fallback; after hydration we measure its first real row precisely.
        if (self.embeddedInboxSection == ApolloModernChatInboxSectionRequests) {
            initialTopOffset = -54.0;
        } else if (self.embeddedInboxSection == ApolloModernChatInboxSectionThreads) {
            initialTopOffset = 8.0;
        } else {
            initialTopOffset = -213.0;
        }
    }
    self.webViewTopConstraint = [self.webView.topAnchor constraintEqualToAnchor:webTopAnchor
                                                                        constant:initialTopOffset];
    self.webViewBottomConstraint = [self.webView.bottomAnchor
        constraintEqualToAnchor:webBottomAnchor];
    [NSLayoutConstraint activateConstraints:@[
        [self.webView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.webView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        // Keep Reddit's conversation composer below Apollo's navigation bar
        // and above the home indicator/keyboard instead of drawing underneath
        // either chrome surface.
        self.webViewTopConstraint,
        self.webViewBottomConstraint,
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

    NSString *iconName = self.mailboxKind == ApolloModernMailboxKindModmail
        ? @"shield.lefthalf.filled" : @"bubble.left.and.bubble.right.fill";
    UIImageView *iconView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:iconName]];
    self.loadingIconView = iconView;
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    iconView.tintColor = [UIColor colorWithRed:0.93 green:0.12 blue:0.76 alpha:1.0];
    [NSLayoutConstraint activateConstraints:@[
        [iconView.widthAnchor constraintEqualToConstant:46.0],
        [iconView.heightAnchor constraintEqualToConstant:46.0],
    ]];

    self.loadingTitleLabel = [UILabel new];
    self.loadingTitleLabel.text = self.mailboxKind == ApolloModernMailboxKindModmail
        ? @"Opening Moderator Mail" : @"Opening Reddit Chat";
    self.loadingTitleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    self.loadingTitleLabel.textColor = UIColor.labelColor;
    self.loadingTitleLabel.textAlignment = NSTextAlignmentCenter;

    self.loadingDetailLabel = [UILabel new];
    self.loadingDetailLabel.text = @"Preparing your private session…";
    self.loadingDetailLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    self.loadingDetailLabel.textColor = UIColor.secondaryLabelColor;
    self.loadingDetailLabel.textAlignment = NSTextAlignmentCenter;
    self.loadingDetailLabel.numberOfLines = 2;

    self.reauthenticateButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.reauthenticateButton.hidden = YES;
    self.reauthenticateButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    self.reauthenticateButton.layer.cornerRadius = 12.0;
    self.reauthenticateButton.layer.borderWidth = 1.0;
    self.reauthenticateButton.contentEdgeInsets = UIEdgeInsetsMake(11.0, 22.0, 11.0, 22.0);
    [self.reauthenticateButton setTitle:@"Sign In Again" forState:UIControlStateNormal];
    [self.reauthenticateButton addTarget:self
                                  action:@selector(apollo_presentAuthenticationPrompt)
                        forControlEvents:UIControlEventTouchUpInside];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    UIStackView *loadingStack = [[UIStackView alloc] initWithArrangedSubviews:@[
        iconView, self.loadingTitleLabel, self.loadingDetailLabel, self.spinner,
        self.reauthenticateButton
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

    if (!self.embeddedInInbox) {
        UIBarButtonItem *reload = [[UIBarButtonItem alloc]
            initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(apollo_reloadChat)];
        self.navigationItem.rightBarButtonItem = reload;
    }
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(apollo_activeThemeChanged:)
                                                 name:@"com.christianselig.ApolloSpecificThemeChanged"
                                               object:nil];
    [self apollo_applyActiveTheme];
    [self apollo_seedAndLoad];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self apollo_updateEmbeddedWebChromeForURL:self.webView.URL];
    [self apollo_enableNativeScrollBounce];
}

- (void)apollo_enableNativeScrollBounce {
    CGFloat bottomAllowance = 0.0;
    UITabBar *tabBar = self.tabBarController.tabBar;
    if (self.embeddedInInbox && tabBar && !tabBar.hidden && tabBar.alpha > 0.01 &&
        tabBar.window && self.webView.window) {
        CGRect tabBarFrame = [tabBar convertRect:tabBar.bounds toView:self.webView];
        CGFloat overlap = CGRectGetMaxY(self.webView.bounds) - CGRectGetMinY(tabBarFrame);
        if (overlap > 0.0) bottomAllowance = overlap + 12.0;
    }
    NSUInteger configured = ApolloConfigureEmbeddedScrollViews(self.webView);
    BOOL countChanged = configured != self.bounceConfiguredScrollViewCount;
    BOOL allowanceChanged = fabs(bottomAllowance - self.lastAppliedBottomScrollAllowance) > 0.5;
    BOOL generationChanged = self.bottomScrollAllowanceGeneration != self.readinessGeneration;
    self.bounceConfiguredScrollViewCount = configured;
    self.lastAppliedBottomScrollAllowance = bottomAllowance;
    self.bottomScrollAllowanceGeneration = self.readinessGeneration;
    if (bottomAllowance > 0.0 && (countChanged || allowanceChanged || generationChanged)) {
        [self apollo_applyEmbeddedBottomScrollAllowance:bottomAllowance];
    }
    if (countChanged || allowanceChanged || generationChanged) {
        ApolloLog(@"[DirectChatWeb] Enabled Apollo-style bounce on %lu WebKit scroll view(s), bottom allowance %.1fpt",
                  (unsigned long)configured, bottomAllowance);
    }
}

// WKChildScrollView accepts bounces, but WebKit immediately resets its native
// contentInset to zero because the scroll range belongs to a CSS overflow
// element. Add the measured tab-bar overlap to Reddit's actual virtual scroller
// instead. This increases scrollHeight, so the final Threads reply composer can
// move completely above Apollo's floating tab bar. Keep Reddit's own padding
// as the base in case its mobile layout changes later.
- (void)apollo_applyEmbeddedBottomScrollAllowance:(CGFloat)bottomAllowance {
    if (!self.embeddedInInbox || bottomAllowance <= 0.0) return;
    NSString *script = [NSString stringWithFormat:
        @"(()=>{const roots=[];const visit=r=>{if(!r||roots.includes(r))return;roots.push(r);for(const e of r.querySelectorAll('*'))if(e.shadowRoot)visit(e.shadowRoot);};visit(document);"
         "const visible=e=>{const b=e.getBoundingClientRect(),s=getComputedStyle(e);return b.width>0&&b.height>0&&s.display!=='none'&&s.visibility!=='hidden';};"
         "let applied=0;for(const e of roots.flatMap(r=>[...r.querySelectorAll('rs-virtual-scroll-dynamic')])){if(!visible(e))continue;"
         "if(e.dataset.apolloNativePaddingBottom===undefined)e.dataset.apolloNativePaddingBottom=String(parseFloat(getComputedStyle(e).paddingBottom)||0);"
         "const total=(parseFloat(e.dataset.apolloNativePaddingBottom)||0)+%.1f;"
         "e.style.setProperty('padding-bottom',total+'px','important');"
         "e.style.setProperty('scroll-padding-bottom',total+'px','important');applied++;}return applied;})()",
         bottomAllowance];
    [self.webView evaluateJavaScript:script completionHandler:nil];
}

- (void)dealloc {
    [self.webView removeObserver:self
                     forKeyPath:@"URL"
                        context:ApolloDirectChatWebViewURLContext];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey, id> *)change
                       context:(void *)context {
    if (context == ApolloDirectChatWebViewURLContext) {
        id nextValue = change[NSKeyValueChangeNewKey];
        NSURL *url = [nextValue isKindOfClass:[NSURL class]]
            ? nextValue : self.webView.URL;
        [self apollo_updateEmbeddedWebChromeForURL:url];
        return;
    }
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

- (void)viewWillAppear:(BOOL)animated {
    if (self.nativeReturnPathActive) {
        [self apollo_prepareForMailboxReturnAnimated:animated];
    }
    [super viewWillAppear:animated];
    [self apollo_applyActiveTheme];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.authenticationRequired && !self.authenticationPromptAutomaticallyOffered) {
        [self apollo_presentAuthenticationPrompt];
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    if (self.mailboxKind == ApolloModernMailboxKindChat) [self apollo_captureChatStatus];
    [super viewWillDisappear:animated];
    if (!self.embeddedInInbox && self.didCaptureOriginalNavigationTintColor) {
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
    // UINavigationBar is shared by Apollo's whole navigation stack. Capture
    // its actual pre-chat value before the first theme application mutates it,
    // including a legitimate nil/default tint, so popping is a true restore.
    if (!self.embeddedInInbox && !self.didCaptureOriginalNavigationTintColor && self.navigationController) {
        self.originalNavigationTintColor = self.navigationController.navigationBar.tintColor;
        self.didCaptureOriginalNavigationTintColor = YES;
        ApolloLog(@"[DirectChatWeb] Captured original navigation tint before applying mailbox theme");
    }

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
    [self.reauthenticateButton setTitleColor:accent forState:UIControlStateNormal];
    self.reauthenticateButton.backgroundColor = [accent colorWithAlphaComponent:0.14];
    self.reauthenticateButton.layer.borderColor = [accent colorWithAlphaComponent:0.45].CGColor;
    if (!self.embeddedInInbox) {
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
    }

    // Install the palette/layout hook before Reddit creates any SPA shadow
    // roots. The same source is evaluated below for the current document so a
    // live Theme Builder change is immediate as well as flash-free on the next
    // navigation.
    WKUserContentController *contentController = self.webView.configuration.userContentController;
    [contentController removeAllUserScripts];
    [contentController addUserScript:[[WKUserScript alloc]
        initWithSource:ApolloDirectChatEnhancementScript(palette)
        injectionTime:WKUserScriptInjectionTimeAtDocumentStart
        forMainFrameOnly:YES]];

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
    self.loadStartedAt = [NSDate date];
    self.authenticationRequired = NO;
    self.authenticationPromptAutomaticallyOffered = NO;
    self.reauthenticateButton.hidden = YES;
    self.didRevealChat = NO;
    self.readinessGeneration += 1;
    self.modmailThreadTransitionPending = NO;
    self.modmailThreadTransitionGeneration += 1;
    if (self.mailboxKind == ApolloModernMailboxKindModmail) {
        self.loadingTitleLabel.text = @"Opening Moderator Mail";
    } else if (self.embeddedInInbox) {
        switch (self.embeddedInboxSection) {
            case ApolloModernChatInboxSectionRequests:
                self.loadingTitleLabel.text = @"Opening Requests";
                break;
            case ApolloModernChatInboxSectionThreads:
                self.loadingTitleLabel.text = @"Opening Threads";
                break;
            case ApolloModernChatInboxSectionMessages:
            default:
                self.loadingTitleLabel.text = @"Opening Messages";
                break;
        }
    } else {
        self.loadingTitleLabel.text = @"Opening Reddit Chat";
    }
    self.loadingDetailLabel.text = detail.length ? detail : @"Preparing your private session…";
    self.loadingView.hidden = NO;
    self.loadingView.alpha = 1.0;
    self.webView.alpha = 0.0;
    self.webView.userInteractionEnabled = NO;
    [self.spinner startAnimating];

    // WebKit can occasionally stop delivering navigation callbacks after a
    // cancelled authentication flow or an unresponsive Reddit web process.
    // A retryable error is always better than a permanent activity indicator.
    NSUInteger generation = self.readinessGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(25.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || self.didRevealChat || generation != self.readinessGeneration) return;
        NSString *surface = self.mailboxKind == ApolloModernMailboxKindModmail ? @"Moderator Mail" : @"Reddit Chat";
        ApolloLog(@"[DirectChatWeb] %@ loading watchdog fired", surface);
        [self.webView stopLoading];
        [self apollo_showLoadError:[NSString stringWithFormat:@"%@ took too long to respond. Tap refresh to try again.", surface]];
    });
}

- (void)apollo_showLoadError:(NSString *)detail {
    self.authenticationRequired = NO;
    self.reauthenticateButton.hidden = YES;
    self.readinessGeneration += 1;
    self.modmailThreadTransitionPending = NO;
    self.modmailThreadTransitionGeneration += 1;
    self.modmailWarmupPending = NO;
    self.loadingView.hidden = NO;
    self.loadingView.alpha = 1.0;
    self.loadingTitleLabel.text = self.mailboxKind == ApolloModernMailboxKindModmail
        ? @"Moderator Mail couldn’t be opened" : @"Chat couldn’t be opened";
    self.loadingDetailLabel.text = detail ?: @"Try refreshing or signing in again.";
    [self.spinner stopAnimating];
}

- (void)apollo_showAuthenticationError:(NSString *)detail automaticallyPrompt:(BOOL)automaticallyPrompt {
    [self apollo_showLoadError:detail];
    self.authenticationRequired = YES;
    self.reauthenticateButton.hidden = NO;
    if (automaticallyPrompt && !self.authenticationPromptAutomaticallyOffered && self.view.window) {
        [self apollo_presentAuthenticationPrompt];
    }
}

- (void)apollo_presentAuthenticationPrompt {
    if (!self.authenticationRequired || self.authenticationPromptVisible) return;
    self.authenticationPromptVisible = YES;
    self.authenticationPromptAutomaticallyOffered = YES;

    NSString *targetUsername = ApolloActiveAccountUsername() ?: self.username;
    __weak typeof(self) weakSelf = self;
    [ApolloWebSessionLoginViewController
        presentExpiredSessionPromptForUsername:targetUsername
                                    completion:^(BOOL success) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        self.authenticationPromptVisible = NO;
        if (!success || !self.authenticationRequired) return;

        ApolloWebSessionEntry *activeSession = ApolloActiveWebSession();
        if (activeSession.cookieHeader.length > 0) {
            ApolloLog(@"[DirectChatWeb] Re-authentication completed for the active account; retrying %@ in place",
                      self.mailboxKind == ApolloModernMailboxKindModmail ? @"Modmail" : @"Chat");
            [self apollo_seedAndLoad];
            return;
        }

        NSString *active = ApolloActiveAccountUsername();
        NSString *detail = active.length > 0
            ? [NSString stringWithFormat:@"That sign-in did not match u/%@. Tap below and sign in with that Reddit account.", active]
            : @"That sign-in did not match the active Apollo account. Switch accounts or try signing in again.";
        [self apollo_showAuthenticationError:detail automaticallyPrompt:NO];
        ApolloLog(@"[DirectChatWeb] Re-authentication harvested a different account; active account still has no web session");
    }];
}

- (BOOL)apollo_isModmailConversationURL:(NSURL *)url {
    if (self.mailboxKind != ApolloModernMailboxKindModmail || !url) return NO;
    NSString *host = url.host.lowercaseString ?: @"";
    BOOL redditHost = [host isEqualToString:@"reddit.com"] || [host hasSuffix:@".reddit.com"];
    if (!redditHost) return NO;

    // List routes are /mail/<folder>; a real conversation adds its opaque ID
    // as the third non-empty path component (/mail/all/3jbwht).
    NSUInteger componentCount = 0;
    for (NSString *component in [url.path componentsSeparatedByString:@"/"]) {
        if (component.length > 0) componentCount += 1;
    }
    return componentCount >= 3 && [url.path hasPrefix:@"/mail/"];
}

- (void)apollo_beginModmailThreadTransitionToURL:(NSURL *)url {
    if (![self apollo_isModmailConversationURL:url]) return;
    if (self.modmailThreadTransitionPending) return;

    self.modmailThreadTransitionGeneration += 1;
    self.modmailThreadTransitionPending = YES;
    self.webView.userInteractionEnabled = NO;
    // Leave Apollo's navigation bar in place and cover only Reddit's document
    // with the already-themed native background. The user sees one stable
    // surface rather than Reddit's placeholder avatars, partial messages, and
    // several automatic scroll corrections.
    [UIView performWithoutAnimation:^{ self.webView.alpha = 0.0; }];
    ApolloLog(@"[DirectChatWeb] Covering Modmail conversation while it hydrates: %@", url.path);
}

- (void)apollo_finishModmailThreadTransitionForGeneration:(NSUInteger)generation {
    if (!self.modmailThreadTransitionPending ||
        generation != self.modmailThreadTransitionGeneration) return;
    BOOL initialNotificationDestination = !self.didRevealChat;
    self.modmailThreadTransitionPending = NO;
    self.webView.userInteractionEnabled = YES;
    if (initialNotificationDestination) {
        // Exact-thread notification links arrive before the mailbox has ever
        // been revealed. Reuse the normal reveal path so it removes the native
        // loading cover as well as exposing the now-stable web document.
        [self apollo_revealChat];
    } else {
        [UIView performWithoutAnimation:^{ self.webView.alpha = 1.0; }];
    }
    ApolloLog(@"[DirectChatWeb] Revealed stable Modmail conversation");
}

- (void)apollo_waitForModmailThreadStabilityAttempt:(NSUInteger)attempt
                                         generation:(NSUInteger)generation
                                      lastSignature:(NSString *)lastSignature
                                      stableSamples:(NSUInteger)stableSamples {
    if (!self.modmailThreadTransitionPending ||
        generation != self.modmailThreadTransitionGeneration) return;

    // A Modmail navigation finishes before its web components, message data,
    // lazy avatars, composer, and final scroll position finish settling. Probe
    // the document's real structure and geometry. Six identical ready samples
    // keep the cover up across the rapid hydration passes visible in recordings
    // while avoiding a fixed delay on already-cached conversations.
    NSString *script =
        @"(()=>{const roots=[];const visit=r=>{if(!r||roots.includes(r))return;roots.push(r);for(const e of r.querySelectorAll('*'))if(e.shadowRoot)visit(e.shadowRoot);};visit(document);"
         "const all=roots.flatMap(r=>[...r.querySelectorAll('*')]);const rect=e=>{const b=e?.getBoundingClientRect?.();return b?[Math.round(b.x),Math.round(b.y),Math.round(b.width),Math.round(b.height)]:[];};"
         "const thread=all.find(e=>e.tagName==='MODMAIL-THREAD-WRAPPER');const composer=all.find(e=>e.tagName==='SHREDDIT-COMPOSER');const textarea=all.find(e=>e.tagName==='TEXTAREA'&&e.getBoundingClientRect().height>0);"
         "const images=all.filter(e=>e.tagName==='IMG'&&e.getBoundingClientRect().width>0&&e.getBoundingClientRect().height>0);const imagesReady=images.every(e=>e.complete&&e.naturalWidth>0&&e.naturalHeight>0);"
         "const fontsReady=!document.fonts||document.fonts.status==='loaded';const scrolling=document.scrollingElement;const text=(document.body?.innerText||'').replace(/\\s+/g,' ').trim();"
         "const ready=document.readyState==='complete'&&!!thread&&!!composer&&!!textarea&&imagesReady&&fontsReady;"
         "const signature=[all.length,text.length,scrolling?.scrollTop||0,scrolling?.scrollHeight||0,document.body?.scrollHeight||0,rect(thread).join(','),rect(composer).join(','),images.map(e=>[e.naturalWidth,e.naturalHeight,rect(e).join(',')].join(':')).join(';')].join('|');"
         "return {ready,signature};})()";

    __weak typeof(self) weakSelf = self;
    [self.webView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || !self.modmailThreadTransitionPending ||
            generation != self.modmailThreadTransitionGeneration) return;

        BOOL ready = !error && [result isKindOfClass:[NSDictionary class]] && [result[@"ready"] boolValue];
        NSString *signature = ready && [result[@"signature"] isKindOfClass:[NSString class]]
            ? result[@"signature"] : nil;
        NSUInteger nextStableSamples = ready && signature.length > 0 &&
            [signature isEqualToString:lastSignature] ? stableSamples + 1 : 0;
        if (ready && nextStableSamples >= 6) {
            [self apollo_finishModmailThreadTransitionForGeneration:generation];
            return;
        }
        if (attempt >= 49) {
            ApolloLog(@"[DirectChatWeb] Modmail conversation stability probe timed out; revealing final available layout");
            [self apollo_finishModmailThreadTransitionForGeneration:generation];
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self apollo_waitForModmailThreadStabilityAttempt:attempt + 1
                                                   generation:generation
                                                lastSignature:signature
                                                stableSamples:nextStableSamples];
        });
    }];
}

- (void)apollo_revealChat {
    BOOL expectedRoute = [self apollo_urlMatchesMailboxRoute:self.webView.URL];
    if (self.didRevealChat || !expectedRoute) return;
    self.didRevealChat = YES;
    [self.spinner stopAnimating];
    self.webView.userInteractionEnabled = YES;
    [UIView animateWithDuration:0.22 animations:^{
        self.webView.alpha = 1.0;
        self.loadingView.alpha = 0.0;
    } completion:^(BOOL finished) {
        self.loadingView.hidden = YES;
    }];
    NSString *surface = self.mailboxKind == ApolloModernMailboxKindModmail ? @"Modmail" : @"Chat";
    NSTimeInterval elapsed = self.loadStartedAt ? -[self.loadStartedAt timeIntervalSinceNow] : 0.0;
    ApolloLog(@"[DirectChatWeb] Revealed hydrated mobile %@ UI in %.2fs", surface, elapsed);
    // Reddit creates its WKChildScrollView only after the custom elements
    // hydrate. Configure it now and once more after the final compositing pass.
    [self apollo_enableNativeScrollBounce];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf apollo_enableNativeScrollBounce];
    });
    if (self.mailboxKind == ApolloModernMailboxKindChat) {
        [self apollo_captureChatStatus];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self apollo_captureChatStatus];
        });
    }
}

- (void)apollo_captureChatStatus {
    if (self.mailboxKind != ApolloModernMailboxKindChat || !self.webView.URL ||
        ![self apollo_urlMatchesMailboxRoute:self.webView.URL]) return;
    NSString *script =
        @"(()=>{const roots=[];const visit=r=>{if(!r||roots.includes(r))return;roots.push(r);for(const e of r.querySelectorAll('*'))if(e.shadowRoot)visit(e.shadowRoot);};visit(document);"
         "const visible=e=>{const r=e.getBoundingClientRect(),s=getComputedStyle(e);return r.width>0&&r.height>0&&s.display!=='none'&&s.visibility!=='hidden'&&s.opacity!=='0';};"
         "const titleMatch=(document.title||'').match(/^\\((\\d+)\\)/);let unreadCount=titleMatch?parseInt(titleMatch[1],10)||0:0;let hasUnread=unreadCount>0;let preview='';"
         "for(const root of roots)for(const e of root.querySelectorAll('*')){if(!visible(e))continue;const cls=typeof e.className==='string'?e.className:'';const marker=(cls+' '+(e.getAttribute('data-testid')||'')+' '+(e.getAttribute('aria-label')||'')).toLowerCase();const text=(e.textContent||'').replace(/\\s+/g,' ').trim();if(!hasUnread&&marker.includes('unread')&&text.toLowerCase()!=='unread'&&!e.matches('input,[role=switch]'))hasUnread=true;if(!preview&&e.children.length===0&&text.length>3&&text.length<160&&/^[^:]{1,40}:\\s+.+/.test(text))preview=text;}"
         "const requests=location.pathname.startsWith('/chat/requests'),threads=location.pathname.startsWith('/chat/threads');const body=roots.map(r=>{const host=r===document?document.body:r;return host?.innerText||host?.textContent||'';}).join(' ').replace(/\\s+/g,' ').trim().toLowerCase();"
         "const result={surface:requests?'requests':(threads?'threads':'messages'),hasUnread,unreadCount,preview:preview||null,checkedAt:Date.now()};"
         "if(requests)result.hasRequests=!body.includes('no requests yet')&&!/additional requests\\s*0(?:\\D|$)/.test(body);return result;})()";
    [self.webView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
        if (!error && [result isKindOfClass:[NSDictionary class]]) ApolloModernChatPublishStatus(result);
    }];
}

- (void)apollo_updateEmbeddedWebChromeForURL:(NSURL *)url {
    if (!self.embeddedInInbox || !self.webViewTopConstraint ||
        !self.webViewBottomConstraint) return;
    NSString *path = url.path ?: @"";
    BOOL rootList = [path isEqualToString:@"/chat"] || [path isEqualToString:@"/chat/"];
    BOOL requestsList = [path hasPrefix:@"/chat/requests"];
    BOOL threadsList = [path hasPrefix:@"/chat/threads"];
    BOOL conversationRoom = [path hasPrefix:@"/chat/room/"];
    CGFloat topOffset = 0.0;
    if (requestsList) {
        topOffset = -54.0;
    } else if (threadsList) {
        // Use a harmless initial position until the real first thread can be
        // measured after hydration. The readiness pass then removes Reddit's
        // redundant back/Threads row without clipping the first participant.
        topOffset = 8.0;
    } else if (rootList) {
        // Messages now removes Reddit's redundant list chrome in the DOM. Keep
        // the web view itself uncropped so elastic overscroll cannot reveal
        // hidden content above Apollo's native section switcher.
        topOffset = 0.0;
    }

    // Standalone Direct Chat hides Apollo's tab bar, but the embedded Inbox
    // intentionally keeps it visible. Reddit anchors a room's message composer
    // to the bottom of the web viewport, so a full-height embedded viewport
    // places the entire composer behind Apollo's floating tab bar. Shorten only
    // conversation rooms to the top of that bar. Lists continue beneath the
    // floating chrome and retain their separate scroll allowance.
    CGFloat composerBottomInset = 0.0;
    UITabBar *tabBar = self.tabBarController.tabBar;
    if (conversationRoom && tabBar && !tabBar.hidden && tabBar.alpha > 0.01 &&
        tabBar.window && self.view.window) {
        CGRect tabBarFrame = [tabBar convertRect:tabBar.bounds toView:self.view];
        CGFloat overlap = CGRectGetMaxY(self.view.bounds) - CGRectGetMinY(tabBarFrame);
        if (overlap > 0.0) composerBottomInset = overlap + 8.0;
    }

    BOOL topChanged = fabs(self.webViewTopConstraint.constant - topOffset) >= 0.5;
    BOOL bottomChanged =
        fabs(self.webViewBottomConstraint.constant + composerBottomInset) >= 0.5;
    if (!topChanged && !bottomChanged) return;
    self.webViewTopConstraint.constant = topOffset;
    self.webViewBottomConstraint.constant = -composerBottomInset;
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];
    ApolloLog(@"[DirectChatWeb] Embedded Chat %@ Reddit's list chrome; composer inset %.1fpt",
              (rootList || requestsList) ? @"cropped" : @"restored",
              composerBottomInset);
}

// Messages is the direct-chat list. Reddit exposes Direct chats, Group chats,
// and Mod mail as stable checkbox items behind Filter chat inbox. Change one
// checkbox per pass: the component rerenders after every click, so retaining
// and clicking several stale descendants in one JavaScript turn is unreliable.
- (void)apollo_applyEmbeddedInboxFilterAttempt:(NSUInteger)attempt generation:(NSUInteger)generation {
    if (!self.embeddedInInbox || generation != self.readinessGeneration || self.didRevealChat) return;
    ApolloModernChatInboxSection desiredSection = self.embeddedInboxSection;
    if (desiredSection == ApolloModernChatInboxSectionRequests) {
        [self apollo_waitForChatReadinessAttempt:0 generation:generation];
        return;
    }
    if (desiredSection == ApolloModernChatInboxSectionThreads) {
        [self apollo_waitForChatReadinessAttempt:0 generation:generation];
        return;
    }

    NSString *script = [NSString stringWithFormat:
        @"(()=>{const roots=[];const visit=r=>{if(!r||roots.includes(r))return;roots.push(r);for(const e of r.querySelectorAll('*'))if(e.shadowRoot)visit(e.shadowRoot);};visit(document);"
         "const all=()=>roots.flatMap(r=>[...r.querySelectorAll('*')]);const visible=e=>{const b=e.getBoundingClientRect(),s=getComputedStyle(e);return b.width>0&&b.height>0&&s.display!=='none'&&s.visibility!=='hidden'&&s.opacity!=='0';};"
         "const items=all().filter(e=>e.tagName==='RS-ROOMS-NAV-FILTER-ITEM'&&visible(e));"
         "if(!items.length){const filter=all().find(e=>visible(e)&&(e.getAttribute('aria-label')||'').trim().toLowerCase()==='filter chat inbox');if(filter){filter.click();return 'opening';}return 'waiting';}"
         "const wanted={'group chats':%@,'direct chats':%@,'mod mail':false};"
         "for(const item of items){const label=(item.getAttribute('label')||item.textContent||'').replace(/\\s+/g,' ').trim().toLowerCase();if(!(label in wanted))continue;const control=item.querySelector('[role=checkbox]')||item;const checked=item.checked===true||item.hasAttribute('checked')||control.getAttribute('aria-checked')==='true';if(checked!==wanted[label]){control.click();return 'changed';}}"
         "const apply=all().find(e=>visible(e)&&e.matches('button,[role=button]')&&(e.textContent||'').replace(/\\s+/g,' ').trim().toLowerCase()==='apply');if(apply){apply.click();return 'applied';}return 'waiting';})()",
         @"false", @"true"];

    __weak typeof(self) weakSelf = self;
    [self.webView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || generation != self.readinessGeneration || self.didRevealChat ||
            self.embeddedInboxSection != desiredSection) return;
        if (!error && [result isEqual:@"applied"]) {
            ApolloLog(@"[DirectChatWeb] Applied embedded Messages (direct chats) filter");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.30 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (generation != self.readinessGeneration || self.didRevealChat) return;
                [self apollo_alignEmbeddedMessagesForGeneration:generation completion:^{
                    if (generation != self.readinessGeneration || self.didRevealChat) return;
                    [self apollo_captureChatStatus];
                    [self apollo_revealChat];
                }];
            });
            return;
        }
        if (attempt >= 39) {
            ApolloLog(@"[DirectChatWeb] Embedded Messages filter timed out; revealing Reddit's available list");
            [self apollo_alignEmbeddedMessagesForGeneration:generation completion:^{
                [self apollo_revealChat];
            }];
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.14 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self apollo_applyEmbeddedInboxFilterAttempt:attempt + 1 generation:generation];
        });
    }];
}

// Messages deliberately enables Reddit Chat's Direct-only type filter. Reddit
// persists that choice in localStorage and applies it to the dedicated Requests
// route too, where it silently hides group-chat invitations and renders the
// legitimate "No requests yet" state. Clear only the three type flags before
// opening Requests or Threads, then perform a full route load so Reddit's
// in-memory store reads the reset state. Other per-account Chat preferences in
// the same object remain untouched.
- (void)apollo_clearEmbeddedChatTypeFiltersForGeneration:(NSUInteger)generation
                                               completion:(void (^)(BOOL changed))completion {
    if (!self.embeddedInInbox || generation != self.readinessGeneration) {
        if (completion) completion(NO);
        return;
    }
    NSString *script =
        @"(()=>{const key='chat:reddit-chat-type-filters';let state={};"
         "try{state=JSON.parse(localStorage.getItem(key)||'{}')}catch(e){state={}}"
         "let changed=false;for(const account of Object.keys(state)){const value=state[account]||{};"
         "if(value.shouldShowGroupChats||value.shouldShowDirectChats||value.shouldShowModmailChats)changed=true;"
         "state[account]={...value,shouldShowGroupChats:false,shouldShowDirectChats:false,shouldShowModmailChats:false};}"
         "if(changed)localStorage.setItem(key,JSON.stringify(state));return changed;})()";
    __weak typeof(self) weakSelf = self;
    [self.webView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || generation != self.readinessGeneration) return;
        BOOL changed = !error && [result respondsToSelector:@selector(boolValue)] && [result boolValue];
        if (changed) {
            ApolloLog(@"[DirectChatWeb] Cleared persisted Chat type filters before %@",
                      self.embeddedInboxSection == ApolloModernChatInboxSectionRequests
                          ? @"Requests" : @"Threads");
        }
        if (completion) completion(changed);
    }];
}

// Reddit's root Chat page places its own header, filter chips, and two
// mobile-web navigation rows before the first conversation. Apollo already
// supplies all of that navigation. Remove those elements from layout rather
// than cropping the WKWebView: a native crop looks correct at rest but elastic
// overscroll can pull the supposedly-hidden rows back into view.
- (void)apollo_alignEmbeddedMessagesForGeneration:(NSUInteger)generation
                                        completion:(dispatch_block_t)completion {
    if (!self.embeddedInInbox ||
        self.embeddedInboxSection != ApolloModernChatInboxSectionMessages ||
        generation != self.readinessGeneration) {
        if (completion) completion();
        return;
    }
    NSString *script =
        @"(()=>{window.__apolloEmbeddedInboxMessages=true;window.__apolloChatEnhancementSweep?.();"
         "const roots=[];const visit=r=>{if(!r||roots.includes(r))return;roots.push(r);for(const e of r.querySelectorAll('*'))if(e.shadowRoot)visit(e.shadowRoot);};visit(document);"
         "const visible=e=>{const b=e.getBoundingClientRect(),s=getComputedStyle(e);return b.width>0&&b.height>0&&s.display!=='none'&&s.visibility!=='hidden'&&s.opacity!=='0';};"
         "const all=roots.flatMap(r=>[...r.querySelectorAll('*')]);let marker=all.find(e=>visible(e)&&e.matches('.room-name'));"
         "if(marker)marker=marker.closest('li,[role=button]')||marker;"
         "if(!marker)marker=all.find(e=>visible(e)&&(e.textContent||'').replace(/\\s+/g,' ').trim().toLowerCase()==='no messages');"
         "if(!marker)return null;const top=marker.getBoundingClientRect().top;return Number.isFinite(top)?top:null;})()";
    __weak typeof(self) weakSelf = self;
    [self.webView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || generation != self.readinessGeneration ||
            self.embeddedInboxSection != ApolloModernChatInboxSectionMessages) return;
        CGFloat top = !error && [result respondsToSelector:@selector(doubleValue)]
            ? [result doubleValue] : 0.0;
        // The redundant elements are gone from layout, so the first room
        // normally measures at zero. Retain a small native breathing gap and
        // only compensate for a modest future Reddit wrapper—not a hidden
        // screenful that elastic overscroll could expose.
        CGFloat offset = MAX(-40.0, MIN(12.0, 12.0 - top));
        self.webViewTopConstraint.constant = offset;
        [self.view setNeedsLayout];
        [self.view layoutIfNeeded];
        ApolloLog(@"[DirectChatWeb] Aligned embedded Messages first content at %.1fpt (web offset %.1f)",
                  top, offset);
        if (completion) completion();
    }];
}

// The real Threads route prepends its own mobile back button and "Threads"
// title. Apollo already supplies that navigation through the three-way section
// switcher, so align the first actual reply thread beneath it. Measuring the
// custom element avoids clipping its participant row when Reddit changes the
// height of the redundant header.
- (void)apollo_alignEmbeddedThreadsForGeneration:(NSUInteger)generation
                                       completion:(dispatch_block_t)completion {
    if (!self.embeddedInInbox ||
        self.embeddedInboxSection != ApolloModernChatInboxSectionThreads ||
        generation != self.readinessGeneration) {
        if (completion) completion();
        return;
    }
    NSString *script =
        @"(()=>{const roots=[];const visit=r=>{if(!r||roots.includes(r))return;roots.push(r);for(const e of r.querySelectorAll('*'))if(e.shadowRoot)visit(e.shadowRoot);};visit(document);"
         "const visible=e=>{const b=e.getBoundingClientRect(),s=getComputedStyle(e);return b.width>0&&b.height>0&&s.display!=='none'&&s.visibility!=='hidden'&&s.opacity!=='0';};"
         "const all=roots.flatMap(r=>[...r.querySelectorAll('*')]);let thread=all.find(e=>visible(e)&&e.tagName==='RS-THREADS-VIEW-THREAD'),marker=null;"
         "if(thread){const belongs=e=>{let n=e;while(n){if(n===thread)return true;const root=n.getRootNode?.();n=root instanceof ShadowRoot?root.host:n.parentElement;}return false;};marker=all.filter(e=>e!==thread&&belongs(e)&&visible(e)&&e.children.length===0&&(e.textContent||'').replace(/\\s+/g,' ').trim().length>0).sort((a,b)=>a.getBoundingClientRect().top-b.getBoundingClientRect().top)[0]||thread;}"
         "if(!marker)marker=all.find(e=>visible(e)&&e.children.length===0&&(e.textContent||'').replace(/\\s+/g,' ').trim().toLowerCase()==='no threads');"
         "if(!marker)return null;const top=marker.getBoundingClientRect().top;return Number.isFinite(top)?top:null;})()";
    __weak typeof(self) weakSelf = self;
    [self.webView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || generation != self.readinessGeneration ||
            self.embeddedInboxSection != ApolloModernChatInboxSectionThreads) return;
        if (!error && [result respondsToSelector:@selector(doubleValue)]) {
            CGFloat top = [result doubleValue];
            CGFloat offset = MAX(-240.0, MIN(8.0, 12.0 - top));
            self.webViewTopConstraint.constant = offset;
            [self.view setNeedsLayout];
            [self.view layoutIfNeeded];
            ApolloLog(@"[DirectChatWeb] Aligned embedded Threads first content at %.1fpt (web offset %.1f)",
                      top, offset);
        }
        if (completion) completion();
    }];
}

- (void)apollo_showEmbeddedInboxSection:(ApolloModernChatInboxSection)section {
    if (!self.embeddedInInbox || self.mailboxKind != ApolloModernMailboxKindChat) return;
    if (section < ApolloModernChatInboxSectionMessages ||
        section > ApolloModernChatInboxSectionThreads) {
        section = ApolloModernChatInboxSectionMessages;
    }

    NSString *targetPath;
    switch (section) {
        case ApolloModernChatInboxSectionRequests:
            targetPath = @"/chat/requests";
            break;
        case ApolloModernChatInboxSectionThreads:
            targetPath = @"/chat/threads";
            break;
        case ApolloModernChatInboxSectionMessages:
        default:
            targetPath = @"/chat";
            break;
    }
    NSString *currentPath = self.webView.URL.path ?: @"";
    BOOL alreadyOnTarget;
    if (section == ApolloModernChatInboxSectionRequests) {
        alreadyOnTarget = [currentPath hasPrefix:@"/chat/requests"];
    } else if (section == ApolloModernChatInboxSectionThreads) {
        alreadyOnTarget = [currentPath hasPrefix:@"/chat/threads"];
    } else {
        alreadyOnTarget = [currentPath isEqualToString:@"/chat"] ||
            [currentPath isEqualToString:@"/chat/"];
    }
    BOOL sameSection = self.embeddedInboxSection == section;
    self.embeddedInboxSection = section;
    self.initialDestinationPath = targetPath;
    [self apollo_updateEmbeddedWebChromeForURL:[NSURL URLWithString:
        [@"https://www.reddit.com" stringByAppendingString:targetPath]]];

    // Re-selecting the active list is intentionally inert, matching a native
    // tab bar. If a conversation room is open, however, tapping the selected
    // tab returns to that section's list.
    if (sameSection && alreadyOnTarget && self.didRevealChat) return;

    NSString *detail;
    switch (section) {
        case ApolloModernChatInboxSectionRequests:
            detail = @"Checking for people who want to chat…";
            break;
        case ApolloModernChatInboxSectionThreads:
            detail = @"Loading conversations around messages you replied to…";
            break;
        case ApolloModernChatInboxSectionMessages:
        default:
            detail = @"Loading your direct conversations…";
            break;
    }
    [self apollo_showLoadingWithDetail:detail];
    NSUInteger generation = self.readinessGeneration;

    // Direct-only is useful for Messages but incorrect for Requests, where it
    // hides group invitations. Reset the persisted type filter before either
    // non-Messages route is allowed to hydrate. If the route is already open,
    // a full reload is required to replace Reddit's in-memory filtered store.
    if (section != ApolloModernChatInboxSectionMessages) {
        __weak typeof(self) weakSelf = self;
        [self apollo_clearEmbeddedChatTypeFiltersForGeneration:generation
                                                    completion:^(BOOL changed) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || generation != self.readinessGeneration ||
                self.embeddedInboxSection != section) return;
            if (alreadyOnTarget && !changed) {
                [self apollo_waitForChatReadinessAttempt:0 generation:generation];
                return;
            }
            [self.webView stopLoading];
            NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:
                [@"https://www.reddit.com" stringByAppendingString:targetPath]]];
            request.cachePolicy = NSURLRequestUseProtocolCachePolicy;
            [self.webView loadRequest:request];
        }];
        return;
    }

    if (alreadyOnTarget) {
        [self apollo_applyEmbeddedInboxFilterAttempt:0 generation:generation];
        return;
    }

    // Rapid taps may leave WebKit finishing an older route after a newer tab
    // has already been selected. Explicitly cancel that obsolete navigation so
    // only the newly selected tab is allowed to drive readiness and layout.
    [self.webView stopLoading];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:
        [@"https://www.reddit.com" stringByAppendingString:targetPath]]];
    request.cachePolicy = NSURLRequestUseProtocolCachePolicy;
    [self.webView loadRequest:request];
}

- (void)apollo_seedAndLoad {
    ApolloWebSessionEntry *session = ApolloActiveWebSession();
    self.username = ApolloActiveWebSessionUsername() ?: @"";
    if (session.cookieHeader.length == 0) {
        NSString *detail = self.username.length > 0
            ? [NSString stringWithFormat:@"Sign in as u/%@ to continue.", self.username]
            : @"Sign in to Reddit to continue.";
        [self apollo_showAuthenticationError:detail automaticallyPrompt:YES];
        ApolloLog(@"[DirectChatWeb] Cannot load: active account has no web session");
        return;
    }
    NSString *detail = self.username.length ? [NSString stringWithFormat:@"Connecting as u/%@…", self.username] : @"Connecting to Reddit…";
    [self apollo_showLoadingWithDetail:detail];

    NSDictionary<NSString *, NSString *> *pairs = ApolloDirectChatCookiePairs(session.cookieHeader);
    WKHTTPCookieStore *store = self.webView.configuration.websiteDataStore.httpCookieStore;
    ApolloSeedModernMailboxCookies(session.cookieHeader, store, ^{
        BOOL modmail = self.mailboxKind == ApolloModernMailboxKindModmail;
        self.modmailWarmupPending = modmail;
        ApolloLog(@"[DirectChatWeb] Seeded %lu cookies for u/%@; loading mobile %@",
                  (unsigned long)pairs.count, self.username, modmail ? @"Modmail warm-up" : @"Chat Requests");
        // Reddit exposes stable authenticated routes for the conversation list
        // (`/chat`), incoming requests (`/chat/requests`), and participated
        // message-reply threads (`/chat/threads`). Start mobile/device-width
        // here so none of the old desktop feed/drawer handoff is needed during
        // ordinary use.
        // Reddit moved the official Modmail surface into www.reddit.com/mail;
        // unlike Apollo's OAuth-only /api/mod endpoints this page accepts the
        // same signed-in web cookie as the rest of API-Key-Free Mode. A fresh
        // web process needs one authenticated same-origin document first, so
        // Modmail deliberately starts on the hidden Chat Requests warm-up.
        NSString *chatPath = !modmail && self.initialDestinationPath.length > 0
            ? self.initialDestinationPath : @"/chat/requests";
        NSString *urlString = [@"https://www.reddit.com" stringByAppendingString:chatPath];
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
        // Reddit's API calls still fetch current inbox data; allowing the main
        // document and versioned JS/CSS bundles to revalidate is what makes a
        // warmed launch faster without showing stale conversations.
        request.cachePolicy = NSURLRequestUseProtocolCachePolicy;
        [self.webView loadRequest:request];
    });
}

- (void)apollo_waitForChatReadinessAttempt:(NSUInteger)attempt generation:(NSUInteger)generation {
    if (generation != self.readinessGeneration || self.didRevealChat) return;
    // The navigation-finished callback fires before Reddit's Chat custom
    // elements finish hydrating. Keep the native loading cover up until the
    // selected list has painted a real control, row, or legitimate empty state.
    NSString *script;
    if (self.mailboxKind == ApolloModernMailboxKindModmail) {
        // Current (2026) Reddit Modmail lives at /mail/all. Its first navigation
        // finishes before the mailbox custom element paints, so keep the Apollo
        // loading cover up until a real folder/control or conversation is visible.
        script =
            @"(()=>{const body=(document.body?.innerText||'').replace(/\\s+/g,' ').trim().toLowerCase();"
             "const signedOut=(body.includes('log in')||body.includes('sign in'))&&!body.includes('mark all as read')&&!body.includes('recently updated');"
             "if(signedOut)return 'signedOut';"
             "const ready=location.pathname.startsWith('/mail')&&(body.includes('mark all as read')||body.includes('recently updated')||body.includes('all mail')||body.includes('in progress')||!!document.querySelector('modmail-mailbox-wrapper'));"
             "return ready?'ready':'waiting';})()";
    } else {
        BOOL keepExplicitEmptyRequests = [self.initialDestinationPath isEqualToString:@"/chat/requests"];
        script = [NSString stringWithFormat:
            @"(()=>{const roots=[];const visit=r=>{if(!r||roots.includes(r))return;roots.push(r);for(const e of r.querySelectorAll('*'))if(e.shadowRoot)visit(e.shadowRoot);};visit(document);"
             "const visible=e=>{const r=e.getBoundingClientRect(),s=getComputedStyle(e);return r.width>0&&r.height>0&&s.display!=='none'&&s.visibility!=='hidden'&&s.opacity!=='0';};"
             "const text=e=>(e.textContent||'').replace(/\\s+/g,' ').trim().toLowerCase();"
             "const controls=roots.flatMap(r=>[...r.querySelectorAll('button,a,[role=button],input,textarea,[contenteditable=true],h1,h2,h3,p')]);"
             "const all=roots.flatMap(r=>[...r.querySelectorAll('*')]);const threadsRoute=location.pathname.startsWith('/chat/threads');"
             "if(threadsRoute){const threadItem=all.some(e=>visible(e)&&e.tagName==='RS-THREADS-VIEW-THREAD');const threadText=all.filter(e=>e.children.length===0).map(text).join(' ');return threadItem||threadText.includes('no threads')?'ready':'waiting';}"
             "const empty=location.pathname.startsWith('/chat/requests')&&controls.some(e=>visible(e)&&text(e)==='no requests yet');"
             // Reddit paints its Requests empty state before its current
             // invitations finish loading. Give that data request a short
             // settling window before accepting the empty state as genuine.
             "if(empty&&%@)return %lu>=8?'ready':'waiting';"
             "if(empty&&!window.__apolloEmptyRequestsHandled){window.__apolloEmptyRequestsHandled=true;const clickables=roots.flatMap(r=>[...r.querySelectorAll('button,a,[role=button]')]).filter(visible);"
             "let back=clickables.find(e=>{const r=e.getBoundingClientRect();if(r.left>130||r.top>180)return false;const marker=[text(e),e.getAttribute('aria-label'),e.getAttribute('title'),e.getAttribute('data-testid')].filter(Boolean).join(' ').toLowerCase();return /(^|\\s)(back|threads?)(\\s|$)/.test(marker)||!!e.querySelector('[icon-name*=back i],[name*=back i],[aria-label*=back i]');});"
             "if(!back)back=clickables.filter(e=>{const r=e.getBoundingClientRect(),cx=r.left+r.width/2,cy=r.top+r.height/2;return cx<90&&cy>55&&cy<180&&r.width<180&&r.height<100;}).sort((a,b)=>a.getBoundingClientRect().top-b.getBoundingClientRect().top)[0];"
             "if(back){back.click();return 'redirected';}location.replace('/chat');return 'redirected';}"
             // A fully-hydrated filtered list can legitimately contain no
             // rooms. Reddit renders this as an exact empty-state pair; treat
             // both markers together as ready instead of leaving an already
             // complete screen behind the loading cover for 15 seconds.
             "const rootList=location.pathname==='/chat'||location.pathname==='/chat/';"
             "const hydratedEmpty=rootList&&controls.some(e=>visible(e)&&text(e)==='no messages')&&controls.some(e=>visible(e)&&text(e)==='clear filters');"
             "if(hydratedEmpty)return 'ready';"
             "const ready=controls.some(e=>{if(!visible(e))return false;const t=text(e),a=(e.getAttribute('aria-label')||'').trim().toLowerCase();"
             "if(t==='view request'||t==='go to messages'||t==='start new chat'||t==='accept'||t==='additional requests'||t==='threads'||t==='chats')return true;"
             "const room=location.pathname.startsWith('/chat/room/');return room&&(e.matches('input,textarea,[contenteditable=true]')||a==='send message'||a==='message');});return ready?'ready':'waiting';})()",
             keepExplicitEmptyRequests ? @"true" : @"false",
             (unsigned long)attempt];
    }
    __weak typeof(self) weakSelf = self;
    [self.webView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || generation != self.readinessGeneration || self.didRevealChat) return;
        if (!error && [result isEqual:@"ready"]) {
            NSString *path = self.webView.URL.path ?: @"";
            BOOL embeddedList = self.embeddedInInbox &&
                ([path isEqualToString:@"/chat"] || [path isEqualToString:@"/chat/"]);
            if (embeddedList) {
                [self apollo_applyEmbeddedInboxFilterAttempt:0 generation:generation];
            } else if (self.embeddedInInbox && [path hasPrefix:@"/chat/threads"]) {
                [self apollo_alignEmbeddedThreadsForGeneration:generation completion:^{
                    [self apollo_revealChat];
                }];
            } else {
                [self apollo_revealChat];
            }
            return;
        }
        if (!error && [result isEqual:@"redirected"] && attempt == 0) {
            ApolloLog(@"[DirectChatWeb] No pending requests; returning to the Threads list");
        }
        if (!error && [result isEqual:@"signedOut"]) {
            [self apollo_showAuthenticationError:@"Your Reddit web session expired. Sign in again to reconnect."
                             automaticallyPrompt:YES];
            return;
        }
        if (attempt >= 59) {
            NSString *surface = self.mailboxKind == ApolloModernMailboxKindModmail ? @"Modmail" : @"Chat";
            ApolloLog(@"[DirectChatWeb] %@ readiness probe timed out", surface);
            if (self.mailboxKind == ApolloModernMailboxKindModmail) {
                [self apollo_showLoadError:@"Moderator Mail took too long to finish loading. Tap refresh to try again."];
            } else {
                // Chat's markup changes frequently; if its expected route did
                // finish, preserve the prior behavior and reveal it rather
                // than treating an unknown new ready marker as a hard failure.
                [self apollo_revealChat];
            }
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self apollo_waitForChatReadinessAttempt:attempt + 1 generation:generation];
        });
    }];
}

- (BOOL)apollo_urlMatchesMailboxRoute:(NSURL *)url {
    if (!url) return NO;
    NSString *host = url.host.lowercaseString ?: @"";
    BOOL redditHost = [host isEqualToString:@"reddit.com"] || [host hasSuffix:@".reddit.com"];
    if (!redditHost) return NO;

    NSString *path = url.path ?: @"";
    if (self.mailboxKind == ApolloModernMailboxKindModmail) {
        BOOL mailbox = [path isEqualToString:@"/mail"] || [path hasPrefix:@"/mail/"];
        // The composer links to Reddit's per-subreddit saved-response manager.
        // Keep that management flow in the authenticated Modmail WKWebView;
        // Apollo's native deep-link parser otherwise mistakes it for content
        // navigation and opens an unusable Comments controller.
        BOOL savedResponses = [path hasPrefix:@"/mod/"] &&
            [path rangeOfString:@"/saved-responses" options:NSCaseInsensitiveSearch].location != NSNotFound;
        return mailbox || savedResponses;
    }
    return [path isEqualToString:@"/chat"] || [path hasPrefix:@"/chat/"];
}

- (void)apollo_routeURLOutsideMailbox:(NSURL *)url {
    if (!url) return;
    NSURL *apolloURL = ApolloURLByConvertingResolvedURLToApolloScheme(url);
    if (apolloURL) {
        // Keep the hidden-tab mailbox and every Inbox controller completely out
        // of native Reddit navigation. Rebuilding or temporarily removing this
        // controller from the Inbox stack poisons UINavigationController's
        // safe-area cache on iOS 26; every later Inbox destination then starts
        // beneath the navigation bar. Route through Apollo's Posts tab instead.
        UINavigationController *mailboxNavigationController = self.navigationController;
        UITabBarController *tabBarController = self.tabBarController;
        UINavigationController *routingNavigationController = nil;
        for (UIViewController *candidate in tabBarController.viewControllers) {
            if (candidate == mailboxNavigationController ||
                ![candidate isKindOfClass:[UINavigationController class]]) continue;
            routingNavigationController = (UINavigationController *)candidate;
            break;
        }

        if (routingNavigationController) {
            ApolloClearMailboxReturn(routingNavigationController);
            tabBarController.selectedViewController = routingNavigationController;
        }

        UIViewController *routingAnchorBeforeOpen = routingNavigationController.topViewController;
        if (routingNavigationController && ApolloRouteResolvedURLViaApolloScheme(url)) {
            UINavigationController *destinationNavigationController =
                [tabBarController.selectedViewController isKindOfClass:[UINavigationController class]]
                    ? (UINavigationController *)tabBarController.selectedViewController
                    : routingNavigationController;
            UIViewController *destination = destinationNavigationController.topViewController;
            if (destinationNavigationController &&
                destinationNavigationController != mailboxNavigationController && destination &&
                destination != routingAnchorBeforeOpen) {
                ApolloStoreMailboxReturn(destinationNavigationController, self, destination);
                ApolloLog(@"[DirectChatWeb] Preserved mailbox while native Reddit destination %@ uses another tab",
                          NSStringFromClass(destination.class));
            }
            ApolloLog(@"[DirectChatWeb] Routed Reddit link through Apollo without changing the Inbox stack: %@",
                      url.absoluteString);
            return;
        }

        // The converter recognized Reddit but Apollo's native handler was not
        // available. Return to the still-intact mailbox before presenting
        // Apollo's browser.
        if (mailboxNavigationController && tabBarController) {
            tabBarController.selectedViewController = mailboxNavigationController;
        }
        [self apollo_prepareForMailboxReturnAnimated:NO];
        ApolloPresentWebURLFromViewController(self, url);
        ApolloLog(@"[DirectChatWeb] Native Reddit routing unavailable; used Apollo browser: %@", url.absoluteString);
        return;
    }

    NSString *scheme = url.scheme.lowercaseString ?: @"";
    if ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) {
        ApolloPresentWebURLFromViewController(self, url);
    } else {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    }
    ApolloLog(@"[DirectChatWeb] Routed link outside isolated mailbox: %@", url.absoluteString);
}

- (void)apollo_prepareForMailboxReturnAnimated:(BOOL)animated {
    (void)animated;
    self.nativeReturnPathActive = NO;
    self.hidesBottomBarWhenPushed = YES;

    // Let the navigation transition apply this controller preference. Calling
    // setTabBarHidden: here creates sticky tab-controller state on iOS 18+;
    // after Modmail is later popped, Boxes can otherwise remain without its
    // tab bar and with zero safe-area insets under the navigation bar.
    ApolloLog(@"[DirectChatWeb] Restored composer-safe mailbox chrome");
}

- (WKWebView *)webView:(WKWebView *)webView
    createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
               forNavigationAction:(WKNavigationAction *)navigationAction
                    windowFeatures:(WKWindowFeatures *)windowFeatures {
    // Reddit's “Open chat in full screen” control opens a new browsing context.
    // Keep mailbox routes inside the isolated web view, but never load a post,
    // profile, or third-party target into the cookie-seeded browsing context.
    if (!navigationAction.targetFrame && navigationAction.request.URL) {
        if ([self apollo_urlMatchesMailboxRoute:navigationAction.request.URL]) {
            [webView loadRequest:navigationAction.request];
        } else {
            [self apollo_routeURLOutsideMailbox:navigationAction.request.URL];
        }
    }
    return nil;
}

- (void)webView:(WKWebView *)webView
    decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
                    decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *url = navigationAction.request.URL;
    // Reddit Chat switches rooms with same-document client-side navigation.
    // WKWebView's URL is updated only after that transition, and neither
    // didStartProvisionalNavigation: nor didFinishNavigation: is guaranteed to
    // run. Size the pending mailbox route here so an embedded room's fixed
    // composer is already above Apollo's tab bar on the first rendered frame.
    if (url && [self apollo_urlMatchesMailboxRoute:url]) {
        [self apollo_updateEmbeddedWebChromeForURL:url];
    }
    if (url && [self apollo_isModmailConversationURL:url]) {
        [self apollo_beginModmailThreadTransitionToURL:url];
    }
    NSString *host = url.host.lowercaseString ?: @"";
    BOOL redditHost = [host isEqualToString:@"reddit.com"] || [host hasSuffix:@".reddit.com"];
    BOOL redditHomeLogo = redditHost && [url.path isEqualToString:@"/"] && url.query.length == 0 && url.fragment.length == 0;
    if (redditHomeLogo && navigationAction.navigationType == WKNavigationTypeLinkActivated) {
        ApolloLog(@"[DirectChatWeb] Blocked Reddit home-logo navigation inside Chat");
        decisionHandler(WKNavigationActionPolicyCancel);
        return;
    }
    if (url && navigationAction.navigationType == WKNavigationTypeLinkActivated &&
        ![self apollo_urlMatchesMailboxRoute:url]) {
        // User-selected links leave the mailbox through Apollo's native Reddit
        // router or in-app browser. Apart from avoiding the false expired-state
        // overlay, this prevents third-party pages inheriting Reddit cookies in
        // the private WKWebView used for Chat and Modmail.
        decisionHandler(WKNavigationActionPolicyCancel);
        [self apollo_routeURLOutsideMailbox:url];
        return;
    }
    decisionHandler(WKNavigationActionPolicyAllow);
}

- (void)apollo_reloadChat {
    if (self.mailboxKind == ApolloModernMailboxKindModmail) {
        [self.webView stopLoading];
        [self apollo_seedAndLoad];
        return;
    }
    if (self.webView.URL) {
        [self apollo_showLoadingWithDetail:self.mailboxKind == ApolloModernMailboxKindModmail
            ? @"Refreshing Moderator Mail…" : @"Refreshing your chat…"];
        [self.webView reloadFromOrigin];
    } else {
        [self apollo_seedAndLoad];
    }
}

- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation {
    // Reddit occasionally starts a Modmail thread through location.assign
    // without delivering a useful targetFrame in the policy callback. At this
    // point the destination URL has already been installed on WKWebView, but
    // the new document has not committed, so this remains early enough to hide
    // every placeholder/hydration frame. The pending guard makes this a no-op
    // when decidePolicyForNavigationAction: already covered the transition.
    if ([self apollo_isModmailConversationURL:webView.URL]) {
        [self apollo_beginModmailThreadTransitionToURL:webView.URL];
    }
    [self apollo_updateEmbeddedWebChromeForURL:webView.URL];
    if (!self.didRevealChat) [self.spinner startAnimating];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    ApolloLog(@"[DirectChatWeb] Loaded %@%@ for u/%@", webView.URL.host ?: @"unknown host", webView.URL.path ?: @"", self.username);
    [self apollo_updateEmbeddedWebChromeForURL:webView.URL];
    if (self.mailboxKind == ApolloModernMailboxKindModmail &&
        self.modmailWarmupPending && [webView.URL.path hasPrefix:@"/chat"]) {
        self.modmailWarmupPending = NO;
        NSString *modmailPath = self.initialDestinationPath.length > 0
            ? self.initialDestinationPath : @"/mail/all";
        ApolloLog(@"[DirectChatWeb] Modmail same-origin warm-up complete; loading requested mailbox route");
        NSMutableURLRequest *request = [NSMutableURLRequest
            requestWithURL:[NSURL URLWithString:[@"https://www.reddit.com" stringByAppendingString:modmailPath]]];
        request.cachePolicy = NSURLRequestUseProtocolCachePolicy;
        [webView loadRequest:request];
        return;
    }
    BOOL expectedRoute = [self apollo_urlMatchesMailboxRoute:webView.URL];
    if (expectedRoute) {
        // Apply the active Apollo palette before the loading cover is removed;
        // users never see Reddit's stock colors flash during hydration.
        [self apollo_applyActiveTheme];
        if (self.modmailThreadTransitionPending &&
            [self apollo_isModmailConversationURL:webView.URL]) {
            [self apollo_waitForModmailThreadStabilityAttempt:0
                                                   generation:self.modmailThreadTransitionGeneration
                                                lastSignature:nil
                                                stableSamples:0];
            return;
        }
        if (self.modmailThreadTransitionPending) {
            // A back/redirect may replace the intended conversation with a
            // mailbox list. Never strand that valid destination behind the
            // transition cover.
            [self apollo_finishModmailThreadTransitionForGeneration:
                self.modmailThreadTransitionGeneration];
        }
        if (self.embeddedInInbox && self.mailboxKind == ApolloModernMailboxKindChat) {
            NSString *path = webView.URL.path ?: @"";
            BOOL wantsRequests = self.embeddedInboxSection == ApolloModernChatInboxSectionRequests;
            BOOL wantsThreads = self.embeddedInboxSection == ApolloModernChatInboxSectionThreads;
            BOOL routeMatchesSelection = wantsRequests
                ? [path hasPrefix:@"/chat/requests"]
                : (wantsThreads
                    ? [path hasPrefix:@"/chat/threads"]
                    : ([path isEqualToString:@"/chat"] || [path isEqualToString:@"/chat/"]));
            if (!routeMatchesSelection) {
                ApolloLog(@"[DirectChatWeb] Ignored stale embedded Chat navigation %@ while %@ is selected",
                          path, wantsRequests ? @"Requests" :
                          (wantsThreads ? @"Threads" : @"Messages"));
                return;
            }
            if (wantsRequests || wantsThreads) {
                [self apollo_waitForChatReadinessAttempt:0 generation:self.readinessGeneration];
            } else {
                // The filter helper is itself a readiness loop and handles
                // Reddit's shadow-DOM rerenders. Starting it immediately after
                // the correct /chat document finishes avoids the generic
                // probe's 15-second timeout on valid empty chat lists.
                [self apollo_applyEmbeddedInboxFilterAttempt:0 generation:self.readinessGeneration];
            }
            return;
        }
        [self apollo_waitForChatReadinessAttempt:0 generation:self.readinessGeneration];
        return;
    }
    // An unexpected route only proves authentication failed during the initial
    // mailbox bootstrap. Once the mailbox was revealed, never cover a valid
    // page with a false “session expired” state; link-activated departures are
    // already cancelled and handed to Apollo above.
    if (!self.didRevealChat) {
        [self apollo_showAuthenticationError:@"Your Reddit web session expired. Sign in again to reconnect."
                         automaticallyPrompt:YES];
    } else {
        ApolloLog(@"[DirectChatWeb] Ignored post-reveal non-mailbox navigation: %@", webView.URL.absoluteString);
    }
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

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
    ApolloLog(@"[DirectChatWeb] Reddit web process terminated for u/%@", self.username);
    [self apollo_showLoadError:@"Reddit stopped responding. Tap refresh to reconnect."];
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

BOOL ApolloModernModmailShouldOpen(void) {
    if (ApolloModernChatIsRequiredForActiveAccount()) return YES;
    return [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyUseModernRedditModmail];
}

UIViewController *ApolloCreateModernChatViewController(void) {
    return ApolloCreateModernChatViewControllerForPath(nil);
}

UIViewController *ApolloCreateModernChatViewControllerForPath(NSString *destinationPath) {
    ApolloDirectChatWebViewController *controller = [ApolloDirectChatWebViewController new];
    controller.initialDestinationPath = ApolloValidatedModernMailboxPath(
        ApolloModernMailboxKindChat, destinationPath);
    // Apollo's translucent tab bar otherwise covers Reddit's composer and send
    // button. This must be set before the navigation push so UIKit reserves the
    // full chat screen and keyboard-safe bottom inset correctly.
    controller.hidesBottomBarWhenPushed = YES;
    return controller;
}

UIViewController *ApolloCreateEmbeddedModernChatViewController(ApolloModernChatInboxSection section) {
    if (section < ApolloModernChatInboxSectionMessages ||
        section > ApolloModernChatInboxSectionThreads) {
        section = ApolloModernChatInboxSectionMessages;
    }
    ApolloDirectChatWebViewController *controller = [ApolloDirectChatWebViewController new];
    controller.embeddedInInbox = YES;
    controller.embeddedInboxSection = section;
    switch (section) {
        case ApolloModernChatInboxSectionRequests:
            controller.initialDestinationPath = @"/chat/requests";
            break;
        case ApolloModernChatInboxSectionThreads:
            controller.initialDestinationPath = @"/chat/threads";
            break;
        case ApolloModernChatInboxSectionMessages:
        default:
            controller.initialDestinationPath = @"/chat";
            break;
    }
    controller.hidesBottomBarWhenPushed = NO;
    return controller;
}

void ApolloModernChatControllerShowInboxSection(UIViewController *controller,
                                                ApolloModernChatInboxSection section) {
    if (![controller isKindOfClass:[ApolloDirectChatWebViewController class]]) return;
    [(ApolloDirectChatWebViewController *)controller apollo_showEmbeddedInboxSection:section];
}

void ApolloModernChatControllerRefreshEmbeddedLayout(UIViewController *controller) {
    if (![controller isKindOfClass:[ApolloDirectChatWebViewController class]]) return;
    ApolloDirectChatWebViewController *chatController =
        (ApolloDirectChatWebViewController *)controller;
    [chatController.view setNeedsLayout];
    [chatController.view layoutIfNeeded];
    [chatController apollo_enableNativeScrollBounce];
    // WebKit may discard its private WKChildScrollView while the preloaded hub
    // is hidden and recreate it on the next compositing pass. Reapply after
    // that handoff so the real CSS overflow scroller receives the tab-bar inset.
    __weak ApolloDirectChatWebViewController *weakController = chatController;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakController apollo_enableNativeScrollBounce];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.90 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakController apollo_enableNativeScrollBounce];
    });
}

UIViewController *ApolloCreateModernModmailViewController(void) {
    return ApolloCreateModernModmailViewControllerForPath(nil);
}

UIViewController *ApolloCreateModernModmailViewControllerForPath(NSString *destinationPath) {
    ApolloDirectChatWebViewController *controller = [ApolloDirectChatWebViewController new];
    controller.mailboxKind = ApolloModernMailboxKindModmail;
    controller.initialDestinationPath = ApolloValidatedModernMailboxPath(
        ApolloModernMailboxKindModmail, destinationPath);
    controller.hidesBottomBarWhenPushed = YES;
    return controller;
}

// Reddit content opened from a mailbox lives on another tab's native navigation
// stack. Back removes that temporary destination normally, then selects the
// untouched Inbox stack where the exact Chat/Modmail controller is still alive.
%hook UINavigationController

- (void)pushViewController:(UIViewController *)viewController animated:(BOOL)animated {
    // The Inbox row has its own direct modern-Modmail route, but subreddit
    // moderator menus (and any other Apollo entry point) still construct and
    // push Apollo's OAuth-only ModmailInboxViewController. Replace that
    // destination before its view loads so API-key-free accounts never land
    // on the legacy screen, and API-key accounts follow their explicit toggle.
    Class nativeModmailClass = objc_getClass("_TtC6Apollo26ModmailInboxViewController");
    if (nativeModmailClass &&
        [viewController isKindOfClass:nativeModmailClass] &&
        ApolloModernModmailShouldOpen()) {
        ApolloLog(@"[DirectChatWeb] Redirecting native Modmail push to modern authenticated Modmail");
        %orig(ApolloCreateModernModmailViewController(), animated);
        return;
    }

    %orig;
}

- (UIViewController *)popViewControllerAnimated:(BOOL)animated {
    UIViewController *anchor = ApolloMailboxReturnAnchor(self);
    if (anchor && self.topViewController == anchor) {
        // Reveal the preserved mailbox first, then clean up the now-hidden
        // native stack. Popping first briefly exposes the Posts screen between
        // the profile/subreddit and Modmail for a single rendered frame.
        ApolloReturnToMailboxFromNavigationController(self);
        return %orig(NO);
    }
    return %orig(animated);
}

%end

// Selecting Inbox already reveals the untouched mailbox. Clear the optional
// native-Back return marker so a later Back action in Posts behaves normally.
%hook _TtC6Apollo13SceneDelegate

- (BOOL)tabBarController:(UITabBarController *)tabBarController
 shouldSelectViewController:(UIViewController *)viewController {
    for (UIViewController *candidate in tabBarController.viewControllers) {
        if (![candidate isKindOfClass:[UINavigationController class]]) continue;
        UINavigationController *navigationController = (UINavigationController *)candidate;
        ApolloDirectChatWebViewController *mailbox = ApolloMailboxReturnController(navigationController);
        if (mailbox && viewController == mailbox.navigationController) {
            ApolloClearMailboxReturn(navigationController);
            [mailbox apollo_prepareForMailboxReturnAnimated:NO];
            ApolloLog(@"[DirectChatWeb] Inbox tab returned directly to preserved %@",
                      mailbox.mailboxKind == ApolloModernMailboxKindModmail ? @"Modmail" : @"Chat");
            // Apollo treats Inbox selection as a request to reset that tab's
            // stack. The mailbox is already the desired destination, so allow
            // UIKit to select it without running Apollo's reset behavior.
            return YES;
        }
    }
    return %orig(tabBarController, viewController);
}

%end

%ctor {
    %init;
    ApolloLog(@"[DirectChatWeb] module loaded");
}
