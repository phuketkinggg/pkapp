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
  nowHM:function(){ return new Date(Date.now()+7*3600e3).toISOString().slice(11,16); },
  // read published blog posts (public, read only)
  rest:function(path){ return fetch('https://jijnshwduhgegacfvpkh.supabase.co/rest/v1/'+path,{headers:{apikey:'sb_publishable_Y-ecbe3vlPAa6QipGHD1zQ_W-sh8V4i'}}).then(function(r){ if(!r.ok) throw new Error('load'); return r.json(); }); },
  date:function(d){ return d?new Date(d+'T00:00:00Z').toLocaleDateString('en-GB',{day:'numeric',month:'long',year:'numeric',timeZone:'UTC'}):''; },
  // blog text to HTML. Everything is escaped first, so only these simple marks become formatting:
  // ## heading, ### small heading, - list, 1. numbered list, > quote, ![caption](photo link), **bold**, *italic*, [text](link)
  md:function(text){
    var esc=window.PK.esc, okUrl=function(u){ return /^(https:\/\/|mailto:|\/|#|[a-z0-9-]+\.html)/i.test(u)?u:null; };
    function inl(t){ return esc(t).replace(/\[([^\]]+)\]\(([^)\s]+)\)/g,function(m,a,u){ u=okUrl(u.replace(/&amp;/g,'&')); if(!u) return a; var ext=/^https:/.test(u)&&u.indexOf('phuketking')<0; return '<a href="'+esc(u)+'"'+(ext?' target="_blank" rel="noopener"':'')+'>'+a+'</a>'; })
      .replace(/\*\*([^*]+)\*\*/g,'<strong>$1</strong>').replace(/\*([^*\n]+)\*/g,'<em>$1</em>').replace(/\n/g,'<br>'); }
    return String(text||'').replace(/\r/g,'').split(/\n\s*\n/).map(function(b){ b=b.trim(); if(!b) return '';
      var m;
      if((m=b.match(/^!\[([^\]]*)\]\(([^)\s]+)\)$/))){ var u=okUrl(m[2]); return u?'<figure><img src="'+esc(u)+'" alt="'+esc(m[1])+'" loading="lazy">'+(m[1]?'<figcaption>'+esc(m[1])+'</figcaption>':'')+'</figure>':''; }
      if(/^### /.test(b)) return '<h3>'+inl(b.slice(4))+'</h3>';
      if(/^## /.test(b)) return '<h2>'+inl(b.slice(3))+'</h2>';
      if(/^# /.test(b)) return '<h2>'+inl(b.slice(2))+'</h2>';
      var lines=b.split('\n');
      if(lines.every(function(l){ return /^[-*] /.test(l); })) return '<ul>'+lines.map(function(l){ return '<li>'+inl(l.slice(2))+'</li>'; }).join('')+'</ul>';
      if(lines.every(function(l){ return /^\d+[.)] /.test(l); })) return '<ol>'+lines.map(function(l){ return '<li>'+inl(l.replace(/^\d+[.)] /,''))+'</li>'; }).join('')+'</ol>';
      if(/^> /.test(b)) return '<blockquote>'+inl(b.replace(/^> ?/gm,''))+'</blockquote>';
      return '<p>'+inl(b)+'</p>'; }).join('');
  }
};
// for pages filled after loading (blog posts, made pages, courses): the right address, description and share preview for Google
PK.seo=function(o){ var head=document.head, url='https://www.phuketking.com/'+o.path;
  function meta(attr,key,val){ if(!val) return; var m=head.querySelector('meta['+attr+'="'+key+'"]'); if(!m){ m=document.createElement('meta'); m.setAttribute(attr,key); head.appendChild(m); } m.setAttribute('content',val); }
  var c=head.querySelector('link[rel=canonical]'); if(!c){ c=document.createElement('link'); c.rel='canonical'; head.appendChild(c); } c.href=url;
  meta('name','description',o.description); meta('property','og:title',o.title); meta('property','og:description',o.description); meta('property','og:url',url); meta('property','og:image',o.image); meta('property','og:type',o.type||'website'); meta('name','twitter:title',o.title); meta('name','twitter:description',o.description); meta('name','twitter:image',o.image);
  if(o.ld){ var l=document.createElement('script'); l.type='application/ld+json'; l.textContent=JSON.stringify(o.ld); head.appendChild(l); } };
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
// pages made in the app (Web pages) that should show in the footer
PK.rest('site_pages?select=slug,title,footer_label&in_footer=eq.true&status=eq.published&removed=eq.false&order=title').then(function(list){
  if(!list||!list.length) return; var blog=document.querySelector('footer a[href$="blog.html"]'); if(!blog) return;
  var base=blog.getAttribute('href').replace(/blog\.html$/,'page.html?p='), col=blog.parentNode;
  list.forEach(function(x){ if(!/^[a-z0-9-]{1,60}$/.test(x.slug)) return; var a=document.createElement('a'); a.href=base+x.slug; a.textContent=x.footer_label||x.title; col.appendChild(a); });
},function(){});
})();
