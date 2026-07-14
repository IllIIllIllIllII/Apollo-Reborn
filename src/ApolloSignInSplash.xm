#import "ApolloState.h"
#import "ApolloWebSessionLoginViewController.h"

// Both ProfileViewController and InboxViewController host a SignInSplashView
// when no account is signed in. Their "Sign In with Reddit" button fires
// -signInSplashViewSignInButtonTappedWithSender:, which normally goes straight
// to the OAuth/API-key sign-in flow.
//
// Always intercept that tap and present the two-way chooser (same sheet as the
// account switcher's "Add Account") so the user explicitly picks OAuth/API-key
// or API-Key-Free Mode. The "Create Account" button is left untouched.

%hook _TtC6Apollo21ProfileViewController

- (void)signInSplashViewSignInButtonTappedWithSender:(id)sender {
    UIViewController *host = (UIViewController *)self;
    ApolloWebSessionPresentSignInChooser(host, ^{ %orig; });
}

%end

%hook _TtC6Apollo19InboxViewController

- (void)signInSplashViewSignInButtonTappedWithSender:(id)sender {
    UIViewController *host = (UIViewController *)self;
    ApolloWebSessionPresentSignInChooser(host, ^{ %orig; });
}

%end
