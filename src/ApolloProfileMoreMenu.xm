// Own-profile Recently Read and More actions. Liquid Glass uses a shared
// navigation pill; legacy chrome uses standard bar items.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "ApolloAccountCredentials.h"
#import "ApolloActionMenu.h"
#import "ApolloCommon.h"
#import "ApolloNavigationActions.h"
#import "ApolloSwiftRuntime.h"
#import "ApolloGalleryViewController.h"
#import "ApolloProfileEditorWebViewController.h"

extern NSString *ApolloUsernameFromProfileViewController(UIViewController *viewController);
extern void ApolloRecentlyReadPresentFromViewController(UIViewController *fromViewController);

static char kApolloProfileMoreMenuItemKey;
static char kApolloProfileRecentlyReadItemKey;
static char kApolloProfileActionsItemKey;
static char kApolloProfileMoreMenuNavOwnerKey;
// Guard each navigation item separately against setter re-entry.
static char kApolloProfileMoreMenuNormalizingKey;

// ApolloNavigationActions supplies the glass and collapse/expansion behavior.
@interface ApolloProfileRecentActionsView : UIView
@property(nonatomic, strong) UIButton *moreButton;
- (instancetype)initWithRecentlyRead:(UIBarButtonItem *)recent more:(UIBarButtonItem *)more;
@end

@implementation ApolloProfileRecentActionsView
- (instancetype)initWithRecentlyRead:(UIBarButtonItem *)recent more:(UIBarButtonItem *)more {
    self = [super initWithFrame:CGRectMake(0, 0, 93, 32)];
    if (!self) return nil;
    UIButton *clock = [UIButton buttonWithType:UIButtonTypeSystem];
    clock.frame = CGRectMake(5, 0, 44, 32);
    [clock addAction:recent.primaryAction forControlEvents:UIControlEventTouchUpInside];
    [clock setImage:recent.image forState:UIControlStateNormal];
    clock.accessibilityLabel = recent.accessibilityLabel;
    [self addSubview:clock];

    self.moreButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.moreButton.frame = CGRectMake(49, 0, 44, 32);
    [self.moreButton setImage:more.image forState:UIControlStateNormal];
    self.moreButton.accessibilityLabel = more.accessibilityLabel;
    self.moreButton.menu = more.menu;
    self.moreButton.showsMenuAsPrimaryAction = YES;
    [self addSubview:self.moreButton];
    return self;
}
@end

#pragma mark - Resolution helpers

static UIBarButtonItem *ApolloProfileMoreMenuApolloItem(UIViewController *viewController) {
    id value = ApolloObjectIvar(viewController, "moreOptionsBarButtonItem");
    return [value isKindOfClass:[UIBarButtonItem class]] ? (UIBarButtonItem *)value : nil;
}

// The tab may not have loaded userInfo yet; fall back to the active account.
static NSString *ApolloProfileMoreMenuUsername(UIViewController *viewController) {
    NSString *resolved = ApolloUsernameFromProfileViewController(viewController);
    if (resolved.length > 0) return resolved;
    return ApolloActiveAccountUsername();
}

#pragma mark - Actions

static void ApolloProfileMoreMenuComplainNotReady(UIViewController *viewController, NSString *what) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:what
                                                                   message:@"Couldn't confirm this profile's username yet. Try again once the profile has finished loading."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [viewController presentViewController:alert animated:YES completion:nil];
}

static void ApolloProfileMoreMenuOpenGallery(UIViewController *viewController) {
    NSString *username = ApolloProfileMoreMenuUsername(viewController);
    if (username.length == 0) {
        ApolloProfileMoreMenuComplainNotReady(viewController, @"Gallery View");
        return;
    }
    [ApolloGalleryViewController presentGalleryForUsername:username
                                        fromViewController:viewController];
}

static void ApolloProfileMoreMenuShare(UIViewController *viewController) {
    NSString *username = ApolloProfileMoreMenuUsername(viewController);
    if (username.length == 0) {
        ApolloProfileMoreMenuComplainNotReady(viewController, @"Share Profile");
        return;
    }
    NSString *encoded = [username stringByAddingPercentEncodingWithAllowedCharacters:
                         [NSCharacterSet URLPathAllowedCharacterSet]] ?: username;
    NSURL *url = [NSURL URLWithString:[@"https://www.reddit.com/user/" stringByAppendingString:encoded]];
    if (!url) return;

    UIActivityViewController *activity =
        [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
    UIBarButtonItem *toolbar = objc_getAssociatedObject(viewController, &kApolloProfileActionsItemKey);
    ApolloProfileRecentActionsView *content = (id)ApolloNavigationActionsContentView(toolbar);
    if (content.moreButton.window) {
        // The glass strip replaces the bar item; anchor the popover to its visible button.
        activity.popoverPresentationController.sourceView = content.moreButton;
        activity.popoverPresentationController.sourceRect = content.moreButton.bounds;
    } else {
        activity.popoverPresentationController.barButtonItem =
            objc_getAssociatedObject(viewController, &kApolloProfileMoreMenuItemKey);
    }
    [viewController presentViewController:activity animated:YES completion:nil];
    ApolloLog(@"[ProfileMoreMenu] Sharing u/%@", username);
}

#pragma mark - Menu construction

static UIMenu *ApolloProfileMoreMenuBuild(UIViewController *viewController) {
    __weak UIViewController *weakVC = viewController;

    UIAction *gallery = [UIAction actionWithTitle:@"Gallery View"
                                            image:[UIImage systemImageNamed:@"square.grid.2x2"]
                                       identifier:nil
                                          handler:^(__unused __kindof UIAction *action) {
        UIViewController *vc = weakVC;
        if (vc) ApolloProfileMoreMenuOpenGallery(vc);
    }];

    UIMenu *gallerySection = [UIMenu menuWithTitle:@"" image:nil identifier:nil
                                           options:UIMenuOptionsDisplayInline
                                          children:@[gallery]];

    UIAction *edit = [UIAction actionWithTitle:@"Edit Profile"
                                         image:[UIImage systemImageNamed:@"pencil"]
                                    identifier:nil
                                       handler:^(__unused __kindof UIAction *action) {
        UIViewController *vc = weakVC;
        if (vc) ApolloProfileEditorOpenFromViewController(vc);
    }];

    UIAction *share = [UIAction actionWithTitle:@"Share Profile"
                                          image:[UIImage systemImageNamed:@"square.and.arrow.up"]
                                     identifier:nil
                                        handler:^(__unused __kindof UIAction *action) {
        UIViewController *vc = weakVC;
        if (vc) ApolloProfileMoreMenuShare(vc);
    }];
    UIMenu *actionsSection = [UIMenu menuWithTitle:@"" image:nil identifier:nil
                                           options:UIMenuOptionsDisplayInline
                                          children:@[edit, share]];

    return [UIMenu menuWithTitle:@"" children:@[gallerySection, actionsSection]];
}

#pragma mark - Nav-item normalization

// Apollo replaces these items when profile data arrives, so normalize after
// both lifecycle events and navigation-item setter calls.
static void ApolloProfileMoreMenuNormalize(UIViewController *viewController) {
    if (!viewController) return;
    UINavigationItem *navigationItem = viewController.navigationItem;
    if ([objc_getAssociatedObject(navigationItem, &kApolloProfileMoreMenuNormalizingKey) boolValue]) return;

    UIBarButtonItem *apolloItem = ApolloProfileMoreMenuApolloItem(viewController);
    NSArray<UIBarButtonItem *> *currentItems = navigationItem.rightBarButtonItems ?: @[];
    NSMutableArray<UIBarButtonItem *> *desired = [currentItems mutableCopy];

    UIBarButtonItem *ours = objc_getAssociatedObject(viewController, &kApolloProfileMoreMenuItemKey);
    UIBarButtonItem *recent = objc_getAssociatedObject(viewController, &kApolloProfileRecentlyReadItemKey);
    UIBarButtonItem *toolbar = objc_getAssociatedObject(viewController, &kApolloProfileActionsItemKey);
    if (ours) [desired removeObjectIdenticalTo:ours];
    if (recent) [desired removeObjectIdenticalTo:recent];
    if (toolbar) [desired removeObjectIdenticalTo:toolbar];

    NSString *active = ApolloActiveAccountUsername();
    NSString *resolved = ApolloUsernameFromProfileViewController(viewController);
    BOOL bothKnown = resolved.length > 0 && active.length > 0;
    BOOL resolvedAsOwn = bothKnown && [resolved caseInsensitiveCompare:active] == NSOrderedSame;
    BOOL clearlySomeoneElse = bothKnown && !resolvedAsOwn;
    BOOL apolloMenuInstalled = apolloItem && [currentItems containsObject:apolloItem];
    // Pushed profiles must resolve to our account before showing personal actions.
    BOOL pushedProfile = viewController.navigationController != nil &&
        viewController.navigationController.viewControllers.firstObject != viewController;
    BOOL wantOurs = active.length > 0 && !clearlySomeoneElse && !apolloMenuInstalled &&
        (!pushedProfile || resolvedAsOwn);

    if (wantOurs) {
        if (!ours) {
            UIImage *image = apolloItem.image ?: [UIImage systemImageNamed:@"ellipsis"];
            ours = [[UIBarButtonItem alloc] initWithImage:image menu:nil];
            ours.accessibilityLabel = @"More Options";
            // Keep the menu and its source stable while open. Handlers resolve the account at tap time.
            ours.menu = ApolloProfileMoreMenuBuild(viewController);
            objc_setAssociatedObject(viewController, &kApolloProfileMoreMenuItemKey, ours,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            ApolloLog(@"[ProfileMoreMenu] Built own-profile '...' for u/%@ (glyph=%@)",
                      active, apolloItem.image ? @"Apollo's" : @"SF ellipsis");
        }
        if (!recent) {
            __weak UIViewController *weakVC = viewController;
            UIAction *action = [UIAction actionWithTitle:@"Recently Read"
                image:ApolloActionMenuSymbolIcon(@"clock.arrow.circlepath") identifier:nil
                handler:^(__unused UIAction *sender) {
                    UIViewController *vc = weakVC;
                    if (vc) ApolloRecentlyReadPresentFromViewController(vc);
                }];
            recent = [[UIBarButtonItem alloc] initWithPrimaryAction:action];
            recent.title = nil;
            recent.accessibilityLabel = @"Recently Read";
            objc_setAssociatedObject(viewController, &kApolloProfileRecentlyReadItemKey, recent,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (IsLiquidGlass()) {
            if (!toolbar) {
                toolbar = [[UIBarButtonItem alloc] initWithCustomView:
                    [[ApolloProfileRecentActionsView alloc] initWithRecentlyRead:recent more:ours]];
                objc_setAssociatedObject(viewController, &kApolloProfileActionsItemKey, toolbar,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            [desired insertObject:toolbar atIndex:0];
        } else {
            // Bar-item arrays run trailing to leading.
            [desired insertObjects:@[ours, recent]
                         atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, 2)]];
        }
    }

    // Apollo can rewrite items in response to our setter; stop once the order matches.
    if ([desired isEqualToArray:currentItems]) return;

    objc_setAssociatedObject(navigationItem, &kApolloProfileMoreMenuNormalizingKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    navigationItem.rightBarButtonItems = desired;
    objc_setAssociatedObject(navigationItem, &kApolloProfileMoreMenuNormalizingKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloLog(@"[ProfileMoreMenu] Normalized profile nav items (%lu → %lu; ours=%@ apollo=%@)",
              (unsigned long)currentItems.count, (unsigned long)desired.count,
              wantOurs ? @"YES" : @"NO", apolloMenuInstalled ? @"YES" : @"NO");
}

static void ApolloProfileMoreMenuAdoptNavigationItem(UIViewController *viewController) {
    UINavigationItem *navigationItem = viewController.navigationItem;
    // Avoid a cycle: the controller owns its navigation item.
    NSHashTable *holder = [NSHashTable weakObjectsHashTable];
    [holder addObject:viewController];
    objc_setAssociatedObject(navigationItem, &kApolloProfileMoreMenuNavOwnerKey, holder,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloProfileMoreMenuNavigationItemChanged(UINavigationItem *navigationItem) {
    NSHashTable *holder = objc_getAssociatedObject(navigationItem, &kApolloProfileMoreMenuNavOwnerKey);
    UIViewController *owner = holder.anyObject;
    if (owner) ApolloProfileMoreMenuNormalize(owner);
}

#pragma mark - Hooks

%hook _TtC6Apollo21ProfileViewController

- (void)viewDidLoad {
    %orig;
    UIViewController *viewController = (UIViewController *)self;
    ApolloProfileMoreMenuAdoptNavigationItem(viewController);
    ApolloProfileMoreMenuNormalize(viewController);
}

// Profile data and native menu items can arrive after viewDidLoad.
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    ApolloProfileMoreMenuNormalize((UIViewController *)self);
}

- (void)redditAccountChangedWithNotification:(id)notification {
    %orig;
    UIViewController *viewController = (UIViewController *)self;
    dispatch_async(dispatch_get_main_queue(), ^{
        ApolloProfileMoreMenuNormalize(viewController);
    });
}

%end

%hook UINavigationItem

- (void)setRightBarButtonItems:(NSArray *)items {
    %orig;
    ApolloProfileMoreMenuNavigationItemChanged(self);
}

- (void)setRightBarButtonItems:(NSArray *)items animated:(BOOL)animated {
    %orig;
    ApolloProfileMoreMenuNavigationItemChanged(self);
}

// The singular setter does not always call the plural setters.
- (void)setRightBarButtonItem:(UIBarButtonItem *)item {
    %orig;
    ApolloProfileMoreMenuNavigationItemChanged(self);
}

%end

%ctor {
    %init;
    ApolloLog(@"[ProfileMoreMenu] Own-profile '...' menu hooks installed");
}
