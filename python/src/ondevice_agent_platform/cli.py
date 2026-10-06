"""CLI entry point, mirroring PlatformCLI: serve / model pull|list|remove /
setup / acp. Stdlib argparse; no shell scripts."""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import shutil
import signal
import subprocess
import sys
import threading

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
                       VLLMMLX_PROVIDER_ID, parse_registry)

# One managed venv under <root>/providers/oap-env owns the platform's
# provider dependencies: vllm-mlx's server binary resolves there without
# env vars, and `serve` re-execs under its interpreter so the in-process
# mlx-lm/mlx-vlm providers import. Everything pinned - same governed-pull
# posture as model artifacts.
_PROVIDER_ENV = "oap-env"
_PROVIDER_PINS = ("vllm-mlx==0.5.0", "mlx-lm==0.32.0", "mlx-vlm==0.7.6")
_REEXEC_GUARD = "OAP_PROVIDER_ENV"
from .runtime_root import RuntimeRoot
from .server import PlatformHTTPServer
from .supervisor import PlatformSupervisor


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
        apple = AppleFoundationProvider()
        providers[APPLE_PROVIDER_ID] = apple
        supervisor.register_model(ModelProfile(
            alias="apple-foundation-model", provider_id=APPLE_PROVIDER_ID,
            kind=ModelKind.LLM, task="chat", capabilities=("text",),
            max_output_tokens=8192), provider=apple)

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


def _provider_missing(root: RuntimeRoot) -> dict[str, str]:
    """provider_id -> missing prerequisite, for status and setup offers."""
    out: dict[str, str] = {}
    pd = root.providers_path
    from .providers.vllmmlx import _server_binary as _vllm
    from .providers.llamacpp import _server_binary as _llama
    if _vllm(pd) is None:
        out[VLLMMLX_PROVIDER_ID] = "vllm-mlx"
    if _llama(pd) is None:
        out[LLAMACPP_PROVIDER_ID] = "llama-server"
    if _provider_env_python(root) is None:
        # In-process deps matter only when no managed env exists - with
        # one installed, serve re-execs into it before boot.
        miss = [m for m in ("mlx_lm", "mlx_vlm")
                if importlib.util.find_spec(m) is None]
        if miss:
            out[MLX_PROVIDER_ID] = "python: " + "/".join(miss)
    from .providers.apple import _bridge_binary
    if _bridge_binary() is None:
        out[APPLE_PROVIDER_ID] = "oap-apple-bridge"
    return out


def _provider_env_candidates():
    for name in ("python3.13", "python3.12", "python3.11", "python3.10"):
        found = shutil.which(name)
        if found:
            yield found
    if sys.version_info >= (3, 10):
        yield sys.executable


def _install_provider_env(root: RuntimeRoot) -> str:
    """Create <root>/providers/oap-env and install the pinned provider
    dependencies. Provider pins are a governed prerequisite - same class
    of install as `model pull`."""
    os.makedirs(root.providers_path, exist_ok=True)
    env_dir = os.path.join(root.providers_path, _PROVIDER_ENV)
    if os.path.isdir(env_dir):
        shutil.rmtree(env_dir)
    created = False
    for py in _provider_env_candidates():
        try:
            subprocess.run([py, "-m", "venv", env_dir], check=True)
            created = True
            break
        except (subprocess.CalledProcessError, OSError):
            shutil.rmtree(env_dir, ignore_errors=True)
    if not created:
        raise PlatformError(ErrorCode.INVALID_REQUEST,
                            "provider env needs Python >=3.10 on PATH")
    pip = os.path.join(env_dir, "Scripts" if os.name == "nt" else "bin",
                       "pip")
    try:
        subprocess.run([pip, "install", *_PROVIDER_PINS], check=True)
    except subprocess.CalledProcessError:
        raise PlatformError(ErrorCode.STORAGE_FAILURE,
                            "provider env dependency install failed")
    return env_dir


def _maybe_reexec_provider_env(root: RuntimeRoot) -> None:
    """When the managed provider env exists the daemon must run under its
    interpreter - in-process providers import there, not in whatever
    python launched the CLI."""
    if os.environ.get(_REEXEC_GUARD):
        return
    env_py = _provider_env_python(root)
    if env_py is None or \
            os.path.realpath(env_py) == os.path.realpath(sys.executable):
        return
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
    _apply_serve_config(args, _read_config(root))
    _first_run_setup(root)
    _maybe_reexec_provider_env(root)
    root.acquire_lock()
    try:
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
    if interactive:
        _prompt_operator_agent(root, selection, input_fn)
    if interactive and selection and _provider_env_python(root) is None:
        missing = {pid: name for pid, name in _provider_missing(root).items()
                   if pid in {e.provider for e in selection}}
        coverable = sorted({n for pid, n in missing.items()
                            if pid in (VLLMMLX_PROVIDER_ID,
                                       MLX_PROVIDER_ID)})
        if coverable:
            if input_fn(f"provider runtime(s) missing: "
                        f"{', '.join(coverable)} - install the managed "
                        "provider env now? [y/N] ").strip().lower() == "y":
                print("installing provider env "
                      f"({', '.join(_PROVIDER_PINS)})")
                _install_provider_env(root)
                print("  provider env ready")
            else:
                print("  those routes will report provider-unavailable "
                      "until installed (`provider install`)")
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


def _first_run_setup(root: RuntimeRoot) -> None:
    """A root with no declared models: interactive runs get guided setup
    inline; non-interactive runs get a one-line hint, then boot empty."""
    payload = root.read_json(root.registry_path) \
        if os.path.isfile(root.registry_path) else None
    if isinstance(payload, dict) and payload.get("models"):
        return
    if not sys.stdin.isatty():
        _eprint("no models declared - run "
                "`ondevice-agent-platform setup` for guided install")
        return
    print("first run - choose models to serve (or 'none' to skip):")
    selection = _select_models_interactive(catalog.available_entries())
    _finish_setup(root, selection, pull=False, interactive=True)


def cmd_setup(args) -> int:
    root = _root_for(args)
    root.prepare()
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
                LINEAR_PROVIDER_ID):
        print(f"{pid:16} "
              + ("ok" if pid not in missing
                 else f"missing: {missing[pid]}"))
    env_py = _provider_env_python(root)
    print(f"{'provider-env':16} {env_py or 'not installed'}")
    return 0


def cmd_provider_install(args) -> int:
    root = _root_for(args)
    root.prepare()
    print(f"installing provider env ({', '.join(_PROVIDER_PINS)})")
    path = _install_provider_env(root)
    print(f"provider env ready: {path}")
    return 0


# -- install --------------------------------------------------------------------


def _repo_python_dir() -> str | None:
    """<repo>/python when running from a source checkout, else None."""
    here = os.path.abspath(__file__)
    candidate = os.path.dirname(os.path.dirname(os.path.dirname(here)))
    return candidate if os.path.isfile(
        os.path.join(candidate, "pyproject.toml")) else None


def _link_executable(root: RuntimeRoot, bin_name: str) -> str:
    """Put the console script on PATH: symlink into ~/.local/bin when that
    dir is on PATH, else the first writable PATH dir; returns the link
    path. POSIX only - Windows callers get the env Scripts dir printed."""
    script = os.path.join(root.providers_path, _PROVIDER_ENV,
                          "bin", bin_name)
    if not os.path.isfile(script):
        raise PlatformError(ErrorCode.INTERNAL,
                            "installed console script missing")
    home = os.path.expanduser("~")
    candidates = [os.path.join(home, ".local", "bin")] + \
        os.environ.get("PATH", "").split(os.pathsep)
    for d in candidates:
        if d and os.path.isdir(d) and os.access(d, os.W_OK):
            link = os.path.join(d, bin_name)
            if os.path.islink(link) or os.path.isfile(link):
                os.remove(link)
            os.symlink(script, link)
            return link
    raise PlatformError(ErrorCode.INVALID_REQUEST,
                        f"no writable PATH dir; add "
                        f"{os.path.dirname(script)} to PATH")


def cmd_install(args) -> int:
    """Install the platform: managed provider env, editable package into
    it, and an ondevice-agent-platform executable linked onto PATH."""
    root = _root_for(args)
    root.prepare()
    env_py = _provider_env_python(root)
    if env_py is None:
        print(f"installing provider env ({', '.join(_PROVIDER_PINS)})")
        _install_provider_env(root)
        env_py = _provider_env_python(root)
    repo_python = _repo_python_dir()
    if repo_python is not None:
        pip = os.path.join(root.providers_path, _PROVIDER_ENV,
                           "Scripts" if os.name == "nt" else "bin", "pip")
        subprocess.run([pip, "install", "-e", repo_python], check=True)
    if os.name == "nt":
        scripts = os.path.join(root.providers_path, _PROVIDER_ENV,
                               "Scripts")
        print(f"installed; add {scripts} to PATH")
    else:
        link = _link_executable(root, "ondevice-agent-platform")
        print(f"executable linked: {link}")
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
