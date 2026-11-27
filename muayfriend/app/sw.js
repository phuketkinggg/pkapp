// Keeps the app installable and opens the last copy when there is no signal.
// Always tries the network first, so updates show up straight away. Data calls are never cached.
const CACHE = 'mf-free-v391';
// the last version that started properly on this phone, and a mark when a newer one failed to start
const GOOD = CACHE.replace(/v\d+$/, 'good');
const SHELL = ['./', './index.html', './manifest.webmanifest', './icons/icon-192.png', './icons/apple-touch-icon.png', './vendor/supabase-js-2.117.2.js', './vendor/qrcode-generator-1.4.4.js'];
self.addEventListener('install', (e) => { e.waitUntil(caches.open(CACHE).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting())); });
self.addEventListener('activate', (e) => {
  // only this app's older copies are removed: the other apps on the same address keep their own
  const mine = CACHE.replace(/v\d+$/, '');
  e.waitUntil(caches.keys().then((ks) => Promise.all(ks.filter((k) => k !== CACHE && k !== GOOD && k.startsWith(mine)).map((k) => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener('fetch', (e) => {
  const req = e.request, url = new URL(req.url);
  if (req.method !== 'GET' || url.origin !== self.location.origin) return;
  const root0 = new URL('./', self.location).pathname;
  const isApp = req.mode === 'navigate' && (url.pathname === root0 || url.pathname === root0 + 'index.html');
  // the app page always asks the server for the newest copy (skips the browser's 10 minute cache), so an update shows on the next open
  // safety net: this version failed to start on this phone, so open the last good one until a newer version arrives
  if (isApp) {
    e.respondWith(caches.open(GOOD).then((g) => Promise.all([g.match('__bad'), g.match('./')]).then(([bad, good]) => Promise.resolve(bad ? bad.text() : '').then((b) =>
      good && (b === CACHE || url.searchParams.get('safe') === '1') ? good : fresh()))).catch(fresh));
    return;
  }
  e.respondWith(fresh());
  function fresh() { return (isApp ? fetch(url.href, { cache: 'no-cache', credentials: 'same-origin' }) : fetch(req)).then((res) => {
    // only the app itself is kept as the offline copy, never other pages (invoice, booking)
    const root = root0;
    const appPage = isApp;
    if (res.ok && (appPage || (req.mode !== 'navigate' && SHELL.some((p) => url.pathname.endsWith(p.replace('./', '/')))))) {
      const copy = res.clone(); caches.open(CACHE).then((c) => c.put(appPage ? './' : req, copy));
    }
    return res;
  }).catch(() => { const root = new URL('./', self.location).pathname; return caches.match(req.mode === 'navigate' ? ((url.pathname === root || url.pathname === root + 'index.html') ? './' : req) : req).then((r) => r || (req.mode !== 'navigate' || url.pathname.startsWith(root + 'pangea/') ? r : caches.match('./'))); }); }
});
// the app page says when it started properly (keep it as the last good copy) or failed to start (open the last good copy)
self.addEventListener('message', (e) => {
  const t = e.data && e.data.type;
  if (t === 'pk-good') e.waitUntil(caches.open(GOOD).then((g) => g.match('__bad').then((bad) => Promise.resolve(bad ? bad.text() : '').then((b) => {
    if (b === CACHE) return;  // never keep a version that failed on this phone
    return caches.open(CACHE).then((c) => c.match('./')).then((r) => r && g.put('./', r));
  }))));
  if (t === 'pk-bad') e.waitUntil(caches.open(GOOD).then((g) => g.match('./').then((good) => good && g.put('__bad', new Response(CACHE)))));
});

// Phone notifications: chat messages, and new food and drink orders for staff (turned on in the app: Messages, or the kitchen screen).
self.addEventListener('push', (e) => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (_x) { d = { title: 'Muay Friend', body: e.data ? e.data.text() : '' }; }
  e.waitUntil(self.registration.showNotification(d.title || 'Muay Friend', {
    body: d.body || '', tag: d.tag || 'pk', renotify: true, icon: './icons/icon-192.png', badge: './icons/favicon-48.png', data: { url: d.url || './#chat' },
  }));
});
self.addEventListener('notificationclick', (e) => {
  e.notification.close();
  const url = (e.notification.data && e.notification.data.url) || './#chat';
  const m = url.match(/#chat=([0-9a-f-]{36})/);
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((list) => {
    const w = list.find((c) => new URL(c.url).origin === self.location.origin);
    const tab = !m && url.match(/#([a-z_]+)$/);
    if (w) { w.postMessage(tab && tab[1] !== 'chat' ? { type: 'open-tab', tab: tab[1] } : { type: 'open-chat', chat: m ? m[1] : null }); return w.focus(); }
    return self.clients.openWindow(url.startsWith('https://muayfriend.com/app/') && self.location.origin !== 'https://muayfriend.com/app' ? './' + url.slice(url.indexOf('#')) : url);
  }));
});
