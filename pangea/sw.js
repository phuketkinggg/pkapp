// Pangea app: network first so updates show straight away, last copy when offline. Data calls are never cached.
const CACHE = 'pangea-v1';
const SHELL = ['./', './index.html', './manifest.webmanifest', './logo.svg', './icons/icon-192.png', '../vendor/supabase-js-2.117.2.js'];
self.addEventListener('install', (e) => { e.waitUntil(caches.open(CACHE).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting())); });
self.addEventListener('activate', (e) => {
  e.waitUntil(caches.keys().then((ks) => Promise.all(ks.filter((k) => k.startsWith('pangea-') && k !== CACHE).map((k) => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener('fetch', (e) => {
  const req = e.request, url = new URL(req.url);
  if (req.method !== 'GET' || url.origin !== self.location.origin) return;
  const root = new URL('./', self.location).pathname;
  const page = req.mode === 'navigate' && (url.pathname === root || url.pathname === root + 'index.html');
  e.respondWith(fetch(req).then((res) => {
    if (res.ok && (page || SHELL.some((p) => url.pathname === new URL(p, self.location).pathname))) {
      const copy = res.clone(); caches.open(CACHE).then((c) => c.put(page ? './' : req, copy));
    }
    return res;
  }).catch(() => caches.match(page ? './' : req).then((r) => r || caches.match('./'))));
});
