"""Supervisor admission/dispatch/cancel + ACP + HTTP integration tests
with fake providers and fake resource sources."""
import json
import os
import sys
import tempfile
import threading
import time
import unittest
import unittest.mock
import urllib.request

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

from ondevice_agent_platform import resources
from ondevice_agent_platform.acp_service import ACPService
from ondevice_agent_platform.agents import AgentService
from ondevice_agent_platform.cancellation import CancellationToken
from ondevice_agent_platform.chat import (ChatMessage, ChatRequest, ChatRole,
                                          ChatResult, ChatUsage, FinishReason)
from ondevice_agent_platform.errors import ErrorCode, PlatformError
from ondevice_agent_platform.limits import PlatformLimits
from ondevice_agent_platform.profiles import (ConsumerScope, Grant,
                                              LocalConsumers, ModelKind,
                                              ModelProfile, Principal)
from ondevice_agent_platform.providers.base import (
    LLMProvider, ModelCacheEvicting, MLPredictor, ProviderReadiness)
from ondevice_agent_platform.runtime_root import RuntimeRoot
from ondevice_agent_platform.state import JobState
from ondevice_agent_platform.supervisor import PlatformSupervisor


class FakeSource(resources.ResourceSource):
    def __init__(self, thermal=resources.ThermalLevel.NOMINAL,
                 pressure=resources.MemoryPressureLevel.NORMAL):
        self._snap = resources.ResourceSnapshot(
            thermal, pressure, False, time.time(),
            resources.MemoryPressureSource.ESTIMATE)
        self.cb = None

    def current_snapshot(self):
        return self._snap

    def start(self, on_change):
        self.cb = on_change

    def stop(self):
        pass

    def push(self, thermal=None, pressure=None):
        self._snap = resources.ResourceSnapshot(
            thermal or self._snap.thermal,
            pressure or self._snap.memory_pressure, False, time.time(),
            resources.MemoryPressureSource.ESTIMATE)
        if self.cb:
            self.cb(self._snap)


class FakeLLM(LLMProvider):
    provider_id = "fake-llm"

    def __init__(self, delay=0.0, fail=None):
        self.delay = delay
        self.fail = fail
        self.calls = 0
        self._cancel = threading.Event()

    def requires_load(self, profile):
        return False

    def validate(self, request, profile):
        pass

    def complete(self, request, profile, token=None):
        self.calls += 1
        end = time.time() + self.delay
        while time.time() < end:
            if self._cancel.is_set() or (token and token.is_cancelled):
                raise PlatformError(ErrorCode.CANCELLED)
            time.sleep(0.01)
        if self.fail:
            raise self.fail
        return ChatResult(model_identity="fake", content="pong",
                          finish_reason=FinishReason.STOP,
                          tool_calls=[], usage=ChatUsage(1, 1, 2))

    def cancel(self, job_id):
        self._cancel.set()


class FakeEvictingLLM(FakeLLM, ModelCacheEvicting):
    def __init__(self, **kw):
        super().__init__(**kw)
        self.resident_evictions = 0
        self.not_inflight_evictions = 0

    def evict_resident(self):
        self.resident_evictions += 1
        return 0

    def evict_not_inflight(self):
        self.not_inflight_evictions += 1
        return 0


class FakeML(MLPredictor):
    provider_id = "fake-ml"

    def predict(self, request, profile):
        class R:
            outputs = {"label": "x", "confidence": 0.5}
        return R()

    def cancel(self, job_id):
        pass


def make_supervisor(tmpdir, source=None):
    root = RuntimeRoot(tmpdir)
    root.prepare()
    root.acquire_lock()
    sup = PlatformSupervisor(root, source or FakeSource())
    sup.start()
    return sup


class TestSupervisor(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def llm_profile(self, provider_id="fake-llm", alias="m"):
        return ModelProfile(alias=alias, provider_id=provider_id,
                            kind=ModelKind.LLM, task="chat",
                            max_output_tokens=64)

    def req(self, alias="m", text="hi"):
        return ChatRequest(model=alias, messages=[
            ChatMessage(role=ChatRole.USER, parts=[text])],
            max_output_tokens=32, has_explicit_output_limit=True)

    def test_llm_happy_path(self):
        sup = make_supervisor(self.tmp.name)
        self.addCleanup(sup.shutdown)
        sup.register_model(self.llm_profile(), provider=FakeLLM())
        r = sup.submit_llm(LocalConsumers.MODEL, self.req())
        self.assertEqual(r.content, "pong")

    def test_unknown_model_404(self):
        sup = make_supervisor(self.tmp.name)
        self.addCleanup(sup.shutdown)
        with self.assertRaises(PlatformError) as cm:
            sup.submit_llm(LocalConsumers.MODEL, self.req())
        self.assertEqual(cm.exception.code, ErrorCode.NOT_FOUND)

    def test_missing_provider_unavailable(self):
        sup = make_supervisor(self.tmp.name)
        self.addCleanup(sup.shutdown)
        sup.register_model(self.llm_profile())
        with self.assertRaises(PlatformError) as cm:
            sup.submit_llm(LocalConsumers.MODEL, self.req())
        self.assertEqual(cm.exception.code, ErrorCode.PROVIDER_UNAVAILABLE)

    def test_deny_verdict_refuses(self):
        src = FakeSource(pressure=resources.MemoryPressureLevel.CRITICAL)
        sup = make_supervisor(self.tmp.name, src)
        self.addCleanup(sup.shutdown)
        sup.register_model(self.llm_profile(), provider=FakeLLM())
        with self.assertRaises(PlatformError) as cm:
            sup.submit_llm(LocalConsumers.MODEL, self.req())
        self.assertIn(cm.exception.code, (ErrorCode.RESOURCE_DENIED,
                                          ErrorCode.DEADLINE_EXCEEDED))

    def test_deny_and_cancel_kills_queued(self):
        src = FakeSource()
        sup = make_supervisor(self.tmp.name, src)
        self.addCleanup(sup.shutdown)
        provider = FakeLLM(delay=30.0)
        sup.register_model(self.llm_profile(), provider=provider)
        box = {}
        t = threading.Thread(target=lambda: box.setdefault(
            "r", self._submit(sup)), daemon=True)
        t.start()
        time.sleep(0.3)   # job active
        src.push(pressure=resources.MemoryPressureLevel.CRITICAL)
        t.join(PlatformLimits.DENY_RECHECK_SECONDS + 5)
        self.assertIsInstance(box.get("r"), PlatformError)
        self.assertIn(box["r"].code, (ErrorCode.CANCELLED,
                                      ErrorCode.RESOURCE_DENIED))

    def test_transient_deny_spares_inflight(self):
        # A deny snapshot sheds unserving residents first; when pressure
        # recovers before the recheck, the in-flight job completes.
        src = FakeSource()
        sup = make_supervisor(self.tmp.name, src)
        self.addCleanup(sup.shutdown)
        provider = FakeEvictingLLM(delay=3.0)
        sup.register_model(self.llm_profile(), provider=provider)
        box = {}
        t = threading.Thread(target=lambda: box.setdefault(
            "r", self._submit(sup)), daemon=True)
        t.start()
        time.sleep(0.3)
        src.push(pressure=resources.MemoryPressureLevel.CRITICAL)
        time.sleep(0.5)
        src.push(pressure=resources.MemoryPressureLevel.NORMAL)
        t.join(6)
        self.assertEqual(getattr(box.get("r"), "content", None), "pong")
        self.assertGreaterEqual(provider.not_inflight_evictions, 1)
        self.assertEqual(provider.resident_evictions, 0)

    def test_persistent_deny_still_cancels(self):
        # If pressure persists past the recheck, jobs are cancelled and
        # even serving residents are shed.
        src = FakeSource()
        sup = make_supervisor(self.tmp.name, src)
        self.addCleanup(sup.shutdown)
        provider = FakeEvictingLLM(delay=30.0)
        sup.register_model(self.llm_profile(), provider=provider)
        box = {}
        t = threading.Thread(target=lambda: box.setdefault(
            "r", self._submit(sup)), daemon=True)
        t.start()
        time.sleep(0.3)
        src.push(pressure=resources.MemoryPressureLevel.CRITICAL)
        t.join(PlatformLimits.DENY_RECHECK_SECONDS + 6)
        self.assertIsInstance(box.get("r"), PlatformError)
        self.assertIn(box["r"].code, (ErrorCode.CANCELLED,
                                      ErrorCode.RESOURCE_DENIED))
        self.assertGreaterEqual(provider.resident_evictions, 1)

    def _submit(self, sup):
        try:
            return sup.submit_llm(LocalConsumers.MODEL, self.req())
        except PlatformError as e:
            return e

    def test_cancel_running_job(self):
        sup = make_supervisor(self.tmp.name)
        self.addCleanup(sup.shutdown)
        provider = FakeLLM(delay=5.0)
        sup.register_model(self.llm_profile(), provider=provider)
        token = CancellationToken()
        box = {}
        t = threading.Thread(target=lambda: box.setdefault(
            "r", self._submit_tok(sup, token)), daemon=True)
        t.start()
        time.sleep(0.3)
        token.cancel()
        t.join(5)
        self.assertFalse(t.is_alive())
        self.assertIsInstance(box.get("r"), PlatformError)

    def _submit_tok(self, sup, token):
        try:
            return sup.submit_llm(LocalConsumers.MODEL, self.req(),
                                  cancellation=token)
        except PlatformError as e:
            return e

    def test_ml_route(self):
        sup = make_supervisor(self.tmp.name)
        self.addCleanup(sup.shutdown)
        profile = ModelProfile(alias="c", provider_id="fake-ml",
                               kind=ModelKind.ML, task="classification")
        sup.register_model(profile, predictor=FakeML())

        class Req:
            model = "c"
            task = "classification"
            inputs = {"x": 1.0}
        r = sup.submit_ml(LocalConsumers.MODEL, Req())
        self.assertEqual(r.outputs["label"], "x")

    def test_grant_revocation(self):
        sup = make_supervisor(self.tmp.name)
        self.addCleanup(sup.shutdown)
        sup.register_model(self.llm_profile(), provider=FakeLLM())
        sup.revoke_grant(Grant.LLM_INFER, LocalConsumers.MODEL.id)
        with self.assertRaises(PlatformError) as cm:
            sup.submit_llm(LocalConsumers.MODEL, self.req())
        self.assertEqual(cm.exception.code, ErrorCode.FORBIDDEN)

    def test_status_snapshot_shape(self):
        sup = make_supervisor(self.tmp.name)
        self.addCleanup(sup.shutdown)
        sup.register_model(self.llm_profile(), provider=FakeLLM())
        snap = sup.status_snapshot()
        self.assertIn("resource", snap)
        self.assertIn("models", snap)
        self.assertEqual(snap["models"][0]["alias"], "m")


class _TokenOnlyLLM(LLMProvider):
    """Cooperative only via the job token: provider.cancel() is a no-op,
    so every cancellation must arrive through the private job token the
    supervisor hands to complete()."""

    provider_id = "token-only"

    def __init__(self, release=None):
        self.started = threading.Event()
        self.saw_cancel = threading.Event()
        self.closed = False
        self.release = release or threading.Event()

    def requires_load(self, profile):
        return False

    def complete(self, request, profile, token=None):
        self.started.set()
        end = time.time() + 15
        while time.time() < end and not self.release.is_set():
            if token is not None and token.is_cancelled:
                self.saw_cancel.set()
                raise PlatformError(ErrorCode.CANCELLED)
            time.sleep(0.01)
        return ChatResult(model_identity="token-only", content="pong",
                          finish_reason=FinishReason.STOP,
                          tool_calls=[], usage=ChatUsage(1, 1, 2))

    def cancel(self, job_id):
        pass    # deliberately noncooperative at the provider API

    def close(self):
        self.closed = True


class _StateAtSignalLLM(_TokenOnlyLLM):
    """Installs an observer on the private job token that records the
    ACTIVE job's ledger state at the moment the signal fires - the point
    where the old bridge cancelled the token before the locked cancel
    path had marked CANCEL_REQUESTED."""

    provider_id = "token-only"

    def __init__(self, sup):
        super().__init__()
        self._sup = sup
        self.state_at_signal = None

    def complete(self, request, profile, token=None):
        if token is not None:
            def probe():
                with self._sup._lock:
                    jobs = [j for j in self._sup._active.values()
                            if j.state == JobState.ACTIVE
                            or j.state == JobState.CANCEL_REQUESTED]
                    self.state_at_signal = (
                        jobs[0].state if jobs else None)
            token.observe(probe)
        return super().complete(request, profile, token=token)


class _SpontaneousCancelLLM(_TokenOnlyLLM):
    """Returns CANCELLED of its own accord while the job record is still
    ACTIVE - no cancel request anywhere."""

    provider_id = "token-only"

    def complete(self, request, profile, token=None):
        self.started.set()
        raise PlatformError(ErrorCode.CANCELLED)


class _FastLLM(_TokenOnlyLLM):
    """Returns immediately - exercises finish-before-timer ordering."""

    provider_id = "token-only"

    def complete(self, request, profile, token=None):
        self.started.set()
        return ChatResult(model_identity="token-only", content="pong",
                          finish_reason=FinishReason.STOP,
                          tool_calls=[], usage=ChatUsage(1, 1, 2))


class _UncooperativeLLM(_TokenOnlyLLM):
    """Ignores the private token entirely and blocks until the fixture
    releases it; provider.cancel() is a no-op."""

    provider_id = "token-only"

    def complete(self, request, profile, token=None):
        self.started.set()
        end = time.time() + 15
        while time.time() < end and not self.release.is_set():
            time.sleep(0.01)
        return ChatResult(model_identity="token-only", content="pong",
                          finish_reason=FinishReason.STOP,
                          tool_calls=[], usage=ChatUsage(1, 1, 2))


class TestCancellationLifecycle(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def _sup(self, provider=None, source=None):
        sup = make_supervisor(self.tmp.name, source)
        self.addCleanup(sup.shutdown)
        provider = provider or _TokenOnlyLLM()
        sup.register_model(
            ModelProfile(alias="m", provider_id="token-only",
                         kind=ModelKind.LLM, task="chat",
                         max_output_tokens=64),
            provider=provider)
        return sup, provider

    def _req(self, alias="m"):
        return ChatRequest(model=alias, messages=[
            ChatMessage(role=ChatRole.USER, parts=["hi"])],
            max_output_tokens=32, has_explicit_output_limit=True)

    def _submit(self, sup, token=None):
        try:
            return sup.submit_llm(LocalConsumers.MODEL, self._req(),
                                  cancellation=token)
        except PlatformError as e:
            return e

    def _active_job(self, sup):
        for _ in range(200):
            jobs = sup.list_jobs()
            active = [j for j in jobs
                      if j.state == JobState.ACTIVE]
            if active:
                return active[0]
            time.sleep(0.02)
        self.fail("no active job")

    def test_job_cancel_uses_private_token_and_frees_slot(self):
        sup, provider = self._sup()
        box = {}
        t = threading.Thread(target=lambda: box.setdefault(
            "r", self._submit(sup)), daemon=True)
        t.start()
        job = self._active_job(sup)
        sup.cancel_job(LocalConsumers.ADMINISTRATION, job.id)
        t.join(5)
        self.assertFalse(t.is_alive())
        self.assertIsInstance(box["r"], PlatformError)
        self.assertEqual(box["r"].code, ErrorCode.CANCELLED)
        self.assertTrue(provider.saw_cancel.is_set())
        # Slot freed: the next submission dispatches and completes.
        provider.release.set()
        result = self._submit(sup)
        self.assertEqual(result.content, "pong")
        self.assertEqual(sup._job_cancellations, {})

    def test_deadline_signals_private_token(self):
        sup, provider = self._sup()
        box = {}
        with unittest.mock.patch.object(
                PlatformLimits, "INFERENCE_DEADLINE_SECONDS", 0.3):
            t = threading.Thread(target=lambda: box.setdefault(
                "r", self._submit(sup)), daemon=True)
            t.start()
            t.join(5)
        self.assertFalse(t.is_alive())
        self.assertIsInstance(box["r"], PlatformError)
        self.assertEqual(box["r"].code, ErrorCode.DEADLINE_EXCEEDED)
        # The deadline cancels the private token; the provider observes
        # it on its own loop, so allow it a moment.
        self.assertTrue(provider.saw_cancel.wait(3))

    def test_deny_recheck_signals_private_token(self):
        src = FakeSource()
        sup, provider = self._sup(_TokenOnlyLLM(), src)
        box = {}
        with unittest.mock.patch.object(
                PlatformLimits, "DENY_RECHECK_SECONDS", 0.2):
            t = threading.Thread(target=lambda: box.setdefault(
                "r", self._submit(sup)), daemon=True)
            t.start()
            self.assertTrue(provider.started.wait(3))
            src.push(pressure=resources.MemoryPressureLevel.CRITICAL)
            t.join(6)
        self.assertFalse(t.is_alive())
        self.assertIsInstance(box["r"], PlatformError)
        self.assertIn(box["r"].code,
                      (ErrorCode.CANCELLED, ErrorCode.RESOURCE_DENIED))
        self.assertTrue(provider.saw_cancel.is_set())

    def test_sibling_unaffected_parent_cancel_cancels_both(self):
        # Two jobs share a caller token (the parent). Cancelling one job
        # must not cancel the parent or sibling; cancelling the parent
        # must cancel both children.
        sup, provider = self._sup()
        parent = CancellationToken()
        boxes = [{}, {}]
        threads = [
            threading.Thread(target=lambda i=i: boxes[i].setdefault(
                "r", self._submit(sup, parent)), daemon=True)
            for i in range(2)]
        for t in threads:
            t.start()
        job1 = self._active_job(sup)
        sup.cancel_job(LocalConsumers.MODEL, job1.id)
        # The active child ends cancelled; the sibling dispatches next
        # and stays blocked inside the provider; the parent token is
        # untouched by the single-child cancellation.
        deadline = time.time() + 5
        while time.time() < deadline and not any("r" in b for b in boxes):
            time.sleep(0.02)
        self.assertTrue(any("r" in b for b in boxes))
        self.assertFalse(parent.is_cancelled)
        parent.cancel()
        for t in threads:
            t.join(6)
        self.assertFalse(any(t.is_alive() for t in threads))
        for b in boxes:
            self.assertIsInstance(b["r"], PlatformError)
            self.assertEqual(b["r"].code, ErrorCode.CANCELLED)

    def test_shutdown_cancels_jobs_and_closes_provider(self):
        sup, provider = self._sup()
        box = {}
        t = threading.Thread(target=lambda: box.setdefault(
            "r", self._submit(sup)), daemon=True)
        t.start()
        self.assertTrue(provider.started.wait(3))
        sup.shutdown()
        t.join(5)
        self.assertFalse(t.is_alive())
        self.assertIsInstance(box["r"], PlatformError)
        self.assertTrue(provider.closed)
        # Post-shutdown dispatch is refused, not queued.
        with self.assertRaises(PlatformError) as cm:
            sup.submit_llm(LocalConsumers.MODEL, self._req())
        self.assertEqual(cm.exception.code, ErrorCode.CANCELLED)
        # Idempotent.
        sup.shutdown()

    def test_shutdown_releases_root_lock(self):
        sup, _provider = self._sup()
        sup.shutdown()
        sup._root.acquire_lock()   # would block/fail if still held
        sup._root.release_lock()

    def test_parent_cancel_marks_requested_before_token_fires(self):
        # Ordering regression: the parent-token bridge must run the locked
        # cancel path first so the ledger shows CANCEL_REQUESTED (not
        # ACTIVE) at the moment the private token fires; the worker's
        # CANCELLED return then resolves to a durable CANCELLED record.
        sup = make_supervisor(self.tmp.name)
        self.addCleanup(sup.shutdown)
        provider = _StateAtSignalLLM(sup)
        sup.register_model(
            ModelProfile(alias="m", provider_id="token-only",
                         kind=ModelKind.LLM, task="chat",
                         max_output_tokens=64),
            provider=provider)
        parent = CancellationToken()
        box = {}
        t = threading.Thread(target=lambda: box.setdefault(
            "r", self._submit(sup, parent)), daemon=True)
        t.start()
        job = self._active_job(sup)
        # Wait for the worker to install its private-token observer so the
        # ordering assertion is deterministic.
        self.assertTrue(provider.started.wait(3))
        parent.cancel()
        t.join(5)
        self.assertFalse(t.is_alive())
        self.assertEqual(provider.state_at_signal,
                         JobState.CANCEL_REQUESTED)
        self.assertIsInstance(box["r"], PlatformError)
        self.assertEqual(box["r"].code, ErrorCode.CANCELLED)
        record = sup.job_record(job.id)
        self.assertEqual(record.state, JobState.CANCELLED)
        self.assertTrue(record.provider_finished)
        self.assertFalse(sup._inference_blocked)
        self.assertEqual(sup._job_cancellations, {})

    def test_provider_spontaneous_cancelled_ends_cancelled(self):
        sup = make_supervisor(self.tmp.name)
        self.addCleanup(sup.shutdown)
        provider = _SpontaneousCancelLLM()
        sup.register_model(
            ModelProfile(alias="m", provider_id="token-only",
                         kind=ModelKind.LLM, task="chat",
                         max_output_tokens=64),
            provider=provider)
        result = self._submit(sup)
        self.assertIsInstance(result, PlatformError)
        self.assertEqual(result.code, ErrorCode.CANCELLED)
        records = [j for j in sup.list_jobs()]
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0].state, JobState.CANCELLED)
        self.assertTrue(records[0].provider_finished)


class TestJobTimerLifecycle(unittest.TestCase):
    """Owned deadline/grace timers: created per job, cancelled on every
    terminal outcome, popped by their own callbacks, swept at shutdown."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def _sup(self, provider=None):
        sup = make_supervisor(self.tmp.name)
        self.addCleanup(sup.shutdown)
        provider = provider or _TokenOnlyLLM()
        sup.register_model(
            ModelProfile(alias="m", provider_id="token-only",
                         kind=ModelKind.LLM, task="chat",
                         max_output_tokens=64),
            provider=provider)
        return sup, provider

    def _req(self):
        return ChatRequest(model="m", messages=[
            ChatMessage(role=ChatRole.USER, parts=["hi"])],
            max_output_tokens=32, has_explicit_output_limit=True)

    def _submit(self, sup, token=None):
        try:
            return sup.submit_llm(LocalConsumers.MODEL, self._req(),
                                  cancellation=token)
        except PlatformError as e:
            return e

    def _active_job(self, sup):
        for _ in range(200):
            active = [j for j in sup.list_jobs()
                      if j.state == JobState.ACTIVE]
            if active:
                return active[0]
            time.sleep(0.02)
        self.fail("no active job")

    def _owned_timer_threads(self):
        return [t for t in threading.enumerate()
                if (t.name.startswith("oap-deadline-")
                    or t.name.startswith("oap-grace-"))
                and t.is_alive()]

    def _assert_no_owned_timers(self, sup):
        deadline = time.time() + 5
        while time.time() < deadline:
            if (not sup._job_deadline_timers
                    and not sup._job_grace_timers
                    and not self._owned_timer_threads()):
                return
            time.sleep(0.02)
        self.assertEqual(sup._job_deadline_timers, {})
        self.assertEqual(sup._job_grace_timers, {})
        self.assertEqual(self._owned_timer_threads(), [])

    def test_fast_completions_leave_no_timers(self):
        sup, _ = self._sup(provider=_FastLLM())
        for _ in range(10):
            result = self._submit(sup)
            self.assertEqual(result.content, "pong")
        self._assert_no_owned_timers(sup)

    def test_confirmed_cancel_clears_deadline_and_grace(self):
        sup, provider = self._sup()
        box = {}
        t = threading.Thread(target=lambda: box.setdefault(
            "r", self._submit(sup)), daemon=True)
        t.start()
        job = self._active_job(sup)
        # list_jobs reads the store without the lock; the ACTIVE row can
        # persist a moment before _launch registers the timer - wait for
        # the owned handle itself rather than racing it.
        deadline = time.time() + 3
        while (job.id not in sup._job_deadline_timers
               and time.time() < deadline):
            time.sleep(0.01)
        self.assertIn(job.id, sup._job_deadline_timers)
        sup.cancel_job(LocalConsumers.ADMINISTRATION, job.id)
        t.join(5)
        self.assertFalse(t.is_alive())
        self.assertEqual(box["r"].code, ErrorCode.CANCELLED)
        self.assertTrue(provider.saw_cancel.is_set())
        provider.release.set()
        self._assert_no_owned_timers(sup)

    def test_short_deadline_fires_and_cleans_handles(self):
        sup, provider = self._sup()
        box = {}
        with unittest.mock.patch.object(
                PlatformLimits, "INFERENCE_DEADLINE_SECONDS", 0.3):
            t = threading.Thread(target=lambda: box.setdefault(
                "r", self._submit(sup)), daemon=True)
            t.start()
            t.join(5)
            self.assertFalse(t.is_alive())
            self.assertEqual(box["r"].code, ErrorCode.DEADLINE_EXCEEDED)
            self.assertTrue(provider.saw_cancel.wait(3))
        provider.release.set()
        self._assert_no_owned_timers(sup)

    def test_uncooperative_cancel_holds_slot_then_cleans(self):
        sup, provider = self._sup(provider=_UncooperativeLLM())
        box = {}
        with unittest.mock.patch.object(
                PlatformLimits, "CANCELLATION_GRACE_SECONDS", 0.3):
            t = threading.Thread(target=lambda: box.setdefault(
                "r", self._submit(sup)), daemon=True)
            t.start()
            job = self._active_job(sup)
            sup.cancel_job(LocalConsumers.ADMINISTRATION, job.id)
            t.join(5)
            self.assertFalse(t.is_alive())
            self.assertEqual(box["r"].code,
                             ErrorCode.CANCELLATION_UNCONFIRMED)
            # Provider never answered: slot stays occupied, ledger stays
            # unconfirmed - never falsely upgraded to CANCELLED.
            self.assertTrue(sup._inference_blocked)
            record = sup.job_record(job.id)
            self.assertEqual(record.state,
                             JobState.CANCELLATION_UNCONFIRMED)
            provider.release.set()
            deadline = time.time() + 5
            while time.time() < deadline and sup._inference_blocked:
                time.sleep(0.02)
            self.assertFalse(sup._inference_blocked)
        self._assert_no_owned_timers(sup)
        # Slot really freed: a new job runs to completion.
        result = self._submit(sup)
        self.assertEqual(result.content, "pong")

    def test_shutdown_leaves_no_owned_timers(self):
        sup, provider = self._sup()
        box = {}
        t = threading.Thread(target=lambda: box.setdefault(
            "r", self._submit(sup)), daemon=True)
        t.start()
        self.assertTrue(provider.started.wait(3))
        sup.shutdown()
        t.join(5)
        provider.release.set()
        self._assert_no_owned_timers(sup)

    def test_shutdown_noncooperative_resumes_unconfirmed(self):
        # Shutdown must not strand the caller: grace timers stay live
        # through the bounded worker wait, and any still-unconfirmed
        # request is resumed via the normal expiry path before storage
        # closes - while the provider keeps its slot until it finishes.
        sup, provider = self._sup(provider=_UncooperativeLLM())
        box = {}
        with unittest.mock.patch.object(
                PlatformLimits, "CANCELLATION_GRACE_SECONDS", 0.3):
            t = threading.Thread(target=lambda: box.setdefault(
                "r", self._submit(sup)), daemon=True)
            t.start()
            self.assertTrue(provider.started.wait(3))
            sup.shutdown()
            t.join(1)
            self.assertFalse(t.is_alive())
            self.assertIsInstance(box["r"], PlatformError)
            self.assertEqual(box["r"].code,
                             ErrorCode.CANCELLATION_UNCONFIRMED)
            # Slot still held - never falsely confirmed or released.
            self.assertTrue(sup._inference_blocked)
            self.assertTrue(any(
                j.state == JobState.CANCELLATION_UNCONFIRMED
                for j in sup._active.values()))
            provider.release.set()
            deadline = time.time() + 5
            while time.time() < deadline and sup._active:
                time.sleep(0.02)
        self.assertEqual(sup._active, {})
        self.assertEqual(sup._job_deadline_timers, {})
        self.assertEqual(sup._job_grace_timers, {})
        self.assertEqual(self._owned_timer_threads(), [])


class TestACP(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.sup = make_supervisor(self.tmp.name)
        self.addCleanup(self.sup.shutdown)
        agents = AgentService(self.sup)
        agents.attach(self.sup)
        agents.register_builtin_reference()
        self.acp = ACPService(self.sup)
        self.acp.bind("c1", "reference.status", LocalConsumers.AGENT)

    def rpc(self, msg, conn="c1"):
        out = []
        self.acp.handle(conn, msg, None, out.append)
        return out

    def test_initialize(self):
        out = self.rpc({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                        "params": {"protocolVersion": 1}})
        self.assertEqual(out[0]["result"]["protocolVersion"], 1)

    def test_session_and_prompt(self):
        out = self.rpc({"jsonrpc": "2.0", "id": 2, "method": "session/new",
                        "params": {"cwd": "/tmp", "mcpServers": []}})
        sid = out[0]["result"]["sessionId"]
        out = self.rpc({"jsonrpc": "2.0", "id": 3,
                        "method": "session/prompt",
                        "params": {"sessionId": sid, "prompt": [
                            {"type": "text", "text": "hi"}]}})
        notes = [m for m in out if m.get("method") == "session/update"]
        self.assertTrue(notes)
        result = [m for m in out if m.get("id") == 3][0]
        self.assertEqual(result["result"]["stopReason"], "end_turn")

    def test_mcp_refused(self):
        out = self.rpc({"jsonrpc": "2.0", "id": 2, "method": "session/new",
                        "params": {"cwd": "/tmp", "mcpServers": [
                            {"name": "x"}]}})
        self.assertIn("error", out[0])

    def test_unbound_connection(self):
        out = self.rpc({"jsonrpc": "2.0", "id": 1,
                        "method": "initialize"}, conn="nope")
        self.assertEqual(out[0]["error"]["code"], -32600)

    def test_one_prompt_per_session(self):
        out = self.rpc({"jsonrpc": "2.0", "id": 2, "method": "session/new",
                        "params": {"cwd": "/tmp", "mcpServers": []}})
        sid = out[0]["result"]["sessionId"]
        # concurrent prompts: occupy the session claim
        slow = SlowHarness()
        self.sup.agent_service._harnesses[
            self.sup.agent_service._profiles["reference.status"]
            .implementation_ref] = (lambda: slow, "slow", 1)
        results = []
        done = threading.Event()

        def run(i):
            results.append(self.rpc(
                {"jsonrpc": "2.0", "id": 10 + i,
                 "method": "session/prompt",
                 "params": {"sessionId": sid, "prompt": [
                     {"type": "text", "text": "x"}]}}))
            done.set()

        slow.started = threading.Event()
        t = threading.Thread(target=run, args=(0,), daemon=True)
        t.start()
        self.assertTrue(slow.started.wait(3))
        out2 = self.rpc({"jsonrpc": "2.0", "id": 11,
                         "method": "session/prompt",
                         "params": {"sessionId": sid, "prompt": [
                             {"type": "text", "text": "y"}]}})
        self.assertIn("error", out2[-1])   # conflict while turn active
        slow.release.set()
        t.join(5)


class SlowHarness:
    def __init__(self):
        self.started = threading.Event()
        self.release = threading.Event()

    def run(self, blocks, context, emit):
        self.started.set()
        self.release.wait(5)
        emit("message_chunk", "done")
        from ondevice_agent_platform.agents import AgentStopReason
        return AgentStopReason.END_TURN


class TestHTTP(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.sup = make_supervisor(self.tmp.name)
        self.addCleanup(self.sup.shutdown)
        self.sup.register_model(
            ModelProfile(alias="m", provider_id="fake-llm",
                         kind=ModelKind.LLM, task="chat",
                         max_output_tokens=64),
            provider=FakeLLM())
        from ondevice_agent_platform.server import PlatformHTTPServer
        self.server = PlatformHTTPServer(self.sup, port=0)
        self.server.start()
        self.addCleanup(self.server.stop)
        self.base = f"http://127.0.0.1:{self.server.port}"

    def req(self, path, method="GET", body=None, headers=None):
        h = {"Content-Type": "application/json"}
        h.update(headers or {})
        r = urllib.request.Request(self.base + path,
                                   data=json.dumps(body).encode()
                                   if body is not None else None,
                                   headers=h, method=method)
        try:
            return urllib.request.urlopen(r, timeout=10)
        except urllib.error.HTTPError as e:
            return e

    def test_status(self):
        r = self.req("/api/status")
        self.assertEqual(r.status, 200)
        body = json.loads(r.read())
        self.assertIn("resource", body)

    def test_models(self):
        r = self.req("/v1/models")
        self.assertEqual(json.loads(r.read())["data"][0]["id"], "m")

    def test_chat(self):
        r = self.req("/v1/chat/completions", "POST",
                     {"model": "m", "messages": [
                         {"role": "user", "content": "hi"}]})
        body = json.loads(r.read())
        self.assertEqual(
            body["choices"][0]["message"]["content"], "pong")

    def test_chat_stream_sse(self):
        r = self.req("/v1/chat/completions", "POST",
                     {"model": "m", "stream": True, "messages": [
                         {"role": "user", "content": "hi"}]})
        raw = r.read().decode()
        self.assertIn("data:", raw)
        self.assertIn("[DONE]", raw)
        self.assertIn("pong", raw)

    def test_foreign_origin_forbidden(self):
        r = self.req("/api/status",
                     headers={"Origin": "http://evil.example"})
        self.assertEqual(r.status, 403)

    def test_bad_json(self):
        r = urllib.request.Request(
            self.base + "/v1/chat/completions", data=b"{not json",
            headers={"Content-Type": "application/json"}, method="POST")
        try:
            resp = urllib.request.urlopen(r, timeout=10)
            self.fail("expected 400")
        except urllib.error.HTTPError as e:
            self.assertEqual(e.code, 400)


if __name__ == "__main__":
    unittest.main()
