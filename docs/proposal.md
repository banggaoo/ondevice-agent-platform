# Revised project proposal

**Version:** 0.9, 2026-10-04. **Status:** strategy for discussion; the user approved the bounded M1 implementation increment ("approve proposal, proceed development") - see [development](development.md) for executed status. The user's latest direction makes the deterministic serving core the center of the platform, with ACP agent serving and the OpenAI-compatible LLM interface as baseline facilities; remaining technical designs are proposed. This revision carries forward the 2026-10-03 source audit plus scoped v0.7/v0.9 primary-source checks recorded in [source notes](references/sources.md) (see the [revision input notes](references/revision-v0.4-notes.md)) and aligns with the user's recorded answers in [open questions](open-questions.md). No implementation is authorized by this document.

## Mission and consumers

Build a macOS serving platform for engineers broadly that serves models and hosted agents through deterministic code, makes inference predictable under resource pressure, and keeps optimization changes reviewable. The OpenAI-compatible LLM interface and ACP agent serving are baseline facilities; open-source/open-weight LLM support and typed non-generative ML inference are first-class supported categories. Local, free-to-use, and performant operation are product goals, not yet measured results or an established license. **The Operator Agent is an optional served agent**; **Google ARTEMIS is an external inference consumer**, using local or explicitly permitted Apple cloud inference for Android automation without editing ARTEMIS source wherever its supported configuration makes that possible.

Basic platform operation is deterministic code. The `PlatformSupervisor` owns startup/shutdown, registry and configuration validation, auth and consumer scopes, resource admission, scheduling, backend lifecycle, cancellation, durable state, and the admin API; typed native handlers serve status/refresh/list requests and authenticated stop controls with no inference calls. A hosted agent's own versioned harness owns its workflow, clients reach it through the default ACP adapter, and its model calls use the same OpenAI-compatible client and admission as external consumers. Model interpretation or confidence never grants a capability. The optional Operator can explain platform status and draft evidence-backed proposals using brokered metrics and redacted diagnostics; it owns no global limits, state, or authority. See the proposed [harness contract](harness-contract.md) and [agent serving](agent-serving.md).

Trying Apple Foundation Models first is a confirmed experiment direction, not proven suitability or a universal provider preference; Apple and open-weight models serve complementary purposes and each route qualifies on declared purpose, verified capability, and device fit. The accepted sole initial product baseline is macOS 27+ on Foundation Models-capable Macs, including M2 devices, using runtime capability checks rather than one fixed machine or a mandatory 9B model. Apple's current framework also offers Private Cloud Compute, but OS, managed entitlement, distribution, quota, and availability requirements make it a conditional provider. Apple documents a stateless, non-retaining PCC privacy design; the entitlement is an access rule for that protected API rather than for the platform's existence, current published rules describe App Store and TestFlight/ad hoc routes rather than a public GitHub executable, and local-only feasibility does not depend on it. See [hardware and models](hardware-and-models.md). Cloud-enabled operation is local-first; only the local-only mode can claim fully on-device inference.

## Core user journey

1. The user starts the per-user executable and opens the local console; provider availability, resource state, and consumer activity come from typed deterministic handlers that make no inference calls and work when every provider is unavailable.
2. A consumer submits an explicit model request; the core validates, admits, routes it to a purpose-selected provider, and returns a bounded result with truthful provider identity.
3. Optionally, the user runs a hosted agent through the default ACP adapter; its own harness drives the workflow and its model steps use the same admitted model interface.
4. The user can stop work, inspect state, and shut down cleanly at any point without a model call.

## Optional served agent: Operator

The Operator is an optional served agent reached through ACP; it can explain a status or investigate a bounded performance problem on demand, then return an explanation with evidence and uncertainty or a structured change proposal. The user rejects, revises, or accepts the exact proposal version for manual action; review is durable and releases inference capacity while waiting. If needed, the user previews and manually exports a package; application stays outside this MVP.

The Operator is an on-demand role, not a continuously running self-modification loop. Automatic audits and optimization work remain opt-in and bounded.

The confirmed longer-term stage order for the optional Operator is: runtime management first, then project/codebase/data, then training, then distribution, then improvement. Every later stage requires its own explicit capability, executor, and data design plus a separate user request; training stays deferred until serving workloads provide measurable evidence. None of these stages is a prerequisite for core serving.

## External consumer: ARTEMIS

Configure a pinned ARTEMIS revision's provider and model routes to use the platform's authenticated loopback gateway. The gateway validates full conversations and requested capabilities, admits work within its budget, and returns the tested API subset. ARTEMIS owns Android observation, planning loops, action execution, and stop behavior.

ARTEMIS is the confirmed inference consumer and this platform is the provider; the platform never invokes ARTEMIS as an automation backend. Behind the client-facing serving contract, permitted internals may be Apple on-device inference, eligible Apple PCC, an owned local model, or bounded harness/agent orchestration. The chosen internal strategy does not expand permissions or relax the requested conversation, modality, tool/schema, stream, error, or disclosure semantics, and internal orchestration grants no extra tool or execution authority. No additional runtime, agent, or backend is added by default; one is evaluated only when measurement shows a declared-contract need. The user envisions Android and iOS testing later; the platform's gate is the declared serving contract, not exhaustive mobile consumer QA, and iOS support is unverified at the pinned revision.

Treat zero-source-change integration as a **feasibility target**. ARTEMIS's current source uses `OPENAI_BASE_URL`, and profile/node routes, fallbacks, summarization, and OCR must also be audited. A base URL alone is insufficient. See the pinned evidence and unresolved routes in [ARTEMIS integration](artemis-integration.md).

A text model or OCR tool is not automatically a substitute for a vision-language policy. If the actual request needs screenshot reasoning, use a verified image-capable provider or reject that route explicitly. Flash and Pro are consumer workflow profiles, not reliable inference capability labels derived from a model-name substring.

## MVP boundary and sequence

| Core phase | Consumer phase | Defer |
| --- | --- | --- |
| Native resource signals and deterministic governor | Tested OpenAI-compatible request subset | Blanket compatibility with all OpenAI APIs |
| Purpose-qualified Apple and owned LLM routes plus typed ML inference | Source-verified provider/profile configuration | Simultaneous implementation of every inference backend |
| Durable decisions and minimal console | Baseline ACP agent serving; installed agent profiles optional | Automatic model discovery and upgrades |
| Conditional PCC capability design | Optional later targeted device smoke checks | General shell access and platform-driven device actions |
| Privacy, quotas, cancellation, recovery | Audit all cloud/OCR/fallback paths | Automatic cloud patch executor |
| Optional Operator proposals/explanations | Consumer retry/timeout/disconnect verification | Distillation, training dashboard, multi-user service |

LangChain/LangGraph remain optional orchestration tools rather than a requirement for the safety boundary. A Swift `PlatformSupervisor` is the recommended candidate because the initial provider and resource APIs are native. One owned open-weight runtime is qualified as a complementary route on evidence, not only when Apple lacks a capability. Runtime data uses the user-selected `~/.ondevice-agent-platform/` root, with per-session directories only when needed; see [runtime layout](runtime-layout.md). Embedded SQLite is the confirmed engine, with schema and record protocol still proposed. The intended delivery is a GitHub-downloadable per-user executable that starts a local server and web console, not a mandatory standalone GUI or App Store package; no publication, license, or release mechanics are approved. See [distribution and responsible use](distribution-and-responsible-use.md). Cloud use is one explicit local-only/eligible-cloud mode choice per consumer or session, not a prompt per generation. ACP is the default agent-facing protocol; the pinned conformance profile is in [ACP integration](acp-integration.md).

## Revisions to the supplied proposals

| Supplied assumption | Revision |
| --- | --- |
| Qwen 3.8 9B Q4 Distill must be the operator | No single model is the platform; purpose-specific candidates (native or owned) qualify on evidence and device fit |
| Every eligible Mac can host the same engine matrix | Capability tiers based on OS, provider availability, memory, workload, and measured headroom |
| 100% on-device plus cloud handoff | Separate local-only and Apple-cloud-enabled policies; disclose actual provider use |
| Port/API shape guarantees zero-code integration | Pin ARTEMIS and validate all active node/provider/OCR routes and wire semantics |
| Short message count or a Flash substring means Apple/Vision can answer | Match explicit modality, schema, context, and tool requirements to verified provider capability |
| 85% RAM / 82°C avoids hardware damage | Public pressure/thermal signals plus calibrated budgets preserve responsiveness; no damage-prevention guarantee |
| Busy response is a successful chat string | Use bounded admission with protocol errors and tested client retry behavior |
| Markdown and a boolean implement approval | Immutable records, exact-version review, expiry, and restart reconciliation |
| External frontier model makes execution safe | Scope and authority must be enforced independently of model choice |
| Application Support is a sandbox | Storage and process confinement are separate |
| Zero database automatically means lower cost | Compare embedded SQLite with a crash-safe file design; no external database service is needed |
| Logs/screenshots become training data | Content capture off by default; any later dataset requires explicit selection and provenance |
| Foundation Models intent classification is a zero-cost fast path | Classifying intent is itself an inference call; it is counted and budgeted, and typed read-only commands come first |
| Routine formatting, file updates, and builds belong in the Operator MVP | These are workspace mutations and execution; they stay outside MVP authority and receive explicit rejections or proposal-only alternatives |
| ACP transparently translates OpenAI inference calls | ACP is the default agent-facing session protocol, distinct from the model gateway; it is not a universal inference translator |
| Per-consumer folders and directory locks provide confinement | Storage placement and locks are organization, not process sandboxing |
| A successful parse proves correctness and supplies training labels | Static syntax is evidence attached at proposal time; it does not prove behavior, authorize execution, or create labels |
| Nighttime scheduling grants permission for heavy validation | Late-night execution is optional scheduling; heavy jobs remain opt-in, disabled initially, and separately authorized |
| Prompt text can enforce context and resource budgets | Prompts can request brevity; the harness must enforce context, output, tool, retry, and time limits |

Empero's published Qwen3.8-9B-Distill GGUF is a third-party candidate; Q4_K_M is listed as 5.78 GB before runtime overhead. It does not prove MLX compatibility or screenshot capability. [Publisher model card](https://huggingface.co/empero-ai/Qwen3.8-9B-Distill-GGUF).

## Optimization and evidence

The long-term LLM/tool/small-model substitution idea remains useful as an experimental pipeline. First measure the actual repeated requests of served consumers such as the optional Operator and ARTEMIS. Try deterministic tools, context reduction, bounded loops, and correctly invalidated caches before training. Logs and satisfaction ratings are not ground-truth labels.

A trained substitute needs a narrow task, approved labels, held-out quality evaluation, abstention/fallback, shadow runs, and rollback. Compare full labeling/training/evaluation/deployment cost with savings per successful request. Core ML placement and energy advantages require device measurements, not assumptions. [Apple performance analysis](https://developer.apple.com/documentation/coreml/analyzing-a-core-ml-model-s-performance-in-xcode).

Core release depends on the code-owned lifecycle and the declared ACP agent, OpenAI-compatible LLM, and typed ML serving contracts, not the optional Operator or any particular external consumer. ARTEMIS compatibility gates advertising that integration; Operator usefulness gates only its optional profile. A platform that adds little over an existing engine should remain a thin wrapper. All numerical limits are experiment inputs until calibrated; no performance or integration result has been measured. Public Internet research may seed conservative starting profiles; native observations and bounded workload measurements validate them before any performance claim.

## Recommended next step

Settle the platform interface/component contract before either a LangChain prompt configuration or an all-night syntax worker. After a separate implementation request, the first experiment should prove the code-only core lifecycle - boot, registry/status, authorized stop, recovery with no provider available - plus the OpenAI-compatible model endpoint on the native adapter and one owned reference backend candidate. An optional deterministic agent fixture and the Operator may follow; they are not prerequisites. Use synthetic platform snapshots, retain explicit unavailable/deferred/error states, and keep all workspace edits and code execution outside the experiment.

Define validation boundaries before prompt tuning: proposal schema and evidence checks at creation, optional bounded syntax parsing, and separately authorized future compilation or behavioral tests. A prompt can encourage brevity; harnesses and the core must enforce context, output, tool, retry, and time limits. The initial console needs status, registry, jobs, and control, not an active training panel or universal model-flush control; optional chat features can be off.
