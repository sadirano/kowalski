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
  _taskOrder = pref('ui_task_order', 'time');
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
    id('set-task-order').value = pref('ui_task_order', 'time');
    id('set-links').checked = pref('ui_links', '0') === '1';
    id('set-show-add-entry').checked = pref('ui_show_add_entry', '0') === '1';
    id('set-show-keys').checked = pref('ui_show_keys', '1') === '1';
    id('set-single-keys').checked = pref('ui_single_keys', '1') === '1';
    id('set-open-launch').checked = pref('ui_open_on_launch', '1') === '1';
    id('set-autofill').checked = pref('ui_autofill_obs', '0') === '1';
    id('set-post-sessions').checked = pref('post_sessions', '0') === '1';
    renderProviderControls();
    loadSourceStatus().catch(e => { id('set-source-error').textContent = e.message; });
    id('set-zone').value = pref('reporting_zone', '');
    id('set-day-start').value = pref('day_start', '00:00');
    id('set-port').textContent = pref('http_port', location.port || '47100');
    apiJSON('GET', '/api/version').then(data => {
      id('set-version').textContent = data.version;
      id('update-row').style.display = data.update_repo || _lastUpdateOutcome ? '' : 'none';
      if (!data.update_repo && !_lastUpdateOutcome) id('update-result').style.display = 'none';
      else if (_lastUpdateOutcome) {
        id('update-result').style.display = 'flex';
        id('update-message').textContent = updateOutcomeText(_lastUpdateOutcome);
      }
    }).catch(e => showError(e.message));
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

function renderProviderControls() {
  id('set-post-sessions-row').style.display = provider?.sessions ? '' : 'none';
  id('set-account-row').style.display = provider ? '' : 'none';
  renderProviderStatus();
  renderProviderSettings();
  const fields = (provider?.fields || []).slice().sort((a, b) => a.order - b.order);
  const hiddenTabs = chartHiddenGroups();
  id('set-chart-tabs-row').style.display = fields.length ? '' : 'none';
  id('set-chart-tabs').innerHTML = fields.map(f => `<label class="set-sw"><input type="checkbox" class="sw" data-group="${escAttr(f.name)}"${hiddenTabs.includes(f.name) ? '' : ' checked'}><span>${esc(providerLabel(f))}</span></label>`).join('');
}

function renderProviderStatus() {
  id('set-provider-status').style.display = '';
  const providerText = id('set-provider-status-text');
  providerText.textContent = providerStatus.state === 'unavailable'
    ? t('provider_unavailable', { reason: providerStatus.reason })
    : [providerStatus.name, providerStatus.build].filter(Boolean).join(' ');
  providerText.classList.toggle('warn', providerStatus.state === 'unavailable');
  const candidate = providerStatus.candidate;
  id('set-provider-waiting').textContent = candidate ? t('provider_waiting', { file: candidate.file }) : '';
  id('set-provider-review').style.display = candidate ? '' : 'none';
  renderSourceStatus();
}

let _sourceData = null;
let _sourceBusy = false;
let _sourceMode = 'enroll';
let _sourceProposal = null;
let _sourceHow = 'compared';
let _sourceAcceptArmed = false;

async function loadSourceStatus() {
  _sourceData = await apiJSON('GET', '/api/provider/source');
  renderSourceStatus();
}

function renderSourceStatus() {
  const source = _sourceData?.enrollment;
  id('set-source-use').style.display = source ? 'none' : '';
  for (const name of ['check', 'stop']) id(`set-source-${name}`).style.display = source ? '' : 'none';
  const available = _sourceData?.available;
  id('set-source-install').style.display = source && available ? '' : 'none';
  if (available) id('set-source-install').textContent = t('source_install', { version: available.version });
  const lines = [];
  if (source) {
    lines.push(source.source, `${source.provider}/${source.channel}`);
    lines.push(t('source_installed', { version: _sourceData.installed?.version || t('source_none') }));
    if (source.last_check_ms) lines.push(t('source_last_check', { time: new Date(source.last_check_ms).toLocaleString(locale()) }));
    if (source.last_error) lines.push(t('source_last_error', { error: source.last_error }));
    if (_sourceData.ignored_drop_folder) lines.push(t('source_ignored'));
  }
  id('set-source-status').replaceChildren(...lines.map(line => {
    const span = document.createElement('span');
    span.textContent = line;
    return span;
  }));
}

function sourceDialogError(message = '') { id('source-dialog-error').textContent = message; }
function sourceInputChanged() {
  if (_sourceProposal) { _sourceProposal = null; id('source-proposal').style.display = 'none'; }
  _sourceHow = 'compared';
  const usingSetup = _sourceData?.setup && id('source-location').value.trim() === _sourceData.setup.source;
  id('source-setup').style.display = usingSetup ? '' : 'none';
  id('source-accept-row').style.display = usingSetup ? '' : 'none';
  id('source-key-label').querySelector('span').textContent = t(usingSetup ? 'source_paste_key' : 'source_key');
  sourceDialogError();
  id('source-primary').textContent = t('source_review');
}

function showSourceDialog() {
  if (_sourceBusy) return;
  _sourceMode = 'enroll';
  _sourceProposal = null;
  _sourceHow = 'compared';
  _sourceAcceptArmed = false;
  const setup = _sourceData?.setup;
  id('source-title').textContent = t('source_title');
  id('source-location-label').style.display = '';
  id('source-key-label').style.display = '';
  id('source-location').value = setup?.source || '';
  id('source-key').value = '';
  id('source-key-label').querySelector('span').textContent = t(setup ? 'source_paste_key' : 'source_key');
  id('source-setup').style.display = setup ? '' : 'none';
  id('source-setup').textContent = setup ? t('source_unverified', { key: setup.key }) : '';
  id('source-accept-row').style.display = setup ? '' : 'none';
  id('source-accept').textContent = t('source_accept');
  id('source-proposal').style.display = 'none';
  id('source-primary').textContent = t('source_review');
  sourceDialogError();
  id('source-overlay').classList.add('show');
  id('source-popup').classList.add('show');
  setTimeout(() => id(setup ? 'source-key' : 'source-location').focus(), 50);
}

function hideSourceDialog() {
  if (_sourceBusy) return;
  id('source-overlay').classList.remove('show');
  id('source-popup').classList.remove('show');
  _sourceProposal = null;
}

function acceptSourceAsIs() {
  if (_sourceBusy || !_sourceData?.setup || id('source-location').value.trim() !== _sourceData.setup.source) return;
  if (!_sourceAcceptArmed) {
    _sourceAcceptArmed = true;
    id('source-accept').textContent = t('source_accept_confirm');
    return;
  }
  _sourceHow = 'accepted';
  id('source-key').value = _sourceData.setup.key;
  sourceInputChanged();
  _sourceHow = 'accepted';
  submitSource();
}

function showStopSource() {
  if (_sourceBusy) return;
  _sourceMode = 'stop';
  id('source-title').textContent = t('source_stop');
  id('source-location-label').style.display = 'none';
  id('source-key-label').style.display = 'none';
  id('source-setup').style.display = '';
  id('source-setup').textContent = t('source_stop_confirm');
  id('source-proposal').style.display = 'none';
  id('source-accept-row').style.display = 'none';
  id('source-primary').textContent = t('source_stop');
  sourceDialogError();
  id('source-overlay').classList.add('show');
  id('source-popup').classList.add('show');
}

async function submitSource() {
  if (_sourceBusy) return;
  _sourceBusy = true;
  id('source-primary').disabled = true;
  try {
    if (_sourceMode === 'stop') {
      await apiJSON('DELETE', '/api/provider/source');
      _sourceBusy = false;
      hideSourceDialog();
      await loadSourceStatus();
      await loadProvider();
      return;
    }
    const source = id('source-location').value.trim();
    const key = id('source-key').value.trim();
    if (_sourceData?.setup && source === _sourceData.setup.source && key.toLowerCase() !== _sourceData.setup.key.toLowerCase()) throw new Error(t('source_key_mismatch'));
    if (!/^[0-9a-fA-F]{64}$/.test(key)) throw new Error(t('source_key_invalid'));
    const body = { source, key, how: _sourceHow, confirmed: true, yes: !!_sourceProposal };
    if (_sourceProposal) body.proposal_token = _sourceProposal.proposal_token;
    const result = await apiJSON('POST', '/api/provider/source', body);
    if (!body.yes) {
      _sourceProposal = result;
      const p = result.proposal;
      id('source-proposal').textContent = t('source_proposal', { provider: p.provider, channel: p.channel, version: p.version, sequence: p.sequence });
      id('source-proposal').style.display = '';
      id('source-primary').textContent = t('source_confirm');
    } else {
      _sourceBusy = false;
      hideSourceDialog();
      await loadSourceStatus();
      await loadProvider();
    }
  } catch (e) {
    if (e.status === 409 && _sourceProposal) {
      _sourceProposal = null;
      id('source-proposal').style.display = 'none';
      id('source-primary').textContent = t('source_review');
    }
    sourceDialogError(e.message);
  }
  finally { _sourceBusy = false; id('source-primary').disabled = false; }
}

async function checkSource() {
  if (_sourceBusy) return;
  _sourceBusy = true;
  id('set-source-check').disabled = true;
  id('set-source-error').textContent = '';
  try { await apiJSON('POST', '/api/provider/source/check', {}); }
  catch (e) { id('set-source-error').textContent = e.message; }
  finally { await loadSourceStatus().catch(() => {}); _sourceBusy = false; id('set-source-check').disabled = false; }
}

async function installSource() {
  if (_sourceBusy || !_sourceData?.available) return;
  _sourceBusy = true;
  id('set-source-install').disabled = true;
  id('set-source-error').textContent = '';
  try {
    const result = await apiJSON('POST', '/api/provider/source/install', { yes: true });
    if (result.restart) id('provider-restart-prompt').style.display = 'flex';
    await loadSourceStatus();
    await loadProvider();
  } catch (e) { id('set-source-error').textContent = e.message; }
  finally { _sourceBusy = false; id('set-source-install').disabled = false; }
}

let _approvalCandidate = null;
let _approvalBusy = false;
let _approvalAcceptArmed = false;

function showProviderApproval() {
  const candidate = providerStatus.candidate;
  if (!candidate) return;
  _approvalCandidate = candidate;
  _approvalAcceptArmed = false;
  const modified = new Date(candidate.modified_ms);
  const size = candidate.size >= 1024 * 1024
    ? `${(candidate.size / (1024 * 1024)).toLocaleString(locale(), { maximumFractionDigits: 1 })} MB`
    : `${(candidate.size / 1024).toLocaleString(locale(), { maximumFractionDigits: 1 })} KB`;
  id('approve-details').innerHTML = `<strong>${esc(candidate.file)}</strong>
    <span>${esc(t('approve_size'))}: ${esc(size)}</span>
    <span>${esc(t('approve_modified'))}: ${esc(modified.toLocaleDateString(locale(), { year: 'numeric', month: 'short', day: 'numeric' }))} ${esc(padHHMM(modified))}</span>`;
  const version = candidate.version || {};
  const claims = [
    ['approve_product', version.product_name],
    ['approve_version', version.file_version],
    ['approve_company', version.company_name],
  ].filter(([, value]) => value);
  id('approve-claims').innerHTML = `<h4>${esc(t('approve_claims'))}</h4>` + claims.map(([key, value]) =>
    `<div><span>${esc(t(key))}:</span> ${esc(value)}</div>`).join('');
  id('approve-hash').textContent = candidate.sha256;
  id('approve-paste').value = '';
  id('approve-match').textContent = '';
  id('approve-match').className = 'approve-match';
  id('approve-compared').disabled = true;
  id('approve-accept').textContent = t('approve_accept');
  id('approve-overlay').classList.add('show');
  id('approve-popup').classList.add('show');
  setTimeout(() => id('approve-paste').focus(), 50);
}

function hideProviderApproval() {
  if (_approvalBusy) return;
  _approvalCandidate = null;
  _approvalAcceptArmed = false;
  id('approve-paste').value = '';
  id('approve-overlay').classList.remove('show');
  id('approve-popup').classList.remove('show');
}

function updateProviderHashMatch() {
  const pasted = id('approve-paste').value.trim();
  const matches = !!_approvalCandidate && pasted.toLowerCase() === _approvalCandidate.sha256.toLowerCase();
  const result = id('approve-match');
  result.textContent = pasted ? t(matches ? 'approve_match' : 'approve_nomatch') : '';
  result.className = 'approve-match' + (pasted ? matches ? ' matches' : ' differs' : '');
  id('approve-compared').disabled = !matches || _approvalBusy;
}

function trustProviderAsIs() {
  if (_approvalBusy || !_approvalCandidate) return;
  if (!_approvalAcceptArmed) {
    _approvalAcceptArmed = true;
    id('approve-accept').textContent = t('approve_accept_confirm');
    return;
  }
  applyProviderApproval('accepted');
}

async function applyProviderApproval(how) {
  if (_approvalBusy || !_approvalCandidate || (how === 'compared' && id('approve-compared').disabled)) return;
  _approvalBusy = true;
  id('approve-compared').disabled = true;
  id('approve-accept').disabled = true;
  try {
    const result = await apiJSON('POST', '/api/provider/approve', { sha256: _approvalCandidate.sha256, how });
    _approvalBusy = false;
    hideProviderApproval();
    await loadProvider();
    if (result.restart) id('provider-restart-prompt').style.display = 'flex';
  } catch (e) {
    if (e.status === 409) {
      _approvalBusy = false;
      hideProviderApproval();
      try { await loadProvider(); } catch (refreshError) { showError(refreshError.message); return; }
      showError(t('approve_changed'));
    } else {
      showError(e.message);
    }
  } finally {
    _approvalBusy = false;
    id('approve-accept').disabled = false;
    updateProviderHashMatch();
  }
}

let _restarting = false;
async function restartKowalski() {
  if (_restarting) return;
  _restarting = true;
  const banner = id('restart-banner');
  banner.textContent = t('restarting');
  banner.classList.add('show');
  try {
    const before = (await apiJSON('GET', '/api/version')).pid;
    await apiJSON('POST', '/api/restart');
    await waitForDaemon(before);
  } catch (e) {
    banner.classList.remove('show');
    showError(e.message);
  } finally {
    _restarting = false;
  }
}

// A restart can finish between two polls, so wait for a different process
// to answer rather than for the old one to go quiet.
async function waitForDaemon(before, attempts = 80) {
  const banner = id('restart-banner');
  banner.textContent = t('restarting');
  for (let attempt = 0; attempt < attempts; attempt++) {
    await new Promise(resolve => setTimeout(resolve, 500));
    try {
      if ((await apiJSON('GET', '/api/version')).pid !== before) { location.reload(); return; }
    } catch (_) { /* down between the two daemons */ }
  }
  banner.textContent = t('restart_failed');
}

let _updateRelease = null;
let _updateConfirm = false;
let _updateBusy = false;
let _lastUpdateOutcome = null;
function updateOutcomeText(last) {
  return last.phase === 'committed'
    ? t('update_done', { to: last.to })
    : t('update_rolled_back', { to: last.to, from: last.from, reason: last.reason });
}
async function showUpdateOutcome() {
  const result = await apiJSON('GET', '/api/update?outcome=1');
  if (!result.last) return;
  _lastUpdateOutcome = result.last;
  showToast(updateOutcomeText(result.last), result.last.phase === 'rolled_back');
  await apiJSON('POST', '/api/update/ack', { id: result.last.id });
}
async function checkKowalskiUpdate() {
  if (_updateBusy) return;
  _updateBusy = true;
  id('update-check').disabled = true;
  try {
    const result = await apiJSON('GET', '/api/update');
    _updateRelease = result.state === 'available' ? result : null;
    _updateConfirm = false;
    id('update-result').style.display = 'flex';
    id('update-message').textContent = _updateRelease
      ? (result.signed ? t('update_available', { v: result.version, c: result.current }) : t('update_unsigned'))
      : t('update_latest', { v: result.version });
    const notes = id('update-notes');
    const safeNotes = _updateRelease && result.repo &&
      result.notes_url.startsWith(`https://github.com/${result.repo}/releases/`);
    notes.style.display = safeNotes ? '' : 'none';
    if (safeNotes) notes.href = result.notes_url;
    id('update-install').style.display = _updateRelease && result.signed ? '' : 'none';
    id('update-install').textContent = t('update_install');
  } catch (e) { showError(e.message); }
  finally { _updateBusy = false; id('update-check').disabled = false; }
}

async function installKowalskiUpdate() {
  if (!_updateRelease || !_updateRelease.signed || _updateBusy || _restarting) return;
  if (!_updateConfirm) {
    _updateConfirm = true;
    id('update-install').textContent = t('update_confirm');
    return;
  }
  _updateBusy = true;
  id('update-install').disabled = true;
  const banner = id('restart-banner');
  banner.textContent = t('updating');
  banner.classList.add('show');
  try {
    const before = (await apiJSON('GET', '/api/version')).pid;
    await apiJSON('POST', '/api/update', { version: _updateRelease.version });
    await waitForDaemon(before, 320);
  } catch (e) {
    banner.classList.remove('show');
    showError(e.data?.error === 'update_bad_signature' ? t('update_bad_signature')
      : e.data?.error === 'update_unsigned' ? t('update_unsigned') : e.message);
  } finally {
    _updateBusy = false;
    id('update-install').disabled = false;
    _updateConfirm = false;
    id('update-install').textContent = t('update_install');
  }
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
    ui_task_order: id('set-task-order').value,
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
  changes.day_start = id('set-day-start').value;

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
    loadDay(selectedDate, { chart: true }); // weekends, sidebar days, day and task order
  } catch (e) {
    showError(e.message);
  }
}
