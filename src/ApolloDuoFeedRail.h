#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Sidebar & Post (Duo, flat, landscape): the leading column beside the
// full-width Posts feed. A full-height glass panel, inset like the subreddit
// drawer: Home, Popular and All (whichever the subreddit list shows) at the
// top, the account's favorite subreddits below them, and Subreddits, which
// opens the drawer beside it, pinned at the bottom. The host sizes the view to
// the column's reserved width and shows it.
@interface ApolloDuoFeedRail : UIView
/// Width the feed reserves for the column: the panel, its 12pt inset from
/// the display edge and a 12pt gap before the feed.
@property(class, nonatomic, readonly) CGFloat reservedWidth;
/// 0 Home, 1 Popular, 2 All; -1 when the feed is none of them.
@property(nonatomic) NSInteger selectedFeed;
/// The subreddit the feed shows, matched against the favorites; nil for none.
@property(nonatomic, copy, nullable) NSString *selectedSubreddit;
@property(nonatomic) BOOL subredditsSelected;
@property(nonatomic, copy, nullable) void (^selectFeed)(NSInteger feed);
@property(nonatomic, copy, nullable) void (^selectSubreddit)(NSString *subreddit);
@property(nonatomic, copy, nullable) void (^toggleSubreddits)(void);
/// Rebuilds the buttons when the shortcuts (Popular and All can be hidden in
/// Settings) or the favorites changed.
- (void)reloadShortcuts;
- (void)refreshColors;
@end

NS_ASSUME_NONNULL_END
