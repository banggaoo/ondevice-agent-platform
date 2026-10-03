# Decision register

**Confirmed scope** records direct user requirements. **Proposed** records recommendations for discussion. **Open** records unresolved choices. None authorizes implementation during the documentation phase.

| ID | Status | Decision or recommendation | Rationale / condition |
| --- | --- | --- | --- |
| D01 | Confirmed scope | Platform Operator Agent is first consumer | User clarification on 2026-10-03; replace provisional coding-assistant workflow |
| D02 | Confirmed scope | Google ARTEMIS is second consumer | Integration is the second proving workload |
| D03 | Confirmed scope | Support varying Apple Foundation Models-capable Macs, including M2 | Capability checks and memory tiers; no single fixed Mac requirement |
| D04 | Confirmed scope | Use Apple Foundation Models cloud capability if supported | Conditional PCC provider; actual app eligibility and disclosure policy must pass |
| D05 | Confirmed scope | Documentation and strategy discussion before implementation | User's original request remains in force |
| D06 | Proposed | Operator starts with Apple on-device inference | Minimizes custom-model deployment; usefulness and API limits must be measured |
| D07 | Proposed | Swift deterministic supervisor and native Apple-provider adapter | Native resource/provider APIs; LangChain/LangGraph optional if they add concrete value |
| D08 | Proposed | One bounded inference slot initially; Operator is on demand | No permanently resident second model; Apple owns its system-model residency |
| D09 | Open | Add MLX or llama.cpp only for a demonstrated missing capability | Choose one owned-worker backend after model/modality/resource evaluation |
| D10 | Proposed | Capability-aware routing with stable local model aliases | Preserve modality, tool/schema, context, and cloud policy; no substring/length routing |
| D11 | Proposed | Explicit durable job/proposal state machine | Checkpoint framework optional; security decisions remain outside model state |
| D12 | Proposed | SQLite state, bounded JSONL metrics, Markdown exports | Embedded transactions; zero-database alternative remains discussable |
| D13 | Proposed | Same-origin HTTP/SSE console, separate authenticated consumer credentials | Minimal UI transport; OpenAI-compatible gateway is a separate contract |
| D14 | Proposed | Manual previewed proposal export; no automatic executor | Inference cloud permission does not authorize code/configuration mutation |
| D15 | Proposed | Content capture off; metrics/retention bounded | Screenshots and diagnostics can contain private information |
| D16 | Proposed | Deterministic optimization before trained substitution | Require quality and lifecycle cost evidence |
| D17 | Proposed | Pressure/thermal policy, calibrated budgets, bounded errors | No indefinite HTTP hold or fake successful busy message |
| D18 | Open | Personal signed utility versus distributed app | PCC entitlement/distribution and worker confinement depend on packaging |
| D19 | Open | Supported OS tiers, RAM profiles, exact artifacts | M4/16 GB observed; M2-class support requested; no benchmark yet |
| D20 | Open | ARTEMIS configuration-only local operation at pinned revision | Audit all node, fallback, OCR, summarizer, and direct-provider calls |
| D21 | Open | License, Git hosting, and publication scope | Local documentation repository only |

## Alternatives and tradeoffs

- **Apple-native first:** simplest Operator candidate and direct Foundation Models integration; cannot assume every ARTEMIS request maps to its API or modality limits.
- **Add one owned worker:** MLX or llama.cpp can fill a measured capability gap, with artifact verification, packaging, confinement, and resource costs.
- **Python-first orchestration:** useful if later harness complexity warrants it; native provider/resource bridging still required. Avoid using LangGraph as the security boundary.
- **Thin existing-engine wrapper:** preferred pivot if the full platform offers little additional governance or workflow value.

## Storage choice to discuss

SQLite is an embedded local database, not an external server. It can transactionally bind decisions and transitions. If zero database is a firm requirement, specify a single-writer, versioned-record design with atomic replacement, durable flushes, journal/recovery, duplicate-command protection, and quota cleanup; evaluate it against the same crash cases. Do not equate a few JSON files with a durable approval protocol.

## Updating decisions

Record the date, direct user instruction, selected option, rationale, affected documents, and remaining conditions. Update dependent docs together. User permission to use a capability, such as Apple cloud inference, does not establish provider availability or grant an unrelated execution capability.
