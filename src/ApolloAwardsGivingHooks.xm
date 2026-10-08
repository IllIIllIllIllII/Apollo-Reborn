#import "ApolloAwardsGiving.h"
#import "ApolloAwardsSheet.h"
#import "ApolloCommon.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static UIViewController *ApolloAwardsReplaceLegacyPresentation(UIViewController *candidate) {
    UIViewController *content = [candidate isKindOfClass:UINavigationController.class]
        ? ((UINavigationController *)candidate).viewControllers.firstObject : candidate;
    Class gifting = objc_getClass("_TtC6Apollo26AwardGiftingViewController");
    Class details = objc_getClass("_TtC6Apollo25AwardsGivenViewController");
    BOOL isGifting = gifting && [content isKindOfClass:gifting];
    BOOL isDetails = details && [content isKindOfClass:details];
    if (!isGifting && !isDetails) return candidate;
    Ivar ivar = class_getInstanceVariable(object_getClass(content), "thingToAward");
    id thing = ivar ? object_getIvar(content, ivar) : nil;
    return (isGifting ? ApolloAwardsGivingControllerForThing(thing)
                      : ApolloAwardsSheetControllerForThing(thing)) ?: candidate;
}

// Replace Apollo's custom awards overlay and retired gifting catalog before
// their views load. Both entry points now use native, resizable sheets.
%hook UIViewController
- (void)presentViewController:(UIViewController *)controller animated:(BOOL)animated completion:(void (^)(void))completion {
    %orig(ApolloAwardsReplaceLegacyPresentation(controller), animated, completion);
}
%end

%hook _TtC6Apollo26ApolloNavigationController
- (void)presentViewController:(UIViewController *)controller animated:(BOOL)animated completion:(void (^)(void))completion {
    %orig(ApolloAwardsReplaceLegacyPresentation(controller), animated, completion);
}
%end

%ctor {
    %init;
    ApolloLog(@"[Awards] Awards sheet presentation hooks installed");
}
