// Fullscreen media keeps native aspect-fit, zoom, and pan behavior while
// excluding the presenting page's trailing tab rail from its fit calculation.
#import <UIKit/UIKit.h>
#import "ApolloDuoCompatibility.h"
#import "ApolloDuoRail.h"

// Native SMScrollView::_setMinimumZoomScaleToFit subtracts safeAreaInsets
// from its viewport before fitting (Apollo 1.15.11, 0x100042e08). On Duo the
// fullscreen viewer inherits the presenting tab controller's trailing rail
// inset, although the rail is not part of the viewer. The transition uses the
// full bounds, then this native fit shrinks even a square image by 84pt.
// Correct the geometry read at its source. Keep native aspect-fit, zoom and
// pan behavior; tall images should not be forcibly cropped to fill the width.
%hook SMScrollView
- (UIEdgeInsets)safeAreaInsets {
    UIEdgeInsets insets = %orig;
    if (ApolloDuoCurrentMode() == ApolloDuoModePhone) return insets;
    Class viewerClass = NSClassFromString(@"_TtC6Apollo21MediaViewerController");
    BOOL fullscreenImage = [(id)((UIScrollView *)self).delegate isKindOfClass:viewerClass];
    if (!fullscreenImage) {
        for (UIResponder *next = ((UIView *)self).nextResponder; next; next = next.nextResponder) {
            if ([next isKindOfClass:viewerClass]) { fullscreenImage = YES; break; }
        }
    }
    if (fullscreenImage) {
        insets.left = 0.0;
        insets.right = 0.0;
    }
    return insets;
}
%end

%ctor {
    %init;
}
