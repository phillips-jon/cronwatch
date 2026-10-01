"""Keeps everything in Postgres through psycopg 3 (stores/postgres.ts): the
same tables, statements (``$n`` placeholders, sent as written through
psycopg's RawCursor) and JSON as the SDK's store, so a Node, a Ruby and a
Python process can share the database. For apps on Heroku, Fly, Render, Neon,
Supabase and the like, where there is no disk to keep a SQLite file on.
Times are stored as BIGINT epoch milliseconds.

    pip install "cronwatch-sdk[postgres]"

    from cronwatch.stores.postgres import PostgresStore
    cw = cronwatch.Cronwatch(store=PostgresStore(os.environ["DATABASE_URL"]))

The store writes through a connection of its own, in autocommit mode, so its
writes never join a transaction the app has open: a run recorded inside one
survives a rollback, and a check waiting on a job's row cannot deadlock with
a job holding that row inside the app's transaction.
"""

from __future__ import annotations

import os
import threading
from collections.abc import Callable, Iterator, Sequence
from contextlib import contextmanager
from typing import Any, TypeVar

try:
    import psycopg
    from psycopg.rows import dict_row
except ImportError as error:  # pragma: no cover, the message is tested in a subprocess
    raise ImportError(f'cronwatch.stores.postgres needs psycopg 3.2 or newer: pip install "cronwatch-sdk[postgres]" ({error})') from error

from .._deprecated import names as _deprecated_names
from ..types import JobDefinition, JobState, Run, RunStatus, StoredJob
from . import _sql

__all__ = ["PostgresStore"]

_T = TypeVar("T")


class PostgresStore:
    """``PostgresStore("postgres://...")``, or ``PostgresStore()`` to read
    ``DATABASE_URL``. Pass ``pool=`` to bring your own psycopg_pool
    ``ConnectionPool`` (anything whose ``connection()`` is a context manager
    giving a psycopg connection) instead; it is not closed by ``close()``.
    ``prefix`` names the tables: lowercase letters, digits and underscores,
    default "cronwatch_"."""

    def __init__(self, conninfo: str | None = None, *, pool: Any = None, prefix: str = _sql.DEFAULT_PREFIX) -> None:
        self.prefix = _sql.table_prefix(prefix)
        self._sql = _sql.statements("postgres", self.prefix)
        self._pool = pool
        self._conninfo = conninfo if conninfo is not None else os.environ.get("DATABASE_URL", "")
        self._connection: psycopg.Connection[Any] | None = None
        self._lock = threading.RLock()
        self._pid = os.getpid()

    # ---------------------------------------------------------------- connections

    def _open(self) -> psycopg.Connection[Any]:
        """The store's own connection, opened on first use and again after it broke."""
        if self._connection is not None and not self._connection.closed and not self._connection.broken:
            return self._connection
        if self._connection is not None:
            try:
                self._connection.close()
            except Exception:  # noqa: BLE001, a broken connection may not close cleanly
                pass
        self._connection = psycopg.connect(self._conninfo, autocommit=True, row_factory=dict_row, cursor_factory=psycopg.RawCursor)
        return self._connection

    @contextmanager
    def _connect(self) -> Iterator[psycopg.Connection[Any]]:
        if self._pool is not None:
            with self._pool.connection() as connection:
                yield connection
            return
        if self._pid != os.getpid():
            # A forked child (gunicorn, Celery's prefork pool) must not share
            # the parent's socket; it is left for the parent, not closed.
            self._pid = os.getpid()
            self._lock = threading.RLock()
            self._connection = None
        with self._lock:
            yield self._open()

    def _execute(self, text: str, params: Sequence[Any] = ()) -> tuple[list[dict[str, Any]], int]:
        """Runs one statement; returns its rows (if it has any) and its row count."""
        with self._connect() as connection, psycopg.RawCursor(connection, row_factory=dict_row) as cursor:
            cursor.execute(text, list(params))  # type: ignore[arg-type]
            rows = cursor.fetchall() if cursor.description is not None else []
            return rows, cursor.rowcount

    def _all(self, text: str, params: Sequence[Any] = ()) -> list[dict[str, Any]]:
        return self._execute(text, params)[0]

    def _one(self, text: str, params: Sequence[Any] = ()) -> dict[str, Any] | None:
        rows = self._all(text, params)
        return rows[0] if rows else None

    def _count(self, text: str, params: Sequence[Any] = ()) -> int:
        return max(self._execute(text, params)[1], 0)

    def _transaction(self, work: Callable[[psycopg.RawCursor[Any]], None]) -> None:
        with self._connect() as connection, connection.transaction(), psycopg.RawCursor(connection) as cursor:
            work(cursor)

    # ---------------------------------------------------------------- the store

    def init(self) -> None:
        # Many instances starting at once would race CREATE TABLE IF NOT EXISTS, which Postgres can
        # reject with a unique violation on pg_type. A lock per prefix makes them take turns.
        def create(cursor: psycopg.RawCursor[Any]) -> None:
            cursor.execute("SELECT pg_advisory_xact_lock(hashtext($1))", [f"cronwatch:{self.prefix}"])
            cursor.execute(_sql.schema("postgres", self.prefix))

        self._transaction(create)

    def upsert_job(self, definition: JobDefinition, now: int) -> None:
        self._execute(self._sql["upsert_job"], _sql.upsert_job_params(JobDefinition.from_dict(definition), now))

    def get_job(self, name: str) -> StoredJob | None:
        row = self._one(self._sql["get_job"], [name])
        return _sql.row_to_job(row) if row else None

    def list_jobs(self) -> list[StoredJob]:
        return [_sql.row_to_job(r) for r in self._all(self._sql["list_jobs"])]

    def delete_job(self, name: str) -> None:
        def delete(cursor: psycopg.RawCursor[Any]) -> None:
            cursor.execute(self._sql["delete_runs"], [name])
            cursor.execute(self._sql["delete_state"], [name])
            cursor.execute(self._sql["delete_job"], [name])

        self._transaction(delete)

    def insert_run(self, run: Run) -> None:
        self._execute(self._sql["insert_run"], _sql.insert_run_params(run))

    def update_run(self, run: Run) -> None:
        self._execute(self._sql["update_run"], _sql.update_run_params(run))

    def update_run_if(self, run: Run, from_statuses: Sequence[RunStatus | str]) -> bool:
        if not from_statuses:
            return False
        text = _sql.update_run_if_sql("postgres", self.prefix, len(from_statuses))
        return self._count(text, _sql.update_run_if_params(run, from_statuses)) > 0

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
        self._execute(self._sql["set_state"], _sql.state_params(state))

    def compare_and_set_state(self, state: JobState, expected_version: int) -> bool:
        if expected_version == 0:
            return self._count(self._sql["cas_insert"], _sql.state_params(state)) > 0
        return self._count(self._sql["cas_update"], _sql.cas_update_params(state, expected_version)) > 0

    def prune(self, before: int) -> int:
        return self._count(self._sql["prune"], [before])

    def close(self) -> None:
        with self._lock:
            if self._connection is not None:
                self._connection.close()
                self._connection = None


#: Names 1.0 made internal, still answering under their old names (each
#: warning, until 2.0).
__getattr__ = _deprecated_names(__name__, globals(), {"T": "_T"})
