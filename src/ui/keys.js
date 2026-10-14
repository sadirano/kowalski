'use strict';
// The shortcut list is rendered when the cheatsheet opens, so it always speaks
// the current language and stays the single place where the keys are described.
const SHORTCUTS = [
  { sec: 'keys_sec_mod' },
  { k: 'Ctrl + Enter',   i: 'keys_toggle' },
  { k: 'Ctrl + ,',       i: 'keys_settings' },
  { k: 'Ctrl + K',       i: 'keys_search' },
  { sec: 'keys_sec_bare' },
  { k: 'N',           i: 'keys_newtask' },
  { k: '/',           i: 'keys_search' },
  { k: '←  →',  i: 'keys_day' },
  { k: 'T',           i: 'today' },
  { k: '1  2',        i: 'keys_tabs' },
  { k: 'G',           i: 'keys_calendar' },
  { k: 'C',           i: 'keys_chart' },
  { k: 'A',           i: 'keys_addentry' },
  { k: '[',           i: 'keys_sidebar' },
  { k: '?',           i: 'keys_help' },
];

function showKeys() {
  id('keys-grid').innerHTML = SHORTCUTS.map(r => r.sec
    ? `<div class="keys-sec">${esc(t(r.sec))}</div>`
    : `<kbd>${esc(r.k)}</kbd><span>${esc(t(r.i))}</span>`).join('');
  id('keys-overlay').classList.add('show');
  id('keys-popup').classList.add('show');
}
function hideKeys() {
  id('keys-overlay').classList.remove('show');
  id('keys-popup').classList.remove('show');
}

// Every modal that takes over the keyboard while it is open. The page-wide
// shortcuts stay out of the way until the one on top is dismissed, so they never
// compete with the Enter/Escape handling further down.
const POPUP_IDS = ['newtask-popup', 'settings-popup', 'horas-popup',
                   'obs-popup', 'cal-popup', 'edit-popup', 'addentry-popup',
                   'keys-popup', 'login-popup', 'approve-popup', 'source-popup', 'confirm-popup'];
function anyPopupOpen() { return POPUP_IDS.some(p => id(p) && id(p).classList.contains('show')); }
function isTyping(e) {
  const el = e.target;
  return !!el && (el.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(el.tagName));
}
// Controls that use the arrow keys themselves keep them.
function ownsArrows(e) {
  return isTyping(e) || !!e.target?.closest?.('[role=listbox],[role=radiogroup],[role=slider],[role=menu],[role=tablist],[role=grid],[role=tree]');
}

// Japanese (and other) input methods own the keyboard while they compose:
// no shortcut and no dialog Enter/Escape until the text is committed.
let _composing = false;
document.addEventListener('compositionstart', () => { _composing = true; }, true);
document.addEventListener('compositionend', () => { _composing = false; }, true);

// Page-wide shortcuts, plus Enter/Escape for whichever modal is open. Keys are
// matched on the character they produce (e.key), so the list shows the key the
// user presses on any layout, and the letters are the same in every language.
document.addEventListener('keydown', e => {
  if (e.defaultPrevented || _composing || e.isComposing || e.key === 'Process' || e.key === 'Dead') return;
  // Holding a key down repeats it: only the arrows may repeat.
  if (e.repeat && e.key !== 'ArrowLeft' && e.key !== 'ArrowRight') return;
  const ctrl = (e.ctrlKey || e.metaKey) && !e.altKey && !e.shiftKey && !e.getModifierState('AltGraph');
  // A focused day clock opens Post hours, like a click; modifiers and open popups pass through.
  if ((e.key === 'Enter' || e.key === ' ') && !e.ctrlKey && !e.metaKey && !e.altKey && !anyPopupOpen() &&
      e.target.classList && e.target.classList.contains('dclock')) {
    e.preventDefault(); e.target.click(); return;
  }
  // Ctrl+K jumps to the task search, unless a dialog is open.
  if (ctrl && (e.key === 'k' || e.key === 'K') && !anyPopupOpen()) { e.preventDefault(); focusSearch(); return; }
  // Ctrl+Enter is the Start/Pause button. It yields to text fields, where the
  // same combo already confirms a note (interval note, posting note).
  if (ctrl && e.key === 'Enter' && !isTyping(e) && !anyPopupOpen()) {
    e.preventDefault(); toggleTracker(); return;
  }
  // Ctrl+, opens Settings, following the editor convention.
  if (ctrl && e.key === ',' && !anyPopupOpen()) {
    e.preventDefault(); showSettings(); return;
  }
  // A confirmation sits on top of everything: it takes Enter and Escape alone.
  if ((e.key === 'Escape' || e.key === 'Enter') && id('confirm-popup').classList.contains('show')) {
    e.preventDefault();
    closeConfirm(e.key === 'Enter');
    return;
  }
  // The calendar can sit on top of another dialog: it takes the key alone.
  if ((e.key === 'Escape' || e.key === 'Enter') && id('cal-popup').classList.contains('show')) {
    if (e.key === 'Escape') hideCalendar();
    return;
  }
  if (id('approve-popup').classList.contains('show') && (e.key === 'Escape' || e.key === 'Enter')) {
    if (e.key === 'Escape') hideProviderApproval();
    return;
  }
  if (id('source-popup').classList.contains('show') && (e.key === 'Escape' || e.key === 'Enter')) {
    if (e.key === 'Escape') hideSourceDialog();
    return;
  }
  if (e.key === 'Escape' && id('newtask-popup').classList.contains('show')) hideNewTask();
  if (e.key === 'Enter'  && id('newtask-popup').classList.contains('show')) applyNewTask();
  if (e.key === 'Escape' && id('settings-popup').classList.contains('show')) hideSettings();
  if (e.key === 'Enter'  && id('settings-popup').classList.contains('show') && e.target.tagName !== 'BUTTON') applySettings();
  // Notes opens over Post hours: Escape closes Notes alone.
  if (e.key === 'Escape' && id('obs-popup').classList.contains('show')) { closeObsPopup(); return; }
  // Sign-in can open over Post hours too: Escape closes sign-in alone.
  if (e.key === 'Escape' && id('login-popup').classList.contains('show')) { hideLogin(); return; }
  if (e.key === 'Escape' && id('horas-popup').classList.contains('show')) hideHoras();
  if (e.key === 'Escape' && id('edit-popup').classList.contains('show')) closeEditTime();
  if (e.key === 'Enter'  && id('edit-popup').classList.contains('show')) { e.preventDefault(); applyEditTime(); }
  if (e.key === 'Escape' && id('addentry-popup').classList.contains('show')) hideAddEntry();
  if (e.key === 'Enter'  && id('addentry-popup').classList.contains('show')) applyAddEntry();
  if (e.key === 'Escape' && id('keys-popup').classList.contains('show')) hideKeys();

  // ── Single-key shortcuts ────────────────────────────────────────────────────
  // Bare keys, so they have to stay out of the way of typing, of a modal that is
  // up (its Enter/Escape ran above) and of any browser combo. Shift is allowed
  // through: it is what produces '?'. Settings can turn them all off.
  if (!_singleKeys || e.ctrlKey || e.metaKey || e.altKey || e.getModifierState('AltGraph') || anyPopupOpen()) return;
  if (e.key === 'ArrowLeft' || e.key === 'ArrowRight' ? ownsArrows(e) : isTyping(e)) return;
  switch (e.key) {
    case 'n': case 'N': e.preventDefault(); showNewTask();  return;
    case '/':           e.preventDefault(); focusSearch();  return;
    case 'ArrowLeft':   e.preventDefault(); stepDay(-1);    return;
    case 'ArrowRight':  e.preventDefault(); stepDay(1);     return;
    case 't': case 'T': e.preventDefault(); goToDate(todayStr()); return;
    case '1':           e.preventDefault(); setTab('report');    return;
    case '2':           e.preventDefault(); setTab('summary');   return;
    case 'g': case 'G': e.preventDefault(); showCalendar(); return;
    case '[':           e.preventDefault(); toggleLeftPanel(); return;
    case '?':           e.preventDefault(); showKeys();     return;
  }
  if (e.key === 'c' || e.key === 'C') {
    if (activeTab === 'report') { e.preventDefault(); toggleChartVisible(); }
  } else if (e.key === 'a' || e.key === 'A') {
    e.preventDefault(); showAddEntry();
  }
});

