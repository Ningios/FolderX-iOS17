#!/usr/bin/env python3
"""Static regression check, not an iPhone run or Theos build."""
from pathlib import Path
import re
p=Path(__file__).parent
s=(p/'FXCore.mm').read_text()
func=s.split('void FXLaunchApp(id leafIcon) {',1)[1].split('void FXRememberEditingForView(',1)[0]
assert 'NSString *const launchLocation = @"SBIconLocationFolder";' in func
assert 'call(leafIcon, nativeLaunch, launchLocation, nil);' in func
assert not re.search(r'call\(leafIcon,\s*nativeLaunch,\s*@\(',func)
assert 'sig.numberOfArguments == 4' in func
assert "[sig getArgumentTypeAtIndex:2][0] == '@'" in func
assert "[sig getArgumentTypeAtIndex:3][0] == '@'" in func
assert 'FXGridReadPolicy.xm' not in (p/'Makefile').read_text()
assert 'Version: 1.5.18' in (p/'control').read_text()
assert 'FXDragAppFrameGuard.xm' in (p/'Makefile').read_text()
print('PASS 1.5.18: crash-inducing NSNumber location removed, NSString folder location used, ABI checks preserved; no new global policy hook.')
