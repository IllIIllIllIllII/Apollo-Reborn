#import <UIKit/UIKit.h>

// A self-contained sample feed; gestures never navigate or change account data.
@interface ApolloHeaderPreview : UIView
- (void)refresh;
@end

// Direct style comparison; stacks vertically at accessibility text sizes.
@interface ApolloHeaderStyleSelector : UIView
@property (nonatomic, copy) void (^onSelect)(NSInteger style);
- (void)refresh;
+ (CGFloat)heightForTraits:(UITraitCollection *)traits;
@end
