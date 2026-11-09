#import <UIKit/UIKit.h>

// The iOS 26 tab bar bottom accessory: the glass strip UIKit lays out above
// the floating tab bar (or beside it, inline, while the bar is minimized).
// Apollo has one tab bar controller and UIKit one accessory slot, so every
// feature that wants the slot goes through here. Owners stack: the newest
// shown owner is on screen, and hiding it brings back the one underneath.
//
// Main thread only.

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ApolloTabAccessoryOwner) {
    ApolloTabAccessoryOwnerSaveProgress = 1,  // Save All Media (ApolloSaveAllMedia.xm)
    ApolloTabAccessoryOwnerVideo,             // comments mini player (ApolloPictureInPicture.xm)
};

__BEGIN_DECLS

// YES on iOS 26 or later in the Liquid Glass build, where UIKit has the
// accessory at all. Gates the settings rows that use it.
BOOL ApolloTabAccessoryIsSupported(void);

// YES when an accessory can show right now: supported, and Apollo's tab bar
// controller up with nothing presented over it (a sheet or full-screen viewer
// would hide the strip). Each owner checks its own setting first.
BOOL ApolloTabAccessoryIsAvailable(void);

// Shows `contentView` for `owner`, replacing that owner's previous view.
// Returns NO, and shows nothing, when the accessory isn't available; callers
// then keep their old UI.
BOOL ApolloTabAccessoryShow(ApolloTabAccessoryOwner owner, UIView *contentView);

// Removes `owner`'s view. The next owner down, if any, shows again.
void ApolloTabAccessoryHide(ApolloTabAccessoryOwner owner);

__END_DECLS

// Accessory content for a running job: a progress ring, a title and detail
// line, and an optional stop button. Inline (beside a minimized tab bar) it
// shrinks to the ring and the detail line.
@interface ApolloTabAccessoryProgressView : UIView
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy, nullable) NSString *detail;
// 0 to 1.
@property (nonatomic) double progress;
// Shows the stop button when set; it is called once per tap.
@property (nonatomic, copy, nullable) dispatch_block_t stopHandler;
@property (nonatomic, copy) NSString *stopAccessibilityLabel;
// Disables the stop button and shows `title` while a stop is pending.
- (void)showStoppingWithTitle:(NSString *)title;
@end

NS_ASSUME_NONNULL_END
