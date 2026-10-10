# ARTEMIS contract qualification

**Status:** source audit against pinned commit `351ca84` (see
artemis-integration.md Source identity), plus live endpoint verification
on the Swift implementation (2026-10-04, recorded below) and live
consumer verification on the installed Python platform (2026-10-07, see
the final section). ARTEMIS is an external consumer only - no
ARTEMIS code is modified, vendored, or invoked by the platform. The
temporary in-repo checkout at `artemis/` was removed 2026-10-05; the
canonical working tree is the standalone repository under
`~/Development/artemis`.

## What ARTEMIS actually sends

Audited `artemis/artemis/llm/router.py` at the pinned commit and the
agent/tool call sites:

- **Transport:** LangChain `ChatOpenAI` → `POST {base_url}/chat/completions`
  with `Authorization: Bearer <key>`, `model`, `temperature`, `max_tokens`,
  `timeout`. `provider: "openai"` (and `ollama`/`vllm`/`custom`) all use this
  path with a configurable `api_base`. Loopback serving fits directly.
- **Streaming:** not required for the core path - agents call `ainvoke`
  (non-streaming). SSE remains unnecessary for ARTEMIS.
- **Multimodal:** required. Perception tools (`committee_tool.py`,
  `explorer_tool.py`, `mobile/ocr.py`, `object_detector.py`,
  `image_processor.py`) send `image_url` parts carrying
  `data:image/jpeg;base64,...` screenshots.
- **Structured output:** `with_structured_output` is used by `planner`,
  `checker`, and `outputter`. On `ChatOpenAI` this becomes a
  `response_format` (`json_schema` / `json_object`) or tool-calling request
  depending on the LangChain method.
- **Usage:** reads `usage_metadata` (LangChain normalizes `prompt_tokens` /
  `completion_tokens`) - served by our real usage accounting.

## Platform contract after this increment

| ARTEMIS need | Platform state |
|---|---|
| OpenAI-compatible POST chat/completions; optional `Authorization` header ignored | Implemented (M1) - no platform key is required; a client SDK that demands a key can carry any non-secret placeholder |
| `temperature`, `max_tokens` | Honored end-to-end (MLX + Apple) |
| `top_p`, `seed`, `presence_penalty`, `frequency_penalty` | Honored by MLX provider; accepted fields |
| `image_url` data URIs (`data:image/{jpeg,png,webp};base64`) | Parsed, bounded (4 images / 16 MB decoded), gated on a profile's `vision` capability, mapped to VLM input |
| Remote image URLs | Refused - the platform never fetches caller URLs |
| `response_format` `json_object`/`json_schema` | Accepted as documented guidance: injected into instructions, **not** enforced decoding. Downstream JSON validation still required |
| `tools`/`tool_choice`, `stop`, `logit_bias`, `logprobs`, `reasoning_effort` | Refused 400 - no provider honors them; refused rather than silently ignored |
| SSE streaming | Refused (`stream: true` → 400); ARTEMIS core path does not use it |
| Cancellation | `cancelJob` propagates to provider task (verified live) |

## Verified live (M4 / 16 GB host)

- `mlx-community/Qwen3-VL-2B-Instruct-4bit` pulled via `model pull`
  (1.8 GB, 16 files, manifest-verified), registered as `qwen-vl` with
  `capabilities: ["vision"]`.
- `OAP_LIVE_MLX=1` vision test: real image through `submitLLM` → VLM load
  via `VLMModelFactory` → correct answer ("red") on a generated PNG, with
  real token usage. ~9 s including model load.
- Daemon endpoint: image-bearing request to a text-only alias →
  `invalid_request`; `reasoning_effort` → `invalid_request`; unknown alias →
  404. Inference defers `resource_denied` while the host is thermal `fair` -
  the gate working as designed.

## Remaining gaps for full ARTEMIS operation

1. **Structured output is guidance, not enforcement.** `json_schema` is
   injected into instructions; mlx-swift-lm has no grammar-constrained
   decoding. ARTEMIS's planner/checker validation may see occasional
   malformed JSON - acceptable for qualification, not for guaranteed
   pipelines. Real enforcement needs a constraint engine (future scope).
2. **Tool calling is refused.** ARTEMIS agents that bind LangChain tools to
   the model will get 400. The platform's tool execution is code-owned by
   design; model-facing tool schemas would need a separate contract.
3. **Context budget:** VLM contexts on the qualification model are
   modest; long ARTEMIS histories need `maxInputBytes`/context calibration
   per profile.
4. **Concurrency:** single-inference-slot admission serializes ARTEMIS's
   parallel sub-agent calls; throughput for its multi-agent graphs needs
   measurement before claiming fitness.

## Live consumer verification on the Python platform (2026-10-07)

Run against the installed non-editable daemon on `127.0.0.1:8080/v1`,
using ARTEMIS's real `ModelFactory` → endpoint resolution →
`ChatOpenAI`/`invoke` path (venv: `langchain-openai` 1.5.2,
`langchain-core` 1.5.6, `openai` 3.3.0). The working copy was source
revision `897c8c4` with dirty user modifications preserved - this
qualifies that revision's client paths, not clean upstream. All
non-loopback networking was blocked during the probes.

- **Direct text** (`qwen3.8-9b`, direct mlx route): invoke returned a
  real completion with usage - passed.
- **Agent shape** (`qwen3.8-9b-vllm`, primary): text primary call,
  `bind_tools`, synthetic tool-result history, and
  `with_structured_output` on the strict-JSON-enforcing vllm route -
  all four calls returned HTTP 200 with correct model identity, parsed
  tool calls, and usage - passed.
- **Vision** (`qwen-vl`, synthetic PNG): real image turn returned
  `content: "Red"`, usage 99/2/101, finish `stop`, while the `vllm-mlx`
  primary stayed resident in the same daemon under `admit`/normal
  pressure - passed on the fixed build (the earlier run surfaced an
  image-ABI defect, since repaired and reverified). One bounded
  coexistence observation, not capacity/headroom evidence.

Current contract deltas versus the 2026-10-04 table above: tools and
`tool_choice` are now served on the open-weight routes (the platform
forwards schemas and parses returned calls; the platform still never
executes consumer tools); `stream: true` is served as buffered SSE
completion framing (not incremental token streaming); `json_schema`
with `strict: true` is enforced only on the `vllm-mlx` route - the
guidance-only mlx/llamacpp/Apple routes refuse `strict=True` and
forced tool choices explicitly rather than silently degrading.

**Lineup note (2026-10-08):** the `qwen3.8-9b-vllm` route verified above
was removed at user request; ARTEMIS's default and fallback now bind
`qwen3.8-9b`, the same weights served by `mlx-lm` directly. Text, tool,
tool-result, and vision turns are unaffected, but no declared route on
this host enforces `strict: true` JSON - `with_structured_output`
strict requests now meet an explicit `invalid_request` refusal rather
than enforced output.

**Run record (2026-10-09):** probe rerun on the new bindings -
`direct`/`vision`/`agent` all passed. `gemma4-e4b` serves the agent
shape: auto tool loops (parsed tool calls, `tool_calls` finish),
tool-result turns, and `with_structured_output(method="json_mode")`.
Boundaries on this lineup: `tool_choice="required"` and default
(function-call-forced) `with_structured_output` meet `invalid_request`
refusals - use `json_mode` or auto tool choice. `gemma4-e4b`'s own
tool-call markup is parsed into real `tool_calls` (added this date
after live evidence showed calls leaking as raw text).

**Vision routing (2026-10-09, D60, amended same day):** `operator`,
`object_detector`, `video_analyzer`, and `explorer` primaries bind
`gemma4-e4b` (semantic/grounding) with `qwen-vl` as each node's
fallback; `vision-hybrid` is reserved as the OCR-only route - Apple
Vision answers confident extraction turns natively, `qwen-vl` remains
its delegate for the rest. User direction: "vision-hybrid is only for
ocr, others should gemma". Live verification: gemma grounding on
synthetic input returned plausible coordinates (`250, 500` vs true
`203, 687`) - real-UI grid conformance is unverified; `qwen-vl` stays
the verified-grid fallback. `gemma4-e4b` declares
`imageMaxSoftTokens: 1120` (2026-10-09): Gemma4's default image
budget is 280 soft tokens (~224px), which crushed high-res
screenshots to unreadable 224x224; 1120 is the model's designed
maximum (posemb 10240 >= 1120*9 patches). Verified live: a
2240x2240 dense-text image consumed 1109 prompt tokens and the
model read the grid contents. OCR-tier behavior verified live earlier
(`"TOTAL"` no-usage direct answers; `"Red"`/`"black"` escalations).

**OCR serving contract (2026-10-09, verified):** the platform's
`vision-hybrid` route serves position-bearing OCR to consumers.
`oap-vision-bridge` emits pixel vertices in boundingPoly order
(TL,TR,BR,BL), and direct Apple Vision answers carry the additive
`oap_ocr` response field - `{text, confidence, position}` per
observation. Escalated VLM answers carry no `oap_ocr`, so consumers
degrade honestly instead of receiving fabricated coordinates. Verified
through ARTEMIS's real `perform_ocr`/`run_ocr_core` path against a
consumer-side platform provider: a 320x80 `"TOTAL"` image returned
`[{"text":"TOTAL","coordinates":[446,475]}]` (normalized 0-1000,
~[447,475] expected), `usage: null`; a no-text image escalated to
`qwen-vl` and the tool reported "No text detected on the screen." The
ARTEMIS-side provider shim was reverted per user direction - ARTEMIS
stays unmodified and consumes the platform through its existing
config; the `oap_ocr` contract remains served for any OCR caller that
wants positions.

**Residual - not qualified:** the optional `planner_validation` and
`validator_pixel_safety_net` routes still default to Google in the
inspected source (a frozen audit finding); they were not invoked by
these probes. Full local-only ARTEMIS mobile workflows, device action,
and automation behavior are outside this qualification.
