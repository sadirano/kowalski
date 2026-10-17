'use strict';
// The day's title without the weekday, at the width of the language's
// longest month, so the arrows and the toolbar never move.
let _dateTitleLang = null;
function setDateTitle(date) {
  const el = id('date-title');
  const fmt = d => d.toLocaleDateString(locale(), { month: 'long', day: 'numeric', year: 'numeric' });
  if (_dateTitleLang !== _lang) {
    _dateTitleLang = _lang;
    const ctx = document.createElement('canvas').getContext('2d');
    const cs = getComputedStyle(el);
    ctx.font = `${cs.fontWeight} ${cs.fontSize} ${cs.fontFamily}`;
    const widest = Math.max(...Array.from({ length: 12 }, (_, m) => ctx.measureText(fmt(new Date(2026, m, 28))).width));
    el.style.minWidth = Math.ceil(widest + 2) + 'px';
  }
  el.textContent = fmt(new Date(date + 'T12:00:00'));
}

// Each day load takes a generation; neither response may paint an older day.
let _dayGen = 0;

async function loadDay(date, { chart = false } = {}) {
  const gen = ++_dayGen;
  const tab = activeTab;
  try {
    const [days, day] = await Promise.all([
      fetchWeek(),
      apiJSON('GET', '/api/day?date=' + date),
      loadProjects().catch(() => []),
    ]);
    if (gen !== _dayGen || selectedDate !== date || activeTab !== tab) return;
    weekData = days;
    D = day;
    setDateTitle(date);
    id('table-area').classList.toggle('summary-view', tab === 'summary');
    renderSchedule();
    renderSidebar();
    id('cards').parentElement.style.display = tab === 'timeline' ? 'none' : ''; // the timeline reads one task, not the day's numbers
    renderCards(D);
    if (tab === 'report') {
      renderReport(D);
      if (chart) loadChart();
    } else if (tab === 'timeline') {
      id('chart-box').style.display = 'none'; // the timeline has its own day ribbon
      renderReport(D);
    } else {
      loadSummary(D, date);
    }
  } catch (e) {
    if (gen !== _dayGen) return;
    id('table-area').innerHTML = `<div class="empty">${esc(e.message)}</div>`;
  }
}

async function loadChart() {
  if (!_chartVisible) { id('chart-box').style.display = 'none'; return; }
  id('chart-box').style.display = '';
  try {
    const pts = await apiJSON('GET', '/api/chart?days=' + chartDays + '&group=' + encodeURIComponent(chartGroupBy));
    renderChart(pts);
  } catch (e) {
    showError(e.message);
  }
}

function setChartGroup(group, el) {
  chartGroupBy = group;
  _chartHidden.clear();
  document.querySelectorAll('#chart-box .chart-gtab').forEach(t => t.classList.remove('active'));
  el.classList.add('active');
  loadChart();
}

function setChartDays(val) {
  chartDays = parseInt(val, 10) || 14;
  setPref('ui_chart_days', String(chartDays)).catch(e => showError(e.message));
  loadChart();
}

function toggleChartExpand() {
  chartExpanded = !chartExpanded;
  id('chart-box').classList.toggle('expanded', chartExpanded);
  const btn = id('chart-expand-btn');
  const label = t(chartExpanded ? 'collapse' : 'expand');
  btn.textContent = chartExpanded ? '⤡' : '⤢';
  btn.title = label;
  btn.setAttribute('aria-label', label);
  if (chartInst) chartInst.onResize();
}


