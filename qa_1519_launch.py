#!/usr/bin/env python3
from pathlib import Path
p=Path(__file__).parent
s=(p/'FXCore.mm').read_text()
ui=(p/'FXInterface.mm').read_text()
h=(p/'FXCore.h').read_text()
fragment=s.split('void FXLaunchApp(id leafIcon, UIView *sourceHost) {',1)[1].split('void FXRememberEditingForView(',1)[0]
assert 'FXLaunchApp(app, host)' in ui
assert 'void FXLaunchApp(id leafIcon, UIView *sourceHost)' in h
assert 'FXMakeNativeLaunchContext(sourceHost)' in fragment
assert 'if (context)' in fragment
assert 'invoke(leafIcon, nativeLaunch, location, context)' in fragment
assert 'FXLaunchAppFallback(bundleID)' in fragment
assert 'invoke(leafIcon, nativeLaunch, location, nil)' not in fragment
assert 'call(leafIcon, nativeLaunch, launchLocation, nil)' not in fragment
assert 'NSNumber' not in fragment
assert 'object_setIvar(context, settingsField, settings)' in s
assert 'object_setIvar(context, iconViewField, sourceHost)' in s
assert 'launchActivationSettingsForIconView:' in s
assert 'rangeOfString:@"(empty)"' in s
assert 'FXGridReadPolicy.xm' not in (p/'Makefile').read_text()
assert 'Version: 1.5.20' in (p/'control').read_text()
print('PASS: non-nil SBIconLaunchContext with SpringBoard settings or controlled fallback; no old nil-context launch.')
