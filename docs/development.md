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

Serve authenticated POST /v1/chat/completions and GET /v1/models. The initial
text contract preserves ordered system/developer/user/assistant messages and
accepts bounded text strings or text content parts. Unsupported images, tools,
structured-output requests, streaming, and generation options fail explicitly.
Do not discard fields, truncate history, impersonate a cloud model, interpret
prompt text as administration, or turn model requests into agent runs.

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
requests. Connection and request-read limits apply before authentication.

Separate console, model-consumer, and agent-consumer credentials. Persist
secrets only in Keychain, keyed to the resolved runtime root; do not put them in
config, registry, SQLite, URLs, process arguments, diagnostic output, or logs.
An explicit credential-display CLI command may return a secret to its owner's
terminal. Tests use an injected in-memory credential store.

The browser exchanges its console credential for an expiring HttpOnly,
SameSite=Strict cookie and an in-memory CSRF token. Require exact same-origin
checks and CSRF on authenticated mutations; logout invalidates the session and
its event subscriptions. No permissive CORS, localStorage credentials, inline
scripts, remote assets, or arbitrary file serving.

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

Use controlled providers and an in-memory credential store, not downloaded
models or live cloud services. Cover core independence; conversation
preservation; unsupported/malformed/oversized requests; scope/Origin/CSRF
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
