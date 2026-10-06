"""Cross-platform primitives: OS detection, file locks, owned-file writes.

POSIX systems use fcntl.flock + O_NOFOLLOW; Windows uses msvcrt byte-range
locking and GetFileAttributes-based symlink detection. The security posture
is the same everywhere the platform can express it; where an OS cannot
express a check the function is honest about what it verified.
"""
from __future__ import annotations

import os
import platform
import stat
import sys
import uuid

SYSTEM = platform.system()  # "Darwin" | "Linux" | "Windows"
IS_POSIX = os.name == "posix"
IS_WINDOWS = SYSTEM == "Windows"
IS_MACOS = SYSTEM == "Darwin"
IS_LINUX = SYSTEM == "Linux"

ARCH = platform.machine().lower()  # "arm64"/"aarch64" | "x86_64"/"amd64"


def is_symlink(path: str) -> bool:
    """True when `path` itself is a symlink or Windows reparse point."""
    try:
        st = os.lstat(path)
    except OSError:
        return False
    if stat.S_ISLNK(st.st_mode):
        return True
    if IS_WINDOWS:
        return bool(getattr(st, "st_file_attributes", 0)
                    & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400))
    return False


def acquire_lock(path: str) -> int:
    """Exclusive nonblocking lifetime lock on `path`; returns a live fd.

    Raises PlatformError.root_unsafe on symlink/conflict. The caller holds
    the fd; closing it (or process exit) releases the lock.
    """
    from .errors import ErrorCode, PlatformError

    if is_symlink(path):
        raise PlatformError(ErrorCode.ROOT_UNSAFE, "symlinked lock file")
    flags = os.O_CREAT | os.O_RDWR
    if IS_POSIX and hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(path, flags, 0o600)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            raise PlatformError(ErrorCode.ROOT_UNSAFE, "not a regular file")
        if IS_POSIX and st.st_uid != os.getuid():
            raise PlatformError(ErrorCode.ROOT_UNSAFE, "not owned")
        _apply_owner_only(fd, path)
        if IS_POSIX:
            import fcntl
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                raise PlatformError(ErrorCode.CONFLICT, "root already locked")
        else:
            import msvcrt
            try:
                msvcrt.locking(fd, msvcrt.LK_NBLCK, 1)
            except OSError:
                raise PlatformError(ErrorCode.CONFLICT, "root already locked")
        return fd
    except BaseException:
        os.close(fd)
        raise


def release_lock(fd: int) -> None:
    try:
        if IS_POSIX:
            import fcntl
            fcntl.flock(fd, fcntl.LOCK_UN)
        else:
            import msvcrt
            os.lseek(fd, 0, os.SEEK_SET)
            msvcrt.locking(fd, msvcrt.LK_UNLCK, 1)
    except OSError:
        pass
    finally:
        try:
            os.close(fd)
        except OSError:
            pass


def _apply_owner_only(fd: int, path: str) -> None:
    """Best-effort 0600. Windows ACLs are not modeled here; the runtime root
    is created user-private and we report rather than emulate POSIX modes."""
    if IS_POSIX:
        os.fchmod(fd, 0o600)


def open_owned(path: str, flags: int) -> int:
    """Open an owned regular file with O_NOFOLLOW and mode 0600."""
    from .errors import ErrorCode, PlatformError

    if is_symlink(path):
        raise PlatformError(ErrorCode.ROOT_UNSAFE, "symlinked state file")
    real_flags = flags
    if IS_POSIX and hasattr(os, "O_NOFOLLOW"):
        real_flags |= os.O_NOFOLLOW
    fd = os.open(path, real_flags, 0o600)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            raise PlatformError(ErrorCode.ROOT_UNSAFE, "not a regular file")
        if IS_POSIX and st.st_uid != os.getuid():
            raise PlatformError(ErrorCode.ROOT_UNSAFE, "not owned")
        _apply_owner_only(fd, path)
        return fd
    except BaseException:
        os.close(fd)
        raise


def write_owned(path: str, data: bytes) -> None:
    """Atomic owned-file write: validate the existing target, stage into a
    private same-directory temp file, fsync, then os.replace. A failed or
    interrupted write never truncates the live file; only the temp file
    this call created is ever removed."""
    from .errors import ErrorCode, PlatformError

    # Validate the existing target before any mutation.
    if is_symlink(path):
        raise PlatformError(ErrorCode.ROOT_UNSAFE, "symlinked state file")
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        st = None
    if st is not None:
        if not stat.S_ISREG(st.st_mode):
            raise PlatformError(ErrorCode.ROOT_UNSAFE, "not a regular file")
        if IS_POSIX and st.st_uid != os.getuid():
            raise PlatformError(ErrorCode.ROOT_UNSAFE, "not owned")

    directory = os.path.dirname(path) or "."
    tmp = os.path.join(directory,
                       f".oap-write-{os.getpid()}-{uuid.uuid4().hex}")
    flags = os.O_CREAT | os.O_WRONLY | os.O_EXCL
    if IS_POSIX and hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = -1
    try:
        fd = os.open(tmp, flags, 0o600)
        try:
            st = os.fstat(fd)
            if not stat.S_ISREG(st.st_mode):
                raise PlatformError(ErrorCode.ROOT_UNSAFE,
                                    "not a regular file")
            if IS_POSIX and st.st_uid != os.getuid():
                raise PlatformError(ErrorCode.ROOT_UNSAFE, "not owned")
        except BaseException:
            os.close(fd)
            fd = -1
            raise
        view = memoryview(data)
        while view:
            n = os.write(fd, view)
            if n <= 0:
                raise PlatformError(ErrorCode.STORAGE_FAILURE,
                                    f"write errno {n}")
            view = view[n:]
        os.fsync(fd)
        os.close(fd)
        fd = -1
        os.replace(tmp, path)
        # Rename durability: fsync the containing directory on POSIX so a
        # crash cannot lose the replacement. No claim beyond best effort.
        if IS_POSIX:
            try:
                dfd = os.open(directory, os.O_RDONLY)
                try:
                    os.fsync(dfd)
                finally:
                    os.close(dfd)
            except OSError:
                pass
    except BaseException:
        if fd >= 0:
            try:
                os.close(fd)
            except OSError:
                pass
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise


def read_owned(path: str, cap: int) -> bytes | None:
    from .errors import ErrorCode, PlatformError

    if is_symlink(path):
        raise PlatformError(ErrorCode.ROOT_UNSAFE, "symlinked file")
    if not os.path.exists(path):
        return None
    fd = open_owned(path, os.O_RDONLY)
    try:
        chunks = []
        total = 0
        while True:
            block = os.read(fd, 65536)
            if not block:
                break
            total += len(block)
            if total > cap:
                raise PlatformError(ErrorCode.STORAGE_FAILURE, "file too large")
            chunks.append(block)
        return b"".join(chunks)
    finally:
        os.close(fd)


def set_private_dir(path: str) -> None:
    if IS_POSIX:
        os.chmod(path, 0o700)


def home_dir() -> str:
    return os.path.expanduser("~")


def cpu_count() -> int:
    return os.cpu_count() or 1
