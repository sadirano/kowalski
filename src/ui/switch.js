'use strict';
// ── Task switching ────────────────────────────────────────────────────────────
function switchToTaskByIdx(idx) {
  const d = _taskData[idx];
  if (d) switchToTask(d.task);
}

async function switchToTask(task) {
  try {
    await apiJSON('POST', '/api/switch', { task: '#' + task.id });
    showToast(t('switched', { name: task.ref || task.title }));
    await loadCurrent();
    loadSchedule();
    loadDay(selectedDate);
  } catch (e) {
    showError(e.message);
  }
}

// applyFeatureToggles reflects the per-feature visibility settings into the
// header buttons. Called whenever config is (re)loaded.
function applyFeatureToggles() {
  id('add-entry-btn').style.display = _showAddEntry ? '' : 'none';
  id('keys-btn').style.display = _showKeys ? '' : 'none';
  id('login-btn').style.display = provider ? '' : 'none';
}

// ── Provider sign-in ──────────────────────────────────────────────────────────
// The provider names what it asks for; secret answers go in password fields.
// The answers go to the daemon once and are never kept here.
let _loginPrompts = [];

async function showLogin() {
  if (!provider) return;
  try {
    _loginPrompts = (await apiJSON('GET', '/api/provider/login')).prompts || [];
  } catch (e) { showError(e.message); return; }
  id('login-fields').innerHTML = _loginPrompts.map((p, i) =>
    `<label><span>${esc(providerLabel(p))}</span>
      <input id="login-f${i}" type="${p.secret ? 'password' : 'text'}" autocomplete="${p.secret ? 'current-password' : 'username'}" spellcheck="false"></label>`).join('');
  id('login-overlay').classList.add('show');
  id('login-popup').classList.add('show');
  setTimeout(() => document.querySelector('#login-fields input')?.focus(), 50);
}

function hideLogin() {
  _loginPrompts.forEach((_, i) => { const f = id(`login-f${i}`); if (f) f.value = ''; });
  id('login-overlay').classList.remove('show');
  id('login-popup').classList.remove('show');
}

let _loggingIn = false;
async function applyLogin() {
  if (_loggingIn) return;
  const answers = {};
  for (const [i, p] of _loginPrompts.entries()) {
    const value = id(`login-f${i}`).value;
    if (!value) { id(`login-f${i}`).focus(); showError(t('login_empty', { f: providerLabel(p) })); return; }
    answers[p.name] = value;
  }
  _loggingIn = true;
  // Signing in can take several seconds: the button says it is working.
  const btn = id('login-submit');
  btn.disabled = true;
  btn.textContent = t('login_busy');
  try {
    await apiJSON('POST', '/api/provider/login', answers);
    hideLogin();
    showToast(t('login_ok'));
  } catch (e) {
    showError(t('login_failed', { e: e.message }));
  } finally {
    _loggingIn = false;
    btn.disabled = false;
    btn.textContent = t('login_submit');
  }
}
