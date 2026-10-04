# OpenCode consumer qualification

Status: request surface and a bounded native text turn verified,
2026-10-05. Tool execution, multiturn coding, and broader client qualification
remain open gates. OpenCode is an external model consumer alongside ARTEMIS,
not an automation backend invoked by this platform.

## Observed installation

The installed OpenCode executable reports version `1.18.34`. Its existing
user-managed configuration declares an `ondevice` provider using
`@ai-sdk/openai-compatible`, with a base URL of
`http://127.0.0.1:8080/v1` and `ondevice/qwen3.8-9b` as its selected model
(the earlier `ondevice/qwen3-4b` selection was updated when that alias was
removed 2026-10-05).
The model declarations also include the small Qwen, Qwen vision, and Apple
aliases. Credential values are not part of this record.

The installed adapter contains the OpenAI-compatible
`POST /chat/completions` path, SSE `stream: true` requests, optional
`stream_options.include_usage`, assistant tool-call parsing, and tool-result
history mapping.

A synthetic logging proxy recorded 15 POSTs on 2026-10-04: 14 model-client
requests and one separate probe body. The model requests selected
`qwen-small` with a 512-token bound. The tool-bearing request shape was:

```text
{model, messages:[system,user], stream:true,
 stream_options:{include_usage:true}, tool_choice:"auto",
 tools:[10 functions: bash, edit, glob, grep, read, skill, task,
        todowrite, webfetch, write], max_tokens}
```

`max_tokens` tracks the configured `limit.output`. The client did not send
`n`, `stop`, `parallel_tool_calls`, or `reasoning_effort`. The platform now
supports this surface: tools, `tool_choice` (auto/none/required/named),
assistant `tool_calls`, `tool` result messages, streamed SSE chunks with
optional usage, and per-profile output clamps. Unsupported fields and
malformed tool surfaces still fail explicitly.

The raw capture returned canned JSON rather than the requested SSE, so it
establishes request shape, not successful client completion or real inference.
A separate isolated capture attempt timed out without receiving requests.
Neither result is a successful end-to-end consumer run. The redacted metadata
receipt is kept outside Git; authorization headers and credential values are
excluded from that receipt.

## Required boundaries

- Preserve the user's existing OpenCode configuration and credential files.
  Do not overwrite them, print credentials, or embed them in checked-in
  examples.
- OpenCode selects a registered model alias and consumes the model API.
  No hosted-ACP-agent integration is established by the current instruction.
- OpenCode owns its coding harness, workspace operations, and tool
  execution. A returned tool call is data, never platform authority.
- Streaming requests use the same validation, admission, queue, deadline,
  cancellation, and resource policy as non-streaming requests.
- The consumer needs truthful model identity, finish reasons, usage,
  overload/resource errors, and abort behavior. Buffered or truncated
  responses must not be advertised as successful tool execution.

## Qualification gates

1. Capture the installed client's actual wire requests in an isolated
   synthetic exercise without external tools or cloud inference.
   **Done 2026-10-04** - request surface above captured through a local
   logging proxy. This is request-shape evidence only; the fixture did not
   provide the requested streaming response.
2. Verify streaming text, terminal framing, optional usage, and client abort
   against the platform boundary with deterministic providers.
   **Done 2026-10-04** - `testStreamingChatEmitsSSEFrames` asserts the
   emitted frame sequence (role delta, content, tool_calls delta, finish
   reason, usage, `[DONE]`) over real HTTP. curl against a live daemon
   verified the SSE content type and error paths; a deferred request expired
   truthfully at the queue deadline under `thermal: fair`.
3. Verify function-tool declarations, assistant call identifiers and JSON
   arguments, and matching tool-result history on a declared tool-capable
   model. Refuse unsupported choices or constraints rather than ignoring
   them. **Software contract covered, live model/consumer gate open** -
   adapter/parser and MLX mapping tests cover
   declaration, emission, correlation, and refusal (undeclared names,
   duplicate calls, strict schemas, Apple provider tool surface).
4. Run bounded real local inference through the native governor once native
   admission is healthy. **Partially done 2026-10-04** - the gated
   `testLiveCachedTextCompletions` ran real generation through `submitLLM`
   on both `qwen-small` and `qwen3-4b` (42 s, real usage counts) using the
   suite's injected healthy resource snapshot. Through the live daemon the
   same path reached the queue and, with the host pinned at
   `thermal: fair` by sustained external load, deferred for the full 60 s
   queue deadline and expired as `deadline_exceeded` - the deferral working
   as designed. A daemon-side `admit` window remains to be observed.
   **Native text path verified 2026-10-05** - header-free Qwen3-4B JSON
   and SSE completions succeeded on the normal-root token-free daemon
   under its actual native governor. Snapshots reported `nominal` thermal,
   `normal` memory pressure, and `admit`, with pressure explicitly sourced
   from `available_percent_estimate`. This closes the bounded native-text
   functional check, not device-headroom or capacity calibration.
5. Record the exact client version, configuration, supported fields,
   unsupported capabilities, and evidence before advertising compatibility.
   **Partially done 2026-10-04** - `opencode run` against the live daemon
   reached the platform: its tools+stream request parsed, validated, and
   queued, then surfaced `deadline_exceeded` cleanly when the queue
   deadline expired under `thermal: fair`. The request surface is accepted;
   a full agent turn still needs an `admit` window. The client config was
   corrected to `http://127.0.0.1:8080/v1` with `output: 4096` (matching
   the declared profile cap; the platform allows up to 8192).
   **Bounded text turn proved 2026-10-05** - an isolated `opencode run`
   against the token-free daemon on 8080 (private config/home/data/
   workspace, deny-all tools, SDK placeholder key `"local"`) completed a
   single bounded text turn: it returned `contract-ready` with
   `step_finish` reason `stop` and exit 0, and the daemon recorded the
   completion as LLM job 6 under consumer `local-model`. This proves one
   bounded text turn only - tool execution and multiturn/coding-task
   qualification remain open, and this is not blanket OpenCode
   compatibility.

## Normal Runtime

The normal runtime root contains the pulled Qwen artifacts. Its
registry declares the `qwen3.8-9b` model alias as the Operator binding
(D51; `qwen3-4b` was removed 2026-10-05); the runtime Operator is
registered only by an explicit serving opt-in. As prior 2026-10-04
observations - not the current listening state - the 8081 instance answered
a model list and ACP initialize/session setup, while a native Operator
prompt expired at the queue deadline with thermal state `fair`; that is not
successful native generation.

As of 2026-10-05 a reviewed restart of the credential-era binary was
observed waiting inside macOS Keychain access at the recorded check.
That state is historical: the token-free local authority adopted the same
day (D50) removed the credential code path entirely - the platform stores
no API credentials, makes no Keychain calls, and ignores any supplied
`Authorization` value. The deployed token-free build now serves the
normal root on `127.0.0.1:8080` with no Keychain interaction.

The existing OpenCode provider still points at port 8080. The key already
configured for it was a real credential under the superseded scheme and is
preserved on disk, but the platform never reads it and no key is needed -
client SDKs that require a value may use any literal non-secret
placeholder such as `"local"`, as the isolated probe did. Its
configuration and credential file are preserved. The normal-root instance
now uses that existing port 8080 endpoint without changing the client
configuration. The isolated native text probe verifies the path without
relying on the earlier controlled-resource Operator tests.

Strict JSON output, arbitrary tool execution, OpenCode's external providers,
and full coding-task success are not established by this contract record.
