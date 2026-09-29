"""The schema, statements and row mapping of the SDK's SQL stores
(stores/sql.ts), text for text, so a Node, a Ruby and a Python process can
share one database. Statements are written with ``?`` placeholders; a
Postgres store (a later release) numbers them."""

from __future__ import annotations

import re
from collections.abc import Sequence
from typing import Any

from .. import _js
from ..types import JobDefinition, JobState, Run, StoredJob

DEFAULT_PREFIX = "cronwatch_"

# Postgres truncates identifiers past 63 bytes; the longest name built is the prefix plus "runs_job_started".
MAX_PREFIX = 63 - len("runs_job_started")


def table_prefix(prefix: str = DEFAULT_PREFIX) -> str:
    """Table names are built from the prefix, so it must be a plain lowercase
    identifier. Uppercase is refused rather than folded: Postgres lowercases
    unquoted names, so "Monitoring_" would quietly become "monitoring_"."""
    if not isinstance(prefix, str) or not re.fullmatch(r"[a-z_][a-z0-9_]*", prefix) or len(prefix) > MAX_PREFIX:
        shown = _js.quote(prefix) if isinstance(prefix, str) else repr(prefix)
        raise ValueError(
            f"cronwatch: invalid table prefix {shown}. Use lowercase letters, digits and underscores, "
            f"not starting with a digit, at most {MAX_PREFIX} characters."
        )
    return prefix


def schema(dialect: str, p: str) -> str:
    pg = dialect == "postgres"
    integer = "BIGINT" if pg else "INTEGER"
    json = "JSONB" if pg else "TEXT"
    seq = "\n      seq BIGSERIAL," if pg else ""
    return f"""
    CREATE TABLE IF NOT EXISTS {p}jobs (
      name TEXT PRIMARY KEY,
      definition {json} NOT NULL,
      created_at {integer} NOT NULL,
      updated_at {integer} NOT NULL
    );
    CREATE TABLE IF NOT EXISTS {p}runs ({seq}
      id TEXT PRIMARY KEY,
      job TEXT NOT NULL,
      status TEXT NOT NULL,
      started_at {integer} NOT NULL,
      finished_at {integer},
      duration_ms {integer},
      error TEXT,
      output TEXT,
      metrics {json} NOT NULL DEFAULT '{{}}',
      trigger TEXT NOT NULL DEFAULT 'run'
    );
    CREATE INDEX IF NOT EXISTS {p}runs_job_started ON {p}runs (job, started_at DESC);
    CREATE INDEX IF NOT EXISTS {p}runs_running ON {p}runs (status) WHERE status = 'running';
    CREATE TABLE IF NOT EXISTS {p}state (
      job TEXT PRIMARY KEY,
      state {json} NOT NULL
    );
  """


def _number(text: str) -> str:
    n = 0

    def next_placeholder(_m: re.Match[str]) -> str:
        nonlocal n
        n += 1
        return f"${n}"

    return re.sub(r"\?", next_placeholder, text)


def statements(dialect: str, p: str) -> dict[str, str]:
    pg = dialect == "postgres"
    # Insertion order, to break ties between runs that started in the same millisecond.
    seq = "seq" if pg else "rowid"
    # Byte order on both, so names sort the same whatever the database's collation.
    by_name = 'name COLLATE "C"' if pg else "name"

    def version(column: str) -> str:
        """The version inside a state's JSON, as state_version() reads it: a
        whole number from 0 to 2^53 - 1, else 0 (none, or a foreign row's 1.5
        or "x", which must neither fail the statement nor refuse every write
        for good). Each CASE tests the JSON type before any cast."""
        if pg:
            v = f"({column}->>'version')::numeric"
            return (
                f"CASE WHEN jsonb_typeof({column}->'version') <> 'number' THEN 0 "
                f"WHEN {v} % 1 = 0 AND {v} BETWEEN 0 AND 9007199254740991 THEN {v}::bigint ELSE 0 END"
            )
        v = f"json_extract({column}, '$.version')"
        return (
            f"CASE WHEN json_type({column}, '$.version') NOT IN ('integer', 'real') THEN 0 "
            f"WHEN {v} = CAST({v} AS INTEGER) AND {v} BETWEEN 0 AND 9007199254740991 THEN CAST({v} AS INTEGER) ELSE 0 END"
        )

    sql = {
        "upsert_job": f"""INSERT INTO {p}jobs (name, definition, created_at, updated_at) VALUES (?, ?, ?, ?)
      ON CONFLICT (name) DO UPDATE SET definition = excluded.definition, updated_at = excluded.updated_at""",
        "get_job": f"SELECT * FROM {p}jobs WHERE name = ?",
        "list_jobs": f"SELECT * FROM {p}jobs ORDER BY {by_name}",
        "delete_runs": f"DELETE FROM {p}runs WHERE job = ?",
        "delete_state": f"DELETE FROM {p}state WHERE job = ?",
        "delete_job": f"DELETE FROM {p}jobs WHERE name = ?",
        "insert_run": f"""INSERT INTO {p}runs (id, job, status, started_at, finished_at, duration_ms, error, output, metrics, trigger)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
        "update_run": f"UPDATE {p}runs SET status = ?, finished_at = ?, duration_ms = ?, error = ?, output = ?, metrics = ? WHERE id = ?",
        "get_run": f"SELECT * FROM {p}runs WHERE id = ?",
        "list_runs": f"SELECT * FROM {p}runs WHERE job = ? ORDER BY started_at DESC, {seq} DESC LIMIT ?",
        "running_runs": f"SELECT * FROM {p}runs WHERE status = 'running' ORDER BY started_at, {seq}",
        "get_state": f"SELECT state FROM {p}state WHERE job = ?",
        "set_state": f"INSERT INTO {p}state (job, state) VALUES (?, ?) ON CONFLICT (job) DO UPDATE SET state = excluded.state",
        # compare_and_set_state. Expecting version 0 also matches a missing
        # row, so that case inserts; any other version must find its row.
        "cas_insert": f"""INSERT INTO {p}state (job, state) VALUES (?, ?)
      ON CONFLICT (job) DO UPDATE SET state = excluded.state WHERE {version(f"{p}state.state")} = 0""",
        "cas_update": f"UPDATE {p}state SET state = ? WHERE job = ? AND {version('state')} = ?",
        # Each job's newest run is kept whatever its age: without it, a job
        # that runs less often than the retention looks like it never ran.
        "prune": f"""DELETE FROM {p}runs WHERE status <> 'running' AND started_at < ?
      AND started_at < (SELECT MAX(r.started_at) FROM {p}runs r WHERE r.job = {p}runs.job)""",
    }
    if pg:
        sql = {key: _number(text) for key, text in sql.items()}
    return sql


def update_run_if_sql(dialect: str, p: str, count: int) -> str:
    """update_run_if: the update above, only while the stored status is one of
    `count` statuses. Built per count, since the list is bound value by value."""
    marks = ", ".join("?" for _ in range(count))
    text = (
        f"UPDATE {p}runs SET status = ?, finished_at = ?, duration_ms = ?, error = ?, output = ?, metrics = ? "
        f"WHERE id = ? AND status IN ({marks})"
    )
    return _number(text) if dialect == "postgres" else text


def _text(value: str | None) -> str | None:
    """A TEXT value as a JavaScript driver writes it: a lone surrogate as U+FFFD."""
    return None if value is None else _js.well_formed(value)


# Parameters in statement order, so every driver binds the same values.
def upsert_job_params(definition: JobDefinition, now: int) -> list[Any]:
    return [definition.name, _js.dumps(definition.to_dict()), now, now]


def insert_run_params(run: Run) -> list[Any]:
    return [
        run.id,
        run.job,
        str(run.status),
        run.started_at,
        run.finished_at,
        run.duration_ms,
        _text(run.error),
        _text(run.output),
        _js.dumps(run.metrics or {}),
        run.trigger,
    ]


def update_run_params(run: Run) -> list[Any]:
    return [str(run.status), run.finished_at, run.duration_ms, _text(run.error), _text(run.output), _js.dumps(run.metrics or {}), run.id]


def update_run_if_params(run: Run, from_statuses: Sequence[object]) -> list[Any]:
    return [*update_run_params(run), *(str(s) for s in from_statuses)]


def state_params(state: JobState) -> list[Any]:
    return [state.job, _js.dumps(state.to_dict())]


def cas_update_params(state: JobState, expected_version: int) -> list[Any]:
    return [_js.dumps(state.to_dict()), state.job, expected_version]


def _json(value: Any) -> Any:
    """SQLite hands back JSON as TEXT and Postgres as parsed JSONB."""
    return _js.loads(value) if isinstance(value, (str, bytes)) else value


def _num(value: Any) -> Any:
    """Postgres returns BIGINT as a number already; text is read as a number."""
    if value is None or isinstance(value, (int, float)):
        return value
    text = str(value)
    return int(text) if re.fullmatch(r"-?[0-9]+", text) else float(text)


def row_to_job(row: Any) -> StoredJob:
    return StoredJob(
        name=row["name"],
        definition=JobDefinition.from_dict(_json(row["definition"])),
        created_at=_num(row["created_at"]),
        updated_at=_num(row["updated_at"]),
    )


def row_to_run(row: Any) -> Run:
    metrics = row["metrics"]
    return Run(
        id=row["id"],
        job=row["job"],
        status=row["status"],
        started_at=_num(row["started_at"]),
        finished_at=_num(row["finished_at"]),
        duration_ms=_num(row["duration_ms"]),
        error=row["error"],
        output=row["output"],
        metrics={} if metrics is None else dict(_json(metrics)),
        trigger=row["trigger"],
    )


def row_to_state(row: Any) -> JobState:
    return JobState.from_dict(_json(row["state"]))
