#ifndef FX_INTERFACE_H
#define FX_INTERFACE_H

#import "FXCore.h"

// Drag-only App presentation guard; never writes model or folder geometry.
void FXStartDragAppFrameGuard(NSArray<NSDictionary *> *verifiedTargets, UIView *dragSource);
void FXExtendDragAppFrameGuard(NSArray<NSDictionary *> *verifiedTargets, UIView *dragSource);
void FXStopDragAppFrameGuard(void);
void FXRefreshIconView(UIView *host);
void FXRefreshNativeImageView(UIView *imageView);
BOOL FXHandleFolderTap(UIView *host, id gesture);
BOOL FXSuppressNativeFolderAction(UIView *host);
BOOL FXShouldBlockNativeFolderOpen(UIView *host);
void FXSetDropHoverForHost(UIView *host, BOOL hovered);
void FXPrepareNativeFolderOpen(UIView *host);
// Keep only a verified enlarged host visually stable during native icon drag.
void FXSetDragVisualLockForHost(UIView *host, BOOL locked);
// Dragged folder's source must remain movable: lock its image, not list layout.
void FXSetDragVisualLockForHostNoPause(UIView *host, BOOL locked);
// Release the native per-icon layout pause as soon as UIKit ends the drag.
void FXReleaseDragLayoutPauseForHost(UIView *host);
// Native presentation blocks resize; only the tapped icon yields rendering.
void FXSetNativeFolderPresentationActive(BOOL active);
// Size changes are initiated only by the bottom-right corner gesture.
BOOL FXCommitSizeForHost(UIView *host, FXFolderSize size);
UIView *FXResizeHitView(UIView *host, CGPoint point, UIEvent *event);
BOOL FXResizeGestureActiveForHost(UIView *host);

#endif
