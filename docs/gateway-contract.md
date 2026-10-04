# Proposed inference gateway contract

**Status:** documentation specification with an implemented subset. Goal: the tested OpenAI-compatible subset serving every model consumer - ARTEMIS, hosted-agent harness steps including the optional Operator's, and other clients - paired with the default ACP agent interface described in [agent serving](agent-serving.md). It does not depend on or wait for any Operator milestone; the Operator is exposed over ACP while its model calls use this same contract and admission. **Implemented subset:** `POST /v1/chat/completions` (ordered roles; text parts; bounded `image_url` data-URI parts on `vision`-capable aliases; honored sampling hints `temperature`/`top_p`/`seed`/`presence_penalty`/`frequency_penalty`; `response_format` as documented best-effort guidance; strict 400 refusal of tools/streaming/`stop`/`logit_bias`/`logprobs`/`reasoning_effort`/unknown fields), `GET /v1/models` over registered profiles only, and the platform-specific `POST /api/ml/predictions` typed-ML seam - all behind shared admission with truthful 400/404/413/429/503/504 and OpenAI-shaped errors. The ARTEMIS-consumption audit is recorded in [artemis-qualification](artemis-qualification.md).

## Endpoints and identity

Propose authenticated loopback `POST /v1/chat/completions` and, if the consumer needs it, `GET /v1/models`. Port 8080 is configurable; binding and port conflict handling are explicit. This service is an inference gateway, not MCP and not inherently a reverse proxy to an upstream HTTP server. An Apple framework adapter translates an API contract in process. Hosted agents are served through the default ACP adapter rather than a custom public run endpoint, and core administration uses its own channel; an ordinary completion never silently becomes an agent run, and model-returned tool declarations remain data - ModelService does not execute them. Typed ML predictions use their own registered schema seam and are not wrapped in chat completions unless a matching task contract exists and is tested; no `/v1/embeddings` endpoint is promised at this stage. Within the platform, hosted agents and the Operator must use the model interface rather than a direct provider-SDK shortcut; alias, capability, and core checks apply identically. External consumer traffic outside this gateway is not governed by it and remains part of the ARTEMIS route audit.

Issue distinct scoped consumer credentials. A browser console session must not confer ARTEMIS access or approval rights. Keep tokens out of Git, URLs, logs, and model context. Stable local aliases identify registered capabilities and permitted provider policies, rather than impersonating a frontier cloud model.

The capability registry records text/image inputs, context and output bounds, required structured output/tools, streaming support, availability, and local/cloud policy. Do not route by a Flash substring or message count. Check all requirements before admission; unsupported features receive an explicit error.

## Required semantics to validate

| Surface | Proposed behavior |
| --- | --- |
| Conversation | Preserve relevant ordered system/developer/user/assistant/tool messages; reject unsupported roles/translation rather than keeping only the last prompt |
| Content | Validate text and image parts; bound encoded/decoded size and pixel count; require a verified image-capable route for screenshot input |
| Image URLs | Local-only routes accept tested inline data; arbitrary remote fetching is excluded to avoid egress and SSRF |
| Tools | Preserve required tool-call IDs/arguments/results; the serving layer returns suggestions, while the consumer owns execution |
| JSON/schema | Support only tested constraints that the selected provider can preserve; never silently downgrade required structured output |
| Generation options | Document supported fields and effective limits; reject materially unsupported options rather than silently discarding them |
| Nonstreamed response | Validate completion identity, model alias, choices, role/content or tool calls, truthful finish reason, and usage where measurable |
| Streamed response | Chat-completion SSE chunks/deltas and terminal framing; handle role/tool deltas, finish reason, optional usage, and cancellation as tested by the actual client |
| Context | Reject over-budget requests with a clear error; no hidden history/image truncation or opaque provider switching |

OpenAI documents content parts/tool fields and separate streamed chunk semantics. A text-only Apple adapter must not advertise screenshot reasoning or full API parity. References: [Chat Completions reference](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create), [streaming](https://developers.openai.com/api/docs/guides/streaming-responses), [vision](https://developers.openai.com/api/docs/guides/images-vision).

## Overload and failure

The governor owns bounded queue depth and admission time. Return an OpenAI-shaped error body with an appropriate status: proposed 429 for capacity limits, 503 for temporarily unavailable providers/resource gating, 400 for unsupported/malformed request semantics, and 413 for oversized payloads. Set a bounded `Retry-After` when meaningful. Test the pinned consumer's actual retries/timeouts; a server error cannot force a consumer to behave safely. [OpenAI error guidance](https://developers.openai.com/api/docs/guides/error-codes).

Do not return HTTP 200 with `RESOURCE_BUSY_RETRY` as assistant content. That can be interpreted as a valid automation decision. `finish_reason=length` indicates a generation limit, not admission failure. Do not hold a request indefinitely while waiting for nighttime or cooling.

After stream headers are sent, an HTTP status cannot be revised. Define and test how the client detects an interrupted stream; log a failed/cancelled generation rather than inventing a successful terminal chunk. Incomplete tool JSON is not an executable call. Disconnect cancels work within a bounded grace period; stale queued requests are removed.

Bound aggregate retries and wall time. Provider-local retry is distinct from a new ARTEMIS planning/action attempt. Idempotency applies to gateway admission records; it does not establish exactly-once Android actions.

## Local-only and Apple cloud policies

Local-only requests never fall back to PCC, remote OCR, or another cloud model. Where PCC is eligible, enable one explicit local-only/eligible-Apple-cloud mode choice per consumer or session that covers repeated in-scope requests rather than prompting per generation; see the [cloud policy](safety-and-approvals.md#foundation-models-and-optional-apple-cloud-inference). The mode still records allowed input classes, limits, and the actual provider used. A screenshot can be disclosed only if that policy permits it and the provider supports the required image semantics. Do not reinterpret text-only OCR as equivalent perception without evaluation.

Quota/network/unavailability errors use a tested fallback only when it preserves capabilities and the approved policy; otherwise return a clear error. Apple cloud inference does not grant a remote agent execution authority.

## Consumer boundary

The user has confirmed that ARTEMIS is an inference consumer and ondevice-agent-platform is the provider; this contract does not invoke ARTEMIS as an automation executor. The client-facing serving interface is independent of whether permitted internals use Apple on-device inference, eligible Apple PCC, an owned local model, or bounded harness/agent orchestration. Each route must preserve the declared conversation, modality, tool/schema, stream, error, resource, and disclosure semantics; internal orchestration does not grant additional tool or execution authority. Platform acceptance covers that declared subset, not exhaustive Android/iOS consumer QA. Future iOS testing is an intended consumer-side exercise, not verified support at the pinned revision.

No endpoint, token, live request, or conformance test exists yet. The ARTEMIS source audit determines which rows become required gates.
