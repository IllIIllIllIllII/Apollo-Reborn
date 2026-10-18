#import <Foundation/Foundation.h>
#import <CoreGraphics/CGBase.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#import <math.h>
#define ApolloLog(...) do {} while (0)

typedef NS_ENUM(NSInteger, UIUserInterfaceIdiom) {
    UIUserInterfaceIdiomPhone,
    UIUserInterfaceIdiomPad
};
@interface UIDevice : NSObject
@property (nonatomic) UIUserInterfaceIdiom userInterfaceIdiom;
+ (instancetype)currentDevice;
@end
@implementation UIDevice
+ (instancetype)currentDevice {
    static UIDevice *device;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ device = [self new]; });
    return device;
}
@end

@interface UILabel : NSObject
@property (nonatomic, copy) NSString *text;
@end
@implementation UILabel
@end

@interface UIView : NSObject {
@public
    UILabel *label;
}
@property (nonatomic) BOOL hidden;
@property (nonatomic, weak) UIView *superview;
- (void)sizeToFit;
@end
@implementation UIView
- (void)sizeToFit {}
@end


// UIKit stack/control doubles expose state ownership and target/action behavior;
// production compact helpers below perform every hide/restore decision.
typedef NS_ENUM(NSInteger, UILayoutConstraintAxis) {
    UILayoutConstraintAxisHorizontal,
    UILayoutConstraintAxisVertical
};
typedef NS_OPTIONS(NSUInteger, UIControlEvents) { UIControlEventTouchUpInside = 1 << 6 };
@interface UIControl : UIView
@property (nonatomic, copy) NSSet *allTargets;
@property (nonatomic, copy) NSArray<NSString *> *testActions;
- (NSArray<NSString *> *)actionsForTarget:(id)target forControlEvent:(UIControlEvents)event;
- (void)favoriteSubredditButtonTapped:(id)sender;
@end
@implementation UIControl
- (NSArray<NSString *> *)actionsForTarget:(id)target forControlEvent:(UIControlEvents)event {
    return event == UIControlEventTouchUpInside && [self.allTargets containsObject:target] ? self.testActions : nil;
}
- (void)favoriteSubredditButtonTapped:(__unused id)sender {}
@end
@interface UIStackView : UIView
@property (nonatomic) UILayoutConstraintAxis axis;
@property (nonatomic, copy) NSArray<UIView *> *arrangedSubviews;
- (void)removeArrangedSubview:(UIView *)view;
- (void)insertArrangedSubview:(UIView *)view atIndex:(NSUInteger)index;
@end
@implementation UIStackView
- (void)removeArrangedSubview:(UIView *)view {
    NSMutableArray *views = [self.arrangedSubviews mutableCopy];
    [views removeObjectIdenticalTo:view];
    self.arrangedSubviews = views;
}
- (void)insertArrangedSubview:(UIView *)view atIndex:(NSUInteger)index {
    NSMutableArray *views = [self.arrangedSubviews mutableCopy];
    [views insertObject:view atIndex:index];
    self.arrangedSubviews = views;
    view.superview = self;
}
@end
@interface UIImage : NSObject
@property (nonatomic, strong) UIImage *compactVariant;
@end
@implementation UIImage
@end
@interface UIImageView : UIView
@property (nonatomic, strong) UIImage *image;
@end
@implementation UIImageView
@end
// Raster generation is UIKit-owned; these identity fixtures test the shipping
// ownership/restoration rules without substituting those rules in the harness.
static UIImage *ApolloMetaFeedCompactIcon(UIImage *image) { return image.compactVariant ?: image; }
@interface UITableViewCell : UIView
@property (nonatomic, strong) UIControl *testAccessory;
@property (nonatomic, strong) UIStackView *testStack;
@property (nonatomic) BOOL testStarProxyPresent;
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, strong) UILabel *detailTextLabel;
@end
@implementation UITableViewCell
@end
@interface ApolloSubtitleTableViewCell : UITableViewCell
@end
@implementation ApolloSubtitleTableViewCell
@end
static UIControl *ApolloSubredditIndexRedditListAccessoryButton(UITableViewCell *cell) { return cell.testAccessory; }
static UIStackView *ApolloSubredditIndexRedditListMainStackView(UITableViewCell *cell) { return cell.testStack; }
static void ApolloSubredditIndexRemoveStarProxyFromCell(UITableViewCell *cell) { cell.testStarProxyPresent = NO; }

@interface UILocalizedIndexedCollation : NSObject
@property (nonatomic, copy) NSArray<NSString *> *sectionTitles;
+ (instancetype)currentCollation;
@end
@implementation UILocalizedIndexedCollation
+ (instancetype)currentCollation {
    static UILocalizedIndexedCollation *collation;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ collation = [self new]; });
    return collation;
}
@end

// INCLUDE_PRODUCTION_MODEL

@interface NSIndexPath (TableSections)
@property (nonatomic, readonly) NSInteger section;
@end
@implementation NSIndexPath (TableSections)
- (NSInteger)section { return (NSInteger)[self indexAtPosition:0]; }
@end

@class RedditListViewController;
@interface UITableView : NSObject
@property (nonatomic, strong) id dataSource;
@property (nonatomic) NSInteger numberOfSections;
@property (nonatomic) CGFloat sectionHeaderHeight;
@property (nonatomic, copy) NSArray<NSNumber *> *visibleRowCounts;
@property (nonatomic, weak) UITableViewCell *testIndexedCell;
@property (nonatomic, strong) NSIndexPath *testCellPath;
- (NSInteger)numberOfRowsInSection:(NSInteger)section;
- (NSIndexPath *)indexPathForCell:(UITableViewCell *)cell;
@end
@implementation UITableView
- (NSInteger)numberOfRowsInSection:(NSInteger)section {
    return self.visibleRowCounts ? self.visibleRowCounts[(NSUInteger)section].integerValue : 1;
}
- (NSIndexPath *)indexPathForCell:(UITableViewCell *)cell {
    return cell == self.testIndexedCell ? self.testCellPath : nil;
}
@end

@class UINavigationController;
@interface RedditListViewController : NSObject
@property (nonatomic, strong) ApolloFollowingMap *map;
@property (nonatomic) NSUInteger indexNavigationCalls;
@property (nonatomic, weak) UINavigationController *navigationController;
@property (nonatomic, getter=isEditing) BOOL editing;
- (void)setEditing:(BOOL)editing animated:(BOOL)animated;
- (NSInteger)numberOfSectionsInTableView:(UITableView *)table;
- (CGFloat)tableView:(UITableView *)table heightForHeaderInSection:(NSInteger)section;
- (UIView *)tableView:(UITableView *)table viewForHeaderInSection:(NSInteger)section;
- (NSArray *)sectionIndexTitlesForTableView:(UITableView *)table;
- (NSInteger)tableView:(UITableView *)table sectionForSectionIndexTitle:(NSString *)title atIndex:(NSInteger)index;
@end

@implementation RedditListViewController
- (void)setEditing:(BOOL)editing animated:(__unused BOOL)animated { self.editing = editing; }
- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)table {
    return 4 + (NSInteger)UILocalizedIndexedCollation.currentCollation.sectionTitles.count;
}
- (CGFloat)tableView:(__unused UITableView *)table heightForHeaderInSection:(NSInteger)section {
    return 40.0 + section;
}
- (UIView *)tableView:(__unused UITableView *)table viewForHeaderInSection:(NSInteger)section {
    UIView *header = [UIView new];
    header->label = [UILabel new];
    NSArray *prefix = @[@"FEEDS", @"FAVORITES", @"MULTIREDDITS", @"MODERATOR"];
    header->label.text = section < 4 ? prefix[(NSUInteger)section]
        : UILocalizedIndexedCollation.currentCollation.sectionTitles[(NSUInteger)section - 4];
    return header;
}
- (NSArray *)sectionIndexTitlesForTableView:(__unused UITableView *)table {
    return [@[@"≡", @"★", @"○", @"♜"] arrayByAddingObjectsFromArray:UILocalizedIndexedCollation.currentCollation.sectionTitles];
}
- (NSInteger)tableView:(__unused UITableView *)table sectionForSectionIndexTitle:(__unused NSString *)title atIndex:(NSInteger)index {
    self.indexNavigationCalls++;
    return index;
}
@end

#define UIViewController RedditListViewController
static __weak UIViewController *sApolloFollowingListVC;
static ApolloFollowingMap *ApolloFollowingMapFor(UIViewController *controller) { return controller.map; }
static ApolloFollowingMap *ApolloFollowingPresentedMapForTable(UITableView *table) {
    ApolloFollowingMap *map = [(RedditListViewController *)table.dataSource map];
    return map.active ? map : nil;
}
static id ApolloObjectIvar(id object, const char *name) {
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    return ivar ? object_getIvar(object, ivar) : nil;
}

// INCLUDE_PRODUCTION_FOLLOWING_HELPERS
// INCLUDE_PRODUCTION_FOLLOWING_HOOKS

static BOOL sCompactSubredditListEnabled;
static BOOL sHideSubredditListDescriptions;
static Class ApolloClassRedditListViewController;
static Class ApolloClassApolloSubtitleTableViewCell;
static NSHashTable<UITableView *> *sApolloSubredditKnownTables;
static char kApolloSubredditHeaderSectionKey;
static char kApolloSubredditVisibleHeadersKey;
static char kApolloSubredditCompactHeaderHiddenStateKey;
static char kApolloSubredditCompactHeaderTitleStateKey;
static char kApolloSubredditCompactStarStateKey;
static char kApolloMetaFeedCompactIconStateKey;
static char kApolloSubredditDescriptionStashKey;
static CGFloat (*orig_ApolloRedditListHeightForHeader)(id, SEL, UITableView *, NSInteger);
static UIView *(*orig_ApolloRedditListViewForHeader)(id, SEL, UITableView *, NSInteger);
static NSArray *(*orig_ApolloRedditListIndexTitles)(id, SEL, UITableView *);
static NSInteger (*orig_ApolloRedditListSectionForIndexTitle)(id, SEL, UITableView *, NSString *, NSInteger);

// INCLUDE_PRODUCTION_COMPACT_HELPERS

// The real edit/reveal hooks below run against state-only UIKit doubles. The
// separate tab-bar presentation helpers are outside this regression's scope.
@interface UINavigationController : NSObject
@property (nonatomic, strong) RedditListViewController *topViewController;
@property (nonatomic) BOOL navigationBarHidden;
@property (nonatomic) BOOL hidesBarsOnSwipe;
@property (nonatomic) NSUInteger visibilityWrites;
- (void)setNavigationBarHidden:(BOOL)hidden animated:(BOOL)animated;
@end
@implementation UINavigationController
- (void)setNavigationBarHidden:(BOOL)hidden {
    _navigationBarHidden = hidden;
    self.visibilityWrites++;
}
- (void)setNavigationBarHidden:(BOOL)hidden animated:(__unused BOOL)animated {
    _navigationBarHidden = hidden;
    self.visibilityWrites++;
}
@end
@interface ApolloCompactSubredditPanel : NSObject
@property (nonatomic) BOOL changingNavigation;
@end
@implementation ApolloCompactSubredditPanel
@end
@interface ApolloCompactPanelReference : NSObject
@property (nonatomic, weak) ApolloCompactSubredditPanel *panel;
@end
@implementation ApolloCompactPanelReference
@end
static char kCompactPanelOwner;
static BOOL testHideBarsPreference;
static BOOL ApolloNativeHideBarsOnScrollPreferenceEnabled(void) { return testHideBarsPreference; }
static void ApolloTopBarRestoreNavigationController(__unused UINavigationController *nav) {}
static BOOL ApolloSupportsNativeTabBarScrollBehavior(void) { return YES; }
static BOOL ApolloBarSwipeGestureActive(__unused UINavigationController *nav) { return NO; }
static void ApolloMirrorNavBarStateToTabBar(__unused UINavigationController *nav, __unused BOOL hidden, __unused BOOL animated) {}

// INCLUDE_PRODUCTION_EDITING_HOOKS

static NSUInteger checks;
static void Check(BOOL condition, NSString *message) {
    checks++;
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}

static UITableView *Fixture(NSArray<NSString *> *alphabet, NSArray<NSNumber *> *namedOrder, BOOL separate) {
    UILocalizedIndexedCollation.currentCollation.sectionTitles = alphabet;
    RedditListViewController *controller = [RedditListViewController new];
    ApolloFollowingMap *map = [ApolloFollowingMap new];
    map.active = namedOrder != nil;
    map.hasSyntheticSection = separate;
    map.collationSectionCount = (NSInteger)alphabet.count;
    map.specialSlots = namedOrder ?: @[@1, @2, @3];
    map.sectionNames = @[];
    map.hiddenRows = @[];
    ApolloFollowingEntry *followed = [ApolloFollowingEntry new];
    followed.nativeSection = 5; // Borrow B's (or second localized bucket's) height.
    map.entries = separate ? @[followed] : @[];
    controller.map = map;
    UITableView *table = [UITableView new];
    table.dataSource = controller;
    table.numberOfSections = [controller numberOfSectionsInTableView:table];
    return table;
}

static void ExerciseLayout(NSArray<NSString *> *alphabet, NSArray<NSNumber *> *order, BOOL separate) {
    UITableView *table = Fixture(alphabet, order, separate);
    RedditListViewController *controller = table.dataSource;
    NSMutableArray<NSNumber *> *nativeHeights = [NSMutableArray array];
    NSMutableArray<NSString *> *nativeTitles = [NSMutableArray array];
    sCompactSubredditListEnabled = NO;
    for (NSInteger section = 0; section < table.numberOfSections; section++) {
        [nativeHeights addObject:@([controller tableView:table heightForHeaderInSection:section])];
        [nativeTitles addObject:[controller tableView:table viewForHeaderInSection:section]->label.text];
    }
    NSArray *indexBefore = [controller sectionIndexTitlesForTableView:table];
    NSMutableArray<NSNumber *> *nativeTargets = [NSMutableArray array];
    for (NSUInteger index = 0; index < indexBefore.count; index++) {
        [nativeTargets addObject:@([controller tableView:table sectionForSectionIndexTitle:indexBefore[index] atIndex:(NSInteger)index])];
    }
    NSUInteger navigationCallsBefore = controller.indexNavigationCalls;
    sCompactSubredditListEnabled = YES;
    BOOL sawSubredditsHeader = NO;
    for (NSInteger section = 0; section < table.numberOfSections; section++) {
        NSString *title = nativeTitles[(NSUInteger)section];
        CGFloat height = [controller tableView:table heightForHeaderInSection:section];
        UIView *header = [controller tableView:table viewForHeaderInSection:section];
        // Expected categories come from the fixture's actual native header
        // values, not a repetition of the production suffix arithmetic.
        if ([alphabet containsObject:title]) {
            if (!sawSubredditsHeader) {
                Check(height == nativeHeights[(NSUInteger)section].doubleValue,
                      @"The first subreddit bucket retains its native header height");
                Check(header && [header->label.text isEqual:@"SUBREDDITS"],
                      @"One Subreddits heading separates named sections from the subreddit rows");
                sawSubredditsHeader = YES;
            } else {
                Check(height > 0 && height < 0.01, @"Later localized alphabet buckets reserve no header space");
                Check(header == nil, @"Later localized alphabet buckets draw no header/divider");
            }
        } else {
            Check(height == nativeHeights[(NSUInteger)section].doubleValue, @"Named header keeps its original (or donor) height");
            Check(header && [header->label.text isEqual:title], @"Named header remains present and correctly titled");
        }
    }
    Check(sawSubredditsHeader, @"Every nonempty compact fixture has one Subreddits heading");
    Check(controller.indexNavigationCalls == navigationCallsBefore, @"Measuring/styling headers never invokes navigation");
    NSArray *compactIndex = [controller sectionIndexTitlesForTableView:table];
    Check([compactIndex isEqual:alphabet], @"Compact index contains only the localized alphabet, including its trailing bucket");
    for (NSUInteger index = 0; index < compactIndex.count; index++) {
        NSInteger target = [controller tableView:table sectionForSectionIndexTitle:compactIndex[index] atIndex:(NSInteger)index];
        if (index == 0) {
            Check(target == 0, @"Scrubbing all the way to the first letter reaches the feed shortcuts at the top");
        } else {
            Check(target >= 0 && target < (NSInteger)nativeTitles.count,
                  @"Every later compact index entry resolves to a visible section");
            Check([nativeTitles[(NSUInteger)target] isEqual:compactIndex[index]],
                  @"Later compact letters reach their own bucket after reordered named sections and Following");
        }
    }
    Check([controller tableView:table sectionForSectionIndexTitle:@"A" atIndex:-1] == NSNotFound,
          @"A stale negative compact index does not select a named section");
    Check([controller tableView:table sectionForSectionIndexTitle:@"#" atIndex:(NSInteger)compactIndex.count] == NSNotFound,
          @"A stale index beyond the alphabet cannot scroll outside the table");
    Check(controller.indexNavigationCalls == navigationCallsBefore,
          @"Compact navigation bypasses native deferred-scroll side effects");
    sCompactSubredditListEnabled = NO;
    Check([[controller sectionIndexTitlesForTableView:table] isEqual:indexBefore],
          @"Disabling Compact List restores all upstream special glyphs and letters");
    for (NSInteger section = 0; section < table.numberOfSections; section++) {
        Check([controller tableView:table heightForHeaderInSection:section] == nativeHeights[(NSUInteger)section].doubleValue,
            @"Disabling Compact List restores exact upstream header heights");
        UIView *header = [controller tableView:table viewForHeaderInSection:section];
        Check(header && [header->label.text isEqual:nativeTitles[(NSUInteger)section]], @"Disabling restores all native header views");
    }
    for (NSUInteger index = 0; index < indexBefore.count; index++) {
        NSInteger target = [controller tableView:table sectionForSectionIndexTitle:indexBefore[index] atIndex:(NSInteger)index];
        Check(target == nativeTargets[index].integerValue, @"Disabling Compact List restores every upstream index destination");
    }
}

static void ExerciseCompactHeaderBoundary(void) {
    UITableView *table = Fixture(@[@"A", @"B", @"#"], @[@(-2), @3, @1, @2], YES);
    RedditListViewController *controller = table.dataSource;
    sCompactSubredditListEnabled = YES;
    // Following, Moderator, Favorites and Multireddits all precede collation;
    // an empty A bucket must not leave a floating heading before the B rows.
    table.visibleRowCounts = @[@4, @1, @1, @1, @1, @0, @2, @1];
    Check(ApolloSubredditIndexFirstCompactCollationSection(table) == 5,
          @"Reordered named sections and Following stay above the subreddit boundary");
    Check(ApolloSubredditIndexCompactSubredditsHeaderSection(table) == 6,
          @"Subreddits heading attaches to the first populated visible bucket");
    Check([controller tableView:table viewForHeaderInSection:5] == nil,
          @"An empty leading collation bucket creates no heading");
    UIView *header = [controller tableView:table viewForHeaderInSection:6];
    Check(header && [header->label.text isEqual:@"SUBREDDITS"],
          @"The first populated bucket has the shared title");
    ApolloSubredditIndexApplyCompactHeaderTitle(header, table);
    sCompactSubredditListEnabled = NO;
    ApolloSubredditIndexApplyCompactHeaderTitle(header, table);
    Check([header->label.text isEqual:@"B"],
          @"Repeated compact preparation preserves the native title for toggle-off");

    sCompactSubredditListEnabled = YES;
    ApolloSubredditIndexApplyCompactHeaderTitle(header, table);
    table.visibleRowCounts = @[@4, @1, @1, @1, @1, @1, @2, @1];
    Check(ApolloSubredditIndexCompactSubredditsHeaderSection(table) == 5,
          @"Adding a subreddit to an earlier bucket moves the shared heading");
    ApolloSubredditIndexApplyCompactHeaderTitle(header, table);
    Check([header->label.text isEqual:@"B"],
          @"A surviving old shared heading restores its original bucket title");
    Check(ApolloSubredditIndexApplyCompactHeaderVisibility(header, table) && header.hidden,
          @"The old heading is hidden after the first populated bucket moves");
    UIView *newHeader = [controller tableView:table viewForHeaderInSection:5];
    Check(newHeader && [newHeader->label.text isEqual:@"SUBREDDITS"],
          @"The newly populated first bucket becomes the only shared heading");

    table.visibleRowCounts = @[@4, @1, @1, @1, @1, @0, @0, @0];
    Check(ApolloSubredditIndexCompactSubredditsHeaderSection(table) == NSNotFound,
          @"An empty subscription list has no phantom Subreddits heading");
    for (NSInteger section = 5; section < table.numberOfSections; section++) {
        Check([controller tableView:table viewForHeaderInSection:section] == nil,
              @"All-empty collation buckets stay collapsed");
    }
    Check([controller tableView:table viewForHeaderInSection:1] != nil,
          @"Following remains visible when no subreddit bucket is populated");
    sCompactSubredditListEnabled = NO;
    ApolloSubredditIndexApplyCompactHeaderTitle(newHeader, table);
    Check([newHeader->label.text isEqual:@"A"],
          @"Disabling compact restores a retained shared heading after all rows disappear");

    table.visibleRowCounts = @[@4, @1, @1, @1, @1, @1, @2, @1];
    sCompactSubredditListEnabled = YES;
    ApolloSubredditIndexApplyCompactHeaderTitle(newHeader, table);
    newHeader->label.text = @"FAVORITES"; // Apollo reused/reconfigured the native view.
    objc_setAssociatedObject(newHeader, &kApolloSubredditHeaderSectionKey, @3, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloSubredditIndexApplyCompactHeaderTitle(newHeader, table);
    Check([newHeader->label.text isEqual:@"FAVORITES"],
          @"Native reconfiguration takes precedence over the old captured bucket title");
    sCompactSubredditListEnabled = NO;
    ApolloSubredditIndexApplyCompactHeaderTitle(newHeader, table);
    Check([newHeader->label.text isEqual:@"FAVORITES"],
          @"Toggle-off cannot overwrite a newly configured named header with an old letter");
}


static UITableViewCell *StarFixture(BOOL favorite, BOOL hidden, BOOL arranged) {
    UITableViewCell *cell = [UITableViewCell new];
    UIControl *control = [UIControl new];
    control.allTargets = [NSSet setWithObject:[NSObject new]];
    control.testActions = @[favorite ? @"favoriteSubredditButtonTapped:" : @"expandMultiredditButtonTapped:"];
    control.hidden = hidden;
    cell.testAccessory = control;
    UIStackView *stack = [UIStackView new];
    stack.arrangedSubviews = arranged ? @[[UIView new], control, [UIView new]] : @[[UIView new]];
    control.superview = stack;
    cell.testStack = stack;
    cell.testStarProxyPresent = favorite && !hidden;
    return cell;
}

static void ExerciseFavoritesSectionIdentity(void) {
    NSArray *cases = @[
        @{@"order": NSNull.null, @"following": @NO, @"favorites": @1},
        @{@"order": @[@3, @1, @2], @"following": @NO, @"favorites": @2},
        @{@"order": @[@(-2), @3, @1, @2], @"following": @YES, @"favorites": @3},
        @{@"order": @[@2, @1, @3, @(-2)], @"following": @YES, @"favorites": @2},
        @{@"order": @[@1, @3, @2, @(-2)], @"following": @YES, @"favorites": @1}
    ];
    for (NSDictionary *testCase in cases) {
        NSArray *order = testCase[@"order"] == NSNull.null ? nil : testCase[@"order"];
        UITableView *table = Fixture(@[@"A", @"B", @"#"], order, [testCase[@"following"] boolValue]);
        UITableViewCell *cell = [UITableViewCell new];
        table.testIndexedCell = cell;
        for (NSNumber *compact in @[@NO, @YES]) {
            sCompactSubredditListEnabled = compact.boolValue;
            NSArray *index = [(RedditListViewController *)table.dataSource sectionIndexTitlesForTableView:table];
            Check([index containsObject:@"★"] != compact.boolValue,
                  @"Favorite identity is exercised both with and without the special index glyph");
            for (NSInteger section = 0; section < table.numberOfSections; section++) {
                NSUInteger components[] = {(NSUInteger)section, 0};
                table.testCellPath = [NSIndexPath indexPathWithIndexes:components length:2];
                BOOL expectedFavorite = section == [testCase[@"favorites"] integerValue];
                Check(ApolloSubredditIndexCellIsInFavoritesSection(cell, table) == expectedFavorite,
                      @"Favorite identity follows its visible section while excluding feeds, Following, moderator, multireddits and alphabetical rows");
            }
        }
        table.testCellPath = nil;
        Check(!ApolloSubredditIndexCellIsInFavoritesSection(cell, table),
              @"A detached favorite cell has no visible Favorites identity");
        Check(!ApolloSubredditIndexCellIsInFavoritesSection(nil, table)
              && !ApolloSubredditIndexCellIsInFavoritesSection(cell, nil),
              @"Missing cell or table cannot be mistaken for Favorites");
    }
}

static void ExerciseCompactStars(void) {
    UITableView *table = Fixture(@[@"A", @"B", @"#"], nil, NO);
    sCompactSubredditListEnabled = YES;
    UITableViewCell *cell = StarFixture(YES, NO, YES);
    NSArray *nativeOrder = cell.testStack.arrangedSubviews;
    ApolloSubredditIndexApplyCompactStar(table, cell);
    Check(cell.testAccessory.hidden, @"Compact List hides a native favorite accessory");
    Check(!cell.testStarProxyPresent, @"The invisible expanded favorite hit target is removed too");
    Check(cell.testStack.arrangedSubviews.count == 2, @"The favorite no longer reserves horizontal stack space");
    Check(cell.testAccessory.superview == cell.testStack, @"The native control stays retained in its original hierarchy");
    ApolloSubredditIndexApplyCompactStar(table, cell);
    Check(cell.testStack.arrangedSubviews.count == 2, @"Repeated preparation does not remove unrelated arranged views");
    // Native editing can reveal an existing control; preparation must re-hide
    // it without capturing our hidden state as the new native baseline.
    cell.testAccessory.hidden = NO;
    ApolloSubredditIndexApplyCompactStar(table, cell);
    Check(cell.testAccessory.hidden, @"Native Edit/Done reconfiguration cannot reveal a compact favorite");
    sCompactSubredditListEnabled = NO;
    ApolloSubredditIndexApplyCompactStar(table, cell);
    Check(!cell.testAccessory.hidden, @"Turning compact off restores native favorite visibility");
    Check([cell.testStack.arrangedSubviews isEqual:nativeOrder], @"Turning compact off restores the exact native arrangement");
    ApolloSubredditIndexRestoreCompactStar(cell);
    Check([cell.testStack.arrangedSubviews isEqual:nativeOrder], @"Repeated restoration cannot duplicate the accessory");

    sCompactSubredditListEnabled = YES;
    cell = StarFixture(YES, NO, YES);
    UIView *nativeTitle = [UIView new];
    UIView *nativeIcon = [UIView new];
    cell.testStack.arrangedSubviews = @[nativeTitle, cell.testAccessory];
    ApolloSubredditIndexApplyCompactStar(table, cell);
    cell.testStack.arrangedSubviews = @[nativeIcon, nativeTitle];
    ApolloSubredditIndexRestoreCompactStar(cell);
    Check([cell.testStack.arrangedSubviews isEqual:@[nativeIcon, nativeTitle, cell.testAccessory]],
          @"Enabling native list icons keeps the restored star after the title");
    ApolloSubredditIndexApplyCompactStar(table, cell);
    cell.testStack.arrangedSubviews = @[nativeTitle];
    ApolloSubredditIndexRestoreCompactStar(cell);
    Check([cell.testStack.arrangedSubviews isEqual:@[nativeTitle, cell.testAccessory]],
          @"Disabling native list icons keeps the restored star after the title");

    sCompactSubredditListEnabled = YES;
    cell = StarFixture(NO, NO, YES);
    nativeOrder = cell.testStack.arrangedSubviews;
    ApolloSubredditIndexApplyCompactStar(table, cell);
    Check(!cell.testAccessory.hidden && [cell.testStack.arrangedSubviews isEqual:nativeOrder],
          @"The same accessory used for multireddit expansion stays visible and arranged");
    cell = StarFixture(YES, YES, YES);
    ApolloSubredditIndexApplyCompactStar(table, cell);
    ApolloSubredditIndexRestoreCompactStar(cell);
    Check(cell.testAccessory.hidden, @"Reuse restores a natively hidden accessory without exposing it");

    cell = StarFixture(YES, NO, YES);
    ApolloSubredditIndexApplyCompactStar(table, cell);
    ApolloSubredditIndexRestoreCompactStar(cell); // prepareForReuse does this before native configuration.
    cell.testAccessory.testActions = @[@"expandMultiredditButtonTapped:"];
    ApolloSubredditIndexApplyCompactStar(table, cell);
    Check(!cell.testAccessory.hidden && cell.testStack.arrangedSubviews.count == 3,
          @"A reused favorite cell can become a multireddit expansion row");
    cell = StarFixture(YES, NO, NO);
    nativeOrder = cell.testStack.arrangedSubviews;
    ApolloSubredditIndexApplyCompactStar(table, cell);
    ApolloSubredditIndexRestoreCompactStar(cell);
    Check(!cell.testAccessory.hidden && [cell.testStack.arrangedSubviews isEqual:nativeOrder],
          @"A control outside arrangedSubviews restores without inventing stack geometry");
    cell = StarFixture(YES, NO, YES);
    table.dataSource = [NSObject new];
    ApolloSubredditIndexApplyCompactStar(table, cell);
    Check(!cell.testAccessory.hidden && cell.testStarProxyPresent && cell.testStack.arrangedSubviews.count == 3,
          @"Compact List leaves accessory controls in unrelated tables unchanged");
}


static void ExerciseWrappedShortcuts(void) {
    NSArray *four = @[@90, @105, @65, @135];
    NSArray<NSValue *> *ranges = ApolloMetaFeedWrappedRanges(four, 252.0);
    Check(ranges.count == 2 && NSEqualRanges(ranges[0].rangeValue, NSMakeRange(0, 2))
          && NSEqualRanges(ranges[1].rangeValue, NSMakeRange(2, 2)),
          @"A narrow panel wraps Home/Popular and All/Moderator as whole shortcuts");
    ranges = ApolloMetaFeedWrappedRanges(four, 395.0);
    Check(ranges.count == 1 && NSEqualRanges(ranges[0].rangeValue, NSMakeRange(0, 4)),
          @"A wide panel fits all four shortcuts at their intrinsic widths");
    ranges = ApolloMetaFeedWrappedRanges(@[@135, @90, @65], 252.0);
    Check(ranges.count == 2 && NSEqualRanges(ranges[1].rangeValue, NSMakeRange(2, 1)),
          @"Hidden/reordered feeds preserve visible order across the wrap");
    ranges = ApolloMetaFeedWrappedRanges(@[@500, @65], 252.0);
    Check(ranges.count == 2 && ranges[0].rangeValue.length == 1,
          @"An oversized title gets its own row instead of being dropped or combined");
    Check(ApolloMetaFeedWrappedRanges(@[], 252.0).count == 0, @"An empty visible prefix creates no phantom rows");
    ranges = ApolloMetaFeedWrappedRanges(@[@10, @10], 80.0);
    Check(ranges.count == 2, @"Short labels retain at least 44pt of tappable control width");
    ranges = ApolloMetaFeedWrappedRanges(@[@90, @105], 0.0);
    Check(ranges.count == 2, @"Transient zero-width geometry terminates without losing shortcuts");
    // Across rotation widths and feed visibility combinations, every shortcut
    // appears once and in order; multi-item rows never exceed available space.
    for (NSUInteger count = 1; count <= four.count; count++) {
        NSArray *items = [four subarrayWithRange:NSMakeRange(0, count)];
        NSUInteger priorCount = count;
        for (CGFloat width = 80.0; width <= 500.0; width += 17.0) {
            ranges = ApolloMetaFeedWrappedRanges(items, width);
            Check(ranges.count <= priorCount, @"Widening a panel never adds wrapped rows");
            priorCount = ranges.count;
            NSUInteger next = 0;
            for (NSValue *value in ranges) {
                NSRange range = value.rangeValue;
                Check(range.location == next && range.length > 0 && NSMaxRange(range) <= items.count,
                      @"Wrapping preserves every shortcut's order and identity");
                CGFloat used = 0.0;
                for (NSUInteger item = range.location; item < NSMaxRange(range); item++) used += [items[item] doubleValue];
                Check(range.length == 1 || used <= width, @"A multi-shortcut row always has room for full labels and icons");
                next = NSMaxRange(range);
            }
            Check(next == count, @"Wrapping neither duplicates nor drops a visible shortcut");
        }
    }
}


static void ExerciseCompactDensity(void) {
    Check(ApolloCompactListHeightForContent(28.0) == 36.0,
          @"Default native 28pt icons produce the requested 36pt compact row");
    Check(ApolloCompactListHeightForContent(20.3) == 36.0,
          @"A normal single title never collapses below the compact density floor");
    Check(ApolloCompactListHeightForContent(38.0) == 46.0,
          @"Larger title content expands beyond the compact row floor");
    Check(ApolloCompactListHeightForContent(56.2) == 65.0,
          @"Large text grows the row instead of being clipped to 36pt");
    Check(ApolloCompactListHeightForContent(0.0) == 36.0,
          @"Temporarily unmeasured content keeps stable compact row height");
    UITableView *table = Fixture(@[@"A", @"B", @"#"], nil, NO);
    UITableViewCell *cell = [UITableViewCell new];
    cell.imageView = [UIImageView new];
    UIImage *native = [UIImage new];
    UIImage *compact = [UIImage new];
    native.compactVariant = compact;
    cell.imageView.image = native;
    sCompactSubredditListEnabled = YES;
    ApolloMetaFeedApplyCompactIcon(table, cell);
    Check(cell.imageView.image == compact, @"Compact native feed rows use the smaller rendering of their existing artwork");
    ApolloMetaFeedApplyCompactIcon(table, cell);
    sCompactSubredditListEnabled = NO;
    ApolloMetaFeedApplyCompactIcon(table, cell);
    Check(cell.imageView.image == native, @"Disabling Compact List restores the exact original native icon");
    sCompactSubredditListEnabled = YES;
    ApolloMetaFeedApplyCompactIcon(table, cell);
    ApolloMetaFeedRestoreCompactIcon(cell);
    Check(cell.imageView.image == native, @"Cell reuse restores the native icon before new configuration");
    ApolloMetaFeedApplyCompactIcon(table, cell);
    UIImage *newThemeIcon = [UIImage new];
    cell.imageView.image = newThemeIcon;
    ApolloMetaFeedRestoreCompactIcon(cell);
    Check(cell.imageView.image == newThemeIcon, @"Restoration cannot overwrite an icon Apollo has replaced for a new theme");
    table.dataSource = [NSObject new];
    cell.imageView.image = native;
    ApolloMetaFeedApplyCompactIcon(table, cell);
    Check(cell.imageView.image == native, @"Compact icon rendering never affects unrelated tables");
}

static void ExerciseCompactDescriptions(void) {
    UITableView *table = Fixture(@[@"A", @"B", @"#"], nil, NO);
    UITableViewCell *cell = [ApolloSubtitleTableViewCell new];
    cell.detailTextLabel = [UILabel new];
    cell.detailTextLabel.text = @"Posts from your subscribed subreddits";
    sHideSubredditListDescriptions = NO;
    sCompactSubredditListEnabled = NO;
    ApolloSubredditIndexApplyDescriptionPreference(table, cell);
    Check(cell.detailTextLabel.text.length > 0, @"Normal mode retains a visible description when its preference is off");
    sCompactSubredditListEnabled = YES;
    ApolloSubredditIndexApplyDescriptionPreference(table, cell);
    Check(cell.detailTextLabel.text.length == 0, @"Compact mode hides feed descriptions even when the separate preference is off");
    Check(!sHideSubredditListDescriptions, @"Compact mode leaves the user's standalone description preference intact");
    ApolloSubredditIndexApplyDescriptionPreference(table, cell);
    sCompactSubredditListEnabled = NO;
    ApolloSubredditIndexApplyDescriptionPreference(table, cell);
    Check([cell.detailTextLabel.text isEqual:@"Posts from your subscribed subreddits"],
          @"Disabling compact restores a cached native description after repeated preparation");

    sCompactSubredditListEnabled = YES;
    ApolloSubredditIndexApplyDescriptionPreference(table, cell);
    cell.detailTextLabel.text = @"Popular posts across Reddit"; // Native reconfiguration, including Edit/Done.
    ApolloSubredditIndexApplyDescriptionPreference(table, cell);
    Check(cell.detailTextLabel.text.length == 0, @"Native reconfiguration cannot reveal a compact feed description");
    sCompactSubredditListEnabled = NO;
    ApolloSubredditIndexApplyDescriptionPreference(table, cell);
    Check([cell.detailTextLabel.text isEqual:@"Popular posts across Reddit"],
          @"Disabling compact restores the latest native description instead of stale content");

    sHideSubredditListDescriptions = YES;
    ApolloSubredditIndexApplyDescriptionPreference(table, cell);
    Check(cell.detailTextLabel.text.length == 0, @"The explicit Hide Feed Descriptions setting still works outside compact mode");
    sCompactSubredditListEnabled = YES;
    ApolloSubredditIndexApplyDescriptionPreference(table, cell);
    sCompactSubredditListEnabled = NO;
    ApolloSubredditIndexApplyDescriptionPreference(table, cell);
    Check(cell.detailTextLabel.text.length == 0, @"Turning compact off respects an independently enabled hide setting");
    sHideSubredditListDescriptions = NO;
    ApolloSubredditIndexApplyDescriptionPreference(table, cell);
    Check([cell.detailTextLabel.text isEqual:@"Popular posts across Reddit"],
          @"Turning off the standalone hide setting restores the description too");

    sCompactSubredditListEnabled = YES;
    table.dataSource = [NSObject new];
    ApolloSubredditIndexApplyDescriptionPreference(table, cell);
    Check(cell.detailTextLabel.text.length > 0, @"Compact preference does not hide descriptions in an unrelated table");
    table = Fixture(@[@"A", @"B", @"#"], nil, NO);
    UITableViewCell *ordinary = [UITableViewCell new];
    ordinary.detailTextLabel = [UILabel new];
    ordinary.detailTextLabel.text = @"Unrelated detail";
    ApolloSubredditIndexApplyDescriptionPreference(table, ordinary);
    Check([ordinary.detailTextLabel.text isEqual:@"Unrelated detail"],
          @"Compact feed description behavior leaves other cell classes untouched");
}

// A phone backup may restore the stored preference on an iPad even though
// that device has no Compact List switch or panel. Exercise the actual header,
// favorite, and native-icon entry points with that restored value.
static void ExerciseRestoredPreferenceOnIPad(void) {
    UITableView *table = Fixture(@[@"A", @"B", @"#"], @[@(-2), @3, @1, @2], YES);
    RedditListViewController *controller = table.dataSource;
    sCompactSubredditListEnabled = NO;
    NSMutableArray<NSNumber *> *nativeHeights = [NSMutableArray array];
    for (NSInteger section = 0; section < table.numberOfSections; section++) {
        [nativeHeights addObject:@([controller tableView:table heightForHeaderInSection:section])];
    }
    NSArray *nativeIndex = [controller sectionIndexTitlesForTableView:table];
    NSMutableArray<NSNumber *> *nativeTargets = [NSMutableArray array];
    for (NSUInteger index = 0; index < nativeIndex.count; index++) {
        [nativeTargets addObject:@([controller tableView:table sectionForSectionIndexTitle:nativeIndex[index] atIndex:(NSInteger)index])];
    }
    UIDevice.currentDevice.userInterfaceIdiom = UIUserInterfaceIdiomPad;
    sCompactSubredditListEnabled = YES;
    Check(!ApolloCompactListEnabledForDevice(), @"Restored compact preference does not enable phone-only shortcut wrapping on iPad");
    Check(!ApolloSubredditIndexUsesCompactRows(table), @"Restored compact preference does not enable row density on iPad");
    Check([[controller sectionIndexTitlesForTableView:table] isEqual:nativeIndex],
          @"iPad retains all named and alphabetical index entries despite a restored compact preference");
    for (NSUInteger index = 0; index < nativeIndex.count; index++) {
        Check([controller tableView:table sectionForSectionIndexTitle:nativeIndex[index] atIndex:(NSInteger)index] == nativeTargets[index].integerValue,
              @"iPad retains every native index destination, including its first letter's original bucket");
    }
    for (NSInteger section = 0; section < table.numberOfSections; section++) {
        Check([controller tableView:table heightForHeaderInSection:section] == nativeHeights[(NSUInteger)section].doubleValue,
              @"iPad keeps native alphabetical and named header heights despite a restored compact preference");
        Check([controller tableView:table viewForHeaderInSection:section] != nil,
              @"iPad keeps native alphabetical and named header views despite a restored compact preference");
    }
    UITableViewCell *cell = StarFixture(YES, NO, YES);
    NSArray *nativeOrder = cell.testStack.arrangedSubviews;
    ApolloSubredditIndexApplyCompactStar(table, cell);
    Check(!cell.testAccessory.hidden && cell.testStarProxyPresent && [cell.testStack.arrangedSubviews isEqual:nativeOrder],
          @"iPad retains its native favorite controls and arrangement");
    cell.imageView = [UIImageView new];
    UIImage *native = [UIImage new];
    native.compactVariant = [UIImage new];
    cell.imageView.image = native;
    ApolloMetaFeedApplyCompactIcon(table, cell);
    Check(cell.imageView.image == native, @"iPad native shortcut artwork retains its original size");
    UITableViewCell *feed = [ApolloSubtitleTableViewCell new];
    feed.detailTextLabel = [UILabel new];
    feed.detailTextLabel.text = @"Feed description";
    sHideSubredditListDescriptions = NO;
    ApolloSubredditIndexApplyDescriptionPreference(table, feed);
    Check([feed.detailTextLabel.text isEqual:@"Feed description"],
          @"iPad retains descriptions despite a restored phone-only compact preference");
    UIDevice.currentDevice.userInterfaceIdiom = UIUserInterfaceIdiomPhone;
    Check(ApolloCompactListEnabledForDevice() && ApolloSubredditIndexUsesCompactRows(table),
          @"The same preference still enables Compact List on phones");
}

static void ExerciseEditingNavigationOwnership(void) {
    UINavigationController *nav = [UINavigationController new];
    RedditListViewController *list = [RedditListViewController new];
    nav.topViewController = list;
    list.navigationController = nav;
    testHideBarsPreference = YES;
    [nav setNavigationBarHidden:YES animated:NO];
    [list setEditing:YES animated:YES];
    Check(list.isEditing && !nav.navigationBarHidden && !nav.hidesBarsOnSwipe,
          @"The native full list reveals Done and disables swipe hiding during Edit");
    [nav setNavigationBarHidden:YES];
    Check(!nav.navigationBarHidden, @"The native property setter cannot hide Done during Edit");
    [nav setNavigationBarHidden:YES animated:YES];
    Check(!nav.navigationBarHidden, @"The native animated setter cannot hide Done during Edit");
    [list setEditing:NO animated:NO];
    Check(nav.hidesBarsOnSwipe, @"Done restores the full list's configured swipe-hiding behavior");

    ApolloCompactSubredditPanel *panel = [ApolloCompactSubredditPanel new];
    ApolloCompactPanelReference *reference = [ApolloCompactPanelReference new];
    reference.panel = panel;
    objc_setAssociatedObject(nav, &kCompactPanelOwner, reference, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    nav.hidesBarsOnSwipe = NO;
    [nav setNavigationBarHidden:YES animated:NO];
    NSUInteger writes = nav.visibilityWrites;
    [list setEditing:YES animated:YES];
    Check(list.isEditing && nav.navigationBarHidden && !nav.hidesBarsOnSwipe,
          @"The compact panel enters Edit without revealing a second navigation title");
    Check(nav.visibilityWrites == writes, @"Panel Edit does not enqueue a redundant reveal of its child navigation bar");
    [nav setNavigationBarHidden:NO];
    Check(nav.navigationBarHidden, @"Panel ownership takes precedence over Edit in the property setter");
    [nav setNavigationBarHidden:NO animated:YES];
    Check(nav.navigationBarHidden, @"Panel ownership takes precedence over Edit in the animated setter");
    [list setEditing:NO animated:YES];
    Check(nav.navigationBarHidden && !nav.hidesBarsOnSwipe,
          @"Panel Done preserves its own bar and does not re-enable native swipe hiding");
    [nav setNavigationBarHidden:NO];
    Check(nav.navigationBarHidden, @"Panel ownership still prevents a duplicate bar after Done");

    panel.changingNavigation = YES;
    [nav setNavigationBarHidden:NO animated:NO];
    Check(!nav.navigationBarHidden, @"Returning the borrowed list releases panel visibility ownership");
    [list setEditing:YES animated:NO];
    Check(!nav.navigationBarHidden, @"Native Done protection resumes while the list leaves the compact panel");
    objc_setAssociatedObject(nav, &kCompactPanelOwner, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [list setEditing:NO animated:NO];
    [nav setNavigationBarHidden:YES];
    Check(nav.navigationBarHidden && nav.hidesBarsOnSwipe,
          @"The restored native list again accepts regular hide requests and its swipe preference");

    nav.topViewController = [RedditListViewController new];
    nav.hidesBarsOnSwipe = YES;
    [list setEditing:YES animated:NO];
    Check(nav.hidesBarsOnSwipe && nav.navigationBarHidden,
          @"Editing an offscreen list cannot change the visible navigation controller");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        ApolloClassRedditListViewController = RedditListViewController.class;
        ApolloClassApolloSubtitleTableViewCell = ApolloSubtitleTableViewCell.class;
        sApolloSubredditKnownTables = [NSHashTable weakObjectsHashTable];
        BOOL innerControl = argc > 1 && strcmp(argv[1], "--inner-hook-control") == 0;
        if (innerControl) {
            ApolloSubredditIndexInstallCompactHeaderHooks();
            InstallFollowingHooks();
            UITableView *table = Fixture(@[@"A", @"B", @"#"], @[@(-2), @1, @2, @3], YES);
            // Following borrows native B (5). With an empty visible A (5),
            // an inner compact hook misreads that native donor as visible A.
            table.visibleRowCounts = @[@4, @1, @1, @1, @1, @0, @1, @1];
            sCompactSubredditListEnabled = YES;
            CGFloat height = [(RedditListViewController *)table.dataSource tableView:table heightForHeaderInSection:1];
            Check(height < 0.01, @"Negative control reproduces the inner-hook FOLLOWING-height regression");
            printf("Compact List negative control: incorrect inner hook detected.\n");
            return 0;
        }
        InstallFollowingHooks();
        ApolloSubredditIndexInstallCompactHeaderHooks();
        InstallEditingHooks();
        ExerciseLayout(@[@"A", @"B", @"#"], nil, NO);
        ExerciseLayout(@[@"A", @"B", @"#"], @[@3, @1, @2], NO);
        ExerciseLayout(@[@"A", @"B", @"#"], @[@(-2), @3, @1, @2], YES);
        ExerciseLayout(@[@"A", @"B", @"#"], @[@2, @1, @3, @(-2)], YES);
        ExerciseLayout(@[@"あ", @"か", @"さ", @"た", @"な", @"は", @"ま", @"や", @"ら", @"わ", @"#"], @[@2, @(-2), @3, @1], YES);
        ExerciseLayout(@[@"ㄱ", @"ㄴ", @"ㄷ", @"#"], @[@3, @2, @(-2), @1], YES);
        ExerciseCompactHeaderBoundary();

        UITableView *table = Fixture(@[@"A", @"B", @"#"], nil, NO);
        UIView *reused = [UIView new];
        objc_setAssociatedObject(reused, &kApolloSubredditHeaderSectionKey, @5, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        sCompactSubredditListEnabled = YES;
        Check(ApolloSubredditIndexApplyCompactHeaderVisibility(reused, table) && reused.hidden, @"Surviving alphabetical header becomes hidden");
        objc_setAssociatedObject(reused, &kApolloSubredditHeaderSectionKey, @1, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        Check(!ApolloSubredditIndexApplyCompactHeaderVisibility(reused, table) && !reused.hidden, @"Reusing a hidden header for Favorites restores visibility");
        objc_setAssociatedObject(reused, &kApolloSubredditHeaderSectionKey, @5, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloSubredditIndexApplyCompactHeaderVisibility(reused, table);
        sCompactSubredditListEnabled = NO;
        Check(!ApolloSubredditIndexApplyCompactHeaderVisibility(reused, table) && !reused.hidden, @"Toggle-off restores surviving header visibility");
        sCompactSubredditListEnabled = YES;
        table.dataSource = [NSObject new];
        Check(!ApolloSubredditIndexUsesCompactRows(table), @"Unrelated tables are unaffected");
        table.dataSource = [RedditListViewController new];
        table.numberOfSections = 2;
        Check(!ApolloSubredditIndexHidesCompactHeader(table, 1), @"Incomplete initial section geometry stays native");
        ExerciseCompactStars();
        ExerciseFavoritesSectionIdentity();
        ExerciseWrappedShortcuts();
        ExerciseCompactDensity();
        ExerciseCompactDescriptions();
        ExerciseRestoredPreferenceOnIPad();
        ExerciseEditingNavigationOwnership();
        printf("Compact List: %lu checks passed.\n", (unsigned long)checks);
    }
    return 0;
}
