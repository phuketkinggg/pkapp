/* 360 photos in a full screen viewer (Pannellum, kept with the site in vendor/).
   PKPano.open({title:'Lake View', scenes:[{url, caption, vaov, yaw}], start:0})  start: the scene it opens on
   vaov: how much of the photo is kept top to bottom (degrees, 180 = all of it, less when the bottom was cut off). yaw: where it starts, 0 = the middle. */
(function(){
'use strict';
var BASE=(document.currentScript&&document.currentScript.src||'').replace(/[^\/]*$/,''), PN=null;
function load(){ if(PN) return PN; PN=new Promise(function(res,rej){ var l=document.createElement('link'); l.rel='stylesheet'; l.href=BASE+'vendor/pannellum.css'; document.head.appendChild(l);
  var s=document.createElement('script'); s.src=BASE+'vendor/pannellum.js'; s.onload=function(){ res(window.pannellum); }; s.onerror=function(){ PN=null; rej(new Error('no viewer')); }; document.head.appendChild(s); }); return PN; }
var css='.pp-ov{position:fixed;inset:0;z-index:2147483000;background:#0d0d0d;display:flex;flex-direction:column;color:#fff;font-family:inherit}'+
  '.pp-top{display:flex;align-items:center;gap:10px;flex-wrap:wrap;padding:calc(12px + env(safe-area-inset-top)) max(16px,env(safe-area-inset-right)) 10px max(16px,env(safe-area-inset-left))}'+
  '.pp-top h3{margin:0;font-size:19px;flex:1;min-width:140px;color:#fff}'+
  '.pp-b{font:inherit;font-size:14px;border:1px solid rgba(255,255,255,.35);background:transparent;color:#fff;border-radius:99px;padding:7px 14px;cursor:pointer}'+
  '.pp-b[aria-pressed="true"]{background:#fff;color:#111;border-color:#fff;font-weight:600}.pp-x{background:#fff;color:#111;font-weight:600;border-color:#fff}'+
  '.pp-b:focus-visible{outline:2px solid #fff;outline-offset:2px}'+
  '.pp-main{flex:1;min-height:0;padding:0 8px}.pp-v{width:100%;height:100%;border-radius:8px;overflow:hidden;background:#000}'+
  '.pp-bot{padding:8px max(16px,env(safe-area-inset-right)) calc(12px + env(safe-area-inset-bottom)) max(16px,env(safe-area-inset-left));font-size:13px;opacity:.75}'+
  '.pp-err{display:flex;align-items:center;justify-content:center;height:100%;opacity:.8}';
var st=document.createElement('style'); st.textContent=css; document.head.appendChild(st);
function esc(s){ return String(s==null?'':s).replace(/[&<>"']/g,function(c){ return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]; }); }
function pic(u){ return new Promise(function(res,rej){ var im=new Image(); im.crossOrigin='anonymous'; im.onload=function(){ res(im); }; im.onerror=function(){ rej(new Error('photo')); }; im.src=u; }); }
function open(o){
  var sc=(o.scenes||[]).filter(function(s){ return s&&s.url; }); if(!sc.length) return;
  var i=0, pv=null, back=document.activeElement, ov=document.createElement('div');
  ov.className='pp-ov'; ov.setAttribute('role','dialog'); ov.setAttribute('aria-modal','true'); ov.setAttribute('aria-label',o.title||'360 view');
  ov.innerHTML='<div class="pp-top"><h3>'+esc(o.title||'360 view')+'</h3>'+(sc.length>1?sc.map(function(s,j){ return '<button type="button" class="pp-b" data-j="'+j+'">'+esc(s.caption||('View '+(j+1)))+'</button>'; }).join(''):'')+
    '<button type="button" class="pp-b pp-x">Close</button></div><div class="pp-main"><div class="pp-v" id="pp-v"></div></div><div class="pp-bot">Drag to look around. Pinch or scroll to zoom.</div>';
  function show(j){ i=j; [].forEach.call(ov.querySelectorAll('[data-j]'),function(b){ b.setAttribute('aria-pressed',+b.getAttribute('data-j')===i?'true':'false'); });
    if(pv){ try{ pv.destroy(); }catch(e){} pv=null; }
    var box=ov.querySelector('#pp-v'); box.innerHTML='';
    box.innerHTML='<div class="pp-err">Loading the 360 view.</div>';
    /* the photo is loaded as a normal picture and handed to the viewer: some phones refuse the viewer's own background download */
    load().then(function(P){ return pic(sc[i].url).then(function(img){ return [P,img]; }); }).then(function(r){ var P=r[0]; if(!box.isConnected) return; box.innerHTML=''; var s=sc[i], va=Number(s.vaov)||180,
      c={type:'equirectangular',panorama:r[1],dynamic:true,dynamicUpdate:true,autoLoad:true,autoRotate:-2,autoRotateInactivityDelay:4000,showZoomCtrl:false,compass:false,hfov:100,crossOrigin:'anonymous'};
      if(s.yaw!=null) c.yaw=Number(s.yaw)||0;
      if(va<180) Object.assign(c,{haov:360,vaov:va,vOffset:90-va/2,minPitch:90-va,maxPitch:90});
      pv=P.viewer(box,c); var v0=pv; setTimeout(function(){ try{ v0.setUpdate(false); }catch(e){} var lb=box.querySelector('.pnlm-load-box'); if(lb) lb.style.display='none'; },1200); }).catch(function(){ box.innerHTML='<div class="pp-err">The 360 view could not open here.</div>'; }); }
  function close(){ if(pv){ try{ pv.destroy(); }catch(e){} } document.removeEventListener('keydown',key); ov.remove(); document.body.style.overflow=''; if(back&&back.focus) back.focus(); }
  function key(e){ if(e.key==='Escape') close(); }
  ov.addEventListener('click',function(e){ var t=e.target; if(t.closest('.pp-x')) return close(); var b=t.closest('[data-j]'); if(b) show(+b.getAttribute('data-j')); });
  document.addEventListener('keydown',key); document.body.style.overflow='hidden'; document.body.appendChild(ov); show(Math.max(0,Math.min(sc.length-1,Number(o.start)||0))); ov.querySelector('.pp-x').focus();
}
window.PKPano={open:open};
})();
