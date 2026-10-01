"""Replays every case in conformance/ (written by scripts/conformance.mjs from
the TypeScript SDK): the core, the store scripts against every store, each
channel's requests and errors, and the pg_cron source's pure parts. Values
are compared as the JSON the SDK would write, so key order and number
formatting count too. triage.json is replayed by test_triage.py."""

from __future__ import annotations

import hashlib
import json
import math
import re
import threading
import urllib.parse
from pathlib import Path
from typing import Any

import pytest

from cronwatch import Cronwatch, _js, alerts, duration, evaluate, output, schedule, serialize
from cronwatch.alerts import discord, twilio, webhook
from cronwatch.alerts._shared import error_body
from cronwatch.alerts.email import compose as compose_email
from cronwatch.format import compose_alert
from cronwatch.sources import pgcron
from cronwatch.job import RunRecorder
from cronwatch.stores import MemoryStore, SqliteStore
from cronwatch.types import Alert, AlertDraft, JobDefinition, JobState, Run, StoredJob, snake

from helpers import NO_PG, PG, T0, drop_pg_tables, pg_prefix

DIR = Path(__file__).resolve().parents[3] / "conformance"


def fixture(name: str) -> dict[str, Any]:
    return json.loads((DIR / name).read_text("utf-8"))


def decode(value: Any) -> Any:
    """JSON has no NaN or Infinity; the fixtures write them as {"special": "NaN"}."""
    if isinstance(value, dict) and "special" in value:
        return {"NaN": math.nan, "Infinity": math.inf, "-Infinity": -math.inf}[value["special"]]
    return value


def as_json(value: Any) -> str:
    if isinstance(value, list):
        return "[" + ",".join(as_json(v) for v in value) + "]"
    return _js.dumps(value.to_dict() if hasattr(value, "to_dict") else value)


def each_case(cases: list[dict[str, Any]], check: Any) -> None:
    """Runs each case, collecting mismatches, so one failure lists them all."""
    failures = []
    for i, case in enumerate(cases):
        try:
            message = check(case)
        except Exception as error:  # noqa: BLE001
            message = f"raised {type(error).__name__}: {error}"
        if message:
            failures.append(f"#{i} {json.dumps(case)[:300]}\n    {message}")
    assert not failures, f"{len(failures)} of {len(cases)} cases differ:\n" + "\n".join(failures[:15])


def differs(expected: Any, actual: Any) -> str | None:
    e = expected if isinstance(expected, str) else as_json(expected)
    a = actual if isinstance(actual, str) else as_json(actual)
    return None if e == a else f"expected {e[:1500]}\n    got      {a[:1500]}"


def raises(expected: str, fn: Any) -> str | None:
    try:
        fn()
    except ValueError as error:
        return None if str(error) == expected else f"expected error {expected!r}\n    got   error {str(error)!r}"
    return f"expected an error: {expected}"


# ---------------------------------------------------------------- duration

DURATION = fixture("duration.json")


def test_duration_parse() -> None:
    def check(c: dict[str, Any]) -> str | None:
        args = [decode(c["input"])] + ([c["label"]] if "label" in c else [])
        if "error" in c:
            return raises(c["error"], lambda: duration.parse_duration(*args))
        return differs(c["ms"], duration.parse_duration(*args))

    each_case(DURATION["parse"], check)


def test_duration_format() -> None:
    each_case(DURATION["format"], lambda c: differs(c["text"], duration.format_duration(decode(c["ms"]))))


def test_duration_relative() -> None:
    each_case(DURATION["relative"], lambda c: differs(c["text"], duration.format_relative(c["at"], c["now"])))


# ---------------------------------------------------------------- schedule

SCHEDULE = fixture("schedule.json")


def test_schedule_parse() -> None:
    def check(c: dict[str, Any]) -> str | None:
        if "error" in c:
            return raises(c["error"], lambda: schedule.parse_schedule(c["schedule"], c.get("timezone")))
        return differs(c["parsed"], schedule.parse_schedule(c["schedule"], c.get("timezone")))

    each_case(SCHEDULE["parse"], check)


def _times(values: list[Any]) -> list[Any]:
    return [_js.iso(v) if v is not None else None for v in values]


def test_schedule_fires() -> None:
    def check(c: dict[str, Any]) -> str | None:
        parsed = schedule.parse_schedule(c["schedule"], c.get("timezone"))
        t = c["from"]
        fires = []
        for _ in c["fires"]:
            t = schedule.next_fire(parsed, t, None)
            fires.append(t)
            if t is None:
                break
        return differs(_times(c["fires"]), _times(fires))

    each_case(SCHEDULE["fires"], check)


def test_schedule_next_fire_across_the_autumn_clock_change() -> None:
    def check(c: dict[str, Any]) -> str | None:
        parsed = schedule.parse_schedule(c["schedule"], c.get("timezone"))
        actual = [schedule.next_fire(parsed, c["from"] + i * c["stepMs"], None) for i in range(len(c["next"]))]
        return differs(_times(c["next"]), _times(actual))

    each_case(SCHEDULE["autumn"], check)


def test_schedule_next_fire_for_intervals() -> None:
    each_case(
        SCHEDULE["nextFire"],
        lambda c: differs(c["expected"], schedule.next_fire(schedule.parse_schedule(c["schedule"]), c["from"], c["lastRunAt"])),
    )


def test_schedule_expectation() -> None:
    def check(c: dict[str, Any]) -> str | None:
        parsed = schedule.parse_schedule(c["schedule"], c.get("timezone"))
        return differs(c["expected"], schedule.expectation(parsed, c["lastRunAt"], c["registeredAt"], c["graceMs"]))

    each_case(SCHEDULE["expectation"], check)


def test_schedule_run_covers() -> None:
    each_case(SCHEDULE["runCovers"], lambda c: differs(c["expected"], schedule.run_covers(c["startedAt"], c["dueAt"], c["followingAt"])))


# ---------------------------------------------------------------- evaluate


class Sim:
    """The generator's Sim: a job's life through the pure functions, the way the client plays it."""

    def __init__(self, definition: JobDefinition, created_at: int) -> None:
        self.definition = definition
        self.stored = StoredJob(name=definition.name, definition=definition, created_at=created_at, updated_at=created_at)
        self.state = evaluate.empty_state(definition.name)
        self.runs: list[Run] = []
        self.order: dict[str, int] = {}
        self.seq = 0

    def define(self, definition: JobDefinition) -> None:
        self.definition = definition
        self.stored = StoredJob(name=self.stored.name, definition=definition, created_at=self.stored.created_at, updated_at=self.stored.updated_at)

    def silence(self, until: int | None) -> dict[str, Any]:
        self.state = self.state.copy()
        self.state.silenced_until = until
        return {"state": self.state}

    def sorted(self) -> list[Run]:
        return sorted(self.runs, key=lambda r: (-r.started_at, -self.order[r.id]))

    def settle(self, previous: JobState, evaluation: evaluate.Evaluation, now: int) -> list[Alert]:
        state, alerts = evaluation.state, evaluation.alerts
        if evaluate.is_silenced(previous, now):
            state = evaluate.mute_opens(previous, state)
            alerts = []
        self.state = state
        return [compose_alert(draft, self.definition, now) for draft in alerts]

    def start(self, run_id: str, now: int) -> dict[str, Any]:
        self.runs.append(Run(id=run_id, job=self.definition.name, status="running", started_at=now))
        self.seq += 1
        self.order[run_id] = self.seq
        self.state = evaluate.on_run_start(self.state)
        return {"state": self.state}

    def finish_run(self, run: Run, now: int) -> list[Alert]:
        history = [r.copy() for r in self.sorted() if r.id != run.id]
        previous = self.state
        return self.settle(previous, evaluate.on_run_finish(self.definition, run.copy(), previous, history, now), now)

    def finish(self, run_id: str, now: int, fields: dict[str, Any]) -> dict[str, Any]:
        run = next(r for r in self.runs if r.id == run_id)
        # As the client's conditional write (update_run_if): a run already
        # finished takes no second finish, and nothing is judged.
        if run.status in ("ok", "failed"):
            return {"alerts": [], "state": self.state, "ignored": f"was already finished as {run.status}"}
        marked_timed_out = run.status == "timeout"
        run.finished_at = now
        run.duration_ms = max(0, now - run.started_at)
        run.status = Run.from_dict({**run.to_dict(), "status": fields["status"]}).status
        run.metrics = fields.get("metrics", {})
        run.output = fields.get("output")
        run.error = fields.get("error")
        # As the client does: a check already counted this run as stuck, so a
        # late failure only updates the run; a late success is evaluated.
        if marked_timed_out and run.status != "ok":
            return {"alerts": [], "state": self.state}
        return {"alerts": self.finish_run(run, now), "state": self.state}

    def check(self, now: int) -> dict[str, Any]:
        alerts: list[Alert] = []
        running = sorted((r for r in self.runs if r.status == "running"), key=lambda r: (r.started_at, self.order[r.id]))
        for run in running:
            if not evaluate.is_stuck(self.definition, run, now):
                continue
            run.status = Run.from_dict({**run.to_dict(), "status": "timeout"}).status
            run.finished_at = now
            run.duration_ms = now - run.started_at
            run.error = f"Still running after {duration.format_duration(evaluate.timeout_ms(self.definition))}; marked as timed out"
            alerts.extend(self.finish_run(run, now))
        recent = [r.copy() for r in self.sorted()[:20]]
        previous = self.state
        evaluation = evaluate.on_check(self.definition, self.stored, recent[0] if recent else None, previous, now)
        alerts.extend(self.settle(previous, evaluation, now))
        return {
            "alerts": alerts,
            "state": self.state,
            "nextExpectedAt": evaluation.next_expected_at,
            "dueAt": evaluation.due_at,
            "summary": evaluate.summarize(self.stored, recent, self.state, evaluation.next_expected_at, now),
        }


EVALUATE = fixture("evaluate.json")


@pytest.mark.parametrize("scenario", EVALUATE["scenarios"], ids=[s["name"] for s in EVALUATE["scenarios"]])
def test_scenario(scenario: dict[str, Any]) -> None:
    sim = Sim(JobDefinition.from_dict(scenario["definition"]), scenario["createdAt"])
    for i, event in enumerate(scenario["events"]):
        op = event["op"]
        if op == "start":
            actual = sim.start(event["id"], event["at"])
        elif op == "finish":
            actual = sim.finish(event["id"], event["at"], event)
        elif op == "check":
            actual = sim.check(event["at"])
        elif op == "silence":
            actual = sim.silence(event["until"])
        elif op == "unsilence":
            actual = sim.silence(None)
        elif op == "define":
            sim.define(JobDefinition.from_dict(event["definition"]))
            continue
        else:
            raise AssertionError(f"unknown event {op}")
        for key, expected in event["expect"].items():
            assert differs(expected, actual[key]) is None, f"{scenario['name']}: event {i} ({op} at {event.get('at')}), {key}: {differs(expected, actual[key])}"


# ---------------------------------------------------------------- format

FORMAT = fixture("format.json")


def draft_from(data: dict[str, Any]) -> AlertDraft:
    alert = Alert.from_dict({**data, "job": None, "definition": {}, "title": None, "message": None, "at": None})
    return AlertDraft(type=alert.type, run=alert.run, details=alert.details)


def test_compose_alert() -> None:
    each_case(
        FORMAT["alerts"],
        lambda c: differs(c["alert"], compose_alert(draft_from(c["draft"]), JobDefinition.from_dict(c["definition"]), c["now"])),
    )


def test_format_number() -> None:
    each_case(FORMAT["numbers"], lambda c: differs(c["text"], evaluate.format_number(c["n"])))


def test_cap_output() -> None:
    def check(c: dict[str, Any]) -> str | None:
        capped = output.cap_output(c["prefix"] + c["piece"] * c["times"])
        return differs([c["length"], c["sha256"]], [_js.length16(capped), hashlib.sha256(capped.encode("utf-8")).hexdigest()])

    each_case(FORMAT["capOutput"], check)


def expect_from(value: Any) -> Any:
    if not isinstance(value, dict):
        return value
    if value.get("callable"):
        return lambda text: len(text) > 3
    flags = re.IGNORECASE if "i" in value["regex"]["flags"] else 0
    return re.compile(value["regex"]["source"], flags)


def test_to_stored() -> None:
    def check(c: dict[str, Any]) -> str | None:
        fields = {k: expect_from(v) if k == "expect" else v for k, v in c["definition"].items()}
        return differs(c["stored"], serialize.to_stored(JobDefinition(fields)))

    each_case(FORMAT["toStored"], check)


def test_check_expectation() -> None:
    each_case(FORMAT["checkExpectation"], lambda c: differs(c["result"], serialize.check_expectation(expect_from(c["expect"]), c["output"])))


# ---------------------------------------------------------------- health

HEALTH = fixture("health.json")


def state_from(data: dict[str, Any] | None) -> JobState | None:
    return JobState.from_dict(data) if data is not None else None


def run_from(data: dict[str, Any] | None) -> Run | None:
    return Run.from_dict(data) if data is not None else None


def test_job_health() -> None:
    each_case(
        HEALTH["jobHealth"],
        lambda c: differs(
            c["health"],
            str(evaluate.job_health(JobDefinition.from_dict(c["definition"]), run_from(c["lastRun"]), state_from(c["state"]), c["now"])),  # type: ignore[arg-type]
        ),
    )


def test_summarize() -> None:
    def check(c: dict[str, Any]) -> str | None:
        stored = StoredJob.from_dict(c["stored"])
        recent = [Run.from_dict(r) for r in c["recent"]]
        return differs(c["summary"], evaluate.summarize(stored, recent, state_from(c["state"]), c["nextExpectedAt"], c["now"]))  # type: ignore[arg-type]

    each_case(HEALTH["summarize"], check)


def test_percentile_and_median() -> None:
    each_case(HEALTH["percentile"], lambda c: differs(c["percentile"], evaluate.percentile(c["values"], c["p"])))
    each_case(HEALTH["median"], lambda c: differs(c["median"], evaluate.median(c["values"])))


def test_normalize_state() -> None:
    each_case(HEALTH["normalizeState"], lambda c: differs(c["normalized"], evaluate.normalize_state(state_from(c["state"]), "j")))


def test_mute_opens() -> None:
    each_case(HEALTH["muteOpens"], lambda c: differs(c["muted"], evaluate.mute_opens(state_from(c["previous"]), state_from(c["next"]))))  # type: ignore[arg-type]


def test_is_stuck() -> None:
    each_case(
        HEALTH["isStuck"],
        lambda c: differs(c["stuck"], evaluate.is_stuck(JobDefinition.from_dict(c["definition"]), Run.from_dict(c["run"]), c["now"])),
    )


def test_unevaluable_summary() -> None:
    def check(c: dict[str, Any]) -> str | None:
        stored = StoredJob.from_dict(c["stored"])
        recent = [Run.from_dict(r) for r in c["recent"]]
        return differs(c["summary"], evaluate.unevaluable_summary(stored, recent, state_from(c["state"]), c["now"]))  # type: ignore[arg-type]

    each_case(HEALTH["unevaluableSummary"], check)


def test_apply_silence() -> None:
    def check(c: dict[str, Any]) -> str | None:
        evaluation = evaluate.Evaluation(state_from(c["evaluation"]["state"]), [draft_from(a) for a in c["evaluation"]["alerts"]])  # type: ignore[arg-type]
        result = evaluate.apply_silence(state_from(c["previous"]), evaluation, c["now"])  # type: ignore[arg-type]
        return differs(c["result"], {"state": result.state.to_dict(), "alerts": [a.to_dict() for a in result.alerts]})

    each_case(HEALTH["applySilence"], check)


def test_run_duration() -> None:
    each_case(HEALTH["runDuration"], lambda c: differs(c["durationMs"], evaluate.run_duration(c["startedAt"], c["finishedAt"])))


def test_state_version() -> None:
    each_case(HEALTH["stateVersion"], lambda c: differs(c["version"], evaluate.state_version(JobState.from_dict(json.loads(c["state"])))))


def test_failure_count() -> None:
    minute = 60_000
    definition = JobDefinition.from_dict({"name": "j", "failuresBeforeAlert": 3})
    run = Run.from_dict({
        "id": "f", "job": "j", "status": "failed", "startedAt": T0 - minute, "finishedAt": T0 - minute + 1000, "durationMs": 1000,
        "error": "Error: boom", "output": None, "metrics": {}, "trigger": "run",
    })

    def check(c: dict[str, Any]) -> str | None:
        normalized = evaluate.normalize_state(JobState.from_dict(json.loads(c["state"])), "j")
        result = evaluate.on_run_finish(definition, run.copy(), normalized, [], T0)
        return differs(c["consecutiveFailures"], normalized.consecutive_failures) or differs(
            c["failed"], {"state": result.state.to_dict(), "alerts": [a.to_dict() for a in result.alerts]}
        )

    each_case(HEALTH["failureCount"], check)


def test_silence_end() -> None:
    each_case(
        HEALTH["silenceEnd"],
        lambda c: differs(c["silencedUntil"], evaluate.silence_end(c["now"], duration.parse_duration(c["duration"], "silence duration"))),
    )


DELIVERY = HEALTH["delivery"]


def test_delivery_constants_are_the_sdks() -> None:
    assert DELIVERY["maxUndelivered"] == evaluate.MAX_UNDELIVERED
    assert DELIVERY["sendLeaseMs"] == evaluate.SEND_LEASE_MS


def delivered(result: evaluate.Delivery) -> str:
    """The result as JSON with the state's keys in order. An alert's keys are
    sorted on both sides: the fixture's alerts are written by hand, in an
    order no writer of either SDK uses (compose_alert's is held by format.json)."""
    return _js.dumps({"state": result.state.to_dict(), "dropped": result.dropped})


def same_delivery(expected: Any, actual: str) -> str | None:
    def canonical(value: Any) -> Any:
        if isinstance(value, dict):
            items = sorted(value.items()) if "title" in value and "at" in value else value.items()
            return {k: canonical(v) for k, v in items}
        if isinstance(value, list):
            return [canonical(v) for v in value]
        return value

    return differs(_js.dumps(canonical(expected)), _js.dumps(canonical(json.loads(actual))))


def test_alert_key() -> None:
    each_case(DELIVERY["alertKey"], lambda c: differs(c["key"], evaluate.alert_key(Alert.from_dict(c["alert"]))))


def test_delivery_normalize_state() -> None:
    each_case(
        DELIVERY["normalizeState"],
        lambda c: same_delivery({"state": c["normalized"], "dropped": 0}, delivered(evaluate.Delivery(evaluate.normalize_state(state_from(c["state"]), "j"), 0))),
    )


def test_queue_undelivered() -> None:
    each_case(
        DELIVERY["queueUndelivered"],
        lambda c: same_delivery(c["result"], delivered(evaluate.queue_undelivered(JobState.from_dict(c["state"]), [Alert.from_dict(a) for a in c["alerts"]]))),
    )


def test_hold_alerts() -> None:
    def check(c: dict[str, Any]) -> str | None:
        alerts_ = [Alert.from_dict(a) for a in c["alerts"]]
        return same_delivery(c["result"], delivered(evaluate.hold_alerts(JobState.from_dict(c["state"]), alerts_, c["until"], c["deferred"])))

    each_case(DELIVERY["holdAlerts"], check)


def test_release_sending() -> None:
    each_case(DELIVERY["releaseSending"], lambda c: same_delivery(c["result"], delivered(evaluate.release_sending(JobState.from_dict(c["state"]), c["now"]))))


def test_record_sent() -> None:
    def check(c: dict[str, Any]) -> str | None:
        lists = [[Alert.from_dict(a) for a in c[key]] for key in ("delivered", "failed", "stale")]
        return same_delivery(c["result"], delivered(evaluate.record_sent(JobState.from_dict(c["state"]), *lists, c["now"])))

    each_case(DELIVERY["recordSent"], check)


def test_stale_alert() -> None:
    each_case(HEALTH["staleAlert"], lambda c: differs(c["stale"], evaluate.stale_alert(Alert.from_dict(c["alert"]), state_from(c["state"]))))  # type: ignore[arg-type]


# ---------------------------------------------------------------- output

OUTPUT = fixture("output.json")


def expand(spec: Any) -> Any:
    """Long text travels as {"parts": [[piece, times], ...]}."""
    if isinstance(spec, dict) and "parts" in spec:
        return "".join(piece * times for piece, times in spec["parts"])
    return spec


def digest(text: str | None) -> dict[str, Any] | None:
    """A result as the fixtures hold it: the text, or when long its length in UTF-16 code units and SHA-256."""
    if text is None:
        return None
    length = _js.length16(text)
    return {"text": text} if length <= 400 else {"length": length, "sha256": hashlib.sha256(text.encode("utf-8")).hexdigest()}


def test_output_cap_is_the_sdks() -> None:
    assert OUTPUT["outputCap"] == output.OUTPUT_CAP


def test_redact_secrets() -> None:
    each_case(OUTPUT["redact"], lambda c: differs(c["result"], digest(output.redact_secrets(expand(c["input"])))))


def test_redact_and_cap() -> None:
    assert OUTPUT["redactEdge"] == output.REDACT_EDGE
    each_case(OUTPUT["redactAndCap"], lambda c: differs(c["result"], digest(output.redact_and_cap(expand(c["input"]), output.redact_secrets))))


def test_error_message(monkeypatch: pytest.MonkeyPatch) -> None:
    frames: dict[int, list[str]] = {}
    monkeypatch.setattr(output, "_frames", lambda error: frames.get(id(error), []))

    def check(c: dict[str, Any]) -> str | None:
        if "value" in c:
            error: Any = expand(c["value"])
        else:
            kind = type(c["name"], (Exception,), {})
            error = kind(expand(c["message"]))
            frames[id(error)] = c["frames"]
        return differs(c["result"], digest(output.error_message(error)))

    each_case(OUTPUT["errorMessage"], check)


def expand_lines(lines: list[Any]) -> list[str]:
    out = []
    for line in lines:
        if isinstance(line, dict) and "numbered" in line:
            for i in range(line["count"]):
                head = f"{line['numbered']}{i} "
                out.append(head + "x" * max(0, line["width"] - _js.length16(head)))
        else:
            out.append(expand(line))
    return out


def test_expect_text() -> None:
    def check(c: dict[str, Any]) -> str | None:
        recorder = RunRecorder(Run(id="r", job="j", status="running", started_at=T0), 60_000)
        for line in expand_lines(c["lines"]):
            recorder.context.log(line)
        text = recorder.expect_text()
        checks = [{"expect": k["expect"], "result": serialize.check_expectation(k["expect"], text)} for k in c["checks"]]
        return differs([c["expectText"], c["output"], c["checks"]], [digest(text), digest(recorder.output()), checks])

    each_case(OUTPUT["expectText"], check)


# ---------------------------------------------------------------- store

STORE = fixture("store.json")


STORES = ["memory", "sqlite", pytest.param("postgres", marks=pytest.mark.skipif(not PG, reason=NO_PG))]
_pg_prefixes: list[str] = []


@pytest.fixture(autouse=True)
def _drop_pg_tables() -> Any:
    yield
    while _pg_prefixes:
        drop_pg_tables(_pg_prefixes.pop())


def make_store(kind: str, tmp_path: Path) -> Any:
    if kind == "memory":
        return MemoryStore()
    if kind == "postgres":
        from cronwatch.stores.postgres import PostgresStore

        prefix = pg_prefix("c")
        _pg_prefixes.append(prefix)
        store: Any = PostgresStore(PG, prefix=prefix)
    else:
        store = SqliteStore(tmp_path / f"conformance-{len(list(tmp_path.iterdir()))}.db")
    store.init()
    return store


@pytest.mark.parametrize("kind", STORES)
def test_store_prune(kind: str, tmp_path: Path) -> None:
    def check(c: dict[str, Any]) -> str | None:
        store = make_store(kind, tmp_path)
        mismatch = None
        for event in c["events"]:
            if "insert" in event:
                for run in event["insert"]:
                    store.insert_run(Run.from_dict(run))
            else:
                pruned = store.prune(event["prune"])
                remaining = {job: [r.id for r in store.list_runs(job, 100)] for job in event["remaining"]}
                mismatch = mismatch or differs([event["pruned"], event["remaining"]], [pruned, remaining])
        store.close()
        return mismatch

    each_case(STORE["prune"], check)


@pytest.mark.parametrize("kind", STORES)
def test_store_compare_and_set_state(kind: str, tmp_path: Path) -> None:
    store = make_store(kind, tmp_path)

    def check(c: dict[str, Any]) -> str | None:
        written = None
        if "cas" in c:
            written = store.compare_and_set_state(JobState.from_dict(c["cas"]), c["expected"])
        elif "set" in c:
            store.set_state(JobState.from_dict(c["set"]))
        else:
            store.delete_job(c["forget"])
        states = {job: (s.to_dict() if (s := store.get_state(job)) else None) for job in ("a", "b")}
        actual = {"written": written, "states": states} if "written" in c else {"states": states}
        expected = {"written": c["written"], "states": c["states"]} if "written" in c else {"states": c["states"]}
        return differs(expected, actual)

    each_case(STORE["compareAndSetState"], check)
    store.close()


@pytest.mark.parametrize("kind", STORES)
def test_store_update_run_if(kind: str, tmp_path: Path) -> None:
    store = make_store(kind, tmp_path)
    store.insert_run(Run(id="u1", job="a", status="running", started_at=1000))

    def check(c: dict[str, Any]) -> str | None:
        outcome: Any = None
        if "set" in c:
            store.update_run(Run.from_dict(c["set"]))
        elif "insert" in c:
            try:
                store.insert_run(Run.from_dict(c["insert"]))
                outcome = "inserted"
            except Exception:  # noqa: BLE001
                outcome = "refused"
        else:
            outcome = store.update_run_if(Run.from_dict(c["run"]), c["from"])
        stored = store.get_run("u1")
        expected = [c.get("outcome"), c["stored"]]
        return differs(expected, [outcome, stored.to_dict() if stored else None])

    each_case(STORE["updateRunIf"], check)
    store.close()


def write_raw_state(store: Any, text: str) -> None:
    """A state row as another process wrote it: the JSON text as it is."""
    if isinstance(store, MemoryStore):
        store.set_state(JobState.from_dict(json.loads(text)))
    elif isinstance(store, SqliteStore):
        store._run(f"INSERT INTO {store.prefix}state (job, state) VALUES ('v', ?)", [text])
    else:
        store._execute(f"INSERT INTO {store.prefix}state (job, state) VALUES ('v', $1::jsonb)", [text])


@pytest.mark.parametrize("kind", STORES)
def test_store_foreign_version(kind: str, tmp_path: Path) -> None:
    store = make_store(kind, tmp_path)

    def check(c: dict[str, Any]) -> str | None:
        store.delete_job("v")
        write_raw_state(store, c["stored"])
        for step in c["steps"]:
            written = store.compare_and_set_state(JobState.from_dict(step["cas"]), step["expected"])
            if written != step["written"]:
                return f"expecting {step['expected']}: wrote {written}"
            if "state" in step and (mismatch := differs(step["state"], store.get_state("v"))):
                return mismatch
        return None

    each_case(STORE["foreignVersion"], check)


@pytest.mark.parametrize("kind", STORES)
def test_store_nul(kind: str, tmp_path: Path) -> None:
    """Text is written without U+0000, which Postgres refuses."""
    store = make_store(kind, tmp_path)

    def check(c: dict[str, Any]) -> str | None:
        written: Any = None
        if "upsertJob" in c:
            store.upsert_job(JobDefinition.from_dict(c["upsertJob"]), c["now"])
            stored: Any = store.get_job("nul")
        elif "insertRun" in c:
            store.insert_run(Run.from_dict(c["insertRun"]))
            stored = store.get_run("n1")
        elif "updateRun" in c:
            store.update_run(Run.from_dict(c["updateRun"]))
            stored = store.get_run("n1")
        elif "updateRunIf" in c:
            written = store.update_run_if(Run.from_dict(c["updateRunIf"]), c["from"])
            stored = store.get_run("n1")
        elif "setState" in c:
            store.set_state(JobState.from_dict(c["setState"]))
            stored = store.get_state("nul")
        else:
            written = store.compare_and_set_state(JobState.from_dict(c["compareAndSetState"]), c["expected"])
            stored = store.get_state("nul")
        # Postgres hands JSONB back with its keys in its own order.
        expected = json.dumps([c.get("written"), c["stored"]], sort_keys=True)
        return differs(expected, json.dumps([written, stored.to_dict() if stored else None], sort_keys=True))

    each_case(STORE["nul"], check)
    store.close()
    store.close()


# ---------------------------------------------------------------- channels

CHANNELS = fixture("channels.json")
CHANNEL_ALERTS = {a["name"]: a["alert"] for a in CHANNELS["alerts"]}


class FakeHTTP:
    """Stands in for urllib, keeping every request."""

    def __init__(self, status: int = 200, body: str = "") -> None:
        self.status = status
        self.body = body
        self.requests: list[dict[str, Any]] = []
        self._lock = threading.Lock()

    def post(self, url: str, body: str, headers: dict[str, str]) -> alerts.Response:
        with self._lock:
            self.requests.append({"url": url, "headers": dict(headers), "body": body})
        return alerts.Response(self.status, self.body)


PROVIDERS: dict[str, Any] = {
    "resend": alerts.Resend,
    "postmark": alerts.Postmark,
    "sendgrid": alerts.Sendgrid,
    "mailgun": alerts.Mailgun,
    "ses": alerts.Ses,
    "twilio": alerts.Twilio,
    "sentry": alerts.Sentry,
    "honeybadger": alerts.Honeybadger,
    "datadog": alerts.Datadog,
    "rollbar": alerts.Rollbar,
    "bugsnag": alerts.Bugsnag,
    "newrelic": alerts.NewRelic,
}


def link(alert: Alert) -> str:
    return f"https://app.example/cronwatch/jobs/{alert.job}"


def channel_for(c: dict[str, Any], http: Any) -> Any:
    """The fixture's options, camelCase, as the Python keywords: `link: true`
    stands for the usual link and `now: <ms>` for a clock fixed at that time."""
    options = c["options"]
    given = link if options.get("link") else None
    if c["channel"] == "slack":
        return alerts.Slack(webhook_url=options["webhookUrl"], link=given, http=http)
    if c["channel"] == "discord":
        return alerts.Discord(webhook_url=options["webhookUrl"], link=given, http=http)
    if c["channel"] == "webhook":
        return alerts.Webhook(options["url"], headers=options.get("headers"), secret=options.get("secret"), http=http)
    keywords: dict[str, Any] = {}
    for key, value in options.items():
        if key == "link":
            if value:
                keywords["link"] = link
        elif key == "now":
            keywords["now"] = lambda value=value: value
        elif key == "from":
            keywords["from_"] = value
        else:
            keywords[snake(key)] = value
    return PROVIDERS[c["channel"]](**keywords, http=http)


def in_number_order(requests: list[dict[str, Any]], to: Any) -> list[dict[str, Any]]:
    """Twilio texts every number at once, each from a thread of its own, so the
    requests arrive in whatever order the threads run; the SDK's fetch calls
    are made in the numbers' order. Compared in that order."""
    numbers = [n.strip() for n in (to if isinstance(to, list) else [to])]
    return sorted(requests, key=lambda r: numbers.index(urllib.parse.parse_qs(r["body"])["To"][0]))


def test_channel_payloads() -> None:
    def check(c: dict[str, Any]) -> str | None:
        http = FakeHTTP()
        channel_for(c, http).send(Alert.from_dict(CHANNEL_ALERTS[c["alert"]]))
        request = http.requests[-1]
        return differs([c["url"], c["headers"], c["body"]], [request["url"], request["headers"], digest(request["body"])])

    each_case(CHANNELS["sends"], check)


def test_webhook_payloads() -> None:
    """The webhook's whole body, "schema": 1 first, and its signature, byte for byte."""

    def check(c: dict[str, Any]) -> str | None:
        http = FakeHTTP()
        alerts.Webhook("https://hooks.example.com/cw", secret=c["secret"], http=http).send(Alert.from_dict(CHANNEL_ALERTS[c["alert"]]))
        request = http.requests[-1]
        mine = webhook.signature(c["secret"], request["body"])
        return differs([c["body"], c["signature"], c["signature"]], [request["body"], request["headers"]["x-cronwatch-signature"], f"sha256={mine}"])

    assert len(CHANNELS["webhookPayloads"]) == 15
    each_case(CHANNELS["webhookPayloads"], check)


def test_channel_failures() -> None:
    first = CHANNELS["alerts"][0]["alert"]

    def check(c: dict[str, Any]) -> str | None:
        try:
            channel_for(c, FakeHTTP(c["status"], c["body"])).send(Alert.from_dict(first))
        except RuntimeError as error:
            return differs(c["error"], str(error))
        return f"expected an error: {c['error']}"

    each_case(CHANNELS["failures"], check)


def test_provider_payloads() -> None:
    def check(c: dict[str, Any]) -> str | None:
        http = FakeHTTP()
        channel_for(c, http).send(Alert.from_dict(CHANNEL_ALERTS[c["alert"]]))
        sent = in_number_order(http.requests, c["options"]["to"]) if c["channel"] == "twilio" else http.requests
        requests = [{"url": r["url"], "headers": r["headers"], "body": digest(r["body"])} for r in sent]
        return differs(c["requests"], requests)

    each_case(CHANNELS["providerSends"], check)


def test_provider_failures() -> None:
    first = CHANNELS["alerts"][0]["alert"]

    def check(c: dict[str, Any]) -> str | None:
        try:
            channel_for(c, FakeHTTP(c["status"], c["body"])).send(Alert.from_dict(first))
        except RuntimeError as error:
            return differs(str(c["error"]), str(error))
        return None if c["error"] is None else f"expected an error: {c['error']}"

    each_case(CHANNELS["providerFailures"], check)


def test_provider_cases_cover_every_channel() -> None:
    assert sorted({c["channel"] for c in CHANNELS["providerSends"]}) == sorted(PROVIDERS)
    assert len(CHANNELS["providerSends"]) >= 288


class NumberedHTTP:
    """Answers each Twilio number with its own status, as twilioPartialCases does."""

    def __init__(self, numbers: list[str], statuses: list[int]) -> None:
        self.answers = dict(zip(numbers, statuses, strict=True))
        self.requests: list[dict[str, str]] = []
        self._lock = threading.Lock()

    def post(self, url: str, body: str, headers: dict[str, str]) -> alerts.Response:
        to = urllib.parse.parse_qs(body)["To"][0]
        with self._lock:
            self.requests.append({"url": url, "to": to})
        status = self.answers[to]
        return alerts.Response(status, "{}" if status < 400 else f'{{"message":"refused {to} with tw-secret"}}')


def test_twilio_partial_delivery() -> None:
    """Each number refusing is reported through the channel context; the alert
    fails only when every number refused it. The SDK also records fetch's
    redirect: "error"; urllib is told never to follow one, so there is no
    option to compare."""
    partial = CHANNELS["twilioPartial"]
    options = partial["options"]
    alert = Alert.from_dict(CHANNELS["alerts"][0]["alert"])

    def check(c: dict[str, Any]) -> str | None:
        http = NumberedHTTP(options["to"], c["statuses"])
        reported: list[str] = []
        context = alerts.ChannelContext(lambda e: reported.append(str(e)))
        channel = alerts.Twilio(account_sid=options["accountSid"], auth_token=options["authToken"], from_=options["from"], to=options["to"], http=http)
        error = None
        try:
            channel.send(alert, context)
        except RuntimeError as e:
            error = str(e)
        requests = sorted(http.requests, key=lambda r: options["to"].index(r["to"]))
        expected = [[{"url": r["url"], "to": r["to"]} for r in c["requests"]], c["error"], c["reported"]]
        return differs(expected, [requests, error, reported])

    each_case(partial["cases"], check)


TEXT_CUTS = CHANNELS["textCuts"]


def test_error_bodies_cut_secrets_out_first() -> None:
    each_case(TEXT_CUTS["errorBodies"], lambda c: differs(c["body"], error_body(c["text"], c["secrets"])))


def test_email_subjects_cut_on_a_code_point() -> None:
    first = CHANNELS["alerts"][0]["alert"]

    def check(c: dict[str, Any]) -> str | None:
        alert = Alert.from_dict({**first, "title": c["title"]})
        return differs(c["subject"], compose_email(alert, from_="a@example.com", to=["b@example.com"], subject_prefix=c["subjectPrefix"]).subject)

    each_case(TEXT_CUTS["subjects"], check)


def test_discord_descriptions() -> None:
    first = CHANNELS["alerts"][0]["alert"]

    def check(c: dict[str, Any]) -> str | None:
        alert = Alert.from_dict({**first, "message": expand(c["message"]), "triage": expand(c["triage"])})
        return differs(c["description"], digest(discord.embed_description(alert)))

    each_case(TEXT_CUTS["discordDescriptions"], check)


def test_sms_segments() -> None:
    each_case(TEXT_CUTS["smsSegments"], lambda c: differs(c["segments"], twilio.sms_segments(c["text"])))


def test_sms_bodies() -> None:
    long = Alert.from_dict({**CHANNELS["alerts"][0]["alert"], "title": "nightly failed", "message": ("a" * 152 + "{\n") * 12, "triage": None})

    def check(c: dict[str, Any]) -> str | None:
        link_ = f"https://app.example/{'p' * 2000}" if c.get("link") == "long" else "https://app.example/j"
        segments = math.nan if c["segments"] is None else c["segments"]
        return differs(c["body"], digest(twilio.sms_body(long, link_, segments)))

    each_case(TEXT_CUTS["smsBodies"], check)


# ---------------------------------------------------------------- pg_cron

PGCRON = fixture("pgcron.json")


def test_pg_cron_hold_is_the_sdks() -> None:
    assert PGCRON["holdMs"] == pgcron.HOLD_MS


def test_pg_cron_schedules() -> None:
    each_case(PGCRON["schedules"], lambda c: differs(c["result"], pgcron.schedule(c["schedule"])))


def test_pg_cron_names() -> None:
    each_case(PGCRON["names"], lambda c: differs(c["name"], pgcron.job_name(pgcron.Job(jobid=c["job"]["jobid"], jobname=c["job"]["jobname"]))))


def test_pg_cron_rows_as_runs() -> None:
    def check(c: dict[str, Any]) -> str | None:
        run = pgcron.run(c["row"], "db:j", "pgcron:db:", c["fallbackAt"] if c["fallbackAt"] is not None else T0)
        return differs(c["run"], run)

    each_case(PGCRON["runs"], check)


# ---------------------------------------------------------------- client

CLIENT = fixture("client.json")


def test_client_run_ids() -> None:
    """start, resume and record_run hold run ids to 1 to 200 UTF-16 units, each with its own error."""

    def check(c: dict[str, Any]) -> str | None:
        cw = Cronwatch(store=MemoryStore(), alerts=[], cron_secret=None, now=lambda: T0)
        job = cw.job("j")
        method = c["method"]

        def call() -> None:
            if method == "start":
                job.start(id=c["id"]).finish()
            elif method == "resume":
                job.resume(c["id"])
            else:
                cw.record_run({"id": c["id"], "job": "j", "status": "ok", "startedAt": T0 - 1000, "finishedAt": T0, "durationMs": 1000, "error": None, "output": None, "metrics": {}, "trigger": "run"})

        try:
            if "error" in c:
                # The port's own spelling of the method, as its NUL message already has it.
                return raises(c["error"].replace("recordRun:", "record_run:"), call)
            call()
            return None
        finally:
            cw.close()

    each_case(CLIENT["runIds"], check)


def canonical(value: Any) -> str:
    """JSON with sorted keys: the fixture compares objects as values, not by key order."""
    return json.dumps(json.loads(as_json(value)), sort_keys=True)


@pytest.mark.parametrize("kind", STORES)
def test_client_unknown_fields(kind: str, tmp_path: Path) -> None:
    """What a newer release wrote (a state or definition key, a run status, a
    trigger, an open condition) survives a check, a silence, an unsilence, a
    summary and a run, over each store."""
    unknown = CLIENT["unknownFields"]
    seed = unknown["seed"]
    store = make_store(kind, tmp_path)
    store.upsert_job(JobDefinition.from_dict(seed["definition"]), seed["createdAt"])
    for run in seed["runs"]:
        store.insert_run(Run.from_dict(run))
    store.set_state(JobState.from_dict(seed["state"]))
    clock = {"now": 0}
    sent: list[Alert] = []
    errors: list[str] = []
    cw = Cronwatch(
        store=store,
        now=lambda: clock["now"],
        cron_secret=None,
        alerts=[alerts.Custom("capture", sent.append)],
        on_error=lambda error, where: errors.append(f"{where}: {error}"),
    )
    try:
        for step in unknown["steps"]:
            clock["now"] = step["at"] if "at" in step else clock["now"]
            op = step["op"]
            if op == "check":
                cw.check()
            elif op == "silence":
                cw.silence("keep", step["for"])
            elif op == "unsilence":
                cw.unsilence("keep")
            elif op == "summary":
                summary = cw.job_summary("keep")
                assert summary is not None
                got = summary.to_dict()
                # `open` follows the stored state's key order, which Postgres's JSONB does not keep: compared as a set.
                assert canonical({**got, "open": sorted(got["open"])}) == canonical({**step["summary"], "open": sorted(step["summary"]["open"])}), op
            elif op == "declareAndRun":
                clock["now"] = step["startedAt"]
                handle = cw.job("keep", **{snake(k): v for k, v in step["declared"].items()}).start(id=step["id"])
                clock["now"] = step["finishedAt"]
                handle.finish(step["output"])
            else:
                raise AssertionError(f"unknown step {op}")
            got_job = store.get_job("keep")
            got_state = store.get_state("keep")
            assert got_job is not None and got_state is not None
            snapshot = {
                "job": got_job.to_dict(),
                "state": got_state.to_dict(),
                "runs": [r.to_dict() for r in store.list_runs("keep", 10)],
                "alerts": [a.to_dict() for a in sent],
                "errors": list(errors),
            }
            sent.clear()
            errors.clear()
            assert canonical(snapshot) == canonical(step["expect"]), op
    finally:
        cw.close()


# ---------------------------------------------------------------- every fixture

# triage.json is replayed by test_triage.py, which needs the anthropic package's shapes.
ELSEWHERE = {"triage.json"}


def test_every_fixture_is_replayed() -> None:
    replayed = {"client.json", "duration.json", "schedule.json", "evaluate.json", "format.json", "health.json", "output.json", "store.json", "channels.json", "pgcron.json"}
    assert {p.name for p in DIR.glob("*.json")} == replayed | ELSEWHERE
