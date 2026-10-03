/* Console client: credential -> cookie session + in-memory CSRF. Untrusted
 * values are rendered with textContent only. */
"use strict";

const state = { csrf: null, events: null };

const $ = (id) => document.getElementById(id);

function show(id) { $(id).hidden = false; }
function hide(id) { $(id).hidden = true; }

function setText(id, value) {
  $(id).textContent = value == null ? "unknown" : String(value);
}

async function api(path, options = {}) {
  const headers = Object.assign({}, options.headers || {});
  if (state.csrf) headers["X-CSRF-Token"] = state.csrf;
  const response = await fetch(path, Object.assign({}, options, {
    headers,
    credentials: "same-origin",
  }));
  const text = await response.text();
  let body = null;
  try { body = JSON.parse(text); } catch { body = null; }
  return { status: response.status, body };
}

async function refreshStatus() {
  const [status, registry, jobs] = await Promise.all([
    api("/api/status"), api("/api/registry"), api("/api/jobs"),
  ]);
  if (status.status !== 200 || !status.body) {
    show("offline");
    return;
  }
  hide("offline");
  const s = status.body;
  const resource = s.resource || {};
  setText("thermal", resource.thermal);
  setText("pressure", resource.memoryPressure);
  setText("lowpower", resource.lowPowerMode == null ? "unknown"
    : (resource.lowPowerMode ? "yes" : "no"));
  setText("apple", s.appleAvailability);
  const denied = resource.memoryPressure === "warning"
    || resource.memoryPressure === "critical"
    || resource.thermal === "serious" || resource.thermal === "critical";
  denied ? show("denied") : hide("denied");
  const counts = s.counts || {};
  setText("active", counts.activeInference);
  setText("pending", counts.pendingInference);
  setText("blocked", counts.inferenceBlocked);
  const cats = s.categories || {};
  setText("cat-apple", cats.appleFoundationModels);
  setText("cat-owned", cats.ownedOpenWeight);
  setText("cat-ml", cats.typedML);

  const models = (registry.body && registry.body.models) || [];
  const agents = (registry.body && registry.body.agents) || [];
  renderList($("models"), models, "none registered");
  renderList($("agents"), agents, "none registered");

  const jobList = (jobs.body && jobs.body.jobs) || [];
  renderJobs(jobList);
}

function renderList(ul, items, emptyText) {
  ul.textContent = "";
  if (!items.length) {
    const li = document.createElement("li");
    li.className = "hint";
    li.textContent = emptyText;
    ul.appendChild(li);
    return;
  }
  for (const item of items.slice(0, 50)) {
    const li = document.createElement("li");
    li.textContent = item;
    ul.appendChild(li);
  }
}

function renderJobs(jobs) {
  const tbody = $("jobs");
  tbody.textContent = "";
  for (const job of jobs.slice(0, 50)) {
    const tr = document.createElement("tr");
    for (const key of ["id", "kind", "consumer", "state"]) {
      const td = document.createElement("td");
      td.textContent = job[key];
      tr.appendChild(td);
    }
    const action = document.createElement("td");
    if (["queued", "active", "cancel_requested"].includes(job.state)) {
      const button = document.createElement("button");
      button.textContent = "stop";
      button.addEventListener("click", () => cancelJob(job.id));
      action.appendChild(button);
    }
    tr.appendChild(action);
    tbody.appendChild(tr);
  }
}

async function cancelJob(id) {
  const encoded = encodeURIComponent(id);
  await api(`/api/jobs/${encoded}/cancel`, { method: "POST" });
  await refreshStatus();
}

async function login(event) {
  event.preventDefault();
  hide("login-error");
  const credential = $("credential").value;
  const result = await api("/api/session", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ credential }),
  });
  if (result.status !== 200 || !result.body || !result.body.csrf) {
    $("login-error").textContent = "Sign-in failed. Check the credential.";
    show("login-error");
    return;
  }
  state.csrf = result.body.csrf;
  hide("login-card");
  show("dashboard");
  startEvents();
  await refreshStatus();
}

function startEvents() {
  if (state.events) state.events.close();
  const source = new EventSource("/api/events");
  state.events = source;
  source.onmessage = () => refreshStatus();
  source.onerror = () => { source.close(); };
}

async function resumeSession() {
  const result = await api("/api/session");
  if (result.status === 200 && result.body && result.body.csrf) {
    state.csrf = result.body.csrf;
    hide("login-card");
    show("dashboard");
    startEvents();
    await refreshStatus();
  }
}

async function logout() {
  await api("/api/logout", { method: "POST" });
  if (state.events) state.events.close();
  state.csrf = null;
  location.reload();
}

$("login-form").addEventListener("submit", login);
$("logout").addEventListener("click", logout);
resumeSession();
