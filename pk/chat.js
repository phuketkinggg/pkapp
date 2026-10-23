/* Phuket King website live chat. Messages go to the front desk in the app (Messages tab), with a phone notification.
   Outside chat hours it says so and asks for WhatsApp or email. The chat key stays in this browser only. */
(function(){
'use strict';
if(window.__pkChat) return; window.__pkChat=true;
var FN='https://jijnshwduhgegacfvpkh.supabase.co/functions/v1/chat', KEY='sb_publishable_Y-ecbe3vlPAa6QipGHD1zQ_W-sh8V4i';
var WA='https://wa.me/66615155947?text='+encodeURIComponent('Hi Phuket King, I have a question.');
var css=[
'.pkc-b{position:fixed;right:16px;bottom:16px;z-index:90;display:flex;align-items:center;gap:8px;border:0;border-radius:999px;background:#D8001B;color:#fff;font:600 15px Rubik,system-ui,sans-serif;padding:0 18px 0 14px;height:54px;box-shadow:0 6px 20px rgba(0,0,0,.3);cursor:pointer}',
'.pkc-b svg{width:24px;height:24px;flex:none}.pkc-b .dot{position:absolute;top:6px;left:36px;width:12px;height:12px;border-radius:6px;background:#2ecc71;border:2px solid #D8001B}',
'.pkc-b .n{position:absolute;top:-4px;right:-4px;min-width:22px;height:22px;border-radius:11px;background:#fff;color:#D8001B;font-size:13px;display:flex;align-items:center;justify-content:center;padding:0 6px;box-shadow:0 1px 4px rgba(0,0,0,.3)}',
'@media (max-width:960px){body.pkc-dock .pkc-b{bottom:84px}}',
'@media (max-width:520px){.pkc-b{padding:0;width:56px;justify-content:center}.pkc-b .t{display:none}}',
'.pkc-p{position:fixed;right:16px;bottom:16px;z-index:91;width:370px;max-width:calc(100vw - 32px);height:560px;max-height:calc(100vh - 32px);background:#F9F3ED;color:#171B23;border-radius:16px;box-shadow:0 12px 40px rgba(0,0,0,.35);display:flex;flex-direction:column;overflow:hidden;font:400 15px/1.45 Rubik,system-ui,sans-serif}',
'@media (max-width:520px){.pkc-p{inset:0;width:auto;max-width:none;height:auto;max-height:none;border-radius:0}}',
'.pkc-p[hidden]{display:none}',
'.pkc-h{background:#171B23;color:#fff;padding:12px 12px 12px 16px;display:flex;align-items:center;gap:10px}',
'.pkc-h img{width:36px;height:36px;border-radius:6px}.pkc-h .tt{flex:1;min-width:0}.pkc-h b{display:block;font-weight:600;letter-spacing:.02em}',
'.pkc-h small{display:flex;align-items:center;gap:6px;opacity:.8;font-size:13px}.pkc-h small i{width:8px;height:8px;border-radius:4px;background:#8a8f99;display:inline-block}.pkc-h small i.on{background:#2ecc71}',
'.pkc-h button{background:rgba(255,255,255,.12);border:0;color:#fff;width:38px;height:38px;border-radius:19px;font:600 20px system-ui;cursor:pointer}',
'.pkc-m{flex:1;overflow-y:auto;padding:14px;display:flex;flex-direction:column;gap:8px}',
'.pkc-g{max-width:85%;padding:9px 12px;border-radius:14px;white-space:pre-wrap;word-wrap:break-word;background:#fff;border:1px solid #E2DBD3;align-self:flex-start}',
'.pkc-g.me{align-self:flex-end;background:#171B23;color:#fff;border-color:#171B23}.pkc-g small{display:block;font-size:11px;opacity:.6;margin-top:3px}',
'.pkc-g .who{display:block;font-size:12px;font-weight:600;color:#D8001B;margin-bottom:2px}',
'.pkc-note{font-size:13px;background:#fff;border:1px solid #E2DBD3;border-left:4px solid #D8001B;border-radius:10px;padding:10px 12px;color:#171B23}',
'.pkc-note a{color:#D8001B;font-weight:600}',
'.pkc-f{display:grid;gap:8px;padding:12px 14px;border-top:1px solid #E2DBD3;background:#fff}',
'.pkc-f input,.pkc-f textarea{font:400 16px Rubik,system-ui,sans-serif;border:1px solid #cfc8c0;border-radius:10px;padding:10px 12px;width:100%;box-sizing:border-box;background:#fff;color:#171B23}',
'.pkc-f textarea{resize:none;min-height:46px;max-height:130px}',
'.pkc-row{display:flex;gap:8px;align-items:flex-end}.pkc-row textarea{flex:1}',
'.pkc-send{border:0;border-radius:10px;background:#D8001B;color:#fff;font:600 15px Rubik,system-ui,sans-serif;padding:0 16px;min-height:46px;cursor:pointer}.pkc-send:disabled{opacity:.6}',
'.pkc-err{color:#B80017;font-size:13px;font-weight:600;margin:0}',
'.pkc-c{display:flex;gap:8px}.pkc-c input{flex:1}.pkc-c button{border:1px solid #171B23;background:#fff;border-radius:10px;font:600 14px Rubik,system-ui,sans-serif;padding:0 12px;cursor:pointer}',
'.pkc-lbl{font-size:13px;color:#5E6470;margin:0}'
].join('\n');
var st=document.createElement('style'); st.textContent=css; document.head.appendChild(st);
if(document.querySelector('.dock')) document.body.classList.add('pkc-dock');

function store(v){ try{ if(v) localStorage.setItem('pk_chat',JSON.stringify(v)); else localStorage.removeItem('pk_chat'); }catch(e){} }
function load(){ try{ var v=JSON.parse(localStorage.getItem('pk_chat')||'null'); return v&&v.id&&v.key?v:null; }catch(e){ return null; } }
function call(b){ return fetch(FN,{method:'POST',headers:{'Content-Type':'application/json',apikey:KEY},body:JSON.stringify(b)}).then(function(r){ return r.json(); }).then(function(d){ if(d&&d.error) throw new Error(d.error); return d; }); }
function mk(tag,cls,text){ var e=document.createElement(tag); if(cls) e.className=cls; if(text!=null) e.textContent=text; return e; }
function hm(at){ return new Date(at).toLocaleTimeString('en-GB',{hour:'2-digit',minute:'2-digit'}); }

var T=load(), S={online:null,from:'08:00',to:'20:00'}, seen={}, last=null, open=false, timer=0, unread=0, gotTeam=0;
// button
var btn=mk('button','pkc-b'); btn.type='button'; btn.setAttribute('aria-label','Chat with us');
btn.innerHTML='<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M21 12a8 8 0 0 1-11.6 7.1L4 20l1-4.6A8 8 0 1 1 21 12z"/></svg><span class="t">Chat with us</span>';
var dot=mk('span','dot'); dot.hidden=true; btn.appendChild(dot);
var badge=mk('span','n'); badge.hidden=true; btn.appendChild(badge);
// panel
var pan=mk('div','pkc-p'); pan.hidden=true; pan.setAttribute('role','dialog'); pan.setAttribute('aria-label','Chat with Phuket King');
var head=mk('div','pkc-h'), logo=mk('img'); logo.alt=''; logo.src=(document.querySelector('.logo img')||{}).src||'';
var tt=mk('div','tt'), stat=mk('small'), sdot=mk('i'), stext=mk('span','', 'Checking');
stat.appendChild(sdot); stat.appendChild(stext); tt.appendChild(mk('b',null,'Phuket King')); tt.appendChild(stat);
var x=mk('button',null,'×'); x.type='button'; x.setAttribute('aria-label','Close chat');
if(logo.src) head.appendChild(logo); head.appendChild(tt); head.appendChild(x);
var msgs=mk('div','pkc-m'); msgs.setAttribute('role','log'); msgs.setAttribute('aria-live','polite');
var foot=mk('div','pkc-f');
pan.appendChild(head); pan.appendChild(msgs); pan.appendChild(foot);
document.body.appendChild(btn); document.body.appendChild(pan);

function hours(){ return S.from+' to '+S.to; }
function status(){
  if(S.online===null){ stext.textContent='Checking'; sdot.className=''; return; }
  sdot.className=S.online?'on':''; stext.textContent=S.online?'Online now. We usually reply in a few minutes.':'Away right now. Chat hours '+hours()+' (Thailand).';
  dot.hidden=!S.online;
}
function bubble(m){
  if(m.id&&seen[m.id]) return; if(m.id) seen[m.id]=1;
  var g=mk('div','pkc-g'+(m.me?' me':''));
  if(!m.me&&m.who) g.appendChild(mk('span','who',m.who));
  g.appendChild(document.createTextNode(m.body));
  if(m.at) g.appendChild(mk('small',null,hm(m.at)));
  var end=msgs.scrollHeight-msgs.scrollTop-msgs.clientHeight<60;
  msgs.appendChild(g); if(end||m.me) msgs.scrollTop=msgs.scrollHeight;
}
function note(html){ var n=mk('div','pkc-note'); n.innerHTML=html; msgs.appendChild(n); return n; }
var awayNote=null;
function intro(){
  msgs.innerHTML=''; seen={};
  bubble({who:'Phuket King',body:'Hi! Ask us anything about training, the rooms, prices or the DTV visa.'});
  awayNote=null;
}
function showAway(){
  if(S.online!==false||awayNote) return;
  awayNote=note('We are not online right now. Leave your WhatsApp or email and we will get back to you as soon as we can. Or message us on <a href="'+WA+'" target="_blank" rel="noopener">WhatsApp</a>.');
}

// first message form
function startForm(){
  foot.innerHTML='';
  var name=mk('input'); name.placeholder='Your name'; name.maxLength=80; name.autocomplete='name'; name.setAttribute('aria-label','Your name');
  var contact=mk('input'); contact.className='pkc-ct'; contact.placeholder=S.online===false?'WhatsApp number or email (needed)':'WhatsApp or email (so we can reply if you leave)'; contact.maxLength=120; contact.setAttribute('aria-label','WhatsApp number or email');
  var body=mk('textarea'); body.placeholder='Type your message'; body.maxLength=2000; body.rows=2; body.setAttribute('aria-label','Your message');
  var err=mk('p','pkc-err'); err.hidden=true;
  var send=mk('button','pkc-send','Send'); send.type='button';
  var row=mk('div','pkc-row'); row.appendChild(body); row.appendChild(send);
  foot.appendChild(name); foot.appendChild(contact); foot.appendChild(row); foot.appendChild(err);
  function go(){
    var b=body.value.trim(), c=contact.value.trim(); err.hidden=true;
    if(!b){ err.textContent='Type your message first.'; err.hidden=false; body.focus(); return; }
    if(S.online===false&&!okContact(c)){ err.textContent='Leave your WhatsApp number or email so we can reply.'; err.hidden=false; contact.focus(); return; }
    if(c&&!okContact(c)){ err.textContent='That does not look like a phone number or email.'; err.hidden=false; contact.focus(); return; }
    send.disabled=true;
    call({mode:'start',name:name.value.trim(),contact:c,body:b,page:location.pathname}).then(function(d){
      T={id:d.id,key:d.key,contact:!!c}; store(T); S.online=d.online; status(); chatForm(); poll();
    }).catch(function(e){ err.textContent=e.message; err.hidden=false; send.disabled=false; });
  }
  send.onclick=go; keys(body,go);
  setTimeout(function(){ (S.online===false?contact:body).focus(); },60);
}
function fixHint(){ var c=foot.querySelector('.pkc-ct'); if(c) c.placeholder=S.online===false?'WhatsApp number or email (needed)':'WhatsApp or email (so we can reply if you leave)'; }
function okContact(c){ return /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(c)||/^\+?[0-9][0-9 ()-]{6,}$/.test(c); }
function keys(t,go){ t.addEventListener('keydown',function(e){ if(e.key==='Enter'&&!e.shiftKey&&!('ontouchstart' in window)){ e.preventDefault(); go(); } });
  t.addEventListener('input',function(){ t.style.height=''; t.style.height=Math.min(130,t.scrollHeight)+'px'; }); }

// ongoing chat
function chatForm(){
  foot.innerHTML='';
  if(!T.contact){
    var lbl=mk('p','pkc-lbl','In case you leave the page, where can we reply?');
    var c=mk('div','pkc-c'), ci=mk('input'); ci.placeholder='WhatsApp or email'; ci.maxLength=120; ci.setAttribute('aria-label','WhatsApp number or email');
    var cb=mk('button',null,'Save'); cb.type='button'; c.appendChild(ci); c.appendChild(cb);
    var cerr=mk('p','pkc-err'); cerr.hidden=true;
    cb.onclick=function(){ var v=ci.value.trim(); cerr.hidden=true; if(!okContact(v)){ cerr.textContent='Type a WhatsApp number or email.'; cerr.hidden=false; return; }
      cb.disabled=true; call({mode:'contact',id:T.id,key:T.key,contact:v}).then(function(){ T.contact=true; store(T); chatForm(); poll(); }).catch(function(e){ cb.disabled=false; cerr.textContent=e.message; cerr.hidden=false; if(/ended/.test(e.message)) reset(); }); };
    foot.appendChild(lbl); foot.appendChild(c); foot.appendChild(cerr);
  }
  var body=mk('textarea'); body.placeholder='Type a message'; body.maxLength=2000; body.rows=1; body.setAttribute('aria-label','Your message');
  var send=mk('button','pkc-send','Send'); send.type='button';
  var row=mk('div','pkc-row'); row.appendChild(body); row.appendChild(send);
  var err=mk('p','pkc-err'); err.hidden=true;
  foot.appendChild(row); foot.appendChild(err);
  function go(){ var b=body.value.trim(); if(!b) return; send.disabled=true; err.hidden=true;
    call({mode:'send',id:T.id,key:T.key,body:b}).then(function(){ body.value=''; body.style.height=''; return poll(); })
      .catch(function(e){ err.textContent=e.message; err.hidden=false; if(/ended/.test(e.message)) reset(); }).then(function(){ send.disabled=false; body.focus(); }); }
  send.onclick=go; keys(body,go);
}
function reset(){ T=null; store(null); last=null; intro(); startForm(); }

var busy=false;
function poll(){
  if(!T||busy) return Promise.resolve(); busy=true;
  return call({mode:'poll',id:T.id,key:T.key,after:last}).then(function(d){ busy=false;
    S.online=d.online; S.from=d.from||S.from; S.to=d.to||S.to; status();
    if(d.contact&&!T.contact){ T.contact=true; store(T); if(open) chatForm(); }
    (d.messages||[]).forEach(function(m){ if(seen[m.id]) return; bubble(m); last=m.at; if(!m.me){ gotTeam++; if(!open||document.visibilityState==='hidden') unread++; } });
    if(open&&!gotTeam) showAway();
    paint();
  },function(e){ busy=false; if(/ended/.test(String(e&&e.message))){ reset(); } });
}
function paint(){ badge.hidden=!unread; badge.textContent=String(unread); }
function tick(){ clearTimeout(timer); var ms=open?4000:(T?20000:0); if(!ms) return; timer=setTimeout(function(){ if(document.visibilityState!=='hidden') poll(); tick(); },ms); }

function show(){ try{ if(window.PK&&PK.track) PK.track("chat"); }catch(e){}
  open=true; pan.hidden=false; btn.hidden=true; unread=0; paint();
  if(!T){ intro(); startForm(); call({mode:'status'}).then(function(d){ S.online=d.online; S.from=d.from||S.from; S.to=d.to||S.to; status(); showAway(); fixHint(); },function(){ S.online=false; status(); showAway(); fixHint(); }); }
  else { chatForm(); poll().then(function(){ msgs.scrollTop=msgs.scrollHeight; }); }
  tick();
}
function hide(){ open=false; pan.hidden=true; btn.hidden=false; tick(); btn.focus(); }
btn.onclick=show; x.onclick=hide;
document.addEventListener('keydown',function(e){ if(e.key==='Escape'&&open) hide(); });
// links like <a href="#chat"> open the chat
document.addEventListener('click',function(e){ var a=e.target.closest&&e.target.closest('a[href="#chat"]'); if(a){ e.preventDefault(); show(); } });

intro();
if(T){ poll(); tick(); }
else call({mode:'status'}).then(function(d){ S.online=d.online; S.from=d.from||S.from; S.to=d.to||S.to; status(); },function(){});
window.PKChat={open:show};
})();
