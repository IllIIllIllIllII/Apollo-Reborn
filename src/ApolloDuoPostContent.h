#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Sidebar & Post (Duo, flat, landscape, Split View on): what a post shows in
// the left column beside its comments. Media posts (images, galleries, videos,
// GIFs) play in Gallery View's own pager, embedded; link posts load their page.
// Text posts have nothing of their own to show and stay full width.
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
/// Runs for every state of a rightward drag from the column's leading 28pt,
/// the edge it covers for the page beneath it: the host drives that page's
/// Back with it, as the Duo's own Back swipe does.
@property(nonatomic, copy, nullable) void (^edgeBack)(UIPanGestureRecognizer *pan);
@end

NS_ASSUME_NONNULL_END
