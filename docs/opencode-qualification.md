# OpenCode consumer qualification

Status: request surface, a bounded native text turn, and a real
tool-call agent loop verified on the Swift implementation (2026-10-05);
bounded text and tool turns verified on the installed Python platform
(2026-10-07, final section). Multiturn coding quality and broader
client qualification remain open gates. OpenCode is an external
model consumer alongside ARTEMIS, not an automation backend invoked by
this platform.

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
   them. **Done 2026-10-05** - adapter/parser and MLX mapping tests cover
   declaration, emission, correlation, and refusal (undeclared names,
   duplicate calls, strict schemas, Apple provider tool surface). Live
   consumer evidence: `opencode run -m ondevice/qwen-vl` on the native
   daemon produced a real assistant `tool_call` (glob), which OpenCode
   executed itself, returned as a `tool` message, and the model answered
   with a final natural-language response (exit 0). A second run emitted
   a `read` tool call that dispatched immediately under `defer_load`
   because the resident container reports `requiresLoad: false`; the call
   was refused only by OpenCode's own external-directory permission.
   Tool-call quality on the 2B route is a model-capability limit (it
   sometimes selects `glob` where `read` is correct), not a serving
   defect.
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
   compatibility. **Extended 2026-10-05 (same day, later session)** -
   `qwen-vl` completed a real multi-call tool turn (see gate 3), the
   client surfaced truthful `invalid_request` (a `max_tokens` 4096
   request against the 1024-cap VL profile - client config corrected to
   1024) and `resource_denied` errors, and `activeInference: 1` was
   observed serving a `qwen3.8-9b` turn from the user's interactive
   OpenCode session. Coding-task quality and long-session stability are
   still unmeasured; per-profile `limit.output` must match the declared
   registry caps (the platform refuses over-cap requests rather than
   truncating them).

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

## Integration guide (reconnecting any OpenCode install)

OpenCode is never patched or vendored; the platform speaks its stock
OpenAI-compatible surface. To integrate a fresh OpenCode install, only
the client configuration is needed - the daemon keeps its own state.

1. Run the platform (it is a long-lived process; nothing auto-starts it):

   ```bash
   ondevice-agent-platform serve --port 8080
   ```

   (Installed console script; from a checkout, `bin/ondevice-agent-platform
   serve --port 8080` works the same.) Verify readiness: `GET /v1/models`
   lists `qwen3.8-9b-vllm`, `qwen3.8-9b`, and `qwen-vl`, and
   `GET /api/status` reports `admission: admit` (a
   `deny_and_cancel`/`defer_load` verdict is the host's real
   resource state, not a config problem - see the resource notes below).

2. Merge the following block into your existing
   `~/.config/opencode/opencode.json` (do not overwrite the file - keep
   your other providers and settings):

   ```json
   {
     "provider": {
       "ondevice": {
         "npm": "@ai-sdk/openai-compatible",
         "name": "OnDevice Agent Platform",
         "options": {
           "baseURL": "http://127.0.0.1:8080/v1",
           "apiKey": "local"
         },
         "models": {
           "qwen3.8-9b-vllm": {
             "name": "Qwen3.8 9B (MLX, prefix-cached)",
             "limit": {
               "context": 32768,
               "output": 4096
             }
           }
         }
       }
     },
     "model": "ondevice/qwen3.8-9b-vllm",
     "small_model": "ondevice/qwen3.8-9b-vllm"
   }
   ```

   `limit.output` must not exceed the registry's `maxOutputTokens` for
   the alias (4096 here) - the platform refuses over-cap requests as
   `invalid_request` rather than truncating. `context` 32768 is a
   client-side example bound, not a calibrated capacity figure. The
   `small_model` utility slot reuses the same primary alias; no separate
   utility model exists in this lineup. Under D50 the daemon ignores
   `Authorization`; the literal `"local"` is a non-secret placeholder
   that satisfies the SDK - do not store real credentials or token
   files for this endpoint.

3. Use it: `opencode` (TUI), `opencode run "..."`, or
   `opencode run -m ondevice/qwen3.8-9b-vllm "..."`.

Notes and limits:

- `qwen3.8-9b-vllm` is the agent/coding route (structured tool calls and
  prefix cache); `qwen3.8-9b` is the direct mlx route sharing the same
  artifact; `qwen-vl` serves image turns. An optional Apple Foundation
  Models route can serve plain text only (it refuses `tools` and cannot
  drive OpenCode's tool agent loop) and is not installed by default in a
  source-independent install - the `oap-apple-bridge` helper must be
  built and on PATH.
- `resource_denied` means the host is under real memory pressure or
  serious thermal (check `/api/status`); `deadline_exceeded` after ~60 s
  means a queued request never reached an `admit` window under
  `defer_load`. Both are the governor telling the truth, not client or
  serving defects - free memory or wait for the OS to emit a `normal`
  pressure event.
- The ~5 GB `qwen3.8-9b` weights contend with other apps on a 16 GB
  host; the daemon sheds caches on pressure escalation (verified live:
  RSS returned to ~0.1 GB) so pressure can recover, then reloads on the
  next admitted request.
- OpenCode owns tool execution and permissions; an `external_directory`
  rejection on absolute paths outside the workspace is client-side and
  expected in non-interactive runs.

## Live verification on the installed Python platform (2026-10-07)

Stock OpenCode `1.18.34` was exercised against the updated installed
daemon using a sanitized copy of the ondevice provider selection
(`ondevice/qwen3.8-9b-vllm`), a private HOME/config/data/cache/workspace,
the literal non-secret key `"local"`, and a mandatory `sandbox-exec`
loopback profile (all non-loopback networking denied). Mutating and
network tools were denied; the only permitted read was the exact
synthetic fixture path. Both modes passed:

- **text** - a bounded client turn against the local endpoint completed
  successfully.
- **tools** - a real `read` tool execution against the fixture ran inside
  OpenCode's own agent loop and completed, including a final stop.

This proves bounded turns through the stock client's real wire surface,
not long-session stability, arbitrary coding-edit success, or
compatibility with OpenCode's external/cloud providers (none were
enabled). The user's own OpenCode configuration and processes were not
modified or killed.
