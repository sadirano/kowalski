'use strict';
// ── Task search (Feature 7: find a task by any text that identifies it) ────────
// Type anything that identifies a task — ref, title, field, or note — and the dropdown lists matching tasks
// with the days they were worked on. Picking a hit opens its most recent day
// (or the day chip clicked) on that task: the Timeline reads it and the report
// marks its card; ▶ switches the tracker to it. Ctrl+K focuses the field from anywhere.
let _searchHits  = [];
let _searchSel   = -1;
let _searchTimer = null;
let _searchedQ   = null; // the query the hits answer
let _searchSeq   = 0; // guards a slow response from overwriting a newer one
let _searchFound = null; // { task, date }: the hit opened, marked on that day's report

function onSearchInput() {
  const q = id('task-search').value.trim();
  id('search-clear').style.display = q ? '' : 'none';
  clearTimeout(_searchTimer);
  if (!q) { _searchSeq++; _searchedQ = null; _searchHits = []; _searchSel = -1; closeSearch(); return; }
  _searchTimer = setTimeout(() => runSearch(q), 220); // debounce keystrokes
}

function onSearchFocus() {
  if (id('task-search').value.trim() && _searchHits.length) openSearch();
}

async function runSearch(q) {
  const seq = ++_searchSeq;
  let hits = [];
  try { hits = (await apiJSON('GET', '/api/search?q=' + encodeURIComponent(q) + '&limit=25')).results || []; }
  catch (err) {
    if (seq !== _searchSeq) return false;
    _searchHits = [];
    _searchSel = -1;
    id('search-results').innerHTML = `<div class="sr-msg hr-err">${esc(err.message)}</div>`;
    openSearch();
    return false;
  }
  if (seq !== _searchSeq) return false; // a newer keystroke already answered
  _searchedQ = q;
  _searchHits = Array.isArray(hits) ? hits : [];
  _searchSel  = _searchHits.length ? 0 : -1;
  renderSearch();
  openSearch();
  return true;
}

function renderSearch() {
  const box = id('search-results');
  if (!box) return;
  const q = id('task-search').value.trim();
  if (!_searchHits.length) {
    box.innerHTML = `<div class="sr-msg">${esc(t('search_none', { q }))}</div>` + newTaskRow(q);
    return;
  }
  const rows = _searchHits.map((h, i) => {
    const days   = h.days || [];
    const nDays  = h.day_count || days.length;
    const fields = (h.fields || []).map(f => f.value).filter(Boolean);
    const env    = fields.map(v => `<span class="sr-env">${esc(v)}</span>`).join('');
    const sub    = [...fields, ...(h.task.ref ? [h.task.title] : [])].map(esc).join(' · ');
    const snip   = h.snippet ? `<div class="sr-snip">${esc(h.snippet)}</div>` : '';
    const hidden = nDays - days.length;
    const chips  = days.map(d =>
      `<span class="sr-day" title="${escAttr(t('search_open_day', { d: d.date }))} · ${fmtMs(d.total_ms)}"
             onclick="event.stopPropagation();searchGoDay(${i},'${d.date}')">${esc(shortDate(d.date))}</span>`).join('')
      + (hidden > 0 ? `<span class="sr-day more">+${hidden}</span>` : '');
    const start = `<button class="sr-go" title="${escAttr(t('search_switch'))}"
      onclick="event.stopPropagation();searchSwitch(${i})">▶</button>`;
    return `<div class="sr-item${i === _searchSel ? ' sel' : ''}" onclick="searchOpen(${i})" onmousemove="searchHover(${i})">
      <div class="sr-top">
        <span class="sr-ref">${h.task.ref ? refLink(h.task.ref) : esc(h.task.title)}</span>${env}
        <span class="sr-total">${fmtMs(h.total_ms)} · ${esc(t('search_days', { n: nDays }))}</span>
        ${start}
      </div>
      ${sub ? `<div class="sr-sub">${sub}</div>` : ''}
      ${snip}
      <div class="sr-days">${chips}</div>
    </div>`;
  }).join('');
  box.innerHTML = rows + newTaskRow(q) + `<div class="sr-foot">${esc(t('search_hint'))}</div>`;
}

// Offer a new task when the query does not exactly identify an existing one.
function newTaskRow(q) {
  if (!q || _searchHits.some(h => h.task.ref === q || h.task.title.toLowerCase() === q.toLowerCase())) return '';
  const label = provider && !/\s/.test(q) ? t('search_new', { q }) : t('search_new_title', { q });
  return `<div class="sr-item sr-new" onclick="searchNewTask()">
    <div class="sr-top"><span class="sr-new-txt">${esc(label)}</span></div>
  </div>`;
}

function searchNewTask() {
  const q = id('task-search').value.trim();
  closeSearch();
  showNewTask(provider && !/\s/.test(q) ? { ref: q } : { title: q });
}

function searchHover(i) {
  if (i !== _searchSel) { _searchSel = i; markSearchSel(false); }
}

// markSearchSel repaints the highlight without rebuilding the list, so hovering
// and arrowing through results stay cheap.
function markSearchSel(scroll) {
  const items = document.querySelectorAll('#search-results .sr-item');
  items.forEach((el, i) => el.classList.toggle('sel', i === _searchSel));
  if (scroll && items[_searchSel]) items[_searchSel].scrollIntoView({ block: 'nearest' });
}

async function onSearchKey(e) {
  if (e.key === 'Escape') {
    e.preventDefault();
    if (isSearchOpen()) closeSearch(); else clearSearch();
    return;
  }
  if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
    if (!_searchHits.length) return;
    e.preventDefault();
    const step = e.key === 'ArrowDown' ? 1 : -1;
    _searchSel = (_searchSel + step + _searchHits.length) % _searchHits.length;
    openSearch();
    markSearchSel(true);
    return;
  }
  if (e.key === 'Enter') {
    e.preventDefault();
    clearTimeout(_searchTimer);
    const q = id('task-search').value.trim();
    // Answer for what is typed now, so Enter never starts a task that exists.
    if (q && _searchedQ !== q && !await runSearch(q)) return;
    if (!_searchHits.length) {
      if (newTaskRow(q)) searchNewTask();
      return;
    }
    // Ctrl/Shift+Enter starts the task; a plain Enter just opens its latest day.
    if (e.ctrlKey || e.shiftKey) searchSwitch(_searchSel);
    else searchOpen(_searchSel);
  }
}

function searchOpen(i) {
  const h = _searchHits[i];
  // The most recent day this task was focused on; a task with only parallel
  // time opens on the shown day when it is there, else has no day to open.
  const date = h?.last_date || (h && D?.tasks?.some(e => e.task.id === h.task.id) ? selectedDate : null);
  if (!date) return;
  return searchGoDay(i, date);
}

// Opens a day on a hit's task: the Timeline reads it, and the report marks and
// scrolls to its card.
async function searchGoDay(i, date) {
  const h = _searchHits[i];
  closeSearch();
  if (!h) return goToDate(date);
  _searchFound = { task: h.task.id, date };
  _readerTask = h.task.id;
  _readerSitting = 0;
  _readerPin = null;
  saveLS('readerTask', h.task.id);
  await goToDate(date);
  if (activeTab === 'report') document.querySelector(`.task-card[data-task="${h.task.id}"]`)?.scrollIntoView({ block: 'start' });
}

// The task card a search opened, while its day is shown.
function isSearchFound(taskId) {
  return _searchFound?.task === taskId && _searchFound.date === selectedDate;
}

async function searchSwitch(i) {
  const h = _searchHits[i];
  if (!h) return;
  closeSearch();
  await switchToTask(h.task);
}

function isSearchOpen() { return id('search-results').classList.contains('show'); }
function openSearch()   { id('search-results').classList.add('show'); }
function closeSearch()  { id('search-results').classList.remove('show'); }

function clearSearch() {
  clearTimeout(_searchTimer);
  _searchSeq++; // discard any in-flight response
  _searchedQ = null;
  _searchHits = [];
  _searchSel  = -1;
  _searchFound = null;
  id('task-search').value = '';
  id('search-clear').style.display = 'none';
  closeSearch();
}

function focusSearch() {
  const inp = id('task-search');
  if (!inp) return;
  inp.focus();
  inp.select();
  if (_searchHits.length) openSearch();
}

// A click anywhere outside the box dismisses the results (the input keeps its
// text, so refocusing brings them straight back).
document.addEventListener('click', e => {
  if (!e.target.closest || !e.target.closest('.search-box')) closeSearch();
});

