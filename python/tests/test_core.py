"""Core correctness tests: runtime root, registry, catalog, chat
validation, resources, state, modelstore path safety."""
import json
import os
import stat
import sys
import tempfile
import time
import unittest
from pathlib import Path

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

    def test_interrupted_write_preserves_old_bytes(self):
        from unittest import mock
        from ondevice_agent_platform import compat
        with tempfile.TemporaryDirectory() as d:
            root = RuntimeRoot(d)
            root.prepare()
            root.write_json({"a": 1}, root.config_path)
            original = Path(root.config_path).read_bytes()

            def boom(*a, **k):
                raise OSError("simulated crash before replace")

            with mock.patch.object(compat.os, "replace", boom):
                with self.assertRaises(OSError):
                    root.write_json({"a": 2}, root.config_path)
            self.assertEqual(Path(root.config_path).read_bytes(),
                             original)
            # Only the staged temp file may be cleaned up - and it is.
            self.assertNotIn(".oap-write-",
                             " ".join(os.listdir(root.path)))

    def test_write_json_symlink_refused(self):
        with tempfile.TemporaryDirectory() as d:
            root = RuntimeRoot(os.path.join(d, "rt"))
            root.prepare()
            target = os.path.join(d, "victim.json")
            with open(target, "w") as f:
                f.write('{"precious": true}')
            os.symlink(target, root.config_path)
            raises(ErrorCode.ROOT_UNSAFE,
                   root.write_json, {"a": 1}, root.config_path)
            with open(target) as f:
                self.assertEqual(json.load(f), {"precious": True})

    def test_write_json_nonregular_refused(self):
        with tempfile.TemporaryDirectory() as d:
            root = RuntimeRoot(d)
            root.prepare()
            os.mkdir(root.config_path)
            raises(ErrorCode.ROOT_UNSAFE,
                   root.write_json, {"a": 1}, root.config_path)

    def test_write_json_foreign_owned_refused(self):
        from unittest import mock
        from ondevice_agent_platform import compat
        if not compat.IS_POSIX:
            self.skipTest("uid check is POSIX-only")
        with tempfile.TemporaryDirectory() as d:
            root = RuntimeRoot(d)
            root.prepare()
            root.write_json({"a": 1}, root.config_path)
            original = Path(root.config_path).read_bytes()
            with mock.patch.object(compat.os, "getuid",
                                   return_value=-1):
                raises(ErrorCode.ROOT_UNSAFE,
                       root.write_json, {"a": 2}, root.config_path)
            self.assertEqual(Path(root.config_path).read_bytes(),
                             original)

    def test_crash_stage_residue_tolerated(self):
        # A write_owned stage orphaned by real process death has the
        # exact platform temp shape; prepare must not brick the root
        # over it, and it is preserved untouched.
        with tempfile.TemporaryDirectory() as d:
            root_path = os.path.join(d, "rt")
            stage = os.path.join(
                root_path,
                f".oap-write-{os.getpid()}-{'a' * 32}")
            os.mkdir(root_path)
            with open(stage, "w") as f:
                f.write("partial")
            root = RuntimeRoot(root_path)
            root.prepare()
            self.assertEqual(Path(stage).read_text(), "partial")
            root.write_json({"a": 1}, root.config_path)
            self.assertEqual(root.read_json(root.config_path),
                             {"a": 1})

    def test_stage_lookalikes_still_refused(self):
        # Prefix-lookalike dirs/symlinks/non-pattern names are NOT the
        # platform's stage and remain unrelated entries.
        with tempfile.TemporaryDirectory() as d:
            for name, make in (
                    (f".oap-write-{os.getpid()}-{'b' * 32}",
                     lambda p: os.mkdir(p)),
                    (".oap-write-x-nothex",
                     lambda p: open(p, "w").close()),
                    (f".oap-write-{os.getpid()}-{'c' * 32}",
                     lambda p: os.symlink(os.devnull, p))):
                root_path = os.path.join(d, name.replace("/", "_"))
                os.mkdir(root_path)
                make(os.path.join(root_path, name))
                raises(ErrorCode.ROOT_UNSAFE,
                       RuntimeRoot(root_path).prepare)


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

    def test_vision_hybrid_valid(self):
        entry = {"alias": "vision-hybrid", "kind": "llm",
                 "provider": "vision-hybrid", "task": "chat",
                 "capabilities": ["text", "vision"],
                 "delegate": "qwen-vl"}
        entries = parse_registry({"schemaVersion": 1, "models": [entry]})
        self.assertEqual(entries[0].delegate, "qwen-vl")
        self.assertIsNone(entries[0].profile.source)

    def test_vision_hybrid_requires_delegate(self):
        entry = {"alias": "vision-hybrid", "kind": "llm",
                 "provider": "vision-hybrid", "task": "chat"}
        raises(ErrorCode.INVALID_REQUEST, parse_registry,
               {"schemaVersion": 1, "models": [entry]})

    def test_vision_hybrid_rejects_source(self):
        entry = {"alias": "vision-hybrid", "kind": "llm",
                 "provider": "vision-hybrid", "task": "chat",
                 "delegate": "qwen-vl",
                 "source": {"repo": "o/r", "revision": "abc1234"}}
        raises(ErrorCode.INVALID_REQUEST, parse_registry,
               {"schemaVersion": 1, "models": [entry]})

    def test_delegate_is_hybrid_only(self):
        bad = dict(self.LLM, delegate="qwen-vl")
        raises(ErrorCode.INVALID_REQUEST, parse_registry,
               {"schemaVersion": 1, "models": [bad]})

    def test_image_max_soft_tokens_valid(self):
        entry = dict(self.LLM, capabilities=["text", "vision"],
                     imageMaxSoftTokens=1120)
        entries = parse_registry({"schemaVersion": 1, "models": [entry]})
        self.assertEqual(
            entries[0].profile.image_max_soft_tokens, 1120)

    def test_image_max_soft_tokens_requires_vision(self):
        bad = dict(self.LLM, imageMaxSoftTokens=1120)
        raises(ErrorCode.INVALID_REQUEST, parse_registry,
               {"schemaVersion": 1, "models": [bad]})

    def test_image_max_soft_tokens_bounds(self):
        for value in (0, -1, 8193, "1120"):
            bad = dict(self.LLM, capabilities=["text", "vision"],
                       imageMaxSoftTokens=value)
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
        entry = next(e for e in catalog.ENTRIES
                     if e.alias == "qwen3.8-9b-gguf")
        merged = catalog.merged_registry(existing, [entry])
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

    def test_gguf_offered_only_where_needed(self):
        from ondevice_agent_platform.requirements import HostInfo
        mac = HostInfo(os="macos", arch="arm64", has_metal=True,
                       total_memory=16_000_000_000)
        eligible = {e.alias: ok for e, ok, _
                    in catalog.available_entries(mac)}
        self.assertTrue(eligible["qwen3.8-9b"])
        self.assertFalse(eligible["qwen3.8-9b-gguf"])
        for osname in ("windows", "linux"):
            host = HostInfo(os=osname, arch="x86_64", has_metal=False,
                            total_memory=32_000_000_000)
            eligible = {e.alias: ok for e, ok, _
                        in catalog.available_entries(host)}
            self.assertTrue(eligible["qwen3.8-9b-gguf"], osname)
            self.assertFalse(eligible["qwen3.8-9b"], osname)


class TestServeConfig(unittest.TestCase):
    def _ns(self, **kw):
        import argparse
        defaults = dict(enable_apple_model=False, enable_operator=False,
                        operator_model=None)
        defaults.update(kw)
        return argparse.Namespace(**defaults)

    def test_config_supplies_defaults(self):
        from ondevice_agent_platform import cli
        args = self._ns()
        cli._apply_serve_config(args, {"enableOperator": True,
                                       "operatorModel": "m1",
                                       "enableAppleModel": True})
        self.assertTrue(args.enable_operator)
        self.assertTrue(args.enable_apple_model)
        self.assertEqual(args.operator_model, "m1")

    def test_flags_beat_config(self):
        from ondevice_agent_platform import cli
        args = self._ns(enable_operator=True, operator_model="flag")
        cli._apply_serve_config(args, {"enableOperator": False,
                                       "operatorModel": "cfg"})
        self.assertTrue(args.enable_operator)
        self.assertEqual(args.operator_model, "flag")

    def test_operator_prompt_persists_choice(self):
        from ondevice_agent_platform import cli
        with tempfile.TemporaryDirectory() as d:
            root = RuntimeRoot(os.path.join(d, "rt"))
            root.prepare()
            cli._prompt_operator_agent(
                root, [catalog.ENTRIES[0]], input_fn=lambda _p: "y")
            config = root.read_json(root.config_path)
            self.assertTrue(config.get("enableOperator"))
            # macOS binds the Apple route; other OSes bind the first
            # selected LLM - either way the choice must be explicit.
            self.assertTrue(config.get("enableAppleModel") or
                            config.get("operatorModel"))

    def test_operator_prompt_decline_persists_false(self):
        from ondevice_agent_platform import cli
        with tempfile.TemporaryDirectory() as d:
            root = RuntimeRoot(os.path.join(d, "rt"))
            root.prepare()
            cli._prompt_operator_agent(
                root, [catalog.ENTRIES[0]], input_fn=lambda _p: "n")
            config = root.read_json(root.config_path)
            self.assertFalse(config.get("enableOperator"))


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

    def test_json_schema_strict_parsed_not_dropped(self):
        req, _, _ = parse_chat_request(json.dumps({
            "model": "m",
            "messages": [{"role": "user", "content": "x"}],
            "response_format": {"type": "json_schema",
                                "json_schema": {
                                    "name": "answer",
                                    "schema": {"type": "object"},
                                    "strict": True}}}).encode())
        self.assertEqual(req.response_format.kind, "json_schema")
        self.assertIs(req.response_format.strict, True)
        self.assertEqual(req.response_format.name, "answer")

    def test_json_schema_strict_false_kept(self):
        req, _, _ = parse_chat_request(json.dumps({
            "model": "m",
            "messages": [{"role": "user", "content": "x"}],
            "response_format": {"type": "json_schema",
                                "json_schema": {
                                    "schema": {"type": "object"},
                                    "strict": False}}}).encode())
        self.assertIs(req.response_format.strict, False)

    def test_json_schema_strict_nonbool_rejected(self):
        raises(ErrorCode.INVALID_REQUEST, parse_chat_request,
               json.dumps({
                   "model": "m",
                   "messages": [{"role": "user", "content": "x"}],
                   "response_format": {"type": "json_schema",
                                       "json_schema": {
                                           "schema": {"type": "object"},
                                           "strict": "yes"}}}).encode())

    def test_json_schema_bad_keys_rejected(self):
        raises(ErrorCode.INVALID_REQUEST, parse_chat_request,
               json.dumps({
                   "model": "m",
                   "messages": [{"role": "user", "content": "x"}],
                   "response_format": {"type": "json_schema",
                                       "json_schema": {
                                           "schema": {"type": "object"},
                                           "surprise": 1}}}).encode())


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

    def test_warning_defers_loads(self):
        # Memory warning freezes new loads but does not cancel in-flight
        # work or shed residents; only CRITICAL denies outright.
        v = resources.evaluate(self.snap(
            resources.ThermalLevel.NOMINAL,
            resources.MemoryPressureLevel.WARNING), time.time())
        self.assertEqual(v, resources.ResourceVerdict.DEFER_LOAD)

    def test_critical_denies(self):
        v = resources.evaluate(self.snap(
            resources.ThermalLevel.NOMINAL,
            resources.MemoryPressureLevel.CRITICAL), time.time())
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
