"""Apple Foundation Models provider: the only provider that still needs
native code. FoundationModels is a Swift/ObjC API, so this provider talks
to a small macOS-only bridge helper (`oap-apple-bridge`, a Swift executable
that reads one JSON chat request per line on stdin and writes one JSON
result per line on stdout). Off macOS or without the helper present, the
route reports truthful unavailable - it is never fabricated.

The helper ships as Sources/AppleBridge in the Swift package and is only
built/used on Darwin; every other platform simply never registers this
provider.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import threading

from ..chat import ChatResult, ChatUsage, FinishReason
from ..compat import IS_MACOS
from ..errors import ErrorCode, PlatformError
from ..registry import APPLE_PROVIDER_ID
from .base import LLMProvider

APPLE_MODEL_ALIAS = "apple-foundation-model"


def _bridge_binary() -> str | None:
    override = os.environ.get("OAP_APPLE_BRIDGE")
    if override and os.path.isfile(override) and os.access(override, os.X_OK):
        return override
    for name in ("oap-apple-bridge",):
        found = shutil.which(name)
        if found:
            return found
    # Repo-relative built product: <repo>/.build/debug/oap-apple-bridge.
    here = os.path.dirname(os.path.abspath(__file__))
    repo = os.path.abspath(os.path.join(here, "..", "..", "..", ".."))
    for candidate in (
            os.path.join(repo, ".build", "debug", "oap-apple-bridge"),
            os.path.join(repo, ".build", "release", "oap-apple-bridge")):
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None


class AppleFoundationProvider(LLMProvider):
    """System-managed weights: no platform load, so requires_load is false
    and defer_load never holds this route."""
    provider_id = APPLE_PROVIDER_ID

    def __init__(self) -> None:
        # _lock owns the _proc reference only. _io_lock serializes the
        # stdin/stdout exchange; _kill must never take either while it
        # holds them - aborting a blocking readline is the whole point.
        self._lock = threading.Lock()
        self._io_lock = threading.Lock()
        self._proc: subprocess.Popen | None = None

    @staticmethod
    def available_on_host() -> bool:
        return IS_MACOS and _bridge_binary() is not None

    def requires_load(self, profile) -> bool:
        return False   # system-managed; never loads platform weights

    def _ensure(self):
        binary = _bridge_binary()
        if binary is None:
            raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                                "apple bridge helper not built")
        with self._lock:
            if self._proc is not None and self._proc.poll() is None:
                return self._proc
            self._proc = subprocess.Popen(
                [binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                text=True, bufsize=1)
            return self._proc

    def validate(self, request, profile) -> None:
        # The Apple route honors only temperature + the token cap; every
        # other knob is refused rather than silently ignored, and tool
        # surfaces have no truthful transcript representation here.
        if (request.top_p is not None or request.seed is not None
                or request.presence_penalty is not None
                or request.frequency_penalty is not None):
            raise PlatformError(
                ErrorCode.INVALID_REQUEST,
                "apple route honors only temperature")
        if request.tools or request.tool_choice not in (None,) and \
                getattr(request.tool_choice, "value", request.tool_choice) \
                != "none":
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                "apple provider does not accept tools")
        for m in request.messages:
            if m.role.value == "tool" or m.tool_calls:
                raise PlatformError(
                    ErrorCode.INVALID_REQUEST,
                    "tool messages and calls are not expressible")
        rf = request.response_format
        if rf is not None and rf.strict is True:
            raise PlatformError(
                ErrorCode.INVALID_REQUEST,
                "strict json schema is not enforced by this provider")

    def complete(self, request, profile, token=None):
        proc = self._ensure()
        if token is not None and token.is_cancelled:
            raise PlatformError(ErrorCode.CANCELLED)
        payload = {
            "messages": [{"role": m.role.value, "content": m.combined_text}
                         for m in request.messages],
            "maxTokens": request.max_output_tokens,
            "temperature": request.temperature or 0.0,
        }
        if request.response_format is not None:
            payload["formatGuidance"] = request.response_format.guidance()

        # Cancellation kills the shared bridge: the readline returns empty
        # and the next call respawns. Calls are serialized on the io lock;
        # _kill runs outside it so an abort is never queued behind the
        # very readline it is meant to wake.
        observer = (token.observe(lambda: self._kill(proc))
                    if token is not None else None)
        try:
            with self._io_lock:
                try:
                    proc.stdin.write(json.dumps(payload) + "\n")
                    proc.stdin.flush()
                    line = proc.stdout.readline()
                except (OSError, ValueError):
                    # A cancelled token's observer closed these pipes to
                    # wake this readline - the closed-pipe error is the
                    # cancellation surfacing, not a bridge failure.
                    if token is not None and token.is_cancelled:
                        raise PlatformError(ErrorCode.CANCELLED)
                    with self._lock:
                        if self._proc is proc:
                            self._proc = None
                    raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                                        "apple bridge failed")
            if not line:
                if token is not None and token.is_cancelled:
                    raise PlatformError(ErrorCode.CANCELLED)
                with self._lock:
                    if self._proc is proc:
                        self._proc = None
                raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                                    "apple bridge closed")
            try:
                result = json.loads(line)
            except json.JSONDecodeError:
                raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                                    "apple bridge malformed output")
            if "error" in result:
                code = result.get("code")
                if code == "invalid_request":
                    raise PlatformError(ErrorCode.INVALID_REQUEST,
                                        str(result["error"]))
                if code == "cancelled" or (
                        token is not None and token.is_cancelled):
                    raise PlatformError(ErrorCode.CANCELLED)
                raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                                    str(result["error"]))
        finally:
            if token is not None and observer is not None:
                token.remove_observer(observer)
        if token is not None and token.is_cancelled:
            raise PlatformError(ErrorCode.CANCELLED)
        finish = (FinishReason.LENGTH
                  if result.get("finish") == "length" else FinishReason.STOP)
        return ChatResult(
            model_identity=result.get("model", profile.alias),
            content=result.get("content", ""),
            finish_reason=finish,
            usage=ChatUsage(completion_tokens=result.get("tokens")))

    def _kill(self, proc) -> None:
        # Kill outside _lock: complete() may be inside a blocking readline
        # and _lock is never held by it, but ownership clearing must not
        # race another _ensure() respawn of a different process.
        try:
            proc.kill()
        except (OSError, ProcessLookupError):
            pass
        for pipe in (proc.stdin, proc.stdout):
            try:
                if pipe is not None:
                    pipe.close()
            except (OSError, ValueError):
                pass
        try:
            proc.wait(timeout=2)
        except Exception:
            pass
        with self._lock:
            if self._proc is proc:
                self._proc = None

    def close(self) -> None:
        with self._lock:
            proc = self._proc
            self._proc = None
        if proc is None:
            return
        try:
            try:
                proc.terminate()
            except (OSError, ProcessLookupError):
                pass
            try:
                proc.wait(timeout=2)
            except Exception:
                try:
                    proc.kill()
                except (OSError, ProcessLookupError):
                    pass
                try:
                    proc.wait(timeout=2)
                except Exception:
                    pass
        finally:
            # Reaping alone leaves our pipe ends open; close them so the
            # child cannot linger on inherited fds.
            for pipe in (proc.stdin, proc.stdout):
                try:
                    if pipe is not None:
                        pipe.close()
                except (OSError, ValueError):
                    pass
