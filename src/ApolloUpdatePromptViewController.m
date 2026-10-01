#import "ApolloUpdatePromptViewController.h"
#import "ApolloAppIcon.h"
#import "ApolloCommon.h"
#import "ApolloThemeRuntime.h"
#import <QuartzCore/QuartzCore.h>

// Page transition: the prompt fades out while moving left, the chooser fades in
// while sliding in from the right. Deliberately slow.
static const NSTimeInterval kPageSlideDuration = 0.6;
static const NSTimeInterval kPageFadeInDelay = 0.12;
static const CGFloat kPageSlideFraction = 0.28;   // of the sheet width

// Apollo's bundleIdentifier in every apps*.json source, which is what FlareStore's viewApp matches.
static NSString *const kApolloUpdateAppBundleID = @"com.christianselig.Apollo";

// SF Symbols are OS-versioned and the device floor is iOS 14, so each row lists
// fallbacks; the last entry is always available.
static UIImage *ApolloUpdateSymbol(NSArray<NSString *> *names) {
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:26
                                                                                         weight:UIImageSymbolWeightRegular];
    for (NSString *name in names) {
        UIImage *image = [UIImage systemImageNamed:name withConfiguration:config];
        if (image) return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    return nil;
}

// The four sideloader icons ship in the resource bundle (Resources/update-icon-*.png,
// 150px for a 50pt tile), so the chooser needs no network. nil falls back to a tile.
static UIImage *ApolloUpdateSourceIcon(NSString *name) {
    NSString *path = ApolloBundledResourcePath(name, @"png");
    UIImage *raw = path ? [UIImage imageWithContentsOfFile:path] : nil;
    return raw.CGImage ? [UIImage imageWithCGImage:raw.CGImage scale:3 orientation:UIImageOrientationUp] : nil;
}

#pragma mark - Chooser row

// A tappable filled card: colored icon tile, title, subtitle, chevron.
@interface ApolloUpdateChoiceRow : UIControl
- (instancetype)initWithIcon:(nullable UIImage *)icon
                     symbols:(NSArray<NSString *> *)symbols
                   tileColor:(UIColor *)tileColor
                       title:(NSString *)title
                    subtitle:(NSString *)subtitle;
@end

@implementation ApolloUpdateChoiceRow

- (instancetype)initWithIcon:(UIImage *)icon
                     symbols:(NSArray<NSString *> *)symbols
                   tileColor:(UIColor *)tileColor
                       title:(NSString *)title
                    subtitle:(NSString *)subtitle {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    self.backgroundColor = [UIColor secondarySystemFillColor];
    self.layer.cornerRadius = 18;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.isAccessibilityElement = YES;
    self.accessibilityTraits = UIAccessibilityTraitButton;
    self.accessibilityLabel = [NSString stringWithFormat:@"%@, %@", title, subtitle];

    // The real app icon when we have it, otherwise a colored tile with a glyph.
    UIView *badge;
    if (icon) {
        UIImageView *imageView = [[UIImageView alloc] initWithImage:icon];
        imageView.contentMode = UIViewContentModeScaleAspectFill;
        badge = imageView;
    } else {
        badge = [[UIView alloc] init];
        badge.backgroundColor = tileColor;
        UIImageView *glyph = [[UIImageView alloc] initWithImage:ApolloUpdateSymbol(symbols)];
        glyph.tintColor = [UIColor whiteColor];
        glyph.contentMode = UIViewContentModeCenter;
        glyph.translatesAutoresizingMaskIntoConstraints = NO;
        [badge addSubview:glyph];
        [NSLayoutConstraint activateConstraints:@[
            [glyph.centerXAnchor constraintEqualToAnchor:badge.centerXAnchor],
            [glyph.centerYAnchor constraintEqualToAnchor:badge.centerYAnchor],
        ]];
    }
    badge.layer.cornerRadius = 50 * 0.2237;   // app-icon corner radius
    badge.layer.cornerCurve = kCACornerCurveContinuous;
    badge.clipsToBounds = YES;
    badge.userInteractionEnabled = NO;
    [NSLayoutConstraint activateConstraints:@[
        [badge.widthAnchor constraintEqualToConstant:50],
        [badge.heightAnchor constraintEqualToConstant:50],
    ]];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = title;
    titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    titleLabel.numberOfLines = 0;

    UILabel *subtitleLabel = [[UILabel alloc] init];
    subtitleLabel.text = subtitle;
    subtitleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    subtitleLabel.textColor = [UIColor secondaryLabelColor];
    subtitleLabel.numberOfLines = 0;

    UIStackView *text = [[UIStackView alloc] initWithArrangedSubviews:@[titleLabel, subtitleLabel]];
    text.axis = UILayoutConstraintAxisVertical;
    text.spacing = 2;

    UIImageSymbolConfiguration *chevronConfig = [UIImageSymbolConfiguration configurationWithPointSize:14
                                                                                                 weight:UIImageSymbolWeightSemibold];
    UIImageView *chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right" withConfiguration:chevronConfig]];
    chevron.tintColor = [UIColor tertiaryLabelColor];
    [chevron setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[badge, text, chevron]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 14;
    row.userInteractionEnabled = NO;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:row];
    [NSLayoutConstraint activateConstraints:@[
        [row.topAnchor constraintEqualToAnchor:self.topAnchor constant:13],
        [row.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-13],
        [row.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:14],
        [row.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
    ]];
    return self;
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    [UIView animateWithDuration:0.15 animations:^{ self.alpha = highlighted ? 0.6 : 1.0; }];
}

@end

#pragma mark - Link

// "See what's new >" — body-sized so it reads as part of the copy, with a chevron
// so it reads as tappable.
@interface ApolloUpdateLinkControl : UIControl
- (instancetype)initWithTitle:(NSString *)title;
@end

@implementation ApolloUpdateLinkControl

- (instancetype)initWithTitle:(NSString *)title {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    self.isAccessibilityElement = YES;
    self.accessibilityTraits = UIAccessibilityTraitLink;
    self.accessibilityLabel = title;

    UILabel *label = [[UILabel alloc] init];
    label.text = title;
    label.font = [UIFont systemFontOfSize:[UIFont preferredFontForTextStyle:UIFontTextStyleBody].pointSize
                                   weight:UIFontWeightMedium];
    label.textColor = [UIColor labelColor];

    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:13
                                                                                         weight:UIImageSymbolWeightSemibold];
    UIImageView *chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right" withConfiguration:config]];
    chevron.tintColor = [UIColor labelColor];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[label, chevron]];
    stack.spacing = 5;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.userInteractionEnabled = NO;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:self.topAnchor constant:6],
        [stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-6],
        [stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
    ]];
    return self;
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.alpha = highlighted ? 0.5 : 1.0;
}

@end

#pragma mark - Sheet

@implementation ApolloUpdatePromptViewController {
    ApolloUpdateInfo *_info;
    NSString *_installedVersion;
    BOOL _offerSkip;
    UIColor *_accent;

    UIView *_promptPage;
    UIView *_chooserPage;
    UIStackView *_promptHeader;
    UIStackView *_promptActions;
    UIStackView *_chooserHeader;
    UIStackView *_chooserRows;
    UIStackView *_chooserActions;
    UIButton *_updateButton;

    BOOL _hasAnimatedIn;
    BOOL _showingChooser;
    BOOL _transitioning;
}

- (instancetype)initWithInfo:(ApolloUpdateInfo *)info
            installedVersion:(NSString *)installedVersion
                   offerSkip:(BOOL)offerSkip {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _info = info;
        _installedVersion = [installedVersion copy];
        _offerSkip = offerSkip;
    }
    return self;
}

- (void)presentOverViewController:(UIViewController *)presenter {
    self.modalPresentationStyle = UIModalPresentationPageSheet;
    if (@available(iOS 15.0, *)) {
        UISheetPresentationController *sheet = self.sheetPresentationController;
        sheet.detents = @[UISheetPresentationControllerDetent.largeDetent];
        sheet.prefersGrabberVisible = YES;
    }
    [presenter presentViewController:self animated:YES completion:nil];
}

#pragma mark Building

- (UILabel *)apollo_labelWithText:(NSString *)text font:(UIFont *)font color:(UIColor *)color {
    UILabel *label = [[UILabel alloc] init];
    label.text = text;
    label.font = font;
    label.textColor = color;
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    return label;
}

- (UIFont *)apollo_largeTitleFont {
    return [UIFont boldSystemFontOfSize:[UIFont preferredFontForTextStyle:UIFontTextStyleLargeTitle].pointSize];
}

// Full-width accent-filled button, identical to What's New's Continue button.
- (UIButton *)apollo_primaryButtonWithTitle:(NSString *)title action:(SEL)action identifier:(NSString *)identifier {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.backgroundColor = _accent;
    button.layer.cornerRadius = 14;
    button.layer.cornerCurve = kCACornerCurveContinuous;
    button.clipsToBounds = YES;
    button.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    [button setTitle:title forState:UIControlStateNormal];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    button.accessibilityIdentifier = identifier;
    [button.heightAnchor constraintEqualToConstant:50].active = YES;
    return button;
}

// Quiet text button (Later / Skip / Cancel / Release notes): label-colored, not
// accent, so it stays legible on every theme (stock accents can be near-white).
- (UIButton *)apollo_textButtonWithTitle:(NSString *)title
                                    font:(UIFont *)font
                                   color:(UIColor *)color
                                  height:(CGFloat)height
                                  action:(SEL)action
                              identifier:(NSString *)identifier {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.titleLabel.font = font;
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:color forState:UIControlStateNormal];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    button.accessibilityIdentifier = identifier;
    [button.heightAnchor constraintEqualToConstant:height].active = YES;
    return button;
}

- (UIScrollView *)apollo_scrollViewInPage:(UIView *)page bottomAnchor:(NSLayoutYAxisAnchor *)bottomAnchor constant:(CGFloat)bottomConstant content:(UIView *__autoreleasing *)outContent {
    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [page addSubview:scroll];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:page.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:page.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:page.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:bottomAnchor constant:bottomConstant],
    ]];
    UIView *content = [[UIView alloc] init];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [content.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
        [content.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
        [content.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor],
        // Short content fills the frame so it can be centered.
        [content.heightAnchor constraintGreaterThanOrEqualToAnchor:scroll.frameLayoutGuide.heightAnchor],
    ]];
    *outContent = content;
    return scroll;
}

- (UIView *)apollo_pagePinnedToSheet {
    UIView *page = [[UIView alloc] init];
    page.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:page];
    [NSLayoutConstraint activateConstraints:@[
        [page.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [page.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [page.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [page.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
    return page;
}

- (UIStackView *)apollo_actionsStackWithButtons:(NSArray<UIView *> *)buttons {
    UIStackView *actions = [[UIStackView alloc] initWithArrangedSubviews:buttons];
    actions.axis = UILayoutConstraintAxisVertical;
    actions.spacing = 4;
    return actions;
}

// Pinned to the bottom of the sheet (the chooser page).
- (UIStackView *)apollo_actionsStackInPage:(UIView *)page buttons:(NSArray<UIView *> *)buttons {
    UIStackView *actions = [self apollo_actionsStackWithButtons:buttons];
    actions.translatesAutoresizingMaskIntoConstraints = NO;
    [page addSubview:actions];
    [NSLayoutConstraint activateConstraints:@[
        [actions.leadingAnchor constraintEqualToAnchor:page.leadingAnchor constant:20],
        [actions.trailingAnchor constraintEqualToAnchor:page.trailingAnchor constant:-20],
        [actions.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-12],
    ]];
    return actions;
}

- (void)apollo_buildPromptPage {
    BOOL canUpdate = (_info.sourceURL != nil || _info.downloadURL != nil);

    _promptPage = [self apollo_pagePinnedToSheet];

    // With no sideloader to hand off to (a dev build), the primary action just
    // opens the release page.
    _updateButton = [self apollo_primaryButtonWithTitle:canUpdate ? @"Update" : @"Release notes"
                                                 action:canUpdate ? @selector(apollo_updateTapped) : @selector(apollo_notesTapped)
                                             identifier:@"update.primary"];
    NSMutableArray<UIView *> *buttons = [NSMutableArray arrayWithObject:_updateButton];
    [buttons addObject:[self apollo_textButtonWithTitle:@"Later"
                                                   font:[UIFont systemFontOfSize:17]
                                                  color:[UIColor secondaryLabelColor]
                                                 height:44
                                                 action:@selector(apollo_dismissTapped)
                                             identifier:@"update.later"]];
    if (_offerSkip) {
        [buttons addObject:[self apollo_textButtonWithTitle:@"Skip this version"
                                                       font:[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote]
                                                      color:[UIColor tertiaryLabelColor]
                                                     height:30
                                                     action:@selector(apollo_skipTapped)
                                                 identifier:@"update.skip"]];
    }
    _promptActions = [self apollo_actionsStackInPage:_promptPage buttons:buttons];

    UIView *content = nil;
    [self apollo_scrollViewInPage:_promptPage bottomAnchor:_promptActions.topAnchor constant:-12 content:&content];

    // Same icon size and corner radius as the What's New sheet.
    const CGFloat iconSize = 64;
    UIImageView *iconView = [[UIImageView alloc] initWithImage:ApolloCurrentAppIcon()];
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    iconView.layer.cornerRadius = 16;
    iconView.layer.cornerCurve = kCACornerCurveContinuous;
    iconView.clipsToBounds = YES;
    iconView.hidden = (iconView.image == nil);
    iconView.accessibilityIdentifier = @"update.icon";
    [NSLayoutConstraint activateConstraints:@[
        [iconView.widthAnchor constraintEqualToConstant:iconSize],
        [iconView.heightAnchor constraintEqualToConstant:iconSize],
    ]];

    UILabel *pillLabel = [[UILabel alloc] init];
    pillLabel.attributedText = [[NSAttributedString alloc] initWithString:@"NEW RELEASE" attributes:@{
        NSKernAttributeName: @0.8,
        NSFontAttributeName: [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold],
        NSForegroundColorAttributeName: [UIColor labelColor],
    }];
    UIView *pill = [[UIView alloc] init];
    pill.backgroundColor = [_accent colorWithAlphaComponent:0.18];
    pill.layer.cornerRadius = 11;
    pill.layer.cornerCurve = kCACornerCurveContinuous;
    pillLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [pill addSubview:pillLabel];
    [NSLayoutConstraint activateConstraints:@[
        [pillLabel.topAnchor constraintEqualToAnchor:pill.topAnchor constant:4],
        [pillLabel.bottomAnchor constraintEqualToAnchor:pill.bottomAnchor constant:-4],
        [pillLabel.leadingAnchor constraintEqualToAnchor:pill.leadingAnchor constant:10],
        [pillLabel.trailingAnchor constraintEqualToAnchor:pill.trailingAnchor constant:-10],
    ]];

    UILabel *title = [self apollo_labelWithText:@"Update available" font:[self apollo_largeTitleFont] color:[UIColor labelColor]];
    UILabel *subtitle = [self apollo_labelWithText:@"See what's new and get the latest version of Apollo Reborn."
                                              font:[UIFont preferredFontForTextStyle:UIFontTextStyleBody]
                                             color:[UIColor secondaryLabelColor]];
    UILabel *versions = [self apollo_labelWithText:[NSString stringWithFormat:@"%@ \u2192 %@", _installedVersion, _info.version]
                                              font:[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote]
                                             color:[UIColor tertiaryLabelColor]];

    NSMutableArray<UIView *> *header = [NSMutableArray arrayWithObjects:iconView, pill, title, subtitle, versions, nil];
    if (canUpdate && _info.releaseURL) {
        ApolloUpdateLinkControl *notes = [[ApolloUpdateLinkControl alloc] initWithTitle:@"Release Notes"];
        notes.accessibilityIdentifier = @"update.notes";
        [notes addTarget:self action:@selector(apollo_notesTapped) forControlEvents:UIControlEventTouchUpInside];
        [header addObject:notes];
    }
    _promptHeader = [[UIStackView alloc] initWithArrangedSubviews:header];
    _promptHeader.axis = UILayoutConstraintAxisVertical;
    _promptHeader.alignment = UIStackViewAlignmentCenter;
    _promptHeader.spacing = 12;
    [_promptHeader setCustomSpacing:22 afterView:iconView];
    [_promptHeader setCustomSpacing:12 afterView:pill];
    [_promptHeader setCustomSpacing:8 afterView:title];
    [_promptHeader setCustomSpacing:10 afterView:subtitle];
    _promptHeader.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:_promptHeader];
    NSLayoutConstraint *centerY = [_promptHeader.centerYAnchor constraintEqualToAnchor:content.centerYAnchor constant:-16];
    centerY.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        centerY,
        [_promptHeader.topAnchor constraintGreaterThanOrEqualToAnchor:content.topAnchor constant:36],
        [_promptHeader.bottomAnchor constraintLessThanOrEqualToAnchor:content.bottomAnchor constant:-24],
        [_promptHeader.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:28],
        [_promptHeader.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-28],
    ]];
}

- (void)apollo_buildChooserPage {
    _chooserPage = [self apollo_pagePinnedToSheet];

    _chooserActions = [self apollo_actionsStackInPage:_chooserPage buttons:@[
        [self apollo_textButtonWithTitle:@"Cancel"
                                    font:[UIFont systemFontOfSize:17]
                                   color:[UIColor secondaryLabelColor]
                                  height:44
                                  action:@selector(apollo_dismissTapped)
                              identifier:@"update.cancel"],
    ]];

    UIView *content = nil;
    [self apollo_scrollViewInPage:_chooserPage bottomAnchor:_chooserActions.topAnchor constant:-12 content:&content];

    UILabel *title = [self apollo_labelWithText:@"Update Apollo" font:[self apollo_largeTitleFont] color:[UIColor labelColor]];
    UILabel *subtitle = [self apollo_labelWithText:@"Choose how you'd like to update."
                                              font:[UIFont preferredFontForTextStyle:UIFontTextStyleBody]
                                             color:[UIColor secondaryLabelColor]];
    _chooserHeader = [[UIStackView alloc] initWithArrangedSubviews:@[title, subtitle]];
    _chooserHeader.axis = UILayoutConstraintAxisVertical;
    _chooserHeader.alignment = UIStackViewAlignmentCenter;
    _chooserHeader.spacing = 8;
    _chooserHeader.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:_chooserHeader];

    _chooserRows = [[UIStackView alloc] init];
    _chooserRows.axis = UILayoutConstraintAxisVertical;
    _chooserRows.spacing = 10;
    _chooserRows.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:_chooserRows];

    if (_info.sourceURL) {
        [self apollo_addRowWithIcon:@"update-icon-altstore" symbols:@[@"diamond.fill", @"square.stack.3d.up.fill"] tile:[UIColor colorWithRed:0.13 green:0.65 blue:0.60 alpha:1]
                                 title:@"AltStore" subtitle:@"Continue in AltStore"
                            identifier:@"update.altstore" action:@selector(apollo_altStoreTapped)];
        [self apollo_addRowWithIcon:@"update-icon-sidestore" symbols:@[@"diamond.fill", @"square.stack.3d.up.fill"] tile:[UIColor colorWithRed:0.55 green:0.36 blue:0.96 alpha:1]
                                 title:@"SideStore" subtitle:@"Continue in SideStore"
                            identifier:@"update.sidestore" action:@selector(apollo_sideStoreTapped)];
        [self apollo_addRowWithIcon:@"update-icon-feather" symbols:@[@"bird.fill", @"leaf.fill"] tile:[UIColor colorWithRed:0.30 green:0.55 blue:0.98 alpha:1]
                                 title:@"Feather" subtitle:(_info.downloadURL ? @"Download to Feather's Library" : @"Continue in Feather")
                            identifier:@"update.feather" action:@selector(apollo_featherTapped)];
        [self apollo_addRowWithIcon:@"update-icon-flarestore" symbols:@[@"flame.fill"] tile:[UIColor colorWithRed:0.98 green:0.45 blue:0.20 alpha:1]
                                 title:@"FlareStore" subtitle:@"Open Apollo's page in FlareStore"
                            identifier:@"update.flarestore" action:@selector(apollo_flareStoreTapped)];
    }
    if (_info.downloadURL) {
        if (_info.sourceURL) {
            // Hairline between "open in an app" and "do it yourself".
            UIView *rule = [[UIView alloc] init];
            rule.backgroundColor = [UIColor separatorColor];
            [rule.heightAnchor constraintEqualToConstant:1.0 / UIScreen.mainScreen.scale].active = YES;
            [_chooserRows setCustomSpacing:16 afterView:_chooserRows.arrangedSubviews.lastObject];
            [_chooserRows addArrangedSubview:rule];
            [_chooserRows setCustomSpacing:16 afterView:rule];
        }
        [self apollo_addRowWithIcon:nil symbols:@[@"arrow.down.to.line", @"arrow.down.circle"] tile:[UIColor systemGrayColor]
                                 title:@"Download IPA" subtitle:@"Save for manual installation"
                            identifier:@"update.download" action:@selector(apollo_downloadTapped)];
    }

    [NSLayoutConstraint activateConstraints:@[
        [_chooserHeader.topAnchor constraintEqualToAnchor:content.topAnchor constant:36],
        [_chooserHeader.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:28],
        [_chooserHeader.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-28],
        [_chooserRows.topAnchor constraintEqualToAnchor:_chooserHeader.bottomAnchor constant:32],
        [_chooserRows.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16],
        [_chooserRows.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16],
        // <=, not ==: an equal pin would stretch the rows to fill a tall sheet.
        [_chooserRows.bottomAnchor constraintLessThanOrEqualToAnchor:content.bottomAnchor constant:-24],
    ]];
}

- (void)apollo_addRowWithIcon:(NSString *)iconName
                      symbols:(NSArray<NSString *> *)symbols
                         tile:(UIColor *)tile
                        title:(NSString *)title
                     subtitle:(NSString *)subtitle
                   identifier:(NSString *)identifier
                       action:(SEL)action {
    ApolloUpdateChoiceRow *row = [[ApolloUpdateChoiceRow alloc] initWithIcon:iconName ? ApolloUpdateSourceIcon(iconName) : nil
                                                                     symbols:symbols
                                                                   tileColor:tile
                                                                       title:title
                                                                    subtitle:subtitle];
    row.accessibilityIdentifier = identifier;
    [row addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [_chooserRows addArrangedSubview:row];
}

#pragma mark Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    _accent = ApolloThemeAccentColor() ?: self.view.tintColor ?: [UIColor systemBlueColor];

    [self apollo_buildPromptPage];
    [self apollo_buildChooserPage];
    _chooserPage.alpha = 0.0;
    _chooserPage.hidden = YES;

    // Entrance states (see -apollo_animateEntrance).
    _promptHeader.alpha = 0.0;
    _promptHeader.transform = CGAffineTransformMakeScale(0.82, 0.82);
    _promptActions.alpha = 0.0;
    _promptActions.transform = CGAffineTransformMakeTranslation(0, 10);
    [self apollo_updateButtonTitleColor];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self apollo_updateButtonTitleColor];   // in the hierarchy now, so real traits
    if (_hasAnimatedIn) return;
    _hasAnimatedIn = YES;
    [self apollo_animateEntrance];
}

// Same beat as What's New: the header pops in scaled and faded, then the actions
// fade in beneath it.
- (void)apollo_animateEntrance {
    if (UIAccessibilityIsReduceMotionEnabled()) {
        _promptHeader.alpha = 1.0;
        _promptHeader.transform = CGAffineTransformIdentity;
        _promptActions.alpha = 1.0;
        _promptActions.transform = CGAffineTransformIdentity;
        return;
    }
    [UIView animateWithDuration:0.5 delay:0.05 usingSpringWithDamping:0.78 initialSpringVelocity:0.4
                        options:UIViewAnimationOptionCurveEaseOut animations:^{
        self->_promptHeader.alpha = 1.0;
        self->_promptHeader.transform = CGAffineTransformIdentity;
    } completion:nil];
    [UIView animateWithDuration:0.4 delay:0.3 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self->_promptActions.alpha = 1.0;
        self->_promptActions.transform = CGAffineTransformIdentity;
    } completion:nil];
}

// Black-vs-white title on the accent fill; static, so re-run on appearance changes
// (stock monochromatic/chumbus accents are near-white).
- (void)apollo_updateButtonTitleColor {
    UIColor *accent = _accent ?: [UIColor systemBlueColor];
    BOOL lightAccent = ApolloColorIsLight([accent resolvedColorWithTraitCollection:self.traitCollection]);
    [_updateButton setTitleColor:lightAccent ? [UIColor blackColor] : [UIColor whiteColor] forState:UIControlStateNormal];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previous]) {
        [self apollo_updateButtonTitleColor];
    }
}

#pragma mark Page transition

- (void)apollo_showChooser {
    if (_showingChooser || _transitioning) return;
    _showingChooser = YES;
    _transitioning = YES;
    _promptPage.userInteractionEnabled = NO;

    BOOL reduceMotion = UIAccessibilityIsReduceMotionEnabled();
    CGFloat shift = reduceMotion ? 0.0 : CGRectGetWidth(self.view.bounds) * kPageSlideFraction;

    _chooserPage.hidden = NO;
    _chooserPage.alpha = 0.0;
    _chooserPage.transform = CGAffineTransformMakeTranslation(shift, 0);

    // The prompt fades out drifting left...
    [UIView animateWithDuration:kPageSlideDuration delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        self->_promptPage.alpha = 0.0;
        self->_promptPage.transform = CGAffineTransformMakeTranslation(-shift, 0);
    } completion:nil];

    // ...while the chooser fades in sliding from the right.
    [UIView animateWithDuration:kPageSlideDuration delay:kPageFadeInDelay options:UIViewAnimationOptionCurveEaseInOut animations:^{
        self->_chooserPage.alpha = 1.0;
        self->_chooserPage.transform = CGAffineTransformIdentity;
    } completion:^(BOOL finished) {
        self->_promptPage.hidden = YES;
        self->_transitioning = NO;
        UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, self->_chooserHeader);
    }];
}

#pragma mark Actions

- (void)apollo_updateTapped {
    ApolloLog(@"[update] sheet: update tapped");
    [self apollo_showChooser];
}

- (void)apollo_dismissTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)apollo_skipTapped {
    if (self.onSkip) self.onSkip();
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)apollo_notesTapped {
    if (_info.releaseURL) ApolloPresentWebURLFromViewController(self, _info.releaseURL);
}

- (void)apollo_altStoreTapped {
    [self apollo_openURL:ApolloUpdateSideloaderSourceURL(ApolloUpdateSideloaderAltStore, _info.sourceURL) appName:@"AltStore" dismissOnSuccess:YES];
}

- (void)apollo_sideStoreTapped {
    [self apollo_openURL:ApolloUpdateSideloaderSourceURL(ApolloUpdateSideloaderSideStore, _info.sourceURL) appName:@"SideStore" dismissOnSuccess:YES];
}

// Feather takes the IPA directly, which works whether or not the repo is already added (its
// source link only adds the repo and stays put). It has no deep link to a source or app page,
// and no progress UI for URL downloads: the app just shows up in its Library when done.
- (void)apollo_featherTapped {
    NSURL *url = _info.downloadURL ? ApolloUpdateSideloaderInstallURL(ApolloUpdateSideloaderFeather, _info.downloadURL) : nil;
    [self apollo_openURL:url ?: ApolloUpdateSideloaderSourceURL(ApolloUpdateSideloaderFeather, _info.sourceURL)
                 appName:@"Feather" dismissOnSuccess:YES];
}

// FlareStore's viewApp lands on Apollo's page (GET button) when a repo listing it is added.
// It only acts while FlareStore is already running: a cold launch drops the link, so the
// sheet stays up and a second tap works once FlareStore is open.
- (void)apollo_flareStoreTapped {
    [self apollo_openURL:ApolloUpdateSideloaderAppPageURL(ApolloUpdateSideloaderFlareStore, kApolloUpdateAppBundleID)
                 appName:@"FlareStore" dismissOnSuccess:NO];
}

- (void)apollo_downloadTapped {
    [self apollo_openURL:_info.downloadURL appName:nil dismissOnSuccess:YES];
}

// `appName` non-nil => a sideloader hand-off, so a failed open means it isn't installed.
// `dismissOnSuccess` NO leaves the sheet up for a second try (see apollo_flareStoreTapped).
- (void)apollo_openURL:(NSURL *)url appName:(NSString *)appName dismissOnSuccess:(BOOL)dismissOnSuccess {
    if (!url) return;
    __weak typeof(self) weakSelf = self;
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:^(BOOL success) {
        ApolloLog(@"[update] open %@ -> %@", url.scheme, success ? @"ok" : @"failed");
        UIViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (success) {
            // Handed off; the user finishes the update in the other app.
            if (dismissOnSuccess) [strongSelf dismissViewControllerAnimated:YES completion:nil];
            return;
        }
        if (!appName) return;
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:[NSString stringWithFormat:@"Couldn't Open %@", appName]
                             message:@"Make sure it's installed, or choose Download IPA instead."
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [strongSelf presentViewController:alert animated:YES completion:nil];
    }];
}

@end
