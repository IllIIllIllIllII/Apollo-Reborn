#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
__BEGIN_DECLS

// Explicitly register the handler when constructing a tweak-owned action menu.
// The same UIAlertAction is used by the classic sheet; no private UIAlertAction
// storage is read to recover callbacks for the Liquid Glass menu.
UIAlertAction *ApolloMenuAction(NSString *title, UIAlertActionStyle style,
                                void (^ _Nullable handler)(UIAlertAction *action));

// Consume the sheet's public title, message, actions, and popover anchor. On
// Liquid Glass these become UIMenu actions; other builds retain the sheet.
// Native callbacks run after dismissal, including an outside-tap cancellation.
// Long explanations remain available through Details…; consent that must be
// read before acting belongs in a regular confirmation alert in the handler.
void ApolloPresentActionMenu(UIViewController *presenter, UIAlertController *sheet);

// Main-thread check for native menus requested by this presenter, including
// their dismissal animation. Classic sheets use presentedViewController.
BOOL ApolloActionMenuIsPresented(UIViewController *presenter);

__END_DECLS
NS_ASSUME_NONNULL_END
