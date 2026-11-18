#import <UIKit/UIKit.h>

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
/// Stops video and audio while the column is out of sight.
- (void)pausePlayback;
/// Ends a Back swipe from the column's edge as cancelled; the host calls it
/// before taking the column off screen.
- (void)cancelEdgeBack;
/// Safari's Done button: the host goes Back from the post.
@property(nonatomic, copy, nullable) void (^done)(void);
/// Runs for every state of a rightward swipe on the column (from its leading
/// 28pt, the edge it covers for the page beneath it, or anywhere the content
/// doesn't take it): the host drives that page's Back with it, as the Duo's
/// own Back swipe does.
@property(nonatomic, copy, nullable) void (^edgeBack)(UIPanGestureRecognizer *pan);
@end

NS_ASSUME_NONNULL_END
