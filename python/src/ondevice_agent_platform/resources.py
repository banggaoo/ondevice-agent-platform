"""Resource observation and admission policy, mirroring
ResourceSnapshot.swift + ResourcePolicy.swift.

Per-OS samplers:
- macOS: kern.memorystatus_level (kernel pressure gauge), pmset therm.
- Linux: MemAvailable ratio + PSI + cgroup v2 limits; /sys thermal zones.
- Windows: GlobalMemoryStatusEx + GetSystemPowerStatus; WMI thermal best
  effort.

`not_present` is a truthful sensor-absence report (verified: no sensor
exists), distinct from `unknown` (a sensor exists but observation failed);
only the latter denies admission.
"""
from __future__ import annotations

import ctypes
import enum
import glob
import os
import platform
import subprocess
import threading
import time
from typing import Callable

from .compat import IS_LINUX, IS_MACOS, IS_WINDOWS
from .limits import PlatformLimits


class ThermalLevel(enum.Enum):
    UNKNOWN = "unknown"
    NOT_PRESENT = "not_present"  # verified: device exposes no thermal sensor
    NOMINAL = "nominal"
    FAIR = "fair"
    SERIOUS = "serious"
    CRITICAL = "critical"


class MemoryPressureLevel(enum.Enum):
    UNKNOWN = "unknown"
    NORMAL = "normal"
    WARNING = "warning"
    CRITICAL = "critical"


class MemoryPressureSource(enum.Enum):
    EVENT = "dispatch_event"                    # native push event
    ESTIMATE = "available_percent_estimate"     # sampled ratio fallback
    PSI = "psi"                                 # Linux pressure stall info
    UNAVAILABLE = "unavailable"
    UNSPECIFIED = "unspecified"


class ResourceSnapshot:
    def __init__(self, thermal: ThermalLevel,
                 memory_pressure: MemoryPressureLevel,
                 low_power_mode: bool | None,
                 captured_at: float,
                 pressure_source: MemoryPressureSource = MemoryPressureSource.UNSPECIFIED):
        self.thermal = thermal
        self.memory_pressure = memory_pressure
        self.low_power_mode = low_power_mode
        self.captured_at = captured_at
        self.pressure_source = pressure_source

    @staticmethod
    def unknown() -> "ResourceSnapshot":
        return ResourceSnapshot(ThermalLevel.UNKNOWN,
                                MemoryPressureLevel.UNKNOWN, None, 0.0)


class ResourceVerdict(enum.Enum):
    ADMIT = "admit"
    DEFER_LOAD = "defer_load"            # reduced profile unqualified
    DENY_AND_CANCEL = "deny_and_cancel"  # block new inference, cancel children


def evaluate(snapshot: ResourceSnapshot, now: float) -> ResourceVerdict:
    """Admits only on fresh, known-healthy observations. `not_present`
    thermal is verified sensor-absence and does not gate; `unknown` denies.
    Pressure escalation wins over a reduced-power deferral."""
    if (snapshot.memory_pressure == MemoryPressureLevel.UNKNOWN
            or snapshot.thermal == ThermalLevel.UNKNOWN):
        return ResourceVerdict.DENY_AND_CANCEL
    age = now - snapshot.captured_at
    if (not (0.0 <= age <= PlatformLimits.RESOURCE_MAX_AGE_SECONDS)
            or snapshot.low_power_mode is None):
        return ResourceVerdict.DENY_AND_CANCEL
    if (snapshot.thermal in (ThermalLevel.SERIOUS, ThermalLevel.CRITICAL)
            or snapshot.memory_pressure == MemoryPressureLevel.CRITICAL):
        return ResourceVerdict.DENY_AND_CANCEL
    # Memory WARNING (kernel warn boundary, e.g. macOS level <= 30) freezes
    # new loads but lets in-flight work finish and keeps residents: the
    # boundary is a reclaim notice, not the emergency floor. A resident
    # model legitimately holds a loaded host at warning; only CRITICAL
    # (swap-storm floor) sheds everything.
    if (snapshot.thermal == ThermalLevel.FAIR or snapshot.low_power_mode
            or snapshot.memory_pressure == MemoryPressureLevel.WARNING):
        return ResourceVerdict.DEFER_LOAD
    return ResourceVerdict.ADMIT


# ---------------------------------------------------------------------------
# OS samplers. Each returns (thermal, pressure, low_power, source). All are
# cheap file/ctypes reads; nothing here may block for long.
# ---------------------------------------------------------------------------


def _read_file(path: str) -> str | None:
    try:
        with open(path, "r") as f:
            return f.read()
    except OSError:
        return None


def _pressure_from_ratio(available: int, total: int) -> MemoryPressureLevel:
    """Available-memory ratio mapped to the platform's escalation levels.
    warning at <20% available, critical at <8% - conservative, documented."""
    if total <= 0:
        return MemoryPressureLevel.UNKNOWN
    ratio = available / total
    if ratio < 0.08:
        return MemoryPressureLevel.CRITICAL
    if ratio < 0.20:
        return MemoryPressureLevel.WARNING
    return MemoryPressureLevel.NORMAL


def _sample_linux() -> tuple:
    # Memory: MemAvailable / MemTotal. cgroup v2 limit wins when tighter.
    total = available = 0
    info = _read_file("/proc/meminfo") or ""
    for line in info.splitlines():
        if line.startswith("MemTotal:"):
            total = int(line.split()[1]) * 1024
        elif line.startswith("MemAvailable:"):
            available = int(line.split()[1]) * 1024
    pressure = (_pressure_from_ratio(available, total)
                if total else MemoryPressureLevel.UNKNOWN)
    source = (MemoryPressureSource.ESTIMATE if total
              else MemoryPressureSource.UNAVAILABLE)
    # cgroup v2: when the container limit is the real constraint.
    cg_max = _read_file("/sys/fs/cgroup/memory.max")
    cg_cur = _read_file("/sys/fs/cgroup/memory.current")
    if cg_max and cg_cur and cg_max.strip() != "max":
        try:
            m, c = int(cg_max), int(cg_cur)
            if m > 0:
                cgp = _pressure_from_ratio(m - c, m)
                if cgp.value != MemoryPressureLevel.NORMAL.value or (
                        pressure == MemoryPressureLevel.NORMAL):
                    pressure = max(pressure, cgp,
                                   key=lambda p: [MemoryPressureLevel.NORMAL,
                                                  MemoryPressureLevel.WARNING,
                                                  MemoryPressureLevel.CRITICAL,
                                                  MemoryPressureLevel.UNKNOWN]
                                   .index(p))
        except ValueError:
            pass
    psi = _read_file("/proc/pressure/memory")
    if psi and "avg10=" in psi:
        try:
            avg10 = float(psi.split("avg10=")[1].split()[0])
            if avg10 >= 30.0 and pressure == MemoryPressureLevel.NORMAL:
                pressure = MemoryPressureLevel.WARNING
            if avg10 >= 60.0:
                pressure = MemoryPressureLevel.CRITICAL
            source = MemoryPressureSource.PSI
        except (ValueError, IndexError):
            pass
    # Thermal: hottest ratio across zones with a critical trip point.
    thermal = ThermalLevel.NOT_PRESENT
    worst = ThermalLevel.NOT_PRESENT
    zones = sorted(glob.glob("/sys/class/thermal/thermal_zone*/temp"))
    if zones:
        thermal = ThermalLevel.UNKNOWN
    for temp_path in zones:
        tdir = os.path.dirname(temp_path)
        temp_raw, crit_raw = _read_file(temp_path), None
        for trip in sorted(glob.glob(os.path.join(tdir, "trip_point_*_temp"))):
            ttype = _read_file(trip.replace("_temp", "_type"))
            if ttype and "critical" in ttype:
                crit_raw = _read_file(trip)
        if temp_raw and crit_raw:
            try:
                ratio = int(temp_raw) / int(crit_raw)
                level = (ThermalLevel.NOMINAL if ratio < 0.75
                         else ThermalLevel.FAIR if ratio < 0.88
                         else ThermalLevel.SERIOUS if ratio < 0.97
                         else ThermalLevel.CRITICAL)
                order = [ThermalLevel.NOMINAL, ThermalLevel.FAIR,
                         ThermalLevel.SERIOUS, ThermalLevel.CRITICAL]
                if worst == ThermalLevel.NOT_PRESENT or \
                        order.index(level) > order.index(worst):
                    worst = level
            except (ValueError, ZeroDivisionError):
                pass
    if worst != ThermalLevel.NOT_PRESENT:
        thermal = worst
    elif zones:
        thermal = ThermalLevel.NOMINAL  # sensors exist, no crit trip data
    # Low power: only machines with a battery can enter it.
    low_power = False
    supplies = glob.glob("/sys/class/power_supply/BAT*/status")
    for status_path in supplies:
        if (_read_file(status_path) or "").strip() == "Discharging":
            prof = _read_file("/sys/firmware/acpi/platform_profile") or ""
            low_power = "low-power" in prof
            break
    return thermal, pressure, low_power, source


def _sysctl_int(name: str) -> int | None:
    """macOS sysctlbyname via libSystem."""
    try:
        lib = ctypes.CDLL("libSystem.dylib")
        val = ctypes.c_uint64(0)
        size = ctypes.c_size_t(ctypes.sizeof(val))
        if lib.sysctlbyname(name.encode(), ctypes.byref(val),
                            ctypes.byref(size), None, 0) == 0:
            return val.value
    except (OSError, AttributeError):
        pass
    return None


_macos_pm_cache = {"at": float("-inf"), "thermal": ThermalLevel.UNKNOWN,
                   "low_power": False}


def _sample_macos() -> tuple:
    # kern.memorystatus_level: the kernel Jetsam gauge, percent of memory
    # still available - LOWER means MORE pressure. Warning follows the
    # kernel's own transition threshold (vm_pressure_level_transition_
    # threshold, observed 30); critical is the swap-storm floor.
    level = _sysctl_int("kern.memorystatus_level")
    if level is None:
        pressure, source = (MemoryPressureLevel.UNKNOWN,
                            MemoryPressureSource.UNAVAILABLE)
    else:
        pressure = (MemoryPressureLevel.CRITICAL if level <= 8
                    else MemoryPressureLevel.WARNING if level <= 30
                    else MemoryPressureLevel.NORMAL)
        source = MemoryPressureSource.ESTIMATE
    # pmset is a slower snapshot; refresh it at most every 5 s.
    now = time.monotonic()
    if now - _macos_pm_cache["at"] >= 5.0:
        _macos_pm_cache["at"] = now
        try:
            out = subprocess.run(["pmset", "-g", "therm"], capture_output=True,
                                 text=True, timeout=3).stdout
            limit = None
            for line in out.splitlines():
                if "CPU_Speed_Limit" in line:
                    limit = int(line.split("=")[1].strip())
            _macos_pm_cache["thermal"] = (
                ThermalLevel.NOMINAL if limit is None or limit >= 99
                else ThermalLevel.FAIR if limit >= 80
                else ThermalLevel.SERIOUS if limit >= 50
                else ThermalLevel.CRITICAL)
        except (OSError, ValueError, subprocess.SubprocessError):
            _macos_pm_cache["thermal"] = ThermalLevel.UNKNOWN
        try:
            out = subprocess.run(["pmset", "-g"], capture_output=True,
                                 text=True, timeout=3).stdout
            _macos_pm_cache["low_power"] = any(
                line.strip().startswith("lowpowermode")
                and line.rstrip().endswith("1")
                for line in out.splitlines())
        except (OSError, subprocess.SubprocessError):
            pass
    return (_macos_pm_cache["thermal"], pressure,
            _macos_pm_cache["low_power"], source)


def _sample_windows() -> tuple:
    class MEMSTATUSEX(ctypes.Structure):
        _fields_ = [("dwLength", ctypes.c_ulong),
                    ("dwMemoryLoad", ctypes.c_ulong),
                    ("ullTotalPhys", ctypes.c_ulonglong),
                    ("ullAvailPhys", ctypes.c_ulonglong),
                    ("ullTotalPageFile", ctypes.c_ulonglong),
                    ("ullAvailPageFile", ctypes.c_ulonglong),
                    ("ullTotalVirtual", ctypes.c_ulonglong),
                    ("ullAvailVirtual", ctypes.c_ulonglong),
                    ("ullAvailExtendedVirtual", ctypes.c_ulonglong)]

    class SYSTEM_POWER_STATUS(ctypes.Structure):
        _fields_ = [("ACLineStatus", ctypes.c_ubyte),
                    ("BatteryFlag", ctypes.c_ubyte),
                    ("BatteryLifePercent", ctypes.c_ubyte),
                    ("SystemStatusFlag", ctypes.c_ubyte),
                    ("BatteryLifeTime", ctypes.c_ulong),
                    ("BatteryFullLifeTime", ctypes.c_ulong)]

    try:
        st = MEMSTATUSEX()
        st.dwLength = ctypes.sizeof(st)
        if not ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(st)):
            raise OSError("GlobalMemoryStatusEx failed")
        pressure = _pressure_from_ratio(st.ullAvailPhys, st.ullTotalPhys)
        source = MemoryPressureSource.ESTIMATE
    except (OSError, AttributeError):
        pressure, source = (MemoryPressureLevel.UNKNOWN,
                            MemoryPressureSource.UNAVAILABLE)
    low_power = False
    try:
        sps = SYSTEM_POWER_STATUS()
        if ctypes.windll.kernel32.GetSystemPowerStatus(ctypes.byref(sps)):
            low_power = sps.SystemStatusFlag == 1  # battery saver on
    except (OSError, AttributeError):
        pass
    # Thermal: user-accessible sensors are rare on Windows; WMI thermal is
    # admin-gated, so absence of any readable zone is sensor absence.
    return ThermalLevel.NOT_PRESENT, pressure, low_power, source


def _sample_fallback() -> tuple:
    return (ThermalLevel.UNKNOWN, MemoryPressureLevel.UNKNOWN, None,
            MemoryPressureSource.UNAVAILABLE)


def sample() -> ResourceSnapshot:
    if IS_LINUX:
        t, p, lp, src = _sample_linux()
    elif IS_MACOS:
        t, p, lp, src = _sample_macos()
    elif IS_WINDOWS:
        t, p, lp, src = _sample_windows()
    else:
        t, p, lp, src = _sample_fallback()
    return ResourceSnapshot(t, p, lp, time.time(), src)


class ResourceSource:
    """Observation source contract: current snapshot + change callbacks."""

    def current_snapshot(self) -> ResourceSnapshot:
        raise NotImplementedError

    def start(self, on_change: Callable[[ResourceSnapshot], None]) -> None:
        raise NotImplementedError

    def stop(self) -> None:
        raise NotImplementedError


class PollingResourceSource(ResourceSource):
    """Polls the OS sampler each RESOURCE_SAMPLE_SECONDS; publishes only
    fresh snapshots. Change-driven: a new sample always calls back."""

    def __init__(self) -> None:
        self._latest = sample()
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    def current_snapshot(self) -> ResourceSnapshot:
        with self._lock:
            return self._latest

    def start(self, on_change: Callable[[ResourceSnapshot], None]) -> None:
        def loop() -> None:
            while not self._stop.wait(PlatformLimits.RESOURCE_SAMPLE_SECONDS):
                snap = sample()
                with self._lock:
                    self._latest = snap
                try:
                    on_change(snap)
                except Exception:
                    pass

        self._thread = threading.Thread(target=loop, daemon=True,
                                        name="oap-resources")
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
