#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Implemented by the Swift bridge compiled with the pinned native renderer.
@interface ApolloAwardAnimationView : UIView
- (instancetype)initWithURL:(NSURL *)URL stillImageView:(UIImageView *)stillImageView;
@property (nonatomic) BOOL displayActive;
- (void)prepareForRemoval;
@end

NS_ASSUME_NONNULL_END
