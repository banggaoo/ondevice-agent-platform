"""Console-only bridge to ACP-served agents, mirroring
ConsoleOperatorBridge.swift. Reuses the shared ACP service under the
fixed console consumer; accepts only a bounded {"text", "agent"?} body;
never exposes tool/model/cwd/configuration selection to the browser.
The Operator remains the default agent; owner-declared custom chat
agents are reachable by id."""
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
        self._bindings: dict[tuple, _Binding] = {}
        self._creating: dict[tuple, threading.Event] = {}
        self._created: dict[tuple, object] = {}
        self._turn_owners: set[tuple] = set()
        self._sequence = 0

    def bound_connection_count(self) -> int:
        with self._lock:
            return len(self._bindings)

    @staticmethod
    def _reply(agent: str, model: str | None, text: str,
               stop: str) -> dict:
        return {"agent": agent, "model": model,
                "text": text, "stopReason": stop}

    def prompt(self, console_session, body: bytes, cancellation) -> dict:
        text, agent_id = self._parse_body(body)
        profile = self._s.agent_service.profile(agent_id) \
            if self._s.agent_service else None
        if profile is None:
            raise PlatformError(ErrorCode.NOT_FOUND,
                                f"agent not registered: {agent_id}")
        if cancellation.is_cancelled:
            return self._reply(agent_id, profile.model_profile_alias,
                               "", "cancelled")
        binding = self._binding_for(console_session, agent_id)
        if cancellation.is_cancelled:
            return self._reply(agent_id,
                               binding.profile.model_profile_alias,
                               "", "cancelled")
        key = (console_session.id, agent_id)
        with self._lock:
            if key in self._turn_owners:
                raise PlatformError(ErrorCode.CONFLICT,
                                    "a question is already running")
            self._turn_owners.add(key)
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
            return self._reply(agent_id,
                               binding.profile.model_profile_alias,
                               collector.joined_text, stop)
        finally:
            with self._lock:
                self._turn_owners.discard(key)

    def connection_closed(self, cookie_id: str) -> None:
        with self._lock:
            owned = [k for k in self._bindings if k[0] == cookie_id]
            bindings = [self._bindings.pop(k) for k in owned]
        for binding in bindings:
            self._acp.connection_closed(binding.connection_id)

    def reap_expired(self) -> None:
        now = time.time()
        with self._lock:
            expired = [k for k, b in self._bindings.items()
                       if b.expires_at <= now]
        for cookie_id in {k[0] for k in expired}:
            self.connection_closed(cookie_id)

    def _parse_body(self, body: bytes) -> tuple:
        try:
            obj = json.loads(body)
        except (json.JSONDecodeError, UnicodeDecodeError):
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                'expected {"text": "..."}')
        if not isinstance(obj, dict) \
                or not set(obj) <= {"text", "agent"} \
                or not isinstance(obj.get("text"), str):
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                'expected {"text": "...", "agent"?}')
        text = obj["text"]
        if len(text.encode()) > PlatformLimits.AGENT_PROMPT_BYTES:
            raise PlatformError(ErrorCode.PAYLOAD_TOO_LARGE)
        if not text.strip():
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                "empty question")
        agent_id = obj.get("agent") or "operator"
        if not isinstance(agent_id, str):
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                "agent must be a string")
        return text, agent_id

    def _binding_for(self, session, agent_id: str) -> _Binding:
        live = self._sessions.lookup(session.id)
        if live is None or live.csrf != session.csrf:
            raise PlatformError(ErrorCode.SESSION_CLOSED,
                                "console session ended")
        now = time.time()
        key = (session.id, agent_id)
        with self._lock:
            existing = self._bindings.get(key)
            if existing and existing.expires_at > now:
                return existing
            if len(self._bindings) >= PlatformLimits.CONSOLE_SESSIONS:
                raise PlatformError(ErrorCode.CAPACITY_LIMITED,
                                    "agent session limit")
        # Single-flight creation per console session + agent.
        with self._lock:
            event = self._creating.get(key)
            if event is None:
                event = threading.Event()
                self._creating[key] = event
                owner = True
            else:
                owner = False
        if not owner:
            event.wait()
            with self._lock:
                result = self._created.get(key)
            if isinstance(result, _Binding):
                return result
            if isinstance(result, PlatformError):
                raise result
            raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE)
        try:
            binding = self._create_binding(session, agent_id)
            with self._lock:
                self._bindings[key] = binding
                self._created[key] = binding
            return binding
        except PlatformError as e:
            with self._lock:
                self._created[key] = e
            raise
        finally:
            event.set()
            with self._lock:
                self._creating.pop(key, None)
                self._created.pop(key, None)

    def _create_binding(self, session, agent_id: str) -> _Binding:
        conn_id = f"console-{uuid.uuid4().hex}"
        collector = _Collector()
        self._acp.bind(conn_id, agent_id, self._principal)
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
                                    "agent session failed")
            profile = self._s.agent_service.profile(agent_id)
            if profile is None:
                self._acp.connection_closed(conn_id)
                raise PlatformError(ErrorCode.NOT_FOUND,
                                    f"agent not registered: {agent_id}")
            return _Binding(conn_id, session_id, profile,
                            session.expires_at)
        except PlatformError:
            self._acp.connection_closed(conn_id)
            raise
