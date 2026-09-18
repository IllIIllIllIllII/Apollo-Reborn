#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "ApolloCommon.h"

// Keep the native edit controls and data-source actions, but present their
// confirmation in place. UIKit's swipe confirmation translates the entire cell
// and temporarily clears its fill on newer iOS versions.
static char kListConfirmation, kCellConfirmation;

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

@interface ApolloListEditConfirmation : NSObject <UIGestureRecognizerDelegate>
@property(nonatomic, weak) UITableView *table;
@property(nonatomic, weak) UITableViewCell *cell;
@property(nonatomic, strong) UIView *panel;
@property(nonatomic, strong) UITapGestureRecognizer *outsideTap;
- (void)dismiss;
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
    [state dismiss];
    if (sameCell) return YES;
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
    // The row keeps its own background. This small backing only covers the
    // trailing star/reorder grip underneath the confirmation button.
    panel.backgroundColor = cell.contentView.backgroundColor ?: cell.backgroundColor;
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [panel addSubview:button];
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
        [button.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:4.0],
        [button.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-4.0],
        [button.centerYAnchor constraintEqualToAnchor:panel.centerYAnchor],
        [button.heightAnchor constraintEqualToAnchor:panel.heightAnchor constant:-8.0]
    ]];
    ApolloLog(@"[ListEditing] showing confirmation %@", title);
    state.cell = cell;
    objc_setAssociatedObject(cell, &kCellConfirmation, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    state.panel = panel;
    state.outsideTap = [[UITapGestureRecognizer alloc] initWithTarget:state action:@selector(dismiss)];
    state.outsideTap.cancelsTouchesInView = NO;
    state.outsideTap.delegate = state;
    [table addGestureRecognizer:state.outsideTap];
    [table.panGestureRecognizer addTarget:state action:@selector(scrolled:)];
    panel.alpha = 0.0;
    [UIView animateWithDuration:0.2 animations:^{ panel.alpha = 1.0; }];
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
- (void)prepareForReuse {
    ApolloListEditConfirmation *state = objc_getAssociatedObject(self, &kCellConfirmation);
    if (state.cell == self) [state dismiss];
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
