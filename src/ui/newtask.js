'use strict';
// ── New Task modal ────────────────────────────────────────────────────────────
let _newTaskIdLookup = null;
let _newTaskIdValue = '';
async function showNewTask(prefill) {
  try { await loadProjects(); } catch (e) { showError(e.message); }
  _lookupTok++; // a lookup still running belongs to the previous dialog
  id('nt-ref').value = prefill?.ref || '';
  id('nt-title').value = prefill?.title || '';
  _newTaskIdLookup = null;
  _newTaskIdValue = '';
  const project = prefill && Object.hasOwn(prefill, 'project_id') ? prefill.project_id : focusProjectId();
  id('nt-project').innerHTML = projectOptions(project ?? 'unassigned');
  id('nt-project').value = project == null ? 'unassigned' : String(project);
  id('nt-ref-row').style.display = provider ? '' : 'none';
  id('nt-info').style.display = 'none';
  id('nt-info').innerHTML = '';
  id('newtask-overlay').classList.add('show');
  id('newtask-popup').classList.add('show');
  setTimeout(() => id(provider ? 'nt-ref' : 'nt-title').focus(), 50);
}

function hideNewTask() {
  _lookupTok++;
  id('newtask-overlay').classList.remove('show');
  id('newtask-popup').classList.remove('show');
}

let _pendingBind = null; // {id, ref}: created, bind not yet done
let _taskChain = Promise.resolve();

// Resolutions run one after another, so a double submit finds the task the
// first one created instead of creating a second.
function taskFor(ref, title, projectId) {
  const run = _taskChain.then(() => resolveTask(ref, title, projectId));
  _taskChain = run.catch(() => {});
  return run;
}

// The search limit is the server's maximum, so an exact match is not cut off.
async function findTask(ref, title, projectId) {
  const found = await apiJSON('GET', '/api/tasks?q=' + encodeURIComponent(ref || title) + '&limit=1000');
  return found.tasks.find(s => ref ? s.ref === ref : s.title.toLowerCase() === title.toLowerCase() && s.project_id === projectId) || null;
}

async function resolveTask(ref, title, projectId) {
  if (!ref && /^#[1-9]\d*$/.test(title)) {
    const found = await apiJSON('GET', '/api/tasks/' + title.slice(1));
    return found.task;
  }
  // A task created on an earlier try whose bind failed is reused, not duplicated.
  if (ref && _pendingBind && _pendingBind.ref === ref) {
    const taskId = _pendingBind.id;
    return (await bindRef(taskId, ref)) || { id: taskId };
  }
  let task = await findTask(ref, title, projectId);
  if (task) return task;
  const created = await apiJSON('POST', '/api/tasks', { title: title || ref, project_id: projectId });
  task = created.task;
  if (ref && provider) {
    _pendingBind = { id: task.id, ref };
    task = (await bindRef(task.id, ref)) || task;
  }
  return task;
}

async function syncNewTaskProjectFromId() {
  const title = id('nt-title').value.trim();
  if (id('nt-ref').value.trim() || !/^#[1-9]\d*$/.test(title)) return;
  if (title === _newTaskIdValue) return _newTaskIdLookup;
  _newTaskIdValue = title;
  _newTaskIdLookup = apiJSON('GET', '/api/tasks/' + title.slice(1)).then(data => {
    if (id('nt-title').value.trim() !== title) return;
    const value = data.task.project_id == null ? 'unassigned' : String(data.task.project_id);
    id('nt-project').innerHTML = projectOptions(value);
    id('nt-project').value = value;
  }).catch(e => showError(e.message));
  return _newTaskIdLookup;
}

// Binds the ref; a 409 means another task owns it, and that task is the answer.
// The ref is kept even when the provider cannot confirm it; the task then
// carries the reason as `lookupError` for the caller to show.
async function bindRef(taskId, ref) {
  try {
    const bound = await apiJSON('POST', '/api/tasks/' + taskId + '/bind', { ref });
    _pendingBind = null;
    return bound.lookup_error ? { ...bound.task, lookupError: bound.lookup_error } : bound.task;
  } catch (e) {
    if (e.status !== 409) throw e;
    const owner = await findTask(ref, '', null);
    if (!owner) throw e;
    _pendingBind = null;
    return owner;
  }
}

async function applyNewTask() {
  const ref = id('nt-ref').value.trim();
  const title = id('nt-title').value.trim();
  if (!ref && !title) {
    id(provider ? 'nt-ref' : 'nt-title').focus();
    showError(t('ae_need_task'));
    return;
  }
  try {
    await syncNewTaskProjectFromId();
    const selected = id('nt-project').value;
    const projectId = selected === 'unassigned' ? null : Number(selected);
    const task = await taskFor(ref, title, projectId);
    hideNewTask();
    await switchToTask(task, projectId);
    if (task.lookupError) showError(t('ref_unconfirmed', { ref, e: task.lookupError }));
  } catch (e) {
    showError(e.message);
  }
}

// Explicit lookup overwrites the title; automatic lookup fills it only when blank.
// New-task modal lookup also shows provider fields in the context box.
function lookupRef(explicit) {
  return lookupInto({ refId: 'nt-ref', titleId: 'nt-title', explicit, showInfo: true });
}

// Add-entry modal lookup fills the title only (no context box there).
function lookupAERef(explicit) {
  return lookupInto({ refId: 'ae-ref', titleId: 'ae-title', explicit });
}

let _lookupTimer = null;
let _lookupTok = 0; // drops a lookup answer for a ref no longer in the dialog
function autoLookup(fn) {
  if (_lookupTimer) clearTimeout(_lookupTimer);
  _lookupTimer = setTimeout(() => fn(false), 500);
}

// Fetch provider data for the ref and fill the title. An explicit lookup
// reports errors and overwrites; an automatic lookup only fills a blank title.
async function lookupInto({ refId, titleId, explicit, showInfo }) {
  const ref = id(refId).value.trim();
  if (!ref || !provider) return;

  const titleEl = id(titleId);
  const tok = ++_lookupTok;
  // Visual feedback that we're searching
  const oldPlaceholder = titleEl.placeholder;
  titleEl.placeholder = t('searching');

  try {
    const data = await apiJSON('GET', '/api/lookup?ref=' + encodeURIComponent(ref));
    if (tok !== _lookupTok || id(refId).value.trim() !== ref) return;
    if (data.title && (explicit || !titleEl.value.trim())) titleEl.value = data.title;
    if (showInfo) {
      const labels = new Map([...provider.fields].sort((a, b) => a.order - b.order).map(f => [f.name, providerLabel(f)]));
      const names = [...labels.keys(), ...Object.keys(data.fields || {}).filter(name => !labels.has(name))];
      id('nt-info').innerHTML = names.filter(name => data.fields && data.fields[name] != null).map(name =>
        `<div class="nt-info-row"><span class="nt-info-lbl">${esc(labels.get(name) || name)}</span>` +
        `<span class="nt-info-val">${esc(String(data.fields[name]))}</span></div>`).join('');
      id('nt-info').style.display = 'flex';
    }
  } catch (e) {
    if (tok === _lookupTok) showError(e.message);
  } finally {
    titleEl.placeholder = oldPlaceholder;
  }
}
