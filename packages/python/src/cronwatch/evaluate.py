"""Pure decisions about a job's health (evaluate.ts). Each function takes the
current state and returns the new state plus the alerts that should go out.
Nothing here touches a store or a network, which is what makes it testable."""

from __future__ import annotations

import math
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from typing import Any

from . import _js
from .duration import format_duration, parse_duration
from .schedule import expectation, next_fire, parse_schedule
from .stats import median, percentile
from .types import (
    Alert,
    AlertDraft,
    AlertType,
    Condition,
    JobDefinition,
    JobHealth,
    JobState,
    JobStats,
    JobSummary,
    Run,
    RunStatus,
    SendingAlert,
    StoredJob,
)

DEFAULT_GRACE_MS = 10 * 60_000
DEFAULT_TIMEOUT_MS = 60 * 60_000
#: Runs faster than this are never called slow, whatever the baseline says.
SLOW_FLOOR_MS = 10_000
#: How many earlier runs a baseline needs before it is trusted.
BASELINE_MIN_RUNS = 5
#: How many successful runs a baseline looks at, and how many runs a summary covers.
BASELINE_WINDOW = 20
#: The longest duration written: the largest integer JavaScript holds exactly,
#: which every port and store reads back unchanged.
MAX_DURATION_MS = 9_007_199_254_740_991


def run_duration(started_at: float, finished_at: float) -> float:
    """How long a run took, from `started_at` to `finished_at`: 0 when it
    started later, and never more than MAX_DURATION_MS. A foreign row's start
    near a 64-bit limit must not make a duration no store can write."""
    ms = finished_at - started_at
    return min(ms, MAX_DURATION_MS) if ms > 0 else 0


def silence_end(now: float, ms: float) -> int:
    """When a silence of `ms` from `now` ends: a whole millisecond, never past
    MAX_DURATION_MS (2^53 - 1), however long the silence asked for. Every port
    sharing the store reads it back unchanged, where a larger number could
    wrap to a time long past and send alerts during the silence."""
    return int(min(now + math.floor(min(ms, MAX_DURATION_MS)), MAX_DURATION_MS))


def state_version(state: JobState | None) -> int:
    """The version a stored state counts as for compare_and_set_state: its
    `version` when that is a whole number from 0 to MAX_DURATION_MS (2^53 - 1),
    else 0, as when it is absent. The SQL stores read it the same way, so a
    foreign row's 1.5, "x" or -1 is written over by the next update instead of
    refusing every compare-and-set of its job for good."""
    version = None if state is None else state.version
    if isinstance(version, bool) or not isinstance(version, (int, float)):
        return 0
    if isinstance(version, float) and not version.is_integer():
        return 0
    return int(version) if 0 <= version <= MAX_DURATION_MS else 0


def failure_count(state: JobState | None) -> int:
    """The failures in a row a stored state counts as: its
    `consecutive_failures` when that is a whole number, held at
    MAX_DURATION_MS (2^53 - 1), and 0 when it is negative or not a whole
    number. A foreign row's count past 2^53, or at a 64-bit limit, stays at
    the top, and a 1.5, "3" or -1 counts as none."""
    count = None if state is None else state.consecutive_failures
    if isinstance(count, bool) or not isinstance(count, (int, float)):
        return 0
    if isinstance(count, float) and not count.is_integer():
        return 0
    return min(int(count), MAX_DURATION_MS) if count > 0 else 0


@dataclass
class Evaluation:
    state: JobState
    alerts: list[AlertDraft]


@dataclass
class CheckEvaluation(Evaluation):
    next_expected_at: int | None
    due_at: int | None


def empty_state(job: str) -> JobState:
    return JobState(job=job, open={}, consecutive_failures=0, silenced_until=None, last_alert_at=None, pending_recovery=[], undelivered=[])


def normalize_state(state: JobState | None, job: str) -> JobState:
    """A stored state with every field present, or a fresh one. State written
    by an older version lacks the newer fields. `sending` is the exception: it
    is there only while it holds an alert (see hold_alerts)."""
    if state is None:
        return empty_state(job)
    out = state.copy()
    out.consecutive_failures = failure_count(state)
    if out.pending_recovery is None:
        out.pending_recovery = []
    if out.undelivered is None:
        out.undelivered = []
    if not isinstance(out.sending, list) or not out.sending:
        out.sending = None
    return out


def _clone_state(state: JobState) -> JobState:
    return normalize_state(state, state.job)


# ---------------------------------------------------------------- delivery

#: Alerts kept per job for retry, and per job being sent; past it the oldest go.
MAX_UNDELIVERED = 20

#: How long an alert in `sending` is left to the process sending it. Longer
#: than any send takes: at most three alerts go out together, each with 25
#: seconds of triage and 15 of channels.
SEND_LEASE_MS = 5 * 60_000


@dataclass
class Delivery:
    """A state after a delivery step, and how many alerts it let go past MAX_UNDELIVERED."""

    state: JobState
    dropped: int


def alert_key(alert: Alert) -> str:
    """Identifies an alert across retries, and in `sending`."""
    return f"{alert.type}|{_js.number(alert.at)}|{alert.run.id if alert.run else ''}"


def _newest(items: list[Any], most: int) -> tuple[list[Any], int]:
    """The newest `most` of `items`, and how many went."""
    return items[-most:], max(0, len(items) - most)


def _held_alert(entry: Any) -> bool:
    return isinstance(entry, SendingAlert) and isinstance(entry.alert, Alert)


def queue_undelivered(state: JobState, alerts: Sequence[Alert]) -> Delivery:
    """`alerts` added to the undelivered queue: one with the same key as a
    queued alert replaces it where it stands, the rest go at the end, and only
    the newest MAX_UNDELIVERED stay. `dropped` counts those let go."""
    following = _clone_state(state)
    by_key = {alert_key(a): a for a in alerts}
    queue = [by_key.get(alert_key(a), a) for a in following.undelivered or []]
    known = {alert_key(a) for a in queue}
    queue.extend(a for a in alerts if alert_key(a) not in known)
    following.undelivered, dropped = _newest(queue, MAX_UNDELIVERED)
    return Delivery(following, dropped)


def hold_alerts(state: JobState, alerts: Sequence[Alert], until: int, deferred: bool) -> Delivery:
    """The outbox. Alerts just composed are written with the state that opens
    their condition, before any is sent, so a process that stops part way
    does not lose them: into `sending`, each with its lease ending at
    `until`, when this process sends them, or (deliver="check") straight into
    the undelivered queue for a check elsewhere. `dropped` counts alerts let
    go past MAX_UNDELIVERED."""
    if not alerts:
        return Delivery(state, 0)
    if deferred:
        return queue_undelivered(state, alerts)
    following = _clone_state(state)
    kept, dropped = _newest([*(following.sending or []), *(SendingAlert(until=until, alert=a) for a in alerts)], MAX_UNDELIVERED)
    following.sending = kept
    return Delivery(following, dropped)


def release_sending(state: JobState, now: int) -> Delivery:
    """Alerts in `sending` whose lease ran out by `now`: the process sending
    them stopped before it recorded how the send went. They go to the
    undelivered queue, where the retry sends them (with triage, which is
    never stored with them here) or drops them as stale. An entry that is not
    an object with an alert is dropped; one without a numeric `until` counts
    as run out."""
    sending = state.sending or []

    def lapsed(entry: Any) -> bool:
        return not (isinstance(entry, SendingAlert) and _js.is_number(entry.until) and entry.until > now)

    gone = [e for e in sending if lapsed(e)]
    if not gone:
        return Delivery(state, 0)
    held = [e for e in sending if not lapsed(e)]
    following = state.copy()
    following.sending = held or None
    return queue_undelivered(following, [e.alert for e in gone if _held_alert(e)])


def record_sent(state: JobState, delivered: Sequence[Alert], failed: Sequence[Alert], stale: Sequence[Alert], now: int) -> Delivery:
    """How a send went. Delivered and stale alerts leave the queue; failed
    ones replace their queued copy, so a triage made on this attempt is kept,
    or join the queue. Every one of them leaves `sending`. last_alert_at moves
    only on a delivery. `dropped` counts alerts let go past MAX_UNDELIVERED."""
    following = _clone_state(state)
    done = {alert_key(a) for a in [*delivered, *stale]}
    following.undelivered = [a for a in following.undelivered or [] if alert_key(a) not in done]
    sent = {alert_key(a) for a in [*delivered, *failed, *stale]}
    held = [e for e in following.sending or [] if not (_held_alert(e) and alert_key(e.alert) in sent)]
    following.sending = held or None
    if delivered:
        following.last_alert_at = now
    return queue_undelivered(following, failed)


def _open_condition(state: JobState, condition: Condition, now: int) -> bool:
    if condition in state.open:
        return False
    state.open[condition] = now
    return True


def _close_condition(state: JobState, condition: Condition) -> bool:
    """Every open condition has alerted, so closing one owes a recovered
    message. It is remembered until a successful run leaves nothing open and
    sends it."""
    if condition not in state.open:
        return False
    del state.open[condition]
    if state.pending_recovery is None:
        state.pending_recovery = []
    if condition not in state.pending_recovery:
        state.pending_recovery.append(condition)
    return True


def open_conditions(state: JobState) -> list[Condition | str]:
    return list(state.open.keys())


def grace_ms(definition: JobDefinition) -> float:
    return DEFAULT_GRACE_MS if definition.grace is None else parse_duration(definition.grace, "grace")


def timeout_ms(definition: JobDefinition) -> float:
    return DEFAULT_TIMEOUT_MS if definition.timeout is None else parse_duration(definition.timeout, "timeout")


def slow_threshold(definition: JobDefinition, history: Sequence[Run]) -> tuple[float, str] | None:
    """Slow threshold for a successful run, as (threshold_ms, basis), or None when there is nothing to compare against yet."""
    if definition.max_duration is not None:
        return parse_duration(definition.max_duration, "maxDuration"), "maxDuration"
    durations = [r.duration_ms for r in history if r.status == RunStatus.OK and r.duration_ms is not None][:BASELINE_WINDOW]
    if len(durations) < BASELINE_MIN_RUNS:
        return None
    p95 = percentile(durations, 95)
    assert p95 is not None
    return max(2 * p95, SLOW_FLOOR_MS), f"twice the p95 of the last {len(durations)} runs ({format_duration(p95)})"


def budget_breaches(definition: JobDefinition, run: Run, history: Sequence[Run]) -> list[dict[str, Any]]:
    breaches: list[dict[str, Any]] = []
    budget = definition.budget or {}
    for metric in _js.object_keys(run.metrics):
        value = run.metrics[metric]
        ceiling = budget.get(metric) if isinstance(budget, dict) else None
        if ceiling is not None:
            if value > ceiling:
                breaches.append({"metric": metric, "value": value, "limit": ceiling, "basis": "budget"})
            continue
        past = [r.metrics[metric] for r in history if r.status == RunStatus.OK and _js.is_number(r.metrics.get(metric))][:BASELINE_WINDOW]
        if len(past) < BASELINE_MIN_RUNS:
            continue
        usual = median(past)
        assert usual is not None
        if usual > 0 and value > 3 * usual:
            breaches.append({"metric": metric, "value": value, "limit": 3 * usual, "basis": f"three times the usual {format_number(usual)}"})
    return breaches


def has_full_baseline(history: Sequence[Run]) -> bool:
    """Whether `history` (newest first) holds a full baseline window of successful runs."""
    return sum(1 for r in history if r.status == RunStatus.OK) >= BASELINE_WINDOW


def format_number(n: float) -> str:
    """toLocaleString("en-US"): digit groups, and a fraction rounded half up to
    at most four places. Worked on the shortest decimal digits, as ICU does."""
    if isinstance(n, float) and not math.isfinite(n):
        return ("-" if n < 0 else "") + ("NaN" if math.isnan(n) else "∞")
    negative = n < 0 or (isinstance(n, float) and n == 0 and math.copysign(1.0, n) < 0)
    if _js.is_integer(n):
        whole = str(abs(int(n)))
        fraction = ""
    else:
        digits, point = _js.decimal(abs(float(n)))
        if point >= len(digits):
            whole = digits + "0" * (point - len(digits))
            fraction = ""
        elif point > 0:
            whole = digits[:point]
            fraction = digits[point:]
        else:
            whole = "0"
            fraction = "0" * -point + digits
        if len(fraction) > 4:
            up = int(fraction[4]) >= 5
            fraction = fraction[:4]
            if up:
                rounded = str(int(whole + fraction) + 1).rjust(len(whole) + 4, "0")
                whole = rounded[:-4]
                fraction = rounded[-4:]
        fraction = fraction.rstrip("0")
    groups: list[str] = []
    while len(whole) > 3:
        groups.insert(0, whole[-3:])
        whole = whole[:-3]
    groups.insert(0, whole)
    text = ",".join(groups)
    if fraction:
        text = f"{text}.{fraction}"
    return f"-{text}" if negative else text


def on_run_start(state: JobState) -> JobState:
    """Called when a run starts. Missed and stuck are about the absence of a
    run, so a run starting closes them without an alert; the recovered
    message waits for a successful finish."""
    following = _clone_state(state)
    _close_condition(following, Condition.MISSED)
    _close_condition(following, Condition.STUCK)
    return following


def on_run_finish(definition: JobDefinition, run: Run, state: JobState, history: Sequence[Run], now: int) -> Evaluation:
    """Called when a run finishes with status ok, failed or timeout. `history`
    is the job's earlier runs, newest first, not including this one."""
    following = _clone_state(state)
    alerts: list[AlertDraft] = []

    if run.status == RunStatus.OK:
        following.consecutive_failures = 0
        _close_condition(following, Condition.MISSED)
        _close_condition(following, Condition.STUCK)
        _close_condition(following, Condition.FAILED)

        slow = slow_threshold(definition, history)
        if slow and run.duration_ms is not None and run.duration_ms > slow[0]:
            if _open_condition(following, Condition.SLOW, now):
                alerts.append(
                    AlertDraft(AlertType.SLOW, run, {"duration_ms": run.duration_ms, "threshold_ms": slow[0], "basis": slow[1]})
                )
        else:
            _close_condition(following, Condition.SLOW)

        breaches = budget_breaches(definition, run, history)
        if breaches:
            if _open_condition(following, Condition.OVER_BUDGET, now):
                alerts.append(AlertDraft(AlertType.OVER_BUDGET, run, {"breaches": breaches}))
        else:
            _close_condition(following, Condition.OVER_BUDGET)

        pending = following.pending_recovery or []
        if pending and not open_conditions(following):
            alerts.append(AlertDraft(AlertType.RECOVERED, run, {"after": list(pending)}))
            following.pending_recovery = []
        return Evaluation(following, alerts)

    # failed or timeout
    # Held at the top: a count at the limit must not pass what the SDK and every store hold exactly.
    following.consecutive_failures = min(following.consecutive_failures + 1, MAX_DURATION_MS)
    _close_condition(following, Condition.MISSED)
    threshold = max(1, definition.failures_before_alert if definition.failures_before_alert is not None else 1)
    condition = Condition.STUCK if run.status == RunStatus.TIMEOUT else Condition.FAILED
    if following.consecutive_failures >= threshold:
        if _open_condition(following, condition, now):
            alerts.append(
                AlertDraft(AlertType(str(condition)), run, {"consecutive_failures": following.consecutive_failures, "threshold": threshold})
            )
    return Evaluation(following, alerts)


def on_check(definition: JobDefinition, stored: StoredJob, last_run: Run | None, state: JobState, now: int) -> CheckEvaluation:
    """Called by check(). Decides whether the schedule has been missed: the run
    the schedule wants next (see expectation()) has not started and its grace
    has run out. `last_run` is the most recent run of any status. A job with
    no schedule is never missed, and one whose schedule was removed while
    missed was open gets a recovered alert (reason "unscheduled") for missed alone."""
    following = _clone_state(state)
    alerts: list[AlertDraft] = []
    if not definition.schedule:
        since = following.open.get(Condition.MISSED)
        if Condition.MISSED in following.open:
            # The schedule went away while missed was open, so nothing is due
            # any more. Missed closes now with a recovery of its own; other
            # open conditions keep their own rules. Missed is taken out of the
            # pending recovery too, so the next successful run does not name it again.
            del following.open[Condition.MISSED]
            following.pending_recovery = [c for c in (following.pending_recovery or []) if c != Condition.MISSED]
            alerts.append(AlertDraft(AlertType.RECOVERED, last_run, {"after": [Condition.MISSED], "reason": "unscheduled", "since": since}))
        return CheckEvaluation(following, alerts, None, None)

    parsed = parse_schedule(definition.schedule, definition.timezone)
    grace = grace_ms(definition)
    last_run_at = last_run.started_at if last_run else None
    exp = expectation(parsed, last_run_at, stored.created_at, grace)
    next_expected_at = next_fire(parsed, stored.created_at, last_run_at) if parsed.kind == "interval" else next_fire(parsed, now, None)
    if exp is None:
        return CheckEvaluation(following, alerts, next_expected_at, None)

    # An interval's next run is due a period after the last one started. If
    # that run is still going, the job is busy, not late; stuck covers one that never ends.
    if parsed.kind == "interval" and last_run is not None and last_run.status == RunStatus.RUNNING:
        return CheckEvaluation(following, alerts, next_expected_at, exp.due_at)

    if now > exp.deadline:
        if _open_condition(following, Condition.MISSED, now):
            alerts.append(
                AlertDraft(
                    AlertType.MISSED,
                    last_run,
                    {"due_at": exp.due_at, "deadline": exp.deadline, "grace_ms": grace, "last_run_at": last_run_at},
                )
            )
    else:
        # A run has started since it opened, or the grace was widened.
        _close_condition(following, Condition.MISSED)
    return CheckEvaluation(following, alerts, next_expected_at, exp.due_at)


def is_stuck(definition: JobDefinition, run: Run, now: int) -> bool:
    """Whether a running run has gone on longer than the job's timeout."""
    return run.status == RunStatus.RUNNING and now - run.started_at > timeout_ms(definition)


def mute_opens(previous: JobState, following: JobState) -> JobState:
    """While a job is silenced nothing new is recorded as an incident:
    conditions may close (so a job that recovered during the silence shows as
    healthy) but none may open, so the first problem after the silence ends
    alerts normally."""
    muted = _clone_state(following)
    for condition in open_conditions(muted):
        if condition not in previous.open:
            del muted.open[condition]
    return muted


def is_silenced(state: JobState, now: int) -> bool:
    return state.silenced_until is not None and state.silenced_until > now


def apply_silence(previous: JobState, evaluation: Evaluation, now: int) -> Evaluation:
    """An evaluation as it is saved and sent: while the job was silenced when it
    began, nothing opens and nothing is sent."""
    if not is_silenced(previous, now):
        return evaluation
    return Evaluation(mute_opens(previous, evaluation.state), [])


def stale_alert(alert: Alert, state: JobState) -> bool:
    """Whether an alert waiting to be retried no longer describes the job, so it
    is dropped rather than sent late. An alert for a condition is stale once
    that condition has closed, or has closed and opened again (it opened at a
    time other than the alert's). A recovery is stale when any condition it
    names is open again; while they all stay closed it is kept."""
    if alert.type == AlertType.RECOVERED:
        return any(c in state.open for c in alert.details.get("after") or [])
    return state.open.get(str(alert.type), _MISSING) != alert.at


_MISSING = object()


def job_health(definition: JobDefinition, last_run: Run | None, state: JobState, now: int) -> JobHealth:
    """How a job looks at a glance. Silence wins, then stuck, failing and late."""
    opened = open_conditions(state)
    if is_silenced(state, now):
        return JobHealth.SILENCED
    if Condition.STUCK in opened or (last_run is not None and is_stuck(definition, last_run, now)):
        return JobHealth.STUCK
    if Condition.FAILED in opened or (last_run is not None and last_run.status in (RunStatus.FAILED, RunStatus.TIMEOUT)):
        return JobHealth.FAILING
    if Condition.MISSED in opened:
        return JobHealth.LATE
    if last_run is None:
        return JobHealth.NEVER_RAN
    return JobHealth.HEALTHY


def summarize(stored: StoredJob, recent: Sequence[Run], state: JobState, next_expected_at: int | None, now: int) -> JobSummary:
    """A job's summary from its most recent runs (newest first; the first
    BASELINE_WINDOW are used) and its state. Stats cover runs of any status;
    the percentiles are over the successful ones among them."""
    return _summary(stored, recent, state, next_expected_at, lambda last: job_health(stored.definition, last, state, now))


def unevaluable_summary(stored: StoredJob, recent: Sequence[Run], state: JobState, now: int) -> JobSummary:
    """The summary of a job that could not be evaluated, say because its stored
    schedule no longer parses. It reads nothing from the definition. The job
    shows as failing (or silenced, while it is), since it needs a look, and
    nothing is known about when it is next due."""
    return _summary(stored, recent, state, None, lambda _last: JobHealth.SILENCED if is_silenced(state, now) else JobHealth.FAILING)


def _summary(
    stored: StoredJob,
    recent: Sequence[Run],
    state: JobState,
    next_expected_at: int | None,
    health: Callable[[Run | None], JobHealth],
) -> JobSummary:
    window = list(recent[:BASELINE_WINDOW])
    last_run = window[0] if window else None
    finished = [r for r in window if r.status != RunStatus.RUNNING]
    ok_durations = [r.duration_ms for r in window if r.status == RunStatus.OK and r.duration_ms is not None]
    ok_count = sum(1 for r in finished if r.status == RunStatus.OK)
    return JobSummary(
        name=stored.name,
        definition=stored.definition,
        health=health(last_run),
        open=open_conditions(state),
        last_run=last_run,
        next_expected_at=next_expected_at,
        consecutive_failures=state.consecutive_failures,
        silenced_until=state.silenced_until,
        stats=JobStats(
            runs=len(finished),
            ok_rate=1 if not finished else ok_count / len(finished),
            p50_ms=percentile(ok_durations, 50),  # type: ignore[arg-type]
            p95_ms=percentile(ok_durations, 95),  # type: ignore[arg-type]
        ),
    )
