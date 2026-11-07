#!/usr/bin/env python3
"""Local source-only smoke checks. Not an iOS runtime or Theos compile."""
from pathlib import Path
import math,re
root=Path(__file__).parent
src={f.name:f.read_text() for f in root.iterdir() if f.suffix in {'.mm','.xm','.h'}}
alltext='\n'.join(src.values()); ui=src['FXInterface.mm']; transition=src['FXTransition.xm']; core=src['FXCore.mm']
expected={'Tweak.xm','FXCore.mm','FXDrop.xm','FXInterface.mm','FXMenu.xm','FXTransition.xm'}
assert expected.issubset(src), expected-set(src)
for token in ('changeGridSizeClassOfContainedIcon:toGridSizeClass:gridCellInfoOptions:',
              'gridRangeForIcon:gridCellInfoOptions:', 'FXResizeHitView',
              'FXNativeFolderIsPresented', 'FXSetNativeThumbnailVisibility',
              'FXCanUseWideGrid', 'FXPreflightExpansion'):
    assert token in alltext, token
assert 'FXSetNativeFolderPresentationActive(NO);' not in transition.split('- (void)viewWillDisappear:')[1].split('- (void)viewDidDisappear:')[0], 'premature close handoff'
assert 'FXCompleteIfAllControllersGone();' in transition.split('- (void)viewDidDisappear:')[1], 'missing final handoff'
assert 'FXPresentedControllers()' in transition, 'multi-folder controller ownership must be counted'
assert 'BOOL geometrySettled' in ui and 'BOOL suppressNative' in ui, 'native/host layout handshake absent'
assert 'FXSetNativeThumbnailVisibility(nativeImage, suppressNative)' in ui
# Regression: the old global presentation toggle must never hide every folder.
assert 'BOOL transitionOwner = FXIsYieldingToNativeOpen(host);' in ui
assert 'FXParkGridOnIconHost' not in ui
assert 'BOOL showOverlay = pinnedTransitionGrid ||' in ui
assert 'BOOL suppressNative = showOverlay ||' in ui
assert 'if (!wasPresented) return;' in ui
assert 'wasYielding && host.window' in ui and 'kFXNativeOpenPendingKey, openedUID' in ui
# Regression: the edit-only corner gesture must have a guarded wide target.
assert 'if (FXCanUseWideGrid()) target = FXFolderSizeWide;' in ui
assert 'else if (self.startSize == FXFolderSizeWide)' in ui
assert 'kFXPageOriginalAlphaKey' in ui and 'kFXNativeAlphaMutationKey' in ui, 'native redraw protection absent'
assert 'FXReadNativeGridAlpha' in ui and 'signature.numberOfArguments == 3' in ui
assert 'self.gridColumns == 6 ? 12 : 9' in ui and 'NSUInteger columns = wide ? 6 : 3;' in ui
assert 'NSUInteger rows = wide ? 2 : 3;' in ui and 'if (out.count >= 12) break;' in core and 'listAtIndex(folder, listSelector, i)' in core
assert 'for (NSNumber *delay in @[@(0.18), @(0.5)])' not in ui, 'old delayed refresh still present'
assert '[host layoutIfNeeded];' not in ui.split('BOOL FXCommitSizeForHost(')[1].split('void FXSetNativeFolderPresentationActive')[0], 'nested size transaction still forced'
assert 'UIDropInteraction alloc' not in alltext and 'FXSnapshot' not in alltext
assert 'fopen(' not in alltext and 'debug.log' not in alltext
for name,text in src.items():
    code=re.sub(r'/\*.*?\*/|//[^\n]*|@?"(?:\\.|[^"\\])*"|\x27(?:\\.|[^\x27\\])*\x27','',text,flags=re.S)
    closing={'(':')','[':']','{':'}'};stack=[]
    for c in code:
        if c in closing:stack.append(closing[c])
        elif c in ')]}':
            assert stack and stack.pop()==c,(name,'unmatched',c)
    assert not stack,(name,'unclosed')
    assert code.count('%hook')<=code.count('%end'),(name,'Logos end')
# Mirror the geometry calculations in FXMiniGrid for 2x2 and wide 4x2.
def grid(w,h,cols,rows):
    wide=cols==6
    mx=round(w*(.045 if wide else .095)); my=round(h*(.115 if wide else .095))
    gx=round(w*(.033 if wide else .076)); gy=round(h*(.095 if wide else .076))
    cell=math.floor(max(0,min((w-2*mx-(cols-1)*gx)/cols,(h-2*my-(rows-1)*gy)/rows)))
    x=(w-(cols*cell+(cols-1)*gx))/2; y=(h-(rows*cell+(rows-1)*gy))/2
    cells=[(round(x+(i%cols)*(cell+gx)),round(y+(i//cols)*(cell+gy)),cell,cell) for i in range(cols*rows)]
    assert len(cells)==cols*rows
    assert all(a>=0 and b>=0 and a+c<=w and b+d<=h for a,b,c,d in cells)
    assert len(set((a,b) for a,b,_,_ in cells))==cols*rows
    return cell
sq=grid(158,158,3,3); wide=grid(330,158,6,2)
assert 32<=sq<=37,(sq,wide)
assert 36<=wide<=44,(sq,wide)
print(f'PASS: source delimiters/hooks, lifecycle ordering, per-folder preview and guarded wide gesture, no snapshots/logs, square={sq}pt, wide={wide}pt 2x6')
print('NOT TESTED: Theos compile / real SpringBoard transitions / native 4x2 class or drop acceptance')

# 1.4.5 Frida-confirmed native method spelling + no visual-only authorization.
drop=src['FXDrop.xm']
assert 'addIcons:intoFolderIcon:openFolderOnFinish:completion:' in drop
assert 'addIcons:intoFolderIcon:openFolderOnFinish:complete:' not in drop
assert 'FXCaptureNativeTargets(selfView.window)' in drop
assert 'FXCachedTargetForList(list, point)' in drop
assert 'FXListModel(current)' in drop


# 1.4.7 lifecycle / drag preview / native handoff guards.
assert 'FXNativeClosePending' in transition and 'FXNativeCloseFinished' in transition
assert '_folderDidFinishOpenClose:(BOOL)opened animated:(BOOL)animated success:(BOOL)success' in transition
assert 'FXStabilizeNativeImageDuringDrag(view, actualImage)' in ui
assert 'FXSetDragVisualLockForHost' in ui and 'kFXDragVisualLockKey' in ui
assert 'FXNativeHandoffSubmittedGeneration' in drop
assert 'FXSetDragVisualLockForHost(host, YES)' in drop
source_hook = drop.split('- (id)dragInteraction:')[1].split('return result;')[0]
assert source_hook.index('FXSetDragVisualLockForHost') < source_hook.index('id result = %orig;'), 'drag visual lock installed too late'
perform = drop.split('- (void)dropInteraction:(UIDropInteraction *)interaction performDrop:')[1].split('%end')[0]
assert perform.index('%orig;') < perform.index('dispatch_async(dispatch_get_main_queue()'), 'native drop original must execute first'
assert 'FXReconcileAfterNativeDrop(source, folder, uid, bundleID, generation)' in perform
assert 'FXFolderHasApp(currentFolder, uid, bundleID)' in drop
assert 'FXNativeHandoffSubmittedGeneration = generation' in drop
assert 'FXSetHoveredHost(nil);' in perform
assert 'FXSnapshot' not in alltext and 'fopen(' not in alltext
print('PASS: drag-start visual lock, original UIKit drop preserved, early native manager handoff, once-per-drag guard, manager-close gate')

# 1.4.8: manager open-completion must never release a close-pending visual.
assert 'if (FXNativeClosePending && !opened)' in transition
assert 'if (FXNativeClosePending) {' not in transition, 'opening completion may release close too early'
print('PASS: folder close completion is gated on !opened')

# 1.5.0: One native image tree supplies both steady and zoom preview.
assert 'FXParkGridOnIconHost' not in ui
assert 'if (!pinnedTransitionGrid)' in ui
assert 'FXLaunchApp(app, host);' in ui
assert 'sig.methodReturnType[0]' in core and 'launchFromLocation:context:' in core
assert 'if (active) return;' in ui
assert 'BOOL hide = (visible && visible.superview && !visible.hidden)' in ui
assert 'if (nativeImage && overlay.superview != nativeImage)' in ui
assert '[nativeImage addSubview:overlay];' in ui
assert '[host addSubview:overlay];' not in ui
assert 'FXPreviewColumns(icon, host)' in ui
assert 'FXRecentlyHandledApp(host, app)' in ui
assert 'FXMarkHandled(host, app)' in ui
print('PASS: 1.5.0 single native image-tree for transitions and per-App tap guard; drag and size logic unchanged')

# 1.5.5: page-wide nondefault-size policy caused the 1.5.4 regression.
assert 'FXNativeDragGridPolicyHooks' not in drop
assert 'modelHasNonDefaultSizedIcons' not in drop
assert 'setModelHasNonDefaultSizedIcons' not in drop
assert 'FXNativeDragListHasVerifiedLargeFolder' not in drop
assert 'if (eligible && FXNativeDragIsActive()) FXClearSource();' in drop
assert 'if (genuineLarge && allowPause) FXAcquireDragLayoutPause(host, icon);' in ui
assert 'FXWasCapturedWideHost' in drop and 'FXCachedTargetForList(list, point)' in drop
hover = ui.split('- (void)setDropHovered:(BOOL)hovered {',1)[1].split('- (void)launchAtPoint:',1)[0]
assert 'borderWidth = hovered' not in hover and 'CABasicAnimation' not in hover
assert 'systemBlue' not in hover and 'self.layer.borderWidth = 0.0;' in hover
assert 'FXSetHoveredHost(nil);' in drop
print('PASS: 1.5.4 intrusive page hooks absent; repeat-drag reset before capture, native per-view guard restored, no blue ring, 4x2 target kept')

# 1.5.7 emergency rollback: edit layout policy is NOT installed.
assert not (root / 'FXEditLayout.xm').exists()
assert 'FXEditLayout.xm' not in (root / 'Makefile').read_text()
assert 'modelHasNonDefaultSizedIcons' not in '\n'.join(v for k,v in src.items() if k != 'FXGridReadPolicy.xm')
assert 'FXNativeDragLayoutInFlight' not in '\n'.join(src.values())
assert 'FXReleaseDragLayoutPauseForHost((UIView *)self);' not in src['Tweak.xm']
assert 'FXSetHoveredHost(nativePermitsDrop ? folderHost : nil)' in drop
assert 'FXAcquireDragLayoutPause' in ui # original 1.5.5 drag handling unchanged
assert '@property (nonatomic) BOOL dropHovered;' in ui
assert 'cell.alpha = self.dropHovered ? 0.48 : 1.0;' in ui
assert 'for (FXAppCell *cell in self.cells) cell.alpha = targetAlpha;' in ui
assert 'FXGridOf(' not in hover and 'setGridSizeClass' not in hover
print('PASS: no failed global grid policy or list hit override; hover-cell opacity preserved')

# 1.5.10 safety/one-variable regression guards.
assert not (root/'FXListHit.xm').exists()
assert not (root/'FXEditLayout.xm').exists()
assert 'FXListHit.xm' not in (root/'Makefile').read_text()
assert 'FXEditLayout.xm' not in (root/'Makefile').read_text()
assert 'FXResolveNativeFolderListHit' not in alltext
assert 'iconAtPoint:(CGPoint)point index:' not in alltext
assert 'FXNativeDragGridPolicyHooks' not in alltext
assert 'modelHasNonDefaultSizedIcons' not in ''.join(src.values())
assert 'modelHasNonDefaultSizedIcons' not in '\n'.join(v for k,v in src.items() if k != 'FXGridReadPolicy.xm')
assert 'FXAcquireDragLayoutPause(host, icon)' in ui
assert 'FXReleaseDragLayoutPauseForHost(host)' in drop
assert 'FXDragLayoutLease' in ui
assert 'FXSetDropHoverForHost' in drop
assert 'cell.alpha = self.dropHovered ? 0.48 : 1.0;' in ui
assert 'for (FXAppCell *cell in self.cells) cell.alpha = targetAlpha;' in ui
assert 'FXChangeSize' not in drop
print('PASS: native per-icon pause retained; no list hit override; 2x2/4x2 hover and native drop preserved')

## 1.5.12: v8-confirmed transient App view displacement only.
assert not (root/'FXGridReadPolicy.xm').exists()
assert 'FXGridReadPolicy.xm' not in (root/'Makefile').read_text()
assert 'FXDragAppFrameGuard.xm' in (root/'Makefile').read_text()
assert 'modelHasNonDefaultSizedIcons' not in '\n'.join(src.values())
guard=src['FXDragAppFrameGuard.xm']
assert 'FXGridOf(model, icon)' in guard
assert 'appRange.gridCellIndex != snap.cellIndex' in guard
assert 'current.gridCellIndex != zone.occupiedRange.gridCellIndex' in guard
assert 'FXRejectTransientAppPosition' in guard
assert '- (void)setFrame:(CGRect)frame' in guard
assert '- (void)setCenter:(CGPoint)center' in guard
assert 'FXChangeSize' not in guard and 'setGridSizeClass' not in guard
assert 'setNeedsLayout' not in guard and 'layoutIfNeeded' not in guard
assert 'FXStartDragAppFrameGuard(nativeTargets, (UIView *)self);' in drop
assert 'FXStopDragAppFrameGuard();' in drop
assert 'FXAcquireDragLayoutPause(host, icon)' in ui
assert 'FXReleaseDragLayoutPauseForHost(host)' in drop
assert 'cell.alpha = self.dropHovered ? 0.48 : 1.0;' in ui
print('PASS 1.5.12: verified-App transient overlap guard only; folder model and 2x2/4x2 size never modified')

# 1.5.13: source-folder drag, incoming page and menu toggle; read-only diagnostics.
assert 'FXDraggedFolder = FXIsFolder(icon) ? icon : nil;' in drop
assert 'FXSetDragVisualLockForHostNoPause(host, YES);' in drop
assert 'FXExtendActiveDragProtectionForList(interaction.view);' in drop
assert '%group FXIncomingPageProtectionHooks' in drop
assert 'FXExtendActiveDragProtectionForList((UIView *)self);' in drop
assert 'FXExtendDragAppFrameGuard(newTargets, FXDraggedFolderHost);' in drop
assert 'FXStopDragAppFrameGuard();' in drop
assert 'FXSetDragVisualLockForHostNoPause' in ui
assert 'FXFolderEntryBlocked' in core and 'FXSetFolderEntryBlockedByIdentifier' in core
assert 'FXShouldBlockNativeFolderOpen' in ui and 'FXHandleFolderTap(host' in ui
menu=src['FXMenu.xm']
assert '禁止进入文件夹' in menu and 'blockOpen.state' in menu
assert '文件夹大小' not in menu and 'FXCommitSizeForIdentifier' not in menu
assert 'FXCommitSizeForHost(host, size)' in ui and 'FXCornerHandle' in ui
assert 'FXChangeSize' not in drop and 'changeGridSizeClassOfContainedIcon' not in drop
assert 'modelHasNonDefaultSizedIcons' not in drop
assert (root/'folderx_event_probe_v10_light.js').exists()
print('PASS 1.5.13: folder-source visual protection without pinning dragged source; incoming-page extension; per-folder entry toggle; 1.5.12 guard intact')

# 1.5.14: reproduce v9 folder-source view jump; native folder manager gate.
assert 'NSArray<NSDictionary *> *nativeTargets = eligible ?' in drop
assert 'if (nativeTargets.count)' in drop and 'FXStartDragAppFrameGuard(nativeTargets, (UIView *)self);' in drop
assert 'if (FXDraggedLeaf || FXDraggedFolder)' in drop
assert 'FXExtendDragAppFrameGuard(newTargets, FXDraggedFolderHost);' in drop
guard=src['FXDragAppFrameGuard.xm']
assert 'FXLastAppSampleByList' in guard and 'now - last.doubleValue < 0.40' in guard
assert 'overlap.size.width * overlap.size.height > 0.12 * area' in guard
assert 'FXChangeSize' not in guard and 'setGridSizeClass' not in guard
assert 'FXShouldBlockFolderOpenIcon(id icon)' in core
assert 'FXNativeDragIsActive()' not in core.split('BOOL FXShouldBlockFolderOpenIcon')[1].split('void FXSetFolderEntryBlockedByIdentifier')[0]
assert '%group FXManagerOpenFolderGate' in menu and '%group FXManagerPushFolderGate' in menu
assert 'FXShouldBlockFolderOpenIcon(icon)' in menu
assert 'FXChangeSize' not in drop and 'FXChangeSize' not in menu
print('PASS 1.5.15: folder-source App guard and native entry gate without stale-drag bypass, no size mutation')

# 1.5.16: native temporary model is only bypassed for verified incoming App
# drags on a DIFFERENT page. This is not a global nonDefault policy hook.
assert 'FXIncomingTemporaryModelGuardHooks' in drop
assert 'FXDraggedOriginList' in drop and 'FXDraggedOriginModel' in drop
assert 'list == FXDraggedOriginList' in drop and 'model == FXDraggedOriginModel' in drop
assert 'wide == 2 && large == 1' in drop
assert 'occupiedMask & mask' in drop and 'r.gridCellIndex >= 24' in drop
assert 'FXDraggedLeaf' in drop and 'FXDraggedFolder' in drop
assert 'FXDragNativeFinalizing = YES; // Resume original temporary model before drop.' in drop
assert 'FXDragNativeFinalizing = YES; // Allow original regen on cancel/end too.' in drop
assert 'FXDragNativeFinalizing ||' in drop
assert 'FXDraggedOriginList.bounds.size.height < 650' in drop
assert 'class_getInstanceMethod(listClass,' in drop
assert 'regenerateTemporaryDisplayedModelIfNecessary {' in drop
assert 'if (FXCanSkipIncomingTemporaryRegen((UIView *)self)) return;' in drop
assert 'FXCanSkipIncomingTemporaryRegen' not in src['FXCore.mm']
assert 'modelHasNonDefaultSizedIcons' not in drop
assert 'FXGridReadPolicy' not in alltext and 'FXEditLayout' not in alltext
assert 'FXBeginNativeDrag(possibleSource, sourceUID, bundleID, originList, originModel' in drop
assert 'FXClearSource(void) {' in drop and 'FXDraggedOriginModel = nil;' in drop
print('PASS: incoming App-only/other-page/native-grid-verified temp model guard, original drag/entry UI untouched')
