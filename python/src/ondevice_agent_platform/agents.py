"""Hosted-agent runtime, mirroring AgentService.swift plus the built-in
harnesses (reference.status, reference.echo, operator.runtime).

Sessions are bound to a single connection and consumer; profiles pin their
harness versions at creation; implementations are reviewed compiled-in
code resolved by reference name - never arbitrary path loading.
"""
from __future__ import annotations

import enum
import json
import shutil
import subprocess
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path

from .chat import (ChatImage, ChatMessage, ChatRequest, ChatRole,
                   FinishReason)
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
    kind: str                # "text" | "resource_link" | "image"
    text: str = ""
    uri: str = ""
    image: "ChatImage | None" = None


def prompt_text(blocks) -> str:
    """The text a text-consuming harness sends for a turn: text blocks
    plus resource-link references rendered as markdown links (uris are
    client-provided labels, never fetched)."""
    parts = []
    for b in blocks:
        if b.kind == "text":
            parts.append(b.text)
        elif b.kind == "resource_link" and b.uri:
            parts.append(f"[{b.text or b.uri}]({b.uri})")
    return "\n".join(parts).strip()


def prompt_images(blocks) -> list:
    return [b.image for b in blocks
            if b.kind == "image" and b.image is not None]


@dataclass
class AgentSession:
    id: str
    profile: AgentProfile
    consumer_id: str
    connection_id: str
    created_at: float
    prompt_active: bool = False
    # Bounded in-memory turn transcript ({"role","text"}), trimmed to
    # PlatformLimits.AGENT_SESSION_*; not persisted - a restarted daemon
    # resumes the session with an empty transcript.
    transcript: list = field(default_factory=list)
    transcript_bytes: int = 0


# ---------------------------------------------------------------------------
# Harnesses: reviewed, compiled-in implementations.
# ---------------------------------------------------------------------------

def _trim_transcript(session: "AgentSession") -> None:
    max_entries = 2 * PlatformLimits.AGENT_SESSION_TURNS
    while (len(session.transcript) > max_entries
           or session.transcript_bytes
           > PlatformLimits.AGENT_SESSION_TRANSCRIPT_BYTES):
        old = session.transcript.pop(0)
        session.transcript_bytes -= len(old["text"].encode())


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
        text = prompt_text(input_blocks)
        if not text:
            emit("message_chunk", "Nothing to echo.")
            return AgentStopReason.REFUSAL
        if context.is_cancelled():
            return AgentStopReason.CANCELLED
        messages = [ChatMessage(role=(ChatRole.USER
                                      if e["role"] == "user"
                                      else ChatRole.ASSISTANT),
                                parts=[e["text"]])
                    for e in context.history()]
        messages.append(ChatMessage(role=ChatRole.USER, parts=[text]))
        try:
            result = context.complete(ChatRequest(
                model=self._alias, messages=messages,
                max_output_tokens=64, has_explicit_output_limit=True))
            emit("message_chunk", result.content)
            return AgentStopReason.END_TURN
        except PlatformError as e:
            if e.code == ErrorCode.CANCELLED:
                return AgentStopReason.CANCELLED
            emit("message_chunk", f"Echo unavailable: {e.safe_message}")
            return AgentStopReason.ERROR


# ---------------------------------------------------------------------------
# workspace.manage — deterministic workspace manager for external
# orchestrators (e.g. POH). Default action "report" is analysis only; an
# explicit {"action": "purge"} task deletes the allowlisted cache/build
# directories found inside the declared workspace — nothing outside it,
# never through a symlink — and reports reclaimed bytes.
# ---------------------------------------------------------------------------

_WS_PURGE_DIRS = (
    "DerivedData", "node_modules", ".venv", "venv", "env",
    "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache",
    "dist", "build", ".next", ".build", "Pods",
)
_WS_SKIP_DIRS = {".git", ".venv", "venv", "env", "node_modules",
                 "__pycache__", ".pytest_cache", "Pods", "DerivedData",
                 ".build", "build", "dist", ".next"}
_WS_MAX_WALK_FILES = 4000


def _ws_dir_size(path: Path) -> int:
    total = 0
    files = 0
    stack = [path]
    while stack:
        cur = stack.pop()
        try:
            entries = list(cur.iterdir())
        except OSError:
            continue
        for e in entries:
            try:
                if e.is_dir():
                    stack.append(e)
                elif e.is_file():
                    files += 1
                    if files > _WS_MAX_WALK_FILES:
                        return total
                    total += e.stat().st_size
            except OSError:
                continue
    return total


def _ws_git_state(path: Path) -> dict:
    if not (path / ".git").exists():
        return {}
    def _git(*args: str) -> str:
        try:
            out = subprocess.run(
                ["git", "-C", str(path), *args],
                capture_output=True, text=True, timeout=15)
            return out.stdout if out.returncode == 0 else ""
        except Exception:
            return ""
    status = _git("status", "--porcelain=v1", "--branch")
    lines = status.splitlines()
    ahead = _git("rev-list", "--count", "@{u}..HEAD").strip()
    return {
        "branch": lines[0].lstrip("# ") if lines else "?",
        "dirty_files": max(0, len(lines) - 1),
        "unpushed_commits": int(ahead) if ahead.isdigit() else None,
    }


def _ws_purge(workspace: Path, report: dict) -> None:
    """Delete every scanned purge candidate inside ``workspace``.

    Candidates come from the fixed _WS_PURGE_DIRS allowlist under direct
    workspace children, so execution is bounded by construction; we still
    refuse symlinks and resolved paths outside the workspace root.
    """
    root = workspace.resolve()
    removed = 0
    for entry in report["entries"]:
        for cand in entry["purge_candidates"]:
            target = Path(cand["path"])
            if target.is_symlink():
                cand["skipped"] = "symlink"
                continue
            try:
                if not target.resolve().is_relative_to(root):
                    cand["skipped"] = "outside-workspace"
                    continue
                shutil.rmtree(target)
            except OSError as exc:
                cand["error"] = str(exc)
                report["purge_errors"].append(
                    {"path": cand["path"], "error": str(exc)})
                continue
            cand["removed"] = True
            removed += 1
            report["freed_bytes"] += cand["bytes"]
    report["removed_count"] = removed
    report["action_executed"] = "purge"
    report["disk_free_bytes_after"] = shutil.disk_usage(workspace).free


def manage_workspace(task: dict) -> dict:
    """Workspace analysis for the workspace.manage harness.

    ``task["action"]`` defaults to ``"report"`` (analysis only). The
    explicit ``"purge"`` action reclaims allowlisted directories inside
    the workspace and annotates each candidate removed/skipped/error."""
    workspace = Path(task.get("workspace") or "").expanduser()
    action = str(task.get("action") or "report")
    report = {
        "workspace": str(workspace),
        "agent": WorkspaceManageHarness.id,
        "ok": False,
        "action_executed": "report",
        "metrics": task.get("metrics") or {},
        "findings": task.get("findings") or [],
        "entries": [],
        "purge_total_bytes": 0,
        "freed_bytes": 0,
        "removed_count": 0,
        "purge_errors": [],
        "actions": [],
    }
    if not workspace.is_dir():
        report["error"] = f"workspace {workspace} is not a directory"
        return report
    report["ok"] = True
    for child in sorted(workspace.iterdir(), key=lambda p: p.name.lower()):
        if not child.is_dir() or child.name.startswith("."):
            continue
        purges = []
        for name in _WS_PURGE_DIRS:
            candidate = child / name
            if candidate.is_dir():
                purges.append({"path": str(candidate),
                               "bytes": _ws_dir_size(candidate)})
        entry = {
            "name": child.name,
            "path": str(child),
            "purge_candidates": purges,
            "reclaimable_bytes": sum(p["bytes"] for p in purges),
            "git": _ws_git_state(child),
        }
        report["entries"].append(entry)
        report["purge_total_bytes"] += entry["reclaimable_bytes"]
    if action == "purge":
        _ws_purge(workspace, report)
    metrics = report["metrics"]
    disk_status = str(metrics.get("disk_status") or "")
    top = sorted(report["entries"], key=lambda e: e["reclaimable_bytes"],
                 reverse=True)
    if disk_status == "CRITICAL_LOW" or report["action_executed"] == "purge":
        executed = report["action_executed"] == "purge"
        purge_action = {
            "action": "purge",
            "severity": "CRITICAL",
            "executed": executed,
        }
        if executed:
            purge_action["detail"] = (
                f"freed {report['freed_bytes']/1e9:.2f} GB across "
                f"{report['removed_count']} directories"
                + (f"; {len(report['purge_errors'])} error(s)"
                   if report["purge_errors"] else ""))
        else:
            purge_action["detail"] = (
                "reclaim cache/build directories to restore free disk "
                "(send action='purge' to execute)")
            purge_action["candidates"] = [
                {"path": p["path"], "bytes": p["bytes"]}
                for e in top[:5] for p in e["purge_candidates"]][:8]
        report["actions"].append(purge_action)
    if disk_status in ("LOW", "CRITICAL_LOW"):
        report["actions"].append({
            "action": "report",
            "severity": "WARNING",
            "detail": f"workspace holds {report['purge_total_bytes']/1e9:.1f} GB "
                      "of reclaimable cache/build data",
        })
    dirty = [e["name"] for e in report["entries"]
             if (e["git"].get("dirty_files") or 0) > 0]
    unpushed = [f"{e['name']}({e['git']['unpushed_commits']})"
                for e in report["entries"]
                if (e["git"].get("unpushed_commits") or 0) > 0]
    if dirty or unpushed:
        report["actions"].append({
            "action": "git_hygiene",
            "severity": "WARNING",
            "detail": f"dirty: {', '.join(dirty) or 'none'}; "
                      f"unpushed: {', '.join(unpushed) or 'none'}",
        })
    return report


class WorkspaceManageHarness:
    """Deterministic workspace manager (no model call): the prompt is a
    JSON task ({workspace, metrics, findings, action}) or a bare workspace
    path. Returns a JSON management report; only the explicit "purge"
    action mutates anything — allowlisted cache/build dirs inside the
    declared workspace."""
    id = "workspace.manage"
    version = 1

    def run(self, input_blocks, context, emit) -> AgentStopReason:
        text = prompt_text(input_blocks)
        if not text:
            emit("message_chunk", "No workspace task to evaluate.")
            return AgentStopReason.REFUSAL
        try:
            task = json.loads(text)
        except json.JSONDecodeError:
            task = {"workspace": text.strip()}
        emit("message_chunk", json.dumps(manage_workspace(task), indent=2))
        return AgentStopReason.END_TURN


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


class CustomChatHarness:
    """Owner-declared general chat agent: a named profile with its own
    system prompt bound to a declared model alias. Same contract as the
    Operator minus the status snapshot - one bounded model call per turn,
    no tools, no authority - plus a bounded per-session transcript so a
    session is a real conversation. Image blocks pass through to the
    bound model; validate_chat enforces vision capability and limits."""
    id = "custom.chat"
    version = 1
    DEFAULT_MAX_OUTPUT_TOKENS = 1024

    def __init__(self, model_alias: str, system_prompt: str,
                 max_output_tokens: int | None = None) -> None:
        self._alias = model_alias
        self._system = system_prompt
        self._max = (max_output_tokens
                     or self.DEFAULT_MAX_OUTPUT_TOKENS)

    def run(self, input_blocks, context, emit) -> AgentStopReason:
        text = prompt_text(input_blocks)
        images = prompt_images(input_blocks)
        if not text and not images:
            emit("message_chunk", "Nothing to answer.")
            return AgentStopReason.REFUSAL
        if context.is_cancelled():
            return AgentStopReason.CANCELLED
        if not context.model_ready(self._alias):
            emit("message_chunk",
                 f"model '{self._alias}' is not installed; "
                 "pull it first.")
            return AgentStopReason.ERROR
        messages = []
        if self._system:
            messages.append(ChatMessage(role=ChatRole.SYSTEM,
                                        parts=[self._system]))
        for entry in context.history():
            role = (ChatRole.USER if entry["role"] == "user"
                    else ChatRole.ASSISTANT)
            messages.append(ChatMessage(role=role,
                                        parts=[entry["text"]]))
        messages.append(ChatMessage(role=ChatRole.USER, parts=[text],
                                    images=images))
        try:
            result = context.complete(ChatRequest(
                model=self._alias, messages=messages,
                max_output_tokens=self._max,
                has_explicit_output_limit=True))
            if context.is_cancelled():
                return AgentStopReason.CANCELLED
            if result.tool_calls:
                emit("message_chunk",
                     "This agent cannot execute tool calls.")
                return AgentStopReason.ERROR
            if result.finish_reason == FinishReason.CONTENT_FILTER:
                emit("message_chunk",
                     result.content or "Response was refused.")
                return AgentStopReason.REFUSAL
            if result.finish_reason in (FinishReason.ERROR,
                                        FinishReason.TOOL_CALLS):
                emit("message_chunk", "Model returned an unusable response.")
                return AgentStopReason.ERROR
            if not result.content.strip():
                emit("message_chunk", "Model returned no usable text.")
                return AgentStopReason.ERROR
            emit("message_chunk", result.content)
            return (AgentStopReason.MAX_TOKENS
                    if result.finish_reason == FinishReason.LENGTH
                    else AgentStopReason.END_TURN)
        except PlatformError as e:
            if e.code == ErrorCode.CANCELLED:
                return AgentStopReason.CANCELLED
            emit("message_chunk", f"Agent unavailable: {e.safe_message}")
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

    def resume_sessions(self, store) -> None:
        """Session ids persist in the durable ledger across restarts;
        resume the in-memory sequence above them or the next
        `sess-N` collides on the store's primary key. Called by the
        supervisor after the store opens."""
        with self._lock:
            self._sequence = store.max_session_sequence()

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

    def register_builtin_workspace(self) -> None:
        self.register(
            AgentProfile(id="workspace.manage", version=1,
                         harness_id=WorkspaceManageHarness.id,
                         harness_version=WorkspaceManageHarness.version,
                         state_schema_version=1,
                         implementation_ref="builtin:workspace.manage"),
            WorkspaceManageHarness,
            WorkspaceManageHarness.id, WorkspaceManageHarness.version)

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

    def unregister_runtime_operator(self) -> bool:
        """Remove the optional runtime Operator profile. Existing ACP
        sessions keep their bound profile snapshot; new session/new calls
        no longer see the agent. Returns True when it was registered."""
        with self._lock:
            existed = self._profiles.pop("operator", None) is not None
            self._versions.pop("operator", None)
            return existed

    def register_custom_agent(self, agent_id: str, model_alias: str,
                              system_prompt: str,
                              max_output_tokens: int | None) -> None:
        """Owner-declared chat agent. Each id gets its own
        implementation_ref so its factory (system prompt + model) is
        distinct; unregister keeps the harness entry so bound sessions
        finish like operator sessions do."""
        self.register(
            AgentProfile(id=agent_id, version=1,
                         harness_id=CustomChatHarness.id,
                         harness_version=CustomChatHarness.version,
                         state_schema_version=1,
                         model_profile_alias=model_alias,
                         implementation_ref=
                         f"builtin:custom.chat/{agent_id}"),
            lambda: CustomChatHarness(model_alias, system_prompt,
                                      max_output_tokens),
            CustomChatHarness.id, CustomChatHarness.version)

    def unregister_agent(self, agent_id: str) -> bool:
        """Remove any agent profile (custom or operator). Sessions keep
        their bound profile snapshot; the harness factory stays so an
        in-flight turn still resolves."""
        with self._lock:
            profile = self._profiles.pop(agent_id, None)
            self._versions.pop(agent_id, None)
            return profile is not None

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
                "custom": p.implementation_ref.startswith(
                    "builtin:custom.chat/"),
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

    def transcript(self, session_id: str) -> list:
        """Copy of the session's bounded turn transcript for harness
        use; [] for unknown or never-prompted sessions."""
        with self._lock:
            session = self._sessions.get(session_id)
            return list(session.transcript) if session else []

    def record_turn(self, session_id: str, user_text: str,
                    assistant_text: str) -> None:
        """Append a completed turn to the session transcript, trimming
        oldest entries past the turn/byte bounds. Images never enter the
        transcript - history is text only."""
        with self._lock:
            session = self._sessions.get(session_id)
            if session is None:
                return
            for role, text in (("user", user_text),
                               ("assistant", assistant_text)):
                if text:
                    session.transcript.append({"role": role,
                                               "text": text})
                    session.transcript_bytes += len(text.encode())
            _trim_transcript(session)

    def adopt_session(self, session_id: str, agent_id: str,
                      consumer_id: str, connection_id: str,
                      transcript: list) -> AgentSession:
        """session/load: bring a ledger-resident session live again on a
        (possibly new) connection, with its persisted transcript."""
        with self._lock:
            if session_id in self._sessions:
                raise PlatformError(ErrorCode.CONFLICT,
                                    "session already active")
            profile = self._profiles.get(agent_id)
            if profile is None \
                    or profile.implementation_ref not in self._harnesses:
                raise PlatformError(ErrorCode.NOT_FOUND,
                                    "agent not registered")
            session = AgentSession(
                id=session_id, profile=profile, consumer_id=consumer_id,
                connection_id=connection_id, created_at=time.time())
            session.transcript = [dict(e) for e in transcript]
            session.transcript_bytes = sum(
                len(e["text"].encode()) for e in session.transcript)
            _trim_transcript(session)
            self._sessions[session_id] = session
            return session

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
