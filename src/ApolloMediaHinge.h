#import <UIKit/UIKit.h>

__BEGIN_DECLS
/// Publish and invalidate retained Texture geometry before a Duo column transition.
/// Call after UIKit lays out the destination, before committing Texture updates.
void ApolloDuoMediaPrepareTableForTransition(UITableView *table);
/// Where the Focused post column sits in `availableWidth`, the width the
/// feed's post cards are laid out in (the table less its side safe-area
/// insets): its leading offset and width. NO when the feed shows Original
/// or isn't a Duo feed. For views outside the cells, such as the table
/// header, to line up with the cards.
BOOL ApolloDuoFeedFocusedColumn(UITableView *table, CGFloat availableWidth, CGFloat *leading, CGFloat *width);
/// Posted (object: the table) when a Duo feed's layout geometry changes:
/// Original/Focused, a rotation or resize, or the column moving.
extern NSString *const ApolloDuoFeedGeometryDidChangeNotification;
__END_DECLS
