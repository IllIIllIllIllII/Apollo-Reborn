#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Name-only compact tab bar. Its owner supplies the frame, transition, and
// expanded touch target; UIControlEventTouchUpInside requests expansion.
@interface ApolloCompactTabBarView : UIControl

@property (nonatomic, copy) NSString *title;
@property (nonatomic, assign) CGFloat titleAlpha;
@property (nonatomic, assign) CGFloat expansionProgress; // 0 = compact, 1 = expanded
@property (nonatomic, readonly) CGSize expandedContentSize;

- (CGSize)compactSize;
// Call once with laid-out, untransformed native content before hiding the bar.
// expandedFrame is expressed in tabBar.superview coordinates.
- (BOOL)captureExpandedContentFromTabBar:(UITabBar *)tabBar expandedFrame:(CGRect)expandedFrame;

@end

NS_ASSUME_NONNULL_END
