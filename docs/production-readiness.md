# Production readiness: tested envelope and limits

**Status:** verification record, 2026-10-07. This document records what was
actually tested, against which artifact, and what remains unqualified. It is
not a "fully production ready" claim; read the limits before relying on any
surface.

## Tested artifact and deployment

- Platform: the Python implementation under `python/` (D54), installed
  non-editable into a managed provider environment and driven through the
  `ondevice-agent-platform` console script.
- Host: Apple M4 MacBook Air, 16 GB, macOS Apple Silicon. This is the only
  host family on which serving is verified; Windows and Linux code paths are
  written but not host-qualified.
- Python requirement: `>=3.11` (probed on the actual interpreter).
- Install: `ondevice-agent-platform install [--source /path/to/checkout/python]`
  creates or reuses `<data-root>/providers/oap-env` (venv), installs the
  package non-editable (`pip install --no-deps --no-build-isolation`,
  `direct_url` without `editable`), and links the console script onto
  `~/.local/bin`. `install --source` updates an existing installation; the
  daemon must be stopped first (root lifetime lock). Re-running `install`
  with no source is idempotent.
- Provider environment: the existing env is reused only after a structural
  check plus an interpreter probe (`sys.prefix`, Python version) and an
  `importlib.metadata` comparison against the exact frozen pins —
  `vllm-mlx==0.5.0`, `mlx-lm==0.32.0`, `mlx-vlm==0.7.6`. No sentinel/marker
  file authorizes skipping those checks; the env is never destructively
  wiped. MLX pins are only provisioned when the registry declares MLX/vLLM
  routes and the host has Metal; an empty-registry install is core-only.
- Source independence: verified from an empty working directory with
  `PYTHONPATH` unset — `ondevice_agent_platform.__file__` resolves inside
  managed-env `site-packages`, not the checkout.
- Model aliases verified on this host (registry, not re-derived here):
  `qwen3.8-9b-vllm` (primary text/agent/coding route, `vllm-mlx` 0.5.0),
  `qwen3.8-9b` (direct `mlx` route sharing the same artifact),
  `qwen-vl` (`mlx-vlm` 0.7.6, `Qwen3-VL-2B-Instruct-4bit` vision), and
  `gemma4-e4b` (`mlx-vlm` 0.7.6 `gemma4` arch,
  `mlx-community/gemma-4-e4b-it-4bit` @ `475b9088`, added 2026-10-08:
  text turn + real image turn verified on the installed daemon). GGUF
  catalog entries are Windows/Linux-scoped; no `llama-server` auto-install
  exists anywhere.

## Verification record

### Software gates (final-10072026, frozen)

- Python `unittest discover -s python/tests`: **218 tests, 0 failures**.
- Node console tests `node --test Tests/ConsoleTests/app.test.cjs`:
  **21 pass, 0 fail, 0 skipped**.
- Swift `swift test` (cached deps, no downloads): **234 cases executed —
  227 pass, 0 fail, 7 skipped** live-MLX cases (`OAP_LIVE_MLX` unset);
  spans `PlatformServingTests`, `PlatformMLXTests`, `PlatformCoreTests`.

These gates predate the late fix batches. The post-gate fixes were covered
by targeted suites only — **50 tests** (`TestMlxVlmPath`,
`TestCancellationLifecycle`, `TestHTTP`, `TestTransport`,
`TestJobTimerLifecycle`) then **14 tests** for the shutdown-grace ordering
follow-up. No post-fix full-suite rerun exists; the counts above are
separate facts, not one run.

### Installed control plane (final-10072026)

- Code-only scratch-daemon probe: health/status/administration, truthful
  missing-model refusals, ACP stdio `reference.status` with real `end_turn`,
  Origin/CSRF handling, clean shutdown — **passed** with no models and no
  inference provider.
- Two real installs plus idempotent no-source install, all under
  `PIP_NO_INDEX=1`; no downloads occurred.

### Real consumers (final-10072026 + followup-10072026)

- ARTEMIS (venv `langchain-openai` 1.5.2 / `langchain-core` 1.5.6 /
  `openai` 3.3.0, source revision `897c8c4`, dirty user work preserved,
  all non-loopback networking blocked):
  - `--mode direct` (`qwen3.8-9b`): real `ModelFactory` → endpoint
    resolution → `ChatOpenAI` invoke — **passed**.
  - `--mode agent` (`qwen3.8-9b-vllm`): text primary, `bind_tools`,
    synthetic tool-result history, `with_structured_output` — **passed**.
  - `--mode vision` (`qwen-vl`, synthetic PNG): real image answer
    (`content: "Red"`, usage 99/2/101, finish `stop`) while the `vllm-mlx`
    primary stayed resident in the same daemon, admission `admit`,
    memory pressure `normal` — **passed** on the fixed build. This is one
    bounded coexistence observation, not a capacity/headroom guarantee.
- OpenCode 1.18.34 (stock binary, private HOME/config/data/workspace,
  deny-all mutating/network tools, mandatory `sandbox-exec` loopback
  profile): `--mode text` and `--mode tools` both **passed**, including a
  real `read` tool execution against the synthetic fixture and a final
  stop. Bounded turns only — not long-session or arbitrary coding-edit
  qualification.
- Native probes on the warmed primary: job cancel **passed**;
  client-disconnect-only cancellation reached a durable `CANCELLED` record
  with `provider_finished=1` (job-314) — **passed**; buffered-SSE content /
  finish / usage / `[DONE]` — **passed**. API SSE is buffered completion
  framing, not incremental token streaming.

## Correctness fixes verified in this cycle

- Strict wire hygiene: non-2xx upstreams, truncated streams, malformed
  choices, duplicate tool-call IDs, and bogus finish reasons can no longer
  surface as empty successes. Partial usage is omitted (or `"usage": null`
  in the requested SSE usage frame) instead of fabricated zeros.
- Cancellation coherence: per-job private tokens, ordering — ledger
  `CANCEL_REQUESTED` is persisted before the private token signal; a
  worker returning `CANCELLED` against a still-`ACTIVE` record now ends as
  durable `CANCELLED`; disconnect detection via socket shutdown; child
  process terminate/kill/reap; provider `close()`.
- Resource/controller hygiene: per-job owned deadline/grace timers
  cancelled on every terminal outcome and at shutdown without suppressing
  `CANCELLATION_UNCONFIRMED` for noncooperative providers; bounded HTTP
  admission before worker threads; bounded head/body reads and deadlines.
- Vision ABI: `mlx-vlm` 0.7.6 `process_image` only decodes `str` inputs —
  image bytes are now decoded via `utils.load_image` to PIL before
  `stream_generate`.
- Root/config durability: atomic owned writes with crash-residue
  tolerance and directory fsync; status path performs no heavy
  inference-library imports.

## Limitations — read before relying on this

- **macOS Apple Silicon only.** Windows/Linux providers (llamacpp),
  launchers, and lock paths are unqualified on real hosts; the `.cmd`
  launcher is statically tested only.
- **No auth boundary beyond trusted loopback.** No API tokens, no
  Keychain, no sign-in (D50). Browser cookie/CSRF guards protect the
  console origin only; local processes and other local users are not
  isolated from the daemon. Client SDKs that require a key may send any
  literal non-secret placeholder such as `apiKey: "local"`.
- **ACP is a restricted v1 subset** (initialize/session/prompt/cancel,
  text + resource-link blocks). MCP process launching is refused. The
  optional runtime Operator is read-only and holds no execution or
  configuration authority.
- **Strict JSON only on the enforcing route.** `json_schema.strict` is
  forwarded on `vllm-mlx`; guidance-only routes (mlx, llamacpp, Apple)
  explicitly refuse `strict=True` and forced tool choices rather than
  pretending enforcement.
- **ARTEMIS full local-only mobile workflows are not qualified.** The
  optional `planner_validation` and `validator_pixel_safety_net` routes
  still default to Google in the inspected source; they were not invoked,
  and device/automation behavior is outside this gate.
- **Apple bridge absent in source-independent installs** unless built
  and placed on PATH (`oap-apple-bridge`); it is unselected on this host —
  not an installation failure for the primary or vision routes.
- **Development-scale operational bounds.** Admission/queue/connection/
  body/output limits and the 1000-record/16 MiB storage cap are
  fail-closed development defaults, not calibrated production capacity.
  No retention, long-run stability, battery, or device-calibration data.
- **No public release approval.** No license selection (pyproject remains
  Proprietary), no signing/notarization, no release artifact. Private
  GitHub source publication has been requested by the user; the remote
  namespace confirmation is still pending — no repository has been
  created and nothing has been pushed.
