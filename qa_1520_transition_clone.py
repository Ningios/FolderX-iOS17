#!/usr/bin/env python3
from pathlib import Path
p=Path(__file__).parent
ui=(p/'FXInterface.mm').read_text()
assert 'FXGuardTransitionCloneGrid' in ui
assert 'FXObject(original, @"icon") != folder' in ui
assert '!FXRootListForHost(original)' in ui
assert '!FXIsYieldingToNativeOpen(original)' in ui
assert 'FXRootListForHost(host) != nil' in ui
assert 'FXSetTransitionCloneGridAlpha(grid, 0.0)' in ui
assert 'FXSetTransitionCloneGridAlpha(grid, 1.0)' in ui
assert 'FXGuardTransitionCloneGrid(host, icon, overlay);\n        overlay.hidden = NO;' in ui
assert 'FXGuardTransitionCloneGrid(host, icon, oldOverlay);' in ui
# Direct model/geometry, app launch and drag files remain from 1.5.19.
print('PASS: exact-model transition clone guard, real-list release, pre-show mutation')
