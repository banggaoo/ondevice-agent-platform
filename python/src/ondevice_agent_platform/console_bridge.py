"""Console-only bridge to the opt-in read-only runtime Operator, mirroring
ConsoleOperatorBridge.swift. Reuses the shared ACP service under the fixed
console consumer; accepts only a bounded {"text": ...} body; never exposes
tool/model/cwd/configuration selection to the browser."""
from __future__ import annotations

import json
import threading
import time
import uuid

from .errors import ErrorCode, PlatformError
from .limits import PlatformLimits


def _rpc_request(msg_id: str, method: str, params: dict) -> dict:
    return {"jsonrpc": "2.0", "id": msg_id, "method": method,
            "params": params}


class _Collector:
    """Lock-confined wire collector: notifications accumulate bounded text;
    the request's own response is captured by id."""

    MAX_UPDATES = 1024
    MAX_TEXT_BYTES = 1 << 20

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self.updates: list[str] = []
        self.responses: list[dict] = []
        self.text_bytes = 0
        self.overflowed = False

    def append(self, value) -> None:
        with self._lock:
            if isinstance(value, dict) and value.get("method") == "session/update":
                if len(self.updates) >= self.MAX_UPDATES:
                    self.overflowed = True
                    return
                text = (value.get("params", {}).get("update", {})
                        .get("content", {}).get("text"))
                if isinstance(text, str):
                    self.text_bytes += len(text.encode())
                    if self.text_bytes > self.MAX_TEXT_BYTES:
                        self.overflowed = True
                        return
                    self.updates.append(text)
                return
            self.responses.append(value)

    def response(self, msg_id) -> dict | None:
        with self._lock:
            return next((r for r in self.responses
                         if r.get("id") == msg_id), None)

    @property
    def joined_text(self) -> str:
        with self._lock:
            return "".join(self.updates)


class _Binding:
    def __init__(self, connection_id: str, acp_session_id: str,
                 profile, expires_at: float):
        self.connection_id = connection_id
        self.acp_session_id = acp_session_id
        self.profile = profile
        self.expires_at = expires_at


class ConsoleOperatorBridge:
    def __init__(self, acp, supervisor, sessions, principal) -> None:
        self._acp = acp
        self._s = supervisor
        self._sessions = sessions
        self._principal = principal
        self._lock = threading.RLock()
        self._bindings: dict[str, _Binding] = {}
        self._creating: dict[str, threading.Event] = {}
        self._created: dict[str, object] = {}
        self._turn_owners: set[str] = set()
        self._sequence = 0

    def bound_connection_count(self) -> int:
        with self._lock:
            return len(self._bindings)

    @staticmethod
    def _reply(model: str | None, text: str, stop: str) -> dict:
        return {"agent": "operator", "model": model,
                "text": text, "stopReason": stop}

    def prompt(self, console_session, body: bytes, cancellation) -> dict:
        if self._principal is None:
            raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                                "operator is not enabled")
        text = self._parse_body(body)
        if cancellation.is_cancelled:
            profile = self._s.agent_service.profile("operator")
            return self._reply(
                profile.model_profile_alias if profile else None,
                "", "cancelled")
        binding = self._binding_for(console_session)
        if cancellation.is_cancelled:
            return self._reply(binding.profile.model_profile_alias,
                               "", "cancelled")
        cookie_id = console_session.id
        with self._lock:
            if cookie_id in self._turn_owners:
                raise PlatformError(ErrorCode.CONFLICT,
                                    "a question is already running")
            self._turn_owners.add(cookie_id)
            self._sequence += 1
            prompt_id = f"op-{self._sequence}"
        try:
            collector = _Collector()
            self._acp.handle(
                binding.connection_id,
                _rpc_request(prompt_id, "session/prompt", {
                    "sessionId": binding.acp_session_id,
                    "prompt": [{"type": "text", "text": text}],
                }),
                cancellation, collector.append)
            response = collector.response(prompt_id)
            if response is None:
                raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                                    "no agent response")
            error = response.get("error")
            if isinstance(error, dict):
                raise PlatformError(
                    ErrorCode.PROVIDER_UNAVAILABLE,
                    str(error.get("message", "agent error"))[:200])
            if collector.overflowed:
                raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                                    "response overflow")
            stop = (response.get("result", {}) or {}).get(
                "stopReason", "error")
            return self._reply(binding.profile.model_profile_alias,
                               collector.joined_text, stop)
        finally:
            with self._lock:
                self._turn_owners.discard(cookie_id)

    def connection_closed(self, cookie_id: str) -> None:
        with self._lock:
            binding = self._bindings.pop(cookie_id, None)
        if binding is not None:
            self._acp.connection_closed(binding.connection_id)

    def reap_expired(self) -> None:
        now = time.time()
        with self._lock:
            expired = [k for k, b in self._bindings.items()
                       if b.expires_at <= now]
        for cookie_id in expired:
            self.connection_closed(cookie_id)

    def _parse_body(self, body: bytes) -> str:
        try:
            obj = json.loads(body)
        except (json.JSONDecodeError, UnicodeDecodeError):
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                'expected {"text": "..."}')
        if not isinstance(obj, dict) or len(obj) != 1 or \
                not isinstance(obj.get("text"), str):
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                'expected {"text": "..."}')
        text = obj["text"]
        if len(text.encode()) > PlatformLimits.AGENT_PROMPT_BYTES:
            raise PlatformError(ErrorCode.PAYLOAD_TOO_LARGE)
        if not text.strip():
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                "empty question")
        return text

    def _binding_for(self, session) -> _Binding:
        live = self._sessions.lookup(session.id)
        if live is None or live.csrf != session.csrf:
            raise PlatformError(ErrorCode.SESSION_CLOSED,
                                "console session ended")
        now = time.time()
        with self._lock:
            existing = self._bindings.get(session.id)
            if existing and existing.expires_at > now:
                return existing
            if len(self._bindings) >= PlatformLimits.CONSOLE_SESSIONS:
                raise PlatformError(ErrorCode.CAPACITY_LIMITED,
                                    "operator session limit")
        # Single-flight creation per console session.
        with self._lock:
            event = self._creating.get(session.id)
            if event is None:
                event = threading.Event()
                self._creating[session.id] = event
                owner = True
            else:
                owner = False
        if not owner:
            event.wait()
            with self._lock:
                result = self._created.get(session.id)
            if isinstance(result, _Binding):
                return result
            if isinstance(result, PlatformError):
                raise result
            raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE)
        try:
            binding = self._create_binding(session)
            with self._lock:
                self._bindings[session.id] = binding
                self._created[session.id] = binding
            return binding
        except PlatformError as e:
            with self._lock:
                self._created[session.id] = e
            raise
        finally:
            event.set()
            with self._lock:
                self._creating.pop(session.id, None)
                self._created.pop(session.id, None)

    def _create_binding(self, session) -> _Binding:
        conn_id = f"console-{uuid.uuid4().hex}"
        collector = _Collector()
        self._acp.bind(conn_id, "operator", self._principal)
        try:
            self._acp.handle(
                conn_id,
                _rpc_request("op-init", "session/new", {
                    "cwd": "/", "mcpServers": []}),
                None, collector.append)
            response = collector.response("op-init")
            session_id = ((response or {}).get("result", {}) or {}).get(
                "sessionId")
            if not isinstance(session_id, str) or not session_id:
                self._acp.connection_closed(conn_id)
                raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                                    "operator session failed")
            profile = self._s.agent_service.profile("operator")
            if profile is None:
                self._acp.connection_closed(conn_id)
                raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                                    "operator is not enabled")
            return _Binding(conn_id, session_id, profile,
                            session.expires_at)
        except PlatformError:
            self._acp.connection_closed(conn_id)
            raise
