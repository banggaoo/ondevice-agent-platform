# Docs-first roadmap

**Current phase: M0.** Only strategy documentation is authorized by the current request. Later milestones describe future work after an explicit implementation request; they are not instructions to run installations or services now.

## M0 — Agree on strategy

Deliver and revise the Operator-first proposal, Apple provider/device matrix, ARTEMIS source audit, gateway subset, resource policy, approval lifecycle, evaluation plan, and decisions. Resolve storage, packaging/PCC eligibility, first supported OS/RAM tiers, and ARTEMIS's configuration-only offline constraints.

**Exit:** agreement on direction plus a separate explicit request to implement. Confirmed consumer/hardware direction is already recorded; other decisions remain open or proposed.

## M1 — Verify Apple-native Operator feasibility

After implementation is requested, use synthetic platform-state fixtures. Check supported macOS resource signals and Apple on-device model availability on agreed devices, including an M2-class target. Compare Operator explanations/proposals with deterministic status summaries. Verify context, schema, cancellation, timeout, and refusal behavior; no automatic tool/policy changes.

Evaluate candidate signing/application permissions and authenticate the local console. The trusted native Apple adapter may initially run in process; it receives brokered inputs and never executes model output. If an owned-model worker is added, separately demonstrate its runtime/model allowlist, denied direct private state/trace access, denied write/network/child-action capabilities, and recovery before private live use. Check PCC eligibility and entitlement separately; local operation must remain useful if cloud is unavailable.

**Exit:** useful bounded Operator behavior on the declared hardware/OS tier; demonstrated required confinement before private data. **Pivot:** simplify to a status view plus proposal helper if the model adds little value.

## M2 — Small governed Operator product

Implement durable jobs/proposals, scoped metadata tools, quotas/retention, review/revision/export, deterministic resource response, and restart reconciliation. Pending review releases inference capacity. Show provider availability and defer reasons, never a false completion.

If PCC is eligible and enabled, validate policy-constrained disclosure, network/quota failures, cancellation, and visible provider provenance. Before routing live ARTEMIS traffic through PCC, establish that the consumer gateway use is covered by the applicable entitlement and usage terms. Never silently move a local-only request to cloud. Apple system-model residency is observed rather than forcibly unloaded by this app.

**Exit:** Operator journey works; changed/expired proposals cannot reuse approval; privacy and negative capability cases pass. No patch application, shell, training, or external executor.

## M3 — ARTEMIS contract feasibility

Pin ARTEMIS and inventory every active node/provider/fallback, OCR/summarizer path, request schema, client timeout, and retry behavior. Determine whether configuration alone can redirect all required inference and disable external dependencies. Audit both Flash and Pro separately. Preserve the ARTEMIS source tree unchanged.

Use recorded/synthetic request fixtures before device automation. Define the compatible gateway subset. Select an additional local image/text backend only for a required capability Apple cannot satisfy; benchmark at most two plausible pairs, then choose one. Verify artifacts, modality behavior, constrained output, memory, cancellation, unloading, and packaging. Account for emulator and consumer-process memory in headroom.

**Exit:** documented configuration-only coverage and backend capability. **Failure:** label unsupported routes/profiles; narrow integration or evaluate another upstream revision. Any source patch requires a new explicit scope decision.

## M4 — Controlled ARTEMIS evaluation

Run the pinned unmodified consumer against the gateway on one test device/emulator with harmless tasks and test accounts. Verify wire parsing, image understanding, required JSON/tool output, streamed and nonstreamed responses, finite retries, overload errors, disconnects, and cancellation. Local-only mode includes a network egress audit of ARTEMIS, OCR, and inference providers; network access intrinsic to a test app is reported separately.

Compare against the same backend without adaptive governance and document model/backend differences. Distinguish platform inference success from Android task success; never transfer upstream cloud benchmark claims to local models.

**Exit:** compatible, useful behavior under declared quality/resource/timeout gates. **Pivot:** retain a narrower tested profile rather than claiming complete ARTEMIS support.

## M5 — Optimize proven workloads

Try context reduction, bounded loops, valid caching, and deterministic substitutes first. Review and version one candidate at a time, preserve the previous route, and test rollback.

Only add a classifier/distillation experiment after a narrow repeated task, approved labeled dataset, held-out evaluation, abstention/fallback, and amortization plan exist. Background computation is opt-in and governed by power, idleness, pressure, thermal state, schedule, and duration. Screenshots and logs are not automatically datasets.

**Exit:** repeatable net benefit with preserved task quality; otherwise retain the baseline.

## Separate future capability: applying changes

Mutation or remote execution needs an explicit user request and its own scoped-executor, exact-diff, disclosure, verification, rollback, and crash-reconciliation design. Apple cloud inference permission does not authorize external code/configuration execution.

There are no calendar commitments. Estimate work after M0 choices and initial provider/integration feasibility establish the real scope.
