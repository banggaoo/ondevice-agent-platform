# Docs-first roadmap

**Current phase: bounded M1 implementation**, approved by the user on 2026-10-04 ("approve proposal, proceed development"). The approved increment scope is fixed in [development](development.md); later milestones still require their own explicit requests.

## M0 — Agree on strategy

Deliver and revise the platform-first proposal, provider/device matrix, ARTEMIS source audit, gateway subset, core and per-agent harness contracts, resource policy, approval lifecycle, evaluation plan, and decisions. The user has confirmed the engineer-wide audience and goals, the deterministic code-owned core independent of any agent, baseline ACP agent serving and OpenAI-compatible LLM serving with per-agent versioned harnesses, complementary purpose-selected Apple and open-weight backends plus typed ML inference, the `~/.ondevice-agent-platform/` data root, the SQLite engine, the macOS 27+ sole initial baseline, the ARTEMIS consumer/provider direction, and GitHub-downloadable executable delivery with a per-user local server and console. Still outstanding engineering checks: signing/notarization/build/release/license, PCC eligibility under that delivery plus the cloud disclosure/payload policy, calibrated device/RAM/provider profiles, owned-artifact/runtime qualification, and ARTEMIS's configuration-only offline constraints.

**Exit:** agreement on direction plus a separate explicit request to implement. Confirmed consumer/hardware direction is already recorded; other decisions remain open or proposed.

## M1 - Code-owned serving core

After an explicit implementation request, build the platform lifecycle, authenticated administrative API/console, provider/profile registry, resource observations, bounded scheduler, cancellation, durable core records, and the default OpenAI-compatible and ACP adapters on the accepted macOS 27+ baseline. The adapters are baseline even with an empty agent registry; no Operator or other agent is needed to start, inspect, configure, or stop the platform. Keep runtime data in the chosen dotfolder and session scratch optional. Use controlled adapters/fixtures for fault cases; such fixtures are not advertised as real inference.

**Exit:** the core remains operable with no agents installed and all models unavailable; status, registry, authorized stop, and recovery use no LLM. Unknown/oversized requests, stale pressure, revoked scope, overload, and disconnects produce bounded typed failures. No generated-code execution.

## M2 - Purpose-qualified model serving

Implement the declared OpenAI-compatible model subset behind shared core admission and provider interfaces. Qualify Apple on-device and one owned open-weight artifact/runtime candidate as complementary LLM routes, and the typed MLService with a qualified runtime and registered input/output schemas as a baseline facility; an Apple trial does not make it the universal default. Select per-purpose model profiles from explicit caller requirements, verified capabilities, and device/resource fit. Verify complete conversations, required tools/schema/images, streaming, deadlines, cancellation, and truthful provider identity. Native tool integration does not grant system privileges.

**Exit:** declared model-serving routes pass their contract and resource checks without the Operator; purpose claims and unsupported capabilities are explicit. Test with controlled API clients before live consumer work. PCC is a separate conditional provider gate, not a core prerequisite. No requirement to implement every backend at once.

## M3 - ACP agent serving and versioned harnesses

Implement the baseline [ACP agent-serving module](agent-serving.md) with per-agent profile/harness definitions and explicit run lifecycle. Start with a deterministic reference harness, then bounded model steps using the same OpenAI-compatible interface as external consumers. Validate independent state/tool scopes, version pinning, spec-change compatibility, rollback, child-call budgets, and cancellation. An agent may complete a supported deterministic task with no inference.

**Exit:** installing, updating, or disabling one agent does not replace the core or other harnesses; in-flight runs remain version-pinned subject to current permission revocation. No inference slot is held while a harness waits on tools or review. The Operator is an optional served profile, not a gate for the rest of the platform.

## M4 — ARTEMIS contract feasibility

Pin ARTEMIS and inventory every active node/provider/fallback, OCR/summarizer path, request schema, client timeout, and retry behavior. Determine whether configuration alone can redirect all required inference and disable external dependencies. Audit both Flash and Pro separately. Preserve the ARTEMIS source tree unchanged.

Use recorded/synthetic request fixtures before device automation. Define the compatible gateway subset. Select the tested image/text backend by declared purpose, verified capabilities, and device fit; benchmark at most two plausible pairs, then choose one. Verify artifacts, modality behavior, constrained output, memory, cancellation, unloading, and packaging. Account for emulator and consumer-process memory in headroom.

**Exit:** documented configuration-only coverage and backend capability. **Failure:** label unsupported routes/profiles; narrow integration or evaluate another upstream revision. Any source patch requires a new explicit scope decision.

## M5 - Verify the declared ARTEMIS serving contract

Use the pinned client and recorded/synthetic replay fixtures to verify the supported gateway subset: wire parsing, image grounding where advertised, required JSON/tool output, streamed and nonstreamed responses, finite retries, overload errors, disconnects, cancellation, and provider/resource provenance. Declare the tested revision, profile, capabilities, and unsupported routes. A local-only claim additionally requires an egress audit of every active consumer/OCR/inference route; endpoint tests alone cannot prove it.

Compare the same backend and limits through direct serving and the gateway, recording model/backend differences. Full Android/iOS task qualification is not the platform exit gate. If later requested, run a narrow smoke check on an authorized test device/emulator; first verify the chosen consumer revision actually supports the target platform, including iOS. Keep device actions, accounts, and consumer safety controls outside the serving platform.

**Exit:** the declared serving contract passes its quality/resource/error/privacy checks; no claim of complete mobile task success or unverified iOS support. **Pivot:** narrow the profile or serving subset rather than advertise complete ARTEMIS compatibility.

## M6 — Optimize proven workloads

Try context reduction, bounded loops, valid caching, and deterministic substitutes first. Review and version one candidate at a time, preserve the previous route, and test rollback.

Only add a classifier/distillation experiment after a narrow repeated task, approved labeled dataset, held-out evaluation, abstention/fallback, and amortization plan exist. Background computation is opt-in and governed by power, idleness, pressure, thermal state, schedule, and duration. Screenshots and logs are not automatically datasets.

**Exit:** repeatable net benefit with preserved task quality; otherwise retain the baseline.

## Optional Operator management stages

For the optional Operator profile, the confirmed longer-term order beyond runtime management is: project/codebase/data management, then training, then distribution, then improvement. These are vision stages, not scheduled work. Each requires its own scoped capability, authority, and quality design plus a separate explicit user request. Training stays optional and evidence-gated; this roadmap does not authorize distribution or publication.

The confirmed delivery direction is a GitHub-downloadable repository and per-user executable that starts the local server and web console - not a mandatory standalone GUI or App Store app. Recommended release mechanics (a standard MIT license, versioned archives with checksums, Developer ID signing/notarization) are proposed in [distribution and responsible use](distribution-and-responsible-use.md); signing, notarization, release mechanics, and actual publication remain unverified engineering work, not commands to run now. The user's planned ARTEMIS serving tests are future work; no result exists yet.

## Default protocols

ACP agent serving and the OpenAI-compatible LLM interface are baseline facilities; installed agents and models remain optional. The proposed pinned ACP profile is v1, documented in [ACP integration](acp-integration.md); the custom `/api/agent-runs` proposal is superseded, and no mandatory editor integration exists.

## Separate future capability: applying changes

Mutation or remote execution needs an explicit user request and its own scoped-executor, exact-diff, disclosure, verification, rollback, and crash-reconciliation design. Apple cloud inference permission does not authorize external code/configuration execution.

Heavy compilation and behavioral testing of generated code likewise needs a separately authorized constrained executor; it is not a nighttime MVP feature.

There are no calendar commitments. Estimate work after M0 choices and initial provider/integration feasibility establish the real scope.
