"""A Node process and a Python process sharing one SQLite file: the SDK's
store (from the built packages/sdk/dist) and SqliteStore replay the same
store calls (fixtures/shared_store.json), and each must read what the other
wrote exactly as it reads its own, down to the bytes in every column.

Needs node on the PATH and the SDK built (`npm ci && npm run build` at the
repository root); skipped, with the reason, without them."""

from __future__ import annotations

import json
import shutil
import sqlite3
import subprocess
from pathlib import Path
from typing import Any

import pytest

from cronwatch import Cronwatch, JobDefinition, JobState, Run, _js
from cronwatch.stores import SqliteStore

from helpers import MIN, Capture, Clock

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
SCRIPT = HERE / "node_store.mjs"
FIXTURE_PATH = HERE / "fixtures" / "shared_store.json"
FIXTURE = json.loads(FIXTURE_PATH.read_text("utf-8"))


def _unavailable() -> str | None:
    if shutil.which("node") is None:
        return "node is not on the PATH"
    if not (REPO / "packages/sdk/dist/sqlite.js").exists():
        return "packages/sdk/dist is not built: run `npm ci && npm run build` at the repository root"
    if not (REPO / "node_modules/better-sqlite3").is_dir():
        return "the SDK's SQLite driver is not installed: run `npm ci` at the repository root"
    return None


pytestmark = pytest.mark.skipif(_unavailable() is not None, reason=f"Node compatibility: {_unavailable()}")


def node(action: str, file: Path, prefix: str, *args: str) -> str:
    done = subprocess.run(["node", str(SCRIPT), action, str(file), prefix, *args], capture_output=True, text=True, encoding="utf-8", check=False)
    assert done.returncode == 0, f"node {action} failed: {done.stderr}"
    return done.stdout


def node_write(file: Path, prefix: str) -> Any:
    return json.loads(node("write", file, prefix, str(FIXTURE_PATH)))


def python_write(store: SqliteStore) -> dict[str, Any]:
    store.init()
    pruned = []
    for step in FIXTURE["ops"]:
        op = step["op"]
        if op == "upsertJob":
            store.upsert_job(JobDefinition.from_dict(step["definition"]), step["now"])
        elif op == "insertRun":
            store.insert_run(Run.from_dict(step["run"]))
        elif op == "updateRun":
            store.update_run(Run.from_dict(step["run"]))
        elif op == "setState":
            store.set_state(JobState.from_dict(step["state"]))
        elif op == "deleteJob":
            store.delete_job(step["name"])
        elif op == "prune":
            pruned.append(store.prune(step["before"]))
        else:
            raise AssertionError(f"unknown op {op}")
    return {"pruned": pruned}


def python_read(store: SqliteStore) -> str:
    """What node_store.mjs `read` prints, from the Python store, in the same key order."""

    def d(value: Any) -> Any:
        return value.to_dict() if value is not None else None

    out: dict[str, Any] = {"jobs": [j.to_dict() for j in store.list_jobs()], "job": {}, "runs": {}, "limited": {}, "last": {}, "state": {}}
    for name in FIXTURE["read"]["jobs"]:
        out["job"][name] = d(store.get_job(name))
        out["runs"][name] = [r.to_dict() for r in store.list_runs(name, 100)]
        out["limited"][name] = [r.to_dict() for r in store.list_runs(name, 1)]
        out["last"][name] = d(store.last_run(name))
        out["state"][name] = d(store.get_state(name))
    out["running"] = [r.to_dict() for r in store.running_runs()]
    out["run"] = {run_id: d(store.get_run(run_id)) for run_id in FIXTURE["read"]["runs"]}
    return _js.dumps(out)


def raw_rows(file: Path, prefix: str) -> dict[str, list[Any]]:
    """Every row of the three tables, with each value's SQLite type, JSON columns as the text the database holds."""
    db = sqlite3.connect(file)
    try:
        typed = lambda column: f"{column}, typeof({column})"  # noqa: E731
        runs_columns = ", ".join(typed(c) for c in ("id", "job", "status", "started_at", "finished_at", "duration_ms", "error", "output", "metrics", "trigger"))
        return {
            "jobs": db.execute(f"SELECT {typed('name')}, {typed('definition')}, {typed('created_at')}, {typed('updated_at')} FROM {prefix}jobs ORDER BY created_at, name").fetchall(),
            "runs": db.execute(f"SELECT rowid, {runs_columns} FROM {prefix}runs ORDER BY rowid").fetchall(),
            "state": db.execute(f"SELECT {typed('job')}, {typed('state')} FROM {prefix}state ORDER BY job").fetchall(),
        }
    finally:
        db.close()


def schema_of(file: Path, prefix: str) -> list[Any]:
    db = sqlite3.connect(file)
    try:
        rows = db.execute("SELECT type, name, tbl_name, sql FROM sqlite_master WHERE name LIKE ? ORDER BY name", [f"{prefix}%"]).fetchall()
    finally:
        db.close()
    return [tuple(str(v).replace(prefix, "PREFIX_") for v in row) for row in rows]


def test_python_reads_what_node_wrote(tmp_path: Path) -> None:
    file = tmp_path / "shared.db"
    written = node_write(file, "cw_")
    assert written["pruned"] == [1]
    store = SqliteStore(file, prefix="cw_")
    node_view = node("read", file, "cw_", str(FIXTURE_PATH))
    assert "never stored" not in node_view
    assert python_read(store) == node_view
    store.close()


def test_node_reads_what_python_wrote_and_the_rows_are_the_same(tmp_path: Path) -> None:
    node_file = tmp_path / "node.db"
    python_file = tmp_path / "python.db"
    written = node_write(node_file, "cw_")
    store = SqliteStore(python_file, prefix="cw_")
    assert python_write(store) == written
    store.close()
    assert node("read", python_file, "cw_", str(FIXTURE_PATH)) == node("read", node_file, "cw_", str(FIXTURE_PATH)), "Node reads Python's rows as it reads its own"
    assert raw_rows(python_file, "cw_") == raw_rows(node_file, "cw_"), "the same bytes, and the same types, in every column"


def test_the_tables_are_the_same_whoever_creates_them(tmp_path: Path) -> None:
    file = tmp_path / "both.db"
    node_write(file, "node_")
    store = SqliteStore(file, prefix="py_")
    store.init()
    store.close()
    assert schema_of(file, "py_") == schema_of(file, "node_")


def test_node_carries_on_from_python_and_python_from_node(tmp_path: Path) -> None:
    file = tmp_path / "shared.db"
    node_write(file, "cw_")
    store = SqliteStore(file, prefix="cw_")
    # A Python client finishes a run of a job Node wrote, and checks every job.
    clock = Clock(1_767_606_100_000)
    capture = Capture()
    client = Cronwatch(store=store, now=clock.now, alerts=[capture], cron_secret=None)
    client.job("every-5", schedule="every 5m", timeout="2m", max_duration="90s").run(lambda ctx: ctx.log("from python"))
    clock.advance(10 * MIN)
    result = client.check()
    assert "nightly-report" in [j.name for j in result.jobs]
    assert store.last_run("every-5").output == "from python"
    node_view = json.loads(node("read", file, "cw_", str(FIXTURE_PATH)))
    assert node_view["last"]["every-5"]["output"] == "from python"
    assert list(node_view["state"]["every-5"].keys()) == list(store.get_state("every-5").to_dict().keys())
    assert _js.dumps(node_view) == python_read(store)

    # And Node takes a turn on the same file: Python reads its run and state.
    clock.advance(10 * MIN)
    node_run = json.loads(node("run", file, "cw_", str(clock.now())))
    assert "every-5" in node_run["jobs"]
    assert store.last_run("every-5").output == "from node"
    assert _js.dumps(json.loads(node("read", file, "cw_", str(FIXTURE_PATH)))) == python_read(store)
    again = client.check()
    assert "every-5" in [j.name for j in again.jobs]
    store.close()


def test_node_and_python_take_turns_on_one_jobs_state_version(tmp_path: Path) -> None:
    file = tmp_path / "versions.db"
    store = SqliteStore(file, prefix="cw_")
    store.init()

    def v(version: int, failures: int, job: str = "v") -> JobState:
        return JobState(job=job, consecutive_failures=failures, version=version)

    def node_cas(state: JobState, expected: int) -> Any:
        return json.loads(node("cas", file, "cw_", _js.dumps(state.to_dict()), str(expected)))

    assert store.compare_and_set_state(v(1, 1), 0), "Python writes the first version"
    assert node_cas(v(1, 9), 0)["written"] is False, "Node's write from before it is refused"
    fresh = node_cas(v(2, 2), 1)
    assert fresh["written"] is True
    assert fresh["state"]["version"] == 2
    assert not store.compare_and_set_state(v(2, 7), 1), "Python's stale write is refused"
    assert store.compare_and_set_state(v(3, 3), 2)
    late = node_cas(v(3, 0), 2)
    assert [late["written"], late["state"]["version"], late["state"]["consecutiveFailures"]] == [False, 3, 3], "Node reads Python's version"
    assert _js.dumps(late["state"]) == _js.dumps(store.get_state("v").to_dict())

    # State written before versions existed counts as 0 for both.
    store.set_state(JobState(job="old", consecutive_failures=4))
    assert node_cas(v(1, 5, job="old"), 0)["written"] is True
    assert store.get_state("old").version == 1
    store.close()
