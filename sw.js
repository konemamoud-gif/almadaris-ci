// Al-Madaris CI — Service worker : تشغيل التطبيق دون إنترنت
const V = 'amc-v1';
const SHELL = ['./', './index.html', './config.js', './logo.png', './emblem.png', './manifest.webmanifest',
               './icon-192.png', './icon-512.png', './apple-touch-icon.png'];
const CDN = ['https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2',
             'https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js',
             'https://cdn.jsdelivr.net/npm/jsqr@1.4.0/dist/jsQR.min.js',
             'https://cdn.jsdelivr.net/npm/xlsx@0.18.5/dist/xlsx.full.min.js'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(V).then(async c => {
    await c.addAll(SHELL);
    await Promise.all(CDN.map(u => c.add(u).catch(() => {})));   // المكتبات: إن تعذّرت تُخزَّن لاحقاً
  }).then(() => self.skipWaiting()));
});

self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== V).map(k => caches.delete(k))))
    .then(() => self.clients.claim()));
});

self.addEventListener('fetch', e => {
  const r = e.request;
  if (r.method !== 'GET') return;
  const u = new URL(r.url);
  if (/supabase\.(co|in)$/.test(u.hostname)) return;            // البيانات لا تُخزَّن هنا أبداً
  if (u.origin === self.location.origin) {                        // ملفات التطبيق: الشبكة أولاً لتصل التحديثات
    e.respondWith(fetch(r).then(res => {
      if (res.ok) { const cp = res.clone(); caches.open(V).then(c => c.put(r, cp)); }
      return res;
    }).catch(() => caches.match(r, { ignoreSearch: true })
      .then(m => m || (r.mode === 'navigate' ? caches.match('./index.html') : Response.error()))));
    return;
  }
  if (/cdn\.jsdelivr\.net|cdnjs\.cloudflare\.com|fonts\.googleapis\.com|fonts\.gstatic\.com/.test(u.hostname)) {
    e.respondWith(caches.open(V).then(async c => {                // المكتبات والخطوط: من الذاكرة ثم تحديث
      const m = await c.match(r);
      const f = fetch(r).then(res => { if (res.ok || res.type === 'opaque') c.put(r, res.clone()); return res; }).catch(() => m);
      return m || f.then(x => x || Response.error());
    }));
  }
});
