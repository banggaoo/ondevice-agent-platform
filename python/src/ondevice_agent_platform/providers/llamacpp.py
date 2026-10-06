"""llama.cpp provider: the cross-platform open-weight route.

Each profile's pinned GGUF runs as an owned `llama-server` child process on
a loopback port; the provider speaks the same OpenAI chat shape to it and
maps results back. Process residency is the container model: requires_load
is true until the server for that profile is running; evict_resident kills
servers so deny_and_cancel actually frees host memory. The binary is
discovered on PATH or OAP_LLAMA_SERVER; absent -> truthful unavailable.
"""
from __future__ import annotations

import json
import os
import shutil
import signal
import socket
import subprocess
import threading
import time
import urllib.request

from ..chat import ChatResult, ChatToolCall, ChatUsage, FinishReason
from ..errors import ErrorCode, PlatformError
from ..registry import LLAMACPP_PROVIDER_ID
from .base import LLMProvider, ModelCacheEvicting, ProviderReadiness


def _server_binary() -> str | None:
    override = os.environ.get("OAP_LLAMA_SERVER")
    if override and os.path.isfile(override):
        return override
    for name in ("llama-server", "llama-server.exe"):
        found = shutil.which(name)
        if found:
            return found
    return None


def _free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class _Server:
    """One resident llama-server process for a profile's artifact."""

    def __init__(self, binary: str, model_path: str, alias: str) -> None:
        self.alias = alias
        self.port = _free_port()
        self.proc = subprocess.Popen(
            [binary, "-m", model_path, "--host", "127.0.0.1",
             "--port", str(self.port), "-ngl", "99",
             "--ctx-size", "16384", "--jinja"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.last_used = time.time()
        self.epoch = 0

    def healthy(self) -> bool:
        return self.proc.poll() is None

    def stop(self) -> None:
        if self.proc.poll() is None:
            try:
                self.proc.terminate()
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()


class LlamaCppProvider(LLMProvider, ModelCacheEvicting, ProviderReadiness):
    provider_id = LLAMACPP_PROVIDER_ID

    def __init__(self, store, artifact_files: dict[str, str] | None = None):
        self._store = store
        self._files = artifact_files or {}   # alias -> source file name
        self._servers: dict[str, _Server] = {}
        self._lock = threading.Lock()
        self._epochs: dict[str, int] = {}
        self._profiles: list = []

    # -- readiness ---------------------------------------------------------
    @property
    def has_ready_artifact(self) -> bool:
        binary = _server_binary()
        if binary is None:
            return False
        return any(
            self._store.is_ready(p.source, self._files.get(p.alias))
            for p in self._profiles)

    def artifact_ready(self, profile) -> bool | None:
        if profile.source is None:
            return None
        return self._store.is_ready(profile.source,
                                    self._files.get(profile.alias))

    def track_profiles(self, profiles) -> None:
        self._profiles = list(profiles)

    # -- cache lifecycle ----------------------------------------------------
    def requires_load(self, profile) -> bool:
        with self._lock:
            return profile.alias not in self._servers

    def evict_resident(self) -> int:
        with self._lock:
            servers = list(self._servers.values())
            self._servers.clear()
            for alias in list(self._epochs):
                self._epochs[alias] += 1
        for s in servers:
            s.stop()
        return len(servers)

    def evict_idle(self, older_than: float) -> int:
        with self._lock:
            idle = [a for a, s in self._servers.items()
                    if s.last_used < older_than]
            for a in idle:
                self._epochs[a] = self._epochs.get(a, 0) + 1
                self._servers.pop(a).stop()
        return len(idle)

    # -- inference -----------------------------------------------------------
    def _server_for(self, profile, token=None):
        binary = _server_binary()
        if binary is None:
            raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                                "llama-server binary not found")
        if profile.source is None or not self._store.is_ready(
                profile.source, self._files.get(profile.alias)):
            raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                                "model artifact not pulled")
        directory = self._store.directory(profile.source,
                                          self._files.get(profile.alias))
        manifest = self._store.manifest_of(profile.source,
                                           self._files.get(profile.alias))
        gguf = next((f["name"] for f in manifest["files"]
                     if f["name"].endswith(".gguf")), None)
        if gguf is None:
            raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                                "no gguf artifact")
        model_path = os.path.join(directory, gguf)
        with self._lock:
            epoch = self._epochs.get(profile.alias, 0)
        server = _Server(binary, model_path, profile.alias)
        # Wait for readiness: the server answers /health once weights map.
        deadline = time.time() + 120
        while time.time() < deadline:
            if token is not None and token.is_cancelled:
                server.stop()
                raise PlatformError(ErrorCode.CANCELLED)
            if server.proc.poll() is not None:
                raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                                    "llama-server exited during load")
            try:
                urllib.request.urlopen(
                    f"http://127.0.0.1:{server.port}/health", timeout=1)
                break
            except Exception:
                time.sleep(0.25)
        else:
            server.stop()
            raise PlatformError(ErrorCode.DEADLINE_EXCEEDED,
                                "llama-server load deadline")
        with self._lock:
            # Epoch guard: an eviction during load discards this container.
            if self._epochs.get(profile.alias, 0) != epoch:
                server.stop()
                raise PlatformError(ErrorCode.CANCELLED,
                                    "container evicted during load")
            self._servers[profile.alias] = server
        return server

    def complete(self, request, profile, token=None):
        with self._lock:
            server = self._servers.get(profile.alias)
        if server is None:
            server = self._server_for(profile, token)
        if not server.healthy():
            with self._lock:
                self._servers.pop(profile.alias, None)
            server = self._server_for(profile, token)
        server.last_used = time.time()
        if token is not None and token.is_cancelled:
            raise PlatformError(ErrorCode.CANCELLED)
        body = self._wire_request(request, profile)
        req = urllib.request.Request(
            f"http://127.0.0.1:{server.port}/v1/chat/completions",
            data=json.dumps(body).encode(),
            headers={"Content-Type": "application/json"})
        # Cancellation can abort the in-flight read: the token's observer
        # closes the response so a cancel never waits out the socket.
        inflight = []
        observer = (token.observe(lambda: [r.close() for r in inflight])
                    if token is not None else None)
        try:
            with urllib.request.urlopen(req, timeout=300) as r:
                inflight.append(r)
                payload = json.loads(r.read())
        except Exception as e:
            if token is not None and token.is_cancelled:
                raise PlatformError(ErrorCode.CANCELLED)
            raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                                f"llama-server call failed: {e}")
        finally:
            if token is not None and observer is not None:
                token.remove_observer(observer)
        if token is not None and token.is_cancelled:
            raise PlatformError(ErrorCode.CANCELLED)
        server.last_used = time.time()
        return self._wire_result(payload, request.model)

    def cancel(self, job_id: str) -> None:
        # llama-server has no cooperative cancel for a finished socket call;
        # eviction or process stop is the real cancellation path here.
        return None

    # -- wire mapping --------------------------------------------------------
    def _wire_request(self, request, profile) -> dict:
        messages = []
        for m in request.messages:
            msg = {"role": m.role.value}
            if m.parts:
                msg["content"] = m.combined_text
            elif m.role.value == "assistant" and m.tool_calls:
                msg["content"] = None
            if m.tool_calls:
                msg["tool_calls"] = [
                    {"id": c.id or f"call_{i}", "type": "function",
                     "function": {"name": c.name,
                                  "arguments": json.dumps(c.arguments)}}
                    for i, c in enumerate(m.tool_calls)]
            if m.tool_call_id:
                msg["tool_call_id"] = m.tool_call_id
            messages.append(msg)
        if request.response_format is not None:
            guidance = request.response_format.guidance()
            messages.insert(0, {"role": "system", "content": guidance})
        body = {"model": request.model, "messages": messages,
                "max_tokens": request.max_output_tokens,
                "temperature": request.temperature if
                request.temperature is not None else 0.0}
        if request.tools:
            body["tools"] = [
                {"type": "function",
                 "function": {"name": t.name,
                              "description": t.description,
                              "parameters": t.parameters or {}}}
                for t in request.tools]
        if request.top_p is not None:
            body["top_p"] = request.top_p
        if request.seed is not None:
            body["seed"] = request.seed
        if request.presence_penalty is not None:
            body["presence_penalty"] = request.presence_penalty
        if request.frequency_penalty is not None:
            body["frequency_penalty"] = request.frequency_penalty
        return body

    def _wire_result(self, payload: dict, model: str) -> ChatResult:
        choices = payload.get("choices") or []
        choice = choices[0] if choices else {}
        message = choice.get("message") or {}
        content = message.get("content") or ""
        calls = []
        for c in message.get("tool_calls") or []:
            fn = c.get("function") or {}
            try:
                args = json.loads(fn.get("arguments") or "{}")
            except json.JSONDecodeError:
                args = {}
            calls.append(ChatToolCall(
                id=c.get("id"), name=fn.get("name", ""), arguments=args))
        raw_reason = choice.get("finish_reason") or "stop"
        reason = {
            "stop": FinishReason.STOP, "length": FinishReason.LENGTH,
            "tool_calls": FinishReason.TOOL_CALLS,
            "content_filter": FinishReason.CONTENT_FILTER,
        }.get(raw_reason, FinishReason.ERROR)
        if calls and reason == FinishReason.STOP:
            reason = FinishReason.TOOL_CALLS
        usage_raw = payload.get("usage") or {}
        usage = ChatUsage(
            prompt_tokens=usage_raw.get("prompt_tokens"),
            completion_tokens=usage_raw.get("completion_tokens"),
            total_tokens=usage_raw.get("total_tokens"))
        return ChatResult(model_identity=model, content=content,
                          finish_reason=reason, usage=usage,
                          tool_calls=calls)
