# Proposed inference gateway contract

**Status:** documentation specification, not an implemented endpoint. Goal: the OpenAI-compatible subset needed by a pinned ARTEMIS revision, rather than blanket API emulation. ARTEMIS support follows the Operator milestone.

## Endpoints and identity

Propose authenticated loopback `POST /v1/chat/completions` and, if the consumer needs it, `GET /v1/models`. Port 8080 is configurable; binding and port conflict handling are explicit. This service is an inference gateway, not MCP and not inherently a reverse proxy to an upstream HTTP server. An Apple framework adapter translates an API contract in process.

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

Local-only requests never fall back to PCC, remote OCR, or another cloud model. Where PCC is eligible, enable an explicit consumer/session policy with allowed input classes, limits, and visible actual-provider records. A screenshot can be disclosed only if that policy permits it and the provider supports the required image semantics. Do not reinterpret text-only OCR as equivalent perception without evaluation.

Quota/network/unavailability errors use a tested fallback only when it preserves capabilities and the approved policy; otherwise return a clear error. Apple cloud inference does not grant a remote agent execution authority.

No endpoint, token, live request, or conformance test exists yet. The ARTEMIS source audit determines which rows become required gates.
