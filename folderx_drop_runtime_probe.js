/* FolderX 1.4.5 read-only runtime selector check for Frida 16.1.4. */
'use strict';
(function () {
  console.log('=== FOLDERX DROP RUNTIME START ===');
  if (typeof ObjC === 'undefined' || !ObjC.available) {
    console.log('Objective-C unavailable'); return;
  }
  var classes = {
    SBIconView: [
      '- dragInteraction:itemsForBeginningSession:',
      '- dragInteraction:session:didEndWithOperation:'
    ],
    SBIconListView: ['- iconAtPoint:index:', '- dragHitRegionForPoint:icon:'],
    SBIconListViewDraggingDestinationDelegate: [
      '- dropInteraction:sessionDidUpdate:',
      '- dropInteraction:performDrop:',
      '- dropInteraction:sessionDidExit:'
    ],
    SBHIconManager: ['- addIcons:intoFolderIcon:openFolderOnFinish:completion:'],
    SBIconListModel: [
      '- gridRangeForIcon:gridCellInfoOptions:',
      '- changeGridSizeClassOfContainedIcon:toGridSizeClass:gridCellInfoOptions:'
    ]
  };
  Object.keys(classes).forEach(function (name) {
    var cls = ObjC.classes[name];
    console.log('[CLASS] ' + name + ': ' + (cls ? 'PRESENT' : 'MISSING'));
    if (!cls) return;
    var methods = cls.$methods || [];
    classes[name].forEach(function (sel) {
      var exists = methods.indexOf(sel) !== -1;
      // Some methods are inherited; Objective-C's respondsToSelector captures that.
      console.log('  ' + (exists ? 'YES ' : 'NO  ') + sel);
      if (exists) {
        try { console.log('    type=' + String(cls[sel].types)); }
        catch (e) { console.log('    type unreadable'); }
      }
    });
  });
  console.log('=== FOLDERX DROP RUNTIME COMPLETE ===');
})();
