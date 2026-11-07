from pathlib import Path
root=Path(__file__).resolve().parent
core=(root/'FXCore.mm').read_text()
ui=(root/'FXInterface.mm').read_text()
drop=(root/'FXDrop.xm').read_text()
menu=(root/'FXMenu.xm').read_text()
gate=core.split('BOOL FXShouldBlockFolderOpenIcon(id icon) {',1)[1].split('\n}',1)[0]
assert 'FXNativeDragIsActive()' not in gate
assert 'FXFolderEntryBlocked(icon)' in gate
assert 'FXIsGenuineLarge(icon)' in gate
view=ui.split('BOOL FXShouldBlockNativeFolderOpen(UIView *host) {',1)[1].split('\n}',1)[0]
assert 'FXNativeDragIsActive()' not in view
assert 'FXIsEditing(host)' not in view
assert 'FXShouldBlockFolderOpenIcon' in view
assert 'FXSuppressNativeFolderAction((UIView *)self)' in (root/'Tweak.xm').read_text()
assert 'if (FXShouldBlockFolderOpenIcon(icon)) return;' in menu
assert 'FXStartDragAppFrameGuard(nativeTargets, (UIView *)self);' in drop
assert 'FXExtendDragAppFrameGuard(newTargets, FXDraggedFolderHost);' in drop
assert 'FXSetDragVisualLockForHostNoPause' in drop
assert 'modelHasNonDefaultSizedIcons' not in (root/'Makefile').read_text()
assert not (root/'FXGridReadPolicy.xm').exists()
print('PASS: entry gate no longer bypasses on drag state; App & folder guard retained; model untouched')
