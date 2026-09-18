#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif
void ApolloSubredditListIconCacheClear(void);
// Custom multireddit art takes precedence over the native avatar cache.
BOOL ApolloMultiredditHasCustomListIcon(UIImageView *view);
#ifdef __cplusplus
}
#endif
