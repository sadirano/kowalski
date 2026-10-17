'use strict';
let S = null;         // GET /api/state
let D = null;         // GET /api/day for selectedDate
const _cachedProvider = loadLS('providerCache', null);
let provider = _cachedProvider?.provider || null;  // GET /api/provider: {instance, fields:[{name,label,type,order}]} or null
let providerStatus = _cachedProvider?.providerStatus || { state: 'none', name: '', build: '', reason: '' };
let settings = loadLS('settingsCache', {});    // key -> value from GET /api/settings
const _savedSel = loadLS('selectedDate', null);
let selectedDate   = _savedSel?.sessionDate === todayStr() && _savedSel.date ? _savedSel.date : todayStr();
let activeTab      = 'report';
let chartInst      = null;
let chartGroupBy   = 'task';
let chartDays      = parseInt(settings['ui_chart_days'] ?? '14', 10) || 14;
let chartView      = (settings['ui_chart_view'] ?? 'bars') === 'lanes' ? 'lanes' : 'bars';
let chartExpanded  = false;
// Panel widths are saved per device; other preferences are daemon settings
// (ui_* keys).
const MIN_PANEL_W = 150, MAX_PANEL_W = 520;
let _leftWidth     = Math.max(MIN_PANEL_W, Math.min(MAX_PANEL_W, parseInt(loadLS('leftWidth', 220), 10) || 220));
let _rightWidth    = 240;
let _leftCollapsed = false;
let _rightCollapsed= false;
let _chartVisible  = true;
let weekData       = [];
let _taskData      = [];   // populated by renderReport; used by switch buttons
let _currentTaskId = null; // kowalski task id of the focus (null when idle)
let _hideWeekends  = false; // when true, Sat/Sun are dropped from the day list & chart
let _sidebarDays   = 7;     // how many days the sidebar shows (work days when _hideWeekends)
let _refLinks      = false; // when true, refs link to the provider's page
let _showAddEntry    = false; // gate: "Add entry" button (Feature 3/4)
let _showKeys        = true;  // gate: the shortcuts button in the header
let _singleKeys      = true;  // gate: the one-key shortcuts (N, T, arrows...)
let _summaryFormat   = 'grouped'; // summary layout format: 'chronological' | 'grouped'
let _taskOrder       = 'time';    // day task order: 'time' | 'ref' | 'added'
let _reportLayout    = 'classic'; // report layout: 'classic' | 'grid' (the timeline tab is its own view)
let _sidebarFirstRender = true; // first sidebar paint scrolls today (newest) into view
let _calYear       = 0;     // calendar modal: displayed year
let _calMonth      = 0;     // calendar modal: displayed month (0-based)
let _calTotals     = {};    // calendar modal: { "YYYY-MM-DD": total_ms } for the shown month
const IDLE_MS = 5 * 60 * 1000; // 5 minutes
let _lastInteraction = Date.now();
let _pollInterval = null;

// Stamp any meaningful user gesture so idle detection covers the whole page.
['mousemove','mousedown','keydown','touchstart','scroll'].forEach(ev =>
  document.addEventListener(ev, () => { _lastInteraction = Date.now(); }, { passive: true })
);

function pref(key, def) { return settings[key] ?? def; }
// Saves run one after another, so the last reply is the newest snapshot.
let _prefQueue = Promise.resolve();
function setPref(key, value) {
  const save = _prefQueue.then(async () => {
    const data = await apiJSON('PATCH', '/api/settings', { [key]: value });
    settings = Object.fromEntries(data.settings.map(({ key, value }) => [key, value]));
    saveLS('settingsCache', settings);
    return settings;
  });
  _prefQueue = save.catch(() => {});
  return save;
}
