'use strict';
// ── Boot ─────────────────────────────────────────────────────────────────────
// Installable as an app: the service worker only stands in when the daemon is down.
if ('serviceWorker' in navigator) navigator.serviceWorker.register('/sw.js').catch(() => {});

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

(async () => {
  const browserToday = todayStr();
  applyLang(); // fill static labels before data arrives
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
  loadDay(selectedDate, { chart: true });
  initTour();
  // Poll every 30 s; refresh the full page only once the user has been idle ≥5 m.
  setInterval(() => {
    loadCurrent();  // header ticker — always safe, never re-renders content
    loadSchedule(); // today's projection — cheap, drives the schedule strip
    if (Date.now() - _lastInteraction >= IDLE_MS) loadDay(selectedDate, { chart: true });
  }, 30_000);
  // Re-render the schedule strip every second so the countdown / clock-out ticks
  // smoothly between the 30 s fetches (uses cached data + the current clock).
  setInterval(renderSchedule, 1_000);
})();

async function loadProvider() {
  const data = await apiJSON('GET', '/api/provider');
  providerStatus = data.status || providerStatus;
  provider = data.instance ? data : null;
  renderProviderStatus();
  if (id('settings-popup').classList.contains('show')) renderProviderControls();
  applyFeatureToggles();
  return data;
}

