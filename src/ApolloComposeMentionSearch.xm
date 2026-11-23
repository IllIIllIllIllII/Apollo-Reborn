// ApolloComposeMentionSearch.xm
//
// Keeps the comment composer's u/ and r/ search from crashing when UIKit
// edits the text mid-update.
//
// -[ComposeViewController textViewDidChange:] (Apollo 1.15.11, sub_1001b8c2c)
// opens a search when the text before the cursor ends in "/u/" or "/r/": it
// stores `searchType`, whose didSet (sub_1001b2664) turns off the text view's
// autocapitalization, autocorrection and spell checking, and only then stores
// `beginningSearchPosition`. While a search is open, the same method
// force-unwraps that position. On an active text view, turning autocorrection
// off can make UIKit commit a pending correction or prediction, which edits
// the text and calls textViewDidChange: again from inside the didSet: the
// search is open and the position is still nil, so the unwrap traps. Typing a
// sentence and then adding a second u/ mention does it. Those four stores and
// the controller's init are the only writes to `searchType`, so this
// re-entrance is the only way to reach that trap.
//
// The nested call is held until the outer one has finished, then run once
// with the text as it is by then, so Apollo still sees the committed edit.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "ApolloClasses.h"
#import "ApolloCommon.h"

static char kComposeTextChangeRunningKey;
static char kComposeTextChangePendingKey;

%hook _TtC6Apollo21ComposeViewController

- (void)textViewDidChange:(UITextView *)textView {
    if ([objc_getAssociatedObject(self, &kComposeTextChangeRunningKey) boolValue]) {
        if (![objc_getAssociatedObject(self, &kComposeTextChangePendingKey) boolValue]) {
            objc_setAssociatedObject(self, &kComposeTextChangePendingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            ApolloLog(@"[ComposeMentionSearch] text changed during Apollo's own text update; replaying it after");
            __weak UIViewController *weakComposer = (UIViewController *)self;
            __weak UITextView *weakTextView = textView;
            dispatch_async(dispatch_get_main_queue(), ^{
                UIViewController *composer = weakComposer;
                if (!composer) return;
                objc_setAssociatedObject(composer, &kComposeTextChangePendingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                UITextView *strongTextView = weakTextView;
                if (strongTextView) [(id<UITextViewDelegate>)composer textViewDidChange:strongTextView];
            });
        }
        return;
    }
    objc_setAssociatedObject(self, &kComposeTextChangeRunningKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    @try {
        %orig;
    } @finally {
        objc_setAssociatedObject(self, &kComposeTextChangeRunningKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

%end

%ctor {
    if (!ApolloClassComposeViewController) return;
    if (!class_getInstanceMethod(ApolloClassComposeViewController, @selector(textViewDidChange:))) return;
    %init(_TtC6Apollo21ComposeViewController = ApolloClassComposeViewController);
    ApolloLog(@"[ComposeMentionSearch] hook installed (textViewDidChange: re-entrance guard)");
}
