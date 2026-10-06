"""Core correctness tests: runtime root, registry, catalog, chat
validation, resources, state, modelstore path safety."""
import json
import os
import stat
import sys
import tempfile
import time
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

from ondevice_agent_platform import catalog, resources
from ondevice_agent_platform.chat import (ChatMessage, ChatRequest, ChatRole,
                                          validate_chat)
from ondevice_agent_platform.errors import ErrorCode, PlatformError
from ondevice_agent_platform.openai_adapter import parse_chat_request
from ondevice_agent_platform.profiles import ModelKind
from ondevice_agent_platform.registry import parse_registry
from ondevice_agent_platform.runtime_root import RuntimeRoot
from ondevice_agent_platform.state import JobKind, JobRecord, JobState, StateStore


def raises(code, fn, *a, **k):
    try:
        fn(*a, **k)
    except PlatformError as e:
        assert e.code == code, f"expected {code}, got {e.code}: {e}"
        return
    raise AssertionError(f"expected PlatformError {code}")


class TestRuntimeRoot(unittest.TestCase):
    def test_prepare_creates_owned_dirs(self):
        with tempfile.TemporaryDirectory() as d:
            root = RuntimeRoot(os.path.join(d, "rt"))
            root.prepare()
            mode = stat.S_IMODE(os.stat(root.path).st_mode)
            self.assertEqual(mode, 0o700)
            # Subdirs are created lazily by their owners.
            from ondevice_agent_platform.modelstore import ModelStore
            ModelStore(root)
            self.assertTrue(os.path.isdir(root.models_path))

    def test_symlinked_root_refused(self):
        with tempfile.TemporaryDirectory() as d:
            real = os.path.join(d, "real")
            link = os.path.join(d, "link")
            os.makedirs(real)
            os.symlink(real, link)
            root = RuntimeRoot(link)
            raises(ErrorCode.ROOT_UNSAFE, root.prepare)

    def test_lock_exclusive(self):
        with tempfile.TemporaryDirectory() as d:
            root = RuntimeRoot(d)
            root.prepare()
            root.acquire_lock()
            other = RuntimeRoot(d)
            raises(ErrorCode.CONFLICT, other.acquire_lock)
            root.release_lock()
            other.acquire_lock()
            other.release_lock()


class TestRegistry(unittest.TestCase):
    LLM = {"alias": "m1", "kind": "llm", "provider": "llamacpp",
           "task": "chat", "purposes": [], "capabilities": ["text"],
           "source": {"repo": "o/r", "revision": "abc1234",
                      "file": "m.gguf"}}

    def test_valid(self):
        entries = parse_registry({"schemaVersion": 1,
                                  "models": [self.LLM]})
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0].artifact_file, "m.gguf")
        self.assertEqual(entries[0].profile.kind, ModelKind.LLM)

    def test_file_is_llamacpp_only(self):
        bad = dict(self.LLM, provider="mlx")
        raises(ErrorCode.INVALID_REQUEST, parse_registry,
               {"schemaVersion": 1, "models": [bad]})

    def test_unknown_key_rejected(self):
        bad = dict(self.LLM, surprise=True)
        raises(ErrorCode.INVALID_REQUEST, parse_registry,
               {"schemaVersion": 1, "models": [bad]})

    def test_bad_repo_rejected(self):
        bad = json.loads(json.dumps(self.LLM))
        bad["source"]["repo"] = "no-slash-allowed!!"
        raises(ErrorCode.INVALID_REQUEST, parse_registry,
               {"schemaVersion": 1, "models": [bad]})

    def test_file_traversal_rejected(self):
        bad = json.loads(json.dumps(self.LLM))
        bad["source"]["file"] = "../evil.gguf"
        raises(ErrorCode.INVALID_REQUEST, parse_registry,
               {"schemaVersion": 1, "models": [bad]})

    def test_linear_valid(self):
        entries = parse_registry({"schemaVersion": 1, "models": [{
            "alias": "clf", "kind": "ml", "provider": "builtin.linear",
            "task": "classification",
            "inputSchema": {"x": "number"},
            "outputSchema": {"label": "string", "confidence": "number"},
            "linear": {"features": ["x"], "labels": ["a", "b"],
                       "weights": [[1.0], [-1.0]], "bias": [0.0, 0.0]},
        }]})
        self.assertEqual(entries[0].profile.kind, ModelKind.ML)
        self.assertEqual(entries[0].linear.labels, ["a", "b"])

    def test_linear_schema_mismatch(self):
        raises(ErrorCode.INVALID_REQUEST, parse_registry,
               {"schemaVersion": 1, "models": [{
                   "alias": "clf", "kind": "ml", "provider": "builtin.linear",
                   "task": "classification",
                   "inputSchema": {"x": "number"},
                   "outputSchema": {"label": "string", "confidence": "number"},
                   "linear": {"features": ["y"], "labels": ["a"],
                              "weights": [[1.0]]},
               }]})


class TestCatalog(unittest.TestCase):
    def test_merge_preserves_unrelated(self):
        existing = {"schemaVersion": 1, "models": [
            {"alias": "mine", "kind": "ml", "provider": "builtin.linear",
             "task": "classification",
             "inputSchema": {"x": "number"},
             "outputSchema": {"label": "string", "confidence": "number"},
             "linear": {"features": ["x"], "labels": ["a"],
                        "weights": [[1.0]]}}]}
        merged = catalog.merged_registry(existing, [catalog.ENTRIES[2]])
        aliases = [m["alias"] for m in merged["models"]]
        self.assertIn("mine", aliases)
        self.assertIn("qwen3.8-9b-gguf", aliases)

    def test_merge_replaces_same_alias(self):
        e = catalog.ENTRIES[0]
        existing = {"schemaVersion": 1, "models": [dict(
            e.registry_value(), purposes=["old"])]}
        merged = catalog.merged_registry(existing, [e])
        models = [m for m in merged["models"] if m["alias"] == e.alias]
        self.assertEqual(len(models), 1)
        self.assertEqual(models[0]["purposes"], list(e.purposes))

    def test_malformed_models_rejected(self):
        raises(ErrorCode.INVALID_REQUEST, catalog.merged_registry,
               {"schemaVersion": 1, "models": "nope"}, [])


class TestChatParse(unittest.TestCase):
    def test_minimal(self):
        req, stream, usage = parse_chat_request(json.dumps({
            "model": "m", "messages": [
                {"role": "user", "content": "hi"}]}).encode())
        self.assertFalse(stream)
        self.assertEqual(req.model, "m")
        self.assertEqual(req.messages[0].parts, ["hi"])

    def test_unknown_field(self):
        raises(ErrorCode.INVALID_REQUEST, parse_chat_request, json.dumps({
            "model": "m", "messages": [], "wat": 1}).encode())

    def test_remote_image_refused(self):
        raises(ErrorCode.INVALID_REQUEST, parse_chat_request, json.dumps({
            "model": "m", "messages": [{"role": "user", "content": [
                {"type": "image_url",
                 "image_url": {"url": "https://evil/x.png"}}]}]}).encode())

    def test_tools_parse(self):
        req, _, _ = parse_chat_request(json.dumps({
            "model": "m",
            "messages": [{"role": "user", "content": "x"}],
            "tools": [{"type": "function", "function": {"name": "f"}}],
            "tool_choice": "auto"}).encode())
        self.assertEqual(len(req.tools), 1)

    def test_validate_context_bound(self):
        from ondevice_agent_platform.profiles import ModelProfile
        profile = ModelProfile(alias="m", provider_id="llamacpp",
                               kind=ModelKind.LLM, task="chat",
                               max_output_tokens=8)
        req = ChatRequest(model="m", messages=[
            ChatMessage(role=ChatRole.USER, parts=["x"])],
            max_output_tokens=64, has_explicit_output_limit=True)
        raises(ErrorCode.INVALID_REQUEST, validate_chat, req, profile)


class TestResources(unittest.TestCase):
    def snap(self, thermal, pressure, lp=False):
        return resources.ResourceSnapshot(
            thermal, pressure, lp, time.time(),
            resources.MemoryPressureSource.ESTIMATE)

    def test_healthy_admits(self):
        v = resources.evaluate(self.snap(
            resources.ThermalLevel.NOMINAL,
            resources.MemoryPressureLevel.NORMAL), time.time())
        self.assertEqual(v, resources.ResourceVerdict.ADMIT)

    def test_unknown_denies(self):
        v = resources.evaluate(self.snap(
            resources.ThermalLevel.UNKNOWN,
            resources.MemoryPressureLevel.NORMAL), time.time())
        self.assertEqual(v, resources.ResourceVerdict.DENY_AND_CANCEL)

    def test_not_present_does_not_deny(self):
        v = resources.evaluate(self.snap(
            resources.ThermalLevel.NOT_PRESENT,
            resources.MemoryPressureLevel.NORMAL), time.time())
        self.assertEqual(v, resources.ResourceVerdict.ADMIT)

    def test_warning_denies(self):
        v = resources.evaluate(self.snap(
            resources.ThermalLevel.NOMINAL,
            resources.MemoryPressureLevel.WARNING), time.time())
        self.assertEqual(v, resources.ResourceVerdict.DENY_AND_CANCEL)

    def test_fair_defers_load(self):
        v = resources.evaluate(self.snap(
            resources.ThermalLevel.FAIR,
            resources.MemoryPressureLevel.NORMAL), time.time())
        self.assertEqual(v, resources.ResourceVerdict.DEFER_LOAD)

    def test_stale_denies(self):
        s = self.snap(resources.ThermalLevel.NOMINAL,
                      resources.MemoryPressureLevel.NORMAL)
        s.captured_at = time.time() - 3600
        self.assertEqual(resources.evaluate(s, time.time()),
                         resources.ResourceVerdict.DENY_AND_CANCEL)


class TestStateStore(unittest.TestCase):
    def test_lifecycle(self):
        with tempfile.TemporaryDirectory() as d:
            store = StateStore(os.path.join(d, "s.db"))
            store.open()
            job = JobRecord(id="job-1", kind=JobKind.LLM,
                            consumer_id="c", parent_id=None,
                            state=JobState.QUEUED, created_at=time.time(),
                            updated_at=time.time())
            store.insert_job(job)
            job.state = JobState.COMPLETED
            store.update_job(job)
            self.assertEqual(store.job("job-1").state, JobState.COMPLETED)
            self.assertEqual(len(store.jobs()), 1)
            store.close()

    def test_interrupted_marked_on_reopen(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "s.db")
            s1 = StateStore(p)
            s1.open()
            s1.insert_job(JobRecord(
                id="job-9", kind=JobKind.ML, consumer_id="c", parent_id=None,
                state=JobState.ACTIVE, created_at=time.time(),
                updated_at=time.time()))
            s1._db.close(); s1._db = None   # simulate crash
            s2 = StateStore(p)
            s2.open()
            self.assertEqual(s2.job("job-9").state, JobState.INTERRUPTED)
            s2.close()


class TestModelStore(unittest.TestCase):
    def test_directory_is_inside_models(self):
        from ondevice_agent_platform.modelstore import ModelStore
        from ondevice_agent_platform.profiles import ModelSource
        with tempfile.TemporaryDirectory() as d:
            root = RuntimeRoot(d)
            root.prepare()
            store = ModelStore(root)
            src = ModelSource(repo="o/r", revision="abc123")
            path = store.directory(src, "f.gguf")
            self.assertTrue(path.startswith(
                os.path.realpath(root.models_path)))
            self.assertFalse(store.is_ready(src, "f.gguf"))


if __name__ == "__main__":
    unittest.main()
