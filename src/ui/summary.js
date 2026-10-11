'use strict';
async function loadSummary(date) {
  const gen = ++_dayGen;
  try {
    const day = await apiJSON('GET', '/api/day?date=' + date);
    if (gen !== _dayGen) return;
    D = day;
    renderCards(D);
    if (D.summary) {
      renderSavedSummary(D.summary, date);
    } else {
      renderSummary(D);
    }
    id('chart-box').style.display = 'none';
  } catch (e) {
    if (gen === _dayGen) id('table-area').innerHTML = `<div class="empty">${esc(e.message)}</div>`;
  }
}

function buildSummaryWrap(content, isSaved) {
  const statusText = isSaved ? t('summary_saved_label') : '';
  return `<div class="summary-wrap">`
    + `<button class="summary-regen" onclick="regenerateSummary()" title="${t('summary_regen')}" aria-label="${t('summary_regen')}">${icon('refresh')}</button>`
    + `<textarea class="summary-area" id="summary-text" oninput="onSummaryInput()">${content}</textarea>`
    + `<span class="summary-status${isSaved ? '' : ' hidden'}" id="summary-status">${statusText}</span>`
    + `</div>`;
}

let _summaryAutoSaveTimer = null;
let _summaryDate = null;  // the day the textarea belongs to
let _summaryDraft = null; // {date, text}: typed, not yet sent
let _summaryQueue = Promise.resolve(); // writes run in order, so the newest text lands last

// Another day rendering sends the pending draft of the previous one first.
function prepareSummaryDate(date) {
  if (_summaryDraft && _summaryDraft.date !== date) flushSummary();
  _summaryDate = date;
}
// A reload of the same day shows the unsent draft, not the stored text.
function summaryShown(date, text) {
  return _summaryDraft && _summaryDraft.date === date ? _summaryDraft.text : text;
}
function onSummaryInput() {
  const st = id('summary-status');
  if (st) { st.classList.add('hidden'); }
  _summaryDraft = { date: _summaryDate, text: id('summary-text').value.trim() };
  clearTimeout(_summaryAutoSaveTimer);
  _summaryAutoSaveTimer = setTimeout(flushSummary, 1000);
}
function flushSummary() {
  clearTimeout(_summaryAutoSaveTimer);
  _summaryAutoSaveTimer = null;
  if (!_summaryDraft) return Promise.resolve();
  const { date, text } = _summaryDraft;
  _summaryDraft = null;
  return saveSummary(date, text);
}

function renderSavedSummary(text, date = selectedDate) {
  prepareSummaryDate(date);
  id('table-area').innerHTML = buildSummaryWrap(esc(summaryShown(date, text)), true);
}

function writeSummary(date, text) {
  const run = _summaryQueue.then(() => apiJSON('POST', '/api/summary', { date, text }));
  _summaryQueue = run.catch(() => {});
  return run;
}

async function saveSummary(date, text) {
  try {
    await writeSummary(date, text);
    if (_summaryDate !== date || _summaryDraft) return; // newer typing is still unsent
    const st = id('summary-status');
    if (st) { st.textContent = t('summary_saved_label'); st.classList.remove('hidden'); }
  } catch (e) { showError(e.message); }
}

async function regenerateSummary() {
  const date = _summaryDate;
  const day = D;
  clearTimeout(_summaryAutoSaveTimer);
  _summaryAutoSaveTimer = null;
  _summaryDraft = null; // regenerating discards the draft
  try {
    await writeSummary(date, '');
    // Another day or tab opened meanwhile: the cleared text shows when it is next loaded.
    if (_summaryDate !== date || activeTab !== 'summary' || D !== day) return;
    D.summary = null;
    renderSummary(D);
  } catch (e) { showError(e.message); }
}

function renderSummary(day) {
  const area = id('table-area');
  prepareSummaryDate(day.date || selectedDate);
  const intervals = (day.intervals || []).filter(s => s.role === 'focus')
    .sort((a, b) => a.start_ms - b.start_ms);
  if (!intervals.length) { area.innerHTML = `<div class="empty">${t('no_sessions')}</div>`; return; }

  const now = Date.now() + _skew; // the daemon's clock
  const tasks = new Map((day.tasks || []).map(entry => [String(entry.task.id), entry]));
  const taskInfo = s => {
    const task = s.task || {};
    const fields = (tasks.get(String(task.id))?.fields || []).map(f => f.value).filter(Boolean).join(' · ');
    return { task, fields: fields || t('summary_other'), ref: task.ref || '#' + task.id };
  };
  const fmtTimeShort = ms => fmtTime(ms);
  const fmtDurationMs = ms => fmtMins(Math.round(ms / 60000));
  // An interval crossing midnight counts only its part inside this day.
  const dayStart = day.start_ms ?? -Infinity;
  const dayEnd = day.end_ms ?? Infinity;
  const duration = s => Math.max(0, Math.min(s.end_ms ?? now, dayEnd) - Math.max(s.start_ms, dayStart));
  const hours = s => `${fmtTimeShort(s.start_ms)} – ${s.end_ms === null ? t('now') : fmtTimeShort(s.end_ms)}`;
  const notes = s => [
    ...(s.text ? [{ at_ms: s.start_ms, text: s.text }] : []),
    ...(s.notes || []),
  ].filter(n => n.text).sort((a, b) => a.at_ms - b.at_ms);

  let text = '';
  if (_summaryFormat === 'grouped') {
    const groups = new Map();
    intervals.forEach(s => {
      const info = taskInfo(s);
      if (!groups.has(info.fields)) groups.set(info.fields, { totalMs: 0, tasks: new Map() });
      const group = groups.get(info.fields);
      const key = String(info.task.id);
      if (!group.tasks.has(key)) {
        group.tasks.set(key, { ref: info.ref, title: info.task.title, durationMs: 0, intervals: [], notes: [] });
      }
      const task = group.tasks.get(key);
      task.durationMs += duration(s);
      group.totalMs += duration(s);
      task.intervals.push(hours(s));
      task.notes.push(...notes(s));
    });

    groups.forEach((group, name) => {
      text += `* ${name} — ${fmtDurationMs(group.totalMs)}\n`;
      group.tasks.forEach(task => {
        text += `  - [${task.ref}] ${task.title} (${fmtDurationMs(task.durationMs)})\n`;
        text += `    ↳ ${t('summary_hours')}: ${task.intervals.join(', ')}\n`;
        if (task.notes.length) text += `    ↳ ${t('summary_notes')}:\n`;
        task.notes.sort((a, b) => a.at_ms - b.at_ms).forEach(note => {
          note.text.split('\n').forEach((line, idx) => {
            text += `${idx === 0 ? '      - ' : '        '}${line}\n`;
          });
        });
      });
      text += '\n';
    });
  } else {
    // Chronological format
    intervals.forEach(s => {
      const info = taskInfo(s);
      const ref = info.task.ref || info.task.id;
      text += `${hours(s)} | ${fmtDurationMs(duration(s))} | ${info.fields} | #${ref} | ${info.task.title}\n`;
      notes(s).forEach(note => {
        const lines = note.text.split('\n');
        lines.forEach((line, idx) => {
          if (idx === 0) {
            text += `  - [${fmtTimeShort(note.at_ms)}] ${line}\n`;
          } else {
            text += `    ${line}\n`;
          }
        });
      });
      text += '\n';
    });
  }

  area.innerHTML = buildSummaryWrap(esc(summaryShown(_summaryDate, text.trim())), false);
}
