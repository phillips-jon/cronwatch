"""The schema, statements, and row mapping of the SDK's SQL stores
(stores/sql.ts), text for text, so a Node, a Ruby, and a Python process can
share one database. Statements are written with ``?`` placeholders; a
Postgres store (a later release) numbers them."""

from __future__ import annotations

import json
import math
import re
from collections.abc import Mapping, Sequence
from typing import Any

from .. import _js
from .._output import strip_json_nul, strip_nul
from .._serialize import unreadable_definition
from ..types import JobDefinition, JobState, Run, StoredJob

__all__ = [
    "DEFAULT_PREFIX",
    "MAX_PREFIX",
    "cas_update_params",
    "insert_run_params",
    "row_to_job",
    "row_to_run",
    "row_to_state",
    "schema",
    "state_params",
    "statements",
    "table_prefix",
    "update_run_if_params",
    "update_run_if_sql",
    "update_run_params",
    "upsert_job_params",
]

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
            f"cronwatch: invalid table prefix {shown}. Use lowercase letters, digits, and underscores, "
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
        for good; on SQLite, also text that is not JSON). Each CASE tests the
        JSON type before any cast."""
        if pg:
            v = f"({column}->>'version')::numeric"
            return (
                f"CASE WHEN jsonb_typeof({column}->'version') <> 'number' THEN 0 "
                f"WHEN {v} % 1 = 0 AND {v} BETWEEN 0 AND 9007199254740991 THEN {v}::bigint ELSE 0 END"
            )
        v = f"json_extract({column}, '$.version')"
        # Text that is not JSON at all (SQLite holds any) counts as 0 too, before json_type could fail on it.
        return (
            f"CASE WHEN NOT json_valid({column}) THEN 0 WHEN json_type({column}, '$.version') NOT IN ('integer', 'real') THEN 0 "
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


# Postgres refuses U+0000 in TEXT and JSONB, and a refused write loses the
# whole row, so every dialect writes text without it: a run's trigger,
# output, error, and metric names, and every key and string of a definition
# and a state. Identifiers (a job's name, a run's id) are written as given;
# the client refuses one with a NUL before it gets here.
def _text(value: str | None) -> str | None:
    """A TEXT value as a JavaScript driver writes it: a lone surrogate as U+FFFD, and no NUL."""
    return None if value is None else strip_nul(_js.well_formed(value))


def _json_text(value: Any) -> str:
    return strip_json_nul(_js.dumps(value))


# Parameters in statement order, so every driver binds the same values.
def upsert_job_params(definition: JobDefinition, now: int) -> list[Any]:
    return [definition.name, _json_text(definition.to_dict()), now, now]


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
        _json_text(run.metrics or {}),
        strip_nul(run.trigger),
    ]


def update_run_params(run: Run) -> list[Any]:
    return [str(run.status), run.finished_at, run.duration_ms, _text(run.error), _text(run.output), _json_text(run.metrics or {}), run.id]


def update_run_if_params(run: Run, from_statuses: Sequence[object]) -> list[Any]:
    return [*update_run_params(run), *(str(s) for s in from_statuses)]


def state_params(state: JobState) -> list[Any]:
    return [state.job, _json_text(state.to_dict())]


def cas_update_params(state: JobState, expected_version: int) -> list[Any]:
    return [_json_text(state.to_dict()), state.job, expected_version]


# Rows are read leniently: a foreign, hand-edited, or damaged row (SQLite
# keeps whatever type it is given, in any column) must affect only its own
# job, never every read. JSON text that does not parse reads as None, which
# the client takes as no state, or as an unreadable definition it reports.


def _refuse_constant(name: str) -> Any:
    raise ValueError(f"{name} is not JSON")


def _json(value: Any) -> Any:
    """SQLite hands back JSON as TEXT and Postgres as parsed JSONB. Text that
    is not JSON (JSON.parse would throw, so NaN and Infinity too) reads as None."""
    if not isinstance(value, (str, bytes)):
        return value
    try:
        return json.loads(value, parse_constant=_refuse_constant)
    except ValueError:  # JSONDecodeError and UnicodeDecodeError are ValueErrors
        return None


# What Number() reads from text, once trimmed: a decimal, or a 0x, 0o, or 0b integer.
_DECIMAL = re.compile(r"[+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?")
_RADIX = re.compile(r"0([xX][0-9a-fA-F]+|[oO][0-7]+|[bB][01]+)")


def _read_number(value: Any) -> Any:
    """A time, or a count of milliseconds, as a column holds it (text from
    Postgres's BIGINT), read the way JavaScript's Number() reads it: None when
    it is not a finite number."""
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return value if _js.is_finite(value) else None
    if not isinstance(value, str):
        return None
    text = _js.trim(value)
    if not text:
        return None
    if re.fullmatch(r"-?[0-9]+", text):
        n: Any = int(text)
        return n if _js.is_finite(n) else None
    radix = _RADIX.fullmatch(text)
    if radix:
        n = int(text, 0)
        return n if _js.is_finite(n) else None
    if not _DECIMAL.fullmatch(text):
        return None
    f = float(text)
    if not math.isfinite(f):
        return None
    return int(f) if f.is_integer() and abs(f) <= _js.MAX_SAFE_INTEGER else f


def _time(value: Any) -> Any:
    """A time that must be there: one that is not a finite number reads as 0."""
    n = _read_number(value)
    return 0 if n is None else n


def row_to_job(row: Any) -> StoredJob:
    """A job's row. A definition that is not a JSON object (or whose text does
    not parse) is held as an unreadable one, which the client reports (see
    read_stored_job); a time that is not a finite number reads as 0."""
    definition = _json(row["definition"])
    return StoredJob(
        name=row["name"],
        definition=JobDefinition(definition) if isinstance(definition, Mapping) else unreadable_definition(row["name"]),
        created_at=_time(row["created_at"]),
        updated_at=_time(row["updated_at"]),
    )


def row_to_run(row: Any) -> Run:
    """A run's row. A start that is not a finite number reads as 0, a finish or
    duration as None; an error or output that is not text as None; metrics
    that do not parse to an object as {}; a trigger that is not text as "run"."""
    metrics = _json(row["metrics"])
    error, output, trigger = row["error"], row["output"], row["trigger"]
    return Run(
        id=row["id"],
        job=row["job"],
        status=row["status"],
        started_at=_time(row["started_at"]),
        finished_at=_read_number(row["finished_at"]),
        duration_ms=_read_number(row["duration_ms"]),
        error=error if isinstance(error, str) else None,
        output=output if isinstance(output, str) else None,
        metrics=dict(metrics) if isinstance(metrics, Mapping) else {},
        trigger=trigger if isinstance(trigger, str) else "run",
    )


def row_to_state(row: Any) -> JobState | None:
    """A state's row, or None (no state) when it is not a JSON object."""
    state = _json(row["state"])
    return JobState.from_dict(state) if isinstance(state, Mapping) else None
