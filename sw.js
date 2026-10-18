// Keeps the app installable and opens the last copy when there is no signal.
// Always tries the network first, so updates show up straight away. Data calls are never cached.
const CACHE = 'pk-shell-v19';
const SHELL = ['./', './index.html', './manifest.webmanifest', './icons/icon-192.png', './icons/apple-touch-icon.png', './vendor/supabase-js-2.117.2.js', './vendor/qrcode-generator-1.4.4.js'];
self.addEventListener('install', (e) => { e.waitUntil(caches.open(CACHE).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting())); });
self.addEventListener('activate', (e) => {
  e.waitUntil(caches.keys().then((ks) => Promise.all(ks.filter((k) => k !== CACHE).map((k) => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener('fetch', (e) => {
  const req = e.request, url = new URL(req.url);
  if (req.method !== 'GET' || url.origin !== self.location.origin) return;
  e.respondWith(fetch(req).then((res) => {
    if (res.ok && (req.mode === 'navigate' || SHELL.some((p) => url.pathname.endsWith(p.replace('./', '/'))))) {
      const copy = res.clone(); caches.open(CACHE).then((c) => c.put(req.mode === 'navigate' ? './' : req, copy));
    }
    return res;
  }).catch(() => caches.match(req.mode === 'navigate' ? './' : req).then((r) => r || caches.match('./'))));
});

// Website chat notifications for the desk (turned on in the app: Messages, Website chat).
self.addEventListener('push', (e) => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (_x) { d = { title: 'Phuket King', body: e.data ? e.data.text() : '' }; }
  e.waitUntil(self.registration.showNotification(d.title || 'Phuket King', {
    body: d.body || '', tag: d.tag || 'pk', renotify: true, icon: './icons/icon-192.png', badge: './icons/favicon-48.png', data: { url: d.url || './#chat' },
  }));
});
self.addEventListener('notificationclick', (e) => {
  e.notification.close();
  const url = (e.notification.data && e.notification.data.url) || './#chat';
  const m = url.match(/#chat=([0-9a-f-]{36})/);
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((list) => {
    const w = list.find((c) => new URL(c.url).origin === self.location.origin);
    if (w) { w.postMessage({ type: 'open-chat', chat: m ? m[1] : null }); return w.focus(); }
    return self.clients.openWindow(url.startsWith('https://app.phuketking.com/') && self.location.origin !== 'https://app.phuketking.com' ? './' + url.slice(url.indexOf('#')) : url);
  }));
});
