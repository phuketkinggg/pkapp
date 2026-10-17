/* Checkout for online courses: card (Stripe) or PromptPay QR straight to the gym bank account.
   Uses the same 'buy' function as the Prices page. The price always comes from the database. */
(function(){
'use strict';
var FN='https://jijnshwduhgegacfvpkh.supabase.co/functions/v1/buy', KEY='sb_publishable_Y-ecbe3vlPAa6QipGHD1zQ_W-sh8V4i', cur=null;
function $(id){ return document.getElementById(id); }
function call(b){ return fetch(FN,{method:'POST',headers:{'Content-Type':'application/json',apikey:KEY},body:JSON.stringify(b)}).then(function(r){ return r.json(); }).then(function(d){ if(d&&d.error) throw new Error(d.error); return d; }); }
function openDlg(d){ if(d.showModal) d.showModal(); else d.setAttribute('open',''); }
function ppCrc(str){ var c=0xFFFF; for(var i=0;i<str.length;i++){ c^=str.charCodeAt(i)<<8; for(var j=0;j<8;j++) c=(c&0x8000)?((c<<1)^0x1021)&0xFFFF:(c<<1)&0xFFFF; } return ('0000'+c.toString(16).toUpperCase()).slice(-4); }
function ppTlv(str){ var out=[], i=0; while(i<str.length){ if(i+4>str.length) return null; var id=str.substr(i,2), n=parseInt(str.substr(i+2,2),10); if(isNaN(n)||i+4+n>str.length) return null; out.push([id,str.substr(i+4,n)]); i+=4+n; } return out; }
function ppWithAmount(str,amt){ var t=(ppTlv(String(str).trim())||[]).filter(function(x){ return x[0]!=='54'&&x[0]!=='63'; }).map(function(x){ return x[0]==='01'?['01','12']:x; });
  if(!t.some(function(x){ return x[0]==='01'; })) t.push(['01','12']);
  var at=-1; t.forEach(function(x,i){ if(x[0]==='53') at=i; }); t.splice(at>=0?at+1:t.length,0,['54',(Math.round(amt*100)/100).toFixed(2)]);
  var b=t.map(function(x){ return x[0]+String(x[1].length).padStart(2,'0')+x[1]; }).join('')+'6304'; return b+ppCrc(b); }

var html='<dialog class="basket" id="cbuy" aria-labelledby="cbuyTitle"><div class="bhead"><h2 id="cbuyTitle">Buy</h2><button type="button" class="x" id="cbuyX" aria-label="Close">×</button></div>'+
  '<div id="cbuyWhat" style="padding:14px 20px 0"></div><div id="cppView" style="padding:14px 20px 22px" hidden></div>'+
  '<form id="cbuyForm" novalidate><label>Full name<input id="cb-name" autocomplete="name" required maxlength="80"></label>'+
  '<label>Email<input id="cb-email" type="email" autocomplete="email" required maxlength="120"></label>'+
  '<label>Phone or WhatsApp<input id="cb-phone" type="tel" autocomplete="tel" maxlength="30"></label>'+
  '<fieldset class="paypick"><legend>How do you want to pay?</legend><label><input type="radio" name="cbpay" value="card" checked> Card (Visa, Mastercard and more), on the secure Stripe page</label>'+
  '<label><input type="radio" name="cbpay" value="pp"> PromptPay QR from any Thai bank app</label></fieldset>'+
  '<p class="sub">Use this email to sign in to the Phuket King app: the course opens there in the Learn tab. We never see your card number.</p>'+
  '<p class="err" id="cberr" role="alert" hidden></p><button class="btn red" type="submit" id="cbPay">Pay</button></form></dialog>'+
  '<dialog class="basket" id="cdone" aria-labelledby="cdoneTitle"><div class="bhead"><h2 id="cdoneTitle">Payment</h2><button type="button" class="x" id="cdoneX" aria-label="Close">×</button></div><div id="cdoneBody" style="padding:16px 20px 22px" aria-live="polite"></div></dialog>';
var wrap=document.createElement('div'); wrap.innerHTML=html; while(wrap.firstChild) document.body.appendChild(wrap.firstChild);
$('cbuyX').onclick=function(){ $('cbuy').close(); }; $('cdoneX').onclick=function(){ $('cdone').close(); };
var APP='https://app.phuketking.com/#c_learn';
function opened(email){ return '<p style="font-size:20px;margin:0 0 8px"><b>The course is yours.</b></p><p>Open the <a href="'+APP+'" target="_blank" rel="noopener">Phuket King app</a> and sign in'+(email?' with <b>'+PK.esc(email)+'</b>':' with the email you used')+'. The course is in the <b>Learn</b> tab.</p><p class="sub">Questions? <a href="'+PK.wa('Hi Phuket King, I just bought a course on the website.')+'" target="_blank" rel="noopener">WhatsApp us</a>.</p>'; }

window.PKBuy={open:function(c){ cur=c; $('cbuyTitle').textContent='Buy the course';
  $('cbuyWhat').innerHTML='<p style="margin:0 0 6px"><b>'+PK.esc(c.title)+'</b><br><span style="font-size:26px;font-weight:700">'+PK.thb(c.price)+'</span></p>'+(c.members_free?'<p class="sub" style="margin:0">Already a member with an active package? It is free for you in the app, no need to buy.</p>':'');
  $('cbuyForm').hidden=false; $('cppView').hidden=true; $('cbuyWhat').hidden=false; $('cbPay').disabled=false; $('cbPay').textContent='Pay '+PK.thb(c.price); $('cberr').hidden=true;
  try{ var m=JSON.parse(localStorage.getItem('pk_buyer')||'{}'); ['name','email','phone'].forEach(function(k){ if(m[k]&&!$('cb-'+k).value) $('cb-'+k).value=m[k]; }); }catch(e){}
  openDlg($('cbuy')); }};

$('cbuyForm').addEventListener('submit',function(e){ e.preventDefault(); if(!cur) return;
  var err=$('cberr'), btn=$('cbPay'), name=$('cb-name').value.trim(), email=$('cb-email').value.trim(), pay=(document.querySelector('input[name=cbpay]:checked')||{}).value||'card';
  err.hidden=true;
  if(name.length<2){ err.textContent='Type your full name.'; err.hidden=false; $('cb-name').focus(); return; }
  if(!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)){ err.textContent='Type your email. You sign in to the app with it to watch the course.'; err.hidden=false; $('cb-email').focus(); return; }
  try{ localStorage.setItem('pk_buyer',JSON.stringify({name:name,email:email,phone:$('cb-phone').value.trim()})); }catch(x){}
  btn.disabled=true; btn.textContent=pay==='pp'?'Making your QR':'Opening the secure payment page';
  call({mode:'order',pay:pay,course_id:cur.id,name:name,email:email,phone:$('cb-phone').value.trim(),back:location.href.split('#')[0].replace(/[?&](paid|ref)=[^&]*/g,'')})
    .then(function(d){ if(d.pp) showPP(d,email); else location.href=d.url; })
    .catch(function(x){ btn.disabled=false; btn.textContent='Pay '+PK.thb(cur.price); err.textContent=x.message; err.hidden=false; });
});
function showPP(d,email){
  $('cbuyForm').hidden=true; $('cbuyWhat').hidden=true; var v=$('cppView'); v.hidden=false; $('cbuyTitle').textContent='Pay with PromptPay';
  var svg=''; try{ var q=window.qrcode(0,'M'); q.addData(ppWithAmount(d.pp.payload,d.amount)); q.make(); svg=q.createSvgTag({cellSize:6,margin:2,scalable:true}); }catch(e){ svg=''; }
  v.innerHTML='<p style="margin:0 0 4px"><b>'+PK.esc(d.what)+'</b></p><p style="font-size:28px;font-weight:700;margin:0 0 10px">'+PK.thb(d.amount)+'</p>'+
    (svg?'<div class="ppqr">'+svg+'</div>':'<p class="err">The QR could not be drawn. WhatsApp us and we will send it.</p>')+
    (d.pp.name?'<p class="sub" style="text-align:center">To '+PK.esc(String(d.pp.name).replace(/\.$/,''))+'. Check the name in your bank app before you pay.</p>':'')+
    '<ol class="ppsteps"><li>Screenshot this QR, or scan it with another phone.</li><li>Open your Thai bank app, scan the QR and pay. The amount is already filled in.</li><li>Come back here and tap <b>I have paid</b>.</li></ol>'+
    '<p class="err" id="cpperr" role="alert" hidden></p><button type="button" class="btn red" id="cppDone" style="width:100%">I have paid</button>';
  $('cppDone').onclick=function(){ var b=this; b.disabled=true; $('cpperr').hidden=true;
    call({mode:'claim',ref:d.id}).then(function(){ $('cbuy').close(); wait(d.id,true,email); }).catch(function(x){ b.disabled=false; $('cpperr').textContent=x.message; $('cpperr').hidden=false; }); };
}
function wait(ref,pp,email){ var box=$('cdoneBody'), tries=0; openDlg($('cdone'));
  function draw(s){
    if(s&&s.paid){ $('cdoneTitle').textContent='You are in'; box.innerHTML=opened(email); return true; }
    if(s&&s.rejected){ $('cdoneTitle').textContent='Payment not found'; box.innerHTML='<p>The front desk could not find your PromptPay payment. If you paid, <a href="'+PK.wa('Hi Phuket King, I paid by PromptPay for a course on the website.')+'" target="_blank" rel="noopener">WhatsApp us</a> your payment slip.</p>'; return true; }
    $('cdoneTitle').textContent=pp?'Thank you':'Checking your payment';
    box.innerHTML=pp?'<p><b>The front desk is checking your PromptPay payment.</b> This usually takes a few minutes during opening hours. The course unlocks in the app as soon as it is confirmed.</p>'
      :'<p>'+(tries>12?'This is taking longer than usual. Your payment went to Stripe. The course unlocks in the app as soon as it is confirmed.':'One moment.')+'</p>'; return false; }
  function poll(){ call({mode:'status',ref:ref}).then(function(s){ if(!draw(s)&&++tries<(pp?120:40)) setTimeout(poll,pp?5000:2500); },function(){ if(++tries<40) setTimeout(poll,5000); }); }
  draw(null); poll();
}
(function(){ var q=new URLSearchParams(location.search), ref=q.get('ref'), paid=q.get('paid'); if(!ref||!/^[0-9a-f-]{36}$/.test(ref)) return;
  var keep=q.get('c'); try{ history.replaceState(null,'',location.pathname+(keep?'?c='+encodeURIComponent(keep):'')); }catch(e){}
  if(paid!=='1'){ openDlg($('cdone')); $('cdoneTitle').textContent='Not paid'; $('cdoneBody').innerHTML='<p>Nothing was charged. You can try again any time.</p>'; return; }
  var em=''; try{ em=(JSON.parse(localStorage.getItem('pk_buyer')||'{}')).email||''; }catch(e){}
  wait(ref,false,em);
})();
})();
