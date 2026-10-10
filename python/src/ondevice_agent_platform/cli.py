"""CLI entry point, mirroring PlatformCLI: serve / model pull|list|remove /
setup / acp. Stdlib argparse; no shell scripts."""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import threading
import webbrowser

from . import catalog
from .acp_facade import run_stdio_facade
from .acp_service import ACPService
from .agents import AgentService
from .console_bridge import ConsoleOperatorBridge
from .console_sessions import ConsoleSessions
from .errors import ErrorCode, PlatformError
from .modelstore import ModelStore
from .profiles import ModelKind, ModelProfile, ModelSource
from .providers.linear import LinearPredictor
from .registry import (APPLE_PROVIDER_ID, LINEAR_PROVIDER_ID,
                       LLAMACPP_PROVIDER_ID, MLX_PROVIDER_ID,
                       VLLMMLX_PROVIDER_ID, VISIONHYBRID_PROVIDER_ID,
                       parse_registry)
from .runtime_root import RuntimeRoot
from .server import PlatformHTTPServer
from .supervisor import PlatformSupervisor

# One managed venv under <root>/providers/oap-env owns the platform's
# provider dependencies: vllm-mlx's server binary resolves there without
# env vars, and `serve` re-execs under its interpreter so the in-process
# mlx-lm/mlx-vlm providers import. Everything pinned - same governed-pull
# posture as model artifacts.
_PROVIDER_ENV = "oap-env"
_PROVIDER_PINS = ("vllm-mlx==0.5.0", "mlx-lm==0.32.0", "mlx-vlm==0.7.6")
_PROVIDER_DISTS = ("vllm-mlx", "mlx-lm", "mlx-vlm")
_MIN_PYTHON = (3, 11)
_REEXEC_GUARD = "OAP_PROVIDER_ENV"


def _eprint(*args) -> None:
    print(*args, file=sys.stderr)


def _root_for(args) -> RuntimeRoot:
    root = (RuntimeRoot(args.data_root) if getattr(args, "data_root", None)
            else RuntimeRoot.default())
    return root


# -- serve ---------------------------------------------------------------------


def _build_supervisor(root: RuntimeRoot, args):
    """Load the registry, wire providers + supervisor. Returns
    (supervisor, store, providers-by-id)."""
    store = ModelStore(root)
    supervisor = PlatformSupervisor(root, _default_resource_source())

    registry_payload = {}
    if os.path.isfile(root.registry_path):
        registry_payload = root.read_json(root.registry_path)
    entries = parse_registry(registry_payload) if registry_payload else []

    providers: dict[str, object] = {}
    artifact_files: dict[str, str] = {}
    for entry in entries:
        profile = entry.profile
        provider = None
        predictor = None
        if profile.kind == ModelKind.ML \
                and profile.provider_id == LINEAR_PROVIDER_ID:
            predictor = LinearPredictor(entry.linear)
        elif profile.provider_id == MLX_PROVIDER_ID:
            from .providers.mlx_provider import MLXProvider
            providers.setdefault(MLX_PROVIDER_ID, MLXProvider(store))
            provider = providers[MLX_PROVIDER_ID]
        elif profile.provider_id == VLLMMLX_PROVIDER_ID:
            from .providers.vllmmlx import VllmMlxProvider
            providers.setdefault(VLLMMLX_PROVIDER_ID, VllmMlxProvider(
                store, providers_dir=root.providers_path))
            provider = providers[VLLMMLX_PROVIDER_ID]
        elif profile.provider_id == VISIONHYBRID_PROVIDER_ID:
            from .providers.vision_hybrid import VisionHybridProvider
            providers.setdefault(VISIONHYBRID_PROVIDER_ID,
                                 VisionHybridProvider(
                                     providers_dir=root.providers_path))
            provider = providers[VISIONHYBRID_PROVIDER_ID]
        elif profile.provider_id == LLAMACPP_PROVIDER_ID:
            if entry.artifact_file:
                artifact_files[profile.alias] = entry.artifact_file
        supervisor.register_model(profile, provider=provider,
                                  predictor=predictor)

    if artifact_files or any(e.profile.provider_id == LLAMACPP_PROVIDER_ID
                             for e in entries):
        from .providers.llamacpp import LlamaCppProvider
        provider = LlamaCppProvider(store, artifact_files=artifact_files,
                                  providers_dir=root.providers_path)
        providers[LLAMACPP_PROVIDER_ID] = provider
        for entry in entries:
            if entry.profile.provider_id == LLAMACPP_PROVIDER_ID:
                supervisor.register_model(entry.profile, provider=provider)

    if getattr(args, "enable_apple_model", False):
        from .providers.apple import AppleFoundationProvider
        apple = AppleFoundationProvider(providers_dir=root.providers_path)
        providers[APPLE_PROVIDER_ID] = apple
        supervisor.register_model(ModelProfile(
            alias="apple-foundation-model", provider_id=APPLE_PROVIDER_ID,
            kind=ModelKind.LLM, task="chat", capabilities=("text",),
            max_output_tokens=8192), provider=apple)

    # Composite routes bind their delegate after all providers exist.
    hybrid = providers.get(VISIONHYBRID_PROVIDER_ID)
    if hybrid is not None:
        by_alias = {e.profile.alias: e for e in entries}
        for e in entries:
            if e.profile.provider_id != VISIONHYBRID_PROVIDER_ID:
                continue
            target = by_alias.get(e.delegate or "")
            dep = (providers.get(target.profile.provider_id)
                   if target is not None else None)
            if target is None or dep is None \
                    or target.profile.provider_id == VISIONHYBRID_PROVIDER_ID:
                raise PlatformError(
                    ErrorCode.INVALID_REQUEST,
                    f"vision-hybrid delegate not declared: {e.delegate}")
            hybrid.bind(e.profile.alias, dep, target.profile)

    # Readiness surfaces: providers see the LLM profiles they may serve.
    llm_profiles = [e.profile for e in entries
                    if e.profile.kind == ModelKind.LLM]
    for provider in providers.values():
        track = getattr(provider, "track_profiles", None)
        if callable(track):
            track(llm_profiles)

    return supervisor, store, providers


def _default_resource_source():
    from .resources import PollingResourceSource
    return PollingResourceSource()


def _provider_env_python(root: RuntimeRoot) -> str | None:
    name = "Scripts/python.exe" if os.name == "nt" else "bin/python"
    path = os.path.join(root.providers_path, _PROVIDER_ENV, name)
    return path if os.path.isfile(path) else None


def _host_supports_mlx() -> bool:
    from .requirements import host_info
    return host_info().has_metal


def _env_python_path(env_dir: str) -> str | None:
    name = "Scripts/python.exe" if os.name == "nt" else "bin/python"
    path = os.path.join(env_dir, name)
    return path if os.path.isfile(path) else None


def _env_structural_check(env_dir: str) -> str:
    """Validate an existing env directory's shape and ownership: real
    pyvenv.cfg (regular, non-symlink, owned) plus an interpreter. Raises
    ROOT_UNSAFE on anything else - refuse, never wipe."""
    import stat
    cfg = os.path.join(env_dir, "pyvenv.cfg")
    try:
        st = os.lstat(cfg)
    except OSError:
        raise PlatformError(
            ErrorCode.ROOT_UNSAFE,
            f"{env_dir} is not a managed python env - move it aside or "
            "re-run `provider install` on a clean providers dir")
    if not stat.S_ISREG(st.st_mode):
        raise PlatformError(ErrorCode.ROOT_UNSAFE,
                            "pyvenv.cfg is not a regular file")
    if os.name == "posix" and st.st_uid != os.getuid():
        raise PlatformError(ErrorCode.ROOT_UNSAFE,
                            "pyvenv.cfg not owned by this user")
    env_py = _env_python_path(env_dir)
    if env_py is None:
        raise PlatformError(ErrorCode.ROOT_UNSAFE,
                            "provider env has no interpreter")
    return env_py


def _probe_provider_env(env_py: str, names=None) -> dict | None:
    """Ask the env interpreter itself for version, sys.prefix, and
    installed distribution versions - importlib.metadata only, no
    package imports. None means the interpreter is not usable."""
    names = list(names) if names is not None \
        else list(_PROVIDER_DISTS) + ["setuptools"]
    script = (
        "import json,sys;"
        "import importlib.metadata as M;"
        "names=sys.argv[1:];"
        "have={d.metadata.get('Name','').lower():d.version "
        "for d in M.distributions()};"
        "print(json.dumps({'version':list(sys.version_info[:2]),"
        "'prefix':sys.prefix,"
        "'packages':{n:have.get(n.lower()) for n in names}}))")
    try:
        proc = subprocess.run(
            [env_py, "-c", script, *names],
            capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode != 0:
        return None
    try:
        data = json.loads(proc.stdout.strip())
    except json.JSONDecodeError:
        return None
    return data if isinstance(data, dict) else None


def _validate_env_interpreter(env_py: str, env_dir: str,
                              probe: dict | None) -> None:
    """The interpreter must be a real >=3.11 whose sys.prefix IS the env
    dir - a shell wrapper or foreign python fails."""
    if probe is None:
        raise PlatformError(ErrorCode.ROOT_UNSAFE,
                            "provider env interpreter is not usable")
    version = probe.get("version")
    if (not isinstance(version, list) or len(version) < 2
            or tuple(version[:2]) < _MIN_PYTHON):
        raise PlatformError(
            ErrorCode.ROOT_UNSAFE,
            f"provider env interpreter is too old "
            f"(needs Python >={_MIN_PYTHON[0]}.{_MIN_PYTHON[1]})")
    prefix = probe.get("prefix")
    if not isinstance(prefix, str) or os.path.normcase(
            os.path.realpath(prefix)) != os.path.normcase(
            os.path.realpath(env_dir)):
        raise PlatformError(ErrorCode.ROOT_UNSAFE,
                            "provider env interpreter prefix mismatch")


def _missing_pins(packages: dict) -> list[str]:
    """Pinned dists absent or at the wrong version. Exact pins only."""
    missing = []
    for pin in _PROVIDER_PINS:
        name, _, want = pin.partition("==")
        if packages.get(name) != want:
            missing.append(pin)
    return missing


def _provider_missing(root: RuntimeRoot) -> dict[str, str]:
    """provider_id -> missing prerequisite, for status and setup offers."""
    out: dict[str, str] = {}
    pd = root.providers_path
    from .providers.vllmmlx import _server_binary as _vllm
    from .providers.llamacpp import _server_binary as _llama
    from .providers.apple import _bridge_binary
    if _host_supports_mlx():
        if _vllm(pd) is None:
            out[VLLMMLX_PROVIDER_ID] = "vllm-mlx"
        env_py = _provider_env_python(root)
        if env_py is not None:
            # An env directory alone proves nothing; dists are probed in
            # the env interpreter itself, never imported here.
            probe = _probe_provider_env(env_py, ("mlx-lm", "mlx-vlm"))
            packages = probe.get("packages", {}) if probe else {}
            miss = [d for d in ("mlx-lm", "mlx-vlm")
                    if not packages.get(d)]
        else:
            # In-process deps matter only when no managed env exists -
            # with one installed, serve re-execs into it before boot.
            miss = [m for m in ("mlx_lm", "mlx_vlm")
                    if importlib.util.find_spec(m) is None]
        if miss:
            out[MLX_PROVIDER_ID] = "python: " + "/".join(miss)
    else:
        out[VLLMMLX_PROVIDER_ID] = "requires Metal (Apple Silicon)"
        out[MLX_PROVIDER_ID] = "requires Metal (Apple Silicon)"
    if _llama(pd) is None:
        out[LLAMACPP_PROVIDER_ID] = "llama-server"
    if _bridge_binary(pd) is None:
        out[APPLE_PROVIDER_ID] = "oap-apple-bridge"
    from .providers.vision_hybrid import _vision_bridge
    if _host_supports_mlx() and _vision_bridge(pd) is None:
        # Optional tier: the route still serves through its VLM delegate.
        out[VISIONHYBRID_PROVIDER_ID] = \
            "oap-vision-bridge (OCR tier; VLM fallback serves)"
    return out


def _python_supports(path: str) -> bool:
    """Probe the candidate interpreter itself; the PATH name (or the
    running interpreter) proves nothing about its real version."""
    try:
        proc = subprocess.run(
            [path, "-c",
             "import sys;sys.exit(0 if sys.version_info[:2] >= "
             f"({_MIN_PYTHON[0]},{_MIN_PYTHON[1]}) else 1)"],
            capture_output=True, timeout=15)
        return proc.returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def _provider_env_candidates():
    seen = set()
    for name in ("python3.13", "python3.12", "python3.11", "python3",
                 "python"):
        found = shutil.which(name)
        if found and found not in seen:
            seen.add(found)
            yield found
    if sys.executable and sys.executable not in seen:
        yield sys.executable


def _pip_install(env_py: str, args: list) -> None:
    """Owner-visible failure only: pip errors map to a typed error with
    the exit status, never a traceback."""
    try:
        subprocess.run([env_py, "-m", "pip", "install", *args],
                       check=True)
    except subprocess.CalledProcessError as e:
        raise PlatformError(ErrorCode.STORAGE_FAILURE,
                            f"pip install failed (exit {e.returncode})")
    except (OSError, subprocess.SubprocessError) as e:
        raise PlatformError(ErrorCode.STORAGE_FAILURE,
                            f"pip install failed: {e}")


def _ensure_provider_env(root: RuntimeRoot,
                         install_pins: bool | None = None) -> str:
    """Ensure <root>/providers/oap-env exists with its dependencies.
    Existing envs are reused, never wiped; a symlinked or non-venv
    directory is refused rather than repaired. Every existing env is
    re-validated for real: structure, interpreter version and prefix,
    and on Metal hosts the exact provider pins - missing or wrong pins
    are repaired through the governed provider-install flow, not by
    deleting the env. Callers hold the root lifetime lock."""
    if install_pins is None:
        install_pins = _host_supports_mlx()
    pdir = root.providers_path
    if os.path.islink(pdir):
        raise PlatformError(ErrorCode.ROOT_UNSAFE,
                            "providers dir is a symlink")
    env_dir = os.path.join(pdir, _PROVIDER_ENV)
    if os.path.islink(env_dir):
        raise PlatformError(ErrorCode.ROOT_UNSAFE,
                            "provider env is a symlink")
    if os.path.isdir(env_dir):
        env_py = _env_structural_check(env_dir)
        _validate_env_interpreter(env_py, env_dir,
                                  _probe_provider_env(env_py))
    else:
        if os.path.exists(env_dir):
            raise PlatformError(
                ErrorCode.ROOT_UNSAFE,
                f"{env_dir} is not a managed python env - move it aside "
                "or remove it, then re-run `provider install`")
        os.makedirs(pdir, exist_ok=True)
        env_py = _create_venv(env_dir)
    if install_pins:
        probe = _probe_provider_env(env_py)
        missing = _missing_pins(
            probe.get("packages", {}) if probe else {})
        if missing:
            _pip_install(env_py, list(_PROVIDER_PINS))
            probe = _probe_provider_env(env_py)
            missing = _missing_pins(
                probe.get("packages", {}) if probe else {})
            if missing:
                raise PlatformError(
                    ErrorCode.STORAGE_FAILURE,
                    "provider env still lacks: " + ", ".join(missing))
    return env_py


def _create_venv(env_dir: str) -> str:
    """Create the env with the first probed interpreter meeting the
    minimum; candidates are version-probed before use."""
    created = False
    for py in _provider_env_candidates():
        if not _python_supports(py):
            continue
        try:
            subprocess.run([py, "-m", "venv", env_dir], check=True)
            created = True
            break
        except (subprocess.CalledProcessError, OSError):
            shutil.rmtree(env_dir, ignore_errors=True)
    if not created:
        raise PlatformError(
            ErrorCode.INVALID_REQUEST,
            f"provider env needs Python >={_MIN_PYTHON[0]}."
            f"{_MIN_PYTHON[1]} on PATH")
    env_py = _env_python_path(env_dir)
    if env_py is None:
        raise PlatformError(ErrorCode.STORAGE_FAILURE,
                            "venv created no interpreter")
    return env_py


def _build_requires(source: str) -> list[str]:
    """[build-system] requires of the package being installed - the only
    build prerequisites --no-build-isolation may need."""
    import tomllib
    try:
        with open(os.path.join(source, "pyproject.toml"), "rb") as f:
            data = tomllib.load(f)
    except (OSError, tomllib.TOMLDecodeError):
        return []
    requires = data.get("build-system", {}).get("requires", [])
    return [r for r in requires if isinstance(r, str)]


def _version_meets(have: str | None, spec: str) -> bool:
    """True when installed `have` satisfies a name[>=|==]version spec."""
    m = re.match(r"\s*([A-Za-z0-9_.-]+)\s*(>=|==)\s*([0-9.]+)\s*$", spec)
    if m is None:
        return have is not None
    if have is None:
        return False
    want = m.group(3)
    if m.group(2) == "==":
        return have == want
    try:
        wv = tuple(int(x) for x in want.split("."))
        hv = tuple(int(x) for x in have.split(".")[:len(wv)])
    except ValueError:
        return False
    return hv >= wv


def _check_build_prereqs(env_py: str, source: str) -> None:
    """The package's declared build prerequisites must exist in the env
    (>=3.12 venvs no longer ship setuptools). Missing declared specs are
    provisioned via the governed pip step; an unmet prerequisite under
    PIP_NO_INDEX fails as an installer error, never a silent download."""
    specs = _build_requires(source)
    if not specs:
        return
    names = []
    for spec in specs:
        m = re.match(r"\s*([A-Za-z0-9_.-]+)", spec)
        names.append(m.group(1) if m else spec)
    probe = _probe_provider_env(env_py, names)
    packages = probe.get("packages", {}) if probe else {}
    absent = [spec for spec, name in zip(specs, names)
              if not _version_meets(packages.get(name), spec)]
    if not absent:
        return
    _pip_install(env_py, absent)
    probe = _probe_provider_env(env_py, names)
    packages = probe.get("packages", {}) if probe else {}
    still = [spec for spec, name in zip(specs, names)
             if not _version_meets(packages.get(name), spec)]
    if still:
        raise PlatformError(
            ErrorCode.STORAGE_FAILURE,
            "managed env lacks build prerequisites: " + ", ".join(still)
            + " - install them into the env or provide a package index")


def _needs_provider_reexec(root: RuntimeRoot) -> bool:
    """A managed env exists and this interpreter is not its python. The
    comparison is sys.prefix vs the env dir, not interpreter realpaths -
    venv binaries resolve to the same base Python and previously skipped
    a needed reexec."""
    if os.environ.get(_REEXEC_GUARD):
        return False
    env_dir = os.path.join(root.providers_path, _PROVIDER_ENV)
    if _provider_env_python(root) is None:
        return False
    return os.path.normcase(os.path.realpath(sys.prefix)) != \
        os.path.normcase(os.path.realpath(env_dir))


def _maybe_reexec_provider_env(root: RuntimeRoot) -> None:
    """When the managed provider env exists the daemon must run under its
    interpreter - in-process providers import there, not in whatever
    python launched the CLI."""
    if not _needs_provider_reexec(root):
        return
    env_py = _provider_env_python(root)
    env = dict(os.environ)
    env[_REEXEC_GUARD] = "1"
    src = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    env["PYTHONPATH"] = src + (os.pathsep + env["PYTHONPATH"]
                               if env.get("PYTHONPATH") else "")
    _eprint(f"managed provider env detected; restarting under {env_py}")
    os.execve(env_py, [env_py, "-m", "ondevice_agent_platform",
                       *sys.argv[1:]], env)


def cmd_serve(args) -> int:
    root = _root_for(args)
    root.prepare()
    root.check_state_files()
    # The lifetime lock precedes every guided-setup write; a running
    # daemon holding it makes serve (and any setup write) fail loudly.
    root.acquire_lock()
    try:
        _first_run_setup(root)
        # Config applies after the prompts: an enableOperator answer from
        # guided setup takes effect on this same launch, while explicit
        # CLI flags still win over stored choices.
        _apply_serve_config(args, _read_config(root))
        if _needs_provider_reexec(root):
            # A setup-created env means the interpreter must change. The
            # lock fd cannot survive execve - release before exec, and
            # reacquire when exec turns out not to run.
            root.release_lock()
            _maybe_reexec_provider_env(root)
            root.acquire_lock()
        supervisor, _store, _providers = _build_supervisor(root, args)
        agents = AgentService(supervisor)
        agents.attach(supervisor)
        acp = ACPService(supervisor)
        sessions = ConsoleSessions()
        supervisor._options = {
            "enable_reference_agent": args.enable_reference_agent,
            "reference_echo_model_alias": args.reference_echo_model,
        }
        bridge = None
        if args.enable_operator:
            supervisor.register_runtime_operator(
                args.operator_model or _default_operator_model(supervisor))
            principal = supervisor.register_console_operator_consumer()
            bridge = ConsoleOperatorBridge(acp, supervisor, sessions,
                                           principal)
        supervisor.start()
        server = PlatformHTTPServer(supervisor, acp, sessions, bridge,
                                    port=args.port)
        server.start()
        root.write_daemon_marker(server.port)
        _eprint(f"ondevice-agent-platform serving on "
                f"127.0.0.1:{server.port}")
        if getattr(args, "open", False):
            try:
                webbrowser.open(f"http://127.0.0.1:{server.port}/")
            except Exception:
                pass   # a headless host still serves; the URL is printed

        stop = threading.Event()

        def _sigint(_sig, _frame):
            stop.set()

        try:
            signal.signal(signal.SIGINT, _sigint)
            signal.signal(signal.SIGTERM, _sigint)
        except ValueError:
            pass   # off-main-thread (tests): no signal handlers
        try:
            stop.wait()
        finally:
            server.stop()
            supervisor.shutdown()
            root.remove_daemon_marker()
        return 0
    except PlatformError as e:
        _eprint(f"error: {e.safe_message}"
                + (f" ({e.detail})" if e.detail else ""))
        try:
            root.release_lock()
        except Exception:
            pass
        return 1
    except Exception as e:
        _eprint(f"error: {e}")
        try:
            root.release_lock()
        except Exception:
            pass
        return 1


def _default_operator_model(supervisor) -> str:
    """Operator binds the Apple route when enabled, else the first
    registered local LLM."""
    for p in supervisor.registered_models(ModelKind.LLM):
        if p.provider_id == APPLE_PROVIDER_ID:
            return p.alias
    models = supervisor.registered_models(ModelKind.LLM)
    if not models:
        raise PlatformError(ErrorCode.INVALID_REQUEST,
                            "no LLM registered for operator")
    return models[0].alias


# -- model ----------------------------------------------------------------------


def _progress(label: str):
    state = {"last": -1}

    def report(fraction: float) -> None:
        pct = int(fraction * 100)
        if pct != state["last"] and pct % 5 == 0:
            state["last"] = pct
            _eprint(f"  {label}: {pct}%")
    return report


def cmd_model_pull(args) -> int:
    root = _root_for(args)
    root.prepare()
    store = ModelStore(root)
    if args.alias:
        if not os.path.isfile(root.registry_path):
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                "no registry; run setup first")
        entries = parse_registry(root.read_json(root.registry_path))
        match = next((e for e in entries
                      if e.profile.alias == args.alias), None)
        if match is None or match.profile.source is None:
            raise PlatformError(ErrorCode.NOT_FOUND,
                                f"alias not declared: {args.alias}")
        source = match.profile.source
        artifact_file = match.artifact_file
    else:
        if not args.repo or not args.revision:
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                "--repo and --revision required")
        source = ModelSource(repo=args.repo, revision=args.revision)
        artifact_file = args.file
    print(f"pulling {source.repo}@{source.revision}"
          + (f" [{artifact_file}]" if artifact_file else ""))
    manifest = store.pull(source, artifact_file=artifact_file,
                          progress=_progress(source.repo))
    files = manifest.get("files", {})
    total = sum(f.get("size") or 0 for f in files)
    print(f"installed {len(files)} file(s), "
          f"{total / 1e9:.2f} GB -> "
          f"{store.directory(source, artifact_file)}")
    return 0


def cmd_model_list(args) -> int:
    root = _root_for(args)
    if not os.path.isfile(root.registry_path):
        print("no registry; run setup first")
        return 0
    entries = parse_registry(root.read_json(root.registry_path))
    store = ModelStore(root)
    for e in entries:
        p = e.profile
        src = p.source.repo if p.source else "-"
        ready = (store.is_ready(p.source, e.artifact_file)
                 if p.source else True)
        print(f"{p.alias:24} {p.kind.value:4} {p.provider_id:10} "
              f"{p.task:15} {'ready' if ready else 'not-pulled':10} {src}")
    return 0


def cmd_model_remove(args) -> int:
    root = _root_for(args)
    store = ModelStore(root)
    entries = parse_registry(root.read_json(root.registry_path)) \
        if os.path.isfile(root.registry_path) else []
    match = next((e for e in entries
                  if e.profile.alias == args.alias), None)
    if match is None or match.profile.source is None:
        raise PlatformError(ErrorCode.NOT_FOUND,
                            f"alias not declared: {args.alias}")
    store.remove(match.profile.source, match.artifact_file)
    print(f"removed artifacts for {args.alias} "
          f"(registry declaration kept)")
    return 0


# -- setup ----------------------------------------------------------------------


def _read_config(root: RuntimeRoot) -> dict:
    config = root.read_json(root.config_path)
    if config is None:
        return {}
    if not isinstance(config, dict):
        raise PlatformError(ErrorCode.INVALID_REQUEST, "config malformed")
    return config


def _apply_serve_config(args, config: dict) -> None:
    """config.json supplies serve defaults; explicit flags always win."""
    if not getattr(args, "enable_apple_model", False):
        args.enable_apple_model = bool(config.get("enableAppleModel"))
    if not getattr(args, "enable_operator", False):
        args.enable_operator = bool(config.get("enableOperator"))
    if getattr(args, "operator_model", None) is None:
        args.operator_model = config.get("operatorModel")


def _select_models_interactive(available, input_fn=input) -> list:
    """Guided menu over host-eligible catalog entries."""
    eligible = [(e, reason) for e, ok, reason in available if ok]
    print("available models:")
    for i, (e, _) in enumerate(eligible, 1):
        print(f"  {i}) {e.alias:18} ~{e.approx_bytes / 1e9:.1f} GB   "
              f"{e.summary}")
    for e, r in ((e, r) for e, ok, r in available if not ok):
        print(f"  -  {e.alias:18} unavailable: {r}")
    print("  note: apple-foundation-model needs no download")
    choice = input_fn("select numbers (e.g. 1,2), 'all', or 'none': "
                      ).strip().lower()
    if choice == "all":
        return [e for e, _ in eligible]
    if choice in ("none", ""):
        return []
    try:
        idx = [int(x) for x in choice.split(",")]
        return [eligible[i - 1][0] for i in idx
                if 1 <= i <= len(eligible)]
    except (ValueError, IndexError):
        raise PlatformError(ErrorCode.INVALID_REQUEST, "bad selection")


def _prompt_operator_agent(root: RuntimeRoot, selection,
                           input_fn=input) -> None:
    """Offer the optional read-only Operator during guided setup and
    persist the choice to config.json. The binding needs a model: the
    Apple system route on macOS, else the first selected LLM."""
    config = _read_config(root)
    if "enableOperator" in config:
        return
    from .requirements import host_info
    if host_info().os == "macos":
        bound = catalog.APPLE_MODEL_ALIAS
    elif selection:
        bound = selection[0].alias
    else:
        return
    config["enableOperator"] = (
        input_fn("enable the optional read-only Operator agent "
                 f"(binds {bound})? [y/N] ").strip().lower() == "y")
    if config["enableOperator"]:
        if bound == catalog.APPLE_MODEL_ALIAS:
            config["enableAppleModel"] = True
            config.pop("operatorModel", None)
        else:
            config["operatorModel"] = bound
    root.write_json(config, root.config_path)


def _finish_setup(root: RuntimeRoot, selection, *, pull: bool,
                  interactive: bool, input_fn=input) -> None:
    existing = root.read_json(root.registry_path) \
        if os.path.isfile(root.registry_path) else None
    merged = catalog.merged_registry(existing, selection)
    root.write_json(merged, root.registry_path)
    print(f"registry: {len(selection)} catalog model(s) declared, "
          f"{len(merged['models'])} total")
    # Even an empty selection is an intentional answer - mark the setup
    # completed so first-run serve does not re-prompt every launch.
    config = _read_config(root)
    if not config.get("setupCompleted"):
        config["setupCompleted"] = True
        root.write_json(config, root.config_path)
    if interactive:
        _prompt_operator_agent(root, selection, input_fn)
    if interactive and selection:
        # A base/core managed env may already exist without provider
        # pins; that must not suppress the offer for selected runtimes.
        missing = {pid: name for pid, name in _provider_missing(root).items()
                   if pid in {e.provider for e in selection}}
        coverable = sorted({n for pid, n in missing.items()
                            if _host_supports_mlx()
                            and pid in (VLLMMLX_PROVIDER_ID,
                                        MLX_PROVIDER_ID)})
        if coverable:
            if input_fn(f"provider runtime(s) missing: "
                        f"{', '.join(coverable)} - install the managed "
                        "provider env now? [y/N] ").strip().lower() == "y":
                print("installing provider env "
                      f"({', '.join(_PROVIDER_PINS)})")
                _ensure_provider_env(root, install_pins=True)
                print("  provider env ready")
            else:
                print("  those routes will report provider-unavailable "
                      "until installed (`provider install`)")
            missing = {pid: n for pid, n in missing.items()
                       if pid not in (VLLMMLX_PROVIDER_ID,
                                      MLX_PROVIDER_ID)}
        external = sorted({n for pid, n in missing.items()
                           if pid not in (VLLMMLX_PROVIDER_ID,
                                          MLX_PROVIDER_ID)})
        for name in external:
            print(f"  provider {name}: not managed - install it "
                  "separately (env override or PATH)")
    if not pull and interactive and selection:
        pull = input_fn("pull selected models now? [y/N] "
                        ).strip().lower() == "y"
    if pull:
        store = ModelStore(root)
        for e in selection:
            print(f"pulling {e.alias} ({e.source.repo})")
            store.pull(e.source, artifact_file=e.artifact_file,
                       progress=_progress(e.alias))
            print(f"  {e.alias} ready")
    elif selection:
        print("run `model pull --alias ALIAS` to fetch artifacts")


def _first_run_setup(root: RuntimeRoot, input_fn=input) -> None:
    """A root with no declared models: interactive runs get guided setup
    inline; non-interactive runs get a one-line hint, then boot empty."""
    payload = root.read_json(root.registry_path) \
        if os.path.isfile(root.registry_path) else None
    if isinstance(payload, dict) and payload.get("models"):
        return
    if _read_config(root).get("setupCompleted"):
        # An intentional "none" answer is a settled choice, not an
        # unfinished setup - do not re-prompt on every launch.
        return
    if not sys.stdin.isatty():
        _eprint("no models declared - run "
                "`ondevice-agent-platform setup` for guided install")
        return
    print("first run - choose models to serve (or 'none' to skip):")
    selection = _select_models_interactive(catalog.available_entries(),
                                           input_fn=input_fn)
    _finish_setup(root, selection, pull=False, interactive=True,
                  input_fn=input_fn)


def cmd_setup(args) -> int:
    root = _root_for(args)
    root.prepare()
    root.check_state_files()
    # Setup writes registry/config and may install the env - all under
    # the lifetime lock so it refuses while a daemon is running.
    root.acquire_lock()
    try:
        return _cmd_setup_locked(root, args)
    finally:
        root.release_lock()


def _cmd_setup_locked(root: RuntimeRoot, args) -> int:
    available = catalog.available_entries()
    eligible = [(e, reason) for e, ok, reason in available if ok]
    if args.all:
        selection = [e for e, _ in eligible]
    elif args.none:
        selection = []
    elif args.models:
        wanted = [a.strip() for a in args.models.split(",") if a.strip()]
        selection = []
        for alias in wanted:
            found = next((e for e, _ in eligible if e.alias == alias),
                         None)
            if found is None:
                known = next((e for e, ok, r in available
                              if e.alias == alias), None)
                if known is not None:
                    reason = next(r for e, ok, r in available
                                  if e.alias == alias)
                    raise PlatformError(
                        ErrorCode.INVALID_REQUEST,
                        f"{alias}: not eligible on this host ({reason})")
                raise PlatformError(ErrorCode.INVALID_REQUEST,
                                    f"unknown catalog alias: {alias}")
            selection.append(found)
    elif sys.stdin.isatty():
        selection = _select_models_interactive(available)
    else:
        raise PlatformError(ErrorCode.INVALID_REQUEST,
                            "no selection (use --models/--all/--none)")
    _finish_setup(root, selection, pull=args.pull,
                  interactive=sys.stdin.isatty())
    return 0


# -- provider ---------------------------------------------------------------------


def cmd_provider_list(args) -> int:
    root = _root_for(args)
    root.prepare()
    missing = _provider_missing(root)
    for pid in (VLLMMLX_PROVIDER_ID, MLX_PROVIDER_ID,
                LLAMACPP_PROVIDER_ID, APPLE_PROVIDER_ID,
                VISIONHYBRID_PROVIDER_ID, LINEAR_PROVIDER_ID):
        print(f"{pid:16} "
              + ("ok" if pid not in missing
                 else f"missing: {missing[pid]}"))
    env_py = _provider_env_python(root)
    print(f"{'provider-env':16} {env_py or 'not installed'}")
    return 0


def cmd_provider_install(args) -> int:
    root = _root_for(args)
    root.prepare()
    root.check_state_files()
    root.acquire_lock()
    try:
        if _host_supports_mlx():
            print(f"installing provider env "
                  f"({', '.join(_PROVIDER_PINS)})")
        else:
            print("installing provider env (no mlx pins on this host)")
        _ensure_provider_env(root)
        print(f"provider env ready: "
              f"{os.path.join(root.providers_path, _PROVIDER_ENV)}")
    finally:
        root.release_lock()
    return 0


# -- install --------------------------------------------------------------------


def _repo_python_dir() -> str | None:
    """<repo>/python when running from a source checkout, else None."""
    here = os.path.abspath(__file__)
    candidate = os.path.dirname(os.path.dirname(os.path.dirname(here)))
    return candidate if os.path.isfile(
        os.path.join(candidate, "pyproject.toml")) else None


def _link_executable(root: RuntimeRoot, bin_name: str) -> str:
    """Link the env console script into ~/.local/bin only - never an
    arbitrary writable PATH dir. A link already pointing at this exact
    script is idempotent; unrelated files/symlinks are preserved and
    reported. POSIX only - Windows callers get the Scripts dir printed."""
    script = os.path.join(root.providers_path, _PROVIDER_ENV,
                          "bin", bin_name)
    if not os.path.isfile(script):
        raise PlatformError(ErrorCode.INTERNAL,
                            "installed console script missing")
    target_dir = os.path.join(os.path.expanduser("~"), ".local", "bin")
    os.makedirs(target_dir, exist_ok=True)
    link = os.path.join(target_dir, bin_name)
    if os.path.lexists(link):
        if os.path.islink(link) and \
                os.path.realpath(link) == os.path.realpath(script):
            return link
        raise PlatformError(
            ErrorCode.INVALID_REQUEST,
            f"{link} exists and is unrelated - move it aside or remove "
            "it, then re-run install")
    os.symlink(script, link)
    return link


def cmd_install(args) -> int:
    """Install the platform: managed provider env (reused, never wiped),
    the package installed non-editably from --source, and an
    ondevice-agent-platform executable linked into ~/.local/bin.
    --serve chains into `serve --open` so setup finishes in the console."""
    root = _root_for(args)
    root.prepare()
    root.check_state_files()
    root.acquire_lock()
    try:
        code = _install_impl(root, args)
    finally:
        root.release_lock()
    if code == 0 and getattr(args, "serve", False):
        print("starting the platform and opening the console - "
              "Ctrl-C to stop")
        serve_args = argparse.Namespace(
            data_root=getattr(args, "data_root", None), port=8080,
            enable_reference_agent=False, reference_echo_model=None,
            enable_apple_model=False, enable_operator=False,
            operator_model=None, open=True)
        return cmd_serve(serve_args)
    if code == 0:
        print("run `ondevice-agent-platform serve --open` to open the "
              "console and install models or the Operator")
    return code


def _root_needs_mlx(root: RuntimeRoot) -> bool:
    """'Install only what is needed': provision the pinned MLX stack
    only when the declared registry uses an MLX-backed provider on a
    Metal host - a bare or empty-registry install stays core-only."""
    if not _host_supports_mlx():
        return False
    payload = root.read_json(root.registry_path) \
        if os.path.isfile(root.registry_path) else None
    if not isinstance(payload, dict):
        return False
    return any(e.profile.provider_id in (MLX_PROVIDER_ID,
                                         VLLMMLX_PROVIDER_ID)
               for e in parse_registry(payload))


def _install_impl(root: RuntimeRoot, args) -> int:
    source = getattr(args, "source", None) or _repo_python_dir()
    script_name = "ondevice-agent-platform" + \
        (".exe" if os.name == "nt" else "")
    script = os.path.join(root.providers_path, _PROVIDER_ENV,
                          "Scripts" if os.name == "nt" else "bin",
                          script_name)
    have_script = os.path.isfile(script)
    if source is not None and not os.path.isfile(
            os.path.join(source, "pyproject.toml")):
        # An explicitly supplied source that is not a package directory
        # must not be silently ignored, even with a script installed.
        raise PlatformError(
            ErrorCode.INVALID_REQUEST,
            f"no pyproject.toml at --source {source} - pass the repo's "
            "python/ package directory")
    have_source = source is not None
    if not have_source and not have_script:
        # Fail before touching the env: a new install needs a package
        # source to make the console script.
        raise PlatformError(
            ErrorCode.INVALID_REQUEST,
            "no package source found - pass --source PATH to the repo's "
            "python/ directory or run via bin/ondevice-agent-platform "
            "from a checkout")
    env_py = _ensure_provider_env(root,
                                  install_pins=_root_needs_mlx(root))
    if have_source:
        # An explicit (or source-mode default) source always means
        # "install this package": run the pip step even when a console
        # script already exists - that is how updates/reinstalls work.
        _check_build_prereqs(env_py, source)
        _pip_install(env_py,
                     ["--no-deps", "--no-build-isolation", source])
        if not os.path.isfile(script):
            raise PlatformError(ErrorCode.STORAGE_FAILURE,
                                "package install produced no console "
                                "script")
    if os.name == "nt":
        print(f"installed; add {os.path.dirname(script)} to PATH")
    else:
        link = _link_executable(root, "ondevice-agent-platform")
        print(f"executable linked: {link}")
        bindir = os.path.dirname(link)
        if bindir not in os.environ.get("PATH", "").split(os.pathsep):
            print(f"note: {bindir} is not on PATH - add it: "
                  f'export PATH="{bindir}:$PATH"')
    if os.path.isfile(root.daemon_path):
        print("note: a daemon is running - restart `serve` to pick up "
              "the new install")
    return 0


# -- acp ------------------------------------------------------------------------


def cmd_acp(args) -> int:
    root = _root_for(args)
    port = root.read_daemon_marker()
    if port is None:
        raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                            "daemon not running (start `serve` first)")
    url = f"http://127.0.0.1:{port}/_bridge/acp"
    return run_stdio_facade(args.agent, url)


# -- entry ------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="ondevice-agent-platform",
        description="local-first agent and model serving platform")
    sub = p.add_subparsers(dest="command", required=True)

    def data_root(s):
        s.add_argument("--data-root", default=None,
                       help="runtime root (default ~/.ondevice-agent-platform)")

    serve = sub.add_parser("serve", help="run the daemon")
    data_root(serve)
    serve.add_argument("--port", type=int, default=8080)
    serve.add_argument("--enable-reference-agent", action="store_true")
    serve.add_argument("--reference-echo-model", default=None)
    serve.add_argument("--enable-apple-model", action="store_true")
    serve.add_argument("--enable-operator", action="store_true")
    serve.add_argument("--operator-model", default=None)
    serve.add_argument("--open", action="store_true",
                       help="open the console in the default browser")
    serve.set_defaults(func=cmd_serve)

    model = sub.add_parser("model", help="model store commands")
    msub = model.add_subparsers(dest="model_command", required=True)
    pull = msub.add_parser("pull")
    pull.add_argument("--alias")
    pull.add_argument("--repo")
    pull.add_argument("--revision")
    pull.add_argument("--file", default=None,
                      help="single-file artifact (GGUF)")
    data_root(pull)
    pull.set_defaults(func=cmd_model_pull)
    lst = msub.add_parser("list")
    data_root(lst)
    lst.set_defaults(func=cmd_model_list)
    rm = msub.add_parser("remove")
    rm.add_argument("--alias", required=True)
    data_root(rm)
    rm.set_defaults(func=cmd_model_remove)

    setup = sub.add_parser("setup", help="guided model setup")
    data_root(setup)
    setup.add_argument("--models", default=None,
                       help="comma-separated catalog aliases")
    setup.add_argument("--all", action="store_true")
    setup.add_argument("--none", action="store_true")
    setup.add_argument("--pull", action="store_true")
    setup.set_defaults(func=cmd_setup)

    prov = sub.add_parser("provider", help="provider runtime commands")
    psub = prov.add_subparsers(dest="provider_command", required=True)
    plist = psub.add_parser("list", help="provider prerequisite status")
    data_root(plist)
    plist.set_defaults(func=cmd_provider_list)
    pinst = psub.add_parser(
        "install", help="install the managed provider environment")
    data_root(pinst)
    pinst.set_defaults(func=cmd_provider_install)

    inst = sub.add_parser(
        "install", help="install provider env + ondevice-agent-platform "
        "executable onto PATH")
    data_root(inst)
    inst.add_argument("--source", default=None,
                      help="path to the repo's python/ package directory "
                      "(containing pyproject.toml); defaults to the "
                      "checkout this CLI was launched from")
    inst.add_argument("--serve", action="store_true",
                      help="after install, start the daemon and open the "
                      "console to finish setup (install models, Operator)")
    inst.set_defaults(func=cmd_install)

    acp = sub.add_parser("acp", help="ACP stdio facade")
    acp.add_argument("--agent", required=True)
    data_root(acp)
    acp.set_defaults(func=cmd_acp)
    return p


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return args.func(args)
    except PlatformError as e:
        print(f"error: {e.safe_message}"
              + (f" ({e.detail})" if e.detail else ""), file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
