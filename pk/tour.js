/* Gym tour: the aerial photo of the gym with each area marked. Tap an area to see its photos (and a 360 view when there is one).
   Everything comes from the app: Settings, Website, Gym tour (site_tour). Put <div id="gymtour"></div> on a page and load this file after site.js. */
(function(){
'use strict';
var box=document.getElementById('gymtour'); if(!box||!window.PK) return;
var css='.gt-map{position:relative;border-radius:14px;overflow:hidden;background:#1a1a1a;box-shadow:0 14px 40px rgba(0,0,0,.18)}.gt-map img{display:block;width:100%;height:auto}'+
  '.gt-z{position:absolute;border:2px solid rgba(255,255,255,.75);border-radius:8px;background:rgba(0,0,0,.08);cursor:pointer;padding:0;display:flex;align-items:center;justify-content:center;transition:background .2s,border-color .2s;font:inherit}'+
  '.gt-z:hover,.gt-z:focus-visible{background:rgba(201,38,52,.28);border-color:#fff;outline:none}'+
  '.gt-z span{background:rgba(17,17,17,.82);color:#fff;font-weight:600;font-size:clamp(11px,1.6vw,15px);padding:5px 10px;border-radius:99px;white-space:nowrap;box-shadow:0 2px 10px rgba(0,0,0,.3);pointer-events:none}'+
  '.gt-z span:after{content:" +";opacity:.7}'+
  '.gt-chips{display:flex;flex-wrap:wrap;gap:8px;margin-top:14px}.gt-chips button{font:inherit;border:1px solid var(--line,#ddd);background:#fff;color:inherit;border-radius:99px;padding:7px 14px;cursor:pointer}'+
  '.gt-ov{position:fixed;inset:0;z-index:2147483000;background:#0d0d0d;display:flex;flex-direction:column;color:#fff}'+
  '.gt-top{display:flex;align-items:center;gap:12px;padding:calc(12px + env(safe-area-inset-top)) 16px 12px}.gt-top h3{margin:0;font-size:20px;flex:1;color:#fff}'+
  '.gt-x{font:inherit;font-size:15px;background:#fff;color:#111;border:0;border-radius:99px;padding:8px 16px;cursor:pointer;font-weight:600}'+
  '.gt-main{flex:1;min-height:0;display:flex;align-items:center;justify-content:center;position:relative;padding:0 8px}.gt-main img,.gt-main video{max-width:100%;max-height:100%;object-fit:contain;border-radius:8px;background:#000}'+
  '.gt-main iframe{width:min(100%,1100px);aspect-ratio:16/9;border:0;border-radius:8px;max-height:100%}'+
  '.gt-nav{position:absolute;top:50%;transform:translateY(-50%);width:44px;height:44px;border-radius:50%;border:0;background:rgba(255,255,255,.9);color:#111;font-size:22px;cursor:pointer}.gt-prev{left:12px}.gt-next{right:12px}'+
  '.gt-bot{padding:10px 16px calc(14px + env(safe-area-inset-bottom));max-width:1100px;margin:0 auto;width:100%}.gt-bot p{margin:0 0 10px;opacity:.85;font-size:15px}.gt-cap{font-size:14px;opacity:.75;margin-bottom:8px;min-height:1.2em}'+
  '.gt-th{display:flex;gap:6px;overflow-x:auto;padding-bottom:4px}.gt-th button{flex:none;width:72px;height:52px;padding:0;border:2px solid transparent;border-radius:6px;overflow:hidden;cursor:pointer;background:#333}.gt-th button.on{border-color:#fff}.gt-th img,.gt-th video{width:100%;height:100%;object-fit:cover;display:block}.gt-th button{position:relative}.gt-th .pl{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;color:#fff;font-size:18px;text-shadow:0 1px 4px #000}'+
  '.gt-empty{text-align:center;opacity:.85;max-width:420px;padding:20px}.gt-empty a{color:#fff}';
var st=document.createElement('style'); st.textContent=css; document.head.appendChild(st);
function esc(s){ return String(s==null?'':s).replace(/[&<>"']/g,function(c){ return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]; }); }
function yt(u){ var m=String(u||'').match(/^https:\/\/(?:www\.)?(?:youtube\.com\/(?:watch\?v=|shorts\/|embed\/|live\/)|youtu\.be\/)([A-Za-z0-9_-]{6,20})/); return m?m[1]:null; }

PK.rest('rpc/site_tour').then(function(T){
  var Z=(T&&Array.isArray(T.zones))?T.zones:[]; if(!Z.length) return;
  var sec=box.closest('section'); if(sec) sec.hidden=false;
  var img=T.image||'img/gym-aerial.jpg';
  box.innerHTML=(T.title||T.text?'<div class="center" style="margin-bottom:22px">'+(T.title?'<h2>'+esc(T.title)+'</h2><span class="rule"></span>':'')+(T.text?'<p class="lead">'+esc(T.text)+'</p>':'')+'</div>':'')+
    '<div class="gt-map"><img src="'+esc(img)+'" alt="Aerial view of the gym from above" width="1260" height="956">'+
    Z.map(function(z,i){ return '<button type="button" class="gt-z" data-i="'+i+'" style="left:'+z.x+'%;top:'+z.y+'%;width:'+z.w+'%;height:'+z.h+'%" aria-label="See '+esc(z.name)+'"><span>'+esc(z.name)+'</span></button>'; }).join('')+'</div>'+
    '<div class="gt-chips">'+Z.map(function(z,i){ return '<button type="button" data-i="'+i+'">'+esc(z.name)+'</button>'; }).join('')+'</div>';
  box.addEventListener('click',function(e){ var b=e.target.closest('[data-i]'); if(b) open(Z[+b.getAttribute('data-i')]); });
}).catch(function(){});

function item(p){ var id=p.yt?yt(p.url):null;
  if(id) return '<iframe src="https://www.youtube-nocookie.com/embed/'+id+'?rel=0&playsinline=1" allow="accelerometer; gyroscope; autoplay; fullscreen" allowfullscreen title="'+esc(p.caption||'Video')+'"></iframe>';
  if(p.video) return '<video src="'+esc(p.url)+'" controls playsinline autoplay muted loop preload="metadata"></video>';
  return '<img src="'+esc(p.url)+'" alt="'+esc(p.caption||'')+'">'; }
function thumb(p){ var id=p.yt?yt(p.url):null;
  if(id) return '<img src="https://i.ytimg.com/vi/'+id+'/mqdefault.jpg" alt="" loading="lazy"><span class="pl">&#9654;</span>';
  if(p.video) return '<video src="'+esc(p.url)+'#t=0.5" muted playsinline preload="metadata"></video><span class="pl">&#9654;</span>';
  return '<img src="'+esc(p.url)+'" alt="" loading="lazy">'; }
function open(z){
  var ph=(z.photos||[]).filter(function(p){ return p&&p.url; }), i=0, pano=z.pano||'', showPano=!ph.length&&!!pano;
  var ov=document.createElement('div'); ov.className='gt-ov'; ov.setAttribute('role','dialog'); ov.setAttribute('aria-modal','true'); ov.setAttribute('aria-label',z.name);
  function draw(){
    var main;
    if(showPano){ var id=yt(pano); main=id?'<iframe src="https://www.youtube-nocookie.com/embed/'+id+'?rel=0" allow="accelerometer; gyroscope; fullscreen" allowfullscreen title="360 view of '+esc(z.name)+'"></iframe>':'<div class="gt-empty"><p>The 360 view opens in a new tab.</p><p><a href="'+esc(pano)+'" target="_blank" rel="noopener">Open the 360 view</a></p></div>'; }
    else if(ph.length) main=item(ph[i])+(ph.length>1?'<button type="button" class="gt-nav gt-prev" aria-label="Previous photo">&#8249;</button><button type="button" class="gt-nav gt-next" aria-label="Next photo">&#8250;</button>':'');
    else main='<div class="gt-empty"><p>Photos of the '+esc(z.name.toLowerCase())+' are coming soon.</p><p><a data-wa="Hi Phuket King, can I see the '+esc(z.name.toLowerCase())+'?">Ask us for a video on WhatsApp</a></p></div>';
    ov.innerHTML='<div class="gt-top"><h3>'+esc(z.name)+'</h3>'+(pano&&ph.length?'<button type="button" class="gt-x gt-pano">'+(showPano?'Photos':'360 view')+'</button>':'')+'<button type="button" class="gt-x gt-close">Close</button></div>'+
      '<div class="gt-main">'+main+'</div><div class="gt-bot">'+(z.text?'<p>'+esc(z.text)+'</p>':'')+
      (!showPano&&ph.length?'<div class="gt-cap">'+esc(ph[i].caption||'')+(ph.length>1?(ph[i].caption?' · ':'')+(i+1)+' of '+ph.length:'')+'</div>':'')+
      (!showPano&&ph.length>1?'<div class="gt-th">'+ph.map(function(p,j){ return '<button type="button" data-j="'+j+'" class="'+(j===i?'on':'')+'" aria-label="'+(p.video||p.yt?'Video ':'Photo ')+(j+1)+'">'+thumb(p)+'</button>'; }).join('')+'</div>':'')+'</div>';
    ov.querySelectorAll('[data-wa]').forEach(function(a){ if(PK.wa){ a.href=PK.wa(a.getAttribute('data-wa')); a.target='_blank'; a.rel='noopener'; } });
  }
  function go(d){ if(!ph.length) return; i=(i+d+ph.length)%ph.length; draw(); }
  function close(){ document.removeEventListener('keydown',key); ov.remove(); document.body.style.overflow=''; }
  function key(e){ if(e.key==='Escape') close(); else if(e.key==='ArrowLeft') go(-1); else if(e.key==='ArrowRight') go(1); }
  ov.addEventListener('click',function(e){ var t=e.target;
    if(t.closest('.gt-close')) return close(); if(t.closest('.gt-pano')){ showPano=!showPano; return draw(); }
    if(t.closest('.gt-prev')) return go(-1); if(t.closest('.gt-next')) return go(1);
    var b=t.closest('[data-j]'); if(b){ i=+b.getAttribute('data-j'); draw(); } else if(t===ov) close(); });
  var sx=null; ov.addEventListener('touchstart',function(e){ sx=e.touches[0].clientX; },{passive:true});
  ov.addEventListener('touchend',function(e){ if(sx==null) return; var dx=e.changedTouches[0].clientX-sx; if(Math.abs(dx)>50) go(dx<0?1:-1); sx=null; });
  document.addEventListener('keydown',key); document.body.style.overflow='hidden'; document.body.appendChild(ov); draw();
  var c=ov.querySelector('.gt-close'); if(c) c.focus();
}
})();
