/* Phuket King website: shared header behaviour and live data from the app (packages, prices, timetable). */
(function(){
'use strict';
var FN='https://jijnshwduhgegacfvpkh.supabase.co/functions/v1/site';
var WA='66615155947';
/* referral links: ?ref=<code> is remembered for 60 days, and the booking page sends it with the booking */
(function(){ try{ var m=location.search.match(/[?&]ref=([A-Za-z0-9-]{2,30})(?:&|$)/); if(m) localStorage.setItem('pk_ref',JSON.stringify({c:m[1].toLowerCase(),t:Date.now()})); }catch(e){} })();
window.PKREF=function(){ try{ var x=JSON.parse(localStorage.getItem('pk_ref')||'null'); if(x&&x.c&&Date.now()-x.t<60*864e5) return x.c; }catch(e){} return null; };
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
// switch to the menu button if the links would run into the logo
(function(){ var top=document.querySelector('.top'), logo=document.querySelector('.top .logo'); if(!top||!logo||!n) return;
  function fit(){ if(n.classList.contains('open')) return; top.classList.remove('tight'); if(getComputedStyle(n).display==='none') return;
    var a=n.querySelector('a'), w=top.querySelector('.wrap'); if(!a||!w) return;
    if(a.getBoundingClientRect().left<logo.getBoundingClientRect().right+12||n.getBoundingClientRect().right>w.getBoundingClientRect().right+1) top.classList.add('tight'); }
  fit(); window.addEventListener('resize',fit); if(document.fonts&&document.fonts.ready) document.fonts.ready.then(fit); window.addEventListener('load',fit); })();
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
/* website numbers: small anonymous events (no names or emails), so the owner sees where visitors stop. See the app, Website numbers. */
(function(){
  var REST='https://jijnshwduhgegacfvpkh.supabase.co/rest/v1/rpc/site_track', KEY='sb_publishable_Y-ecbe3vlPAa6QipGHD1zQ_W-sh8V4i';
  function rid(){ var a='abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789', o=''; for(var i=0;i<16;i++) o+=a.charAt(Math.floor(Math.random()*a.length)); return o; }
  function get(st,k){ try{ var v=st.getItem(k); if(!v){ v=rid(); st.setItem(k,v); } return v; }catch(e){ return null; } }
  var vid=get(window.localStorage,'pk_vid')||rid(), sid=get(window.sessionStorage,'pk_sid')||rid();
  /* where this visit came from, kept for the visit */
  function source(){
    var q=new URLSearchParams(location.search), u=q.get('utm_source'), r='';
    if(u) return u.slice(0,40);
    if(q.get('fbclid')) return 'Facebook or Instagram ad'; if(q.get('gclid')) return 'Google ad'; if(q.get('ref')) return 'Referral link';
    try{ r=document.referrer?new URL(document.referrer).hostname.replace(/^www\./,''):''; }catch(e){}
    if(!r||/phuketking\.com$/.test(r)) return null;
    if(/google\./.test(r)) return 'Google'; if(/facebook\.|fb\./.test(r)) return 'Facebook'; if(/instagram\./.test(r)) return 'Instagram';
    if(/bing\./.test(r)) return 'Bing'; if(/tiktok\./.test(r)) return 'TikTok'; if(/youtube\./.test(r)) return 'YouTube'; if(/chatgpt|openai|perplexity|claude\.ai|gemini/.test(r)) return 'AI chat';
    return r.slice(0,40);
  }
  var src=null; try{ src=sessionStorage.getItem('pk_src'); if(src===null){ src=source()||''; sessionStorage.setItem('pk_src',src); } }catch(e){ src=source(); }
  var dev=(window.matchMedia&&window.matchMedia('(max-width: 820px)').matches)||/Mobi|Android|iPhone/i.test(navigator.userAgent)?'m':'d';
  var page=(location.pathname.replace(/\.html$/,'').replace(/\/index$/,'/')||'/');
  /* blog posts, app pages and courses: keep which one */
  (function(){ var q=new URLSearchParams(location.search), k=/\/(post|page)$/.test(page)?'p':/\/course$/.test(page)?'c':null; if(k&&q.get(k)) page+='?'+k+'='+q.get(k); })();
  page=page.slice(0,80);
  /* where in the world (by the visitor's clock, no IP is kept), their language, and the ad campaign */
  var tz=null, lang=null, camp=null; try{ tz=Intl.DateTimeFormat().resolvedOptions().timeZone||null; }catch(e){} try{ lang=(navigator.language||'').slice(0,15)||null; }catch(e){}
  try{ camp=sessionStorage.getItem('pk_camp'); if(camp===null){ camp=new URLSearchParams(location.search).get('utm_campaign')||''; sessionStorage.setItem('pk_camp',camp); } }catch(e){ camp=new URLSearchParams(location.search).get('utm_campaign'); }
  window.PK.track=function(ev,item){
    try{ fetch(REST,{method:'POST',keepalive:true,headers:{'Content-Type':'application/json',apikey:KEY},body:JSON.stringify({p:{ev:ev,vid:vid,sid:sid,page:page,src:src||null,dev:dev,tz:tz,lang:lang,camp:camp||null,item:item==null?null:String(item).slice(0,120)}})}).catch(function(){}); }catch(e){}
  };
  var off=/[?&]notrack=1/.test(location.search);
  if(off){ window.PK.track=function(){}; return; }
  if(document.documentElement.getAttribute('data-nf')==='1'||/^Page not found/.test(document.title)) window.PK.track('nf',(location.pathname+location.search).slice(0,120));
  window.PK.track('view');
  /* engaged: 15 seconds on the page, or read half of it */
  var eng=false; function engaged(){ if(eng) return; eng=true; window.PK.track('engaged'); }
  setTimeout(function(){ if(document.visibilityState==='visible') engaged(); },15000);
  window.addEventListener('scroll',function(){ var h=document.documentElement; if((window.scrollY+window.innerHeight)/Math.max(1,h.scrollHeight)>0.5&&h.scrollHeight>window.innerHeight*1.3) engaged(); },{passive:true});
  /* time on the page: seconds while it is on screen, sent when they leave or switch away */
  var shown=document.visibilityState==='visible'?Date.now():0, acc=0;
  function flush(){ if(shown){ acc+=(Date.now()-shown)/1000; shown=0; } var n=Math.round(acc); if(n>=1){ acc=0; window.PK.track('time',String(Math.min(n,1800))); } }
  document.addEventListener('visibilitychange',function(){ if(document.visibilityState==='hidden') flush(); else shown=Date.now(); });
  window.addEventListener('pagehide',flush);
  /* taps on phone, email, map and social links */
  document.addEventListener('click',function(ev){ var a=ev.target&&ev.target.closest&&ev.target.closest('a[href]'); if(!a) return; var u=a.getAttribute('href')||'', k=null;
    if(/^tel:/i.test(u)) k='Phone call'; else if(/^mailto:/i.test(u)) k='Email'; else if(/google\.[a-z.]+\/maps|maps\.app\.goo\.gl|goo\.gl\/maps|maps\.apple/i.test(u)) k='Map directions';
    else if(/instagram\.com/i.test(u)) k='Instagram'; else if(/facebook\.com|fb\.com/i.test(u)) k='Facebook'; else if(/youtube\.com|youtu\.be/i.test(u)) k='YouTube';
    else if(/tiktok\.com/i.test(u)) k='TikTok'; else if(/line\.me/i.test(u)) k='LINE'; else if(/tripadvisor/i.test(u)) k='TripAdvisor';
    else if(/app\.phuketking\.com/i.test(u)) k='Opened the member app';
    if(k) window.PK.track('click',k); },true);
  /* taps on WhatsApp links anywhere on the site */
  document.addEventListener('click',function(ev){ var a=ev.target&&ev.target.closest&&ev.target.closest('a[href*="wa.me"],a[href*="whatsapp"]'); if(a) window.PK.track('wa'); },true);
})();

})();
