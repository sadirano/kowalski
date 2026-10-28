'use strict';
// ── Chart ─────────────────────────────────────────────────────────────────────
// Distinct palette. With more series than colours a colour repeats; pointing
// at a row of the list beside the chart tells them apart.
const CHART_PALETTE = [
  '#4f8ef7','#f97316','#22c55e','#a855f7','#ec4899',
  '#14b8a6','#eab308','#ef4444','#06b6d4','#84cc16',
];

// A series keeps its colour across ranges and tabs: the colour comes from its
// identity, moving to the next free one when two series collide, until every
// colour is taken once.
function chartColors(keys) {
  const used = new Set();
  return keys.map(key => {
    if (used.size === CHART_PALETTE.length) used.clear();
    let h = 0;
    for (const ch of key) h = (h * 31 + ch.codePointAt(0)) | 0;
    let k = Math.abs(h) % CHART_PALETTE.length;
    for (let n = 0; n < CHART_PALETTE.length && used.has(k); n++) k = (k + 1) % CHART_PALETTE.length;
    used.add(k);
    return CHART_PALETTE[k];
  });
}

// Every series with time in the range, biggest first, each with its colour.
function rankSeries(series) {
  const ranked = series.map(s => ({ ...s,
    key: chartGroupBy === '@project' ? s.project_id == null ? 'unassigned' : 'project:' + s.project_id : s.label,
    label: chartGroupBy === '@project' ? projectName(s.project_id) : s.label,
    total: s.ms.reduce((a, b) => a + b, 0) }))
    .filter(s => s.total > 0).sort((a, b) => b.total - a.total);
  const colors = chartColors(ranked.map(s => s.key));
  ranked.forEach((s, i) => { s.color = colors[i]; });
  return ranked;
}

// Series hidden from the chart by a click in the list, by identity; kept while
// the range changes and cleared when the grouping does.
const _chartHidden = new Set();
let _chartRanked = [];
let _chartDates = [];
let _lastChartData = null;
let _lastDrawKey = null;

function isSameChartData(a, b) {
  if (!a || !b || a.dates?.length !== b.dates?.length || a.series?.length !== b.series?.length) return false;
  if (a.dates.some((d, i) => d !== b.dates[i])) return false;
  return a.series.every((s1, i) => {
    const s2 = b.series[i];
    return s1.label === s2.label && s1.project_id === s2.project_id && s1.ms?.length === s2.ms?.length
      && s1.ms.every((ms, j) => ms === s2.ms[j]);
  });
}

function renderChart(data) {
  if (!data?.dates?.length) {
    _lastChartData = null;
    if (chartInst) { chartInst.destroy(); chartInst = null; }
    id('chart-legend').innerHTML = '';
    id('chart-lanes').innerHTML = '';
    return;
  }
  // The same data drawn the same way only moves the selected day.
  const drawKey = JSON.stringify([chartView, chartGroupBy, _hideWeekends, S?.daily_work_minutes ?? null,
    (projects || []).map(p => p.label)]);
  if (_lastChartData && chartInst && drawKey === _lastDrawKey && isSameChartData(data, _lastChartData)) {
    updateChartSelectedDay(selectedDate);
    return;
  }
  _lastChartData = data;
  _lastDrawKey = drawKey;
  if (!TOUR) saveLS('chartCache', { days: chartDays, group: chartGroupBy, data });
  id('chart-legend').innerHTML = '';
  id('chart-lanes').innerHTML = '';

  let { dates, series } = data;
  // Drop weekend columns when hidden. dates[] and every series' ms[] are
  // parallel arrays, so the same indices must be removed from all of them.
  if (_hideWeekends) {
    const keep = dates.map(d => !isWeekend(d));
    dates = dates.filter((_, i) => keep[i]);
    series = (series || []).map(s => ({ ...s, ms: s.ms.filter((_, i) => keep[i]) }));
  }
  _chartDates = dates;
  _chartRanked = rankSeries(series || []);
  const lanes = chartView === 'lanes';
  id('chart-box').classList.toggle('lanes', lanes);
  document.querySelectorAll('#chart-views button').forEach(b => b.classList.toggle('active', b.dataset.view === chartView));
  if (lanes) renderLanes(); else renderBars();
  renderChartList();
}

function renderBars() {
  // Stacked bars, biggest series at the bottom, the selected day bright and a
  // dashed line at the daily target; one canvas, kept across renders.
  if (!chartInst) chartInst = new BuiltinBarChart(id('chart'));
  chartInst.setData({
    dates: _chartDates,
    ranked: _chartRanked,
    selectedDate,
    dailyTargetHours: (S?.daily_work_minutes || 0) / 60,
    hiddenSet: _chartHidden,
  });
}

// Task lanes: one row per series, one cell per day, brighter for more hours;
// a click on a cell opens that day.
function renderLanes() {
  const dates = _chartDates;
  const rows = _chartRanked.filter(s => !_chartHidden.has(s.key));
  const max = Math.max(1, ...rows.flatMap(s => s.ms));
  const step = Math.max(1, Math.round(dates.length / 10));
  const cols = `minmax(120px,220px) repeat(${dates.length},minmax(3px,1fr)) auto`;
  const head = `<span></span>${dates.map((d, j) => `<span class="lane-ax${d === selectedDate ? ' sel' : ''}">${j % step === 0 ? esc(shortDate(d)) : ''}</span>`).join('')}<span></span>`;
  const body = rows.map(s => `<span class="lane-lbl" title="${escAttr(s.label)}">${esc(s.label)}</span>`
    + s.ms.map((ms, j) => {
      const shade = ms ? s.color + Math.round(56 + 199 * Math.min(1, ms / max)).toString(16).padStart(2, '0') : '';
      return `<i class="lane-c${ms ? '' : ' none'}${dates[j] === selectedDate ? ' sel' : ''}"${shade ? ` style="background:${shade}"` : ''}`
        + ` title="${escAttr(shortDate(dates[j]) + (ms ? ' · ' + fmtMs(ms) : ''))}" onclick="goToDate('${dates[j]}')"></i>`;
    }).join('')
    + `<b class="lane-tot">${esc(fmtMs(s.total))}</b>`).join('');
  id('chart-lanes').innerHTML = `<div class="lanes-grid" style="grid-template-columns:${cols}">${head}${body}</div>`;
}

// Pointing at a list row keeps that series bright and fades the rest.
function focusChartSeries(key) {
  if (chartInst) chartInst.focusSeries(key);
}

// A day was selected in the sidebar or calendar; move the highlight on the
// visible bars or lanes without refetching the range.
function updateChartSelectedDay(date) {
  if (!_chartDates?.length) {
    if (_lastChartData) renderChart(_lastChartData);
    return;
  }
  if (chartView === 'lanes') { renderLanes(); return; }
  if (chartInst) chartInst.setSelectedDate(date);
}

// The list beside the bars: every series in the range, biggest first, with
// its hours, share and a bar to scale. A click hides or shows that series.
function renderChartList() {
  const box = id('chart-legend');
  const grand = _chartRanked.reduce((n, s) => n + s.total, 0);
  const top = _chartRanked[0]?.total || 1;
  box.innerHTML = _chartRanked.map((s, i) => {
    const off = _chartHidden.has(s.key);
    return `<button type="button" class="rank-row${off ? ' off' : ''}" title="${escAttr(s.label)}"`
      + ` onclick="toggleChartSeries(${i})" onmouseenter="focusChartSeries(_chartRanked[${i}].key)" onmouseleave="focusChartSeries(null)"`
      + ` onfocus="focusChartSeries(_chartRanked[${i}].key)" onblur="focusChartSeries(null)" aria-pressed="${!off}">`
      + `<span>${esc(s.label)}</span><b>${esc(fmtMs(s.total))} · ${Math.round(100 * s.total / grand)}%</b>`
      + `<em><i style="width:${(100 * s.total / top).toFixed(1)}%;background:${s.color}"></i></em></button>`;
  }).join('');
}

function toggleChartSeries(i) {
  const s = _chartRanked[i];
  if (!s) return;
  if (_chartHidden.has(s.key)) _chartHidden.delete(s.key); else _chartHidden.add(s.key);
  renderChartList();
  if (chartView === 'lanes') { renderLanes(); return; }
  if (chartInst) chartInst.toggleSeries(_chartHidden);
}

function setChartView(view) {
  chartView = view;
  setPref('ui_chart_view', view).catch(e => showError(e.message));
  loadChart();
}

// Provider fields the user turned off as chart tabs (Settings > Display).
function chartHiddenGroups() {
  try { const v = JSON.parse(pref('ui_chart_hidden', '[]')); return Array.isArray(v) ? v : []; }
  catch { return []; }
}

function renderChartGroups() {
  const hidden = chartHiddenGroups();
  // A provider field labelled like a core grouping says whose it is.
  const core = [t('g_task'), t('project')];
  const groups = [{ name: 'task', label: t('g_task') }, { name: '@project', label: t('project') },
    ...(provider?.fields || []).filter(field => !hidden.includes(field.name))
      .slice().sort((a, b) => a.order - b.order)
      .map(field => ({ name: field.name, label: providerLabel(field)
        + (core.includes(providerLabel(field)) ? ' (' + provider.instance + ')' : '') }))];
  if (!groups.some(group => group.name === chartGroupBy)) { chartGroupBy = 'task'; _chartHidden.clear(); }
  // Task alone needs no tabs.
  id('chart-groups').style.display = groups.length > 1 ? '' : 'none';
  // Provider fields can be taken off the tabs; without any there is nothing to choose.
  id('chart-pref-btn').style.display = (provider?.fields || []).length ? '' : 'none';
  id('chart-groups').innerHTML = groups.map(group => {
    const name = escAttr(JSON.stringify(group.name));
    return `<button class="chart-gtab${group.name === chartGroupBy ? ' active' : ''}"`
      + ` onclick="setChartGroup(${name}, this)">${esc(group.label)}</button>`;
  }).join('');
}

