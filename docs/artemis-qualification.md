# ARTEMIS contract qualification

**Status:** source audit against pinned commit `351ca84` (see
artemis-integration.md Source identity), plus live endpoint verification
on this platform, 2026-10-04. ARTEMIS is an external consumer only - no
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
