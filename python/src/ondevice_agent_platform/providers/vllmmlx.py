"""vllm-mlx provider: the batched MLX serving route (macOS only).

vllm-mlx is itself a serving layer (continuous batching, trie prefix
cache, paged KV cache, OpenAI API). It is adopted as a *provider behind
the seam*, never as the foundational layer: the platform supervisor
remains the admission/queue/cancellation authority, so the route gains
prefix-cache and batching benefits inside our governance - on
deny_and_cancel the resident server is evicted and its KV cache freed.

Runs as an owned `vllm-mlx serve` child process per profile on a
loopback port; the provider speaks OpenAI chat to it. The binary is
discovered on PATH or OAP_VLLM_MLX; absent -> truthful unavailable.
Artifact residency/epoch semantics mirror the llamacpp provider.
"""
from __future__ import annotations

import base64
import json
import os
import shutil
import socket
import subprocess
import threading
import time
import urllib.request

from ..chat import ChatResult, ChatToolCall, ChatUsage, FinishReason
from ..errors import ErrorCode, PlatformError
from ..registry import VLLMMLX_PROVIDER_ID
from . import overlay
from .base import LLMProvider, ModelCacheEvicting, ProviderReadiness


def _server_binary(providers_dir: str | None = None) -> str | None:
    override = os.environ.get("OAP_VLLM_MLX")
    if override and os.path.isfile(override):
        return override
    if providers_dir:
        managed = os.path.join(providers_dir, "oap-env",
                               "bin", "vllm-mlx")
        if os.path.isfile(managed):
            return managed
    return shutil.which("vllm-mlx")


def _free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class _Server:
    def __init__(self, binary: str, model_path: str, alias: str) -> None:
        self.alias = alias
        self.port = _free_port()
        # model_path is an absolute on-disk directory from the governed
        # store; vllm-mlx loads it directly with no hub resolution.
        # --served-model-name lets wire "model" be the registry alias.
        self.proc = subprocess.Popen(
            [binary, "serve", model_path,
             "--served-model-name", alias,
             "--host", "127.0.0.1", "--port", str(self.port),
             "--enable-prefix-cache"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.last_used = time.time()

    def healthy(self) -> bool:
        return self.proc.poll() is None

    def stop(self) -> None:
        # Must finish inside the supervisor's cancellation grace (5s):
        # a slow terminate would leave the job unconfirmed and block
        # daemon-wide inference.
        if self.proc.poll() is None:
            try:
                self.proc.terminate()
                self.proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.proc.kill()


class VllmMlxProvider(LLMProvider, ModelCacheEvicting, ProviderReadiness):
    provider_id = VLLMMLX_PROVIDER_ID

    def __init__(self, store, providers_dir: str | None = None) -> None:
        self._store = store
        self._providers_dir = providers_dir
        self._servers: dict[str, _Server] = {}
        self._lock = threading.Lock()
        self._epochs: dict[str, int] = {}
        self._serving: dict[str, int] = {}
        self._profiles: list = []

    # -- readiness ---------------------------------------------------------
    @property
    def has_ready_artifact(self) -> bool:
        if _server_binary(self._providers_dir) is None:
            return False
        return any(p.source is not None and self._store.is_ready(p.source)
                   for p in self._profiles)

    def artifact_ready(self, profile) -> bool | None:
        if profile.source is None:
            return None
        return self._store.is_ready(profile.source)

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

    def evict_not_inflight(self) -> int:
        with self._lock:
            targets = [a for a in self._servers if not self._serving.get(a)]
            for a in targets:
                self._epochs[a] = self._epochs.get(a, 0) + 1
                self._servers.pop(a).stop()
        return len(targets)

    def evict_idle(self, older_than: float) -> int:
        with self._lock:
            idle = [a for a, s in self._servers.items()
                    if s.last_used < older_than and not self._serving.get(a)]
            for a in idle:
                self._epochs[a] = self._epochs.get(a, 0) + 1
                self._servers.pop(a).stop()
        return len(idle)

    def _serving_add(self, alias: str) -> None:
        self._serving[alias] = self._serving.get(alias, 0) + 1

    def _serving_drop(self, alias: str) -> None:
        n = self._serving.get(alias, 0)
        if n <= 1:
            self._serving.pop(alias, None)
        else:
            self._serving[alias] = n - 1

    # -- inference -----------------------------------------------------------
    def _serve_path(self, profile) -> str:
        return overlay.serve_text_dir(self._store._root.models_path,
                                      self._store.directory(profile.source))

    def _server_for(self, profile, token=None):
        binary = _server_binary(self._providers_dir)
        if binary is None:
            raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                                "vllm-mlx not installed "
                                "(pip install vllm-mlx)")
        if profile.source is None or not self._store.is_ready(
                profile.source):
            raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                                "model artifact not pulled")
        model_path = self._serve_path(profile)
        with self._lock:
            epoch = self._epochs.get(profile.alias, 0)
        server = _Server(binary, model_path, profile.alias)
        # Load deadline: weights map before /health answers.
        deadline = time.time() + 180
        while time.time() < deadline:
            if token is not None and token.is_cancelled:
                server.stop()
                raise PlatformError(ErrorCode.CANCELLED)
            if server.proc.poll() is not None:
                raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                                    "vllm-mlx exited during load")
            try:
                urllib.request.urlopen(
                    f"http://127.0.0.1:{server.port}/health", timeout=1)
                break
            except Exception:
                time.sleep(0.25)
        else:
            server.stop()
            raise PlatformError(ErrorCode.DEADLINE_EXCEEDED,
                                "vllm-mlx load deadline")
        with self._lock:
            # Epoch guard: an eviction during load discards this container.
            if self._epochs.get(profile.alias, 0) != epoch:
                server.stop()
                raise PlatformError(ErrorCode.CANCELLED,
                                    "container evicted during load")
            self._servers[profile.alias] = server
        return server

    def complete(self, request, profile, token=None):
        # Mark serving intent before selecting the server so a deny
        # eviction can never take a container this call is about to use.
        with self._lock:
            self._serving_add(profile.alias)
        try:
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
            body = self._wire_request(request)
            req = urllib.request.Request(
                f"http://127.0.0.1:{server.port}/v1/chat/completions",
                data=json.dumps(body).encode(),
                headers={"Content-Type": "application/json"})
            inflight = []
            observer = (token.observe(lambda: [r.close() for r in inflight])
                        if token is not None else None)
            try:
                with urllib.request.urlopen(req, timeout=300) as r:
                    inflight.append(r)
                    payload = self._read_stream(r, token)
            except Exception as e:
                if token is not None and token.is_cancelled:
                    raise PlatformError(ErrorCode.CANCELLED)
                raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                                    f"vllm-mlx call failed: {e}")
            finally:
                if token is not None and observer is not None:
                    token.remove_observer(observer)
            if token is not None and token.is_cancelled:
                raise PlatformError(ErrorCode.CANCELLED)
            server.last_used = time.time()
            return self._wire_result(payload, request.model)
        finally:
            with self._lock:
                self._serving_drop(profile.alias)

    def _read_stream(self, response, token=None):
        """The prompt/LRU prefix cache only engages on the streaming path;
        the provider aggregates SSE frames into the completion shape
        callers already expect. Mid-stream cancellation closes the
        response, ending the turn truthfully."""
        content_parts: list[str] = []
        tool_calls: dict[int, dict] = {}
        finish = None
        usage = {}
        for raw in response:
            if token is not None and token.is_cancelled:
                response.close()
                raise PlatformError(ErrorCode.CANCELLED)
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                break
            try:
                chunk = json.loads(data)
            except json.JSONDecodeError:
                continue
            if chunk.get("usage"):
                usage = chunk["usage"]
            choice = (chunk.get("choices") or [{}])[0]
            delta = choice.get("delta") or {}
            if delta.get("content"):
                content_parts.append(delta["content"])
            for tc in delta.get("tool_calls") or []:
                idx = tc.get("index", 0)
                slot = tool_calls.setdefault(
                    idx, {"id": tc.get("id"), "name": None,
                          "args": []})
                if tc.get("id"):
                    slot["id"] = tc["id"]
                fn = tc.get("function") or {}
                if fn.get("name"):
                    slot["name"] = fn["name"]
                if fn.get("arguments"):
                    slot["args"].append(fn["arguments"])
            if choice.get("finish_reason"):
                finish = choice["finish_reason"]
        message = {"content": "".join(content_parts) or None}
        if tool_calls:
            message["tool_calls"] = [
                {"id": s["id"], "function": {"name": s["name"],
                 "arguments": "".join(s["args"])}}
                for _, s in sorted(tool_calls.items())]
        return {"choices": [{"message": message,
                             "finish_reason": finish or "stop"}],
                "usage": usage}

    def cancel(self, job_id: str) -> None:
        # Cooperative cancel rides the token's in-flight close observer.
        return None

    # -- wire mapping --------------------------------------------------------
    def _wire_request(self, request) -> dict:
        messages = []
        for m in request.messages:
            msg: dict = {"role": m.role.value}
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
            if m.images:
                msg["content"] = ([
                    {"type": "text", "text": m.combined_text}
                ] if m.combined_text else []) + [
                    {"type": "image_url",
                     "image_url": {"url": "data:" + img.media_type +
                                   ";base64," +
                                   base64.b64encode(img.data).decode()}}
                    for img in m.images]
            messages.append(msg)
        body: dict = {"model": request.model, "messages": messages,
                      "max_tokens": request.max_output_tokens,
                      "temperature": request.temperature if
                      request.temperature is not None else 0.0,
                      "stream": True,
                      "stream_options": {"include_usage": True}}
        if request.top_p is not None:
            body["top_p"] = request.top_p
        if request.seed is not None:
            body["seed"] = request.seed
        if request.presence_penalty is not None:
            body["presence_penalty"] = request.presence_penalty
        if request.frequency_penalty is not None:
            body["frequency_penalty"] = request.frequency_penalty
        if request.tools:
            body["tools"] = [
                {"type": "function",
                 "function": {"name": t.name,
                              "description": t.description,
                              "parameters": t.parameters or {}}}
                for t in request.tools]
            choice = request.tool_choice
            if choice is not None:
                value = getattr(choice, "value", None)
                body["tool_choice"] = (
                    value if isinstance(value, str)
                    else {"type": "function",
                          "function": {"name": choice.name}})
        if request.response_format is not None:
            rf = request.response_format
            if rf.kind == "json_object":
                body["response_format"] = {"type": "json_object"}
            elif rf.kind == "json_schema" and rf.schema is not None:
                body["response_format"] = {
                    "type": "json_schema",
                    "json_schema": {"name": rf.name or "response",
                                    "schema": rf.schema}}
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
