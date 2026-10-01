#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

__BEGIN_DECLS

// The app's currently active icon: the default, or whichever alternate the user picked in
// the icon picker. Icons with image files come from Info.plist's CFBundleIcons, the way
// UIApplication resolves alternateIconName. A picked alternate that only exists in the asset
// catalog (the Liquid Glass builds' Icon Composer icons) has no file, so the system renders it.
UIImage *_Nullable ApolloCurrentAppIcon(void);

__END_DECLS

NS_ASSUME_NONNULL_END
