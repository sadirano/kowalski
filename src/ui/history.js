'use strict';
// ── Interval block delete / edit-time ────────────────────────────────────────
function seenOf(s) {
  return { start_ms: s.start_ms, end_ms: s.end_ms };
}

function typedMs(hhmm, anchorMs) {
  if (hhmm === hhmm24(anchorMs)) return anchorMs;
  const [h, m] = hhmm.split(':').map(Number);
  const d = new Date(anchorMs);
  d.setHours(h, m, 0, 0);
  return d.getTime();
}

// Asks in the page, never with a browser dialog. Resolves true on OK; a newer
// question answers the older one with false.
let _confirmDone = null;
function askConfirm(text, okLabel, danger = false, { details = [], focusCancel = false } = {}) {
  if (_confirmDone) closeConfirm(false);
  id('confirm-text').textContent = text;
  const list = id('confirm-details');
  list.replaceChildren();
  for (const detail of details) {
    const item = document.createElement('li');
    item.textContent = detail;
    list.appendChild(item);
  }
  list.hidden = !details.length;
  const ok = id('confirm-ok');
  ok.textContent = okLabel;
  ok.classList.toggle('danger', danger);
  id('confirm-overlay').classList.add('show');
  id('confirm-popup').classList.add('show');
  setTimeout(() => (focusCancel ? id('confirm-cancel') : ok).focus(), 50);
  return new Promise(resolve => { _confirmDone = resolve; });
}

function closeConfirm(yes) {
  id('confirm-overlay').classList.remove('show');
  id('confirm-popup').classList.remove('show');
  const done = _confirmDone;
  _confirmDone = null;
  if (done) done(yes);
}

async function mergeBlocks(i, j, gapMs = 0) {
  const a = _blockData[i];
  const b = _blockData[j];
  if (gapMs > 600000) {
    const mins = Math.round(gapMs / 60000);
    if (!await askConfirm(t('merge_gap_confirm', { m: mins }), t('confirm_merge'))) return;
  }
  try {
    await apiJSON('POST', '/api/intervals/merge', {
      first: { id: a.id, ...seenOf(a) },
      second: { id: b.id, ...seenOf(b) },
    });
    showToast(t('merged'));
    loadDay(selectedDate, { chart: true });
  } catch (e) {
    showError(e.message);
  }
}

async function deleteBlock(i) {
  const s = _blockData[i];
  if (!await askConfirm(t('delete_confirm'), t('confirm_delete'), true)) return;
  try {
    await apiJSON('POST', '/api/intervals/' + s.id + '/delete', { seen: seenOf(s) });
    showToast(t('deleted'));
    loadDay(selectedDate, { chart: true }); // refresh totals
  } catch (e) {
    showError(e.message);
  }
}

// The block as it was when the popup opened: a reload may reorder _blockData.
let _editBlock = null;
let _editProjectEpoch = 0, _editProjectBusy = false;

async function openEditTime(i) {
  const epoch = ++_editProjectEpoch;
  const s = _blockData[i];
  // No target until this dialog's picker is ready: Save must not act on the old one.
  _editBlock = null;
  id('edit-end-activity').style.display = s.captured && s.end_ms == null ? '' : 'none';
  id('edit-take-focus').style.display = s.role === 'parallel' ? '' : 'none';
  const current = () => epoch === _editProjectEpoch;
  try { if (!await setupProjectPicker(id('edit-project-filter'), id('edit-project-target'), s.project_id, current)) return; }
  catch (e) { if (current()) showError(e.message); return; }
  if (!current()) return;
  _editBlock = { id: s.id, start_ms: s.start_ms, end_ms: s.end_ms, project_id: s.project_id };
  const isOpen = s.end_ms == null;
  id('edit-project-filter').disabled = isOpen;
  id('edit-project-target').disabled = isOpen;
  id('edit-project-open-hint').hidden = !isOpen;
  id('edit-start').value = fmtClock(hhmm24(s.start_ms));
  id('edit-end').value = s.end_ms == null ? '' : fmtClock(hhmm24(s.end_ms));
  for (const el of [id('edit-start'), id('edit-end')]) el.classList.remove('bad');
  id('edit-end').disabled = s.end_ms == null;
  id('edit-overlay').classList.add('show');
  id('edit-popup').classList.add('show');
}

async function applyIntervalAction(action) {
  if (!_editBlock) return;
  const s = _editBlock;
  try {
    await apiJSON('POST', '/api/intervals/' + s.id + '/' + action, { seen: seenOf(s) });
    if (_editBlock === s) closeEditTime();
    loadDay(selectedDate, { chart: true });
    loadCurrent();
  } catch (e) { showError(e.message); }
}

function closeEditTime() {
  ++_editProjectEpoch;
  id('edit-overlay').classList.remove('show');
  id('edit-popup').classList.remove('show');
  _editBlock = null;
}

async function applyEditTime() {
  if (_editBlock == null || _editProjectBusy) return;
  const s = _editBlock;
  const startVal = parseClock(id('edit-start').value); // HH:MM or null
  const endVal   = parseClock(id('edit-end').value);   // HH:MM or null
  if (!startVal || (s.end_ms != null && !endVal)) {
    showError(t('ae_need_times'));
    return;
  }
  const start_ms = typedMs(startVal, s.start_ms);
  const end_ms = s.end_ms == null ? null : typedMs(endVal, s.end_ms);
  const project_id = s.end_ms == null ? s.project_id : pickedProject(id('edit-project-target'));
  // The dialog stays open until the change is saved, so a refusal keeps what was typed.
  _editProjectBusy = true;
  try {
    const body = { seen: seenOf(s), start_ms, end_ms };
    if (s.end_ms != null && project_id !== s.project_id) {
      const preview = await apiJSON('POST', '/api/projects/assign/preview', { scope: { interval_ids: [s.id] }, project_id });
      if (_editBlock !== s || pickedProject(id('edit-project-target')) !== project_id ||
          parseClock(id('edit-start').value) !== startVal || parseClock(id('edit-end').value) !== endVal) return;
      if (preview.snapshot.intervals.length !== 1) throw { status: 409 };
      body.project_id = project_id;
      body.snapshot = preview.snapshot;
    }
    if (_editBlock !== s) return;
    await apiJSON('PATCH', '/api/intervals/' + s.id, body);
    if (_editBlock === s) closeEditTime();
    showToast(project_id !== s.project_id ? t('project_applied', { n: 1 }) : t('times_updated'));
    loadDay(selectedDate, { chart: true });
  } catch (e) {
    if (_editBlock === s) showError(e.status === 409 ? t('project_stale') : e.message);
  } finally {
    _editProjectBusy = false;
  }
}

// ── Add a past entry (manual interval via POST /api/intervals) ───────────────
function showAddEntry() {
  setAEDate((selectedDate && selectedDate.length === 10) ? selectedDate : todayStr());
  for (const [k, hint] of [['ae-start', '09:00'], ['ae-end', '12:00']]) {
    id(k).value = '';
    id(k).placeholder = fmtClock(hint);
    id(k).classList.remove('bad');
  }
  id('ae-ref').value = '';
  id('ae-title').value = '';
  id('addentry-overlay').classList.add('show');
  id('addentry-popup').classList.add('show');
  setTimeout(() => id(provider ? 'ae-ref' : 'ae-title').focus(), 0);
}

// The entry's day, picked on the dashboard's own calendar.
function setAEDate(date) {
  id('ae-date').dataset.value = date;
  id('ae-date-text').textContent = new Date(date + 'T12:00:00')
    .toLocaleDateString(locale(), { weekday: 'short', day: 'numeric', month: 'short', year: 'numeric' });
}

function pickAEDate() { showCalendar({ date: id('ae-date').dataset.value, onPick: setAEDate }); }

function hideAddEntry() {
  id('addentry-overlay').classList.remove('show');
  id('addentry-popup').classList.remove('show');
}

async function applyAddEntry() {
  const date = id('ae-date').dataset.value; // YYYY-MM-DD
  const sVal = parseClock(id('ae-start').value); // HH:MM or null
  const eVal = parseClock(id('ae-end').value);   // HH:MM or null
  const ref = id('ae-ref').value.trim();
  const title = id('ae-title').value.trim();
  if (!date) {
    showError(t('ae_need_date'));
    return;
  }
  if (!ref && !title) {
    showError(t('ae_need_task'));
    return;
  }
  if (!sVal || !eVal) {
    showError(t('ae_need_times'));
    return;
  }

  // Build millisecond timestamps from the chosen date and local times.
  const start_ms = new Date(date + 'T' + sVal + ':00').getTime();
  const end_ms = new Date(date + 'T' + eVal + ':00').getTime();
  if (!Number.isFinite(start_ms) || !Number.isFinite(end_ms) || end_ms <= start_ms) {
    showError(t('ae_need_times'));
    return;
  }

  try {
    const task = await taskFor(ref, title);
    await apiJSON('POST', '/api/intervals', { task: '#' + task.id, role: 'focus', start_ms, end_ms });
    hideAddEntry();
    if (task.lookupError) showError(t('ref_unconfirmed', { ref, e: task.lookupError }));
    else showToast(t('ae_added'));
    goToDate(date, { chart: true }); // jump to (and refresh) the day the entry landed on
  } catch (e) {
    showError(t('ae_failed') + ': ' + e.message);
  }
}

// ── Move an interval to another task by dragging ─────────────────────────────
// Headers drag one full interval; a selected slot drags the whole clock range.
let _drag = null; // { snapshot }

function dragBlock(e, bi) {
  const s = _blockData[bi];
  if (!s || s.end_ms == null) return;
  _drag = { snapshot: {
    pieces: [{ s, from: s.start_ms, to: s.end_ms }],
    sources: [{ id: s.id, seen: seenOf(s), ranges: [[s.start_ms, s.end_ms]] }],
    from_ms: s.start_ms, to_ms: s.end_ms,
    posted_tasks: new Set(D.posted_tasks || []),
  } };
  e.dataTransfer.effectAllowed = 'move';
  e.dataTransfer.setData('text/plain', String(s.id));
  e.currentTarget.closest('.block').classList.add('dragging');
}

// Dragging a slot outside the selection selects just that slot first.
function dragSlots(e, bi, k) {
  e.stopPropagation();
  if (!e.currentTarget.closest('.slot-row').classList.contains('sel')) selectSlot({ stopPropagation() {}, shiftKey: false }, bi, k);
  const snapshot = selectionSnapshot();
  if (!snapshot?.sources.length) return;
  _drag = { snapshot };
  e.dataTransfer.effectAllowed = 'move';
  e.dataTransfer.setData('text/plain', String(_blockData[bi].id));
}

function dragEndBlock() {
  _drag = null;
  document.querySelectorAll('.block.dragging').forEach(el => el.classList.remove('dragging'));
  document.querySelectorAll('.task-card.drop-target').forEach(el => el.classList.remove('drop-target'));
}

// Only another task's card accepts the drop.
function dropTask(idx) {
  const task = _taskData[idx]?.task;
  return _drag?.snapshot?.sources.length && task && _drag.snapshot.pieces.some(p => p.s.task.id !== task.id) ? task : null;
}

function dragOverTask(e, idx) {
  if (!_drag || !dropTask(idx)) return;
  e.preventDefault();
  e.dataTransfer.dropEffect = 'move';
  e.currentTarget.classList.add('drop-target');
}

function dragLeaveTask(e) {
  if (!e.currentTarget.contains(e.relatedTarget)) e.currentTarget.classList.remove('drop-target');
}

async function dropOnTask(e, idx) {
  e.preventDefault();
  const drag = _drag;
  const task = dropTask(idx);
  dragEndBlock();
  if (!task) return;
  await assignSelectionToTask(task, drag.snapshot);
}
