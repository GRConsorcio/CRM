const CACHE = 'crm-gr-v4';
const SHELL = ['./', './index.html', './manifest.json', './logo.svg', './icon.svg?v=2'];

self.addEventListener('install', (e) => {
  self.skipWaiting();
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(SHELL)));
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys().then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
  );
  self.clients.claim();
});

self.addEventListener('fetch', (e) => {
  if (e.request.method !== 'GET') return;
  // BUGFIX: interceptar TUDO (inclusive chamadas cross-origin pro Supabase)
  // podia quebrar/atrasar dados reais no app instalado. Só a casca do app
  // (mesmo origin) passa pelo SW; tudo cross-origin vai direto pra rede.
  if (new URL(e.request.url).origin !== self.location.origin) return;
  e.respondWith(
    fetch(e.request).then((res) => {
      const copy = res.clone();
      caches.open(CACHE).then((c) => c.put(e.request, copy));
      return res;
    }).catch(() => caches.match(e.request))
  );
});
