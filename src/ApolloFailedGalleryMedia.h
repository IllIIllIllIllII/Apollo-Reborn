#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

// What i.redd.it serves for one gallery image: its URL, MIME type and pixel size.
@interface ApolloFailedGalleryImage : NSObject
@property (nonatomic, copy) NSString *URLString;
@property (nonatomic, copy) NSString *mimeType;
@property (nonatomic) NSInteger width;
@property (nonatomic) NSInteger height;
@end

// Finds the image a gallery media id names on i.redd.it, trying `extensions`
// in order. Nil when none of them is there. Synchronous: background threads only.
typedef ApolloFailedGalleryImage * _Nullable (^ApolloFailedGalleryImageResolver)(NSString *mediaID, NSArray<NSString *> *extensions);

// Reddit can return a gallery post whose `media_metadata` entries are only
// {"status": "failed"} (no URL, type or size), although every image is still on
// i.redd.it (r/classywomen 1xdlhq1, 2026-10-23: archived copy all "valid",
// live copy all "failed"). Apollo then has nothing to show and renders the post
// as a bare reddit.com link. This rebuilds each failed entry of a listing or
// comments response from its media id, as a valid image entry. Returns `data`
// itself when nothing needed or could be repaired.
NSData *ApolloRepairFailedGalleryMedia(NSData *data, ApolloFailedGalleryImageResolver resolver);

// The resolver the app uses: ranged GETs to i.redd.it (enough bytes to read
// the image header), cached per media id.
ApolloFailedGalleryImageResolver ApolloFailedGalleryNetworkResolver(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
