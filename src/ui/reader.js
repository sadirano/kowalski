'use strict';
// ── Reader layout ─────────────────────────────────────────────────────────────
// One task's day read top to bottom, beside a day map to click a moment on:
// the task's sittings (its intervals joined while the gaps stay under
// SITTING_GAP), each with its exchanges: a prompt and what came of it. The
// map's "At" panel lists what else ran at the pinned minute.
const SITTING_GAP = 10 * 60000;
const READER_FOLD = 3;   // updates under a prompt shown before folding
let _readerTask = null;  // the task being read; kept across reloads
let _readerPin = null;   // the minute clicked on the ribbon, or null
let _readerSitting = 0;  // the sitting J/K move from
let _readerDay = null;     // the day shown; a new day drops the pin and sitting
let _readerPointer = null; // last pointer over the map, to restore hover after a render
let _ribbonA = 0, _ribbonB = 1;

function readerEnd(s) { return s.end_ms ?? Date.now() + _skew; }

// The day's intervals clipped to its bounds; an open one runs to now and stays live.
function readerIntervals(rep) {
  const now = Date.now() + _skew;
  return rep.intervals.map(s => ({
    ...s, start_ms: Math.max(s.start_ms, rep.start_ms),
    end_ms: Math.min(s.end_ms ?? now, rep.end_ms),
    readerLive: s.end_ms == null && now < rep.end_ms,
    notes: s.notes.filter(n => n.at_ms >= rep.start_ms && n.at_ms < rep.end_ms)
  })).filter(s => s.end_ms > s.start_ms);
}

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
  const list = readerIntervals(rep).filter(s => s.task.id === taskId).sort((a, b) => a.start_ms - b.start_ms);
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

// A task's time running in parallel, outside its own focus.
function parallelMsOf(rep, taskId) {
  const items = readerIntervals(rep).filter(s => s.task.id === taskId);
  return unionMs(items.map(s => [s.start_ms, readerEnd(s)])) - unionMs(items.filter(s => s.role === 'focus').map(s => [s.start_ms, readerEnd(s)]));
}

// Focus time, with the task's parallel time beside it, muted, when it has any;
// the second figure needs no label.
function durHtml(rep, entry) {
  const par = parallelMsOf(rep, entry.task.id);
  return fmtMs(entry.focus_ms) + (par >= 60000 ? `<span class="dur-par"> · ${fmtMs(par)}</span>` : '');
}

// The focus other tasks had between two sittings, longest first.
function meanwhileOf(rep, taskId, a, b) {
  const m = new Map();
  for (const s of readerIntervals(rep)) {
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
  for (const s of readerIntervals(rep)) if (s.task.id === taskId)
    for (const n of s.notes) if (n.at_ms <= t && (!best || n.at_ms > best.at_ms)) best = n;
  return best;
}

function whatAt(rep, t) {
  const on = readerIntervals(rep).filter(s => s.start_ms <= t && t < readerEnd(s));
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
  const page = area.closest('section');
  const pageScroll = page?.scrollTop ?? 0;
  const tabsScroll = area.querySelector('.rd-tabs')?.scrollTop ?? 0;
  const atScroll = area.querySelector('.rd-at')?.scrollTop ?? 0;
  if (_readerDay !== rep.start_ms) {
    _readerDay = rep.start_ms;
    _readerPin = null;
    _readerSitting = 0;
  }
  const tasks = orderTasks(rep);
  const savedTask = loadLS('readerTask', null);
  if (savedTask !== _readerTask && tasks.some(e => e.task.id === savedTask)) {
    _readerTask = savedTask;
    _readerSitting = 0;
    _readerPin = null;
  }
  if (!tasks.some(e => e.task.id === _readerTask)) {
    _readerSitting = 0;
    _readerTask = tasks.some(e => e.task.id === _currentTaskId) ? _currentTaskId : tasks[0].task.id;
  }
  const pinned = _readerPin;
  // A task with an open interval shows the report's live badge; parallel work in its muted form.
  const live = new Map(rep.intervals.filter(s => s.end_ms == null).map(s => [s.task.id, s.role]));
  const liveBadge = id => !live.has(id) ? '' : `<span class="open-badge${live.get(id) === 'parallel' ? ' par' : ''}">${t('live')}</span>`;
  mapRange(rep);
  area.innerHTML = `<div class="rd">
    <nav class="rd-tabs" role="tablist">${tasks.map(e => `<button class="rd-tab" role="tab" data-t="${e.task.id}" aria-selected="${e.task.id === _readerTask}" onclick="readerPick(${e.task.id})"
        onmouseenter="readerLight(${e.task.id})" onmouseleave="readerLight(null)" onfocus="readerLight(${e.task.id})" onblur="readerLight(null)">
        <span class="rd-id">${esc(taskLabel(e.task))}</span><span class="rd-tt">${esc(e.task.title)}<small class="rd-project">${esc(projectName(e.task.project_id))}${liveBadge(e.task.id)}</small></span><span class="rd-t">${durHtml(rep, e)}</span></button>`).join('')}</nav>
    <div class="rd-main" id="rd-main">${readerMainHtml(rep)}<button class="rd-end" type="button" onclick="readerToEnd()">${icon('chev')}${esc(t('rd_to_end'))}</button></div>
    <div class="rd-work">
      <div class="resize-handle" onpointerdown="startRdResize(event)" ondblclick="resetRdWorkWidth()" title="${escAttr(t('rd_resize_hint'))}"></div>
      <div class="rd-workhead"><div class="rd-legend"><span><i class="rd-sw f"></i>${esc(t('rd_legend_you'))}</span><span><i class="rd-sw p"></i>${esc(t('rd_legend_par'))}</span><span><i class="rd-sw o"></i>${esc(t('rd_legend_other'))}</span></div></div>
      <div class="rd-workbody"><div class="rd-map" id="rd-ribbon">${rowsHtml(rep)}</div>
        <aside class="rd-at" id="rd-at">${pinned == null ? `<p class="rd-nil">${esc(t('rd_pick_hint'))}</p>` : atHtml(rep, pinned)}</aside></div>
      <div class="rd-hint">${esc(t('rd_hint'))}</div>
    </div>
  </div>`;
  applyRdWorkWidth();
  if (page) page.scrollTop = pageScroll;
  area.querySelector('.rd-tabs').scrollTop = tabsScroll;
  area.querySelector('.rd-at').scrollTop = atScroll;
  if (page && !page.dataset.rdEnd) { page.dataset.rdEnd = '1'; page.addEventListener('scroll', readerEndFit, { passive: true }); }
  readerEndFit();
  if (pinned != null) markMoment(rep, pinned, false);
  requestAnimationFrame(() => {
    const tab = area.querySelector('.rd-tab:hover');
    readerLight(tab ? +tab.dataset.t : null);
    const strip = area.querySelector('.rd-strip:hover');
    if (strip && _readerPointer) readerHover(_readerPointer, strip);
  });
}

// Map positions are percentages; refresh the hover marker after its strip moves.
function readerRefitMap() {
  const map = id('rd-ribbon');
  if (!map) return;
  map.querySelectorAll('.rd-cursor').forEach(cursor => cursor.remove());
  const strip = map.querySelector('.rd-strip:hover');
  if (strip && _readerPointer) readerHover(_readerPointer, strip);
  else readerMark(null);
}

// Pointing at a task in the list lights its pieces on the map, parallel
// time included, and dims the rest.
function readerLight(taskId) {
  const map = id('rd-ribbon');
  if (!map) return;
  map.classList.toggle('lit', taskId != null);
  for (const el of map.querySelectorAll('.rd-seg')) el.classList.toggle('hot', +el.dataset.t === taskId);
}

// The map spans whole hours around the day's intervals.
function mapRange(rep) {
  const H = 3600000;
  const intervals = readerIntervals(rep);
  const s0 = Math.min(...intervals.map(s => s.start_ms)), e0 = Math.max(...intervals.map(readerEnd));
  _ribbonA = rep.start_ms + Math.floor((s0 - rep.start_ms) / H) * H;
  _ribbonB = Math.max(_ribbonA + H, rep.start_ms + Math.ceil((e0 - rep.start_ms) / H) * H);
}

// Other tasks get one of a few muted tints, in order of first appearance, so
// neighbours read apart without naming them.
const OTHER_TINTS = 6;
function otherTints(rep) {
  const m = new Map();
  for (const s of readerIntervals(rep).sort((p, q) => p.start_ms - q.start_ms))
    if (s.task.id !== _readerTask && !m.has(s.task.id)) m.set(s.task.id, m.size % OTHER_TINTS);
  return m;
}

// One clickable strip covering [a, b), left to right.
function stripHtml(rep, a, b) {
  const pos = ms => ((ms - a) / (b - a) * 100).toFixed(3) + '%';
  const size = (x, y) => Math.max((y - x) / (b - a) * 100, 0.2).toFixed(3) + '%';
  // The hover cursor names what is under it, so segments carry no tooltip of their own.
  const seg = (s, cls) => {
    const x = Math.max(s.start_ms, a), y = Math.min(readerEnd(s), b);
    return y <= x ? '' : `<div class="rd-seg ${cls}" data-t="${s.task.id}" style="left:${pos(x)};width:${size(x, y)}"></div>`;
  };
  const tint = otherTints(rep);
  const H = 3600000;
  let lines = '';
  for (let h = a + H; h < b; h += H) lines += `<i class="rd-hl" style="left:${pos(h)}"></i>`;
  return `<div class="rd-strip" data-a="${a}" data-b="${b}" onclick="readerRibbonClick(event,this)" onmousemove="readerHover(event,this)" onmouseleave="readerHoverOut(this)">${lines}`
    + readerIntervals(rep).filter(s => s.task.id !== _readerTask).map(s => seg(s, `o t${tint.get(s.task.id)}${s.role === 'focus' ? '' : ' op'}`)).join('')
    + readerIntervals(rep).filter(s => s.task.id === _readerTask).map(s => seg(s, s.role === 'focus' ? 'f' : 'p')).join('')
    + (_readerPin != null && _readerPin >= a && _readerPin < b ? `<div class="rd-pin" style="left:${pos(_readerPin)}"></div>` : '')
    + '</div>';
}

// Rows: the day folded into three rows of whole hours, read left to right.
function rowsHtml(rep) {
  const H = 3600000, SPAN = Math.ceil((_ribbonB - _ribbonA) / H / 3) * H;
  let html = '';
  for (let a = _ribbonA; a < _ribbonB; a += SPAN) {
    const b = Math.min(a + SPAN, _ribbonB);
    let ticks = '';
    for (let h = a; h <= b; h += H) ticks += `<span style="left:${((h - a) / (b - a) * 100).toFixed(3)}%">${esc(fmtTime(h))}</span>`;
    html += `<div class="rd-row"><div class="rd-rticks">${ticks}</div>${stripHtml(rep, a, b)}</div>`;
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
  let h = `<h1 class="rd-h1"${entry.task.ref ? ` title="${escAttr(t('rd_provider_title'))}"` : ''}><span class="rd-ref">${entry.task.ref ? refLink(entry.task.ref) : esc('#' + entry.task.id)}</span><span class="rd-title" id="rd-title">${esc(entry.task.title)}</span>${entry.task.ref ? '' : `<button class="rd-title-edit" type="button" onclick="editReaderTitle()" title="${escAttr(t('rd_edit_title'))}" aria-label="${escAttr(t('rd_edit_title'))}">${icon('edit')}</button>`}</h1>
    <p class="rd-headline">${esc(t(parallel >= 60000 ? 'rd_head_par' : 'rd_head', vars))} ${esc(list.length > 1 ? t('rd_back', { n: list.length - 1 }) : t('rd_one'))}</p>`;
  list.forEach((st, k) => {
    if (k > 0) {
      const prev = list[k - 1];
      const mw = meanwhileOf(rep, _readerTask, prev.end, st.start).slice(0, 3)
        .map(([tid, ms]) => `${esc(trunc(titleOf(rep, tid), 40))} (${esc(rdDur(ms))})`).join(', ');
      h += `<div class="rd-gap"><span><b>${esc(t('rd_later', { d: rdDur(st.start - prev.end) }))}</b>${mw ? ' · ' + esc(t('rd_meanwhile')) + ' ' + mw : ''}</span></div>`;
    }
    const L = (st.end - st.start) || 1;
    // The rail: the sitting's time runs down beside its text, start at the top, end at the bottom.
    const bar = (s, cls) => `<i class="${cls}" style="top:${((s.start_ms - st.start) / L * 100).toFixed(2)}%;height:${((readerEnd(s) - s.start_ms) / L * 100).toFixed(2)}%"></i>`;
    const live = st.items.some(s => s.readerLive);
    h += `<section class="rd-sitting" id="rd-s${k}">
      <div class="rd-bar" aria-hidden="true">${st.items.filter(s => s.role === 'parallel').map(s => bar(s, 'p')).join('')}${st.items.filter(s => s.role === 'focus').map(s => bar(s, 'f')).join('')}</div>
      <div class="rd-shead"><span class="rd-span rd-t0">${fmtTime(st.start)}</span>
        <span class="rd-who"><span class="f">${esc(t('rd_you_n', { d: fmtMs(st.focus) }))}</span>${st.parallel >= 60000 ? ` · <span class="p">${esc(t('rd_par_n', { d: fmtMs(st.parallel) }))}</span>` : ''}</span></div>`;
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
    h += `<div class="rd-t1">${live ? `<span style="color:var(--grn)">${t('now')}</span>` : fmtTime(st.end)}</div></section>`;
  });
  return h;
}

function editReaderTitle() {
  const entry = D?.tasks.find(e => e.task.id === _readerTask);
  const span = id('rd-title');
  if (!entry || entry.task.ref || !span) return;
  const oldTitle = entry.task.title;
  const inp = document.createElement('input');
  inp.className = 'rd-title-inp';
  inp.type = 'text';
  inp.value = oldTitle;
  inp.setAttribute('aria-label', t('rd_edit_title'));
  span.replaceWith(inp);
  id('rd-main').querySelector('.rd-title-edit').hidden = true;
  let done = false;
  const cancel = () => { if (!done) { done = true; renderReport(D); } };
  const save = async () => {
    if (done) return;
    const title = inp.value.trim();
    if (!title || title === oldTitle) { cancel(); return; }
    done = true;
    try {
      await apiJSON('PATCH', `/api/tasks/${entry.task.id}`, { title });
      await Promise.all([loadCurrent(), loadDay(selectedDate, { chart: true })]);
    } catch (e) {
      showError(e.message);
      done = false;
      inp.focus();
    }
  };
  inp.onkeydown = e => {
    if (e.key === 'Enter') { e.preventDefault(); save(); }
    if (e.key === 'Escape') { e.preventDefault(); cancel(); }
  };
  inp.onblur = save;
  inp.focus();
  inp.select();
}

function atHtml(rep, t0) {
  const { focus, others } = whatAt(rep, t0);
  const row = (s, kind) => {
    const n = lastNoteBefore(rep, s.task.id, t0);
    return `<button class="rd-run ${kind}" onclick="readerPick(${s.task.id},${t0})"><span class="rd-id">${esc(taskLabel(s.task))}</span> ${esc(s.task.title)}
      <span class="rd-last">${esc(t(kind === 'f' ? 'rd_legend_you' : 'rd_legend_par'))} · ${fmtTime(s.start_ms)} - ${s.readerLive ? t('now') : fmtTime(s.end_ms)}${n ? ' · ' + esc(trunc(n.text.replace(/^->\s*/, ''), 90)) : ''}</span></button>`;
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
    sec.querySelector('.rd-bar').insertAdjacentHTML('beforeend', `<i class="now" style="top:${((t0 - st.start) / ((st.end - st.start) || 1) * 100).toFixed(2)}%"></i>`);
  let hit = null;
  for (const e of sec.querySelectorAll('.rd-ex')) if (+e.dataset.at <= t0) hit = e;
  hit = hit || sec.querySelector('.rd-ex') || sec;
  hit.classList.add('hit');
  if (scroll) hit.scrollIntoView({ block: 'start', behavior: 'smooth' });
}

// From a report card: the Timeline tab, opened on that task.
function openInTimeline(taskId) {
  _readerSitting = 0;
  _readerTask = taskId;
  saveLS('readerTask', taskId);
  _readerPin = null;
  setTab('timeline');
  const page = id('table-area')?.closest('section');
  if (page) page.scrollTop = 0;
}

function readerPick(taskId, t0 = null) {
  _readerSitting = 0;
  _readerTask = taskId;
  saveLS('readerTask', taskId);
  _readerPin = t0;
  if (!D) return;
  renderReport(D);
  if (t0 != null) markMoment(D, t0);
  else { const page = id('rd-main')?.closest('section'); if (page) page.scrollTop = 0; } // a new task always opens at the top, so the page never jumps
}

function stripTime(ev, el) {
  const r = el.getBoundingClientRect(), a = +el.dataset.a, b = +el.dataset.b;
  const f = Math.max(0, Math.min(1, (ev.clientX - r.left) / r.width));
  return Math.max(a, Math.min(b - 60000,
    Math.floor((a + f * (b - a)) / 60000) * 60000));
}

// Clicking a minute opens the task that had the focus then (or ran then, or
// ran closest) at that moment.
function readerRibbonClick(ev, el) {
  const t0 = stripTime(ev, el);
  const { focus, others } = whatAt(D, t0);
  let task = focus ? focus.task.id : others.length ? others[0].task.id : null;
  if (task === null) {
    let best = Infinity;
    for (const s of readerIntervals(D)) {
      const d = t0 < s.start_ms ? s.start_ms - t0 : t0 - readerEnd(s);
      if (d < best) { best = d; task = s.task.id; }
    }
  }
  readerPick(task, t0);
}

function readerHover(ev, el) {
  _readerPointer = { clientX: ev.clientX };
  const t0 = stripTime(ev, el);
  const { focus } = whatAt(D, t0);
  let c = el.querySelector('.rd-cursor');
  if (!c) { el.insertAdjacentHTML('beforeend', '<div class="rd-cursor"><span></span></div>'); c = el.querySelector('.rd-cursor'); }
  const f = (t0 - +el.dataset.a) / (+el.dataset.b - +el.dataset.a);
  c.style.left = (f * 100).toFixed(3) + '%';
  // Near an edge the label opens inward so it never runs off the map.
  c.firstChild.style.transform = `translate(${f < 0.2 ? '0' : f > 0.8 ? '-100%' : '-50%'},2px)`;
  c.firstChild.textContent = fmtTime(t0) + '  ' + (focus ? taskLabel(focus.task) + ' ' + trunc(focus.task.title, 28) : t('rd_nothing_focused'));
  readerMark(focus ? focus.task.id : null);
}
function readerHoverOut(el) { el.querySelector('.rd-cursor')?.remove(); readerMark(null); }

// The task focused at the pointed minute stands out in the list.
function readerMark(taskId) {
  for (const tab of document.querySelectorAll('.rd-tab')) tab.classList.toggle('lit', +tab.dataset.t === taskId);
}

function readerUnfold(btn) {
  btn.insertAdjacentHTML('afterend', decodeURIComponent(btn.dataset.more));
  btn.remove();
  readerEndFit();
}

// Long tasks run to hundreds of notes: a button jumps to the latest, hidden
// once the end is in view.
function readerToEnd() {
  const page = id('rd-main')?.closest('section');
  if (page) page.scrollTo({ top: page.scrollHeight, behavior: 'smooth' });
}
function readerEndFit() {
  const page = id('rd-main')?.closest('section'), btn = document.querySelector('.rd-end');
  if (page && btn) btn.hidden = page.scrollHeight - page.scrollTop - page.clientHeight < 80;
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
