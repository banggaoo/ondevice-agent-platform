"""ACP service: the private bridge endpoint's JSON-RPC handling, mirroring
ACPService.swift. Connections bind to one agent profile; the v1 subset is
initialize/session-new/prompt/cancel with text and resource-link blocks.
Turn cancellation, run slots, and emission gating mirror the actor model
with locks and daemon threads.
"""
from __future__ import annotations

import json
import threading
import time
import uuid
from dataclasses import dataclass

from . import __version__
from .agents import AgentStopReason, PromptBlock
from .cancellation import CancellationToken
from .errors import ErrorCode, PlatformError
from .limits import PlatformLimits
from .profiles import Grant, Principal

_JSONRPC = "2.0"


def _rpc_result(msg_id, result) -> dict:
    return {"jsonrpc": _JSONRPC, "id": msg_id, "result": result}


def _rpc_error(msg_id, code: int, message: str) -> dict:
    return {"jsonrpc": _JSONRPC, "id": msg_id,
            "error": {"code": code, "message": message}}


def _rpc_notification(method: str, params: dict) -> dict:
    return {"jsonrpc": _JSONRPC, "method": method, "params": params}


def _rpc_code(error: PlatformError) -> int:
    return {
        ErrorCode.INVALID_REQUEST: -32602,
        ErrorCode.MALFORMED_JSON: -32700,
        ErrorCode.NOT_FOUND: -32602,
        ErrorCode.CONFLICT: -32602,
        ErrorCode.CAPACITY_LIMITED: -32602,
        ErrorCode.RATE_LIMITED: -32602,
        ErrorCode.FORBIDDEN: -32602,
        ErrorCode.UNAUTHORIZED: -32602,
    }.get(error.code, -32603)


@dataclass
class _Conn:
    connection_id: str
    agent_id: str
    principal: Principal


class ACPService:
    def __init__(self, supervisor) -> None:
        self._s = supervisor
        self._lock = threading.RLock()
        self._connections: dict[str, _Conn] = {}
        self._run_slots = 0
        self._sequence = 0
        self._active_runs: dict[str, str] = {}          # session -> run
        self._run_flags: dict[str, threading.Event] = {}
        self._run_tokens: dict[str, CancellationToken] = {}
        self._starting_claims: dict[str, object] = {}
        self._pending_cancels: set[str] = set()

    # -- connection lifecycle -------------------------------------------------

    def bind(self, connection_id: str, agent_id: str,
             principal: Principal) -> None:
        with self._lock:
            existing = self._connections.get(connection_id)
            if existing is not None:
                if (existing.agent_id == agent_id
                        and existing.principal.id == principal.id):
                    return
                raise PlatformError(ErrorCode.CONFLICT,
                                    "connection already bound")
            if len(self._connections) >= PlatformLimits.AGENT_CONNECTIONS:
                raise PlatformError(ErrorCode.CAPACITY_LIMITED,
                                    "agent connection limit reached")
            if self._s.agent_service.profile(agent_id) is None:
                raise PlatformError(ErrorCode.NOT_FOUND,
                                    "agent not registered")
            self._connections[connection_id] = _Conn(
                connection_id, agent_id, principal)

    def connection_closed(self, connection_id: str) -> None:
        sessions = self._s.agent_service.close_connection(connection_id)
        with self._lock:
            for s in sessions:
                run_id = self._active_runs.get(s.id)
                if run_id:
                    flag = self._run_flags.get(run_id)
                    if flag:
                        flag.set()
                    token = self._run_tokens.get(run_id)
                    if token:
                        token.cancel()
                    self._s.cancel_children(run_id)
                elif s.id in self._starting_claims:
                    self._pending_cancels.add(s.id)
                self._active_runs.pop(s.id, None)
            self._connections.pop(connection_id, None)

    def live_run_count(self) -> int:
        with self._lock:
            return self._run_slots

    # -- message handling -----------------------------------------------------

    def handle(self, connection_id: str, message,
               cancellation: CancellationToken | None, emit) -> None:
        """`emit` receives response dicts and session/update notifications
        in wire order."""
        try:
            msg_id, method, params, is_notification = self._parse(message)
        except PlatformError:
            emit(_rpc_error(None, -32600, "invalid request"))
            return
        with self._lock:
            conn = self._connections.get(connection_id)
        if conn is None:
            emit(_rpc_error(msg_id, -32600, "connection not bound"))
            return
        if method == "initialize":
            self._respond(conn, msg_id, is_notification,
                          lambda: self._initialize_result(params), emit)
        elif method == "session/new":
            self._respond(conn, msg_id, is_notification,
                          lambda: self._session_new(conn, params), emit)
        elif method == "session/prompt":
            self._respond(conn, msg_id, is_notification,
                          lambda: self._session_prompt(
                              conn, params, cancellation, emit), emit)
        elif method == "session/cancel":
            if not is_notification:
                emit(_rpc_error(msg_id, -32600,
                                "cancel is a notification"))
                return
            self._session_cancel(conn, params)
        elif method == "session/update":
            emit(_rpc_error(msg_id, -32601, "method not found"))
        else:
            emit(_rpc_error(msg_id, -32601, "method not found"))

    @staticmethod
    def _parse(message):
        if not isinstance(message, dict):
            raise PlatformError(ErrorCode.INVALID_REQUEST)
        method = message.get("method")
        if not isinstance(method, str):
            raise PlatformError(ErrorCode.INVALID_REQUEST)
        msg_id = message.get("id")
        is_notification = "id" not in message
        return msg_id, method, message.get("params"), is_notification

    def _respond(self, conn: _Conn, msg_id, is_notification: bool,
                 work, emit) -> None:
        try:
            result = work()
        except PlatformError as e:
            if not is_notification:
                emit(_rpc_error(msg_id, _rpc_code(e), e.safe_message))
            return
        except Exception:
            if not is_notification:
                emit(_rpc_error(msg_id, -32603, "internal error"))
            return
        if not is_notification:
            emit(_rpc_result(msg_id, result))

    # -- methods ----------------------------------------------------------------

    def _initialize_result(self, params) -> dict:
        if isinstance(params, dict) and "protocolVersion" in params:
            v = params["protocolVersion"]
            if not isinstance(v, int) or v < 1:
                raise PlatformError(ErrorCode.INVALID_REQUEST,
                                    "protocolVersion")
        return {
            "protocolVersion": 1,
            "agentCapabilities": {
                "loadSession": False,
                "promptCapabilities": {
                    "audio": False, "embeddedContext": False,
                    "image": False, "video": False,
                },
            },
            "authMethods": [],
            "agentInfo": {"name": "ondevice-agent-platform",
                          "version": f"{__version__}-py"},
        }

    def _session_new(self, conn: _Conn, params) -> dict:
        if not isinstance(params, dict):
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                "params required")
        cwd = params.get("cwd")
        if not isinstance(cwd, str) or not cwd.startswith("/"):
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                "absolute cwd required")
        mcp = params.get("mcpServers")
        if not isinstance(mcp, list):
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                "mcpServers array required")
        if mcp:
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                "MCP servers are not supported")
        session = self._s.agent_service.new_session(
            agent_id=conn.agent_id, consumer_id=conn.principal.id,
            connection_id=conn.connection_id)
        try:
            self._s._store.insert_session(session.id, session.profile,
                                          conn.principal.id, time.time())
        except PlatformError:
            pass   # session ledger write is best-effort like job persistence
        return {"sessionId": session.id}

    def _session_prompt(self, conn: _Conn, params,
                        cancellation: CancellationToken | None,
                        emit) -> dict:
        token = cancellation or CancellationToken()
        cancelled_result = {"stopReason": AgentStopReason.CANCELLED.value}
        if not isinstance(params, dict):
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                "params required")
        session_id = params.get("sessionId")
        if not isinstance(session_id, str) or not session_id:
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                "sessionId required")
        raw_blocks = params.get("prompt")
        if not isinstance(raw_blocks, list):
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                "prompt blocks required")
        blocks: list[PromptBlock] = []
        total_text = 0
        for raw in raw_blocks:
            if not isinstance(raw, dict) or not isinstance(raw.get("type"), str):
                raise PlatformError(ErrorCode.INVALID_REQUEST, "bad block")
            btype = raw["type"]
            if btype == "text":
                t = raw.get("text")
                if not isinstance(t, str):
                    raise PlatformError(ErrorCode.INVALID_REQUEST,
                                        "text required")
                total_text += len(t.encode())
                blocks.append(PromptBlock(kind="text", text=t))
            elif btype == "resource_link":
                uri = raw.get("uri")
                if not isinstance(uri, str) or len(uri.encode()) > 4096:
                    raise PlatformError(ErrorCode.INVALID_REQUEST,
                                        "bad resource link")
                blocks.append(PromptBlock(
                    kind="resource_link",
                    uri=uri, text=raw.get("name") or ""))
            else:
                raise PlatformError(ErrorCode.INVALID_REQUEST,
                                    "unsupported block type")
        if total_text > PlatformLimits.AGENT_PROMPT_BYTES:
            raise PlatformError(ErrorCode.PAYLOAD_TOO_LARGE)
        if token.is_cancelled:
            return cancelled_result
        self._s.require(Grant.AGENT_RUN, conn.principal)
        if token.is_cancelled:
            return cancelled_result
        with self._lock:
            if self._run_slots >= PlatformLimits.AGENT_CONNECTIONS:
                raise PlatformError(ErrorCode.CAPACITY_LIMITED,
                                    "agent run limit reached")
            self._run_slots += 1
        slot_held = True
        try:
            with self._lock:
                claim = uuid.uuid4()
                self._starting_claims.setdefault(session_id, claim)
            try:
                session = self._s.agent_service.begin_prompt(
                    session_id, conn.principal.id, conn.connection_id)
            except PlatformError:
                with self._lock:
                    if self._starting_claims.get(session_id) is claim:
                        del self._starting_claims[session_id]
                raise
            claim_held = True
            try:
                if token.is_cancelled:
                    return cancelled_result
                harness = self._s.agent_service.harness_for(session)
                with self._lock:
                    self._sequence += 1
                    run_id = f"run-{self._sequence}"
                    flag = threading.Event()
                    self._run_flags[run_id] = flag
                    self._run_tokens[run_id] = token
                    self._active_runs[session.id] = run_id
                    claim_held = False
                    if self._starting_claims.get(session_id) is claim:
                        del self._starting_claims[session_id]
                    if session.id in self._pending_cancels:
                        self._pending_cancels.discard(session.id)
                        flag.set()
                        token.cancel()
                # A cancel that landed during setup reaches the harness via
                # the token; the stopReason rail reports cancelled normally.
                context = _HarnessContext(
                    self._s, conn.principal, run_id, flag, token)
                stop, orphaned = self._run_with_deadline(
                    run_id, session, harness, blocks, context, flag,
                    token, emit)
                flag.set()
                token.cancel()
                self._s.cancel_children(run_id)
                if orphaned is not None:
                    # Terminal reported on timeout while the harness thread
                    # is still alive: keep the session claimed and the slot
                    # held until real harness completion, then release.
                    orphaned.join()
                slot_held = False
                self._run_ended(run_id, session.id)
                if orphaned is not None:
                    raise PlatformError(ErrorCode.DEADLINE_EXCEEDED,
                                        "agent turn deadline")
                if stop == AgentStopReason.ERROR:
                    raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                                        "agent turn failed")
                return {"stopReason": stop.value}
            finally:
                if claim_held:
                    self._s.agent_service.set_prompt_active(session.id, False)
        finally:
            # _run_ended decrements the slot on the owning path; anything
            # leaving before registration must release it here.
            if slot_held:
                with self._lock:
                    self._run_slots -= 1

    def _run_ended(self, run_id: str, session_id: str) -> None:
        with self._lock:
            flag = self._run_flags.pop(run_id, None)
            token = self._run_tokens.pop(run_id, None)
            if flag is None and token is None:
                return   # already reaped
            held_claim = self._active_runs.get(session_id) == run_id
            if held_claim:
                del self._active_runs[session_id]
            if flag:
                flag.set()
            if token:
                token.cancel()
            self._run_slots -= 1
        if held_claim:
            self._s.agent_service.set_prompt_active(session_id, False)

    def _run_with_deadline(self, run_id, session, harness, blocks,
                           context, flag, token, emit):
        """Race the harness against the turn deadline. On timeout the caller
        is answered a deadline error while the harness thread is cancelled
        and kept quarantined until it actually finishes."""

        def emitter(kind: str, text: str) -> None:
            if flag.is_set() or token.is_cancelled:
                return
            if kind == "message_chunk":
                emit(_rpc_notification("session/update", {
                    "sessionId": session.id,
                    "update": {
                        "sessionUpdate": "agent_message_chunk",
                        "content": {"type": "text", "text": text},
                    }}))

        result_box: dict = {}

        def run() -> None:
            try:
                result_box["stop"] = harness.run(blocks, context, emitter)
            except Exception:
                result_box["stop"] = AgentStopReason.ERROR

        thread = threading.Thread(target=run, daemon=True,
                                  name=f"oap-{run_id}")
        thread.start()
        thread.join(PlatformLimits.AGENT_DEADLINE_SECONDS)
        if thread.is_alive():
            # Deadline: quarantine the runaway thread.
            flag.set()
            token.cancel()
            self._s.cancel_children(run_id)
            return AgentStopReason.CANCELLED, thread
        return result_box.get("stop", AgentStopReason.ERROR), None

    def _session_cancel(self, conn: _Conn, params) -> None:
        if not isinstance(params, dict):
            return
        session_id = params.get("sessionId")
        if not isinstance(session_id, str):
            return
        session = self._s.agent_service.session(
            session_id, conn.principal.id, conn.connection_id)
        if session is None:
            return
        with self._lock:
            run_id = self._active_runs.get(session.id)
            if run_id:
                flag = self._run_flags.get(run_id)
                if flag:
                    flag.set()
                token = self._run_tokens.get(run_id)
                if token:
                    token.cancel()
                self._s.cancel_children(run_id)
            elif session.id in self._starting_claims:
                self._pending_cancels.add(session.id)


class _HarnessContext:
    """The context a harness sees: status snapshot + one scoped model call
    + cooperative cancellation. No admin surface is exposed."""

    def __init__(self, supervisor, principal, run_id,
                 flag: threading.Event, token: CancellationToken) -> None:
        self._s = supervisor
        self._principal = principal
        self._run_id = run_id
        self._flag = flag
        self._token = token

    def is_cancelled(self) -> bool:
        return self._flag.is_set() or self._token.is_cancelled

    def status_snapshot(self) -> dict:
        return self._s.status_snapshot()

    def complete(self, request):
        if self._token.is_cancelled:
            raise PlatformError(ErrorCode.CANCELLED)
        return self._s.submit_llm(self._principal, request,
                                  parent_id=self._run_id,
                                  cancellation=self._token)
