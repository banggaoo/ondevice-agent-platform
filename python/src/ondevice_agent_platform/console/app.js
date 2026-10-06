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
  return new Date(epoch * 1000).toLocaleTimeString();
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
  $("chat-stop").addEventListener("click", stopOperatorPrompt);
}

/* ---- refresh ---- */

/* All three reads must succeed before rendering: a partial success must
 * not erase previously displayed registry/jobs data or the warning. */
async function refreshStatus() {
  const [status, registry, jobs] = await Promise.all([
    consoleGet("/api/status"), consoleGet("/api/registry"), consoleGet("/api/jobs"),
  ]);
  if (status.status !== 200 || !status.body
      || registry.status !== 200 || !registry.body
      || jobs.status !== 200 || !jobs.body) {
    show("offline");
    return;
  }
  hide("offline");
  state.data = { status: status.body, registry: registry.body, jobs: jobs.body };
  state.operator = detectOperator(registry.body);
  renderOverview(status.body);
  renderModels(registry.body);
  renderJobs(jobs.body.jobs || []);
  renderChatMeta();
}

/* Event stream: one delayed, controlled reconnect through a fresh session
 * per failure. The retry budget resets only on a delivered status frame -
 * a bare open is not proof of health - and stale sources or a pending
 * timer can never schedule a parallel reconnect. No rapid loop. */
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
    if (state.eventReconnects >= 1) { show("offline"); return; }
    state.eventReconnects += 1;
    state.reconnectTimer = setTimeout(() => {
      state.reconnectTimer = null;
      if (state.events === source) reconnectEvents();
    }, 1000);
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
