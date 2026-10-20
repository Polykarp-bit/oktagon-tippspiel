// Service Worker nur für die Offline-Version: offline.html zuerst aus dem Netz, ohne Netz aus dem Cache.
// Alle anderen Anfragen (auch die Online-Version) laufen unverändert durchs Netz.
const CACHE = "okt-offline-v1";
const FILES = ["offline.html", "offline.webmanifest", "icons/offline-180.png", "icons/offline-192.png", "icons/offline-512.png"];

self.addEventListener("install", (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(FILES)).then(() => self.skipWaiting()));
});
self.addEventListener("activate", (e) => e.waitUntil(self.clients.claim()));

self.addEventListener("fetch", (e) => {
  const url = new URL(e.request.url);
  const file = FILES.find((f) => url.pathname.endsWith("/" + f));
  if (e.request.method !== "GET" || url.origin !== location.origin || !file) return;
  e.respondWith(
    fetch(e.request)
      .then((res) => {
        if (res.ok) { const copy = res.clone(); caches.open(CACHE).then((c) => c.put(file, copy)); }
        return res;
      })
      .catch(() => caches.match(file))
  );
});
