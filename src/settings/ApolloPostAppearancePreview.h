#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Hosts Apollo's actual feed nodes, measured at the available preview width.
@interface ApolloPostAppearancePreview : UIView
@property (nonatomic) BOOL compact;
@property (nonatomic, copy, nullable) void (^heightDidChange)(void);
- (CGFloat)heightForWidth:(CGFloat)width;
- (void)refresh;
@end

NS_ASSUME_NONNULL_END
