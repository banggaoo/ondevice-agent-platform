"""Chat request/result types and shared bounds validation, mirroring
ChatTypes.swift + RequestValidation.swift.

Image inspection is pure stdlib: PNG/JPEG/WebP dimensions are parsed from
container headers with magic-byte format checks - the same guarantees the
ImageIO path provided (declared MIME must match container format, one
frame, bounded dimensions), with no pixel decode and no dependency.
"""
from __future__ import annotations

import enum
import json
import struct
from dataclasses import dataclass, field

from .errors import ErrorCode, PlatformError
from .limits import PlatformLimits


class ChatRole(enum.Enum):
    SYSTEM = "system"
    DEVELOPER = "developer"
    USER = "user"
    ASSISTANT = "assistant"
    # A tool result turn: the client's reply to an assistant tool call.
    # Model output never executes; the caller owns actual tool execution.
    TOOL = "tool"


@dataclass
class ChatImage:
    """Decoded image bytes (base64 already undone at the adapter)."""
    data: bytes
    media_type: str


@dataclass
class ChatToolCall:
    """One assistant function invocation in either direction. `id`
    correlates with the tool_call_id of a later tool message."""
    name: str
    arguments: dict
    id: str | None = None


@dataclass
class ChatToolSpec:
    name: str
    description: str | None = None
    parameters: dict | None = None


@dataclass
class ChatMessage:
    role: ChatRole
    parts: list[str] = field(default_factory=list)
    images: list[ChatImage] = field(default_factory=list)
    tool_calls: list[ChatToolCall] = field(default_factory=list)
    tool_call_id: str | None = None

    @property
    def combined_text(self) -> str:
        return "\n".join(self.parts)


@dataclass
class ResponseFormat:
    """Requested output shape: guidance, never enforced decoding.
    `strict` is only honored by providers that enforce it (vllm-mlx);
    guidance-only providers must refuse strict=True rather than pretend."""
    kind: str                       # "json_object" | "json_schema"
    name: str | None = None
    schema: dict | None = None
    strict: bool | None = None

    def guidance(self) -> str:
        if self.kind == "json_object":
            return ("Respond with a single valid JSON object and no other"
                    " text.")
        if not isinstance(self.schema, dict):
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                "JSON schema must be an object")
        rendered = json.dumps(self.schema, separators=(",", ":"))
        label = f' named "{self.name}"' if self.name else ""
        return (f"Respond with a single valid JSON object{label} matching"
                f" this JSON schema and no other text: {rendered}")


class ToolChoice(enum.Enum):
    AUTO = "auto"
    NONE = "none"
    REQUIRED = "required"


@dataclass
class NamedToolChoice:
    name: str


@dataclass
class ChatRequest:
    model: str
    messages: list[ChatMessage]
    max_output_tokens: int = PlatformLimits.OUTPUT_TOKENS
    has_explicit_output_limit: bool = False
    temperature: float | None = None
    top_p: float | None = None
    seed: int | None = None
    presence_penalty: float | None = None
    frequency_penalty: float | None = None
    response_format: ResponseFormat | None = None
    tools: list[ChatToolSpec] = field(default_factory=list)
    # ToolChoice enum member or NamedToolChoice
    tool_choice: object = ToolChoice.AUTO

    @property
    def has_images(self) -> bool:
        return any(m.images for m in self.messages)

    def resolving_default_output_tokens(self, cap: int | None) -> "ChatRequest":
        if self.has_explicit_output_limit:
            return self
        return self.limiting_output_tokens(cap)

    def limiting_output_tokens(self, cap: int | None) -> "ChatRequest":
        """A declared profile cap lowers the client's bound; never raises."""
        if cap is None or self.max_output_tokens <= cap:
            return self
        clone = ChatRequest(**{**self.__dict__})
        clone.max_output_tokens = cap
        return clone


class FinishReason(enum.Enum):
    STOP = "stop"
    LENGTH = "length"
    CONTENT_FILTER = "content_filter"
    ERROR = "error"
    # The model emitted tool calls; the client runs them and continues.
    TOOL_CALLS = "tool_calls"


@dataclass
class ChatUsage:
    prompt_tokens: int | None = None
    completion_tokens: int | None = None
    total_tokens: int | None = None


@dataclass
class ChatResult:
    model_identity: str
    content: str
    finish_reason: FinishReason
    usage: ChatUsage | None = None
    tool_calls: list[ChatToolCall] = field(default_factory=list)


# ---------------------------------------------------------------------------
# Image dimension sniffing (PNG/JPEG/WebP), replacing the ImageIO path.
# Returns (width, height) or raises invalid_request for malformed/foreign
# formats. Same posture: declared MIME must match container format.
# ---------------------------------------------------------------------------

_PNG_SIG = b"\x89PNG\r\n\x1a\n"
_JPEG_SOI = b"\xff\xd8"
_JPEG_SOF = frozenset(
    [0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB,
     0xCD, 0xCE, 0xCF])
_WEBP_RIFF = b"RIFF"
_WEBP_WEBP = b"WEBP"


def image_pixels(width: int, height: int) -> int:
    if not (0 < width <= PlatformLimits.CHAT_IMAGE_DIMENSION
            and 0 < height <= PlatformLimits.CHAT_IMAGE_DIMENSION):
        raise PlatformError(ErrorCode.PAYLOAD_TOO_LARGE,
                            "image dimensions out of range")
    pixels = width * height
    if pixels > PlatformLimits.CHAT_IMAGE_PIXELS:
        raise PlatformError(ErrorCode.PAYLOAD_TOO_LARGE,
                            "image pixel limit exceeded")
    return pixels


def validated_pixels(image: ChatImage) -> int:
    data, media = image.data, image.media_type
    if media == "image/png":
        dims = _png_dims(data)
    elif media == "image/jpeg":
        dims = _jpeg_dims(data)
    elif media == "image/webp":
        dims = _webp_dims(data)
    else:
        raise PlatformError(ErrorCode.INVALID_REQUEST,
                            "unsupported image media type")
    if dims is None:
        raise PlatformError(ErrorCode.INVALID_REQUEST,
                            "image format does not match declared type")
    return image_pixels(*dims)


def _png_dims(data: bytes) -> tuple[int, int] | None:
    # Signature + first chunk must be IHDR with a 13-byte payload.
    if len(data) < 24 or not data.startswith(_PNG_SIG):
        return None
    if data[12:16] != b"IHDR":
        return None
    w, h = struct.unpack(">II", data[16:24])
    return (w, h) if w and h else None


def _jpeg_dims(data: bytes) -> tuple[int, int] | None:
    if len(data) < 4 or not data.startswith(_JPEG_SOI):
        return None
    i = 2
    while i + 3 < len(data):
        if data[i] != 0xFF:
            i += 1
            continue
        marker = data[i + 1]
        if marker in _JPEG_SOF:
            if i + 9 <= len(data):
                h, w = struct.unpack(">HH", data[i + 5:i + 9])
                return (w, h) if w and h else None
            return None
        # APPn/other segments carry a 2-byte length after the marker.
        if marker in (0xD8, 0xD9) or 0xD0 <= marker <= 0xD7:
            i += 2
            continue
        if i + 4 > len(data):
            return None
        seg_len = struct.unpack(">H", data[i + 2:i + 4])[0]
        if seg_len < 2:
            return None
        i += 2 + seg_len
    return None


def _webp_dims(data: bytes) -> tuple[int, int] | None:
    if len(data) < 30 or data[0:4] != _WEBP_RIFF or data[8:12] != _WEBP_WEBP:
        return None
    fourcc = data[12:16]
    if fourcc == b"VP8 ":
        # Lossy: frame tag at 23..26, signature 9d 01 2a, then 14-bit dims.
        if data[23:26] != b"\x9d\x01\x2a":
            return None
        w = struct.unpack("<H", data[26:28])[0] & 0x3FFF
        h = struct.unpack("<H", data[28:30])[0] & 0x3FFF
        return (w, h) if w and h else None
    if fourcc == b"VP8L":
        if data[20] != 0x2F or len(data) < 25:
            return None
        b0, b1, b2, b3 = data[21:25]
        w = ((b1 & 0x3F) << 8 | b0) + 1
        h = ((b3 & 0x0F) << 10 | b2 << 2 | (b1 & 0xC0) >> 6) + 1
        return (w, h)
    if fourcc == b"VP8X":
        w = (data[24] | data[25] << 8 | data[26] << 16) + 1
        h = (data[27] | data[28] << 8 | data[29] << 16) + 1
        return (w, h)
    return None


# ---------------------------------------------------------------------------
# RequestValidation.chat — the shared bounds layer of record.
# ---------------------------------------------------------------------------


def _bounded(value: float | None, lo: float, hi: float, field_name: str) -> None:
    if value is None:
        return
    if not (lo <= value <= hi) or value != value:  # NaN excluded
        raise PlatformError(ErrorCode.INVALID_REQUEST,
                            f"{field_name} out of range")


def _encoded_count(value) -> int:
    try:
        return len(json.dumps(value, separators=(",", ":")).encode("utf-8"))
    except (TypeError, ValueError, OverflowError):
        raise PlatformError(ErrorCode.INVALID_REQUEST, "value not encodable")


def _validate_tool_name(name: str) -> None:
    ok = (1 <= len(name.encode()) <= 64
          and all(c in "-_" or c.isdigit() or "A" <= c <= "Z" or "a" <= c <= "z"
                  for c in name))
    if not ok:
        raise PlatformError(ErrorCode.INVALID_REQUEST, "invalid tool name")


def _validate_tool_call(call: ChatToolCall) -> None:
    if not call.id or not (1 <= len(call.id.encode()) <= 128):
        raise PlatformError(ErrorCode.INVALID_REQUEST,
                            "tool call id out of range")
    _validate_tool_name(call.name)
    if not isinstance(call.arguments, dict):
        raise PlatformError(ErrorCode.INVALID_REQUEST,
                            "tool arguments must be an object")


def validate_chat(request: ChatRequest, profile) -> None:
    request = request.resolving_default_output_tokens(profile.max_output_tokens)
    if not request.messages or len(request.messages) > PlatformLimits.CHAT_MESSAGES:
        raise PlatformError(ErrorCode.INVALID_REQUEST,
                            "message count out of range")
    token_cap = min(PlatformLimits.OUTPUT_TOKENS,
                    profile.max_output_tokens or PlatformLimits.OUTPUT_TOKENS)
    if not (0 < request.max_output_tokens <= token_cap):
        raise PlatformError(ErrorCode.INVALID_REQUEST,
                            "max output tokens out of range")
    _bounded(request.temperature, 0, 2, "temperature")
    _bounded(request.top_p, 0, 1, "top_p")
    _bounded(request.presence_penalty, -2, 2, "presence_penalty")
    _bounded(request.frequency_penalty, -2, 2, "frequency_penalty")
    if request.seed is not None and request.seed > 2**63 - 1:
        raise PlatformError(ErrorCode.INVALID_REQUEST, "seed out of range")

    text_bytes = image_bytes = image_count = total_pixels = 0
    # Count/total caps enforced before any header work below.
    for message in request.messages:
        for image in message.images:
            if message.role != ChatRole.USER:
                raise PlatformError(ErrorCode.INVALID_REQUEST,
                                    "images only allowed on user messages")
            if "vision" not in profile.capabilities:
                raise PlatformError(ErrorCode.INVALID_REQUEST,
                                    "model does not accept image input")
            image_count += 1
            image_bytes += len(image.data)
    if (image_count > PlatformLimits.CHAT_IMAGES_PER_REQUEST
            or image_bytes > PlatformLimits.CHAT_IMAGE_BYTES):
        raise PlatformError(ErrorCode.PAYLOAD_TOO_LARGE,
                            "image limits exceeded")

    # Tool result turns must answer a call made earlier in this request.
    declared_call_ids: set[str] = set()
    unanswered_call_ids: set[str] = set()
    for message in request.messages:
        if message.role == ChatRole.USER and unanswered_call_ids:
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                "tool calls unanswered before user turn")
        has_text = any(p.strip() for p in message.parts)
        if not (has_text or message.images or message.tool_calls):
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                "message has no content")
        if message.tool_calls:
            if message.role != ChatRole.ASSISTANT:
                raise PlatformError(ErrorCode.INVALID_REQUEST,
                                    "tool_calls only allowed on assistant messages")
            if len(message.tool_calls) > PlatformLimits.CHAT_TOOL_CALLS_PER_MESSAGE:
                raise PlatformError(ErrorCode.PAYLOAD_TOO_LARGE,
                                    "tool call count exceeded")
        if message.tool_call_id is not None:
            if message.role != ChatRole.TOOL:
                raise PlatformError(ErrorCode.INVALID_REQUEST,
                                    "tool_call_id only allowed on tool messages")
            tid = message.tool_call_id
            if not tid or len(tid.encode()) > 128:
                raise PlatformError(ErrorCode.INVALID_REQUEST,
                                    "tool_call_id out of range")
            if tid not in unanswered_call_ids:
                raise PlatformError(ErrorCode.INVALID_REQUEST,
                                    "tool_call_id has no matching tool call")
            unanswered_call_ids.discard(tid)
        elif message.role == ChatRole.TOOL:
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                "tool message requires tool_call_id")
        for part in message.parts:
            text_bytes += len(part.encode())
        for call in message.tool_calls:
            _validate_tool_call(call)
            text_bytes += (len(call.id.encode()) + len(call.name.encode())
                           + _encoded_count(call.arguments))
            if call.id in declared_call_ids:
                raise PlatformError(ErrorCode.INVALID_REQUEST,
                                    "duplicate tool call id")
            declared_call_ids.add(call.id)
            unanswered_call_ids.add(call.id)
        for image in message.images:
            total_pixels += validated_pixels(image)
    if total_pixels > PlatformLimits.CHAT_IMAGE_PIXELS:
        raise PlatformError(ErrorCode.PAYLOAD_TOO_LARGE,
                            "image limits exceeded")

    last_role = request.messages[-1].role if request.messages else None
    if last_role == ChatRole.USER:
        pass
    elif last_role == ChatRole.TOOL:
        if unanswered_call_ids:
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                "unanswered tool calls remain")
    else:
        raise PlatformError(ErrorCode.INVALID_REQUEST,
                            "final message must be a user or tool turn")

    if len(request.tools) > PlatformLimits.CHAT_TOOLS:
        raise PlatformError(ErrorCode.PAYLOAD_TOO_LARGE,
                            "tool count exceeded")
    tool_names: set[str] = set()
    for tool in request.tools:
        _validate_tool_name(tool.name)
        if tool.name in tool_names:
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                "duplicate tool name")
        tool_names.add(tool.name)
        text_bytes += len(tool.name.encode())
        if tool.description:
            text_bytes += len(tool.description.encode())
        if tool.parameters is not None:
            if not isinstance(tool.parameters, dict):
                raise PlatformError(ErrorCode.INVALID_REQUEST,
                                    "tool schema must be an object")
            text_bytes += _encoded_count(tool.parameters)

    if isinstance(request.tool_choice, NamedToolChoice):
        _validate_tool_name(request.tool_choice.name)
        if request.tool_choice.name not in tool_names:
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                "tool_choice names an undeclared tool")
    if request.response_format is not None:
        try:
            guidance = request.response_format.guidance()
        except PlatformError:
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                "invalid response format")
        text_bytes += len(guidance.encode())
    if text_bytes > PlatformLimits.CHAT_TEXT_BYTES:
        raise PlatformError(ErrorCode.PAYLOAD_TOO_LARGE,
                            "text limit exceeded")
    if (profile.max_input_bytes is not None
            and text_bytes + image_bytes > profile.max_input_bytes):
        raise PlatformError(ErrorCode.PAYLOAD_TOO_LARGE,
                            "model input limit exceeded")


def validate_prediction(request, profile) -> None:
    try:
        encoded = json.dumps(request.inputs).encode("utf-8")
    except (TypeError, ValueError):
        raise PlatformError(ErrorCode.INVALID_REQUEST,
                            "inputs not encodable")
    cap = min(PlatformLimits.ML_INPUT_BYTES,
              profile.max_input_bytes or PlatformLimits.ML_INPUT_BYTES)
    if len(encoded) > cap:
        raise PlatformError(ErrorCode.PAYLOAD_TOO_LARGE,
                            "ml input limit exceeded")


def validate_features(inputs: dict, schema: dict) -> None:
    """Typed-ML feature check: every declared feature present and typed."""
    for name, ftype in schema.items():
        if name not in inputs:
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                f"missing feature: {name}")
        value = inputs[name]
        if ftype == "number" and not isinstance(value, (int, float)):
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                f"feature not numeric: {name}")
        if ftype == "string" and not isinstance(value, str):
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                f"feature not string: {name}")
        if ftype == "boolean" and not isinstance(value, bool):
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                f"feature not boolean: {name}")
