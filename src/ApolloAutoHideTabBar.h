#import <UIKit/UIKit.h>

__BEGIN_DECLS

// Reveal scroll-hidden bottom chrome when a status-bar jump reaches the top.
void ApolloTabBarRevealAfterScrollToTop(UITabBarController *controller);

// Cancel a pending reveal retry when the user leaves or resumes scrolling.
void ApolloTabBarCancelScrollToTopReveal(UITabBarController *controller);

// Reconcile native bottom-bar policy once after the Duo bar changes placement.
void ApolloScheduleDuoBarPolicyUpdate(UITabBarController *controller);

// YES while Fade or Down has the bottom tab bar hidden or is animating it
// away (the target, not the current frame). The tab bar accessory follows it.
BOOL ApolloTabBarScrollHidesBarAway(UITabBarController *controller);


// Simulator builds expose bounded probes so the allocation-free
// tab-navigation fast paths can be verified
// without putting diagnostics in production scroll callbacks.

#if APOLLO_SIM_BUILD
NSString *ApolloAutoHideTabBarSimScanStatus(NSUInteger iterations);
NSString *ApolloAutoHideTabBarSimSetPolicy(BOOL enabled);
#endif

__END_DECLS
