/* FolderX 1.5.15 — v11 event-driven, READ-ONLY trace for Frida 16.x.
 * Captures the first model-verified expanded-folder view shrinking to 1x1
 * during cross-page native drag, without scanning every UIWindow.
 * No return values/frames/models modified. Try one drag then stop.
 */
'use strict';
(function () {
  if (typeof ObjC === 'undefined' || !ObjC.available) {
    console.log('[FXCALL11] Objective-C bridge not available'); return;
  }
  var C = ObjC.classes;
  var listClass = C.SBIconListView, iconViewClass=C.SBIconView;
  var folderClass=C.SBFolderIcon;
  var active=false, source='-', generation=0, seenPages={}, loggedShrinks={}, maxSetterReports=6;
  function safe(fn, fallback) {try {return fn();} catch (_e) {return fallback;}}
  function obj(p) {return safe(function(){return new ObjC.Object(p);},null);}
  function n(x){return Number(x);}
  function rect(v) {
    var x=null;
    if (Array.isArray(v)&&v.length===2&&Array.isArray(v[0])&&Array.isArray(v[1])) x=[v[0][0],v[0][1],v[1][0],v[1][1]];
    else if (Array.isArray(v)&&v.length===4) x=v;
    else if (v&&v.origin&&v.size) x=[v.origin.x,v.origin.y,v.size.width,v.size.height];
    if (!x) return null;
    x=x.map(n);return x.every(function(z){return isFinite(z);})?x:null;
  }
  function fmt(x){return x?x.map(function(v){return v.toFixed(1);}).join(','):'?';}
  function kind(icon){return folderClass&&icon&&safe(function(){return icon.isKindOfClass_(folderClass);},false);}
  function address(x){return safe(function(){return String(x.handle);},'-');}
  function listFor(view){
    var p=safe(function(){return view.superview();},null), hops=0;
    while(p&&hops++<10) {
      if(listClass&&safe(function(){return p.isKindOfClass_(listClass);},false))return p;
      p=safe(function(){return p.superview();},null);
    }
    return null;
  }
  function range(m,icon){
    var r=safe(function(){return m.gridRangeForIcon_gridCellInfoOptions_(icon,0);},null);
    if (Array.isArray(r)&&r.length>=2&&Array.isArray(r[1]))return String(r[0])+'/'+String(r[1][0])+'x'+String(r[1][1]);
    return '?';
  }
  function large(r){return /\/(2x2|4x2)$/.test(r);}
  function getFolderInfo(view){
    var icon=safe(function(){return view.icon();},null);
    if(!kind(icon))return null;
    var list=listFor(view), model=safe(function(){return list.model();},null);
    var r=range(model,icon);
    if(!large(r))return null;
    var nativeFrame=rect(safe(function(){return view.frame();},null));
    var localFrame=rect(safe(function(){return view.convertRect_toView_(view.bounds(),list);},null));
    return {r:r,frame:nativeFrame,local:localFrame,list:list,view:view};
  }
  function log(s){console.log('[FXCALL11] '+s);}
  function traceAddress(ptrValue){
    return safe(function(){
      var a=ptr(ptrValue);var m=Process.findModuleByAddress(a);
      if(m)return m.name+'+'+a.sub(m.base).toString();
      return String(DebugSymbol.fromAddress(a));
    },'?');
  }
  function hook(cls,method,name,onEnter,onLeave){
    var m=cls&&cls['- '+method];
    if (!m) {log('MISSING '+name);return false;}
    Interceptor.attach(m.implementation,{onEnter:function(args){
      try {if(onEnter)onEnter.call(this,args);}catch(e){log('ERROR '+name+': '+String(e).slice(0,80));}
    },onLeave:function(ret){
      try {if(onLeave)onLeave.call(this,ret);}catch(e){log('ERROR '+name+': '+String(e).slice(0,80));}
    }});
    log('HOOKED '+name);return true;
  }
  function scanPage(list,stage){
    if (!list||!listClass||!safe(function(){return list.isKindOfClass_(listClass);},false))return;
    var folders=[],apps=0,visited=0;
    function walk(v,depth){
      if(!v||depth>10||++visited>280)return;
      if(iconViewClass&&safe(function(){return v.isKindOfClass_(iconViewClass);},false)) {
        var ic=safe(function(){return v.icon();},null);
        if(kind(ic)) {
          var range0=range(safe(function(){return list.model();},null),ic);
          if(large(range0)){
            var f=rect(safe(function(){return v.convertRect_toView_(v.bounds(),list);},null));
            folders.push({model:range0,frame:f});
          }
        }else if(ic)apps++;
        return;
      }
      var children=safe(function(){return v.subviews();},null);
      var count=Math.min(70,safe(function(){return Number(children.count());},0));
      for(var i=0;i<count;i++)walk(safe(function(){return children.objectAtIndex_(i);},null),depth+1);
    }
    walk(list,0);
    var bad=folders.filter(function(f){return f.frame&&(f.frame[2]<98||f.frame[3]<95);});
    log('PAGE '+stage+' folders='+folders.length+' apps='+apps+' shrunk='+bad.length+' visited='+visited);
    folders.forEach(function(f,i){log('F'+(i+1)+' model='+f.model+' view='+fmt(f.frame));});
  }
  function settings(icon){
    return safe(function(){
      var uid=icon.uniqueIdentifier();
      var defaults=C.NSUserDefaults.alloc().initWithSuiteName_('com.huhansibuxin.folderx.fresh');
      var d=defaults.dictionaryForKey_('folderOpenBlockedByIdentifier');
      if(!d)return 'NO';var v=d.objectForKey_(uid);return v&&v.boolValue()?'YES':'NO';
    },'?');
  }
  log('=== FOLDERX LAYOUT CALLER PROBE v11 (low overhead) ===');
  hook(iconViewClass,'dragInteraction:itemsForBeginningSession:','native-drag-begin',function(args){
    var view=obj(args[0]),icon=view&&safe(function(){return view.icon();},null);
    generation++;active=true;source=kind(icon)?'folder':'app';seenPages={};loggedShrinks={};maxSetterReports=6;
    log('DRAG START '+generation+' '+source);
  },null);
  hook(iconViewClass,'dragInteraction:session:didEndWithOperation:','native-drag-end',function(){
    active=false;log('DRAG END '+generation);
  },null);
  hook(C.SBHIconManager,'openFolderIcon:location:animated:withCompletion:','native-folder-open',function(args){
    var icon=obj(args[2]);log('OPEN preference='+settings(icon)+' sessionActive='+active+' source='+source);
  },null);
  hook(C.SBFolderController,'viewWillAppear:','folder-open-animation',function(){log('FOLDER CONTROLLER appeared');},null);
  var own=safe(function(){return iconViewClass.$ownMethods||[];},[]);
  ['setFrame:','setCenter:'].forEach(function(sel){
    var full='- '+sel;
    if(own.indexOf(full)<0){log('SKIP '+sel+' (not an SBIconView own method; avoid global UIView hook)');return;}
    hook(iconViewClass,sel,'source-'+sel,function(args){
      if(!active||maxSetterReports<=0)return;
      this.inspectView=args[0];this.callerAddress=this.returnAddress;
    },function(){
      if(!this.inspectView||!active||maxSetterReports<=0)return;
      var iv=obj(this.inspectView),data=iv&&getFolderInfo(iv);
      if(!data||!data.frame||data.frame[2]>=98||data.frame[3]>=95)return;
      var key=address(iv);
      if(loggedShrinks[key])return;
      loggedShrinks[key]=1;maxSetterReports--;
      log('SHRINK by='+sel+' model='+data.r+' frame='+fmt(data.frame)+' list='+address(data.list)+' caller='+traceAddress(this.callerAddress));
    });
  });
  hook(C.SBIconListViewDraggingDestinationDelegate,'dropInteraction:sessionDidUpdate:','target-page-enter',function(args){
    if(!active)return;
    var interaction=obj(args[2]),list=interaction&&safe(function(){return interaction.view();},null);
    if(!list)return;
    var key=address(list);
    if(seenPages[key])return;
    seenPages[key]=1;
    log('ENTER TARGET '+key);
    [0,350,850].forEach(function(delay){setTimeout(function(){
      ObjC.schedule(ObjC.mainQueue,function(){scanPage(list,'+'+delay+'ms');});
    },delay);});
  },null);
  log('READY. Test ONE cross-page App drag; optionally test a blocked folder tap separately. No continuous window scans.');
})();
