/* Console client: automatic local session bootstrap -> cookie session +
 * in-memory CSRF. No credential is ever typed, stored, or shown in the
 * page. Untrusted values are rendered with textContent only. */
"use strict";

const VIEWS = ["overview", "models", "history", "train", "chat"];

const state = { csrf: null, events: null, sessionPromise: null,
                eventReconnects: 0, reconnectTimer: null,
                data: null, operator: null,
                chatAbort: null, chatPending: false };

const $ = (id) => document.getElementById(id);

function show(id) { $(id).hidden = false; }
function hide(id) { $(id).hidden = true; }

function setText(id, value) {
  $(id).textContent = value == null ? "unknown" : String(value);
}

async function api(path, options = {}) {
  const headers = Object.assign({}, options.headers || {});
  if (state.csrf) headers["X-CSRF-Token"] = state.csrf;
  try {
    const response = await fetch(path, Object.assign({}, options, {
      headers,
      credentials: "same-origin",
    }));
    const text = await response.text();
    let body = null;
    try { body = JSON.parse(text); } catch { body = null; }
    return { status: response.status, body };
  } catch (e) {
    if (e && e.name === "AbortError") return { status: -1, body: null, aborted: true };
    return { status: 0, body: null };
  }
}

/* Deduplicated session bootstrap: reuse the presented cookie when valid,
 * else create a local session with an empty POST (the browser supplies
 * Origin). Only a 401 means an absent/expired session - a 403 or a
 * network failure is not a session problem and must not POST. Concurrent
 * callers share the same in-flight attempt; the promise clears on settle
 * so a later 401 can bootstrap again. */
function bootstrapSession() {
  if (!state.sessionPromise) {
    state.sessionPromise = (async () => {
      let result = await api("/api/session");
      if (result.status === 401) {
        result = await api("/api/session", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: "{}",
        });
      }
      if (result.status === 200 && result.body && result.body.csrf) {
        state.csrf = result.body.csrf;
        return true;
      }
      return false;
    })().finally(() => { state.sessionPromise = null; });
  }
  return state.sessionPromise;
}

/* Console reads recover an expired session once: 401 -> bootstrap -> one
 * retry. A second failure surfaces as offline instead of looping. */
async function consoleGet(path, retried) {
  const result = await api(path);
  if (result.status === 401 && !retried && await bootstrapSession()) {
    return consoleGet(path, true);
  }
  return result;
}

/* ---- view routing ---- */

function currentView() {
  const hash = typeof location === "undefined" ? "" : (location.hash || "");
  const name = hash.slice(1) || "overview";
  return VIEWS.includes(name) ? name : "overview";
}

let appliedView = "";
function switchView() {
  const name = currentView();
  for (const view of VIEWS) {
    $("view-" + view).hidden = view !== name;
    const nav = $("nav-" + view);
    if (typeof nav.setAttribute !== "function") continue;
    if (view === name) {
      nav.setAttribute("aria-current", "page");
    } else {
      nav.removeAttribute("aria-current");
    }
  }
  /* A nav hash like #models must not land mid-page on a data element;
   * reset scroll on an actual view change. */
  if (name !== appliedView) {
    appliedView = name;
    if (typeof window !== "undefined" && typeof window.scrollTo === "function") {
      window.scrollTo(0, 0);
    }
  }
}

/* ---- rendering ---- */

/* Provenance is labeled, never re-derived: a kernel percent gauge is an
 * estimate, not measured headroom; event and unknown sources stay distinct. */
function pressureSourceLabel(source) {
  switch (source) {
    case "dispatch_event": return "Kernel pressure event";
    case "available_percent_estimate":
      return "Kernel gauge estimate; not calibrated headroom";
    case "unavailable": return "pressure signal unavailable";
    default: return "source unknown";
  }
}

function artifactReadyLabel(value) {
  if (value === true) return "artifact ready";
  if (value === false) return "artifact unavailable";
  return "artifact unverified";
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

function renderOverview(s) {
  const resource = s.resource || {};
  setText("thermal", resource.thermal);
  setText("pressure", resource.memoryPressure);
  setText("pressure-source", pressureSourceLabel(resource.memoryPressureSource));
  setText("lowpower", resource.lowPowerMode == null ? "unknown"
    : (resource.lowPowerMode ? "yes" : "no"));
  setText("apple", s.appleAvailability);
  /* The daemon's evaluated admission verdict is the truthful resource
   * signal; the page never re-derives policy thresholds from raw fields. */
  setText("admission", resource.admission);
  resource.admission === "admit" ? hide("denied") : show("denied");
  const counts = s.counts || {};
  setText("active", counts.activeInference);
  setText("pending", counts.pendingInference);
  setText("blocked", counts.inferenceBlocked);
  const active = counts.activeInference || 0;
  const pending = counts.pendingInference || 0;
  setText("slots", active + pending);
  if (counts.inferenceCapacity != null) {
    setText("slots-total", counts.inferenceCapacity);
  }
  const cats = s.categories || {};
  setText("cat-apple", cats.appleFoundationModels);
  setText("cat-owned", cats.ownedOpenWeight);
  setText("cat-ml", cats.typedML);
}

function renderModels(registry) {
  /* Rich profiles when the daemon reports them; plain alias lists remain
   * the fallback for an older or partial server response. */
  const profiles = registry.modelProfiles;
  const ul = $("model-list");
  ul.textContent = "";
  if (Array.isArray(profiles) && profiles.length) {
    for (const p of profiles.slice(0, 50)) {
      const li = document.createElement("li");
      const source = p.source
        ? `${p.source.repo}@${p.source.revision}` : "no declared source";
      li.textContent = `${p.alias} — ${p.kind || "?"} · ${p.provider || "?"}` +
        ` · ${p.task || "?"}` +
        (p.purposes && p.purposes.length ? ` · ${p.purposes.join("/")}` : "") +
        ` · cap ${p.maxOutputTokens == null ? "?" : p.maxOutputTokens}` +
        (p.imageMaxSoftTokens != null
          ? ` · img tokens ${p.imageMaxSoftTokens}` : "") +
        ` · ${source}` +
        ` · provider ${p.providerRegistered ? "registered" : "unregistered"}` +
        ` · ${artifactReadyLabel(p.artifactReady)}`;
      ul.appendChild(li);
    }
  } else {
    renderList(ul, registry.models || [], "none registered");
  }
  const agentProfiles = registry.agentProfiles;
  const agentsUl = $("agents");
  agentsUl.textContent = "";
  if (Array.isArray(agentProfiles) && agentProfiles.length) {
    for (const a of agentProfiles.slice(0, 50)) {
      const li = document.createElement("li");
      li.textContent = `${a.id} — v${a.version}` +
        ` · harness ${a.harnessId} v${a.harnessVersion}` +
        ` · model ${a.model || "none"}` +
        ` · tools ${(a.toolScope || []).length}`;
      agentsUl.appendChild(li);
    }
  } else {
    renderList(agentsUl, registry.agents || [], "none registered");
  }
}

function jobTime(epoch) {
  if (typeof epoch !== "number") return "-";
  const d = new Date(epoch * 1000);
  if (d.toDateString() === new Date().toDateString()) {
    return d.toLocaleTimeString();
  }
  return d.toLocaleDateString() + " " + d.toLocaleTimeString();
}

function renderJobs(jobs) {
  const tbody = $("jobs");
  tbody.textContent = "";
  for (const job of jobs.slice(0, 50)) {
    const tr = document.createElement("tr");
    for (const key of ["id", "kind", "consumer", "state"]) {
      const td = document.createElement("td");
      if (key === "kind" && job.detail) {
        td.textContent = job.detail;
      } else if (key === "state" && job.progress != null) {
        td.textContent = `${job.state} ${Math.round(job.progress * 100)}%`;
      } else {
        td.textContent = job[key];
      }
      tr.appendChild(td);
    }
    const parent = document.createElement("td");
    parent.textContent = job.parentId || "-";
    tr.appendChild(parent);
    const updated = document.createElement("td");
    updated.textContent = jobTime(job.updatedAt);
    tr.appendChild(updated);
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
  const result = await api(`/api/jobs/${encoded}/cancel`, { method: "POST" });
  /* Mutations are never retried automatically after a lost session or CSRF:
   * re-establish the session for the next click and refresh state so the
   * user can decide to stop again. */
  if (result.status === 401 || result.status === 403) {
    await bootstrapSession();
  }
  await refreshStatus();
}

/* ---- installs: catalog models + Operator ---- */

/* Mutations are retried only for session loss: the re-bootstrap fixes the
 * next click; the failed action itself is never replayed automatically. */
async function modelMutation(path, body) {
  const result = await api(path, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  if (result.status === 401 || result.status === 403) {
    await bootstrapSession();
  }
  if (result.status !== 200) {
    const err = result.body && result.body.error;
    const msg = (err && typeof err === "object" && err.message) ||
      `request failed (status ${result.status || "unreachable"})`;
    setText("catalog-status", msg);
    show("catalog-status");
  } else {
    hide("catalog-status");
  }
  await refreshStatus();
}

function pullJobFor(alias, jobs) {
  return jobs.find((j) => j.kind === "admin" && j.detail === `pull ${alias}`
    && ["active", "cancel_requested", "queued"].includes(j.state));
}

function actionButton(label, fn) {
  const b = document.createElement("button");
  b.className = "rowbtn";
  b.textContent = label;
  b.addEventListener("click", fn);
  return b;
}

function renderCatalog(cat, registry, jobs) {
  $("env-missing").hidden = !cat || cat.providerEnvInstalled !== false;
  const ul = $("catalog-list");
  ul.textContent = "";
  const entries = (cat && cat.entries) || [];
  const profiles = (registry.modelProfiles || []);
  const shown = new Set();
  for (const e of entries.slice(0, 50)) {
    shown.add(e.alias);
    const li = document.createElement("li");
    li.className = "modelrow";
    const size = e.approxBytes ? ` ~${(e.approxBytes / 1e9).toFixed(1)} GB`
      : "";
    const job = pullJobFor(e.alias, jobs);
    let status;
    if (job) {
      status = `pulling ${Math.round((job.progress || 0) * 100)}%`;
    } else if (e.ready) {
      status = "installed";
    } else if (e.declared) {
      status = "declared";
    } else if (e.eligible) {
      status = "available";
    } else {
      status = e.reason || "not eligible";
    }
    li.textContent = `${e.alias} — ${e.summary || ""} · ${e.provider}${size}`
      + ` · ${status}`;
    if (!job && e.eligible !== false) {
      if (!e.ready) {
        li.appendChild(actionButton(e.declared ? "pull" : "install",
          () => modelMutation("/api/console/models/pull",
                              { alias: e.alias })));
      }
      if (e.ready) {
        li.appendChild(actionButton("remove",
          () => modelMutation("/api/console/models/remove",
                              { alias: e.alias })));
      }
    }
    ul.appendChild(li);
  }
  /* Declared profiles outside the catalog (composite routes like
   * vision-hybrid) still list, status-only. */
  for (const p of profiles) {
    if (shown.has(p.alias)) continue;
    const li = document.createElement("li");
    li.className = "modelrow";
    li.textContent = `${p.alias} — ${p.provider || "?"} · declared · `
      + artifactReadyLabel(p.artifactReady);
    ul.appendChild(li);
  }
}

function renderOperator(registry) {
  const op = (registry.agentProfiles || []).find((a) => a.id === "operator");
  const models = (registry.modelProfiles || [])
    .filter((p) => p.kind === "llm" &&
      ["mlx", "llamacpp", "apple-foundation-models"].includes(p.provider));
  const sel = $("op-model");
  const want = models.map((p) => p.alias).join("|");
  if (sel.dataset.models !== want) {
    sel.dataset.models = want;
    sel.textContent = "";
    for (const p of models) {
      const opt = document.createElement("option");
      opt.value = p.alias;
      opt.textContent = p.alias + (p.artifactReady ? "" : " (not pulled)");
      sel.appendChild(opt);
    }
  }
  if (op && op.model && sel.dataset.models.includes(op.model)) {
    sel.value = op.model;
  }
  setText("op-state", op ? `enabled - bound to ${op.model || "?"}`
                         : "not enabled");
  $("op-enable").disabled = models.length === 0;
  $("op-disable").disabled = !op;
}

function initOperator() {
  $("op-enable").addEventListener("click", () => {
    const model = $("op-model").value;
    if (model) {
      modelMutation("/api/console/operator", { model });
    }
  });
  $("op-disable").addEventListener("click", () => {
    modelMutation("/api/console/operator", { enabled: false });
  });
}

/* ---- Operator chat ---- */

function detectOperator(registry) {
  const profiles = registry.agentProfiles;
  if (Array.isArray(profiles)) {
    const op = profiles.find((a) => a && a.id === "operator");
    if (op) return { model: op.model || null,
                     harness: `${op.harnessId} v${op.harnessVersion}` };
  }
  if (Array.isArray(registry.agents) && registry.agents.includes("operator")) {
    return { model: null, harness: "operator.runtime" };
  }
  return null;
}

function renderChatMeta() {
  const op = state.operator;
  if (op) {
    hide("chat-unavailable");
    setText("chat-model", op.model || "unbound");
    setText("chat-harness", op.harness || "operator.runtime");
    $("chat-input").disabled = false;
    $("chat-send").disabled = state.chatPending;
  } else {
    show("chat-unavailable");
    setText("chat-model", "none");
    setText("chat-harness", "none");
    setText("chat-status", "");
    $("chat-input").disabled = true;
    $("chat-send").disabled = true;
    $("chat-stop").hidden = true;
  }
}

function chatEntry(kind, text) {
  const div = document.createElement("div");
  div.className = "chatmsg " + kind;
  div.textContent = text;
  $("chat-log").appendChild(div);
  return div;
}

function stopLabel(stopReason) {
  switch (stopReason) {
    case "end_turn": return "complete";
    case "max_tokens": return "partial answer - token limit reached";
    case "refusal": return "the Operator declined to answer";
    case "cancelled": return "cancelled";
    default: return stopReason || "error";
  }
}

/* A prompt is sent exactly once: an abort cancels the in-flight request
 * (the daemon cancels the turn), and a 401 or network failure is reported
 * without re-running inference. */
async function sendOperatorPrompt(text) {
  if (state.chatPending || !state.operator) return;
  state.chatPending = true;
  $("chat-send").disabled = true;
  $("chat-stop").hidden = false;
  setText("chat-status", "asking the runtime Operator");
  const controller = new AbortController();
  state.chatAbort = controller;
  const result = await api("/api/console/operator/prompt", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ text }),
    signal: controller.signal,
  });
  state.chatPending = false;
  state.chatAbort = null;
  $("chat-stop").hidden = true;
  $("chat-send").disabled = !state.operator;
  if (result.aborted) {
    setText("chat-status", "cancelled");
    chatEntry("chat-note", "cancelled");
    return;
  }
  if (result.status === 200 && result.body) {
    const answer = result.body;
    const message = answer.text || "(empty reply)";
    chatEntry("chat-answer", message);
    setText("chat-status", stopLabel(answer.stopReason));
    return;
  }
  if (result.status === 401 || result.status === 403) {
    /* Re-establish the session for the next question; this prompt was
     * attempted once and is not retried automatically. */
    await bootstrapSession();
  }
  /* The wire error body is {error: {code, message}} - render the safe
   * message (and code) rather than coercing an object into the page. */
  const err = result.body && result.body.error;
  const detail = typeof err === "string" ? err
    : err && typeof err === "object"
      ? [err.message, err.code !== undefined ? `(${err.code})` : null]
          .filter(Boolean).join(" ")
      : `request failed (status ${result.status || "unreachable"})`;
  setText("chat-status", "error: " + detail);
  chatEntry("chat-note", "error: " + detail);
}

function stopOperatorPrompt() {
  if (state.chatAbort) state.chatAbort.abort();
}

function initChat() {
  $("chat-form").addEventListener("submit", (event) => {
    event.preventDefault();
    /* An ignored submit (pending turn or no Operator) must not clear the
     * draft or log a phantom question. */
    if (state.chatPending || !state.operator) return;
    const text = $("chat-input").value;
    if (!text || !text.trim()) return;
    $("chat-input").value = "";
    chatEntry("chat-question", text);
    sendOperatorPrompt(text);
  });
  $("chat-input").addEventListener("keydown", (event) => {
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault();
      $("chat-form").requestSubmit();
    }
  });
  $("chat-stop").addEventListener("click", stopOperatorPrompt);
}

/* ---- refresh ---- */

/* All three reads must succeed before rendering: a partial success must
 * not erase previously displayed registry/jobs data or the warning.
 * The event stream ticks every 2s; a slow daemon must not stack fetches,
 * so a refresh already in flight is not duplicated. */
let refreshInFlight = false;
async function refreshStatus() {
  if (refreshInFlight) return;
  refreshInFlight = true;
  try {
    const [status, registry, jobs, catalog] = await Promise.all([
      consoleGet("/api/status"), consoleGet("/api/registry"),
      consoleGet("/api/jobs"), consoleGet("/api/catalog"),
    ]);
    if (status.status !== 200 || !status.body
        || registry.status !== 200 || !registry.body
        || jobs.status !== 200 || !jobs.body
        || catalog.status !== 200 || !catalog.body) {
      show("offline");
      return;
    }
    hide("offline");
    state.data = { status: status.body, registry: registry.body,
                   jobs: jobs.body, catalog: catalog.body };
    state.operator = detectOperator(registry.body);
    renderOverview(status.body);
    renderModels(registry.body);
    renderJobs(jobs.body.jobs || []);
    renderCatalog(catalog.body, registry.body, jobs.body.jobs || []);
    renderOperator(registry.body);
    renderChatMeta();
  } finally {
    refreshInFlight = false;
  }
}

/* Event stream: delayed, controlled reconnects through a fresh session
 * per failure, with exponential backoff capped at 30s. The delay ladder
 * resets only on a delivered status frame - a bare open is not proof of
 * health - and stale sources or a pending timer can never schedule a
 * parallel reconnect. A daemon restart or dropped network therefore
 * recovers instead of leaving the console dead until reload; the minimum
 * delay keeps the loop slow. */
function startEvents() {
  if (state.reconnectTimer) {
    clearTimeout(state.reconnectTimer);
    state.reconnectTimer = null;
  }
  if (state.events) state.events.close();
  const source = new EventSource("/api/events");
  state.events = source;
  source.onmessage = () => {
    if (source !== state.events) return;
    state.eventReconnects = 0;
    refreshStatus();
  };
  source.onerror = () => {
    if (source !== state.events || state.reconnectTimer) return;
    source.close();
    if (state.eventReconnects >= 2) show("offline");
    const delay = Math.min(30000, 1000 * (1 << state.eventReconnects));
    state.eventReconnects += 1;
    state.reconnectTimer = setTimeout(() => {
      state.reconnectTimer = null;
      if (state.events === source) reconnectEvents();
    }, delay);
  };
}

async function reconnectEvents() {
  if (await bootstrapSession()) {
    startEvents();
  } else {
    show("offline");
  }
}

async function start() {
  if (await bootstrapSession()) {
    hide("connstate");
    switchView();
    initChat();
    initOperator();
    startEvents();
    await refreshStatus();
  } else {
    hide("connstate");
    show("offline");
  }
}

if (typeof window !== "undefined" && window.addEventListener) {
  window.addEventListener("hashchange", switchView);
}
start();
