'use strict';
// Service worker for the installed app. Everything comes from the local
// daemon and nothing is cached: the data lives there. When the daemon is not
// running, a page load gets a short page saying so instead of a browser error.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));

const OFFLINE = `<!doctype html><html><head><meta charset="utf-8"><title>kowalski</title>
<style>body{margin:0;height:100vh;display:grid;place-items:center;background:#0f1117;color:#e2e8f0;font:14px system-ui,sans-serif}
p{color:#94a3b8}</style></head><body><div><h2>kowalski is not running</h2>
<p>Start it with <code>kowalski start</code>, then reload.</p></div></body></html>`;

self.addEventListener('fetch', e => {
  if (e.request.mode !== 'navigate') return;
  e.respondWith(fetch(e.request).catch(() =>
    new Response(OFFLINE, { status: 503, headers: { 'content-type': 'text/html; charset=utf-8' } })));
});
