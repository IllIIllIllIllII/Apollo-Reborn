#import <UIKit/UIKit.h>
__BEGIN_DECLS
void ApolloDuoSplitScheduleUpdate(void);
void ApolloDuoSplitApplyPostsStop(UINavigationController *anyPostsNavigation);
/// The Posts divider pressed and dragged (ApolloDuoSplitDivider.m), with
/// the adjustable split on. Position is where the divider is in `host` (the
/// Posts split host's view): the thread pane's leading edge beside the feed,
/// the screen's leading edge while the post covers the feed (the bar is
/// there), or -1 without a thread in the unfolded landscape split or while
/// the panes move; `adjustable` says whether the setting is on. With it on,
/// a touch-down there also keeps UIKit's own separator tap off. Begin covers
/// the columns with the drag's pictures (over a covered feed it is the
/// uncover drag: the cover ends under the full-width picture); NO when it
/// can't. Update moves the divider to `dividerX` and returns NO once the
/// split let the drag go. Finish lands the divider where it is let go,
/// closes the thread or covers the feed (ApolloDuoSplitReleaseFor), with one
/// re-layout; Cancel removes the drag at once.
CGFloat ApolloDuoSplitDividerPosition(UIView *host, BOOL *adjustable);
BOOL ApolloDuoSplitDividerBegin(UIView *host);
BOOL ApolloDuoSplitDividerUpdate(UIView *host, CGFloat dividerX);
void ApolloDuoSplitDividerFinish(UIView *host, CGFloat dividerX, CGFloat velocityX);
void ApolloDuoSplitDividerCancel(UIView *host);

BOOL ApolloDuoSplitIsResizing(void);
BOOL ApolloDuoSplitIsUnfolded(void);
BOOL ApolloDuoRequiresSubredditEnhancements(void);
BOOL ApolloDuoSplitIsUnfoldedPortrait(void);
CGFloat ApolloDuoSplitTransitionContentWidth(UIView *view, CGFloat trailingInset);
UINavigationController *ApolloDuoSplitDetailNavigation(UINavigationController *navigation);
/// The native tab root retained by Duo, including while its tab is offscreen.
/// Returns nil when the navigation controller has no Duo split state.
UIViewController *ApolloDuoSplitRootController(UINavigationController *navigation);
CGRect ApolloDuoSplitContentFrame(UIViewController *controller, UIView *coordinateView);
BOOL ApolloDuoSplitIsAccountFeedController(UIViewController *controller);
BOOL ApolloDuoSplitIsOwnAccountController(UIViewController *controller);
BOOL ApolloDuoSplitIsSubredditOverlayView(UIView *view);
/// Appearance only; both styles remain overlays for geometry and navigation.
BOOL ApolloDuoSplitIsGlassSubredditOverlayView(UIView *view);
BOOL ApolloDuoSplitIsSidebarController(UIViewController *controller);
BOOL ApolloDuoSplitRevealPostsList(UINavigationController *navigation);
/// Excludes containment controllers, the open drawer, and adapting columns.
BOOL ApolloDuoSplitAllowsNavigationSwipe(UINavigationController *navigation);
/// Only the Posts feed root can open its closed drawer with an edge swipe.
BOOL ApolloDuoSplitCanRevealPostsListWithSwipe(UINavigationController *navigation);
/// Closes the Posts subreddit drawer when it is open; NO when it was not.
BOOL ApolloDuoSplitDismissPostsList(UINavigationController *navigation);
/// Returns from a visited profile dashboard to its retained Posts Back stack.
BOOL ApolloDuoSplitCanReturnFromVisitedProfile(UINavigationController *navigation);
BOOL ApolloDuoSplitReturnFromVisitedProfile(UINavigationController *navigation);
BOOL ApolloDuoSplitShowSidebar(UINavigationController *navigation);
__END_DECLS

void ApolloDuoSplitPrepareOverlaySurface(UIView *surface);

BOOL ApolloDuoSplitSuppressesFeedActions(UIViewController *controller);

UIColor *ApolloDuoSplitOverlayBackground(UIView *view, UIColor *color);
