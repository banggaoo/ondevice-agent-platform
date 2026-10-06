# Development baseline

The user approved proposal v0.9 and explicitly requested development on
2026-10-04: "approve proposal, proceed development". M0 is complete. Start with
M1, the code-owned serving foundation; this does not authorize publication,
model downloads, training, general tool execution, or cloud access.

This document records the selected first-increment design. Implementation and
test results must be reported separately from these intentions.

## Components

- A dependency-free Swift package targets macOS 27 on Apple Silicon.
- PlatformCore owns PlatformSupervisor, scoped authorization, validated
  registries, SQLite records, admission, cancellation, and resource observations.
- PlatformServing supplies the loopback HTTP boundary, OpenAI-compatible
  adapter, ACP bridge, and bundled console assets.
- The ondevice-agent-platform executable starts the one shared core. Its ACP
  stdio facade connects to that core rather than creating another supervisor.
- LLMProvider and MLPredictor are separate injectable provider contracts. An
  empty provider registry is valid; no test fixture is advertised as inference.
- AgentService resolves immutable agent/harness versions. The optional
  reference.status agent is deterministic, read-only, and not the Operator.

## First-increment contracts

Serve POST /v1/chat/completions and GET /v1/models on the trusted-local
boundary. The initial
text contract preserves ordered system/developer/user/assistant messages and
accepts bounded text strings or text content parts. Unsupported inputs fail
explicitly; the current surface is documented per-increment below (images and
structured-output hints were added in the multimodal increment; function
tools, tool results, and SSE streaming were added in the OpenCode contract
increment). Do not discard fields, truncate history, impersonate a cloud
model, interpret prompt text as administration, or turn model requests into
agent runs.

No real LLM or ML artifact is qualified in M1. Provider categories include Apple
Foundation Models, owned open-weight LLMs, and typed ML from the start. Apple
availability can be observed without generation; framework availability is not
the same as a qualified serving route. Owned-engine and Core ML artifact
qualification belong to M2.

MLService uses registered task/input/output schemas and the same scoped
admission as LLMService. Its initial typed JSON seam accepts a registered model,
task, and inputs; no arbitrary path or model loader is exposed. Unavailable
profiles fail truthfully. LLM-call and ML-prediction counts remain separate.

ACP is pinned to v1. The facade binds its registered agent before session/new.
Implement initialize, session/new, session/prompt, session/update, and
session/cancel with v1 turn completion and newline-delimited JSON-RPC stdio.
The internal HTTP bridge is not advertised as a standardized ACP transport.
Cancellation completes the original prompt with stopReason cancelled; it does
not destroy the session or send a response to a notification.

M1 refuses every nonempty MCP configuration and unadvertised optional
capability. Accept resource links as bounded metadata without fetching or
reading them. This is a deliberately restricted development subset, not a claim
of full ACP conformance: required stdio MCP connectivity remains a M3 gate.
The reference agent only understands an explicit status command; arbitrary
instructions are refused without inference or side effects.

## Local authority

Bind only 127.0.0.1 and validate the exact Host and any supplied Origin.
Use one request per HTTP connection, bounded HTTP/1.1 framing, and explicit
errors for unsupported transfer encodings, ambiguous lengths, or trailing
requests. Connection and request-read limits apply before route dispatch.

The platform issues no API access tokens and stores no credentials: local
model, agent, and administration routes each run under a fixed code-owned
consumer principal whose scope's base grants apply deterministically
(`LocalConsumers.model`, `LocalConsumers.agent`,
`LocalConsumers.administration`). An incoming `Authorization` header is
ignored for SDK compatibility; no header, body field, or prompt text can
select a different principal or grant. Tests register fake principals
directly rather than minting secrets.

The console is a trusted-local, single-user development surface: the browser
posts an empty same-origin bootstrap to obtain an expiring HttpOnly,
SameSite=Strict cookie and an in-memory CSRF token; no credential is typed or
stored in the page. Automatic bootstrap trusts local users and processes -
localhost alone is not identity authentication - and exact same-origin plus
CSRF checks protect browser mutations rather than isolating the daemon from
other local programs. Require an exact Origin on bootstrap and on every
cookie-backed mutation; a supplied Sec-Fetch-Site marker must not be
cross-site. Logout still invalidates the session and its event subscriptions.
No permissive CORS, localStorage credentials, inline scripts, remote assets,
or arbitrary file serving.

Core status, registry, job listing, and scoped stop never acquire an inference
slot. A served agent has no stop/admin grant from its name, prompt, resource
link, or client capability advertisement. Recheck grants on queued dispatch;
revocation overrides pinned definitions.

## Scheduling and records

PlatformLimits.swift is the authoritative lead-authored development policy.
Its values are conservative experiment bounds, not benchmark results or
minimum-device guarantees. The queue is finite and consumer-fair.

Do not release the active inference slot merely because a task is cancelled.
A noncooperative provider retains the slot until it actually terminates;
after the cancellation grace, report unconfirmed cancellation and block new
inference while leaving administration available. Queued requests have finite
expiry. Disconnect, shutdown, resource denial, and agent cancellation propagate
to child work. An agent session never owns an inference slot.

Native observations use public thermal/power APIs and memory-pressure events.
Unknown or stale critical observations block inference. Do not replace an
unknown pressure observation with an invented normal value or use private
sysctl readings. os_proc_available_memory is unavailable on macOS in the
installed SDK and is not a platform headroom API.

Use the selected ~/.ondevice-agent-platform root, with an explicit absolute
--data-root override for isolated development/tests. Restrict owned directories
to 0700 and files to 0600. Refuse symlinked state files and unsafe/non-owned
roots. Hold a per-root exclusive lifetime lock; never overwrite an unrelated
directory or start two authoritative stores for the same root.

SQLite schema v1 stores content-free job/session/profile metadata, immutable
version references, and bounded counters. Transactions protect transitions;
enable WAL, FULL synchronization, foreign keys, and a bounded busy timeout.
Restart marks unfinished jobs interrupted instead of replaying them. Saved
session identifiers do not imply session/load support. No raw prompts, outputs,
screenshots, credentials, training directories, or mandatory session folders.
Storage exhaustion refuses new records rather than silently deleting history.

## Verification

Use controlled providers and directly registered fake principals, not
downloaded models or live cloud services. Cover core independence;
conversation preservation; unsupported/malformed/oversized requests;
scope/Origin/CSRF
denials; finite queue/expiry; stale pressure; cooperative and unconfirmed
cancellation; separate LLM/ML accounting; SQLite restart, exclusive locking, and
symlink refusal; ACP negotiation, session isolation, version pinning, updates,
notification cancellation, and MCP denial.

Run the built executable's help and the targeted Swift tests offline. Exercise
actual loopback HTTP and stdio in integration tests, keeping temporary runtime
state outside Git. Verify local documentation links, git diff --check, and the
unchanged original proposal. Record limitations honestly; software contract
tests are not Apple/Qwen quality, battery, or ARTEMIS compatibility evidence.

## Executed M1 status (2026-10-04)

The bounded increment above is implemented in Swift 6 / SwiftPM with no
third-party dependencies (`PlatformCore`, `PlatformServing`, and the
`ondevice-agent-platform` executable; system SQLite via a small `CSQLite`
module map). `swift test` passes the full 55-test software-contract suite:
empty-registry administration, OpenAI subset validation and truthful
404/503/429/504, scoped credentials and grant rechecks, bounded fair queue,
cooperative and unconfirmed cancellation with retained slots, typed-ML schema
validation, SQLite restart/lock/symlink safety, real loopback HTTP
integration, and real ACP stdio subprocess integration including
cross-connection denial, nonempty MCP refusal, EOF cancellation, and
harness version pinning/rollback.

Not done: no real inference provider, model artifact, Apple Foundation Models
or PCC call, ARTEMIS change, automation, signing, packaging, or release.
The `credential --scope` command remains the only deliberate token display;
`serve` refuses to start on missing scope credentials. ACP is the documented
v1 subset only; MCP definitions are refused before any process boundary.
Contract tests are software evidence, not model-quality, battery, or ARTEMIS
compatibility evidence.

## Apple provider increment (2026-10-04)

First M2 seam work: `AppleFoundationProvider` implements the `LLMProvider`
contract against the installed macOS 27 `FoundationModels` Swift interface
(`SystemLanguageModel.default.availability`, `LanguageModelSession` with a
mapped `Transcript`, `GenerationOptions.maximumResponseTokens`, real usage
counts). Mapping preserves ordered system/developer instructions, prior
user/assistant turns, and requires a final nonempty user turn. `cancel`
cooperatively interrupts the single in-flight generation through task
cancellation; the provider holds no policy, admission, or scheduling
authority.

Registration is opt-in only: `serve --enable-apple-model` or the
`enableAppleModel` config key registers the `apple-foundation-model` alias.
The provider instance is attached only when the device reports availability;
otherwise the alias exists and every request returns truthful
provider-unavailable. The availability check runs again per request, so a
device that loses eligibility stops serving rather than fabricating. This is
one purpose-tagged provider (`lightweight`, `system-integration`), not a
universal default; open-weight routes remain complementary M2 work.

Suite status after the increment: 61 software-contract tests pass,
including request-to-transcript mapping, refusal of malformed final turns,
stable provider identity, and truthful complete-or-unavailable behavior
through shared admission. No downloaded artifact, cloud call, PCC use, or
quality claim is implied.

## Typed-ML registry + model-step harness increment (2026-10-04)

`builtin.linear` is the first qualified typed-ML provider: a pure-Swift
linear classifier whose artifact (ordered features, labels, weight matrix,
optional bias) is declared as bounded JSON data in `registry.json`. The
compiled-in runtime computes `bias + W*x` per label and a deterministic
stable-softmax argmax; it is honestly `builtin.linear`, not a disguised
Core ML or downloaded runtime. `ModelRegistry.parse` validates strictly -
unknown keys, wrong kinds/providers/tasks, nonnumeric features, ragged or
nonfinite weights, and duplicate aliases all fail startup loudly rather
than partially registering. LLM entries remain code-registered only.

`reference.echo` is the second reference harness: a bounded single-call
model-step agent that forwards prompt text through the scoped `ModelClient`
(same admission as external consumers), emits the reply, and stops. It is
registered only when `--enable-reference-agent` is set AND a declared model
alias exists (currently the Apple opt-in); calls to unavailable models end
in truthful error. It demonstrates the hosted-agent model path the
optional Operator will later use - it is not the Operator.

Suite status: 71 software-contract tests pass, covering strict registry
validation, deterministic prediction math, schema enforcement through
submitML admission, harness stop semantics (refusal/error/cancel), and the
bounded token cap. Live check: `registry.json` entry -> banner reports the
alias -> typed-ML endpoint serves it under scoped credentials.

Known development limitation: Keychain items created by an unsigned debug
binary are bound to that build's identity, so recompiling and then reading
previously minted credentials triggers a Keychain approval prompt. Fresh
data roots mint and serve cleanly every build; signing removes the class of
prompt entirely and is already listed as required release engineering.

Observation, not benchmark: on the M4 Air development host the first
live Apple completion through full admission took ~16.5 s (includes model
load); later calls in the same process were materially faster. Thermal
state sat at `fair` after sustained builds and correctly deferred new
inference - the resource gate working as designed, not a fault.

## Owned open-weight MLX route (2026-10-04)

The user authorized downloads explicitly, unblocking the owned open-weight
LLM route. The runtime is MLX Swift (`mlx-swift-lm` pinned exactly at
3.31.4, plus `swift-huggingface` 0.11.0 and `swift-transformers` 1.3.4 -
the two HF packages are required because mlx-swift-lm 3.x moved hub
downloading and tokenization behind caller-provided macros). All three are
confined to a new `PlatformMLX` target; `PlatformCore` still links only
system frameworks and system SQLite, and `Package.resolved` records the
exact pin set.

Artifact governance is code-owned and explicit. `registry.json` accepts
`kind: "llm"`, `provider: "mlx"` entries with a pinned `source` {repo,
revision}; the entry declares intent only. `model pull` (new CLI command)
enumerates the repo tree, downloads each file directly into a `.staging-*`
sibling (no HF cache layer - no doubled disk usage), verifies per-file
sizes and the LFS sha256 when the hub reports one, records a manifest
(repo, revision, resolved commit, file list), then renames into
`models/<owner--name__rev>/`. `model list` and `model remove` are the
other two verbs. Nothing downloads at inference time, nothing follows
arbitrary paths, and a directory without a complete verified manifest is
never treated as ready. `RuntimeRoot` now owns `models/` in its
allowed-names set.

First-run bootstrap is a `setup` CLI command, not an installer script.
It prepares the data root and offers a code-owned curated catalog
(`ModelCatalog` in PlatformCore) - currently `qwen3.8-9b` and `qwen-vl`,
the two routes verified live on this host. Interactive terminals get a
numbered menu; `--models`/`--all`/`--none` cover scripts. Selection
writes declarations through `ModelCatalog.mergedRegistry`, which
replaces same-alias entries, preserves unrelated declarations, and
re-validates the merged result through `ModelRegistry.parse` before
writing - a malformed existing registry fails loudly rather than being
repaired. `--pull` (or the interactive prompt) runs the same governed
`model pull` path; declaration alone never downloads.

`MLXProvider` implements `LLMProvider` behind the same seam as the Apple
route: identical message mapping (system/developer -> instructions,
ordered history, final nonempty user turn), `GenerateParameters.maxTokens`
from the request bound, temperature fixed at 0 (the serving contract has
no sampling fields; determinism is the platform default), real
prompt/generation token counts and true stop reasons from
`GenerateCompletionInfo`, and cooperative cancellation via task
cancellation into `ChatSession`'s termination path. Providers conform to
the new `ProviderReadiness` protocol so `ownedOpenWeight` reports
`qualified` only when a pulled, valid artifact exists - `observing` when a
route is declared but nothing is pulled.

Verified live on this host (M4 Air, 16 GB): `model pull` of
`mlx-community/Qwen3-0.6B-4bit` (~351 MB) and
`mlx-community/Qwen3-4B-Instruct-2507-4bit` (~2.28 GB) with manifest
verification; `serve` reports `providers qualified: qwen-small,qwen3-4b`
and `ownedOpenWeight: qualified`; `/v1/models` lists both aliases. The
gated `MLXLiveTests` (`OAP_LIVE_MLX=1`) prove real generation through
shared admission with real usage counts, and `cancelJob` -> provider
cancel -> `.cancelled` to the caller in well under the full generation
time. Observation, not benchmark: on this host the 0.6B-4bit live test
complete path (pull + load + short generation) took ~31 s; sustained
builds keep the thermal state at `fair`, where the resource policy
correctly defers inference - the gate working as designed.

One toolchain note: Xcode 27's Metal compile step for mlx-swift requires
the downloadable Metal toolchain (`xcodebuild -downloadComponent
MetalToolchain`); without it `swift build` fails inside `Cmlx` Metal
targets. This is a host setup step, not a code dependency.

Suite status: 95 tests pass (59 core + 23 serving + 13 MLX; the 2 live
tests skip unless `OAP_LIVE_MLX=1` and were exercised manually). Known
boundaries unchanged: no streaming/SSE, no tool dispatch to executors,
no cloud fallback, and the Operator remains unimplemented pending its
own scoped request.

## Multimodal + OpenAI-compat tightening increment (2026-10-04)

ARTEMIS contract audit (see `artemis-qualification.md`) showed the core
transport already matched but three consumer-real gaps existed: image
parts, honored sampling fields, and a structured-output surface.

- `ChatMessage` carries `images: [ChatImage]` (decoded bytes + media type)
  on user turns only; `ChatRequest` carries optional `temperature`,
  `topP`, `seed`, `presencePenalty`, `frequencyPenalty`, and a
  `ResponseFormat` hint (`jsonObject` / `jsonSchema`). Sampling hints are
  honored: MLX maps them onto `GenerateParameters`, Apple onto
  `GenerationOptions.temperature` (the only knob it exposes).
- `OpenAIAdapter` accepts `image_url` parts **only** as bounded
  `data:image/{jpeg,png,webp};base64` URIs (4 images / 16 MB decoded per
  request) - remote URLs are refused, the platform never fetches caller
  URLs. `response_format` is accepted as documented best-effort guidance
  (no grammar-constrained decoding exists in mlx-swift-lm). Generative
  fields no provider can honor - `stop`, `logit_bias`, `logprobs`,
  `reasoning_effort` - moved from silently-ignored to explicit 400, per
  the adapter's own contract.
- Admission gates images on a declared `vision` capability: an image
  request to a text-only alias is a 400, not a provider failure.
- `MLXProvider` attaches images to the carrying turn (history and final
  prompt), imports `MLXVLM` so `VLMModelFactory` registers in the
  `ModelFactoryRegistry` trampoline and VLM configs load through the same
  `loadModelContainer` seam.

Verified live: `mlx-community/Qwen3-VL-2B-Instruct-4bit` pulled
(1.8 GB manifest-verified), `qwen-vl` alias qualified, and the gated
`testLiveVisionCompletion` produced a correct answer ("red") on a
generated solid-color PNG with real usage counts (~9 s including load).
Daemon endpoint rejects image-on-text-alias and unhonored fields with
400. `requestBodyBytes` raised to 24 MB to admit base64 screenshots.

Suite status: 104 tests pass (61 core + 27 serving + 16 MLX; 3 live
tests gated on `OAP_LIVE_MLX`).

## Automatic console bootstrap + monitor correctness fix (2026-10-04)

The user objected to mandatory console sign-in on a single-user local
development surface. `POST /api/session` is now an automatic bootstrap: it
requires an exact same-origin `Origin` (absent, foreign, and "null" all
403, and a supplied `Sec-Fetch-Site` must be `same-origin`), exchanges no
credential, reuses a still-valid presented cookie, and only consumes the
existing rate/session bounds when it actually creates a session. Cookie
reads keep allowing an absent Origin but refuse a foreign supplied Origin
or a `Sec-Fetch-Site: cross-site` marker; every cookie-backed mutation now
requires the exact Origin in addition to the matching CSRF. The page drops
the sign-in/sign-out form entirely, opens the dashboard directly, and
bootstraps and renews sessions itself through a deduplicated promise with
bounded retries (mutations are never auto-retried; the event stream gets
one controlled reconnect per failure). `serve` now requires only `model`
and `agent` scope credentials; a `console` credential stays optional for
command-line administration, and all bearer scope checks are unchanged.
Explicit trust statement: automatic bootstrap trusts local users and
processes - localhost alone is NOT identity authentication, and
same-origin+CSRF protect browser mutations, not isolation from other local
programs. This supersedes the M1 manual console credential gate for this
local development console.

`NativeResourceMonitor` had two real bugs. It read the DispatchSource
memory-pressure `mask` - the constant subscription set - as if it were an
observation, so once monitoring started pressure reported `critical`
permanently regardless of actual host pressure. And the periodic timer
refreshed only an internal field without invoking `onChange`, so the
supervisor's snapshot went stale and `ResourcePolicy` correctly denied
admission past the freshness window. The monitor now stores only
delivered pressure events read from the source's `data` inside its event
handler (decoded worst-first; unrecognized bits -> unknown, never inferred
normal), publishes every periodic sample through `onChange`, and guards
handler epochs so stop/restart cannot leak stale state. Review hardening
followed: decoding fails closed when any unrecognized bit is mixed with
known ones, `start()` is a no-op while an epoch is live, and the
supervisor drops strictly-older samples so off-lock callback delivery
cannot regress a newer observation (equal timestamps still apply).
Honest limitation: the public Dispatch source may not emit a startup
event, so unobserved pressure remains `unknown` - which blocks inference -
until a real event is delivered; `os_proc_available_memory` remains
unavailable on macOS and no sysctl or private-API fallback was added.

`statusSnapshot` now reports `resource.admission` - the
`ResourcePolicy.evaluate` verdict (`admit`, `defer_load`,
`deny_and_cancel`) - as the single truthful resource signal; the console
renders it instead of duplicating Swift thresholds in JavaScript, and
shows the defer/deny notice whenever admission is not `admit`. The
frontend's recovery paths were tightened the same pass: bootstrap POSTs
only after a 401 (never after 403 or offline failures), SSE retry budget
resets only on a delivered status frame with a 1 s delayed single
reconnect guarded against stale sources and duplicate errors, and a
partial status/registry/jobs refresh no longer erases previously
displayed data. `Tests/ConsoleTests/app.test.cjs` covers these flows with
Node built-ins only. This is a correctness fix, not a capacity benchmark.

## Continued development and OpenCode (2026-10-04)

The user explicitly requested continued work on missing and remaining
features and added OpenCode as an external consumer (D47). The completed
software-contract tests are evidence for individual seams, not completion
of the product, resource qualification, or the documented console.

The next implementation sequence is:

1. Enforce request bounds in the shared core, not only in the HTTP parser;
   reserve admission capacity across storage suspension; propagate socket
   cancellation; bound agent sessions, turns, and generated-token
   reservations independently of cooperative harness behavior.
2. Resolve native admission and owned-model lifecycle limitations with
   truthful observations. Unknown pressure must not be renamed normal.
   Critical pressure must take precedence over fair-thermal or low-power
   deferral. No private pressure probe or unmeasured healthy assumption is
   authorized by this continuation.
3. Qualify OpenCode's installed OpenAI-compatible consumer contract,
   including required streaming, tool-call data, history, abort, and usage
   semantics. The consumer executes its own tools; the platform does not.
   ARTEMIS's structured-output and context requirements remain separate
   qualification gates.
4. The multi-view console (Overview, Models, History, Train, Chat) is
   implemented below; the remaining console work is calibration and any
   later-authorized controls.
5. Reconcile current status notes with code and evidence, then perform one
   final software gate and narrowly scoped live consumer checks. Release,
   signing, PCC eligibility, and separately permissioned optional
   capabilities retain their own gates.

The installed OpenCode configuration currently targets
`http://127.0.0.1:8080/v1` through `@ai-sdk/openai-compatible`. Its existing
configuration and credential files are user-owned inputs, not files to
replace during development. This observation is not a compatibility result.

Input image policy adds an 8,192-pixel maximum dimension and an aggregate
8,388,608-pixel budget per request, alongside the existing count and decoded
byte bounds. These are conservative experimental bounds, not measured
capacity claims. Per-model `maxInputBytes` counts decoded message content
and response-format guidance; it must be checked on every shared-core path.

## Qwen-backed runtime Operator request (2026-10-04)

The user explicitly requested usable models under the selected normal root
and a Qwen-backed Operator (D48). Verified Qwen small, 4B instruct, and 2B
vision artifacts have been clone-copied from isolated qualification storage
to `~/.ondevice-agent-platform/models`; its previously empty registry now
declares those aliases. The original artifacts and runtime records remain
intact. A successful copy or manifest listing is installation evidence,
not a claim that the native governor has admitted inference.

The selected first Operator implementation is optional and runtime-only:

- Public ACP profile `operator`, agent version 1, harness
  `operator.runtime` version 1; bound model alias defaults to
  `apple-foundation-model` (D52) - the earlier `qwen3.8-9b` default (D51;
  initially `qwen3-4b` before the user's 2026-10-05 correction) remains
  selectable through `--operator-model`. No tool scope.
- Code gathers one read-only platform snapshot and sends it with the user's
  question to the scoped shared model interface. One model call per turn,
  at most 512 requested output tokens, temperature zero.
- The lead-authored instructions are versioned in `OperatorPrompt.swift`.
  Model output is an explanation or review proposal, never an applied
  change, permission, calibration measurement, or executable configuration.
- Empty prompts, unavailable artifacts, cancellation, invalid scope, and
  resource denial remain explicit outcomes. The Operator never bypasses
  native admission and does not load models at core startup.
- Agent sessions, concurrent turns, child-call reservations, and late
  emissions must remain code-owned and bounded. A noncooperative harness
  cannot hold the caller indefinitely or start another turn before its
  retained work actually stops.

Implementation and live execution results for this request must be recorded
after verification; neither this design nor the artifact installation
establishes that the Operator has run successfully.

## Multi-view console and console Operator bridge (2026-10-05)

The console now has five hash-routed views in the existing paper/teal
visual language: Overview, Models, History, Train, Chat. All values are
rendered as `textContent` (never markup) and no view fabricates controls:

- Overview shows the real resource fields, the evaluated `admission`
  verdict, occupied inference slots, and provider categories. Memory
  pressure carries a `memoryPressureSource` provenance label:
  `dispatch_event` is a delivered OS event and stays authoritative
  (including a delivered unknown, which is never replaced by an estimate),
  `available_percent_estimate` is labeled on the page as "Kernel gauge
  estimate; not calibrated headroom", and `unavailable`/`unspecified`
  report honestly. Policy thresholds are unchanged and uncalibrated.
- Models renders `modelProfiles`/`agentProfiles` (alias, provider, task,
  purposes, capabilities, declared source+revision, maxOutputTokens,
  `providerRegistered`, tri-state `artifactReady`: ready / unavailable /
  unverified - never a resident or capacity guarantee), falling back to
  the plain alias arrays for an older server. Artifact management stays
  CLI-governed (`model pull`/`list`/`remove`); there are no pull or remove
  buttons.
- History lists real jobs with state, parent links, and the existing
  CSRF-scoped stop control; Train is explicitly unavailable rather than
  simulated.
- Chat reaches only the opt-in read-only runtime Operator, never an
  arbitrary model or agent. The page states "One bounded call per
  question; fresh snapshot; no conversation memory or applied actions",
  shows the pinned model/harness metadata, labels `max_tokens` answers as
  partial, and disables the composer when the Operator is not registered.
  Send uses an `AbortController`; abort propagates through HTTP request
  cancellation as a turn-scoped `CancellationToken` passed straight into
  the ACP `session/prompt` call, so an abort cancels that run directly
  and can never reach a later turn that reuses the same session. A
  failed request is never retried automatically.

`POST /api/console/operator/prompt` is a console-only route (cookie
session + exact Origin + CSRF + fetch-site checks + per-consumer rate
limit) accepting exactly `{"text": String}` (unknown keys, blank, or
>16 KiB UTF-8 refused). `ConsoleOperatorBridge` reuses the shared
`ACPService` in-process - same admission, claiming, and cancellation -
under a fixed non-secret `console-operator` principal holding only
agentRun/agentStatusRead/llmInfer. Bindings key on the console cookie id
with an opaque UUID ACP connection id, deduplicate concurrent creation
under a cancel lease, are reaped on the resource-sample cadence, and close
with logout or expiry. Creation validation and commit run inside the
shared creation task, so every waiter receives the same validated
outcome: after the last await the commit re-checks the lease and the
live `ConsoleSessions` entry (id, expiry, CSRF) and closes the fresh ACP
connection when the session was logged out or expired mid-create, so an
invalidated cookie can never resurrect a binding. Router logout
invalidates the console session before closing the bridge binding. One
in-flight question per console session, two cookies cannot cancel each
other's turn. JSON-RPC errors map to truthful HTTP statuses (provider
503, deadline 504, capacity 429, conflict 409, closed 410). The closing
bearer-credential sentence in the original record is superseded by D50:
generic model/ML/ACP routes now bind fixed `LocalConsumers` principals
header-free, a console cookie carries no API authority, and every
`Authorization` header is ignored.

OpenAI wire responses now emit the requested serving alias in the `model`
field and a unique `chatcmpl-UUID` completion id per response (shared
across all SSE frames of one response); provider `modelIdentity` remains
internal engine identity, never promoted to a model or capacity claim.

Controlled-wire qualification (`OperatorWireLiveTests`, double-gated,
single run): real loopback HTTP + Router + shared ACPService + real pulled
Qwen3-4B artifact; `initialize` reported protocolVersion 1, `session/new`
issued a session, `session/prompt` ("Explain runtime status.") delivered
agent_message_chunk text ending `end_turn` in 80.3 s with exactly one LLM
job, zero ML calls, and the run as the job's parent. This proves the
protocol path end to end under injected healthy resources; it is NOT
native-daemon admission proof, draws no quality/performance conclusions,
and complements (does not recompute) the frozen 54.9 s functional pass.

## OpenCode contract implementation (2026-10-04)

The user approved extending the platform to OpenCode's observed request
surface (D47 qualification gates 1-3). A logging proxy captured the
installed client's actual wire shape: `{model, messages, stream: true,
stream_options: {include_usage: true}, tool_choice: "auto", tools: [10
function schemas], max_tokens}` - no `n`, `stop`, `parallel_tool_calls`,
or `reasoning_effort`.

- `ChatRequest`/`ChatMessage` now carry `tools`, `toolChoice`, `toolCalls`,
  and `tool` role messages end-to-end through the shared core.
- `OpenAIAdapter` parses and validates `tools`, `tool_choice`
  (`auto`/`none`/`required`/named), assistant `tool_calls`, and
  `role: "tool"` results with declared-name and call-ID correlation
  checks; undeclared or duplicate names, malformed calls, and
  `strict: true` schemas (no grammar-constrained decoding exists)
  refuse 400 rather than being ignored. `stream` and `stream_options`
  are accepted; the Router emits real SSE `chat.completion.chunk`
  frames (role delta, content delta, tool-call deltas, finish reason,
  optional usage chunk, `data: [DONE]`). Non-streaming tool-call
  messages omit the streaming-only `index` field.
- `PlatformLimits` raised for agentic workflows: `outputTokens` 8192,
  `chatMessages` 256, `chatTextBytes` 256 KB, `chatTools` 64,
  `chatToolCallsPerMessage` 16, `inferenceDeadlineSeconds` 300,
  `queueDeadlineSeconds` 60. Profile-declared `maxOutputTokens` still
  clamps down, never up.
- `MLXProvider` maps structured messages (system/developer/user/
  assistant/tool), converts OpenAI tool specs to the pinned
  mlx-swift-lm `ToolSpec` shape, passes `tools:` to `ChatSession`, and
  collects `.toolCall` stream events into `ChatToolCall` results.
  Assistant-final messages, undecodable images, and tool results
  without a matching prior call refuse truthfully.
- `AppleFoundationProvider` refuses the tool surface in `validate()`
  (before queueing) - declared tools with any `tool_choice` other than
  `none`, assistant `tool_calls`, and `tool` messages - since the
  FoundationModels transcript cannot express a caller-managed tool
  loop. `tool_choice: "none"` withholds schemas on both providers.
- Resource admission fix: `NativeResourceMonitor` consults the
  `kern.memorystatus_level` sysctl while a monitoring epoch is live and
  no pressure event has been delivered, so a healthy machine no longer
  sits at `unknown` forever. Pre-start samples stay honestly `unknown`.
  `deferLoad` is now a real deferral - jobs stay queued and dispatch
  re-evaluates each fresh ~1 s snapshot until the per-job 60 s queue
  deadline - instead of an immediate `resourceDenied`. `denyAndCancel`
  still fails fast and cancels queued/active work.
- `ACPFacade`'s line parser now tracks a scan offset (amortized O(n))
  and resets oversized partial lines before unbounded growth; raising
  `requestBodyBytes` to 24 MB had exposed an O(n^2) rescan that blocked
  pipe writes in integration tests.

Evidence: `swift build` clean; full suite passes (see suite status in
this file's prior section; live MLX tests remain gated on
`OAP_LIVE_MLX`). curl E2E against a live daemon on the model-bearing
root verified `/v1/models`, 400s for undeclared `tool_choice` and
unsupported `parallel_tool_calls`, and a fast (140 ms) `invalid_request`
refusal for Apple-provider tools. A real `stream: true` inference
request was admitted to the queue and, under sustained `thermal: fair`
on a heavily loaded host, deferred for the full 60 s queue deadline and
expired as `deadline_exceeded` - the deferral working as designed, not
an adapter failure. (Subsequently closed: gated live MLX generation
under `admit` and real OpenCode tool-call turns on `qwen-vl` verified
2026-10-05 - opencode-qualification.md gates 3-5.)

## Final software gate and deployment state (2026-10-05, credential-era record)

This section records the earlier credential-era build and deployment
state, before the D50 token-free rework below. Its pending assertions are
historical, not current.

The reviewed console/ACP hardening build passes `swift test --skip-build` with live gates unset: 221 tests executed, zero failures, seven explicitly gated live tests skipped (74 serving, 125 core, 22 MLX including the skips). The console client tests separately pass 21/21. `git diff --check` is clean and the README/docs local Markdown link check finds no broken links. These are software-contract results, not native admission or consumer quality measurements.

The normal runtime contains the three Qwen artifacts and registry aliases. A launch of the reviewed binary with the normal data root, port 8081, Apple/reference opt-ins and `--enable-operator --operator-model qwen3-4b` was blocked inside macOS Keychain access. At the recorded deployment check there was no listener or daemon marker; the process remained pending for owner approval at that check. Credentials, model artifacts, and the existing OpenCode configuration are preserved. Native model, SSE, ACP stdio Operator, console Operator, and isolated OpenCode receipts and desktop/mobile screenshots were pending at that check. Prior controlled-resource Qwen passes are carried forward unchanged and do not establish current native serving success.

## Token-free local authority (2026-10-05)

The user directed that a locally run, single-user platform must not require
Keychain or mandatory API tokens (D50). The credential-storage subsystem is
removed from production entirely - `CredentialStore`, the Keychain store,
the `credential` CLI command, token minting, and `serve`'s secret preflight
are gone. No runtime code reads, mints, deletes, or re-ACLs Keychain items,
and previously stored entries are left untouched on disk/in Keychain.

Local-trust structure as implemented:

- `LocalConsumers.model`, `.agent`, and `.administration` are fixed
  code-owned principals registered at `start()`; every loopback route binds
  to one of them, and the console Operator consumer keeps its three scoped
  grants. Scope checks remain internal code-owned permissions with
  queued-dispatch rechecks and revocation - not OS-user authentication.
- An incoming `Authorization` header is ignored outright on every route for
  SDK compatibility; it selects no principal and bypasses no guard.
- Model/ML/ACP-bridge POSTs and administration reads need no cookie or
  credential; supplied `Origin` must be exact (foreign and `null` are 403)
  and a supplied cross-site `Sec-Fetch-Site` fails closed before any
  provider or harness work. Per-consumer rate limits apply per fixed id.
- Job cancellation splits on browser markers: a session cookie, any
  `Origin`, or any `Sec-Fetch-Site` routes through the console mutation
  checks (exact Origin + live session + CSRF, no fallback); a marker-free
  native request cancels under `LocalConsumers.administration` so the
  device owner can stop local work.
- The console's automatic session bootstrap, HttpOnly SameSite cookie,
  CSRF, expiry/logout, per-session binding, and cancellation checks are
  unchanged browser request guards - they are not user authentication, and
  no identity isolation from other local processes or users is claimed.
- `serve` starts on a fresh root with no bootstrap step and no credential
  files; `acp` reads only the daemon marker for its port and forwards
  stdio JSON-RPC to the bridge with no token. `SessionNonce` (32 random
  bytes, hex) is the only randomness helper and exists solely for browser
  session/CSRF nonces.

## Token-free deployment native verification (2026-10-05)

The reviewed token-free build was deployed on the normal runtime root at
`127.0.0.1:8080` (single daemon, no Keychain interaction at launch) and
verified with header-free requests. Raw receipts, run logs, and
screenshots live in a private evidence directory outside Git under the
devin `oap-evidence` store (`localrun-032101`); the raw transcripts are
not committed. Recorded functional facts:

- Real native Qwen3-4B JSON response: HTTP 200, content `model-ready.`,
  finish `stop`, usage 15 prompt / 3 completion / 18 total tokens.
- Native SSE stream: HTTP 200, same text, one shared completion id across
  frames, usage reported, terminated by `[DONE]`.
- Two completed LLM jobs (ids 2 and 3) recorded under consumer
  `local-model`.
- Production ACP stdio Operator turn emitted real text and `end_turn`;
  job 4 completed under `local-agent`, parent `run-1`.
- Console Operator prompt: HTTP 200, pinned `qwen3-4b`, `end_turn`, real
  text; job 5 completed under `console-operator`, parent `run-2`.
- Isolated OpenCode probe returned text `contract-ready` with
  `step_finish` reason `stop` and exit 0, usage 1919 input / 2 output;
  job 6 completed under `local-model`. The probe ran with deny-all tools
  - no actual coding or tool execution was exercised.
- Resource snapshots reported thermal `nominal`, memory pressure
  `normal`, admission `admit`, with `memoryPressureSource` explicitly
  `available_percent_estimate` - a kernel gauge estimate, not calibrated
  headroom.
- Headless-browser pass: all ten desktop/mobile view renders reached
  app-ready with no page-wide horizontal overflow at 1280x900 or
  320x800. The initial `GET /api/session` 401 followed by automatic
  bootstrap was the expected session flow; no JS exception was observed.

These are functional and native-governor observations, not model
quality, capacity, or performance measurements. The Operator generated
runtime explanations, but its statements about there being no
performance bottlenecks or resource constraints are not measurements.
Artifact readiness and a normal pressure estimate do not establish model
headroom, capacity, quality, or a lack of bottlenecks.

## Token-free final software gate (2026-10-05)

The final `swift test` run, with live gates unset, executed 225 tests with
zero failures and seven explicitly gated live skips: 78 serving, 125 core,
and 22 MLX including the skips. The updated console client suite passed
21/21 Node tests. Two earlier attempts failed compiling test edits before
any test executed; they are not successful test runs.

The mobile Models navigation and History table corrections were checked
by re-rendering captured native status, registry, and job data. These
frozen-data screenshots show readable table cells, top-of-view navigation,
and no page-wide overflow at 320 pixels; they are presentation checks, not
new native observations or repeated model measurements. The running
token-free daemon remains on `127.0.0.1:8080`.

## Operator model correction to Qwen3.8-9B 4-bit (2026-10-05)

User correction: "model is wrong, operator should use qwen 3.8 9b 4q" (D51).
The interim `qwen3-4b` binding was replaced with the requested artifact.

Artifact qualification (checked 2026-10-05 via the Hugging Face API):

- The previously cited `empero-ai/Qwen3.8-9B-Distill-GGUF` is llama.cpp GGUF
  and is not consumable by the MLX route; no backend was added for it.
- `mlx-community` publishes only Qwen3.8 27B variants - too large for 16 GB.
- Selected: `nvythong/Qwen3.8-9B-Distill-mlx-4Bit` pinned at
  `e827c31fbd588828f43180a87ab34415a6d8a4bf` - a flat-layout mlx-lm affine
  4-bit (group 64) conversion of `empero-ai/Qwen3.8-9B-Distill`, `qwen3_5`
  architecture (supported by the pinned `mlx-swift-lm` 3.31.4), text-only
  weights (vision tower excluded), Apache-2.0. Alternatives considered:
  `schsu/Qwen3.8-9B-MLX-MXFP4` (smaller but mxfp4, a less-proven mode on
  this stack), `PocketAiHub/Qwen3.8-9B-MLX` (rejected: multi-variant repo
  would pull ~32 GB including 8-bit/bf16 folders).
- Governed `model pull --alias qwen3.8-9b` installed 9 files,
  5,058,246,338 bytes, manifest-verified (sizes + LFS sha256), resolved
  revision `e827c31fbd58`. Registry entry: purposes
  `reasoning,coding,runtime-explanation`, capabilities `text`,
  maxOutputTokens 4096. `qwen3-4b` was subsequently removed at the user's
  direction (below).

Binding change: `ServeCommand.operatorDefaultModelAlias` is now
`qwen3.8-9b`; `serve --enable-operator` and `--operator-model` validation
are unchanged (declared, LLM, MLX, >=512 output cap, artifact ready).
Operator harness, ACP profile, authority boundaries, and the 512-token
bounded call are unchanged.

Verification on the real artifact and native daemon:

- `OperatorLiveTests` and `OperatorWireLiveTests` (double-gated, injected
  healthy resources - controlled-path evidence): both passed against the
  pulled 9B, real load + generation, exactly one LLM job under the run,
  `end_turn`. Runtimes 37.9 s and 52.1 s on this host.
- Native daemon (`--operator-model qwen3.8-9b`, port 8080): `/v1/models`
  lists all five aliases; a `qwen3.8-9b` chat completion returned HTTP 200
  with real text and usage 33 (job-16, `local-model`); a spaced ACP stdio
  Operator turn emitted real text with `end_turn` (job-18, `local-agent`,
  parent `run-2`); a console Operator prompt returned HTTP 200 with
  `model: "qwen3.8-9b"` and `end_turn` (job-21, `console-operator`,
  parent `run-1`).
- Native governor observation: while the ~5 GB model stayed resident the
  OS delivered a `warning` memory-pressure event (`dispatch_event`),
  flipping admission to `deny_and_cancel`; a console Operator prompt was
  refused with `provider_unavailable` (job-19 failed) and later identical
  pressure after the completed turn repeated the state. This is truthful
  resource enforcement - and concrete evidence for the already-documented
  resident-container limitation (no idle eviction yet). A clean restart
  unloads weights and returns pressure to `normal`.
- The 9B distill emits `<think>` reasoning traces before its answer;
  output is passed verbatim. This is functional-serving evidence only -
  answer quality, capacity over time, battery, and thermal characteristics
  remain unmeasured.

Following the correction the user directed removal of the interim
artifact: "remove mlx-community--Qwen3-4B-Instruct-2507-4bit__main. make
sure provide qwen 9b and qwen vl for artemis and opencode". The artifact
was deleted via governed `model remove --alias qwen3-4b` and the registry
entry dropped; `/v1/models` serves `qwen3.8-9b`, `qwen-vl`, and
`apple-foundation-model` - the two routes ARTEMIS and OpenCode require
(text reasoning + vision), after the user's follow-up removal of
`qwen-small` (`model remove --alias qwen-small`, registry entry dropped,
OpenCode client entry removed; it remains only the gated pull-test
artifact, which pulls to a temp store). The local OpenCode client
configuration was updated to the `qwen3.8-9b` serving alias. A live
completion on the restarted daemon was refused with `resource_denied`
under a real OS `warning` memory-pressure event (`dispatch_event`) on the
unloaded fresh process - the host itself was under pressure; this is the
governor, not a serving defect, and the earlier same-session 9B evidence
stands.

## Apple-bound Operator binding (2026-10-05)

User instruction: "develop artemis operator agent, use apple foundation
model as llm" (D52). `ServeCommand.operatorDefaultModelAlias` is now
`apple-foundation-model`, and `PlatformSupervisor.registerRuntimeOperator`
accepts either local route family - `AppleFoundationProvider.id` or
`MLXProviderContract.id` - always verified against a live provider at
registration. The CLI gate splits by route: the Apple alias requires
`--enable-apple-model`; a registry alias still requires declared + LLM +
MLX + >=512 output cap + pulled. `--operator-model qwen3.8-9b` keeps the
explicit MLX binding. Harness, ACP profile, authority boundaries, and the
512-token bounded call are unchanged - only the provider family widened
and the default moved to the system route, which holds no
platform-resident weights and so does not re-create the measured ~5 GB
9B residency pressure problem on this 16 GB host.

Tests: `RuntimeOperatorTests` gains `testAppleAliasRegistersPinnedOperator`
(live fake apple-foundation-models provider -> pinned profile -> bounded
call targets `apple-foundation-model`); the third-party-provider and
no-provider rejections are unchanged. All 10 tests pass.

Verification (native daemon, 2026-10-05): ACP stdio Operator turn
produced real Apple Foundation Model text with `end_turn` (job-42,
`local-agent`, parent `run-1`); console Operator prompt returned HTTP 200
with `model: "apple-foundation-model"` and `end_turn`. Both turns ran
while the governor held `defer_load` under fair thermal - made possible
by the companion dispatch refinement below.

deferLoad semantics refinement (same change): `defer_load` now defers
exactly its namesake - model weight loads - instead of all queued work.
`LLMProvider.requiresLoad(for:)` reports whether dispatching would load
weights (Apple system route: never; MLX: only when no cached container
and no load already in flight; default: true). Under fair thermal/low
power, no-load jobs still dispatch while load-bearing jobs stay queued;
`deny_and_cancel` is unchanged - it still fails everything. Verified
live: with the daemon at `defer_load`, the Apple Operator turn completed
while a queued `qwen3.8-9b` request (job-43, `local-model`) correctly
remained deferred. Tests: `testDeferralDefersLoadsNotResidentCalls`
(no-load dispatches under defer; load-bearing queues; admit releases it);
the pre-existing defer/expiry tests hold because the default provider
answer stays conservative.

Console loopback hostnames (2026-10-05): the router's Host gate and
expected-Origin check were hardcoded to `127.0.0.1:PORT`, so the console
served only under that spelling - `http://localhost:PORT` returned 400 on
every request including the page itself ("console not working, no
information"). The listener binds IPv4 loopback only, so the reachable
spellings are exactly `127.0.0.1:PORT` and `localhost:PORT`; the Host
gate now accepts both and the expected Origin is derived from the served
Host, so a rebound DNS name still fails before routing.
`testLoopbackHostSpellingsAcceptedForeignRefused` covers both spellings
plus a foreign-host refusal.

Model cache lifecycle (2026-10-05): resident weight containers were
previously pinned for the daemon's life - on this 16 GB host a loaded
9B kept the OS at `warning` pressure and the governor at
`deny_and_cancel` until a restart (measured above). Two truthful
shedding paths now bound residency, via the `ModelCacheEvicting`
provider seam: (1) on a `deny_and_cancel` verdict the supervisor drops
every resident container alongside child cancellation, so pressure can
recover; (2) every snapshot also trims containers idle past
`PlatformLimits.modelIdleSeconds` (600 s - a conservative bound, not a
latency claim). A load completing after an eviction does not re-cache
(epoch guard); an in-flight generation keeps its own container
reference and finishes or surfaces cancellation. Verified live: a
cancelled mid-load 9B left the daemon at 0.01 GB resident (previously
~7.3 GB) with instant admission recovery. `requiresLoad` reverts to
true after eviction, so `defer_load` again defers that model's next
call until thermal allows a reload. Tests:
`testPressureEscalationShedsModelCaches` (shed on deny, trim on
healthy push). An idle-TTL bound rather than LRU/eviction-on-write is
deliberate: the single inference slot makes ordering trivial and keeps
warm reload behavior predictable for interactive use.

Python cross-platform core (2026-10-05): per D54 the deterministic
platform is now also implemented under `python/` (stdlib-only core;
optional provider imports). Ported: runtime root + owned-file/symlink
safety + cross-OS locking, strict registry + curated catalog + per-route
`requires` host filtering (os/accelerator/format/min-free-memory),
content-free sqlite job/session ledger (with crash-recovery
interrupted marking), resource samplers (Linux MemAvailable+PSI+cgroup
v2+thermal zones; macOS `kern.memorystatus_level` + pmset therm/lowpowermode;
Windows GlobalMemoryStatusEx + GetSystemPowerStatus), the lock+threading
supervisor (fair-share dispatch, queue/inference deadlines, cancellation
grace -> unconfirmed -> inference-blocked, deny_and_cancel eviction +
idle-TTL trim + epoch guards), providers (builtin.linear, llama.cpp
subprocess on all OS, mlx-lm/mlx-vlm on macOS, Apple FM via the
`oap-apple-bridge` Swift executable on macOS), the loopback HTTP router
(console static + sessions/CSRF, admin reads, /v1 chat+models, typed-ML,
SSE events, private ACP bridge), ACP v1 stdio facade + bridge, the
three built-in harnesses including the bounded read-only Operator, and
the setup/model/serve/acp CLI. Verified live on macOS: 47 unit tests,
linear prediction 200, truthful provider-unavailable for unpulled
weights, ACP initialize/session/prompt with streamed chunk + end_turn,
and the Apple route through the bridge (`READY`, 2.8 s). Sampler note:
`kern.memorystatus_level` is percent-free (higher = healthier); the
warning boundary follows the kernel's own
`vm_pressure_level_transition_threshold` (observed 30). Not yet verified
on Linux/Windows hosts; `llama-server -ngl 99` is a pending per-host
calibration. The Swift implementation remains the reference and keeps
its own test suite; both cores share the wire surface, admission, and
truthful-refusal contract.

vllm-mlx route (2026-10-05): `vllm-mlx` (waybarrios/vllm-mlx, PyPI
0.5.0) is adopted as a fourth LLM provider - an owned `vllm-mlx serve`
child per profile on a loopback port, the same subprocess-container
shape as llamacpp (requires_load, epochs, evict_resident drops the
server and its KV cache on deny_and_cancel). Its prefix cache +
continuous batching run *inside* platform admission, not as the
foundational layer: the supervisor stays scheduler-of-record. Registry
entries declare `"provider": "vllm-mlx"` with an MLX-format source;
the route truthfully refuses when the `vllm-mlx` binary (PATH or
OAP_VLLM_MLX) or the pulled artifact is absent. Deliberately not
curated into the setup catalog: per the measured-evidence rule it
needs an on-host benchmark vs the direct mlx route (prefix-cache TTFT
on repeated agent-loop contexts vs ~25 extra runtime dependencies)
before a recommendation. Measured 2026-10-06 (Qwen3.8-9B, 16GB host):
decode ~17-19 tok/s on all three routes, but a ~5.8K-token agent-loop
prefix costs 40-80s on EVERY turn for both mlx routes - vllm-mlx routes
this artifact through its uncached MLLM text path and mlx-lm has no
prefix cache - while llama.cpp's slot context-reuse drops repeat turns
to ~7s (12x). For repeated-context agent workloads on this model the
GGUF route is currently the fastest on macOS too; vllm-mlx's batching
(~2x on 2 concurrent) and prefix cache may pay off on a text-only
artifact. Follow-up: every public MLX build of this distill (keXjos,
schsu MXFP4, enginil, PocketAiHub, nvythong) inherits
`Qwen3_5ForConditionalGeneration` from the source - the model is a
hybrid linear-attention VLM-family distill, so no text-arch MLX
package exists. Serving the artifact with `model_type: qwen3_5` +
`architectures: ["Qwen3_5ForCausalLM"]` (nested `text_config` kept)
makes vllm-mlx route it as `type: llm`: prefix cache then engages
(0.76-0.93s TTFT, ~6-9s repeat turns vs 40-80s uncached; coherent
output verified) - the fastest measured macOS path for this model,
ahead of llama.cpp (~7s) with faster decode. Caveat: patching
config.json breaks manifest verification; a symlink-overlay dir
(store files linked, config patched) would preserve the byte
contract if adopted. Claims check vs the circulating proposal:
prefix caching/continuous batching/OpenAI+Anthropic APIs are real;
"SHA-256 image hashing 28x", `vllm.entrypoints` serving, and
`sudo sysctl wired_mem_alloc_limit` requirements are not - the real
entry is `vllm-mlx serve <model> --local-files-only`.

vllm-mlx productionization + consumer validation (2026-10-06):
the provider now builds the symlink overlay itself (weights linked
from the verified store, config.json patched to the CausalLM arch
with VLM marker keys stripped - zero bytes copied), passes
`--enable-prefix-cache` + `--served-model-name`, and calls the
server with `stream: true` internally because the trie prompt cache
only engages on the streaming path; SSE deltas are aggregated into
a normal ChatResult for callers.

Three governance bugs found and fixed by live benchmarking on this
16 GB host: (1) provider `_Server.stop()` could take ~8s, longer
than the 5s cancellation grace - jobs landed `cancellation_
unconfirmed` and latched `_inference_blocked`; stop now terminates
inside grace in both vllm-mlx and llamacpp providers. (2) A deny
verdict cancelled in-flight jobs before shedding resident caches -
the cheapest relief ran last, and the job whose own load tipped the
host was killed by it. Order is now: evict non-serving residents ->
settle -> re-sample -> cancel only on persistent deny
(`DENY_RECHECK_SECONDS = 3.0`). Providers track per-alias serving
counts (`evict_not_inflight`) so a container mid-request is never
shed. (3) Memory WARNING mapped to deny_and_cancel, but the kernel
warn boundary (memorystatus_level <= 30) is a reclaim notice, not
the emergency floor - on a 16 GB host ANY useful resident model
(4-5 GB) idles at ~25-30, so the flagship workload was structurally
unadmissible: loads died at recheck and idle residents were shed
~1s after each turn, destroying the prefix cache between calls.
WARNING now maps to DEFER_LOAD semantics (new loads freeze,
in-flight finishes, residents keep serving); CRITICAL (<= 8,
swap-storm floor) keeps deny_and_cancel. Verified live: a resident
qwen3.8-9b-vllm server held through level oscillation 27-50 and
served warm-cache turns while the host sat at warning.

Measured coding-agent comparison through governed /v1 (same bench:
~5.4-5.9K-token repo context + tool schemas, cold load, repeat
prefix turn, 350-token codegen): qwen2.5-coder-7b-vllm (official
mlx-community conversion, Qwen2ForCausalLM - no overlay needed)
cold 8.0s, big-prefix turn 90.9s, same-prefix repeat 3.4s (~27x),
codegen 4/4 signals, ~12 tok/s - but answered in text instead of
emitting the read_file tool call on the agent prompt.
qwen3.8-9b-vllm (overlay-routed) cold 16.2s, big-prefix turn 92.9s,
same-prefix repeat 6.7s (~14x), codegen 3/4, ~12 tok/s - emitted a
correct read_file(src/mod_7.py) tool call. Consumer validation:
ARTEMIS real ModelFactory->ChatOpenAI path against /v1 returned
invoke + bind_tools results with correctly parsed tool_calls;
OpenCode `run --model ondevice/qwen3.8-9b-vllm` completed its
title+build agent calls through governed streaming (cold-context
turn 106s, same-session follow-up 6.1s - real-consumer prefix
cache reuse ~17x). Selection: keep both routes; qwen3.8-9b-vllm
is the verified tool-calling agent default on this host,
qwen2.5-coder-7b-vllm the lighter/faster alternative (noting it
skipped the tool call in this single-sample probe). llama.cpp
remains the cross-platform route; this policy change is macOS-
observed but the warn/defer semantics apply on every OS.
