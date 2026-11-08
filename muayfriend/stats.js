/* Muay Friend website numbers: page views and key clicks, for the team dashboard (muayfriend.com/dash/).
   No cookies and nothing stored on the visitor's device. The visitor count is a daily hash made on the server. */
(function(){
  var URL='https://bnglnfdgptvnmugntiom.supabase.co/rest/v1/rpc/mf_hit', KEY='sb_publishable_I2cEA2hEPelGTNMwf2zWwA_98_mxHT1';
  if(/bot|crawl|spider|headless/i.test(navigator.userAgent)||location.hostname.indexOf('muayfriend.com')<0) { window.mfT=function(){}; return; }
  var q=new URLSearchParams(location.search), tz='';
  try{ tz=Intl.DateTimeFormat().resolvedOptions().timeZone||''; }catch(e){}
  var guess={'Asia/Bangkok':'TH','Europe/London':'GB','Australia/Sydney':'AU','Australia/Melbourne':'AU','Asia/Dubai':'AE','Asia/Singapore':'SG','Europe/Berlin':'DE','Europe/Paris':'FR','Asia/Kolkata':'IN','Asia/Riyadh':'SA','Asia/Kuwait':'KW','Europe/Moscow':'RU'}[tz]||(tz.indexOf('America/')===0?'US?':'');
  function send(kind){
    var d={kind:kind,path:location.pathname,lang:document.documentElement.lang||'en',ref:kind==='view'?document.referrer:'',
      utm_source:q.get('utm_source')||q.get('ref')||(q.get('fbclid')?'facebook':''),utm_medium:q.get('utm_medium')||'',utm_campaign:q.get('utm_campaign')||'',country:guess};
    try{ fetch(URL,{method:'POST',keepalive:true,headers:{'Content-Type':'application/json',apikey:KEY},body:JSON.stringify({p:d})}).catch(function(){}); }catch(e){}
  }
  window.mfT=send;
  send('view');
  var seen={};
  document.addEventListener('click',function(e){
    var a=e.target.closest&&e.target.closest('a,button'); if(!a) return;
    var h=a.getAttribute('href')||'', k='';
    if(h==='#free'||/^#plan-/.test(h)) k='start';
    else if(/(^|\/)demo\/?$/.test(h)) k='demo';
    else if(h==='#contact'||h.indexOf('mailto:')===0) k='contact';
    else if(/wa\.me|whatsapp/i.test(h)) k='whatsapp';
    else if(/line\.me/i.test(h)) k='line';
    else if(h==='#pricing'||a.hasAttribute('data-bill')||a.hasAttribute('data-cur')) k='price';
    if(!k) return;
    if(k==='price'&&seen.price) return; seen[k]=1; /* one price look per page view */
    send(k);
  },true);
})();
