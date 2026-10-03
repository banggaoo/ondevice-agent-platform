# Hardware, Apple providers, and model tiers

**Status:** verified API facts plus proposed support policy, 2026-10-03. No device benchmark, entitlement approval, or provider integration has been performed.

## Device and OS support

The user requested varying Apple Foundation Models-capable Macs, including M2 devices. Apple lists M1-and-later Macs as eligible for Apple Intelligence. Eligibility still depends on OS, language/region, downloaded model readiness, and runtime availability; it does not establish application performance. [Apple device requirements](https://support.apple.com/en-us/121115).

| Tier | Verified API baseline | Proposed project role |
| --- | --- | --- |
| Eligible Mac, macOS 26+ | `SystemLanguageModel` on-device language model | Operator text/status/proposal baseline |
| Eligible Mac, macOS 27+ | New image `Attachment` prompting surface | First native screenshot-inference candidate for ARTEMIS; validate actual M2 behavior and quality |
| Eligible Mac, macOS 27+, eligible signed app | `PrivateCloudComputeLanguageModel` | Optional Apple-cloud route under an enabled disclosure policy |
| Any supported tier with measured spare capacity | Separately verified owned model/runtime | Optional missing-capability fallback, not a required 9B default |

Sources: [SystemLanguageModel](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel), [Attachment](https://developer.apple.com/documentation/foundationmodels/attachment), [PCC model](https://developer.apple.com/documentation/foundationmodels/privatecloudcomputelanguagemodel).

Recommend macOS 27 for the first complete two-consumer experiment to avoid maintaining two image/provider translations immediately. A macOS 26 Operator-only tier can be added if demand justifies it. This is a proposed support policy, not a request to upgrade the user's Mac.

## Native image capability

Current Apple documentation supports text-plus-image prompts and guided output, and describes switching an image-analysis session to PCC for greater reasoning/context. Therefore start with Apple's native image provider before adding a custom VLM. API availability is not evidence that Android screenshot reasoning, arbitrary JSON schemas, tool-call histories, or the OpenAI wire protocol translate correctly. [Apple multimodal prompting](https://developer.apple.com/documentation/foundationmodels/analyzing-images-with-multimodal-prompting).

Keep Vision OCR as a distinct extraction capability. OCR can assist a model but cannot replace visual understanding of icons, geometry, or state. Test the actual consumer request and target hardware rather than routing every Flash request to OCR.

## Conditional Private Cloud Compute

PCC requires macOS 27+, network/service availability, managed entitlement, and applicable developer/distribution eligibility. Apple's published eligibility includes App Store Small Business Program enrollment and fewer than two million first-time downloads from any app, with the entitlement assigned. It documents App Store use and TestFlight/ad hoc testing. General unrestricted standalone-CLI access is not established by these sources. [Apple PCC eligibility](https://developer.apple.com/private-cloud-compute/).

Apple documents a larger PCC context window, daily quota handling, and availability checks. Do not assume unlimited throughput or a fixed daily request count. Read provider capabilities and quota state at runtime; a local-only request cannot silently move to cloud. If PCC is unavailable, retain a compatible local route or return an explicit unsupported/unavailable result. [Apple PCC integration](https://developer.apple.com/documentation/foundationmodels/adding-server-side-intelligence-with-private-cloud-compute).

The user has allowed this cloud capability when supported. The product still needs a visible per-consumer/session disclosure policy for telemetry, screenshots, and other inputs. This may authorize repeated eligible requests within the chosen scope; it need not prompt on every request. PCC inference permission does not authorize an external patch executor.

Packaging and developer-account eligibility are unresolved feasibility decisions. Do not make Operator usefulness depend on cloud entitlement. Whether exposing the ARTEMIS consumer gateway fits Apple's applicable entitlement/usage terms must be checked before enabling any live ARTEMIS-to-PCC traffic, independently of local synthetic/on-device gateway tests.

## Memory and ownership

| RAM class | Proposed starting experiment |
| --- | --- |
| 8 GB eligible Mac | Apple-provider Operator first; no mandatory custom model or concurrent Android emulator |
| 16 GB | Apple native text/image tests; add a small owned worker only after headroom measurements, including ARTEMIS/emulator load |
| 24 GB and above | Larger owned artifacts may be evaluated; use the same pressure/quality gates |

These are planning tiers, not minimum-RAM guarantees. The observed host is M4/16 GB; no M2 measurements exist. Prefer a physical test device when an emulator would consume scarce host headroom.

Apple manages system-model versions and residency. The platform can release its sessions and bound submitted work, but cannot promise to unload Apple's model weights or free a known amount of unified memory. Capture the exposed model/OS identity and acknowledge opaque provider state.

An optional owned artifact needs publisher, revision, digest, license, tokenizer/template, quantization, and runtime verification. Qwen3.8-9B-Distill GGUF remains a candidate rather than a required Operator or VLM; disk size is not peak memory or image capability. Promotion requires the same measured workload and hardware evidence as any other provider.
