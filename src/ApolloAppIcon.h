#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

__BEGIN_DECLS

// The app's currently active icon (the default, or whichever alternate the user
// picked in the icon picker), read from Info.plist's CFBundleIcons the way
// UIApplication resolves alternateIconName. nil when the icon is only in the
// asset catalog (e.g. the Liquid Glass alternates), so callers hide the view.
UIImage *_Nullable ApolloCurrentAppIcon(void);

__END_DECLS

NS_ASSUME_NONNULL_END
