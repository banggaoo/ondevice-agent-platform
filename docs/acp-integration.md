# Agent Client Protocol serving contract

**Status:** baseline agent-facing protocol, 2026-10-04. ACP is the default agent protocol alongside the OpenAI-compatible LLM interface; installed agents - including the Operator - remain optional. **Verified:** stable v1 pages fetched and read 2026-10-03/04; v2 is labelled Draft upstream and is not the pinned profile. **Implemented subset (M1):** stdio facade delegating to the live daemon's private `/_bridge/acp` NDJSON transport (not a standardized ACP HTTP transport), `initialize`/`session/new`/`session/prompt`/`session/cancel`, text and resource-link blocks, v1 negotiation, per-connection session binding, EOF cancellation, and refusal of nonempty MCP configurations before any process boundary. Permission/file/terminal tools and MCP launch are absent; required stdio MCP qualification stays with M3.

## Role and pinned profile

A console or other ACP client talks to `AgentService` through the default ACP adapter; each selected `AgentProfile` runs through its own versioned harness, and harness generative steps use the scoped OpenAI-compatible `ModelClient`. ACP presents an agent session; the [OpenAI-compatible gateway](gateway-contract.md) presents the tested inference contract for consumers such as ARTEMIS. They share core admission, provider policy, cancellation tracking, diagnostics, and durable records; neither protocol changes permissions, and ACP is not a universal translator for model traffic.

Proposed initial conformance target is stable ACP v1: `initialize`, `session/new`, `session/prompt`, `session/update`, and `session/cancel`. A v1 prompt turn runs to completion and returns a `stopReason`; cancellation aborts child calls, sends final updates, then returns `stopReason: cancelled` to the original prompt. `session/load`, `session/resume`, `session/close`, richer content types, and other negotiated features are advertised only after their pinned-spec cases are implemented and tested. The v2 draft changes prompt-acceptance/completion behavior; it is a separately tested future profile, never mixed into v1, and multi-version compatibility is not claimed.

## Transport and lifecycle

v1 specifies newline-delimited UTF-8 JSON-RPC over stdio, with the client launching an agent subprocess; standard output must contain only protocol messages and diagnostics belong on standard error. Its Streamable HTTP transport remains a draft, and a custom transport must preserve the negotiated lifecycle and document mapping - carrying JSON-RPC over a socket or WebSocket does not by itself make a standardized ACP transport. [Transports](https://agentclientprotocol.com/protocol/v1/transports).

**Proposed:** a default stdio facade/bridge that attaches a selected registered profile to the same core; no second core, store, or model supervisor exists behind it. A reviewed console bridge may serve the browser over the platform's own HTTP/SSE mechanics, but that bridge is a proposed implementation detail, not a standardized ACP HTTP transport and not a mandatory editor integration. Defer socket/remote ACP transports until a concrete client requires one and its transport is verified.

The adapter must negotiate `initialize`, create `session/new`, handle `session/prompt`, publish `session/update`, and honor `session/cancel` before claiming the baseline. `session/load` requires persisted context and replay behavior; it is not advertised merely because a session identifier was saved. Text and resource links are baseline v1 prompt types; URI resolution remains subject to broker policy. [Initialization](https://agentclientprotocol.com/protocol/v1/initialization), [session setup](https://agentclientprotocol.com/protocol/v1/session-setup), [prompt turn](https://agentclientprotocol.com/protocol/v1/prompt-turn).

## Permission and confinement

**Evidence:** ACP's `session/request_permission` lets an agent ask the client about a tool operation, and clients can apply user settings automatically. Tool names are informational metadata, not authorization. [Tool calls](https://agentclientprotocol.com/protocol/v1/tool-calls).

**Proposed:** retain platform authority checks independently. A client permission response cannot enlarge the caller's granted scope, and core admission/authorization still applies. A served agent may execute only its registered, validated tool handlers within its scope. Review acceptance authorizes the recorded review decision; applying a patch still requires a separately defined execution scope. Show proposed changes as clearly labelled proposals, not completed edit-tool results. Cancellation invalidates outstanding permission requests and prevents later work from using a stale response.

v1 session setup requires agents to support stdio MCP connections, with HTTP/SSE optional. Assess this requirement before claiming conformance: client-supplied executable paths, arguments, environment values, and requested working directories require explicit policy and confinement. Start with reviewed, allowlisted server definitions and reject configurations outside the supported policy; never launch arbitrary supplied commands. An empty MCP list in the target workflow reduces initial exposure but does not remove this protocol requirement. [Session setup](https://agentclientprotocol.com/protocol/v1/session-setup).

## Acceptance focus

Claim the baseline only after a pinned v1 client exercise covers negotiation, unsupported content, session isolation, streamed updates, permission denial, cancellation, provider failure, and disconnect recovery - including the required stdio MCP handling against out-of-policy requests. Do not advertise optional sessions or modalities before their cases pass, and do not claim unrestricted or full conformance.

Measure adaptation overhead and resource release against the direct console workflow. No compatibility, safety, or usefulness result has been measured; ACP support is a baseline facility claim pending implementation and pinned-profile tests, not an executed result.
