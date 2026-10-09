"""vision-hybrid provider: the OCR-first composite route.

Deterministic two-tier serving for image turns. Tier one is Apple Vision
(`oap-vision-bridge` stdio helper - native VNRecognizeTextRequest, no
model weights, no token usage). Tier two is the declared `delegate` VLM
alias (e.g. qwen-vl), used when OCR cannot answer: no usable text, low
confidence, or a question that is not text-extraction at all.

The policy is code-owned and deterministic - no model decides which tier
serves. A missing bridge degrades truthfully to the VLM tier rather than
failing; a missing delegate fails loudly at wiring time.
"""
from __future__ import annotations

import base64
import json
import os
import re
import shutil
import subprocess
import threading

from ..chat import (ChatMessage, ChatRequest, ChatResult, ChatRole,
                    FinishReason, NamedToolChoice, ToolChoice)
from ..errors import ErrorCode, PlatformError
from ..registry import VISIONHYBRID_PROVIDER_ID
from .base import LLMProvider, ModelCacheEvicting, ProviderReadiness


def _vision_bridge(providers_dir: str | None = None) -> str | None:
    override = os.environ.get("OAP_VISION_BRIDGE")
    if override and os.path.isfile(override) and os.access(override, os.X_OK):
        return override
    found = shutil.which("oap-vision-bridge")
    if found:
        return found
    # Repo-relative built product: <repo>/.build/{debug,release} - valid
    # only when the package runs from a source checkout.
    here = os.path.dirname(os.path.abspath(__file__))
    repo = os.path.abspath(os.path.join(here, "..", "..", "..", ".."))
    candidates = [
        os.path.join(repo, ".build", "debug", "oap-vision-bridge"),
        os.path.join(repo, ".build", "release", "oap-vision-bridge")]
    if providers_dir:
        candidates += [
            os.path.join(providers_dir, "oap-vision-bridge"),
            os.path.join(providers_dir, "oap-env", "bin",
                         "oap-vision-bridge")]
    for candidate in candidates:
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None


# Phrase hints that a prompt asks for text extraction rather than scene
# understanding. Verb forms only - nouns like "letters"/"price"/"total"
# appear equally in non-extraction questions ("what color are the
# letters") and a direct OCR answer there is wrong. An unmatched prompt
# escalates to the VLM with the OCR text as context, never fails.
_OCR_INTENT = re.compile(
    r"\b(ocr|read|reads|reading|transcri\w*|extract\w*|says|say\b|"
    r"written|digitiz\w*|spell\w*|recogniz\w*)\b"
    r"|what\b.{0,30}\b(say|says|write|writes|written)\b",
    re.IGNORECASE)

# Below this mean confidence the OCR output is not trustworthy enough to
# answer an extraction prompt directly.
_OCR_CONFIDENCE_FLOOR = 0.55


class VisionHybridProvider(LLMProvider, ModelCacheEvicting,
                           ProviderReadiness):
    """OCR-first composite: Apple Vision tier plus a bound VLM delegate.

    `ocr` is a test seam - production uses the bridge subprocess; tests
    inject a callable bytes -> [(text, confidence)] or None.
    """
    provider_id = VISIONHYBRID_PROVIDER_ID

    def __init__(self, ocr=None, providers_dir: str | None = None) -> None:
        # Same discipline as the apple bridge: _lock owns _proc; _io_lock
        # serializes the stdin/stdout exchange; _kill takes neither.
        self._lock = threading.Lock()
        self._io_lock = threading.Lock()
        self._proc: subprocess.Popen | None = None
        self._ocr = ocr
        self._providers_dir = providers_dir
        # alias -> (delegate_provider, delegate_profile)
        self._bindings: dict[str, tuple] = {}
        self._profiles: list = []

    # -- wiring -------------------------------------------------------------

    def bind(self, alias: str, provider, profile) -> None:
        self._bindings[alias] = (provider, profile)

    def track_profiles(self, profiles) -> None:
        self._profiles = list(profiles)

    # -- readiness (reports through the delegate, truthfully) ---------------

    @property
    def has_ready_artifact(self) -> bool:
        for dep, dprofile in self._bindings.values():
            ready = getattr(dep, "artifact_ready", None)
            if ready is None or ready(dprofile) is not False:
                return True
        return False

    def artifact_ready(self, profile) -> bool | None:
        binding = self._bindings.get(profile.alias)
        if binding is None:
            return None
        dep, dprofile = binding
        ready = getattr(dep, "artifact_ready", None)
        return ready(dprofile) if ready is not None else None

    def requires_load(self, profile) -> bool:
        binding = self._bindings.get(profile.alias)
        if binding is None:
            return True
        dep, dprofile = binding
        return dep.requires_load(dprofile)

    def evict_resident(self) -> int:
        freed = 0
        seen = set()
        for dep, _profile in self._bindings.values():
            if id(dep) in seen:
                continue
            seen.add(id(dep))
            evict = getattr(dep, "evict_resident", None)
            if callable(evict):
                freed += evict()
        return freed

    # -- validation -----------------------------------------------------------

    def validate(self, request, profile) -> None:
        # Guidance-only composite: refuse what neither tier can honor.
        rf = request.response_format
        if rf is not None and rf.strict is True:
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                "strict json schema is not enforced by "
                                "this provider")
        if isinstance(request.tool_choice, NamedToolChoice) \
                or request.tool_choice == ToolChoice.REQUIRED:
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                "forced tool choice is not guaranteed")

    # -- the hybrid policy ---------------------------------------------------

    def complete(self, request: ChatRequest, profile, token=None):
        binding = self._bindings.get(profile.alias)
        if binding is None:
            raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                                "vision-hybrid delegate not wired")
        dep, dprofile = binding
        images = [img for m in request.messages for img in m.images]
        if token is not None and token.is_cancelled:
            raise PlatformError(ErrorCode.CANCELLED)
        if not images:
            # A plain text turn on the vision route: the VLM tier covers it.
            return dep.complete(request, dprofile, token=token)

        ocr = self._run_ocr(images, token)
        if token is not None and token.is_cancelled:
            raise PlatformError(ErrorCode.CANCELLED)
        if ocr:
            text, confidence = self._render(ocr)
            if confidence >= _OCR_CONFIDENCE_FLOOR:
                if self._extraction_intent(request):
                    # Deterministic tier-one answer: extracted text, no
                    # model call, no fabricated token usage. Structured
                    # observations (text/confidence/position) ride along
                    # for callers that need boxes, e.g. ARTEMIS OCR.
                    return ChatResult(model_identity=request.model,
                                      content=text,
                                      finish_reason=FinishReason.STOP,
                                      tool_calls=[], usage=None,
                                      extra={"oap_ocr": [
                                          {"text": t,
                                           "confidence": c,
                                           "position": p}
                                          for t, c, p in ocr]})
                # Trustworthy OCR but the question is not extraction:
                # the VLM answers with the OCR text as context.
                return dep.complete(
                    self._with_ocr_context(request, text),
                    dprofile, token=token)
        # No usable OCR evidence: the delegate answers unaided.
        return dep.complete(request, dprofile, token=token)

    @staticmethod
    def _render(ocr) -> tuple[str, float]:
        texts = [t for t, _c, _p in ocr]
        confidence = sum(c for _t, c, _p in ocr) / max(len(ocr), 1)
        return "\n".join(texts), confidence

    @staticmethod
    def _extraction_intent(request: ChatRequest) -> bool:
        user_text = "\n".join(
            m.combined_text for m in reversed(request.messages)
            if m.role == ChatRole.USER)
        return bool(_OCR_INTENT.search(user_text or ""))

    @staticmethod
    def _with_ocr_context(request: ChatRequest, text: str) -> ChatRequest:
        clone = ChatRequest(**{**request.__dict__})
        clone.messages = [ChatMessage(
            role=ChatRole.SYSTEM,
            parts=["Apple Vision OCR of the attached image(s):\n" + text])
        ] + list(request.messages)
        return clone

    # -- apple vision tier ----------------------------------------------------

    def _run_ocr(self, images, token) -> list | None:
        """[(text, confidence, position)] across all images, or None when
        the tier is unavailable/failed - callers escalate, they never
        invent. position is the bridge's pixel vertices or None."""
        if self._ocr is not None:
            out = []
            for img in images:
                for item in self._ocr(img.data) or []:
                    t, c, *rest = item
                    out.append((t, c, rest[0] if rest else None))
            return out or None
        if _vision_bridge(self._providers_dir) is None:
            return None
        out = []
        try:
            proc = self._ensure()
            observer = (token.observe(lambda: self._kill(proc))
                        if token is not None else None)
            try:
                with self._io_lock:
                    for img in images:
                        payload = {"image": base64.b64encode(
                            img.data).decode()}
                        proc.stdin.write(json.dumps(payload) + "\n")
                        proc.stdin.flush()
                        line = proc.stdout.readline()
                        if not line:
                            if token is not None and token.is_cancelled:
                                raise PlatformError(ErrorCode.CANCELLED)
                            return None
                        try:
                            result = json.loads(line)
                        except json.JSONDecodeError:
                            return None
                        if "error" in result:
                            if result.get("code") == "invalid_request":
                                raise PlatformError(
                                    ErrorCode.INVALID_REQUEST,
                                    result.get("error", "invalid image"))
                            return None
                        for obs in result.get("lines") or []:
                            t = obs.get("text")
                            c = obs.get("confidence")
                            if isinstance(t, str) and t.strip() \
                                    and isinstance(c, (int, float)):
                                out.append((t, float(c),
                                            obs.get("position")))
            except PlatformError:
                raise
            except (OSError, ValueError):
                if token is not None and token.is_cancelled:
                    raise PlatformError(ErrorCode.CANCELLED)
                with self._lock:
                    if self._proc is proc:
                        self._proc = None
                return None
            finally:
                if token is not None and observer is not None:
                    token.remove_observer(observer)
        except PlatformError:
            raise
        except Exception:
            return None
        return out or None

    def _ensure(self):
        binary = _vision_bridge(self._providers_dir)
        if binary is None:
            raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                                "vision bridge helper not built")
        with self._lock:
            if self._proc is not None and self._proc.poll() is None:
                return self._proc
            self._proc = subprocess.Popen(
                [binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                text=True, bufsize=1)
            return self._proc

    def _kill(self, proc) -> None:
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
        # Delegates are owned/closed by the supervisor's provider set;
        # only the OCR helper is ours to reap.
        with self._lock:
            proc = self._proc
            self._proc = None
        if proc is None:
            return
        try:
            proc.terminate()
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
        for pipe in (proc.stdin, proc.stdout):
            try:
                if pipe is not None:
                    pipe.close()
            except (OSError, ValueError):
                pass
