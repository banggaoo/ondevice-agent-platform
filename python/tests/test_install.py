"""Install/setup regression tests: env reuse and refusal rules, Python
>=3.11 probing, host-filtered pins, --source package install, PATH
linking, lock ordering, and first-run setup completion - all offline
with mocked subprocess/host; no pip or network is ever invoked."""
import argparse
import json
import os
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from pathlib import Path

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

from ondevice_agent_platform import catalog, cli
from ondevice_agent_platform.errors import ErrorCode, PlatformError
from ondevice_agent_platform.requirements import HostInfo
from ondevice_agent_platform.runtime_root import RuntimeRoot


def raises(code, fn, *a, **k):
    try:
        fn(*a, **k)
    except PlatformError as e:
        assert e.code == code, f"expected {code}, got {e.code}: {e}"
        return e
    raise AssertionError(f"expected PlatformError {code}")


class _Result:
    def __init__(self, returncode=0, stdout=""):
        self.returncode = returncode
        self.stdout = stdout


class _FakeRun:
    """subprocess.run dispatcher. The env probe answers with the frozen
    pin metadata unless a test overrides it; `calls`/`pip_calls` record
    every invocation."""

    def __init__(self):
        self.calls = []
        self.pip_calls = []
        self.version_ok = True             # candidate >=3.11 check
        self.probe_version = [3, 12]       # env interpreter version
        self.probe_prefix = None           # None -> derive from argv[0]
        self.probe_fails = False
        self.packages = {                  # env distributions, probed
            "vllm-mlx": "0.5.0",
            "mlx-lm": "0.32.0",
            "mlx-vlm": "0.7.6",
            "setuptools": "80.0.0",
        }
        self.pip_fails = False
        self.on_venv = None        # callable(env_dir)
        self.on_pip = None         # callable(env_py, args)

    def __call__(self, argv, *a, check=False, capture_output=False,
                 timeout=None, text=False, **kw):
        self.calls.append(list(argv))
        if "-m" in argv and "venv" in argv:
            env_dir = argv[argv.index("venv") + 1]
            os.makedirs(os.path.join(
                env_dir, "Scripts" if os.name == "nt" else "bin"),
                exist_ok=True)
            pyname = "python.exe" if os.name == "nt" else "python"
            with open(os.path.join(
                    env_dir,
                    "Scripts" if os.name == "nt" else "bin",
                    pyname), "w") as f:
                f.write("#!/bin/sh\n")
            with open(os.path.join(env_dir, "pyvenv.cfg"), "w") as f:
                f.write("home = /\n")
            if self.on_venv:
                self.on_venv(env_dir)
            return _Result(0)
        if "-c" in argv:
            code = argv[argv.index("-c") + 1]
            if "importlib.metadata" in code:
                if self.probe_fails:
                    return _Result(1, "probe failed")
                names = argv[argv.index("-c") + 2:]
                env_dir = os.path.dirname(os.path.dirname(argv[0]))
                return _Result(0, json.dumps({
                    "version": self.probe_version,
                    "prefix": self.probe_prefix or env_dir,
                    "packages": {n: self.packages.get(n)
                                 for n in names}}))
            if "version_info" in code:
                return _Result(0 if self.version_ok else 1)
            return _Result(0)
        if "-m" in argv and "pip" in argv:
            args = list(argv[argv.index("install") + 1:]) \
                if "install" in argv else list(argv)
            self.pip_calls.append(args)
            if self.on_pip:
                self.on_pip(argv[0], args)
            if self.pip_fails:
                if check:
                    raise subprocess.CalledProcessError(1, argv)
                return _Result(1)
            return _Result(0)
        return _Result(0)


def _make_root(tmp):
    root = RuntimeRoot(os.path.join(tmp, "rt"))
    root.prepare()
    return root


def _make_env(root):
    """A structurally valid managed env: bin/python + pyvenv.cfg."""
    env_dir = os.path.join(root.providers_path, cli._PROVIDER_ENV)
    bindir = os.path.join(env_dir,
                          "Scripts" if os.name == "nt" else "bin")
    os.makedirs(bindir)
    py = os.path.join(bindir,
                      "python.exe" if os.name == "nt" else "python")
    with open(py, "w") as f:
        f.write("#!/bin/sh\n")
    with open(os.path.join(env_dir, "pyvenv.cfg"), "w") as f:
        f.write("home = /\n")
    return env_dir, py


def _args(*argv):
    return cli.build_parser().parse_args(list(argv))


class TestEnsureEnv(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = _make_root(self.tmp.name)

    def test_valid_env_reused_no_pip(self):
        env_dir, _ = _make_env(self.root)
        marker = os.path.join(env_dir, "owner-marker")
        with open(marker, "w") as f:
            f.write("keep")
        fake = _FakeRun()      # probe answers all frozen pins present
        with mock.patch.object(cli.subprocess, "run", fake):
            env_py = cli._ensure_provider_env(
                self.root, install_pins=True)
        # Cheap metadata probing is intended; pip reuse is the promise.
        self.assertFalse(fake.pip_calls)
        self.assertTrue(os.path.isfile(marker))
        self.assertTrue(env_py.endswith(
            "python.exe" if os.name == "nt" else "python"))

    def test_wrong_pin_version_repaired_by_pip(self):
        _make_env(self.root)
        fake = _FakeRun()
        fake.packages["vllm-mlx"] = "0.4.9"

        def pip(env_py, args):
            for pin in args:
                name, _, ver = pin.partition("==")
                fake.packages[name] = ver

        fake.on_pip = pip
        with mock.patch.object(cli.subprocess, "run", fake):
            cli._ensure_provider_env(self.root, install_pins=True)
        self.assertIn(list(cli._PROVIDER_PINS), fake.pip_calls)

    def test_pins_missing_after_install_errors(self):
        env_dir, _ = _make_env(self.root)
        fake = _FakeRun()
        fake.packages = {}     # pip never actually fixes anything
        with mock.patch.object(cli.subprocess, "run", fake):
            e = raises(ErrorCode.STORAGE_FAILURE,
                       cli._ensure_provider_env, self.root,
                       install_pins=True)
        self.assertIn("vllm-mlx", e.detail or "")
        self.assertTrue(os.path.isdir(env_dir))   # never wiped

    def test_symlinked_env_refused_not_wiped(self):
        env_dir = os.path.join(self.root.providers_path,
                               cli._PROVIDER_ENV)
        target = os.path.join(self.tmp.name, "real-env")
        os.makedirs(target)
        os.makedirs(self.root.providers_path)
        os.symlink(target, env_dir)
        raises(ErrorCode.ROOT_UNSAFE,
               cli._ensure_provider_env, self.root)
        self.assertTrue(os.path.islink(env_dir))
        self.assertTrue(os.path.isdir(target))

    def test_non_venv_dir_refused_not_wiped(self):
        env_dir = os.path.join(self.root.providers_path,
                               cli._PROVIDER_ENV)
        os.makedirs(env_dir)
        with open(os.path.join(env_dir, "data.txt"), "w") as f:
            f.write("user data")
        raises(ErrorCode.ROOT_UNSAFE,
               cli._ensure_provider_env, self.root)
        self.assertTrue(os.path.isfile(os.path.join(env_dir,
                                                    "data.txt")))

    def test_fake_python_without_pyvenv_cfg_refused(self):
        env_dir = os.path.join(self.root.providers_path,
                               cli._PROVIDER_ENV)
        bindir = os.path.join(env_dir, "bin")
        os.makedirs(bindir)
        wrapper = os.path.join(bindir, "python")
        with open(wrapper, "w") as f:
            f.write("#!/bin/sh\n")
        raises(ErrorCode.ROOT_UNSAFE,
               cli._ensure_provider_env, self.root)
        self.assertTrue(os.path.isfile(wrapper))   # preserved

    def test_env_old_interpreter_refused(self):
        env_dir, _ = _make_env(self.root)
        fake = _FakeRun()
        fake.probe_version = [3, 10]
        with mock.patch.object(cli.subprocess, "run", fake):
            e = raises(ErrorCode.ROOT_UNSAFE,
                       cli._ensure_provider_env, self.root)
        self.assertIn("3.11", e.detail or "")
        self.assertTrue(os.path.isdir(env_dir))

    def test_env_prefix_mismatch_refused(self):
        _make_env(self.root)
        fake = _FakeRun()
        fake.probe_prefix = "/some/other/prefix"
        with mock.patch.object(cli.subprocess, "run", fake):
            raises(ErrorCode.ROOT_UNSAFE,
                   cli._ensure_provider_env, self.root)

    def test_env_unusable_interpreter_refused(self):
        _make_env(self.root)
        fake = _FakeRun()
        fake.probe_fails = True
        with mock.patch.object(cli.subprocess, "run", fake):
            raises(ErrorCode.ROOT_UNSAFE,
                   cli._ensure_provider_env, self.root)

    def test_missing_deps_installs_pins(self):
        _make_env(self.root)
        fake = _FakeRun()
        fake.packages = {}

        def pip(env_py, args):
            for pin in args:
                name, _, ver = pin.partition("==")
                fake.packages[name] = ver

        fake.on_pip = pip
        with mock.patch.object(cli.subprocess, "run", fake):
            cli._ensure_provider_env(self.root, install_pins=True)
        self.assertIn(list(cli._PROVIDER_PINS), fake.pip_calls)

    def test_fresh_env_creation_installs_pins_on_metal(self):
        fake = _FakeRun()
        fake.packages = {}

        def pip(env_py, args):
            for pin in args:
                name, _, ver = pin.partition("==")
                fake.packages[name] = ver

        fake.on_pip = pip
        with mock.patch.object(cli.subprocess, "run", fake), \
                mock.patch.object(cli, "_provider_env_candidates",
                                  return_value=["/fake/python3.12"]):
            cli._ensure_provider_env(self.root, install_pins=True)
        self.assertTrue(any("venv" in c for c in fake.calls))
        self.assertIn(list(cli._PROVIDER_PINS), fake.pip_calls)

    def test_fresh_env_skips_pins_off_metal(self):
        fake = _FakeRun()
        with mock.patch.object(cli.subprocess, "run", fake), \
                mock.patch.object(cli, "_provider_env_candidates",
                                  return_value=["/fake/python3.12"]):
            cli._ensure_provider_env(self.root, install_pins=False)
        # No pip dependency install at all.
        self.assertFalse(fake.pip_calls)

    def test_python_310_candidate_rejected(self):
        fake = _FakeRun()
        fake.version_ok = False
        with mock.patch.object(cli.subprocess, "run", fake), \
                mock.patch.object(cli, "_provider_env_candidates",
                                  return_value=["/fake/python3.10"]):
            e = raises(ErrorCode.INVALID_REQUEST,
                       cli._ensure_provider_env, self.root)
        self.assertIn("3.11", e.detail or "")

    def test_pip_failure_is_platform_error(self):
        fake = _FakeRun()
        fake.packages = {}
        fake.pip_fails = True
        with mock.patch.object(cli.subprocess, "run", fake), \
                mock.patch.object(cli, "_provider_env_candidates",
                                  return_value=["/fake/python3.12"]):
            raises(ErrorCode.STORAGE_FAILURE,
                   cli._ensure_provider_env, self.root,
                   install_pins=True)


class TestReexecDecision(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = _make_root(self.tmp.name)

    def test_no_env_no_reexec(self):
        self.assertFalse(cli._needs_provider_reexec(self.root))

    def test_env_same_prefix_no_reexec(self):
        env_dir, _ = _make_env(self.root)
        with mock.patch.object(sys, "prefix", env_dir):
            self.assertFalse(cli._needs_provider_reexec(self.root))

    def test_same_base_python_different_prefix_reexecs(self):
        # The regression: env python realpath resolves to the same base
        # binary as sys.executable - the old check compared realpaths of
        # interpreters and skipped a needed reexec. sys.prefix is what
        # differs.
        env_dir, _ = _make_env(self.root)
        with mock.patch.object(sys, "prefix", "/some/base/python"):
            self.assertTrue(cli._needs_provider_reexec(self.root))

    def test_guard_blocks_reexec(self):
        _make_env(self.root)
        with mock.patch.object(sys, "prefix", "/elsewhere"), \
                mock.patch.dict(os.environ,
                                {cli._REEXEC_GUARD: "1"}):
            self.assertFalse(cli._needs_provider_reexec(self.root))


class TestLinkExecutable(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = _make_root(self.tmp.name)
        self.home = os.path.join(self.tmp.name, "home")
        os.makedirs(self.home)
        env_dir, _ = _make_env(self.root)
        bindir = os.path.join(env_dir, "bin")
        with open(os.path.join(bindir, "ondevice-agent-platform"),
                  "w") as f:
            f.write("#!/bin/sh\n")
        self._home_patch = mock.patch.dict(
            os.environ, {"HOME": self.home})
        self._home_patch.start()
        self.addCleanup(self._home_patch.stop)

    @unittest.skipIf(os.name == "nt", "posix link semantics")
    def test_link_into_local_bin(self):
        link = cli._link_executable(self.root, "ondevice-agent-platform")
        self.assertEqual(link, os.path.join(
            self.home, ".local", "bin", "ondevice-agent-platform"))
        self.assertTrue(os.path.islink(link))

    @unittest.skipIf(os.name == "nt", "posix link semantics")
    def test_link_idempotent(self):
        first = cli._link_executable(self.root, "ondevice-agent-platform")
        second = cli._link_executable(self.root, "ondevice-agent-platform")
        self.assertEqual(first, second)

    @unittest.skipIf(os.name == "nt", "posix link semantics")
    def test_unrelated_executable_preserved(self):
        target = os.path.join(self.home, ".local", "bin")
        os.makedirs(target)
        other = os.path.join(target, "ondevice-agent-platform")
        with open(other, "w") as f:
            f.write("not ours")
        raises(ErrorCode.INVALID_REQUEST,
               cli._link_executable, self.root, "ondevice-agent-platform")
        with open(other) as f:
            self.assertEqual(f.read(), "not ours")

    @unittest.skipIf(os.name == "nt", "posix link semantics")
    def test_foreign_symlink_refused(self):
        target = os.path.join(self.home, ".local", "bin")
        os.makedirs(target)
        other = os.path.join(self.tmp.name, "elsewhere")
        with open(other, "w") as f:
            f.write("x")
        os.symlink(other, os.path.join(target, "ondevice-agent-platform"))
        raises(ErrorCode.INVALID_REQUEST,
               cli._link_executable, self.root, "ondevice-agent-platform")


class TestCmdInstall(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = _make_root(self.tmp.name)

    def _source(self):
        src = os.path.join(self.tmp.name, "repo-python")
        os.makedirs(src)
        with open(os.path.join(src, "pyproject.toml"), "w") as f:
            f.write("[build-system]\n"
                    'requires = ["setuptools>=68"]\n'
                    "build-backend = 'setuptools.build_meta'\n"
                    "[project]\nname='x'\n")
        return src

    def _add_script(self, env_dir):
        bindir = os.path.join(env_dir,
                              "Scripts" if os.name == "nt" else "bin")
        with open(os.path.join(bindir, "ondevice-agent-platform"),
                  "w") as f:
            f.write("#!/bin/sh\n")

    def test_missing_source_fails_before_env(self):
        args = _args("install", "--data-root", self.root.path)
        with mock.patch.object(cli, "_repo_python_dir",
                               return_value=None):
            e = raises(ErrorCode.INVALID_REQUEST,
                       cli.cmd_install, args)
        self.assertIn("--source", e.detail or "")
        self.assertFalse(os.path.exists(
            os.path.join(self.root.providers_path, cli._PROVIDER_ENV)))

    def test_install_refused_while_locked(self):
        self.root.acquire_lock()
        try:
            args = _args("install", "--data-root", self.root.path)
            raises(ErrorCode.CONFLICT, cli.cmd_install, args)
        finally:
            self.root.release_lock()

    def test_locked_second_root_refused(self):
        self.root.acquire_lock()
        try:
            other = RuntimeRoot(self.root.path)
            args = _args("install", "--data-root", self.root.path)
            with mock.patch.object(cli, "_root_for",
                                   return_value=other):
                raises(ErrorCode.CONFLICT, cli.cmd_install, args)
        finally:
            self.root.release_lock()

    def test_install_with_source_and_links(self):
        _make_env(self.root)
        src = self._source()
        fake = _FakeRun()

        def pip(env_py, args):
            if src in args:
                bindir = os.path.dirname(env_py)
                with open(os.path.join(
                        bindir, "ondevice-agent-platform"), "w") as f:
                    f.write("#!/bin/sh\n")

        fake.on_pip = pip
        home = os.path.join(self.tmp.name, "home")
        args = _args("install", "--data-root", self.root.path,
                     "--source", src)
        with mock.patch.object(cli.subprocess, "run", fake), \
                mock.patch.object(cli, "_host_supports_mlx",
                                  return_value=True), \
                mock.patch.dict(os.environ,
                                {"HOME": home, "PATH": "/usr/bin"}):
            out = []
            with mock.patch("builtins.print", lambda *a, **k:
                            out.append(" ".join(str(x) for x in a))):
                self.assertEqual(cli.cmd_install(args), 0)
        # --no-deps --no-build-isolation package install, not editable.
        self.assertIn(["--no-deps", "--no-build-isolation", src],
                      fake.pip_calls)
        if os.name != "nt":
            link = os.path.join(home, ".local", "bin",
                                "ondevice-agent-platform")
            self.assertTrue(os.path.islink(link))
            self.assertTrue(any("not on PATH" in line
                                for line in out))

    def test_empty_registry_install_skips_mlx_pip(self):
        # 'install only what is needed': no declared MLX routes means
        # the managed stack pins are not pip-installed even on Metal.
        _make_env(self.root)
        src = self._source()
        fake = _FakeRun()

        def pip(env_py, args):
            if src in args:
                bindir = os.path.dirname(env_py)
                with open(os.path.join(
                        bindir, "ondevice-agent-platform"), "w") as f:
                    f.write("#!/bin/sh\n")

        fake.on_pip = pip
        args = _args("install", "--data-root", self.root.path,
                     "--source", src)
        with mock.patch.object(cli.subprocess, "run", fake), \
                mock.patch.object(cli, "_host_supports_mlx",
                                  return_value=True), \
                mock.patch.dict(os.environ,
                                {"HOME": self.tmp.name,
                                 "PATH": "/usr/bin"}):
            with mock.patch("builtins.print"):
                self.assertEqual(cli.cmd_install(args), 0)
        self.assertNotIn(list(cli._PROVIDER_PINS), fake.pip_calls)

    def test_mlx_registry_install_provisions_pins(self):
        _make_env(self.root)
        merged = catalog.merged_registry(
            None, [catalog.entry("qwen3.8-9b")])
        self.root.write_json(merged, self.root.registry_path)
        src = self._source()
        fake = _FakeRun()
        fake.packages = {"setuptools": "80.0.0"}

        def pip(env_py, args):
            for pin in args:
                name, _, ver = pin.partition("==")
                if ver:
                    fake.packages[name] = ver
            if src in args:
                bindir = os.path.dirname(env_py)
                with open(os.path.join(
                        bindir, "ondevice-agent-platform"), "w") as f:
                    f.write("#!/bin/sh\n")

        fake.on_pip = pip
        args = _args("install", "--data-root", self.root.path,
                     "--source", src)
        with mock.patch.object(cli.subprocess, "run", fake), \
                mock.patch.object(cli, "_host_supports_mlx",
                                  return_value=True), \
                mock.patch.dict(os.environ,
                                {"HOME": self.tmp.name,
                                 "PATH": "/usr/bin"}):
            with mock.patch("builtins.print"):
                self.assertEqual(cli.cmd_install(args), 0)
        self.assertIn(list(cli._PROVIDER_PINS), fake.pip_calls)

    def test_existing_script_plus_source_still_reinstalls(self):
        # The regression: an installed console script used to swallow
        # --source silently. Source present -> the package pip step
        # always runs (that is how updates land).
        env_dir, _ = _make_env(self.root)
        self._add_script(env_dir)
        src = self._source()
        fake = _FakeRun()
        args = _args("install", "--data-root", self.root.path,
                     "--source", src)
        with mock.patch.object(cli.subprocess, "run", fake), \
                mock.patch.object(cli, "_host_supports_mlx",
                                  return_value=False), \
                mock.patch.dict(os.environ,
                                {"HOME": self.tmp.name,
                                 "PATH": "/usr/bin"}):
            with mock.patch("builtins.print"):
                self.assertEqual(cli.cmd_install(args), 0)
        self.assertIn(["--no-deps", "--no-build-isolation", src],
                      fake.pip_calls)

    def test_existing_script_plus_invalid_source_refused(self):
        # An explicit --source that is not a package dir must fail
        # before env work even when a console script already exists.
        env_dir, _ = _make_env(self.root)
        self._add_script(env_dir)
        args = _args("install", "--data-root", self.root.path,
                     "--source", os.path.join(self.tmp.name,
                                              "does-not-exist"))
        ensured = []
        with mock.patch.object(
                cli, "_ensure_provider_env",
                lambda *a, **k: ensured.append(1)):
            e = raises(ErrorCode.INVALID_REQUEST, cli.cmd_install, args)
        self.assertIn("--source", e.detail or "")
        self.assertEqual(ensured, [])

    def test_missing_build_prereqs_fail_actionably(self):
        _make_env(self.root)
        src = self._source()
        fake = _FakeRun()
        fake.packages = {"vllm-mlx": "0.5.0", "mlx-lm": "0.32.0",
                         "mlx-vlm": "0.7.6"}   # no setuptools
        args = _args("install", "--data-root", self.root.path,
                     "--source", src)
        with mock.patch.object(cli.subprocess, "run", fake), \
                mock.patch.object(cli, "_host_supports_mlx",
                                  return_value=False):
            e = raises(ErrorCode.STORAGE_FAILURE, cli.cmd_install, args)
        self.assertIn("setuptools", e.detail or "")
        # It tried to provision the declared spec, not invent one.
        self.assertIn(["setuptools>=68"], fake.pip_calls)

    def test_existing_install_idempotent_no_source_needed(self):
        env_dir, _ = _make_env(self.root)
        self._add_script(env_dir)
        args = _args("install", "--data-root", self.root.path)
        home = os.path.join(self.tmp.name, "home")
        fake = _FakeRun()
        with mock.patch.object(cli.subprocess, "run", fake), \
                mock.patch.object(cli, "_host_supports_mlx",
                                  return_value=True), \
                mock.patch.object(cli, "_repo_python_dir",
                                  return_value=None), \
                mock.patch.dict(os.environ, {"HOME": home,
                                             "PATH": "/usr/bin"}):
            with mock.patch("builtins.print"):
                self.assertEqual(cli.cmd_install(args), 0)
        # Env probing is intended; only the pip steps must not run.
        self.assertFalse(fake.pip_calls)


class TestProviderMissing(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = _make_root(self.tmp.name)

    def _host(self, osname="linux", arch="x86_64", metal=False):
        return HostInfo(os=osname, arch=arch, has_metal=metal,
                        total_memory=8_000_000_000)

    def test_unsupported_host_reports_metal_requirement(self):
        with mock.patch("ondevice_agent_platform.requirements.host_info",
                        return_value=self._host("linux")):
            missing = cli._provider_missing(self.root)
        self.assertIn("requires Metal", missing["mlx"])
        self.assertIn("requires Metal", missing["vllm-mlx"])

    def test_env_exists_but_deps_absent(self):
        _make_env(self.root)
        fake = _FakeRun()
        fake.packages = {}
        with mock.patch("ondevice_agent_platform.requirements.host_info",
                        return_value=self._host("macos", "arm64", True)), \
                mock.patch.object(cli.subprocess, "run", fake):
            missing = cli._provider_missing(self.root)
        self.assertIn("mlx-lm", missing.get("mlx", ""))


class TestFinishSetupProviderOffer(unittest.TestCase):
    """A base core env must not suppress the provider-runtime offer for
    selected MLX/vllm models; install runs only on an explicit y."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = _make_root(self.tmp.name)
        # Skip the operator prompt so the answer stream is deterministic.
        self.root.write_json({"enableOperator": False},
                             self.root.config_path)

    def _selection(self):
        return [catalog.entry("qwen3.8-9b")]

    def test_base_env_still_offers_provider_install(self):
        _make_env(self.root)     # core env exists - offer must appear
        ensure_calls = []

        def ensure(root, install_pins=None):
            ensure_calls.append(install_pins)

        answers = iter(["y", "n"])   # install env? -> y; pull? -> n
        with mock.patch.object(cli, "_provider_missing",
                               return_value={"mlx": "python: mlx-lm"}), \
                mock.patch.object(cli, "_host_supports_mlx",
                                  return_value=True), \
                mock.patch.object(cli, "_ensure_provider_env", ensure):
            cli._finish_setup(self.root, self._selection(), pull=False,
                              interactive=True,
                              input_fn=lambda _p: next(answers))
        self.assertEqual(ensure_calls, [True])

    def test_declined_offer_does_not_install(self):
        ensure_calls = []
        answers = iter(["n", "n"])
        with mock.patch.object(cli, "_provider_missing",
                               return_value={"mlx": "python: mlx-lm"}), \
                mock.patch.object(cli, "_host_supports_mlx",
                                  return_value=True), \
                mock.patch.object(
                    cli, "_ensure_provider_env",
                    lambda root, install_pins=None:
                        ensure_calls.append(install_pins)):
            cli._finish_setup(self.root, self._selection(), pull=False,
                              interactive=True,
                              input_fn=lambda _p: next(answers))
        self.assertEqual(ensure_calls, [])


class TestFirstRunSetup(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = _make_root(self.tmp.name)

    def _tty(self):
        stdin = mock.Mock()
        stdin.isatty.return_value = True
        return mock.patch.object(sys, "stdin", stdin)

    def test_intentional_none_writes_setup_completed(self):
        answers = iter(["none", "n"])

        def input_fn(prompt):
            return next(answers)

        with self._tty():
            cli._first_run_setup(self.root, input_fn=input_fn)
        config = self.root.read_json(self.root.config_path)
        self.assertTrue(config.get("setupCompleted"))
        self.assertFalse(config.get("enableOperator"))

    def test_settled_setup_never_reprompts(self):
        self.root.write_json({"setupCompleted": True},
                             self.root.config_path)

        def boom(_p):
            raise AssertionError("must not prompt")

        with self._tty():
            cli._first_run_setup(self.root, input_fn=boom)

    def test_operator_answer_applies_same_launch(self):
        # Guided "y" then config application must turn the operator on
        # for this serve invocation, not a later one.
        answers = iter(["none", "y"])
        with self._tty():
            cli._first_run_setup(
                self.root, input_fn=lambda _p: next(answers))
        args = argparse.Namespace(enable_apple_model=False,
                                  enable_operator=False,
                                  operator_model=None)
        cli._apply_serve_config(args,
                                cli._read_config(self.root))
        from ondevice_agent_platform.requirements import host_info
        if host_info().os == "macos":
            self.assertTrue(args.enable_operator)
            self.assertTrue(args.enable_apple_model)

    def test_explicit_flag_beats_config_after_prompts(self):
        self.root.write_json({"setupCompleted": True,
                              "enableOperator": False},
                             self.root.config_path)
        args = argparse.Namespace(enable_apple_model=False,
                                  enable_operator=True,
                                  operator_model="explicit-m")
        cli._apply_serve_config(args,
                                cli._read_config(self.root))
        self.assertTrue(args.enable_operator)
        self.assertEqual(args.operator_model, "explicit-m")


class TestLaunchers(unittest.TestCase):
    """Static checks only - Windows host behavior is unverified."""

    def test_cmd_launcher_probes_py_versions(self):
        here = os.path.dirname(os.path.abspath(__file__))
        cmd = os.path.join(here, "..", "..", "bin",
                           "ondevice-agent-platform.cmd")
        with open(cmd) as f:
            text = f.read()
        # py -3.11 alone falsely rejects a host whose only newer
        # interpreter is 3.12/3.13: probe each tag plus py -3.
        for probe in ("py -3.13", "py -3.12", "py -3.11", "py -3 ",
                      "python"):
            self.assertIn(probe, text)
        self.assertIn("(3,11)", text)   # real version check


class TestAtomicWrites(unittest.TestCase):
    def test_interrupted_write_preserves_old_bytes(self):
        with tempfile.TemporaryDirectory() as d:
            root = _make_root(d)
            path = root.config_path
            root.write_json({"a": 1}, path)
            original = Path(path).read_bytes()
            from ondevice_agent_platform import compat
            real_replace = compat.os.replace

            def boom(*a, **k):
                raise OSError("simulated crash before replace")

            with mock.patch.object(compat.os, "replace", boom):
                with self.assertRaises(OSError):
                    root.write_json({"a": 2}, path)
            self.assertEqual(Path(path).read_bytes(), original)
            # Only the staged temp file may be cleaned up - and it is.
            self.assertNotIn(".oap-write-",
                             " ".join(os.listdir(root.path)))

    def test_symlink_target_refused(self):
        with tempfile.TemporaryDirectory() as d:
            root = _make_root(d)
            target = os.path.join(d, "victim.json")
            with open(target, "w") as f:
                f.write('{"precious": true}')
            os.symlink(target, root.config_path)
            raises(ErrorCode.ROOT_UNSAFE,
                   root.write_json, {"a": 1}, root.config_path)
            with open(target) as f:
                self.assertEqual(json.load(f), {"precious": True})

    def test_nonregular_target_refused(self):
        with tempfile.TemporaryDirectory() as d:
            root = _make_root(d)
            os.mkdir(root.config_path)
            raises(ErrorCode.ROOT_UNSAFE,
                   root.write_json, {"a": 1}, root.config_path)

    def test_foreign_owned_refused(self):
        with tempfile.TemporaryDirectory() as d:
            root = _make_root(d)
            root.write_json({"a": 1}, root.config_path)
            original = Path(root.config_path).read_bytes()
            from ondevice_agent_platform import compat
            if not compat.IS_POSIX:
                self.skipTest("uid check is POSIX-only")
            with mock.patch.object(compat.os, "getuid",
                                   return_value=-1):
                raises(ErrorCode.ROOT_UNSAFE,
                       root.write_json, {"a": 2}, root.config_path)
            self.assertEqual(Path(root.config_path).read_bytes(),
                             original)


if __name__ == "__main__":
    unittest.main()
