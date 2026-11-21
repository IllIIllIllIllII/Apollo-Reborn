#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif

// The feed carousel on a card's album (its AlbumThumbnailsNode): the page it
// shows and the pictures it has loaded, by page. Nil when the card has none.
// Main thread only.
NSDictionary<NSNumber *, UIImage *> *_Nullable ApolloFeedGalleryCarouselPictures(id _Nullable albumNode,
                                                                                 NSInteger *_Nullable currentIndex);

#ifdef __cplusplus
}
#endif
