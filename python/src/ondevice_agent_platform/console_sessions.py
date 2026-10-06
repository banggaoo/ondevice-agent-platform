"""Console cookie sessions + CSRF, mirroring ConsoleSessions.swift."""
from __future__ import annotations

import secrets
import threading
import time

from .errors import ErrorCode, PlatformError
from .limits import PlatformLimits


class ConsoleSessions:
    class Session:
        def __init__(self, session_id: str, csrf: str, expires_at: float):
            self.id = session_id
            self.csrf = csrf
            self.expires_at = expires_at

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._sessions: dict[str, ConsoleSessions.Session] = {}
        self._login_window: list[float] = []

    def lookup(self, session_id: str):
        with self._lock:
            session = self._sessions.get(session_id)
            if session is None or session.expires_at <= time.time():
                return None
            return session

    def login_allowed(self) -> bool:
        cutoff = time.time() - 60
        with self._lock:
            self._login_window = [t for t in self._login_window
                                  if t >= cutoff]
            if len(self._login_window) >= \
                    PlatformLimits.LOGIN_ATTEMPTS_PER_MINUTE:
                return False
            self._login_window.append(time.time())
            return True

    def create(self) -> "ConsoleSessions.Session":
        with self._lock:
            if len(self._sessions) >= PlatformLimits.CONSOLE_SESSIONS:
                raise PlatformError(ErrorCode.CAPACITY_LIMITED,
                                    "console session limit reached")
            session = ConsoleSessions.Session(
                session_id=secrets.token_urlsafe(24),
                csrf=secrets.token_urlsafe(24),
                expires_at=time.time()
                + PlatformLimits.CONSOLE_SESSION_SECONDS)
            self._sessions[session.id] = session
            return session

    def logout(self, session_id: str) -> None:
        with self._lock:
            self._sessions.pop(session_id, None)
