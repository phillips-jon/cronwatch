"""Keeps everything in one SQLite file through the standard library's sqlite3
(stores/sqlite.ts): the same tables, statements and JSON as the SDK's store,
so a Node process and a Python process can share the file. WAL mode, so the
app's reads never block on a run being written. The right choice for a
single server."""

from __future__ import annotations

import contextlib
import os
import sqlite3
import threading
import time
from collections.abc import Callable, Sequence
from typing import Any, TypeVar

from .._deprecated import names as _deprecated_names
from ..types import JobDefinition, JobState, Run, RunStatus, StoredJob
from . import _sql

__all__ = ["SqliteStore"]

_T = TypeVar("T")

#: How long opening SQLite keeps retrying a busy database before it gives up.
_BUSY_RETRY_MS = 2_000


def _busy(error: BaseException) -> bool:
    name = getattr(error, "sqlite_errorname", "") or ""
    if name.startswith(("SQLITE_BUSY", "SQLITE_LOCKED")):
        return True
    return isinstance(error, sqlite3.OperationalError) and ("database is locked" in str(error) or "database table is locked" in str(error))


def _retry_busy(fn: Callable[[], _T], budget_ms: int = _BUSY_RETRY_MS, sleep: Callable[[float], None] = time.sleep) -> _T:
    """Runs `fn`, retrying while SQLite answers SQLITE_BUSY (or SQLITE_LOCKED),
    with a short growing pause, for up to `budget_ms` in all."""
    waited = 0
    attempt = 0
    while True:
        try:
            return fn()
        except sqlite3.Error as error:
            if not _busy(error) or waited >= budget_ms:
                raise
            pause = min(10 * 2**attempt, 200, budget_ms - waited)
            sleep(pause / 1000)
            waited += pause
            attempt += 1


class SqliteStore:
    """``SqliteStore("./data/cronwatch.db")``. The directory is created if
    missing, and ":memory:" works too. Pass ``connection=`` to bring your own
    open sqlite3 connection (in autocommit mode, ``isolation_level=None``).
    ``prefix`` names the tables: lowercase letters, digits and underscores,
    default "cronwatch_"."""

    def __init__(self, path: str | os.PathLike[str] = "./data/cronwatch.db", *, connection: sqlite3.Connection | None = None, prefix: str = _sql.DEFAULT_PREFIX) -> None:
        self.prefix = _sql.table_prefix(prefix)
        self.path = os.fspath(path)
        self._sql = _sql.statements("sqlite", self.prefix)
        self._own = connection is None
        self._db: sqlite3.Connection | None = connection
        self._mutex = threading.RLock()
        self._pid = os.getpid()

    @property
    def _lock(self) -> threading.RLock:
        """The store's lock. A forked child (gunicorn, Celery's prefork pool)
        gets a fresh one, and opens a connection of its own: SQLite's must not
        be used across a fork, so the parent's is left to it, not closed."""
        if self._pid != os.getpid():
            self._pid = os.getpid()
            self._mutex = threading.RLock()
            if self._own:
                self._db = None
        return self._mutex

    def _open(self) -> sqlite3.Connection:
        if self._db is not None:
            return self._db
        file = self.path
        on_disk = file not in (":memory:", "")
        if on_disk:
            directory = os.path.dirname(file)
            if directory:
                os.makedirs(directory, exist_ok=True)
            # Create the file private before SQLite opens it. SQLite gives the
            # -wal and -shm files the main file's mode, so the whole set stays
            # 0600; the chmods cover files left by an earlier open.
            with contextlib.suppress(OSError):
                os.close(os.open(file, os.O_CREAT | os.O_APPEND | os.O_WRONLY, 0o600))
                for f in (file, f"{file}-wal", f"{file}-shm"):
                    with contextlib.suppress(OSError):
                        os.chmod(f, 0o600)
        # No busy handler until WAL is on: switching journal mode can answer
        # SQLITE_BUSY at once while another process is doing the same on a new
        # file, so that is retried here. The connection is kept only once every
        # pragma has gone through; a failed open is tried afresh next time.
        opened = sqlite3.connect(file, timeout=0, isolation_level=None, check_same_thread=False)
        try:
            _retry_busy(lambda: opened.execute("PRAGMA journal_mode = WAL").fetchall())
            opened.execute("PRAGMA busy_timeout = 5000")
            opened.execute("PRAGMA synchronous = NORMAL")
        except BaseException:
            opened.close()
            raise
        self._db = opened
        return opened

    def _run(self, text: str, params: Sequence[Any] = ()) -> sqlite3.Cursor:
        """A statement on a cursor of its own that reads rows by column name,
        leaving a connection that was handed in as it was."""
        with self._lock:
            cursor = self._open().cursor()
            cursor.row_factory = sqlite3.Row
            return cursor.execute(text, list(params))

    def _all(self, text: str, params: Sequence[Any] = ()) -> list[sqlite3.Row]:
        with self._lock:
            return self._run(text, params).fetchall()

    def _one(self, text: str, params: Sequence[Any] = ()) -> sqlite3.Row | None:
        with self._lock:
            row: sqlite3.Row | None = self._run(text, params).fetchone()
            return row

    def init(self) -> None:
        with self._lock:
            self._open().executescript(_sql.schema("sqlite", self.prefix))

    def upsert_job(self, definition: JobDefinition, now: int) -> None:
        self._run(self._sql["upsert_job"], _sql.upsert_job_params(JobDefinition.from_dict(definition), now))

    def get_job(self, name: str) -> StoredJob | None:
        row = self._one(self._sql["get_job"], [name])
        return _sql.row_to_job(row) if row else None

    def list_jobs(self) -> list[StoredJob]:
        return [_sql.row_to_job(r) for r in self._all(self._sql["list_jobs"])]

    def delete_job(self, name: str) -> None:
        with self._lock:
            db = self._open()
            db.execute("BEGIN")
            try:
                db.execute(self._sql["delete_runs"], [name])
                db.execute(self._sql["delete_state"], [name])
                db.execute(self._sql["delete_job"], [name])
                db.execute("COMMIT")
            except BaseException:
                db.execute("ROLLBACK")
                raise

    def insert_run(self, run: Run) -> None:
        self._run(self._sql["insert_run"], _sql.insert_run_params(run))

    def update_run(self, run: Run) -> None:
        self._run(self._sql["update_run"], _sql.update_run_params(run))

    def update_run_if(self, run: Run, from_statuses: Sequence[RunStatus | str]) -> bool:
        if not from_statuses:
            return False
        text = _sql.update_run_if_sql("sqlite", self.prefix, len(from_statuses))
        return self._run(text, _sql.update_run_if_params(run, from_statuses)).rowcount > 0

    def get_run(self, run_id: str) -> Run | None:
        row = self._one(self._sql["get_run"], [run_id])
        return _sql.row_to_run(row) if row else None

    def list_runs(self, job: str, limit: int) -> list[Run]:
        return [_sql.row_to_run(r) for r in self._all(self._sql["list_runs"], [job, int(limit)])]

    def last_run(self, job: str) -> Run | None:
        row = self._one(self._sql["list_runs"], [job, 1])
        return _sql.row_to_run(row) if row else None

    def running_runs(self) -> list[Run]:
        return [_sql.row_to_run(r) for r in self._all(self._sql["running_runs"])]

    def get_state(self, job: str) -> JobState | None:
        row = self._one(self._sql["get_state"], [job])
        return _sql.row_to_state(row) if row else None

    def set_state(self, state: JobState) -> None:
        self._run(self._sql["set_state"], _sql.state_params(state))

    def compare_and_set_state(self, state: JobState, expected_version: int) -> bool:
        if expected_version == 0:
            cursor = self._run(self._sql["cas_insert"], _sql.state_params(state))
        else:
            cursor = self._run(self._sql["cas_update"], _sql.cas_update_params(state, expected_version))
        return cursor.rowcount > 0

    def prune(self, before: int) -> int:
        return self._run(self._sql["prune"], [before]).rowcount

    def close(self) -> None:
        with self._lock:
            if self._db is not None and self._own:
                self._db.close()
                self._db = None


#: Internal names, still answering under their old public names (each
#: warning, until 1.0 removes them).
__getattr__ = _deprecated_names(__name__, globals(), {"BUSY_RETRY_MS": "_BUSY_RETRY_MS", "retry_busy": "_retry_busy", "T": "_T"})
