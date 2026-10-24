#import <Foundation/Foundation.h>

@class UINavigationController, ApolloDuoSplitState;
@interface TestView : NSObject
@property(nonatomic, strong) NSObject *window;
@end
@implementation TestView
@end
@interface UIViewController : NSObject
@property(nonatomic, copy) NSString *subreddit;
@property(nonatomic, strong) TestView *viewIfLoaded;
@property(nonatomic, strong) UIViewController *presentedViewController;
@property(nonatomic, weak) UIViewController *presentingViewController;
@property(nonatomic, weak) UINavigationController *navigationController;
@property(nonatomic, strong) NSObject *transitionCoordinator;
@property(nonatomic) BOOL isBeingDismissed;
@property(nonatomic) NSUInteger presentations;
@property(nonatomic, copy) void (^dismissalCompletion)(void);
- (void)presentViewController:(UIViewController *)page animated:(BOOL)animated completion:(void (^)(void))completion;
- (void)dismissViewControllerAnimated:(BOOL)animated completion:(void (^)(void))completion;
- (void)finishDismissal;
@end
@implementation UIViewController
- (void)presentViewController:(UIViewController *)page animated:(__unused BOOL)animated completion:(void (^)(void))completion {
    self.presentedViewController = page;
    page.presentingViewController = self;
    self.presentations++;
    if (completion) completion();
}
- (void)dismissViewControllerAnimated:(__unused BOOL)animated completion:(void (^)(void))completion {
    self.dismissalCompletion = completion;
}
- (void)finishDismissal {
    void (^completion)(void) = self.dismissalCompletion;
    self.dismissalCompletion = nil;
    self.presentedViewController.presentingViewController = nil;
    self.presentedViewController = nil;
    if (completion) completion();
}
@end

typedef NSInteger UIAlertActionStyle;
typedef NSInteger UIAlertControllerStyle;
enum { UIAlertActionStyleDefault, UIAlertControllerStyleAlert };
@interface UIAlertAction : NSObject
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) void (^handler)(UIAlertAction *);
+ (instancetype)actionWithTitle:(NSString *)title style:(UIAlertActionStyle)style handler:(void (^)(UIAlertAction *))handler;
@end
@implementation UIAlertAction
+ (instancetype)actionWithTitle:(NSString *)title style:(__unused UIAlertActionStyle)style handler:(void (^)(UIAlertAction *))handler {
    UIAlertAction *action = [self new];
    action.title = title;
    action.handler = handler;
    return action;
}
@end
@interface UIAlertController : UIViewController
@property(nonatomic, copy) NSString *title;
@property(nonatomic, strong) NSMutableArray<UIAlertAction *> *actions;
@property(nonatomic, strong) UIAlertAction *preferredAction;
+ (instancetype)alertControllerWithTitle:(NSString *)title message:(NSString *)message preferredStyle:(UIAlertControllerStyle)style;
- (void)addAction:(UIAlertAction *)action;
@end
@implementation UIAlertController
+ (instancetype)alertControllerWithTitle:(NSString *)title message:(__unused NSString *)message preferredStyle:(__unused UIAlertControllerStyle)style {
    UIAlertController *alert = [self new];
    alert.title = title;
    alert.actions = [NSMutableArray array];
    return alert;
}
- (void)addAction:(UIAlertAction *)action { [self.actions addObject:action]; }
@end

@interface TestPostsPage : UIViewController
@end
@implementation TestPostsPage
@end
static Class ApolloClassPostsViewController;

@interface UINavigationController : UIViewController
@property(nonatomic, copy) NSArray<UIViewController *> *viewControllers;
@property(nonatomic) BOOL lastAnimated;
@property(nonatomic) NSUInteger writes;
@property(nonatomic, weak) ApolloDuoSplitState *duoState;
@property(nonatomic) BOOL routingGuardSeen;
- (void)setViewControllers:(NSArray<UIViewController *> *)pages animated:(BOOL)animated;
@end
@implementation UINavigationController
- (void)setViewControllers:(NSArray<UIViewController *> *)pages animated:(BOOL)animated {
    self.viewControllers = pages;
    self.lastAnimated = animated;
    self.writes++;
}
@end

@interface ApolloDuoSplitHost : NSObject
@property(nonatomic) BOOL listVisible, postsShowingDetail, postsSplitEnabled;
- (void)setListVisible:(BOOL)visible animated:(BOOL)animated;
@end
@implementation ApolloDuoSplitHost
- (void)setListVisible:(BOOL)visible animated:(__unused BOOL)animated { self.listVisible = visible; }
@end

@interface ApolloDuoSplitState : NSObject
@property(nonatomic, strong) UINavigationController *feed, *secondary, *outer, *primary;
@property(nonatomic, strong) NSObject *split;
@property(nonatomic, strong) ApolloDuoSplitHost *host;
@property(nonatomic) BOOL changing, needsDefault, routingSubredditLink, postsTogglingSplit;
@property(nonatomic, weak) UIAlertController *subredditPanePrompt;
@end
@implementation ApolloDuoSplitState
@end
@interface UINavigationController (Push)
- (void)pushViewController:(UIViewController *)page animated:(BOOL)animated;
@end
@implementation UINavigationController (Push)
- (void)pushViewController:(UIViewController *)page animated:(BOOL)animated {
    self.routingGuardSeen = self.duoState.routingSubredditLink;
    self.viewControllers = [(self.viewControllers ?: @[]) arrayByAddingObject:page];
    page.navigationController = self;
    self.lastAnimated = animated;
    self.writes++;
}
@end

static BOOL sDuoSubredditLinksInFeed = YES;
static BOOL splitEnabled, landscape, reduceMotion, adaptiveBars;
static NSUInteger syncs;
static ApolloDuoSplitState *ApolloDuoSplitStateForNavigation(UINavigationController *nav, __unused BOOL create) { return nav.duoState; }
static BOOL ApolloDuoPostsHasLandscapeColumns(__unused ApolloDuoSplitState *state) { return landscape; }
static BOOL ApolloDuoPostsUsesSplit(__unused ApolloDuoSplitState *state) { return splitEnabled && landscape; }
static NSString *ApolloNamedSubredditForPostsController(UIViewController *page) { return page.subreddit; }
static BOOL UIAccessibilityIsReduceMotionEnabled(void) { return reduceMotion; }
static BOOL ApolloDuoUsesAdaptiveBars(void) { return adaptiveBars; }
static void ApolloDuoPostsSyncColumns(__unused ApolloDuoSplitState *state) { syncs++; }
#define ApolloLog(...) do {} while (0)

@interface UISwitch : NSObject
@property(nonatomic, getter=isOn) BOOL on;
@end
@implementation UISwitch
@end

// Isolate preference writes from the host user's actual defaults.
static NSMutableDictionary *preferences;
@interface TestDefaults : NSObject
+ (instancetype)standardUserDefaults;
- (void)setBool:(BOOL)value forKey:(NSString *)key;
- (BOOL)boolForKey:(NSString *)key;
@end
@implementation TestDefaults
+ (instancetype)standardUserDefaults {
    static TestDefaults *defaults;
    if (!defaults) defaults = [TestDefaults new];
    return defaults;
}
- (void)setBool:(BOOL)value forKey:(NSString *)key { preferences[key] = @(value); }
- (BOOL)boolForKey:(NSString *)key {
    if (!preferences[key] && [key isEqual:@"DuoSubredditLinksInFeed"]) return YES;
    return [preferences[key] boolValue];
}
@end
#define NSUserDefaults TestDefaults
static NSString *const UDKeyDuoSubredditLinksInFeed = @"DuoSubredditLinksInFeed";
static NSString *const UDKeyDuoSubredditPaneChosen = @"DuoSubredditPaneChosen";

@interface ApolloSettingsRow : NSObject
@property(nonatomic, copy) BOOL (^isOn)(void);
@property(nonatomic, copy) void (^onToggle)(UISwitch *);
+ (instancetype)switchRowWithID:(NSString *)rowID title:(NSString *)title
                          isOn:(BOOL (^)(void))isOn onToggle:(void (^)(UISwitch *))onToggle;
@end
@implementation ApolloSettingsRow
+ (instancetype)switchRowWithID:(__unused NSString *)rowID title:(__unused NSString *)title
                          isOn:(BOOL (^)(void))isOn onToggle:(void (^)(UISwitch *))onToggle {
    ApolloSettingsRow *row = [self new];
    row.isOn = isOn;
    row.onToggle = onToggle;
    return row;
}
@end

@interface ApolloSettingsSection : NSObject
@property(nonatomic, copy) NSArray<ApolloSettingsRow *> *rows;
@property(nonatomic, copy) BOOL (^visible)(void);
+ (instancetype)sectionWithTitle:(NSString *)title footer:(NSString *)footer rows:(NSArray *)rows;
@end
@implementation ApolloSettingsSection
+ (instancetype)sectionWithTitle:(__unused NSString *)title footer:(__unused NSString *)footer rows:(NSArray *)rows {
    ApolloSettingsSection *section = [self new];
    section.rows = rows;
    return section;
}
@end

@interface SettingsFixture : NSObject
- (ApolloSettingsSection *)buildSubredditsDuoNavigationSection;
@end
@implementation SettingsFixture
// INCLUDE_PRODUCTION_SETTING
@end

// INCLUDE_PRODUCTION_ROUTING
static void SyncHistory(ApolloDuoSplitState *state) {
    // INCLUDE_PRODUCTION_STACK_MIGRATION
}
static void LoadPreference(__unused NSDictionary *persistentDomain) {
    NSUserDefaults *standardDefaults = NSUserDefaults.standardUserDefaults;
    // INCLUDE_PRODUCTION_PREFERENCE_LOAD
}

static NSUInteger checks;
static void Check(BOOL condition, NSString *message) {
    checks++;
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}
static ApolloDuoSplitState *State(void) {
    ApolloDuoSplitState *state = [ApolloDuoSplitState new];
    state.feed = [UINavigationController new];
    state.feed.viewControllers = @[[TestPostsPage new]];
    state.secondary = [UINavigationController new];
    state.secondary.viewControllers = @[[UIViewController new], [UIViewController new]];
    state.primary = [UINavigationController new];
    state.outer = [UINavigationController new];
    state.outer.viewIfLoaded = [TestView new];
    state.outer.viewIfLoaded.window = [NSObject new];
    for (UINavigationController *nav in @[state.feed, state.secondary, state.outer]) nav.duoState = state;
    state.split = [NSObject new];
    state.host = [ApolloDuoSplitHost new];
    state.host.listVisible = YES;
    state.host.postsSplitEnabled = YES;
    state.needsDefault = YES;
    return state;
}
static void CheckUnrouted(ApolloDuoSplitState *state, UINavigationController *origin,
                          UIViewController *page, NSString *reason) {
    NSArray *feed = state.feed.viewControllers;
    NSArray *thread = state.secondary.viewControllers;
    NSUInteger before = syncs;
    Check(!ApolloDuoPostsRouteSubredditLink(state, origin, page, YES), reason);
    Check(state.feed.viewControllers == feed && state.secondary.viewControllers == thread && syncs == before,
          @"unhandled navigation leaves both stacks and geometry unchanged");
}

static UIViewController *Subreddit(void) {
    UIViewController *page = [TestPostsPage new];
    page.subreddit = @"iPhoneDuo";
    return page;
}
static void CheckFeedHistory(void) {
    landscape = splitEnabled = YES;
    ApolloDuoSplitState *state = State();
    UIViewController *home = state.feed.viewControllers.firstObject;
    UIViewController *subreddit = Subreddit();
    UIViewController *next = Subreddit();
    state.feed.viewControllers = @[home, subreddit, next];
    NSArray *thread = state.secondary.viewControllers;
    Check(ApolloDuoPostsFeedPageCount(state.feed.viewControllers) == 3 && ApolloDuoPostsCurrentFeed(state) == next,
          @"multiple subreddit pages remain left-pane history");
    SyncHistory(state);
    Check(state.feed.viewControllers.count == 3 && state.secondary.viewControllers == thread,
          @"landscape synchronization does not mistake previous feeds for comments");
    state.host.postsShowingDetail = YES;
    Check(ApolloDuoSplitDetailNavigation(state.feed) == state.feed && ApolloDuoSplitDetailNavigation(state.secondary) == state.secondary,
          @"Back in either explicit pane stays in that pane even while both are visible");
    Check(ApolloDuoSplitDetailNavigation(state.outer) == state.secondary,
          @"shared outer Back still closes the right detail first");
    state.secondary.viewControllers = @[thread.firstObject];
    state.host.postsShowingDetail = NO;
    Check(ApolloDuoSplitDetailNavigation(state.outer) == state.feed && ApolloDuoPostsCurrentFeed(state) == next,
          @"after closing the thread the left history remains reachable");
    state.feed.viewControllers = @[home, subreddit];
    Check(ApolloDuoPostsCurrentFeed(state) == subreddit, @"left Back restores the previous retained subreddit");
    state.feed.viewControllers = @[home];
    Check(ApolloDuoPostsCurrentFeed(state) == home, @"another left Back restores the original retained feed");
    UIViewController *comment = [UIViewController new];
    state.feed.viewControllers = @[home, subreddit, comment];
    SyncHistory(state);
    Check(state.feed.viewControllers.count == 2 && state.feed.viewControllers.firstObject == home
          && state.secondary.viewControllers.lastObject == comment,
          @"unfolding moves only the thread suffix to the right, preserving all feed history");
    landscape = NO;
    SyncHistory(state);
    Check(state.feed.viewControllers.count == 3 && state.feed.viewControllers[1] == subreddit
          && state.feed.viewControllers.lastObject == comment && state.secondary.viewControllers.count == 1,
          @"portrait restores the native feed-plus-thread Back stack");
    landscape = YES;
    SyncHistory(state);
    Check(state.feed.viewControllers.count == 2 && state.secondary.viewControllers.lastObject == comment,
          @"repeated rotations preserve controller identity and do not duplicate pages");
    Check(ApolloDuoPostsFeedPageCount(@[]) == 0 && ApolloDuoPostsFeedPageCount(@[[UIViewController new]]) == 1,
          @"startup and empty stacks remain valid");
}

static void CheckPromptLifecycle(void) {
    for (NSUInteger choice = 0; choice < 2; choice++) {
        [preferences removeAllObjects];
        sDuoSubredditLinksInFeed = YES;
        ApolloDuoSplitState *state = State();
        UIViewController *page = Subreddit();
        NSArray *feed = state.feed.viewControllers;
        NSArray *thread = state.secondary.viewControllers;
        Check(ApolloDuoPostsRouteSubredditLink(state, state.secondary, page, YES), @"first link waits for a preference");
        UIAlertController *alert = state.subredditPanePrompt;
        Check(alert.actions.count == 2 && [alert.preferredAction.title isEqual:@"Left Pane"], @"first-use prompt recommends Left Pane");
        Check(state.feed.viewControllers == feed && state.secondary.viewControllers == thread
              && !preferences[UDKeyDuoSubredditPaneChosen], @"showing an alert does not navigate or mark it answered");
        Check(ApolloDuoPostsRouteSubredditLink(state, state.secondary, Subreddit(), YES)
              && state.outer.presentations == 1, @"double taps do not create another prompt or destination");
        UIAlertAction *action = alert.actions[choice];
        action.handler(action);
        Check([preferences[UDKeyDuoSubredditPaneChosen] boolValue]
              && sDuoSubredditLinksInFeed == (choice == 0), @"selection persists the chosen side");
        Check(state.feed.viewControllers == feed && state.secondary.viewControllers == thread,
              @"navigation waits for modal dismissal completion");
        [state.outer finishDismissal];
        Check(!state.subredditPanePrompt, @"completed choice releases the pending request");
        if (choice == 0) {
            Check(state.feed.viewControllers.lastObject == page && state.feed.viewControllers.firstObject == feed.firstObject && state.secondary.viewControllers == thread,
                  @"Left completes the original tap and preserves the current thread");
        } else {
            Check(state.feed.viewControllers == feed && state.secondary.viewControllers.lastObject == page
                  && state.secondary.viewControllers.firstObject == thread.firstObject,
                  @"Right completes the original tap with native Back history");
        }
        sDuoSubredditLinksInFeed = choice != 0;
        LoadPreference([preferences copy]);
        Check(sDuoSubredditLinksInFeed == (choice == 0) && [preferences[UDKeyDuoSubredditPaneChosen] boolValue],
              @"simulated relaunch restores both the saved side and answered marker");
        Check(ApolloDuoPostsRouteSubredditLink(state, state.feed, Subreddit(), YES)
              && state.outer.presentations == 1, @"saved choice suppresses future prompts after relaunch");
    }
    [preferences removeAllObjects];
    ApolloDuoSplitState *state = State();
    @autoreleasepool {
        ApolloDuoPostsRouteSubredditLink(state, state.secondary, Subreddit(), YES);
        state.outer.presentedViewController = nil;
    }
    Check(!state.subredditPanePrompt && !preferences[UDKeyDuoSubredditPaneChosen], @"interrupted prompt remains unanswered");
    ApolloDuoPostsRouteSubredditLink(state, state.secondary, Subreddit(), YES);
    Check(state.outer.presentations == 2, @"an interrupted prompt can be shown again");

    [preferences removeAllObjects];
    state = State();
    UIViewController *page = Subreddit();
    ApolloDuoPostsRouteSubredditLink(state, state.secondary, page, YES);
    UIAlertController *alert = state.subredditPanePrompt;
    state.feed = nil;
    state.split = nil;
    UIAlertAction *right = alert.actions.lastObject;
    right.handler(right);
    [state.outer finishDismissal];
    Check(state.outer.viewControllers.lastObject == page && [preferences[UDKeyDuoSubredditPaneChosen] boolValue],
          @"folding with prompt open resumes on the retained outer navigation");

    [preferences removeAllObjects];
    state = State();
    page = Subreddit();
    ApolloDuoPostsRouteSubredditLink(state, state.secondary, page, YES);
    alert = state.subredditPanePrompt;
    landscape = NO;
    UIAlertAction *left = alert.actions.firstObject;
    left.handler(left);
    [state.outer finishDismissal];
    Check(state.feed.viewControllers.lastObject == page, @"rotating to portrait resumes the native feed stack");
    landscape = YES;

    [preferences removeAllObjects];
    sDuoSubredditLinksInFeed = YES;
    state = State();
    state.feed.transitionCoordinator = [NSObject new];
    ApolloDuoPostsRouteSubredditLink(state, state.feed, Subreddit(), YES);
    Check(state.outer.presentations == 0 && !preferences[UDKeyDuoSubredditPaneChosen],
          @"active navigation transition defers the prompt without marking a choice");
    state.feed.transitionCoordinator = nil;
    ApolloDuoPostsRouteSubredditLink(state, state.feed, Subreddit(), YES);
    Check(state.outer.presentations == 1, @"the next eligible tap offers the deferred prompt");
    [preferences removeAllObjects];
    state = State();
    state.outer.presentedViewController = [UIViewController new];
    ApolloDuoPostsRouteSubredditLink(state, state.secondary, Subreddit(), YES);
    Check(state.outer.presentations == 0 && !preferences[UDKeyDuoSubredditPaneChosen], @"another modal defers the alert without marking a choice");
    state.outer.presentedViewController = nil;
    ApolloDuoPostsRouteSubredditLink(state, state.secondary, Subreddit(), YES);
    Check(state.outer.presentations == 1, @"the prompt remains available after the modal closes");
}

int main(void) {
    @autoreleasepool {
        ApolloClassPostsViewController = TestPostsPage.class;
        preferences = [NSMutableDictionary dictionary];
        sDuoSubredditLinksInFeed = NO;
        LoadPreference(@{});
        Check(sDuoSubredditLinksInFeed && !preferences[UDKeyDuoSubredditPaneChosen], @"fresh launch defaults left without treating registration as a choice");
        for (NSNumber *saved in @[@NO, @YES]) {
            preferences[UDKeyDuoSubredditLinksInFeed] = saved;
            [preferences removeObjectForKey:UDKeyDuoSubredditPaneChosen];
            LoadPreference(@{UDKeyDuoSubredditLinksInFeed: saved});
            Check(sDuoSubredditLinksInFeed == saved.boolValue && !preferences[UDKeyDuoSubredditPaneChosen],
                  @"earlier on/off preferences survive upgrade without skipping the new chooser");
        }
        [preferences removeAllObjects];
        LoadPreference(@{});
        ApolloSettingsSection *section = [[SettingsFixture new] buildSubredditsDuoNavigationSection];
        ApolloSettingsRow *row = section.rows.firstObject;
        Check(row.isOn(), @"left pane defaults on");
        Check(!section.visible(), @"Duo navigation section is hidden on regular phones");
        adaptiveBars = YES;
        Check(section.visible(), @"Duo navigation section is visible on Duo");
        UISwitch *control = [UISwitch new];
        control.on = YES;
        row.onToggle(control);
        Check(row.isOn() && [preferences[UDKeyDuoSubredditLinksInFeed] boolValue] && [preferences[UDKeyDuoSubredditPaneChosen] boolValue],
              @"real settings callback updates live routing state and persists the enabled value");
        splitEnabled = landscape = YES;
        UIViewController *subreddit = [TestPostsPage new];
        subreddit.subreddit = @"iPhoneDuo";
        for (NSUInteger origin = 0; origin < 3; origin++) {
            for (NSUInteger motion = 0; motion < 2; motion++) {
                reduceMotion = motion != 0;
                ApolloDuoSplitState *state = State();
                NSArray *thread = state.secondary.viewControllers;
                UINavigationController *nav = @[state.feed, state.secondary, state.outer][origin];
                Check(ApolloDuoPostsRouteSubredditLink(state, nav, subreddit, YES), @"content subreddit link is routed");
                Check(state.feed.viewControllers.count == 2 && state.feed.viewControllers.lastObject == subreddit,
                      @"subreddit pushes onto the left feed Back stack");
                Check(state.secondary.viewControllers == thread && state.secondary.writes == 0,
                      @"right thread instances and navigation history are retained");
                Check(state.feed.lastAnimated == !reduceMotion && !state.needsDefault && !state.host.listVisible,
                      @"routing respects Reduce Motion and completes navigation state");
            }
        }
        reduceMotion = NO;
        ApolloDuoSplitState *state = State();
        CheckUnrouted(state, state.secondary, [UIViewController new], @"comments, profiles and unnamed feeds retain native routing");
        CheckUnrouted(state, state.primary, subreddit, @"drawer selection retains existing behavior");
        CheckUnrouted(state, [UINavigationController new], subreddit, @"unrelated navigation is not redirected");
        state.changing = YES;
        CheckUnrouted(state, state.secondary, subreddit, @"fold/containment changes are not intercepted");
        state.changing = NO;
        landscape = NO;
        CheckUnrouted(state, state.secondary, subreddit, @"portrait retains native routing");
        landscape = YES;
        splitEnabled = NO;
        CheckUnrouted(state, state.secondary, subreddit, @"full-width mode retains native routing");
        splitEnabled = YES;
        state.split = nil;
        CheckUnrouted(state, state.secondary, subreddit, @"closed Duo without split retains native routing");
        state.split = [NSObject new];
        state.feed = nil;
        CheckUnrouted(state, state.secondary, subreddit, @"Search/Account without a feed are not redirected");
        state = State();
        control.on = NO;
        row.onToggle(control);
        Check(!row.isOn() && ![preferences[UDKeyDuoSubredditLinksInFeed] boolValue], @"switching off persists and applies immediately");
        Check(ApolloDuoPostsRouteSubredditLink(state, state.outer, subreddit, YES), @"explicit Right choice handles outer navigation");
        Check(state.secondary.viewControllers.lastObject == subreddit && state.secondary.routingGuardSeen
              && !state.routingSubredditLink && state.outer.presentations == 0,
              @"Right choice opens right without recursion or another prompt");
        CheckPromptLifecycle();
        CheckFeedHistory();
        printf("OK: %lu checks\n", (unsigned long)checks);
    }
    return 0;
}
