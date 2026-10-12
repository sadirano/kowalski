'use strict';
// ── Sidebar ───────────────────────────────────────────────────────────────────
function renderSidebar() {
  const nav = id('week-nav');
  const lbl = id('sidebar-head-label');
  if (lbl) lbl.textContent = t(_hideWeekends ? 'last_workdays' : 'last_days', { n: _sidebarDays });
  // The server returns the right set of days (work days when weekends are
  // hidden), oldest-to-newest; reverse a copy for the newest-first setting.
  const newestFirst = pref('ui_day_order', 'oldest') === 'newest';
  const days = newestFirst ? [...weekData].reverse() : weekData;
  if (!days.length) { nav.innerHTML=''; return; }
  const prevScroll = nav.scrollTop;
  const maxMs = Math.max(...days.map(d => d.total_ms), 1);
  nav.innerHTML = days.map(d => {
    const active = d.date === (D?.date || selectedDate) ? 'active' : '';
    const pct = Math.round(d.total_ms / maxMs * 100);
    const label = d.date === todayStr() ? t('today') : dayName(d.date);
    const clockClass = d.status === 'posted' ? 'synced'
      : ['partial', 'changed', 'unknown'].includes(d.status) ? 'partial'
      : d.status === 'unposted' ? 'unsynced' : '';
    const clockTitle = escAttr(t('post_hours') + ' — ' + t('st_' + d.status));
    const warn = d.status === 'unknown' ? '<span class="dclock-warn">!</span>' : '';
    return `<div class="dbtn ${active}" data-date="${d.date}" onclick="selectDate('${d.date}',this)">
      <div class="dclock ${clockClass}" title="${clockTitle}" aria-label="${clockTitle}" role="button" tabindex="0" onclick="event.stopPropagation();showHorasDialog('${d.date}')"><svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"></circle><path d="M12 7.5V12l3 2"></path></svg>${warn}</div>
      <div class="dname">${label}</div>
      <div class="ddate">${shortDate(d.date)}</div>
      <div class="dtotal">${d.total_ms ? fmtMs(d.total_ms) : '—'}</div>
      <div class="dbar"><div class="dbar-fill" style="width:${pct}%"></div></div>
    </div>`;
  }).join('');
  // First paint: scroll the newest day (bottom for oldest-first, top for newest-first)
  // into view. Later re-renders preserve the user's scroll position.
  if (_sidebarFirstRender && !_leftCollapsed) {
    nav.scrollTop = newestFirst ? 0 : nav.scrollHeight;
    _sidebarFirstRender = false;
  } else {
    nav.scrollTop = prevScroll;
  }
}

function selectDate(date) {
  selectedDate = date;
  loadDay(date);
}

// ── Calendar (navigate to older days) ──────────────────────────────────────────
// While a dialog borrows the calendar to pick a date, the day it shows as
// selected and what a click does come from that dialog.
let _calPick = null;
let _calSel = null;

function showCalendar(pick) {
  _calPick = pick?.onPick || null;
  _calSel = pick?.date || selectedDate;
  id('cal-overlay').classList.toggle('picking', !!_calPick);
  id('cal-popup').classList.toggle('picking', !!_calPick);
  const base = (_calSel && _calSel.length === 10) ? _calSel : todayStr();
  const d = new Date(base + 'T12:00:00');
  _calYear  = d.getFullYear();
  _calMonth = d.getMonth();
  _calTotals = {};
  id('cal-overlay').classList.add('show');
  id('cal-popup').classList.add('show');
  renderCalendar();
  fetchCalTotals();
}

function hideCalendar() {
  id('cal-overlay').classList.remove('show');
  id('cal-popup').classList.remove('show');
  _calPick = null;
}

// A click on a day: open it, or hand it to the dialog that asked.
function calChoose(date) {
  const pick = _calPick;
  if (!pick) { goToDate(date); return; }
  hideCalendar();
  pick(date);
}

function calShift(delta) {
  _calMonth += delta;
  if (_calMonth < 0)       { _calMonth = 11; _calYear--; }
  else if (_calMonth > 11) { _calMonth = 0;  _calYear++; }
  _calTotals = {};
  renderCalendar();
  fetchCalTotals();
}

function calGoToday() { calChoose(todayStr()); }

function stepDay(dir) {
  let d = new Date(selectedDate + 'T12:00:00');
  do {
    d.setDate(d.getDate() + dir);
  } while (_hideWeekends && (d.getDay() === 0 || d.getDay() === 6));
  goToDate(d.toLocaleDateString('sv'));
}

// Jump to an arbitrary day (from the calendar). Unlike selectDate it doesn't need
// a sidebar element — loadDay re-renders the sidebar and highlights the active day.
function goToDate(date, options) {
  selectedDate = date;
  hideCalendar();
  loadDay(date, options);
}

async function fetchCalTotals() {
  const mm   = String(_calMonth + 1).padStart(2, '0');
  const last = new Date(_calYear, _calMonth + 1, 0).getDate();
  const from = `${_calYear}-${mm}-01`;
  const to   = `${_calYear}-${mm}-${String(last).padStart(2, '0')}`;
  try {
    _calTotals = (await apiJSON('GET', '/api/daytotals?from=' + from + '&to=' + to)).totals || {};
  } catch { _calTotals = {}; }
  renderCalendar();
}

function renderCalendar() {
  // 2023-01-01 was a Sunday — derive localized weekday initials from it.
  const WD = Array.from({ length: 7 }, (_, i) =>
    new Date(2023, 0, 1 + i).toLocaleDateString(locale(), { weekday: 'short' }).slice(0, 2));
  id('cal-weekdays').innerHTML = WD.map(w => `<div class="cal-wd">${w}</div>`).join('');
  id('cal-title').textContent = new Date(_calYear, _calMonth, 1)
    .toLocaleDateString(locale(), { month: 'long', year: 'numeric' });

  const firstDow     = new Date(_calYear, _calMonth, 1).getDay(); // 0=Sun
  const daysInMonth  = new Date(_calYear, _calMonth + 1, 0).getDate();
  const today        = todayStr();
  const mm           = String(_calMonth + 1).padStart(2, '0');

  let cells = '';
  for (let i = 0; i < firstDow; i++) cells += `<div class="cal-cell blank"></div>`;
  for (let day = 1; day <= daysInMonth; day++) {
    const ds  = `${_calYear}-${mm}-${String(day).padStart(2, '0')}`;
    const dow = new Date(_calYear, _calMonth, day).getDay();
    const cls = ['cal-cell'];
    if (dow === 0 || dow === 6) cls.push('weekend');
    if (ds === today)        cls.push('today');
    if (ds === _calSel) cls.push('selected');
    const has = _calTotals[ds] > 0;
    if (has) cls.push('has-data');
    let attrs = '';
    if (ds > today) {                       // future days can't have data
      cls.push('future');
    } else {
      attrs = ` onclick="calChoose('${ds}')"`;
      if (has) attrs += ` title="${t('tracked', { t: fmtMs(_calTotals[ds]) })}"`;
    }
    cells += `<div class="${cls.join(' ')}"${attrs}>${day}</div>`;
  }
  id('cal-grid').innerHTML = cells;
}

