'use strict';
// ── Toast ─────────────────────────────────────────────────────────────────────
// A newer toast replaces the shown one and gets its own full time on screen.
let _toastTimer = 0;
function showToast(msg, error = false) {
  const t = id('toast');
  t.textContent = msg;
  t.classList.toggle('error', error);
  t.classList.add('show');
  clearTimeout(_toastTimer);
  _toastTimer = setTimeout(() => t.classList.remove('show'), error ? 5000 : 3000);
}
function showError(msg) { showToast(msg, true); }

// A line icon from the page's sprite (index.html), drawn in the text colour.
function icon(name) { return `<svg class="ico" aria-hidden="true"><use href="#i-${name}"/></svg>`; }

// ── Formatters ────────────────────────────────────────────────────────────────
function fmtMs(ms) {
  if (!ms||ms<0) return '0h 00m';
  const m=Math.floor(ms/60000), h=Math.floor(m/60);
  return `${h}h ${String(m%60).padStart(2,'0')}m`;
}
function fmtTime(ms) {
  if (ms == null) return '—';
  return padHHMM(new Date(ms));
}
// Clock times follow the time format setting; "system" asks the browser's
// own locale, so it matches the rest of the machine.
function hour12() {
  const f = pref('ui_time_format', 'system');
  if (f === '12') return true;
  if (f === '24') return false;
  return new Intl.DateTimeFormat(undefined, { hour: 'numeric' }).resolvedOptions().hour12 === true;
}
function padHHMM(d) {
  const h = d.getHours(), m = String(d.getMinutes()).padStart(2, '0');
  return hour12() ? `${h % 12 || 12}:${m} ${h < 12 ? 'AM' : 'PM'}` : `${String(h).padStart(2, '0')}:${m}`;
}
// "HH:MM" as typed in a time field, always 24-hour, for an instant.
function hhmm24(ms) { const d = new Date(ms); return `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`; }
// A stored "HH:MM" shown in the chosen format.
function fmtClock(hhmm) { const [h, m] = hhmm.split(':').map(Number); const d = new Date(); d.setHours(h, m, 0, 0); return padHHMM(d); }
// Rewrites a typed time field in the chosen 12/24-hour format, or marks it
// when it cannot be read.
function tidyClock(el) {
  const v = parseClock(el.value);
  el.classList.toggle('bad', !!el.value.trim() && !v);
  if (v) el.value = fmtClock(v);
}
// A typed time ("17", "1730", "5pm", "5:30 PM", "17.30") as "HH:MM", or null.
function parseClock(text) {
  const m = String(text).trim().toLowerCase().match(/^(\d{1,2})(?:[:.h]?(\d{2}))?\s*([ap])?\.?m?\.?$/);
  if (!m) return null;
  let h = Number(m[1]);
  const min = m[2] ? Number(m[2]) : 0;
  if (m[3]) { if (h < 1 || h > 12) return null; h = h % 12 + (m[3] === 'p' ? 12 : 0); }
  if (h > 23 || min > 59) return null;
  return `${String(h).padStart(2, '0')}:${String(min).padStart(2, '0')}`;
}
function fmtMins(m) {
  if (!m || m < 0) return '0m';
  const h = Math.floor(m / 60), mm = m % 60;
  if (h && mm) return `${h}h ${mm}m`;
  return h ? `${h}h` : `${mm}m`;
}
function fmtDate(str) {
  return str ? new Date(str+'T12:00:00').toLocaleDateString(locale(),{weekday:'long',year:'numeric',month:'long',day:'numeric'}) : '—';
}
function shortDate(str) { return new Date(str+'T12:00:00').toLocaleDateString(locale(),{month:'short',day:'numeric'}); }
function dayName(str)   { return new Date(str+'T12:00:00').toLocaleDateString(locale(),{weekday:'short'}); }
function isWeekend(str) { const d = new Date(str+'T12:00:00').getDay(); return d === 0 || d === 6; }
function calendarDateStr(d) { return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`; }
function todayStr()     { return S?.date ?? calendarDateStr(new Date()); }
// Writes markup into el by changing only what differs from what is there, so
// a refresh that repeats the page does not rebuild it (no blink, hover and
// focus stay). A focused field keeps what is being typed.
function patchHTML(el, html) {
  const tpl = document.createElement('template');
  tpl.innerHTML = html;
  patchChildren(el, tpl.content);
}

function patchChildren(from, to) {
  const want = [...to.childNodes];
  for (let i = 0; i < want.length; i++) {
    const have = from.childNodes[i];
    const next = want[i];
    if (!have) { from.appendChild(next); continue; }
    if (have.nodeType !== next.nodeType || have.nodeName !== next.nodeName) { from.replaceChild(next, have); continue; }
    if (have.nodeType !== 1) { if (have.nodeValue !== next.nodeValue) have.nodeValue = next.nodeValue; continue; }
    for (const a of [...have.attributes]) if (!next.hasAttribute(a.name)) have.removeAttribute(a.name);
    for (const a of next.attributes) if (have.getAttribute(a.name) !== a.value) have.setAttribute(a.name, a.value);
    if (have === document.activeElement && (have.nodeName === 'INPUT' || have.nodeName === 'TEXTAREA')) continue;
    patchChildren(have, next);
  }
  while (from.childNodes.length > want.length) from.removeChild(from.lastChild);
}

function esc(s)  { return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;'); }
// escAttr also escapes the quote, for text dropped into an HTML attribute
// (client names and notes reach title="…" in the search results).
function escAttr(s) { return esc(s).replace(/"/g, '&quot;'); }
function trunc(s,n) { return s.length<=n?s:s.slice(0,n-1)+'…'; }

// refLink renders a ref as plain escaped text unless links are enabled and the
// provider supplies an HTTP(S) page template. Links open in a new tab.
function refLink(ref) {
  if (!ref) return '—';
  const txt = esc(ref);
  if (pref('ui_links','0') !== '1' || !S || !S.link) return txt;
  const url = S.link.replace('{ref}', encodeURIComponent(ref));
  if (!/^https?:\/\//i.test(url)) return txt;
  const title = escAttr(t('open_ref', { ref }));
  return `<a class="ref-link" href="${escAttr(url)}" target="_blank" rel="noopener noreferrer" title="${title}" onclick="event.stopPropagation()">${txt}</a>`;
}
function id(x)   { return document.getElementById(x); }
// On /?tour=1 the page runs the guided tour: every API call goes to the
// daemon's sandbox under /tour/, except starting and finishing the tour.
const TOUR = new URLSearchParams(location.search).has('tour');
// Kowalski refuses changes without this header or from another origin.
function api(path, opts = {}) {
  opts.headers = Object.assign({ 'X-Kowalski': '1' }, opts.headers || {});
  if (TOUR && path.startsWith('/api/') && !path.startsWith('/api/tour/')) path = '/tour' + path;
  return fetch(path, opts);
}
async function apiJSON(method, path, body) {
  const opts = { method };
  if (body !== undefined) {
    opts.headers = { 'Content-Type': 'application/json' };
    opts.body = JSON.stringify(body);
  }
  const response = await api(path, opts);
  const text = await response.text();
  const data = text ? JSON.parse(text) : null;
  if (!response.ok) {
    const error = new Error((data && (data.message || data.error)) || `HTTP ${response.status}`);
    error.status = response.status;
    error.data = data;
    throw error;
  }
  return data;
}

function loadLS(key, def) {
  try { const v = localStorage.getItem('kw.' + key); return v === null ? def : JSON.parse(v); }
  catch { return def; }
}
function saveLS(key, val) {
  try { localStorage.setItem('kw.' + key, JSON.stringify(val)); } catch { /* private mode / quota */ }
}
