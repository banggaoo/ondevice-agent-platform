# ARTEMIS integration: source audit and feasibility target

Status: v0.3 discussion draft, verified 2026-10-03. This is documentation only. ARTEMIS was not installed, executed or edited, and no configuration was applied. Configuration-only integration remains a testable target, not a confirmed result.

**Current strategy scope (confirmed follow-up answers, 2026-10-03):** ARTEMIS is the inference consumer and ondevice-agent-platform is the provider, not an automation backend. Prioritize the declared agent/LLM serving contract, not exhaustive mobile automation QA. Android and iOS testing are later user goals; this audit does not verify iOS support. Internal provider or bounded harness/agent choices do not establish complete wire compatibility or offline operation; those claims still require the pinned source and runtime evidence. The Operator is a separate optional consumer role, provider-neutral like ARTEMIS; neither owns the serving core.

## Source identity

The audited checkout reported clean working-tree status at commit `351ca8422f7b5b54e80a9c1ce03a222e02415b6b` (2026-09-29 UTC). The in-repo copy at `artemis/` was removed 2026-10-05 - ARTEMIS is not part of this project. The canonical checkout is the standalone repository at `~/Development/artemis/artemis`, whose HEAD is 16 commits ahead of and a descendant of the pinned commit. Its origin is [banggaoo/artemis](https://github.com/banggaoo/artemis), the user's fork. The same SHA was independently returned by Google's public main-branch metadata during this review. Evidence links below pin [google/artemis at that commit](https://github.com/google/artemis/tree/351ca8422f7b5b54e80a9c1ce03a222e02415b6b); future source changes require a fresh audit.

The locked dependencies include `langchain-openai` 1.5.2 and `openai` 3.3.0. Their presence does not establish installed versions or wire behavior. [Dependency lock](https://github.com/google/artemis/blob/351ca8422f7b5b54e80a9c1ce03a222e02415b6b/uv.lock).

## Evidence matrix

| Claim or route | Verified source behavior | Integration consequence |
| --- | --- | --- |
| Base URL setting | `Settings` declares `OPENAI_BASE_URL`; OpenAI factory forwards it to `ChatOpenAI(base_url=...)`. `OPENAI_API_BASE` was not found in inspected source/configuration. [Settings](https://github.com/google/artemis/blob/351ca8422f7b5b54e80a9c1ce03a222e02415b6b/artemis/config/settings.py#L109), [factory](https://github.com/google/artemis/blob/351ca8422f7b5b54e80a9c1ce03a222e02415b6b/artemis/llm/router.py#L283) | Use the actual key; environment change alone does not change providers or models. |
| Model/provider mapping | `default` and `nodes` expand into per-agent and utility configurations; primary and fallback models are separate. [Loader](https://github.com/google/artemis/blob/351ca8422f7b5b54e80a9c1ce03a222e02415b6b/artemis/config/llm.py#L149) | Resolve every active route. Factory endpoint `api_base` is not a verified JSONC field: the loaded LLM schema/resolver does not forward it. |
| Flash/Pro | Flash is reactive; Pro has planning and checks. Explorer tier is separately configured. Flash defaults to unlimited turns. [Profile definitions](https://github.com/google/artemis/blob/351ca8422f7b5b54e80a9c1ce03a222e02415b6b/artemis/config/agent.py#L759) | Profile names do not select a capable gateway model. Set explicit bounded consumer session limits. |
| Screenshots and tools | Flash sends JPEG data URLs and binds tools; Pro also builds image messages and binds tools. [Flash](https://github.com/google/artemis/blob/351ca8422f7b5b54e80a9c1ce03a222e02415b6b/artemis/agents/flash/runner.py#L371), [Pro messages](https://github.com/google/artemis/blob/351ca8422f7b5b54e80a9c1ce03a222e02415b6b/artemis/agents/operator/prompts.py#L386) | A text-only response is insufficient. Validate image grounding, tool IDs/arguments and tool-result conversations. |
| Streaming | Wrapper attempts model streaming and can downgrade to ordinary invocation on recognized failures. [Streaming wrapper](https://github.com/google/artemis/blob/351ca8422f7b5b54e80a9c1ce03a222e02415b6b/artemis/services/llm.py#L691) | Validate real SSE chunks, tool fragments, terminal status and nonstreamed replies against the locked client. |
| Structured outputs | Planner validation and Checker use `with_structured_output`; other paths parse/validate returned JSON. [Planner](https://github.com/google/artemis/blob/351ca8422f7b5b54e80a9c1ce03a222e02415b6b/artemis/agents/planner/planner.py#L188), [Checker](https://github.com/google/artemis/blob/351ca8422f7b5b54e80a9c1ce03a222e02415b6b/artemis/agents/checker/checker.py#L410) | Capture actual schema/tool wire shape; a prose answer that resembles JSON is not proof of compatibility. |
| Visual summarizer bypass | Configured `model_name` invokes `get_google_llm`; its exception path also uses Google. Flash can disable this service, but shared Pro memory constructs it separately. [Summarizer](https://github.com/google/artemis/blob/351ca8422f7b5b54e80a9c1ce03a222e02415b6b/artemis/agents/flash/summarizer.py#L164), [shared memory](https://github.com/google/artemis/blob/351ca8422f7b5b54e80a9c1ce03a222e02415b6b/artemis/memory/__init__.py#L48) | Renaming this model to a local alias does not redirect its provider. Disabling one Flash option does not establish offline Pro. |
| Capsule summarizer bypass | `StepCapsuleLens` calls `get_google_llm` for primary/fallback. Flash attaches a chunk manager when its data engine exists. [Capsule lens](https://github.com/google/artemis/blob/351ca8422f7b5b54e80a9c1ce03a222e02415b6b/artemis/memory/chunking.py#L324), [Flash attachment](https://github.com/google/artemis/blob/351ca8422f7b5b54e80a9c1ce03a222e02415b6b/artemis/agents/flash/runner.py#L258) | Provider overrides and visual-summary disablement leave another direct Google path. No verified all-profile local-only recipe exists yet. |
| OCR | Configured OCR/Vision credentials cause screenshots to be posted to Google Vision; no key returns an empty result. [OCR implementation](https://github.com/google/artemis/blob/351ca8422f7b5b54e80a9c1ce03a222e02415b6b/artemis/utils/ocr_api.py#L51) | This bypasses the inference gateway. Credential absence removes this call but does not supply replacement OCR. |
| Native video/explorer | Gemini/key/shared-client conditions select native paths; video can upload media through the Gemini Files API. Universal video uses extracted frames and can attempt audio. [Video selection](https://github.com/google/artemis/blob/351ca8422f7b5b54e80a9c1ce03a222e02415b6b/artemis/agents/video_analyzer/video_analyzer.py#L414), [media upload](https://github.com/google/artemis/blob/351ca8422f7b5b54e80a9c1ce03a222e02415b6b/artemis/agents/video_analyzer/gemini_files.py#L119) | A local chat endpoint cannot emulate every native video path. Audit credentials and enabled tools; reject unsupported audio/video explicitly. |
| Failure handling | 429 is classified as rate limit; 500/502/503/504 as unavailable, with bounded retry policies. [Reliability](https://github.com/google/artemis/blob/351ca8422f7b5b54e80a9c1ce03a222e02415b6b/artemis/llm/reliability.py#L93) | Return protocol errors, not successful busy chat. Verify retry/fallback behavior and accumulated deadlines. |

## Verified configuration shapes, not an applied recipe

The following illustrates verified environment keys. The credential and alias are placeholders; the proposed gateway does not exist yet:

```dotenv
OPENAI_BASE_URL=http://127.0.0.1:8080/v1
OPENAI_API_KEY=REPLACE_WITH_SCOPED_LOCAL_CREDENTIAL
```

The verified unified configuration shape can select the OpenAI-compatible factory:

```json
{
  "default": {
    "provider": "openai",
    "model": "artemis-vision",
    "fallback": { "provider": "openai", "model": "artemis-vision" }
  }
}
```

This is a partial future example, not a complete offline configuration. `artemis-vision` is a proposed stable alias requiring verified image/tool capability. Existing node overrides, special lightweight judge defaults, raw Google summary calls and native media paths must still be resolved. Actual dotenv/config paths depend on source versus installed application mode. [Path selection](https://github.com/google/artemis/blob/351ca8422f7b5b54e80a9c1ce03a222e02415b6b/artemis/config/paths.py#L83).

ARTEMIS delegates transport to `ChatOpenAI`; no wire request was captured. Chat Completions is the proposed subset; verify endpoint selection and schema serialization with the locked SDK. This audit does not establish Responses, native Gemini Files/Interactions or full API compatibility. See [gateway contract](gateway-contract.md).

Apple documents a 4K on-device context window. ARTEMIS prompts, tools and history may exceed it before useful work starts. Native tool/guided-generation semantics also require explicit translation of dynamic schemas and tool-call histories. Measure actual payloads before promising native compatibility. [Apple provider comparison](https://developer.apple.com/documentation/foundationmodels/adding-server-side-intelligence-with-private-cloud-compute).

## Offline and zero-source-change gate

Use synthetic screenshots and a dedicated test device. Resolve and record every primary/fallback agent, utility and background route; remove inherited Google/OCR/cloud credentials; examine shared native clients and startup download paths. Observe outbound destinations while external inference access is denied. Exercise history compression thresholds, failed calls and enabled visual/video tools, not only the first successful turn. The platform cannot block ARTEMIS's separate outbound traffic merely by governing its own worker.

Accept zero-source-change only for a declared revision, configuration, profile, task/modality subset and successful wire/privacy tests. If supported settings cannot disable or redirect a required raw Google path while preserving useful behavior, record the gap: request an upstream provider-routing change, narrow the profile, or defer local-only integration. Do not hide it behind a proxy that silently sends data elsewhere.

The platform Operator and ARTEMIS's own Operator are distinct roles. Android actions and consumer safety policy remain ARTEMIS's responsibility. Check PCC entitlement and permitted use of the proposed generic gateway before any live ARTEMIS-to-PCC request. Apple-cloud permission applies only to the explicitly selected eligible provider; it does not approve arbitrary ARTEMIS Google/OCR traffic or grant device-action authority.
