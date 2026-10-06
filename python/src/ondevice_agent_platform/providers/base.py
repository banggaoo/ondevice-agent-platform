"""Provider seam contracts, mirroring ProviderContracts.swift.

Distinct injectable seams. Empty registries are valid; test fixtures live
in test support, never as default serving aliases.
"""
from __future__ import annotations


class LLMProvider:
    provider_id: str = ""

    def validate(self, request, profile) -> None:
        """Provider-specific option check after shared validation and before
        admission. A provider that does not honor a field must reject it
        here rather than silently ignore it."""
        return None

    def complete(self, request, profile, token=None):
        """Blocking provider call. `token` is a CancellationToken for
        cooperative cancellation; providers that cannot cancel simply finish
        and the scheduler keeps the slot until real completion."""
        raise NotImplementedError

    def cancel(self, job_id: str) -> None:
        """Cooperative cancellation hint."""
        return None

    def requires_load(self, profile) -> bool:
        """Whether dispatching now would load weights into memory. The
        admission scheduler applies defer_load truthfully: load-bearing
        work stays queued; resident/system-managed calls still dispatch.
        Conservative default: assume a call loads weights."""
        return True


class MLPredictor:
    provider_id: str = ""

    def predict(self, request, profile):
        raise NotImplementedError

    def cancel(self, job_id: str) -> None:
        return None


class ModelCacheEvicting:
    """Optional weight-cache shedding: deny_and_cancel sheds resident
    containers; snapshots trim containers idle past MODEL_IDLE_SECONDS.
    Containers serving an in-flight request are never idle: deny verdicts
    shed only unserving residents, then re-check; a persistent deny still
    cancels jobs and sheds everything via evict_resident."""

    def evict_resident(self) -> int:
        return 0

    def evict_not_inflight(self) -> int:
        return 0

    def evict_idle(self, older_than: float) -> int:
        return 0


class ProviderReadiness:
    """Optional truthful readiness for providers with external artifacts."""

    @property
    def has_ready_artifact(self) -> bool:
        return False

    def artifact_ready(self, profile) -> bool | None:
        return None
