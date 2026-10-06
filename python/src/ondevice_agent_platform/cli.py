"""CLI entry point, mirroring PlatformCLI: serve / model pull|list|remove /
setup / acp. Stdlib argparse; no shell scripts."""
from __future__ import annotations

import argparse
import json
import os
import signal
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
            providers.setdefault(VLLMMLX_PROVIDER_ID, VllmMlxProvider(store))
            provider = providers[VLLMMLX_PROVIDER_ID]
        elif profile.provider_id == LLAMACPP_PROVIDER_ID:
            if entry.artifact_file:
                artifact_files[profile.alias] = entry.artifact_file
        supervisor.register_model(profile, provider=provider,
                                  predictor=predictor)

    if artifact_files or any(e.profile.provider_id == LLAMACPP_PROVIDER_ID
                             for e in entries):
        from .providers.llamacpp import LlamaCppProvider
        provider = LlamaCppProvider(store, artifact_files=artifact_files)
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


def cmd_serve(args) -> int:
    root = _root_for(args)
    root.prepare()
    root.check_state_files()
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
        _eprint(f"error: {e.safe_message}")
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
        print("available models:")
        for i, (e, _) in enumerate(eligible, 1):
            print(f"  {i}) {e.alias:18} ~{e.approx_bytes / 1e9:.1f} GB   "
                  f"{e.summary}")
        ineligible = [(e, r) for e, ok, r in available if not ok]
        for e, r in ineligible:
            print(f"  -  {e.alias:18} unavailable: {r}")
        print("  note: apple-foundation-model needs no download - "
              "--enable-apple-model at serve")
        choice = input("select numbers (e.g. 1,2), 'all', or 'none': "
                       ).strip().lower()
        if choice == "all":
            selection = [e for e, _ in eligible]
        elif choice in ("none", ""):
            selection = []
        else:
            try:
                idx = [int(x) for x in choice.split(",")]
                selection = [eligible[i - 1][0] for i in idx
                             if 1 <= i <= len(eligible)]
            except (ValueError, IndexError):
                raise PlatformError(ErrorCode.INVALID_REQUEST,
                                    "bad selection")
    else:
        raise PlatformError(ErrorCode.INVALID_REQUEST,
                            "no selection (use --models/--all/--none)")
    existing = root.read_json(root.registry_path) \
        if os.path.isfile(root.registry_path) else None
    merged = catalog.merged_registry(existing, selection)
    root.write_json(merged, root.registry_path)
    print(f"registry: {len(selection)} catalog model(s) declared, "
          f"{len(merged['models'])} total")
    pull = args.pull
    if not pull and sys.stdin.isatty() and selection:
        pull = input("pull selected models now? [y/N] "
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
        print(f"error: {e.safe_message}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
