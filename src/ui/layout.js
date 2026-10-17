'use strict';

// ── Layout: collapsible & resizable side panel + chart visibility ──────────────
function loadLS(key, def) {
  try { const v = localStorage.getItem('kw.' + key); return v === null ? def : JSON.parse(v); }
  catch { return def; }
}
function saveLS(key, val) {
  try { localStorage.setItem('kw.' + key, JSON.stringify(val)); } catch { /* private mode / quota */ }
}
// A panel never takes more than a third of the window so the day view fits
// when the window shrinks, even if a wider preference was stored.
function maxPanelW() { return Math.max(MIN_PANEL_W, Math.min(MAX_PANEL_W, Math.round(window.innerWidth / 3))); }
// sanitizeW bounds a stored preference; clampW additionally fits it to the
// current window. Only the latter reaches the DOM.
function sanitizeW(w) { w = parseInt(w, 10); if (isNaN(w)) w = 220; return Math.max(MIN_PANEL_W, Math.min(MAX_PANEL_W, w)); }
function clampW(w) { return Math.min(sanitizeW(w), maxPanelW()); }

// The clamp lives here, at render time, so the user's preferred width survives
// a temporary narrow window instead of being overwritten by it.
function applyLeftWidth() { document.documentElement.style.setProperty('--left-w', clampW(_leftWidth) + 'px'); }

function applyLeftCollapsed() {
  id('left-panel').classList.toggle('collapsed', _leftCollapsed);
}
function toggleLeftPanel() {
  _leftCollapsed = !_leftCollapsed;
  applyLeftCollapsed();
  const collapsed = _leftCollapsed;
  setPref('ui_left_collapsed', collapsed ? '1' : '0').catch(e => {
    showError(e.message);
    if (_leftCollapsed !== collapsed) return; // a later toggle owns the panel now
    _leftCollapsed = !collapsed;
    applyLeftCollapsed();
  });
  // If the sidebar booted collapsed, #week-nav never got its initial scroll to
  // today (it had no height); do it now that the list is visible again.
  if (!_leftCollapsed && _sidebarFirstRender) {
    const nav = id('week-nav');
    if (nav) nav.scrollTop = nav.scrollHeight;
    _sidebarFirstRender = false;
  }
}

// Drag-to-resize. Pointer events give touch support + capture for free, so the
// drag keeps tracking even if the cursor leaves the thin handle strip.
let _resize = null;
function startResize(e) {
  const panel = id('left-panel');
  if (panel.classList.contains('collapsed')) return; // nothing to resize
  e.preventDefault();
  // Start from the rendered width, not the stored preference: they differ when
  // the window is too narrow for the preference, and the drag would jump.
  _resize = { startX: e.clientX, startW: clampW(_leftWidth) };
  panel.classList.add('resizing'); // suppress the width transition mid-drag
  const h = e.currentTarget;
  h.classList.add('dragging');
  h.setPointerCapture?.(e.pointerId);
  h.addEventListener('pointermove', onResizeMove);
  h.addEventListener('pointerup', endResize);
  h.addEventListener('pointercancel', endResize);
}
function onResizeMove(e) {
  if (!_resize) return;
  const dx = e.clientX - _resize.startX;
  const w = clampW(_resize.startW + dx);
  _leftWidth = w; applyLeftWidth();
}
function endResize(e) {
  if (!_resize) return;
  id('left-panel').classList.remove('resizing');
  saveLS('leftWidth', _leftWidth);
  _resize = null;
  const h = e.currentTarget;
  h.classList.remove('dragging');
  h.releasePointerCapture?.(e.pointerId);
  h.removeEventListener('pointermove', onResizeMove);
  h.removeEventListener('pointerup', endResize);
  h.removeEventListener('pointercancel', endResize);
  if (chartInst) chartInst.resize(); // the content column width just changed
}

// The Timeline preference is a pixel width. Only the rendered width is fitted
// to the current grid, so a narrower window does not erase the preference.
let _rdWorkWidth = null;
let _rdResize = null;
function applyRdWorkWidth() {
  const grid = document.querySelector('.rd');
  if (!grid) return;
  const room = grid.clientWidth - 280 - 48;
  const wanted = _rdWorkWidth ?? Math.round(room * 0.4);
  const width = Math.max(360, Math.min(wanted, room - 480));
  grid.style.setProperty('--rd-work-w', width + 'px');
}
function startRdResize(e) {
  if (e.button !== 0) return;
  const grid = e.currentTarget.closest('.rd');
  e.preventDefault();
  _rdResize = { startX: e.clientX, startW: grid.querySelector('.rd-work').getBoundingClientRect().width };
  const h = e.currentTarget;
  h.classList.add('dragging');
  h.setPointerCapture?.(e.pointerId);
  h.addEventListener('pointermove', onRdResizeMove);
  h.addEventListener('pointerup', endRdResize);
  h.addEventListener('pointercancel', endRdResize);
}
function onRdResizeMove(e) {
  if (!_rdResize) return;
  const grid = e.currentTarget.closest('.rd');
  const room = grid.clientWidth - 280 - 48;
  _rdWorkWidth = Math.max(360, Math.min(_rdResize.startW - (e.clientX - _rdResize.startX), room - 480));
  applyRdWorkWidth();
}
function endRdResize(e) {
  if (!_rdResize) return;
  if (_rdWorkWidth !== null) saveLS('rdWorkW', _rdWorkWidth);
  _rdResize = null;
  const h = e.currentTarget;
  h.classList.remove('dragging');
  h.releasePointerCapture?.(e.pointerId);
  h.removeEventListener('pointermove', onRdResizeMove);
  h.removeEventListener('pointerup', endRdResize);
  h.removeEventListener('pointercancel', endRdResize);
  requestAnimationFrame(readerRefitMap);
}
function resetRdWorkWidth() {
  _rdWorkWidth = null;
  saveLS('rdWorkW', null);
  applyRdWorkWidth();
  requestAnimationFrame(readerRefitMap);
}

// Chart visibility — only meaningful in the report view, so the toggle button
// hides itself in the summary tab.
function updateChartToggleBtn() {
  const btn = id('chart-toggle');
  if (!btn) return;
  btn.style.display = activeTab === 'report' ? '' : 'none';
  btn.querySelector('span').textContent = t(_chartVisible ? 'menu_chart_hide' : 'menu_chart_show');
}
function toggleChartVisible() {
  _chartVisible = !_chartVisible;
  updateChartToggleBtn();
  if (activeTab === 'report') loadChart();
  const visible = _chartVisible;
  setPref('ui_chart_visible', visible ? '1' : '0').catch(e => {
    showError(e.message);
    if (_chartVisible !== visible) return; // a later toggle owns the chart now
    _chartVisible = !visible;
    updateChartToggleBtn();
    if (activeTab === 'report') loadChart();
  });
}

function initLayout() {
  _leftWidth     = sanitizeW(loadLS('leftWidth', 220));
  const rdWidth  = loadLS('rdWorkW', null);
  _rdWorkWidth   = Number.isFinite(rdWidth) ? Math.max(360, Math.round(rdWidth)) : null;
  _leftCollapsed = pref('ui_left_collapsed', '0') === '1';
  _chartVisible  = pref('ui_chart_visible', '1') === '1';
  applyLeftWidth();
  applyLeftCollapsed();
  updateChartToggleBtn();
  // Re-fit the panels when the window changes: the stored preference stays put,
  // only the rendered width follows.
  window.addEventListener('resize', () => {
    applyLeftWidth();
    applyRdWorkWidth();
    requestAnimationFrame(readerRefitMap);
  });
}

// ── Tabs ──────────────────────────────────────────────────────────────────────
// el is the clicked tab when a click got us here; the keyboard shortcuts pass
// only the name and let the tab be looked up by its data-tab.
function setTab(tab, el) {
  activeTab = tab;
  el = el || document.querySelector(`#main-tabs .tab[data-tab="${tab}"]`);
  document.querySelectorAll('#main-tabs .tab').forEach(t => t.classList.remove('active'));
  if (el) el.classList.add('active');
  updateChartToggleBtn(); // hide the chart toggle in the summary view
  loadDay(selectedDate, { chart: tab === 'report' });
}

