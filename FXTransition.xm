#import "FXInterface.h"
#import "FXDiag.h"
#import <dispatch/dispatch.h>


// Folder opening/closing is a UIViewController lifecycle, not a fixed timer.
// Maintain native ownership THROUGH the close transition of the opened icon,
// then unfreeze only that icon after the close completes. Neighbors stay expanded.
// A single boolean may be cleared by an intermediate folder controller while
// another folder is still on screen. Keep a weak set of controllers that have
// entered presentation and not yet completed disappearance.
static NSHashTable *FXPresentedFolderControllers = nil;
static BOOL FXNativeClosePending = NO;
static BOOL FXNativeCloseFinished = NO;
static BOOL FXManagerCompletionHookInstalled = NO;
static NSUInteger FXCloseSequence = 0;
static void FXCompleteIfAllControllersGone(void) {
    if ([[FXPresentedFolderControllers allObjects] count] == 0 &&
        (!FXManagerCompletionHookInstalled || !FXNativeClosePending || FXNativeCloseFinished)) {
        FXNativeClosePending = NO;
        FXNativeCloseFinished = NO;
        FXSetNativeFolderPresentationActive(NO);
    }
}
static BOOL FXIsNativeFolderController(id controller) {
    Class root = NSClassFromString(@"SBRootFolderController");
    return !root || ![controller isKindOfClass:root];
}
static NSHashTable *FXPresentedControllers(void) {
    if (!FXPresentedFolderControllers)
        FXPresentedFolderControllers = [NSHashTable weakObjectsHashTable];
    return FXPresentedFolderControllers;
}

%group FXNativeFolderTransitionHooks
%hook SBFolderController
- (void)viewWillAppear:(BOOL)animated {
    if (FXIsNativeFolderController(self)) {
        [FXPresentedControllers() addObject:self];
        FXSetNativeFolderPresentationActive(YES);
        FXDiagEvent(@"ctrl.willAppear", @{@"animated": @(animated),
                                          @"count": @(FXPresentedControllers().allObjects.count)});
    }
    %orig;
}
- (void)viewWillDisappear:(BOOL)animated {
    // Crucial: do not restore the custom large grid here. The native folder
    // still has an active close animation. Do not change the live image-tree
    // contents or unfreeze its layout in the middle of that animation.
    if (FXIsNativeFolderController(self))
        FXDiagEvent(@"ctrl.willDisappear", @{@"animated": @(animated)});
    %orig;
}
- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    if (FXIsNativeFolderController(self)) {
        [FXPresentedControllers() removeObject:self];
        FXDiagEvent(@"ctrl.didDisappear", @{@"animated": @(animated),
                                            @"left": @(FXPresentedControllers().allObjects.count),
                                            @"closePending": @(FXNativeClosePending),
                                            @"closeFinished": @(FXNativeCloseFinished)});
        FXCompleteIfAllControllersGone();
    }
}
%end
%end

static void FXInstallFolderTransitionHooks(NSUInteger attempt) {
    Class cls = NSClassFromString(@"SBFolderController");
    if (cls && class_getInstanceMethod(cls, @selector(viewWillAppear:)) &&
        class_getInstanceMethod(cls, @selector(viewWillDisappear:)) &&
        class_getInstanceMethod(cls, @selector(viewDidDisappear:))) {
        %init(FXNativeFolderTransitionHooks);
        return;
    }
    if (attempt >= 12) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ FXInstallFolderTransitionHooks(attempt + 1); });
}
%ctor {
    FXDiagInstall();
    dispatch_async(dispatch_get_main_queue(), ^{ FXInstallFolderTransitionHooks(0); });
}

// On iOS 17.1.1 viewDidDisappear: may precede the manager's final close
// animation callback. Restoring the custom large preview at that point makes
// tiny icons flash behind the closing folder. Wait for BOTH signals.
%group FXNativeManagerCompletionHooks
%hook SBHIconManager
- (void)folderControllerWillClose:(id)controller {
    if (FXIsNativeFolderController(controller)) {
        FXDiagEvent(@"mgr.willClose", @{@"openControllers": @(FXPresentedControllers().allObjects.count)});
        FXNativeClosePending = YES;
        FXNativeCloseFinished = NO;
        NSUInteger sequence = ++FXCloseSequence;
        // Watchdog only: never use a guessed duration for a normal handoff.
        // This avoids leaving the home screen permanently in presentation
        // mode if a particular SpringBoard build omits the finish callback.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (sequence == FXCloseSequence && FXNativeClosePending) {
                FXNativeCloseFinished = YES;
                FXCompleteIfAllControllersGone();
            }
        });
    }
    %orig;
}
- (void)_folderDidFinishOpenClose:(BOOL)opened animated:(BOOL)animated success:(BOOL)success {
    %orig;
    FXDiagEvent(@"mgr.didFinishOpenClose", @{@"opened": @(opened), @"success": @(success),
                                             @"pending": @(FXNativeClosePending)});
    // The selector is shared by *both* opening and closing. During a fast
    // open/close sequence an opening completion can arrive while a close is
    // pending. Counting that as close completion would restore the custom
    // large grid before SpringBoard's native closing preview is gone,
    // producing the two overlapping icon grids seen on the Home Screen.
    // Never complete a pending close from an opening callback.
    if (FXNativeClosePending && !opened) {
        FXNativeCloseFinished = YES;
        FXCompleteIfAllControllersGone();
    }
}
%end
%end

static void FXInstallManagerCompletionHooks(NSUInteger attempt) {
    Class cls = NSClassFromString(@"SBHIconManager");
    if (cls && class_getInstanceMethod(cls, @selector(folderControllerWillClose:)) &&
        class_getInstanceMethod(cls, @selector(_folderDidFinishOpenClose:animated:success:))) {
        FXManagerCompletionHookInstalled = YES;
        %init(FXNativeManagerCompletionHooks);
        return;
    }
    if (attempt >= 12) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ FXInstallManagerCompletionHooks(attempt + 1); });
}
%ctor {
    dispatch_async(dispatch_get_main_queue(), ^{ FXInstallManagerCompletionHooks(0); });
}
