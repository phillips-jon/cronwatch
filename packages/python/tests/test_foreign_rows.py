"""Rows a foreign, hand-edited or damaged writer could leave (conformance
store.json foreignRows, written by the TypeScript SDK): each is read
leniently, and one affects only its own job (the SDK's stores.test.ts)."""

from __future__ import annotations

import json
import sqlite3
from pathlib import Path
from typing import Any

from cronwatch import Cronwatch
from cronwatch._evaluate import normalize_state
from cronwatch._serialize import read_stored_job
from cronwatch.stores import SqliteStore

from helpers import Capture, Errors, send

FOREIGN = json.loads((Path(__file__).resolve().parents[3] / "conformance" / "store.json").read_text("utf-8"))["foreignRows"]


def insert(db: sqlite3.Connection, table: str, row: dict[str, Any]) -> None:
    keys = list(row)
    db.execute(f"INSERT INTO cronwatch_{table} ({', '.join(keys)}) VALUES ({', '.join('?' for _ in keys)})", [row[k] for k in keys])
    db.commit()


def fresh() -> tuple[sqlite3.Connection, SqliteStore]:
    db = sqlite3.connect(":memory:", check_same_thread=False)
    store = SqliteStore(connection=db)
    store.init()
    return db, store


def test_each_foreign_row_reads_leniently() -> None:
    failures = []
    for case in FOREIGN["rows"]:
        db, store = fresh()
        insert(db, case["table"], case["row"])
        row = case["row"]
        if case["table"] == "jobs":
            job, readable = read_stored_job(store.get_job(row["name"]))
            listed = [read_stored_job(j)[0].to_dict() for j in store.list_jobs()]
            got: Any = (job.to_dict(), readable, listed)
            want: Any = (case["read"], case["readable"], [case["read"]])
        elif case["table"] == "runs":
            got = (store.get_run(row["id"]).to_dict(), [r.to_dict() for r in store.list_runs(row["job"], 10)])
            want = (case["read"], [case["read"]])
        else:
            got = normalize_state(store.get_state(row["job"]), row["job"]).to_dict()
            want = case["read"]
        if got != want:
            failures.append(f"{case['table']} {json.dumps(row)[:200]}\n  want {want}\n  got  {got}")
        db.close()
    assert not failures, "\n".join(failures)


def test_a_check_a_silence_and_every_page_over_foreign_rows() -> None:
    c = FOREIGN["check"]
    db, store = fresh()
    jobs = [r["row"] for r in FOREIGN["rows"] if r["table"] == "jobs"] + c["extraJobs"]
    for row in jobs:
        insert(db, "jobs", row)
    for row in [r["row"] for r in FOREIGN["rows"] if r["table"] == "runs"] + c["extraRuns"]:
        insert(db, "runs", row)
    for row in [r["row"] for r in FOREIGN["rows"] if r["table"] == "state"]:
        insert(db, "state", row)
    names = [j["name"] for j in jobs]
    errors = Errors()

    def reported() -> list[str]:
        wheres = [where for _, where in errors.items]
        errors.items.clear()
        return sorted({next((n for n in names if w.endswith(f" {n}")), w) for w in wheres})

    sent = Capture()
    cw = Cronwatch(store=store, now=lambda: c["now"], cron_secret=None, alerts=[sent], on_error=errors)
    result = cw.check()
    assert reported() == c["reported"]
    assert [{"type": str(a.type), "job": a.job, "at": a.at} for a in sent.alerts] == c["alerts"]
    assert {j.name: str(j.health) for j in result.jobs} == c["health"]

    cw.silence(c["silence"]["job"], c["silence"]["for"])
    assert reported() == c["silence"]["reported"]
    assert store.get_state(c["silence"]["job"]).to_dict() == c["silence"]["state"]
    # The rows as stored: those never rewritten still hold the foreign values
    # (a read that changes nothing writes nothing), which get_state, typed,
    # cannot show, so the column is read as the SDK's getState returns it.
    for job, state in c["states"].items():
        (text,) = db.execute("SELECT state FROM cronwatch_state WHERE job = ?", [job]).fetchone()
        assert json.loads(text) == state, job

    web = cw.routes(token="tok", base_path="/cronwatch")
    for page in c["read"]["pages"]:
        assert send(web, "GET", page["path"], {"authorization": "Bearer tok"}).status == page["status"], page["path"]
    assert reported() == c["read"]["reported"]
    cw.close()
    db.close()


def test_a_bad_silenced_until_on_a_job_that_cannot_be_evaluated_stops_only_that_job() -> None:
    # The review's Python case: the fallback summary compared "x" with the
    # clock and raised again, which aborted the check for every job.
    db, store = fresh()
    insert(db, "jobs", {"name": "bad", "definition": '{"name":"bad","schedule":"not a schedule"}', "created_at": 0, "updated_at": 0})
    insert(db, "jobs", {"name": "fine", "definition": '{"name":"fine"}', "created_at": 0, "updated_at": 0})
    insert(db, "state", {"job": "bad", "state": '{"job":"bad","open":{},"consecutiveFailures":0,"silencedUntil":"x","lastAlertAt":null}'})
    errors = Errors()
    cw = Cronwatch(store=store, now=lambda: 1767605400000, cron_secret=None, alerts=[Capture()], on_error=errors)
    result = cw.check()
    assert {j.name: str(j.health) for j in result.jobs} == {"bad": "failing", "fine": "never_ran"}
    assert errors.wheres == ["checking bad"]
    assert [j.name for j in cw.jobs()] == ["bad", "fine"]
    db.close()


def test_a_queued_alert_whose_at_is_not_a_number_is_dropped_and_new_alerts_still_go() -> None:
    db, store = fresh()
    insert(db, "jobs", {"name": "j", "definition": '{"name":"j"}', "created_at": 0, "updated_at": 0})
    state = {
        "job": "j", "open": {}, "consecutiveFailures": 0, "silencedUntil": None, "lastAlertAt": None,
        "undelivered": [{"type": "failed", "at": "x", "run": 5}],
        "sending": [{"until": 0, "alert": {"type": "failed", "at": [1]}}],
    }
    insert(db, "state", {"job": "j", "state": json.dumps(state)})
    errors = Errors()
    sent = Capture()
    cw = Cronwatch(store=store, now=lambda: 1767605400000, cron_secret=None, alerts=[sent], on_error=errors)
    cw.check()
    assert errors.items == []
    assert store.get_state("j").undelivered == []
    try:
        cw.job("j").run(lambda _ctx: 1 / 0)
    except ZeroDivisionError:
        pass
    assert errors.items == []
    assert sent.types() == ["failed"]
    db.close()
