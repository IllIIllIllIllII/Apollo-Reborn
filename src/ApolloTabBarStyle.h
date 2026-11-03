#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

// The value the Inbox tab item should display for Apollo's (combined) badge
// value. Count mode returns it unchanged; dot mode returns @"" for any unread
// value, which the tab bar's badge view then draws as a dot.
NSString *_Nullable ApolloInboxBadgeDisplayValue(NSString *_Nullable value);

void ApolloTabBarIconTintSetEnabled(BOOL enabled);
// YES for the inactive icon tint's own color, which ApolloLiquidGlass.xm's
// appearance scrub must keep.
BOOL ApolloTabBarIconTintOwnsColor(UIColor *_Nullable color);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
