# Proposed evaluation and decision gates

Status: v0.9 discussion draft, 2026-10-04. No benchmarks, integration tests or performance claims are established. Core model/agent serving is evaluated independently of optional consumers. Implementation requires a separate request.

## Evaluation questions and hardware

Does the deterministic core operate correctly with all agents disabled and providers unavailable? Does the declared model-serving API preserve its contract under resource pressure? Can purpose-qualified native and owned-model routes serve their declared workloads? Can optional agent harnesses evolve independently while retaining scope, version, state, and cancellation guarantees? ARTEMIS and the Operator are separate consumer exercises, not owners of the serving core.

Test core operation and each declared provider independently on representative Macs under the accepted macOS 27+ baseline, including the requested M2 class. The observed M4 Air/16 GB development host is one data point, not a minimum specification. Record OS, availability, memory, power, foreground workload and policy. PCC is a separate conditional track; verify API access for the chosen GitHub-distributed executable and permitted consumer-gateway use before live ARTEMIS requests. Report unavailable quota/service as failure. [Hardware and models](hardware-and-models.md).

## Core and harness independence

With no Operator profile installed and an empty agent registry, exercise authenticated startup, registry/status, queue limits, scoped cancellation, and restart. With every inference provider unavailable, these administrative paths must still work without a model call, while inference requests fail explicitly. Text such as "refresh" in a model prompt must not select an administrative capability.

For hosted agents, verify that model calls use the same OpenAI-compatible contract, admission, and disclosure checks as external consumers. Ordinary model completions must not execute consumer tool declarations. Test two distinct harness versions, one changed specification, rollback, and an in-flight run pinned to the prior version. Permission revocation takes precedence over pinned definitions. Check isolated consumer state, parent/child accounting, propagated cancellation, and that a waiting harness does not occupy the model inference slot.

## Default protocol and ML facilities

Verify the default ACP agent and OpenAI-compatible LLM adapters independently of whether the Operator or any particular model is installed. Pin ACP v1 and a target client for the initial profile; test initialize, session/new, session/prompt, streamed session/update, permission denial, cancellation, and provider failure according to v1 turn-completion semantics. Advertise optional session/modality capabilities only after their cases pass; do not mix draft v2 behavior. Required stdio MCP support must be qualified with reviewed server definitions and denied out-of-policy command/path/environment requests before conformance is claimed.

Test a deterministic registered agent that completes a supported task with zero model calls, then a served-agent model step that passes through the same OpenAI-compatible admission path as an external caller. Empty or unavailable agent profiles produce explicit errors without breaking core controls. Validate that an ACP client permission response cannot bypass core grants.

For ML inference, validate typed input/output schemas, incompatible task/feature rejection, unavailable runtimes, resource limits, cancellation boundaries, and separate LLM-call versus ML-prediction accounting. An ML step does not require an LLM but still consumes compute. Prediction labels or confidence cannot grant administrative or tool scope, and unsupported tensor/classifier results are not fabricated chat completions. These are acceptance cases, not executed results; ML training remains separate.

## Purpose-qualified model comparison

Freeze supported task inputs, expected outputs, tool/schema requirements, and limits before comparing routes. Match text/reasoning/code tasks only where both selected providers support the required contract; evaluate vision separately on verified image-capable routes. Record exact artifact/runtime/quantization/template, exposed Apple OS/model identity, device/load conditions, and cold/warm state. Publisher scores and advertised context are not this platform's quality or resource results.

Compare task quality, latency, resource use, and permitted energy measurements for the declared purpose, not a universal "intelligence" rank. No source checked here supplies a matched Apple macOS 27 versus this Qwen9B comparison. Native tool integration is evaluated separately from reasoning quality; all tool effects remain authorized code. Promotion requires useful quality within the device/resource profile, with unavailable or unsupported routes reported rather than hidden capability downgrade.

## Optional Operator workload and baselines

This is an optional consumer evaluation, not a prerequisite for core model or agent serving. Clients access the Operator through ACP; its own harness uses the same OpenAI-compatible model client as ARTEMIS, and its usefulness cannot determine whether the serving core works.

Prepare approximately 40 synthetic/redacted platform-state fixtures: ten health/provider explanations, ten admission/queue explanations, ten evidence-backed optimization proposals and ten adverse cases. Include stale or missing observations, contradictory diagnostics, unavailable providers, quota exhaustion and hostile instructions embedded in diagnostic text. Specify expected facts, evidence IDs, uncertainty and forbidden actions before tuning.

Use the [harness contract](harness-contract.md) to distinguish native commands from generative tasks. Status, refresh, list, and stop requests must make no inference calls and remain available when the provider is unavailable. An ambiguous request or injected diagnostic must not select an edit, build, shell, or policy-change capability. Count any model-based classification as inference rather than a zero-call route.

Split development and held-out fixtures by scenario family. Freeze the rubric before evaluation; avoid near-duplicates across partitions. Prefer blind human review with disagreement recorded. The Operator's confidence and self-rating are not ground truth. Compare against:

1. A deterministic status dashboard and rule-generated explanation/proposal template.
2. Direct calls to the same selected provider with identical prompts, structured inputs and limits.
3. A fixed manual harness with the same metadata broker, without adaptive governance or optimization.

Score factual grounding, invented causes, proper handling of uncertainty, requested scope and proposal usefulness. A proposal should identify the problem, supporting observations, intended change, validation and rollback. Record model/tool calls, input/output size, latency, queue time and cancellation.

## ARTEMIS source and wire feasibility

Pin source revision, dependency lock, resolved configuration and profile; record test-device setup only for a later live-device exercise. The inspected checkout is revision `351ca8422f7b5b54e80a9c1ce03a222e02415b6b`; its remote is the user's fork. Static inspection verifies configuration paths, not successful requests. [ARTEMIS integration](artemis-integration.md) identifies direct Google summarization, OCR and native-video paths that a base URL does not redirect.

After implementation authorization, capture requests against a controlled test endpoint with synthetic screenshots. Test the actual locked client for non-streamed and streamed chat, fragmented tool-call arguments, tool results, JSON/schema output, image blocks, output limits and terminal/error events. Verify whether its SDK chooses Chat Completions or another endpoint; implement only the demonstrated subset. Never discard unsupported modalities or silently convert tool calls into plain text. [Gateway contract](gateway-contract.md).

Test Flash and Pro separately. These are harness profiles, not gateway model capabilities. Audit every active node, utility, fallback and background summarizer. Test 429/503 retry limits, timeouts, partial-stream failures, disconnect cancellation, restart and exhausted budgets. Confirm the consumer stops or reports failure rather than treating a busy message as a completed task.

Use a frozen screenshot/hierarchy replay set for serving capability tests. Include ordinary UI, custom controls, coordinate grounding, small text, dialogs and missing hierarchy. Select the image-capable route by declared purpose, verified capabilities, and device fit; evaluate native and owned candidates without treating either as a universal default. Compare ARTEMIS using the same model/configuration through direct serving versus the gateway. Model/quantization changes are not pure gateway-overhead comparisons. Upstream benchmark claims do not establish local-model performance. Full Android/iOS task success is not an exit gate for the platform serving milestone; future iOS use requires source and runtime verification rather than an assumed consumer capability.

If a live-device exercise is later requested, keep authority outside the platform. Use authorized test accounts and consumer-owned action/stop policy. Include emulator/device-observation costs in total-machine measurements when those components are present; do not attribute them all to inference. Declare live-device results separately from serving-contract results.

## Resources and privacy procedure

Published research informs starting assumptions, not measured results for this platform. Keep source-informed estimates separate from this workload's observed memory, latency, pressure, cancellation, and quality results. Apple's Foundation Models Instruments exposes runtime profiling metrics and can capture sensitive prompt/response content; start with synthetic fixtures and keep trace files outside Git. [Apple profiling guidance](https://developer.apple.com/videos/play/wwdc2026/243/).

Measure cold/warm availability and load costs, p50/p95 task latency, first-token latency where meaningful, peak process/model memory, pressure transitions, swap change, idle overhead and cancellation/recovery deadlines. Apple owns system-model residency; measure whole-machine impact without claiming the platform evicted it. Owned-worker counters, process memory and system memory describe different quantities and should not be summed blindly.

Use paired tasks, identical limits and repeated measurements with spread reported. Exercise foreground work, consumer fairness, queue saturation and provider recovery. Fault injection and real-pressure tests provide separate evidence. Private input requires the chosen native adapter's trust, broker and disclosure checks; optional workers additionally need OS confinement.

Local-only tests remove inherited cloud/OCR credentials, audit native provider bypasses and observe outbound destinations while denying external inference traffic. Include startup/download behavior as a separate setup audit. Screen data must not escape via OCR, video upload, fallback or raw logging. Configuration inspection alone cannot prove offline operation. Optional energy experiments must state collection method, permissions, baseline subtraction and uncertainty; tokens and temperature are not battery measurements.

## Pass, fail and pivot

| Gate | Proposed condition | Failure response |
| --- | --- | --- |
| Core independence | Administrative lifecycle and model serving do not require the Operator or any hosted agent; missing providers yield explicit errors | Repair shared-core ownership before adding consumers |
| Default facilities | ACP agent serving, OpenAI LLM serving, and typed ML inference are baseline interfaces with explicit availability and tested capability claims | Repair protocol/serving adapters without making the Operator mandatory |
| Optional Operator usefulness | At least 90% success on supported held-out fixtures; no material unsupported facts in accepted proposals; useful beyond static status | Narrow or omit the optional Operator; retain independent serving core |
| Harness independence | Version pinning, rollback, scoped tools/state, child budgets, and cancellation hold for each optional agent | Repair the agent module without assigning it core authority |
| Authority/privacy | Defined denial cases pass; no direct state access or unauthorized disclosure; owned-worker confinement proven before private data | Keep synthetic inputs and repair the boundary |
| Durable review | Restart preserves exact proposal versions; stale/expired approvals cannot authorize changed artifacts | Repair records before adding workflows |
| ARTEMIS compatibility | Locked client passes required image/tool/schema/stream/error cases with no source changes for the declared profile | Narrow supported profile, request an upstream change or defer integration |
| Resource control | Agreed budgets, bounded admission/retries and cancellation/recovery deadlines hold | Reduce task/model/context or use a thinner wrapper |
| Gateway overhead | Warm model-call p95 adds no more than 10% over direct serving under identical conditions | Simplify transport/control path; reassess its governance benefit |

The ARTEMIS compatibility gate covers only the declared serving contract. It does not certify exhaustive consumer mobile QA, iOS support, or any ARTEMIS-based automation executor. Any local-only or zero-source-change claim still needs the corresponding consumer-route and egress evidence.

The 90% and 10% targets require discussion and adequate samples. Proposed resource bounds in [resource policy](resource-policy.md) also require device-tier calibration. A failed task cannot count as efficient because it used less compute. Prefer deterministic tools, context reduction and valid caches before training. Classifier promotion requires approved labels, holdout/shadow evaluation, abstention, rollback and lifecycle-cost amortization. The 90% Operator target gates only that optional consumer; it does not gate core serving.

## First paired measurement (recorded, 2026-10-04)

Conditions: M4 Air 16 GB, thermal `fair`, single run, `temperature: 0`,
`max_tokens: 256`, direct provider calls (admission not in the path -
this measures model behavior, not the resource gate). Three fixed prompts.
This is one data point, not a benchmark; spread and repeats are pending.

| Prompt | apple-fm | qwen3-4b | qwen-small (0.6B) |
|---|---|---|---|
| math (17*23+19) | 4.9s, correct (410) | 18.1s, correct, verbose | 8.1s, truncated in `<think>` - no answer within cap |
| code (isPalindrome) | 2.0s, correct, idiomatic | 3.6s, correct, idiomatic | 6.1s, truncated in `<think>` |
| instruction (3 colors) | 0.67s, exact format | 0.53s, correct | 3.3s, thinking chatter |

Observations consistent with (not proof of) the user's purpose hypothesis:
the Apple route is materially faster and reliably format-exact on short
system-style tasks; qwen3-4b matches quality on reasoning/code at higher
latency; the 0.6B variant's chain-of-thought spillover makes it a poor fit
for short-capped utility calls - a real purpose-fit finding, not a quality
rank. MLX tok/s under thermal-fair conditions on this host is plausible
(~60-100 gen tok/s observed for 4B-4bit). No claim about the 9B class or
battery-normalized cost until repeated measurement under controlled load.
