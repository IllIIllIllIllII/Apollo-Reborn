#import "ApolloAwardsParsing.h"
#import <libxml/HTMLparser.h>
#import <libxml/xpath.h>

static BOOL ApolloAwardsMatches(NSString *value, NSString *pattern) {
    if (![value isKindOfClass:NSString.class] || value.length == 0) return NO;
    NSString *anchored = [NSString stringWithFormat:@"\\A(?:%@)\\z", pattern];
    NSRange match = [value rangeOfString:anchored options:NSRegularExpressionSearch];
    return match.location == 0 && match.length == value.length;
}

NSString *ApolloAwardsNormalizeFullName(NSString *value) {
    if (![value isKindOfClass:NSString.class]) return nil;
    NSString *normalized = value.lowercaseString;
    return ApolloAwardsMatches(normalized, @"t[13]_[a-z0-9]{1,16}") ? normalized : nil;
}

static NSString *ApolloAwardsAttribute(xmlNodePtr node, const char *name) {
    xmlChar *bytes = xmlGetProp(node, BAD_CAST name);
    if (!bytes) return nil;
    NSString *value = [[NSString alloc] initWithUTF8String:(const char *)bytes];
    xmlFree(bytes);
    return value;
}

static NSString *ApolloAwardsText(xmlNodePtr node) {
    xmlChar *bytes = xmlNodeGetContent(node);
    if (!bytes) return nil;
    NSString *value = [[NSString alloc] initWithUTF8String:(const char *)bytes];
    xmlFree(bytes);
    return [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSArray<NSValue *> *ApolloAwardsNodes(xmlDocPtr document, xmlNodePtr parent,
                                           const char *expression) {
    xmlXPathContextPtr context = xmlXPathNewContext(document);
    if (!context) return @[];
    context->node = parent;
    xmlXPathObjectPtr result = xmlXPathEvalExpression(BAD_CAST expression, context);
    NSMutableArray *nodes = [NSMutableArray array];
    if (result && result->nodesetval) {
        for (int i = 0; i < result->nodesetval->nodeNr; i++) {
            [nodes addObject:[NSValue valueWithPointer:result->nodesetval->nodeTab[i]]];
        }
    }
    if (result) xmlXPathFreeObject(result);
    xmlXPathFreeContext(context);
    return nodes;
}

static xmlDocPtr ApolloAwardsDocumentWithLimit(NSString *HTML, NSString *closingTag, NSUInteger maximumBytes) {
    // Bound parsing work and distinguish a complete component from a truncated
    // download that libxml's HTML recovery could otherwise silently accept.
    if (![HTML isKindOfClass:NSString.class] || HTML.length > maximumBytes ||
        [HTML rangeOfString:closingTag options:NSCaseInsensitiveSearch].location == NSNotFound) return NULL;
    NSData *data = [HTML dataUsingEncoding:NSUTF8StringEncoding];
    if (data.length == 0 || data.length > maximumBytes) return NULL;
    return htmlReadMemory(data.bytes, (int)data.length, NULL, "UTF-8",
                          HTML_PARSE_NONET | HTML_PARSE_NOERROR | HTML_PARSE_NOWARNING);
}

static xmlDocPtr ApolloAwardsDocument(NSString *HTML, NSString *closingTag) {
    return ApolloAwardsDocumentWithLimit(HTML, closingTag, 2 * 1024 * 1024);
}

static BOOL ApolloAwardsSafeHTTPS(NSURLComponents *components, NSSet<NSString *> *hosts) {
    return [components.scheme.lowercaseString isEqualToString:@"https"] &&
        [hosts containsObject:components.host.lowercaseString] && !components.user &&
        !components.password && !components.port && !components.fragment;
}

static NSURL *ApolloAwardsValidatedPartial(NSString *source, NSString *fullName) {
    if (source.length == 0 || source.length > 2048 || [source hasPrefix:@"//"]) return nil;
    // The public /svc/shreddit routes are canonical on www: sh.reddit.com
    // redirects there even though the full website may use the sh hostname.
    // Use that canonical host directly so callers can reject every redirect.
    NSString *absolute = [source hasPrefix:@"/"]
        ? [@"https://www.reddit.com" stringByAppendingString:source] : source;
    NSURLComponents *components = [NSURLComponents componentsWithString:absolute];
    if (!ApolloAwardsSafeHTTPS(components, [NSSet setWithObject:@"www.reddit.com"]) ||
        ![components.path isEqualToString:components.percentEncodedPath] ||
        !ApolloAwardsMatches(components.path, @"/svc/shreddit/partial/[A-Za-z0-9_-]+/award-leaderboard")) return nil;

    // params is itself URL encoded. Require exactly one thingId and preserve
    // the server's signed URL verbatim; never construct or guess its signature.
    NSArray<NSURLQueryItem *> *items = components.queryItems;
    if (items.count != 2) return nil;
    NSString *params = nil;
    NSString *signature = nil;
    for (NSURLQueryItem *item in items) {
        if ([item.name isEqualToString:@"params"] && !params) params = item.value;
        else if ([item.name isEqualToString:@"sig"] && !signature) signature = item.value;
        else return nil;
    }
    if (![params isEqualToString:[@"thingId=" stringByAppendingString:fullName]] ||
        !ApolloAwardsMatches(signature, @"[A-Za-z0-9_.-]{1,512}")) return nil;
    return components.URL;
}

NSURL *ApolloAwardsLeaderboardURL(NSString *dialogHTML, NSString *fullName) {
    NSString *normalized = ApolloAwardsNormalizeFullName(fullName);
    if (!normalized) return nil;
    xmlDocPtr document = ApolloAwardsDocument(dialogHTML, @"</faceplate-partial>");
    if (!document) return nil;
    NSArray *partials = ApolloAwardsNodes(document, NULL,
        "//faceplate-partial[starts-with(@name, 'AwardLeaderboard_')]");
    NSURL *URL = nil;
    if (partials.count == 1) {
        URL = ApolloAwardsValidatedPartial(ApolloAwardsAttribute([partials[0] pointerValue], "src"), normalized);
    }
    xmlFreeDoc(document);
    return URL;
}

static BOOL ApolloAwardsHasClass(xmlNodePtr node, NSString *token) {
    NSArray *classes = [ApolloAwardsAttribute(node, "class")
        componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return [classes containsObject:token];
}

static NSString *ApolloAwardsAnimationURL(xmlNodePtr player) {
    NSString *source = ApolloAwardsAttribute(player, "src");
    if (source.length == 0 || source.length > 2048) return nil;
    NSURLComponents *URL = [NSURLComponents componentsWithString:source];
    if (!ApolloAwardsSafeHTTPS(URL, [NSSet setWithObjects:@"i.redd.it", @"www.redditstatic.com", nil]) ||
        URL.query || ![URL.path isEqualToString:URL.percentEncodedPath] || ![URL.path hasSuffix:@".json"]) return nil;
    BOOL knownPath = ([URL.host isEqualToString:@"i.redd.it"] &&
                     [URL.path hasPrefix:@"/snoovatar/snoo_assets/marketing/"]) ||
                    ([URL.host isEqualToString:@"www.redditstatic.com"] &&
                     [URL.path hasPrefix:@"/marketplace-assets/v1/core/awards/"]);
    if (!knownPath) return nil;
    for (NSString *part in URL.path.pathComponents) {
        if ([part isEqualToString:@"."] || [part isEqualToString:@".."]) return nil;
    }
    return source;
}

static NSDictionary *ApolloAwardsParseRow(xmlDocPtr document, xmlNodePtr row, NSString *fullName) {
    NSArray *reports = ApolloAwardsNodes(document, row, ".//report-award");
    NSArray *icons = ApolloAwardsNodes(document, row, ".//img | .//shreddit-lottie-player");
    // The gold amount has additional classes; this standalone count is the
    // exact quantity of this award, not the post's total or its gold value.
    NSArray *counts = ApolloAwardsNodes(document, row,
        ".//span[normalize-space(@class)='text-secondary-plain']");
    if (reports.count != 1 || icons.count != 1 || counts.count != 1) return nil;
    xmlNodePtr report = [reports[0] pointerValue];
    NSString *awardID = ApolloAwardsAttribute(report, "award-id");
    if (!ApolloAwardsMatches(awardID, @"award_[A-Za-z0-9_-]{1,120}") ||
        ![ApolloAwardsAttribute(report, "thing-id") isEqualToString:fullName]) return nil;

    NSString *countString = ApolloAwardsText([counts[0] pointerValue]);
    if (!ApolloAwardsMatches(countString, @"(?:[1-9][0-9]{0,8}|[1-9][0-9]{0,2}(?:,[0-9]{3}){1,2})")) return nil;
    NSInteger count = [[countString stringByReplacingOccurrencesOfString:@"," withString:@""] integerValue];
    if (count <= 0 || count > 999999999) return nil;

    xmlNodePtr icon = [icons[0] pointerValue];
    BOOL animated = xmlStrEqual(icon->name, BAD_CAST "shreddit-lottie-player");
    NSString *iconString = ApolloAwardsAttribute(icon, animated ? "placeholder-src" : "src");
    NSString *name = [ApolloAwardsAttribute(icon, animated ? "description" : "alt")
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (name.length == 0 || name.length > 128 ||
        [name rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) return nil;
    NSURLComponents *image = [NSURLComponents componentsWithString:iconString ?: @""];
    if (!ApolloAwardsSafeHTTPS(image, [NSSet setWithObjects:@"i.redd.it", @"www.redditstatic.com", nil]) ||
        image.query || ![image.path isEqualToString:image.percentEncodedPath]) return nil;
    BOOL knownPath = ([image.host isEqualToString:@"i.redd.it"] &&
                     [image.path hasPrefix:@"/snoovatar/snoo_assets/marketing/"]) ||
                    ([image.host isEqualToString:@"www.redditstatic.com"] &&
                     [image.path hasPrefix:@"/marketplace-assets/v1/core/awards/"]);
    if (!knownPath || ![image.path hasSuffix:@"_128.png"]) return nil;

    // The current leaderboard's static and animation-placeholder assets are
    // 128x128 PNGs (verified from all eight live fixture images' PNG headers).
    // Keep the actual asset size; never label a 128px URL as a 40px rendition.
    NSDictionary *resized = @{@"url": iconString, @"width": @128, @"height": @128};
    NSMutableDictionary *award = [@{@"id": awardID, @"name": name, @"description": name, @"count": @(count),
                                    @"icon_url": iconString, @"icon_width": @128, @"icon_height": @128,
                                    @"resized_icons": @[resized]} mutableCopy];
    // Animation is optional metadata, never a replacement for the static
    // fallback. Do not infer JSON paths from PNG filenames or other tags.
    NSString *animation = animated ? ApolloAwardsAnimationURL(icon) : nil;
    if (animation) award[@"animation_url"] = animation;
    return [award copy];
}

NSArray<NSDictionary *> *ApolloAwardsParseLeaderboard(NSString *HTML, NSString *fullName) {
    NSString *normalized = ApolloAwardsNormalizeFullName(fullName);
    if (!normalized) return nil;
    xmlDocPtr document = ApolloAwardsDocument(HTML, @"</award-leaderboard>");
    if (!document) return nil;
    NSArray *roots = ApolloAwardsNodes(document, NULL, "//award-leaderboard");
    NSMutableArray *awards = nil;
    if (roots.count == 1) {
        xmlNodePtr root = [roots[0] pointerValue];
        if ([ApolloAwardsAttribute(root, "thing-id") isEqualToString:normalized]) {
            NSArray *reports = ApolloAwardsNodes(document, root, ".//report-award");
            NSArray *empty = ApolloAwardsNodes(document, root,
                ".//award-dialog-leaderboard-entrypoint[starts-with(@pane-name, 'zero_state:')]");
            NSArray *panes = ApolloAwardsNodes(document, root,
                ".//faceplate-tabpanel/*[@slot='page-1']");
            if (reports.count == 0 && panes.count == 0 && empty.count == 1 &&
                [ApolloAwardsAttribute([empty[0] pointerValue], "thing-id") isEqualToString:normalized]) {
                awards = [NSMutableArray array];
            } else if (empty.count == 0 && panes.count == 1 && reports.count > 0 && reports.count <= 128) {
                xmlNodePtr pane = [panes[0] pointerValue];
                NSArray *paneReports = ApolloAwardsNodes(document, pane, ".//report-award");
                NSArray *rows = ApolloAwardsNodes(document, pane,
                    ".//div[contains(concat(' ', normalize-space(@class), ' '), ' flex ') and "
                    "contains(concat(' ', normalize-space(@class), ' '), ' justify-between ') and "
                    "contains(concat(' ', normalize-space(@class), ' '), ' px-sm ')]");
                NSMutableSet *seen = [NSMutableSet set];
                awards = paneReports.count == reports.count && rows.count == reports.count
                    ? [NSMutableArray array] : nil;
                for (NSValue *pointer in paneReports) {
                    if (!awards) break;
                    xmlNodePtr row = [pointer pointerValue];
                    while (row && row != pane &&
                           !(xmlStrEqual(row->name, BAD_CAST "div") &&
                             ApolloAwardsHasClass(row, @"flex") &&
                             ApolloAwardsHasClass(row, @"justify-between") &&
                             ApolloAwardsHasClass(row, @"px-sm"))) row = row->parent;
                    NSDictionary *award = row && row != pane ? ApolloAwardsParseRow(document, row, normalized) : nil;
                    if (!award || [seen containsObject:award[@"id"]]) { awards = nil; break; }
                    [seen addObject:award[@"id"]];
                    [awards addObject:award];
                }
            }
        }
    }
    xmlFreeDoc(document);
    return [awards copy];
}

ApolloAwardsUnparsedHTMLKind ApolloAwardsClassifyUnparsedHTML(NSString *HTML, NSString *fullName) {
    NSString *normalized = ApolloAwardsNormalizeFullName(fullName);
    if (!normalized) return ApolloAwardsUnparsedHTMLUnknown;
    xmlDocPtr document = ApolloAwardsDocument(HTML, @"</html>");
    if (document) {
        NSArray *titles = ApolloAwardsNodes(document, NULL, "//head/title");
        NSArray *challenges = ApolloAwardsNodes(document, NULL,
            "//form//*[contains(concat(' ', normalize-space(@class), ' '), ' g-recaptcha ')]");
        BOOL challenge = titles.count == 1 && challenges.count > 0 &&
            [ApolloAwardsText([titles[0] pointerValue]) isEqualToString:@"Reddit - Prove your humanity"];
        xmlFreeDoc(document);
        if (challenge) return ApolloAwardsUnparsedHTMLChallenge;
    }
    document = ApolloAwardsDocument(HTML, @"</award-leaderboard>");
    if (!document) return ApolloAwardsUnparsedHTMLUnknown;
    NSArray *roots = ApolloAwardsNodes(document, NULL, "//award-leaderboard");
    BOOL matching = roots.count == 1 &&
        [ApolloAwardsAttribute([roots[0] pointerValue], "thing-id") isEqualToString:normalized];
    xmlFreeDoc(document);
    // This is diagnostic classification, not evidence of zero awards. The
    // caller still receives nil from the parser for unsupported components.
    return matching ? ApolloAwardsUnparsedHTMLMatchingLeaderboard : ApolloAwardsUnparsedHTMLUnknown;
}

static NSUInteger ApolloAwardsTagCount(NSString *HTML, NSString *tag, BOOL closing) {
    NSString *pattern = [NSString stringWithFormat:@"<%@%@(?>[\\s>])", closing ? @"/" : @"", tag];
    NSRegularExpression *expression = [NSRegularExpression regularExpressionWithPattern:pattern
        options:NSRegularExpressionCaseInsensitive error:nil];
    return [expression numberOfMatchesInString:HTML options:0 range:NSMakeRange(0, HTML.length)];
}

static NSArray<NSValue *> *ApolloAwardsOwnCommentButtons(xmlDocPtr document, xmlNodePtr comment, NSString *fullName) {
    NSMutableArray *buttons = [NSMutableArray new];
    for (NSValue *pointer in ApolloAwardsNodes(document, comment, ".//award-button")) {
        xmlNodePtr button = pointer.pointerValue;
        if (![ApolloAwardsAttribute(button, "thing-id") isEqualToString:fullName]) continue;
        xmlNodePtr owner = button->parent;
        while (owner && owner != comment && !xmlStrEqual(owner->name, BAD_CAST "shreddit-comment")) owner = owner->parent;
        if (owner == comment) [buttons addObject:pointer];
    }
    return buttons;
}

NSDictionary<NSString *, NSNumber *> *ApolloAwardsParsePageCounts(NSString *HTML) {
    // Full feed/thread pages include scripts and text beyond the compact award
    // dialog. Match the transport's 4 MiB cap without widening partial parsing.
    NSUInteger const maximumPageBytes = 4 * 1024 * 1024;
    if (![HTML isKindOfClass:NSString.class] || HTML.length > maximumPageBytes) return nil;
    NSString *closing = [HTML rangeOfString:@"</shreddit-post>" options:NSCaseInsensitiveSearch].location != NSNotFound
        ? @"</shreddit-post>" : @"</shreddit-comment>";
    xmlDocPtr document = ApolloAwardsDocumentWithLimit(HTML, closing, maximumPageBytes);
    if (!document) return nil;
    NSArray *posts = ApolloAwardsNodes(document, NULL, "//shreddit-post");
    NSArray *comments = ApolloAwardsNodes(document, NULL, "//shreddit-comment");
    // libxml recovers truncated custom elements. Do not let an unfinished
    // page turn a missing count/button into a false zero. Require complete
    // component boundaries, including on pages with multiple rows.
    BOOL complete = posts.count + comments.count > 0 && posts.count + comments.count <= 2000;
    for (NSString *tag in @[@"shreddit-post", @"shreddit-comment"]) {
        NSUInteger expected = [tag isEqualToString:@"shreddit-post"] ? posts.count : comments.count;
        complete &= ApolloAwardsTagCount(HTML, tag, NO) == expected && ApolloAwardsTagCount(HTML, tag, YES) == expected;
    }
    if (!complete) { xmlFreeDoc(document); return nil; }
    NSMutableDictionary *counts = [NSMutableDictionary new];
    NSMutableSet *conflicted = [NSMutableSet new];
    for (NSValue *pointer in [posts arrayByAddingObjectsFromArray:comments]) {
        xmlNodePtr node = pointer.pointerValue;
        BOOL post = xmlStrEqual(node->name, BAD_CAST "shreddit-post");
        NSString *fullName = ApolloAwardsNormalizeFullName(ApolloAwardsAttribute(node, post ? "id" : "thingid"));
        if (![fullName hasPrefix:post ? @"t3_" : @"t1_"]) continue;
        NSString *source = ApolloAwardsAttribute(node, "award-count");
        NSNumber *count = ApolloAwardsMatches(source, @"(?:0|[1-9][0-9]{0,8})") ? @([source longLongValue]) : nil;
        NSArray *buttons = post ? @[] : ApolloAwardsOwnCommentButtons(document, node, fullName);
        if (!post && !xmlHasProp(node, BAD_CAST "award-count") && buttons.count == 1) {
            xmlNodePtr button = [buttons[0] pointerValue];
            if (!xmlHasProp(button, BAD_CAST "award-id") && !xmlHasProp(button, BAD_CAST "icon-url")) count = @0;
        }
        if (count && count.longLongValue == 0) {
            // Contradictory positive award metadata cannot seed a zero cache.
            if (post && (ApolloAwardsAttribute(node, "award-id").length ||
                         ApolloAwardsAttribute(node, "award-icon-url").length)) count = nil;
            for (NSValue *buttonPointer in buttons) {
                xmlNodePtr button = buttonPointer.pointerValue;
                if (ApolloAwardsAttribute(button, "award-id").length || ApolloAwardsAttribute(button, "icon-url").length) count = nil;
            }
        }
        NSNumber *previous = counts[fullName];
        if (!count || (previous && ![previous isEqualToNumber:count])) {
            [conflicted addObject:fullName];
            [counts removeObjectForKey:fullName];
        } else if (![conflicted containsObject:fullName]) {
            counts[fullName] = count;
        }
    }
    xmlFreeDoc(document);
    return [counts copy];
}
