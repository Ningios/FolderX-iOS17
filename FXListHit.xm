#import "FXInterface.h"
#import <dispatch/dispatch.h>

// In a genuine expanded native icon grid, UIKit can still return a neighboring app or a
// drag placeholder as the folder's list-level target. Hand back the existing
// live SBFolderIcon + the corresponding native list index as ONE pair.
// We do not invent a model, expand the hit rectangle or accept arbitrary data.
extern BOOL FXResolveNativeFolderListHit(UIView *list, CGPoint point,
                                         id stock, id *replacement, NSUInteger *index);

%group FXNativeListHitHooks
%hook SBIconListView
- (id)iconAtPoint:(CGPoint)point index:(NSUInteger *)index {
    id original = %orig;
    id replacement = nil;
    NSUInteger position = NSNotFound;
    if (FXResolveNativeFolderListHit((UIView *)self, point, original,
                                     &replacement, &position)) {
        if (index) *index = position;
        return replacement;
    }
    return original;
}
%end
%end

static void FXInstallListHitHook(NSUInteger attempt) {
    Class cls = NSClassFromString(@"SBIconListView");
    if (cls && class_getInstanceMethod(cls, @selector(iconAtPoint:index:))) {
        %init(FXNativeListHitHooks);
        return;
    }
    if (attempt >= 12) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ FXInstallListHitHook(attempt + 1); });
}
%ctor {
    dispatch_async(dispatch_get_main_queue(), ^{ FXInstallListHitHook(0); });
}
