#import "ApolloHeaderPreview.h"
#import "ApolloState.h"
#import "ApolloNavigationActions.h"
#import "ApolloCommon.h"
#import "ApolloThemeRuntime.h"

@interface ApolloHeaderPreview () <UIScrollViewDelegate>
@property (nonatomic, strong) UIScrollView *feed;
@property (nonatomic, strong) UIImageView *backgroundImage;
@property (nonatomic) NSInteger renderedStyle;
@property (nonatomic, strong) UIView *header;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIVisualEffectView *titleGlass;
@property (nonatomic, strong) UIImageView *titleChevron;
@property (nonatomic, strong) UILabel *hint;
@property (nonatomic, strong) UIButton *back;
@property (nonatomic, strong) NSArray<UIButton *> *actions;
@property (nonatomic, strong) UIControl *strip;
@property (nonatomic, strong) UIView *progressiveBlur;
@property (nonatomic, strong) UIVisualEffectView *fullHeaderBlur;
@property (nonatomic, strong) UIScrollEdgeElementContainerInteraction *edgeInteraction API_AVAILABLE(ios(26.0));
@property (nonatomic) BOOL expanded;
@property (nonatomic) BOOL collapsePreference;
@end

@implementation ApolloHeaderPreview
- (UIButton *)button:(NSString *)symbol label:(NSString *)label {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setImage:[UIImage systemImageNamed:symbol withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightSemibold]] forState:UIControlStateNormal];
    button.accessibilityLabel = label;
    if (@available(iOS 26.0, *)) {
        button.configuration = [UIButtonConfiguration glassButtonConfiguration];
        [button setImage:[UIImage systemImageNamed:symbol withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightSemibold]] forState:UIControlStateNormal];
    }
    [self.header addSubview:button];
    return button;
}
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.clipsToBounds = YES;
    self.layer.cornerRadius = 16;
    self.backgroundColor = UIColor.secondarySystemBackgroundColor;
    _feed = [UIScrollView new];
    _feed.delegate = self;
    _feed.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    _feed.showsVerticalScrollIndicator = NO;
    _feed.contentSize = CGSizeMake(1, 300);
    _feed.contentOffset = CGPointMake(0, 24);
    [self addSubview:_feed];
    // Sample the supplied artwork through the actual header effects. Its fine
    // texture makes Hidden, Soft, and progressive Blur visibly distinguishable.
    NSString *imagePath = ApolloBundledResourcePath(@"HeaderStylePreview", @"jpg");
    _backgroundImage = [[UIImageView alloc] initWithImage:imagePath ? [UIImage imageWithContentsOfFile:imagePath] : nil];
    _backgroundImage.contentMode = UIViewContentModeScaleAspectFill;
    _backgroundImage.clipsToBounds = YES;
    [_feed addSubview:_backgroundImage];
    _renderedStyle = NSIntegerMin;
    // Reuse the progressive renderer for Soft and UIKit's native edge
    // interaction for Hard; Blur below covers the whole header uniformly.
    _progressiveBlur = [NSClassFromString(@"ApolloProgressiveBlurView") new];
    if (_progressiveBlur) [self addSubview:_progressiveBlur];
    _fullHeaderBlur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleRegular]];
    _fullHeaderBlur.userInteractionEnabled = NO;
    [self addSubview:_fullHeaderBlur];
    _header = [UIView new];
    [self addSubview:_header];
    _titleLabel = [UILabel new];
    _titleLabel.text = @"ApolloReborn";
    _titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    _titleLabel.textColor = UIColor.labelColor;
    _titleLabel.adjustsFontSizeToFitWidth = YES;
    _titleLabel.minimumScaleFactor = 0.75;
    if (@available(iOS 26.0, *)) {
        _titleGlass = [[UIVisualEffectView alloc] initWithEffect:[UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular]];
        _titleGlass.layer.cornerRadius = 19;
        _titleGlass.clipsToBounds = YES;
        [_header addSubview:_titleGlass];
        [_titleGlass.contentView addSubview:_titleLabel];
        UIImage *chevron = [UIImage imageNamed:@"disclosure-indicator-down" inBundle:NSBundle.mainBundle
            compatibleWithTraitCollection:self.traitCollection];
        _titleChevron = [[UIImageView alloc] initWithImage:[chevron imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
        _titleChevron.contentMode = UIViewContentModeScaleAspectFit;
        [_titleGlass.contentView addSubview:_titleChevron];
    }
    _back = [self button:@"chevron.left" label:@"Sample back button"];
    UIView *content = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 80, 44)];
    NSMutableArray *buttons = [NSMutableArray new];
    NSArray *assets = @[@"option-sort-hot", @"option-more"];
    NSArray *labels = @[@"Sort by Hot", @"Expand sample navigation actions"];
    for (NSUInteger i = 0; i < assets.count; i++) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        UIImage *image = [UIImage imageNamed:assets[i] inBundle:NSBundle.mainBundle compatibleWithTraitCollection:self.traitCollection];
        [button setImage:[image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] forState:UIControlStateNormal];
        button.accessibilityLabel = labels[i];
        button.frame = CGRectMake(i * 36, 0, 44, 44);
        [content addSubview:button];
        [buttons addObject:button];
    }
    _actions = buttons;
    _strip = ApolloNavigationActionsCreatePreview(content, _actions.lastObject);
    [_header addSubview:_strip];
    [_strip addTarget:self action:@selector(toggleActions) forControlEvents:UIControlEventTouchUpInside];
    [_actions.lastObject addTarget:self action:@selector(toggleActions) forControlEvents:UIControlEventTouchUpInside];
    if (@available(iOS 26.0, *)) {
        UIScrollEdgeElementContainerInteraction *interaction = [UIScrollEdgeElementContainerInteraction new];
        interaction.scrollView = _feed;
        interaction.edge = UIRectEdgeTop;
        [_header addInteraction:interaction];
        _edgeInteraction = interaction;
    }
    _hint = [UILabel new];
    _hint.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption2];
    _hint.textColor = UIColor.secondaryLabelColor;
    _hint.textAlignment = NSTextAlignmentCenter;
    _hint.numberOfLines = 0;
    _hint.adjustsFontForContentSizeCategory = YES;
    _hint.backgroundColor = self.backgroundColor;
    [self addSubview:_hint];
    UISwipeGestureRecognizer *swipe = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(collapseSample)];
    swipe.direction = UISwipeGestureRecognizerDirectionUp | UISwipeGestureRecognizerDirectionDown;
    [self addGestureRecognizer:swipe];
    self.isAccessibilityElement = YES;
    self.accessibilityLabel = @"ApolloReborn header preview";
    _collapsePreference = sCollapseNavigationActions;
    _expanded = !sCollapseNavigationActions;
    [self refresh];
    return self;
}
- (void)refresh {
    if (_collapsePreference != sCollapseNavigationActions) {
        _collapsePreference = sCollapseNavigationActions;
        _expanded = !sCollapseNavigationActions;
    }
    self.tintColor = ApolloNavigationChromeColor();
    NSInteger style = ApolloResolvedScrollEdgeEffectStyle();
    // Preview treatments requested for this comparison: Soft fades the blur
    // toward the content; Blur keeps the complete header uniformly blurred.
    _progressiveBlur.hidden = style != ApolloScrollEdgeEffectStyleSoft;
    _fullHeaderBlur.hidden = style != ApolloScrollEdgeEffectStyleBlur;
    if (@available(iOS 26.0, *)) {
        _edgeInteraction.scrollView = style == ApolloScrollEdgeEffectStyleHard ? _feed : nil;
    }
    // The real navigation title loses its capsule when Hard supplies a band.
    if (@available(iOS 26.0, *)) {
        if (_renderedStyle != style) {
            _titleGlass.effect = style == ApolloScrollEdgeEffectStyleHard ? nil
                : [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
            _renderedStyle = style;
        }
    }
    ApolloApplyScrollEdgeEffectStyle(_feed);
    [self updateHint];
    [self setNeedsLayout];
    ApolloNavigationActionsPreviewSetExpanded(_strip, _expanded, self.window != nil, ^{ [self layoutIfNeeded]; });
}
- (void)updateHint {
    NSString *style;
    NSString *detail;
    switch (ApolloResolvedScrollEdgeEffectStyle()) {
        case ApolloScrollEdgeEffectStyleHard: style = @"Hard"; detail = @"Solid header band"; break;
        case ApolloScrollEdgeEffectStyleBlur: style = @"Blur"; detail = @"Full header blur"; break;
        case ApolloScrollEdgeEffectStyleHidden: style = @"Hidden"; detail = @"Clear background"; break;
        default: style = @"Soft"; detail = @"Fades into the content"; break;
    }
    if (sCollapseNavigationActions) detail = _expanded ? @"Swipe to collapse" : @"Tap ••• to expand";
    _hint.text = [NSString stringWithFormat:@"%@ · %@", style, detail];
    self.accessibilityValue = [NSString stringWithFormat:@"%@ style. Navigation actions %@. %@", style,
        _expanded ? @"expanded" : @"collapsed",
        sCenterTitleBetweenButtons && !sCollapseNavigationActions ? @"Title centered between buttons." : @"Title centered on the header."];
    self.accessibilityTraits = sCollapseNavigationActions ? UIAccessibilityTraitButton : UIAccessibilityTraitImage;
    self.accessibilityHint = sCollapseNavigationActions ? @"Double-tap to expand or collapse the sample actions." : @"Use the style choices below to compare headers.";
    self.accessibilityCustomActions = sCollapseNavigationActions
        ? @[[[UIAccessibilityCustomAction alloc] initWithName:_expanded ? @"Collapse sample actions" : @"Expand sample actions" target:self selector:@selector(accessibilityToggleSample)]] : @[];
}
- (void)toggleActions {
    if (!sCollapseNavigationActions) return;
    _expanded = !_expanded;
    [self updateHint];
    [self setNeedsLayout];
    ApolloNavigationActionsPreviewSetExpanded(_strip, _expanded, YES, ^{ [self layoutIfNeeded]; });
}
- (BOOL)accessibilityActivate {
    if (!sCollapseNavigationActions) return NO;
    [self toggleActions];
    return YES;
}
- (BOOL)accessibilityToggleSample {
    return [self accessibilityActivate];
}
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    _hint.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption2 compatibleWithTraitCollection:self.traitCollection];
    [self setNeedsLayout];
}
- (void)collapseSample {
    if (sCollapseNavigationActions && _expanded) [self toggleActions];
}
- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    if (sCollapseNavigationActions && _expanded) [self toggleActions];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.bounds.size.width;
    CGFloat hintHeight = MAX(32, ceil(_hint.font.lineHeight) * (UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory) ? 3 : 2) + 12);
    _feed.frame = CGRectMake(0, 0, width, MAX(60, self.bounds.size.height - hintHeight));
    CGFloat contentHeight = _feed.bounds.size.height + 48;
    _feed.contentSize = CGSizeMake(width, contentHeight);
    _backgroundImage.frame = CGRectMake(0, 0, width, contentHeight);
    _header.frame = CGRectMake(0, 0, width, 60);
    _progressiveBlur.frame = CGRectMake(0, 0, width, 90);
    _fullHeaderBlur.frame = _feed.frame;
    _back.frame = CGRectMake(8, 8, 44, 44);
    _titleChevron.tintColor = ApolloNavigationChromeColor();
    BOOL expanded = !sCollapseNavigationActions || _expanded;
    CGFloat actionsWidth = expanded ? 80 : 44;
    CGFloat right = width - 8 - actionsWidth;
    // Keep the strip's outer frame stable while its production glass surface
    // expands toward the leading edge, just as it does in the real bar.
    _strip.frame = CGRectMake(width - 52, 8, 44, 44);
    // Keep the natural screen center until the actions would collide. The
    // optional mode instead centers in the entire available button gap.
    CGFloat left = 58;
    CGFloat available = MAX(0, right - 6 - left);
    CGFloat titleWidth = MIN(available, [_titleLabel sizeThatFits:CGSizeMake(CGFLOAT_MAX, 44)].width + 48);
    CGFloat center = sCenterTitleBetweenButtons && !sCollapseNavigationActions
        ? (left + right - 6) / 2 : MIN(width / 2, right - 6 - titleWidth / 2);
    // Match the real title capsule: native label height plus 8pt above and
    // below, 14pt side padding, and a 6pt gap before Apollo's 14×8 arrow.
    CGFloat titleHeight = MIN(44, ceil(_titleLabel.font.lineHeight) + 16);
    _titleGlass.layer.cornerRadius = titleHeight / 2;
    _titleGlass.frame = CGRectMake(MAX(left, center - titleWidth / 2), 8 + (44 - titleHeight) / 2, titleWidth, titleHeight);
    _titleLabel.frame = CGRectMake(14, 8, MAX(0, titleWidth - 48), titleHeight - 16);
    _titleChevron.frame = CGRectMake(titleWidth - 28, (titleHeight - 8) / 2, 14, 8);
    _hint.frame = CGRectMake(8, self.bounds.size.height - hintHeight, width - 16, hintHeight);
}
@end

@interface ApolloHeaderStyleSelector ()
@property (nonatomic, strong) UIStackView *stack;
@property (nonatomic, copy) NSArray<NSNumber *> *styles;
@end

@implementation ApolloHeaderStyleSelector
+ (CGFloat)heightForTraits:(UITraitCollection *)traits {
    CGFloat buttonHeight = MAX(44, ceil([UIFont preferredFontForTextStyle:UIFontTextStyleBody compatibleWithTraitCollection:traits].lineHeight) + 16);
    NSInteger count = ApolloProgressiveBlurAvailable() ? 4 : 3;
    return UIContentSizeCategoryIsAccessibilityCategory(traits.preferredContentSizeCategory)
        ? count * buttonHeight + (count - 1) * 8 : buttonHeight;
}
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    _styles = ApolloProgressiveBlurAvailable() ? @[@1, @2, @4, @3] : @[@1, @2, @3];
    NSDictionary *names = @{@1:@"Soft", @2:@"Hard", @4:@"Blur", @3:@"Hidden"};
    _stack = [UIStackView new];
    _stack.spacing = 8;
    _stack.distribution = UIStackViewDistributionFillEqually;
    _stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_stack];
    [NSLayoutConstraint activateConstraints:@[
        [_stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_stack.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
    ]];
    for (NSNumber *style in _styles) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.tag = style.integerValue;
        [button setTitle:names[style] forState:UIControlStateNormal];
        button.accessibilityLabel = [names[style] stringByAppendingString:@" header style"];
        button.accessibilityHint = @"Updates the preview and navigation headers.";
        button.titleLabel.adjustsFontForContentSizeCategory = YES;
        button.layer.cornerRadius = 10;
        [button addTarget:self action:@selector(selected:) forControlEvents:UIControlEventTouchUpInside];
        [_stack addArrangedSubview:button];
    }
    [self refresh];
    return self;
}
- (void)selected:(UIButton *)sender {
    if (self.onSelect) self.onSelect(sender.tag);
    [self refresh];
}
- (void)refresh {
    _stack.axis = UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory)
        ? UILayoutConstraintAxisVertical : UILayoutConstraintAxisHorizontal;
    UIColor *accent = ApolloThemeAccentColor() ?: self.tintColor;
    UIColor *resolved = [accent resolvedColorWithTraitCollection:self.traitCollection];
    for (UIButton *button in _stack.arrangedSubviews) {
        BOOL selected = button.tag == ApolloResolvedScrollEdgeEffectStyle();
        button.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody compatibleWithTraitCollection:self.traitCollection];
        button.backgroundColor = selected ? accent : UIColor.tertiarySystemFillColor;
        [button setTitleColor:selected ? (ApolloColorIsLight(resolved) ? UIColor.blackColor : UIColor.whiteColor) : UIColor.labelColor forState:UIControlStateNormal];
        button.accessibilityTraits = UIAccessibilityTraitButton | (selected ? UIAccessibilityTraitSelected : 0);
        // Outline plus the selected accessibility trait avoids relying on color alone.
        button.layer.borderWidth = selected ? 2 : 0;
        button.layer.borderColor = [UIColor.labelColor resolvedColorWithTraitCollection:self.traitCollection].CGColor;
    }
}
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self refresh];
}
@end
