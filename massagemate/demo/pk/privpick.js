/* Private lesson picker, used on the website (buying a private or a pack) and in the app (requesting a private).
   Pick the coach, the day and a free time. Then: is another coach OK if they cannot make it? If not, pick a backup
   time with the same coach. Free times come from the database (private_book_slots): coach hours minus booked,
   waiting and closed times.
   var p = PrivPick({load: function(from, days){ return Promise of slots }, coach: optional id});
   box.appendChild(p.el); p.check() -> error text or null; p.value() -> {coach, coach_name, date, time, any, alt_date, alt_time} */
(function(){
'use strict';
var CSS='.pp{display:flex;flex-direction:column;gap:14px;color:inherit;min-width:0;max-width:100%}.pp>div{min-width:0;max-width:100%}.pp h4{margin:0 0 6px;font-size:15px;font-weight:600}'+
'.pp-sub{margin:0;font-size:13px;opacity:.75}.pp-coaches{display:grid;grid-template-columns:repeat(auto-fill,minmax(140px,1fr));gap:8px}'+
'.pp-coach{display:flex;gap:10px;align-items:center;text-align:left;font:inherit;color:inherit;background:transparent;border:1.5px solid var(--pp-line,#D9D5C8);border-radius:12px;padding:8px 10px;cursor:pointer;min-height:56px}'+
'.pp-coach img,.pp-coach .pp-ini{width:40px;height:40px;border-radius:50%;object-fit:cover;flex:none;background:var(--pp-soft,#eee);display:flex;align-items:center;justify-content:center;font-weight:600;font-size:15px;color:#555}'+
'.pp-coach b{display:block;font-size:14px;line-height:1.2}.pp-coach small{display:block;font-size:12px;opacity:.7;line-height:1.3;margin-top:2px}'+
'.pp-coach[aria-pressed="true"]{border-color:var(--pp-on,#171B23);box-shadow:0 0 0 1.5px var(--pp-on,#171B23) inset}'+
'.pp-days{display:flex;gap:6px;overflow-x:auto;max-width:100%;padding-bottom:4px;scrollbar-width:thin}'+
'.pp-day,.pp-time,.pp-yn button{font:inherit;color:inherit;background:transparent;border:1.5px solid var(--pp-line,#D9D5C8);border-radius:10px;cursor:pointer}'+
'.pp-day{flex:none;min-width:58px;padding:6px 4px;display:flex;flex-direction:column;align-items:center;line-height:1.2}.pp-day span{font-size:11px;text-transform:uppercase;opacity:.7}.pp-day b{font-size:17px}.pp-day small{font-size:11px;opacity:.7}'+
'.pp-day:disabled{opacity:.35;cursor:default}.pp-more{flex:none;font:inherit;font-size:13px;color:inherit;background:transparent;border:1.5px dashed var(--pp-line,#D9D5C8);border-radius:10px;padding:6px 10px;cursor:pointer}'+
'.pp-times{display:grid;grid-template-columns:repeat(auto-fill,minmax(74px,1fr));gap:6px}.pp-time{padding:9px 4px;font-weight:600;font-size:15px}'+
'.pp-day[aria-pressed="true"],.pp-time[aria-pressed="true"],.pp-yn button[aria-pressed="true"]{background:var(--pp-on,#171B23);border-color:var(--pp-on,#171B23);color:var(--pp-on-ink,#fff)}'+
'.pp-pick{font-weight:600;padding:10px 12px;border-radius:10px;background:var(--pp-soft,#F3F1EA)}.pp-yn{display:flex;gap:8px;flex-wrap:wrap}.pp-yn button{padding:9px 14px;font-weight:600;min-height:42px}'+
'.pp-rate{font-weight:600;opacity:1!important}.pp-alt{display:flex;flex-direction:column;gap:10px;padding:12px;border:1.5px dashed var(--pp-line,#D9D5C8);border-radius:12px}.pp-empty{font-size:14px;opacity:.8;margin:0}';
function css(){ if(document.getElementById('pp-css')) return; var s=document.createElement('style'); s.id='pp-css'; s.textContent=CSS; document.head.appendChild(s); }
function el(tag,attrs){ var e=document.createElement(tag); if(attrs) for(var k in attrs){ var v=attrs[k]; if(v==null||v===false) continue; if(k==='text') e.textContent=v; else if(k.slice(0,2)==='on') e.addEventListener(k.slice(2),v); else e.setAttribute(k,v===true?'':v); }
  for(var i=2;i<arguments.length;i++) add(e,arguments[i]); return e; }
function add(e,c){ if(c==null||c===false) return; if(Array.isArray(c)) c.forEach(function(x){ add(e,x); }); else e.appendChild(c.nodeType?c:document.createTextNode(String(c))); }
function dt(d){ return new Date(d+'T00:00:00Z'); }
function dayName(d){ return dt(d).toLocaleDateString('en-GB',{weekday:'short',timeZone:'UTC'}); }
function longDay(d){ return dt(d).toLocaleDateString('en-GB',{weekday:'long',day:'numeric',month:'long',timeZone:'UTC'}); }
function plus(d,n){ var x=dt(d); x.setUTCDate(x.getUTCDate()+n); return x.toISOString().slice(0,10); }
function initials(n){ return String(n||'?').split(/\s+/).map(function(w){ return w.charAt(0); }).join('').slice(0,2).toUpperCase(); }

window.PrivPick=function(opts){
  css();
  var S={data:null,coach:opts.coach||null,date:null,time:null,any:null,alt_date:null,alt_time:null,loading:false,err:null,until:null};
  var root=el('div',{class:'pp'});
  function coachOf(id){ return (S.data&&S.data.coaches||[]).filter(function(c){ return c.id===id; })[0]||null; }
  function freeOn(d,id){ var day=(S.data.days||[]).filter(function(x){ return x.date===d; })[0]; return day&&day.free&&day.free[id]||[]; }
  function merge(x){ if(!S.data){ S.data=x; } else { var have={}; S.data.days.forEach(function(d){ have[d.date]=1; }); x.days.forEach(function(d){ if(!have[d.date]) S.data.days.push(d); }); }
    S.until=S.data.days.length?S.data.days[S.data.days.length-1].date:null; }
  function load(from){ S.loading=true; draw();
    return opts.load(from||null,14).then(function(x){ S.loading=false; S.err=null; merge(x);
      if(S.coach&&!coachOf(S.coach)) S.coach=null; if(!S.coach&&S.data.coaches.length===1) S.coach=S.data.coaches[0].id; draw(); },
      function(e){ S.loading=false; S.err=(e&&e.message)||'The free times could not load. Check your connection and try again.'; draw(); }); }
  function more(){ if(S.until) load(plus(S.until,1)); }
  function days(id,sel,onPick,skip){
    var row=el('div',{class:'pp-days',role:'group','aria-label':'Day'});
    S.data.days.forEach(function(d){ var n=freeOn(d.date,id).filter(function(t){ return !(skip&&skip.date===d.date&&skip.time===t); }).length;
      row.appendChild(el('button',{type:'button',class:'pp-day','aria-pressed':String(sel===d.date),disabled:n?null:true,title:n?n+' free times':'No free time',onclick:function(){ onPick(d.date); }},
        el('span',{text:d.date===S.data.today?'Today':dayName(d.date)}),el('b',{text:String(dt(d.date).getUTCDate())}),el('small',{text:dt(d.date).toLocaleDateString('en-GB',{month:'short',timeZone:'UTC'})}))); });
    row.appendChild(el('button',{type:'button',class:'pp-more',onclick:more},S.loading?'Loading':'Later days'));
    return row; }
  function times(id,d,sel,onPick,skip){
    var list=freeOn(d,id).filter(function(t){ return !(skip&&skip.date===d&&skip.time===t); });
    if(!list.length) return el('p',{class:'pp-empty',text:'No free time that day. Pick another day.'});
    return el('div',{class:'pp-times',role:'group','aria-label':'Start time'},list.map(function(t){ return el('button',{type:'button',class:'pp-time','aria-pressed':String(sel===t),onclick:function(){ onPick(t); }},t); })); }
  function draw(){
    if(opts.onChange) setTimeout(function(){ try{ opts.onChange(); }catch(e){} },0);
    root.replaceChildren();
    if(S.err&&!S.data){ root.appendChild(el('p',{class:'pp-empty',text:S.err})); root.appendChild(el('button',{type:'button',class:'pp-more',onclick:function(){ load(); }},'Try again')); return; }
    if(!S.data){ root.appendChild(el('p',{class:'pp-empty',text:'Loading the free times.'})); return; }
    if(!S.data.coaches.length){ root.appendChild(el('p',{class:'pp-empty',text:'No coach is taking online bookings right now. Book your time later, or message us.'})); return; }
    root.appendChild(el('div',null,el('h4',{text:'1. Choose your coach'}),el('div',{class:'pp-coaches'},S.data.coaches.map(function(c){
      return el('button',{type:'button',class:'pp-coach','aria-pressed':String(S.coach===c.id),onclick:function(){ if(S.coach!==c.id){ S.coach=c.id; S.time=null; S.alt_date=null; S.alt_time=null; if(S.date&&!freeOn(S.date,c.id).length) S.date=null; } draw(); }},
        c.photo?el('img',{src:c.photo,alt:'',loading:'lazy'}):el('span',{class:'pp-ini','aria-hidden':'true',text:initials(c.name)}),
        el('span',null,el('b',{text:c.name}),c.bio?el('small',{text:c.bio}):null,c.rate?el('small',{class:'pp-rate',text:'Own rate: '+Number(c.rate).toLocaleString('en-US')+' THB'+(opts.rateNote?' '+opts.rateNote(c):'')}):null)); }))));
    if(!S.coach) return;
    var co=coachOf(S.coach);
    root.appendChild(el('div',null,el('h4',{text:'2. Choose the day'}),days(S.coach,S.date,function(d){ S.date=d; S.time=null; draw(); })));
    if(S.date) root.appendChild(el('div',null,el('h4',{text:'3. Choose the time'}),times(S.coach,S.date,S.time,function(t){ S.time=t; if(S.alt_date===S.date&&S.alt_time===t) S.alt_time=null; draw(); })));
    if(!S.time) return;
    root.appendChild(el('div',{class:'pp-pick'},longDay(S.date)+', '+S.time+' with '+co.name));
    root.appendChild(el('div',null,el('h4',{text:'If '+co.name+' cannot make it, we will give you another coach. Is that OK?'}),
      el('div',{class:'pp-yn'},el('button',{type:'button','aria-pressed':String(S.any===true),onclick:function(){ S.any=true; S.alt_date=null; S.alt_time=null; draw(); }},'Yes, that is OK'),
        el('button',{type:'button','aria-pressed':String(S.any===false),onclick:function(){ S.any=false; draw(); }},'No, only '+co.name))));
    if(S.any===false){ var skip={date:S.date,time:S.time};
      root.appendChild(el('div',{class:'pp-alt'},el('h4',{text:'Add a backup time with '+co.name}),el('p',{class:'pp-sub',text:'If the first time does not work, we book this one, so one of them happens.'}),
        days(S.coach,S.alt_date,function(d){ S.alt_date=d; S.alt_time=null; draw(); },skip),
        S.alt_date?times(S.coach,S.alt_date,S.alt_time,function(t){ S.alt_time=t; draw(); },skip):null,
        S.alt_time?el('div',{class:'pp-pick'},'Backup: '+longDay(S.alt_date)+', '+S.alt_time):null)); }
  }
  load();
  return {el:root,
    check:function(){ if(S.data&&!S.data.coaches.length) return null; if(!S.coach) return 'Choose your coach.'; if(!S.date) return 'Choose the day.'; if(!S.time) return 'Choose the time.';
      if(S.any==null) return 'Tell us if another coach is OK.'; if(S.any===false&&!(S.alt_date&&S.alt_time)) return 'Choose a backup time with '+coachOf(S.coach).name+'.'; return null; },
    value:function(){ var c=coachOf(S.coach); return {coach:S.coach,coach_name:c?c.name:'',rate:c&&c.rate?Number(c.rate):null,date:S.date,time:S.time,any:S.any!==false,alt_date:S.any===false?S.alt_date:null,alt_time:S.any===false?S.alt_time:null}; },
    reload:function(){ S.data=null; return load(); },
    text:function(){ var v=this.value(); if(!v.time) return ''; return longDay(v.date)+', '+v.time+' with '+v.coach_name+(v.alt_date?'. Backup: '+longDay(v.alt_date)+', '+v.alt_time:''); }};
};
window.PrivPick.longDay=longDay;
})();
