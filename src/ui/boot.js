'use strict';
// ── Boot ─────────────────────────────────────────────────────────────────────
// Installable as an app: the service worker only stands in when the daemon is down.
if ('serviceWorker' in navigator) navigator.serviceWorker.register('/sw.js').catch(() => {});

(async () => {
  const browserToday = todayStr();
  applyLang(); // fill static labels before data arrives
  if (TOUR) await ensureTour();
  const [settingsResult, currentResult, providerResult] = await Promise.allSettled([
    loadSettings(),
    loadCurrent(),
    apiJSON('GET', '/api/provider'),
  ]);
  if (settingsResult.status === 'rejected') showError(settingsResult.reason.message);
  if (currentResult.status === 'rejected') showError(currentResult.reason.message);
  if (providerResult.status === 'fulfilled') {
    const data = providerResult.value;
    provider = data.instance ? data : null;
  } else {
    provider = S && S.provider ? { instance: S.provider, fields: [] } : null;
    showError(providerResult.reason.message);
  }
  setLangFrom(settings);
  applyLang();
  initLayout();
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
  loadDay(selectedDate);
  initTour();
  // Poll every 30 s; refresh the full page only once the user has been idle ≥5 m.
  setInterval(() => {
    loadCurrent();  // header ticker — always safe, never re-renders content
    loadSchedule(); // today's projection — cheap, drives the schedule strip
    if (Date.now() - _lastInteraction >= IDLE_MS) loadDay(selectedDate);
  }, 30_000);
  // Re-render the schedule strip every second so the countdown / clock-out ticks
  // smoothly between the 30 s fetches (uses cached data + the current clock).
  setInterval(renderSchedule, 1_000);
})();

