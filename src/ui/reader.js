'use strict';
// ── Reader layout ─────────────────────────────────────────────────────────────
// One task's day read top to bottom: a day ribbon to click a moment on, then
// the task's sittings (its intervals joined while the gaps stay under
// SITTING_GAP), each with its exchanges: a prompt and what came of it. The
// ribbon's "At" panel lists what else ran at the pinned minute. Read-only:
// editing stays in the other layouts.
const SITTING_GAP = 10 * 60000;
const READER_FOLD = 3;   // updates under a prompt shown before folding
let _readerTask = null;  // the task being read; kept across reloads
let _readerPin = null;   // the minute clicked on the ribbon, or null
let _readerSitting = 0;  // the sitting J/K move from
let _ribbonA = 0, _ribbonB = 1;

function readerEnd(s) { return s.end_ms ?? Date.now() + _skew; }

// A gap or a wait reads as minutes; totals keep fmtMs.
function rdDur(ms) {
  const m = Math.round(ms / 60000);
  return m < 1 ? t('rd_lt_min') : m < 60 ? t('rd_min', { n: m }) : fmtMs(ms);
}

function unionMs(spans) {
  let total = 0, cs = null, ce = null;
  for (const [s, e] of spans.slice().sort((a, b) => a[0] - b[0])) {
    if (cs === null || s > ce) { if (cs !== null) total += ce - cs; cs = s; ce = e; }
    else ce = Math.max(ce, e);
  }
  return cs === null ? 0 : total + ce - cs;
}

function readerNotes(list) {
  const notes = [];
  for (const s of list) {
    if (s.text) notes.push({ at_ms: s.start_ms, text: s.text, source: null });
    for (const n of s.notes) notes.push(n);
  }
  return notes.sort((a, b) => a.at_ms - b.at_ms);
}

function sittingsOf(rep, taskId) {
  const out = [];
  const list = rep.intervals.filter(s => s.task.id === taskId).sort((a, b) => a.start_ms - b.start_ms);
  for (const s of list) {
    const last = out[out.length - 1];
    if (last && s.start_ms <= last.end + SITTING_GAP) { last.items.push(s); last.end = Math.max(last.end, readerEnd(s)); }
    else out.push({ start: s.start_ms, end: readerEnd(s), items: [s] });
  }
  for (const st of out) {
    st.focus = unionMs(st.items.filter(s => s.role === 'focus').map(s => [s.start_ms, readerEnd(s)]));
    st.parallel = unionMs(st.items.map(s => [s.start_ms, readerEnd(s)])) - st.focus;
    st.notes = readerNotes(st.items);
  }
  return out;
}

// The focus other tasks had between two sittings, longest first.
function meanwhileOf(rep, taskId, a, b) {
  const m = new Map();
  for (const s of rep.intervals) {
    if (s.task.id === taskId || s.role !== 'focus') continue;
    const x = Math.max(a, s.start_ms), y = Math.min(b, readerEnd(s));
    if (y > x) m.set(s.task.id, (m.get(s.task.id) || 0) + y - x);
  }
  return [...m.entries()].filter(([, ms]) => ms >= 60000).sort((p, q) => q[1] - p[1]);
}

// A prompt opens an exchange and outcomes hang under it; other notes stand alone.
function exchangesOf(notes) {
  const out = [];
  let cur = null;
  for (const n of notes) {
    if (n.source === 'prompt') { cur = { prompt: n, out: [] }; out.push(cur); }
    else if (n.source === 'outcome') { if (!cur) { cur = { prompt: null, out: [] }; out.push(cur); } cur.out.push(n); }
    else { out.push({ note: n }); cur = null; }
  }
  return out;
}

function lastNoteBefore(rep, taskId, t) {
  let best = null;
  for (const s of rep.intervals) if (s.task.id === taskId)
    for (const n of s.notes) if (n.at_ms <= t && (!best || n.at_ms > best.at_ms)) best = n;
  return best;
}

function whatAt(rep, t) {
  const on = rep.intervals.filter(s => s.start_ms <= t && t < readerEnd(s));
  const focus = on.find(s => s.role === 'focus') || null;
  const seen = new Set(focus ? [focus.task.id] : []);
  const others = on.filter(s => s !== focus && !seen.has(s.task.id) && seen.add(s.task.id));
  return { focus, others };
}

function noteBody(n) { return esc(n.source === 'outcome' ? n.text.replace(/^->\s*/, '') : n.text); }
function taskLabel(task) { return task.ref ? task.ref : '#' + task.id; }
function titleOf(rep, taskId) {
  const e = rep.tasks.find(x => x.task.id === taskId);
  return e ? e.task.title : '#' + taskId;
}

function renderReader(rep, area) {
  const tasks = orderTasks(rep);
  if (!tasks.some(e => e.task.id === _readerTask))
    _readerTask = tasks.some(e => e.task.id === _currentTaskId) ? _currentTaskId : tasks[0].task.id;
  const pinned = _readerPin;
  area.innerHTML = `<div class="rd">
    <div class="rd-top">
      <div class="rd-ribbon" id="rd-ribbon" onclick="readerRibbonClick(event)" onmousemove="readerHover(event)" onmouseleave="readerHoverOut()">${ribbonHtml(rep)}</div>
      <div class="rd-ticks">${ticksHtml(rep)}</div>
      <div class="rd-legend"><span><i class="rd-sw f"></i>${esc(t('rd_legend_you'))}</span><span><i class="rd-sw p"></i>${esc(t('rd_legend_par'))}</span><span><i class="rd-sw o"></i>${esc(t('rd_legend_other'))}</span><span class="rd-hint">${esc(t('rd_hint'))}</span></div>
    </div>
    <div class="rd-body"><nav class="rd-tabs" role="tablist">${tasks.map(e => `<button class="rd-tab" role="tab" aria-selected="${e.task.id === _readerTask}" onclick="readerPick(${e.task.id})">
        <span class="rd-id">${esc(taskLabel(e.task))}</span><span class="rd-tt">${esc(e.task.title)}</span><span class="rd-t">${fmtMs(e.focus_ms)}</span></button>`).join('')}</nav><div class="rd-main" id="rd-main">${readerMainHtml(rep)}</div><aside class="rd-at" id="rd-at"${pinned == null ? ' hidden' : ''}>${pinned == null ? '' : atHtml(rep, pinned)}</aside></div>
  </div>`;
  if (pinned != null) markMoment(rep, pinned, false);
}

function ribbonPos(ms) { return ((ms - _ribbonA) / (_ribbonB - _ribbonA) * 100).toFixed(3) + '%'; }
function ribbonWidth(a, b) { return Math.max((b - a) / (_ribbonB - _ribbonA) * 100, 0.25).toFixed(3) + '%'; }

function ribbonHtml(rep) {
  const H = 3600000;
  const s0 = Math.min(...rep.intervals.map(s => s.start_ms)), e0 = Math.max(...rep.intervals.map(readerEnd));
  _ribbonA = rep.start_ms + Math.floor((s0 - rep.start_ms) / H) * H;
  _ribbonB = Math.max(_ribbonA + H, rep.start_ms + Math.ceil((e0 - rep.start_ms) / H) * H);
  const mine = rep.intervals.filter(s => s.task.id === _readerTask).sort((a, b) => (a.role === 'focus') - (b.role === 'focus'));
  const seg = (s, cls, title) => `<div class="rd-seg ${cls}" style="left:${ribbonPos(s.start_ms)};width:${ribbonWidth(s.start_ms, readerEnd(s))}" title="${escAttr(title)}"></div>`;
  return '<div class="rd-track"></div>'
    + rep.intervals.filter(s => s.task.id !== _readerTask && s.role === 'focus')
      .map(s => seg(s, 'o', `${taskLabel(s.task)} ${s.task.title}`)).join('')
    + mine.map(s => seg(s, s.role === 'focus' ? 'f' : 'p', `${fmtTime(s.start_ms)} - ${fmtTime(readerEnd(s))} ${t(s.role === 'focus' ? 'rd_legend_you' : 'rd_legend_par')}`)).join('')
    + (_readerPin != null ? `<div class="rd-pin" style="left:${ribbonPos(_readerPin)}"></div>` : '');
}

function ticksHtml(rep) {
  const H = 3600000, hours = (_ribbonB - _ribbonA) / H;
  let html = '';
  for (let h = _ribbonA; h <= _ribbonB; h += H) {
    if (hours > 12 && Math.round((h - rep.start_ms) / H) % 2) continue;
    html += `<span style="left:${ribbonPos(h)}">${esc(fmtTime(h))}</span>`;
  }
  return html;
}

function readerMainHtml(rep) {
  const entry = rep.tasks.find(e => e.task.id === _readerTask);
  const list = sittingsOf(rep, _readerTask);
  if (!list.length) return '';
  const first = list[0].start, last = list[list.length - 1].end;
  const parallel = list.reduce((n, st) => n + st.parallel, 0);
  const vars = { focus: fmtMs(entry.focus_ms), par: fmtMs(parallel), span: fmtMs(last - first), from: fmtTime(first), to: fmtTime(last) };
  let h = `<h1 class="rd-h1"><span class="rd-ref">${entry.task.ref ? refLink(entry.task.ref) : esc('#' + entry.task.id)}</span>${esc(entry.task.title)}</h1>
    <p class="rd-headline">${esc(t(parallel >= 60000 ? 'rd_head_par' : 'rd_head', vars))} ${esc(list.length > 1 ? t('rd_back', { n: list.length - 1 }) : t('rd_one'))}</p>`;
  list.forEach((st, k) => {
    if (k > 0) {
      const prev = list[k - 1];
      const mw = meanwhileOf(rep, _readerTask, prev.end, st.start).slice(0, 3)
        .map(([tid, ms]) => `${esc(trunc(titleOf(rep, tid), 40))} (${esc(rdDur(ms))})`).join(', ');
      h += `<div class="rd-gap"><span><b>${esc(t('rd_later', { d: rdDur(st.start - prev.end) }))}</b>${mw ? ' · ' + esc(t('rd_meanwhile')) + ' ' + mw : ''}</span></div>`;
    }
    const L = (st.end - st.start) || 1;
    const bar = (s, cls) => `<i class="${cls}" style="left:${((s.start_ms - st.start) / L * 100).toFixed(2)}%;width:${((readerEnd(s) - s.start_ms) / L * 100).toFixed(2)}%"></i>`;
    const live = st.items.some(s => s.end_ms == null);
    h += `<section class="rd-sitting" id="rd-s${k}">
      <div class="rd-shead"><span class="rd-span">${fmtTime(st.start)} → ${live ? `<span style="color:var(--grn)">${t('now')}</span>` : fmtTime(st.end)}</span>
        <span class="rd-who"><span class="f">${esc(t('rd_you_n', { d: fmtMs(st.focus) }))}</span>${st.parallel >= 60000 ? ` · <span class="p">${esc(t('rd_par_n', { d: fmtMs(st.parallel) }))}</span>` : ''}</span></div>
      <div class="rd-bar" aria-hidden="true">${st.items.filter(s => s.role === 'parallel').map(s => bar(s, 'p')).join('')}${st.items.filter(s => s.role === 'focus').map(s => bar(s, 'f')).join('')}</div>`;
    const ex = exchangesOf(st.notes);
    if (!ex.length) h += `<p class="rd-empty">${esc(t('rd_no_notes'))}</p>`;
    ex.forEach((e, j) => {
      if (e.note) { h += `<div class="rd-ex" data-at="${e.note.at_ms}"><div class="rd-at-time">${fmtTime(e.note.at_ms)}</div><p class="rd-note">${noteBody(e.note)}</p></div>`; return; }
      const base = e.prompt ? e.prompt.at_ms : e.out[0].at_ms;
      // A prompt that opens a sitting answers what the agent said before the break.
      let ctx = '';
      if (e.prompt && j === 0) {
        const prev = lastNoteBefore(rep, _readerTask, e.prompt.at_ms - 1);
        if (prev && prev.source === 'outcome') ctx = `<p class="rd-ctx"><b>${esc(t('rd_replying', { d: rdDur(e.prompt.at_ms - prev.at_ms) }))}</b>${noteBody(prev)}</p>`;
      }
      h += `<div class="rd-ex" data-at="${base}"><div class="rd-at-time">${fmtTime(base)}</div>${ctx}${e.prompt ? `<p class="rd-prompt">${noteBody(e.prompt)}</p>` : ''}`;
      if (e.out.length) {
        const rows = e.out.map(n => `<span class="rd-rel" title="${escAttr(fmtTime(n.at_ms))}">+${Math.max(0, Math.round((n.at_ms - base) / 60000))}m</span><p>${noteBody(n)}</p>`);
        h += '<div class="rd-out">' + (rows.length > READER_FOLD
          ? rows[0] + `<button class="rd-fold" onclick="readerUnfold(this)" data-more="${escAttr(encodeURIComponent(rows.slice(1, -1).join('')))}">${esc(t('rd_more', { n: rows.length - 2, from: fmtTime(e.out[1].at_ms), to: fmtTime(e.out[e.out.length - 2].at_ms) }))}</button>` + rows[rows.length - 1]
          : rows.join('')) + '</div>';
      }
      h += '</div>';
    });
    h += '</section>';
  });
  return h;
}

function atHtml(rep, t0) {
  const { focus, others } = whatAt(rep, t0);
  const row = (s, kind) => {
    const n = lastNoteBefore(rep, s.task.id, t0);
    return `<button class="rd-run ${kind}" onclick="readerPick(${s.task.id},${t0})"><span class="rd-id">${esc(taskLabel(s.task))}</span> ${esc(s.task.title)}
      <span class="rd-last">${esc(t(kind === 'f' ? 'rd_legend_you' : 'rd_legend_par'))} · ${fmtTime(s.start_ms)} - ${s.end_ms == null ? t('now') : fmtTime(s.end_ms)}${n ? ' · ' + esc(trunc(n.text.replace(/^->\s*/, ''), 90)) : ''}</span></button>`;
  };
  return `<h2>${esc(t('rd_at', { t: fmtTime(t0) }))}</h2>
    <div class="rd-grp">${esc(t('rd_your_focus'))}</div>${focus ? row(focus, 'f') : `<p class="rd-nil">${esc(t('rd_nothing_focused'))}</p>`}
    <div class="rd-grp">${esc(t('rd_also'))}</div>${others.length ? others.map(s => row(s, 'p')).join('') : `<p class="rd-nil">${esc(t('rd_nothing_else'))}</p>`}`;
}

// Highlights the sitting and exchange at a moment and scrolls to it.
function markMoment(rep, t0, scroll = true) {
  const list = sittingsOf(rep, _readerTask);
  let k = list.findIndex(st => t0 >= st.start && t0 <= st.end);
  if (k < 0) {
    let best = Infinity;
    list.forEach((st, j) => { const d = Math.min(Math.abs(t0 - st.start), Math.abs(t0 - st.end)); if (d < best) { best = d; k = j; } });
  }
  const sec = id('rd-s' + k);
  if (!sec) return;
  _readerSitting = k;
  const st = list[k];
  if (t0 >= st.start && t0 <= st.end)
    sec.querySelector('.rd-bar').insertAdjacentHTML('beforeend', `<i class="now" style="left:${((t0 - st.start) / ((st.end - st.start) || 1) * 100).toFixed(2)}%"></i>`);
  let hit = null;
  for (const e of sec.querySelectorAll('.rd-ex')) if (+e.dataset.at <= t0) hit = e;
  hit = hit || sec.querySelector('.rd-ex') || sec;
  hit.classList.add('hit');
  if (scroll) hit.scrollIntoView({ block: 'start', behavior: 'smooth' });
}

// From a report card: the Timeline tab, opened on that task.
function openInTimeline(taskId) {
  _readerTask = taskId;
  _readerPin = null;
  setTab('timeline');
  const page = id('table-area')?.closest('section');
  if (page) page.scrollTop = 0;
}

function readerPick(taskId, t0 = null) {
  _readerTask = taskId;
  _readerPin = t0;
  if (!D) return;
  renderReport(D);
  if (t0 != null) markMoment(D, t0);
  else { const page = id('rd-main')?.closest('section'); if (page) page.scrollTop = 0; } // a new task always opens at the top, so the page never jumps
}

function ribbonTime(ev) {
  const r = id('rd-ribbon').getBoundingClientRect();
  return _ribbonA + Math.max(0, Math.min(1, (ev.clientX - r.left) / r.width)) * (_ribbonB - _ribbonA);
}

// Clicking a minute opens the task that had the focus then (or ran then, or
// ran closest) at that moment.
function readerRibbonClick(ev) {
  const t0 = Math.round(ribbonTime(ev) / 60000) * 60000;
  const { focus, others } = whatAt(D, t0);
  let task = focus ? focus.task.id : others.length ? others[0].task.id : null;
  if (task === null) {
    let best = Infinity;
    for (const s of D.intervals) {
      const d = t0 < s.start_ms ? s.start_ms - t0 : t0 - readerEnd(s);
      if (d < best) { best = d; task = s.task.id; }
    }
  }
  readerPick(task, t0);
}

function readerHover(ev) {
  const rib = id('rd-ribbon');
  const t0 = Math.round(ribbonTime(ev) / 60000) * 60000;
  const { focus } = whatAt(D, t0);
  let c = rib.querySelector('.rd-cursor');
  if (!c) { rib.insertAdjacentHTML('beforeend', '<div class="rd-cursor"><span></span></div>'); c = rib.querySelector('.rd-cursor'); }
  c.style.left = ribbonPos(t0);
  c.firstChild.textContent = fmtTime(t0) + '  ' + (focus ? taskLabel(focus.task) + ' ' + trunc(focus.task.title, 28) : t('rd_nothing_focused'));
}
function readerHoverOut() { id('rd-ribbon')?.querySelector('.rd-cursor')?.remove(); }

function readerUnfold(btn) {
  btn.insertAdjacentHTML('afterend', decodeURIComponent(btn.dataset.more));
  btn.remove();
}

// J and K step through the sittings.
function readerStep(dir) {
  const secs = document.querySelectorAll('.rd-sitting');
  if (!secs.length) return;
  _readerSitting = Math.max(0, Math.min(secs.length - 1, _readerSitting + dir));
  secs.forEach(s => s.classList.remove('cur'));
  secs[_readerSitting].classList.add('cur');
  secs[_readerSitting].scrollIntoView({ block: 'start', behavior: 'smooth' });
}
