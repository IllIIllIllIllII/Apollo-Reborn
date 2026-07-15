#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

__BEGIN_DECLS

BOOL ApolloModernChatIsAvailable(void);
BOOL ApolloModernChatIsRequiredForActiveAccount(void);
BOOL ApolloModernChatShouldOpen(void);
BOOL ApolloModernModmailShouldOpen(void);
UIColor *ApolloModernChatThemeColor(UITraitCollection *traits, NSString *role);
NSDictionary<NSString *, id> * _Nullable ApolloModernChatCachedStatus(void);
extern NSString * const ApolloModernChatStatusDidChangeNotification;
UIViewController *ApolloCreateModernChatViewController(void);
// Notification/deep-link entry point. The optional destination must be a
// Reddit Chat path such as /chat/room/<opaque-room-id>; invalid paths safely
// fall back to the normal Chat entry screen.
UIViewController *ApolloCreateModernChatViewControllerForPath(NSString * _Nullable destinationPath);
// API-key-free accounts cannot use Apollo's OAuth-only native new-Modmail
// endpoints. This presents Reddit's current cookie-authenticated Modmail inbox
// in the same isolated, Apollo-themed mailbox shell as modern Chat.
UIViewController *ApolloCreateModernModmailViewController(void);
// Notification/deep-link entry point. The optional destination must be a
// Reddit Modmail path such as /mail/all/<opaque-conversation-id>.
UIViewController *ApolloCreateModernModmailViewControllerForPath(NSString * _Nullable destinationPath);

__END_DECLS

NS_ASSUME_NONNULL_END
