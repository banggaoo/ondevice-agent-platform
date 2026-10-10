"""MLX provider via the Python `mlx-lm`/`mlx-vlm` packages (macOS only).

MLX needs Metal - a macOS/arm64 requirement enforced by the requirements
model before this provider is ever registered. Containers are the loaded
(model, processor) pairs; residency/eviction/epoch semantics mirror the
Swift PlatformMLX provider.
"""
from __future__ import annotations

import importlib.util
import threading
import time
from io import BytesIO

from ..chat import (ChatResult, ChatToolCall, ChatUsage, FinishReason,
                    NamedToolChoice, ToolChoice)
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


def _module_present(name: str) -> bool:
    """Presence check without import: the readiness path must never pay
    the multi-second mlx import under the supervisor status lock."""
    try:
        return importlib.util.find_spec(name) is not None
    except (ImportError, ValueError):
        return False


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
        # Health-path answer only: stat the store and probe module
        # presence by spec. Importing mlx-lm here once blocked admin
        # reads for seconds under the supervisor lock.
        for p in self._profiles:
            if p.source is None or not self._store.is_ready(p.source):
                continue
            dep = "mlx_vlm" if "vision" in p.capabilities else "mlx_lm"
            if _module_present(dep):
                return True
        return False

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

    def close(self) -> None:
        self.evict_resident()

    def validate(self, request, profile) -> None:
        # mlx-lm/vlm's sampler surface has no presence/frequency penalty;
        # tool_choice beyond auto/none is not guaranteed; strict JSON is
        # guidance-only here. Refuse all of it rather than drop silently.
        for value, name in ((request.presence_penalty, "presence_penalty"),
                            (request.frequency_penalty,
                             "frequency_penalty")):
            if value is not None and float(value) != 0.0:
                raise PlatformError(
                    ErrorCode.INVALID_REQUEST,
                    f"{name} is not expressible on the mlx route")
        # Forced tool choice (REQUIRED / NamedToolChoice) is best-effort here:
        # a named choice is enforced by forwarding only that tool's schema so
        # the grammar can only name it; REQUIRED degrades to AUTO behaviour.
        rf = request.response_format
        if rf is not None and rf.strict is True:
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                "strict json schema is not enforced by "
                                "this provider")

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
            # The alias must own an epoch before load starts so an
            # eviction mid-load bumps it and the guard below discards
            # this container.
            epoch = self._epochs.setdefault(profile.alias, 0)
        if vision:
            vlm = _import_mlx_vlm()
            if vlm is None:
                raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                                    "mlx-vlm not installed")
            model, processor = vlm.load(path)
            budget = profile.image_max_soft_tokens
            if budget is not None:
                # Raise the image token budget for processors that size
                # images by soft-token patches (Gemma4's
                # max_soft_tokens: 70/140/280/560/1120). The prompt's
                # expansion strings must be rebuilt or the fallback path
                # would expand <image> at the stale default.
                ip = getattr(processor, "image_processor", None)
                if ip is not None and hasattr(ip, "max_soft_tokens"):
                    ip.max_soft_tokens = budget
                if hasattr(processor, "image_seq_length"):
                    processor.image_seq_length = budget
                if all(hasattr(processor, a) for a in
                        ("boi_token", "eoi_token", "image_token")):
                    processor.full_image_sequence = (
                        f"{processor.boi_token}"
                        f"{processor.image_token * budget}"
                        f"{processor.eoi_token}")
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

    def _tool_schemas(self, request) -> list | None:
        # tool_choice=none suppresses schema forwarding AND any parsed
        # tool calls. A named choice forwards only that tool's schema so the
        # model can only emit that function name.
        if not request.tools or request.tool_choice == ToolChoice.NONE:
            return None
        tools = request.tools
        if isinstance(request.tool_choice, NamedToolChoice):
            tools = [t for t in request.tools
                     if t.name == request.tool_choice.name]
        return [
            {"type": "function",
             "function": {"name": t.name, "description": t.description,
                          "parameters": t.parameters or {}}}
            for t in tools]

    def _complete_text(self, container, request, profile, flag) -> ChatResult:
        lm = _import_mlx_lm()
        tokenizer = container.processor
        # Thinking stays explicitly off: reasoning blocks are not part of
        # this platform's serving contract (and would burn output tokens).
        prompt = tokenizer.apply_chat_template(
            self._messages_payload(request, profile),
            tokenize=False, add_generation_prompt=True,
            tools=self._tool_schemas(request), enable_thinking=False)
        text, prompt_tokens, completion_tokens = "", 0, 0
        finish = None
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
            if getattr(chunk, "finish_reason", None):
                finish = chunk.finish_reason
        return self._result(text, request, prompt_tokens,
                            completion_tokens, finish)

    def _vlm_messages(self, request) -> list[dict]:
        """Full ordered history for apply_chat_template: every turn is
        preserved; image-bearing user content carries text/image markers
        in order on that turn. Tool calls/results ride through unchanged."""
        messages = []
        for m in request.messages:
            role = ("system" if m.role.value in ("system", "developer")
                    else m.role.value)
            msg: dict = {"role": role}
            if m.images:
                msg["content"] = (
                    [{"type": "text", "text": t} for t in m.parts]
                    + [{"type": "image"} for _ in m.images])
            else:
                msg["content"] = m.combined_text or None
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

    def _complete_vlm(self, container, request, profile, flag) -> ChatResult:
        vlm = _import_mlx_vlm()
        if vlm is None:
            raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                                "mlx-vlm not installed")
        stream_generate = getattr(vlm, "stream_generate", None)
        apply_template = getattr(
            getattr(vlm, "prompt_utils", None), "apply_chat_template", None)
        load_image = getattr(getattr(vlm, "utils", None), "load_image", None)
        if stream_generate is None or apply_template is None \
                or load_image is None:
            raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                                "mlx-vlm version lacks the required API")
        # process_image only normalizes str inputs; BytesIO would reach the
        # transformers processor unconverted. Decode to PIL via load_image
        # (RGB + EXIF normalization) before handing images to stream_generate.
        images = [load_image(BytesIO(img.data))
                  for m in request.messages for img in m.images]
        kwargs: dict = {"enable_thinking": False}
        tools = self._tool_schemas(request)
        if tools is not None:
            kwargs["tools"] = tools
        prompt = apply_template(
            container.processor, container.model.config,
            self._vlm_messages(request),
            add_generation_prompt=True, num_images=len(images), **kwargs)
        # mlx-vlm 0.7.x stream_generate(model, processor, prompt, image=...);
        # kwargs flow into generate_step where the temperature key is
        # `temperature` (not the mlx-lm `temp` sampler name).
        gen_kwargs = {"max_tokens": request.max_output_tokens,
                      "temperature": request.temperature
                      if request.temperature is not None else 0.0}
        if request.top_p is not None:
            gen_kwargs["top_p"] = request.top_p
        if request.seed is not None:
            gen_kwargs["seed"] = request.seed
        text, prompt_tokens, completion_tokens = "", 0, 0
        finish = None
        for chunk in stream_generate(
                container.model, container.processor, prompt,
                image=images if images else None, **gen_kwargs):
            if flag.is_set():
                raise PlatformError(ErrorCode.CANCELLED)
            text += getattr(chunk, "text", "")
            prompt_tokens = getattr(chunk, "prompt_tokens", prompt_tokens)
            completion_tokens = getattr(chunk, "generation_tokens",
                                        completion_tokens)
            if getattr(chunk, "finish_reason", None):
                finish = chunk.finish_reason
        return self._result(text, request, prompt_tokens,
                            completion_tokens, finish)

    def _result(self, text: str, request, prompt_tokens,
                completion_tokens, finish=None) -> ChatResult:
        import json as _json
        import re
        calls: list[ChatToolCall] = []
        content = text
        # mlx-lm tool templates emit calls as JSON inside the text; parse
        # the common {"name":..., "arguments":{...}} envelope back out.
        if request.tools and request.tool_choice != ToolChoice.NONE:
            for match in re.finditer(
                    r'\{[^{}]*"name"\s*:\s*"([^"]+)"[^{}]*'
                    r'"arguments"\s*:\s*(\{.*?\})\s*\}', text, re.DOTALL):
                try:
                    calls.append(ChatToolCall(
                        name=match.group(1),
                        arguments=_json.loads(match.group(2))))
                except _json.JSONDecodeError:
                    pass
            if not calls:
                # Gemma's template emits its own markup: the tool_call
                # tag pair, "call:", the name, and brace args whose
                # string values are wrapped in its quote tokens.
                _OPEN = r'\x3c\x7ctool_call\x3e'
                _CLOSE = r'\x3ctool_call\x7c\x3e'
                _Q = r'\x3c\x7c"\x7c\x3e'
                for match in re.finditer(
                        _OPEN + r'call:(\w+)\s*\{(.*?)\}' + _CLOSE,
                        text, re.DOTALL):
                    args = {}
                    for am in re.finditer(
                            r'(\w+)\s*:\s*(?:' + _Q + r'(.*?)' + _Q
                            + r'|"([^"]*)"|((?:[^,}]|,(?!\s*\w+\s*:))*))',
                            match.group(2), re.DOTALL):
                        value = None
                        if am.group(2) is not None:
                            value = am.group(2)
                        elif am.group(3) is not None:
                            value = am.group(3)
                        else:
                            raw = am.group(4).strip()
                            # Unquoted values may arrive wrapped in the
                            # model's own |...| borders instead of the
                            # quote tokens; drop the border chars.
                            if raw.startswith("|") and raw.endswith("|"):
                                raw = raw[1:-1].strip()
                            try:
                                value = _json.loads(raw)
                            except _json.JSONDecodeError:
                                value = raw
                        if isinstance(value, str):
                            # Gemma writes check-line keywords as
                            # "verify@end:"/"assert@end:"; align with the
                            # declared "<kw>:" form.
                            value = re.sub(r'\b(verify|assert)@end(?=:)',
                                           r'\1', value)
                        args[am.group(1)] = value
                    calls.append(ChatToolCall(name=match.group(1),
                                              arguments=args))
            if calls:
                content = re.sub(r'<think>.*?</think>', '', text,
                                 flags=re.DOTALL)
                content = re.sub(
                    r'<\|channel>.*?<channel\|>', '', content,
                    flags=re.DOTALL)
                content = re.sub(
                    r'\x3c\x7ctool_call\x3e.*?\x3ctool_call\x7c\x3e',
                    '', content, flags=re.DOTALL).strip()
        if calls:
            reason = FinishReason.TOOL_CALLS
        elif finish == "length":
            reason = FinishReason.LENGTH
        else:
            reason = FinishReason.STOP
        usage = ChatUsage(prompt_tokens=prompt_tokens or None,
                          completion_tokens=completion_tokens or None,
                          total_tokens=(prompt_tokens + completion_tokens)
                          if prompt_tokens and completion_tokens else None)
        return ChatResult(model_identity=request.model, content=content,
                          finish_reason=reason, usage=usage,
                          tool_calls=calls)
