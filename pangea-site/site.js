// Pangea website: menu, and live class times and prices from the Phuket King system (Supabase).
(function () {
  var FN = 'https://jijnshwduhgegacfvpkh.supabase.co/functions/v1/site';
  var DAYS = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
  function esc(s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); }
  function thb(n) { return Number(n).toLocaleString('en-US') + ' THB'; }
  function weekday() { return (new Date(Date.now() + 7 * 3600e3).getUTCDay() + 6) % 7; }

  var m = document.querySelector('.menu'), nav = document.querySelector('nav.links');
  if (m && nav) {
    m.addEventListener('click', function () { var o = nav.classList.toggle('open'); m.setAttribute('aria-expanded', o ? 'true' : 'false'); });
    nav.addEventListener('click', function (e) { if (e.target.tagName === 'A') { nav.classList.remove('open'); m.setAttribute('aria-expanded', 'false'); } });
  }
  var y = document.getElementById('year'); if (y) y.textContent = new Date().getFullYear();

  var tt = document.getElementById('timetable'), pr = document.getElementById('prices');
  if (!tt && !pr) return;
  fetch(FN).then(function (r) { if (!r.ok) throw new Error(r.status); return r.json(); }).then(function (d) {
    if (tt) {
      var cls = (d.classes || []).filter(function (c) { return !c.off; });
      var bar = document.getElementById('days'), cur = weekday();
      function draw(day) {
        Array.prototype.forEach.call(bar.children, function (b, i) { b.classList.toggle('on', i === day); });
        var l = cls.filter(function (c) { return c.day === day; });
        tt.innerHTML = l.length ? l.map(function (c) {
          return '<div class="cls"><b>' + esc(c.time) + (c.end ? ' to ' + esc(c.end) : '') + '</b><div>' + esc(c.title) + '</div><span>' + esc(c.discipline || '') + '</span></div>';
        }).join('') : '<div class="cls"><div>No group classes on ' + DAYS[day] + '. Private sessions and the open gym still run.</div></div>';
      }
      bar.innerHTML = DAYS.map(function (n, i) { return '<button type="button">' + n.slice(0, 3) + (i === cur ? ' (today)' : '') + '</button>'; }).join('');
      Array.prototype.forEach.call(bar.children, function (b, i) { b.addEventListener('click', function () { draw(i); }); });
      draw(cur);
    }
    if (pr) {
      var want = [['Training Only, 1 Session', 'One group class'], ['Training Only, 1 Week', 'Unlimited group classes for a week'], ['Training Only, 1 Month', 'Unlimited group classes for a month'], ['Spa Access, Full spa 1 time', 'Herbal sauna, dry sauna, ice bath']];
      var pk = d.packages || [], out = [];
      want.forEach(function (w) { var p = pk.find(function (x) { return x.name === w[0]; }); if (p) out.push('<div class="price"><small>' + esc(w[1]) + '</small><b>' + thb(p.price) + '</b></div>'); });
      if (d.private_price) out.push('<div class="price"><small>Private session with a coach</small><b>' + thb(d.private_price) + '</b></div>');
      if (out.length) pr.innerHTML = out.slice(0, 4).join('');
    }
  }).catch(function () {
    if (tt) tt.innerHTML = '<div class="cls"><div>Muay Thai at 8:00 am and 4:30 pm Monday to Saturday, and 6:30 pm Monday to Friday. Yoga at 9:45 am Monday, Wednesday and Friday.</div></div>';
  });
})();
