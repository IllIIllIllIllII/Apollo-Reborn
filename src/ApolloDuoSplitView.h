#import <UIKit/UIKit.h>
__BEGIN_DECLS
void ApolloDuoSplitScheduleUpdate(void);
BOOL ApolloDuoSplitIsResizing(void);
BOOL ApolloDuoSplitIsUnfolded(void);
BOOL ApolloDuoSplitIsUnfoldedPortrait(void);
CGFloat ApolloDuoSplitTransitionContentWidth(UIView *view, CGFloat trailingInset);
UINavigationController *ApolloDuoSplitDetailNavigation(UINavigationController *navigation);
/// The native tab root retained by Duo, including while its tab is offscreen.
/// Returns nil when the navigation controller has no Duo split state.
UIViewController *ApolloDuoSplitRootController(UINavigationController *navigation);
CGRect ApolloDuoSplitContentFrame(UIViewController *controller, UIView *coordinateView);
BOOL ApolloDuoSplitIsSidebarController(UIViewController *controller);
BOOL ApolloDuoSplitShowSidebar(UINavigationController *navigation);
__END_DECLS
