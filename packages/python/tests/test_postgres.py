"""The Postgres store's own tests, beside the store conformance test (in
test_stores.py) and the finish-once tests (in test_start_finish.py) it also
passes: the SDK's test/stores.test.ts, its schema read back from the
catalogue, and writes that never join the app's transaction. They run when
CRONWATCH_TEST_PG is set."""

from __future__ import annotations

import subprocess
import sys
import threading
from collections.abc import Iterator
from typing import Any

import pytest

from cronwatch import Cronwatch, JobDefinition, JobState
from cronwatch.stores import _sql

from helpers import NO_PG, PG, drop_pg_tables, pg_prefix

needs_pg = pytest.mark.skipif(not PG, reason=NO_PG)


@pytest.fixture
def prefix() -> Iterator[str]:
    made = pg_prefix("p")
    yield made
    if PG:
        drop_pg_tables(made)


def test_a_prefix_that_is_not_a_plain_lowercase_identifier_is_refused() -> None:
    from cronwatch.stores.postgres import PostgresStore

    for bad in ("1cw_", "cw-", "Cw_", "cw_;drop", "", "x" * 48):
        with pytest.raises(ValueError, match="invalid table prefix"):
            PostgresStore("postgres://unused", prefix=bad)


BAD_URL = "postgres://app:p%zzword@db.example:5432/app"


def test_a_database_url_whose_password_has_a_stray_percent_is_not_quoted_in_the_error() -> None:
    # libpq's own error quotes the token it could not read: here the password.
    from cronwatch.stores.postgres import PostgresStore

    errors: list[str] = []
    cw = Cronwatch(store=PostgresStore(BAD_URL), alerts=[], cron_secret=None, on_error=lambda e, _where: errors.append(str(e)))
    with pytest.raises(Exception) as raised:
        cw.check()
    assert "zzword" not in str(raised.value)
    assert '"db.example"' in str(raised.value)
    # A run still runs; the store's error goes to on_error, without the password.
    assert cw.run("j", lambda ctx: 7) == 7
    assert errors and all("zzword" not in e for e in errors)


def test_pg_cron_with_such_a_url_does_not_quote_it_either() -> None:
    from cronwatch.sources import pgcron

    with pytest.raises(Exception) as raised:
        pgcron._adapter(BAD_URL).query("SELECT 1", [])
    assert "zzword" not in str(raised.value)
    assert '"db.example"' in str(raised.value)


def test_statements_are_the_sdks_with_numbered_placeholders() -> None:
    sql = _sql.statements("postgres", "cronwatch_")
    assert sql["cas_update"] == (
        "UPDATE cronwatch_state SET state = $1 WHERE job = $2 AND CASE WHEN jsonb_typeof(state->'version') <> 'number' THEN 0 "
        "WHEN (state->>'version')::numeric % 1 = 0 AND (state->>'version')::numeric BETWEEN 0 AND 9007199254740991 "
        "THEN (state->>'version')::numeric::bigint ELSE 0 END = $3"
    )
    assert sql["list_runs"] == "SELECT * FROM cronwatch_runs WHERE job = $1 ORDER BY started_at DESC, seq DESC LIMIT $2"
    assert sql["list_jobs"] == 'SELECT * FROM cronwatch_jobs ORDER BY name COLLATE "C"'
    assert _sql.update_run_if_sql("postgres", "cronwatch_", 2).endswith("WHERE id = $7 AND status IN ($8, $9)")


@pytest.mark.parametrize("module", ["cronwatch.stores.postgres", "cronwatch.triage.anthropic"])
def test_loading_without_the_driver_says_what_to_install(module: str) -> None:
    missing = "psycopg" if module.endswith("postgres") else "anthropic"
    script = f"import sys; sys.modules[{missing!r}] = None\ntry:\n    import {module}\nexcept ImportError as e:\n    print(e)"
    out = subprocess.run([sys.executable, "-c", script], capture_output=True, text=True, check=True).stdout
    extra = "postgres" if missing == "psycopg" else "anthropic"
    assert f'pip install "cronwatch-sdk[{extra}]"' in out, out


@needs_pg
def test_the_schema_is_the_sdks(prefix: str) -> None:
    import psycopg

    from cronwatch.stores.postgres import PostgresStore

    store = PostgresStore(PG, prefix=prefix)
    store.init()
    store.init()  # IF NOT EXISTS: a second init changes nothing
    store.close()
    with psycopg.connect(PG or "") as connection:
        columns = connection.execute(
            "SELECT table_name, column_name, data_type, column_default FROM information_schema.columns "
            "WHERE table_name LIKE %s ORDER BY table_name, ordinal_position",
            [f"{prefix}%"],
        ).fetchall()
        indexes = connection.execute("SELECT indexname FROM pg_indexes WHERE indexname LIKE %s ORDER BY indexname", [f"{prefix}%"]).fetchall()
    types = {(t[len(prefix) :], c): d for t, c, d, _ in columns}
    assert types[("runs", "seq")] == "bigint"
    assert [c for t, c, _, _ in columns if t == f"{prefix}runs"][:2] == ["seq", "id"]
    assert types[("runs", "metrics")] == "jsonb"
    assert types[("jobs", "definition")] == "jsonb"
    assert types[("state", "state")] == "jsonb"
    assert types[("runs", "started_at")] == "bigint"
    defaults = {(t[len(prefix) :], c): d for t, c, _, d in columns}
    assert defaults[("runs", "seq")].startswith("nextval(")
    assert defaults[("runs", "trigger")] == "'run'::text"
    assert [i for (i,) in indexes] == [f"{prefix}jobs_pkey", f"{prefix}runs_job_started", f"{prefix}runs_pkey", f"{prefix}runs_running", f"{prefix}state_pkey"]


@needs_pg
def test_output_and_errors_with_nul_characters_are_still_recorded(prefix: str) -> None:
    from cronwatch.stores.postgres import PostgresStore

    def fail(error: BaseException, where: str) -> None:
        raise error

    cw = Cronwatch(store=PostgresStore(PG, prefix=prefix), alerts=[], cron_secret=None, on_error=fail)

    def job(ctx: Any) -> None:
        ctx.log("before\x00after")
        raise RuntimeError("bad\x00byte")

    with pytest.raises(RuntimeError, match="bad"):
        cw.run("nul", job)
    [run] = cw.runs("nul")
    assert run.status == "failed"
    assert run.output == "beforeafter"
    assert run.error.startswith("RuntimeError: badbyte")
    assert cw.store.get_state("nul").consecutive_failures == 1, "the state, with its alert, was written too"
    # So are a trigger, metric names, and a definition's text.
    nul2 = cw.job("nul2", description="a\x00b", tags=["t\x00"], budget={"c\x00": 5})
    nul2.run(lambda ctx: ctx.metric("ro\x00ws", 2), trigger="cr\x00on")
    [second] = cw.runs("nul2")
    assert [second.status, second.trigger, second.metrics] == ["ok", "cron", {"rows": 2}]
    definition = cw.store.get_job("nul2").definition
    assert [definition.description, definition.tags, definition.budget] == ["ab", ["t"], {"c": 5}]
    cw.close()


@needs_pg
def test_two_stores_racing_on_one_jobs_state(prefix: str) -> None:
    from cronwatch.stores.postgres import PostgresStore

    one, two = PostgresStore(PG, prefix=prefix), PostgresStore(PG, prefix=prefix)
    one.init()
    two.init()

    def state(version: int, n: int) -> JobState:
        return JobState(job="r", consecutive_failures=n, version=version)

    def race(expected: int, version: int) -> list[bool]:
        results: list[bool] = []
        barrier = threading.Barrier(2)

        def attempt(store: Any, n: int) -> None:
            barrier.wait(5)
            results.append(store.compare_and_set_state(state(version, n), expected))

        threads = [threading.Thread(target=attempt, args=(s, n)) for s, n in ((one, version * 2 - 1), (two, version * 2))]
        for t in threads:
            t.start()
        for t in threads:
            t.join(10)
        return sorted(results)

    assert race(0, 1) == [False, True], "exactly one insert wins"
    assert race(1, 2) == [False, True], "exactly one update wins"
    assert one.get_state("r").version == 2
    one.close()
    two.close()


@needs_pg
def test_many_instances_can_init_at_once(prefix: str) -> None:
    from cronwatch.stores.postgres import PostgresStore

    stores = [PostgresStore(PG, prefix=prefix) for _ in range(8)]
    errors: list[BaseException] = []

    def init(store: Any) -> None:
        try:
            store.init()
        except BaseException as error:  # noqa: BLE001, collected for the assertion
            errors.append(error)

    threads = [threading.Thread(target=init, args=(s,)) for s in stores]
    for t in threads:
        t.start()
    for t in threads:
        t.join(20)
    assert errors == []
    stores[0].upsert_job(JobDefinition({"name": "a"}), 1)
    assert stores[7].get_job("a").created_at == 1
    for s in stores:
        s.close()


@needs_pg
def test_writes_never_join_the_apps_transaction(prefix: str) -> None:
    import psycopg

    from cronwatch.stores.postgres import PostgresStore

    cw = Cronwatch(store=PostgresStore(PG, prefix=prefix), alerts=[], cron_secret=None)
    job = cw.job("inside")
    with psycopg.connect(PG or "") as app:
        with app.transaction(force_rollback=True):
            app.execute("SELECT 1")
            job.run(lambda ctx: ctx.log("done"))
        # The app's transaction rolled back; the run was written on the store's own connection.
    assert [r.output for r in cw.runs("inside")] == ["done"]
    cw.close()


@needs_pg
def test_a_pool_of_the_apps_own_is_used_and_left_open(prefix: str) -> None:
    import psycopg

    from cronwatch.stores.postgres import PostgresStore

    class Pool:
        """psycopg_pool's shape: connection() is a context manager giving a connection."""

        def __init__(self) -> None:
            self.connection_ = psycopg.connect(PG or "", autocommit=True)
            self.used = 0

        def connection(self) -> Any:
            pool = self

            class Borrow:
                def __enter__(self) -> Any:
                    pool.used += 1
                    return pool.connection_

                def __exit__(self, *exc: Any) -> None:
                    return None

            return Borrow()

    pool = Pool()
    store = PostgresStore(pool=pool, prefix=prefix)
    store.init()
    store.upsert_job(JobDefinition({"name": "p"}), 5)
    assert store.get_job("p").created_at == 5
    store.close()
    assert pool.used >= 3
    assert not pool.connection_.closed, "a pool given is left open"
    pool.connection_.close()
