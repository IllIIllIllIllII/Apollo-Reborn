#import "ApolloSettingsForm.h"

__BEGIN_DECLS
NSArray<NSString *> *ApolloSettingsShortcutIDs(void);
NSArray<NSString *> *ApolloSettingsShortcutCatalog(void);
NSString *ApolloSettingsShortcutTitle(NSString *identifier);
UIImage *ApolloSettingsShortcutImage(NSString *identifier, UITraitCollection *traits, CGFloat size);
__END_DECLS

@interface ApolloSettingsShortcutsViewController : ApolloSettingsFormViewController
@end
