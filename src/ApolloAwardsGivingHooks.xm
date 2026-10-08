#import "ApolloAwardsGiving.h"
#import "ApolloCommon.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static UIViewController *ApolloAwardsReplaceLegacyGifting(UIViewController *candidate) {
    UIViewController *content = [candidate isKindOfClass:UINavigationController.class]
        ? ((UINavigationController *)candidate).viewControllers.firstObject : candidate;
    Class gifting = objc_getClass("_TtC6Apollo26AwardGiftingViewController");
    if (!gifting || ![content isKindOfClass:gifting]) return candidate;
    Ivar ivar = class_getInstanceVariable(object_getClass(content), "thingToAward");
    id thing = ivar ? object_getIvar(content, ivar) : nil;
    return ApolloAwardsGivingControllerForThing(thing) ?: candidate;
}

// Every stock Give Award action (including a zero-award post/comment) presents
// this controller. Replace it before viewDidLoad can fetch the retired catalog.
%hook UIViewController
- (void)presentViewController:(UIViewController *)controller animated:(BOOL)animated completion:(void (^)(void))completion {
    %orig(ApolloAwardsReplaceLegacyGifting(controller), animated, completion);
}
%end

%hook _TtC6Apollo26ApolloNavigationController
- (void)presentViewController:(UIViewController *)controller animated:(BOOL)animated completion:(void (^)(void))completion {
    %orig(ApolloAwardsReplaceLegacyGifting(controller), animated, completion);
}
%end

%ctor {
    %init;
    ApolloLog(@"[Awards] Reddit gifting presentation hooks installed");
}
