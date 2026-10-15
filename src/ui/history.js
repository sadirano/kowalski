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
function askConfirm(text, okLabel, danger = false) {
  if (_confirmDone) closeConfirm(false);
  id('confirm-text').textContent = text;
  const ok = id('confirm-ok');
  ok.textContent = okLabel;
  ok.classList.toggle('danger', danger);
  id('confirm-overlay').classList.add('show');
  id('confirm-popup').classList.add('show');
  setTimeout(() => ok.focus(), 50);
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
let _editProjectSnapshot = null;
let _editProjectEpoch = 0, _editProjectBusy = false;

function openEditTime(i) {
  ++_editProjectEpoch;
  const s = _blockData[i];
  _editBlock = { id: s.id, start_ms: s.start_ms, end_ms: s.end_ms, project_id: s.project_id };
  _editProjectSnapshot = null;
  id('edit-project-current').textContent = projectName(s.project_id);
  id('edit-project-target').innerHTML = projectOptions(s.project_id ?? 'unassigned');
  id('edit-project-target').value = s.project_id == null ? 'unassigned' : String(s.project_id);
  id('edit-project-result').innerHTML = '';
  id('edit-project-apply').disabled = true;
  id('edit-start').value = fmtClock(hhmm24(s.start_ms));
  id('edit-end').value = s.end_ms == null ? '' : fmtClock(hhmm24(s.end_ms));
  for (const el of [id('edit-start'), id('edit-end')]) el.classList.remove('bad');
  id('edit-end').disabled = s.end_ms == null;
  id('edit-overlay').classList.add('show');
  id('edit-popup').classList.add('show');
}

function closeEditTime() {
  ++_editProjectEpoch;
  id('edit-overlay').classList.remove('show');
  id('edit-popup').classList.remove('show');
  _editBlock = null;
  _editProjectSnapshot = null;
}

function clearEditProjectPreview() {
  ++_editProjectEpoch;
  _editProjectSnapshot = null;
  id('edit-project-result').innerHTML = '';
  id('edit-project-apply').disabled = true;
}

async function previewEditProject() {
  if (!_editBlock || _editProjectBusy) return;
  const s = _editBlock;
  const value = id('edit-project-target').value;
  const project_id = value === 'unassigned' ? null : Number(value);
  clearEditProjectPreview();
  const epoch = _editProjectEpoch;
  if (project_id === s.project_id) {
    id('edit-project-result').textContent = t('project_same');
    return;
  }
  try {
    const result = await apiJSON('POST', '/api/projects/assign/preview', { scope: { interval_ids: [s.id] }, project_id });
    if (_editBlock !== s || epoch !== _editProjectEpoch || id('edit-project-target').value !== value) return;
    if (result.skipped.length) {
      id('edit-project-result').textContent = t('project_skipped', { n: result.skipped.length });
      return;
    }
    if (result.snapshot.intervals.length !== 1) {
      id('edit-project-result').textContent = t('project_same');
      return;
    }
    _editProjectSnapshot = result.snapshot;
    id('edit-project-result').textContent = t('project_edit_preview', { from: projectName(s.project_id), to: projectName(project_id) });
    id('edit-project-apply').disabled = false;
  } catch (e) {
    if (_editBlock !== s || epoch !== _editProjectEpoch) return;
    id('edit-project-result').textContent = e.message;
  }
}

async function applyEditProject() {
  if (!_editBlock || !_editProjectSnapshot || _editProjectBusy) return;
  const s = _editBlock;
  const snapshot = _editProjectSnapshot;
  clearEditProjectPreview();
  _editProjectBusy = true;
  const epoch = _editProjectEpoch;
  try {
    await apiJSON('PATCH', '/api/intervals/' + s.id, { seen: seenOf(s), start_ms: s.start_ms,
      end_ms: s.end_ms, project_id: snapshot.project_id, snapshot });
    if (_editBlock === s) closeEditTime();
    showToast(t('project_applied', { n: 1 }));
    loadDay(selectedDate, { chart: true });
  } catch (e) {
    if (_editBlock !== s || epoch !== _editProjectEpoch) return;
    id('edit-project-result').textContent = e.status === 409 ? t('project_stale') : e.message;
  } finally {
    _editProjectBusy = false;
  }
}

async function applyEditTime() {
  if (_editBlock == null) return;
  const s = _editBlock;
  const startVal = parseClock(id('edit-start').value); // HH:MM or null
  const endVal   = parseClock(id('edit-end').value);   // HH:MM or null
  if (!startVal || (s.end_ms != null && !endVal)) {
    showError(t('ae_need_times'));
    return;
  }
  const start_ms = typedMs(startVal, s.start_ms);
  const end_ms = s.end_ms == null ? null : typedMs(endVal, s.end_ms);
  // The dialog stays open until the change is saved, so a refusal keeps what was typed.
  try {
    await apiJSON('PATCH', '/api/intervals/' + s.id, { seen: seenOf(s), start_ms, end_ms });
    if (_editBlock === s) closeEditTime();
    showToast(t('times_updated'));
    loadDay(selectedDate, { chart: true });
  } catch (e) {
    showError(e.message);
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
// A closed interval's header, or a run of its selected 15-minute slots,
// drags onto another task's card on the same day. A run cuts the interval:
// only that stretch moves. Times and notes stay; the report re-sorts on reload.
let _drag = null; // { bi, part: null | { from, to } }

function dragBlock(e, bi) {
  _drag = { bi, part: null };
  e.dataTransfer.effectAllowed = 'move';
  e.dataTransfer.setData('text/plain', String(bi));
  e.currentTarget.closest('.block').classList.add('dragging');
}

// Dragging a slot outside the selection selects just that slot first.
function dragSlots(e, bi, k) {
  e.stopPropagation();
  if (!(_slotSel?.bi === bi && k >= _slotSel.a && k <= _slotSel.b)) {
    _slotSel = { bi, a: k, b: k };
    markSlotSel();
  }
  _drag = { bi, part: slotRange(bi, _slotSel.a, _slotSel.b) };
  e.dataTransfer.effectAllowed = 'move';
  e.dataTransfer.setData('text/plain', String(bi));
}

function dragEndBlock() {
  _drag = null;
  document.querySelectorAll('.block.dragging').forEach(el => el.classList.remove('dragging'));
  document.querySelectorAll('.task-card.drop-target').forEach(el => el.classList.remove('drop-target'));
}

// Only another task's card accepts the drop.
function dropTask(idx) {
  const s = _drag && _blockData[_drag.bi];
  const task = _taskData[idx]?.task;
  return s && task && task.id !== s.task.id ? task : null;
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
  const s = _blockData[drag.bi];
  const body = { seen: seenOf(s), task: task.id };
  if (drag.part) { body.from_ms = drag.part.from; body.to_ms = drag.part.to; }
  try {
    await apiJSON('POST', '/api/intervals/' + s.id + '/move', body);
    const what = drag.part ? `${fmtTime(drag.part.from)}–${fmtTime(drag.part.to)}` : `${fmtTime(s.start_ms)}–${fmtTime(s.end_ms)}`;
    showToast(t('moved_to', { what, name: task.ref || task.title }));
  } catch (err) {
    showError(err.data?.error === 'Overlap' ? t('move_overlap') : err.message);
  }
  loadDay(selectedDate, { chart: true });
}
