'use strict';
// ── Settings ──────────────────────────────────────────────────────────────────
function applyPrefs() {
  _hideWeekends = pref('ui_hide_weekends', '0') === '1';
  _sidebarDays = parseInt(pref('ui_sidebar_days', '7'), 10);
  if (!Number.isFinite(_sidebarDays) || _sidebarDays < 1 || _sidebarDays > 90) _sidebarDays = 7;
  _refLinks = pref('ui_links', '0') === '1';
  _showAddEntry = pref('ui_show_add_entry', '0') === '1';
  _showKeys = pref('ui_show_keys', '1') === '1';
  _singleKeys = pref('ui_single_keys', '1') === '1';
  _summaryFormat = pref('ui_summary_format', 'grouped');
  _chartVisible = pref('ui_chart_visible', '1') === '1';
  chartDays = parseInt(pref('ui_chart_days', '14'), 10);
  if (!Number.isFinite(chartDays) || chartDays < 1) chartDays = 14;
  chartView = pref('ui_chart_view', 'bars') === 'lanes' ? 'lanes' : 'bars';
}

async function loadSettings() {
  const data = await apiJSON('GET', '/api/settings');
  settings = Object.fromEntries(data.settings.map(({ key, value }) => [key, value]));
  applyPrefs();
}

let _settingsLoaded = false;
// Window rows being edited; switching a mode off keeps them for this visit.
let _paidDraft = [];
let _lockDraft = [];

// "08:00-12:00=15,13:00-18:00=15" → [{ from, to, min }]; and back.
function parseWindows(text, withMinutes) {
  return (text || '').split(',').map(x => x.trim()).filter(Boolean).map(item => {
    const [span, min] = item.split('=');
    const [from, to] = span.split('-');
    return withMinutes ? { from, to, min: Number(min) } : { from, to };
  });
}
function joinWindows(rows, withMinutes) {
  return rows.map(r => `${r.from}-${r.to}` + (withMinutes ? `=${r.min}` : '')).join(',');
}

async function showSettings() {
  try {
    await loadSettings();
    const daily = Number(pref('daily_work_minutes', '510'));
    id('set-daily-h').value = Math.floor(daily / 60);
    id('set-daily-m').value = daily % 60;
    id('set-lunch').value = pref('lunch_minutes', '60');
    const paid = pref('paid_breaks', null);
    id('set-paid-mode').value = paid == null ? 'provider' : paid === '' ? 'off' : 'custom';
    _paidDraft = parseWindows(paid, true);
    _lockDraft = parseWindows(pref('lock_pause', ''), false);
    id('set-lock-on').checked = _lockDraft.length > 0;
    id('set-lang').value = _lang;
    id('set-time-format').value = pref('ui_time_format', 'system');
    id('set-sidebar-days').value = pref('ui_sidebar_days', '7');
    id('set-day-order').value = pref('ui_day_order', 'oldest');
    id('set-show-weekends').checked = pref('ui_hide_weekends', '0') !== '1';
    id('set-summary-format').value = pref('ui_summary_format', 'grouped');
    id('set-links').checked = pref('ui_links', '0') === '1';
    id('set-show-add-entry').checked = pref('ui_show_add_entry', '0') === '1';
    id('set-show-keys').checked = pref('ui_show_keys', '1') === '1';
    id('set-single-keys').checked = pref('ui_single_keys', '1') === '1';
    id('set-open-launch').checked = pref('ui_open_on_launch', '1') === '1';
    id('set-autofill').checked = pref('ui_autofill_obs', '0') === '1';
    id('set-post-sessions').checked = pref('post_sessions', '0') === '1';
    id('set-post-sessions-row').style.display = provider?.sessions ? '' : 'none';
    id('set-account-row').style.display = provider ? '' : 'none';
    renderProviderSettings();
    const fields = (provider?.fields || []).slice().sort((a, b) => a.order - b.order);
    const hiddenTabs = chartHiddenGroups();
    id('set-chart-tabs-row').style.display = fields.length ? '' : 'none';
    id('set-chart-tabs').innerHTML = fields.map(f => `<label class="set-sw"><input type="checkbox" class="sw" data-group="${escAttr(f.name)}"${hiddenTabs.includes(f.name) ? '' : ' checked'}><span>${esc(providerLabel(f))}</span></label>`).join('');
    id('set-zone').value = pref('reporting_zone', '');
    id('set-port').textContent = pref('http_port', location.port || '47100');
    renderPaidRows(false);
    renderLockRows(false);
    _settingsLoaded = true;
  } catch (e) {
    // Saving defaults over settings that did not load would overwrite them.
    _settingsLoaded = false;
    showError(e.message);
  }
  id('settings-overlay').classList.add('show');
  id('settings-popup').classList.add('show');
  setTimeout(() => id('set-daily-h').focus(), 50);
}

// Settings the provider declares, saved as `provider.<name>`.
function renderProviderSettings() {
  const list = provider?.settings || [];
  id('set-provider-rows').innerHTML = list.map(s => {
    const key = 'provider.' + s.name;
    const val = pref(key, s.default);
    const hint = providerHint(s);
    const ctl = s.type === 'choice'
      ? `<span class="sel"><select id="set-p-${s.name}" data-key="${key}">${s.choices.map(c =>
          `<option value="${escAttr(c.value)}"${c.value === val ? ' selected' : ''}>${esc(providerLabel(c))}</option>`).join('')}</select></span>`
      : `<input type="text" class="wide" id="set-p-${s.name}" data-key="${key}" value="${escAttr(val)}" spellcheck="false" autocomplete="off">`;
    return `<div class="set-row"><label class="set-lbl" for="set-p-${s.name}"><span>${esc(providerLabel(s))}</span>${hint ? `<small>${esc(hint)}</small>` : ''}</label>
      <div class="set-ctl">${ctl}</div></div>`;
  }).join('');
}

// Number fields have no spinners; the arrow keys step them instead.
function stepNumber(e) {
  const el = e.target;
  if (!el.matches('#settings-popup input.n') || (e.key !== 'ArrowUp' && e.key !== 'ArrowDown')) return;
  e.preventDefault();
  const max = 10 ** Number(el.maxLength || 3) - 1;
  el.value = Math.min(max, Math.max(0, (parseInt(el.value, 10) || 0) + (e.key === 'ArrowUp' ? 1 : -1)));
  el.dispatchEvent(new Event('input', { bubbles: true }));
}
document.addEventListener('keydown', stepNumber);

function hideSettings() {
  id('settings-overlay').classList.remove('show');
  id('settings-popup').classList.remove('show');
}

// ── Window rows ───────────────────────────────────────────────────────────────
// One row per window: start – end (+ minutes for paid breaks) and a remove
// button. Times are typed in the chosen 12/24-hour format; a lock window may
// cross midnight and says so.
function timeField(kind, k, v) {
  return `<input class="t" value="${escAttr(v ? fmtClock(v) : '')}" data-k="${k}" spellcheck="false" autocomplete="off" onchange="tidyTime(this,'${kind}')">`;
}
function windowRows(kind, rows, withMinutes) {
  return rows.map((r, i) => {
    const overnight = r.from && r.to && r.to <= r.from;
    return `<div class="win-row">
      ${timeField(kind, 'from', r.from)}<i>–</i>${timeField(kind, 'to', r.to)}
      ${withMinutes ? `<span class="fld"><input class="n" inputmode="numeric" maxlength="3" value="${escAttr(String(r.min || ''))}" data-k="min" oninput="readWindows('${kind}')"><i>min</i></span>` : ''}
      ${!withMinutes && overnight ? `<span class="win-next">${esc(t('win_next_day'))}</span>` : ''}
      <button type="button" class="btn-icon" title="${escAttr(t('win_remove'))}" aria-label="${escAttr(t('win_remove'))}" onclick="dropWindow('${kind}',${i})">${icon('trash')}</button>
    </div>`;
  }).join('') + `<button type="button" class="win-add" onclick="addWindow('${kind}')">${icon('plus')}${esc(t('win_add'))}</button>`;
}

// Rewrites a typed time in the chosen format, or marks it when unreadable.
function tidyTime(el, kind) {
  const v = parseClock(el.value);
  el.classList.toggle('bad', !v);
  if (!v) return;
  el.value = fmtClock(v);
  readWindows(kind);
  if (kind === 'lock') renderLockRows(false); // the "next day" tag
}

function renderPaidRows(changed) {
  if (changed && id('set-paid-mode').value === 'custom' && !_paidDraft.length) {
    _paidDraft = (S?.provider_paid_breaks || []).map(p => ({ from: minClock(p.from_min), to: minClock(p.to_min), min: p.minutes }));
  }
  const mode = id('set-paid-mode').value;
  const box = id('paid-rows');
  if (mode === 'custom') { box.innerHTML = windowRows('paid', _paidDraft, true); return; }
  if (mode === 'off') { box.innerHTML = ''; return; }
  const own = S?.provider_paid_breaks || [];
  box.innerHTML = own.length
    ? own.map(p => `<div class="win-ro">${esc(fmtClock(minClock(p.from_min)))} – ${esc(fmtClock(minClock(p.to_min)))} · ${p.minutes} min</div>`).join('')
    : `<div class="win-ro">${esc(t('paid_none'))}</div>`;
}

function renderLockRows(changed) {
  if (changed && id('set-lock-on').checked && !_lockDraft.length) _lockDraft = [{ from: '17:00', to: '19:00' }];
  id('lock-rows').innerHTML = id('set-lock-on').checked ? windowRows('lock', _lockDraft, false) : '';
}

function minClock(m) { return `${String(Math.floor(m / 60)).padStart(2, '0')}:${String(m % 60).padStart(2, '0')}`; }

function readWindows(kind) {
  const rows = [...id(`${kind}-rows`).querySelectorAll('.win-row')].map(row => {
    const v = k => row.querySelector(`[data-k="${k}"]`)?.value || '';
    const from = parseClock(v('from')) || '', to = parseClock(v('to')) || '';
    return kind === 'paid' ? { from, to, min: Number(v('min')) } : { from, to };
  });
  if (kind === 'paid') _paidDraft = rows; else _lockDraft = rows;
}

function addWindow(kind) {
  readWindows(kind);
  if (kind === 'paid') { _paidDraft.push({ from: '13:00', to: '18:00', min: 15 }); renderPaidRows(false); }
  else { _lockDraft.push({ from: '17:00', to: '19:00' }); renderLockRows(false); }
}

function dropWindow(kind, i) {
  readWindows(kind);
  if (kind === 'paid') { _paidDraft.splice(i, 1); renderPaidRows(false); }
  else { _lockDraft.splice(i, 1); renderLockRows(false); }
}

// ── Save ──────────────────────────────────────────────────────────────────────
// One PATCH with every setting; the daemon applies all or none, so a refusal
// leaves the dialog open with the edits in place.
function settingsError(elId, key) {
  id(elId)?.focus();
  showError(t(key));
}

async function applySettings() {
  if (!_settingsLoaded) { showError(t('settings_load_failed')); return; }
  const daily = (parseInt(id('set-daily-h').value, 10) || 0) * 60 + (parseInt(id('set-daily-m').value, 10) || 0);
  if (daily < 1 || daily > 1440) return settingsError('set-daily-h', 'set_bad_hours');
  let lunch = parseInt(id('set-lunch').value, 10);
  if (isNaN(lunch) || lunch < 0) lunch = 0;

  const mode = id('set-paid-mode').value;
  let paidBreaks = null;
  if (mode === 'off') paidBreaks = '';
  if (mode === 'custom') {
    readWindows('paid');
    const ok = _paidDraft.length && _paidDraft.every(r => r.from && r.to && r.from < r.to && r.min >= 1 && r.min <= 240);
    if (!ok) return settingsError('paid-rows', 'win_bad');
    paidBreaks = joinWindows(_paidDraft, true);
  }
  let lockPause = null;
  if (id('set-lock-on').checked) {
    readWindows('lock');
    const ok = _lockDraft.length && _lockDraft.every(r => r.from && r.to && r.from !== r.to);
    if (!ok) return settingsError('lock-rows', 'win_bad');
    lockPause = joinWindows(_lockDraft, false);
  }
  let sidebarDays = parseInt(id('set-sidebar-days').value, 10);
  if (isNaN(sidebarDays)) sidebarDays = 7;
  sidebarDays = Math.min(90, Math.max(1, sidebarDays));
  const lang = id('set-lang').value;
  const changes = {
    daily_work_minutes: String(daily),
    lunch_minutes: String(lunch),
    paid_breaks: paidBreaks,
    lock_pause: lockPause,
    ui_lang: lang,
    ui_time_format: id('set-time-format').value,
    ui_sidebar_days: String(sidebarDays),
    ui_day_order: id('set-day-order').value,
    ui_hide_weekends: id('set-show-weekends').checked ? '0' : '1',
    ui_summary_format: id('set-summary-format').value,
    ui_links: id('set-links').checked ? '1' : '0',
    ui_show_add_entry: id('set-show-add-entry').checked ? '1' : '0',
    ui_show_keys: id('set-show-keys').checked ? '1' : '0',
    ui_single_keys: id('set-single-keys').checked ? '1' : '0',
    ui_open_on_launch: id('set-open-launch').checked ? '1' : '0',
    ui_autofill_obs: id('set-autofill').checked ? '1' : '0',
    post_sessions: id('set-post-sessions').checked ? '1' : '0',
    // An emptied text goes back to the provider's default.
    ...Object.fromEntries([...document.querySelectorAll('#set-provider-rows [data-key]')]
      .map(el => [el.dataset.key, el.value.trim() || null])),
    ui_chart_hidden: JSON.stringify([...id('set-chart-tabs').querySelectorAll('input:not(:checked)')].map(el => el.dataset.group)),
  };
  const zoneName = id('set-zone').value.trim();
  if (zoneName && zoneName !== pref('reporting_zone', '')) changes.reporting_zone = zoneName;

  try {
    const data = await apiJSON('PATCH', '/api/settings', changes);
    settings = Object.fromEntries(data.settings.map(({ key, value }) => [key, value]));
    applyPrefs();
    hideSettings();
    showToast(t('settings_saved'));
    applyFeatureToggles();
    renderChartGroups();
    if (lang !== _lang) { setLangFrom(settings); relabel(); return; }
    loadCurrent(); // the header picks up the link and time-format choices
    loadSchedule();
    loadDay(selectedDate); // weekends, sidebar days and day order
  } catch (e) {
    showError(e.message);
  }
}
