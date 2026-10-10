"""SQLite durable store, mirroring StateStore.swift.

Schema v1 holds content-free job/session/profile metadata only. WAL + FULL
sync + foreign keys + bounded busy timeout. Newer on-disk schema fails
rather than downgrading. Storage exhaustion refuses new records; it never
silently deletes history. All access is serialized under one lock.
"""
from __future__ import annotations

import enum
import os
import sqlite3
import threading
import time
from dataclasses import dataclass

from .errors import ErrorCode, PlatformError
from .limits import PlatformLimits

SCHEMA_VERSION = 1


class JobKind(enum.Enum):
    LLM = "llm"
    ML = "ml"
    # Governed administration work (model pulls): its own lane, never
    # counted against inference slots or the inference-blocked latch.
    ADMIN = "admin"


class JobState(enum.Enum):
    QUEUED = "queued"
    ACTIVE = "active"
    CANCEL_REQUESTED = "cancel_requested"
    COMPLETED = "completed"
    FAILED = "failed"
    CANCELLED = "cancelled"
    CANCELLATION_UNCONFIRMED = "cancellation_unconfirmed"
    # set on restart for unfinished rows; never replayed
    INTERRUPTED = "interrupted"

    @property
    def is_terminal(self) -> bool:
        return self in (JobState.COMPLETED, JobState.FAILED, JobState.CANCELLED,
                        JobState.CANCELLATION_UNCONFIRMED, JobState.INTERRUPTED)


@dataclass
class JobRecord:
    id: str
    kind: JobKind
    consumer_id: str
    parent_id: str | None
    state: JobState
    created_at: float
    updated_at: float
    provider_finished: bool = False


class StateStore:
    def __init__(self, path: str,
                 database_bytes_cap: int = PlatformLimits.DATABASE_BYTES):
        self._path = path
        self._cap = database_bytes_cap
        self._db: sqlite3.Connection | None = None
        self._lock = threading.Lock()

    def open(self) -> None:
        try:
            # check_same_thread=False is safe: every public method already
            # serializes all sqlite calls under self._lock.
            db = sqlite3.connect(self._path, timeout=1.0,
                                 isolation_level=None,
                                 check_same_thread=False)
            db.execute("PRAGMA journal_mode=WAL")
            db.execute("PRAGMA synchronous=FULL")
            db.execute("PRAGMA foreign_keys=ON")
        except sqlite3.Error as e:
            raise PlatformError(ErrorCode.STORAGE_FAILURE, f"sqlite open: {e}")
        self._db = db
        try:
            self._migrate()
            self._mark_interrupted()
        except BaseException:
            db.close()
            self._db = None
            raise
        for suffix in ("-wal", "-shm"):
            sidecar = self._path + suffix
            if os.path.exists(sidecar):
                try:
                    os.chmod(sidecar, 0o600)
                except OSError:
                    pass

    def close(self) -> None:
        with self._lock:
            if self._db:
                self._db.close()
                self._db = None

    def _conn(self) -> sqlite3.Connection:
        if self._db is None:
            raise PlatformError(ErrorCode.STORAGE_FAILURE, "db closed")
        return self._db

    def _migrate(self) -> None:
        with self._lock:
            db = self._conn()
            version = db.execute("PRAGMA user_version").fetchone()[0]
            if version > SCHEMA_VERSION:
                raise PlatformError(ErrorCode.VERSION_UNSUPPORTED,
                                    f"db schema {version}")
            if version < SCHEMA_VERSION:
                db.execute("BEGIN IMMEDIATE")
                try:
                    db.execute("""
                        CREATE TABLE IF NOT EXISTS jobs(
                            id TEXT PRIMARY KEY,
                            kind TEXT NOT NULL,
                            consumer_id TEXT NOT NULL,
                            parent_id TEXT,
                            state TEXT NOT NULL,
                            created_at REAL NOT NULL,
                            updated_at REAL NOT NULL,
                            provider_finished INTEGER NOT NULL DEFAULT 0
                        )""")
                    db.execute("""
                        CREATE TABLE IF NOT EXISTS sessions(
                            id TEXT PRIMARY KEY,
                            agent_id TEXT NOT NULL,
                            agent_version INTEGER NOT NULL,
                            harness_id TEXT NOT NULL,
                            harness_version INTEGER NOT NULL,
                            consumer_id TEXT NOT NULL,
                            state TEXT NOT NULL,
                            created_at REAL NOT NULL,
                            updated_at REAL NOT NULL
                        )""")
                    db.execute("""
                        CREATE TABLE IF NOT EXISTS counters(
                            name TEXT PRIMARY KEY,
                            value INTEGER NOT NULL
                        )""")
                    db.execute(f"PRAGMA user_version={SCHEMA_VERSION}")
                    db.execute("COMMIT")
                except sqlite3.Error as e:
                    db.execute("ROLLBACK")
                    raise PlatformError(ErrorCode.STORAGE_FAILURE,
                                        f"migrate: {e}")

    def _mark_interrupted(self) -> None:
        """Restart semantics: unfinished rows become interrupted, never
        replayed."""
        with self._lock:
            db = self._conn()
            now = time.time()
            db.execute(
                "UPDATE jobs SET state='interrupted', updated_at=? "
                "WHERE state IN ('queued','active','cancel_requested')",
                (now,))
            db.execute(
                "UPDATE sessions SET state='closed', updated_at=? "
                "WHERE state IN ('open','active')", (now,))

    def _check_capacity(self) -> None:
        db = self._conn()
        (count,) = db.execute("SELECT COUNT(*) FROM jobs").fetchone()
        if count >= PlatformLimits.DURABLE_RECORDS:
            raise PlatformError(ErrorCode.STORAGE_EXHAUSTED, "record cap")
        try:
            if os.path.getsize(self._path) > self._cap:
                raise PlatformError(ErrorCode.STORAGE_EXHAUSTED,
                                    "db bytes cap")
        except OSError:
            pass

    def max_job_sequence(self) -> int:
        with self._lock:
            rows = self._conn().execute("SELECT id FROM jobs").fetchall()
            best = 0
            for (job_id,) in rows:
                if job_id.startswith("job-"):
                    try:
                        best = max(best, int(job_id[4:]))
                    except ValueError:
                        pass
            return best

    def insert_job(self, job: JobRecord) -> None:
        with self._lock:
            self._check_capacity()
            try:
                self._conn().execute(
                    "INSERT INTO jobs(id,kind,consumer_id,parent_id,state,"
                    "created_at,updated_at,provider_finished) "
                    "VALUES(?,?,?,?,?,?,?,?)",
                    (job.id, job.kind.value, job.consumer_id, job.parent_id,
                     job.state.value, job.created_at, job.updated_at,
                     1 if job.provider_finished else 0))
            except sqlite3.Error as e:
                raise PlatformError(ErrorCode.STORAGE_FAILURE, f"insert: {e}")

    def update_job(self, job: JobRecord) -> None:
        with self._lock:
            self._conn().execute(
                "UPDATE jobs SET state=?,updated_at=?,provider_finished=? "
                "WHERE id=?",
                (job.state.value, job.updated_at,
                 1 if job.provider_finished else 0, job.id))

    @staticmethod
    def _row_to_job(row) -> JobRecord:
        return JobRecord(
            id=row[0],
            kind=JobKind(row[1]) if row[1] in ("llm", "ml", "admin")
            else JobKind.LLM,
            consumer_id=row[2], parent_id=row[3],
            state=JobState(row[4]) if row[4] in {s.value for s in JobState}
            else JobState.FAILED,
            created_at=row[5], updated_at=row[6],
            provider_finished=bool(row[7]))

    def job(self, job_id: str) -> JobRecord | None:
        with self._lock:
            row = self._conn().execute(
                "SELECT id,kind,consumer_id,parent_id,state,created_at,"
                "updated_at,provider_finished FROM jobs WHERE id=?",
                (job_id,)).fetchone()
            return self._row_to_job(row) if row else None

    def jobs(self, limit: int = 100) -> list[JobRecord]:
        with self._lock:
            rows = self._conn().execute(
                "SELECT id,kind,consumer_id,parent_id,state,created_at,"
                "updated_at,provider_finished FROM jobs "
                "ORDER BY created_at DESC LIMIT ?",
                (max(0, min(limit, 1000)),)).fetchall()
            return [self._row_to_job(r) for r in rows]

    def insert_session(self, session_id: str, agent, consumer_id: str,
                       now: float) -> None:
        with self._lock:
            self._conn().execute(
                "INSERT INTO sessions(id,agent_id,agent_version,harness_id,"
                "harness_version,consumer_id,state,created_at,updated_at) "
                "VALUES(?,?,?,?,?,?,?,?,?)",
                (session_id, agent.id, agent.version, agent.harness_id,
                 agent.harness_version, consumer_id, "open", now, now))

    def close_session(self, session_id: str, now: float) -> None:
        with self._lock:
            self._conn().execute(
                "UPDATE sessions SET state='closed',updated_at=? WHERE id=?",
                (now, session_id))

    def increment_counter(self, name: str) -> None:
        with self._lock:
            self._conn().execute(
                "INSERT INTO counters(name,value) VALUES(?,1) "
                "ON CONFLICT(name) DO UPDATE SET value=value+1", (name,))

    def counter(self, name: str) -> int:
        with self._lock:
            row = self._conn().execute(
                "SELECT value FROM counters WHERE name=?", (name,)).fetchone()
            return int(row[0]) if row else 0
