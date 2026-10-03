# Proposed resource and scheduling policy

**Status:** unimplemented, uncalibrated design. Preserve interactive responsiveness and bound contention; do not claim hardware-damage prevention or a hard unified-memory reservation.

## Signals and authority

The deterministic supervisor owns admission, cancellation, and policy. The Operator explains decisions and proposes adjustments; it cannot change limits. Use public thermal state, memory pressure, power state, measured process/provider behavior, and workload headroom. Sources: [ProcessInfo](https://developer.apple.com/documentation/foundation/processinfo), [memory-pressure notifications](https://developer.apple.com/documentation/dispatch/dispatchsourcememorypressure).

Replace the proposed 82°C/85%-used-memory rule. Raw temperature tools may be optional diagnostics; total used-memory percentage does not reliably describe pressure or reclaimable caches. Measure owned workers, platform overhead, ARTEMIS processes, and any emulator; do not double-count shared CPU/GPU allocations. Artifact size and engine counters alone are incomplete.

Missing or stale critical observations defer new inference. Provider availability and cloud quota are additional independent admission conditions. PCC can reduce local inference load only for requests whose capability and approved disclosure policy permit it; pressure does not grant cloud permission.

## Admission and escalation

| Condition | Proposed behavior |
| --- | --- |
| Nominal thermal / normal pressure / ready provider | Admit one bounded inference request |
| Fair thermal | Defer optional background work; use a tested reduced interactive budget |
| Serious thermal or warning pressure | Stop new inference; request cancellation and release request state. If the condition persists 5 seconds, unload an owned model; if reclamation fails, stop its worker within another 5 seconds |
| Critical thermal or critical pressure | Stop admission; cancel immediately, release sessions, unload owned workers; terminate an unresponsive owned worker after a 5-second grace period |
| Battery / Low Power Mode | Disable optional background computation; use reduced interactive profile by explicit user choice |
| User stop, disconnect, sleep, or logout | Cancel queued/stale work, persist state, request bounded cancellation; reconcile rather than replay on wake/restart |
| Provider unavailable or PCC quota/network failure | Compatible policy-approved fallback or explicit error; no hidden capability downgrade |

Action mapping and timings are proposed experiment inputs, not Apple rules. Recovery requires normal pressure and nominal/fair conditions stable for 30 seconds; reload backoff starts at 60 seconds. Tighten recovery if it oscillates. Safety escalation takes priority over idle retention.

For an owned worker: stop admission → cancel generation → release context/cache/weights → terminate if unresponsive. Merely pausing preserves memory. MLX's [memory limit is a guideline](https://ml-explore.github.io/mlx/build/html/python/_autosummary/mlx.core.set_memory_limit.html), and [clear_cache](https://ml-explore.github.io/mlx/build/html/python/_autosummary/mlx.core.clear_cache.html) does not unload live weights.

For Apple-managed inference: release/cancel the application's session and stop submitting work. Verify cancellation behavior and observed system recovery; do not kill Apple services or claim ownership of their weight residency. Cancellation acknowledgement and actual compute/memory cessation are separate measurements. See [hardware and models](hardware-and-models.md).

## Initial bounds to calibrate

| Setting | Proposed starting value |
| --- | --- |
| Active inference | 1 platform slot shared by Operator and ARTEMIS |
| Pending queue | At most 4; expired/excess requests fail clearly |
| Operator output / loop / task budget | At most 512 tokens per generation, 6 tool rounds, 2,048 total generated tokens, 120 seconds |
| Context | Provider-reported capacity minus measured prompt/tool/output margin; no silent truncation |
| ARTEMIS request limits | Derive from real node payloads and client deadlines; reject unsupported/oversized inputs |
| Monitoring | Initial 1–2 second sample target; critical observations stale after 5 seconds |
| Owned-model idle timeout | 5 minutes, subordinate to pressure escalation |
| Application cancellation grace | Initial 5 seconds; provider limitations must be measured and reported |

One platform slot bounds admission; it does not prove one Apple model is resident or control unrelated Apple Intelligence requests. Operator and ARTEMIS queues need explicit fair scheduling and per-consumer limits. User stop controls remain available without needing a model slot.

An 8 GB Apple-provider profile has no mandatory custom model. For a 16 GB test machine, an optional owned worker could start with a 6 GiB aggregate platform admission budget, including control/worker/cache overhead; lower it when emulator/foreground load requires more headroom. Larger-memory profiles still require calibration. Apple-managed residency cannot be treated as an enforceable per-process budget.

The listed 5.78 GB Qwen GGUF artifact may not fit comfortably inside that optional 6 GiB envelope once runtime state is added. Reduce model/context or reject admission; do not silently enlarge limits. Reserve host headroom empirically rather than assigning the same ceiling to all M2 devices.

## HTTP and consumer deadlines

A thermal/resource gate must not hold ARTEMIS requests indefinitely. Use a finite admission deadline shorter than the consumer timeout, bounded retries, and appropriate 429/503 error semantics. Never disguise overload as successful assistant text. Disconnect removes stale queued requests and requests active cancellation. The serving platform cannot cancel or undo Android actions ARTEMIS has already executed. See [gateway contract](gateway-contract.md).

## Optional background work

Training/distillation are outside the MVP. Later heavy jobs require opt-in, permitted hours, AC power, sustained idle time, nominal thermal state, normal pressure, no active consumer work, disk quota, and a duration cap. A discussion profile is 02:00–05:00 local time, 15 minutes idle, and 30 minutes maximum; disabled by default.

Do not wake or keep a laptop awake for optimization by default. Skip missed windows and reevaluate after time-zone changes/sleep/restart. Persist deferred work without retaining a model/thread. Lightweight status collection need not be restricted to nighttime; heavy optimization does.
