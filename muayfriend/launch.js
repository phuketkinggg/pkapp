/* Muay Friend launch offer box: the launch price is for the first 100 gyms or until the end date, whichever comes first.
   The numbers are real and come from the database (public.mf_launch). If the offer has ended, the box says so. */
(function(){
  var el=document.getElementById('launch'); if(!el) return;
  var th=document.documentElement.lang==='th';
  var T=th?{h:'ราคาเปิดตัว สำหรับ 100 ยิมแรก หรือถึง 30 พฤศจิกายน',s:'แล้วแต่อย่างใดถึงก่อน ล็อกราคานี้ไว้ตราบเท่าที่คุณใช้ต่อ',left:function(n){ return 'เหลืออีก '+n+' ที่'; },
      time:function(d,h,m){ return 'เหลือเวลา '+d+' วัน '+h+' ชม. '+m+' นาที'; },end:'โปรเปิดตัวจบแล้ว ขอบคุณยิมทั้ง 100 แห่งที่เข้าร่วม'}
    :{h:'Launch price for the first 100 gyms, or until 30 November',s:'Whichever comes first. Keep the launch price for as long as you stay.',left:function(n){ return n===1?'1 place left':n+' places left'; },
      time:function(d,h,m){ return d+' days '+h+' h '+m+' min left'; },end:'The launch offer has ended. Thank you to every gym that joined.'};
  var css=document.createElement('style');
  css.textContent='.launch{display:flex;flex-wrap:wrap;gap:12px 22px;align-items:center;justify-content:space-between;background:#101A2E;color:#fff;border-radius:18px;padding:16px 20px;margin:14px 0 6px}'+
    '.launch b{display:block;font-size:18px}.launch .s{color:#C9CFDB;font-size:14px}.launch .n{display:flex;gap:10px;flex-wrap:wrap}'+
    '.launch .n span{background:rgba(255,255,255,.1);border-radius:999px;padding:6px 14px;font-weight:600;font-size:15px;white-space:nowrap;font-variant-numeric:tabular-nums}'+
    '.launch .n span.hot{background:#D7263D}.launch .bar{flex-basis:100%;height:6px;background:rgba(255,255,255,.15);border-radius:99px;overflow:hidden}.launch .bar i{display:block;height:100%;background:#D7263D}';
  document.head.appendChild(css);
  function draw(d){
    if(!d) return;
    if(!d.open){ el.innerHTML='<div><b>'+T.end+'</b></div>'; el.hidden=false; return; }
    var ends=new Date(d.ends).getTime();
    function tick(){
      var ms=Math.max(0,ends-Date.now()), m=Math.floor(ms/60000), dd=Math.floor(m/1440), hh=Math.floor(m%1440/60), mm=m%60;
      if(ms<=0){ el.innerHTML='<div><b>'+T.end+'</b></div>'; return; }
      el.innerHTML='<div><b>'+T.h+'</b><span class="s">'+T.s+'</span></div><div class="n"><span class="hot">'+T.left(d.left)+'</span><span>'+T.time(dd,hh,mm)+'</span></div>'+
        '<div class="bar" aria-hidden="true"><i style="width:'+Math.max(3,Math.round(d.used/d.cap*100))+'%"></i></div>';
    }
    tick(); el.hidden=false; setInterval(tick,30000);
  }
  fetch('https://bnglnfdgptvnmugntiom.supabase.co/rest/v1/rpc/mf_launch',{method:'POST',headers:{'Content-Type':'application/json',apikey:'sb_publishable_I2cEA2hEPelGTNMwf2zWwA_98_mxHT1'},body:'{}'})
    .then(function(r){ return r.ok?r.json():null; }).then(draw).catch(function(){});
})();
