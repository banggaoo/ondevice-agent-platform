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
import http.client
import json
import os
import shutil
import socket
import subprocess
import threading
import time

from ..errors import ErrorCode, PlatformError
from ..limits import PlatformLimits
from ..registry import VLLMMLX_PROVIDER_ID
from . import _openai, overlay
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
        # daemon-wide inference. Kill is always followed by a reap so the
        # zombie cannot linger; exit races between checks are benign.
        proc = self.proc
        if proc.poll() is not None:
            return
        try:
            proc.terminate()
        except OSError:
            pass
        try:
            proc.wait(timeout=2)
            return
        except subprocess.TimeoutExpired:
            pass
        try:
            proc.kill()
        except OSError:
            pass
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            pass


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

    def close(self) -> None:
        self.evict_resident()

    # -- cache lifecycle ----------------------------------------------------
    def requires_load(self, profile) -> bool:
        # A cached entry whose process died is a load, not a resident:
        # drop and reap it so defer_load admission stays truthful.
        dead = None
        with self._lock:
            server = self._servers.get(profile.alias)
            if server is None:
                return True
            if server.healthy():
                return False
            self._servers.pop(profile.alias, None)
            self._epochs[profile.alias] = \
                self._epochs.get(profile.alias, 0) + 1
            dead = server
        dead.stop()
        return True

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
            # The alias must own an epoch before load starts so an
            # eviction mid-load bumps it and the guard below discards
            # this server.
            epoch = self._epochs.setdefault(profile.alias, 0)
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
            if _openai.health_ready(server.port):
                break
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
                server.stop()
                server = self._server_for(profile, token)
            server.last_used = time.time()
            if token is not None and token.is_cancelled:
                raise PlatformError(ErrorCode.CANCELLED)
            body = self._wire_request(request)
            # The token observer must abort a call still waiting on
            # response headers, not only a streaming response: urlopen
            # hides the socket until headers arrive, so use http.client
            # and let the observer close conn.sock through that window.
            conn = http.client.HTTPConnection("127.0.0.1", server.port,
                                              timeout=300)
            inflight: list = []
            sock = None

            def _abort() -> None:
                s = sock if sock is not None else conn.sock
                if s is not None:
                    try:
                        s.shutdown(socket.SHUT_RDWR)
                    except OSError:
                        pass
                    try:
                        s.close()
                    except OSError:
                        pass
                for r in list(inflight):
                    try:
                        r.close()
                    except Exception:
                        pass

            observer = (token.observe(_abort)
                        if token is not None else None)
            try:
                # The observer may already have fired: a pre-cancelled
                # token must never send the request.
                if token is not None and token.is_cancelled:
                    raise PlatformError(ErrorCode.CANCELLED)
                conn.request("POST", "/v1/chat/completions",
                             body=json.dumps(body),
                             headers={"Content-Type": "application/json"})
                # conn.sock may clear on Connection: close - the captured
                # reference stays the abort handle.
                sock = conn.sock
                if token is not None and token.is_cancelled:
                    raise PlatformError(ErrorCode.CANCELLED)
                resp = conn.getresponse()
                if token is not None and token.is_cancelled:
                    resp.close()
                    raise PlatformError(ErrorCode.CANCELLED)
                inflight.append(resp)
                try:
                    _openai.require_ok(resp, "vllm-mlx")
                    payload = self._read_stream(resp, token)
                finally:
                    resp.close()
            except PlatformError as e:
                # A cancel can race an upstream error surfacing (e.g. the
                # observer's socket close reads as a truncated stream):
                # the caller's cancellation still reports as cancelled.
                if token is not None and token.is_cancelled:
                    raise PlatformError(ErrorCode.CANCELLED)
                raise
            except Exception as e:
                if token is not None and token.is_cancelled:
                    raise PlatformError(ErrorCode.CANCELLED)
                raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                                    f"vllm-mlx call failed: {e}")
            finally:
                if token is not None and observer is not None:
                    token.remove_observer(observer)
                conn.close()
                if sock is not None:
                    try:
                        sock.close()
                    except OSError:
                        pass
                    sock = None
            if token is not None and token.is_cancelled:
                raise PlatformError(ErrorCode.CANCELLED)
            server.last_used = time.time()
            return _openai.wire_result(payload, request.model)
        finally:
            with self._lock:
                self._serving_drop(profile.alias)

    def _read_stream(self, response, token=None):
        """The prompt/LRU prefix cache only engages on the streaming path;
        the provider aggregates SSE frames into the completion shape
        callers already expect (the platform boundary stays buffered).
        Comments and blank heartbeat lines are skipped; every data frame
        must be valid JSON, an error object fails the call, and the
        stream is only successful after a terminal finish_reason followed
        by [DONE]."""
        content_parts: list[str] = []
        tool_calls: dict[int, dict] = {}
        finish = None
        usage = {}
        done = False
        received = 0
        cap = PlatformLimits.REQUEST_BODY_BYTES
        while True:
            if token is not None and token.is_cancelled:
                response.close()
                raise PlatformError(ErrorCode.CANCELLED)
            try:
                # Bounded per-read: one huge line cannot allocate
                # unboundedly before the cumulative size check below.
                raw = response.readline(cap + 1 - received)
            except Exception:
                if token is not None and token.is_cancelled:
                    raise PlatformError(ErrorCode.CANCELLED)
                raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                                    "upstream stream failed")
            if not raw:
                break
            received += len(raw)
            if received > cap:
                raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                                    "upstream stream exceeded size bound")
            line = raw.decode("utf-8", "replace").strip()
            if not line or line.startswith(":"):
                continue
            if not line.startswith("data:"):
                raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                                    "upstream stream frame malformed")
            data = line[5:].strip()
            if data == "[DONE]":
                done = True
                break
            try:
                chunk = json.loads(data)
            except json.JSONDecodeError:
                raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                                    "upstream stream frame not JSON")
            if not isinstance(chunk, dict):
                raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                                    "upstream stream frame malformed")
            if chunk.get("error") is not None:
                raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                                    "upstream stream error frame")
            if isinstance(chunk.get("usage"), dict):
                usage = chunk["usage"]
            choices = chunk.get("choices")
            if choices is not None and (
                    not isinstance(choices, list) or len(choices) > 1
                    or (choices and not isinstance(choices[0], dict))):
                raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                                    "upstream stream choices malformed")
            if not choices:
                continue
            choice = choices[0]
            delta = choice.get("delta")
            if delta is None:
                delta = {}
            if not isinstance(delta, dict):
                raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                                    "upstream stream delta malformed")
            text = delta.get("content")
            if text is not None:
                if not isinstance(text, str):
                    raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                                        "upstream content delta malformed")
                content_parts.append(text)
            tcs = delta.get("tool_calls")
            if tcs is not None and not isinstance(tcs, list):
                raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                                    "upstream tool delta malformed")
            for tc in tcs or []:
                if not isinstance(tc, dict):
                    raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                                        "upstream tool delta malformed")
                idx = tc.get("index", 0)
                slot = tool_calls.setdefault(
                    idx, {"id": tc.get("id"), "name": None,
                          "args": []})
                if tc.get("id"):
                    slot["id"] = tc["id"]
                fn = tc.get("function")
                if fn is not None and not isinstance(fn, dict):
                    raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                                        "upstream tool delta malformed")
                fn = fn or {}
                if fn.get("name"):
                    slot["name"] = fn["name"]
                if fn.get("arguments"):
                    slot["args"].append(fn["arguments"])
            if choice.get("finish_reason") is not None:
                finish = choice["finish_reason"]
        if not done:
            raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                                "upstream stream ended before [DONE]")
        if finish not in _openai.FINISH_REASONS:
            raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                                "upstream stream lacks a terminal "
                                "finish reason")
        message = {"content": "".join(content_parts) or None}
        if tool_calls:
            message["tool_calls"] = [
                {"id": s["id"], "function": {"name": s["name"],
                 "arguments": "".join(s["args"])}}
                for _, s in sorted(tool_calls.items())]
        return {"choices": [{"message": message,
                             "finish_reason": finish}],
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
                # vllm-mlx enforces the schema itself; strict passes
                # through unchanged (guidance-only providers refuse it).
                body["response_format"] = {
                    "type": "json_schema",
                    "json_schema": {"name": rf.name or "response",
                                    "schema": rf.schema,
                                    **({"strict": rf.strict}
                                       if rf.strict is not None else {})}}
        return body
