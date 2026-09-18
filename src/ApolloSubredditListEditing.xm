#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "ApolloCommon.h"
#import "ApolloFollowingSection.h"

// Keep the native edit controls and data-source actions, but present their
// confirmation in place. UIKit's swipe confirmation translates the entire cell
// and temporarily clears its fill on newer iOS versions.
static char kListConfirmation, kCellConfirmation, kEditingRightMargin, kEditingStarPriorities;

static UITableView *ApolloEditingTable(UIView *view) {
    for (UIView *v = view; v; v = v.superview) {
        if ([v isKindOfClass:UITableView.class]) return (UITableView *)v;
    }
    return nil;
}

static BOOL ApolloEditingIsList(UITableView *table) {
    Class cls = NSClassFromString(@"Apollo.RedditListViewController");
    return cls && [(id)table.dataSource isKindOfClass:cls];
}

static id ApolloEditingIvar(id object, const char *name) {
    Ivar ivar = object ? class_getInstanceVariable([object class], name) : NULL;
    return ivar ? object_getIvar(object, ivar) : nil;
}

// UIKit's inherited margins can reflect either the pre-edit or edited content
// width on reused cells. Apollo anchors its star stack to that margin, so the
// two values produce two different star columns. Use one explicit editing
// inset, restoring the original value outside editing. Do this at lifecycle
// entry points, never by driving geometry from layoutSubviews.
static void ApolloEditingAlignStar(UITableViewCell *cell, BOOL editing) {
    UIButton *star = ApolloEditingIvar(cell, "accessoryButton");
    if (![star isKindOfClass:UIButton.class]) return;
    NSNumber *original = objc_getAssociatedObject(cell, &kEditingRightMargin);
    NSArray<NSNumber *> *priorities = objc_getAssociatedObject(cell, &kEditingStarPriorities);
    UIEdgeInsets margins = cell.contentView.layoutMargins;
    if (editing && ApolloEditingIsList(ApolloEditingTable(cell))) {
        // The star and text otherwise share the same hugging priority. A
        // reused stack can give spare width to the button instead of its text,
        // centering the glyph inside a wider button and shifting that star.
        if (!priorities) {
            priorities = @[@([star contentHuggingPriorityForAxis:UILayoutConstraintAxisHorizontal]),
                           @([star contentCompressionResistancePriorityForAxis:UILayoutConstraintAxisHorizontal])];
            objc_setAssociatedObject(cell, &kEditingStarPriorities, priorities, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        [star setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [star setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        if (!original) objc_setAssociatedObject(cell, &kEditingRightMargin, @(margins.right), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!objc_getAssociatedObject(cell, &kCellConfirmation)) margins.right = 23.0;
    } else if (original) {
        margins.right = original.doubleValue;
        if (priorities.count == 2) {
            [star setContentHuggingPriority:priorities[0].floatValue forAxis:UILayoutConstraintAxisHorizontal];
            [star setContentCompressionResistancePriority:priorities[1].floatValue forAxis:UILayoutConstraintAxisHorizontal];
            objc_setAssociatedObject(cell, &kEditingStarPriorities, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        objc_setAssociatedObject(cell, &kEditingRightMargin, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        return;
    }
    cell.contentView.layoutMargins = margins;
}

@interface ApolloListEditConfirmation : NSObject <UIGestureRecognizerDelegate>
@property(nonatomic, weak) UITableView *table;
@property(nonatomic, weak) UITableViewCell *cell;
@property(nonatomic, strong) UIView *panel;
@property(nonatomic, strong) UITapGestureRecognizer *outsideTap;
- (void)dismiss;
- (void)close;
- (void)confirm;
@end

@implementation ApolloListEditConfirmation
- (void)dismiss {
    objc_setAssociatedObject(self.cell, &kCellConfirmation, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (self.panel) ApolloLog(@"[ListEditing] dismiss");
    [self.panel removeFromSuperview];
    [self.table removeGestureRecognizer:self.outsideTap];
    [self.table.panGestureRecognizer removeTarget:self action:@selector(scrolled:)];
    self.panel = nil;
    self.cell = nil;
    self.outsideTap = nil;
}
- (void)close {
    UIView *panel = self.panel;
    UITableViewCell *cell = self.cell;
    if (!panel || !cell) { [self dismiss]; return; }
    [UIView animateWithDuration:UIAccessibilityIsReduceMotionEnabled() ? 0.0 : 0.28
                          delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseInOut
                     animations:^{
        panel.subviews.firstObject.transform = CGAffineTransformMakeTranslation(CGRectGetWidth(panel.bounds), 0.0);
    } completion:^(BOOL finished) {
        // A reload, reuse or another minus tap may have replaced this panel.
        if (self.panel == panel) [self dismiss];
    }];
}
- (void)scrolled:(UIPanGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) [self dismiss];
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldReceiveTouch:(UITouch *)touch {
    for (UIView *view = touch.view; view; view = view.superview) {
        if ([NSStringFromClass(view.class) isEqualToString:@"UITableViewCellEditControl"]) return NO;
    }
    return ![touch.view isDescendantOfView:self.panel];
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}
- (void)confirm {
    UITableView *table = self.table;
    NSIndexPath *path = [table indexPathForCell:self.cell];
    [self dismiss];
    // Resolve the visible path at tap time. The Following/hidden-section hooks
    // translate it to Apollo's model; never retain an index across row changes.
    if (table.editing && path && [table.dataSource respondsToSelector:@selector(tableView:commitEditingStyle:forRowAtIndexPath:)]) {
        ApolloFollowingAnimateNextRemoval(table, path);
        [table.dataSource tableView:table commitEditingStyle:UITableViewCellEditingStyleDelete forRowAtIndexPath:path];
    }
}
@end

static BOOL ApolloEditingShowConfirmation(UIControl *control) {
    if (![NSStringFromClass(control.class) isEqualToString:@"UITableViewCellEditControl"]) return NO;
    UIView *parent = control.superview;
    while (parent && ![parent isKindOfClass:UITableViewCell.class]) parent = parent.superview;
    UITableViewCell *cell = (UITableViewCell *)parent;
    UITableView *table = ApolloEditingTable(cell);
    if (!ApolloEditingIsList(table) || !table.editing || cell.editingStyle != UITableViewCellEditingStyleDelete) return NO;
    NSIndexPath *path = [table indexPathForCell:cell];
    if (!path) return NO;
    ApolloListEditConfirmation *state = objc_getAssociatedObject(table, &kListConfirmation);
    BOOL sameCell = state.cell == cell;
    if (sameCell) { [state close]; return YES; }
    [state dismiss];
    if (!state) {
        state = [ApolloListEditConfirmation new];
        state.table = table;
        objc_setAssociatedObject(table, &kListConfirmation, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSString *title = nil;
    if ([table.delegate respondsToSelector:@selector(tableView:titleForDeleteConfirmationButtonForRowAtIndexPath:)]) {
        title = [table.delegate tableView:table titleForDeleteConfirmationButtonForRowAtIndexPath:path];
    }
    if (!title.length) title = NSLocalizedString(@"Delete", nil);
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    button.backgroundColor = UIColor.systemRedColor;
    button.layer.cornerRadius = 16.0;
    button.layer.cornerCurve = kCACornerCurveContinuous;
    button.accessibilityIdentifier = @"ApolloListEditConfirmation";
    [button addTarget:state action:@selector(confirm) forControlEvents:UIControlEventTouchUpInside];
    UIView *panel = [UIView new];
    // Slide an opaque row-colored backing with the button, covering the
    // stationary star/grip even around the button's rounded corners.
    panel.clipsToBounds = YES;
    UIView *surface = [UIView new];
    surface.backgroundColor = cell.contentView.backgroundColor ?: cell.backgroundColor;
    surface.translatesAutoresizingMaskIntoConstraints = NO;
    [panel addSubview:surface];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [surface addSubview:button];
    [cell addSubview:panel];
    // Match the native swipe button: Footnote text, 12 points on each side,
    // four-point vertical insets and a continuous 16-point corner radius.
    // Round to the display pixel just as UIKit does (Unfavorite: 86 2/3 pt
    // at 3x; Hide: 52 pt at the default content size).
    CGFloat scale = MAX(1.0, cell.traitCollection.displayScale);
    CGFloat textWidth = [title sizeWithAttributes:@{NSFontAttributeName: button.titleLabel.font}].width;
    CGFloat width = ceil((textWidth + 24.0) * scale) / scale;
    [NSLayoutConstraint activateConstraints:@[
        [panel.trailingAnchor constraintEqualToAnchor:cell.safeAreaLayoutGuide.trailingAnchor constant:-30.0],
        [panel.topAnchor constraintEqualToAnchor:cell.topAnchor],
        [panel.bottomAnchor constraintEqualToAnchor:cell.bottomAnchor],
        [panel.widthAnchor constraintEqualToConstant:width + 8.0],
        [surface.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor],
        [surface.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor],
        [surface.topAnchor constraintEqualToAnchor:panel.topAnchor],
        [surface.bottomAnchor constraintEqualToAnchor:panel.bottomAnchor],
        [button.leadingAnchor constraintEqualToAnchor:surface.leadingAnchor constant:4.0],
        [button.trailingAnchor constraintEqualToAnchor:surface.trailingAnchor constant:-4.0],
        [button.centerYAnchor constraintEqualToAnchor:surface.centerYAnchor],
        [button.heightAnchor constraintEqualToAnchor:surface.heightAnchor constant:-8.0]
    ]];
    ApolloLog(@"[ListEditing] showing confirmation %@", title);
    state.cell = cell;
    objc_setAssociatedObject(cell, &kCellConfirmation, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    state.panel = panel;
    state.outsideTap = [[UITapGestureRecognizer alloc] initWithTarget:state action:@selector(close)];
    state.outsideTap.cancelsTouchesInView = NO;
    state.outsideTap.delegate = state;
    [table addGestureRecognizer:state.outsideTap];
    [table.panGestureRecognizer addTarget:state action:@selector(scrolled:)];
    [cell layoutIfNeeded];
    surface.transform = CGAffineTransformMakeTranslation(width + 8.0, 0.0);
    // Only the overlay moves. Keep every underlying row view and margin intact.
    [UIView animateWithDuration:UIAccessibilityIsReduceMotionEnabled() ? 0.0 : 0.28
                          delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseInOut
                     animations:^{
        surface.transform = CGAffineTransformIdentity;
    } completion:nil];
    return YES;
}

%hook UIControl
- (void)sendAction:(SEL)action to:(id)target forEvent:(UIEvent *)event {
    // The native minus sends TWO actions for one tap: its rotation, then the
    // cell's confirmation action. Only the latter may toggle our panel.
    if (action == NSSelectorFromString(@"editControlWasClicked:") && ApolloEditingShowConfirmation(self)) return;
    if (action == NSSelectorFromString(@"_toggleRotate") &&
        [NSStringFromClass(self.class) isEqualToString:@"UITableViewCellEditControl"] &&
        ApolloEditingIsList(ApolloEditingTable(self))) return;
    %orig;
}
%end

%hook UITableView
- (void)setEditing:(BOOL)editing animated:(BOOL)animated {
    [(ApolloListEditConfirmation *)objc_getAssociatedObject(self, &kListConfirmation) dismiss];
    %orig;
}
- (void)reloadData {
    [(ApolloListEditConfirmation *)objc_getAssociatedObject(self, &kListConfirmation) dismiss];
    %orig;
}
%end

%hook UITableViewCell
- (void)setEditing:(BOOL)editing animated:(BOOL)animated {
    ApolloEditingAlignStar(self, editing);
    %orig;
}
- (void)didMoveToSuperview {
    %orig;
    ApolloEditingAlignStar(self, self.editing);
}
- (void)prepareForReuse {
    ApolloListEditConfirmation *state = objc_getAssociatedObject(self, &kCellConfirmation);
    if (state.cell == self) [state dismiss];
    ApolloEditingAlignStar(self, NO);
    %orig;
}
%end

// Apollo's Swift cell overrides prepareForReuse without forwarding to the
// UITableViewCell implementation. Cover that entry point as well as stock rows.
@interface ApolloEditListCell : UITableViewCell @end
%group ApolloListEditingCells
%hook ApolloEditListCell
- (void)prepareForReuse {
    ApolloListEditConfirmation *state = objc_getAssociatedObject(self, &kCellConfirmation);
    if (state.cell == self) [state dismiss];
    ApolloEditingAlignStar(self, NO);
    %orig;
}
%end
%end

%ctor {
    %init;
    Class cellClass = NSClassFromString(@"Apollo.RedditListTableViewCell");
    if (cellClass) {
        %init(ApolloListEditingCells, ApolloEditListCell = cellClass);
    }
}
