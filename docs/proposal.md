# Revised project proposal

**Version:** 0.3, 2026-10-03. **Status:** strategy for discussion. Consumer order and device direction reflect the user's clarification; technical choices remain proposed. No implementation is authorized by this document.

## Mission and consumers

Build a macOS serving platform that makes agent inference predictable under resource pressure and makes optimization changes reviewable. The first consumer is the platform's **Operator Agent**. The second is **Google ARTEMIS**, using local or explicitly permitted Apple cloud inference for Android automation without editing ARTEMIS source wherever its supported configuration makes that possible.

The Operator's first valuable task is explaining platform status: why a request was deferred, which provider is available, where resource cost is accumulating, and what narrowly scoped change could improve it. It uses brokered metrics and redacted diagnostics, and produces evidence-backed proposals. Deterministic application code owns permissions and resource decisions.

Support Apple Foundation Models-capable Macs, including M2 devices, using runtime capability checks rather than one fixed machine or a mandatory 9B model. Prefer the Apple on-device provider for the Operator. Apple's current framework also offers Private Cloud Compute, but OS, managed entitlement, distribution, quota, and availability requirements make it a conditional provider. See [hardware and models](hardware-and-models.md). Cloud-enabled operation is local-first; only the local-only mode can claim fully on-device inference.

## First user journey: Operator

1. The user opens the local console and sees provider availability, resource state, and consumer activity.
2. The user asks the Operator to explain a status or investigate a bounded performance problem.
3. The broker provides approved platform metadata; the model cannot freely inspect the filesystem or alter configuration.
4. The Operator returns an explanation with evidence and uncertainty, or a structured change proposal.
5. The user rejects, revises, or accepts the exact proposal version for manual action. Review is durable and releases inference capacity while waiting.
6. If needed, the user previews and manually exports a package. Application happens outside this MVP, with reported and verified outcomes kept distinct.

The Operator is an on-demand role, not a continuously running self-modification loop. Automatic audits and optimization work remain opt-in and bounded.

## Second user journey: ARTEMIS

Configure a pinned ARTEMIS revision's provider and model routes to use the platform's authenticated loopback gateway. The gateway validates full conversations and requested capabilities, admits work within its budget, and returns the tested API subset. ARTEMIS owns Android observation, planning loops, action execution, and stop behavior.

Treat zero-source-change integration as a **feasibility target**. ARTEMIS's current source uses `OPENAI_BASE_URL`, and profile/node routes, fallbacks, summarization, and OCR must also be audited. A base URL alone is insufficient. See the pinned evidence and unresolved routes in [ARTEMIS integration](artemis-integration.md).

A text model or OCR tool is not automatically a substitute for a vision-language policy. If the actual request needs screenshot reasoning, use a verified image-capable provider or reject that route explicitly. Flash and Pro are consumer workflow profiles, not reliable inference capability labels derived from a model-name substring.

## MVP boundary and sequence

| Operator phase | ARTEMIS phase | Defer |
| --- | --- | --- |
| Native resource signals and deterministic governor | Tested OpenAI-compatible request subset | Blanket compatibility with all OpenAI APIs |
| Apple on-device provider, bounded Operator tasks | Source-verified provider/profile configuration | Simultaneous implementation of every inference backend |
| Platform metadata tools and structured proposals | Required local text/vision capability only | Automatic model discovery and upgrades |
| Durable decisions and minimal console | One controlled test device or emulator | General shell access and platform-driven device actions |
| Conditional PCC capability design | Audit all cloud/OCR/fallback paths | Automatic cloud patch executor |
| Privacy, quotas, cancellation, recovery | Consumer retry/timeout/disconnect verification | Distillation, training dashboard, multi-user service |

LangChain/LangGraph remain optional orchestration tools rather than a requirement for the safety boundary. Start with the smallest durable workflow that serves the Operator. A Swift control plane is the recommended candidate because the initial provider and resource APIs are native. Add a separate MLX or llama.cpp worker only if the second consumer's required capability justifies it.

## Revisions to the supplied proposals

| Supplied assumption | Revision |
| --- | --- |
| Qwen 3.8 9B Q4 Distill must be the operator | Apple on-device provider first; benchmark third-party 9B only if a task needs it and it fits |
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

Empero's published Qwen3.8-9B-Distill GGUF is a third-party candidate; Q4_K_M is listed as 5.78 GB before runtime overhead. It does not prove MLX compatibility or screenshot capability. [Publisher model card](https://huggingface.co/empero-ai/Qwen3.8-9B-Distill-GGUF).

## Optimization and evidence

The long-term LLM/tool/small-model substitution idea remains useful as an experimental pipeline. First measure the Operator and ARTEMIS's actual repeated requests. Try deterministic tools, context reduction, bounded loops, and correctly invalidated caches before training. Logs and satisfaction ratings are not ground-truth labels.

A trained substitute needs a narrow task, approved labels, held-out quality evaluation, abstention/fallback, shadow runs, and rollback. Compare full labeling/training/evaluation/deployment cost with savings per successful request. Core ML placement and energy advantages require device measurements, not assumptions. [Apple performance analysis](https://developer.apple.com/documentation/coreml/analyzing-a-core-ml-model-s-performance-in-xcode).

Proceed only if the Operator is useful beyond a static status view and ARTEMIS achieves compatible, resource-bounded operation on the selected device class. A platform that adds little over an existing engine should remain a thin wrapper. All numerical limits are experiment inputs until calibrated; no performance or integration result has been measured.
