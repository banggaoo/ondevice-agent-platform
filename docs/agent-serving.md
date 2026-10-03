# Baseline agent serving

**Status:** v0.9 baseline facility, remaining details proposed, 2026-10-04. Agent serving is a default platform capability exposed through Agent Client Protocol (ACP). No endpoint, harness, or agent runtime exists yet, and nothing here grants the platform or any agent permission to automate ARTEMIS or execute arbitrary code.

## Agent front door

Agent serving is a baseline platform facility exposed through Agent Client Protocol (ACP), alongside the default OpenAI-compatible LLM interface. Installed agent profiles and the Operator instance may be absent; this does not make protocol support an optional extension or prevent core administration. The Operator is a served agent: a console or other client interacts with it through ACP, while its own harness requests generative inference through the scoped OpenAI-compatible ModelClient. Other agents follow the same separation.

Use stable ACP v1 as the proposed initial pinned interoperability profile: initialize, session/new, session/prompt, session/update, and session/cancel. A v1 prompt turn ends with a stopReason response; streamed agent/tool updates and cancellation follow that negotiated lifecycle. Current documentation labels v2 Draft; do not mix its changed prompt-acceptance/completion rules into v1 or claim untested multi-version compatibility. Optional load/resume/close and richer content must reflect the pinned specification and tested implementation. Stdio MCP support is required by v1; optional HTTP/SSE MCP transports are advertised only if qualified under the same server-definition policy.

The earlier /api/agent-runs HTTP trio is superseded as the public agent interface. AgentRunRecord remains an internal lifecycle abstraction mapped to an ACP session/turn. A console bridge or stdio facade may connect to the same core; bridge mechanics are proposed implementation details, not a new mandatory public protocol or a claim that arbitrary HTTP/WebSocket framing is standard ACP.

| ACP v1 method | Proposed internal mapping |
| --- | --- |
| `initialize` | Negotiate protocol version and capabilities; platform identity/scope validation is a separate authorization check, not an implicit grant from negotiation |
| `session/new` | Open a session for the profile bound to the reviewed facade invocation or console-bridge connection; pin agent/harness versions and core run/session records |
| `session/prompt` | Admit the turn through core checks; the harness advances and returns a `stopReason` on completion |
| `session/update` | Stream typed run events/progress to the client |
| `session/cancel` | Scoped cancellation of the run and its child calls; no model call |

The standard v1 session/new payload does not select an agent_id. The proposed facade/bridge binds one registered profile before session creation; it does not add an undocumented field to the standard method. A session keeps that profile and harness-version snapshot across turns; a new approved profile version requires a new session unless an explicit compatible migration is authorized. Cancellation ends the active turn and its child work while retaining the session according to the negotiated lifecycle.

A hosted agent's model steps use `POST /v1/chat/completions` through the scoped `ModelClient`. An ordinary model completion is never silently replaced by an agent run. ModelService returns tool-call data and does not execute consumer tool declarations; during an explicitly requested agent run, that agent's harness may ask the broker to execute a registered tool after argument validation and run-scope checks. This grants no additional permission and does not authorize arbitrary generated code.

## Versioned records

| Record | Conceptual fields |
| --- | --- |
| `AgentProfile` | agent_id, agent_version, harness_id, harness_version, implementation_ref, model_profile, tool_scope, budget_profile, state_schema_version |
| `AgentRunRecord` | run_id, consumer_id, pinned agent/harness versions, resolved model-profile snapshot, granted tool/disclosure scope, deadline/budget, state/checkpoint schema version, child request IDs |

Profile and harness versions are immutable records; implementation code is reviewed and registered through the platform, never loaded from arbitrary paths or remote commands. The core is the authoritative state writer: a harness submits typed events and checkpoints through scoped APIs and cannot edit durable records directly.

## Harness lifecycle

Conceptual hooks: `initialize(run_context, input)`, `advance(event)`, `snapshot()`, `cancel(reason)`; the concrete framework is not fixed. Deterministic steps can complete a supported task with zero model calls. Model steps occur only where explicitly allowed and every call counts against the run budget.

## Update, pinning, and cancellation

- Updating one agent's harness or spec changes neither the core nor other agents.
- New runs use the newly approved version; in-flight runs stay pinned to their recorded versions.
- State schema migration is explicit: compatibility is checked and a previous definition remains available for rollback.
- Permission revocation and core resource limits override any pinned version; an agent cannot modify its own permission grants.
- Cancellation propagates to queued and active child requests. A harness holds no inference slot while waiting on tools, human review, or its own run lifetime; each child generation is separately admitted and charged to the parent run.

## Boundaries

An agent's tool scope is its own declared, approved scope; it does not gain core administrative powers, and the core's administrative API is not reachable through a `ModelClient` prompt or an ACP session. The Operator is one optional served profile; its presence or absence does not affect core serving or the ACP facility itself. ARTEMIS remains an external consumer of model serving and is never hosted or invoked as an automation backend; nothing here authorizes its device actions.

## Acceptance focus

Run lifecycle, version pinning, spec-change compatibility, rollback, isolated per-agent state and tool scopes, child-call budgets, propagated cancellation, and a deterministic task completing with zero inference. The exact acceptance gates are set by [evaluation](evaluation.md); no benchmark or conformance result exists yet.
