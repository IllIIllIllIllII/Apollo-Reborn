#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Replaces Apollo's custom awards overlay with a standard UIKit sheet. The
// captured thing supplies both the displayed award snapshot and giving target.
FOUNDATION_EXPORT UIViewController * _Nullable ApolloAwardsSheetControllerForThing(id thing);

NS_ASSUME_NONNULL_END
