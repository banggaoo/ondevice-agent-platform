# Decision register

**Confirmed scope** records direct user requirements. **Proposed** records recommendations for discussion. **Open** records unresolved choices. None authorizes implementation during the documentation phase.

| ID | Status | Decision or recommendation | Rationale / condition |
| --- | --- | --- | --- |
| D01 | Confirmed scope | The Operator Agent is an optional served agent reached through ACP; the shared deterministic core is independent | User direction on 2026-10-04; inside its own harness it uses the OpenAI-compatible model client like other consumers |
| D02 | Confirmed scope | Google ARTEMIS is an external inference consumer | Not a priority gate on core serving; the platform never invokes it as an automation backend |
| D03 | Confirmed scope | Support varying Apple Foundation Models-capable Macs, including M2, adapted to each user's device capability | Capability checks and memory tiers; no single prescribed RAM host |
| D04 | Confirmed scope | Use Apple Foundation Models cloud capability if supported | Conditional PCC provider; Apple's documented stateless/no-retention privacy design supports the user's acceptance, while entitlement/access and this platform's own disclosure policy remain independent conditions |
| D05 | Confirmed scope | Documentation and strategy discussion before implementation | User's original request remains in force |
| D06 | Confirmed scope | Apple Foundation Models and open-weight models serve complementary purposes; Apple remains an allowed first experiment | User clarified on 2026-10-03 that neither is a universal default; suitability and limits remain unmeasured |
| D07 | Proposed | Swift `PlatformSupervisor` and native provider adapters | Native resource/provider APIs; LangChain/LangGraph optional if they add concrete value |
| D08 | Proposed | One shared inference admission slot initially | An experiment budget, not a provider limit; no permanently resident agent model; core status/stop need no slot |
| D09 | Confirmed scope | Open-source/open-weight LLM and non-generative ML inference are baseline supported categories | Default categories, not fallback-only; exact runtime/artifact qualification stays Open (D41). Initial qualification targets one owned LLM artifact/runtime pair and a separately schema-qualified ML profile; this is not a permanent single-backend limit. |
| D10 | Proposed | Capability-aware routing with stable local model aliases | Preserve modality, tool/schema, context, and cloud policy; no substring/length routing |
| D11 | Proposed | Explicit durable job/proposal state machine | Checkpoint framework optional; security decisions remain outside model state |
| D12 | Confirmed scope | Use embedded SQLite for durable local state | User explicitly accepted SQLite on 2026-10-03; record schema, transition protocol, logging, and retention remain proposed |
| D13 | Proposed | Same-origin HTTP/SSE console, separate authenticated consumer credentials | Minimal UI transport; OpenAI-compatible gateway is a separate contract |
| D14 | Proposed | Manual previewed proposal export; no automatic executor | Inference cloud permission does not authorize code/configuration mutation |
| D15 | Proposed | Content capture off; metrics/retention bounded | Screenshots and diagnostics can contain private information |
| D16 | Confirmed scope | Deterministic optimization first; training deferred until measured workload evidence | User accepted the recommendation on 2026-10-03; quality and lifecycle-cost evidence still required before any training |
| D17 | Proposed | Pressure/thermal policy, calibrated budgets, bounded errors | No indefinite HTTP hold or fake successful busy message |
| D18 | Confirmed scope | GitHub-downloadable repository/executable; per-user local server and console | User-selected delivery direction on 2026-10-03; build/release/signing details and actual publication require separate work |
| D19 | Confirmed scope | macOS 27+ as sole initial supported OS baseline | User explicitly accepted on 2026-10-03; eligible hardware, RAM profiles, and provider limits still require checks and measurements |
| D20 | Open | ARTEMIS configuration-only local operation at pinned revision | Audit all node, fallback, OCR, summarizer, and direct-provider calls; planned tests are accepted (D36), results unestablished |
| D21 | Open | License, actual publication, and release/build details | GitHub direction chosen; standard MIT is the default recommendation (D34, Proposed); no publishing authorized |
| D22 | Proposed | Typed native read fast paths and authenticated stop controls under the deterministic harness | Status/refresh/list/stop need no inference; model-based intent classification still counts as an inference call |
| D23 | Confirmed scope | ACP is the default agent-facing protocol; no mandatory editor integration | User direction on 2026-10-04 supersedes the earlier no-adapter deferral; the protocol contract is in [ACP integration](acp-integration.md) |
| D24 | Confirmed scope | Runtime data in `~/.ondevice-agent-platform/`; session folders only when needed | User selected on 2026-10-03; does not grant general home access or prove confinement; packaging compatibility still open |
| D25 | Proposed | Static validation evidence at proposal time; generated-code execution outside MVP | Parser results are recorded evidence, not correctness, execution authority, or training labels |
| D26 | Confirmed scope | Staged optional-Operator vision: runtime, then project/codebase/data, then training, then distribution, then improvement | User direction on 2026-10-03; these are optional consumer stages, not core milestones; each later stage needs its own capability/executor/data design and a separate request |
| D27 | Confirmed scope | Engineer-wide audience with local/free/performant product goals | User answer on 2026-10-03; GitHub delivery direction now chosen; licensing, measured performance, and packaging details still open |
| D28 | Confirmed scope | Settle the core and per-agent harness contracts before prompts or training workers | User accepted the recommendation on 2026-10-03 |
| D29 | Confirmed scope | ARTEMIS is an inference consumer; the platform is its provider, not an automation backend | User explicitly resolved the direction on 2026-10-03 |
| D30 | Confirmed scope | Platform serves agent/LLM inference through a tested subset, not exhaustive Android/iOS consumer QA | User answer on 2026-10-03; iOS support is unverified at the pinned revision |
| D31 | Open | Signing/notarization and PCC feasibility for the GitHub-distributed executable and consumer gateway | Verified 2026-10-03 published rules describe App Store production use and TestFlight/ad hoc testing with an assigned entitlement; no established public GitHub-executable route, but no categorical CLI ban either; separate from the privacy question; retain a useful local-only route regardless |
| D32 | Confirmed scope | Declared model and agent interfaces are independent of internal provider/orchestration strategy | Approved local, eligible Apple cloud, or bounded harness/agent internals do not relax the contract or permissions; a model completion never hides agent execution; not all backends are promised |
| D33 | Confirmed scope | Include misuse-responsibility and warranty/liability-disclaimer direction in release documentation | User requested on 2026-10-03; the legal text and its effect are not selected, and a disclaimer does not remove platform authority or data-handling obligations |
| D34 | Proposed | Standard MIT license; versioned GitHub Release artifacts with checksums, Developer ID signing/notarization | Conventional recommendations per user direction to follow common AI project practice; not current approval or publication |
| D35 | Confirmed scope | Use public Internet research to inform starting device/provider profiles | User direction on 2026-10-03; source-informed estimates are not measured calibration; measurements still required before performance or capacity guarantees |
| D36 | Confirmed scope | Perform the pinned ARTEMIS serving/compatibility tests before advertising the declared integration | User plans to test; no result exists yet |
| D37 | Confirmed scope | The platform's base operation is deterministic code-owned, independent of any LLM or Operator | User correction on 2026-10-03; health, admin, status, cancel, registry, and storage are code paths; model requests fail truthfully when providers are unavailable |
| D38 | Confirmed scope | Each hosted agent has its own replaceable, versioned harness | User direction on 2026-10-03; no single global harness; agent loops are not core control policy |
| D39 | Confirmed scope | Separate layers/components/tiers with purpose-driven serving | User direction on 2026-10-03; the control plane governs model, ML, and agent planes; device tiers bound resources, not provider rank |
| D40 | Confirmed scope | ACP agent serving is baseline; the custom `/api/agent-runs` public front door is superseded | User direction on 2026-10-04; the earlier custom endpoint proposal is historical, not current design |
| D41 | Open | Exact open-source LLM and ML artifact/runtime qualification and paired native/owned comparison | Publisher claims are not device measurements; initial qualification is bounded, while registered adapters and purpose profiles may expand with evidence |
| D42 | Confirmed scope | OpenAI-compatible LLM serving and ACP agent serving are both default protocol facilities | User instruction on 2026-10-04; installed agents and models remain optional, the interfaces do not |
| D43 | Confirmed scope | Typed non-generative ML inference is a baseline serving capability, not training | User instruction on 2026-10-04; artifacts qualify per ModelProfile; training and promotion remain a separate consented scope |
| D44 | Proposed | Stable ACP v1 as the initial pinned conformance profile; draft v2 only when separately tested | Verified 2026-10-04: upstream navigation marks v1 Latest and v2 Draft; no multi-version claim until tested |
| D45 | Confirmed scope | Begin the bounded M1 implementation increment defined in [development](development.md) | Direct approval 2026-10-04: "approve proposal, proceed development". Covers the deterministic core, baseline ACP/OpenAI/typed-ML surfaces, and local console only; signing/notarization, release/build, license, PCC feasibility, and artifact qualification remain open (D21, D31, D41) |

## Alternatives and tradeoffs

- **Apple-native and open-weight peers:** complementary first-class backends chosen by declared purpose; neither is a universal default or a fallback-only role, and ARTEMIS requests must not be assumed to map to either API's limits.
- **One qualified owned worker:** choose at most one of MLX or llama.cpp after purpose/modality/resource evidence, with artifact verification, packaging, confinement, and resource costs.
- **Python-first orchestration:** useful if later harness complexity warrants it; native provider/resource bridging still required. Avoid using LangGraph as the security boundary.
- **Thin existing-engine wrapper:** preferred pivot if the full platform offers little additional governance or workflow value.

## Selected storage

Embedded SQLite is the user-selected engine for durable local state. Its schema, transition protocol, logging, and retention remain proposed design; a file-only alternative is no longer a current choice. Do not equate a few JSON files with a durable approval protocol.

## Revision notes (2026-10-03)

v0.4: Trying Apple Foundation Models first is a confirmed experiment direction (D06). Restricting the initial product baseline to macOS 27+ was then a user-permitted proposal, not an accepted technical decision. See the [revision input notes](references/revision-v0.4-notes.md).

v0.5 follow-up: the user's first recorded answers superseded earlier proposals - D23 and D24 became confirmed scope (no ACP adapter; `~/.ondevice-agent-platform/` root), and the staged vision, engineer-wide goals, and serving-first ARTEMIS scope were confirmed (D26-D28, D30).

v0.6 follow-up: the user's latest answers settle D12 (SQLite engine), D18 (GitHub-downloadable executable with per-user local server and console), D19 (macOS 27+ sole initial baseline), D29 (ARTEMIS is the inference consumer, the platform the provider), and D32 (declared interface independent of internals). Still open: signing/notarization, release/build, license, and PCC feasibility under the chosen delivery (D21, D31). See the recorded answers in [open questions](open-questions.md); earlier notes remain historical.

v0.7 follow-up: scoped primary-source checks on 2026-10-03 verified Apple's PCC privacy design and published entitlement rules, the canonical MIT terms, Foundation Models Instruments profiling, and Developer ID/notarization references (see [source notes](references/sources.md)). New confirmed scope: misuse-disclaimer direction (D33), research-seeded starting profiles (D35), and planned ARTEMIS tests (D36); MIT/release mechanics are proposed (D34); PCC feasibility under GitHub delivery and the final license/publication remain open (D21, D31). The recorded engineering replies in [open questions](open-questions.md) are preserved verbatim.

v0.8 scope correction: the user's latest direction supersedes the earlier Operator-first, Apple-default interpretation - the deterministic core serves models and optional agents independently (D01, D37), each hosted agent owns a versioned harness (D38), layers/components/tiers are separate with purpose-driven provider selection (D39, D06, D09), and the agent-run contract is proposed (D40). OSS artifact qualification and paired comparison remain open (D41). Earlier notes remain historical, not current architecture.

v0.9 protocol scope, 2026-10-04: per the user's instruction - "agent protocol and openai protocol is default, agent should also serving, operator agent is agent that should use agent protocol. open source llm and ml support also default" - ACP agent serving, the OpenAI-compatible LLM interface, open-source/open-weight LLM support, and typed ML inference are baseline facilities (D23, D40, D42, D43); the earlier `/api/agent-runs` proposal is superseded and ACP v1 is the proposed pinned profile (D44).

## Updating decisions

Record the date, direct user instruction, selected option, rationale, affected documents, and remaining conditions. Update dependent docs together. User permission to use a capability, such as Apple cloud inference, does not establish provider availability or grant an unrelated execution capability.
