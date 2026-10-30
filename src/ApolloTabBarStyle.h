#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

// The value the Inbox tab item should display for Apollo's (combined) badge
// value. Count mode returns it unchanged; dot mode returns @"" for any unread
// value, which the tab bar's badge view then draws as a dot.
NSString *_Nullable ApolloInboxBadgeDisplayValue(NSString *_Nullable value);

// The inactive icon tint exists only on the classic tab bar.
BOOL ApolloTabBarIconTintAvailable(void);
void ApolloTabBarIconTintSetEnabled(BOOL enabled);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
