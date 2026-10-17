'use strict';
// ── Loaders ──────────────────────────────────────────────────────────────────
async function loadWeek() {
  weekData = await fetchWeek();
}

async function fetchWeek() {
  try { return (await apiJSON('GET', '/api/days?count=' + _sidebarDays + '&weekends=' + (_hideWeekends ? 0 : 1))).days; }
  catch { return []; }
}

let _trackerActive = false;
let _skew = 0;

async function loadCurrent() {
  try {
    S = await apiJSON('GET', '/api/state');
    _skew = S.now_ms - Date.now();
    const refEl  = id('hdr-ref');
    const detEl  = id('hdr-detail');
    const btn    = id('tracker-btn');
    const working = S.focus || S.parallel.length;
    if (working) {
      _trackerActive = true;
      if (S.focus) {
        const task = S.focus.task;
        _currentTaskId = task.id;
        refEl.innerHTML = `${task.ref ? refLink(task.ref) : esc('#' + task.id)}  ${esc(task.title)}`;
        refEl.title = task.title;
        detEl.textContent = [fmtMs(Date.now() + _skew - S.focus.start_ms), ...S.focus_fields.map(field => field.value)].join('  ·  ');
      } else {
        _currentTaskId = null;
        refEl.innerHTML = esc(t('parallel'));
        detEl.textContent = S.parallel.map(interval => interval.task.title).join(', ');
      }
      refEl.classList.remove('idle');
      btn.classList.add('active');
    } else {
      _trackerActive = false;
      _currentTaskId = null;
      refEl.textContent = t('no_session');
      refEl.title = '';
      refEl.classList.add('idle');
      detEl.textContent = t(S.saved.length ? 'idle_resume' : 'idle_start');
      btn.classList.remove('active');
    }
    btn.innerHTML = icon(working ? 'pause' : 'play');
    const runs = S.capture?.runs || [];
    const chip = id('hdr-session');
    chip.classList.toggle('working', !!working);
    chip.classList.toggle('capture-quiet', runs.some(run => run.state === 'quiet'));
    const pop = id('capture-popover');
    pop.hidden = true;
    if (runs.length) {
      const count = document.createElement('button');
      count.type = 'button';
      count.className = 'capture-count';
      count.textContent = t(runs.length === 1 ? 'capture_one_session' : 'capture_many_sessions', { n: runs.length });
      count.onclick = e => { e.stopPropagation(); pop.hidden = !pop.hidden; };
      detEl.append(document.createTextNode('  ·  '), count);
      pop.innerHTML = runs.map(run => `<div class="capture-run"><strong>${esc(run.task?.title || t('no_session'))}</strong><span>${esc(run.source)} · ${esc(t('capture_' + run.state))} · ${esc(t('capture_last_activity'))} ${esc(hhmm24(run.last_ms))}</span></div>`).join('');
    }
    btn.title = t(working ? 'btn_pause' : S.saved.length ? 'btn_resume' : 'btn_start');
    btn.setAttribute('aria-label', btn.title);
  } catch { id('hdr-session').classList.remove('working'); }
}

document.addEventListener('click', e => {
  const pop = id('capture-popover');
  if (pop && !e.target.closest('#hdr-session')) pop.hidden = true;
});

async function toggleTracker() {
  if (!S) return; // state not loaded yet
  let endpoint;
  if (S.focus || S.parallel.length) endpoint = '/api/pause';
  else if (S.saved.length) endpoint = '/api/resume';
  else { showNewTask(); return; }
  try {
    // The reply is the new state: keep it even if the refresh below fails.
    S = await apiJSON('POST', endpoint);
    _skew = S.now_ms - Date.now();
    await loadCurrent();
    loadSchedule();
    loadDay(selectedDate, { chart: true });
  } catch (e) { showError(e.message); }
}



// ── The header's "more" menu ──────────────────────────────────────────────────
function toggleMoreMenu(open) {
  const menu = id('more-menu');
  const show = open ?? !menu.classList.contains('show');
  menu.classList.toggle('show', show);
  id('more-btn').setAttribute('aria-expanded', String(show));
  if (show) id('lang-item').querySelector('span').textContent = t('menu_lang', { lang: LANG_NAMES[_lang] });
}
function moreDo(action) { toggleMoreMenu(false); action(); }
document.addEventListener('click', e => {
  if (id('more-menu').classList.contains('show') && !e.target.closest('.hdr-menu-wrap')) toggleMoreMenu(false);
});
document.addEventListener('keydown', e => {
  if (e.key === 'Escape' && id('more-menu').classList.contains('show')) { toggleMoreMenu(false); id('more-btn').focus(); }
});
