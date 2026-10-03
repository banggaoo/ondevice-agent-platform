# Primary-source notes

**Checked:** 2026-10-03. These sources inform the design; they do not establish that this project has implemented or benchmarked any feature. Model cards describe publisher claims, which require independent task evaluation. Pin immutable versions before implementation because linked documentation and artifact inventories can change.

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

## Local observations and unresolved evidence

- The initially empty directory `/Users/james/Development/OndeviceAgentPlatform` was not a Git repository; it was initialized locally for this documentation work.
- `system_profiler SPHardwareDataType -detailLevel mini` reported an Apple M4 MacBook Air with 16 GB memory. No identifiers such as serial numbers were collected in the returned output.
- No model was downloaded, no dependency installed, and no performance, power, or confinement test was run. All numerical resource settings are proposed experiment inputs.
- The original proposal is preserved verbatim in [original-proposal.md](original-proposal.md). Its sample code is historical reference, not runnable project code or a security design.

## ARTEMIS reference and scope changes

Consumer order and M2/Apple cloud direction were confirmed by the user's replies; see [scope clarification](scope-clarification.md). They replace the initial provisional coding-assistant workload.

An existing separate `artemis/` checkout was present when work resumed. It is a clean checkout of the user's fork, `https://github.com/banggaoo/artemis.git`, at `351ca8422f7b5b54e80a9c1ce03a222e02415b6b`, matching the previously observed upstream Google revision. It was inspected read-only; this task did not create it, install dependencies, run automation, or alter its source. The platform Git repository ignores this nested reference checkout.

The [ARTEMIS integration audit](../artemis-integration.md) supplies pinned source-file links and separates verified settings/direct provider paths from untested runtime behavior. The audit does not establish full zero-code-change/offline compatibility. Apple Markdown API pages were fetched read-only when the web reader could not parse that format; canonical documentation links above remain the citation targets.
