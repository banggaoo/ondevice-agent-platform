"use strict";

/* Behavioral coverage for the console client using only Node built-ins:
 * node:test + vm with mocked DOM, fetch, EventSource, and timers.
 * CSRF/header values below are fixed test fixtures, not real secrets. */

const test = require("node:test");
const assert = require("node:assert/strict");
const vm = require("node:vm");
const fs = require("node:fs");
const path = require("node:path");

const APP_JS = path.join(__dirname, "..", "..",
  "Sources", "PlatformServing", "Console", "app.js");
const SOURCE = fs.readFileSync(APP_JS, "utf8");

const settle = () => new Promise((r) => setTimeout(r, 10));
const json = (status, body) => ({ status, text: async () => JSON.stringify(body) });

function statusBody(overrides = {}) {
  return {
    resource: Object.assign({
      thermal: "nominal", memoryPressure: "normal", lowPowerMode: false,
      capturedAt: 1, admission: "admit",
    }, overrides),
    appleAvailability: "available",
    categories: { appleFoundationModels: 1, ownedOpenWeight: 1, typedML: 0 },
    counts: { activeInference: 0, pendingInference: 0, inferenceBlocked: false },
  };
}
const REGISTRY = { models: ["qwen-small"], agents: ["reference.status"] };
const JOBS = { jobs: [] };

class El {
  constructor(id) {
    this.id = id;
    this.hidden = false;
    this.disabled = false;
    this._text = "";
    this.children = [];
    this.listeners = {};
    this.className = "";
    this.attributes = {};
    this.value = "";
  }
  set textContent(v) { this._text = String(v); this.children = []; }
  get textContent() { return this._text; }
  appendChild(c) { this.children.push(c); }
  addEventListener(type, fn) { this.listeners[type] = fn; }
  setAttribute(k, v) { this.attributes[k] = String(v); }
  removeAttribute(k) { delete this.attributes[k]; }
}

class MockAbortController {
  constructor() {
    this.signal = { aborted: false, _listeners: [],
      addEventListener(_t, fn) { this._listeners.push(fn); } };
  }
  abort() {
    this.signal.aborted = true;
    for (const fn of this.signal._listeners) fn();
  }
}

/* Loads app.js into a fresh vm realm. fetchImpl(url, options) returns
 * {status, text}; EventSource instances support error()/message();
 * setTimeout callbacks are captured for manual firing via runTimers(). */
function makeEnv(fetchImpl) {
  const elements = new Map();
  const byId = (id) => {
    if (!elements.has(id)) elements.set(id, new El(id));
    return elements.get(id);
  };
  const fetchCalls = [];
  const esInstances = [];
  const timers = [];
  const scrollCalls = [];
  const context = {
    window: {
      addEventListener: () => {},
      scrollTo: (x, y) => scrollCalls.push([x, y]),
    },
    document: {
      getElementById: byId,
      createElement: (tag) => new El(tag),
    },
    fetch: async (url, options = {}) => {
      fetchCalls.push({ url, options });
      return fetchImpl(url, options);
    },
    /* error()/message() deliberately deliver to closed instances too, so
     * stale-source guards in app.js are exercised rather than hidden. */
    EventSource: class {
      constructor(url) { this.url = url; this.closed = false; esInstances.push(this); }
      close() { this.closed = true; }
      error() { if (this.onerror) this.onerror(); }
      message() { if (this.onmessage) this.onmessage({ data: "{}" }); }
    },
    setTimeout: (fn, ms) => { const t = { fn, ms, cleared: false }; timers.push(t); return t; },
    clearTimeout: (t) => { if (t) t.cleared = true; },
    AbortController: MockAbortController,
    location: { hash: "" },
  };
  vm.createContext(context);
  vm.runInContext(SOURCE, context);
  const runTimers = () => {
    for (const t of timers.splice(0)) if (!t.cleared) t.fn();
  };
  return { context, elements, byId, fetchCalls, esInstances, timers, runTimers,
    scrollCalls };
}

function healthyFetch(url, options = {}) {
  const method = options.method || "GET";
  if (url === "/api/session" && method === "GET") {
    return json(200, { session: "s1", csrf: "csrf-fixture-1", expiresAt: 1 });
  }
  if (url === "/api/session" && method === "POST") {
    return json(200, { session: "s2", csrf: "csrf-fixture-2", expiresAt: 1 });
  }
  if (url === "/api/status") return json(200, statusBody());
  if (url === "/api/registry") return json(200, REGISTRY);
  if (url === "/api/jobs") return json(200, JOBS);
  return json(404, {});
}

test("startup: GET session 401 -> exactly one empty POST bootstrap -> dashboard populated, no credential UI", async () => {
  const posts = [];
  const env = makeEnv(async (url, options = {}) => {
    const method = options.method || "GET";
    if (url === "/api/session" && method === "GET") return json(401, {});
    if (url === "/api/session" && method === "POST") {
      posts.push(options);
      return json(200, { session: "s1", csrf: "csrf-fixture", expiresAt: 1 });
    }
    return healthyFetch(url, options);
  });
  await settle();

  assert.equal(posts.length, 1);
  assert.equal(posts[0].body, "{}");
  assert.equal(env.byId("connstate").hidden, true);
  assert.equal(env.byId("thermal").textContent, "nominal");
  assert.equal(env.byId("admission").textContent, "admit");
  assert.equal(env.byId("model-list").children[0].textContent, "qwen-small");
  assert.equal(env.byId("agents").children[0].textContent, "reference.status");
  assert.equal(env.esInstances.length, 1);
  // No credential element was ever looked up and no credential was sent.
  assert.ok(!env.elements.has("credential"));
  assert.ok(!env.elements.has("login-form"));
  assert.ok(!env.elements.has("login-error"));
});

test("GET session 403 does not POST bootstrap or loop", async () => {
  const env = makeEnv(async (url, options = {}) => {
    if (url === "/api/session" && (options.method || "GET") === "GET") {
      return json(403, {});
    }
    return healthyFetch(url, options);
  });
  await settle();
  assert.equal(env.fetchCalls.filter((c) => c.options.method === "POST").length, 0);
  assert.equal(env.fetchCalls.length, 1);
  assert.equal(env.byId("offline").hidden, false);
  assert.equal(env.esInstances.length, 0);
});

test("session network failure does not POST bootstrap or loop", async () => {
  const env = makeEnv(async () => { throw new Error("connection refused"); });
  await settle();
  assert.equal(env.fetchCalls.length, 1);
  assert.equal(env.byId("offline").hidden, false);
  assert.equal(env.esInstances.length, 0);
});

test("concurrent read 401s share a single session bootstrap", async () => {
  let phase = "valid";
  let bootPosts = 0;
  const env = makeEnv(async (url, options = {}) => {
    const method = options.method || "GET";
    if (url === "/api/session" && method === "GET") {
      if (phase === "expired") return json(401, {});
      return json(200, { session: "s1", csrf: "csrf-fixture-1", expiresAt: 1 });
    }
    if (url === "/api/session" && method === "POST") {
      bootPosts += 1;
      phase = "renewed";
      return json(200, { session: "s2", csrf: "csrf-fixture-2", expiresAt: 1 });
    }
    if (phase === "expired") return json(401, {});
    return healthyFetch(url, options);
  });
  await settle();

  phase = "expired";
  await env.context.refreshStatus();
  await settle();

  assert.equal(bootPosts, 1);
  assert.equal(env.byId("thermal").textContent, "nominal");
  assert.equal(env.byId("offline").hidden, true);
});

test("cancel 401 re-establishes the session; the cancel POST runs exactly once", async () => {
  let phase = "valid";
  let cancelPosts = 0;
  let bootPosts = 0;
  const env = makeEnv(async (url, options = {}) => {
    const method = options.method || "GET";
    if (url === "/api/session" && method === "GET") {
      if (phase === "expired") return json(401, {});
      return json(200, { session: "s1", csrf: "csrf-fixture-1", expiresAt: 1 });
    }
    if (url === "/api/session" && method === "POST") {
      bootPosts += 1;
      phase = "renewed";
      return json(200, { session: "s2", csrf: "csrf-fixture-2", expiresAt: 1 });
    }
    if (url === "/api/jobs/job-1/cancel" && method === "POST") {
      cancelPosts += 1;
      phase = "expired";
      return json(401, {});
    }
    if (phase === "expired") return json(401, {});
    return healthyFetch(url, options);
  });
  await settle();

  await env.context.cancelJob("job-1");
  await settle();

  assert.equal(cancelPosts, 1);
  assert.equal(bootPosts, 1);
  assert.equal(env.byId("offline").hidden, true);
});

test("open+error without a status frame does not reset the retry budget or reschedule", async () => {
  const env = makeEnv(healthyFetch);
  await settle();
  assert.equal(env.esInstances.length, 1);

  env.esInstances[0].error();
  assert.equal(env.timers.length, 1);
  assert.equal(env.timers[0].ms, 1000);

  env.runTimers();
  await settle();
  assert.equal(env.esInstances.length, 2);

  // The reconnect errored without ever delivering a frame: budget spent,
  // no third source, no pending timer, offline shown.
  env.esInstances[1].error();
  assert.equal(env.esInstances.length, 2);
  assert.equal(env.timers.length, 0);
  assert.equal(env.byId("offline").hidden, false);
});

test("duplicate errors and stale sources cannot schedule parallel reconnects", async () => {
  const env = makeEnv(healthyFetch);
  await settle();
  const es1 = env.esInstances[0];

  es1.error();
  es1.error();
  assert.equal(env.timers.length, 1);

  env.runTimers();
  await settle();
  assert.equal(env.esInstances.length, 2);

  // A stale source error after the reconnect must be ignored entirely.
  es1.error();
  assert.equal(env.timers.length, 0);
  assert.equal(env.esInstances.length, 2);

  // A late frame from the stale stream must not renew the live stream's budget.
  es1.message();
  await settle();
  env.esInstances[1].error();
  assert.equal(env.timers.length, 0);
});

test("a delivered status frame resets the reconnect budget", async () => {
  const env = makeEnv(healthyFetch);
  await settle();

  env.esInstances[0].error();
  env.runTimers();
  await settle();
  assert.equal(env.esInstances.length, 2);

  // A real status frame proves health: the next error may reconnect once.
  env.esInstances[1].message();
  await settle();
  env.esInstances[1].error();
  assert.equal(env.timers.length, 1);
  env.runTimers();
  await settle();
  assert.equal(env.esInstances.length, 3);
});

test("registry failure keeps displayed data and does not hide the resource warning", async () => {
  let failRegistry = false;
  const env = makeEnv(async (url, options = {}) => {
    if (url === "/api/registry" && failRegistry) return json(500, {});
    if (url === "/api/status") {
      return json(200, statusBody({ admission: "deny_and_cancel", thermal: "fair" }));
    }
    return healthyFetch(url, options);
  });
  await settle();

  const before = env.byId("model-list").children.length;
  assert.equal(before, 1);
  assert.equal(env.byId("denied").hidden, false);
  assert.equal(env.byId("admission").textContent, "deny_and_cancel");

  failRegistry = true;
  await env.context.refreshStatus();
  await settle();

  assert.equal(env.byId("offline").hidden, false);
  assert.equal(env.byId("model-list").children.length, before);
  assert.equal(env.byId("model-list").children[0].textContent, "qwen-small");
  assert.equal(env.byId("denied").hidden, false);
});

/* ---- multi-view console and Operator chat ---- */

const OP_REGISTRY = {
  models: ["qwen3.8-9b"], agents: ["operator"],
  modelProfiles: [{ alias: "qwen3.8-9b", kind: "llm", provider: "mlx",
    task: "chat", purposes: ["runtime-explanation"], capabilities: ["text"],
    providerRegistered: true, artifactReady: true, maxOutputTokens: 512,
    source: { repo: "nvythong/Qwen3.8-9B-Distill-mlx-4Bit",
              revision: "e827c31fbd588828f43180a87ab34415a6d8a4bf" } }],
  agentProfiles: [{ id: "operator", version: 1, stateSchemaVersion: 1,
    harnessId: "operator.runtime", harnessVersion: 1,
    model: "qwen3.8-9b", toolScope: [] }],
};

function opFetch(reply, urlMap = {}) {
  return async (url, options = {}) => {
    const method = options.method || "GET";
    if (url === "/api/registry") return json(200, OP_REGISTRY);
    if (url === "/api/console/operator/prompt" && method === "POST") {
      return typeof reply === "function" ? reply(options) : reply;
    }
    if (urlMap[url]) return urlMap[url](options);
    return healthyFetch(url, options);
  };
}

function submitChat(env, text = "Explain runtime status.") {
  env.byId("chat-input").value = text;
  env.byId("chat-form").listeners.submit({ preventDefault() {} });
}

test("nav switches five views, marks aria-current, resets scroll on switch", async () => {
  const env = makeEnv(healthyFetch);
  await settle();
  /* Startup lands on overview; each distinct hash change below must
   * scroll back to the top so a nav hash cannot leave the user
   * mid-page on a tall view. */
  const afterStartup = env.scrollCalls.length;
  for (const name of ["overview", "models", "history", "train", "chat"]) {
    env.context.location.hash = "#" + name;
    env.context.switchView();
    for (const v of ["overview", "models", "history", "train", "chat"]) {
      assert.equal(env.byId("view-" + v).hidden, v !== name);
      assert.equal(env.byId("nav-" + v).attributes["aria-current"],
        v === name ? "page" : undefined);
    }
  }
  /* overview->models->history->train->chat = 4 real switches; the
   * re-application of #overview is not a switch. */
  assert.equal(env.scrollCalls.length, afterStartup + 4);
  assert.deepEqual(env.scrollCalls[env.scrollCalls.length - 1], [0, 0]);

  env.context.location.hash = "#models";
  env.context.switchView();
  const onModels = env.scrollCalls.length;
  env.context.switchView();   // same hash again: not a switch
  assert.equal(env.scrollCalls.length, onModels);

  env.context.location.hash = "#bogus";
  env.context.switchView();
  assert.equal(env.byId("view-overview").hidden, false);
  assert.equal(env.scrollCalls.length, onModels + 1);   // models -> overview
});

test("Operator absent: chat is disabled and the view explains why", async () => {
  const env = makeEnv(healthyFetch);
  await settle();
  assert.equal(env.byId("chat-input").disabled, true);
  assert.equal(env.byId("chat-send").disabled, true);
  assert.equal(env.byId("chat-unavailable").hidden, false);
  assert.equal(env.byId("chat-model").textContent, "none");
  // No prompt was ever attempted.
  assert.equal(env.fetchCalls.filter(
    (c) => c.url === "/api/console/operator/prompt").length, 0);
});

test("Operator question: one POST, pinned metadata, answer via textContent", async () => {
  const posts = [];
  const env = makeEnv(opFetch((options) => {
    posts.push(options);
    return json(200, { agent: "operator", model: "qwen3.8-9b",
      text: "Runtime is nominal.", stopReason: "end_turn" });
  }));
  await settle();
  assert.equal(env.byId("chat-input").disabled, false);
  assert.equal(env.byId("chat-model").textContent, "qwen3.8-9b");
  assert.equal(env.byId("chat-harness").textContent, "operator.runtime v1");
  assert.equal(env.byId("chat-unavailable").hidden, true);

  submitChat(env);
  await settle();
  assert.equal(posts.length, 1);
  assert.equal(posts[0].method, "POST");
  assert.equal(JSON.parse(posts[0].body).text, "Explain runtime status.");
  const log = env.byId("chat-log").children;
  assert.equal(log.length, 2);
  assert.equal(log[0].className, "chatmsg chat-question");
  assert.equal(log[0].textContent, "Explain runtime status.");
  assert.equal(log[1].className, "chatmsg chat-answer");
  assert.equal(log[1].textContent, "Runtime is nominal.");
  assert.equal(env.byId("chat-status").textContent, "complete");
});

test("model output with markup renders as text, never as markup", async () => {
  const payload = "<img src=x onerror=alert(1)>";
  const env = makeEnv(opFetch(json(200, { agent: "operator",
    model: "qwen3.8-9b", text: payload, stopReason: "end_turn" })));
  await settle();
  submitChat(env);
  await settle();
  const answer = env.byId("chat-log").children.at(-1);
  assert.equal(answer.textContent, payload);
  assert.equal(answer.innerHTML, undefined);
});

test("max_tokens answer is labeled partial, not complete", async () => {
  const env = makeEnv(opFetch(json(200, { agent: "operator",
    model: "qwen3.8-9b", text: "truncated", stopReason: "max_tokens" })));
  await settle();
  submitChat(env);
  await settle();
  assert.equal(env.byId("chat-status").textContent,
    "partial answer - token limit reached");
});

test("pending send disables re-submit and shows Stop", async () => {
  let resolvePrompt;
  const env = makeEnv(opFetch(new Promise((r) => { resolvePrompt = r; })));
  await settle();
  submitChat(env);
  await settle();
  assert.equal(env.byId("chat-send").disabled, true);
  assert.equal(env.byId("chat-stop").hidden, false);
  // A second submit while pending sends nothing more.
  submitChat(env);
  await settle();
  assert.equal(env.fetchCalls.filter(
    (c) => c.url === "/api/console/operator/prompt").length, 1);
  resolvePrompt(json(200, { agent: "operator", model: "qwen3.8-9b",
    text: "done", stopReason: "end_turn" }));
  await settle();
  assert.equal(env.byId("chat-send").disabled, false);
});

test("Stop aborts the in-flight question exactly once", async () => {
  let calls = 0;
  const env = makeEnv(opFetch((options) => {
    calls += 1;
    return new Promise((_res, rej) => {
      options.signal.addEventListener("abort", () => {
        const e = new Error("aborted"); e.name = "AbortError"; rej(e);
      });
    });
  }));
  await settle();
  submitChat(env);
  await settle();
  env.context.stopOperatorPrompt();
  await settle();
  assert.equal(calls, 1);
  assert.equal(env.byId("chat-status").textContent, "cancelled");
  assert.equal(env.byId("chat-send").disabled, false);
});

test("Operator error is reported, never shown as a success or retried", async () => {
  const env = makeEnv(opFetch(json(503, { error: "unavailable" })));
  await settle();
  submitChat(env);
  await settle();
  assert.equal(env.fetchCalls.filter(
    (c) => c.url === "/api/console/operator/prompt").length, 1);
  assert.equal(env.byId("chat-status").textContent, "error: unavailable");
  const last = env.byId("chat-log").children.at(-1);
  assert.equal(last.className, "chatmsg chat-note");
});

test("ignored submit while pending preserves the draft and logs nothing", async () => {
  let resolvePrompt;
  const env = makeEnv(opFetch(new Promise((r) => { resolvePrompt = r; })));
  await settle();
  submitChat(env);
  await settle();
  const questions = () => env.byId("chat-log").children
    .filter((c) => c.className === "chatmsg chat-question").length;
  assert.equal(questions(), 1);

  // A second submit while pending is ignored: the draft stays in the
  // input and no phantom question is appended.
  env.byId("chat-input").value = "draft still typing";
  env.byId("chat-form").listeners.submit({ preventDefault() {} });
  await settle();
  assert.equal(env.byId("chat-input").value, "draft still typing");
  assert.equal(questions(), 1);
  assert.equal(env.fetchCalls.filter(
    (c) => c.url === "/api/console/operator/prompt").length, 1);
  resolvePrompt(json(200, { agent: "operator", model: "qwen3.8-9b",
    text: "done", stopReason: "end_turn" }));
  await settle();
});

test("ignored submit when Operator is absent preserves the draft", async () => {
  const env = makeEnv(healthyFetch); // no operator in this registry
  await settle();
  assert.equal(env.byId("chat-input").disabled, true);
  env.byId("chat-input").value = "Explain runtime status.";
  env.byId("chat-form").listeners.submit({ preventDefault() {} });
  await settle();
  assert.equal(env.byId("chat-input").value, "Explain runtime status.");
  assert.equal(env.byId("chat-log").children.length, 0);
  assert.equal(env.fetchCalls.filter(
    (c) => c.url === "/api/console/operator/prompt").length, 0);
});

test("structured Operator error renders message and code, one POST", async () => {
  const env = makeEnv(opFetch(json(504, {
    error: { message: "deadline exceeded", code: "deadline_exceeded" } })));
  await settle();
  submitChat(env);
  await settle();
  assert.equal(env.fetchCalls.filter(
    (c) => c.url === "/api/console/operator/prompt").length, 1);
  const status = env.byId("chat-status").textContent;
  assert.ok(status.includes("deadline exceeded"), status);
  assert.ok(status.includes("deadline_exceeded"), status);
  assert.ok(!status.includes("[object Object]"), status);
  const last = env.byId("chat-log").children.at(-1);
  assert.equal(last.className, "chatmsg chat-note");
  assert.ok(last.textContent.includes("deadline exceeded"));
});

test("kernel gauge estimate is labeled as estimate, not headroom", async () => {
  const env = makeEnv(async (url, options = {}) => {
    if (url === "/api/status") {
      return json(200, statusBody({
        memoryPressure: "normal",
        memoryPressureSource: "available_percent_estimate" }));
    }
    return healthyFetch(url, options);
  });
  await settle();
  assert.equal(env.byId("pressure-source").textContent,
    "Kernel gauge estimate; not calibrated headroom");
});
