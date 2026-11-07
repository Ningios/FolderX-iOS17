#ifndef FX_INTERFACE_H
#define FX_INTERFACE_H

#import "FXCore.h"

void FXRefreshIconView(UIView *host);
void FXRefreshNativeImageView(UIView *imageView);
void FXNeutralizeNativeGridAfterUpdate(UIView *imageView);
BOOL FXHandleFolderTap(UIView *host, id gesture);
BOOL FXSuppressNativeFolderAction(UIView *host);
void FXSetDropHoverForHost(UIView *host, BOOL hovered);
void FXPrepareNativeFolderOpen(UIView *host);
// Keep only a verified enlarged host visually stable during native icon drag.
void FXSetDragVisualLockForHost(UIView *host, BOOL locked);
// Release the native per-icon layout pause as soon as UIKit ends the drag.
void FXReleaseDragLayoutPauseForHost(UIView *host);
// Native presentation blocks resize; only the tapped icon yields rendering.
void FXSetNativeFolderPresentationActive(BOOL active);
// One actual model mutation path, shared by corner drag and context menu.
BOOL FXCommitSizeForHost(UIView *host, FXFolderSize size);
BOOL FXCommitSizeForIdentifier(NSString *uid, FXFolderSize size);
UIView *FXResizeHitView(UIView *host, CGPoint point, UIEvent *event);
BOOL FXResizeGestureActiveForHost(UIView *host);

#endif
