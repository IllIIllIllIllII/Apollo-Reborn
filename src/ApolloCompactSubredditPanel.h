#import <UIKit/UIKit.h>

__BEGIN_DECLS
/// Present the native Posts root list over its current feed when Compact List
/// is enabled. Returns NO when native navigation should handle the request.
BOOL ApolloCompactSubredditPanelReveal(UINavigationController *navigation);
/// The visible page is unchanged while its native list root is borrowed or
/// restored. Navigation reset hooks should preserve that page's bar state.
BOOL ApolloCompactSubredditPanelIsUpdatingNavigation(UINavigationController *navigation);
/// The borrowed list uses the panel's own Edit/Done bar; its child navigation
/// bar stays hidden, including while the native list is editing.
BOOL ApolloCompactSubredditPanelOwnsNavigation(UINavigationController *navigation);
BOOL ApolloCompactSubredditPanelContainsView(UIView *view);
BOOL ApolloCompactSubredditPanelUsesGlass(UIView *view);
void ApolloCompactSubredditPanelPrepareSurface(UIView *view);
UIColor *ApolloCompactSubredditPanelBackground(UIView *view, UIColor *color);
__END_DECLS
