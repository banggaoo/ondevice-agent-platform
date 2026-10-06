"""Deterministic shared core, mirroring PlatformSupervisor +
Supervisor+Admission: grants, registry, admission, scheduling,
cancellation, durable records, resource gating.

Threaded port of the actor semantics: all state transitions run under one
lock; provider calls execute on worker threads; a deadline timer records
terminal intent; a noncooperative provider keeps its slot until it
actually finishes.
"""
from __future__ import annotations

import threading
import time
import uuid
from dataclasses import dataclass

from .cancellation import CancellationToken
from .compat import IS_MACOS
from .chat import (ChatRequest, validate_chat, validate_prediction,
                   validate_features)
from .errors import ErrorCode, PlatformError
from .limits import PlatformLimits
from .profiles import (AgentProfile, CategoryStatus, ConsumerScope, Grant,
                       LocalConsumers, ModelKind, ModelProfile, Principal)
from .providers.base import (ModelCacheEvicting, ProviderReadiness)
from .registry import APPLE_PROVIDER_ID, MLX_PROVIDER_ID, LLAMACPP_PROVIDER_ID
from . import resources
from .state import JobKind, JobRecord, JobState, StateStore


@dataclass
class _WorkItem:
    kind: JobKind
    request: object
    profile: ModelProfile
    provider: object


class _Waiter:
    def __init__(self) -> None:
        self.event = threading.Event()
        self.result = None
        self.error: Exception | None = None


class AgentHarnessContext:
    """Model/status seam handed to harnesses (context.model/.status)."""

    def __init__(self, supervisor: "PlatformSupervisor", principal: Principal,
                 parent_id: str, token: CancellationToken):
        self._s = supervisor
        self._p = principal
        self._parent = parent_id
        self._token = token

    def is_cancelled(self) -> bool:
        return self._token.is_cancelled

    def status_snapshot(self) -> dict:
        return self._s.status_snapshot()

    def complete(self, request: ChatRequest):
        return self._s.submit_llm(self._p, request, parent_id=self._parent,
                                  cancellation=self._token)


class PlatformSupervisor:
    def __init__(self, root, resource_source, options: dict | None = None):
        self._root = root
        self._store = StateStore(root.database_path)
        self._source = resource_source
        self._options = options or {}
        self._lock = threading.RLock()

        self._grants: dict[str, frozenset] = {}
        self._model_profiles: dict[str, ModelProfile] = {}
        self._llm_providers: dict[str, object] = {}
        self._ml_predictors: dict[str, object] = {}
        self.agent_service = None  # attached by service wiring (agents.py)

        self._pending: list[JobRecord] = []
        self._active: dict[str, JobRecord] = {}
        self._pending_work: dict[str, _WorkItem] = {}
        self._running_work: dict[str, _WorkItem] = {}
        self._running_threads: dict[str, threading.Thread] = {}
        self._waiters: dict[str, _Waiter] = {}
        self._insertion_reservations = 0
        self._job_cancellations: dict[str, tuple] = {}
        self._job_tokens: dict[str, CancellationToken] = {}
        self._job_sequence = 0
        self._next_consumer_index = 0
        self._inference_blocked = False
        self._shutting_down = False
        self._deny_recheck_pending = False
        self._latest_snapshot = resources.ResourceSnapshot.unknown()

    # -- lifecycle ---------------------------------------------------------

    def start(self) -> None:
        self._store.open()
        self._job_sequence = self._store.max_job_sequence()
        for consumer in (LocalConsumers.MODEL, LocalConsumers.AGENT,
                         LocalConsumers.ADMINISTRATION):
            self._grants[consumer.id] = consumer.scope.base_grants
        self._latest_snapshot = self._source.current_snapshot()
        self._source.start(self.resource_changed)
        if self._options.get("enable_reference_agent") and self.agent_service:
            self.agent_service.register_builtin_reference()
            alias = self._options.get("reference_echo_model_alias")
            if alias:
                self.agent_service.register_builtin_echo(model_alias=alias)

    def shutdown(self) -> None:
        with self._lock:
            self._shutting_down = True
        self._cancel_all(PlatformError(ErrorCode.CANCELLED))
        time.sleep(0.2)
        self._source.stop()
        if self.agent_service:
            self.agent_service.close_all()
        self._store.close()
        self._root.release_lock()

    # -- grants ------------------------------------------------------------

    def register_principal(self, principal: Principal) -> None:
        with self._lock:
            self._grants[principal.id] = principal.scope.base_grants

    def register_console_operator_consumer(self) -> Principal:
        principal = Principal("console-operator", ConsumerScope.AGENT)
        with self._lock:
            self._grants[principal.id] = frozenset(
                {Grant.AGENT_RUN, Grant.AGENT_STATUS_READ, Grant.LLM_INFER})
        return principal

    def revoke_grant(self, grant: Grant, principal_id: str) -> None:
        with self._lock:
            current = set(self._grants.get(principal_id, frozenset()))
            current.discard(grant)
            self._grants[principal_id] = frozenset(current)

    def has(self, grant: Grant, principal: Principal) -> bool:
        with self._lock:
            current = self._grants.get(principal.id,
                                       principal.scope.base_grants)
            return grant in current

    def require(self, grant: Grant, principal: Principal) -> None:
        if not self.has(grant, principal):
            raise PlatformError(ErrorCode.FORBIDDEN)

    # -- registry ----------------------------------------------------------

    def register_model(self, profile: ModelProfile,
                       provider=None, predictor=None) -> None:
        with self._lock:
            self._model_profiles[profile.alias] = profile
            if provider is not None:
                self._llm_providers[provider.provider_id] = provider
            if predictor is not None:
                self._ml_predictors[predictor.provider_id] = predictor

    def registered_models(self, kind: ModelKind) -> list[ModelProfile]:
        with self._lock:
            return sorted(
                (p for p in self._model_profiles.values() if p.kind == kind),
                key=lambda p: p.alias)

    def register_runtime_operator(self, model_alias: str) -> None:
        if not model_alias:
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                "operator model alias required")
        with self._lock:
            profile = self._model_profiles.get(model_alias)
            if profile is None or profile.kind != ModelKind.LLM:
                raise PlatformError(ErrorCode.NOT_FOUND,
                                    "operator model alias not registered")
            if (profile.provider_id not in
                    (MLX_PROVIDER_ID, LLAMACPP_PROVIDER_ID,
                     APPLE_PROVIDER_ID)
                    or profile.provider_id not in self._llm_providers):
                raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                                    "operator requires a local model route")
        self.agent_service.register_runtime_operator(model_alias)

    # -- status ------------------------------------------------------------

    def status_snapshot(self) -> dict:
        with self._lock:
            snap = self._latest_snapshot
            verdict = resources.evaluate(snap, time.time())
            return {
                "version": "0.2.0-py",
                "resource": {
                    "thermal": snap.thermal.value,
                    "memoryPressure": snap.memory_pressure.value,
                    "memoryPressureSource": snap.pressure_source.value,
                    "lowPowerMode": snap.low_power_mode,
                    "capturedAt": snap.captured_at,
                    "admission": verdict.value,
                },
                "appleAvailability": self._apple_status_string(),
                "categories": {
                    "appleFoundationModels": self._apple_category().value,
                    "ownedOpenWeight": self._open_weight_category().value,
                    "typedML": (CategoryStatus.QUALIFIED.value
                                if self._ml_predictors
                                else CategoryStatus.NOT_CONFIGURED.value),
                },
                "counts": {
                    "activeInference": len(self._active),
                    "pendingInference": len(self._pending),
                    "inferenceBlocked": self._inference_blocked,
                },
                "models": self._model_summaries_locked(),
                "jobs": {
                    "active": [self._job_summary(j)
                               for j in sorted(self._active.values(),
                                               key=lambda x: x.id)],
                    "pending": [self._job_summary(j) for j in self._pending],
                },
            }

    @staticmethod
    def _job_summary(job: JobRecord) -> dict:
        return {"id": job.id, "kind": job.kind.value,
                "state": job.state.value, "parentId": job.parent_id}

    def _model_summaries_locked(self) -> list[dict]:
        out = []
        for profile in sorted(self._model_profiles.values(),
                              key=lambda p: p.alias):
            if profile.kind == ModelKind.ML:
                registered = profile.provider_id in self._ml_predictors
                ready = registered
            elif profile.provider_id in self._llm_providers:
                registered = True
                provider = self._llm_providers[profile.provider_id]
                ready = (provider.artifact_ready(profile)
                         if isinstance(provider, ProviderReadiness)
                         else None)
            else:
                registered, ready = False, False
            out.append({
                "alias": profile.alias,
                "kind": profile.kind.value,
                "provider": profile.provider_id,
                "task": profile.task,
                "purposes": sorted(profile.purposes),
                "capabilities": sorted(profile.capabilities),
                "providerRegistered": registered,
                "artifactReady": ready,
                "maxOutputTokens": min(
                    PlatformLimits.OUTPUT_TOKENS,
                    profile.max_output_tokens or PlatformLimits.OUTPUT_TOKENS),
                "source": ({"repo": profile.source.repo,
                            "revision": profile.source.revision}
                           if profile.source else None),
            })
        return out

    def _apple_status_string(self) -> str:
        if not IS_MACOS:
            return "notApplePlatform"
        from .providers.apple import AppleFoundationProvider
        return ("available" if AppleFoundationProvider.available_on_host()
                else "unavailable")

    def _apple_category(self) -> CategoryStatus:
        if APPLE_PROVIDER_ID in self._llm_providers:
            return CategoryStatus.QUALIFIED
        return (CategoryStatus.OBSERVING
                if self._apple_status_string() != "notApplePlatform"
                else CategoryStatus.NOT_CONFIGURED)

    def _open_weight_category(self) -> CategoryStatus:
        providers = [self._llm_providers.get(MLX_PROVIDER_ID),
                     self._llm_providers.get(LLAMACPP_PROVIDER_ID)]
        if not any(providers):
            return (CategoryStatus.OBSERVING
                    if any(p.provider_id in (MLX_PROVIDER_ID,
                                             LLAMACPP_PROVIDER_ID)
                           for p in self._model_profiles.values())
                    else CategoryStatus.NOT_CONFIGURED)
        ready = any(isinstance(p, ProviderReadiness) and p.has_ready_artifact
                    for p in providers if p)
        return (CategoryStatus.QUALIFIED if ready
                else CategoryStatus.OBSERVING)

    def registry_snapshot(self) -> dict:
        with self._lock:
            models = self._model_summaries_locked()
            agents = (self.agent_service.profile_summaries()
                      if self.agent_service else [])
            return {
                "models": [p.alias for p in
                           sorted(self._model_profiles.values(),
                                  key=lambda p: p.alias)],
                "agents": [a["id"] for a in agents],
                "modelProfiles": models,
                "agentProfiles": agents,
            }

    def list_jobs(self) -> list[JobRecord]:
        return self._store.jobs()

    # -- admission -----------------------------------------------------------

    def submit_llm(self, principal: Principal, request: ChatRequest,
                   parent_id: str | None = None,
                   cancellation: CancellationToken | None = None):
        self.require(Grant.LLM_INFER, principal)
        with self._lock:
            profile = self._model_profiles.get(request.model)
        if profile is None or profile.kind != ModelKind.LLM:
            raise PlatformError(ErrorCode.NOT_FOUND)
        request = request.resolving_default_output_tokens(
            profile.max_output_tokens)
        validate_chat(request, profile)
        with self._lock:
            provider = self._llm_providers.get(profile.provider_id)
        if provider is None:
            raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE)
        provider.validate(request, profile)
        result = self._enqueue(
            JobKind.LLM, principal.id, parent_id, cancellation,
            _WorkItem(JobKind.LLM,
                      request.limiting_output_tokens(
                          profile.max_output_tokens),
                      profile, provider))
        return result

    def submit_ml(self, principal: Principal, request,
                  parent_id: str | None = None,
                  cancellation: CancellationToken | None = None):
        self.require(Grant.ML_PREDICT, principal)
        with self._lock:
            profile = self._model_profiles.get(request.model)
        if profile is None or profile.kind != ModelKind.ML:
            raise PlatformError(ErrorCode.NOT_FOUND)
        if profile.task != request.task:
            raise PlatformError(ErrorCode.INVALID_REQUEST, "task mismatch")
        if profile.input_schema:
            validate_features(request.inputs, profile.input_schema)
        validate_prediction(request, profile)
        with self._lock:
            predictor = self._ml_predictors.get(profile.provider_id)
        if predictor is None:
            raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE)
        result = self._enqueue(JobKind.ML, principal.id, parent_id,
                               cancellation,
                               _WorkItem(JobKind.ML, request, profile,
                                         predictor))
        if profile.output_schema:
            validate_features(result.outputs, profile.output_schema)
        return result

    def _work_requires_load(self, work: _WorkItem) -> bool:
        if work.kind == JobKind.LLM:
            return work.provider.requires_load(work.profile)
        return True

    def _verdict(self) -> resources.ResourceVerdict:
        return resources.evaluate(self._latest_snapshot, time.time())

    def _dispatchable_slot(self, requires_load: bool) -> bool:
        if (self._shutting_down or self._inference_blocked
                or len(self._active) >= PlatformLimits.ACTIVE_INFERENCE):
            return False
        verdict = self._verdict()
        return (verdict == resources.ResourceVerdict.ADMIT
                or (verdict == resources.ResourceVerdict.DEFER_LOAD
                    and not requires_load))

    def _enqueue(self, kind: JobKind, consumer_id: str,
                 parent_id: str | None,
                 cancellation: CancellationToken | None,
                 work: _WorkItem):
        with self._lock:
            if self._shutting_down:
                raise PlatformError(ErrorCode.CANCELLED)
            if cancellation is not None and cancellation.is_cancelled:
                raise PlatformError(ErrorCode.CANCELLED)
            if self._inference_blocked:
                raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                                    "inference blocked")
            # Reserve capacity before storage: outstanding inserts count
            # toward the bound so a submission burst cannot overrun.
            if self._dispatchable_slot(self._work_requires_load(work)):
                cap = (PlatformLimits.ACTIVE_INFERENCE
                       + PlatformLimits.PENDING_INFERENCE)
                total = (len(self._active) + len(self._pending)
                         + self._insertion_reservations)
            else:
                cap = PlatformLimits.PENDING_INFERENCE
                total = len(self._pending) + self._insertion_reservations
            if total >= cap:
                raise PlatformError(ErrorCode.CAPACITY_LIMITED, "queue full")
            now = time.time()
            self._job_sequence += 1
            job = JobRecord(id=f"job-{self._job_sequence}", kind=kind,
                            consumer_id=consumer_id, parent_id=parent_id,
                            state=JobState.QUEUED, created_at=now,
                            updated_at=now)
            job_token = CancellationToken()
            self._job_tokens[job.id] = job_token
            if cancellation is not None:
                observer = cancellation.observe(
                    lambda jt=job_token, j=job.id: (
                        jt.cancel(),
                        threading.Thread(
                            target=self._cancel_job_record_safely,
                            args=(j, PlatformError(ErrorCode.CANCELLED)),
                            daemon=True).start()))
                self._job_cancellations[job.id] = (cancellation, observer)
            self._insertion_reservations += 1
        try:
            self._store.insert_job(job)
        except PlatformError:
            with self._lock:
                self._insertion_reservations -= 1
                self._release_job_cancellation(job.id)
            raise PlatformError(ErrorCode.STORAGE_FAILURE)
        with self._lock:
            self._insertion_reservations -= 1
            if self._shutting_down or (
                    cancellation is not None and cancellation.is_cancelled):
                self._finish_terminal(job, JobState.CANCELLED)
                raise PlatformError(ErrorCode.CANCELLED)
            if (not self._dispatchable_slot(
                    self._work_requires_load(work))
                    and len(self._pending) >= PlatformLimits.PENDING_INFERENCE):
                self._finish_terminal(job, JobState.FAILED)
                raise PlatformError(ErrorCode.CAPACITY_LIMITED, "queue full")
            self._pending.append(job)
            self._pending_work[job.id] = work
            waiter = _Waiter()
            # Registered BEFORE dispatch: dispatch can finish the job
            # synchronously and a missing waiter would lose the result.
            self._waiters[job.id] = waiter
            self._dispatch_locked()
        waiter.event.wait()
        if waiter.error is not None:
            raise waiter.error
        return waiter.result

    # -- dispatch (lock held) ------------------------------------------------

    def _sweep_expired_locked(self) -> None:
        now = time.time()
        kept = []
        for job in self._pending:
            if now - job.created_at > PlatformLimits.QUEUE_DEADLINE_SECONDS:
                self._pending_work.pop(job.id, None)
                self._finish_terminal(job, JobState.FAILED)
                self._resume(job.id, None,
                             PlatformError(ErrorCode.DEADLINE_EXCEEDED))
            else:
                kept.append(job)
        self._pending = kept

    def _dispatch_locked(self) -> None:
        self._sweep_expired_locked()
        if (self._shutting_down or self._inference_blocked
                or len(self._active) >= PlatformLimits.ACTIVE_INFERENCE
                or not self._pending):
            return
        now = time.time()
        verdict = self._verdict()
        consumers = sorted({j.consumer_id for j in self._pending})
        picked = None
        for step in range(len(consumers)):
            chosen = consumers[(self._next_consumer_index + step)
                               % len(consumers)]
            for i, job in enumerate(self._pending):
                if job.consumer_id != chosen:
                    continue
                work = self._pending_work.get(job.id)
                loads = (self._work_requires_load(work)
                         if work is not None else True)
                if (verdict == resources.ResourceVerdict.DEFER_LOAD
                        and loads):
                    break  # try next consumer's candidate
                picked = i
                break
            if picked is not None:
                break
        if picked is None:
            return
        self._next_consumer_index += 1
        job = self._pending.pop(picked)
        work = self._pending_work.pop(job.id, None)
        if work is None:
            return self._dispatch_locked()
        token_pair = self._job_cancellations.get(job.id)
        if token_pair is not None and token_pair[0].is_cancelled:
            self._finish_terminal(job, JobState.CANCELLED)
            self._resume(job.id, None, PlatformError(ErrorCode.CANCELLED))
            return self._dispatch_locked()
        needed = Grant.LLM_INFER if job.kind == JobKind.LLM else Grant.ML_PREDICT
        if needed not in self._grants.get(job.consumer_id, frozenset()):
            self._finish_terminal(job, JobState.FAILED)
            self._resume(job.id, None, PlatformError(ErrorCode.FORBIDDEN))
            return self._dispatch_locked()
        if not (verdict == resources.ResourceVerdict.ADMIT or (
                verdict == resources.ResourceVerdict.DEFER_LOAD
                and not self._work_requires_load(work))):
            self._finish_terminal(job, JobState.FAILED)
            self._resume(job.id, None,
                         PlatformError(ErrorCode.RESOURCE_DENIED))
            return self._dispatch_locked()
        job.state = JobState.ACTIVE
        job.updated_at = now
        self._active[job.id] = job
        self._running_work[job.id] = work
        self._persist(job)
        self._increment(kind=job.kind)
        self._launch(job, work)
        self._dispatch_locked()

    def _launch(self, job: JobRecord, work: _WorkItem) -> None:
        job_id = job.id
        token = self._job_tokens.get(job_id)

        def run() -> None:
            try:
                if work.kind == JobKind.LLM:
                    result = work.provider.complete(
                        work.request, work.profile, token=token)
                else:
                    result = work.provider.predict(work.request, work.profile)
                self._provider_finished(job_id, result=result)
            except PlatformError as e:
                self._provider_finished(job_id, error=e)
            except Exception as e:
                self._provider_finished(
                    job_id, error=PlatformError(
                        ErrorCode.PROVIDER_UNAVAILABLE,
                        f"{type(e).__name__}: {e}"))

        thread = threading.Thread(target=run, daemon=True,
                                  name=f"oap-{job_id}")
        self._running_threads[job_id] = thread
        thread.start()
        deadline = threading.Timer(
            PlatformLimits.INFERENCE_DEADLINE_SECONDS,
            self._inference_deadline, args=(job_id,))
        deadline.daemon = True
        deadline.start()

    def _inference_deadline(self, job_id: str) -> None:
        with self._lock:
            job = self._active.get(job_id)
            if job is None or job.state != JobState.ACTIVE:
                return
            job.state = JobState.FAILED
            job.updated_at = time.time()
            self._persist(job)
            self._resume(job_id, None,
                         PlatformError(ErrorCode.DEADLINE_EXCEEDED))
            job_token = self._job_tokens.get(job_id)
            if job_token is not None:
                job_token.cancel()
            self._ask_provider_cancel_locked(job_id)

    def _provider_finished(self, job_id: str, result=None,
                           error: Exception | None = None) -> None:
        with self._lock:
            self._running_threads.pop(job_id, None)
            self._running_work.pop(job_id, None)
            self._release_job_cancellation(job_id)
            job = self._active.get(job_id)
            if job is None:
                return   # stale/double ignored
            job.provider_finished = True
            job.updated_at = time.time()
            if job.state == JobState.CANCEL_REQUESTED:
                del self._active[job_id]
                job.state = JobState.CANCELLED
                self._persist(job)
                self._resume(job_id, None,
                             PlatformError(ErrorCode.CANCELLED))
            elif job.state == JobState.CANCELLATION_UNCONFIRMED:
                del self._active[job_id]
                self._persist(job)
            elif job.state == JobState.ACTIVE:
                del self._active[job_id]
                if error is not None:
                    self._finish_terminal(job, JobState.FAILED)
                    self._resume(job_id, None, error)
                elif result is not None:
                    self._finish_terminal(job, JobState.COMPLETED)
                    self._resume(job_id, result, None)
                else:
                    self._finish_terminal(job, JobState.FAILED)
                    self._resume(job_id, None, PlatformError(
                        ErrorCode.DEADLINE_EXCEEDED))
            else:
                # Terminal retained job (deadline-failed): release slot only.
                del self._active[job_id]
                self._persist(job)
            self._refresh_blocked_locked()
            self._dispatch_locked()

    def _cancel_job_record(self, job_id: str, error: PlatformError) -> None:
        for i, job in enumerate(self._pending):
            if job.id == job_id:
                job = self._pending.pop(i)
                self._pending_work.pop(job_id, None)
                self._finish_terminal(job, JobState.CANCELLED)
                self._resume(job_id, None, error)
                return
        job = self._active.get(job_id)
        if job is not None and job.state == JobState.ACTIVE:
            job.state = JobState.CANCEL_REQUESTED
            job.updated_at = time.time()
            self._persist(job)
            job_token = self._job_tokens.get(job_id)
            if job_token is not None:
                job_token.cancel()
            self._ask_provider_cancel_locked(job_id)
            timer = threading.Timer(
                PlatformLimits.CANCELLATION_GRACE_SECONDS,
                self._grace_expired, args=(job_id,))
            timer.daemon = True
            timer.start()

    def _cancel_job_record_safely(self, job_id: str, error: PlatformError) -> None:
        with self._lock:
            self._cancel_job_record(job_id, error)

    def _ask_provider_cancel_locked(self, job_id: str) -> None:
        work = self._running_work.get(job_id)
        if work is None:
            return
        try:
            work.provider.cancel(job_id)
        except Exception:
            pass

    def _grace_expired(self, job_id: str) -> None:
        with self._lock:
            job = self._active.get(job_id)
            if job is None or job.state != JobState.CANCEL_REQUESTED:
                return
            job.state = JobState.CANCELLATION_UNCONFIRMED
            job.updated_at = time.time()
            self._persist(job)
            self._inference_blocked = True
            self._resume(job_id, None, PlatformError(
                ErrorCode.CANCELLATION_UNCONFIRMED))

    def _refresh_blocked_locked(self) -> None:
        self._inference_blocked = any(
            j.state == JobState.CANCELLATION_UNCONFIRMED
            for j in self._active.values())

    def cancel_job(self, principal: Principal, job_id: str) -> None:
        job = self.job_record(job_id)
        if job is None:
            raise PlatformError(ErrorCode.NOT_FOUND)
        admin = self.has(Grant.ADMIN_STOP, principal)
        own = job.consumer_id == principal.id
        own_work = (self.has(Grant.LLM_INFER, principal)
                    or self.has(Grant.ML_PREDICT, principal)
                    or self.has(Grant.AGENT_RUN, principal))
        if not (admin or (own and own_work)):
            raise PlatformError(ErrorCode.FORBIDDEN)
        with self._lock:
            self._cancel_job_record(job_id, PlatformError(ErrorCode.CANCELLED))

    def cancel_children(self, parent_id: str) -> None:
        with self._lock:
            for job in list(self._pending) + list(self._active.values()):
                if job.parent_id == parent_id:
                    self._cancel_job_record(
                        job.id, PlatformError(ErrorCode.CANCELLED))

    def _cancel_all(self, reason: PlatformError) -> None:
        with self._lock:
            for job in list(self._pending):
                self._cancel_job_record(job.id, reason)
            for job in list(self._active.values()):
                self._cancel_job_record(job.id, reason)

    def cancel_children_for_resource_denial(self) -> None:
        for job in list(self._pending) + list(self._active.values()):
            self._cancel_job_record(
                job.id, PlatformError(ErrorCode.RESOURCE_DENIED))

    def job_record(self, job_id: str) -> JobRecord | None:
        with self._lock:
            for job in self._pending:
                if job.id == job_id:
                    return job
            if job_id in self._active:
                return self._active[job_id]
        return self._store.job(job_id)

    # -- helpers (lock held) -------------------------------------------------

    def _persist(self, job: JobRecord) -> None:
        # Must never raise: a store failure here must not strand the job or
        # the waiter; the durable ledger is best-effort after enqueue.
        try:
            self._store.update_job(job)
        except Exception:
            pass

    def _finish_terminal(self, job: JobRecord, state: JobState) -> None:
        job.state = state
        job.updated_at = time.time()
        job.provider_finished = True
        self._persist(job)
        self._release_job_cancellation(job.id)

    def _resume(self, job_id: str, result, error: Exception | None) -> None:
        waiter = self._waiters.pop(job_id, None)
        if waiter is not None:
            waiter.result = result
            waiter.error = error
            waiter.event.set()

    def _release_job_cancellation(self, job_id: str) -> None:
        self._job_tokens.pop(job_id, None)
        pair = self._job_cancellations.pop(job_id, None)
        if pair is not None:
            pair[0].remove_observer(pair[1])

    def _increment(self, kind: JobKind) -> None:
        try:
            self._store.increment_counter(f"jobs.{kind.value}")
        except PlatformError:
            pass

    # -- resource observation ------------------------------------------------

    def resource_changed(self, snapshot) -> None:
        with self._lock:
            if snapshot.captured_at < self._latest_snapshot.captured_at:
                return
            self._latest_snapshot = snapshot
            if resources.evaluate(snapshot, time.time()) == \
                    resources.ResourceVerdict.DENY_AND_CANCEL:
                # Shed unserving residents first - cheapest relief.
                # Cancelling in-flight work on a transient dip punishes
                # the request whose own allocation tipped the host; the
                # recheck cancels only if pressure persists.
                for provider in self._llm_providers.values():
                    if isinstance(provider, ModelCacheEvicting):
                        provider.evict_not_inflight()
                self._schedule_deny_recheck_locked()
            else:
                cutoff = time.time() - PlatformLimits.MODEL_IDLE_SECONDS
                for provider in self._llm_providers.values():
                    if isinstance(provider, ModelCacheEvicting):
                        provider.evict_idle(cutoff)
            self._dispatch_locked()

    def _schedule_deny_recheck_locked(self) -> None:
        if self._deny_recheck_pending or self._shutting_down:
            return
        self._deny_recheck_pending = True
        timer = threading.Timer(PlatformLimits.DENY_RECHECK_SECONDS,
                                self._deny_recheck)
        timer.daemon = True
        timer.start()

    def _deny_recheck(self) -> None:
        try:
            snapshot = self._source.current_snapshot()
        except Exception:
            snapshot = None
        with self._lock:
            self._deny_recheck_pending = False
            if self._shutting_down:
                return
            if snapshot is not None:
                self._latest_snapshot = snapshot
            if resources.evaluate(snapshot or self._latest_snapshot,
                                  time.time()) == \
                    resources.ResourceVerdict.DENY_AND_CANCEL:
                self.cancel_children_for_resource_denial()
                for provider in self._llm_providers.values():
                    if isinstance(provider, ModelCacheEvicting):
                        provider.evict_resident()
            self._dispatch_locked()

    def harness_context(self, principal: Principal, parent_id: str,
                        token: CancellationToken) -> AgentHarnessContext:
        return AgentHarnessContext(self, principal, parent_id, token)
