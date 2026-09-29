"""The test every store passes (the SDK's test/store-conformance.ts), run
against the memory and SQLite stores, and the SQLite store's own details."""

from __future__ import annotations

import os
import sqlite3
import stat
from pathlib import Path
from typing import Any

import pytest

from cronwatch import JobDefinition, JobState, Run
from cronwatch.stores import MemoryStore, SqliteStore
from cronwatch.stores import _sql
from cronwatch.stores.sqlite import retry_busy

from helpers import NO_PG, PG, drop_pg_tables, pg_prefix


def run(run_id: str, job: str, status: str, started_at: int, **extra: Any) -> Run:
    done = status != "running"
    fields: dict[str, Any] = {
        "id": run_id,
        "job": job,
        "status": status,
        "started_at": started_at,
        "finished_at": started_at + 10 if done else None,
        "duration_ms": 10 if done else None,
        "metrics": {"n": 1},
        **extra,
    }
    return Run(**fields)


def definition(**fields: Any) -> JobDefinition:
    return JobDefinition(fields)


@pytest.fixture(params=["memory", "sqlite", pytest.param("postgres", marks=pytest.mark.skipif(not PG, reason=NO_PG))])
def store(request: pytest.FixtureRequest, tmp_path: Path) -> Any:
    if request.param == "postgres":
        from cronwatch.stores.postgres import PostgresStore

        prefix = pg_prefix("s")
        made: Any = PostgresStore(PG, prefix=prefix)
        yield made
        made.close()
        drop_pg_tables(prefix)
        return
    made = MemoryStore() if request.param == "memory" else SqliteStore(tmp_path / "data" / "cw.db")
    yield made
    made.close()


def test_store_conformance(store: Any) -> None:
    getattr(store, "init", lambda: None)()
    assert store.get_job("a") is None
    store.upsert_job(definition(name="a", schedule="every 5m"), 100)
    store.upsert_job(definition(name="a", schedule="every 10m", tags=["x"]), 200)
    store.upsert_job(definition(name="b"), 300)
    store.upsert_job(definition(name="B"), 300)
    store.upsert_job(definition(name="_c"), 300)
    a = store.get_job("a")
    assert a.created_at == 100, "created_at survives upsert"
    assert a.updated_at == 200
    assert a.definition.to_dict() == {"name": "a", "schedule": "every 10m", "tags": ["x"]}
    assert [j.name for j in store.list_jobs()] == ["B", "_c", "a", "b"], "code unit order, not locale"

    store.insert_run(run("r1", "a", "ok", 1000))
    store.insert_run(run("r2", "a", "failed", 2000))
    store.insert_run(run("r3", "a", "running", 3000))
    store.insert_run(run("r4", "b", "ok", 1500))
    store.insert_run(run("rb", "B", "running", 2000))
    store.insert_run(run("rc", "_c", "running", 2000))
    assert [r.id for r in store.list_runs("a", 10)] == ["r3", "r2", "r1"]
    assert [r.id for r in store.list_runs("a", 2)] == ["r3", "r2"]
    assert store.last_run("a").id == "r3"
    assert store.last_run("none") is None
    assert [r.id for r in store.running_runs()] == ["rb", "rc", "r3"], "oldest first, then insertion order"
    r1 = store.get_run("r1")
    assert r1.metrics == {"n": 1}
    assert r1.duration_ms == 10

    store.update_run(run("r3", "a", "ok", 3000, output="line1\nline2", metrics={"cost": 0.25}))
    r3 = store.get_run("r3")
    assert r3.status == "ok"
    assert r3.output == "line1\nline2"
    assert r3.metrics == {"cost": 0.25}
    assert [r.id for r in store.running_runs()] == ["rb", "rc"]

    # update_run_if: writes only over a row whose status is one of those given, and says whether it did.
    with pytest.raises(Exception):  # an id already recorded is refused, by whatever the driver raises
        store.insert_run(run("r3", "a", "running", 3000))
    store.upsert_job(definition(name="q"), 300)
    store.insert_run(run("rx", "q", "running", 2500))
    assert store.update_run_if(run("rx", "q", "failed", 2500, error="first"), ["running"]) is True
    assert store.update_run_if(run("rx", "q", "ok", 2500, output="second"), ["running"]) is False, "a second finish over the first is refused"
    assert store.get_run("rx").error == "first"
    assert store.update_run_if(run("rx", "q", "ok", 2500, output="late"), ["running", "timeout"]) is False
    store.update_run(run("rx", "q", "timeout", 2500, error="stuck"))
    assert store.update_run_if(run("rx", "q", "ok", 2500, output="late", metrics={"m": 2}), ["running", "timeout"]) is True
    late = store.get_run("rx")
    assert [str(late.status), late.output, late.error, late.metrics, late.job, late.trigger] == ["ok", "late", None, {"m": 2}, "q", "run"]
    assert store.update_run_if(run("missing", "q", "ok", 1), ["running"]) is False, "a run that is not there is not written"
    assert store.get_run("missing") is None
    assert store.update_run_if(run("rx", "q", "failed", 2500), []) is False, "no statuses, no write"
    assert store.get_run("rx").status == "ok"
    store.delete_job("q")

    # Forgetting a job while one of its runs is in flight: the run finishing later changes nothing.
    store.delete_job("B")
    store.update_run(run("rb", "B", "ok", 2000, output="late"))
    assert store.get_run("rb") is None
    assert store.list_runs("B", 10) == []
    assert [r.id for r in store.running_runs()] == ["rc"]
    store.delete_job("_c")

    assert store.get_state("a") is None
    store.set_state(JobState(job="a", open={"failed": 5}, consecutive_failures=2, last_alert_at=6))
    store.set_state(JobState(job="a", open={}, consecutive_failures=0, silenced_until=99, last_alert_at=6))
    assert store.get_state("a").to_dict() == {"job": "a", "open": {}, "consecutiveFailures": 0, "silencedUntil": 99, "lastAlertAt": 6}
    full = JobState.from_dict(
        {
            "job": "a",
            "open": {"stuck": 7},
            "consecutiveFailures": 1,
            "silencedUntil": None,
            "lastAlertAt": 6,
            "pendingRecovery": ["missed"],
            "undelivered": [{"type": "failed", "job": "a", "title": "a failed", "message": "boom", "at": 7, "details": {"consecutiveFailures": 1}}],
        }
    )
    store.set_state(full)
    assert store.get_state("a").to_dict() == full.to_dict(), "pendingRecovery and undelivered round-trip"
    store.set_state(JobState(job="a", open={}, silenced_until=99, last_alert_at=6))

    # compare_and_set_state: writes only over the version it was told to expect.
    def v(version: int, **extra: Any) -> JobState:
        return JobState(job=extra.pop("job", "v"), version=version, **extra)

    assert store.compare_and_set_state(v(2), 1) is False, "no row matches only version 0"
    assert store.get_state("v") is None
    assert store.compare_and_set_state(v(1), 0) is True, "no row counts as version 0"
    assert store.compare_and_set_state(v(1, consecutive_failures=9), 0) is False, "a write from a stale read is refused"
    assert store.compare_and_set_state(v(2, consecutive_failures=1), 1) is True
    assert store.compare_and_set_state(v(3), 1) is False
    assert store.get_state("v").to_dict() == v(2, consecutive_failures=1).to_dict()
    store.set_state(JobState(job="w", consecutive_failures=3))
    assert store.compare_and_set_state(v(1, job="w"), 1) is False, "state written before versions counts as 0"
    assert store.compare_and_set_state(v(1, job="w"), 0) is True
    assert store.get_state("w").version == 1
    store.delete_job("v")
    assert store.compare_and_set_state(v(3), 2) is False, "a forgotten job's state is not written back"
    assert store.get_state("v") is None
    store.delete_job("w")

    store.insert_run(run("r5", "a", "running", 500))
    assert store.prune(2500) == 2, "r1 and r2 pruned; running r5 kept, and b's r4 kept as b's newest run"
    assert [r.id for r in store.list_runs("a", 10)] == ["r3", "r5"]
    assert [r.id for r in store.list_runs("b", 10)] == ["r4"]
    assert store.prune(1_000_000) == 0, "however old, each job keeps its newest run, and running runs stay"

    store.delete_job("a")
    assert store.get_job("a") is None
    assert store.list_runs("a", 10) == []
    assert store.get_state("a") is None
    assert store.get_job("b").name == "b"


def test_sqlite_creates_its_directory_and_keeps_the_file_private(tmp_path: Path) -> None:
    file = tmp_path / "nested" / "dir" / "cw.db"
    store = SqliteStore(file)
    store.init()
    store.upsert_job(definition(name="a"), 1)
    assert file.exists()
    if os.name == "posix":
        assert stat.S_IMODE(file.stat().st_mode) == 0o600
        for sidecar in (Path(f"{file}-wal"), Path(f"{file}-shm")):
            if sidecar.exists():
                assert stat.S_IMODE(sidecar.stat().st_mode) == 0o600
    mode = sqlite3.connect(file).execute("PRAGMA journal_mode").fetchone()[0]
    assert mode == "wal"
    store.close()


def test_sqlite_schema_is_the_sdks_text_for_text(tmp_path: Path) -> None:
    store = SqliteStore(tmp_path / "cw.db", prefix="mon_")
    store.init()
    rows = sqlite3.connect(tmp_path / "cw.db").execute("SELECT name, sql FROM sqlite_master WHERE name LIKE 'mon_%' ORDER BY name").fetchall()
    names = [name for name, _ in rows]
    assert names == ["mon_jobs", "mon_runs", "mon_runs_job_started", "mon_runs_running", "mon_state"]
    assert dict(rows)["mon_runs_running"] == "CREATE INDEX mon_runs_running ON mon_runs (status) WHERE status = 'running'"
    store.init()  # IF NOT EXISTS: a second init changes nothing
    store.close()


def test_sqlite_in_memory_and_a_connection_of_your_own(tmp_path: Path) -> None:
    memory = SqliteStore(":memory:")
    memory.init()
    memory.upsert_job(definition(name="m"), 1)
    assert memory.get_job("m").name == "m"
    memory.close()

    connection = sqlite3.connect(tmp_path / "own.db", isolation_level=None, check_same_thread=False)
    own = SqliteStore(connection=connection)
    own.init()
    own.upsert_job(definition(name="o"), 2)
    own.close()
    assert connection.execute("SELECT name FROM cronwatch_jobs").fetchall() == [("o",)], "a connection given is left open"
    connection.close()


def test_table_prefix_is_a_plain_lowercase_identifier() -> None:
    assert _sql.table_prefix() == "cronwatch_"
    assert _sql.table_prefix("app_cw_") == "app_cw_"
    for bad in ("Monitoring_", "1st_", "has-dash_", "", "x" * 48):
        with pytest.raises(ValueError, match="invalid table prefix"):
            SqliteStore(":memory:", prefix=bad)


def test_busy_retries_with_a_growing_pause_then_gives_up() -> None:
    pauses: list[float] = []
    attempts = [0]

    def busy() -> str:
        attempts[0] += 1
        if attempts[0] < 4:
            raise sqlite3.OperationalError("database is locked")
        return "ok"

    assert retry_busy(busy, sleep=pauses.append) == "ok"
    assert pauses == [0.01, 0.02, 0.04]

    def always() -> None:
        raise sqlite3.OperationalError("database is locked")

    pauses.clear()
    with pytest.raises(sqlite3.OperationalError):
        retry_busy(always, budget_ms=100, sleep=pauses.append)
    assert round(sum(pauses) * 1000) == 100

    def other() -> None:
        raise sqlite3.OperationalError("no such table: x")

    with pytest.raises(sqlite3.OperationalError, match="no such table"):
        retry_busy(other, sleep=pauses.append)


@pytest.mark.skipif(not hasattr(os, "fork"), reason="needs fork")
@pytest.mark.filterwarnings("ignore:This process .* is multi-threaded, use of fork:DeprecationWarning")
def test_a_forked_child_opens_a_sqlite_connection_of_its_own(tmp_path: Path) -> None:
    """As a prefork worker's children do: the parent's connection is left to it."""
    store = SqliteStore(str(tmp_path / "fork.db"))
    store.init()
    parent_connection = store._db
    pid = os.fork()
    if pid == 0:  # pragma: no cover, the child
        code = 0
        try:
            store.insert_run(Run(id="from-child", job="j", status="ok", started_at=1, finished_at=2, duration_ms=1))
            code = 0 if store._db is not parent_connection else 3
        except BaseException:
            code = 2
        os._exit(code)
    _, status = os.waitpid(pid, 0)
    assert os.waitstatus_to_exitcode(status) == 0
    assert store._db is parent_connection
    assert store.get_run("from-child") is not None

@pytest.fixture(params=["sqlite", pytest.param("postgres", marks=pytest.mark.skipif(not PG, reason=NO_PG))])
def sql_store(request: pytest.FixtureRequest, tmp_path: Path) -> Any:
    if request.param == "postgres":
        from cronwatch.stores.postgres import PostgresStore

        prefix = pg_prefix("f")
        made: Any = PostgresStore(PG, prefix=prefix)
        yield made
        made.close()
        drop_pg_tables(prefix)
        return
    made = SqliteStore(tmp_path / "foreign.db")
    yield made
    made.close()


def test_a_check_over_a_run_that_started_at_the_lowest_bigint_and_a_state_whose_version_is_1_5(sql_store: Any) -> None:
    """Rows another process wrote. The job is silenced: an alert's text shows
    the start as a date, and no date is that far back."""
    from cronwatch import Cronwatch

    from helpers import Errors

    store = sql_store
    store.init()
    store.upsert_job(definition(name="far", timeout="5m"), 1)
    execute = store._run if isinstance(store, SqliteStore) else store._execute
    p = store.prefix
    execute(f"INSERT INTO {p}runs (id, job, status, started_at, metrics, trigger) VALUES ('far1', 'far', 'running', -9223372036854775808, '{{}}', 'run')")
    execute(
        f"INSERT INTO {p}state (job, state) VALUES ('far', "
        """'{"job":"far","open":{},"consecutiveFailures":0,"silencedUntil":4102444800000,"lastAlertAt":null,"version":1.5}')"""
    )
    errors = Errors()
    cw = Cronwatch(store=store, alerts=[], cron_secret=None, on_error=errors)
    cw.check()
    cw.check()
    assert errors.items == []
    stuck = store.get_run("far1")
    assert stuck.status == "timeout"
    assert stuck.duration_ms == 9_007_199_254_740_991, "the duration is held at 2^53 - 1"
    state = store.get_state("far")
    assert state.version == 1, "the state's 1.5 counted as 0 and was written over"
    assert state.consecutive_failures == 1
