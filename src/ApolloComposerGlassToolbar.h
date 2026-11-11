#import <UIKit/UIKit.h>

__BEGIN_DECLS
/// YES when the Liquid Glass composer bar has moved this button stack into its
/// sideways-scrolling capsule. The stack then sizes to its content, so code that
/// squeezes the stack to fit the bar's width must leave it alone.
BOOL ApolloComposerGlassToolbarHostsStack(UIStackView *stack);
__END_DECLS
