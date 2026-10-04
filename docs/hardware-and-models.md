# Hardware, Apple providers, and model tiers

**Status:** verified API facts plus accepted support policy; the 2026-10-03 audit is carried forward, and scoped v0.7 checks on 2026-10-03 verified Apple's PCC eligibility rules, the PCC security-design page, and the Foundation Models profiling guidance. v0.8 adds the scoped check of the Qwen publisher model cards and Apple's WWDC25 tools documentation (see [source notes](references/sources.md)). No device benchmark, entitlement approval, or provider integration has been performed.

## Device and OS support

The user requested varying Apple Foundation Models-capable Macs, including M2 devices, and has accepted macOS 27+ as the sole initial product baseline. Support adapts to each user's device capability rather than one prescribed RAM host; the product goals include distribution to engineers broadly through a GitHub-downloadable executable, but signing/notarization, PCC entitlement, and compatibility with the selected `~/.ondevice-agent-platform/` data root remain open. Apple lists M1-and-later Macs as eligible for Apple Intelligence. Eligibility still depends on OS, language/region, downloaded model readiness, and runtime availability; it does not establish application performance. Apple Intelligence enablement and model readiness are needed only for the Apple backend; core administrative operation and other providers do not depend on them, and a backend's availability in the registry is not platform eligibility. [Apple device requirements](https://support.apple.com/en-us/121115).

| Tier | Verified API baseline | Proposed project role |
| --- | --- | --- |
| Eligible Mac, macOS 27+ | `SystemLanguageModel` on-device language model (API available since macOS 26) | First-class low-latency/local-native candidate for bounded text, structured, and tool-suggestion workloads, subject to runtime availability checks |
| Eligible Mac, macOS 27+ | New image `Attachment` prompting surface | A native vision candidate for screenshot inference; validate actual M2 behavior and quality before advertising |
| Eligible Mac, macOS 27+, eligible signed app | `PrivateCloudComputeLanguageModel` | Optional Apple-cloud route under an enabled disclosure policy; entitlement eligibility still required |
| Any supported tier with measured spare capacity | Qualified owned open-weight model/runtime | A peer backend for purposes it demonstrably fits (for example reasoning/code), qualified by evidence - not a fallback-only role and not a mandatory 9B default |

Sources: [SystemLanguageModel](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel), [Attachment](https://developer.apple.com/documentation/foundationmodels/attachment), [PCC model](https://developer.apple.com/documentation/foundationmodels/privatecloudcomputelanguagemodel).

Generative LLM serving and typed non-generative ML inference are baseline supported categories. Core ML is one possible native ML adapter: Apple's API documents typed `MLFeatureProvider` inputs and a typed prediction result, distinct from chat/token generation; see [`MLModel.prediction(from:options:)`](https://developer.apple.com/documentation/coreml/mlmodel/prediction(from:options:)-81mr6). Core ML is not the definition of all open ML support, and specific ML artifacts require input/output contract, resource, and licensing qualification - enabling the inference facility does not require or imply training. See the [architecture](architecture.md) ML paragraph.

macOS 27+ is the accepted sole initial product baseline, avoiding a second image/provider translation at launch. `SystemLanguageModel` availability since macOS 26 remains a source fact, not product support; an earlier-OS tier is not planned. This is not a request to upgrade the user's Mac.

## Native image capability

Current Apple documentation supports text-plus-image prompts and guided output, and describes switching an image-analysis session to PCC for greater reasoning/context. Native and owned image routes are peer candidates; select the image-capable route by declared purpose, verified capabilities, and device fit rather than a native-first rule. API availability is not evidence that Android screenshot reasoning, arbitrary JSON schemas, tool-call histories, or the OpenAI wire protocol translate correctly. [Apple multimodal prompting](https://developer.apple.com/documentation/foundationmodels/analyzing-images-with-multimodal-prompting).

Apple's documented tool model is cooperative, not autonomous privilege: the model invokes a declared `Tool.call` that executes application code under the app's and OS's existing permissions, and tools may run concurrently. No model brand independently executes system automation or grants OS rights; any compatible model may request an authorized tool, and harness/tool code performs and enforces the action. [Apple tool calling](https://developer.apple.com/videos/play/wwdc2025/301/), [`Tool.call(arguments:)`](https://developer.apple.com/documentation/foundationmodels/tool/call(arguments:)).

Keep Vision OCR as a distinct extraction capability. OCR can assist a model but cannot replace visual understanding of icons, geometry, or state. Test the actual consumer request and target hardware rather than routing every Flash request to OCR.

## Conditional Private Cloud Compute

PCC requires macOS 27+, network/service availability, managed entitlement, and applicable developer/distribution eligibility. Apple's published eligibility, rechecked 2026-10-03, requires App Store Small Business Program enrollment, fewer than two million first-time downloads from any app on the App Store, and an assigned PCC entitlement. It documents App Store production use and TestFlight/ad hoc testing, not unrestricted public GitHub-executable distribution. The rule applies to the protected API regardless of whether the calling software is called a platform, server, or app; it does not prove every possible CLI arrangement is forbidden, and the local-only Apple provider does not depend on PCC. [Apple PCC eligibility](https://developer.apple.com/private-cloud-compute/).

Apple documents a larger PCC context window, daily quota handling, and availability checks. Do not assume unlimited throughput or a fixed daily request count. Read provider capabilities and quota state at runtime; a local-only request cannot silently move to cloud. If PCC is unavailable, retain a compatible local route or return an explicit unsupported/unavailable result. [Apple PCC integration](https://developer.apple.com/documentation/foundationmodels/adding-server-side-intelligence-with-private-cloud-compute).

The user accepts Apple cloud use conditionally on preserving privacy, citing Apple's PCC architecture. Apple now documents that design directly: stateless request processing, no retained user data after the response, no privileged runtime access, and verifiable transparency ([Apple PCC security design](https://security.apple.com/blog/private-cloud-compute/), published 2024-06-10, checked 2026-10-03). The user's confidence therefore has primary-source support; it is still an Apple design guarantee rather than this project's proof that no vulnerability exists, and it does not cover this platform's own local logging, broker, or disclosure discipline. Permitted payload classes, redaction, packaging/entitlement, and applicable provider terms remain to be reviewed. Existing per-consumer/session consent, revocation, and visible provider provenance still apply; cloud inference never authorizes patch application.

GitHub delivery is selected; concrete executable/bundle packaging, signing, and developer-account/PCC eligibility remain unresolved feasibility details. Do not make core serving depend on cloud entitlement or on any single provider's availability. Whether exposing the ARTEMIS consumer gateway fits Apple's applicable entitlement/usage terms must be checked before enabling any live ARTEMIS-to-PCC traffic, independently of local synthetic/on-device gateway tests.

## Memory and ownership

| RAM class | Proposed starting experiment |
| --- | --- |
| 8 GB eligible Mac | Code-owned core first; qualify only provider profiles with measured headroom, no mandatory custom model or emulator |
| 16 GB | Native and owned purpose profiles qualified within measured headroom, including consumer/emulator load |
| 24 GB and above | Larger owned artifacts may be evaluated; use the same pressure/quality gates |

These are planning tiers, not minimum-RAM guarantees. The observed host is M4/16 GB; no M2 measurements exist. Prefer a physical test device when an emulator would consume scarce host headroom.

Public provider documentation, device specifications, and reproducible published results may seed conservative starting profiles. Record source date, provider/model version, and workload assumptions; label unsourced or transferred numbers as estimates. Internet research is not device calibration and cannot establish current memory headroom, thermal behavior, latency, or quality on a user's running machine. Use native availability/pressure observations and bounded workload measurements to validate the profile before claiming performance or capacity. This does not require exhaustive benchmarking of every Mac before the first local experiment; unsupported or unmeasured combinations remain explicit.

Apple manages system-model versions and residency. The platform can release its sessions and bound submitted work, but cannot promise to unload Apple's model weights or free a known amount of unified memory. Capture the exposed model/OS identity and acknowledge opaque provider state.

An owned artifact needs publisher, revision, digest, license, tokenizer/template, quantization, and runtime verification before advertised support. The Empero Qwen3.8-9B-Distill cards (checked 2026-10-03) state an Apache-2.0 license, a Qwen3.5-9B base with distillation claims toward a Qwen3.8 teacher, and a text-only fine-tune - vision is not evaluated. The GGUF Q4_K_M file is listed as 5.780 decimal GB before runtime overhead and requires a recent llama.cpp with Qwen3.5/Gated DeltaNet support; no MLX compatibility is demonstrated, and disk size is not peak memory. The publisher's benchmarks compare the distill to its Qwen3.5 base, not to Apple models, and its advertised context is not a device budget; treat these as publisher claims requiring this platform's own quality/resource checks. [Distill card](https://huggingface.co/empero-ai/Qwen3.8-9B-Distill), [GGUF card](https://huggingface.co/empero-ai/Qwen3.8-9B-Distill-GGUF). Promotion requires the same measured workload and hardware evidence as any other provider, and no checked source supplies a matched Apple macOS 27 versus Qwen 9B quality, latency, or battery comparison - the user's stated comparison is a purpose hypothesis, not a measured result.

## Qualified MLX artifacts (2026-10-04)

The owned open-weight route is qualified on `mlx-swift-lm` 3.31.4 with two
real artifacts pulled through `model pull` on the M4/16 GB host:

| Alias | Repository | Verified size | Notes |
|---|---|---|---|
| `qwen-small` | `mlx-community/Qwen3-0.6B-4bit` | 351 MB, 11 files | Live completion through admission verified; quality unmeasured |
| `qwen3-4b` | `mlx-community/Qwen3-4B-Instruct-2507-4bit` | 2.28 GB, 13 files | Pulled + qualified route; generation not yet observed on host (thermal gate) |
| `qwen-vl` | `mlx-community/Qwen3-VL-2B-Instruct-4bit` | 1.8 GB, 16 files | Vision route; live image completion verified (correct answer, real usage) |

Disk size is not peak memory; MLX allocates KV and activation headroom
beyond the weight bytes. The VLM artifact additionally carries `capabilities: ["vision"]` in `registry.json`; image input to text-only aliases is refused at admission.

Route qualification answers "can the
platform serve this" - it is not evidence for or against the user's
Qwen-vs-Apple purpose hypothesis, which still needs the paired measured
comparison in the proposal. The 9B distill above was not pulled: at
~5.8 GB of weights plus runtime overhead it needs a capacity/thermal
measurement first on a 16 GB host.
