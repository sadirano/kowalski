'use strict';
// ── Schedule (return / clock-out projection) ───────────────────────────────────
async function loadSchedule() {
  renderSchedule();
}

// renderSchedule paints the strip from the cached payload + the live clock.
// The clock-out time itself is fixed while you work; only the "left" countdown
// and progress bar advance, so a 1 s re-render keeps it lively without refetching.
function scheduleShown() { return (D?.date || selectedDate) === todayStr() && !!S; }

function renderSchedule() {
  const box = id('sched-box');
  if (!box) return;
  // The projection is inherently about *today* — hide it on past days.
  if (!scheduleShown()) { box.style.display = 'none'; return; }

  const n = S.numbers;
  const target = S.daily_work_minutes * 60000;
  const lunch  = fmtMins(Number(pref('lunch_minutes', '60')));

  // Live values while working: derive remaining/worked from the clock so the
  // numbers tick down even though `_schedData` is only a 30 s snapshot.
  const now = Date.now() + _skew;
  let workedNow = n.total_ms + n.paid_break_ms + (n.working ? now - S.now_ms : 0);
  const pct = target > 0 ? Math.max(0, Math.min(100, Math.round(workedNow / target * 100))) : 0;

  // When the day's hours are done on a Friday, cheer the weekend (idea.md).
  const weekend = new Date(todayStr() + 'T12:00:00').getDay() === 5 ? ` ${t('weekend_friday')}` : '';

  let primary, secondary, accent;
  if (n.first_start_ms == null) {
    accent = 'var(--muted)';
    primary = t('sched_not_started');
    secondary = t('sched_target', { t: fmtMs(target), l: lunch });
  } else if (!n.working && n.remaining_ms <= 0) {
    accent = 'var(--grn)';
    primary = t('sched_done');
    secondary = t('sched_done_sub', { w: fmtMs(workedNow), t: fmtMs(target) }) + weekend;
  } else if (n.working) {
    accent = 'var(--grn)';
    const clockOutT = n.clock_out_ms || 0;
    const remAtCompany = Math.max(0, clockOutT - now);
    if (workedNow >= target && remAtCompany <= 0) {
      primary = t('sched_can_clock_out');
      secondary = t('sched_worked_complete', { w: fmtMs(workedNow) }) + weekend;
    } else {
      primary = t('sched_clock_out_at', { t: padHHMM(new Date(clockOutT)) });
      secondary = t('sched_left', { r: fmtMs(remAtCompany), w: fmtMs(workedNow), t: fmtMs(target) });
    }
  } else {
    // On a break: no open session. ExpectedReturn = last end + minimum break.
    accent = 'var(--warn)';
    const retT  = n.expected_return_ms;
    // If you can't return before retT you finish at retT+remaining; if the break
    // is already long enough, resuming now finishes at now+remaining.
    const finT  = Math.max(retT, now) + n.remaining_ms;
    const remAtCompany = Math.max(0, finT - now);
    if (retT <= now) {
      primary = t('sched_can_return');
      secondary = t('sched_return_full', { l: lunch, c: padHHMM(new Date(finT)), r: fmtMs(n.remaining_ms) });
    } else {
      primary = t('sched_return_at', { t: padHHMM(new Date(retT)) });
      secondary = t('sched_return_hint', { l: lunch, c: padHHMM(new Date(finT)), r: fmtMs(n.remaining_ms) });
    }
  }

  box.style.display = '';
  let pEl = box.querySelector('.sched-primary');
  let sEl = box.querySelector('.sched-secondary');
  let fEl = box.querySelector('.sched-bar-fill');
  if (!pEl || !sEl || !fEl) {
    box.innerHTML = `
      <div class="sched-main">
        <div class="sched-primary" style="color:${accent}">${primary}</div>
        <div class="sched-secondary">${secondary}</div>
        <div class="sched-bar"><div class="sched-bar-fill" style="width:${pct}%;background:${accent}"></div></div>
      </div>`;
  } else {
    if (pEl.textContent !== primary) pEl.textContent = primary;
    if (pEl.style.color !== accent) pEl.style.color = accent;
    if (sEl.textContent !== secondary) sEl.textContent = secondary;
    const widthStyle = pct + '%';
    if (fEl.style.width !== widthStyle) fEl.style.width = widthStyle;
    if (fEl.style.background !== accent) fEl.style.background = accent;
  }
}

// ── Stat cards ────────────────────────────────────────────────────────────────
// The work-periods card takes the rest of the row and shows the day's clock
// on one line: start - lunch out / lunch back - end (just start - end without
// a lunch break). Today's schedule box takes its place.
function renderCards(rep) {
  const el = id('cards');
  if (!rep) { el.innerHTML=''; return; }
  const n = rep.numbers;
  const end = fmtTime(rep.last_end_ms);
  // The day API gives the lunch: a recorded one, else the longest pause in
  // the lunch window.
  const lunch = rep.lunch_out_ms != null && rep.lunch_back_ms != null
    ? { out: rep.lunch_out_ms, back: rep.lunch_back_ms } : null;
  const periods = n.first_start_ms == null ? '—'
    : lunch
      ? `${fmtTime(n.first_start_ms)} – ${fmtTime(lunch.out)} / ${fmtTime(lunch.back)} – ${end}`
      : `${fmtTime(n.first_start_ms)} – ${end}`;
  const lunchSub = lunch ? t('lbl_lunch') + ' ' + fmtMs(lunch.back - lunch.out) : t('no_lunch');
  patchHTML(el, `
    <div class="card"><div class="lbl">${t('card_total')}</div>
      <div class="val">${fmtMs(n.total_ms)}</div><div class="sub">${esc(rep.date)}</div></div>
    <div class="card"><div class="lbl">${t('card_tasks')}</div>
      <div class="val">${rep.tasks.filter(task => task.focus_ms > 0).length}</div><div class="sub">${t('card_tasks_sub')}</div></div>
    <div class="card"><div class="lbl">${t('card_hops')}</div>
      <div class="val" style="color:${n.hops>0?'var(--warn)':'var(--grn)'}">${n.hops}</div>
      <div class="sub">${t('card_hops_sub')}</div></div>
    ${scheduleShown() ? '' : `<div class="card card-wide"><div class="lbl">${t('card_periods')}</div>
      <div class="val">${periods}</div><div class="sub">${lunchSub}</div></div>`}`);
}
