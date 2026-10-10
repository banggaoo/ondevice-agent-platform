"""Console-administration tests: the admin job lane, governed pull
submission + cooperative abort, live catalog declaration, artifact
removal, and runtime Operator enable/disable - plus their HTTP routes."""
import json
import os
import sys
import tempfile
import threading
import time
import unittest
import urllib.request
import urllib.error
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))
sys.path.insert(0, os.path.dirname(__file__))

from ondevice_agent_platform import catalog
from ondevice_agent_platform.errors import ErrorCode, PlatformError
from ondevice_agent_platform.modelstore import ModelStore
from ondevice_agent_platform.profiles import (LocalConsumers, ModelKind,
                                              ModelProfile)
from ondevice_agent_platform.state import JobState
from ondevice_agent_platform.server import PlatformHTTPServer

from test_supervisor import FakeLLM, make_supervisor

ADMIN = LocalConsumers.ADMINISTRATION


def _wait_state(sup, job_id, states, timeout=5.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        job = sup.job_record(job_id)
        if job is not None and job.state in states:
            return job
        time.sleep(0.02)
    return sup.job_record(job_id)


class TestAdminLane(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.sup = make_supervisor(self.tmp.name)
        self.addCleanup(self.sup.shutdown)

    def test_submit_admin_runs_and_completes(self):
        seen = []
        job = self.sup.submit_admin(
            ADMIN, "task one",
            lambda token, progress: (progress(0.5), seen.append(1)))
        self.assertEqual(job.kind.value, "admin")
        done = _wait_state(self.sup, job.id, {JobState.COMPLETED})
        self.assertIsNotNone(done)
        self.assertEqual(done.state, JobState.COMPLETED)
        self.assertEqual(seen, [1])
        self.assertTrue(done.provider_finished)

    def test_admin_failure_records_failed(self):
        def boom(token, progress):
            raise PlatformError(ErrorCode.STORAGE_FAILURE, "nope")
        job = self.sup.submit_admin(ADMIN, "task fail", boom)
        done = _wait_state(self.sup, job.id, {JobState.FAILED})
        self.assertEqual(done.state, JobState.FAILED)

    def test_admin_dedup_by_detail(self):
        gate = threading.Event()
        self.sup.submit_admin(
            ADMIN, "task dup", lambda t, p: gate.wait(5))
        with self.assertRaises(PlatformError) as cm:
            self.sup.submit_admin(ADMIN, "task dup", lambda t, p: None)
        self.assertEqual(cm.exception.code, ErrorCode.CAPACITY_LIMITED)
        gate.set()

    def test_admin_cancel_resolves_cancelled(self):
        gate = threading.Event()

        def work(token, progress):
            while not token.is_cancelled and not gate.wait(0.01):
                pass
            if token.is_cancelled:
                raise PlatformError(ErrorCode.CANCELLED)

        job = self.sup.submit_admin(ADMIN, "task cancel", work)
        self.sup.cancel_job(ADMIN, job.id)
        done = _wait_state(self.sup, job.id, {JobState.CANCELLED})
        self.assertEqual(done.state, JobState.CANCELLED)

    def test_admin_progress_extras(self):
        gate = threading.Event()

        def work(token, progress):
            progress(0.42)
            gate.wait(5)

        job = self.sup.submit_admin(ADMIN, "task progress", work)
        deadline = time.time() + 5
        extras = {}
        while time.time() < deadline:
            extras = self.sup.admin_job_extras().get(job.id) or {}
            if extras.get("progress") == 0.42:
                break
            time.sleep(0.02)
        self.assertEqual(extras.get("detail"), "task progress")
        self.assertEqual(extras.get("progress"), 0.42)
        gate.set()
        _wait_state(self.sup, job.id,
                    {JobState.COMPLETED, JobState.FAILED})


def _declare_fake(sup, alias="fake-pull"):
    payload = {"schemaVersion": 1, "models": [{
        "alias": alias, "kind": "llm", "provider": "mlx",
        "task": "chat",
        "source": {"repo": "mlx-community/fake", "revision": "main"}}]}
    sup._root.write_json(payload, sup._root.registry_path)
    return payload


class TestPullDeclareRemove(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.sup = make_supervisor(self.tmp.name)
        self.addCleanup(self.sup.shutdown)

    def test_pull_model_unknown_alias(self):
        with self.assertRaises(PlatformError) as cm:
            self.sup.pull_model(ADMIN, "no-such")
        self.assertEqual(cm.exception.code, ErrorCode.NOT_FOUND)

    def test_pull_model_declared_runs_admin_job(self):
        _declare_fake(self.sup)
        calls = []

        def fake_pull(self, source, artifact_file=None, progress=None,
                      should_stop=None):
            calls.append((source.repo, should_stop))
            if progress:
                progress(1.0)
            return {"files": []}

        with mock.patch.object(ModelStore, "pull", fake_pull):
            job = self.sup.pull_model(ADMIN, "fake-pull")
        self.assertEqual(job.kind.value, "admin")
        done = _wait_state(self.sup, job.id, {JobState.COMPLETED})
        self.assertEqual(done.state, JobState.COMPLETED)
        self.assertEqual(calls[0][0], "mlx-community/fake")
        self.assertTrue(callable(calls[0][1]))

    def test_pull_model_abort_marks_cancelled(self):
        _declare_fake(self.sup)

        def fake_pull(self, source, artifact_file=None, progress=None,
                      should_stop=None):
            while not should_stop():
                time.sleep(0.01)
            raise PlatformError(ErrorCode.CANCELLED)

        with mock.patch.object(ModelStore, "pull", fake_pull):
            job = self.sup.pull_model(ADMIN, "fake-pull")
            self.sup.cancel_job(ADMIN, job.id)
            done = _wait_state(self.sup, job.id, {JobState.CANCELLED})
        self.assertEqual(done.state, JobState.CANCELLED)

    def test_pull_model_declares_catalog_alias_first(self):
        entry = catalog.ENTRIES[0]

        def fake_pull(self, source, artifact_file=None, progress=None,
                      should_stop=None):
            return {"files": []}

        with mock.patch.object(ModelStore, "pull", fake_pull):
            job = self.sup.pull_model(ADMIN, entry.alias)
            done = _wait_state(self.sup, job.id, {JobState.COMPLETED,
                                                  JobState.FAILED})
        self.assertEqual(done.state, JobState.COMPLETED)
        profile = self.sup._model_profiles.get(entry.alias)
        self.assertIsNotNone(profile)
        self.assertEqual(profile.source.repo, entry.source.repo)
        payload = self.sup._root.read_json(self.sup._root.registry_path)
        self.assertTrue(any(m["alias"] == entry.alias
                            for m in payload["models"]))

    def test_declare_catalog_model(self):
        entry = catalog.ENTRIES[0]
        profile = self.sup.declare_catalog_model(entry.alias)
        self.assertEqual(profile.alias, entry.alias)
        with self.assertRaises(PlatformError) as cm:
            self.sup.declare_catalog_model(entry.alias)
        self.assertEqual(cm.exception.code, ErrorCode.INVALID_REQUEST)

    def test_declare_unknown_alias(self):
        with self.assertRaises(PlatformError) as cm:
            self.sup.declare_catalog_model("ghost-model")
        self.assertEqual(cm.exception.code, ErrorCode.NOT_FOUND)

    def test_remove_model_artifacts(self):
        _declare_fake(self.sup)
        self.sup.remove_model_artifacts(ADMIN, "fake-pull")

    def test_remove_evicts_resident_container(self):
        # A removed alias must not keep serving from a resident
        # container: providers are asked to evict it.
        _declare_fake(self.sup)
        evicted = []

        class Evicting(FakeLLM):
            provider_id = "mlx"

            def evict_alias(self, alias):
                evicted.append(alias)
                return True

        self.sup.register_model(
            ModelProfile(alias="fake-pull", provider_id="mlx",
                         kind=ModelKind.LLM, task="chat"),
            provider=Evicting())
        self.sup.remove_model_artifacts(ADMIN, "fake-pull")
        self.assertEqual(evicted, ["fake-pull"])

    def test_remove_unknown_alias(self):
        with self.assertRaises(PlatformError) as cm:
            self.sup.remove_model_artifacts(ADMIN, "no-such")
        self.assertEqual(cm.exception.code, ErrorCode.NOT_FOUND)

    def test_remove_blocked_while_pulling(self):
        _declare_fake(self.sup)
        gate = threading.Event()

        def fake_pull(self, source, artifact_file=None, progress=None,
                      should_stop=None):
            gate.wait(5)
            return {"files": []}

        with mock.patch.object(ModelStore, "pull", fake_pull):
            job = self.sup.pull_model(ADMIN, "fake-pull")
            with self.assertRaises(PlatformError) as cm:
                self.sup.remove_model_artifacts(ADMIN, "fake-pull")
            self.assertEqual(cm.exception.code,
                             ErrorCode.CAPACITY_LIMITED)
            self.sup.cancel_job(ADMIN, job.id)
            _wait_state(self.sup, job.id, {JobState.CANCELLED})
            gate.set()

    def test_catalog_status_shape(self):
        status = self.sup.catalog_status()
        self.assertIn("providerEnvInstalled", status)
        self.assertIn("providerPinsReady", status)
        self.assertFalse(status["providerEnvInstalled"])
        self.assertFalse(status["providerPinsReady"])
        aliases = {e["alias"] for e in status["entries"]}
        for entry in catalog.ENTRIES:
            self.assertIn(entry.alias, aliases)
        for e in status["entries"]:
            self.assertIn(e["declared"], (True, False))
            self.assertIn(e["ready"], (True, False))

    def test_install_provider_env_admin_job(self):
        from ondevice_agent_platform import cli as platform_cli
        calls = []
        with mock.patch.object(platform_cli, "_ensure_provider_env",
                               lambda root, install_pins:
                               calls.append(install_pins)):
            self.sup._env_probe = (time.time(), False)
            job = self.sup.install_provider_env(ADMIN)
            done = _wait_state(self.sup, job.id, {JobState.COMPLETED,
                                                  JobState.FAILED})
        self.assertEqual(done.state, JobState.COMPLETED)
        self.assertEqual(calls, [True])
        self.assertIsNone(self.sup._env_probe)

    def test_install_provider_env_failure_marks_failed(self):
        from ondevice_agent_platform import cli as platform_cli

        def boom(root, install_pins):
            raise PlatformError(ErrorCode.STORAGE_FAILURE, "pip failed")

        with mock.patch.object(platform_cli, "_ensure_provider_env", boom):
            job = self.sup.install_provider_env(ADMIN)
            done = _wait_state(self.sup, job.id, {JobState.FAILED})
        self.assertEqual(done.state, JobState.FAILED)


class TestOperatorToggle(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.sup = make_supervisor(self.tmp.name)
        self.addCleanup(self.sup.shutdown)
        from ondevice_agent_platform.agents import AgentService
        service = AgentService()
        service.attach(self.sup)
        self.service = service
        self.sup.register_model(
            ModelProfile(alias="m", provider_id="fake-llm",
                         kind=ModelKind.LLM, task="chat",
                         max_output_tokens=64),
            provider=FakeLLM())
        self.sup.register_model(
            ModelProfile(alias="m2", provider_id="mlx",
                         kind=ModelKind.LLM, task="chat",
                         max_output_tokens=64),
            provider=FakeLLM())
        self.sup._llm_providers["mlx"] = FakeLLM()

    def test_set_operator_registers_and_persists(self):
        self.sup.set_operator("m2")
        profile = self.service.profile("operator")
        self.assertIsNotNone(profile)
        self.assertEqual(profile.model_profile_alias, "m2")
        config = self.sup._root.read_json(self.sup._root.config_path)
        self.assertTrue(config["enableOperator"])
        self.assertEqual(config["operatorModel"], "m2")

    def test_set_operator_unknown_alias(self):
        with self.assertRaises(PlatformError) as cm:
            self.sup.set_operator("ghost")
        self.assertEqual(cm.exception.code, ErrorCode.NOT_FOUND)

    def test_clear_operator_unregisters_and_clears(self):
        self.sup.set_operator("m2")
        self.sup.clear_operator()
        self.assertIsNone(self.service.profile("operator"))
        config = self.sup._root.read_json(self.sup._root.config_path)
        self.assertFalse(config["enableOperator"])
        self.assertNotIn("operatorModel", config)

    def test_operator_sessions_keep_bound_profile(self):
        self.sup.set_operator("m2")
        session = self.service.new_session("operator", "c", "conn")
        self.sup.clear_operator()
        self.assertEqual(session.profile.id, "operator")
        with self.assertRaises(PlatformError):
            self.service.new_session("operator", "c", "conn")


class TestAdminRoutes(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.sup = make_supervisor(self.tmp.name)
        self.addCleanup(self.sup.shutdown)
        from ondevice_agent_platform.agents import AgentService
        service = AgentService()
        service.attach(self.sup)
        self.sup.register_model(
            ModelProfile(alias="m2", provider_id="mlx",
                         kind=ModelKind.LLM, task="chat",
                         max_output_tokens=64),
            provider=FakeLLM())
        self.sup._llm_providers["mlx"] = FakeLLM()
        self.server = PlatformHTTPServer(self.sup, port=0)
        self.server.start()
        self.addCleanup(self.server.stop)
        self.base = f"http://127.0.0.1:{self.server.port}"
        self.csrf, self.cookie = self._session()

    def _req(self, path, method="GET", body=None, headers=None):
        h = {"Content-Type": "application/json",
             "Origin": self.base}
        h.update(headers or {})
        r = urllib.request.Request(
            self.base + path,
            data=json.dumps(body).encode() if body is not None else None,
            headers=h, method=method)
        try:
            return urllib.request.urlopen(r, timeout=10)
        except urllib.error.HTTPError as e:
            return e

    def _session(self):
        r = urllib.request.Request(self.base + "/api/session",
                                   data=b"", method="POST",
                                   headers={"Origin": self.base})
        resp = urllib.request.urlopen(r, timeout=10)
        body = json.loads(resp.read())
        cookie = resp.headers["Set-Cookie"].split(";")[0]
        return body["csrf"], cookie

    def _mutate(self, path, body):
        return self._req(path, "POST", body, headers={
            "Cookie": self.cookie, "X-CSRF-Token": self.csrf})

    def test_catalog_route(self):
        r = self._req("/api/catalog")
        self.assertEqual(r.status, 200)
        body = json.loads(r.read())
        self.assertIn("entries", body)
        self.assertIn("providerEnvInstalled", body)

    def test_pull_requires_session(self):
        r = self._req("/api/console/models/pull", "POST",
                      {"alias": "x"})
        self.assertEqual(r.status, 401)

    def test_pull_requires_csrf(self):
        r = self._req("/api/console/models/pull", "POST",
                      {"alias": "x"}, headers={"Cookie": self.cookie})
        self.assertEqual(r.status, 403)

    def test_pull_route_starts_admin_job(self):
        _declare_fake(self.sup)
        with mock.patch.object(ModelStore, "pull",
                               lambda *a, **k: {"files": []}):
            r = self._mutate("/api/console/models/pull",
                             {"alias": "fake-pull"})
        self.assertEqual(r.status, 200)
        body = json.loads(r.read())
        self.assertIn("jobId", body)
        done = _wait_state(self.sup, body["jobId"],
                           {JobState.COMPLETED, JobState.FAILED})
        self.assertEqual(done.state, JobState.COMPLETED)

    def test_remove_route(self):
        _declare_fake(self.sup)
        r = self._mutate("/api/console/models/remove",
                         {"alias": "fake-pull"})
        self.assertEqual(r.status, 200)

    def test_provider_install_route(self):
        from ondevice_agent_platform import cli as platform_cli
        with mock.patch.object(platform_cli, "_ensure_provider_env",
                               lambda root, install_pins: None):
            r = self._mutate("/api/console/provider/install", {})
        self.assertEqual(r.status, 200)
        body = json.loads(r.read())
        done = _wait_state(self.sup, body["jobId"],
                           {JobState.COMPLETED, JobState.FAILED})
        self.assertEqual(done.state, JobState.COMPLETED)

    def test_operator_enable_disable(self):
        r = self._mutate("/api/console/operator", {"model": "m2"})
        self.assertEqual(r.status, 200)
        self.assertTrue(json.loads(r.read())["enabled"])
        self.assertIsNotNone(self.server.router._bridge)
        r = self._mutate("/api/console/operator", {"enabled": False})
        self.assertEqual(r.status, 200)
        self.assertFalse(json.loads(r.read())["enabled"])
        self.assertIsNone(self.server.router._bridge)

    def test_operator_enable_unknown_model(self):
        r = self._mutate("/api/console/operator", {"model": "ghost"})
        self.assertEqual(r.status, 404)

    def test_jobs_route_merges_admin_extras(self):
        gate = threading.Event()

        def work(token, progress):
            progress(0.5)
            gate.wait(5)

        job = self.sup.submit_admin(ADMIN, "pull fake-pull", work)
        deadline = time.time() + 5
        body = {}
        while time.time() < deadline:
            r = self._req("/api/jobs")
            body = json.loads(r.read())
            row = next((j for j in body["jobs"]
                        if j["id"] == job.id), None)
            if row and row.get("progress") == 0.5:
                break
            time.sleep(0.02)
        row = next(j for j in body["jobs"] if j["id"] == job.id)
        self.assertEqual(row["kind"], "admin")
        self.assertEqual(row["detail"], "pull fake-pull")
        self.assertEqual(row["progress"], 0.5)
        gate.set()
        _wait_state(self.sup, job.id,
                    {JobState.COMPLETED, JobState.FAILED})

    def test_cancel_route_on_admin_job(self):
        def work(token, progress):
            while not token.is_cancelled:
                time.sleep(0.01)
            raise PlatformError(ErrorCode.CANCELLED)

        job = self.sup.submit_admin(ADMIN, "pull fake-pull", work)
        r = self._mutate(f"/api/jobs/{job.id}/cancel", None)
        self.assertEqual(r.status, 200)
        done = _wait_state(self.sup, job.id, {JobState.CANCELLED})
        self.assertEqual(done.state, JobState.CANCELLED)


if __name__ == "__main__":
    unittest.main()
