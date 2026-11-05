'use strict';
/* FolderX read-only transition view-tree probe (Frida 16.x).
   Reads class names, layer opacity, and size; never invokes layout/mutations. */
(function () {
  if (typeof ObjC === 'undefined' || !ObjC.available) {
    console.log('[ERROR] Objective-C runtime not available');
    return;
  }
  var phase = 'idle';
  var last = 0;
  var printed = 0;
  var maxPrint = 45;
  function getter(o, name) {
    try { return o && o[name] ? o[name]() : null; } catch (e) { return null; }
  }
  function num(v) { var n = Number(v); return isFinite(n) ? n.toFixed(2) : '?'; }
  function info(v) {
    try {
      var b = getter(v, 'bounds');
      var layer = getter(v, 'layer');
      return String(v.$className) +
        ' b=' + (b ? num(b.size.width) + 'x' + num(b.size.height) : '?') +
        ' alpha=' + num(getter(v, 'alpha')) +
        ' opacity=' + num(getter(layer, 'opacity')) +
        ' hidden=' + String(getter(v, 'isHidden'));
    } catch (e) { return '(view data unavailable)'; }
  }
  function nativeImageHost(image) {
    var p = image;
    for (var i = 0; i < 10 && p; i++) {
      if (String(p.$className) === 'SBIconView') return p;
      p = getter(p, 'superview');
    }
    return null;
  }
  function emitTree(image) {
    var host = nativeImageHost(image);
    var icon = getter(host, 'icon');
    if (!icon || String(icon.$className).indexOf('FolderIcon') === -1) return;
    var sz = Number(getter(icon, 'gridSizeClass'));
    var bounds = getter(host, 'bounds');
    if (sz !== 1 && sz !== 2 && (!bounds || bounds.size.width < 100)) return;
    var now = Date.now();
    if (now - last < 200 || printed >= maxPrint) return;
    last = now;
    printed++;
    console.log('[FRAME] ' + phase + ' folderSizeClass=' + sz + ' host=' + info(host));
    console.log('   native=' + info(image));
    var count = 0;
    function recurse(v, depth) {
      if (!v || depth > 7 || count > 80) return;
      count++;
      var name = String(v.$className);
      if (depth > 0 && (/FXMiniGrid|PageGrid|Crossfade|CrossFade|FolderIcon|IconGrid|GridContainer/i).test(name)) {
        console.log('   ' + Array(depth+1).join('.') + info(v));
      }
      var children = getter(v, 'subviews');
      if (!children) return;
      try { for (var i=0; i<Math.min(25,children.count()); i++) recurse(children.objectAtIndex_(i),depth+1); }
      catch (e) {}
    }
    recurse(image,0);
    ['pageGridContainer','crossfadeScalingView','crossfadeFolderView'].forEach(function (name) {
      var value = getter(image,name);
      if (value && value.$className) console.log('   direct-' + name + '=' + info(value));
    });
  }
  function hook(className, methodName, callback, onLeave) {
    try {
      var klass = ObjC.classes[className];
      var m = klass && klass[methodName];
      if (!m) { console.log('[MISSING] ' + className + ' ' + methodName); return; }
      Interceptor.attach(m.implementation, onLeave ? {
        onEnter: function(args) { this.selfptr=args[0]; },
        onLeave: function() { try { callback(this.selfptr); } catch(e) {} }
      } : {
        onEnter: function(args) { try { callback(args[0]); } catch(e) {} }
      });
      console.log('[HOOKED] ' + className + ' ' + methodName);
    } catch(e) { console.log('[HOOK ERROR] ' + className + ' ' + methodName + ': ' + e); }
  }
  hook('SBHIconManager', '- folderControllerWillOpen:', function() { phase='OPEN'; console.log('[TRANSITION] OPEN'); });
  hook('SBHIconManager', '- folderControllerWillClose:', function() { phase='CLOSE'; console.log('[TRANSITION] CLOSE'); });
  hook('SBHIconManager', '- _folderDidFinishOpenClose:animated:success:', function() { console.log('[TRANSITION] CALLBACK ' + phase); });
  hook('SBFolderIconImageView', '- layoutSubviews', function(ptr) {
    if (phase === 'idle') return;
    try { emitTree(new ObjC.Object(ptr)); } catch(e) {}
  }, true);
  console.log('=== FOLDERX TRANSITION PROBE READY ===');
  console.log('Open and close ONE 2x2 or 4x2 folder twice, then Control+C.');
  console.log('Observation only; SpringBoard attachment still carries risk.');
})();
