/* Phuket King website: shared header behaviour and live data from the app (packages, prices, timetable). */
(function(){
'use strict';
var FN='https://jijnshwduhgegacfvpkh.supabase.co/functions/v1/site';
var WA='66615155947';
window.PK={
  thb:function(n){ return Number(n).toLocaleString('en-US')+' THB'; },
  wa:function(text){ return 'https://wa.me/'+WA+'?text='+encodeURIComponent(text); },
  data:function(){ if(!this._d) this._d=fetch(FN).then(function(r){ return r.json(); }).then(function(d){ if(d&&d.error) throw new Error(d.error); return d; }); return this._d; },
  el:function(tag,cls,html){ var e=document.createElement(tag); if(cls) e.className=cls; if(html!=null) e.innerHTML=html; return e; },
  esc:function(s){ return String(s==null?'':s).replace(/[&<>"']/g,function(c){ return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]; }); },
  // Monday is day 0 in the app
  weekday:function(){ return (new Date(Date.now()+7*3600e3).getUTCDay()+6)%7; },
  nowHM:function(){ return new Date(Date.now()+7*3600e3).toISOString().slice(11,16); }
};
var b=document.querySelector('.menu'), n=document.querySelector('.nav');
if(b&&n) b.addEventListener('click',function(){ var o=n.classList.toggle('open'); b.setAttribute('aria-expanded',o?'true':'false'); b.textContent=o?'Close':'Menu'; });
if(n) n.addEventListener('click',function(e){ if(e.target.closest('a')&&n.classList.contains('open')){ n.classList.remove('open'); b.textContent='Menu'; b.setAttribute('aria-expanded','false'); } });
document.querySelectorAll('[data-wa]').forEach(function(a){ a.href=PK.wa(a.getAttribute('data-wa')); a.target='_blank'; a.rel='noopener'; });
var y=document.getElementById('year'); if(y) y.textContent=new Date().getFullYear();
// text and photos the manager has changed in the app (Settings > Website text, Website photos)
// text format: *stars* highlight, a new line is a line break, in lists each line is one item
PK.rich=function(t,list){ var e=function(x){ return PK.esc(x).replace(/\*([^*\n]+)\*/g,'<em>$1</em>'); };
  return list?String(t).split('\n').filter(function(l){ return l.trim(); }).map(function(l){ return '<li>'+e(l.trim())+'</li>'; }).join(''):e(String(t).trim()).replace(/\n/g,'<br>'); };
PK.txt=function(d,k,def){ var t=d&&d.texts&&d.texts[k]; return typeof t==='string'&&t.trim()?t:def; };
PK.data().then(function(d){ var tx=(d&&d.texts)||{};
  Object.keys(tx).forEach(function(k){ if(!/^[a-z0-9_]+$/.test(k)||typeof tx[k]!=='string'||!tx[k].trim()) return;
    document.querySelectorAll('[data-text="'+k+'"]').forEach(function(e){ e.innerHTML=PK.rich(tx[k],e.tagName==='UL'); }); });
},function(){});
PK.data().then(function(d){ var ph=(d&&d.photos)||{}, ok=/^https:\/\/jijnshwduhgegacfvpkh\.supabase\.co\/storage\/v1\/object\/public\/promos\/site\//;
  Object.keys(ph).forEach(function(k){ var u=ph[k]; if(!/^[a-z0-9_]+$/.test(k)||typeof u!=='string'||!ok.test(u)) return;
    document.querySelectorAll('[data-photo="'+k+'"]').forEach(function(e){ e.src=u; });
    document.querySelectorAll('[data-photo-bg="'+k+'"]').forEach(function(e){ e.style.backgroundImage='url("'+u.replace(/["\\]/g,'')+'")'; }); });
},function(){});
})();
