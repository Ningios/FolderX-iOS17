/* FolderX SpringBoard interface discovery — READ-ONLY.
 * Intended for Frida CLI REPL on a personally owned jailbroken iPhone.
 * No Interceptor, method calls, memory writes, or hook installation.
 * Only prints class/method names and Objective-C type encodings.
 */
'use strict';

console.log('=== FolderX 1.4.4 SpringBoard read-only method probe ===');
console.log('No methods will be invoked or replaced. No app names are collected.');
if (typeof ObjC === 'undefined' || !ObjC.available) {
    console.log('ERROR: Objective-C bridge is not available in this process.');
} else {
    const wanted = [
        'SBFolderController', 'SBRootFolderController', 'SBIconView',
        'SBFolderIcon', 'SBFolderIconImageView', 'SBIconListView',
        'SBIconListModel', 'SBIconController', 'SBIconManager',
        'SBIconListViewDraggingDestinationDelegate', 'SBIconDragManager'
    ];
    const interesting = /grid|size|cell|layout|folder|iconAtPoint|point.*icon|drag|drop|alpha|image|resize|moving/i;
    wanted.forEach((name) => {
        try {
            const klass = ObjC.classes[name];
            if (!klass) {
                console.log('\n[MISSING] ' + name);
                return;
            }
            console.log('\n[CLASS] ' + name + ' ' + (klass.$moduleName || ''));
            const methods = (klass.$methods || []).filter(x => interesting.test(x)).sort();
            methods.slice(0, 75).forEach((selector) => {
                let encoding = '';
                try {
                    const fn = klass[selector];
                    if (fn && fn.types) encoding = String(fn.types);
                } catch (_) { /* read-only error */ }
                console.log('  ' + selector + '  ' + encoding);
            });
            if (methods.length > 75) console.log('  ... ' + (methods.length - 75) + ' more methods');
        } catch (err) {
            console.log('[ERROR] ' + name + ': ' + err);
        }
    });
    console.log('\n[RELATED CLASS NAMES]');
    try {
        Object.keys(ObjC.classes).filter(name =>
            /^SB/.test(name) && /GridSize|IconGrid|Folder.*Controller|List.*Model/.test(name)
        ).slice(0, 70).sort().forEach(name => console.log('  ' + name));
    } catch (err) { console.log('Related names unavailable: ' + err); }
}
console.log('\n=== Probe complete; Ctrl+C to exit Frida ===');
