'use strict';
let _blockData = [];
const _openBlocks = new Set();
// Episodes whose details are shown, by their first interval's id.
const _openEpisodes = new Set();
// Episodes showing all their notes, not just the first few.
const _allNotes = new Set();
// Tasks folded to their header line, by task id; kept per viewer.
const _foldedTasks = new Set((() => {
  try { return JSON.parse(localStorage.getItem('kowalski.foldedTasks') || '[]'); } catch { return []; }
})());
function saveFolded() {
  try { localStorage.setItem('kowalski.foldedTasks', JSON.stringify([..._foldedTasks])); } catch { /* per-viewer only */ }
}
function toggleTaskFold(taskId) {
  if (_foldedTasks.has(taskId)) _foldedTasks.delete(taskId); else _foldedTasks.add(taskId);
  saveFolded();
  if (D) renderReport(D);
}
function foldAllTasks(fold) {
  for (const entry of D?.tasks || []) {
    if (fold) _foldedTasks.add(entry.task.id); else _foldedTasks.delete(entry.task.id);
  }
  saveFolded();
  if (D) renderReport(D);
}

// ── Report view ───────────────────────────────────────────────────────────────
// The day's tasks in the chosen order. The API sends them by focus time.
function orderTasks(rep) {
  const tasks = rep.tasks.slice();
  if (_taskOrder === 'ref') {
    // Tasks without a ref go last, in the order they were created.
    tasks.sort((a, b) => (a.task.ref == null) - (b.task.ref == null)
      || (a.task.ref || '').localeCompare(b.task.ref || '', undefined, { numeric: true })
      || a.task.id - b.task.id);
  } else if (_taskOrder === 'added') {
    const first = new Map();
    for (const s of rep.intervals) first.set(s.task.id, Math.min(first.get(s.task.id) ?? Infinity, s.start_ms));
    tasks.sort((a, b) => (first.get(a.task.id) ?? Infinity) - (first.get(b.task.id) ?? Infinity) || a.task.id - b.task.id);
  }
  return tasks;
}

function renderReport(rep) {
  const area = id('table-area');
  const page = area.closest('section');
  const pageScroll = page?.scrollTop ?? 0;
  const restoreScroll = () => { if (page) page.scrollTop = pageScroll; };
  closeSelectionMenu(false);
  closeSelectionPicker(false);
  if (_slotSel && (_slotSelDate !== rep.date || activeTab !== 'report')) {
    _slotSel = null;
    _slotSelDate = null;
  }
  _taskData = []; // reset task registry for switch buttons
  _blockData = []; // reset interval registry for block actions
  if (!rep.tasks?.length) {
    area.innerHTML = `<div class="empty">${t('no_sessions')}</div>`;
    restoreScroll();
    markSlotSel();
    return;
  }

  if (activeTab === 'timeline') {
    area.classList.remove('grid-report');
    renderReader(rep, area);
    return;
  }
  const ordered = orderTasks(rep);
  // Grid: cards in columns, work blocks, folding. Classic: the report as it
  // was, one full-width card per task listing its intervals.
  const grid = _reportLayout === 'grid';
  const allFolded = ordered.every(entry => _foldedTasks.has(entry.task.id));
  const fold = grid ? `<button class="link-btn" onclick="foldAllTasks(${!allFolded})">${esc(t(allFolded ? 'expand_all' : 'collapse_all'))}</button>` : '';
  const toolbar = `<div class="report-bar">${fold}${prefButton('report')}</div>`;
  area.classList.toggle('grid-report', grid);
  const cards = ordered.map(entry => {
    const task = entry.task;
    const hopCls  = entry.hops > 0 ? 'some' : 'none';
    const hopText = entry.hops > 0 ? t('hops', { n: entry.hops }) : t('no_hops');

    const sessions = rep.intervals.filter(s => s.task.id === task.id).sort((a, b) => a.start_ms - b.start_ms);
    // compact: a timeline row under an episode's Details; its note grid
    // opens only when clicked, since the episode already lists the notes.
    const renderBlocks = (list, compact = false) => list.map((s, idx) => {
      const bi = _blockData.length;
      _blockData.push(s);
      const isOpen   = s.end_ms == null;
      const endStr   = isOpen ? `<span style="color:var(--grn)">${t('now')}</span>` : fmtTime(s.end_ms);
      const dur      = fmtMs(Math.min(s.end_ms ?? Date.now() + _skew, rep.end_ms) - Math.max(s.start_ms, rep.start_ms));
      const badge    = (isOpen ? `<span class="open-badge">${t('live')}</span>` : '')
                     + (s.role === 'parallel' ? `<span class="open-badge par">${t('parallel')}</span>` : '');
      const filled   = s.notes.length + (s.text ? 1 : 0);
      const preview  = filled > 0 ? t('notes_n', { n: filled }) : t('click_notes');
      const blockOpen = _openBlocks.has(s.id) || (!compact && isOpen && !_openBlocks.has(-s.id));

      // Merge button: show between this block and the next when:
      //  • Both closed and gap ≤ 60 s, OR
      //  • Next block is the currently open interval (gap constraint waived)
      let mergeBtn = '';
      const next = list[idx + 1];
      if (next && !isOpen && s.role === next.role) {
        const gapMs  = next.start_ms - s.end_ms;
        const gapStr = gapMs < 0 ? 'overlap'
                     : gapMs < 1000 ? '<1s'
                     : gapMs < 60000 ? `${Math.round(gapMs/1000)}s`
                     : `${Math.round(gapMs/60000)}m`;
        const nextIsOpen   = next.end_ms == null;
        const withinWindow = gapMs >= 0 && gapMs <= 60000;
        if (nextIsOpen || withinWindow) {
          const bigGap  = gapMs > 600000;
          const label = `${t('merge_next')} (gap ${gapStr})`;
          mergeBtn = `<div class="merge-row">
            <button class="merge-btn${bigGap?' warn':''}" onclick="mergeBlocks(${bi},${bi + 1},${gapMs})" title="${escAttr(label)}">
              ${esc(label)}
            </button>
          </div>`;
        }
      }

      return `<div class="block${compact ? ' compact' : ''}" id="blk-${s.id}" data-bi="${bi}">
        <div class="block-hdr" onclick="toggleBlock(this)"${isOpen ? '' : ` draggable="true" ondragstart="dragBlock(event,${bi})" ondragend="dragEndBlock()" title="${escAttr(t('drag_block'))}"`}>
          <div class="block-time">${fmtTime(s.start_ms)} → ${endStr}${badge}</div>
          <div class="block-dur">${dur}</div>
          <div class="block-note-preview ${filled>0?'has-note':''}">${preview}</div>
          <span class="slot-selected-mark" title="${escAttr(t('selection_selected_marker'))}">●</span>
          <div class="block-actions">
            <button class="btn-icon" title="${escAttr(t('edit_times'))}" aria-label="${escAttr(t('edit_times'))}" onclick="event.stopPropagation();openEditTime(${bi})">${icon('edit')}</button>
            ${isOpen ? '' : `<button class="btn-icon" title="${escAttr(t('delete_block'))}" aria-label="${escAttr(t('delete_block'))}" onclick="event.stopPropagation();deleteBlock(${bi})">${icon('trash')}</button>`}
          </div>
          <div class="block-toggle">${blockOpen ? '▾' : '▸'}</div>
        </div>
        <div class="slot-grid${blockOpen ? ' open' : ''}">${buildSlotRows(s, bi)}</div>
      </div>${mergeBtn}`;
    }).join('');
    const folded = grid && _foldedTasks.has(task.id);
    const spanEnd = Math.max(...sessions.map(x => x.end_ms ?? Date.now() + _skew));
    const span = sessions.length ? `${fmtTime(sessions[0].start_ms)} – ${sessions.some(x => x.end_ms == null) ? t('now') : fmtTime(spanEnd)}` : '';
    const blocks = !grid ? renderBlocks(sessions) : folded ? '' : renderEpisodes(sessions, rep, renderBlocks);

    // Register task data for the switch button (avoids escaping task data in onclick)
    const taskIdx = _taskData.length;
    _taskData.push({ task });
    const isCurrent  = task.id === _currentTaskId;
    const switchLabel = isCurrent ? '●' : '▶';
    const switchTitle = isCurrent ? t('live') : t('search_switch');
    const switchCls   = isCurrent ? 'switch-btn current-task' : 'switch-btn';
    const switchClick = isCurrent
      ? ''
      : `onclick="event.stopPropagation();switchToTaskByIdx(${taskIdx})"`;

    const meta = esc(entry.fields.map(field => field.value).filter(Boolean).concat(task.title).join(' · '));
    // The projects this task's time went to today; most tasks have one.
    const projectTag = [...new Set(sessions.map(s => s.project_id).filter(id => id != null))].map(projectName).map(esc).join(', ');
    const ref = task.ref ? refLink(task.ref) : esc('#' + task.id);
    const head = grid
      ? `<div class="task-hdr fold" onclick="toggleTaskFold(${task.id})" title="${escAttr(t(folded ? 'expand' : 'collapse'))}">
        <div class="task-line">
          <span class="task-fold">${folded ? '▸' : '▾'}</span>
          <span class="task-id" onclick="event.stopPropagation()">${ref}</span>
          <span class="task-meta">${projectTag ? `<span class="task-project">${projectTag}</span>` : ''}${meta}</span>
          ${folded && span ? `<span class="task-eps">${span}</span>` : ''}
        </div>`
      : `<div class="task-hdr">
        <div>
          <div class="task-id">${ref}</div>
          <div class="task-meta">${projectTag ? `<span class="task-project">${projectTag}</span>` : ''}${meta}</div>
        </div>`;
    const card = `<div class="task-card${folded ? ' folded' : ''}${isSearchFound(task.id) ? ' found' : ''}" data-task="${task.id}" ondragover="dragOverTask(event,${taskIdx})" ondragleave="dragLeaveTask(event)" ondrop="dropOnTask(event,${taskIdx})">
      ${head}
        <div style="display:flex;align-items:center;gap:10px">
          <button class="${switchCls}" title="${escAttr(switchTitle)}" aria-label="${escAttr(switchTitle)}" ${switchClick}>${switchLabel}</button>
          <button class="btn-icon" title="${escAttr(t('open_timeline'))}" aria-label="${escAttr(t('open_timeline'))}" onclick="event.stopPropagation();openInTimeline(${task.id})">${icon('lanes')}</button>
          <div>
            <div class="task-dur">${fmtMs(entry.focus_ms)}</div>
            <div class="task-hops ${hopCls}">${hopText}</div>
          </div>
        </div>
      </div>
      <div class="block-list">${blocks}</div>
    </div>`;
    // Folded height, roughly in lines: placing cards by it keeps them in
    // their column when one shows more notes.
    // Weighed as if open, so folding a card never moves the others between columns.
    const weight = 2 + episodesOf(sessions).reduce((n, ep) => n + 1 + Math.min(EPISODE_NOTES, episodeNotes(ep).length), 0);
    return { html: card, weight };
  });
  if (!grid) {
    patchHTML(area, cards.map(c => c.html).join(''));
    restoreScroll();
    markSlotSel();
    return;
  }
  // Each card goes to the shortest column so far, in task order.
  const count = Math.max(1, Math.floor((area.clientWidth + 10) / (GRID_COLUMN + 10)));
  _gridCols = count;
  const cols = Array.from({ length: count }, () => ({ html: [], weight: 0 }));
  for (const c of cards) {
    const col = cols.reduce((low, x) => (x.weight < low.weight ? x : low));
    col.html.push(c.html);
    col.weight += c.weight;
  }
  patchHTML(area, toolbar + `<div class="card-cols">${cols.map(c => `<div class="card-col">${c.html.join('')}</div>`).join('')}</div>`);
  restoreScroll();
  markSlotSel();
}

// The narrowest a grid column gets, in pixels.
const GRID_COLUMN = 480;
let _gridCols = 0;
window.addEventListener('resize', () => {
  if (_reportLayout !== 'grid' || activeTab !== 'report' || !D) return;
  const area = id('table-area');
  const count = Math.max(1, Math.floor((area.clientWidth + 10) / (GRID_COLUMN + 10)));
  if (count !== _gridCols) renderReport(D);
});

// ── Episodes ──────────────────────────────────────────────────────────────────
// A task's intervals read as episodes: a stretch of work on it, joined while
// the gaps stay under EPISODE_GAP, whatever the focus did in between. Each
// shows its span, its focus and its agent time, and every note in it; the
// intervals themselves sit behind Details. Counting does not change: focus
// is still only the focus intervals.
const EPISODE_GAP = 5 * 60000;
// Notes an episode shows before "+N more" (all of them with Details open).
const EPISODE_NOTES = 3;
// An episode with no notes and less time than this joins "Other".
const EPISODE_QUIET = 2 * 60000;

function episodesOf(sessions) {
  const now = Date.now() + _skew;
  const out = [];
  for (const s of sessions) {
    const end = s.end_ms ?? now;
    const last = out[out.length - 1];
    if (last && s.start_ms - last.end <= EPISODE_GAP) {
      last.items.push(s);
      last.end = Math.max(last.end, end);
    } else out.push({ items: [s], start: s.start_ms, end });
  }
  return out;
}

function episodeTimes(ep, rep) {
  const now = Date.now() + _skew;
  const clip = s => Math.max(0, Math.min(s.end_ms ?? now, rep.end_ms) - Math.max(s.start_ms, rep.start_ms));
  let focus = 0, agent = 0, estimated = false;
  for (const s of ep.items) {
    if (s.role === 'focus') { focus += clip(s); estimated ||= s.captured; } else agent += clip(s);
  }
  return { focus, agent, estimated };
}

function episodeNotes(ep) {
  const notes = [];
  for (const s of ep.items) {
    if (s.text) notes.push({ at_ms: s.start_ms, text: s.text, source: null });
    for (const n of s.notes) notes.push(n);
  }
  return notes.sort((a, b) => a.at_ms - b.at_ms);
}

function episodeNoteHtml(n) {
  const who = n.source === 'prompt' ? `<span class="ep-who you">${esc(t('ep_you'))}</span>`
    : n.source === 'outcome' ? `<span class="ep-who agent">${esc(t('ep_agent'))}</span>` : '';
  const text = n.source === 'outcome' ? n.text.replace(/^->\s*/, '') : n.text;
  return `<div class="ep-note"><span class="ep-at">${fmtTime(n.at_ms)}</span>${who}<span class="ep-text" title="${escAttr(text)}">${notePreview(text)}</span></div>`;
}

function notePreview(text) {
  const first = text.split(/\r?\n/, 1)[0];
  return esc(first) + (first.length < text.length ? '<small>...</small>' : '');
}

function episodeHtml(ep, rep, renderBlocks, label) {
  const key = ep.items[0].id;
  const open = _openEpisodes.has(key);
  const all = _allNotes.has(key);
  const live = ep.items.some(s => s.end_ms == null);
  const { focus, agent, estimated } = episodeTimes(ep, rep);
  const parts = [];
  if (focus > 0 || agent === 0) parts.push(`${esc(t('ep_focus'))} ${estimated ? '≈ ' : ''}${fmtMs(focus)}`);
  if (agent > 0) parts.push(`${esc(t('ep_agent_time'))} ${fmtMs(agent)}`);
  const end = live ? `<span style="color:var(--grn)">${t('now')}</span>` : fmtTime(ep.end);
  const notes = episodeNotes(ep);
  const title = estimated ? ` title="${escAttr(t('ep_estimated'))}"` : '';
  return `<div class="episode${open ? ' open' : ''}">
    <div class="ep-hdr" onclick="toggleEpisode(${key})">
      <div class="ep-time">${label ? esc(label) : `${fmtTime(ep.start)} → ${end}`}${live ? `<span class="open-badge">${t('live')}</span>` : ''}</div>
      <div class="ep-dur"${title}>${parts.join(' · ')}</div>
    </div>
    ${notes.length ? `<div class="ep-notes">${(all ? notes : notes.slice(0, EPISODE_NOTES)).map(episodeNoteHtml).join('')}${notes.length > EPISODE_NOTES ? `<div class="ep-note ep-rest" onclick="toggleAllNotes(${key})">${esc(all ? t('show_less') : t('more_n', { n: notes.length - EPISODE_NOTES }))}</div>` : ''}</div>` : ''}
    <div class="ep-details${open ? ' open' : ''}">${renderBlocks(ep.items, true)}</div>
  </div>`;
}

function renderEpisodes(sessions, rep, renderBlocks) {
  const episodes = episodesOf(sessions);
  const quiet = [];
  const shown = [];
  for (const ep of episodes) {
    const { focus, agent } = episodeTimes(ep, rep);
    const live = ep.items.some(s => s.end_ms == null);
    if (!live && !episodeNotes(ep).length && focus + agent < EPISODE_QUIET) quiet.push(ep);
    else shown.push(ep);
  }
  let html = shown.map(ep => episodeHtml(ep, rep, renderBlocks)).join('');
  if (quiet.length) {
    const other = { items: quiet.flatMap(ep => ep.items), start: quiet[0].start, end: quiet[quiet.length - 1].end };
    html += episodeHtml(other, rep, renderBlocks, t('ep_other'));
  }
  return html;
}

function toggleAllNotes(key) {
  if (_allNotes.has(key)) _allNotes.delete(key); else _allNotes.add(key);
  if (D) renderReport(D);
}

// Clicking a block's time line shows its intervals, for editing.
function toggleEpisode(key) {
  if (_openEpisodes.has(key)) _openEpisodes.delete(key); else _openEpisodes.add(key);
  if (D) renderReport(D);
}

// ── 15-minute slots ───────────────────────────────────────────────────────────
// An open block lists every 15-minute clock slot it covers, each with the
// notes written in it. An empty slot takes a note at its start (or at the
// interval's start, in its first slot). Note times are not edited.
const SLOT_MS = 15 * 60000;

function slotsOf(s) {
  const end = s.end_ms ?? Date.now() + _skew;
  const first = Math.floor(s.start_ms / SLOT_MS) * SLOT_MS;
  const count = Math.max(1, Math.ceil((end - first) / SLOT_MS));
  return { first, count, end };
}

function buildSlotRows(s, bi) {
  const { first, count } = slotsOf(s);
  const bySlot = Array.from({ length: count }, () => []);
  const place = at => Math.min(count - 1, Math.max(0, Math.floor((at - first) / SLOT_MS)));
  if (s.text) bySlot[place(s.start_ms)].push(`<span class="slot-note" title="${escAttr(s.text)}">${notePreview(s.text)}</span>`);
  for (const n of s.notes) {
    bySlot[place(n.at_ms)].push(`<span class="slot-note" id="sn-${n.id}" title="${escAttr(n.text)}" onclick="editNote(${bi},${n.id})">${notePreview(n.text)}</span>`);
  }
  const closed = s.end_ms != null;
  const hint = closed ? escAttr(t('slot_hint')) : '';
  return bySlot.map((notes, k) => {
    // A slot is a quarter hour of the clock; its label is where the
    // interval's time in it begins, not where the quarter does.
    const at = Math.max(first + k * SLOT_MS, s.start_ms);
    const time = fmtTime(at);
    const handle = closed
      ? ` tabindex="0" onclick="selectSlot(event,${bi},${k})" draggable="true" ondragstart="dragSlots(event,${bi},${k})" ondragend="dragEndBlock()" title="${hint}"`
      : ' tabindex="0"';
    const body = notes.length ? notes.join('')
      : `<span class="slot-note blank" id="na-${s.id}-${k}" data-ph="${escAttr(t('add_note'))}" onclick="addNoteAt(${bi},${k})"></span>`;
    return `<div class="slot-row" data-slot="${k}" data-bi="${bi}">
      <div class="slot-time${closed ? ' pick' : ''}"${handle}>${time}</div>
      <div class="slot-note-wrap">${body}</div>
    </div>`;
  }).join('');
}

// ── Slot selection ────────────────────────────────────────────────────────────
let _slotSel = null; // { anchor_ms, from_ms, to_ms }: time on the shown day
let _slotSelDate = null;
let _selectionMenu = null, _selectionMenuReturn = null;
let _selectionPicker = null, _selectionPickerReturn = null;
let _selectionSearchTimer = 0, _selectionSearchSeq = 0;
let _selectionPickerIndex = -1;

function selectionUiOpen() { return !!(_selectionMenu || _selectionPicker); }

function slotRange(bi, a, b) {
  const s = _blockData[bi];
  const { first } = slotsOf(s);
  return {
    from: Math.max(s.start_ms, D.start_ms, first + a * SLOT_MS),
    to: Math.min(s.end_ms ?? D.end_ms, D.end_ms, first + (b + 1) * SLOT_MS),
  };
}

function slotClock(bi, k) { return slotsOf(_blockData[bi]).first + k * SLOT_MS; }

function selectSlot(e, bi, k) {
  e.stopPropagation();
  const s = _blockData[bi];
  if (!s || s.end_ms == null) return;
  const range = slotRange(bi, k, k);
  if (range.from >= range.to) return;
  const clock = slotClock(bi, k);
  if (e.shiftKey && _slotSel) {
    _slotSel = {
      anchor_ms: _slotSel.anchor_ms,
      from_ms: Math.max(D.start_ms, Math.min(_slotSel.anchor_ms, clock)),
      to_ms: Math.min(D.end_ms, Math.max(_slotSel.anchor_ms, clock) + SLOT_MS),
    };
  } else if (_slotSel?.anchor_ms === clock && _slotSel.from_ms === range.from && _slotSel.to_ms === range.to) {
    clearSlotSelection();
    return;
  } else {
    _slotSel = { anchor_ms: clock, from_ms: range.from, to_ms: range.to };
  }
  _slotSelDate = D.date;
  closeSelectionMenu(false);
  closeSelectionPicker(false);
  markSlotSel();
  // The footer can appear over a slot near the bottom of the scrollport.
  // Bring the slot just above it so the next click can still reach the row.
  const row = e.currentTarget?.closest?.('.slot-row')
    || [...id('table-area').querySelectorAll(`.slot-row[data-bi="${bi}"][data-slot="${k}"]`)]
      .find(el => el.getClientRects().length);
  const bar = id('selection-bar');
  const page = id('table-area').closest('section');
  if (row && bar && page) {
    const rowRect = row.getBoundingClientRect(), barRect = bar.getBoundingClientRect();
    const pageRect = page.getBoundingClientRect();
    if (rowRect.bottom > barRect.top - 8 && rowRect.top < barRect.bottom &&
        rowRect.top < pageRect.bottom && rowRect.bottom > pageRect.top) {
      page.scrollTop += rowRect.bottom - barRect.top + 8;
    }
  }
}

function clearSlotSelection() {
  closeSelectionMenu(false);
  closeSelectionPicker(false);
  _slotSel = null;
  _slotSelDate = null;
  markSlotSel();
}

// Each interval appears once even when its episode and Details both render it.
function selectedPieces() {
  if (!_slotSel) return [];
  const found = new Set();
  const pieces = [];
  for (const s of _blockData) {
    if (found.has(s.id)) continue;
    found.add(s.id);
    if (s.end_ms == null) continue;
    const from = Math.max(s.start_ms, _slotSel.from_ms);
    const to = Math.min(s.end_ms, _slotSel.to_ms);
    if (from < to) pieces.push({ s, from, to });
  }
  pieces.sort((a, b) => a.from - b.from || a.s.id - b.s.id);
  return pieces;
}

function selectedSummary() {
  const pieces = selectedPieces();
  const ms = pieces.reduce((n, p) => n + p.to - p.from, 0);
  const tasks = new Set(pieces.map(p => p.s.task.id));
  const seen = new Set();
  const runningExcluded = !!_slotSel && _blockData.some(s => {
    if (seen.has(s.id)) return false;
    seen.add(s.id);
    return s.end_ms == null && s.start_ms < _slotSel.to_ms && Date.now() + _skew > _slotSel.from_ms;
  });
  return { pieces, ms, tasks, runningExcluded };
}

function selectionSnapshot() {
  if (!_slotSel) return null;
  const summary = selectedSummary();
  return {
    ...summary,
    from_ms: _slotSel.from_ms,
    to_ms: _slotSel.to_ms,
    sources: summary.pieces.map(({ s, from, to }) => ({ id: s.id, seen: seenOf(s), ranges: [[from, to]] })),
    posted_tasks: new Set(D.posted_tasks || []),
  };
}

function selectionRangeText(from, to) { return `${fmtTime(from)}-${fmtTime(to)}`; }

function selectionCountLabel(kind, count) {
  return t(`selection_${kind}_${count === 1 ? 'one' : 'many'}`);
}

function markSlotSel() {
  const area = id('table-area');
  const selected = new Map(selectedPieces().map(p => [p.s.id, p]));
  area.querySelectorAll('.block').forEach(block => {
    const s = _blockData[Number(block.dataset.bi)];
    const piece = s && selected.get(s.id);
    block.classList.toggle('has-slot-selection', !!piece);
    block.querySelectorAll('.slot-row').forEach(row => {
      const k = Number(row.dataset.slot);
      const range = piece && slotRange(Number(block.dataset.bi), k, k);
      row.classList.toggle('sel', !!range && range.from < piece.to && range.to > piece.from);
    });
  });
  renderSelectionBar();
}

function renderSelectionBar() {
  const area = id('table-area');
  let bar = id('selection-bar');
  if (!_slotSel || activeTab !== 'report') { bar?.remove(); return; }
  const summary = selectedSummary();
  if (!bar) {
    bar = document.createElement('div');
    bar.id = 'selection-bar';
    bar.className = 'selection-bar';
    area.appendChild(bar);
  }
  const range = selectionRangeText(_slotSel.from_ms, _slotSel.to_ms);
  const disabled = summary.pieces.length ? '' : ' disabled';
  bar.innerHTML = `<div class="selection-bar-text"><strong>${esc(range)}</strong><span>${esc(t('selection_summary', { duration: fmtMs(summary.ms), intervals: summary.pieces.length, intervals_label: selectionCountLabel('interval', summary.pieces.length), tasks: summary.tasks.size, tasks_label: selectionCountLabel('task', summary.tasks.size) }))}</span>${summary.runningExcluded ? `<span class="selection-excluded">${esc(t('selection_running_excluded'))}</span>` : ''}</div>
    <button type="button" onclick="openSelectionPicker()"${disabled}>${esc(t('selection_assign'))}</button>
    <button type="button" class="danger" onclick="deleteSelectedTime()"${disabled}>${esc(t('selection_delete'))}</button>
    <button type="button" onclick="copySelectedTime()"${disabled}>${esc(t('selection_copy'))}</button>
    <button type="button" class="clear" onclick="clearSlotSelection()" title="${escAttr(t('selection_clear'))}" aria-label="${escAttr(t('selection_clear'))}">×</button>`;
}

function closeSelectionMenu(returnFocus = true) {
  if (!_selectionMenu) return;
  _selectionMenu.remove();
  _selectionMenu = null;
  const target = _selectionMenuReturn;
  _selectionMenuReturn = null;
  if (returnFocus) (target?.isConnected ? target : document.querySelector('#table-area .slot-row.sel .slot-time'))?.focus();
}

function openSelectionMenu(e, row, running = false) {
  closeSelectionMenu(false);
  closeSelectionPicker(false);
  const menu = document.createElement('div');
  menu.className = 'selection-menu';
  menu.setAttribute('role', 'menu');
  menu.setAttribute('aria-label', t('selection_actions'));
  menu.tabIndex = -1;
  _selectionMenu = menu;
  _selectionMenuReturn = document.activeElement?.closest?.('.slot-time') || row?.querySelector('.slot-time') || document.activeElement;
  if (running) {
    const line = document.createElement('div');
    line.className = 'selection-menu-disabled';
    line.setAttribute('role', 'menuitem');
    line.setAttribute('aria-disabled', 'true');
    line.textContent = t('selection_running_edit');
    menu.appendChild(line);
  } else {
    const hasPieces = selectedPieces().length > 0;
    for (const [key, action, enabled] of [
      ['selection_assign', openSelectionPicker, hasPieces],
      ['selection_delete', deleteSelectedTime, hasPieces],
      ['selection_copy', copySelectedTime, hasPieces],
      ['selection_clear', clearSlotSelection, true],
    ]) {
      const button = document.createElement('button');
      button.type = 'button';
      button.setAttribute('role', 'menuitem');
      button.textContent = t(key);
      button.disabled = !enabled;
      button.addEventListener('click', () => { closeSelectionMenu(); action(); });
      menu.appendChild(button);
    }
  }
  menu.addEventListener('keydown', event => {
    if (event.key === 'Escape') { event.preventDefault(); event.stopPropagation(); closeSelectionMenu(); return; }
    if (!['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(event.key)) return;
    const items = [...menu.querySelectorAll('button:not(:disabled)')];
    if (!items.length) return;
    event.preventDefault();
    event.stopPropagation();
    const at = items.indexOf(document.activeElement);
    const next = event.key === 'Home' ? 0 : event.key === 'End' ? items.length - 1
      : event.key === 'ArrowDown' ? (at + 1) % items.length : (at + items.length - 1) % items.length;
    items[next].focus();
  });
  document.body.appendChild(menu);
  const rect = row?.querySelector('.slot-time')?.getBoundingClientRect();
  const x = e.clientX || rect?.left || 8;
  const y = e.clientY || rect?.bottom || 8;
  menu.style.left = `${Math.max(8, Math.min(x, innerWidth - menu.offsetWidth - 8))}px`;
  menu.style.top = `${Math.max(8, Math.min(y, innerHeight - menu.offsetHeight - 8))}px`;
  (menu.querySelector('button:not(:disabled)') || menu).focus();
}

document.addEventListener('contextmenu', e => {
  if (activeTab !== 'report') return;
  const row = e.target.closest?.('.slot-row');
  if (!row || !id('table-area').contains(row)) return;
  const bi = Number(row.dataset.bi), k = Number(row.dataset.slot);
  const s = _blockData[bi];
  if (!s) return;
  e.preventDefault();
  if (s.end_ms == null) { openSelectionMenu(e, row, true); return; }
  if (!row.classList.contains('sel')) {
    selectSlot({ stopPropagation() {}, shiftKey: false }, bi, k);
    if (!row.classList.contains('sel')) return;
  }
  openSelectionMenu(e, row);
});

document.addEventListener('pointerdown', e => {
  if (_selectionMenu && !_selectionMenu.contains(e.target)) closeSelectionMenu(false);
  if (_selectionPicker && !_selectionPicker.contains(e.target)) closeSelectionPicker(false);
});

function closeSelectionPicker(returnFocus = true) {
  if (!_selectionPicker) return;
  clearTimeout(_selectionSearchTimer);
  ++_selectionSearchSeq;
  _selectionPicker.remove();
  _selectionPicker = null;
  _selectionPickerIndex = -1;
  const target = _selectionPickerReturn;
  _selectionPickerReturn = null;
  if (returnFocus) (target?.isConnected ? target : id('selection-bar')?.querySelector('button'))?.focus();
}

function renderSelectionTasks(tasks) {
  const list = _selectionPicker?.querySelector('.selection-picker-list');
  if (!list) return;
  list.replaceChildren();
  _selectionPickerIndex = -1;
  _selectionPicker.querySelector('input').removeAttribute('aria-activedescendant');
  if (!tasks.length) {
    const empty = document.createElement('div');
    empty.className = 'selection-picker-empty';
    empty.textContent = t('selection_no_tasks');
    list.appendChild(empty);
    return;
  }
  for (const [index, task] of tasks.entries()) {
    const button = document.createElement('button');
    button.type = 'button';
    button.id = `selection-task-${index}`;
    button.setAttribute('role', 'option');
    button.setAttribute('aria-selected', 'false');
    button.textContent = task.ref ? `${task.ref} · ${task.title}` : task.title;
    button.addEventListener('mouseenter', () => highlightSelectionTask(index));
    button.addEventListener('click', () => {
      const snapshot = selectionSnapshot();
      closeSelectionPicker(false);
      assignSelectionToTask(task, snapshot);
    });
    list.appendChild(button);
  }
  highlightSelectionTask(0);
}

function highlightSelectionTask(index) {
  const picker = _selectionPicker;
  const list = picker?.querySelector('.selection-picker-list');
  const options = [...(list?.querySelectorAll('[role="option"]') || [])];
  if (!options.length) return;
  _selectionPickerIndex = Math.max(0, Math.min(index, options.length - 1));
  options.forEach((option, i) => {
    option.setAttribute('aria-selected', String(i === _selectionPickerIndex));
  });
  picker.querySelector('input').setAttribute('aria-activedescendant', options[_selectionPickerIndex].id);
  const optionRect = options[_selectionPickerIndex].getBoundingClientRect();
  const listRect = list.getBoundingClientRect();
  if (optionRect.top < listRect.top) list.scrollTop -= listRect.top - optionRect.top;
  else if (optionRect.bottom > listRect.bottom) list.scrollTop += optionRect.bottom - listRect.bottom;
}

function openSelectionPicker() {
  if (!selectedPieces().length) return;
  closeSelectionMenu(false);
  closeSelectionPicker(false);
  const area = id('table-area');
  const picker = document.createElement('div');
  picker.className = 'selection-picker';
  picker.setAttribute('role', 'dialog');
  picker.setAttribute('aria-label', t('selection_assign'));
  picker.innerHTML = `<div class="selection-picker-head"><strong>${esc(t('selection_pick_task'))}</strong><button type="button" aria-label="${escAttr(t('selection_clear'))}" onclick="closeSelectionPicker()">×</button></div>
    <input type="search" role="combobox" aria-autocomplete="list" aria-expanded="true" aria-controls="selection-task-list" autocomplete="off" spellcheck="false" placeholder="${escAttr(t('selection_filter'))}" aria-label="${escAttr(t('selection_filter'))}">
    <div class="selection-picker-list" id="selection-task-list" role="listbox" aria-label="${escAttr(t('selection_pick_task'))}"></div>`;
  _selectionPickerReturn = document.activeElement;
  _selectionPicker = picker;
  area.appendChild(picker);
  renderSelectionTasks((D.tasks || []).map(entry => entry.task));
  const bar = id('selection-bar');
  const pageRect = area.closest('section').getBoundingClientRect();
  const barRect = bar.getBoundingClientRect();
  picker.style.width = `${Math.min(340, pageRect.width - 16)}px`;
  picker.style.maxHeight = `${Math.max(80, barRect.top - pageRect.top - 14)}px`;
  picker.style.left = `${Math.max(pageRect.left + 8, Math.min(barRect.left + (barRect.width - picker.offsetWidth) / 2,
    pageRect.right - picker.offsetWidth - 8))}px`;
  picker.style.top = `${Math.max(pageRect.top + 8, barRect.top - picker.offsetHeight - 6)}px`;
  const input = picker.querySelector('input');
  input.addEventListener('keydown', e => {
    if (e.isComposing || e.key === 'Process') return;
    if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); closeSelectionPicker(); return; }
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      e.preventDefault(); e.stopPropagation();
      highlightSelectionTask(_selectionPickerIndex + (e.key === 'ArrowDown' ? 1 : -1));
      return;
    }
    if (e.key === 'Enter') {
      e.preventDefault(); e.stopPropagation();
      picker.querySelectorAll('.selection-picker-list [role="option"]')[_selectionPickerIndex]?.click();
    }
  });
  input.addEventListener('input', () => {
    clearTimeout(_selectionSearchTimer);
    const q = input.value.trim();
    const seq = ++_selectionSearchSeq;
    if (!q) { renderSelectionTasks((D.tasks || []).map(entry => entry.task)); return; }
    // Old results must not take an Enter or a click meant for the new query.
    picker.querySelector('.selection-picker-list').replaceChildren();
    _selectionPickerIndex = -1;
    input.removeAttribute('aria-activedescendant');
    _selectionSearchTimer = setTimeout(async () => {
      try {
        const data = await apiJSON('GET', '/api/search?q=' + encodeURIComponent(q) + '&limit=25');
        if (seq === _selectionSearchSeq && _selectionPicker === picker) renderSelectionTasks((data.results || []).map(hit => hit.task).filter(Boolean));
      } catch (err) {
        if (seq !== _selectionSearchSeq || _selectionPicker !== picker) return;
        const list = picker.querySelector('.selection-picker-list');
        list.textContent = err.message;
      }
    }, 180);
  });
  input.focus();
}

async function assignSelectionToTask(task, snapshot = selectionSnapshot()) {
  if (!snapshot?.sources.length) return;
  const posted = snapshot.posted_tasks.has(task.id) || snapshot.pieces.some(p => snapshot.posted_tasks.has(p.s.task.id));
  try {
    await apiJSON('POST', '/api/intervals/selection', { op: 'assign', task: task.id, sources: snapshot.sources });
    clearSlotSelection();
    showToast(t('moved_to', { what: selectionRangeText(snapshot.from_ms, snapshot.to_ms), name: task.ref || task.title })
      + (posted ? ' ' + t('selection_posted_suffix') : ''));
    loadDay(selectedDate, { chart: true });
  } catch (err) {
    if (err.data?.error === 'Stale') {
      clearSlotSelection();
      showError(t('selection_stale'));
      loadDay(selectedDate, { chart: true });
    } else showError(err.data?.error === 'Overlap' ? t('move_overlap') : err.message);
  }
}

function noteInSelectedPiece(piece, at) {
  return piece.from <= at && (at < piece.to || (at === piece.to && piece.to === piece.s.end_ms));
}

function deleteSelectionReview(snapshot) {
  const lost = { notes: [], texts: [] };
  const details = [];
  for (const piece of snapshot.pieces) {
    const s = piece.s;
    if (piece.from === s.start_ms && s.text != null) {
      lost.texts.push({ interval: s.id, text: s.text });
      details.push(t('selection_lost_text', { time: fmtTime(s.start_ms), text: s.text }));
    }
    for (const n of s.notes.filter(n => noteInSelectedPiece(piece, n.at_ms)).sort((a, b) => a.at_ms - b.at_ms)) {
      lost.notes.push({ id: n.id, at_ms: n.at_ms, text: n.text });
      details.push(t('selection_lost_note', { time: fmtTime(n.at_ms), text: n.text }));
    }
    const remnants = [];
    if (s.start_ms < piece.from) remnants.push(selectionRangeText(s.start_ms, piece.from));
    if (piece.to < s.end_ms) remnants.push(selectionRangeText(piece.to, s.end_ms));
    const name = s.task.ref || s.task.title;
    details.push(`${name}: ${remnants.length ? t('selection_leaves', { ranges: remnants.join(', ') }) : t('selection_whole')}`);
  }
  if (snapshot.pieces.some(p => snapshot.posted_tasks.has(p.s.task.id))) details.push(t('selection_posted_warning'));
  return { lost, details };
}

async function deleteSelectedTime() {
  const snapshot = selectionSnapshot();
  if (!snapshot?.sources.length) return;
  const review = deleteSelectionReview(snapshot);
  const question = t('selection_delete_confirm', {
    range: selectionRangeText(snapshot.from_ms, snapshot.to_ms),
    duration: fmtMs(snapshot.ms),
    intervals: snapshot.pieces.length,
    intervals_label: selectionCountLabel('interval', snapshot.pieces.length),
  });
  if (!await askConfirm(question, t('confirm_delete'), true, { details: review.details, focusCancel: true })) return;
  try {
    await apiJSON('POST', '/api/intervals/selection', { op: 'delete', sources: snapshot.sources, lost: review.lost });
    clearSlotSelection();
    showToast(t('selection_deleted'));
    loadDay(selectedDate, { chart: true });
  } catch (err) {
    if (err.data?.error === 'ReviewChanged' || err.data?.error === 'Stale') {
      showError(t(err.data.error === 'ReviewChanged' ? 'selection_review_changed' : 'selection_stale'));
      loadDay(selectedDate, { chart: true });
    } else showError(err.message);
  }
}

async function copySelectedTime() {
  const snapshot = selectionSnapshot();
  if (!snapshot?.pieces.length) return;
  const lines = [];
  for (const piece of snapshot.pieces) {
    const s = piece.s;
    lines.push(`${selectionRangeText(piece.from, piece.to)}  ${fmtMs(piece.to - piece.from)}  ${s.task.ref || s.task.title}`);
    if (piece.from === s.start_ms && s.text) lines.push(`  ${fmtTime(s.start_ms)}  ${s.text.replace(/\r?\n/g, '\n  ')}`);
    for (const n of s.notes.filter(n => noteInSelectedPiece(piece, n.at_ms)).sort((a, b) => a.at_ms - b.at_ms)) {
      lines.push(`  ${fmtTime(n.at_ms)}  ${n.text.replace(/\r?\n/g, '\n  ')}`);
    }
  }
  lines.push(t('selection_total', { duration: fmtMs(snapshot.ms) }));
  try {
    await navigator.clipboard.writeText(lines.join('\n'));
    showToast(t('selection_copied'));
  } catch (err) { showError(t('selection_copy_failed', { error: err.message || String(err) })); }
}

// Toggle a block's note rows open/closed
function toggleBlock(hdr) {
  const grid = hdr.nextElementSibling;
  const tog  = hdr.querySelector('.block-toggle');
  const open = grid.classList.toggle('open');
  const blockId = Number(hdr.parentElement.id.slice(4));
  if (open) {
    _openBlocks.add(blockId);
    _openBlocks.delete(-blockId);
  } else {
    _openBlocks.delete(blockId);
    _openBlocks.add(-blockId);
  }
  tog.textContent = open ? '▾' : '▸';
}

// ── Note editing ──────────────────────────────────────────────────────────────
// Open note editors. A save re-renders the report only once no other editor
// is open, so a finished save never wipes a draft in progress.
let _noteEditors = 0;
let _reloadPending = false;
async function closeNoteEditor(saved) {
  _noteEditors = Math.max(0, _noteEditors - 1);
  if (saved) _reloadPending = true;
  if (_noteEditors > 0) return;
  if (_reloadPending) {
    _reloadPending = false;
    await loadDay(selectedDate, { chart: true });
  } else {
    renderReport(D);
  }
}

// Swaps `span` for a textarea editor. Ctrl+Enter or the button saves, Escape
// cancels, leaving the box saves; blank input clears the note.
function openNoteEditor(span, value, placeholder, commit) {
  const inp = document.createElement('textarea');
  inp.className   = 'slot-inp';
  inp.id          = span.id;
  inp.value       = value;
  inp.placeholder = placeholder;
  _noteEditors++;
  let done = false;
  const save = async () => {
    if (done) return;
    done = true;
    try {
      if (!await commit(inp.value.trim() ? inp.value : '')) { await closeNoteEditor(false); return; }
    } catch (e) {
      showError(e.message);
      done = false; // keep the editor and the text to fix or retry
      return;
    }
    await closeNoteEditor(true);
  };
  const cancel = () => {
    if (done) return;
    done = true;
    closeNoteEditor(false);
  };
  inp.onkeydown = e => {
    if (e.key === 'Enter' && e.ctrlKey) { e.preventDefault(); save(); }
    if (e.key === 'Escape') { e.preventDefault(); cancel(); }
  };
  inp.onblur = () => save();
  const btn = document.createElement('span');
  btn.className   = 'save-btn';
  btn.textContent = t('save');
  btn.onmousedown = e => { e.preventDefault(); save(); };
  const row = document.createElement('div');
  row.className = 'slot-edit';
  row.append(inp, btn);
  span.replaceWith(row);
  inp.focus();
  return inp;
}

// Edits a note's text; clearing it deletes the note.
function editNote(bi, noteId) {
  const s = _blockData[bi];
  const n = s?.notes.find(note => note.id === noteId);
  const span = id(`sn-${noteId}`);
  if (!n || !span || span.tagName === 'TEXTAREA') return;
  openNoteEditor(span, n.text, t('edit_note'), async value => {
    if (value === n.text) return false;
    if (!value) await apiJSON('POST', `/api/notes/${noteId}/delete`);
    else await apiJSON('PATCH', `/api/notes/${noteId}`, { text: value });
    return true;
  }).select();
}

// Adds a note in slot `k`: at the slot's start, kept inside the interval
// (the running slot takes the time it is saved).
function addNoteAt(bi, k) {
  const s = _blockData[bi];
  const span = id(`na-${s.id}-${k}`);
  if (!span || span.tagName === 'TEXTAREA') return;
  openNoteEditor(span, '', t('add_note'), async value => {
    if (!value) return false;
    const { first, end } = slotsOf(s);
    const slotStart = first + k * SLOT_MS;
    const live = s.end_ms == null && Date.now() + _skew < slotStart + SLOT_MS;
    const atMs = live ? Math.max(s.start_ms, Date.now() + _skew) : Math.min(end, Math.max(s.start_ms, slotStart));
    await apiJSON('POST', '/api/notes', { interval: s.id, at_ms: atMs, text: value });
    return true;
  });
}
