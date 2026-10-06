"""Filesystem safety for the runtime root, mirroring RuntimeRoot.swift."""
from __future__ import annotations

import json
import os

from .compat import (
    acquire_lock, is_symlink, release_lock, read_owned, set_private_dir,
    write_owned, home_dir,
)
from .errors import ErrorCode, PlatformError
from .limits import PlatformLimits

_OWNED_NAMES = {
    "config.json", "registry.json", "state.sqlite3",
    "state.sqlite3-wal", "state.sqlite3-shm",
    "lock.fd", "daemon.json", "sessions", "models",
}


class RuntimeRoot:
    """Owns creation, permission modes, symlink refusal, ownership checks,
    and the exclusive lifetime lock for the data root."""

    def __init__(self, path: str) -> None:
        # Canonicalize only the deepest existing ancestor, keeping the final
        # component literal - same rule as the Swift implementation.
        self.path = os.path.join(os.path.realpath(os.path.dirname(path) or "."),
                                 os.path.basename(os.path.normpath(path))) \
            if os.path.basename(os.path.normpath(path)) else os.path.realpath(path)
        self._lock_fd = -1

    @staticmethod
    def default() -> "RuntimeRoot":
        return RuntimeRoot(os.path.join(home_dir(), ".ondevice-agent-platform"))

    @property
    def config_path(self) -> str:
        return os.path.join(self.path, "config.json")

    @property
    def registry_path(self) -> str:
        return os.path.join(self.path, "registry.json")

    @property
    def database_path(self) -> str:
        return os.path.join(self.path, "state.sqlite3")

    @property
    def lock_path(self) -> str:
        return os.path.join(self.path, "lock.fd")

    @property
    def daemon_path(self) -> str:
        return os.path.join(self.path, "daemon.json")

    @property
    def models_path(self) -> str:
        return os.path.join(self.path, "models")

    def prepare(self) -> None:
        """Fresh or previously created root. Refuses symlinked roots and
        roots containing unrelated files."""
        if is_symlink(self.path):
            raise PlatformError(ErrorCode.ROOT_UNSAFE, "root is symlink")
        if os.path.exists(self.path):
            if not os.path.isdir(self.path):
                raise PlatformError(ErrorCode.ROOT_UNSAFE, "root not directory")
            for name in os.listdir(self.path):
                if name not in _OWNED_NAMES:
                    raise PlatformError(ErrorCode.ROOT_UNSAFE,
                                        "unrelated entry: present")
        else:
            os.mkdir(self.path, 0o700)
        set_private_dir(self.path)

    def acquire_lock(self) -> None:
        self._lock_fd = acquire_lock(self.lock_path)

    def release_lock(self) -> None:
        if self._lock_fd >= 0:
            release_lock(self._lock_fd)
            self._lock_fd = -1

    def check_state_files(self) -> None:
        for name in ("state.sqlite3", "state.sqlite3-wal", "state.sqlite3-shm"):
            if is_symlink(os.path.join(self.path, name)):
                raise PlatformError(ErrorCode.ROOT_UNSAFE, "symlinked db file")
        for name in ("config.json", "registry.json", "daemon.json"):
            if is_symlink(os.path.join(self.path, name)):
                raise PlatformError(ErrorCode.ROOT_UNSAFE, "symlinked config file")

    def write_json(self, obj, path: str) -> None:
        write_owned(path, json.dumps(obj, separators=(",", ":"),
                                     ensure_ascii=False).encode("utf-8"))

    def read_json(self, path: str):
        data = read_owned(path, PlatformLimits.REQUEST_BODY_BYTES)
        if data is None:
            return None
        try:
            return json.loads(data)
        except (json.JSONDecodeError, UnicodeDecodeError):
            raise PlatformError(ErrorCode.MALFORMED_JSON, "owned file not JSON")

    def write_daemon_marker(self, port: int) -> None:
        self.write_json({"port": port}, self.daemon_path)

    def read_daemon_marker(self) -> int | None:
        value = self.read_json(self.daemon_path)
        if not isinstance(value, dict):
            return None
        port = value.get("port")
        if isinstance(port, int) and 0 < port <= 65535:
            return port
        return None

    def remove_daemon_marker(self) -> None:
        try:
            os.remove(self.daemon_path)
        except OSError:
            pass
