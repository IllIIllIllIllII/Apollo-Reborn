#import "ApolloAwardsSheet.h"
#import "ApolloAwards.h"
#import "ApolloAwardsGiving.h"
#import "ApolloAwardsParsing.h"
#import "ApolloAwardAnimation.h"
#import "ApolloThemeRuntime.h"
#import <objc/message.h>

@interface UIImageView (ApolloAwardsSheetRemoteImage)
- (void)pin_setImageFromURL:(NSURL *)URL;
- (void)pin_cancelImageDownload;
@end

static id ApolloAwardsSheetValue(id owner, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return [owner respondsToSelector:selector] ? ((id (*)(id, SEL))objc_msgSend)(owner, selector) : nil;
}

static NSString *ApolloAwardsSheetNumber(NSInteger count) {
    return [NSNumberFormatter localizedStringFromNumber:@(count) numberStyle:NSNumberFormatterDecimalStyle];
}

// Preserve the native snapshot even if its metadata entry was evicted while
// the post stayed open. Revalidation can add animation metadata again later.
static NSArray<NSDictionary *> *ApolloAwardsSheetSnapshot(id thing, NSString *fullName) {
    NSArray *cached = ApolloAwardsCached(fullName);
    if (cached) return cached;
    id native = ApolloAwardsSheetValue(thing, @"awards");
    if (![native isKindOfClass:NSArray.class] || [native count] == 0 || [native count] > 128) return nil;
    NSMutableArray *entries = [NSMutableArray new];
    for (id award in native) {
        NSString *name = ApolloAwardsSheetValue(award, @"name");
        NSString *identifier = ApolloAwardsSheetValue(award, @"identifier");
        SEL countSelector = NSSelectorFromString(@"count");
        long long count = [award respondsToSelector:countSelector] ? ((long long (*)(id, SEL))objc_msgSend)(award, countSelector) : 0;
        if (![name isKindOfClass:NSString.class] || !name.length || count <= 0 || count > 999999999) continue;
        NSMutableDictionary *entry = [@{@"name": name, @"count": @(count)} mutableCopy];
        if ([identifier isKindOfClass:NSString.class]) entry[@"id"] = identifier;
        NSURL *URL = ApolloAwardsSheetValue(award, @"largeIconURL");
        if ([URL isKindOfClass:NSURL.class] && [URL.scheme.lowercaseString isEqual:@"https"] &&
            !URL.user && !URL.password && !URL.port &&
            [@[@"i.redd.it", @"www.redditstatic.com", @"redditstatic.com"] containsObject:URL.host.lowercaseString]) {
            entry[@"icon_url"] = URL.absoluteString;
        }
        [entries addObject:entry];
    }
    return entries.count ? [entries copy] : nil;
}

@interface ApolloAwardsSheetCell : UITableViewCell
@property (nonatomic, strong) UIView *iconCanvas;
@property (nonatomic, strong) UIImageView *awardImage;
@property (nonatomic, strong) UILabel *awardName;
@property (nonatomic, strong) UILabel *awardCount;
@property (nonatomic, strong) ApolloAwardAnimationView *awardAnimation;
- (void)configureWithAward:(NSDictionary *)award;
@end

@implementation ApolloAwardsSheetCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    self.clipsToBounds = NO;
    self.contentView.clipsToBounds = NO;
    self.isAccessibilityElement = YES;
    self.iconCanvas = [UIView new];
    self.iconCanvas.clipsToBounds = NO;
    self.awardImage = [UIImageView new];
    self.awardImage.contentMode = UIViewContentModeScaleAspectFit;
    self.awardImage.isAccessibilityElement = NO;
    self.awardName = [UILabel new];
    self.awardName.numberOfLines = 0;
    self.awardName.adjustsFontForContentSizeCategory = YES;
    self.awardCount = [UILabel new];
    self.awardCount.adjustsFontForContentSizeCategory = YES;
    [self.awardCount setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [self.awardCount setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    for (UIView *view in @[self.iconCanvas, self.awardName, self.awardCount]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:view];
    }
    self.awardImage.translatesAutoresizingMaskIntoConstraints = NO;
    [self.iconCanvas addSubview:self.awardImage];
    UILayoutGuide *margins = self.contentView.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.iconCanvas.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [self.iconCanvas.topAnchor constraintGreaterThanOrEqualToAnchor:self.contentView.topAnchor constant:8],
        [self.iconCanvas.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentView.bottomAnchor constant:-8],
        [self.iconCanvas.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [self.iconCanvas.widthAnchor constraintEqualToConstant:80],
        [self.iconCanvas.heightAnchor constraintEqualToConstant:80],
        [self.awardImage.centerXAnchor constraintEqualToAnchor:self.iconCanvas.centerXAnchor],
        [self.awardImage.centerYAnchor constraintEqualToAnchor:self.iconCanvas.centerYAnchor],
        [self.awardImage.widthAnchor constraintEqualToConstant:48],
        [self.awardImage.heightAnchor constraintEqualToConstant:48],
        [self.awardName.leadingAnchor constraintEqualToAnchor:self.iconCanvas.trailingAnchor constant:12],
        [self.awardName.topAnchor constraintGreaterThanOrEqualToAnchor:margins.topAnchor],
        [self.awardName.bottomAnchor constraintLessThanOrEqualToAnchor:margins.bottomAnchor],
        [self.awardName.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [self.awardCount.leadingAnchor constraintEqualToAnchor:self.awardName.trailingAnchor constant:12],
        [self.awardCount.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
        [self.awardCount.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [self.awardCount.topAnchor constraintGreaterThanOrEqualToAnchor:margins.topAnchor],
        [self.awardCount.bottomAnchor constraintLessThanOrEqualToAnchor:margins.bottomAnchor]
    ]];
    return self;
}

- (void)clearMedia {
    [self.awardAnimation prepareForRemoval];
    [self.awardAnimation removeFromSuperview];
    self.awardAnimation = nil;
    if ([self.awardImage respondsToSelector:@selector(pin_cancelImageDownload)]) [self.awardImage pin_cancelImageDownload];
    self.awardImage.hidden = NO;
    self.awardImage.image = nil;
}

- (void)prepareForReuse {
    [self clearMedia];
    [super prepareForReuse];
}

- (void)configureWithAward:(NSDictionary *)award {
    [self clearMedia];
    self.backgroundColor = ApolloThemeCardBackgroundColor() ?: UIColor.secondarySystemGroupedBackgroundColor;
    self.awardName.textColor = ApolloThemeSettingsTextColor() ?: UIColor.labelColor;
    self.awardCount.textColor = ApolloThemeSettingsSecondaryTextColor() ?: UIColor.secondaryLabelColor;
    self.awardName.font = ApolloThemeRuntimeFont([UIFont preferredFontForTextStyle:UIFontTextStyleBody]);
    self.awardCount.font = ApolloThemeRuntimeFont([UIFont preferredFontForTextStyle:UIFontTextStyleBody]);
    self.awardName.text = award[@"name"];
    NSInteger count = [award[@"count"] integerValue];
    NSString *formatted = ApolloAwardsSheetNumber(count);
    self.awardCount.text = formatted;
    self.accessibilityLabel = [NSString stringWithFormat:@"%@, %@ %@", self.awardName.text, formatted, count == 1 ? @"award" : @"awards"];
    self.awardImage.tintColor = ApolloThemeSettingsSecondaryTextColor() ?: UIColor.secondaryLabelColor;
    self.awardImage.image = [UIImage systemImageNamed:@"gift"];
    NSString *icon = award[@"icon_url"];
    NSURL *iconURL = [icon isKindOfClass:NSString.class] ? [NSURL URLWithString:icon] : nil;
    if (iconURL && [self.awardImage respondsToSelector:@selector(pin_setImageFromURL:)]) [self.awardImage pin_setImageFromURL:iconURL];
    NSString *animation = award[@"animation_url"];
    NSURL *animationURL = [animation isKindOfClass:NSString.class] ? [NSURL URLWithString:animation] : nil;
    if (animationURL) {
        self.awardAnimation = [[ApolloAwardAnimationView alloc] initWithURL:animationURL stillImageView:self.awardImage];
        self.awardAnimation.translatesAutoresizingMaskIntoConstraints = NO;
        [self.iconCanvas addSubview:self.awardAnimation];
        // The renderer keeps its resting artwork at 48pt inside this 80pt
        // canvas. The extra margin accommodates motion instead of magnifying it.
        [NSLayoutConstraint activateConstraints:@[
            [self.awardAnimation.leadingAnchor constraintEqualToAnchor:self.iconCanvas.leadingAnchor],
            [self.awardAnimation.trailingAnchor constraintEqualToAnchor:self.iconCanvas.trailingAnchor],
            [self.awardAnimation.topAnchor constraintEqualToAnchor:self.iconCanvas.topAnchor],
            [self.awardAnimation.bottomAnchor constraintEqualToAnchor:self.iconCanvas.bottomAnchor]
        ]];
    }
}

@end

@interface ApolloAwardsSheetViewController : UITableViewController
@property (nonatomic, strong) id thing;
@property (nonatomic, copy) NSString *fullName;
@property (nonatomic, copy) NSArray<NSDictionary *> *entries;
@property (nonatomic) BOOL sheetActive;
@property (nonatomic) BOOL refreshingAwards;
@property (nonatomic) BOOL unavailable;
@end

@implementation ApolloAwardsSheetViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Awards";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(closeSheet)];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 96;
    [self.tableView registerClass:ApolloAwardsSheetCell.class forCellReuseIdentifier:@"award"];
    [self.tableView registerClass:UITableViewHeaderFooterView.class forHeaderFooterViewReuseIdentifier:@"award-count"];
    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(refreshAwards) forControlEvents:UIControlEventValueChanged];
    UIBarButtonItem *give = [[UIBarButtonItem alloc] initWithTitle:@"Give Award" style:UIBarButtonItemStyleDone target:self action:@selector(giveAward)];
    self.toolbarItems = @[[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil], give,
                         [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil]];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(cacheChanged:) name:ApolloAwardsCacheDidLoadNotification object:nil];
    [self applyTheme];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)applyTheme {
    UIColor *page = ApolloThemePageBackgroundColor() ?: UIColor.systemGroupedBackgroundColor;
    UIColor *bar = ApolloThemeRuntimeColor(ApolloThemeTokenBarBackground) ?: page;
    UIColor *primary = ApolloThemeSettingsTextColor() ?: UIColor.labelColor;
    self.tableView.backgroundColor = page;
    self.navigationController.view.backgroundColor = page;
    self.tableView.separatorColor = ApolloThemeSeparatorColor() ?: UIColor.separatorColor;
    UIColor *accent = ApolloThemeAccentColor() ?: self.view.tintColor;
    self.view.tintColor = accent;
    self.navigationController.view.tintColor = accent;
    self.navigationController.navigationBar.tintColor = accent;
    self.navigationController.toolbar.tintColor = accent;
    self.refreshControl.tintColor = accent;
    UINavigationBarAppearance *navigationAppearance = [UINavigationBarAppearance new];
    [navigationAppearance configureWithDefaultBackground];
    navigationAppearance.backgroundColor = bar;
    navigationAppearance.titleTextAttributes = @{NSForegroundColorAttributeName: primary};
    navigationAppearance.largeTitleTextAttributes = @{NSForegroundColorAttributeName: primary};
    self.navigationController.navigationBar.standardAppearance = navigationAppearance;
    self.navigationController.navigationBar.scrollEdgeAppearance = navigationAppearance;
    self.navigationController.navigationBar.compactAppearance = navigationAppearance;
    UIToolbarAppearance *toolbarAppearance = [UIToolbarAppearance new];
    [toolbarAppearance configureWithDefaultBackground];
    toolbarAppearance.backgroundColor = bar;
    self.navigationController.toolbar.standardAppearance = toolbarAppearance;
    self.navigationController.toolbar.compactAppearance = toolbarAppearance;
    if (@available(iOS 15.0, *)) self.navigationController.toolbar.scrollEdgeAppearance = toolbarAppearance;
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (self.isViewLoaded) [self applyTheme];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.navigationController setNavigationBarHidden:NO animated:animated];
    [self.navigationController setToolbarHidden:NO animated:animated];
    [self applyTheme];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    self.sheetActive = YES;
    for (ApolloAwardsSheetCell *cell in self.tableView.visibleCells) cell.awardAnimation.displayActive = YES;
    [self refreshAwards];
}

- (void)viewWillDisappear:(BOOL)animated {
    self.sheetActive = NO;
    for (ApolloAwardsSheetCell *cell in self.tableView.visibleCells) cell.awardAnimation.displayActive = NO;
    [super viewWillDisappear:animated];
}

- (void)closeSheet {
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

- (void)giveAward {
    // Replace the root of this same presented sheet. Closing Reddit's chooser
    // then returns directly to the underlying post/comment, never to a sheet
    // stacked above this awards list.
    UINavigationController *navigation = self.navigationController;
    if (ApolloAwardsReplaceSheetWithGiving(self.thing, navigation)) {
        [navigation setToolbarHidden:YES animated:YES];
    }
}

- (void)cacheChanged:(NSNotification *)notification {
    (void)notification;
    NSArray *cached = ApolloAwardsCached(self.fullName);
    if (cached && ![cached isEqual:self.entries]) {
        self.entries = cached;
        self.unavailable = NO;
        if (self.isViewLoaded) [self.tableView reloadData];
    }
}

- (void)refreshAwards {
    if (self.refreshingAwards) return;
    self.refreshingAwards = YES;
    __weak ApolloAwardsSheetViewController *weakSelf = self;
    ApolloAwardsFetch(self.fullName, ^(NSArray<NSDictionary *> *awards) {
        ApolloAwardsSheetViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.refreshingAwards = NO;
        [strongSelf.refreshControl endRefreshing];
        if (strongSelf.navigationController.viewControllers.firstObject != strongSelf) return;
        if (awards && [awards isEqual:strongSelf.entries]) return;
        strongSelf.unavailable = !awards && !strongSelf.entries;
        if (awards) strongSelf.entries = awards;
        [strongSelf.tableView reloadData];
    });
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return self.entries.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView; (void)section;
    if (!self.entries) return self.unavailable ? @"Couldn’t load awards" : @"Loading awards…";
    if (self.entries.count == 0) return @"No awards yet";
    NSInteger total = 0;
    for (NSDictionary *award in self.entries) total += [award[@"count"] integerValue];
    return [NSString stringWithFormat:@"%@ %@", ApolloAwardsSheetNumber(total), total == 1 ? @"award" : @"awards"];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    ApolloAwardsSheetCell *cell = [tableView dequeueReusableCellWithIdentifier:@"award" forIndexPath:indexPath];
    [cell configureWithAward:self.entries[indexPath.row]];
    return cell;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    UITableViewHeaderFooterView *header = [tableView dequeueReusableHeaderFooterViewWithIdentifier:@"award-count"];
    UIListContentConfiguration *content = [UIListContentConfiguration groupedHeaderConfiguration];
    content.text = [self tableView:tableView titleForHeaderInSection:section];
    content.textProperties.font = ApolloThemeRuntimeFont(content.textProperties.font);
    content.textProperties.color = ApolloThemeSettingsSecondaryTextColor() ?: UIColor.secondaryLabelColor;
    // Keep UIKit's self-sizing count header, but bring it closer to the title.
    NSDirectionalEdgeInsets margins = content.directionalLayoutMargins;
    margins.top = 8;
    content.directionalLayoutMargins = margins;
    header.contentConfiguration = content;
    return header;
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView; (void)indexPath;
    ((ApolloAwardsSheetCell *)cell).awardAnimation.displayActive = self.sheetActive;
}

- (void)tableView:(UITableView *)tableView didEndDisplayingCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView; (void)indexPath;
    ((ApolloAwardsSheetCell *)cell).awardAnimation.displayActive = NO;
}

@end

UIViewController *ApolloAwardsSheetControllerForThing(id thing) {
    NSString *fullName = ApolloAwardsNormalizeFullName(ApolloAwardsSheetValue(thing, @"fullName"));
    if (!fullName) return nil;
    ApolloAwardsSheetViewController *controller = [[ApolloAwardsSheetViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    controller.thing = thing;
    controller.fullName = fullName;
    controller.entries = ApolloAwardsSheetSnapshot(thing, fullName);
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:controller];
    navigation.modalPresentationStyle = UIModalPresentationFormSheet;
    if (@available(iOS 15.0, *)) {
        UISheetPresentationController *sheet = navigation.sheetPresentationController;
        sheet.detents = @[UISheetPresentationControllerDetent.mediumDetent, UISheetPresentationControllerDetent.largeDetent];
        sheet.selectedDetentIdentifier = UISheetPresentationControllerDetentIdentifierMedium;
        sheet.prefersGrabberVisible = YES;
        sheet.prefersScrollingExpandsWhenScrolledToEdge = YES;
        sheet.prefersEdgeAttachedInCompactHeight = YES;
    }
    return navigation;
}
