/* FolderX v10 event-driven lightweight diagnostic (Frida 16.1.x).
   Never changes an Objective-C return value, model, or view.
   Unlike v9, NO timer walks all UIWindows / no per-frame sampling.
   Cross-page scans are limited to the single native destination icon list.
*/
'use strict';
(function () {
  if (typeof ObjC === 'undefined' || !ObjC.available) {
    console.log('[FXLITE10] Objective-C runtime unavailable'); return;
  }
  var C = ObjC.classes;
  var iconView = C.SBIconView, listView = C.SBIconListView;
  var manager = C.SBHIconManager;
  var dest = C.SBIconListViewDraggingDestinationDelegate;
  function safe(f, alt) { try { return f(); } catch (e) { return alt; } }
  function name(v) { return safe(function(){ return String(v.$className); },'?'); }
  function adr(v) { return v ? safe(function(){return String(v.handle);},'-') : '-'; }
  function o(ptr) { return safe(function(){return new ObjC.Object(ptr);},null); }
  function str(v) { return safe(function(){return String(v);},'-'); }
  function num(v) { var x=Number(v); return isFinite(x)?x:NaN; }
  function rect(r) {
    var a=null;
    if (Array.isArray(r) && r.length===2 && Array.isArray(r[0]) && Array.isArray(r[1]))
      a=[r[0][0],r[0][1],r[1][0],r[1][1]];
    else if (Array.isArray(r) && r.length===4) a=r;
    else if (r && r.origin && r.size) a=[r.origin.x,r.origin.y,r.size.width,r.size.height];
    if (!a) return null;
    for (var i=0;i<4;i++) { a[i]=num(a[i]); if (!isFinite(a[i])) return null; }
    return a;
  }
  function fmt(a){ return a ? a.map(function(x){return x.toFixed(1);}).join(',') : '?'; }
  function rng(model,icon) {
    var v=safe(function(){return model.gridRangeForIcon_gridCellInfoOptions_(icon,0);},null);
    if (!v || !Array.isArray(v) || v.length<2 || !Array.isArray(v[1])) return '?';
    return String(v[0])+'/'+String(v[1][0])+'x'+String(v[1][1]);
  }
  function blockedInPreferences(icon) {
    var uid=safe(function(){return str(icon.uniqueIdentifier());},'');
    if (!uid || uid==='null') return '?';
    var d=safe(function(){return C.NSUserDefaults.alloc().initWithSuiteName_('com.huhansibuxin.folderx.fresh');},null);
    if (!d) return '?';
    return safe(function(){
      var map=d.dictionaryForKey_('folderOpenBlockedByIdentifier');
      if(!map) return 'NO';
      var value=map.objectForKey_(uid);
      return value && value.boolValue() ? 'YES' : 'NO';
    },'?');
  }
  function hook(k,method,label,callback) {
    var m=k && k['- '+method];
    if (!m) {console.log('[FXLITE10] MISSING '+label); return false;}
    Interceptor.attach(m.implementation,{onEnter:function(args){
      try {callback(args);} catch(e){console.log('[FXLITE10] ERROR '+label+' '+String(e).slice(0,90));}
    }});
    console.log('[FXLITE10] HOOKED '+label); return true;
  }
  var logPrefix='[FXLITE10] ';
  console.log('=== FOLDERX EVENT PROBE v10 light ===');
  hook(manager,'openFolderIcon:location:animated:withCompletion:','native-open-folder',function(args){
    var icon=o(args[2]);
    console.log(logPrefix+'OPEN entry=openFolderIcon class='+name(icon)+' size='+safe(function(){return icon.gridSizeClass().toString();},'?')+' blockedPref='+blockedInPreferences(icon));
  });
  hook(manager,'pushExpandedIcon:location:animated:completionHandler:','native-push-expanded',function(args){
    var icon=o(args[2]);
    console.log(logPrefix+'OPEN entry=pushExpandedIcon class='+name(icon)+' size='+safe(function(){return icon.gridSizeClass().toString();},'?')+' blockedPref='+blockedInPreferences(icon));
  });
  hook(C.SBFolderController,'viewWillAppear:','folder-will-appear',function(){
    console.log(logPrefix+'FOLDER OPEN animation started');
  });
  hook(C.SBFolderController,'viewDidDisappear:','folder-did-disappear',function(){
    console.log(logPrefix+'FOLDER CLOSE animation ended');
  });
  var pagesSeen={}, drag=0, ended=false;
  hook(iconView,'dragInteraction:itemsForBeginningSession:','drag-begin',function(args){
    if (ended) return;
    drag++; pagesSeen={};
    var iv=o(args[0]), icon=iv && safe(function(){return iv.icon();},null);
    console.log(logPrefix+'DRAG '+drag+' source='+name(icon)+' size='+safe(function(){return icon.gridSizeClass().toString();},'?'));
  });
  hook(iconView,'dragInteraction:session:didEndWithOperation:','drag-end',function(){
    console.log(logPrefix+'DRAG END '+drag);
    pagesSeen={};
  });
  function inspectList(list,stage) {
    if (!list || !listView || !safe(function(){return list.isKindOfClass_(listView);},false)) return;
    var model=safe(function(){return list.model();},null);
    var icons=[], visited=0;
    function walk(view,depth) {
      if (!view || depth>12 || ++visited>600) return;
      if (iconView && safe(function(){return view.isKindOfClass_(iconView);},false)) {
        var ic=safe(function(){return view.icon();},null);
        if (!ic) return;
        var folder=!!(C.SBFolderIcon && safe(function(){return ic.isKindOfClass_(C.SBFolderIcon);},false));
        var range=rng(model,ic);
        var frame=rect(safe(function(){return view.convertRect_toView_(view.bounds(),list);},null));
        var sz=safe(function(){return ic.gridSizeClass().toString();},'?');
        icons.push({folder:folder,range:range,frame:frame,size:sz});
        return;
      }
      var subs=safe(function(){return view.subviews();},null);
      var n=Math.min(safe(function(){return Number(subs.count());},0),100);
      for(var i=0;i<n;i++)walk(safe(function(){return subs.objectAtIndex_(i);},null),depth+1);
    }
    walk(list,0);
    var folders=icons.filter(function(x){return x.folder;});
    var apps=icons.filter(function(x){return !x.folder;});
    var bad=0, shrunk=0, unverified=0;
    folders.forEach(function(f){
      var large=/\/(2x2|4x2)$/.test(f.range);
      if (!large && Number(f.size)>=1)unverified++;
      if (large && f.frame && (f.frame[2]<98 || f.frame[3]<96))shrunk++;
    });
    apps.forEach(function(a){
      if(!a.frame)return;
      var area=a.frame[2]*a.frame[3];
      if(!area)return;
      folders.forEach(function(f){
        if(!f.frame || !/\/(2x2|4x2)$/.test(f.range))return;
        var overlapX=Math.max(0,Math.min(a.frame[0]+a.frame[2],f.frame[0]+f.frame[2])-Math.max(a.frame[0],f.frame[0]));
        var overlapY=Math.max(0,Math.min(a.frame[1]+a.frame[3],f.frame[1]+f.frame[3])-Math.max(a.frame[1],f.frame[1]));
        if(overlapX*overlapY>0.58*area)bad++;
      });
    });
    console.log(logPrefix+'PAGE '+stage+' folders='+folders.length+' apps='+apps.length+' visited='+visited+' shrunkViews='+shrunk+' appFolderOverlap='+bad+' unresolvedSize='+unverified);
    folders.forEach(function(f,i){console.log(logPrefix+'  F'+(i+1)+' model='+f.range+' class='+f.size+' frame='+fmt(f.frame));});
    if(bad)apps.forEach(function(a,i){console.log(logPrefix+'  A'+(i+1)+' model='+a.range+' frame='+fmt(a.frame));});
  }
  if(dest) hook(dest,'dropInteraction:sessionDidUpdate:','destination-page-event',function(args){
    if(ended || !drag)return;
    var interaction=o(args[2]), v=safe(function(){return interaction.view();},null);
    if (!v || !listView || !safe(function(){return v.isKindOfClass_(listView);},false))return;
    var key=adr(v); if(pagesSeen[key])return;
    pagesSeen[key]=1;
    console.log(logPrefix+'PAGE ENTER '+key+' (only 3 samples of THIS list)');
    var stamps=[0,350,850];
    stamps.forEach(function(ms){setTimeout(function(){
      ObjC.schedule(ObjC.mainQueue,function(){
        try{inspectList(v,'after-'+ms+'ms');}catch(e){console.log(logPrefix+'ERROR sampling '+String(e).slice(0,90));}
      });
    },ms);});
  });
  console.log(logPrefix+'READY: test blocked-folder tap OR one cross-page drag. Event-only; no continuous scans.');
})();
