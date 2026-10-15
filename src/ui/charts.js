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

// Dashed line at the daily target, drawn over the bars.
const targetLinePlugin = {
  id: 'targetLine',
  afterDatasetsDraw(chart, _args, opts) {
    if (!(opts.hours > 0)) return;
    const { ctx, chartArea: a, scales: { y } } = chart;
    const py = y.getPixelForValue(opts.hours);
    if (py < a.top || py > a.bottom) return;
    ctx.save();
    ctx.strokeStyle = '#94a3b8'; ctx.lineWidth = 1; ctx.setLineDash([4, 4]);
    ctx.beginPath(); ctx.moveTo(a.left, py); ctx.lineTo(a.right, py); ctx.stroke();
    ctx.restore();
  },
};

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

function renderChart(data) {
  if (chartInst) { chartInst.destroy(); chartInst = null; }
  id('chart-legend').innerHTML = '';
  id('chart-lanes').innerHTML = '';
  if (!data?.dates?.length) return;

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
  const dates = _chartDates;
  const sel = dates.indexOf(selectedDate);

  // One dataset per series, stacked, biggest at the bottom. The selected day
  // is full opacity, the rest dimmed; only the topmost non-empty segment of a
  // column is rounded.
  const datasets = _chartRanked.map(s => ({
    label: s.label,
    key: s.key,
    data: s.ms.map(ms => ms / 3600000),
    ms: s.ms,
    color: s.color,
    hidden: _chartHidden.has(s.key),
    backgroundColor: chartShades(s.color, dates.length, sel, true),
    borderRadius: c => topSegment(c) ? { topLeft: 3, topRight: 3 } : 0,
    borderSkipped: false,
    maxBarThickness: 36,
    stack: 'day',
  }));

  chartInst = new Chart(id('chart'), {
    type: 'bar',
    data: { labels: dates.map(d => shortDate(d)), datasets },
    plugins: [targetLinePlugin],
    options: {
      responsive: true,
      maintainAspectRatio: false,
      interaction: { mode: 'index', intersect: false },
      onClick: (_e, items) => { if (items.length) goToDate(dates[items[0].index]); },
      plugins: {
        legend: { display: false },
        targetLine: { hours: (S?.daily_work_minutes || 0) / 60 },
        tooltip: {
          filter: c => c.dataset.ms[c.dataIndex] > 0,
          itemSort: (a, b) => b.dataset.ms[b.dataIndex] - a.dataset.ms[a.dataIndex],
          callbacks: {
            label: c => ` ${fmtMs(c.dataset.ms[c.dataIndex])}  ${c.dataset.label}`,
            footer: items => items.length > 1
              ? t('card_total') + ' ' + fmtMs(items.reduce((n, c) => n + c.dataset.ms[c.dataIndex], 0)) : '',
          },
        },
      },
      scales: {
        x: { stacked: true, grid: { display: false },
             ticks: { color: c => c.index === sel ? '#e2e8f0' : '#64748b', maxRotation: 0, autoSkipPadding: 8 } },
        y: { stacked: true, grid: { color: '#2a2d3d' }, border: { display: false },
             ticks: { color: '#64748b', maxTicksLimit: 5, callback: v => v+'h' }, beginAtZero: true },
      },
    },
  });
  chartInst.$sel = sel;
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

// Bar colours for one series: the selected day full, the rest dimmed, and
// everything faded when another series is being pointed at in the list.
function chartShades(color, n, sel, lit) {
  return Array.from({ length: n }, (_, j) => color + (!lit ? '26' : j === sel || sel < 0 ? 'ff' : 'b3'));
}

// Pointing at a list row keeps that series bright and fades the rest.
function focusChartSeries(key) {
  if (!chartInst) return;
  chartInst.data.datasets.forEach(d => {
    const lit = key == null || d.key === key;
    d.backgroundColor = chartShades(d.color, d.data.length, chartInst.$sel, lit);
  });
  chartInst.update('none');
}

// True when no dataset above this one has time in the same column.
function topSegment(c) {
  const sets = c.chart.data.datasets;
  for (let k = sets.length - 1; k > c.datasetIndex; k--) {
    if (c.chart.isDatasetVisible(k) && sets[k].data[c.dataIndex] > 0) return false;
  }
  return true;
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
  if (!chartInst) return;
  chartInst.setDatasetVisibility(i, !_chartHidden.has(s.key));
  chartInst.update();
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
  id('chart-groups').innerHTML = groups.map(group => {
    const name = escAttr(JSON.stringify(group.name));
    return `<button class="chart-gtab${group.name === chartGroupBy ? ' active' : ''}"`
      + ` onclick="setChartGroup(${name}, this)">${esc(group.label)}</button>`;
  }).join('');
}

