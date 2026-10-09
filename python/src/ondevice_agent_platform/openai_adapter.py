"""OpenAI-compatible wire adapter, mirroring OpenAIAdapter.swift:
parse chat request, emit response/stream frames, error body, ML adapter."""
from __future__ import annotations

import base64
import json
import time
import uuid

from .chat import (ChatImage, ChatMessage, ChatRequest, ChatRole,
                   ChatToolCall, ChatToolSpec, FinishReason, NamedToolChoice,
                   ResponseFormat, ToolChoice)
from .errors import ErrorCode, PlatformError
from .limits import PlatformLimits

_IMAGE_TYPES = {"image/jpeg", "image/png", "image/webp"}
_TOP_KEYS = {
    "model", "messages", "stream", "stream_options", "max_tokens",
    "max_completion_tokens", "temperature", "top_p", "seed",
    "presence_penalty", "frequency_penalty", "response_format",
    "tools", "tool_choice", "n", "stop",
}
_MESSAGE_KEYS = {"role", "content", "tool_calls", "tool_call_id"}
_PART_KEYS = {"type", "text", "image_url"}
_TOOL_KEYS = {"type", "function"}
_TOOL_FN_KEYS = {"name", "description", "parameters"}
_TOOL_CALL_KEYS = {"id", "type", "function"}
_TOOL_CALL_FN_KEYS = {"name", "arguments"}
_UNSUPPORTED_KEYS = {"user", "logit_bias", "logprobs", "reasoning_effort"}


def parse_chat_request(body: bytes):
    """Returns (ChatRequest, stream, include_usage)."""
    try:
        root = json.loads(body)
    except (json.JSONDecodeError, UnicodeDecodeError):
        raise PlatformError(ErrorCode.MALFORMED_JSON)
    if not isinstance(root, dict):
        raise PlatformError(ErrorCode.INVALID_REQUEST)
    for key in root:
        if key in _UNSUPPORTED_KEYS:
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                f"unsupported option: {key}")
        if key not in _TOP_KEYS:
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                f"unknown field: {key}")
    model = root.get("model")
    if not isinstance(model, str) or not model:
        raise PlatformError(ErrorCode.INVALID_REQUEST, "model required")
    stream = root.get("stream", False)
    if not isinstance(stream, bool):
        raise PlatformError(ErrorCode.INVALID_REQUEST,
                            "stream must be a bool")
    include_usage = False
    if "stream_options" in root:
        opts = root["stream_options"]
        if not isinstance(opts, dict):
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                "stream_options must be an object")
        for key in opts:
            if key != "include_usage":
                raise PlatformError(ErrorCode.INVALID_REQUEST,
                                    f"unknown stream_options field: {key}")
        if not isinstance(opts["include_usage"], bool):
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                "include_usage must be a bool")
        include_usage = opts["include_usage"]
    n = root.get("n", 1)
    if n != 1:
        raise PlatformError(ErrorCode.INVALID_REQUEST, "n must be 1")
    max_tok = root.get("max_tokens")
    max_comp = root.get("max_completion_tokens")
    if max_tok is not None and max_comp is not None:
        raise PlatformError(ErrorCode.INVALID_REQUEST,
                            "both token fields set")
    explicit = max_tok if max_tok is not None else max_comp
    if explicit is not None:
        if not isinstance(explicit, int) or not (
                0 < explicit <= PlatformLimits.OUTPUT_TOKENS):
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                "max tokens out of range")
    seed = root.get("seed")
    if seed is not None and (not isinstance(seed, int) or seed < 0):
        raise PlatformError(ErrorCode.INVALID_REQUEST,
                            "seed must be a nonnegative integer")
    messages = _parse_messages(root.get("messages"))
    return (ChatRequest(
        model=model, messages=messages,
        max_output_tokens=explicit or PlatformLimits.OUTPUT_TOKENS,
        has_explicit_output_limit=explicit is not None,
        temperature=_bounded(root.get("temperature"), "temperature"),
        top_p=_bounded(root.get("top_p"), "top_p"),
        seed=seed,
        presence_penalty=_bounded(root.get("presence_penalty"),
                                  "presence_penalty"),
        frequency_penalty=_bounded(root.get("frequency_penalty"),
                                   "frequency_penalty"),
        response_format=_parse_response_format(root.get("response_format")),
        tools=_parse_tools(root.get("tools")),
        tool_choice=_parse_tool_choice(root.get("tool_choice"))),
        stream, include_usage)


def _bounded(value, field_name: str):
    if value is None:
        return None
    if not isinstance(value, (int, float)) or isinstance(value, bool) \
            or value != value:
        raise PlatformError(ErrorCode.INVALID_REQUEST,
                            f"{field_name} out of range")
    return float(value)


def _parse_messages(value) -> list[ChatMessage]:
    if not isinstance(value, list) or not value:
        raise PlatformError(ErrorCode.INVALID_REQUEST, "messages required")
    if len(value) > PlatformLimits.CHAT_MESSAGES:
        raise PlatformError(ErrorCode.INVALID_REQUEST, "too many messages")
    out: list[ChatMessage] = []
    for raw in value:
        if not isinstance(raw, dict):
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                "message malformed")
        for key in raw:
            if key not in _MESSAGE_KEYS:
                raise PlatformError(ErrorCode.INVALID_REQUEST,
                                    "unsupported message field")
        role_raw = raw.get("role")
        try:
            role = ChatRole(role_raw)
        except ValueError:
            raise PlatformError(ErrorCode.INVALID_REQUEST, "invalid role")
        tool_calls = _parse_tool_calls(raw.get("tool_calls"))
        tool_call_id = raw.get("tool_call_id")
        if tool_call_id is not None:
            if role != ChatRole.TOOL:
                raise PlatformError(ErrorCode.INVALID_REQUEST,
                                    "tool_call_id requires tool role")
            if not isinstance(tool_call_id, str):
                raise PlatformError(ErrorCode.INVALID_REQUEST,
                                    "tool_call_id must be a string")
        elif role == ChatRole.TOOL:
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                "tool message requires tool_call_id")
        parts: list[str] = []
        images: list[ChatImage] = []
        content = raw.get("content")
        if isinstance(content, str):
            parts = [content]
        elif isinstance(content, list):
            for part in content:
                if not isinstance(part, dict):
                    raise PlatformError(ErrorCode.INVALID_REQUEST,
                                        "unsupported content part")
                for key in part:
                    if key not in _PART_KEYS:
                        raise PlatformError(ErrorCode.INVALID_REQUEST,
                                            "unsupported part field")
                ptype = part.get("type")
                if ptype == "text":
                    if not isinstance(part.get("text"), str):
                        raise PlatformError(ErrorCode.INVALID_REQUEST,
                                            "text part lacks text")
                    parts.append(part["text"])
                elif ptype == "image_url":
                    images.append(_parse_image(part.get("image_url")))
                else:
                    raise PlatformError(ErrorCode.INVALID_REQUEST,
                                        "unsupported content part")
        elif content is None:
            if not (role == ChatRole.ASSISTANT and tool_calls):
                raise PlatformError(ErrorCode.INVALID_REQUEST,
                                    "content required")
        else:
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                "content required")
        out.append(ChatMessage(role=role, parts=parts, images=images,
                               tool_calls=tool_calls,
                               tool_call_id=tool_call_id))
    return out


def _parse_image(value) -> ChatImage:
    if not isinstance(value, dict):
        raise PlatformError(ErrorCode.INVALID_REQUEST,
                            "image_url object required")
    for key in value:
        if key not in ("url", "detail"):
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                "unsupported image_url field")
    detail = value.get("detail")
    if detail is not None and detail != "auto":
        raise PlatformError(ErrorCode.INVALID_REQUEST,
                            "image detail not honored")
    url = value.get("url")
    if not isinstance(url, str):
        raise PlatformError(ErrorCode.INVALID_REQUEST, "image url required")
    if not url.startswith("data:"):
        raise PlatformError(ErrorCode.INVALID_REQUEST,
                            "remote image urls are never fetched; "
                            "use a data URI")
    header, _, payload = url.partition(",")
    if not payload or not header.endswith(";base64"):
        raise PlatformError(ErrorCode.INVALID_REQUEST,
                            "image data uri must be base64")
    media = header[5:-7]
    if media not in _IMAGE_TYPES:
        raise PlatformError(ErrorCode.INVALID_REQUEST,
                            "unsupported image media type")
    try:
        data = base64.b64decode(payload)
    except Exception:
        raise PlatformError(ErrorCode.INVALID_REQUEST,
                            "image base64 malformed")
    return ChatImage(data=data, media_type=media)


def _parse_tools(value) -> list[ChatToolSpec]:
    if value is None:
        return []
    if not isinstance(value, list):
        raise PlatformError(ErrorCode.INVALID_REQUEST,
                            "tools must be an array")
    if len(value) > PlatformLimits.CHAT_TOOLS:
        raise PlatformError(ErrorCode.INVALID_REQUEST, "too many tools")
    out = []
    for entry in value:
        if not isinstance(entry, dict):
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                "tool entry malformed")
        for key in entry:
            if key not in _TOOL_KEYS:
                raise PlatformError(ErrorCode.INVALID_REQUEST,
                                    f"unsupported tool field: {key}")
        if entry.get("type") != "function":
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                "tool requires type function")
        fn = entry.get("function")
        if not isinstance(fn, dict):
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                "tool function required")
        for key in fn:
            if key not in _TOOL_FN_KEYS:
                raise PlatformError(ErrorCode.INVALID_REQUEST,
                                    "unsupported tool function field")
        name = fn.get("name")
        if not isinstance(name, str) or not name:
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                "tool name required")
        out.append(ChatToolSpec(name=name,
                                description=fn.get("description"),
                                parameters=fn.get("parameters")))
    return out


def _parse_tool_choice(value):
    if value is None:
        return ToolChoice.AUTO
    if isinstance(value, str):
        try:
            return ToolChoice(value)
        except ValueError:
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                "unknown tool_choice")
    if isinstance(value, dict):
        for key in value:
            if key not in ("type", "function"):
                raise PlatformError(ErrorCode.INVALID_REQUEST,
                                    f"unsupported tool_choice field: {key}")
        fn = value.get("function")
        if value.get("type") != "function" or not isinstance(fn, dict):
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                "tool_choice malformed")
        for key in fn:
            if key != "name":
                raise PlatformError(ErrorCode.INVALID_REQUEST,
                                    "unsupported tool_choice function field")
        name = fn.get("name")
        if not isinstance(name, str) or not name:
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                "tool_choice malformed")
        return NamedToolChoice(name=name)
    raise PlatformError(ErrorCode.INVALID_REQUEST, "tool_choice malformed")


def _parse_tool_calls(value) -> list[ChatToolCall]:
    if value is None:
        return []
    if not isinstance(value, list):
        raise PlatformError(ErrorCode.INVALID_REQUEST,
                            "tool_calls must be an array")
    if len(value) > PlatformLimits.CHAT_TOOL_CALLS_PER_MESSAGE:
        raise PlatformError(ErrorCode.INVALID_REQUEST,
                            "too many tool calls on one message")
    out = []
    for entry in value:
        if not isinstance(entry, dict):
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                "tool_call malformed")
        for key in entry:
            if key not in _TOOL_CALL_KEYS:
                raise PlatformError(ErrorCode.INVALID_REQUEST,
                                    "unsupported tool_call field")
        if "id" in entry and not isinstance(entry["id"], str):
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                "tool_call id must be a string")
        fn = entry.get("function")
        if entry.get("type") != "function" or not isinstance(fn, dict):
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                "tool_call requires type function")
        for key in fn:
            if key not in _TOOL_CALL_FN_KEYS:
                raise PlatformError(ErrorCode.INVALID_REQUEST,
                                    "unsupported tool_call function field")
        name = fn.get("name")
        if not isinstance(name, str) or not name:
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                "tool_call name required")
        args = fn.get("arguments", {})
        if isinstance(args, str):
            try:
                args = json.loads(args)
            except json.JSONDecodeError:
                raise PlatformError(ErrorCode.INVALID_REQUEST,
                                    "tool_call arguments must be JSON")
        elif not isinstance(args, dict):
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                "tool_call arguments must be a JSON string")
        out.append(ChatToolCall(id=entry.get("id"), name=name,
                                arguments=args))
    return out


def _parse_response_format(value) -> ResponseFormat | None:
    if value is None:
        return None
    if not isinstance(value, dict):
        raise PlatformError(ErrorCode.INVALID_REQUEST,
                            "response_format malformed")
    rtype = value.get("type")
    if rtype == "text":
        return None
    if rtype == "json_object":
        return ResponseFormat(kind="json_object")
    if rtype == "json_schema":
        schema_obj = value.get("json_schema")
        if not isinstance(schema_obj, dict):
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                "json_schema malformed")
        for key in schema_obj:
            if key not in ("name", "description", "schema", "strict"):
                raise PlatformError(
                    ErrorCode.INVALID_REQUEST,
                    f"unsupported json_schema field: {key}")
        name = schema_obj.get("name")
        if name is not None and not isinstance(name, str):
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                "json_schema name must be a string")
        schema = schema_obj.get("schema")
        if schema is not None and not isinstance(schema, dict):
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                "json_schema schema must be an object")
        strict = schema_obj.get("strict")
        if strict is not None and not isinstance(strict, bool):
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                "json_schema strict must be a boolean")
        return ResponseFormat(kind="json_schema",
                              name=name, schema=schema, strict=strict)
    raise PlatformError(ErrorCode.INVALID_REQUEST,
                        "unsupported response_format")


# ---------------------------------------------------------------------------
# Responses.
# ---------------------------------------------------------------------------


def _usage_object(usage) -> dict | None:
    """The OpenAI usage object only when all three counts are genuinely
    known - a partial result is never zero-filled into a lie."""
    if usage is None:
        return None
    if usage.prompt_tokens is None or usage.completion_tokens is None \
            or usage.total_tokens is None:
        return None
    return {"prompt_tokens": usage.prompt_tokens,
            "completion_tokens": usage.completion_tokens,
            "total_tokens": usage.total_tokens}


def chat_response(result, requested_model: str) -> dict:
    message: dict = {"role": "assistant", "content": result.content or None}
    if result.tool_calls:
        message["tool_calls"] = [
            {"id": c.id or f"call_{i}", "type": "function",
             "function": {"name": c.name,
                          "arguments": json.dumps(c.arguments)}}
            for i, c in enumerate(result.tool_calls)]
    choice: dict = {"index": 0, "message": message,
                    "finish_reason": result.finish_reason.value}
    body: dict = {
        "id": f"chatcmpl-{uuid.uuid4().hex[:24]}",
        "object": "chat.completion",
        "created": int(time.time()),
        "model": requested_model,
        "choices": [choice],
    }
    usage = _usage_object(result.usage)
    if usage is not None:
        body["usage"] = usage
    if result.extra:
        body.update(result.extra)
    return body


def stream_frames(result, requested_model: str,
                  include_usage: bool) -> list[bytes]:
    """The provider boundary is single-shot: the job resolves to one
    completed result, so SSE emits a delta chunk, a finish chunk, and an
    optional usage chunk before [DONE]."""
    cid = f"chatcmpl-{uuid.uuid4().hex[:24]}"
    created = int(time.time())
    frames: list[bytes] = []

    def frame(payload: dict) -> bytes:
        return b"data: " + json.dumps(
            payload, separators=(",", ":")).encode() + b"\n\n"

    delta: dict = {"role": "assistant"}
    if result.content:
        delta["content"] = result.content
    if result.tool_calls:
        delta["tool_calls"] = [
            {"index": i, "id": c.id or f"call_{i}", "type": "function",
             "function": {"name": c.name,
                          "arguments": json.dumps(c.arguments)}}
            for i, c in enumerate(result.tool_calls)]
    frames.append(frame({
        "id": cid, "object": "chat.completion.chunk", "created": created,
        "model": requested_model,
        "choices": [{"index": 0, "delta": delta, "finish_reason": None}]}))
    frames.append(frame({
        "id": cid, "object": "chat.completion.chunk", "created": created,
        "model": requested_model,
        "choices": [{"index": 0, "delta": {},
                     "finish_reason": result.finish_reason.value}]}))
    if include_usage:
        frames.append(frame({
            "id": cid, "object": "chat.completion.chunk", "created": created,
            "model": requested_model, "choices": [],
            "usage": _usage_object(result.usage)}))
    frames.append(b"data: [DONE]\n\n")
    return frames


def error_body(error: PlatformError) -> dict:
    return {"error": {"message": error.safe_message,
                      "type": error.code.value,
                      "code": error.code.value}}


def models_response(profiles) -> dict:
    return {"object": "list", "data": [
        {"id": p.alias, "object": "model",
         "created": 0, "owned_by": "ondevice-agent-platform"}
        for p in profiles]}


# -- typed ML adapter --------------------------------------------------------


def parse_prediction_request(body: bytes):
    from .providers.linear import PredictionRequest
    try:
        root = json.loads(body)
    except (json.JSONDecodeError, UnicodeDecodeError):
        raise PlatformError(ErrorCode.MALFORMED_JSON)
    if not isinstance(root, dict):
        raise PlatformError(ErrorCode.INVALID_REQUEST)
    for key in root:
        if key not in ("model", "task", "inputs"):
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                f"unknown field: {key}")
    model, task, inputs = (root.get("model"), root.get("task"),
                           root.get("inputs"))
    if not isinstance(model, str) or not model:
        raise PlatformError(ErrorCode.INVALID_REQUEST, "model required")
    if not isinstance(task, str) or not task:
        raise PlatformError(ErrorCode.INVALID_REQUEST, "task required")
    if not isinstance(inputs, dict):
        raise PlatformError(ErrorCode.INVALID_REQUEST, "inputs required")
    return PredictionRequest(model=model, task=task, inputs=inputs)


def prediction_response(result) -> dict:
    return {"outputs": result.outputs}
