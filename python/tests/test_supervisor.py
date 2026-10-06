"""Supervisor admission/dispatch/cancel + ACP + HTTP integration tests
with fake providers and fake resource sources."""
import json
import os
import sys
import tempfile
import threading
import time
import unittest
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
