# Primary-source notes

**Checked:** 2026-10-03; scoped refresh 2026-10-04. These sources inform the design; they do not establish that this project has implemented or benchmarked any feature. Model cards describe publisher claims, which require independent task evaluation. Pin immutable versions before implementation because linked documentation and artifact inventories can change.

This v0.4 documentation revision carries forward the 2026-10-03 source audit and pre-existing local planning drafts; it does not claim a fresh external verification. Reconfirm version-sensitive Apple and ACP behavior before implementation.

Follow-up (v0.5, 2026-10-03): the user's recorded [discussion answers](../open-questions.md) are decisions, not new evidence. The selected `~/.ondevice-agent-platform/` root and the no-ACP answer supersede the earlier root/adapter proposals documented in [runtime layout](../runtime-layout.md), [decisions](../decisions.md), [safety and approvals](../safety-and-approvals.md), and [ACP integration](../acp-integration.md). No new online, Private Cloud Compute, or iOS verification was performed; the audit date above is unchanged.

Follow-up (v0.6, 2026-10-03): the user's latest recorded [answers](../open-questions.md) accept the SQLite engine, the macOS 27+ baseline, the ARTEMIS consumer/provider direction, and GitHub-downloadable delivery; these are decisions, not new evidence. The user's statement about Apple's PCC privacy design is a recorded user position, not a fresh independently checked security or API-eligibility finding. The primary-source audit remains dated 2026-10-03 and is carried forward; no new external facts were verified.

## Fresh checks (2026-10-03, v0.7)

The PCC eligibility, PCC security-design, Foundation Models profiling, and MIT pages were fetched and read on 2026-10-03; raw captures are stored outside Git. Developer ID and notarization references were checked through primary Apple search-result excerpts, not full-page captures. This is a scoped check of the listed sources only; the older source catalogue below is carried forward without reverification. No API integration, account entitlement verification, runtime test, or benchmark was performed.

| Source | Supported fact |
| --- | --- |
| [Apple PCC eligibility](https://developer.apple.com/private-cloud-compute/) | Access requires enrollment in the App Store Small Business Program, "fewer than 2 million first-time app downloads from any of their apps on the App Store," and "the Private Cloud Compute entitlement assigned to their account." The page documents PCC "in their apps distributed on the App Store, and test PCC features via TestFlight or ad hoc distribution." A public GitHub-executable route is not documented; no categorical CLI impossibility is claimed |
| [Apple PCC security design](https://security.apple.com/blog/private-cloud-compute/) | PCC is documented as stateless request processing with no retained user data after the response, controls against privileged runtime access, and verifiable transparency (published 2024-06-10); a design guarantee, not this project's measured proof |
| [Apple WWDC26 Foundation Models profiling](https://developer.apple.com/videos/play/wwdc2026/243/) | Foundation Models Instruments profiles runtime latency, token, and control-flow metrics; traces can capture prompt and response content and may be sensitive |
| [Canonical MIT license](https://opensource.org/license/mit) | Broad permissions conditioned on copyright/license notice preservation, with AS IS warranty disclaimer and liability limitation; a recommended candidate license, not a selected one |
| [Apple Developer ID](https://developer.apple.com/developer-id/) and [notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) | Developer ID signing and notarization are a proposed direct-download release approach; notarization is not App Review and does not grant protected PCC API access |

## Fresh checks (2026-10-03, v0.8)

The two Qwen publisher cards and Apple WWDC25 tools session were fetched and read on 2026-10-03; raw captures are outside Git. The Tool.call reference was checked through primary Apple search-result excerpts, not a full-page capture. Publisher model-card statements are recorded as publisher claims, not verified results; no benchmark was recomputed or republished, and no matched Apple-versus-Qwen quality, latency, or energy comparison exists in the sources checked. No model, API integration, or device measurement was performed.

| Source | Supported fact |
| --- | --- |
| [Empero Qwen3.8-9B-Distill card](https://huggingface.co/empero-ai/Qwen3.8-9B-Distill) | Publisher states Apache-2.0 license, Qwen3.5-9B base, distillation toward a Qwen3.8 teacher, math/code/reasoning intent, and a text-only fine-tune (vision unevaluated); published benchmark compares the distill to its Qwen3.5 base, not Apple models - a publisher claim |
| [Empero Qwen3.8-9B-Distill-GGUF card](https://huggingface.co/empero-ai/Qwen3.8-9B-Distill-GGUF) | Q4_K_M artifact listed at 5.78 decimal GB before runtime overhead; requires a recent llama.cpp with Qwen3.5/Gated DeltaNet support; no MLX compatibility demonstrated - publisher claims requiring platform verification |
| [Apple WWDC25 tools session](https://developer.apple.com/videos/play/wwdc2025/301/) and [`Tool.call(arguments:)`](https://developer.apple.com/documentation/foundationmodels/tool/call(arguments:)) | The model calls a declared `Tool.call` into application code under existing OS/app permissions (Contacts example retains its permission prompt); tools may run concurrently; the model does not independently execute system automation or gain privileges |

The v0.8 scope correction itself - deterministic core independence, per-agent versioned harnesses, and complementary purpose-selected backends - records the user's direct requirements, not a research finding.

## Fresh checks (2026-10-04, v0.9)

The five ACP v1 lifecycle pages and five ACP v2 pages were fetched and read on 2026-10-04; raw captures are outside Git. Navigation marks v1 Latest and v2 Draft; v2 details are recorded only to keep draft behavior out of the default plan, not as a claim of support. The Core ML reference was checked through primary Apple search-result excerpts, not a full-page capture. No ACP conformance test, client implementation, or ML runtime was executed.

| Source | Supported fact |
| --- | --- |
| [ACP v1 transports](https://agentclientprotocol.com/protocol/v1/transports) | UTF-8 newline-delimited JSON-RPC over stdio; stdout carries protocol messages only and diagnostics belong on stderr; Streamable HTTP remains draft and custom transports must preserve ACP lifecycle semantics |
| [ACP v1 initialization](https://agentclientprotocol.com/protocol/v1/initialization) | `initialize` negotiates protocol version and capabilities; optional capabilities are advertised only when implemented |
| [ACP v1 session setup](https://agentclientprotocol.com/protocol/v1/session-setup) | `session/new` establishes a session with client-supplied working directory and MCP definitions; stdio MCP support is required and HTTP/SSE optional. Proposed platform policy reviews and allowlists definitions rather than launching them blindly. |
| [ACP v1 prompt turn](https://agentclientprotocol.com/protocol/v1/prompt-turn) | `session/prompt` runs a turn with streamed `session/update` notifications and completes with a `stopReason`; cancellation returns `stopReason: cancelled` after final updates |
| [ACP v1 tool calls](https://agentclientprotocol.com/protocol/v1/tool-calls) | Agents report tool calls and request client permissions; clients may apply user settings automatically. Independently enforced platform grants are this project's authority policy, not a property established by the protocol alone. |
| [ACP v2 prompt lifecycle](https://agentclientprotocol.com/protocol/v2/prompt-lifecycle) | Marked Draft upstream; v2 prompt handling accepts insertion/message IDs and reports idle updates - draft semantics not mixed into the v1 plan |
| [`MLModel.prediction(from:options:)`](https://developer.apple.com/documentation/coreml/mlmodel/prediction(from:options:)-81mr6) | Typed `MLFeatureProvider` input and typed prediction output, distinct from chat/token generation; checked via primary search excerpts only - Core ML is one candidate runtime, not the definition of ML support |

The v0.9 baseline-facility scope itself - default ACP agent serving, OpenAI-compatible LLM serving, open-source/open-weight LLM and typed ML categories - records the user's direct instruction, not a research finding.

| Source | Supported fact / design implication |
| --- | --- |
| [Apple Intelligence device requirements](https://support.apple.com/en-us/121115) | Eligible Mac hardware includes M1 and later; OS, language/region, and readiness still matter |
| [Apple SystemLanguageModel](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel) | On-device language model API is macOS 26+; availability must be checked |
| [Apple image Attachment](https://developer.apple.com/documentation/foundationmodels/attachment) | New image-prompt attachment surface is macOS 27+ |
| [Apple multimodal prompting](https://developer.apple.com/documentation/foundationmodels/analyzing-images-with-multimodal-prompting) | Current native provider can analyze image/text prompts; Android perception quality and protocol translation remain untested |
| [Apple PCC model](https://developer.apple.com/documentation/foundationmodels/privatecloudcomputelanguagemodel) | Cloud language model API is macOS 27+ with runtime availability and quota conditions |
| [Apple PCC integration](https://developer.apple.com/documentation/foundationmodels/adding-server-side-intelligence-with-private-cloud-compute) | Explicit provider selection, larger context, network and quota handling; not an unrestricted automatic fallback |
| [Apple PCC eligibility](https://developer.apple.com/private-cloud-compute/) | Managed entitlement and Small Business/download/distribution requirements; generic CLI access is not established |
| [OpenAI Chat Completions](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create) | Conversation, content/tool fields, response and stream contract inform the proposed compatibility subset |
| [OpenAI streaming](https://developers.openai.com/api/docs/guides/streaming-responses) | Chat Completions use SSE chunks; UI events and completion streams are separate contracts |
| [OpenAI vision](https://developers.openai.com/api/docs/guides/images-vision) | Image content semantics require a capable route; OCR is not assumed equivalent |
| [OpenAI errors](https://developers.openai.com/api/docs/guides/error-codes) | Errors must be communicated as errors rather than fake successful assistant messages |
| [Apple ProcessInfo](https://developer.apple.com/documentation/foundation/processinfo) | Public thermal-state and Low Power Mode signals are available; exact supported OS versions need checking for the eventual target |
| [Apple thermal states](https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.enum) | Policy can use nominal/fair/serious/critical states; this project proposes its own action mapping |
| [Apple memory-pressure source](https://developer.apple.com/documentation/dispatch/dispatchsourcememorypressure) | Supported pressure events are a useful governor input |
| [Apple applicationSupportDirectory](https://developer.apple.com/documentation/foundation/url/applicationsupportdirectory) | Application storage location depends on context; directory placement is not process confinement |
| [Apple App Sandbox file access](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox) | Actual sandbox and user-selected file permissions require explicit design |
| [Apple XPC](https://developer.apple.com/documentation/XPC) | A native process-boundary option; choosing XPC alone does not establish the full threat model |
| [Apple sandbox entitlements](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html) | Child-process inheritance and helper privileges require care; archive source, recheck for target packaging |
| [Apple ServiceManagement helpers](https://developer.apple.com/documentation/servicemanagement/updating-helper-executables-from-earlier-versions-of-macos) | Modern login/background-item packaging and user authorization should be considered later |
| [MLX LM](https://github.com/ml-explore/mlx-lm) | Existing local generation/conversion facilities can be reused; artifact and architecture support must be tested |
| [MLX memory limit](https://ml-explore.github.io/mlx/build/html/python/_autosummary/mlx.core.set_memory_limit.html) | Engine allocation limit is a guideline, not an absolute process-memory guarantee |
| [MLX clear_cache](https://ml-explore.github.io/mlx/build/html/python/_autosummary/mlx.core.clear_cache.html) | Clearing allocation cache is distinct from unloading live model weights |
| [Official Qwen3.8 repository](https://github.com/QwenLM/Qwen3.8) | Qwen3.8 exists; the proposed local 9B distillation requires its own publisher/artifact identification |
| [Empero GGUF model card](https://huggingface.co/empero-ai/Qwen3.8-9B-Distill-GGUF) | Publisher describes third-party distillation into Qwen3.5-9B and lists Q4_K_M as 5.78 GB; not an MLX compatibility or runtime-footprint measurement |
| [Core ML performance analysis](https://developer.apple.com/documentation/coreml/analyzing-a-core-ml-model-s-performance-in-xcode) | Measure the particular converted model on target hardware rather than assuming a device or energy advantage |
| [LangGraph interrupts](https://docs.langchain.com/oss/python/langgraph/interrupts) | Durable interruption/resumption requires persistence and explicit resume; original sample does not include this |
| [SQLite atomic commit](https://www.sqlite.org/atomiccommit.html) | Embedded transactional storage is appropriate to evaluate for durable local decisions |
| [OWASP CSRF guidance](https://cheatsheetseries.owasp.org/cheatsheets/Cross-Site_Request_Forgery_Prevention_Cheat_Sheet.html) | Browser requests need authentication and origin/CSRF controls even for a local service |
| [OWASP WebSocket guidance](https://cheatsheetseries.owasp.org/cheatsheets/WebSocket_Security_Cheat_Sheet.html) | If WebSockets are added later, validate origins, authorize messages, and enforce resource limits |
| [Apple Keychain](https://developer.apple.com/documentation/security/keychain-services/) | Appropriate future storage for credentials, rather than logs or configuration |

## References indexed from the existing v0.4 planning drafts

The primary pages below were already linked inside the pre-existing local planning drafts (the [harness contract](../harness-contract.md), [ACP integration](../acp-integration.md), and [runtime layout](../runtime-layout.md)) and are indexed here for convenience. They were indexed locally on 2026-10-03; they were not re-fetched in this revision and are not new confirmed findings. See the [revision input notes](revision-v0.4-notes.md).

| Indexed page | Where used |
| --- | --- |
| [Apple Foundation Models generation and tasks](https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models) | Harness contract: deterministic routing before inference |
| [Python ast.parse](https://docs.python.org/3/library/ast.html#ast.parse) | Harness contract: static-validation limits |
| [ACP introduction](https://agentclientprotocol.com/get-started/introduction) | ACP draft: protocol scope and lifecycle |
| [ACP transports](https://agentclientprotocol.com/protocol/v1/transports) | ACP draft: stdio transport |
| [ACP initialization](https://agentclientprotocol.com/protocol/v1/initialization) | ACP draft: capability negotiation |
| [ACP session setup](https://agentclientprotocol.com/protocol/v1/session-setup) | ACP draft: session and MCP configuration |
| [ACP prompt turn](https://agentclientprotocol.com/protocol/v1/prompt-turn) | ACP draft: streamed turn updates and cancellation |
| [ACP tool calls](https://agentclientprotocol.com/protocol/v1/tool-calls) | ACP draft: tool-call reporting |
| [MCP introduction](https://modelcontextprotocol.io/docs/2026-07-28/getting-started/intro) | ACP draft: MCP relationship |

The private-mail link present in the supplied revision input is not an evidence source and is intentionally not indexed.

## Local observations and unresolved evidence

- The initially empty directory `/Users/james/Development/OndeviceAgentPlatform` was not a Git repository; it was initialized locally for this documentation work.
- `system_profiler SPHardwareDataType -detailLevel mini` reported an Apple M4 MacBook Air with 16 GB memory. No identifiers such as serial numbers were collected in the returned output.
- No model was downloaded, no dependency installed, and no performance, power, or confinement test was run. All numerical resource settings are proposed experiment inputs.
- The original proposal is preserved verbatim in [original-proposal.md](original-proposal.md). Its sample code is historical reference, not runnable project code or a security design.

## ARTEMIS reference and scope changes

Consumer order and M2/Apple cloud direction were confirmed by the user's replies; see [scope clarification](scope-clarification.md). They replace the initial provisional coding-assistant workload.

An existing separate `artemis/` checkout was present when work resumed. It is a clean checkout of the user's fork, `https://github.com/banggaoo/artemis.git`, at `351ca8422f7b5b54e80a9c1ce03a222e02415b6b`, matching the previously observed upstream Google revision. It was inspected read-only; this task did not create it, install dependencies, run automation, or alter its source. The platform Git repository ignores this nested reference checkout.

The [ARTEMIS integration audit](../artemis-integration.md) supplies pinned source-file links and separates verified settings/direct provider paths from untested runtime behavior. The audit does not establish full zero-code-change/offline compatibility. Apple Markdown API pages were fetched read-only when the web reader could not parse that format; canonical documentation links above remain the citation targets.

## Local SDK verification (2026-10-04, M1)

Read-only checks against the installed toolchain - SDK verification, not fresh
web research:

- Apple Swift 6.4 (Xcode 27.0) is the active toolchain; the macOS 27.0 SDK is
  at `Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk`.
- `FoundationModels.framework` ships a `arm64e-apple-macos` Swift interface;
  its API is marked `@available(macOS 26.0, *)`. SDK presence does not
  establish device eligibility; runtime `SystemLanguageModel` availability
  checks are still required.
- `Network.framework` Swift interfaces expose `requiredLocalEndpoint` and
  `acceptLocalOnly`, which the loopback listener uses.
- `$SDK/usr/include/os/proc.h` marks `os_proc_available_memory()` as
  `API_UNAVAILABLE(macos)`; the resource monitor therefore does not use it.
- System SQLite (`$SDK/usr/include/sqlite3.h`, `libsqlite3.tbd`) is linked via
  the package's `CSQLite` system-library target; no third-party dependency.

## Installed-package API inspection (2026-10-07)

Primary checks against the pinned libraries actually installed in the
managed provider environment (`vllm-mlx==0.5.0`, `mlx-lm==0.32.0`,
`mlx-vlm==0.7.6`) — installed-package source inspection, not a fresh
remote documentation fetch. Stable reference URLs for the same
libraries: [mlx-vlm](https://github.com/Blaizzy/mlx-vlm),
[mlx-lm](https://github.com/ml-explore/mlx-lm),
[vllm-mlx](https://github.com/waybarrios/vllm-mlx).

- `mlx_vlm.generate.dispatch.stream_generate(model, processor, prompt,
  image=None, **kwargs)`; kwargs flow into `generate_step`
  (`temperature`, `top_p`, `seed` accepted). `prompt_utils
  .apply_chat_template` preserves per-message explicit image/image_url
  markers and accepts `num_images`.
- `mlx_vlm.utils.process_image` calls `load_image` **only** for `str`
  inputs; other objects pass through unconverted. `utils.load_image`
  accepts `BytesIO` and PIL (RGB + EXIF normalization) and rejects raw
  bytes — the installed evidence behind the vision ABI fix (decode via
  `load_image` before `stream_generate`).
- `mlx_lm.stream_generate` takes a `Sampler` (`sample_utils
  .make_sampler(temp=, top_p=)`), not `temperature`/`top_p` kwargs.
- Python stdlib references used by the HTTP providers and transport:
  [`http.client`](https://docs.python.org/3/library/http.client.html)
  (fixed connections the cancel observer can `shutdown()`+`close()`) and
  [`socket.shutdown`](https://docs.python.org/3/library/socket.html#socket.socket.shutdown)
  (waking a `recv` blocked in another thread; `close()` alone does not).

## MLX runtime dependency verification (2026-10-04)

Pinned for the owned open-weight route; verified against upstream tags and
the local checkouts under `.build/checkouts/`:

- `ml-explore/mlx-swift-lm` 3.31.4 (tagged 2025-06-30) provides
  `MLXLMCommon` (`ModelContainer`, `ChatSession`, `GenerateParameters`,
  `GenerateCompletionInfo`, `GenerateStopReason`) and `MLXLLM`
  (`loadModelContainer`). Since 3.x, hub download and tokenizer loading
  are generated by caller-side macros in `MLXHuggingFace`, which require
  the HF client packages below; we inline the equivalent
  `HubClient`/`AutoTokenizer` calls instead of importing the macro module.
- `huggingface/swift-huggingface` 0.11.0 (0.12.0 existed but was <7 days
  old at pin time - skipped per freshness policy) provides `HubClient`,
  `downloadFile(to:)` (direct destination, no cache duplication),
  `listFiles`, `Git.TreeEntry` + `LFSInfo.sha256`.
- `huggingface/swift-transformers` 1.3.4 provides `TokenizerLoader` /
  `AutoTokenizer`.
- Resolved transitive pins are recorded in `Package.resolved`
  (mlx-swift 0.31.6, swift-syntax, swift-numerics, swift-argument-parser,
  swift-crypto, swift-collections, swift-jinja, yyjson, EventSource).
- Xcode 27 requires the downloadable Metal toolchain component to compile
  mlx-swift's `Cmlx` Metal targets
  (`xcodebuild -downloadComponent MetalToolchain`); absent, the build
  fails with missing `.dia` diagnostics.
