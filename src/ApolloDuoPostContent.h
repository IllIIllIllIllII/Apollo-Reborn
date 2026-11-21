#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

// Sidebar & Post (Duo, flat, landscape, Split View on): what a post shows in
// the left column beside its comments. Media posts (images, galleries, videos,
// GIFs) and text posts with pictures play in Gallery View's own pager,
// embedded; link posts load their page in Safari's view controller, as
// Apollo's in-app browser does. A text post with no pictures has nothing to
// show there and keeps the feed rail beside it instead.
@interface ApolloDuoPostContentViewController : UIViewController
/// Whether `link` (an RDKLink) has content for the left column. Cached per link.
+ (BOOL)hasContentForLink:(nullable id)link;
/// nil when the post has nothing to show beside its comments.
+ (nullable instancetype)contentForLink:(nullable id)link;
/// The RDKLink this column shows.
@property(nonatomic, weak, readonly, nullable) id link;
/// YES for media, NO for a web page.
@property(nonatomic, readonly) BOOL showsMedia;
/// Set before the column appears, from the feed card the post opened from, so
/// the column picks up from it: the album page the card was on, the pictures
/// it shows (by item), and the video it was playing.
@property(nonatomic) NSInteger startIndex;
@property(nonatomic, copy, nullable) NSDictionary<NSNumber *, UIImage *> *feedImages;
- (void)continueFromPlayer:(nullable AVPlayer *)player;
/// Stops video and audio while the column is out of sight, and hands the
/// video's place back to the feed card's player.
- (void)pausePlayback;
/// Ends a Back swipe from the column's edge as cancelled; the host calls it
/// before taking the column off screen.
- (void)cancelEdgeBack;
/// Safari's Done button: the host goes Back from the post.
@property(nonatomic, copy, nullable) void (^done)(void);
/// Runs for every state of a rightward swipe on the column (from its leading
/// edge, the one it covers for the page beneath it, or anywhere on media that
/// doesn't take it): the host drives that page's Back with it, as the Duo's
/// own Back swipe does.
@property(nonatomic, copy, nullable) void (^edgeBack)(UIPanGestureRecognizer *pan);
@end

NS_ASSUME_NONNULL_END
