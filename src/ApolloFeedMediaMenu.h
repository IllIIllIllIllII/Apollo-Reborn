#import <UIKit/UIKit.h>
#import "ApolloSaveAllMediaItems.h"

NS_ASSUME_NONNULL_BEGIN
__BEGIN_DECLS

// The feed's hold menu for a post's media (Copy, Save, Save All Media for an
// album, Share), for the same media shown outside the feed's cells, as in the
// Duo's post column. `index` is the item's place in the post's media, which
// the feed resolves from the post; `fallbackItems` (the same media, in the
// same order) stand in when it can't. Keep the session while its menu is up
// and end it when the menu closes: a chosen action runs then, as in the feed.
id ApolloFeedMediaMenuSession(id _Nullable link, NSUInteger index, BOOL album, UIViewController *presenter,
                              UIView *sourceView, NSArray<ApolloSaveAllMediaItem *> *_Nullable fallbackItems);
UIMenu *ApolloFeedMediaMenuForSession(id session);
void ApolloFeedMediaMenuSessionDidEnd(id _Nullable session);

__END_DECLS
NS_ASSUME_NONNULL_END
