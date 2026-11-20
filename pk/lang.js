/* Website languages: on a page in /ru/, /zh/, /fr/ or /de/ this translates what the page draws after it loads (prices, timetable,
   forms, pages made in the app) with the words in /lang/<code>.js, and keeps links to our own pages inside the language.
   The page itself is already translated when the site is built (tools/site_langs.py). Text inside .notr stays as it is. */
(function(){
  var L=document.documentElement.getAttribute('data-lang'), D=window.PK_LANG_D;
  if(!L||!D) return;
  var P=window.PK_LANG_PATHS||{}, C={}, ATTR=['placeholder','title','alt','aria-label'];
  function tr(t){
    if(C[t]!==undefined) return C[t];
    var core=t.replace(/\s+/g,' ').trim(), out=t;
    if(core&&/[A-Za-z]/.test(core)&&D[core]){ var lead=t.match(/^\s*/)[0], trail=t.match(/\s*$/)[0]; out=lead+D[core]+trail; }
    C[t]=out; return out; }
  function skip(e){ return !e||(e.closest&&e.closest('script,style,textarea,.notr')); }
  function link(a){
    var h=a.getAttribute('href')||'', m=h.match(/^\/([a-z0-9-]*)(\.html)?([?#].*)?$/i);
    if(m&&P.hasOwnProperty(m[1]||'')) a.setAttribute('href','/'+L+'/'+(m[1]||'')+(m[3]||'')); }
  function el(e){
    if(skip(e)) return;
    ATTR.forEach(function(k){ var v=e.getAttribute(k); if(v){ var x=tr(v); if(x!==v) e.setAttribute(k,x); } });
    if(e.tagName==='A') link(e);
    if((e.tagName==='INPUT')&&(e.type==='submit'||e.type==='button')&&e.value){ var x=tr(e.value); if(x!==e.value) e.value=x; } }
  function txt(n){ if(skip(n.parentNode)) return; var v=tr(n.nodeValue); if(v!==n.nodeValue) n.nodeValue=v; }
  function walk(root){
    if(!root) return;
    if(root.nodeType===3){ txt(root); return; }
    if(root.nodeType!==1) return;
    el(root);
    root.querySelectorAll('[placeholder],[title],[alt],[aria-label],a[href],input[type=submit],input[type=button]').forEach(el);
    var w=document.createTreeWalker(root,NodeFilter.SHOW_TEXT,null), list=[], n;
    while((n=w.nextNode())) list.push(n);
    list.forEach(txt); }
  walk(document.body);
  new MutationObserver(function(ms){ ms.forEach(function(m){ if(m.type==='characterData') txt(m.target); else if(m.type==='attributes') el(m.target); else m.addedNodes.forEach(walk); }); })
    .observe(document.body,{childList:true,subtree:true,characterData:true,attributes:true,attributeFilter:['href','placeholder','title','aria-label']});
})();
