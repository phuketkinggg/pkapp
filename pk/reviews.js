/* Google reviews on the website. Fills any element with data-reviews. The section stays hidden until reviews load. */
(function(){
'use strict';
var FN='https://jijnshwduhgegacfvpkh.supabase.co/functions/v1/reviews';
var boxes=document.querySelectorAll('[data-reviews]'); if(!boxes.length) return;
var css=[
'.pkr-top{display:flex;align-items:center;gap:14px;flex-wrap:wrap;margin:6px 0 22px}',
'.pkr-score{font:700 44px/1 Rubik,system-ui,sans-serif}.pkr-stars{color:#F4B400;font-size:22px;letter-spacing:2px}.pkr-count{font-size:14px;opacity:.75}',
'.pkr-grid{display:grid;gap:14px;grid-template-columns:repeat(auto-fill,minmax(300px,1fr))}',
'.pkr-card{background:#fff;color:#171B23;border:1px solid #E2DBD3;border-radius:14px;padding:16px;display:flex;flex-direction:column;gap:8px;text-align:left}',
'.pkr-who{display:flex;align-items:center;gap:10px}.pkr-ini{width:38px;height:38px;border-radius:19px;background:#10295D;color:#fff;display:flex;align-items:center;justify-content:center;font-weight:600;flex:none}',
'.pkr-who a,.pkr-who b{font-weight:600;color:#171B23;text-decoration:none}.pkr-who small{display:block;color:#5E6470;font-size:13px}',
'.pkr-card .pkr-stars{font-size:16px}.pkr-text{margin:0;font-size:15px;line-height:1.5;color:#2A303B}',
'.pkr-text.cut{display:-webkit-box;-webkit-line-clamp:6;-webkit-box-orient:vertical;overflow:hidden}',
'.pkr-more{background:none;border:0;padding:0;color:#D8001B;font:600 14px Rubik,system-ui,sans-serif;cursor:pointer;align-self:flex-start}',
'.pkr-acts{display:flex;gap:10px;flex-wrap:wrap;margin-top:22px}',
'.pkr-g{font-size:13px;opacity:.75;margin-top:12px}'
].join('\n');
var st=document.createElement('style'); st.textContent=css; document.head.appendChild(st);
function el(tag,cls,text){ var e=document.createElement(tag); if(cls) e.className=cls; if(text!=null) e.textContent=text; return e; }
function stars(n){ n=Math.round(Number(n)||0); return '★★★★★'.slice(0,n)+'☆☆☆☆☆'.slice(0,5-n); }
function link(href,cls,text){ var a=el('a',cls,text); a.href=href; a.target='_blank'; a.rel='noopener'; return a; }
fetch(FN).then(function(r){ return r.json(); }).then(function(d){
  if(!d||!d.configured||!d.reviews||!d.reviews.length) return;
  boxes.forEach(function(box){
    var top=el('div','pkr-top');
    if(d.rating){ top.appendChild(el('div','pkr-score',Number(d.rating).toFixed(1))); var s=el('div'); s.appendChild(el('div','pkr-stars',stars(d.rating))); s.appendChild(el('div','pkr-count',(d.count||0)+' reviews on Google')); top.appendChild(s); }
    var grid=el('div','pkr-grid');
    d.reviews.slice(0,Number(box.getAttribute('data-reviews'))||6).forEach(function(r){
      var c=el('div','pkr-card'), who=el('div','pkr-who'), ini=el('div','pkr-ini',String(r.author||'G').trim().charAt(0).toUpperCase()), nm=el('div');
      nm.appendChild(r.author_url&&/^https:\/\//.test(r.author_url)?link(r.author_url,null,r.author):el('b',null,r.author)); nm.appendChild(el('small',null,r.when||''));
      who.appendChild(ini); who.appendChild(nm); c.appendChild(who);
      if(r.rating) c.appendChild(el('div','pkr-stars',stars(r.rating)));
      var t=el('p','pkr-text cut',r.text); c.appendChild(t);
      if(String(r.text).length>320){ var m=el('button','pkr-more','Read more'); m.type='button'; m.onclick=function(){ var cut=t.classList.toggle('cut'); m.textContent=cut?'Read more':'Show less'; }; c.appendChild(m); }
      grid.appendChild(c);
    });
    var acts=el('div','pkr-acts');
    if(d.maps_url&&/^https:\/\//.test(d.maps_url)) acts.appendChild(link(d.maps_url,box.getAttribute('data-btn')||'btn','Read all reviews on Google'));
    if(d.write_url) acts.appendChild(link(d.write_url,box.getAttribute('data-btn2')||'btn','Write a review'));
    box.innerHTML=''; box.appendChild(top); box.appendChild(grid); box.appendChild(acts); box.appendChild(el('div','pkr-g','Reviews from Google'));
    var sec=box.closest('[data-reviews-section]'); if(sec) sec.hidden=false;
  });
}).catch(function(){});
})();
