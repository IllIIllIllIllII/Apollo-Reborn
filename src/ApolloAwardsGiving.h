#import <Foundation/Foundation.h>

@class UIViewController;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSURL * _Nullable ApolloAwardsGivingURLForThing(id thing);

// Hosts Reddit's own chooser, balance and confirmation UI. The controller
// never constructs a purchase/order mutation. Only the user can give an award.
FOUNDATION_EXPORT UIViewController * _Nullable ApolloAwardsGivingControllerForThing(id thing);
FOUNDATION_EXPORT BOOL ApolloAwardsPresentGiving(id thing, UIViewController *presenter);

NS_ASSUME_NONNULL_END
