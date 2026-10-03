# Platform and agent harness contract

**Status:** v0.9 proposed design, 2026-10-04; bounded M1 subset implemented. The deterministic core is the `PlatformSupervisor`; served agents are reached through the default ACP adapter and each runs its own versioned harness, whose model steps use the scoped OpenAI-compatible client and whose ML steps use the typed prediction seam. There is no universal `OperatorHarness` owning global admission and no Apple-only assistant role. **Implemented subset (M1):** versioned `AgentProfile`/`AgentHarness` registration, session snapshot pinning, scoped `AgentContext` (`ModelClient`/`MLClient` sharing core admission and cancellation), typed event emission, and the deterministic `reference.status` harness enabled only by `serve --enable-reference-agent`. No Operator, no general tools, and no arbitrary implementation loading.

## Owners and authority

| Path | Owner | Model calls | Effect |
| --- | --- | --- | --- |
| Startup/shutdown, config/registry validation, auth and scopes, scheduling, quotas, cancellation, durable state, telemetry, admin API | `PlatformSupervisor` (deterministic code) | 0 | Administrative control; works with no agent and no provider |
| Status, refresh, list, scoped stop | Native handlers under the supervisor | 0 | Read approved state; stop changes lifecycle but grants no mutation authority |
| Model request | `ModelService` under core admission | Counted, bounded | Returns suggestions/tool-call data; never executes consumer tool declarations |
| Agent run (installed profiles optional) | The agent's own versioned harness via ACP session plus scoped `ModelClient` | Only explicit allowed model/ML steps; every call admitted and charged to the run | Agent workflow/evidence/state; no global policy power |
| Optional Operator explanation/proposal | `OperatorHarness` profile tools, served over ACP | Bounded, on demand | Explanation or reviewable proposal record; no core authority |

Model interpretation or confidence never grants a capability. Calling a model to classify intent is an inference call and is counted and budgeted; typed commands and fixed rules come first. Text such as "refresh" inside a model prompt must not select an administrative capability.

## Request flow

1. Authenticate the consumer and validate the typed request, scope, and size.
2. Check the requested effect against deterministic capabilities; unknown or ambiguous requests cannot select a privileged handler.
3. Run a permitted native handler when it fully satisfies the request; status and stop do not wait for an inference slot.
4. For a declared model task, validate capability, disclosure policy, resource budget, and deadline, then route to the selected provider.
5. For an agent run admitted through an ACP session, resolve the pinned `AgentProfile`/`harness` versions and let the harness submit typed events and checkpoints through scoped APIs; it does not edit the database directly.
6. Validate outputs; mark missing evidence and uncertainty; never invent a completed action.

A consumer inference request must not be replaced by a canned status response, and an ordinary model completion must not silently become an agent run.

## Context limits are a harness responsibility

A prompt may request concise output but cannot enforce the provider's context window, tool scope, retry count, or resource budget. Before inference, the model adapter validates the complete supported conversation, instructions, tool/schema definitions, selected evidence, and image attachments against the provider's verified capacity and the [resource policy](resource-policy.md). Use a documented conservative admission bound when exact token accounting is unavailable; handle provider limit errors explicitly.

Within an agent run, the agent's own harness owns its workflow context, evidence selection, and loop controls, while the core enforces global caps. For the optional Operator, bounded inputs are built from typed snapshots and evidence references; summaries used as model input are untrusted content, never approval or policy. Consumer history, images, and tool results retain the semantics required by the tested contract. Reject requests that cannot fit safely rather than silently dropping required evidence or switching providers.

## Versioned seams

Versions are immutable records; implementation code is reviewed and registered, not loaded from arbitrary paths or remote commands.

| Record | Conceptual fields |
| --- | --- |
| `ModelProfile` | alias, provider_id, kind (llm or ml), task, input_schema, output_schema, artifact_revision/digest (or exposed Apple OS/model identity), purpose, capabilities, context/output limits, ownership/lifecycle, compatible device profile, disclosure policy |
| `AgentProfile` | agent_id, agent_version, harness_id, harness_version, implementation_ref, model_profile, tool_scope, budget_profile, state_schema_version |
| `AgentRunRecord` | run_id, consumer_id, pinned agent/harness versions, resolved model-profile snapshot, granted tool/disclosure scope, deadline/budget, state/checkpoint schema version, child request IDs |

Metadata claims are not a benchmark or an authorization. The core is the authoritative state writer; a harness submits typed events and checkpoints through scoped APIs. Harness lifecycle hooks are `initialize(run_context, input)`, `advance(event)`, `snapshot()`, and `cancel(reason)`; the framework implementation is not fixed. Deterministic steps can satisfy a task with zero model calls; model steps run only where explicitly allowed and all calls count.

Hard cases: updating one agent's harness or spec does not touch the core or other agents; new runs pick the approved version while in-flight runs stay pinned; state migration is explicit with compatibility checked and a previous definition available for rollback; permission revocation and core limits still override a pinned old version; no self-modifying permission grants. Cancellation propagates to child calls. A waiting harness holds no inference slot across tool, review, or run-lifetime waits, preventing nested `ModelClient` deadlock and starvation.

## Static validation and later execution

Schema and evidence checks run when a proposal or agent output is produced. If it includes code, an available bounded parser may attach a syntax result at review time; record language, parser/version, input digest, and `passed`, `failed`, or `not_checked`. Unsupported languages and missing parsers remain explicitly unverified.

A valid AST is not proof of compilation or behavior; compilation is not proof of correctness, safety, or an acceptable training label. [Python's AST limitations](https://docs.python.org/3/library/ast.html#ast.parse). Keep these categories separate from human review and outcome verification. Heavy builds or behavioral tests require an explicitly authorized constrained executor; generated code is not executed to validate itself. Failed or passing syntax is not automatically training data.

## Acceptance evidence

Prove that native status/refresh/list/stop requests make no inference calls and remain available when every provider is unavailable. Prove the core operates with no agent installed. Count optional classification and generation separately. Test ambiguous text, prompt injection, stale evidence, missing providers, pressure, repeated decisions, and malformed output. Test two harness versions, one spec change, rollback, in-flight version pinning, and propagated cancellation. An inexpensive route that produces the wrong answer or bypasses permission fails the gate.

See [safety and approvals](safety-and-approvals.md), [agent serving](agent-serving.md), [resource policy](resource-policy.md), and [evaluation](evaluation.md). No handler, harness, or validation tool has been implemented.
