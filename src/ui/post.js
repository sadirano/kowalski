'use strict';
// ── Post tracked hours ────────────────────────────────────────────────────────
let _horasDate = null;
let _horasEntries = [];
let _obsEntryIdx = null;
let _obsEntry = null; // the entry the observation popup edits
let _obsTok = 0;      // drops an autofill answer meant for an older popup
let _horasGen = 0;    // a new dialog drops answers meant for the old one
let _horasSessionsMode = false;

async function showHorasDialog(date) {
  _horasDate = date;
  const gen = ++_horasGen;
  id('horas-overlay').classList.add('show');
  id('horas-popup').classList.add('show');
  id('horas-title').textContent = `${t('horas_title')} — ${fmtDate(date)}`;
  id('horas-body').innerHTML = `<div class="horas-empty">${t('checking')}</div>`;
  setHorasActions(false);
  if (!provider) {
    id('horas-body').innerHTML = `<div class="horas-empty">${t('no_provider')}</div>`;
    return;
  }
  try {
    const data = await apiJSON('GET', '/api/postings?date=' + encodeURIComponent(date));
    _horasSessionsMode = !!data.sessions_mode;
    if (gen !== _horasGen) return;
    // A posting still sending or unknown stays listed, whatever the tracked time.
    const pending = o => (o.postings || []).some(p => p.state === 'unknown' || p.state === 'sending');
    _horasEntries = (data.offers || []).filter(o => o.total_focus_ms > 0 || pending(o))
      .map(offer => ({ offer, quote: null, refused: null, observation: '', options: {} }));
    renderHorasRows();
    await quoteHoras(gen);
  } catch (err) {
    if (gen !== _horasGen) return;
    id('horas-body').innerHTML = `<div class="horas-empty hr-err">${t('load_failed')} ${esc(err.message)}</div>`;
  }
}

function hideHoras() {
  id('horas-overlay').classList.remove('show');
  id('horas-popup').classList.remove('show');
}

function setHorasActions(on) {
  id('horas-submit-btn').style.display = on ? '' : 'none';
}

function horasResolveButtons(postingId) {
  return `<button class="hr-resolve" onclick="resolveHoras(${postingId}, true)">${t('resolve_posted')}</button>
    <button class="hr-resolve" onclick="resolveHoras(${postingId}, false)">${t('resolve_not_posted')}</button>`;
}

function horasStatus(e) {
  const offer = e.offer;
  const unknown = (offer.postings || []).find(p => p.state === 'unknown');
  if (unknown) return `<span class="hr-err">${t('st_unknown')}</span> ${horasResolveButtons(unknown.id)}`;
  if ((offer.postings || []).some(p => p.state === 'sending')) return `<span class="hr-muted">${t('st_sending')}</span>`;
  if (!offer.ref) return `<span class="hr-muted">${t('not_bound')}</span>`;
  if (e.refused) return `<span class="hr-muted">${esc(e.refused)}</span>`;
  if (!e.quote && offer.postable) return '<span class="hr-muted">…</span>';
  return `<span class="hr-muted">${t('tracked', { t: fmtMs(offer.total_focus_ms) })}</span>`;
}

function horasPostedLine(e) {
  const posted = (e.offer.postings || []).filter(p => p.state === 'confirmed');
  return posted.length
    ? `<div class="hr-ok">${t('posted_amt', { a: esc(posted.map(p => p.amount_text).join(' + ')) })}</div>` : '';
}

// The provider's post options (Internal hours, say) as toggles on a row.
function horasOptions(e, i) {
  return (provider?.post_options || []).map(o => {
    const hint = providerHint(o);
    return `<label class="hr-int"${hint ? ` title="${escAttr(hint)}"` : ''}><input type="checkbox" id="hr-opt-${i}-${o.name}"
      ${e.options[o.name] ? 'checked' : ''} ${e.quote ? '' : 'disabled'}
      onchange="_horasEntries[${i}].options['${o.name}'] = this.checked">${esc(providerLabel(o))}</label>`;
  }).join('');
}

function renderHorasRows() {
  if (!_horasEntries.length) {
    id('horas-body').innerHTML = `<div class="horas-empty">${t('no_ref_day')}</div>`;
    return;
  }
  setHorasActions(_horasEntries.some(e => e.offer.postable)); // nothing to post: no Submit
  const rows = _horasEntries.map((e, i) => {
    const offer = e.offer;
    const obsCls = e.observation ? 'has-val' : '';
    const obsTit = e.observation ? t('obs_prefix') + e.observation : t('obs_add');
    return `<div class="horas-row" id="hr-${i}">
      <input type="checkbox" id="hr-chk-${i}" disabled>
      <span class="hr-ref">${offer.ref ? refLink(offer.ref) : '—'}</span>
      <span class="hr-desc" title="${escAttr(offer.task.title)}">${esc(offer.task.title)}${_horasSessionsMode ? `<small class="hr-muted">${(offer.sessions || []).map(s => `${esc(s.start)}-${esc(s.end)}`).join(' · ')}</small>${offer.open_session ? `<small class="hr-muted">${t('running_session_excluded')}</small>` : ''}` : ''}</span>
      ${horasOptions(e, i)}
      <button class="hr-obs-btn ${obsCls}" id="hr-obs-btn-${i}" onclick="openObsPopup(${i})"
        title="${escAttr(obsTit)}" ${offer.postable ? '' : 'disabled'}>${icon('note')}</button>
      <span class="hr-amt" id="hr-amt-${i}">${e.quote ? esc(e.quote.amount_text) : ''}</span>
      <span class="hr-status" id="hr-st-${i}">${horasStatus(e)}${horasPostedLine(e)}</span>
    </div>`;
  }).join('');
  id('horas-body').innerHTML = `<div class="horas-table">${rows}</div>`;
}

// The provider takes one call at a time, so Submit waits for every quote.
async function quoteHoras(gen = _horasGen) {
  id('horas-submit-btn').disabled = true;
  for (let i = 0; i < _horasEntries.length; i++) {
    if (!_horasEntries[i].offer.postable) continue;
    if (!await quoteRow(i, gen)) return;
  }
  if (gen === _horasGen) id('horas-submit-btn').disabled = false;
}

// Quotes one row; false once the dialog moved on.
async function quoteRow(i, gen) {
  if (gen !== _horasGen) return false;
  const e = _horasEntries[i];
  const chk = id(`hr-chk-${i}`);
  try {
    const quote = await apiJSON('POST', '/api/postings', {
      date: _horasDate, task: '#' + e.offer.task.id, dry_run: true,
    });
    if (gen !== _horasGen) return false;
    e.quote = quote;
    e.refused = null;
    if (chk) { chk.disabled = false; chk.checked = true; }
    id(`hr-${i}`)?.querySelectorAll('.hr-int input').forEach(x => { x.disabled = false; });
  } catch (err) {
    if (gen !== _horasGen) return false;
    e.quote = null;
    e.refused = err.message;
    if (chk) { chk.checked = false; chk.disabled = true; }
    id(`hr-${i}`)?.querySelectorAll('.hr-int input').forEach(x => { x.disabled = true; });
  }
  const amt = id(`hr-amt-${i}`);
  const st = id(`hr-st-${i}`);
  if (amt) amt.textContent = e.quote ? e.quote.amount_text : '';
  if (st) st.innerHTML = horasStatus(e) + horasPostedLine(e);
  return true;
}

function selectedHoras() {
  const out = [];
  _horasEntries.forEach((e, i) => {
    const chk = id(`hr-chk-${i}`);
    if (e.quote && chk && chk.checked) out.push({ i, task: e.offer.task.id, observation: e.observation, options: { ...e.options } });
  });
  return out;
}

async function openObsPopup(idx) {
  const e = _horasEntries[idx];
  if (!e) return;
  _obsEntryIdx = idx;
  _obsEntry = e;
  const tok = ++_obsTok;
  let val = e.observation || '';
  if (!val && pref('ui_autofill_obs', '0') === '1') {
    try {
      const day = D && D.date === _horasDate ? D : await apiJSON('GET', '/api/day?date=' + encodeURIComponent(_horasDate));
      const lines = [];
      for (const interval of day.intervals || []) {
        if (interval.role !== 'focus' || interval.task.id !== e.offer.task.id) continue;
        if (interval.text) lines.push({ at: interval.start_ms, text: interval.text });
        for (const note of interval.notes || []) lines.push({ at: note.at_ms, text: note.text });
      }
      val = lines.sort((a, b) => a.at - b.at).map(line => `[${fmtTime(line.at)}] ${line.text}`).join('\n');
    } catch (err) {
      showError(err.message); // the popup still opens, empty
    }
    if (tok !== _obsTok) return; // another popup opened meanwhile
  }
  id('obs-text').value = val;
  id('obs-overlay').classList.add('show');
  id('obs-popup').classList.add('show');
  setTimeout(() => id('obs-text').focus(), 50);
}

function closeObsPopup() {
  id('obs-overlay').classList.remove('show');
  id('obs-popup').classList.remove('show');
  _obsEntryIdx = null;
  _obsEntry = null;
}

function applyObsPopup() {
  if (_obsEntryIdx === null) return;
  // The dialog was reloaded under the popup: the entry is gone.
  if (_horasEntries[_obsEntryIdx] !== _obsEntry) { closeObsPopup(); return; }
  const val = id('obs-text').value.trim();
  _obsEntry.observation = val;
  // Update button visual state
  const btn = id(`hr-obs-btn-${_obsEntryIdx}`);
  if (btn) {
    if (val) {
      btn.classList.add('has-val');
      btn.title = t('obs_prefix') + val;
    } else {
      btn.classList.remove('has-val');
      btn.title = t('obs_add');
    }
  }
  closeObsPopup();
}

async function submitHoras() { await runHoras(); }

// Post one entry at a time so each row receives its own result.
// The date and rows are the ones submitted: opening another day meanwhile
// only stops the screen updates.
async function runHoras() {
  const sel = selectedHoras();
  if (!sel.length) return;
  const gen = _horasGen;
  const date = _horasDate;
  const entries = _horasEntries;
  const live = () => gen === _horasGen;
  id('horas-submit-btn').disabled = true;
  let posted = false;
  let failure = null;
  const requote = [];
  for (const s of sel) {
    const st = live() ? id(`hr-st-${s.i}`) : null;
    if (st) st.innerHTML = '<span class="hr-muted">…</span>';
    try {
      const data = await apiJSON('POST', '/api/postings', {
        date, task: '#' + s.task, text: s.observation || null, options: s.options,
      });
      entries[s.i].offer.postings.push(...(data.postings || [data.posting]));
      posted = true;
      if (!live()) continue;
      if (st) st.innerHTML = `<span class="hr-ok">${t('posted_amt', { a: esc((data.postings || [data.posting]).map(p => p.amount_text).join(' + ')) })}</span>`;
      id(`hr-${s.i}`)?.classList.add('posted');
      const chk = id(`hr-chk-${s.i}`); if (chk) { chk.checked = false; chk.disabled = true; }
      const obs = id(`hr-obs-btn-${s.i}`); if (obs) obs.disabled = true;
      id(`hr-${s.i}`)?.querySelectorAll('.hr-int input').forEach(x => { x.disabled = true; });
    } catch (err) {
      const unknown = err.data && err.data.posting && err.data.posting.state === 'unknown' ? err.data.posting : null;
      if (unknown) entries[s.i].offer.postings.push(unknown);
      else {
        // The quote shown may be stale: it is fetched again before another try.
        entries[s.i].quote = null;
        failure = err.message;
        requote.push(s.i);
      }
      if (!live()) continue;
      if (st) st.innerHTML = unknown
        ? `<span class="hr-err">${t('st_unknown')}</span> ${horasResolveButtons(unknown.id)}`
        : `<span class="hr-err">${esc(err.message)}</span>`;
      const chk = id(`hr-chk-${s.i}`); if (chk) { chk.checked = false; chk.disabled = true; }
    }
  }
  if (live()) {
    for (const i of requote) await quoteRow(i, gen);
    if (live()) id('horas-submit-btn').disabled = false;
  }
  showToast(failure || t('post_done'));
  if (posted) loadDay(selectedDate);
}

async function resolveHoras(postingId, posted) {
  try {
    await apiJSON('POST', `/api/postings/${postingId}/resolve`, { posted });
    await showHorasDialog(_horasDate);
  } catch (err) { showError(err.message); }
}
