'use strict';
// ── View options ──────────────────────────────────────────────────────────────
// Preferences live beside the view they change (docs/settings.md): a small
// popover per view, saved as soon as a control changes.

const PREF_VIEWS = {
  sidebar: () => [
    { key: 'ui_sidebar_days', label: 'set_sidebar', kind: 'days', fallback: '7' },
    { key: 'ui_day_order', label: 'set_day_order', kind: 'choice', fallback: 'oldest',
      options: [['oldest', 'day_order_oldest'], ['newest', 'day_order_newest']] },
    { key: 'ui_show_weekends', label: 'set_show_weekends', kind: 'flag', fallback: '1' },
  ],
  report: () => [
    { key: 'ui_report_layout', label: 'set_report_layout', kind: 'choice', fallback: 'classic',
      options: [['classic', 'report_layout_classic'], ['grid', 'report_layout_grid']] },
    { key: 'ui_task_order', label: 'set_task_order', kind: 'choice', fallback: 'time',
      options: [['time', 'task_order_time'], ['ref', 'task_order_ref'], ['added', 'task_order_added']] },
  ],
  chart: () => {
    const hidden = chartHiddenGroups();
    return (provider?.fields || []).slice().sort((a, b) => a.order - b.order).map(f => ({
      group: f.name, text: providerLabel(f), kind: 'tab', checked: !hidden.includes(f.name),
    }));
  },
  summary: () => [
    { key: 'ui_summary_format', label: 'set_summary_format', kind: 'choice', fallback: 'grouped',
      options: [['grouped', 'summary_grouped'], ['chronological', 'summary_chrono']] },
  ],
};

// Whether a view has anything to choose; the chart's tabs come from the provider.
function hasPrefs(view) { return PREF_VIEWS[view]().length > 0; }

function prefButton(view) {
  return `<button type="button" class="icon-btn pref-btn" onclick="togglePrefMenu(this,'${view}')"`
    + ` title="${escAttr(t('view_options'))}" aria-label="${escAttr(t('view_options'))}" aria-haspopup="true">${icon('gear')}</button>`;
}

let _prefView = null;

function togglePrefMenu(btn, view) {
  const menu = id('pref-menu');
  if (_prefView === view && menu.classList.contains('show')) { hidePrefMenu(); return; }
  _prefView = view;
  renderPrefMenu();
  const r = btn.getBoundingClientRect();
  menu.classList.add('show');
  const left = Math.min(r.left, window.innerWidth - menu.offsetWidth - 8);
  menu.style.left = Math.max(8, left) + 'px';
  menu.style.top = (r.bottom + 4) + 'px';
}

function hidePrefMenu() {
  id('pref-menu').classList.remove('show');
  _prefView = null;
}

function renderPrefMenu() {
  const rows = PREF_VIEWS[_prefView]().map((p, i) => {
    if (p.kind === 'tab') return `<label class="pref-row"><span>${esc(p.text)}</span>`
      + `<input type="checkbox" class="sw" data-group="${escAttr(p.group)}"${p.checked ? ' checked' : ''} onchange="saveChartTabs()"></label>`;
    const value = pref(p.key, p.fallback);
    const ctl = p.kind === 'flag'
      ? `<input type="checkbox" class="sw" id="pref-${i}"${value === '1' ? ' checked' : ''} onchange="savePref(${i},this.checked?'1':'0')">`
      : p.kind === 'days'
        ? `<input type="number" class="n" id="pref-${i}" min="1" max="90" value="${escAttr(value)}" onchange="savePref(${i},this.value)">`
        : `<select id="pref-${i}" onchange="savePref(${i},this.value)">${p.options.map(([v, k]) =>
          `<option value="${v}"${v === value ? ' selected' : ''}>${esc(t(k))}</option>`).join('')}</select>`;
    return `<label class="pref-row" for="pref-${i}"><span>${esc(t(p.label))}</span>${ctl}</label>`;
  }).join('');
  const hint = _prefView === 'chart' ? `<small class="pref-hint">${esc(t('set_chart_tabs_hint'))}</small>` : '';
  id('pref-menu').innerHTML = `<div class="pref-title">${esc(t(_prefView === 'chart' ? 'set_chart_tabs' : 'view_options'))}</div>${rows}${hint}`;
}

async function savePref(i, value) {
  const p = PREF_VIEWS[_prefView]()[i];
  if (p.kind === 'days') {
    const n = parseInt(value, 10);
    value = String(Math.min(90, Math.max(1, Number.isFinite(n) ? n : parseInt(p.fallback, 10))));
  }
  try {
    await setPref(p.key, value);
    applyPrefs();
    afterPrefChange(_prefView);
  } catch (e) { showError(e.message); }
}

async function saveChartTabs() {
  const off = [...id('pref-menu').querySelectorAll('input[data-group]:not(:checked)')].map(el => el.dataset.group);
  try {
    await setPref('ui_chart_hidden', JSON.stringify(off));
    renderChartGroups();
    loadChart();
  } catch (e) { showError(e.message); }
}

function afterPrefChange(view) {
  if (view === 'sidebar') loadDay(selectedDate, { chart: true });
  else loadDay(selectedDate);
}

document.addEventListener('pointerdown', e => {
  if (!_prefView) return;
  if (e.target.closest('#pref-menu') || e.target.closest('.pref-btn')) return;
  hidePrefMenu();
});
document.addEventListener('keydown', e => { if (e.key === 'Escape' && _prefView) hidePrefMenu(); });
