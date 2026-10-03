# ondevice-agent-platform

A proposed local-first, resource-aware agent serving platform for Apple Silicon macOS.

**Status: strategy draft v0.3, 2026-10-03. Documentation only.** No runtime, model, service, integration, or training job has been implemented.

The confirmed consumer order is **the platform's own Operator Agent first, Google ARTEMIS second**. The Operator explains platform health and drafts reviewed optimization proposals. ARTEMIS later uses the same governed serving layer for Android automation inference. Device actions remain ARTEMIS's responsibility.

Start with Apple Foundation Models on eligible Macs, including M2-class devices. Add an owned local text/vision worker only when a consumer needs capabilities the Apple provider cannot satisfy. Use Apple's Private Cloud Compute where the app, OS, entitlement, quota, and disclosure policy permit it; maintain a distinct local-only mode.

## Read and discuss

| Document | Purpose |
| --- | --- |
| [Revised proposal](docs/proposal.md) | Direction, confirmed scope, and revised assumptions |
| [Architecture](docs/architecture.md) | Operator-first topology and provider boundaries |
| [Hardware and models](docs/hardware-and-models.md) | Device eligibility, Apple providers, PCC constraints, and model tiers |
| [ARTEMIS integration](docs/artemis-integration.md) | Source-verified configuration and zero-code-change feasibility |
| [Gateway contract](docs/gateway-contract.md) | Proposed OpenAI-compatible subset and failure semantics |
| [Resource policy](docs/resource-policy.md) | Admission, cancellation, reclamation, and scheduling |
| [Safety and approvals](docs/safety-and-approvals.md) | Authority, durable review, cloud disclosure, and privacy |
| [Roadmap](docs/roadmap.md) | Sequenced milestones and exit criteria |
| [Evaluation](docs/evaluation.md) | Operator and ARTEMIS baselines and gates |
| [Decision register](docs/decisions.md) | Confirmed scope versus proposed technical choices |
| [Discussion questions](docs/open-questions.md) | Remaining decisions |
| [Change proposal template](docs/templates/change-proposal.md) | Reviewable recommendation format |
| [Source notes](docs/references/sources.md) | Primary sources and verification limits |
| [Original proposal](docs/references/original-proposal.md) | Unmodified initial user-supplied reference |
| [Scope clarification](docs/references/scope-clarification.md) | Subsequent user requirements and ARTEMIS proposal notes |

## Current boundaries

- One user/session initially; bounded inference concurrency and no permanently loaded second operator model.
- Operator access is restricted to brokered platform metadata and approved diagnostics. It proposes changes; it cannot edit policy, configuration, tools, or repositories.
- ARTEMIS compatibility means the tested client contract at a pinned source revision. Endpoint shape alone does not establish compatibility or offline operation.
- Local-only requests must not silently fall back to cloud. Apple cloud use is supported conditionally, with visible policy and no automatic external patch executor.
- Model discovery, automatic upgrades, general shell execution, training, and patch application are deferred.
- Embedded SQLite is recommended for durable state. The zero-database alternative remains a discussion choice; neither is implemented.

The observed development host is an M4 MacBook Air with 16 GB memory; the requested device range includes other eligible Apple Silicon Macs. Hardware eligibility does not establish that a 9B model or Android emulator will fit.

Next: resolve the remaining strategy questions and revise the docs. Implementation requires a separate request. This is a local Git repository; hosting and licensing are undecided.
