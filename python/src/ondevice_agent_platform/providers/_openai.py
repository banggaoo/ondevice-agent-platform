"""Shared strictness for providers that front an OpenAI-chat upstream.

Both HTTP providers speak the same wire shape to an owned loopback
server; the parsing rules are identical by contract: one choice, a valid
message, a supported terminal finish reason, and tool calls whose
arguments are object-valued JSON. Anything else fails
provider_unavailable truthfully - it never becomes an empty answer, a
synthesized stop, or silently objectified garbage.
"""
from __future__ import annotations

import http.client
import json

from ..chat import ChatResult, ChatToolCall, ChatUsage, FinishReason
from ..errors import ErrorCode, PlatformError
from ..limits import PlatformLimits

FINISH_REASONS = {
    "stop": FinishReason.STOP,
    "length": FinishReason.LENGTH,
    "tool_calls": FinishReason.TOOL_CALLS,
    "content_filter": FinishReason.CONTENT_FILTER,
}


def health_ready(port: int, timeout: float = 1.0) -> bool:
    """Loopback health probe for an owned child. http.client speaks to the
    socket directly - urllib honors proxy env vars, which must never
    interpose on a local helper. The response is always drained/closed."""
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    try:
        conn.request("GET", "/health")
        resp = conn.getresponse()
        try:
            resp.read()
            return 200 <= resp.status < 300
        finally:
            resp.close()
    except Exception:
        return False
    finally:
        conn.close()


def require_ok(resp, label: str) -> None:
    """Any non-2xx upstream status fails; detail carries only the status
    code, never the provider's response body."""
    if not (200 <= resp.status < 300):
        raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                            f"{label} upstream HTTP {resp.status}")


def wire_result(payload, model: str) -> ChatResult:
    if not isinstance(payload, dict):
        raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                            "upstream payload malformed")
    if payload.get("error") is not None:
        raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                            "upstream reported an error")
    choices = payload.get("choices")
    if not isinstance(choices, list) or len(choices) != 1 \
            or not isinstance(choices[0], dict):
        raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                            "upstream choices malformed")
    choice = choices[0]
    message = choice.get("message")
    if not isinstance(message, dict):
        raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                            "upstream message missing")
    content = message.get("content")
    if content is not None and not isinstance(content, str):
        raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                            "upstream content malformed")
    raw_reason = choice.get("finish_reason")
    if raw_reason not in FINISH_REASONS:
        raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                            "upstream finish reason missing/unsupported")
    reason = FINISH_REASONS[raw_reason]
    raw_calls = message.get("tool_calls")
    calls: list[ChatToolCall] = []
    seen_ids: set[str] = set()
    if raw_calls is not None:
        if not isinstance(raw_calls, list):
            raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                                "upstream tool_calls malformed")
        if len(raw_calls) > PlatformLimits.CHAT_TOOL_CALLS_PER_MESSAGE:
            raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                                "upstream tool_calls exceeds bound")
        for c in raw_calls:
            if not isinstance(c, dict):
                raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                                    "upstream tool call malformed")
            fn = c.get("function")
            cid = c.get("id")
            name = fn.get("name") if isinstance(fn, dict) else None
            if not isinstance(cid, str) or not cid \
                    or not isinstance(name, str) or not name:
                raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                                    "upstream tool call lacks id/name")
            if cid in seen_ids:
                raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                                    "upstream duplicate tool call id")
            seen_ids.add(cid)
            raw_args = fn.get("arguments")
            if isinstance(raw_args, str):
                try:
                    args = json.loads(raw_args)
                except json.JSONDecodeError:
                    raise PlatformError(
                        ErrorCode.PROVIDER_UNAVAILABLE,
                        "upstream tool arguments not valid JSON")
            else:
                args = raw_args
            if not isinstance(args, dict):
                raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                                    "upstream tool arguments not an object")
            calls.append(ChatToolCall(id=cid, name=name, arguments=args))
    if reason == FinishReason.TOOL_CALLS and not calls:
        raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                            "upstream tool_calls finish without calls")
    if not content and not calls:
        # A null-content content_filter is a real terminal refusal;
        # every other empty message (including an empty-string stop) is
        # upstream nonsense and fails truthfully.
        if not (reason == FinishReason.CONTENT_FILTER
                and content is None):
            raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                                "upstream message empty")
    if calls and reason == FinishReason.STOP:
        reason = FinishReason.TOOL_CALLS
    usage_raw = payload.get("usage")
    usage = None
    if isinstance(usage_raw, dict):
        values = {}
        for key in ("prompt_tokens", "completion_tokens", "total_tokens"):
            v = usage_raw.get(key)
            if v is None:
                continue
            if not isinstance(v, int) or isinstance(v, bool) or v < 0:
                raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                                    "upstream usage malformed")
            values[key] = v
        usage = ChatUsage(**values)
    return ChatResult(model_identity=model, content=content or "",
                      finish_reason=reason, usage=usage,
                      tool_calls=calls)
