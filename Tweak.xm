#import "FXInterface.h"

// SpringBoard-native folder size and gesture extension:
//  1. Native list-model 1x1 <-> 2x2 occupancy, not frame scaling.
//  2. Right-bottom resize grip only while the icon is in edit mode.
//  3. Direct launch via a display-only nine-cell grid and native tap routing.
//  4. Native drag/drop target observation and guarded manager insertion.
// No folder snapshots, competing UIDropInteraction, or debug log writes.

%hook SBIconView

- (void)setIcon:(id)icon {
    %orig;
    FXRefreshIconView((UIView *)self);
}

- (void)setIcon:(id)icon animated:(BOOL)animated {
    %orig;
    FXRefreshIconView((UIView *)self);
}

- (void)layoutSubviews {
    %orig;
    FXRefreshIconView((UIView *)self);
}

- (void)setEditing:(BOOL)editing animated:(BOOL)animated {
    %orig;
    FXRememberEditingForView((UIView *)self, editing);
    FXRefreshIconView((UIView *)self);
}

// A native SBIconView can return its image view from hitTest before asking the
// transparent edit-only resize region. Give that precise region first refusal.
// Normal icon touches, folder long-press and drag remain owned by SpringBoard.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *corner = FXResizeHitView((UIView *)self, point, event);
    if (corner) return corner;
    return %orig;
}

- (void)tapGestureDidChange:(id)gesture {
    if (FXHandleFolderTap((UIView *)self, gesture)) return;
    if ([gesture isKindOfClass:UITapGestureRecognizer.class] &&
        [(UIGestureRecognizer *)gesture state] == UIGestureRecognizerStateEnded) {
        if (FXShouldBlockNativeFolderOpen((UIView *)self)) return;
        FXPrepareNativeFolderOpen((UIView *)self);
    }
    %orig;
}

- (void)_handleTap {
    if (FXSuppressNativeFolderAction((UIView *)self)) return;
    FXPrepareNativeFolderOpen((UIView *)self);
    %orig;
}

- (void)performTap {
    if (FXSuppressNativeFolderAction((UIView *)self)) return;
    FXPrepareNativeFolderOpen((UIView *)self);
    %orig;
}

%end

// SpringBoard frequently repaints the native folder's small thumbnail grid
// during edit-mode transitions. Hide only those thumbnails when the new
// transparent mini-grid is installed; leave the native folder background.
%hook SBFolderIconImageView

- (void)layoutSubviews {
    %orig;
    FXRefreshNativeImageView((UIView *)self);
}

%end
