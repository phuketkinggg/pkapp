/* Invoice and receipt documents. Used by the app (print, save as PDF) and by the customer's page (invoice.html).
   INVDOC.html(invoice, template, {mode:'invoice'|'receipt', payUrl, promptpay:{payload,name}}) returns a full HTML page. */
(function(){
'use strict';
var DEF={prefix:'INV-',receipt_prefix:'RC-',pad:4,color:'#B8892E',terms:'Payment due within 7 days of the invoice date.',
  footer:'Thank you for your business.',
  biz:{'Muay Fight Gym':{name:'Muay Fight Gym Muay Thai',address:'42/9 Moo 5, Chiang Mai 83120, Thailand',phone:'+66 96 907 6150',email:'hello@muayfriend.com',website:'phuketking.com',logo:'https://muayfriend.com/demo/icons/icon-512.png'},
       'Camp Rooms':{name:'Camp Rooms',address:'Chiang Mai, Thailand',phone:'+66 96 907 6150',email:'hello@muayfriend.com',website:'phuketking.com',logo:''}}};
var METHOD={transfer:'Bank transfer',cash:'Cash',card:'Card',qr:'PromptPay',stripe:'Card (online)',cheque:'Cheque',other:'Other',room:'Room bill',pack:'From a pack'};
function esc(s){ return String(s==null?'':s).replace(/[&<>"']/g,function(c){ return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]; }); }
function money(n){ return Number(n||0).toLocaleString('en-US',{minimumFractionDigits:2,maximumFractionDigits:2}); }
function day(d){ if(!d) return ''; var x=new Date(String(d).slice(0,10)+'T00:00:00Z'); return x.toLocaleDateString('en-GB',{day:'numeric',month:'long',year:'numeric',timeZone:'UTC'}); }
function num(p,n,pad){ return (p||'')+String(n||0).padStart(pad||4,'0'); }
function tplOf(t,biz){ t=t||{}; var b=(t.biz&&t.biz[biz])||{}, first=(t.biz&&t.biz[Object.keys(t.biz)[0]])||DEF.biz[Object.keys(DEF.biz)[0]], d=DEF.biz[biz]||Object.assign({},first,{name:biz||first.name,logo:''}), o={};
  ['name','address','tax_id','phone','email','website','logo','bank_name','bank_account_name','bank_account_number','bank_branch','bank_swift','promptpay_id'].forEach(function(k){ o[k]=b[k]!=null&&b[k]!==''?b[k]:(d[k]||''); });
  ['prefix','receipt_prefix','pad','color','terms','footer'].forEach(function(k){ o[k]=t[k]!=null&&t[k]!==''?t[k]:DEF[k]; });
  return o; }
/* PromptPay: a QR with the amount in it */
function crc(s){ var c=0xFFFF; for(var i=0;i<s.length;i++){ c^=s.charCodeAt(i)<<8; for(var j=0;j<8;j++) c=(c&0x8000)?((c<<1)^0x1021)&0xFFFF:(c<<1)&0xFFFF; } return ('0000'+c.toString(16).toUpperCase()).slice(-4); }
function tlv(s){ var out=[],i=0; while(i<s.length){ if(i+4>s.length) return null; var id=s.substr(i,2),n=parseInt(s.substr(i+2,2),10); if(isNaN(n)||i+4+n>s.length) return null; out.push([id,s.substr(i+4,n)]); i+=4+n; } return out; }
function fromId(id){ var d=String(id||'').replace(/\D/g,''),sub; if(d.length===10&&d[0]==='0') sub='01'+'13'+('0066'+d.slice(1)).padStart(13,'0'); else if(d.length===13) sub='02'+'13'+d; else return null;
  function f(k,v){ return k+String(v.length).padStart(2,'0')+v; } var b=f('00','01')+f('01','11')+f('29',f('00','A000000677010111')+sub)+f('58','TH')+f('53','764')+'6304'; return b+crc(b); }
function withAmount(s,amt){ var t=tlv(String(s).trim()); if(!t) return null; t=t.filter(function(x){ return x[0]!=='54'&&x[0]!=='63'; }).map(function(x){ return x[0]==='01'?['01','12']:x; });
  if(!t.some(function(x){ return x[0]==='01'; })) t.push(['01','12']); var at=-1; t.forEach(function(x,i){ if(x[0]==='53') at=i; }); t.splice(at>=0?at+1:t.length,0,['54',(Math.round(amt*100)/100).toFixed(2)]);
  var b=t.map(function(x){ return x[0]+String(x[1].length).padStart(2,'0')+x[1]; }).join('')+'6304'; return b+crc(b); }
function dueNow(i){ if(i.due_now!=null) return Number(i.due_now); var d=Number(i.deposit)||0, t=Number(i.total)||0;
  return i.status==='unpaid'&&d>0?d:(i.status==='unpaid'||i.status==='deposit_paid')?t-(i.deposit_paid_on?d:0):0; }
function qrSvg(text){ if(!text||!window.qrcode) return ''; try{ var q=window.qrcode(0,'M'); q.addData(text); q.make(); return q.createSvgTag({cellSize:4,margin:1,scalable:true}); }catch(e){ return ''; } }

function html(inv,t,o){
  o=o||{}; var T=tplOf(t,inv.business), depR=o.mode==='deposit', receipt=o.mode==='receipt'||depR, col=T.color||'#B8892E';
  var dep=Number(inv.deposit)||0, depPaid=!!inv.deposit_paid_on, due=dueNow(inv), bal=Number(inv.total)-dep;
  var title=depR?'Deposit receipt':receipt?'Receipt':'Invoice', no=depR?num(T.receipt_prefix,inv.deposit_receipt,T.pad):receipt?(inv.receipt_ref||num(T.receipt_prefix,inv.receipt_number,T.pad)):num(T.prefix,inv.number,T.pad);
  var items=(inv.items||[]).map(function(it){ return '<tr><td>'+esc(it.desc)+'</td><td class="r">'+esc(Number(it.qty))+'</td><td class="r">'+money(it.price)+'</td><td class="r">'+money(it.amount!=null?it.amount:it.qty*it.price)+'</td></tr>'; }).join('');
  var tots='<tr><td>Subtotal</td><td class="r">'+money(inv.subtotal)+'</td></tr>'+(Number(inv.discount)?'<tr><td>Discount</td><td class="r">-'+money(inv.discount)+'</td></tr>':'')+
    (Number(inv.vat_rate)?'<tr><td>VAT '+esc(Number(inv.vat_rate))+'%</td><td class="r">'+money(inv.vat)+'</td></tr>':'');
  function tr(a,b,g){ return '<tr'+(g?' class="grand"':'')+'><td>'+a+'</td><td class="r">'+b+'</td></tr>'; }
  if(!dep) tots+=tr(receipt?'Total paid':'Total due','THB '+money(inv.total),true);
  else if(depR) tots+=tr('Total','THB '+money(inv.total))+tr('Deposit paid','THB '+money(dep),true)+tr('Balance to pay'+(inv.balance_due?' by '+esc(day(inv.balance_due)):''),'THB '+money(bal));
  else if(receipt) tots+=tr('Total','THB '+money(inv.total))+(depPaid?tr('Deposit paid '+esc(day(inv.deposit_paid_on)),money(dep))+tr('Balance paid '+esc(day(inv.paid_on)),money(bal)):'')+tr('Total paid','THB '+money(inv.total),true);
  else tots+=tr('Total','THB '+money(inv.total))+(depPaid?tr('Deposit paid '+esc(day(inv.deposit_paid_on)),'-'+money(dep)):tr('Deposit to pay now',money(dep)))+
    tr('Balance to pay'+(inv.balance_due?' by '+esc(day(inv.balance_due)):''),money(bal))+(inv.status!=='paid'?tr(depPaid?'Balance due':'Deposit due now','THB '+money(due),true):'');
  var to=[inv.to_company?'<b>'+esc(inv.to_company)+'</b>':'',inv.to_company&&inv.to_name&&inv.to_name!==inv.to_company?'Attn: '+esc(inv.to_name):(!inv.to_company?'<b>'+esc(inv.to_name)+'</b>':''),
    inv.to_address?esc(inv.to_address).replace(/\n/g,'<br>'):'',inv.to_tax_id?'Tax ID: '+esc(inv.to_tax_id):'',inv.to_email?esc(inv.to_email):'',inv.to_phone?esc(inv.to_phone):''].filter(Boolean).join('<br>');
  var from=['<b>'+esc(T.name)+'</b>',T.address?esc(T.address).replace(/\n/g,'<br>'):'',T.tax_id?'Tax ID: '+esc(T.tax_id):'',[T.phone,T.email].filter(Boolean).map(esc).join(' &middot; '),T.website?esc(T.website):''].filter(Boolean).join('<br>');
  var pm=depR?inv.deposit_method:inv.paid_method;
  var meta=receipt
    ?'<tr><th>Receipt no.</th><td>'+esc(no)+'</td></tr><tr><th>Date paid</th><td>'+esc(day(depR?inv.deposit_paid_on:inv.paid_on))+'</td></tr><tr><th>Paid by</th><td>'+esc(METHOD[pm]||pm||'')+'</td></tr>'+(inv.number!=null?'<tr><th>For invoice</th><td>'+esc(num(T.prefix,inv.number,T.pad))+'</td></tr>':'')
    :'<tr><th>Invoice no.</th><td>'+esc(no)+'</td></tr><tr><th>Date</th><td>'+esc(day(inv.issue_date))+'</td></tr>'+(dep?'<tr><th>Deposit due</th><td>'+esc(day(inv.due_date||inv.issue_date))+'</td></tr>'+(inv.balance_due?'<tr><th>Balance due</th><td>'+esc(day(inv.balance_due))+'</td></tr>':''):(inv.due_date?'<tr><th>Due</th><td>'+esc(day(inv.due_date))+'</td></tr>':''));
  var pay='';
  if(!receipt&&inv.status!=='paid'){
    var boxes=[];
    if(inv.pay_bank&&(T.bank_account_number||T.bank_name)) boxes.push('<div class="pbox"><h4>Bank transfer</h4><table class="kv">'+
      [['Bank',T.bank_name],['Account name',T.bank_account_name],['Account number',T.bank_account_number],['Branch',T.bank_branch],['SWIFT',T.bank_swift]].filter(function(r){ return r[1]; }).map(function(r){ return '<tr><th>'+r[0]+'</th><td>'+esc(r[1])+'</td></tr>'; }).join('')+
      '</table><p class="small">Please use '+esc(no)+' as the reference.</p></div>');
    var ppPayload=o.promptpay&&o.promptpay.payload?withAmount(o.promptpay.payload,due):(T.promptpay_id?withAmount(fromId(T.promptpay_id)||'',due):null);
    if(inv.pay_promptpay&&ppPayload) boxes.push('<div class="pbox center"><h4>PromptPay</h4><div class="qr">'+qrSvg(ppPayload)+'</div><p class="small">Scan with any Thai banking app. THB '+money(due)+(o.promptpay&&o.promptpay.name?'<br>To '+esc(o.promptpay.name):'')+'</p></div>');
    if(inv.pay_card&&o.payUrl) boxes.push('<div class="pbox center"><h4>Pay by card</h4><div class="qr">'+qrSvg(o.payUrl)+'</div><p class="small">Scan, or open:<br><a href="'+esc(o.payUrl)+'">'+esc(o.payUrl.replace(/^https?:\/\//,''))+'</a></p></div>');
    if(boxes.length) pay='<h3>How to pay'+(dep?(depPaid?': the balance, THB '+money(due):': the deposit, THB '+money(due)+' now'):'')+'</h3><div class="pay">'+boxes.join('')+'</div>';
  }
  var stamp=depR||(!receipt&&inv.status==='deposit_paid')?'<div class="stamp" style="font-size:24px">DEPOSIT PAID</div>':receipt||inv.status==='paid'?'<div class="stamp">PAID</div>':'';
  return '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>'+esc(title+' '+no)+'</title><style>'+
    '@page{size:A4;margin:14mm}*{box-sizing:border-box}body{margin:0;font-family:Helvetica,Arial,sans-serif;color:#1d1d1f;font-size:12.5px;line-height:1.45;background:#fff}'+
    '.doc{max-width:780px;margin:0 auto;padding:28px;position:relative}.top{display:flex;justify-content:space-between;gap:24px;align-items:flex-start;border-bottom:3px solid '+col+';padding-bottom:16px}'+
    '.logo{max-height:78px;max-width:180px}.from{text-align:right;font-size:12px;color:#444}h1{font-size:30px;letter-spacing:.06em;text-transform:uppercase;margin:22px 0 4px;color:'+col+'}'+
    '.row{display:flex;justify-content:space-between;align-items:flex-start;gap:24px;margin-top:10px}.to{font-size:12.5px}.lab{font-size:10.5px;letter-spacing:.12em;text-transform:uppercase;color:#888;margin-bottom:4px}'+
    'table{border-collapse:collapse;width:100%}.meta th{text-align:left;color:#888;font-weight:normal;padding:2px 12px 2px 0}.meta td{font-weight:bold;text-align:right}'+
    '.items{margin-top:22px}.items th{background:#f4f1ea;text-align:left;font-size:11px;letter-spacing:.06em;text-transform:uppercase;padding:8px;border-bottom:1px solid #ddd}.items td{padding:8px;border-bottom:1px solid #eee;vertical-align:top}'+
    '.r{text-align:right;white-space:nowrap}.tots{width:340px;max-width:100%;margin:12px 0 0 auto}.tots td{padding:5px 8px}.tots .grand td{border-top:2px solid #1d1d1f;font-size:15px;font-weight:bold}'+
    'h3{margin:26px 0 8px;font-size:14px}.pay{display:flex;gap:12px;flex-wrap:wrap}.pbox{flex:1 1 200px;border:1px solid #ddd;border-radius:8px;padding:12px}.pbox h4{margin:0 0 6px;color:'+col+'}.center{text-align:center}'+
    '.qr{width:140px;height:140px;margin:4px auto}.qr svg{width:100%;height:100%}.kv th{text-align:left;color:#888;font-weight:normal;padding:2px 10px 2px 0;white-space:nowrap}.kv td{font-weight:bold}.small{font-size:11px;color:#666;margin:6px 0 0}'+
    '.notes{margin-top:18px;white-space:pre-line}.foot{margin-top:28px;padding-top:10px;border-top:1px solid #ddd;color:#666;font-size:11px;text-align:center}'+
    '.totrow{display:flex;justify-content:space-between;align-items:center;gap:20px;margin-top:12px}.totrow .tots{margin:0 0 0 auto}.stamp{transform:rotate(-12deg);margin-left:20px;border:4px solid #2E7D32;color:#2E7D32;font-size:34px;font-weight:bold;letter-spacing:.15em;padding:4px 18px;border-radius:8px;opacity:.85}'+
    'a{color:'+col+'}@media print{.doc{padding:0}}'+
    '</style></head><body><div class="doc">'+
    '<div class="top"><div>'+(T.logo?'<img class="logo" src="'+esc(T.logo)+'" alt="">':'<b style="font-size:20px">'+esc(T.name)+'</b>')+'</div><div class="from">'+from+'</div></div>'+
    '<h1>'+title+'</h1><div class="row"><div class="to"><div class="lab">'+(receipt?'Received from':'Bill to')+'</div>'+to+'</div><table class="meta" style="width:auto">'+meta+'</table></div>'+
    '<table class="items"><thead><tr><th>Description</th><th class="r">Qty</th><th class="r">Price THB</th><th class="r">Amount THB</th></tr></thead><tbody>'+items+'</tbody></table>'+
    '<div class="totrow">'+stamp+'<table class="tots">'+tots+'</table></div>'+pay+
    (inv.notes?'<div class="notes"><div class="lab">Notes</div>'+esc(inv.notes)+'</div>':'')+
    (!receipt&&!dep&&T.terms&&inv.status!=='paid'?'<p class="small" style="margin-top:14px">'+esc(T.terms)+'</p>':'')+
    (receipt?'<p style="margin-top:18px">Received with thanks: THB '+money(depR?dep:inv.total)+'.'+(depR&&bal>0?' Balance of THB '+money(bal)+' to pay'+(inv.balance_due?' by '+esc(day(inv.balance_due)):'')+'.':'')+'</p>':'')+
    '<div class="foot">'+esc(T.footer||'')+'</div></div></body></html>';
}
window.INVDOC={html:html,tplOf:tplOf,num:num,DEF:DEF,METHOD:METHOD,dueNow:dueNow};
})();
