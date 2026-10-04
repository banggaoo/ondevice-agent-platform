# ondevice-agent-platform

A proposed local-first, resource-aware agent serving platform for Apple Silicon macOS, intended for engineers broadly. Local, free-to-use, and performant operation are product goals, not measured performance, an established license, or authorization to publish or distribute.

**Status: strategy draft v0.9 + bounded implementation, 2026-10-05.** The deterministic foundation, baseline ACP/OpenAI/typed-ML serving surfaces, local console with five views, opt-in Apple Foundation Models provider, owned open-weight MLX route, and optional read-only runtime Operator described in [docs/development.md](docs/development.md) are implemented in Swift and covered by the `swift test` suite plus a gated live model test. No cloud integration, ARTEMIS mutation, automation, or release artifact exists yet.

## Build and run

Requires macOS 27+ on Apple Silicon and the installed Xcode 27 / Swift 6.4 toolchain (including the downloadable Metal toolchain component: `xcodebuild -downloadComponent MetalToolchain`). Third-party runtime dependencies are pinned exactly in `Package.resolved`: `mlx-swift-lm` 3.31.4 (MLX Swift LLM runtime), `swift-huggingface` 0.11.0 (hub downloads), and `swift-transformers` 1.3.4 (tokenizer loading). They are confined to the `PlatformMLX` target; `PlatformCore` links only system frameworks and system SQLite.

```sh
swift build                                  # build the package
swift test                                   # run the full software-contract suite
.build/debug/ondevice-agent-platform --help  # list commands
```

Commands:

```sh
ondevice-agent-platform serve [--data-root PATH] [--port PORT] [--enable-reference-agent] [--enable-apple-model] [--enable-operator [--operator-model ALIAS]]
ondevice-agent-platform acp --agent AGENT_ID [--data-root PATH]
ondevice-agent-platform model pull --alias ALIAS | --repo ORG/NAME --revision REV [--data-root PATH]
ondevice-agent-platform model list [--data-root PATH]
ondevice-agent-platform model remove --alias ALIAS [--data-root PATH]
```

- The platform is trusted-local single-user software (D50): it issues no API access tokens and stores no credentials or Keychain items. `serve` starts on a fresh root with no bootstrap step; every loopback route runs under a fixed code-owned consumer principal whose scope stays an internal permission. An incoming `Authorization` header is ignored for SDK compatibility - it selects no principal and bypasses no guard.
- `serve` binds loopback only (default 127.0.0.1:8080) and writes a nonsecret `daemon.json` marker under the data root (default `~/.ondevice-agent-platform`).
- `model pull` is the only acquisition path: it downloads a registry-declared (or explicit repo+revision) artifact from Hugging Face into `<data-root>/models/` with staging, per-file size checks, and LFS sha256 verification recorded in a manifest. Inference never downloads; a declared-but-unpulled model serves truthful provider-unavailable.
- `acp` is a stdio facade that forwards JSON-RPC to the running daemon's private bridge; it never starts a second core.
- The console is a loopback development surface: opening the served page in a browser needs no command or token - it bootstraps a local cookie session automatically. It shows five views - Overview (real resource fields with labeled pressure provenance, the evaluated admission verdict, occupied slots, provider categories), Models (declared profiles and readiness; artifacts are governed through `model pull`/`list`/`remove`, never the page), History (jobs with scoped stop controls), Train (explicitly unavailable), and Chat (the opt-in read-only runtime Operator only - one bounded call per question, no conversation memory, no applied actions). Stopping a question cancels only that turn through the request's own cancellation token; console bindings commit only after re-validating the live session, so a logged-out or expired cookie cannot resurrect one. Automatic bootstrap trusts local users and processes: localhost alone is not identity authentication, and exact same-origin plus CSRF checks protect browser mutations rather than isolating the daemon from other local programs. `Secure` cookies are not possible on plain HTTP, so this is not hardened for distribution.

## Explicit limits of this increment

- The model registry starts empty: OpenAI and typed-ML endpoints return truthful 404/503, and administration works with zero providers.
- `serve --enable-apple-model` (or the `enableAppleModel` config key) registers the `apple-foundation-model` alias with the real provider only when `SystemLanguageModel.default.availability` reports available; otherwise the alias serves truthful provider-unavailable rather than fabricating a route.
- `registry.json` accepts `provider: "mlx"` LLM entries with a pinned `source` (`repo` + `revision`); `serve` registers them behind the shared MLX provider, and a pulled, verified artifact makes them executable. `"capabilities": ["vision"]` marks an alias image-capable; image requests to text-only aliases are refused at admission. Verified live on this host: `nvythong/Qwen3.8-9B-Distill-mlx-4Bit` (Operator binding; native completions + ACP/console turns) and `mlx-community/Qwen3-VL-2B-Instruct-4bit` (live vision completion).
- `serve --enable-reference-agent` installs the deterministic `reference.status` harness plus the bounded single-call `reference.echo` model-step harness when a declared model alias exists (currently the Apple opt-in). There is no general tool execution.
- `serve --enable-operator` (or `--operator-model ALIAS`, or the `operatorModel` config key) registers the optional read-only runtime Operator on an explicit opt-in. Its default binding is the Apple Foundation Models system route (`apple-foundation-model`, requires `--enable-apple-model`); `--operator-model` may instead name a declared, pulled MLX LLM alias (e.g. `qwen3.8-9b`). It fails startup truthfully when the alias is undeclared, on an unqualified provider, capped under 512 output tokens, or unpulled; it never downloads. The Operator answers ACP prompts by explaining the platform status snapshot through one bounded model call (max 512 output tokens, temperature 0); it owns no tools and no administrative authority, and its text is a proposal or explanation, never an applied change.
- `registry.json` accepts declared `builtin.linear` typed-ML models (features, labels, weights, optional bias); malformed entries fail startup.
- ACP is the documented v1 subset: initialize/session-new/prompt/cancel with text and resource-link blocks; MCP servers are refused before any process boundary.
- No arbitrary file serving, code execution, MCP process launch, non-loopback traffic, or public release.

The platform serves **models and hosted agents** through a deterministic shared core (`PlatformSupervisor`) that works with no agent installed and no inference provider available. **ACP agent serving and the OpenAI-compatible LLM interface are baseline facilities**, as are open-source/open-weight LLM support and typed non-generative ML inference; installed agent profiles are optional, the facility is not. **The Operator is an optional served agent**: clients reach it through ACP, its own harness calls the same OpenAI-compatible model serving through a scoped client, and it owns no global authority. **ARTEMIS is an external inference consumer**; the platform is the provider and never invokes ARTEMIS as an automation backend. Permitted internals behind the declared contract may be Apple on-device inference, eligible Apple PCC, an owned local model, or bounded harness/agent orchestration, none of which expand client-facing semantics or permissions. Platform scope is agent/LLM serving, not exhaustive consumer mobile QA. Device actions remain ARTEMIS's responsibility. The user envisions Android and iOS testing later; iOS support is unverified at the pinned revision.

The confirmed delivery direction is a GitHub-downloadable repository/executable: each user runs a local executable that starts a loopback server and web console, not a mandatory standalone GUI or App Store package. This repository remains local today; no license, release format, signing, or publication is approved. Release and responsible-use recommendations are in [distribution and responsible use](docs/distribution-and-responsible-use.md).

The confirmed longer-term Operator vision is staged: runtime management first, then project/codebase/data, then training, then distribution, then improvement. Each later stage needs its own explicit capability, executor, and data design plus a separate user request.

Trying Apple Foundation Models first is a confirmed experiment direction, not proven suitability or a product-wide default. Apple and open-source/open-weight models are complementary first-class backends selected by declared purpose, verified capabilities, and device fit; an owned open-weight route is not reserved only for cases where Apple categorically lacks a feature. The accepted initial product baseline is macOS 27+ on eligible Apple Silicon Macs, including M2-class devices, subject to runtime capability and availability checks; no earlier-OS product tier is planned initially. Apple documents PCC's stateless, non-retaining privacy design; use it only where the OS, entitlement, quota, and disclosure policy permit. The entitlement is a protected-API access rule, not a precondition for the platform's local existence, and no established public GitHub-executable route is documented - so a distinct local-only mode stays mandatory and useful without it.

## Read and discuss

| Document | Purpose |
| --- | --- |
| [Revised proposal](docs/proposal.md) | Direction, confirmed scope, and revised assumptions |
| [Architecture](docs/architecture.md) | Layered core, model/agent serving, and provider boundaries |
| [Hardware and models](docs/hardware-and-models.md) | Device eligibility, Apple providers, PCC constraints, and model tiers |
| [ARTEMIS integration](docs/artemis-integration.md) | Source-verified configuration and zero-code-change feasibility |
| [Gateway contract](docs/gateway-contract.md) | Proposed OpenAI-compatible subset and failure semantics |
| [Agent serving](docs/agent-serving.md) | Baseline ACP agent interface, versioned harnesses, and records |
| [Platform and agent harness contract](docs/harness-contract.md) | Proposed deterministic routing, typed fast paths, and validation boundary |
| [ACP integration](docs/acp-integration.md) | Proposed baseline agent-facing protocol contract |
| [Runtime layout](docs/runtime-layout.md) | Confirmed `~/.ondevice-agent-platform/` data root with proposed layout |
| [Resource policy](docs/resource-policy.md) | Admission, cancellation, reclamation, and scheduling |
| [Distribution and responsible use](docs/distribution-and-responsible-use.md) | Proposed GitHub release mechanics, license, and misuse-disclaimer direction |
| [Safety and approvals](docs/safety-and-approvals.md) | Authority, durable review, cloud disclosure, and privacy |
| [Roadmap](docs/roadmap.md) | Sequenced milestones and exit criteria |
| [Evaluation](docs/evaluation.md) | Operator and ARTEMIS baselines and gates |
| [Decision register](docs/decisions.md) | Confirmed scope versus proposed technical choices |
| [Discussion questions](docs/open-questions.md) | Remaining decisions |
| [Change proposal template](docs/templates/change-proposal.md) | Reviewable recommendation format |
| [Source notes](docs/references/sources.md) | Primary sources and verification limits |
| [Original proposal](docs/references/original-proposal.md) | Unmodified initial user-supplied reference |
| [Scope clarification](docs/references/scope-clarification.md) | Subsequent user requirements and ARTEMIS proposal notes |
| [Revision input notes](docs/references/revision-v0.4-notes.md) | Summary of the third proposal driving the v0.4 revision |

## Current boundaries

- One user/session initially; bounded inference concurrency and no permanently resident agent model.
- The core serves status, registry, administration, and stop with no agent installed and no provider available; the ACP agent-serving facility is baseline while installed agents are optional, each running its own versioned harness.
- The optional Operator's access is restricted to brokered platform metadata and approved diagnostics. It proposes changes; it cannot edit policy, configuration, tools, or repositories.
- ARTEMIS compatibility means the tested client contract at a pinned source revision. Endpoint shape alone does not establish compatibility or offline operation.
- Local-only requests must not silently fall back to cloud. Apple cloud use is supported conditionally through one explicit local-only/eligible-cloud mode choice per consumer or session rather than a prompt per generation, with visible policy, no credential or logging-scope relaxation, and no automatic external patch executor.
- Model discovery, automatic upgrades, general shell execution, training, and patch application are deferred.
- Embedded SQLite is the confirmed engine for durable local state; schema v1 (content-free job/session/profile records, WAL, interrupted-on-restart) is implemented, while logging and retention policy remain proposed.
- Runtime data uses the user-selected `~/.ondevice-agent-platform/` root; per-session directories are created only when artifacts or scratch require them. The chosen directory is not a sandbox.
- ACP is the default agent-facing protocol; no particular client or editor integration is mandatory.

The observed development host is an M4 MacBook Air with 16 GB memory; the requested device range includes other eligible Apple Silicon Macs. Hardware eligibility does not establish that a 9B model or Android emulator will fit.

Implemented so far: the code-owned core lifecycle, the OpenAI-compatible endpoint (text + bounded image input, honored sampling hints, best-effort response-format guidance) and ACP agent adapter, typed-ML inference through the `builtin.linear` registry route, the opt-in Apple Foundation Models provider, and the owned open-weight MLX route with governed pull/manifest/lazy-load, real token usage, and VLM support; installed agent profiles and the Operator remain optional. The ARTEMIS consumption audit lives in [docs/artemis-qualification.md](docs/artemis-qualification.md). Still open: remaining M3+ gates, and the engineering checks of signing/notarization/build/release/license, PCC eligibility for the chosen GitHub-delivered executable plus the cloud payload policy, RAM/provider/context calibration, and the pinned wire-compatibility/offline routes. PCC eligibility is a separate cloud gate, not a blocker for local-only feasibility. Public research can seed starting device/provider profiles; native observations and bounded measurements still validate them. This is a local Git repository; GitHub is the selected delivery target; licensing and release details remain open. No publication is performed by this revision.
