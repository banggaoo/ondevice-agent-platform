# Proposed evaluation and decision gates

Status: v0.3 discussion draft, 2026-10-03. No benchmarks, integration tests or performance claims are established. Consumer order is Operator first, ARTEMIS second. Implementation requires a separate request.

## Evaluation questions and hardware

Does the Operator explain platform state and propose useful changes beyond a status view? Does governance improve direct provider calls? Can pinned ARTEMIS use the gateway without source edits while preserving vision, tools and failure semantics? Which device tiers meet those requirements?

Test Foundation Models eligibility at runtime on representative supported Macs, including the requested M2 class. The observed M4 Air/16 GB development host is one data point, not a minimum specification. Record OS, availability, memory, power, foreground workload and policy. PCC is a separate conditional track; check entitlement and permitted generic-gateway use before live ARTEMIS requests. Report unavailable quota/service as failure. [Hardware and models](hardware-and-models.md).

## Operator workload and baselines

Prepare approximately 40 synthetic/redacted platform-state fixtures: ten health/provider explanations, ten admission/queue explanations, ten evidence-backed optimization proposals and ten adverse cases. Include stale or missing observations, contradictory diagnostics, unavailable providers, quota exhaustion and hostile instructions embedded in diagnostic text. Specify expected facts, evidence IDs, uncertainty and forbidden actions before tuning.

Split development and held-out fixtures by scenario family. Freeze the rubric before evaluation; avoid near-duplicates across partitions. Prefer blind human review with disagreement recorded. The Operator's confidence and self-rating are not ground truth. Compare against:

1. A deterministic status dashboard and rule-generated explanation/proposal template.
2. Direct calls to the same Apple provider with identical prompts, structured inputs and limits.
3. A fixed manual harness with the same metadata broker, without adaptive governance or optimization.

Score factual grounding, invented causes, proper handling of uncertainty, requested scope and proposal usefulness. A proposal should identify the problem, supporting observations, intended change, validation and rollback. Record model/tool calls, input/output size, latency, queue time and cancellation.

## ARTEMIS source and wire feasibility

Pin source revision, dependency lock, resolved configuration, profile and test-device setup. The inspected checkout is revision `351ca8422f7b5b54e80a9c1ce03a222e02415b6b`; its remote is the user's fork. Static inspection verifies configuration paths, not successful requests. [ARTEMIS integration](artemis-integration.md) identifies direct Google summarization, OCR and native-video paths that a base URL does not redirect.

After implementation authorization, capture requests against a controlled test endpoint with synthetic screenshots. Test the actual locked client for non-streamed and streamed chat, fragmented tool-call arguments, tool results, JSON/schema output, image blocks, output limits and terminal/error events. Verify whether its SDK chooses Chat Completions or another endpoint; implement only the demonstrated subset. Never discard unsupported modalities or silently convert tool calls into plain text. [Gateway contract](gateway-contract.md).

Test Flash and Pro separately. These are harness profiles, not gateway model capabilities. Audit every active node, utility, fallback and background summarizer. Test 429/503 retry limits, timeouts, partial-stream failures, disconnect cancellation, restart and exhausted budgets. Confirm the consumer stops or reports failure rather than treating a busy message as a completed task.

Begin with a frozen screenshot/hierarchy replay set, then an explicitly authorized test device/emulator and deterministic target states. Include ordinary UI, custom controls, coordinate grounding, small text, dialogs and missing hierarchy. Evaluate native image inference first on macOS 27, separately from earlier text-only API tiers; then any needed owned VLM. Compare ARTEMIS using the same model/configuration through direct serving versus the gateway. Model/quantization changes are not pure gateway-overhead comparisons. Upstream benchmark claims do not establish local-model performance.

Device authority stays outside the platform. Keep test accounts and live-device actions within the consumer's own authorization and stop policy. Include emulator/device-observation costs in total-machine measurements; do not attribute them all to inference.

## Resources and privacy procedure

Measure cold/warm availability and load costs, p50/p95 task latency, first-token latency where meaningful, peak process/model memory, pressure transitions, swap change, idle overhead and cancellation/recovery deadlines. Apple owns system-model residency; measure whole-machine impact without claiming the platform evicted it. Owned-worker counters, process memory and system memory describe different quantities and should not be summed blindly.

Use paired tasks, identical limits and repeated measurements with spread reported. Exercise foreground work, consumer fairness, queue saturation and provider recovery. Fault injection and real-pressure tests provide separate evidence. Private input requires the chosen native adapter's trust, broker and disclosure checks; optional workers additionally need OS confinement.

Local-only tests remove inherited cloud/OCR credentials, audit native provider bypasses and observe outbound destinations while denying external inference traffic. Include startup/download behavior as a separate setup audit. Screen data must not escape via OCR, video upload, fallback or raw logging. Configuration inspection alone cannot prove offline operation. Optional energy experiments must state collection method, permissions, baseline subtraction and uncertainty; tokens and temperature are not battery measurements.

## Pass, fail and pivot

| Gate | Proposed condition | Failure response |
| --- | --- | --- |
| Operator usefulness | At least 90% success on supported held-out fixtures; no material unsupported facts in accepted proposals; useful beyond static status | Narrow scope, improve metadata/templates or retain a deterministic dashboard |
| Authority/privacy | Defined denial cases pass; no direct state access or unauthorized disclosure; owned-worker confinement proven before private data | Keep synthetic inputs and repair the boundary |
| Durable review | Restart preserves exact proposal versions; stale/expired approvals cannot authorize changed artifacts | Repair records before adding workflows |
| ARTEMIS compatibility | Locked client passes required image/tool/schema/stream/error cases with no source changes for the declared profile | Narrow supported profile, request an upstream change or defer integration |
| Resource control | Agreed budgets, bounded admission/retries and cancellation/recovery deadlines hold | Reduce task/model/context or use a thinner wrapper |
| Gateway overhead | Warm model-call p95 adds no more than 10% over direct serving under identical conditions | Simplify transport/control path; reassess its governance benefit |

The 90% and 10% targets require discussion and adequate samples. Proposed resource bounds in [resource policy](resource-policy.md) also require device-tier calibration. A failed task cannot count as efficient because it used less compute. Prefer deterministic tools, context reduction and valid caches before training. Classifier promotion requires approved labels, holdout/shadow evaluation, abstention, rollback and lifecycle-cost amortization.
