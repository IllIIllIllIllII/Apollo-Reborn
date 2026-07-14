// ApolloChatsFilter.xm
//
// Add a "Direct Chat" row to the inbox "Boxes" list, directly above
// "Messages". API-key-free accounts open Reddit's authenticated modern Chat
// client because current Chat is no longer mirrored through /message. API-key
// accounts can choose modern Chat or keep Apollo's legacy filtered list.
//
// Boxes screen = _TtC6Apollo23InboxListViewController (a UITableViewController whose
// data-source methods are ObjC-visible). The "Messages" row maps to InboxType.messages and
// pushes a _TtC6Apollo19InboxViewController (inboxType=messages, messages:[RDKMessage],
// IGListKit listAdapter). We:
//   1. Detect the Messages section by the stock cell's text (layout is account-dependent).
//   2. Add one extra row at the top of that section, styled "Direct Chat".
//   3. On tap, open modern Reddit Chat when selected/required; otherwise invoke
//      the real Messages row as a legacy fallback.
//   4. In that fallback, filter the IGListKit objects to chat-subject messages.

#import "ApolloCommon.h"
#import "ApolloDirectChatWeb.h"
#import "ApolloState.h"
#import "ApolloUserProfileCache.h"
#import "ApolloSubredditInfoCache.h"
#import "ApolloSubredditCustomIconCache.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#define ChatsFilterLog(fmt, ...) ApolloLog(@"[ChatsFilter] " fmt, ##__VA_ARGS__)

// Row discovery must be scoped to each InboxListViewController. Apollo can keep
// more than one Boxes controller alive while accounts/tabs change; global row
// coordinates make one controller rewrite another controller's section.
@interface ApolloBoxesRowState : NSObject
@property (nonatomic, assign) NSInteger messagesSection;
@property (nonatomic, assign) NSInteger messagesRow;
@property (nonatomic, assign) NSInteger moderatorMailSection;
@property (nonatomic, assign) NSInteger moderatorMailRow;
@property (nonatomic, assign) NSInteger nativeDirectChatSection;
@property (nonatomic, assign) NSInteger nativeDirectChatRow;
@end

@implementation ApolloBoxesRowState
- (instancetype)init {
    self = [super init];
    if (self) {
        _messagesSection = _messagesRow = -1;
        _moderatorMailSection = _moderatorMailRow = -1;
        _nativeDirectChatSection = _nativeDirectChatRow = -1;
    }
    return self;
}
@end

static char kApolloBoxesRowStateKey;
static ApolloBoxesRowState *ApolloBoxesState(id controller, BOOL create) {
    ApolloBoxesRowState *state = objc_getAssociatedObject(controller, &kApolloBoxesRowStateKey);
    if (!state && create) {
        state = [ApolloBoxesRowState new];
        objc_setAssociatedObject(controller, &kApolloBoxesRowStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return state;
}

// Current Apollo builds already expose a native Direct Chat row for some
// accounts. Reuse it instead of adding a duplicate; insertion remains as a
// compatibility fallback for builds/account states where Apollo omits it.
static const BOOL sDirectChatRowEnabled = YES;
static BOOL sNextInboxIsChatFilter = NO;    // armed when the Direct Chat row is tapped
static char kChatFilterKey;                 // on InboxViewController: this list is chat-filtered
static __weak id sLatestBoxesController = nil;
static char kInboxAllChatHeaderKey;
static char kInboxAllOriginalHeaderKey;
static char kInboxAllStatusObserverKey;

// Modern Chat makes the row useful for cookie-auth API-free accounts as well as
// OAuth accounts, so it remains present for every signed-in account.
static BOOL ApolloDirectChatRowActive(void) { return sDirectChatRowEnabled; }

#pragma mark - helpers

// Find the cell's primary text whether it uses textLabel or a custom UILabel subview.
static NSString *ApolloCellText(UITableViewCell *cell) {
    if (cell.textLabel.text.length) return cell.textLabel.text;
    NSMutableArray<UIView *> *q = [NSMutableArray arrayWithObject:cell.contentView];
    while (q.count) {
        UIView *v = q.firstObject; [q removeObjectAtIndex:0];
        if ([v isKindOfClass:[UILabel class]] && ((UILabel *)v).text.length) return ((UILabel *)v).text;
        [q addObjectsFromArray:v.subviews];
    }
    return nil;
}

static void ApolloRestyleAsDirectChat(UITableViewCell *cell) {
    if (!cell) return;
    // IconTextTableViewCell uses a CUSTOM label, not cell.textLabel (which is lazy and always
    // non-nil — setting it just overlays a 2nd "Direct Chat" on top of "Messages"). Find the
    // label that actually shows the row text and the leading icon image view, and relabel both.
    UILabel *label = nil; UIImageView *icon = nil;
    NSMutableArray<UIView *> *q = [NSMutableArray arrayWithObject:cell.contentView];
    while (q.count) {
        UIView *v = q.firstObject; [q removeObjectAtIndex:0];
        if (!label && [v isKindOfClass:[UILabel class]] && ((UILabel *)v).text.length) label = (UILabel *)v;
        if (!icon  && [v isKindOfClass:[UIImageView class]] && ((UIImageView *)v).image) icon = (UIImageView *)v;
        [q addObjectsFromArray:v.subviews];
    }
    if (label) label.text = @"Direct Chat";
    if (@available(iOS 13.0, *)) {
        UIImage *glyph = [UIImage systemImageNamed:@"bubble.left.and.bubble.right"];
        if (icon && glyph) icon.image = [glyph imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
}

static void ApolloRememberSpecialBoxesCell(ApolloBoxesRowState *state,
                                            UITableViewCell *cell,
                                            NSIndexPath *indexPath) {
    if (!cell || !indexPath) return;
    NSString *text = ApolloCellText(cell);
    if ([text isEqualToString:@"Moderator Mail"] || [text isEqualToString:@"Mod Mail"]) {
        state.moderatorMailSection = indexPath.section;
        state.moderatorMailRow = indexPath.row;
        ChatsFilterLog(@"Moderator Mail at s=%ld r=%ld", (long)indexPath.section, (long)indexPath.row);
    } else if ([text isEqualToString:@"Direct Chat"]) {
        state.nativeDirectChatSection = indexPath.section;
        state.nativeDirectChatRow = indexPath.row;
        ChatsFilterLog(@"native Direct Chat at s=%ld r=%ld", (long)indexPath.section, (long)indexPath.row);
    }
}

static BOOL ApolloBoxesHasNativeDirectChat(ApolloBoxesRowState *state) {
    return state.nativeDirectChatSection >= 0 &&
           state.nativeDirectChatSection == state.messagesSection &&
           state.nativeDirectChatRow >= 0;
}

static BOOL ApolloBoxesUsesInsertedDirectChat(ApolloBoxesRowState *state) {
    return state.messagesSection >= 0 && !ApolloBoxesHasNativeDirectChat(state);
}

// Apollo builds the Boxes sections synchronously from currentUser.isMod / the
// moderated-subreddits array. During an API-key-free sign-in the account-change
// notification can arrive before those models finish hydrating, so refresh the
// already-visible root a couple of times after a switch. This lets Moderator
// Mail appear without requiring a relaunch.
static UITableView *ApolloBoxesTableView(id controller) {
    if (!controller) return nil;
    Ivar ivar = class_getInstanceVariable([controller class], "tableView");
    id value = ivar ? object_getIvar(controller, ivar) : nil;
    return [value isKindOfClass:[UITableView class]] ? value : nil;
}

static void ApolloRefreshBoxesForModeratorState(NSString *reason) {
    dispatch_async(dispatch_get_main_queue(), ^{
        id controller = sLatestBoxesController;
        UITableView *tableView = ApolloBoxesTableView(controller);
        if (!tableView) return;
        [tableView reloadData];
        ChatsFilterLog(@"reloaded Boxes after moderator state update (%@)", reason ?: @"unknown");
    });
}

#pragma mark - Inbox (All): unified modern Chat entry

@interface ApolloInboxAllChatHeaderView : UIControl
@property (nonatomic, strong) UIView *cardView;
@property (nonatomic, strong) UIImageView *chatIconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *detailLabel;
@property (nonatomic, strong) UILabel *unreadBadgeLabel;
@property (nonatomic, strong) UIImageView *chevronView;
- (void)apollo_refreshForTraits:(UITraitCollection *)traits;
@end

@implementation ApolloInboxAllChatHeaderView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.cardView = [UIView new];
    self.cardView.userInteractionEnabled = NO;
    self.cardView.layer.cornerRadius = 14.0;
    self.cardView.layer.borderWidth = 0.5;
    [self addSubview:self.cardView];

    self.chatIconView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"bubble.left.and.bubble.right.fill"]];
    self.chatIconView.contentMode = UIViewContentModeScaleAspectFit;
    [self.cardView addSubview:self.chatIconView];

    self.titleLabel = [UILabel new];
    self.titleLabel.text = @"Reddit Chat";
    self.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    [self.cardView addSubview:self.titleLabel];

    self.detailLabel = [UILabel new];
    self.detailLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    self.detailLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.cardView addSubview:self.detailLabel];

    self.unreadBadgeLabel = [UILabel new];
    self.unreadBadgeLabel.text = @"NEW";
    self.unreadBadgeLabel.font = [UIFont systemFontOfSize:10.0 weight:UIFontWeightBold];
    self.unreadBadgeLabel.textAlignment = NSTextAlignmentCenter;
    self.unreadBadgeLabel.layer.cornerRadius = 9.0;
    self.unreadBadgeLabel.clipsToBounds = YES;
    [self.cardView addSubview:self.unreadBadgeLabel];

    self.chevronView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
    self.chevronView.contentMode = UIViewContentModeScaleAspectFit;
    [self.cardView addSubview:self.chevronView];

    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.cardView.frame = CGRectInset(self.bounds, 12.0, 7.0);
    CGFloat height = self.cardView.bounds.size.height;
    self.chatIconView.frame = CGRectMake(16.0, (height - 30.0) / 2.0, 30.0, 30.0);
    self.chevronView.frame = CGRectMake(self.cardView.bounds.size.width - 28.0, (height - 17.0) / 2.0, 10.0, 17.0);
    self.unreadBadgeLabel.frame = CGRectMake(self.cardView.bounds.size.width - 82.0, 13.0, 42.0, 18.0);
    CGFloat textRight = self.unreadBadgeLabel.hidden ? self.chevronView.frame.origin.x - 12.0 : self.unreadBadgeLabel.frame.origin.x - 8.0;
    self.titleLabel.frame = CGRectMake(58.0, 11.0, MAX(20.0, textRight - 58.0), 24.0);
    self.detailLabel.frame = CGRectMake(58.0, 36.0, MAX(20.0, self.chevronView.frame.origin.x - 70.0), 21.0);
}

- (void)apollo_refreshForTraits:(UITraitCollection *)traits {
    NSDictionary *status = ApolloModernChatCachedStatus();
    BOOL unread = [status[@"hasUnread"] boolValue];
    NSString *preview = [status[@"preview"] isKindOfClass:[NSString class]] ? status[@"preview"] : nil;
    if (preview.length > 0) {
        self.detailLabel.text = preview;
    } else if (unread) {
        self.detailLabel.text = @"You have a new Chat message";
    } else {
        self.detailLabel.text = @"Direct chats, requests & mod mail";
    }
    self.unreadBadgeLabel.hidden = !unread;

    UIColor *accent = ApolloModernChatThemeColor(traits, @"accent");
    UIColor *raised = ApolloModernChatThemeColor(traits, @"tertiary");
    UIColor *separator = ApolloModernChatThemeColor(traits, @"separator");
    UIColor *text = ApolloModernChatThemeColor(traits, @"text");
    UIColor *secondaryText = ApolloModernChatThemeColor(traits, @"secondaryText");
    self.cardView.backgroundColor = raised;
    self.cardView.layer.borderColor = separator.CGColor;
    self.chatIconView.tintColor = accent;
    self.chevronView.tintColor = secondaryText;
    self.titleLabel.textColor = text;
    self.detailLabel.textColor = secondaryText;
    self.unreadBadgeLabel.backgroundColor = accent;
    self.unreadBadgeLabel.textColor = ApolloColorIsLight(accent) ? UIColor.blackColor : UIColor.whiteColor;
    [self setNeedsLayout];
}

@end

static BOOL ApolloInboxControllerIsAll(id controller) {
    Ivar ivar = class_getInstanceVariable([controller class], "inboxType");
    if (ivar) {
        uint8_t raw = *((uint8_t *)(__bridge void *)controller + ivar_getOffset(ivar));
        if (raw == 0) return YES; // Apollo.InboxType.inbox is the first enum case.
    }
    return [((UIViewController *)controller).title isEqualToString:@"Inbox"];
}

static UITableView *ApolloInboxControllerTableView(id controller) {
    Ivar ivar = class_getInstanceVariable([controller class], "tableNode");
    id tableNode = ivar ? object_getIvar(controller, ivar) : nil;
    if ([tableNode respondsToSelector:@selector(view)]) {
        id view = ((id (*)(id, SEL))objc_msgSend)(tableNode, @selector(view));
        if ([view isKindOfClass:[UITableView class]]) return view;
    }
    return nil;
}

static void ApolloInstallInboxAllChatHeader(id controller) {
    if (!ApolloInboxControllerIsAll(controller)) return;
    UITableView *tableView = ApolloInboxControllerTableView(controller);
    if (!tableView) return;

    ApolloInboxAllChatHeaderView *header = objc_getAssociatedObject(controller, &kInboxAllChatHeaderKey);
    if (!ApolloModernChatShouldOpen()) {
        if (header) {
            tableView.tableHeaderView = objc_getAssociatedObject(controller, &kInboxAllOriginalHeaderKey);
            objc_setAssociatedObject(controller, &kInboxAllChatHeaderKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }

    if (!header) {
        UIView *original = tableView.tableHeaderView;
        objc_setAssociatedObject(controller, &kInboxAllOriginalHeaderKey, original, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        CGFloat oldHeight = original ? CGRectGetHeight(original.frame) : 0.0;
        CGFloat width = CGRectGetWidth(tableView.bounds) ?: CGRectGetWidth(((UIViewController *)controller).view.bounds);
        UIView *wrapper = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, oldHeight + 82.0)];
        if (original) {
            original.frame = CGRectMake(0, 0, width, oldHeight);
            [wrapper addSubview:original];
        }
        header = [[ApolloInboxAllChatHeaderView alloc] initWithFrame:CGRectMake(0, oldHeight, width, 82.0)];
        header.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [header addTarget:controller action:NSSelectorFromString(@"apollo_openModernChatFromAllInbox") forControlEvents:UIControlEventTouchUpInside];
        [wrapper addSubview:header];
        tableView.tableHeaderView = wrapper;
        objc_setAssociatedObject(controller, &kInboxAllChatHeaderKey, header, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ChatsFilterLog(@"installed modern Chat entry in Inbox (All)");
    }
    [header apollo_refreshForTraits:((UIViewController *)controller).traitCollection];
}

#pragma mark - Boxes list: add the Direct Chat row

// Which index-path delegate methods must be remapped for the inserted Direct Chat row? Two layers:
//   * _TtC6Apollo23InboxListViewController's OWN methods (otool class metadata): initWithCoder:,
//     viewDidLoad, numberOfSectionsInTableView:, tableView:numberOfRowsInSection:,
//     tableView:cellForRowAtIndexPath:, tableView:heightForHeaderInSection:,
//     tableView:didSelectRowAtIndexPath:, redditAccountChangedWithNotification:. Of these the only
//     row/index-path ones are cellForRowAtIndexPath:/didSelectRowAtIndexPath: (remapped), numberOfRows
//     is overridden, and heightForHeaderInSection: is section-based.
//   * INHERITED methods matter too — respondsToSelector: (what UITableView dispatches on) sees the
//     whole chain. The runtime canary below caught that the base class _TtC6Apollo25ApolloTableViewController
//     implements tableView:heightForRowAtIndexPath:, which InboxListViewController inherits — so
//     UITableView calls it for every row with our *displayed* index paths. It returns a uniform
//     (self-sizing) height today, so the off-by-one was harmless in practice, but we remap it anyway
//     for correctness + safety (a future per-row height would otherwise mis-size). (Raised by @nickclyde.)
// The canary still watches the OTHER row selectors so a future Apollo build that adds one is caught.
static void ApolloWarnIfUnhandledRowDelegates(id vc) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Row-based selectors we do NOT remap; if Apollo (or a base class) starts implementing any, it
        // would receive our shifted *displayed* index paths unremapped. cellFor/didSelect/heightForRow
        // are handled below, so they're intentionally absent here.
        NSArray<NSString *> *risky = @[
            @"tableView:estimatedHeightForRowAtIndexPath:",
            @"tableView:willDisplayCell:forRowAtIndexPath:",
            @"tableView:didEndDisplayingCell:forRowAtIndexPath:",
            @"tableView:canEditRowAtIndexPath:",
            @"tableView:editActionsForRowAtIndexPath:",
            @"tableView:leadingSwipeActionsConfigurationForRowAtIndexPath:",
            @"tableView:trailingSwipeActionsConfigurationForRowAtIndexPath:",
            @"tableView:commitEditingStyle:forRowAtIndexPath:",
            @"tableView:contextMenuConfigurationForRowAtIndexPath:point:",
            @"tableView:accessoryButtonTappedForRowWithIndexPath:",
            @"tableView:canMoveRowAtIndexPath:",
            @"tableView:moveRowAtIndexPath:toIndexPath:",
        ];
        for (NSString *sel in risky) {
            if ([vc respondsToSelector:NSSelectorFromString(sel)])
                ChatsFilterLog(@"WARNING: InboxListViewController now implements %@ — the Direct Chat row shift may mis-index it; remap it too.", sel);
        }
    });
}

%hook _TtC6Apollo23InboxListViewController

- (void)viewDidLoad {
    %orig;
    sLatestBoxesController = self;
    ApolloBoxesState(self, YES);
}

- (void)redditAccountChangedWithNotification:(id)notification {
    %orig;
    sLatestBoxesController = self;
    // Section membership changes with moderator status. Force a fresh probe so
    // stale coordinates from the previous account cannot route the wrong row.
    objc_setAssociatedObject(self, &kApolloBoxesRowStateKey,
                             [ApolloBoxesRowState new], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.75 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (sLatestBoxesController == self) ApolloRefreshBoxesForModeratorState(@"account switch +0.75s");
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (sLatestBoxesController == self) ApolloRefreshBoxesForModeratorState(@"account switch +2s");
    });
}

- (long long)tableView:(UITableView *)tableView numberOfRowsInSection:(long long)section {
    if (ApolloDirectChatRowActive()) ApolloWarnIfUnhandledRowDelegates(self);   // one-shot future-proofing canary
    long long n = %orig;
    ApolloBoxesRowState *state = ApolloBoxesState(self, YES);
    if (ApolloDirectChatRowActive() && ApolloBoxesUsesInsertedDirectChat(state) &&
        section == state.messagesSection) {
        n += 1;   // + our Direct Chat row
    }
    return n;
}

// Map a displayed row (with our inserted Direct Chat row) back to Apollo's real row in the
// Messages section. The Direct Chat row sits AT sMessagesRow (just above Messages); rows below it
// shift down by one. Returns -1 for the Direct Chat slot itself.
static NSInteger ApolloRealMessagesRow(ApolloBoxesRowState *state, NSInteger displayedRow) {
    if (!ApolloBoxesUsesInsertedDirectChat(state)) return displayedRow;
    if (displayedRow < state.messagesRow) return displayedRow;     // rows above Messages: unchanged
    if (displayedRow == state.messagesRow) return -1;              // our inserted Direct Chat row
    return displayedRow - 1;                                  // rows at/after Messages: shifted down
}

- (id)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (!ApolloDirectChatRowActive()) return %orig;   // Direct Chat row disabled / keyless — leave Boxes untouched
    ApolloBoxesRowState *state = ApolloBoxesState(self, YES);
    // Detection pass: until we know which section/row holds "Messages", just observe.
    if (state.messagesSection < 0) {
        UITableViewCell *cell = %orig;
        NSString *text = ApolloCellText(cell);
        ApolloRememberSpecialBoxesCell(state, cell, indexPath);
        ChatsFilterLog(@"probe s=%ld r=%ld text=%@ cls=%@", (long)indexPath.section, (long)indexPath.row, text, NSStringFromClass([cell class]));
        if ([text isEqualToString:@"Messages"]) {
            state.messagesSection = indexPath.section;
            state.messagesRow = indexPath.row;
            BOOL native = ApolloBoxesHasNativeDirectChat(state);
            ChatsFilterLog(@"Messages at s=%ld r=%ld; %@ Direct Chat row + reloading",
                           (long)state.messagesSection, (long)state.messagesRow,
                           native ? @"reusing native" : @"inserting");
            UITableView *tv = tableView;
            dispatch_async(dispatch_get_main_queue(), ^{ [tv reloadData]; });
        }
        return cell;
    }

    if (indexPath.section == state.messagesSection) {
        // When Apollo already provides this row, leave the data-source mapping
        // untouched. didSelect below decides whether it opens Apollo's legacy
        // chat or the new authenticated Reddit Chat.
        if (ApolloBoxesHasNativeDirectChat(state)) return %orig;
        NSInteger realRow = ApolloRealMessagesRow(state, indexPath.row);
        if (realRow < 0) {
            // our inserted Direct Chat row: borrow the Messages cell and restyle it
            NSIndexPath *real = [NSIndexPath indexPathForRow:state.messagesRow inSection:state.messagesSection];
            UITableViewCell *cell = %orig(tableView, real);
            ChatsFilterLog(@"cellFor displayed=%ld -> DirectChat (borrow r%ld, was '%@')", (long)indexPath.row, (long)state.messagesRow, ApolloCellText(cell));
            ApolloRestyleAsDirectChat(cell);
            return cell;
        }
        // every other row maps to its real Apollo row (Messages, and anything after it)
        NSIndexPath *real = [NSIndexPath indexPathForRow:realRow inSection:state.messagesSection];
        UITableViewCell *cell = %orig(tableView, real);
        ChatsFilterLog(@"cellFor displayed=%ld -> real r%ld text='%@'", (long)indexPath.row, (long)realRow, ApolloCellText(cell));
        return cell;
    }
    UITableViewCell *cell = %orig;
    ApolloRememberSpecialBoxesCell(state, cell, indexPath);
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    ApolloBoxesRowState *state = ApolloBoxesState(self, YES);
    if (ApolloModernModmailShouldOpen() &&
        indexPath.section == state.moderatorMailSection && indexPath.row == state.moderatorMailRow) {
        ChatsFilterLog(@"Moderator Mail tapped -> opening modern authenticated web Modmail");
        UIViewController *controller = ApolloCreateModernModmailViewController();
        [((UIViewController *)self).navigationController pushViewController:controller animated:YES];
        dispatch_async(dispatch_get_main_queue(), ^{
            [tableView deselectRowAtIndexPath:indexPath animated:NO];
        });
        return;
    }
    if (ApolloDirectChatRowActive() && state.messagesSection >= 0 && indexPath.section == state.messagesSection) {
        BOOL nativeChatRow = ApolloBoxesHasNativeDirectChat(state) && indexPath.row == state.nativeDirectChatRow;
        NSInteger realRow = ApolloRealMessagesRow(state, indexPath.row);
        if (nativeChatRow || realRow < 0) {
            if (ApolloModernChatShouldOpen()) {
                ChatsFilterLog(@"Direct Chat tapped -> opening modern Reddit Chat");
                UIViewController *controller = ApolloCreateModernChatViewController();
                [((UIViewController *)self).navigationController pushViewController:controller animated:YES];
                dispatch_async(dispatch_get_main_queue(), ^{
                    for (NSIndexPath *selectedPath in ([tableView indexPathsForSelectedRows] ?: @[])) {
                        [tableView deselectRowAtIndexPath:selectedPath animated:NO];
                    }
                });
                return;
            }
            if (nativeChatRow) {
                ChatsFilterLog(@"Direct Chat tapped -> preserving Apollo legacy Chat");
                %orig;
                return;
            }
            ChatsFilterLog(@"Direct Chat tapped -> opening filtered messages list");
            sNextInboxIsChatFilter = YES;   // one-shot: the next InboxViewController filters to chats
            realRow = state.messagesRow;          // open the real Messages list (which we then filter)
        }
        %orig(tableView, [NSIndexPath indexPathForRow:realRow inSection:state.messagesSection]);
        // We handed Apollo the REAL indexPath, so its own deselect-on-return clears the wrong row.
        // Defer to after the push settles and clear ALL selected rows (the index remap can leave
        // more than one marked) so the tapped row doesn't stay highlighted.
        NSIndexPath *tapped = indexPath;
        dispatch_async(dispatch_get_main_queue(), ^{
            for (NSIndexPath *ip in ([tableView indexPathsForSelectedRows] ?: @[]))
                [tableView deselectRowAtIndexPath:ip animated:NO];
            [tableView deselectRowAtIndexPath:tapped animated:NO];
        });
        return;
    }
    %orig;
}

// Inherited from _TtC6Apollo25ApolloTableViewController (caught by the canary above) and therefore
// called by UITableView for every row — so it must be remapped like cellFor/didSelect, or rows
// at/after Messages get the height of the wrong real row and the Direct Chat row gets an arbitrary
// one. Map our displayed index path back to Apollo's real row; the Direct Chat row borrows the
// Messages row's height. (Raised by @nickclyde in review.)
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    ApolloBoxesRowState *state = ApolloBoxesState(self, YES);
    if (ApolloDirectChatRowActive() && ApolloBoxesUsesInsertedDirectChat(state) &&
        indexPath.section == state.messagesSection) {
        NSInteger realRow = ApolloRealMessagesRow(state, indexPath.row);
        if (realRow < 0) realRow = state.messagesRow;   // Direct Chat row -> same height as the Messages row
        return %orig(tableView, [NSIndexPath indexPathForRow:realRow inSection:state.messagesSection]);
    }
    return %orig;
}

%end

#pragma mark - messages list: filter to chats

// Keep only chat-subject messages (direct + group chats both carry a "chat room" subject;
// regular PMs/modmail have a real subject, so they fall away).
static NSArray *ApolloChatFilterToChats(NSArray *messages) {
    if (![messages isKindOfClass:[NSArray class]]) return messages;
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:messages.count];
    for (id msg in messages) {
        NSString *subject = nil;
        if ([msg respondsToSelector:@selector(subject)])
            subject = ((NSString *(*)(id, SEL))objc_msgSend)(msg, @selector(subject));
        if (subject && [subject localizedCaseInsensitiveContainsString:@"chat room"]) [out addObject:msg];
    }
    ChatsFilterLog(@"filtered messages %lu -> %lu chats", (unsigned long)messages.count, (unsigned long)out.count);
    return out;
}

// Apollo's list is fed by a Swift Apollo.ListAdapterDataSource (not ObjC-hookable) reading the
// `messages` ivar, so we filter one level up: at the RDKClient message-inbox fetch, while the
// chat-filtered list is the visible one (sChatFilterActive). The Messages box itself never sets
// the flag, so it stays unfiltered.
static BOOL sChatFilterActive = NO;

%hook _TtC6Apollo19InboxViewController

- (void)viewDidLoad {
    // Set the flag BEFORE %orig — Apollo's viewDidLoad kicks off the initial fetch, so the flag
    // must already be armed or that fetch slips through unfiltered.
    if (sNextInboxIsChatFilter) {
        sNextInboxIsChatFilter = NO;
        objc_setAssociatedObject(self, &kChatFilterKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        sChatFilterActive = YES;
        ChatsFilterLog(@"InboxViewController marked chat-filtered");
    }
    %orig;
    if ([objc_getAssociatedObject(self, &kChatFilterKey) boolValue])
        ((UIViewController *)self).title = @"Direct Chat";   // after %orig so Apollo doesn't override it
    if (ApolloInboxControllerIsAll(self) && ![objc_getAssociatedObject(self, &kInboxAllStatusObserverKey) boolValue]) {
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:NSSelectorFromString(@"apollo_modernChatStatusChanged:")
                                                     name:ApolloModernChatStatusDidChangeNotification
                                                   object:nil];
        objc_setAssociatedObject(self, &kInboxAllStatusObserverKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        dispatch_async(dispatch_get_main_queue(), ^{ ApolloInstallInboxAllChatHeader(self); });
    }
}
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    if ([objc_getAssociatedObject(self, &kChatFilterKey) boolValue]) sChatFilterActive = YES;
    ApolloInstallInboxAllChatHeader(self);
}
- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    if ([objc_getAssociatedObject(self, &kChatFilterKey) boolValue]) sChatFilterActive = NO;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    %orig;
}

%new
- (void)apollo_modernChatStatusChanged:(NSNotification *)notification {
    ApolloInstallInboxAllChatHeader(self);
}

%new
- (void)apollo_openModernChatFromAllInbox {
    if (!ApolloModernChatShouldOpen()) return;
    UIViewController *chat = ApolloCreateModernChatViewController();
    [((UIViewController *)self).navigationController pushViewController:chat animated:YES];
}
%end

// Safety: opening a chat THREAD must never run with the inbox-list filter armed, or a thread
// refresh that happens to use messagesInCategory could be filtered. Clear the flag on thread show.
%hook _TtC6Apollo28PrivateMessageViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    sChatFilterActive = NO;
}
%end

// Re-entrancy guard for the accumulate-paging below: a nested page-pull does a single filtered page
// and passes the real pagination token straight through (it must NOT re-accumulate). The flag is only
// ever toggled synchronously on the main thread around the nested call (the call just kicks off an
// async task and returns), so a plain BOOL needs no lock.
static BOOL sChatPagingInProgress = NO;
static const NSInteger kMaxChatFilterPages = 8;   // cap so a chat-sparse account can't page forever

%hook RDKClient
// NOTE: `category` is an enum (NSInteger), NOT an object — declaring it `id` makes ARC retain
// the integer value as a pointer (EXC_BAD_ACCESS at 0x2). It MUST be a scalar type.
- (id)messagesInCategory:(long long)category pagination:(id)pagination markRead:(BOOL)markRead completion:(id)completion {
    ChatsFilterLog(@"messagesInCategory cat=%lld active=%d nested=%d", category, sChatFilterActive, sChatPagingInProgress);
    if (!completion || !sChatFilterActive) return %orig;

    // A nested page-pull kicked off by the accumulator below: filter this one page and pass the real
    // pagination token straight through so the accumulator can decide whether to keep going.
    if (sChatPagingInProgress) {
        id wrapped = ^(NSArray *messages, id page, NSError *error) {
            ((void (^)(NSArray *, id, NSError *))completion)(ApolloChatFilterToChats(messages), page, error);
        };
        return %orig(category, pagination, NO, wrapped);
    }

    // Top-level chat-filtered load. Filtering one page to chats can leave it EMPTY when that page holds
    // only non-chat PMs — and Apollo's list (IGListKit) only requests the next page when its bottom
    // LoadNextPage cell appears, which an empty list never shows, so older chats further back would
    // never load. So accumulate across pages until we have at least one chat (or Reddit runs out of
    // pages, or we hit the cap), then deliver a non-empty page carrying the LAST page's pagination
    // token so Apollo's own load-more continues from where we stopped. (Reported by @nickclyde in
    // review.) RDKPagination.after is an NSString (verified in the binary); nil/empty == no more pages.
    NSMutableArray *acc = [NSMutableArray array];
    __block NSInteger pages = 0;
    __weak id weakSelf = self;   // RDKClient is only forward-declared here; message it dynamically
    void (^deliver)(id, NSError *) = ^(id page, NSError *error) {
        ((void (^)(NSArray *, id, NSError *))completion)(acc, page, error);
    };
    // The page-puller references itself (via the __block `step`) to recurse, then nils itself when it
    // stops, so the self-reference is deliberately broken — silence the (correct-in-general) retain
    // cycle warning for just this block. The block is strongly held by the in-flight fetch's completion
    // until we nil it on delivery, so liveness is guaranteed and there's no actual leak.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-retain-cycles"
    __block void (^step)(NSArray *, id, NSError *) = nil;
    step = ^(NSArray *chats, id page, NSError *error) {
        [acc addObjectsFromArray:(chats ?: @[])];
        pages++;
        // RDKPagination.after is an NSString (verified in the binary) but RDKPagination isn't imported,
        // so read it dynamically; nil/empty == no more pages.
        NSString *after = [page respondsToSelector:@selector(after)]
            ? ((NSString *(*)(id, SEL))objc_msgSend)(page, @selector(after)) : nil;
        BOOL morePages = ([after isKindOfClass:[NSString class]] && after.length > 0);
        id ss = weakSelf;
        if (acc.count == 0 && morePages && !error && ss && pages < kMaxChatFilterPages) {
            ChatsFilterLog(@"page %ld had 0 chats; pulling next (after=%@)", (long)pages, after);
            sChatPagingInProgress = YES;
            ((id (*)(id, SEL, long long, id, BOOL, id))objc_msgSend)(
                ss, @selector(messagesInCategory:pagination:markRead:completion:), category, page, (BOOL)NO, step);
            sChatPagingInProgress = NO;
        } else {
            ChatsFilterLog(@"delivering %lu chat(s) after %ld page(s)", (unsigned long)acc.count, (long)pages);
            deliver(page, error);
            step = nil;   // break the recursive block's self-reference so it deallocs
        }
    };
#pragma clang diagnostic pop
    id firstWrapped = ^(NSArray *messages, id page, NSError *error) {
        step(ApolloChatFilterToChats(messages), page, error);
    };
    return %orig(category, pagination, NO, firstWrapped);   // markRead:NO so the filtered view doesn't mark PMs read
}
%end

#pragma mark - sender avatar / subreddit icon on inbox rows

// The inbox is AsyncDisplayKit (Texture): each row is an Apollo.InboxCellNode backed by an RDKMessage
// in its `message` ivar. We overlay a small circular image to the left of the row's identity button,
// gated by the Show User Avatars toggle. Identity is resolved from the MODEL (not parsed text):
//   - reply/mention notifications (contentType 0/1/2) -> the other user's avatar (message.author)
//   - PM to/from a subreddit (modmail / "to #sub")     -> the subreddit's icon (message.subreddit)
//   - sent PM        -> the recipient's avatar (message.recipient)
//   - received PM / direct chat room -> the sender's avatar (message.author)
//   - new-modmail rows (message nil) -> the conversation's subreddit icon, else the participant avatar
#define APOLLO_INBOX_AVATAR_DEBUG 0   // flip to 1 for verbose per-row resolved kind/identity logging

static char kInboxAvatarKey;          // on the cell's view: our image UIImageView
static char kInboxAvatarIdentityKey;  // on the image view: the identity it currently shows ("u:name" / "r:sub")

typedef NS_ENUM(NSInteger, ApolloInboxIconKind) {
    ApolloInboxIconNone = 0,
    ApolloInboxIconUser,
    ApolloInboxIconSubreddit,
};

static CGRect ApolloNodeFrame(id node) {
    if (![node respondsToSelector:@selector(frame)]) return CGRectZero;
    return ((CGRect (*)(id, SEL))objc_msgSend)(node, @selector(frame));
}

// Read a Swift/ObjC ivar by name off any object (the InboxCellNode's model + button-node ivars).
static id ApolloInboxIvarValue(id object, NSString *name) {
    if (!object || name.length == 0) return nil;
    for (Class cls = [object class]; cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        Ivar ivar = class_getInstanceVariable(cls, name.UTF8String);
        if (!ivar) continue;
        @try { return object_getIvar(object, ivar); }
        @catch (__unused NSException *e) { return nil; }
    }
    return nil;
}

static NSString *ApolloInboxStringProp(id obj, SEL sel) {
    if (!obj || ![obj respondsToSelector:sel]) return nil;
    id v = ((id (*)(id, SEL))objc_msgSend)(obj, sel);
    return [v isKindOfClass:[NSString class]] ? v : nil;
}

static NSString *ApolloInboxNormUser(NSString *username) {
    if (![username isKindOfClass:[NSString class]]) return nil;
    NSString *clean = [username stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([clean hasPrefix:@"u/"] || [clean hasPrefix:@"U/"]) clean = [clean substringFromIndex:2];
    if (clean.length == 0) return nil;
    if ([clean isEqualToString:@"[deleted]"] || [clean isEqualToString:@"deleted"]) return nil;
    return clean;
}

// Subreddit name as the icon caches want it: the caches strip "r/" variants + lowercase internally,
// but they do NOT strip a leading "#" (modmail dests like "#dbz"), so do that here.
static NSString *ApolloInboxSubredditClean(NSString *name) {
    if (![name isKindOfClass:[NSString class]]) return nil;
    NSString *s = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    while ([s hasPrefix:@"#"]) s = [[s substringFromIndex:1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (s.length == 0 || [s isEqualToString:@"[deleted]"]) return nil;
    return s;
}

static NSString *ApolloInboxUsernameFromObject(id object) {
    if (!object) return nil;
    if ([object isKindOfClass:[NSString class]]) return ApolloInboxNormUser(object);
    NSString *u = ApolloInboxStringProp(object, @selector(author));
    if (!u) u = ApolloInboxStringProp(object, @selector(username));
    if (!u) u = ApolloInboxStringProp(object, @selector(name));
    return ApolloInboxNormUser(u);
}

static NSString *ApolloInboxCurrentUser(void) {
    Class clientClass = objc_getClass("RDKClient");
    if (!clientClass || ![clientClass respondsToSelector:@selector(sharedClient)]) return nil;
    id client = ((id (*)(id, SEL))objc_msgSend)(clientClass, @selector(sharedClient));
    if (!client || ![client respondsToSelector:@selector(currentUser)]) return nil;
    id user = ((id (*)(id, SEL))objc_msgSend)(client, @selector(currentUser));
    return ApolloInboxUsernameFromObject(user);
}

// Resolve the row's icon kind + identity string + the button node to anchor the overlay to.
static ApolloInboxIconKind ApolloInboxResolveIdentity(id cellNode, NSString **outIdentity, id *outAnchor) {
    *outIdentity = nil;
    if (outAnchor) *outAnchor = nil;

    id msg = ApolloInboxIvarValue(cellNode, @"message");
    if (msg) {
        long long ct = [msg respondsToSelector:@selector(contentType)]
            ? ((long long (*)(id, SEL))objc_msgSend)(msg, @selector(contentType)) : -1;
        NSString *author    = ApolloInboxStringProp(msg, @selector(author));
        NSString *recipient = ApolloInboxStringProp(msg, @selector(recipient));
        NSString *subreddit = ApolloInboxStringProp(msg, @selector(subreddit));

        if (ct == 0 || ct == 1 || ct == 2) {
            // post reply / comment reply / username mention -> the other user (the replier/mentioner).
            NSString *u = ApolloInboxNormUser(author);
            if (u) { *outIdentity = u; if (outAnchor) *outAnchor = ApolloInboxIvarValue(cellNode, @"authorButtonNode"); return ApolloInboxIconUser; }
            // Replier/mentioner is deleted/suspended: fall back to the community icon if we know it.
            NSString *s = ApolloInboxSubredditClean(subreddit);
            if (s) {
                *outIdentity = s;
                if (outAnchor) *outAnchor = ApolloInboxIvarValue(cellNode, @"subredditButtonNode") ?: ApolloInboxIvarValue(cellNode, @"authorButtonNode");
                return ApolloInboxIconSubreddit;
            }
        } else {
            // PM (contentType 3) or unknown: a non-empty subreddit means a modmail/subreddit message.
            NSString *s = ApolloInboxSubredditClean(subreddit);
            if (s) { *outIdentity = s; if (outAnchor) *outAnchor = ApolloInboxIvarValue(cellNode, @"subredditButtonNode"); return ApolloInboxIconSubreddit; }

            // Sent vs received: I sent it IFF I'm the author. recipientButtonNode exists on BOTH sent
            // and received rows (Apollo renders "to <other>" / the sender alike), so it can't decide
            // this — it's only a fallback when the current user is unknown. Show the OTHER party.
            NSString *me = ApolloInboxCurrentUser();
            BOOL sent;
            if (me.length && author.length) sent = ([me caseInsensitiveCompare:author] == NSOrderedSame);
            else                            sent = (ApolloInboxIvarValue(cellNode, @"recipientButtonNode") != nil);

            NSString *other = sent ? ApolloInboxNormUser(recipient) : ApolloInboxNormUser(author);
            // Never paint the logged-in user's own avatar (e.g. a note-to-self where recipient == me).
            if (other.length && me.length && [other caseInsensitiveCompare:me] == NSOrderedSame) other = nil;
            if (other.length) {
                *outIdentity = other;
                if (outAnchor) *outAnchor = sent ? (ApolloInboxIvarValue(cellNode, @"recipientButtonNode") ?: ApolloInboxIvarValue(cellNode, @"authorButtonNode"))
                                                 : ApolloInboxIvarValue(cellNode, @"authorButtonNode");
                return ApolloInboxIconUser;
            }
        }
        return ApolloInboxIconNone;   // a message is present but nothing resolvable — don't guess
    }

    // New-modmail rows (no classic RDKMessage). RDKModmailConversationInfo has no subreddit ivar — the
    // community lives in its `_owner` dict (Reddit owner:{type,displayName,id}); the participant is
    // RDKModmailMessage._author (an RDKModmailAuthor exposing `name`). Best-effort + fully defensive.
    id mmConv = ApolloInboxIvarValue(cellNode, @"newModmailConversationInfo");
    id mmMsg  = ApolloInboxIvarValue(cellNode, @"newModmailMessage");
    if (mmConv || mmMsg) {
        id owner = ApolloInboxIvarValue(mmConv, @"_owner") ?: ApolloInboxIvarValue(mmConv, @"owner");
        if ([owner isKindOfClass:[NSDictionary class]]) {
            NSString *s = ApolloInboxSubredditClean([(NSDictionary *)owner objectForKey:@"displayName"]);
            if (s) { *outIdentity = s; if (outAnchor) *outAnchor = ApolloInboxIvarValue(cellNode, @"subredditButtonNode"); return ApolloInboxIconSubreddit; }
        }
        id mmAuthor = ApolloInboxIvarValue(mmMsg, @"_author") ?: ApolloInboxIvarValue(mmMsg, @"author");
        NSString *u = ApolloInboxUsernameFromObject(mmAuthor);
        if (u) { *outIdentity = u; if (outAnchor) *outAnchor = ApolloInboxIvarValue(cellNode, @"authorButtonNode"); return ApolloInboxIconUser; }
    }
    return ApolloInboxIconNone;
}

static void ApolloInboxCellApplyAvatar(id cellNode) {
    UIView *cellView = [cellNode respondsToSelector:@selector(view)]
        ? ((UIView *(*)(id, SEL))objc_msgSend)(cellNode, @selector(view)) : nil;
    if (![cellView isKindOfClass:[UIView class]]) return;
    UIImageView *av = objc_getAssociatedObject(cellView, &kInboxAvatarKey);

    if (!sShowUserAvatars) { if (av) av.hidden = YES; return; }   // toggle off — definitive hide

    NSString *identity = nil; id anchorBtn = nil;
    ApolloInboxIconKind kind = ApolloInboxResolveIdentity(cellNode, &identity, &anchorBtn);

    // Nothing resolvable (unsupported row, or the model isn't attached yet): don't show a stale image.
    if (kind == ApolloInboxIconNone || identity.length == 0) { if (av) av.hidden = YES; return; }

    static const CGFloat d = 20.0, gap = 6.0;
    if (!av) {
        av = [[UIImageView alloc] init];
        av.contentMode = UIViewContentModeScaleAspectFill;
        av.clipsToBounds = YES;
        av.layer.cornerRadius = d / 2.0;
        av.backgroundColor = [UIColor secondarySystemFillColor];
        objc_setAssociatedObject(cellView, &kInboxAvatarKey, av, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (av.superview != cellView) [cellView addSubview:av];   // re-add if Texture stripped it
    [cellView bringSubviewToFront:av];
    av.hidden = NO;
    // Anchor to the kind-specific identity button; fall back to a cell-relative position (the identity
    // row sits ~25px above the cell bottom) so the image stays put before the buttons are laid out.
    CGRect bf = ApolloNodeFrame(anchorBtn);
    BOOL frameOK = anchorBtn && bf.origin.x > 10.0 && bf.size.height > 0.0;
    CGFloat ax = frameOK ? bf.origin.x - d - gap : 12.0;
    CGFloat ay = frameOK ? bf.origin.y + (bf.size.height - d) / 2.0 : cellView.bounds.size.height - 27.0;
    av.frame = CGRectMake(ax, ay, d, d);

    // Composite identity key so a recycled cell that flipped user<->subreddit can't paint a stale image.
    NSString *idKey = [NSString stringWithFormat:@"%@:%@", kind == ApolloInboxIconSubreddit ? @"r" : @"u", identity];
    BOOL identityChanged = ![objc_getAssociatedObject(av, &kInboxAvatarIdentityKey) isEqualToString:idKey];
    // Skip only when we're already SHOWING the right image. If the identity matches but the image is
    // still nil (a prior fetch failed or hasn't returned yet), fall through and retry — otherwise one
    // transient failure would leave a permanent grey placeholder for that identity.
    if (av.image && !identityChanged) return;
    if (identityChanged) {
        objc_setAssociatedObject(av, &kInboxAvatarIdentityKey, idKey, OBJC_ASSOCIATION_COPY_NONATOMIC);
        av.image = nil;
#if APOLLO_INBOX_AVATAR_DEBUG
        ChatsFilterLog(@"inbox icon -> %@", idKey);
#endif
    }

    __weak UIImageView *wav = av;
    void (^applyImg)(UIImage *) = ^(UIImage *img) {
        UIImageView *sav = wav;
        if (img && sav && [objc_getAssociatedObject(sav, &kInboxAvatarIdentityKey) isEqualToString:idKey]) sav.image = img;
    };

    if (kind == ApolloInboxIconSubreddit) {
        // user-set custom icon wins, then a cached community icon, then async fetch.
        ApolloSubredditCustomIconCache *cic = [ApolloSubredditCustomIconCache sharedCache];
        UIImage *custom = [cic cachedIconForSubreddit:identity];
        if (custom) { applyImg(custom); return; }
        ApolloSubredditInfoCache *sic = [ApolloSubredditInfoCache sharedCache];
        ApolloUserProfileCache *imgCache = [ApolloUserProfileCache sharedCache];
        ApolloSubredditInfo *sinfo = [sic cachedInfoForSubreddit:identity];
        UIImage *subImg = sinfo.iconURL ? [imgCache cachedImageForURL:sinfo.iconURL] : nil;
        if (subImg) { applyImg(subImg); return; }
        [sic requestInfoForSubreddit:identity completion:^(ApolloSubredditInfo *i2) {
            if ([cic hasCustomIconForSubreddit:identity]) return;   // a custom icon arrived meanwhile
            if (i2.iconURL) [imgCache requestImageForURL:i2.iconURL completion:applyImg];
        }];
        return;
    }

    // user avatar
    ApolloUserProfileCache *cache = [ApolloUserProfileCache sharedCache];
    ApolloUserProfileInfo *info = [cache cachedInfoForUsername:identity];
    NSURL *u = info ? (info.iconURL ?: info.snoovatarURL) : nil;
    UIImage *userImg = u ? [cache cachedImageForURL:u] : nil;
    if (userImg) { applyImg(userImg); return; }
    [cache requestInfoForUsername:identity completion:^(ApolloUserProfileInfo *i2) {
        NSURL *uu = i2.iconURL ?: i2.snoovatarURL;
        if (uu) [cache requestImageForURL:uu completion:applyImg];
    }];
}

%hook _TtC6Apollo13InboxCellNode
- (void)layout {
    %orig;
    @try { ApolloInboxCellApplyAvatar(self); } @catch (__unused id e) {}
}
- (void)didEnterVisibleState {
    %orig;
    @try { ApolloInboxCellApplyAvatar(self); } @catch (__unused id e) {}
    // The identity button nodes may not be laid out yet on first visibility; re-apply a couple of
    // times shortly after so the image anchors correctly + re-attaches without needing a scroll.
    __weak id wself = self;
    for (NSTimeInterval delay = 0.25; delay <= 0.8; delay += 0.55) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            @try { if (wself) ApolloInboxCellApplyAvatar(wself); } @catch (__unused id e) {}
        });
    }
}
%end

%ctor {
    ChatsFilterLog(@"module loaded");
}
