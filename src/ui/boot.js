'use strict';
// ── Boot ─────────────────────────────────────────────────────────────────────
// The service worker serves the compiled shell from its cache on reload. When
// a new build's worker takes over a page the old one served, reload once so the
// page runs the build the daemon runs.
if ('serviceWorker' in navigator) {
  const servedByOld = !!navigator.serviceWorker.controller;
  let reloading = false;
  navigator.serviceWorker.addEventListener('controllerchange', () => {
    if (!servedByOld || reloading) return;
    reloading = true;
    location.reload();
  });
  navigator.serviceWorker.register('/sw.js', { updateViaCache: 'none' }).catch(() => {});
}

// Password managers put icon anchors beside fields, which shifts their rows.
// Only the provider sign-in (username and password) is for them.
const AUTOFILL_OFF = 'input:not([type=checkbox]):not([type=radio]):not([autocomplete=username]):not([autocomplete=current-password]),textarea';
function autofillOff(root) {
  const off = el => {
    el.setAttribute('data-lpignore', 'true');    // LastPass
    el.setAttribute('data-1p-ignore', '');       // 1Password
    el.setAttribute('data-bwignore', '');        // Bitwarden
    el.setAttribute('data-form-type', 'other');  // Dashlane
    if (!el.hasAttribute('autocomplete')) el.setAttribute('autocomplete', 'off');
  };
  if (root.matches?.(AUTOFILL_OFF)) off(root);
  root.querySelectorAll?.(AUTOFILL_OFF).forEach(off);
}
autofillOff(document);
new MutationObserver(list => list.forEach(m => m.addedNodes.forEach(n => n.nodeType === 1 && autofillOff(n))))
  .observe(document.body, { childList: true, subtree: true });

function isCurrentBootCache(cached, now) {
  return !!cached?.date && cached.state?.date === cached.date && cached.day?.date === cached.date
    && Number.isFinite(cached.day.start_ms) && Number.isFinite(cached.day.end_ms)
    && cached.day.start_ms <= now && now < cached.day.end_ms;
}

// Today paints from the boot cache while it is still today; another day from
// the last day viewed.
function getInitialDayCache(targetDate, browserToday, now) {
  if (TOUR) return null;
  if (targetDate === browserToday) {
    const cached = loadLS('bootCache', null);
    if (!cached || !isCurrentBootCache(cached, now)) return null;
    selectedDate = cached.date;
    return cached;
  }
  const lastDay = loadLS('lastDayCache', null);
  return lastDay?.date === targetDate && lastDay.day?.date === targetDate ? lastDay : null;
}

function restartPolling() {
  if (_pollInterval) clearInterval(_pollInterval);
  let lastChartRefresh = Date.now();
  _pollInterval = setInterval(() => {
    if (isEditing()) return;
    loadCurrent();
    loadSchedule();
    const now = Date.now();
    const chart = now - lastChartRefresh >= 60_000 || now - _lastInteraction >= IDLE_MS;
    if (selectedDate === todayStr() || selectedDate === S?.date || chart) {
      if (chart) lastChartRefresh = now;
      loadDay(selectedDate, { chart, background: true });
    }
  }, 15_000);
}

(async () => {
  const browserToday = todayStr();
  setLangFrom(settings); // the cached settings, until the daemon answers
  applyLang(); // fill static labels before data arrives
  initLayout(); // restore the active tab before painting cached content
  applyFeatureToggles(); // sync header action buttons before first paint
  const daysEl = id('chart-days');
  if (daysEl && [...daysEl.options].some(o => o.value === String(chartDays))) daysEl.value = String(chartDays);
  renderChartGroups();
  const cached = getInitialDayCache(selectedDate, browserToday, Date.now());
  setDateTitle(selectedDate);
  if (activeTab !== 'report' || !_chartVisible) id('chart-box').style.display = 'none';
  if (cached) {
    D = cached.day;
    S = cached.state;
    weekData = cached.week || weekData;
    projects = cached.projects || projects;
    renderHeader(S);
    id('table-area').classList.toggle('summary-view', activeTab === 'summary');
    id('cards').parentElement.style.display = activeTab === 'timeline' ? 'none' : '';
    renderSidebar();
    renderSchedule();
    renderCards(D);
    if (activeTab === 'summary') loadSummary(D, selectedDate);
    else renderReport(D);
  }
  const chartCache = TOUR ? null : loadLS('chartCache', null);
  const initialChartData = chartCache?.days === chartDays && chartCache?.group === chartGroupBy ? chartCache.data : cached?.chartData;
  if (activeTab === 'report' && _chartVisible && initialChartData) renderChart(initialChartData);
  if (TOUR) await ensureTour();
  const [settingsResult, currentResult, providerResult] = await Promise.allSettled([
    loadSettings(),
    loadCurrent(),
    loadProvider(),
  ]);
  if (settingsResult.status === 'rejected') showError(settingsResult.reason.message);
  if (currentResult.status === 'rejected') showError(currentResult.reason.message);
  if (providerResult.status === 'rejected') {
    provider = S && S.provider ? { instance: S.provider, fields: [] } : null;
    showError(providerResult.reason.message);
  }
  setLangFrom(settings);
  applyLang();
  showUpdateOutcome().catch(() => {});
  initLayout({ migrate: settingsResult.status === 'fulfilled' }); // apply the preferences loaded from the daemon
  applyFeatureToggles();
  renderChartGroups();
  const days = id('chart-days');
  if (days && [...days.options].some(o => o.value === String(chartDays))) days.value = String(chartDays);
  if (selectedDate === browserToday && S?.date) selectedDate = S.date;
  loadCurrent(); // again, now that the link setting is known
  // Each load stands alone: one failing never keeps the day view from loading.
  for (const r of await Promise.allSettled([loadWeek(), loadSchedule()])) {
    if (r.status === 'rejected') showError(r.reason.message);
  }
  renderSidebar();
  loadDay(selectedDate, { chart: true });
  initTour();
  // Keep today's data live, with a full chart refresh each minute or when idle.
  restartPolling();
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) return;
    if (isEditing()) return;
    loadCurrent();
    loadSchedule();
    loadDay(selectedDate, { chart: false, background: true });
  });
  // Re-render the schedule strip and header ticker every second
  setInterval(() => {
    renderSchedule();
    tickHeader();
  }, 1_000);
})();

function isEditing() {
  const focused = document.activeElement?.tagName;
  return _noteEditors > 0 || selectionUiOpen()
    || focused === 'INPUT' || focused === 'TEXTAREA'
    || !!document.querySelector('.modal.show, .popup.show, #confirm-popup.show')
    || !!(_resize || _rdResize);
}

async function loadProvider() {
  const data = await apiJSON('GET', '/api/provider');
  providerStatus = data.status || providerStatus;
  provider = data.instance ? data : null;
  saveLS('providerCache', { provider, providerStatus });
  renderProviderStatus();
  if (id('settings-popup').classList.contains('show')) renderProviderControls();
  applyFeatureToggles();
  renderChartGroups();
  return data;
}

