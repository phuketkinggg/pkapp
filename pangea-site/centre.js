// A Pangea centre's own page (/<web address>): everything comes from the Pangea back office (Settings, Website, Centres and their
// websites). A centre run by another business can show that business's live prices, class times and coaches (data address).
(function () {
  var PG = 'https://tqqfhahchjwihwknyiwo.supabase.co/rest/v1/rpc/', KEY = 'sb_publishable_ei0gMLn3YmXoOO-3O6t_Og_qECOjLb1';
  var slug = location.pathname.replace(/^\/+|\/+$/g, '').toLowerCase();
  var main = document.getElementById('main');
  function esc(s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); }
  function safeUrl(u) { return /^https:\/\/[^\s"<>]+$/.test(u || '') ? u : ''; }
  function rpc(n, body) { return fetch(PG + n, { method: 'POST', headers: { apikey: KEY, 'Content-Type': 'application/json' }, body: JSON.stringify(body || {}) }).then(function (r) { return r.json().then(function (j) { if (!r.ok) throw new Error(j && j.message || 'Something went wrong.'); return j; }); }); }
  function wa(n) { return 'https://wa.me/' + String(n || '').replace(/[^0-9]/g, ''); }
  function notFound() {
    document.title = 'Page not found | Pangea Global Wellness';
    main.innerHTML = '<section class="white"><div class="wrap"><h1>This page does not exist.</h1><p class="lead" style="margin-top:22px">It may have moved. See every Pangea centre on the main page.</p><div class="btns"><a class="btn" href="/#centres">All centres</a></div></div></section>';
  }
  rpc('pangea_site').then(function (d) {
    var c = (d.centres || []).filter(function (x) { return (x.slug || '').toLowerCase() === slug; })[0];
    if (!c) return notFound();
    var open = c.status === 'open', hero = safeUrl(c.hero), book = safeUrl(c.book), map = safeUrl(c.map), data = safeUrl(c.data);
    var short = String(c.name || '').replace(/^Pangea\s+/i, '');
    document.title = c.name + (c.focus ? ' | ' + c.focus : '') + ' | Pangea Global Wellness';
    var md = document.querySelector('meta[name=description]'); if (md && (c.blurb || c.tagline)) md.setAttribute('content', c.blurb || c.tagline);
    document.getElementById('c-short').textContent = short;
    var top = document.getElementById('c-topbtn');
    if (open && book) { top.textContent = 'Book'; top.href = book; } else if (!open) { top.textContent = 'Tell me when it opens'; top.href = '#notify'; }
    var nav = [['#about', 'About'], (c.highlights || []).length ? ['#there', 'What is there'] : null, data ? ['#times', 'Times and prices'] : null, !open ? ['#notify', 'Opening'] : null, ['#find', 'Find us'], ['/', 'Pangea Global']].filter(Boolean);
    document.getElementById('nav').innerHTML = nav.map(function (n) { return '<a href="' + n[0] + '">' + esc(n[1]) + '</a>'; }).join('');
    var paras = String(c.about || '').split(/\n\s*\n/).map(function (p) { return p.trim(); }).filter(Boolean);
    var h = [];
    h.push('<section class="phero' + (hero ? '' : ' noimg') + '" aria-labelledby="h-hero">' + (hero ? '<img src="' + esc(hero) + '" alt="' + esc(c.name) + '" fetchpriority="high">' : '') +
      '<div class="wrap"><p class="where">' + esc(String(c.place || '').toUpperCase()) + (open ? '' : (c.place ? ' · ' : '') + 'PLANNED') + '</p><h1 id="h-hero">' + esc(c.tagline || c.name) + '</h1>' +
      (c.blurb ? '<p class="lead">' + esc(c.blurb) + '</p>' : '') + '<div class="btns">' +
      (open && book ? '<a class="btn light" href="' + esc(book) + '">Book</a>' : '') + (!open ? '<a class="btn light" href="#notify">Tell me when it opens</a>' : '') +
      '<a class="btn line" style="color:#fff;border-color:#fff" href="#about">About ' + esc(short) + '</a></div></div></section>');
    h.push('<section class="white" id="about" aria-labelledby="h-about"><div class="wrap"><div class="split"><h2 id="h-about">' + esc(c.name) + (c.focus ? ', known for ' + esc(c.focus.charAt(0).toLowerCase() + c.focus.slice(1)) + '.' : '.') + '</h2><div class="prose">' +
      (paras.length ? paras.map(function (p) { return '<p>' + esc(p) + '</p>'; }).join('') : '<p>Every Pangea centre looks after the whole of you: training, recovery, food and your health, with the same app and the same team behind you wherever you go.</p>') + '</div></div></div></section>');
    if ((c.highlights || []).length) h.push('<section class="sage" id="there" aria-labelledby="h-there"><div class="wrap"><h2 id="h-there">What is there.</h2><ol class="steps hl">' +
      c.highlights.map(function (x) { return '<li><h3>' + esc(x.title) + '</h3>' + (x.text ? '<p>' + esc(x.text) + '</p>' : '') + '</li>'; }).join('') + '</ol></div></section>');
    if (data) h.push('<section id="train" aria-labelledby="h-team"><div class="wrap"><h2 id="h-team">Your coaches.</h2><div class="coaches"></div></div></section>' +
      '<section class="white" id="times" aria-labelledby="h-times"><div class="wrap"><h2 id="h-times">Times and prices.</h2><div class="times"><div><div id="days"></div><div id="timetable"><div class="cls"><div>Loading the timetable.</div></div></div></div>' +
      '<div><h3 style="margin-bottom:14px">Prices</h3><div id="prices" data-all="1"><div class="price"><small>Loading prices.</small><b></b></div></div></div></div></div></section>');
    if (!open) h.push('<section class="deep" id="notify" aria-labelledby="h-notify"><div class="wrap"><div class="split"><h2 id="h-notify">Be first to know when ' + esc(short) + ' opens.</h2>' +
      '<form class="notify" novalidate><label for="n-name">Your name</label><input id="n-name" autocomplete="name"><label for="n-email">Your email</label><input id="n-email" type="email" autocomplete="email" required>' +
      '<label for="n-note">Anything you would like to tell us (optional)</label><textarea id="n-note" rows="3"></textarea><button class="btn light" type="submit">Tell me when it opens</button><p class="nmsg" role="status"></p></form></div></div></section>');
    var contact = [c.whatsapp ? '<a href="' + wa(c.whatsapp) + '">WhatsApp ' + esc(c.whatsapp) + '</a>' : '', c.email ? '<a href="mailto:' + esc(c.email) + '">' + esc(c.email) + '</a>' : ''].filter(Boolean).join('<br>');
    h.push('<section id="find" aria-labelledby="h-find"><div class="wrap map"><div><h2 id="h-find">Find ' + esc(short) + '.</h2>' + (c.address ? '<p class="lead" style="margin-top:22px">' + esc(c.address) + '</p>' : c.place ? '<p class="lead" style="margin-top:22px">' + esc(c.place) + '</p>' : '') + '</div>' +
      '<div>' + (contact ? '<p>' + contact + '</p>' : '') + '<div class="btns">' + (open && book ? '<a class="btn" href="' + esc(book) + '">Book</a>' : '') + (map ? '<a class="btn line" href="' + esc(map) + '">Open in Google Maps</a>' : '') + '</div></div></div></section>');
    main.innerHTML = h.join('');
    document.getElementById('c-foot').innerHTML = '<h4>' + esc(c.name) + '</h4>' + (open && book ? '<a href="' + esc(book) + '">Book</a>' : '') + (c.whatsapp ? '<a href="' + wa(c.whatsapp) + '">WhatsApp</a>' : '') + (c.email ? '<a href="mailto:' + esc(c.email) + '">' + esc(c.email) + '</a>' : '') + (map ? '<a href="' + esc(map) + '">Map</a>' : '');
    if (c.whatsapp) { var w = document.createElement('a'); w.className = 'wa'; w.href = wa(c.whatsapp); w.textContent = 'WhatsApp'; document.body.appendChild(w); }
    var f = main.querySelector('form.notify');
    if (f) f.addEventListener('submit', function (e) { e.preventDefault(); var m = f.querySelector('.nmsg'), b = f.querySelector('button'), em = f.querySelector('#n-email').value.trim();
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(em)) { m.textContent = 'Type your email.'; return; } b.disabled = true; m.textContent = '';
      rpc('pangea_interest_add', { p_slug: slug, p_name: f.querySelector('#n-name').value, p_email: em, p_note: f.querySelector('#n-note').value })
        .then(function () { f.innerHTML = '<p class="lead">Thank you. We will email you when ' + esc(short) + ' opens.</p>'; }).catch(function (er) { m.textContent = er.message; b.disabled = false; }); });
    if (location.hash) { var t = document.getElementById(location.hash.slice(1)); if (t) t.scrollIntoView(); }
    document.body.setAttribute('data-src', data || '');
    var s = document.createElement('script'); s.src = '/site.js?v=3'; document.body.appendChild(s);
  }).catch(function () { main.innerHTML = '<section class="white"><div class="wrap"><p class="lead">This page could not load. Check your connection and try again.</p></div></section>'; });
})();
