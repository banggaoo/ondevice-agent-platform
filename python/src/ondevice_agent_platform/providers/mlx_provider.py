"""MLX provider via the Python `mlx-lm`/`mlx-vlm` packages (macOS only).

MLX needs Metal - a macOS/arm64 requirement enforced by the requirements
model before this provider is ever registered. Containers are the loaded
(model, processor) pairs; residency/eviction/epoch semantics mirror the
Swift PlatformMLX provider.
"""
from __future__ import annotations

import os
import threading
import time

from ..chat import ChatResult, ChatToolCall, ChatUsage, FinishReason
from ..errors import ErrorCode, PlatformError
from ..registry import MLX_PROVIDER_ID
from .base import LLMProvider, ModelCacheEvicting, ProviderReadiness


def _import_mlx_lm():
    try:
        import mlx_lm  # type: ignore
        return mlx_lm
    except ImportError:
        return None


def _import_mlx_vlm():
    try:
        import mlx_vlm  # type: ignore
        return mlx_vlm
    except ImportError:
        return None


class _Container:
    def __init__(self, model, processor, vlm: bool) -> None:
        self.model = model
        self.processor = processor
        self.vlm = vlm
        self.last_used = time.time()


class MLXProvider(LLMProvider, ModelCacheEvicting, ProviderReadiness):
    provider_id = MLX_PROVIDER_ID

    def __init__(self, store) -> None:
        self._store = store
        self._containers: dict[str, _Container] = {}
        self._epochs: dict[str, int] = {}
        self._serving: dict[str, int] = {}
        self._profiles: list = []
        self._lock = threading.Lock()

    def track_profiles(self, profiles) -> None:
        self._profiles = list(profiles)

    @property
    def has_ready_artifact(self) -> bool:
        if _import_mlx_lm() is None:
            return False
        return any(p.source is not None and self._store.is_ready(p.source)
                   for p in self._profiles)

    def artifact_ready(self, profile) -> bool | None:
        if profile.source is None:
            return None
        return self._store.is_ready(profile.source)

    def requires_load(self, profile) -> bool:
        with self._lock:
            return profile.alias not in self._containers

    def evict_resident(self) -> int:
        with self._lock:
            count = len(self._containers)
            self._containers.clear()
            for alias in list(self._epochs):
                self._epochs[alias] += 1
        return count

    def evict_not_inflight(self) -> int:
        with self._lock:
            targets = [a for a in self._containers
                       if not self._serving.get(a)]
            for a in targets:
                self._epochs[a] = self._epochs.get(a, 0) + 1
                del self._containers[a]
        return len(targets)

    def evict_idle(self, older_than: float) -> int:
        with self._lock:
            idle = [a for a, c in self._containers.items()
                    if c.last_used < older_than and not self._serving.get(a)]
            for a in idle:
                self._epochs[a] = self._epochs.get(a, 0) + 1
                del self._containers[a]
        return len(idle)

    def _serving_add(self, alias: str) -> None:
        self._serving[alias] = self._serving.get(alias, 0) + 1

    def _serving_drop(self, alias: str) -> None:
        n = self._serving.get(alias, 0)
        if n <= 1:
            self._serving.pop(alias, None)
        else:
            self._serving[alias] = n - 1

    def cancel(self, job_id: str) -> None:
        # Cooperative cancellation rides the job's CancellationToken, which
        # the supervisor cancels directly; no per-job map is needed.
        return None

    def _container_for(self, profile):
        if profile.source is None or not self._store.is_ready(profile.source):
            raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                                "model artifact not pulled")
        path = self._store.directory(profile.source)
        vision = "vision" in profile.capabilities
        if not vision:
            from . import overlay
            path = overlay.serve_text_dir(
                self._store._root.models_path, path)
        with self._lock:
            epoch = self._epochs.get(profile.alias, 0)
        if vision:
            vlm = _import_mlx_vlm()
            if vlm is None:
                raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                                    "mlx-vlm not installed")
            model, processor = vlm.load(path)
        else:
            lm = _import_mlx_lm()
            if lm is None:
                raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                                    "mlx-lm not installed")
            model, processor = lm.load(path)
        container = _Container(model, processor, vision)
        with self._lock:
            # Epoch guard: an eviction during load discards this container.
            if self._epochs.get(profile.alias, 0) != epoch:
                raise PlatformError(ErrorCode.CANCELLED,
                                    "container evicted during load")
            self._containers[profile.alias] = container
        return container

    def complete(self, request, profile, token=None):
        if _import_mlx_lm() is None:
            raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                                "mlx-lm not installed")
        with self._lock:
            self._serving_add(profile.alias)
        try:
            with self._lock:
                container = self._containers.get(profile.alias)
            if container is None:
                container = self._container_for(profile)
            flag = threading.Event()
            observer = (token.observe(flag.set)
                        if token is not None else None)
            try:
                container.last_used = time.time()
                if token is not None and token.is_cancelled:
                    raise PlatformError(ErrorCode.CANCELLED)
                if container.vlm:
                    return self._complete_vlm(container, request, profile,
                                              flag)
                return self._complete_text(container, request, profile,
                                           flag)
            finally:
                if token is not None and observer is not None:
                    token.remove_observer(observer)
                container.last_used = time.time()
        finally:
            with self._lock:
                self._serving_drop(profile.alias)

    def _messages_payload(self, request, profile) -> list[dict]:
        messages = []
        for m in request.messages:
            if m.role.value in ("system", "developer"):
                role = "system"
            else:
                role = m.role.value
            msg = {"role": role, "content": m.combined_text or None}
            if m.images:
                msg["images"] = [
                    {"data": img.data, "media_type": img.media_type}
                    for img in m.images]
            if m.tool_calls:
                msg["tool_calls"] = [
                    {"id": c.id or f"call_{i}", "type": "function",
                     "function": {"name": c.name,
                                  "arguments": c.arguments}}
                    for i, c in enumerate(m.tool_calls)]
            if m.tool_call_id:
                msg["tool_call_id"] = m.tool_call_id
            messages.append(msg)
        if request.response_format is not None:
            messages.insert(0, {"role": "system",
                                "content": request.response_format.guidance()})
        return messages

    def _complete_text(self, container, request, profile, flag) -> ChatResult:
        lm = _import_mlx_lm()
        tokenizer = container.processor
        tools = None
        if request.tools:
            tools = [
                {"type": "function",
                 "function": {"name": t.name, "description": t.description,
                              "parameters": t.parameters or {}}}
                for t in request.tools]
        prompt = tokenizer.apply_chat_template(
            self._messages_payload(request, profile),
            tokenize=False, add_generation_prompt=True,
            tools=tools)
        text, prompt_tokens, completion_tokens = "", 0, 0
        # mlx-lm >=0.29 moved sampling to a Sampler callable; temperature/
        # top_p kwargs are no longer accepted by stream_generate.
        from mlx_lm.sample_utils import make_sampler
        sampler = make_sampler(
            temp=request.temperature or 0.0,
            top_p=request.top_p if request.top_p is not None else 1.0)
        if request.seed is not None:
            import mlx.core as mx
            mx.random.seed(request.seed)
        for chunk in lm.stream_generate(
                container.model, tokenizer, prompt=prompt,
                max_tokens=request.max_output_tokens,
                sampler=sampler):
            if flag.is_set():
                raise PlatformError(ErrorCode.CANCELLED)
            text += getattr(chunk, "text", "")
            prompt_tokens = getattr(chunk, "prompt_tokens", prompt_tokens)
            completion_tokens = getattr(chunk, "generation_tokens",
                                        completion_tokens)
        return self._result(text, request, prompt_tokens, completion_tokens)

    def _complete_vlm(self, container, request, profile, flag) -> ChatResult:
        vlm = _import_mlx_vlm()
        images = [img.data for m in request.messages for img in m.images]
        prompt_text = self._messages_payload(request, profile)[-1]["content"]
        output = vlm.generate(
            container.model, container.processor, prompt_text,
            image=images if images else None,
            max_tokens=request.max_output_tokens,
            temp=request.temperature or 0.0)
        if flag.is_set():
            raise PlatformError(ErrorCode.CANCELLED)
        text = output.text if hasattr(output, "text") else str(output)
        return self._result(text, request, None, None)

    def _result(self, text: str, request, prompt_tokens,
                completion_tokens) -> ChatResult:
        import json as _json
        import re
        calls: list[ChatToolCall] = []
        content = text
        # mlx-lm tool templates emit calls as JSON inside the text; parse
        # the common {"name":..., "arguments":{...}} envelope back out.
        if request.tools:
            for match in re.finditer(
                    r'\{[^{}]*"name"\s*:\s*"([^"]+)"[^{}]*'
                    r'"arguments"\s*:\s*(\{.*?\})\s*\}', text, re.DOTALL):
                try:
                    calls.append(ChatToolCall(
                        name=match.group(1),
                        arguments=_json.loads(match.group(2))))
                except _json.JSONDecodeError:
                    pass
            if calls:
                content = re.sub(r'<think>.*?</think>', '', text,
                                 flags=re.DOTALL).strip()
        reason = (FinishReason.TOOL_CALLS if calls else FinishReason.STOP)
        usage = ChatUsage(prompt_tokens=prompt_tokens or None,
                          completion_tokens=completion_tokens or None,
                          total_tokens=(prompt_tokens + completion_tokens)
                          if prompt_tokens and completion_tokens else None)
        return ChatResult(model_identity=request.model, content=content,
                          finish_reason=reason, usage=usage,
                          tool_calls=calls)
