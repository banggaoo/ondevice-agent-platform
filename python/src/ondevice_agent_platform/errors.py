"""Error codes and the platform error type, mirroring PlatformError.swift."""
from __future__ import annotations

import enum


class ErrorCode(enum.Enum):
    INVALID_REQUEST = "invalid_request"
    MALFORMED_JSON = "malformed_json"
    UNAUTHORIZED = "unauthorized"
    FORBIDDEN = "forbidden"
    NOT_FOUND = "not_found"
    CONFLICT = "conflict"
    PAYLOAD_TOO_LARGE = "payload_too_large"
    RATE_LIMITED = "rate_limited"
    PROVIDER_UNAVAILABLE = "provider_unavailable"
    RESOURCE_DENIED = "resource_denied"
    DEADLINE_EXCEEDED = "deadline_exceeded"
    CANCELLED = "cancelled"
    CANCELLATION_UNCONFIRMED = "cancellation_unconfirmed"
    STORAGE_FAILURE = "storage_failure"
    STORAGE_EXHAUSTED = "storage_exhausted"
    ROOT_UNSAFE = "root_unsafe"
    VERSION_UNSUPPORTED = "version_unsupported"
    SESSION_CLOSED = "session_closed"
    CAPACITY_LIMITED = "capacity_limited"
    INTERNAL = "internal"


_SAFE_MESSAGES = {
    ErrorCode.INVALID_REQUEST: "request is invalid or unsupported",
    ErrorCode.MALFORMED_JSON: "body is not valid JSON",
    ErrorCode.UNAUTHORIZED: "authentication required or invalid",
    ErrorCode.FORBIDDEN: "operation not permitted for this principal",
    ErrorCode.NOT_FOUND: "resource not found",
    ErrorCode.CONFLICT: "operation conflicts with current state",
    ErrorCode.PAYLOAD_TOO_LARGE: "request exceeds size limits",
    ErrorCode.RATE_LIMITED: "rate limit exceeded",
    ErrorCode.PROVIDER_UNAVAILABLE: "provider is unavailable or unqualified",
    ErrorCode.RESOURCE_DENIED: "resource conditions deny admission",
    ErrorCode.DEADLINE_EXCEEDED: "operation exceeded its deadline",
    ErrorCode.CANCELLED: "operation was cancelled",
    ErrorCode.CANCELLATION_UNCONFIRMED: "cancellation could not be confirmed",
    ErrorCode.STORAGE_FAILURE: "durable storage operation failed",
    ErrorCode.STORAGE_EXHAUSTED: "durable storage limit reached",
    ErrorCode.ROOT_UNSAFE: "data root is not safe to use",
    ErrorCode.VERSION_UNSUPPORTED: "version or schema unsupported",
    ErrorCode.SESSION_CLOSED: "session is closed",
    ErrorCode.CAPACITY_LIMITED: "capacity limit reached",
    ErrorCode.INTERNAL: "internal error",
}

_STATUS = {
    ErrorCode.INVALID_REQUEST: 400,
    ErrorCode.MALFORMED_JSON: 400,
    ErrorCode.VERSION_UNSUPPORTED: 400,
    ErrorCode.UNAUTHORIZED: 401,
    ErrorCode.FORBIDDEN: 403,
    ErrorCode.NOT_FOUND: 404,
    ErrorCode.CONFLICT: 409,
    ErrorCode.PAYLOAD_TOO_LARGE: 413,
    ErrorCode.RATE_LIMITED: 429,
    ErrorCode.CAPACITY_LIMITED: 429,
    ErrorCode.PROVIDER_UNAVAILABLE: 503,
    ErrorCode.RESOURCE_DENIED: 503,
    ErrorCode.CANCELLED: 503,
    ErrorCode.CANCELLATION_UNCONFIRMED: 503,
    ErrorCode.STORAGE_FAILURE: 503,
    ErrorCode.STORAGE_EXHAUSTED: 503,
    ErrorCode.DEADLINE_EXCEEDED: 504,
    ErrorCode.SESSION_CLOSED: 410,
    ErrorCode.INTERNAL: 500,
    ErrorCode.ROOT_UNSAFE: 500,
}


class PlatformError(Exception):
    """Typed failure. `detail` is never exposed to callers; safe_message is."""

    def __init__(self, code: ErrorCode, detail: str = "") -> None:
        self.code = code
        self.detail = detail
        super().__init__(f"{code.value}: {detail}" if detail else code.value)

    @property
    def safe_message(self) -> str:
        return _SAFE_MESSAGES[self.code]

    @property
    def http_status(self) -> int:
        return _STATUS[self.code]
