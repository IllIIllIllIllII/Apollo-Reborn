#import "ApolloAppIcon.h"

UIImage *ApolloCurrentAppIcon(void) {
    NSDictionary *icons = [NSBundle mainBundle].infoDictionary[@"CFBundleIcons"];
    if (![icons isKindOfClass:[NSDictionary class]]) return nil;

    NSArray<NSString *> *iconFiles = nil;
    NSString *alternateName = [UIApplication sharedApplication].alternateIconName;
    if (alternateName.length > 0) {
        NSDictionary *alternates = icons[@"CFBundleAlternateIcons"];
        NSDictionary *iconInfo = [alternates isKindOfClass:[NSDictionary class]] ? alternates[alternateName] : nil;
        iconFiles = [iconInfo[@"CFBundleIconFiles"] isKindOfClass:[NSArray class]] ? iconInfo[@"CFBundleIconFiles"] : nil;
    }
    if (iconFiles.count == 0) {
        NSDictionary *primary = icons[@"CFBundlePrimaryIcon"];
        iconFiles = [primary[@"CFBundleIconFiles"] isKindOfClass:[NSArray class]] ? primary[@"CFBundleIconFiles"] : nil;
    }

    NSString *iconName = iconFiles.lastObject;
    return iconName.length > 0 ? [UIImage imageNamed:iconName] : nil;
}
