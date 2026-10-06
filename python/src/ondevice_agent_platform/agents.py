"""Hosted-agent runtime, mirroring AgentService.swift plus the built-in
harnesses (reference.status, reference.echo, operator.runtime).

Sessions are bound to a single connection and consumer; profiles pin their
harness versions at creation; implementations are reviewed compiled-in
code resolved by reference name - never arbitrary path loading.
"""
from __future__ import annotations

import enum
import threading
import time
from dataclasses import dataclass, field

from .chat import ChatMessage, ChatRequest, ChatRole, FinishReason
from .errors import ErrorCode, PlatformError
from .limits import PlatformLimits
from .profiles import AgentProfile


class AgentStopReason(enum.Enum):
    END_TURN = "end_turn"
    MAX_TOKENS = "max_tokens"
    CANCELLED = "cancelled"
    REFUSAL = "refusal"
    ERROR = "error"


class AgentEventKind(enum.Enum):
    MESSAGE_CHUNK = "message_chunk"
    TOOL_CALL = "tool_call"
    PLAN = "plan"
    THOUGHT = "thought"


@dataclass
class PromptBlock:
    kind: str                # "text" | "resource_link"
    text: str = ""
    uri: str = ""


@dataclass
class AgentSession:
    id: str
    profile: AgentProfile
    consumer_id: str
    connection_id: str
    created_at: float
    prompt_active: bool = False


# ---------------------------------------------------------------------------
# Harnesses: reviewed, compiled-in implementations.
# ---------------------------------------------------------------------------

OPERATOR_INSTRUCTIONS = (
    "You are the platform Operator, an optional read-only explainer of this "
    "local agent serving platform. You have no tool-execution authority and "
    "cannot change anything. Answer with a concise explanation or proposal "
    "grounded only in the provided status snapshot; never claim to have "
    "applied a change.")


def _operator_snapshot_text(snapshot: dict) -> str:
    import json
    return "Platform status snapshot (JSON):\n" + json.dumps(
        snapshot, indent=None, separators=(",", ":"))


class ReferenceStatusHarness:
    id = "reference.status"
    version = 1

    def run(self, input_blocks, context, emit) -> AgentStopReason:
        emit("message_chunk",
             "reference.status: deterministic harness; no model call.")
        return AgentStopReason.END_TURN


class ReferenceEchoHarness:
    id = "reference.echo"
    version = 1

    def __init__(self, model_alias: str) -> None:
        self._alias = model_alias

    def run(self, input_blocks, context, emit) -> AgentStopReason:
        text = "\n".join(b.text for b in input_blocks if b.kind == "text")
        if not text.strip():
            emit("message_chunk", "Nothing to echo.")
            return AgentStopReason.REFUSAL
        if context.is_cancelled():
            return AgentStopReason.CANCELLED
        try:
            result = context.complete(ChatRequest(
                model=self._alias,
                messages=[ChatMessage(role=ChatRole.USER, parts=[text])],
                max_output_tokens=64, has_explicit_output_limit=True))
            emit("message_chunk", result.content)
            return AgentStopReason.END_TURN
        except PlatformError as e:
            if e.code == ErrorCode.CANCELLED:
                return AgentStopReason.CANCELLED
            emit("message_chunk", f"Echo unavailable: {e.safe_message}")
            return AgentStopReason.ERROR


class RuntimeOperatorHarness:
    """Optional read-only runtime Operator: explains the platform snapshot
    through exactly one bounded model call. No tools, no authority, no
    state, no loops."""
    id = "operator.runtime"
    version = 1
    MAX_OUTPUT_TOKENS = 512

    def __init__(self, model_alias: str) -> None:
        self._alias = model_alias

    def run(self, input_blocks, context, emit) -> AgentStopReason:
        prompt = "\n".join(b.text for b in input_blocks
                           if b.kind == "text").strip()
        if not prompt:
            emit("message_chunk", "No question to answer.")
            return AgentStopReason.REFUSAL
        if context.is_cancelled():
            return AgentStopReason.CANCELLED
        try:
            snapshot = context.status_snapshot()
            snapshot_text = _operator_snapshot_text(snapshot)
            if context.is_cancelled():
                return AgentStopReason.CANCELLED
            result = context.complete(ChatRequest(
                model=self._alias,
                messages=[
                    ChatMessage(role=ChatRole.SYSTEM,
                                parts=[OPERATOR_INSTRUCTIONS]),
                    ChatMessage(role=ChatRole.USER, parts=[snapshot_text]),
                    ChatMessage(role=ChatRole.USER, parts=[prompt]),
                ],
                max_output_tokens=self.MAX_OUTPUT_TOKENS,
                has_explicit_output_limit=True,
                temperature=0.0))
            if context.is_cancelled():
                return AgentStopReason.CANCELLED
            if result.tool_calls:
                emit("message_chunk",
                     "Operator cannot execute tool calls. Nothing was applied.")
                return AgentStopReason.ERROR
            if result.finish_reason == FinishReason.CONTENT_FILTER:
                emit("message_chunk", result.content
                     or "Operator response was refused.")
                return AgentStopReason.REFUSAL
            if result.finish_reason in (FinishReason.ERROR,
                                        FinishReason.TOOL_CALLS):
                emit("message_chunk",
                     "Operator model returned an unusable response.")
                return AgentStopReason.ERROR
            if not result.content.strip():
                emit("message_chunk",
                     "Operator model returned no usable text.")
                return AgentStopReason.ERROR
            emit("message_chunk", result.content)
            return (AgentStopReason.MAX_TOKENS
                    if result.finish_reason == FinishReason.LENGTH
                    else AgentStopReason.END_TURN)
        except PlatformError as e:
            if e.code == ErrorCode.CANCELLED:
                return AgentStopReason.CANCELLED
            emit("message_chunk", f"Operator unavailable: {e.safe_message}")
            return AgentStopReason.ERROR


class AgentService:
    def __init__(self, supervisor=None) -> None:
        self._lock = threading.RLock()
        self._profiles: dict[str, AgentProfile] = {}
        self._versions: dict[str, dict[int, AgentProfile]] = {}
        self._harnesses: dict[str, tuple] = {}
        self._sessions: dict[str, AgentSession] = {}
        self._sequence = 0
        self._cancelled_runs: set[str] = set()
        self._supervisor = supervisor

    def attach(self, supervisor) -> None:
        self._supervisor = supervisor
        supervisor.agent_service = self

    def register(self, profile: AgentProfile, harness_factory,
                 harness_id: str, harness_version: int) -> None:
        with self._lock:
            self._versions.setdefault(profile.id, {})[profile.version] = profile
            self._profiles[profile.id] = profile
            self._harnesses[profile.implementation_ref] = (
                harness_factory, harness_id, harness_version)

    def register_builtin_reference(self) -> None:
        self.register(
            AgentProfile(id="reference.status", version=1,
                         harness_id=ReferenceStatusHarness.id,
                         harness_version=ReferenceStatusHarness.version,
                         state_schema_version=1,
                         implementation_ref="builtin:reference.status"),
            ReferenceStatusHarness,
            ReferenceStatusHarness.id, ReferenceStatusHarness.version)

    def register_builtin_echo(self, model_alias: str) -> None:
        self.register(
            AgentProfile(id="reference.echo", version=1,
                         harness_id=ReferenceEchoHarness.id,
                         harness_version=ReferenceEchoHarness.version,
                         state_schema_version=1,
                         model_profile_alias=model_alias,
                         implementation_ref="builtin:reference.echo"),
            lambda: ReferenceEchoHarness(model_alias),
            ReferenceEchoHarness.id, ReferenceEchoHarness.version)

    def register_runtime_operator(self, model_alias: str) -> None:
        self.register(
            AgentProfile(id="operator", version=1,
                         harness_id=RuntimeOperatorHarness.id,
                         harness_version=RuntimeOperatorHarness.version,
                         state_schema_version=1,
                         model_profile_alias=model_alias,
                         implementation_ref="builtin:operator.runtime"),
            lambda: RuntimeOperatorHarness(model_alias),
            RuntimeOperatorHarness.id, RuntimeOperatorHarness.version)

    def profile_ids(self) -> list[str]:
        with self._lock:
            return sorted(self._profiles)

    def profile_summaries(self) -> list[dict]:
        with self._lock:
            return [{
                "id": p.id, "version": p.version,
                "harnessId": p.harness_id,
                "harnessVersion": p.harness_version,
                "stateSchemaVersion": p.state_schema_version,
                "toolScope": list(p.tool_scope),
                "model": p.model_profile_alias,
            } for p in sorted(self._profiles.values(), key=lambda x: x.id)]

    def profile(self, agent_id: str) -> AgentProfile | None:
        with self._lock:
            return self._profiles.get(agent_id)

    def new_session(self, agent_id: str, consumer_id: str,
                    connection_id: str) -> AgentSession:
        with self._lock:
            profile = self._profiles.get(agent_id)
            if profile is None or profile.implementation_ref not in self._harnesses:
                raise PlatformError(ErrorCode.NOT_FOUND,
                                    "agent not registered")
            owned = sum(1 for s in self._sessions.values()
                        if s.connection_id == connection_id)
            if owned >= PlatformLimits.SESSIONS_PER_CONNECTION:
                raise PlatformError(ErrorCode.CAPACITY_LIMITED,
                                    "session limit reached")
            self._sequence += 1
            session = AgentSession(
                id=f"sess-{self._sequence}", profile=profile,
                consumer_id=consumer_id, connection_id=connection_id,
                created_at=time.time())
            self._sessions[session.id] = session
        return session

    def session(self, session_id: str, consumer_id: str,
                connection_id: str) -> AgentSession | None:
        with self._lock:
            s = self._sessions.get(session_id)
            if s and s.consumer_id == consumer_id \
                    and s.connection_id == connection_id:
                return s
            return None

    def begin_prompt(self, session_id: str, consumer_id: str,
                     connection_id: str) -> AgentSession:
        """Atomically claim the session's single prompt slot."""
        with self._lock:
            session = self._sessions.get(session_id)
            if (session is None or session.consumer_id != consumer_id
                    or session.connection_id != connection_id):
                raise PlatformError(ErrorCode.SESSION_CLOSED)
            if session.prompt_active:
                raise PlatformError(ErrorCode.CONFLICT,
                                    "session already has an active turn")
            session.prompt_active = True
            return session

    def harness_for(self, session: AgentSession):
        with self._lock:
            entry = self._harnesses.get(session.profile.implementation_ref)
        if entry is None:
            raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                                "harness missing")
        return entry[0]()

    def set_prompt_active(self, session_id: str, active: bool) -> None:
        with self._lock:
            if session_id in self._sessions:
                self._sessions[session_id].prompt_active = active

    def mark_cancelled(self, run_id: str) -> None:
        with self._lock:
            self._cancelled_runs.add(run_id)

    def is_cancelled(self, run_id: str) -> bool:
        with self._lock:
            return run_id in self._cancelled_runs

    def clear_run(self, run_id: str) -> None:
        with self._lock:
            self._cancelled_runs.discard(run_id)

    def close_connection(self, connection_id: str) -> list[AgentSession]:
        with self._lock:
            owned = [s for s in self._sessions.values()
                     if s.connection_id == connection_id]
            for s in owned:
                self._sessions.pop(s.id, None)
            return sorted(owned, key=lambda s: s.id)

    def close_all(self) -> None:
        with self._lock:
            self._sessions.clear()
            self._cancelled_runs.clear()
