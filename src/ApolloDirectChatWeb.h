#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

__BEGIN_DECLS

BOOL ApolloModernChatIsAvailable(void);
BOOL ApolloModernChatIsRequiredForActiveAccount(void);
BOOL ApolloModernChatShouldOpen(void);
UIColor *ApolloModernChatThemeColor(UITraitCollection *traits, NSString *role);
NSDictionary<NSString *, id> * _Nullable ApolloModernChatCachedStatus(void);
extern NSString * const ApolloModernChatStatusDidChangeNotification;
UIViewController *ApolloCreateModernChatViewController(void);

__END_DECLS

NS_ASSUME_NONNULL_END
