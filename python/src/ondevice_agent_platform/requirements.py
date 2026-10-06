"""Provider/route requirements: the design where every served route declares
what it needs, and the platform qualifies it against the host rather than
assuming or predefining fitness.

A route's `requires` is owner-visible data; a provider that cannot satisfy
its own requirement reports `unavailable` truthfully - never presents a
route it cannot execute.
"""
from __future__ import annotations

import os
import platform as _plat
from dataclasses import dataclass

from .compat import ARCH, SYSTEM


@dataclass(frozen=True)
class RouteRequirements:
    """Host conditions a route needs. `os`: platform.system() names or
    "any". `accelerator`: "metal" | "cuda" | "none" | "any". `format`:
    artifact format ("mlx" | "gguf" | "none"). `min_free_bytes`: memory the
    route needs free at dispatch (0 = unspecified)."""
    os: tuple = ("macOS",)          # platform.system()=="Darwin" maps below
    accelerator: str = "none"       # metal | cuda | none | any
    fmt: str = "none"               # mlx | gguf | none
    min_free_bytes: int = 0


@dataclass(frozen=True)
class HostInfo:
    os: str                 # normalized: "macos" | "linux" | "windows"
    arch: str               # normalized: "arm64" | "x86_64"
    has_metal: bool
    total_memory: int


def _normalize_os(name: str) -> str:
    return {"Darwin": "macos", "Linux": "linux", "Windows": "windows"}.get(
        name, name.lower())


def _normalize_arch(name: str) -> str:
    n = name.lower()
    if n in ("arm64", "aarch64"):
        return "arm64"
    if n in ("x86_64", "amd64"):
        return "x86_64"
    return n


def host_info() -> HostInfo:
    has_metal = SYSTEM == "Darwin" and _normalize_arch(ARCH) == "arm64"
    total = 0
    try:
        if SYSTEM == "Darwin":
            import ctypes
            lib = ctypes.CDLL("libSystem.dylib")
            v = ctypes.c_uint64(0)
            s = ctypes.c_size_t(8)
            lib.sysctlbyname(b"hw.memsize", ctypes.byref(v),
                             ctypes.byref(s), None, 0)
            total = v.value
        elif SYSTEM == "Linux":
            with open("/proc/meminfo") as f:
                for line in f:
                    if line.startswith("MemTotal:"):
                        total = int(line.split()[1]) * 1024
                        break
        elif SYSTEM == "Windows":
            import ctypes
            class MSE(ctypes.Structure):
                _fields_ = [("dwLength", _plat.ctypes.c_ulong if False else ctypes.c_ulong),
                            ("dwMemoryLoad", ctypes.c_ulong),
                            ("ullTotalPhys", ctypes.c_ulonglong),
                            ("rest", ctypes.c_ulonglong * 6)]
            st = MSE()
            st.dwLength = ctypes.sizeof(st)
            if ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(st)):
                total = st.ullTotalPhys
        else:
            total = 0
    except (OSError, AttributeError, ValueError):
        total = 0
    return HostInfo(os=_normalize_os(SYSTEM), arch=_normalize_arch(ARCH),
                    has_metal=has_metal, total_memory=total)


def qualifies(req: RouteRequirements, host: HostInfo) -> tuple[bool, str]:
    """(eligible, reason). Reasons are truthful non-fit explanations."""
    if req.os != ("any",):
        wanted = tuple(_normalize_os(o) for o in req.os)
        if host.os not in wanted:
            return False, f"requires {','.join(req.os)}"
    if req.accelerator == "metal" and not host.has_metal:
        return False, "requires Metal (Apple Silicon)"
    if req.accelerator == "cuda":
        # Detection without a dependency: presence of the CUDA driver.
        found = os.path.exists("/proc/driver/nvidia/version") or \
            os.path.exists("C:\\Windows\\System32\\nvapi64.dll")
        if not found:
            return False, "requires CUDA device"
    if req.min_free_bytes and host.total_memory:
        if host.total_memory < req.min_free_bytes:
            return False, "requires more memory than this host has"
    return True, "ok"
