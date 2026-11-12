// ApolloComposerGlassToolbar.xm — on Liquid Glass, the markdown composer's
// formatting bar (QuickBarKeyboardView) becomes a glass capsule holding every
// option, including the ••• sheet's rows, in one sideways-scrolling strip,
// like Notes on iOS 26.
//
// Apollo's row stays laid out but invisible (an empty layer mask, not hidden,
// because the GIF injection, media gating and tint walkers skip hidden views).
// Strip buttons forward to Apollo: native buttons send their touch-up actions
// (to the gating overlay when a subreddit blocks images); ••• rows capture a
// fresh ••• sheet without presenting it and select the row by Action kind, so
// they see the current text and follow-up sheets open from the strip button.
// The subreddit/user suggestions and add-link-title rows keep Apollo's bar.

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "ApolloComposerGlassToolbar.h"
#import "ApolloActionMenu.h"
#import "ApolloClasses.h"
#import "ApolloCommon.h"
#import "ApolloDuoRail.h"
#import "ApolloNativeActionMenus.h"
#import "ApolloSwiftRuntime.h"

NSString *const ApolloComposerGlassToolbarIdentifier = @"apollo-composer-glass-toolbar";

// Identifiers ApolloMarkdownToolbarGif gives its GIF chip and its image-gating overlay.
static NSString *const kApolloComposerGlassGifIdentifier = @"apollo-tweak-gif-button";
static NSString *const kApolloComposerGlassImageGateIdentifier = @"apollo-tweak-image-gate";

static const CGFloat kApolloComposerGlassCapsuleHeight = 44.0;
// Space between the capsule and the keyboard. Apollo's bar sits flush on the
// keyboard and is 45pt tall, so the capsule overhangs the bar's top a little.
static const CGFloat kApolloComposerGlassKeyboardGap = 6.0;
static const CGFloat kApolloComposerGlassSideMargin = 16.0;
static const CGFloat kApolloComposerGlassItemWidth = 44.0;
static const CGFloat kApolloComposerGlassItemSpacing = 6.0;
static const CGFloat kApolloComposerGlassStripInset = 6.0;

static char kApolloComposerGlassStripKey;
static char kApolloComposerGlassBarBackgroundKey;
static char kApolloComposerGlassBarClipsKey;
static char kApolloComposerGlassItemKey;

// QuickBarKeyboardView.ViewType: mainActionButtons, subreddits, users, addLinkTitle.
static const uint8_t kApolloComposerGlassMainActionButtons = 0;

#pragma mark - Items

@interface ApolloComposerGlassItem : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, strong) UIImage *image;
// Set for Apollo's own buttons and the GIF chip.
@property (nonatomic, weak) UIControl *nativeControl;
// The ••• sheet's Action kind for its rows, NSNotFound otherwise.
@property (nonatomic) NSUInteger menuKind;
@end

@implementation ApolloComposerGlassItem
@end

// Fit an icon into the 24pt box the glass menus use for Apollo's option-* art.
static UIImage *ApolloComposerGlassFittedIcon(UIImage *image) {
    if (!image) return nil;
    CGSize size = image.size;
    CGFloat side = ApolloActionMenuIconBoxSide;
    CGFloat scale = (size.width > 0.0 && size.height > 0.0) ? MIN(side / size.width, side / size.height) : 1.0;
    if (scale >= 1.0) return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];

    CGSize drawSize = CGSizeMake(round(size.width * scale), round(size.height * scale));
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side)];
    UIImage *fitted = [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {
        [image drawInRect:CGRectMake(floor((side - drawSize.width) / 2.0), floor((side - drawSize.height) / 2.0),
                                     drawSize.width, drawSize.height)];
    }];
    return [fitted imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

// The GIF chip draws a bordered label instead of an image; this is the same
// shape as a template icon.
static UIImage *ApolloComposerGlassGIFIcon(void) {
    static UIImage *icon;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CGFloat side = ApolloActionMenuIconBoxSide;
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side)];
        icon = [[renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {
            UIBezierPath *border = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(1.5, 4.5, side - 3.0, side - 9.0)
                                                              cornerRadius:3.5];
            border.lineWidth = 1.5;
            [UIColor.blackColor setStroke];
            [border stroke];
            NSDictionary *attributes = @{
                NSFontAttributeName: [UIFont systemFontOfSize:9.0 weight:UIFontWeightBold],
                NSForegroundColorAttributeName: UIColor.blackColor,
            };
            CGSize textSize = [@"GIF" sizeWithAttributes:attributes];
            [@"GIF" drawAtPoint:CGPointMake((side - textSize.width) / 2.0, (side - textSize.height) / 2.0)
                 withAttributes:attributes];
        }] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    });
    return icon;
}

static UIImage *ApolloComposerGlassNativeIcon(UIControl *control) {
    if ([control.accessibilityIdentifier isEqualToString:kApolloComposerGlassGifIdentifier]) {
        return ApolloComposerGlassGIFIcon();
    }
    UIImage *image = [control isKindOfClass:[UIButton class]]
        ? [(UIButton *)control imageForState:UIControlStateNormal] : nil;
    if (!image) {
        for (UIView *subview in control.subviews) {
            if ([subview isKindOfClass:[UIImageView class]] && ((UIImageView *)subview).image) {
                image = ((UIImageView *)subview).image;
                break;
            }
        }
    }
    return ApolloComposerGlassFittedIcon(image);
}

static UIControl *ApolloComposerGlassFindGifChip(UIView *view, NSUInteger depth) {
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:[UIControl class]] &&
            [subview.accessibilityIdentifier isEqualToString:kApolloComposerGlassGifIdentifier]) {
            return (UIControl *)subview;
        }
        if (depth > 0) {
            UIControl *found = ApolloComposerGlassFindGifChip(subview, depth - 1);
            if (found) return found;
        }
    }
    return nil;
}

// When a subreddit blocks images, ApolloMarkdownToolbarGif pins a transparent
// button over the photo button that explains why instead of opening the picker.
static UIControl *ApolloComposerGlassGateOverlay(UIControl *control) {
    for (UIView *sibling in control.superview.subviews) {
        if ([sibling isKindOfClass:[UIControl class]] &&
            [sibling.accessibilityIdentifier isEqualToString:kApolloComposerGlassImageGateIdentifier] &&
            CGRectIntersectsRect(sibling.frame, control.frame)) {
            return (UIControl *)sibling;
        }
    }
    return nil;
}

static uint8_t ApolloComposerGlassVisibleViewType(UIView *bar) {
    static ptrdiff_t offset = -2;
    if (offset == -2) offset = ApolloIvarOffset(object_getClass(bar), "currentlyVisibleView");
    if (offset < 0) return kApolloComposerGlassMainActionButtons;
    return *((uint8_t *)(__bridge void *)bar + offset);
}

// Flatten the captured ••• menu into strip items, keeping only rows built from
// an Action kind (those are what a fresh capture can select again).
static void ApolloComposerGlassCollectMenuItems(NSArray<UIMenuElement *> *elements,
                                                NSMutableArray<ApolloComposerGlassItem *> *items,
                                                NSMutableArray<NSString *> *skipped) {
    for (UIMenuElement *element in elements) {
        if ([element isKindOfClass:[UIMenu class]]) {
            ApolloComposerGlassCollectMenuItems(((UIMenu *)element).children, items, skipped);
            continue;
        }
        NSUInteger kind = ApolloActionMenuNativeKindForElement(element);
        if (![element isKindOfClass:[UIAction class]] || kind == NSNotFound || !element.image) {
            [skipped addObject:element.title ?: @"?"];
            continue;
        }
        ApolloComposerGlassItem *item = [ApolloComposerGlassItem new];
        item.title = element.title;
        item.image = [element.image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        item.menuKind = kind;
        [items addObject:item];
    }
}

#pragma mark - Strip

// Drags that start on a button still scroll the strip.
@interface ApolloComposerGlassScrollView : UIScrollView
@end

@implementation ApolloComposerGlassScrollView
- (BOOL)touchesShouldCancelInContentView:(__unused UIView *)view {
    return YES;
}
@end

API_AVAILABLE(ios(26.0))
@interface ApolloComposerGlassToolbarView : UIView
@property (nonatomic, weak) UIView *quickBar;
@property (nonatomic, strong) UIVisualEffectView *glass;
@property (nonatomic, strong) ApolloComposerGlassScrollView *scrollView;
@property (nonatomic, copy) NSArray<UIButton *> *buttons;
@property (nonatomic, copy) NSArray<ApolloComposerGlassItem *> *nativeItems;
@property (nonatomic, copy) NSArray<ApolloComposerGlassItem *> *menuItems;
@property (nonatomic, copy) NSString *nativeSignature;
@property (nonatomic) NSUInteger menuCaptureAttempts;
@property (nonatomic) BOOL menuCapturePending;
- (CGRect)capsuleFrame;
- (void)syncWithQuickBar;
@end

@implementation ApolloComposerGlassToolbarView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.accessibilityIdentifier = ApolloComposerGlassToolbarIdentifier;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.backgroundColor = UIColor.clearColor;
    // Plain black/white glyphs like Notes, not the theme accent.
    self.tintColor = UIColor.labelColor;

    UIGlassEffect *effect = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
    effect.interactive = YES;
    _glass = [[UIVisualEffectView alloc] initWithEffect:effect];
    _glass.clipsToBounds = YES;
    _glass.cornerConfiguration = [UICornerConfiguration capsuleConfiguration];
    [self addSubview:_glass];

    _scrollView = [[ApolloComposerGlassScrollView alloc] initWithFrame:CGRectZero];
    _scrollView.showsHorizontalScrollIndicator = NO;
    _scrollView.showsVerticalScrollIndicator = NO;
    _scrollView.alwaysBounceHorizontal = YES;
    _scrollView.alwaysBounceVertical = NO;
    _scrollView.delaysContentTouches = NO;
    _scrollView.scrollsToTop = NO;
    _scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    _scrollView.contentInset = UIEdgeInsetsMake(0.0, kApolloComposerGlassStripInset, 0.0, kApolloComposerGlassStripInset);
    [_glass.contentView addSubview:_scrollView];

    _buttons = @[];
    return self;
}

- (CGFloat)contentWidth {
    NSUInteger count = self.buttons.count;
    if (count == 0) return 0.0;
    return count * kApolloComposerGlassItemWidth + (count - 1) * kApolloComposerGlassItemSpacing;
}

// The capsule spans the bar's width (inside the margins) and floats a little
// above its bottom edge. When everything fits (iPad), it hugs its content.
- (CGRect)capsuleFrame {
    CGRect bounds = self.bounds;
    // The closed Duo's keyboard runs under its trailing status column, so the
    // capsule ignores that inset and matches the keyboard's width.
    UIEdgeInsets safe = ApolloDuoUsesCoverContentInsets() ? UIEdgeInsetsZero : self.safeAreaInsets;
    CGFloat minX = kApolloComposerGlassSideMargin + safe.left;
    CGFloat available = MAX(0.0, CGRectGetWidth(bounds) - minX - kApolloComposerGlassSideMargin - safe.right);
    CGFloat fitted = self.contentWidth + 2.0 * kApolloComposerGlassStripInset;
    CGFloat width = available;
    CGFloat x = minX;
    if (fitted > 0.0 && fitted < available) {
        width = fitted;
        x = minX + floor((available - fitted) / 2.0);
    }
    CGFloat y = CGRectGetHeight(bounds) - kApolloComposerGlassKeyboardGap - kApolloComposerGlassCapsuleHeight;
    return CGRectMake(x, y, width, kApolloComposerGlassCapsuleHeight);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect capsule = self.capsuleFrame;
    self.glass.frame = capsule;
    self.scrollView.frame = self.glass.contentView.bounds;

    CGFloat x = 0.0;
    for (UIButton *button in self.buttons) {
        button.frame = CGRectMake(x, 0.0, kApolloComposerGlassItemWidth, CGRectGetHeight(capsule));
        x += kApolloComposerGlassItemWidth + kApolloComposerGlassItemSpacing;
    }
    self.scrollView.contentSize = CGSizeMake(self.contentWidth, CGRectGetHeight(capsule));
}

// Only the capsule takes touches; it may overhang the bar's top edge.
- (BOOL)pointInside:(CGPoint)point withEvent:(__unused UIEvent *)event {
    return CGRectContainsPoint(self.glass.frame, point);
}

#pragma mark Items

- (NSArray<UIControl *> *)nativeControls {
    UIView *bar = self.quickBar;
    UIView *mainButtons = ApolloSendObject(bar, @selector(mainActionButtonsView));
    NSMutableArray<UIControl *> *controls = [NSMutableArray array];
    void (^add)(id) = ^(id control) {
        if ([control isKindOfClass:[UIControl class]] && !((UIControl *)control).hidden) [controls addObject:control];
    };
    add(ApolloSendObject(bar, @selector(cameraButton)));
    add(ApolloComposerGlassFindGifChip(mainButtons, 2));
    add(ApolloSendObject(bar, @selector(linkButton)));
    add(ApolloSendObject(bar, @selector(boldButton)));
    add(ApolloSendObject(bar, @selector(italicsButton)));
    add(ApolloSendObject(bar, @selector(subredditButton)));
    add(ApolloSendObject(bar, @selector(userButton)));
    return controls;
}

- (void)syncNativeItems {
    NSArray<UIControl *> *controls = [self nativeControls];
    NSMutableString *signature = [NSMutableString string];
    for (UIControl *control in controls) [signature appendFormat:@"%p,", control];
    if ([signature isEqualToString:self.nativeSignature ?: @""] && self.nativeItems) return;

    NSMutableArray<ApolloComposerGlassItem *> *items = [NSMutableArray array];
    for (UIControl *control in controls) {
        ApolloComposerGlassItem *item = [ApolloComposerGlassItem new];
        item.nativeControl = control;
        item.menuKind = NSNotFound;
        item.title = control.accessibilityLabel ?: @"";
        item.image = ApolloComposerGlassNativeIcon(control);
        if (item.image) [items addObject:item];
    }
    self.nativeSignature = signature;
    self.nativeItems = items;
    ApolloLog(@"[ComposerGlassToolbar] native buttons: %@", [[items valueForKey:@"title"] componentsJoinedByString:@", "]);
    [self rebuildButtons];
}

// Apollo's ••• handler builds its sheet synchronously; capture it without
// presenting it. `source` anchors any follow-up sheet a row opens.
- (id)captureMoreSheetFromSource:(UIView *)source {
    UIView *bar = self.quickBar;
    SEL tapped = @selector(moreButtonTapped:);
    if (!bar.window || ![bar respondsToSelector:tapped]) return nil;
    id moreButton = ApolloSendObject(bar, @selector(moreButton)) ?: source;
    return ApolloNativeActionMenuCaptureController(source, ^{
        ((void (*)(id, SEL, id))objc_msgSend)(bar, tapped, moreButton);
    });
}

- (void)captureMenuItemsIfNeeded {
    if (self.menuItems || self.menuCapturePending || self.menuCaptureAttempts >= 3 || !self.window) return;
    self.menuCapturePending = YES;
    // Not from inside the bar's layout pass: Apollo builds a view controller.
    __weak __typeof__(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong __typeof__(self) strip = weakSelf;
        if (!strip) return;
        strip.menuCapturePending = NO;
        strip.menuCaptureAttempts++;
        id controller = [strip captureMoreSheetFromSource:strip];
        UIMenu *menu = controller ? ApolloNativeActionMenuBuildCaptured(controller) : nil;
        NSMutableArray<ApolloComposerGlassItem *> *items = [NSMutableArray array];
        NSMutableArray<NSString *> *skipped = [NSMutableArray array];
        ApolloComposerGlassCollectMenuItems(menu.children ?: @[], items, skipped);
        NSMutableArray<NSString *> *described = [NSMutableArray array];
        for (ApolloComposerGlassItem *item in items) {
            [described addObject:[NSString stringWithFormat:@"%@=%lu", item.title, (unsigned long)item.menuKind]];
        }
        ApolloLog(@"[ComposerGlassToolbar] ••• rows (attempt %lu, controller=%@): %@; skipped: %@",
                  (unsigned long)strip.menuCaptureAttempts, controller ? NSStringFromClass([controller class]) : @"nil",
                  [described componentsJoinedByString:@", "], [skipped componentsJoinedByString:@", "]);
        if (items.count == 0) return;
        strip.menuItems = items;
        [strip rebuildButtons];
    });
}

- (void)rebuildButtons {
    for (UIButton *button in self.buttons) [button removeFromSuperview];
    NSMutableArray<UIButton *> *buttons = [NSMutableArray array];
    NSArray<ApolloComposerGlassItem *> *items = [(self.nativeItems ?: @[]) arrayByAddingObjectsFromArray:self.menuItems ?: @[]];
    for (ApolloComposerGlassItem *item in items) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        [button setImage:item.image forState:UIControlStateNormal];
        button.accessibilityLabel = item.title;
        SEL action = item.nativeControl ? @selector(nativeItemTapped:) : @selector(menuItemTapped:);
        [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
        objc_setAssociatedObject(button, &kApolloComposerGlassItemKey, item, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [self.scrollView addSubview:button];
        [buttons addObject:button];
    }
    self.buttons = buttons;
    [self syncNativeStates];
    [self setNeedsLayout];
}

// Gating dims the photo button and GIF chip; mirror that and enabled state.
- (void)syncNativeStates {
    for (UIButton *button in self.buttons) {
        ApolloComposerGlassItem *item = objc_getAssociatedObject(button, &kApolloComposerGlassItemKey);
        UIControl *control = item.nativeControl;
        if (!control) continue;
        button.alpha = control.alpha;
        button.enabled = control.enabled;
    }
}

- (void)syncWithQuickBar {
    [self syncNativeItems];
    [self syncNativeStates];
    [self captureMenuItemsIfNeeded];
}

#pragma mark Actions

- (void)nativeItemTapped:(UIButton *)button {
    ApolloComposerGlassItem *item = objc_getAssociatedObject(button, &kApolloComposerGlassItemKey);
    UIControl *control = item.nativeControl;
    if (!control) return;
    UIControl *target = ApolloComposerGlassGateOverlay(control) ?: control;
    [target sendActionsForControlEvents:UIControlEventTouchUpInside];
}

- (void)menuItemTapped:(UIButton *)button {
    ApolloComposerGlassItem *item = objc_getAssociatedObject(button, &kApolloComposerGlassItemKey);
    if (!item || item.menuKind == NSNotFound) return;
    uint16_t kind = (uint16_t)item.menuKind;
    id controller = [self captureMoreSheetFromSource:button];
    if (controller && ApolloNativeActionMenuHasAction(controller, kind)) {
        ApolloNativeActionMenuInvokeAction(controller, kind);
        return;
    }
    // Apollo stopped offering the row in this state: open the whole sheet.
    ApolloLog(@"[ComposerGlassToolbar] %@ (kind %u) unavailable, opening the ••• sheet", item.title, kind);
    UIView *bar = self.quickBar;
    if ([bar respondsToSelector:@selector(moreButtonTapped:)]) {
        ((void (*)(id, SEL, id))objc_msgSend)(bar, @selector(moreButtonTapped:), ApolloSendObject(bar, @selector(moreButton)));
    }
}

@end

#pragma mark - Bar

API_AVAILABLE(ios(26.0))
static ApolloComposerGlassToolbarView *ApolloComposerGlassStrip(UIView *bar) {
    return objc_getAssociatedObject(bar, &kApolloComposerGlassStripKey);
}

API_AVAILABLE(ios(26.0))
static void ApolloComposerGlassSync(UIView *bar) {
    if (!bar.window) return;
    ApolloComposerGlassToolbarView *strip = ApolloComposerGlassStrip(bar);
    if (!strip) {
        strip = [[ApolloComposerGlassToolbarView alloc] initWithFrame:bar.bounds];
        strip.quickBar = bar;
        objc_setAssociatedObject(bar, &kApolloComposerGlassStripKey, strip, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloLog(@"[ComposerGlassToolbar] installed in %@", NSStringFromClass([bar.superview class]));
    }
    // At the back, so Apollo's suggestions and add-link rows slide in over it.
    if (strip.superview != bar) {
        [bar insertSubview:strip atIndex:0];
    } else if (bar.subviews.firstObject != strip) {
        [bar sendSubviewToBack:strip];
    }

    UIView *mainButtons = ApolloSendObject(bar, @selector(mainActionButtonsView));
    UIView *separator = ApolloSendObject(bar, @selector(topSeparator));
    BOOL glass = mainButtons && ApolloComposerGlassVisibleViewType(bar) == kApolloComposerGlassMainActionButtons;

    // Apollo's row stays laid out for the walkers that find its controls, but
    // draws nothing and takes no touches.
    if (mainButtons) {
        if (!mainButtons.layer.mask) mainButtons.layer.mask = [CALayer layer];
        mainButtons.userInteractionEnabled = NO;
        mainButtons.accessibilityElementsHidden = YES;
    }

    UIColor *background = bar.backgroundColor;
    BOOL backgroundIsClear = !background || CGColorGetAlpha(background.CGColor) < 0.01;
    if (glass) {
        if (!backgroundIsClear) {
            objc_setAssociatedObject(bar, &kApolloComposerGlassBarBackgroundKey, background, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            bar.backgroundColor = UIColor.clearColor;
        }
    } else if (backgroundIsClear) {
        UIColor *original = objc_getAssociatedObject(bar, &kApolloComposerGlassBarBackgroundKey);
        if (original) bar.backgroundColor = original;
    }
    // The bar clips to its bounds, which would cut off the capsule's overhang.
    // Apollo's off-bounds rows (suggestions, add-link title) only move in when
    // it leaves the main buttons, and then the bar clips again.
    NSNumber *originalClips = objc_getAssociatedObject(bar, &kApolloComposerGlassBarClipsKey);
    if (glass) {
        if (!originalClips) {
            objc_setAssociatedObject(bar, &kApolloComposerGlassBarClipsKey, @(bar.clipsToBounds), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        bar.clipsToBounds = NO;
    } else if (originalClips) {
        bar.clipsToBounds = originalClips.boolValue;
        objc_setAssociatedObject(bar, &kApolloComposerGlassBarClipsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    separator.hidden = glass;
    strip.alpha = glass ? 1.0 : 0.0;
    [strip syncWithQuickBar];
}

void ApolloComposerGlassToolbarSetNeedsSync(UIView *view) {
    Class barClass = ApolloClassQuickBarKeyboardView;
    if (!barClass || !IsLiquidGlass()) return;
    for (UIView *ancestor = view; ancestor; ancestor = ancestor.superview) {
        if ([ancestor isKindOfClass:barClass]) {
            [ancestor setNeedsLayout];
            return;
        }
    }
}

%hook _TtC6Apollo20QuickBarKeyboardView

- (void)layoutSubviews {
    %orig;
    if (@available(iOS 26.0, *)) {
        if (IsLiquidGlass()) ApolloComposerGlassSync((UIView *)self);
    }
}

// The capsule overhangs the bar's top edge; let that part take touches.
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if (%orig) return YES;
    if (@available(iOS 26.0, *)) {
        ApolloComposerGlassToolbarView *strip = ApolloComposerGlassStrip((UIView *)self);
        if (!strip || strip.hidden || strip.alpha < 0.01) return NO;
        return [strip pointInside:[strip convertPoint:point fromView:(UIView *)self] withEvent:event];
    }
    return NO;
}

%end
