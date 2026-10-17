'use strict';
// ── Guided tour and help ─────────────────────────────────────────────────────
// The tour is the real dashboard on /?tour=1, talking to the daemon's sandbox
// (made-up history, an example provider). A banner keeps saying so. Flows
// spotlight one control at a time and wait for the user to use it. Help mode,
// in or out of the tour, explains whatever is clicked instead of doing it.
// Every text lives in i18n.js: h_<id>(_t) for help, ts_<id>(_t) for steps.

// ── Help catalog ─────────────────────────────────────────────────────────────
// sel: what the entry explains (the first match). provider: only with a
// ticketing provider. open: brings it on screen when picked from search.
const openMenu = () => toggleMoreMenu(true);
const openSettings = async () => { if (!id('settings-popup').classList.contains('show')) await showSettings(); };
const openSettingsAdvanced = async () => { await openSettings(); id('settings-popup').querySelector('.set-adv').open = true; };
const openNewTask = () => { if (!id('newtask-popup').classList.contains('show')) showNewTask(); };
const openAddEntry = () => { if (!id('addentry-popup').classList.contains('show')) showAddEntry(); };
const openPost = async () => { if (!id('horas-popup').classList.contains('show')) await showHorasDialog(selectedDate); };
const openReport = () => { if (activeTab !== 'report') setTab('report'); };
const openBlock = () => {
  openReport();
  const hdr = document.querySelector('.block-hdr');
  if (hdr && !hdr.nextElementSibling.classList.contains('open')) toggleBlock(hdr);
};
const row = sel => () => id(sel)?.closest('.set-row') || null;

const prefRow = key => `#pref-menu [data-key="${key}"]`;
const HELP = [
  // Command bar
  { id: 'date', sel: '.hdr-date', keys: '← → T' },
  { id: 'tabs', sel: '#main-tabs', keys: '1 2' },
  { id: 'search', sel: '.search-box', keys: 'Ctrl+K /' },
  { id: 'tracker', sel: '#tracker-btn', keys: 'Ctrl+Enter' },
  { id: 'session', sel: '.hdr-task-text' },
  { id: 'post', sel: '#post-btn', provider: true },
  { id: 'newtask', sel: '#newtask-btn', keys: 'N' },
  { id: 'addentry_btn', sel: '#add-entry-btn', keys: 'A' },
  { id: 'keys_btn', sel: '#keys-btn', keys: '?' },
  { id: 'settings', sel: '#settings-btn', keys: 'Ctrl+,' },
  { id: 'more', sel: '#more-btn' },
  { id: 'm_login', sel: '#login-btn', provider: true, open: openMenu },
  { id: 'm_lang', sel: '#lang-item', open: openMenu },
  { id: 'm_tour', sel: '#tour-item', open: openMenu },
  // Sidebar and calendar
  { id: 'days', sel: '#week-nav' },
  { id: 'day', sel: '#week-nav .dbtn' },
  { id: 'dclock', sel: '#week-nav .dclock', provider: true },
  { id: 'collapse', sel: '.panel-collapse', keys: '[' },
  { id: 'cal_btn', sel: '.cal-open', keys: 'G' },
  { id: 'calendar', sel: '#cal-grid', open: () => showCalendar() },
  // Cards
  { id: 'c_total', sel: '#cards .card:nth-child(1)' },
  { id: 'c_tasks', sel: '#cards .card:nth-child(2)' },
  { id: 'c_hops', sel: '#cards .card:nth-child(3)' },
  { id: 'c_periods', sel: '#cards .card-wide' },
  { id: 'sched', sel: '#sched-box' },
  // Chart
  { id: 'ch_days', sel: '#chart-days' },
  { id: 'ch_expand', sel: '#chart-expand-btn' },
  { id: 'ch_views', sel: '#chart-views' },
  { id: 'ch_groups', sel: '#chart-groups', provider: true },
  { id: 'ch_bars', sel: '#chart-canvas-wrap' },
  { id: 'ch_lanes', sel: '#chart-lanes' },
  { id: 'ch_list', sel: '#chart-legend' },
  // Report
  { id: 'task', sel: '.task-card .task-hdr', open: openReport },
  { id: 'ref', sel: '.task-card .task-id', provider: true, open: openReport },
  { id: 'switch', sel: '.task-card .switch-btn', open: openReport },
  { id: 'hops', sel: '.task-card .task-hops', open: openReport },
  { id: 'block', sel: '.block-hdr', open: openReport },
  { id: 'slots', sel: '.slot-grid.open', open: openBlock },
  { id: 'edit', sel: '.block-actions .btn-icon', open: openReport },
  { id: 'delete', sel: '.block-actions .btn-icon + .btn-icon', open: openReport },
  { id: 'merge', sel: '.merge-btn', open: openReport },
  { id: 'parallel', sel: '.open-badge.par', open: openReport },
  // Summary
  { id: 'summary', sel: '#summary-text', open: () => setTab('summary') },
  { id: 'regen', sel: '.summary-regen', open: () => setTab('summary') },
  // Dialogs
  { id: 'nt_ref', sel: '#nt-ref-row', provider: true, open: openNewTask },
  { id: 'nt_title', sel: '#nt-title', open: openNewTask },
  { id: 'ae_date', sel: '#ae-date', open: openAddEntry },
  { id: 'ae_times', sel: () => id('ae-start')?.closest('.popup-row'), open: openAddEntry },
  { id: 'edit_dialog', sel: '#edit-popup' },
  { id: 'hr_opt', sel: '.hr-int', provider: true, open: openPost },
  { id: 'hr_row', sel: '.horas-row', provider: true, open: openPost },
  { id: 'hr_obs', sel: '.hr-obs-btn', provider: true, open: openPost },
  { id: 'hr_submit', sel: '#horas-submit-btn', provider: true, open: openPost },
  { id: 'keys', sel: '#keys-grid', open: () => showKeys() },
  // Settings, a row each
  { id: 's_daily', sel: row('set-daily-h'), open: openSettings },
  { id: 's_lunch', sel: row('set-lunch'), open: openSettings },
  { id: 's_paid', sel: row('set-paid-mode'), open: openSettings },
  { id: 's_lock', sel: row('set-lock-on'), open: openSettings },
  { id: 's_lang', sel: row('set-lang'), open: openSettings },
  { id: 's_time', sel: row('set-time-format'), open: openSettings },
  // View options, in the popover beside their view
  { id: 's_sidebar', sel: prefRow('ui_sidebar_days'), open: () => openPrefMenu('sidebar') },
  { id: 's_order', sel: prefRow('ui_day_order'), open: () => openPrefMenu('sidebar') },
  { id: 's_weekends', sel: prefRow('ui_show_weekends'), open: () => openPrefMenu('sidebar') },
  { id: 's_summary', sel: prefRow('ui_summary_format'), open: async () => { setTab('summary'); await openPrefMenu('summary'); } },
  { id: 's_chart_tabs', sel: prefRow('ui_chart_hidden'), provider: true, open: () => openPrefMenu('chart') },
  { id: 's_links', sel: row('set-links'), provider: true, open: openSettings },
  { id: 's_buttons', sel: row('set-show-add-entry'), open: openSettings },
  { id: 's_singlekeys', sel: row('set-single-keys'), open: openSettings },
  { id: 's_openlaunch', sel: row('set-open-launch'), open: openSettings },
  { id: 's_autofill', sel: row('set-post-notes'), provider: true, open: openSettings },
  { id: 's_provider', sel: '#set-provider-rows .set-row', provider: true, open: openSettings },
  { id: 's_sessions', sel: '#set-post-sessions-row', provider: true, open: openSettings },
  { id: 's_account', sel: '#set-account-row', provider: true, open: openSettings },
  { id: 's_zone', sel: row('set-zone'), open: openSettings },
  { id: 's_port', sel: () => id('set-port')?.closest('.set-row'), open: openSettingsAdvanced },
];
const HELP_BY_ID = Object.fromEntries(HELP.map(h => [h.id, h]));

// The "?" next to each dialog and settings section: [container, help id].
const HELP_SPOTS = [
  ['#newtask-popup', 'nt_ref'],
  ['#addentry-popup', 'ae_date'],
  ['#horas-popup', 'hr_row'],
  ['#edit-popup', 'edit_dialog'],
  ['#keys-popup', 'keys'],
  ['#cal-popup', 'calendar'],
];
// A settings section names its help topic in data-help, so order never matters.
const settingsSection = help => id('settings-popup').querySelector(`.set-sec[data-help="${help}"]`);

function helpEl(h) {
  const el = typeof h.sel === 'function' ? h.sel() : document.querySelector(h.sel);
  return el && el.getClientRects().length ? el : null;
}

// ── Popover and spotlight ────────────────────────────────────────────────────
let _spotEl = null;     // what the spotlight follows
let _popAnchor = null;  // what the popover sits next to
let _resolve = null;    // finds the target again after the page re-renders it
let _wantSpot = false;  // the spotlight comes back when the target does
let _spotRaf = 0;
let _popAt = null;      // where the popover last was: it stays there when its target goes away

function tourLayer() {
  let layer = id('tour-layer');
  if (layer) return layer;
  document.body.insertAdjacentHTML('beforeend', `<div id="tour-layer">
    <div class="tour-spot" id="tour-spot"></div>
    <div class="tour-pop" id="tour-pop" role="dialog" aria-live="polite"></div>
  </div>`);
  return id('tour-layer');
}

const shownEl = el => !!el && el.isConnected && el.getClientRects().length > 0;

// A window opened over the target (one the step is not about): the tour
// stops dimming and sits beside it, so the user can read what they opened.
function coveringPopup(target) {
  const open = POPUP_IDS.map(p => id(p)).filter(el => el?.classList.contains('show') && !(target && el.contains(target)));
  return open.at(-1) || null;
}

function placePop() {
  const pop = id('tour-pop');
  if (!pop || !pop.classList.contains('show')) return;
  const spot = id('tour-spot');
  if (_resolve && !shownEl(_popAnchor)) {
    const el = _resolve();
    if (shownEl(el)) { _popAnchor = el; _spotEl = _wantSpot ? el : null; }
  }
  const cover = coveringPopup(_popAnchor);
  const lit = !cover && shownEl(_spotEl);
  id('tour-layer').classList.toggle('dim', lit && !_flow?.live);
  const r = lit ? _spotEl.getBoundingClientRect() : null;
  if (r && r.width) {
    spot.style.cssText = `display:block;left:${r.left - 6}px;top:${r.top - 6}px;width:${r.width + 12}px;height:${r.height + 12}px`;
  } else {
    spot.style.display = 'none';
  }
  const pw = pop.offsetWidth, ph = pop.offsetHeight, vw = innerWidth, vh = innerHeight, gap = 14;
  // Room kept free at the bottom for the tour banner and the help bar.
  const reserve = 8 + (document.body.classList.contains('tour-bar') ? 64 : 0) + (_helpOn ? 56 : 0);
  const put = (x, y) => {
    _popAt = { x: Math.max(8, Math.min(x, vw - pw - 8)), y: Math.max(8, Math.min(y, vh - ph - reserve)) };
    pop.style.left = _popAt.x + 'px';
    pop.style.top = _popAt.y + 'px';
  };
  if (cover) {
    const c = cover.getBoundingClientRect();
    if (c.right + gap + pw < vw) return put(c.right + gap, c.top);
    if (c.left - gap - pw > 0) return put(c.left - gap - pw, c.top);
    return put(vw - pw - 8, vh - ph - reserve);
  }
  const a = shownEl(_popAnchor) ? _popAnchor.getBoundingClientRect() : null;
  if (!a && _popAt) return put(_popAt.x, _popAt.y);
  if (!a || !a.width) return put((vw - pw) / 2, (vh - ph) / 2);
  // Below, above, right, left: the first that fits on screen and keeps off
  // the tour panel in the sidebar.
  const panel = id('tour-panel');
  const keepOff = panel && panel.style.display !== 'none' && panel.offsetHeight ? panel.getBoundingClientRect() : null;
  const clear = (x, y) => !keepOff || x + pw <= keepOff.left || x >= keepOff.right || y + ph <= keepOff.top || y >= keepOff.bottom;
  const midX = a.left + a.width / 2 - pw / 2, midY = Math.max(8, Math.min(a.top + a.height / 2 - ph / 2, vh - ph - reserve));
  const tries = [
    [a.bottom + gap + ph < vh - reserve, Math.max(8, Math.min(midX, vw - pw - 8)), a.bottom + gap],
    [a.top - gap - ph > 8, Math.max(8, Math.min(midX, vw - pw - 8)), a.top - gap - ph],
    [a.right + gap + pw < vw, a.right + gap, midY],
    [a.left - gap - pw > 0, a.left - gap - pw, midY],
  ];
  const fit = tries.find(([ok, x, y]) => ok && clear(x, y)) || tries.find(([ok]) => ok) || tries[3];
  put(fit[1], fit[2]);
}

function followSpot() {
  cancelAnimationFrame(_spotRaf);
  const tick = () => { placePop(); _spotRaf = requestAnimationFrame(tick); };
  _spotRaf = requestAnimationFrame(tick);
}

function showPop(html, el, spotlight, resolve) {
  tourLayer();
  const pop = id('tour-pop');
  pop.innerHTML = html;
  pop.classList.add('show');
  _popAnchor = el;
  _spotEl = spotlight ? el : null;
  _wantSpot = !!spotlight;
  _resolve = resolve || null;
  _popAt = null;
  id('tour-layer').classList.toggle('dim', !!spotlight);
  if (el) el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
  followSpot();
}

function hidePop() {
  cancelAnimationFrame(_spotRaf);
  const layer = id('tour-layer');
  if (!layer) return;
  id('tour-pop').classList.remove('show');
  id('tour-spot').style.display = 'none';
  layer.classList.remove('dim');
  _spotEl = _popAnchor = _resolve = _popAt = null;
}

window.addEventListener('pointerdown', e => {
  if (_popAnchor?.contains(e.target)) _resolve = null;
}, true);

// Help text: the first line says what it is for, the next ones how to use
// it, and a line starting with "!" is what to watch out for.
function helpBody(key) {
  const lines = t(key).split('\n').filter(Boolean);
  const lead = lines.shift() || '';
  const steps = lines.filter(l => !l.startsWith('!'));
  const notes = lines.filter(l => l.startsWith('!')).map(l => l.slice(1).trim());
  return `<p>${esc(lead)}</p>`
    + (steps.length ? `<ul>${steps.map(s => `<li>${esc(s)}</li>`).join('')}</ul>` : '')
    + notes.map(n => `<p class="tour-note">${esc(n)}</p>`).join('');
}

// ── Help mode ────────────────────────────────────────────────────────────────
let _helpOn = false;
let _helpHover = null;
let _helpTagged = 0;

function tagHelp() {
  const now = Date.now();
  if (now - _helpTagged < 250) return;
  _helpTagged = now;
  for (const h of HELP) {
    const el = helpEl(h);
    if (el && !el.closest('#tour-layer, .help-bar')) el.dataset.help = h.id;
  }
}

function enterHelp(focusId) {
  if (_flow) { clearInterval(_waitTimer); _flow.token = ++_token; _flow.held = true; }
  _helpOn = true;
  document.body.classList.add('help-mode');
  if (!id('help-bar')) {
    document.body.insertAdjacentHTML('beforeend', `<div class="help-bar" id="help-bar" role="region">
      ${icon('help')}<span class="help-bar-text" id="help-bar-text"></span>
      <div class="help-find"><input type="text" id="help-q" autocomplete="off" spellcheck="false" oninput="renderHelpFind()" onkeydown="helpFindKey(event)">
        <div class="help-results" id="help-results"></div></div>
      <button type="button" class="tour-btn" onclick="exitHelp()" id="help-done"></button>
    </div>`);
  }
  id('help-bar-text').textContent = t('help_bar');
  id('help-q').placeholder = t('help_search_ph');
  id('help-done').textContent = t('help_done');
  id('help-bar').classList.add('show');
  _helpTagged = 0;
  tagHelp();
  if (focusId) showHelp(focusId);
}

function exitHelp() {
  _helpOn = false;
  document.body.classList.remove('help-mode');
  id('help-bar')?.classList.remove('show');
  id('help-results')?.classList.remove('show');
  if (id('help-q')) id('help-q').value = '';
  _helpHover?.classList.remove('help-hover');
  _helpHover = null;
  if (_flow?.held) { _flow.held = false; runStep(true); }
  else if (!_flow) hidePop();
}

async function showHelp(helpId, el) {
  const h = HELP_BY_ID[helpId];
  if (!h) return;
  let target = el || helpEl(h);
  if (!target && h.open) {
    await h.open();
    await new Promise(r => setTimeout(r, 150));
    target = helpEl(h);
  }
  const tag = h.provider ? `<span class="tour-tag">${esc(t('help_provider'))}</span>` : '';
  const keys = h.keys ? `<div class="tour-keys">${esc(t('help_keys'))} ${h.keys.split(' ').map(k => `<kbd>${esc(k)}</kbd>`).join(' ')}</div>` : '';
  showPop(`<div class="tour-pop-head"><b>${esc(t('h_' + h.id + '_t'))}</b>${tag}
      <button type="button" class="tour-x" onclick="hidePop()" aria-label="${escAttr(t('close'))}">${icon('x')}</button></div>
    ${helpBody('h_' + h.id)}${keys}`, target, true);
}

// Searching help: titles and texts in the current language.
function renderHelpFind() {
  const q = id('help-q').value.trim().toLowerCase();
  const box = id('help-results');
  if (!q) { box.classList.remove('show'); return; }
  const hits = HELP.filter(h => (t('h_' + h.id + '_t') + ' ' + t('h_' + h.id)).toLowerCase().includes(q)).slice(0, 8);
  box.innerHTML = hits.length
    ? hits.map((h, i) => `<button type="button" class="help-hit${i ? '' : ' sel'}" onclick="pickHelp('${h.id}')">${esc(t('h_' + h.id + '_t'))}</button>`).join('')
    : `<div class="help-none">${esc(t('help_none'))}</div>`;
  box.classList.add('show');
}

function helpFindKey(e) {
  const hits = [...document.querySelectorAll('#help-results .help-hit')];
  const at = hits.findIndex(b => b.classList.contains('sel'));
  if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
    e.preventDefault();
    if (!hits.length) return;
    hits[at]?.classList.remove('sel');
    hits[(at + (e.key === 'ArrowDown' ? 1 : -1) + hits.length) % hits.length].classList.add('sel');
  } else if (e.key === 'Enter' && hits[at]) {
    e.preventDefault();
    hits[at].click();
  }
}

function pickHelp(helpId) {
  id('help-results').classList.remove('show');
  id('help-q').value = '';
  showHelp(helpId);
}

// In help mode a click explains instead of acting; the tour's own controls,
// the help bar and the open explanation still work.
window.addEventListener('click', e => {
  if (!_helpOn || e.target.closest('#tour-layer, .help-bar, .tour-banner, .tour-panel, .tour-picker, .help-btn')) return;
  tagHelp();
  const el = e.target.closest('[data-help]');
  e.preventDefault();
  e.stopPropagation();
  if (el) showHelp(el.dataset.help, el);
}, true);

window.addEventListener('pointerover', e => {
  if (!_helpOn) return;
  tagHelp();
  const el = e.target.closest('[data-help]');
  if (el === _helpHover) return;
  _helpHover?.classList.remove('help-hover');
  _helpHover = el;
  el?.classList.add('help-hover');
}, true);

// Escape leaves help mode before it closes anything else.
window.addEventListener('keydown', e => {
  if (e.key !== 'Escape') return;
  if (_helpOn) { e.stopImmediatePropagation(); e.preventDefault(); exitHelp(); }
  else if (id('tour-pop')?.classList.contains('show') && !_flow) { e.stopImmediatePropagation(); hidePop(); }
}, true);

// In a text field an arrow belongs to the tour only where the field has no
// use for it: → with the caret at the end, ← at the start.
function caretAtEdge(e) {
  const el = e.target;
  if (el.isContentEditable || el.tagName === 'SELECT' || el.selectionStart == null || el.selectionStart !== el.selectionEnd) return false;
  return e.key === 'ArrowRight' ? el.selectionEnd === el.value.length : el.selectionStart === 0;
}

window.addEventListener('keydown', e => {
  if (!_flow || _helpOn || (e.key !== 'ArrowRight' && e.key !== 'ArrowLeft')) return;
  if (e.altKey || e.ctrlKey || e.metaKey || e.shiftKey || (isTyping(e) && !caretAtEdge(e))) return;
  if (!id('tour-pop')?.classList.contains('show') || id('tour-picker')?.classList.contains('show')) return;
  if (e.repeat || _moving) { e.preventDefault(); e.stopImmediatePropagation(); return; }
  // A window the step is not about keeps its own keys; one the step opened does not.
  if (!_flow.live && coveringPopup(_popAnchor)) return;
  e.preventDefault();
  e.stopImmediatePropagation();
  if (e.key === 'ArrowRight') flowNext();
  else if (_flow.i) flowStep(-1);
}, true);

function helpHere(e, helpId) {
  e.stopPropagation();
  e.preventDefault();
  enterHelp(helpId);
}

// ── Flows ────────────────────────────────────────────────────────────────────
// A step points at `el`; with `done` it waits until the user has done it,
// otherwise Next moves on. `prep` puts the page in the state the step needs,
// and `act` does the step for a user who moves on without doing it.
const isShown = popupId => id(popupId)?.classList.contains('show');
// Calendar arithmetic on the reporting-zone date; no trip through UTC.
const prevWorkday = () => {
  const d = new Date(todayStr() + 'T12:00:00');
  do d.setDate(d.getDate() - 1); while (d.getDay() === 0 || d.getDay() === 6);
  return calendarDateStr(d);
};
const redDay = () => document.querySelector('#week-nav .dclock.unsynced')?.closest('.dbtn')
  || [...document.querySelectorAll('#week-nav .dbtn')].reverse().find(b => b.querySelector('.dtotal')?.textContent !== '—');
const firstBlock = () => document.querySelector('.block-hdr');
const typeInto = (el, v) => { el.value = v; el.dispatchEvent(new Event('input', { bubbles: true })); };
const pause = ms => new Promise(r => setTimeout(r, ms));
let _focusAtStep = null;
let _openAtStep = 0;
let _switchTo = null;   // the task work_switch points at
let _pickDate = null;   // the day rev_pick points at
let _postDate = null;   // the day the post flow opened
let _postedAtStep = 0;
// Post hours, open on the flow's day, for the steps inside it.
const ensurePost = async () => { if (!isShown('horas-popup') && _postDate) { await showHorasDialog(_postDate); await pause(400); } };
const switchCard = () => document.querySelector(`.task-card[data-task="${_switchTo}"]`);
const closedBlock = () => [...document.querySelectorAll('.block-hdr')].find(h => !h.nextElementSibling?.classList.contains('open'));

const FLOWS = {
  work: [
    { id: 'work_session', el: '#hdr-session', prep: () => goToDate(todayStr()) },
    { id: 'work_play', el: '#tracker-btn', done: () => !!S?.focus, act: () => id('tracker-btn').click() },
    { id: 'work_running', el: '.hdr-task-text' },
    { id: 'work_new', el: '#newtask-btn', done: () => isShown('newtask-popup'), act: openNewTask },
    { id: 'work_ref', el: '#nt-ref-row', done: () => !!id('nt-title')?.value.trim(),
      act: async () => { typeInto(id('nt-ref'), '48555'); for (let n = 0; n < 20 && !id('nt-title').value.trim(); n++) await pause(150); } },
    { id: 'work_start', el: '#nt-submit', prep: () => { _focusAtStep = S?.focus?.task?.id; },
      done: () => !isShown('newtask-popup') && !!S?.focus && S.focus.task.id !== _focusAtStep, act: () => id('nt-submit').click() },
    { id: 'work_card', el: () => document.querySelector('.switch-btn.current-task')?.closest('.task-card') || document.querySelector('.task-card'), prep: openReport },
    { id: 'work_switch', el: () => switchCard()?.querySelector('.task-hdr'),
      prep: () => { _switchTo = document.querySelector('.switch-btn:not(.current-task)')?.closest('.task-card')?.dataset.task; },
      done: () => String(S?.focus?.task?.id) === _switchTo, act: () => switchCard()?.querySelector('.switch-btn')?.click() },
    { id: 'work_block', el: () => closedBlock() || firstBlock(), prep: () => { _openAtStep = document.querySelectorAll('.slot-grid.open').length; },
      done: () => document.querySelectorAll('.slot-grid.open').length > _openAtStep, act: () => { const h = closedBlock(); if (h) toggleBlock(h); } },
    { id: 'work_note', el: () => document.querySelector('.slot-grid.open') },
    { id: 'work_pause', el: '#tracker-btn', done: () => !S?.focus, act: () => id('tracker-btn').click() },
  ],
  review: [
    { id: 'rev_days', el: '#week-nav' },
    { id: 'rev_clock', el: '#week-nav .dclock' },
    { id: 'rev_pick', el: () => document.querySelector(`#week-nav .dbtn[data-date="${_pickDate}"]`),
      prep: () => { _pickDate = [...document.querySelectorAll('#week-nav .dbtn:not(.active)')].reverse().find(b => b.querySelector('.dtotal')?.textContent !== '—')?.dataset.date; },
      done: () => selectedDate === _pickDate, act: () => goToDate(_pickDate) },
    { id: 'rev_cards', el: '#cards' },
    { id: 'rev_chart', el: '#chart-canvas-wrap', prep: () => { if (chartView !== 'bars') setChartView('bars'); } },
    { id: 'rev_list', el: '#chart-legend' },
    { id: 'rev_lanes', el: '#chart-views', done: () => chartView === 'lanes', act: () => setChartView('lanes') },
    { id: 'rev_groups', el: '#chart-groups' },
    { id: 'rev_summary', el: '#main-tabs', done: () => activeTab === 'summary', act: () => setTab('summary') },
    { id: 'rev_summary_text', el: '#summary-text' },
    { id: 'rev_search', el: '.search-box', prep: () => setTab('report'), done: () => id('search-results')?.classList.contains('show'),
      act: async () => { const q = id('task-search'); q.focus(); typeInto(q, document.querySelector('.task-card .task-id')?.textContent.trim() || '4'); await pause(900); } },
    { id: 'rev_calendar', el: '.cal-open', prep: () => clearSearch() },
  ],
  fix: [
    { id: 'fix_day', el: '.hdr-date', prep: () => { goToDate(prevWorkday()); openReport(); } },
    { id: 'fix_edit', el: '.block-actions .btn-icon', done: () => isShown('edit-popup'), act: () => document.querySelector('.block-actions .btn-icon')?.click() },
    { id: 'fix_times', el: '#edit-popup', done: () => !isShown('edit-popup'), act: closeEditTime },
    { id: 'fix_merge', el: '.merge-btn' },
    { id: 'fix_move', el: firstBlock },
    { id: 'fix_delete', el: '.block-actions .btn-icon + .btn-icon' },
    { id: 'fix_more', el: '#more-btn', done: () => id('more-menu')?.classList.contains('show'), act: openMenu },
    { id: 'fix_add', el: () => document.querySelector('#more-menu .menu-item:nth-child(3)'), done: () => isShown('addentry-popup'), act: () => { toggleMoreMenu(false); openAddEntry(); } },
    { id: 'fix_form', el: '#addentry-popup', done: () => !isShown('addentry-popup'), act: hideAddEntry },
  ],
  post: [
    { id: 'post_clock', el: () => redDay()?.querySelector('.dclock'), prep: () => { goToDate(todayStr()); _postDate = redDay()?.dataset.date || null; }, done: () => isShown('horas-popup'),
      act: async () => { redDay()?.querySelector('.dclock')?.click(); await pause(600); } },
    { id: 'post_rows', el: '#horas-body', prep: ensurePost },
    { id: 'post_obs', el: '.hr-obs-btn:not([disabled])', prep: ensurePost },
    { id: 'post_submit', el: '#horas-submit-btn',
      prep: async () => { await ensurePost(); _postedAtStep = document.querySelectorAll('#horas-body .hr-ok').length; },
      done: () => document.querySelectorAll('#horas-body .hr-ok').length > _postedAtStep,
      act: async () => { await submitHoras(); await pause(600); } },
    { id: 'post_after', el: '#week-nav', prep: () => { if (isShown('horas-popup')) hideHoras(); } },
    { id: 'post_settings', el: '#settings-btn', done: () => isShown('settings-popup'), act: openSettings },
    { id: 'post_workday', el: () => settingsSection('s_daily') },
    { id: 'post_display', el: () => settingsSection('s_lang') },
    { id: 'post_posting', el: () => settingsSection('s_autofill') },
    { id: 'post_save', el: '.set-foot' },
  ],
};

let _flow = null;   // { name, i, token, done: false|'already'|'did', live, failed, held }
let _token = 0;     // a new one on every step entry: late work from an old step is dropped
let _waitTimer = 0;
let _moving = false;

function stepEl(step) {
  const el = typeof step.el === 'function' ? step.el() : document.querySelector(step.el);
  return el && el.getClientRects().length ? el : null;
}

// A step that waits for the user says so until it is done, then offers
// Next. Done before it was asked shows as already done. Nothing ever moves
// on by itself, and "done" is the page's state now, not a latch.
function stepFoot() {
  const steps = FLOWS[_flow.name];
  const step = steps[_flow.i];
  const waiting = !!step.done && !_flow.live && !!stepEl(step);
  const back = _flow.i ? `<button type="button" class="tour-btn ghost" onclick="flowStep(-1)" title="←">${esc(t('tour_back'))}</button>` : '';
  let right;
  if (waiting && _flow.failed) {
    right = `<span class="tour-wait">${esc(t('tour_failed'))}</span><button type="button" class="tour-btn ghost" onclick="flowStep(1)">${esc(t('tour_skip'))}</button>`;
  } else if (waiting) {
    right = `<span class="tour-wait">${esc(t('tour_do'))}</span><button type="button" class="tour-btn ghost" onclick="flowNext()" title="→">${esc(t('tour_doit'))}</button>`;
  } else {
    right = (_flow.live ? `<span class="tour-did">${icon('check')}${esc(t(_flow.done === 'already' ? 'tour_already' : 'tour_did'))}</span>` : '')
      + `<button type="button" class="tour-btn" onclick="flowNext()" title="→">${esc(t('tour_next'))}</button>`;
  }
  return `<button type="button" class="tour-link" onclick="endFlow()">${esc(t('tour_end_flow'))}</button>
      <span style="flex:1"></span>${back}${right}`;
}

function renderFoot() {
  const foot = id('tour-pop')?.querySelector('.tour-pop-foot');
  if (foot) foot.innerHTML = stepFoot();
}

// Keeps the footer in step with the page while the step is open.
function watchStep(step, token) {
  clearInterval(_waitTimer);
  if (!step.done) return;
  _waitTimer = setInterval(() => {
    if (!_flow || _flow.token !== token) return clearInterval(_waitTimer);
    const live = !!step.done();
    if (live === _flow.live) return;
    _flow.live = live;
    _flow.done = live ? (_flow.done || 'did') : false;
    if (live) _flow.failed = false;
    renderFoot();
  }, 300);
}

async function runStep(again) {
  clearInterval(_waitTimer);
  const steps = FLOWS[_flow.name];
  const step = steps[_flow.i];
  if (!step) return flowDone();
  const token = _flow.token = ++_token;
  if (!again) {
    _flow.failed = false;
    if (step.prep) { await step.prep(); await pause(350); }
    if (!_flow || _flow.token !== token) return;
  }
  _flow.live = !!(step.done && step.done());
  if (!again) _flow.done = _flow.live ? 'already' : false;
  const el = stepEl(step);
  showPop(`<div class="tour-pop-head"><b>${esc(t('ts_' + step.id + '_t'))}</b>
      <span class="tour-count">${esc(t('tour_step', { n: _flow.i + 1, m: steps.length }))}</span></div>
    ${helpBody('ts_' + step.id)}
    <div class="tour-pop-foot">${stepFoot()}</div>`, el, true, () => stepEl(step));
  watchStep(step, token);
}

function flowStep(dir) {
  if (!_flow || _moving) return;
  _flow.i = Math.max(0, _flow.i + dir);
  runStep();
}

// Next, the → key and "Do it for me": a step the user has not done yet is
// done for them first, so the steps after it find what they expect. If that
// does not work the step stays, and says so.
async function flowNext() {
  if (!_flow || _moving) return;
  const step = FLOWS[_flow.name][_flow.i];
  const token = _flow.token;
  if (step?.done && !step.done() && step.act && stepEl(step)) {
    _moving = true;
    clearInterval(_waitTimer);
    let ok = false;
    try {
      await step.act();
      for (let n = 0; n < 20 && !step.done(); n++) await pause(150);
      ok = !!step.done();
    } catch { /* reported below */ }
    // Leave no field focused, or the arrows would stay with it.
    if (document.activeElement && isTyping({ target: document.activeElement })) document.activeElement.blur();
    _moving = false;
    if (!_flow || _flow.token !== token) return;
    if (!ok) { _flow.failed = true; renderFoot(); watchStep(step, token); return; }
  }
  flowStep(1);
}

function startFlow(name) {
  hidePicker();
  exitHelp();
  _flow = { name, i: 0 };
  runStep();
}

function endFlow() {
  clearInterval(_waitTimer);
  _token++;
  _flow = null;
  hidePop();
}

function flowDone() {
  clearInterval(_waitTimer);
  _flow = null;
  showPop(`<div class="tour-pop-head"><b>${esc(t('tour_done_t'))}</b></div><p>${esc(t('tour_done'))}</p>
    <div class="tour-pop-foot"><span style="flex:1"></span>
      <button type="button" class="tour-btn ghost" onclick="hidePop();enterHelp()">${esc(t('flow_explore_t'))}</button>
      <button type="button" class="tour-btn" onclick="hidePop();showPicker()">${esc(t('tour_flows'))}</button></div>`, null, false);
}

// ── The tour's frame: banner and flow picker ─────────────────────────────────
const FLOW_ICONS = { work: 'play', review: 'chart', fix: 'edit', post: 'send', explore: 'help' };

function showPicker() {
  endFlow();
  exitHelp();
  if (!id('tour-picker')) document.body.insertAdjacentHTML('beforeend', '<div class="tour-picker" id="tour-picker" role="dialog" aria-modal="true"></div>');
  id('tour-picker').innerHTML = `<div class="tour-picker-box">
    <h3>${esc(t('tour_pick_title'))}</h3><p class="tour-picker-sub">${esc(t('tour_pick_sub'))}</p>
    <div class="tour-flows">${['work', 'review', 'fix', 'post', 'explore'].map(f => `
      <button type="button" class="tour-flow" onclick="${f === 'explore' ? 'hidePicker();enterHelp()' : `startFlow('${f}')`}">
        ${icon(FLOW_ICONS[f])}<span><b>${esc(t('flow_' + f + '_t'))}</b><small>${esc(t('flow_' + f))}</small></span></button>`).join('')}
    </div>
    <div class="tour-picker-foot"><button type="button" class="tour-link" onclick="finishTour()">${esc(t('tour_finish'))}</button></div>
  </div>`;
  id('tour-picker').classList.add('show');
  id('tour-picker').querySelector('.tour-flow').focus();
}

function hidePicker() { id('tour-picker')?.classList.remove('show'); }

// The tour's own controls live in the sidebar, under the day list. When the
// sidebar is collapsed, or too short to keep two day rows beside them, they
// fall back to a bar at the bottom of the window.
const DAY_ROW_H = 78;
let _panelH = 0;

function renderBanner() {
  if (!TOUR) return;
  if (!id('tour-panel')) document.querySelector('#left-panel .attrib-row').insertAdjacentHTML('beforebegin', '<div class="tour-panel" id="tour-panel" role="status"></div>');
  id('tour-panel').innerHTML = `<div class="tour-panel-head">${icon('compass')}<b>${esc(t('tour_banner'))}</b></div>
    <p class="tour-panel-note">${esc(t('tour_sample_short'))}</p>
    <div class="tour-panel-btns">
      <button type="button" class="tour-btn ghost" onclick="showPicker()">${esc(t('tour_flows'))}</button>
      <button type="button" class="tour-btn ghost" onclick="enterHelp()">${icon('help')}${esc(t('tour_help'))}</button>
      <button type="button" class="tour-btn" onclick="finishTour()">${esc(t('tour_finish'))}</button></div>`;
  if (!id('tour-banner')) document.body.insertAdjacentHTML('beforeend', '<div class="tour-banner" id="tour-banner" role="status"></div>');
  id('tour-banner').innerHTML = `${icon('compass')}
    <div class="tour-banner-text"><b>${esc(t('tour_banner'))}</b><span>${esc(t('tour_sample'))}</span></div>
    <button type="button" class="tour-btn ghost" onclick="showPicker()">${esc(t('tour_flows'))}</button>
    <button type="button" class="tour-btn ghost" onclick="enterHelp()">${icon('help')}${esc(t('tour_help'))}</button>
    <button type="button" class="tour-btn" onclick="finishTour()">${esc(t('tour_finish'))}</button>`;
  _panelH = 0;
  placeBanner();
}

// The day list's room counts the panel's own height, so showing or hiding
// the panel never flips the decision back.
function placeBanner() {
  const panel = id('tour-panel');
  if (!panel) return;
  const inSide = panel.style.display !== 'none';
  if (inSide && panel.offsetHeight) _panelH = panel.offsetHeight;
  const room = id('week-nav').clientHeight + (inSide ? _panelH : 0);
  const side = !id('left-panel').classList.contains('collapsed') && room - (_panelH || 170) >= 2 * DAY_ROW_H;
  if (side === inSide && document.body.classList.contains('tour-bar') === !side) return;
  panel.style.display = side ? '' : 'none';
  document.body.classList.toggle('tour-bar', !side);
  if (side && !_panelH) _panelH = panel.offsetHeight;
}

// The sandbox can be gone (daemon restarted, or the tour finished in
// another window): start a fresh one before the page loads its data.
async function ensureTour() {
  const r = await fetch('/tour/api/health');
  if (r.ok) return;
  await apiJSON('POST', '/api/tour/start', { lang: new URLSearchParams(location.search).get('lang') || _lang });
}

async function startTour() {
  try {
    await apiJSON('POST', '/api/tour/start', { lang: _lang });
    location.href = '/?tour=1';
  } catch (e) { showError(e.message); }
}

async function finishTour() {
  try { await apiJSON('POST', '/api/tour/finish'); } catch { /* gone already */ }
  try { sessionStorage.removeItem('kw-tour-picked'); } catch { /* storage off */ }
  location.replace('/');
}

// A first look at an empty tracker offers the tour once.
async function maybeOfferTour() {
  if (TOUR || pref('ui_tour_offered', '0') === '1') return;
  let empty = false;
  try { empty = (await apiJSON('GET', '/api/tasks?limit=1')).tasks.length === 0; } catch { return; }
  if (!empty) return;
  showPop(`<div class="tour-pop-head"><b>${esc(t('tour_offer_t'))}</b></div><p>${esc(t('tour_offer'))}</p>
    <div class="tour-pop-foot"><span style="flex:1"></span>
      <button type="button" class="tour-btn ghost" onclick="tourOffered(false)">${esc(t('tour_offer_later'))}</button>
      <button type="button" class="tour-btn" onclick="tourOffered(true)">${esc(t('tour_offer_go'))}</button></div>`, id('more-btn'), false);
}

async function tourOffered(go) {
  hidePop();
  await setPref('ui_tour_offered', '1').catch(() => {});
  if (go) startTour();
}

function addHelpButtons() {
  const btn = helpId => `<button type="button" class="help-btn" onclick="helpHere(event,'${helpId}')" title="${escAttr(t('help_btn'))}" aria-label="${escAttr(t('help_btn'))}">${icon('help')}</button>`;
  for (const [sel, helpId] of HELP_SPOTS) {
    const box = document.querySelector(sel);
    if (box && !box.querySelector(':scope > .help-btn')) box.insertAdjacentHTML('beforeend', btn(helpId));
  }
  id('settings-popup').querySelectorAll('.set-sec[data-help]').forEach(sec => {
    const head = sec.querySelector('h4, summary');
    if (!head || head.querySelector('.help-btn')) return;
    const chev = head.querySelector('.chev');
    if (chev) chev.insertAdjacentHTML('beforebegin', btn(sec.dataset.help));
    else head.insertAdjacentHTML('beforeend', btn(sec.dataset.help));
  });
}

// Labels follow the language: called from relabel() through initTour's hook.
function relabelTour() {
  renderBanner();
  document.querySelectorAll('.help-btn').forEach(b => { b.title = t('help_btn'); b.setAttribute('aria-label', t('help_btn')); });
  if (_helpOn) enterHelp();
}

function initTour() {
  addHelpButtons();
  if (TOUR) {
    document.title = 'kowalski · ' + t('tour_banner');
    id('tour-item').style.display = 'none';
    renderBanner();
    new ResizeObserver(placeBanner).observe(id('left-panel'));
    addEventListener('resize', placeBanner);
    let picked = false;
    try { picked = sessionStorage.getItem('kw-tour-picked') === '1'; sessionStorage.setItem('kw-tour-picked', '1'); } catch { /* storage off */ }
    if (!picked) showPicker();
  } else {
    maybeOfferTour();
  }
}
