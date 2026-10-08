#import "ApolloAwardAnimation.h"
#import "ApolloAwards.h"
#import "ApolloCommon.h"
#import <objc/message.h>
#import <objc/runtime.h>

static char kApolloAwardAnimationViewKey;
static char kApolloAwardAnimationSheetActiveKey;

static id ApolloAwardAnimationIvar(id owner, const char *name) {
    Ivar ivar = owner ? class_getInstanceVariable(object_getClass(owner), name) : NULL;
    return ivar ? object_getIvar(owner, ivar) : nil;
}

static NSString *ApolloAwardAnimationString(id owner, SEL selector) {
    id value = [owner respondsToSelector:selector] ? ((id (*)(id, SEL))objc_msgSend)(owner, selector) : nil;
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static void ApolloAwardAnimationClearCell(id cell) {
    ApolloAwardAnimationView *view = objc_getAssociatedObject(cell, &kApolloAwardAnimationViewKey);
    [view prepareForRemoval];
    [view removeFromSuperview];
    objc_setAssociatedObject(cell, &kApolloAwardAnimationViewKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloAwardAnimationConfigureCell(id controller, UITableViewCell *cell) {
    ApolloAwardAnimationClearCell(cell);
    id model = ApolloAwardAnimationIvar(controller, "thingToAward");
    NSString *fullName = ApolloAwardAnimationString(model, NSSelectorFromString(@"fullName"));
    id award = ApolloAwardAnimationIvar(cell, "award");
    NSString *identifier = ApolloAwardAnimationString(award, NSSelectorFromString(@"identifier"));
    UIImageView *image = ApolloAwardAnimationIvar(cell, "iconImageView");
    if (!fullName || !identifier || ![image isKindOfClass:UIImageView.class] || !image.superview) return;
    NSString *animationURL = nil;
    for (NSDictionary *entry in ApolloAwardsCached(fullName)) {
        if ([entry[@"id"] isEqual:identifier]) { animationURL = entry[@"animation_url"]; break; }
    }
#if APOLLO_SIM_BUILD
    if (animationURL) ApolloLog(@"[Awards][animation] configured award=%@ cachedTypes=%lu", identifier,
        (unsigned long)ApolloAwardsCached(fullName).count);
#endif
    if (![animationURL isKindOfClass:NSString.class]) return;
    NSURL *URL = [NSURL URLWithString:animationURL];
    if (!URL) return;
    ApolloAwardAnimationView *view = [[ApolloAwardAnimationView alloc] initWithURL:URL stillImageView:image];
    view.translatesAutoresizingMaskIntoConstraints = NO;
    [image.superview addSubview:view];
    // A sibling overlay survives the native PIN callback's later setImage:.
    // Constraints follow Apollo's own 48-point manual icon geometry without
    // writing any native layout inputs from layoutSubviews.
    [NSLayoutConstraint activateConstraints:@[
        [view.leadingAnchor constraintEqualToAnchor:image.leadingAnchor],
        [view.topAnchor constraintEqualToAnchor:image.topAnchor],
        [view.widthAnchor constraintEqualToAnchor:image.widthAnchor],
        [view.heightAnchor constraintEqualToAnchor:image.heightAnchor]
    ]];
    objc_setAssociatedObject(cell, &kApolloAwardAnimationViewKey, view, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

%hook _TtC6Apollo25AwardsGivenViewController

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = %orig;
    ApolloAwardAnimationConfigureCell(self, cell);
    return cell;
}

%new
- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    ApolloAwardAnimationView *view = objc_getAssociatedObject(cell, &kApolloAwardAnimationViewKey);
    view.displayActive = [objc_getAssociatedObject(self, &kApolloAwardAnimationSheetActiveKey) boolValue];
}

%new
- (void)tableView:(UITableView *)tableView didEndDisplayingCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    ApolloAwardAnimationView *view = objc_getAssociatedObject(cell, &kApolloAwardAnimationViewKey);
    view.displayActive = NO;
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    objc_setAssociatedObject(self, &kApolloAwardAnimationSheetActiveKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UITableView *table = ApolloAwardAnimationIvar(self, "tableView");
#if APOLLO_SIM_BUILD
    ApolloLog(@"[Awards][animation] sheet appeared visibleCells=%lu", (unsigned long)table.visibleCells.count);
#endif
    for (UITableViewCell *cell in table.visibleCells) {
        ApolloAwardAnimationView *view = objc_getAssociatedObject(cell, &kApolloAwardAnimationViewKey);
        view.displayActive = YES;
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    objc_setAssociatedObject(self, &kApolloAwardAnimationSheetActiveKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UITableView *table = ApolloAwardAnimationIvar(self, "tableView");
    for (UITableViewCell *cell in table.visibleCells) {
        ApolloAwardAnimationView *view = objc_getAssociatedObject(cell, &kApolloAwardAnimationViewKey);
        view.displayActive = NO;
    }
    %orig;
}

%end

%hook _TtC6Apollo18AwardTableViewCell
- (void)prepareForReuse {
    ApolloAwardAnimationClearCell(self);
    %orig;
}
%end

%ctor {
    %init;
#if APOLLO_SIM_BUILD
    [NSNotificationCenter.defaultCenter addObserverForName:@"ApolloAwardAnimationDiagnostic" object:nil
        queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) {
            ApolloLog(@"[Awards][animation] %@", notification.object);
        }];
    ApolloLog(@"[Awards][animation] hooks installed nativeClass=%@ SwiftClass=%@",
        NSClassFromString(@"_TtC6Apollo25AwardsGivenViewController") ? @"YES" : @"NO",
        NSClassFromString(@"ApolloAwardAnimationView") ? @"YES" : @"NO");
#endif
}
