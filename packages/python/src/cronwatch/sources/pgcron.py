"""The pg_cron source (sources/pgcron.ts). Needs no package of its own: it
queries through what it is given, a psycopg 3 connection or pool, a
connection string (``pip install "cronwatch-sdk[postgres]"``), or anything
with ``query(sql, params)`` returning rows as dicts::

    from cronwatch.sources.pgcron import PgCron
    from cronwatch.stores.postgres import PostgresStore

    cw = cronwatch.Cronwatch(store=PostgresStore(url), sources=[PgCron(url, prefix="db:")])
    cw.start()
"""

from __future__ import annotations

import datetime as _dt
import re
import threading
import time
from collections.abc import Callable, Iterable, Mapping, Sequence
from dataclasses import dataclass
from typing import Any

from .. import _js
from ..evaluate import run_duration
from ..types import Alert, JobDefinition, Run, RunStatus

#: How many of a job's newest runs are copied, without alerting, the first time it is seen.
BACKFILL = 20
#: Run details read per query, and the most pages read in one sync.
PAGE = 500
MAX_PAGES = 10
#: How long a run pg_cron has queued but not started (no start_time yet) is
#: waited for. After that it is copied as running from when it was first
#: seen, so a run that never starts is marked stuck like any other.
HOLD_MS = 10 * 60_000

JOBS_SQL = "SELECT jobid, jobname, schedule, database, username, active FROM cron.job ORDER BY jobid"
# pg_settings has no row for a setting the role may not read, where
# current_setting() raises an error that would abort the caller's transaction.
SETTING_SQL = "SELECT setting FROM pg_settings WHERE name = $1"
COLUMNS = "d.runid, d.jobid, d.status, d.return_message, d.start_time, d.end_time"
# Every tracked job's runs after its cursor, and any run still open here, whatever its job.
RUNS_SQL = f"""SELECT {COLUMNS}
  FROM cron.job_run_details d
  LEFT JOIN unnest($1::bigint[], $2::bigint[]) AS c(jobid, after) ON d.jobid = c.jobid
  WHERE d.runid > c.after OR d.runid = ANY($3::bigint[])
  ORDER BY d.runid LIMIT {PAGE}"""
NEWEST_SQL = f"SELECT {COLUMNS} FROM cron.job_run_details d WHERE d.jobid = $1 ORDER BY d.runid DESC LIMIT {BACKFILL}"

_SECONDS = re.compile(f"^([0-9]+)[{_js.WHITESPACE}]*seconds?\\Z", re.IGNORECASE | re.ASCII)
_REBOOT = re.compile(r"^@reboot\Z", re.IGNORECASE | re.ASCII)
_UTC = re.compile(r"^(gmt|utc|z)\Z", re.IGNORECASE | re.ASCII)
_NOT_NAME = re.compile(r"[^A-Za-z0-9._:-]+")
_LEADING = re.compile(r"^[^A-Za-z0-9]+")
_DESCRIBED = re.compile(r"^pg_cron job ([0-9]+) in ")
_RUN_ID = re.compile(r"^[0-9]{1,15}\Z")
_EPOCH = _dt.datetime(1970, 1, 1, tzinfo=_dt.timezone.utc)
_MS = _dt.timedelta(milliseconds=1)

#: What a source never takes from `options`: pg_cron gives the schedule and its timezone.
_SCHEDULE_ONLY = ("schedule", "timezone")
#: The options of a definition that are declared again, without its schedule, for a name no longer in use.
_UNSCHEDULED = ("description", "tags", "grace", "timeout", "max_duration", "budget", "failures_before_alert")


@dataclass
class Job:
    """A row of cron.job."""

    jobid: int
    jobname: str | None = None
    schedule: str = ""
    database: str | None = None
    username: str | None = None
    active: bool = True


def schedule(text: str) -> str | None:
    """pg_cron takes a cron expression, with "$" for the last day of the
    month, or "N seconds" for 1 to 59 seconds. Returns the CronWatch
    schedule, or None for one that has no cadence to watch. pg_cron reads
    only the first five fields of an expression and ignores the rest, so only
    those are kept (a sixth would otherwise be read as seconds)."""
    trimmed = _js.trim(str(text))
    seconds = _SECONDS.search(trimmed)
    if seconds:
        return f"every {_js.number(int(seconds.group(1)))}s"
    if _REBOOT.search(trimmed):
        return None
    fields = _js.SPACES.split(trimmed)
    if len(fields) > 5 and not fields[0].startswith("@"):
        fields = fields[:5]
    if len(fields) == 5 and "$" in fields[2]:
        fields[2] = fields[2].replace("$", "L")
    return " ".join(fields)


def _raised(error: BaseException) -> str:
    return f"{type(error).__name__}: {error}"


def job_name(job: Job) -> str:
    """The default CronWatch name for a pg_cron job, before the prefix."""
    cleaned = _LEADING.sub("", _NOT_NAME.sub("-", job.jobname or ""), count=1)[:100]
    return cleaned or f"pg_cron:{job.jobid}"


def _finished(status: Any) -> bool:
    """Whether a row's status says the run is over."""
    return status in ("succeeded", "failed")


def epoch_ms(value: Any) -> int:
    """A timestamp as epoch milliseconds: a datetime (psycopg decodes them;
    one without a zone is read as UTC), text as Postgres or JSON writes it,
    or a number."""
    if isinstance(value, bool):
        raise TypeError(f"not a timestamp: {value!r}")
    if isinstance(value, (int, float)):
        return int(value // 1)
    if isinstance(value, str):
        text = value.strip().replace(" ", "T", 1)
        if text.endswith(("Z", "z")):
            text = text[:-1] + "+00:00"
        value = _dt.datetime.fromisoformat(text)
    if isinstance(value, _dt.datetime):
        at = value if value.tzinfo is not None else value.replace(tzinfo=_dt.timezone.utc)
        return (at - _EPOCH) // _MS
    raise TypeError(f"not a timestamp: {value!r}")


def run(row: Mapping[str, Any], job: str, id_prefix: str, fallback_at: int | None = None) -> Run | None:
    """A row of cron.job_run_details as a CronWatch run, or None for one that
    has not started (no start_time, not finished). A finished row with no
    start_time (pg_cron writes these for runs a server restart cut off,
    "server restarted") starts at its end_time, else at `fallback_at` (the
    reader passes the job's newest run's start, or now)."""
    finished_at = None if row.get("end_time") is None else epoch_ms(row["end_time"])
    done = _finished(row.get("status"))
    if row.get("start_time") is None and not done:
        return None
    if row.get("start_time") is not None:
        started_at = epoch_ms(row["start_time"])
    elif finished_at is not None:
        started_at = finished_at
    else:
        started_at = fallback_at if fallback_at is not None else time.time_ns() // 1_000_000
    message = row.get("return_message")
    message = None if message is None else (_js.trim(str(message)) or None)
    status = {"succeeded": RunStatus.OK, "failed": RunStatus.FAILED}.get(row.get("status"), RunStatus.RUNNING)  # type: ignore[arg-type]
    end = max(started_at, finished_at if finished_at is not None else started_at) if done else None
    return Run(
        id=f"{id_prefix}{row['runid']}",
        job=job,
        status=status,
        started_at=started_at,
        finished_at=end,
        duration_ms=None if end is None else run_duration(started_at, end),
        error=(message or "pg_cron reported the run as failed") if status == RunStatus.FAILED else None,
        output=message if status == RunStatus.OK else None,
        metrics={},
        trigger="pg_cron",
    )


def _boolean(value: Any) -> bool:
    return value in (True, "t", "true", 1, "1")


# ---------------------------------------------------------------- queries


class _Psycopg:
    """Queries through a psycopg 3 connection, a pool whose connection() lends
    one, or a connection of its own opened from a connection string. $n
    placeholders go to Postgres as written (RawCursor). A connection that is
    not in autocommit mode and not inside a transaction is left as it was
    found: the reads' transaction is rolled back."""

    def __init__(self, db: Any) -> None:
        try:
            import psycopg
            from psycopg.rows import dict_row
        except ImportError as error:
            raise ImportError(f'PgCron needs psycopg 3.2 or newer for a connection: pip install "cronwatch-sdk[postgres]" ({error})') from error
        self._psycopg = psycopg
        self._dict_row = dict_row
        self._conninfo = db if isinstance(db, str) else None
        self._pool = db if self._conninfo is None and callable(getattr(db, "connection", None)) and not hasattr(db, "cursor") else None
        self._connection = None if self._conninfo is not None or self._pool is not None else db
        self._lock = threading.Lock()

    def _own(self) -> Any:
        if self._connection is None or self._connection.closed or self._connection.broken:
            self._connection = self._psycopg.connect(self._conninfo or "", autocommit=True)
        return self._connection

    def _run(self, connection: Any, sql: str, params: Sequence[Any]) -> list[dict[str, Any]]:
        idle = not connection.autocommit and connection.info.transaction_status == self._psycopg.pq.TransactionStatus.IDLE
        try:
            with self._psycopg.RawCursor(connection, row_factory=self._dict_row) as cursor:
                cursor.execute(sql, list(params))
                return cursor.fetchall()
        finally:
            if idle:
                connection.rollback()

    def query(self, sql: str, params: Sequence[Any] = ()) -> list[dict[str, Any]]:
        if self._pool is not None:
            with self._pool.connection() as connection:
                return self._run(connection, sql, params)
        with self._lock:
            return self._run(self._own() if self._conninfo is not None else self._connection, sql, params)


def adapter(db: Any) -> Any:
    """The query adapter for `db`: itself when it has query(sql, params), else psycopg."""
    if callable(getattr(db, "query", None)):
        return db
    if isinstance(db, str) or callable(getattr(db, "cursor", None)) or callable(getattr(db, "connection", None)):
        return _Psycopg(db)
    raise TypeError("PgCron needs a psycopg connection or pool, a connection string, or an object with query(sql, params)")


# ---------------------------------------------------------------- the source


def _field(definition: Any, key: str) -> Any:
    """A snake_case option of a stored JobDefinition or a declared dict."""
    if isinstance(definition, JobDefinition):
        return definition.get(key)
    return definition.get(key) if isinstance(definition, Mapping) else None


def _key(definition: Mapping[str, Any]) -> str:
    """A definition as text, to tell a changed one from the last declared."""

    def plain(value: Any) -> Any:
        if isinstance(value, re.Pattern):
            return f"/{value.pattern}/"
        if callable(value):
            return "function"
        if isinstance(value, _dt.timedelta):
            return value // _MS
        if isinstance(value, Mapping):
            return {str(k): plain(v) for k, v in value.items()}
        if isinstance(value, (list, tuple)):
            return [plain(v) for v in value]
        return value

    return _js.dumps(plain(dict(definition)))


class PgCron:
    """Watches pg_cron jobs, which run inside Postgres where nothing can wrap
    them. As a source, on every check it reads cron.job and declares each job
    with its schedule, then copies new rows of cron.job_run_details in as
    runs (ids "pgcron:<runid>"), so the usual evaluation raises missed,
    failed, stuck and slow alerts.

    A job that is renamed, unscheduled or no longer picked keeps its old
    name's runs and history, and that name is declared again without a
    schedule, so it is never reported missed. Its description says why.

    jobs:     which jobs to watch: names or ids, or a function that picks them (given a Job). Default every job the role can see.
    prefix:   put before every job name, to keep them apart from your own ("db:"). Also keeps run ids apart.
    job_name: a function giving the CronWatch name for a Job. Default its jobname with anything other than
              letters, digits, ".", "_", ":" and "-" turned into "-", or "pg_cron:<jobid>" when it has none.
              The prefix goes in front either way. One that raises or returns no string, like a `jobs` or
              `options` function that raises, is reported once and fails only that job, which keeps its
              last declaration until the callback works again.
    options: grace, timeout, max_duration, expect and the rest, for every job (a dict) or per job (a function
              given a Job). The schedule and timezone always come from pg_cron.
    timezone: the timezone pg_cron reads its cron expressions in. Default the server's cron.timezone, read from
              pg_settings, which shows it only to roles with pg_read_all_settings; UTC (pg_cron's default) is
              assumed when it cannot be read.
    """

    name = "pg_cron"

    def __init__(
        self,
        db: Any,
        *,
        jobs: Iterable[str | int] | Callable[[Job], bool] | None = None,
        prefix: str = "",
        job_name: Callable[[Job], str] | None = None,
        options: Mapping[str, Any] | Callable[[Job], Mapping[str, Any]] | None = None,
        timezone: str | None = None,
    ) -> None:
        self._db = adapter(db)
        self._jobs = jobs if jobs is None or callable(jobs) else list(jobs)
        self._prefix = str(prefix or "")
        self._id_prefix = f"pgcron:{self._prefix}"
        self._job_name = job_name
        self._options = options
        self._timezone = timezone
        # The newest runid read for each jobid, once known.
        self._cursors: dict[int, int] = {}
        # The start of the newest run copied for each jobid: where a restart row with no times is put.
        self._last_at: dict[int, int] = {}
        # Runs copied while still going, by runid, with their job: read again until they finish, even once a check marks them timeout.
        self._pending: dict[int, str] = {}
        # Runs read before they started, by runid, with when they were first seen.
        self._held: dict[int, int] = {}
        # Each job's name and definition as last declared, by jobid.
        self._known: dict[int, tuple[str, dict[str, Any]]] = {}
        # The last definition declared for each name, so an unchanged job is not declared again.
        self._declared: dict[str, str] = {}
        # Names declared again without a schedule by _retire, whose open runs are still read.
        self._retired: set[str] = set()
        self._scanned = False
        self._warned: set[str] = set()
        # Jobids whose callback failed, reported once until it works again.
        self._failing: set[int] = set()

    def sync(self, host: Any) -> list[Alert]:
        """Declares the jobs and records their new runs. Returns the alerts recording them sent."""
        now = host.now()
        timezone = self._timezone
        if not timezone:
            tz = self._setting("cron.timezone")
            if tz is None:
                self._warn_once(host, "tz", "could not read cron.timezone; assuming UTC. Grant pg_read_all_settings or pass PgCron(db, timezone=...).")
            timezone = "UTC" if tz is None or _UTC.search(tz) else tz
        recording = self._setting("cron.log_run") != "off"
        if not recording:
            self._warn_once(
                host,
                "log_run",
                "cron.log_run is off, so pg_cron records no runs: jobs are watched without their schedules and no run can fail. Turn it on to watch them.",
            )

        rows = self._db.query(JOBS_SQL, [])
        if not rows:
            self._warn_once(
                host,
                "empty",
                "cron.job shows no jobs. pg_cron's row level security shows a role only the jobs it scheduled: connect as that role, or give this one BYPASSRLS.",
            )
        every = [self._job_from(r) for r in rows]
        names, definitions = self._declare(host, every, timezone, recording)
        self._retire_unused(host, names, definitions, every)
        if not recording or not names:
            return []

        alerts: list[Alert] = []
        self._start_cursors(host, names, alerts, now)
        self._read_new(host, names, alerts, now)
        return alerts

    # ---------------------------------------------------------------- reading cron.job

    @staticmethod
    def _job_from(row: Mapping[str, Any]) -> Job:
        return Job(
            jobid=int(row["jobid"]),
            jobname=row.get("jobname"),
            schedule=str(row.get("schedule") or ""),
            database=row.get("database"),
            username=row.get("username"),
            active=_boolean(row.get("active")),
        )

    def _warn_once(self, host: Any, key: str, message: str) -> None:
        if key in self._warned:
            return
        self._warned.add(key)
        host.on_error(RuntimeError(message), "source pg_cron")

    def _picks(self, job: Job) -> bool:
        if self._jobs is None:
            return True
        if callable(self._jobs):
            return bool(self._jobs(job))
        return any(j == job.jobid if isinstance(j, int) and not isinstance(j, bool) else j == job.jobname for j in self._jobs)

    def _setting(self, name: str) -> str | None:
        try:
            rows = self._db.query(SETTING_SQL, [name])
        except Exception:  # noqa: BLE001, a setting that cannot be read is assumed
            return None
        value = rows[0].get("setting") if rows else None
        return None if value is None else str(value)

    def _run_id_of(self, run_id: str) -> int | None:
        if not run_id.startswith(self._id_prefix):
            return None
        rest = run_id[len(self._id_prefix) :]
        return int(rest) if _RUN_ID.search(rest) else None

    # ---------------------------------------------------------------- declaring jobs

    def _declare(self, host: Any, jobs: list[Job], timezone: str, recording: bool) -> tuple[dict[int, str], dict[int, dict[str, Any]]]:
        """Declares each job `jobs` picks. A paused one (active = false) keeps
        its failures but loses its schedule, so it is not missed. Returns each
        jobid's name and definition as declared."""
        # One forgotten since it was declared (the dashboard's forget) is declared
        # again, though unchanged: record_run takes runs only of a declared job.
        defined = getattr(host, "defined_jobs", None)
        live = {d.name for d in defined()} if callable(defined) else None
        names: dict[int, str] = {}
        definitions: dict[int, dict[str, Any]] = {}
        used: set[str] = set()

        def trouble(job: Job, what: str) -> None:
            """A callback of the app's (jobs, job_name, options) that raised, or
            a job_name that gave no name, fails only its job, as a bad row does:
            reported once until it works again, and the job carries on as last
            declared (skipped when it never was), so its runs are still copied."""
            if job.jobid not in self._failing:
                self._failing.add(job.jobid)
                host.on_error(RuntimeError(f"pg_cron job {job.jobid}: {what}; it keeps its last declaration until that works"), "source pg_cron")
            last = self._known.get(job.jobid)
            if last is None or last[0] in used:
                return
            names[job.jobid] = last[0]
            definitions[job.jobid] = last[1]
            used.add(last[0])

        for job in jobs:
            try:
                picked = self._picks(job)
            except Exception as error:  # noqa: BLE001, the app's callback fails only its job
                trouble(job, f"the jobs callback raised {_raised(error)}")
                continue
            if not picked:
                self._failing.discard(job.jobid)
                continue
            try:
                base: Any = self._job_name(job) if self._job_name else job_name(job)
            except Exception as error:  # noqa: BLE001, the app's callback fails only its job
                trouble(job, f"job_name raised {_raised(error)}")
                continue
            if not isinstance(base, str):
                trouble(job, f"job_name returned {'None' if base is None else type(base).__name__}, not a name")
                continue
            try:
                extra = (self._options(job) if callable(self._options) else self._options) or {}
                extra = {k: v for k, v in dict(extra).items() if k not in _SCHEDULE_ONLY}
            except Exception as error:  # noqa: BLE001, the app's callback fails only its job
                trouble(job, f"the options callback raised {_raised(error)}")
                continue
            self._failing.discard(job.jobid)
            name = self._prefix + base
            if name in used:
                name = f"{name}:{job.jobid}"
            used.add(name)
            cadence = schedule(job.schedule) if job.active and recording else None
            paused = "" if job.active else " (paused)"
            definition: dict[str, Any] = {"description": f"pg_cron job {job.jobid} in {job.database} as {job.username}{paused}", "tags": ["pg_cron"], **extra}
            if cadence:
                definition.update(schedule=cadence, timezone=timezone)
            try:
                key = _key(definition)
                if self._declared.get(name) != key or (live is not None and name not in live):
                    try:
                        host.job(name, **definition)
                    except Exception as error:
                        if not cadence:
                            raise
                        # A schedule CronWatch cannot read: watch the runs, not the cadence.
                        host.on_error(RuntimeError(f"pg_cron job {job.jobid}: {error}; watching it without a schedule"), "source pg_cron")
                        definition = {k: v for k, v in definition.items() if k not in _SCHEDULE_ONLY}
                        host.job(name, **definition)
                    self._declared[name] = key
                names[job.jobid] = name
                definitions[job.jobid] = definition
            except Exception as error:
                host.on_error(error, f"source pg_cron: job {job.jobid}")
        return names, definitions

    def _retire(self, host: Any, name: str, definition: Any, why: str) -> None:
        """Declares a name this source no longer uses for any job again, without its schedule."""
        base = {field: _field(definition, field) for field in _UNSCHEDULED if _field(definition, field) is not None}
        following = {**base, "description": f"{base.get('description') or 'pg_cron job'} ({why})"}
        try:
            host.job(name, **following)
            self._declared[name] = _key(following)
            self._retired.add(name)
        except Exception as error:
            host.on_error(error, f"source pg_cron: job {name}")

    def _retire_unused(self, host: Any, names: dict[int, str], definitions: dict[int, dict[str, Any]], every: list[Job]) -> None:
        """A name this source used for a job that has since been renamed,
        unscheduled or dropped from `jobs` is declared again without its
        schedule. Once per process, the same for names left scheduled in the
        store while no process was watching."""
        in_use = set(names.values())
        self._retired -= in_use
        for jobid, (previous, definition) in self._known.items():
            if previous in in_use:
                continue
            renamed = names.get(jobid)
            self._retire(host, previous, definition, f"renamed to {renamed}" if renamed else "no longer watched")
        self._known = {jobid: (name, definitions[jobid]) for jobid, name in names.items()}
        if self._scanned or not every:
            return
        self._scanned = True
        try:
            visible = {job.jobid for job in every}
            for stored in host.store.list_jobs():
                definition = stored.definition
                if not stored.name.startswith(self._prefix) or stored.name in in_use:
                    continue
                if not definition.schedule or "pg_cron" not in (definition.tags or []):
                    continue
                match = _DESCRIBED.search(definition.description or "")
                if not match:
                    continue
                jobid = int(match.group(1))
                current = names.get(jobid)
                if jobid not in visible:
                    self._retire(host, stored.name, definition, "no longer in cron.job")
                elif current and not stored.name.endswith(current[len(self._prefix) :]):
                    # Another pg_cron source's name for the same job ends the same way: that one is left alone.
                    self._retire(host, stored.name, definition, f"renamed to {current}")
        except Exception as error:
            host.on_error(error, "source pg_cron")

    # ---------------------------------------------------------------- copying runs

    def _record(self, host: Any, names: dict[int, str], row: Mapping[str, Any], evaluate: bool, alerts: list[Alert], now: int) -> None:
        """Copies one detail row in as a run. A row that cannot be recorded is
        reported and skipped; it never stops the others."""
        runid = int(row["runid"])
        jobid = int(row["jobid"])
        name = self._pending.get(runid) or names.get(jobid)
        if not name:
            self._held.pop(runid, None)
            return
        if row.get("start_time") is None and not _finished(row.get("status")):
            since = self._held.get(runid, now)
            if now - since < HOLD_MS:
                self._held[runid] = since
                return
            found = run({**row, "start_time": since}, name, self._id_prefix)
        else:
            found = run(row, name, self._id_prefix, self._last_at.get(jobid, now))
        self._held.pop(runid, None)
        if found is None:
            return
        try:
            alerts.extend(host.record_run(found, evaluate=evaluate))
        except Exception as error:
            host.on_error(error, f"source pg_cron: run {runid}")
            return
        if found.status == RunStatus.RUNNING:
            self._pending[runid] = name
        else:
            self._pending.pop(runid, None)
        if jobid not in self._last_at or found.started_at > self._last_at[jobid]:
            self._last_at[jobid] = found.started_at

    def _start_cursors(self, host: Any, names: dict[int, str], alerts: list[Alert], now: int) -> None:
        """Where each job left off. Found from the store the first time, so a restart carries on."""
        for jobid, name in names.items():
            if jobid in self._cursors:
                continue
            ours = [(runid, r) for r in host.store.list_runs(name, BACKFILL) if (runid := self._run_id_of(r.id)) is not None]
            if ours:
                self._cursors[jobid] = max(runid for runid, _ in ours)
                self._last_at[jobid] = max(r.started_at for _, r in ours)
                for runid, r in ours:
                    if r.status in (RunStatus.RUNNING, RunStatus.TIMEOUT):
                        self._pending[runid] = r.job
                continue
            # First sight: copy recent history quietly, and judge only from the newest finished run on.
            # The cursor goes to the newest row read, whatever is held, so history is never judged later.
            ordered = list(reversed(self._db.query(NEWEST_SQL, [jobid])))
            last_finished = -1
            for i, r in enumerate(ordered):
                if _finished(r.get("status")):
                    last_finished = i
            for i, row in enumerate(ordered):
                # Already copied under another name (the job was renamed while no process watched): left there.
                if host.store.get_run(f"{self._id_prefix}{row['runid']}") is not None:
                    continue
                self._record(host, names, row, i >= last_finished, alerts, now)
            self._cursors[jobid] = int(ordered[-1]["runid"]) if ordered else 0

    def _read_new(self, host: Any, names: dict[int, str], alerts: list[Alert], now: int) -> None:
        """New runs, runs copied while still going (or since marked timeout), and runs not yet started."""
        watched = set(names.values()) | self._retired
        for stored in host.store.running_runs():
            runid = self._run_id_of(stored.id)
            if runid is not None and stored.job in watched:
                self._pending[runid] = stored.job
        still_open = {*self._pending, *self._held}
        complete = False
        for _ in range(MAX_PAGES):
            jobids = list(names)
            details = self._db.query(RUNS_SQL, [jobids, [self._cursors.get(j, 0) for j in jobids], sorted(still_open)])
            for row in details:
                jobid = int(row["jobid"])
                runid = int(row["runid"])
                still_open.discard(runid)
                self._record(host, names, row, True, alerts, now)
                # Held or not, the cursor moves on: a held run is read again by its runid.
                if jobid in names and runid > self._cursors.get(jobid, 0):
                    self._cursors[jobid] = runid
            if len(details) < PAGE:
                complete = True
                break
        # Every row was read and these were not among them: pg_cron no longer has them.
        if complete:
            for runid in still_open:
                self._pending.pop(runid, None)
                self._held.pop(runid, None)
