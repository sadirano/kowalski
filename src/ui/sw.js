'use strict';
// The daemon injects SHELL_REVISION from the contents of the compiled shell.
const CACHE_NAME = 'kw-shell-' + SHELL_REVISION;
const SHELL_ASSETS = [
  '/',
  '/index.html',
  '/favicon.svg',
  '/manifest.webmanifest',
  '/ui/app.css',
  '/ui/bundle.js',
  '/icon-192.png',
  '/icon-512.png',
];

const OFFLINE = `<!doctype html><html><head><meta charset="utf-8"><title>kowalski</title>
<style>body{margin:0;height:100vh;display:grid;place-items:center;background:#0f1117;color:#e2e8f0;font:14px system-ui,sans-serif}
p{color:#94a3b8}</style></head><body><div><h2>kowalski is not running</h2>
<p>Start it with <code>kowalski start</code>, then reload.</p></div></body></html>`;

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE_NAME)
    .then(cache => cache.addAll(SHELL_ASSETS))
    .then(() => self.skipWaiting()));
});

self.addEventListener('activate', e => {
  e.waitUntil(caches.keys()
    .then(keys => Promise.all(keys
      .filter(key => key.startsWith('kw-shell-') && key !== CACHE_NAME)
      .map(key => caches.delete(key))))
    .then(() => self.clients.claim()));
});

async function matchShell(request, options) {
  const cache = await caches.open(CACHE_NAME);
  return cache.match(request, options);
}

self.addEventListener('fetch', e => {
  if (e.request.method !== 'GET') return;
  const url = new URL(e.request.url);
  if (url.origin !== self.location.origin) return;

  if (url.pathname.startsWith('/api/') || url.pathname.startsWith('/tour/api/')) {
    e.respondWith(fetch(e.request));
    return;
  }

  // The shell comes from this build's cache, so a reload paints at once. A new
  // build ships a new worker; the page reloads once when it takes over.
  if (e.request.mode === 'navigate') {
    e.respondWith((async () => {
      if (url.pathname === '/' || url.pathname === '/index.html') {
        const cached = await matchShell(e.request, { ignoreSearch: true }).catch(() => undefined);
        if (cached) return cached;
      }
      try {
        return await fetch(e.request);
      } catch {
        return new Response(OFFLINE, { status: 503, headers: { 'content-type': 'text/html; charset=utf-8' } });
      }
    })());
    return;
  }

  if (url.pathname.startsWith('/ui/')
      || ['/favicon.svg', '/manifest.webmanifest', '/icon-192.png', '/icon-512.png'].includes(url.pathname)) {
    e.respondWith(matchShell(e.request).catch(() => undefined).then(cached => cached || fetch(e.request)));
  }
});
