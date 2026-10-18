#import <UIKit/UIKit.h>

__BEGIN_DECLS

// Deferred, change-gated presentation maintenance. Safe to call from bar layout.
// The UINavigationItem model and the actual custom titleView remain unchanged.
void ApolloNavigationTitlePresentationRefresh(UINavigationBar *navigationBar);
// Settle an explicit navigation update before its next frame. Call after the
// navigation stack/item update, never from a layout hook.
void ApolloNavigationTitlePresentationSynchronize(UINavigationBar *navigationBar);
BOOL ApolloNavigationTitlePresentationOwnsControl(UIView *titleControl);
BOOL ApolloNavigationTitlePresentationSuppressesControl(UIView *titleControl);
BOOL ApolloNavigationTitleContainsNativeSearchSurface(UIView *view);

CGRect ApolloIPadFloatingTabsFrame(UINavigationBar *bar, UIViewController *top);

__END_DECLS
