"""APScheduler: a listener that records every job's runs from APScheduler's
events, with its trigger read as the job's schedule. Needs APScheduler 3.10
or newer in the 3.x line (``pip install "cronwatch-sdk[apscheduler]"``).

    from apscheduler.schedulers.background import BackgroundScheduler
    import cronwatch, cronwatch.apscheduler

    cw = cronwatch.configure(store=SqliteStore("./data/cronwatch.db"))
    scheduler = BackgroundScheduler()
    scheduler.add_job(nightly_report, "cron", hour=2, id="nightly-report")
    cronwatch.apscheduler.watch(scheduler, grace="15m")
    scheduler.start()
    cw.start_checking()  # checks for missed and stuck runs every minute

Every job of the scheduler is then a CronWatch job, named after its id (or,
for an id APScheduler generated, its name, which is the function's), with its
trigger as the schedule: a CronTrigger becomes the cron expression CronWatch
reads in the trigger's zone, checked against APScheduler's own fire times
around every clock change in the next five years and through a sample year;
an IntervalTrigger becomes "every <interval>"; a DateTrigger runs once, so the
job has no schedule. A trigger that cannot be read (a combined trigger, a
calendar interval, a week or year field, a fire time daylight saving skips)
is reported to the client's on_error as "declaring <job>" and the job is
watched without a schedule. A job added, rescheduled or removed later is
declared again (a removed job keeps its runs and loses its schedule, so it is
not reported missed).

A run starts when APScheduler submits the job to its executor and ends when
the executor reports it: the return value is the run's output when it is a
string (and is checked by ``expect``), an exception fails the run. Runs are
recorded in a thread of the listener's own, so neither the scheduler's thread
nor an asyncio scheduler's event loop waits on the store. APScheduler tells a
listener only that a job was submitted and how it ended, so inside the job
``cronwatch.current()`` is None; return the text to record, or wrap the
function in ``job.run()`` yourself and leave the job out with ``exclude=``.
A run APScheduler skips because it started too late (``misfire_grace_time``)
is recorded as failed; a run it never submits (the job already running at
``max_instances``, the scheduler down) is missed as usual.

Per-job options: ``watch(scheduler, jobs={"nightly-report": {"timeout": "2h"}})``,
by job id, with Cronwatch.job()'s options and ``name=`` (``schedule=`` there
replaces the trigger's). ``exclude=[...]`` leaves jobs alone, by id or name.
watch()'s own options (grace, timeout, failures_before_alert, tags...) apply
to every job it declares.

APScheduler 4 (still a pre-release) changed its events and triggers
altogether; it is not supported yet.
"""

from __future__ import annotations

import contextlib
import copy
import queue
import re
import threading
from collections import deque
from collections.abc import Callable, Iterable, Mapping
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any

try:
    import apscheduler
    from apscheduler import events
    from apscheduler.triggers.cron import CronTrigger
    from apscheduler.triggers.cron.expressions import (
        AllExpression,
        LastDayOfMonthExpression,
        RangeExpression,
        WeekdayPositionExpression,
    )
    from apscheduler.triggers.date import DateTrigger
    from apscheduler.triggers.interval import IntervalTrigger
except ImportError as error:  # pragma: no cover
    raise ImportError('cronwatch.apscheduler needs APScheduler 3: pip install "cronwatch-sdk[apscheduler]"') from error

if not str(getattr(apscheduler, "__version__", "3")).startswith("3."):  # pragma: no cover
    raise ImportError(f"cronwatch.apscheduler supports APScheduler 3.x, not {apscheduler.__version__}")

import cronwatch

from ._convert import check_options, every_text, field_text, zone_name
from ._deprecated import names as _deprecated_names
from ._scheduler_check import NeverFires, ScheduleError, check_fires
from ._client import NAME_RE, Cronwatch, JobHandle
from ._run_handle import RunHandle
from ._schedule import parse_schedule

__all__ = ["ScheduleError", "SchedulerWatch", "convert", "watch"]

_TRIGGER = "apscheduler"
#: What APScheduler generates for a job added without an id.
_GENERATED_ID = re.compile(r"[0-9a-f]{32}\Z")
#: Runs that ended before their submission was heard of, remembered so it starts nothing.
_DONE_KEPT = 1000
#: The type of APScheduler's listeners lock (a reentrant lock), taken while a watch's listener is swapped.
_RLOCK = type(threading.RLock())
_EVENTS = (
    events.EVENT_SCHEDULER_STARTED
    | events.EVENT_JOB_ADDED
    | events.EVENT_JOB_MODIFIED
    | events.EVENT_JOB_REMOVED
    | events.EVENT_ALL_JOBS_REMOVED
    | events.EVENT_JOB_SUBMITTED
    | events.EVENT_JOB_EXECUTED
    | events.EVENT_JOB_ERROR
    | events.EVENT_JOB_MISSED
)


# ---------------------------------------------------------------- triggers


def _probe(field: Any, value: int) -> datetime:
    """A date whose `field` is `value`, for asking the field whether it matches."""
    name = field.name
    if name == "second":
        return datetime(2026, 1, 1, 0, 0, value)
    if name == "minute":
        return datetime(2026, 1, 1, 0, value)
    if name == "hour":
        return datetime(2026, 1, 1, value)
    if name == "month":
        return datetime(2026, value, 1)
    if name == "day":
        return datetime(2026, 1, value)  # January has every day of the month
    if name == "day_of_week":
        return datetime(2026, 1, 5 + value)  # 2026-01-05 is a Monday, APScheduler's 0
    raise ValueError(name)


def _matching(field: Any, lo: int, hi: int) -> list[int]:
    return [value for value in range(lo, hi + 1) if field.get_next_value(_probe(field, value)) == value]


def _is_all(field: Any) -> bool:
    return len(field.expressions) == 1 and type(field.expressions[0]) is AllExpression and not field.expressions[0].step


def _cron_text(trigger: Any, where: str) -> str:
    """The cron expression croner reads for a CronTrigger. APScheduler fires on
    a day that matches the day of the month and the day of the week together
    (Monday is its 0), which croner reads with "+" before the day of the week
    when both are restricted."""
    fields = {field.name: field for field in trigger.fields}
    for name in ("year", "week"):
        if not _is_all(fields[name]):
            raise ScheduleError(f"{where} sets the {name} field ({fields[name]}), which CronWatch cannot read")
    second = field_text(_matching(fields["second"], 0, 59), 0, 59)
    minute = field_text(_matching(fields["minute"], 0, 59), 0, 59)
    hour = field_text(_matching(fields["hour"], 0, 23), 0, 23)
    month = field_text(_matching(fields["month"], 1, 12), 1, 12)
    weekday_field = fields["day_of_week"]
    weekdays = "*" if _is_all(weekday_field) else field_text([(d + 1) % 7 for d in _matching(weekday_field, 0, 6)], 0, 6)

    day_field = fields["day"]
    positions = [e for e in day_field.expressions if isinstance(e, WeekdayPositionExpression)]
    last = any(isinstance(e, LastDayOfMonthExpression) for e in day_field.expressions)
    plain = [e for e in day_field.expressions if isinstance(e, (AllExpression, RangeExpression)) and not isinstance(e, (WeekdayPositionExpression, LastDayOfMonthExpression))]
    if positions:
        if plain or last or weekdays != "*":
            raise ScheduleError(f"{where} mixes a weekday of the month ({day_field}) with other days, which CronWatch cannot read")
        # "1st fri" is croner's 5#1, "last fri" its 5L.
        weekdays = ",".join(
            f"{(e.weekday + 1) % 7}L" if e.option_num == 5 else f"{(e.weekday + 1) % 7}#{e.option_num + 1}" for e in positions
        )
        day = "*"
    else:
        numbers = [v for v in range(1, 32) if any(e.get_next_value(_probe(day_field, v), day_field) == v for e in plain)]
        day = field_text(numbers, 1, 31) if numbers else ""
        if last and day != "*":
            day = f"{day},L" if numbers else "L"
        if day != "*" and weekdays != "*":
            weekdays = f"+{weekdays}"
    five = f"{minute} {hour} {day} {month} {weekdays}"
    return five if second == "0" else f"{second} {five}"


def _trigger_runs(trigger: Any) -> Callable[[int, int | None], list[int]]:
    """APScheduler's own fire times for a CronTrigger, without jitter or start and end dates."""
    sim = copy.copy(trigger)
    sim.jitter = None
    sim.start_date = None
    sim.end_date = None
    tz = trigger.timezone

    def at(ms: int) -> datetime:
        return datetime.fromtimestamp(ms / 1000, timezone.utc).astimezone(tz)

    def ms_of(moment: datetime) -> int:
        return round(moment.timestamp() * 1000)

    def following(previous: datetime) -> datetime | None:
        found: datetime | None = sim.get_next_fire_time(previous, previous + timedelta(microseconds=1))
        # APScheduler 3 answers the repeated wall time when clocks go back (the
        # second 01:30) with itself, or an earlier instant, however it is asked
        # from just after it; asked from further on, it moves on.
        for step in (1, 60, 3600, 7200, 86_400):
            if found is None or found.timestamp() > previous.timestamp():
                return found
            found = sim.get_next_fire_time(None, previous + timedelta(seconds=step))
        raise NeverFires(f"APScheduler answers {found} again and again after {previous}")

    def runs(start: int, end: int | None) -> list[int]:
        before: datetime | None = None
        for lookback in (3_600_000, 86_400_000, 8 * 86_400_000, 32 * 86_400_000, 367 * 86_400_000, 5 * 366 * 86_400_000):
            found = sim.get_next_fire_time(None, at(start - lookback))
            while found is not None and ms_of(found) <= start:
                before = found
                found = following(found)
            if before is not None:
                break
        if before is None:
            raise NeverFires("APScheduler finds no fire time in the five years before it")
        out = [ms_of(before)]
        current: datetime | None = before
        while current is not None:
            current = following(current)
            if current is None:
                break
            out.append(ms_of(current))
            if (end is None and len(out) > 8) or (end is not None and out[-1] > end):
                break
        return out

    return runs


_converted: dict[tuple[str, str], dict[str, Any]] = {}
_converted_lock = threading.Lock()


def convert(trigger: Any, where: str = "cronwatch: this job") -> dict[str, Any] | None:
    """{"schedule"[, "timezone"]} for an APScheduler trigger, or None for one
    that fires once (DateTrigger). Raises ScheduleError, naming `where`."""
    if isinstance(trigger, DateTrigger):
        return None
    if isinstance(trigger, IntervalTrigger):
        if trigger.interval_length < 1:
            raise ScheduleError(f"{where} runs every {trigger.interval_length}s; CronWatch watches intervals of one second or more")
        return {"schedule": every_text(trigger.interval)}
    if isinstance(trigger, CronTrigger):
        zone = zone_name(trigger.timezone)
        if zone is None:
            raise ScheduleError(f"{where} is read in {trigger.timezone!r}, which is not an IANA timezone; give the trigger one, such as UTC or Europe/London")
        text = _cron_text(trigger, where)
        key = (text, zone)
        with _converted_lock:
            hit = _converted.get(key)
        if hit is not None:
            return dict(hit)
        try:
            parsed = parse_schedule(text, zone)
        except ValueError as error:
            raise ScheduleError(f"{where} is {cronwatch._js.dumps(text)}, which CronWatch cannot read: {error}") from None
        fields = {field.name: field for field in trigger.fields}
        daily = all(_is_all(fields[name]) for name in ("day", "month", "day_of_week"))
        check_fires(_trigger_runs(trigger), parsed, f"{where}: {cronwatch._js.dumps(text)}", "APScheduler", daily=daily)
        made = {"schedule": text, "timezone": zone}
        with _converted_lock:
            _converted[key] = made
        return dict(made)
    raise ScheduleError(f"{where} has a {type(trigger).__name__}, which CronWatch cannot read")


# ---------------------------------------------------------------- the listener


@dataclass
class _Declaration:
    job_id: str
    name: str
    options: dict[str, Any]
    where: str


class SchedulerWatch:
    """What watch() sets up for one scheduler. See the module's docstring."""

    def __init__(
        self,
        scheduler: Any,
        *,
        client: Cronwatch | Callable[[], Cronwatch] | None,
        jobs: Mapping[str, Mapping[str, Any]],
        exclude: Iterable[str],
        options: Mapping[str, Any],
        previous: SchedulerWatch | None = None,
    ) -> None:
        self.scheduler = scheduler
        self._client = client
        self.jobs = {str(key): check_options(dict(value), f"watch(jobs={{{key!r}: ...}})", allow=("name",)) for key, value in jobs.items()}
        self.exclude = frozenset(str(key) for key in exclude)
        self.options = check_options(options, "watch()")
        for key in ("schedule", "timezone"):
            if key in self.options:
                raise TypeError(f"watch() takes {key} from each job's trigger; give a job its own with jobs={{id: {{{key!r}: ...}}}}")
        self._declared: dict[str, _Declaration] = {}
        self._handles: dict[str, tuple[Cronwatch, dict[str, Any], JobHandle]] = {}
        self._active: dict[tuple[str, datetime], RunHandle] = {}
        self._later: dict[tuple[str, datetime], int] = {}
        self._done: deque[tuple[str, datetime]] = deque(maxlen=_DONE_KEPT)
        self._events: queue.Queue[Any] = queue.Queue()
        self._closed = False
        self._thread = threading.Thread(target=self._work, name="cronwatch-apscheduler", daemon=True)
        self._events.put(("declare_all", None))
        if previous is None:
            scheduler.add_listener(self._listen, _EVENTS)
        else:
            self._take_over(previous)
        self._thread.start()

    def _take_over(self, previous: SchedulerWatch) -> None:
        """Replaces `previous` without losing or doubling an event: its listener
        and this one's are swapped under the scheduler's listeners lock (which
        APScheduler holds while it takes the listeners for an event), then
        everything it heard is recorded, and the runs it has under way, and
        what it remembers of runs that ended before their submission or were
        caught up, carry over, so their ends finish them here. This one's
        thread starts after that, on the events heard since the swap."""
        lock = getattr(self.scheduler, "_listeners_lock", None)
        with lock if isinstance(lock, _RLOCK) else contextlib.nullcontext():
            if not previous._closed:
                try:
                    self.scheduler.remove_listener(previous._listen)
                except Exception:
                    pass
            self.scheduler.add_listener(self._listen, _EVENTS)
        previous.close()
        self._active.update(previous._active)
        self._later.update(previous._later)
        self._done.extend(previous._done)

    @property
    def client(self) -> Cronwatch:
        given = self._client
        if isinstance(given, Cronwatch):
            return given
        if callable(given):
            made: Cronwatch = given()
            return made
        return cronwatch.client()

    # ------------------------------------------------------------ the thread

    def _listen(self, event: Any) -> None:
        if not self._closed:
            self._events.put(("event", event))

    def _work(self) -> None:
        while True:
            kind, event = self._events.get()
            try:
                if kind == "stop":
                    return
                if kind == "declare_all":
                    self._declare_all()
                else:
                    self._handle(event)
            except Exception as error:
                self.client._report(error, "apscheduler listener")
            finally:
                self._events.task_done()

    def flush(self) -> None:
        """Waits until every event heard so far is recorded (for tests, and before exit)."""
        self._events.join()

    def close(self) -> None:
        """Stops listening, records what was heard, and ends the listener's thread."""
        if self._closed:
            return
        self._closed = True
        try:
            self.scheduler.remove_listener(self._listen)
        except Exception:
            pass
        self._events.put(("stop", None))
        self._thread.join()

    # ------------------------------------------------------------ jobs

    def _name(self, job: Any) -> str | None:
        given = self.jobs.get(job.id, {})
        if given.get("name"):
            return str(given["name"])
        for candidate in (job.id, getattr(job, "name", None)):
            if isinstance(candidate, str) and NAME_RE.fullmatch(candidate) and not (candidate == job.id and _GENERATED_ID.fullmatch(candidate)):
                return candidate
        return None

    def _declaration(self, job: Any) -> _Declaration | None:
        if job.id in self.exclude or getattr(job, "name", None) in self.exclude:
            return None
        where = f"APScheduler job {cronwatch._js.dumps(str(job.id))}"
        name = self._name(job)
        if name is None:
            self.client._report(
                ValueError(
                    f"cronwatch: {where} ({job.name}) has no id or name CronWatch can use as a job name; give it an id= of "
                    'letters, digits, ".", "_", ":" or "-", or pass jobs={id: {"name": ...}} to watch()'
                ),
                f"declaring {where}",
            )
            return None
        given = {key: value for key, value in self.jobs.get(job.id, {}).items() if key != "name"}
        options = dict(self.options)
        if "schedule" not in given:
            try:
                found = convert(job.trigger, f"cronwatch: {where}")
                if found:
                    options.update(found)
            except ScheduleError as error:
                self.client._report(error, f"declaring {where}")
        options.update({k: v for k, v in given.items() if not (k == "schedule" and v is None)})
        return _Declaration(job_id=job.id, name=name, options=options, where=where)

    def _declare(self, declaration: _Declaration) -> JobHandle | None:
        client = self.client
        known = self._handles.get(declaration.job_id)
        if known is not None and known[0] is client and known[1] == declaration.options and known[2].name == declaration.name:
            return known[2]
        try:
            made = client.job(declaration.name, **declaration.options)
        except Exception as error:
            client._report(error, f"declaring {declaration.where}")
            return None
        self._handles[declaration.job_id] = (client, dict(declaration.options), made)
        return made

    def _add(self, job: Any) -> None:
        declaration = self._declaration(job)
        if declaration is None:
            self._declared.pop(job.id, None)
            return
        self._declared[job.id] = declaration
        self._declare(declaration)

    def _declare_all(self) -> None:
        for job in self.scheduler.get_jobs():
            self._add(job)

    def _unschedule(self, job_id: str) -> None:
        """A job gone from the scheduler keeps its runs and loses its schedule."""
        declaration = self._declared.get(job_id)
        if declaration is None or "schedule" not in declaration.options:
            return
        options = {k: v for k, v in declaration.options.items() if k not in ("schedule", "timezone")}
        self._declared[job_id] = _Declaration(job_id, declaration.name, options, declaration.where)
        self._declare(self._declared[job_id])

    def _handle_for(self, job_id: str, jobstore: str | None) -> JobHandle | None:
        declaration = self._declared.get(job_id)
        if declaration is None and job_id not in self.exclude:
            job = self.scheduler.get_job(job_id, jobstore)
            if job is not None:
                self._add(job)
                declaration = self._declared.get(job_id)
        return self._declare(declaration) if declaration is not None else None

    # ------------------------------------------------------------ events

    def _handle(self, event: Any) -> None:
        code = event.code
        if code == events.EVENT_SCHEDULER_STARTED:
            self._declare_all()
        elif code in (events.EVENT_JOB_ADDED, events.EVENT_JOB_MODIFIED):
            job = self.scheduler.get_job(event.job_id, event.jobstore)
            if job is not None:
                self._add(job)
        elif code == events.EVENT_JOB_REMOVED:
            self._unschedule(event.job_id)
        elif code == events.EVENT_ALL_JOBS_REMOVED:
            for job_id in list(self._declared):
                self._unschedule(job_id)
        elif code == events.EVENT_JOB_SUBMITTED:
            self._submitted(event)
        elif code in (events.EVENT_JOB_EXECUTED, events.EVENT_JOB_ERROR, events.EVENT_JOB_MISSED):
            self._ended(event)

    def _submitted(self, event: Any) -> None:
        run_times = list(event.scheduled_run_times or [])
        if not run_times:
            return
        first = (event.job_id, run_times[0])
        for later in run_times[1:]:
            key = (event.job_id, later)
            if key in self._done:
                self._done.remove(key)  # it ended (or was skipped) before its submission was heard of
            else:
                self._later[key] = 1
        if first in self._done:
            self._done.remove(first)  # it ended before its submission was heard of
            return
        handle = self._handle_for(event.job_id, event.jobstore)
        if handle is not None:
            self._active[first] = handle.start(trigger=_TRIGGER)

    def _ended(self, event: Any) -> None:
        key = (event.job_id, event.scheduled_run_time)
        run = self._active.pop(key, None)
        caught_up = self._later.pop(key, None) is not None
        if event.code == events.EVENT_JOB_MISSED:
            skipped = f"APScheduler skipped the run: it could not start within misfire_grace_time of {event.scheduled_run_time.isoformat()}"
            if run is None and not caught_up:
                # APScheduler can report the miss before the submission: the run
                # is failed now, and the submission that follows starts nothing.
                handle = self._handle_for(event.job_id, event.jobstore)
                if handle is None:
                    return
                self._done.append(key)
                run = handle.start(trigger=_TRIGGER)
            if run is not None:
                run.fail(skipped)
            return
        if run is None:
            handle = self._handle_for(event.job_id, event.jobstore)
            if handle is None:
                return
            if not caught_up:
                self._done.append(key)  # ended before its submission was heard of
            run = handle.start(trigger=_TRIGGER)
        if event.code == events.EVENT_JOB_ERROR:
            run.fail(event.exception if event.exception is not None else RuntimeError("the job failed"))
        else:
            run.finish(result=event.retval)


_watches: dict[int, SchedulerWatch] = {}
_watches_lock = threading.Lock()


def watch(
    scheduler: Any,
    *,
    client: Cronwatch | Callable[[], Cronwatch] | None = None,
    jobs: Mapping[str, Mapping[str, Any]] | None = None,
    exclude: Iterable[str] = (),
    **options: Any,
) -> SchedulerWatch:
    """Records every job's runs (see the module's docstring). Call it once per
    scheduler, before or after start(); calling it again replaces the listener,
    and the runs the earlier one has under way are finished by the new one.

    client:  a Cronwatch, or a function returning one. Default: cronwatch.client(), looked up when used.
    jobs:    {job id: options} per job: Cronwatch.job()'s options and name=.
    exclude: job ids or names to leave alone.
    options: job options (grace, timeout, failures_before_alert, tags...) for every job.
    """
    with _watches_lock:
        previous = _watches.get(id(scheduler))
        made = SchedulerWatch(
            scheduler,
            client=client,
            jobs=jobs or {},
            exclude=[exclude] if isinstance(exclude, str) else exclude,
            options=options,
            previous=previous if previous is not None and previous.scheduler is scheduler else None,
        )
        _watches[id(scheduler)] = made
    return made


#: Internal names, still answering under their old public names (each
#: warning, until 1.0 removes them).
__getattr__ = _deprecated_names(__name__, globals(), {"TRIGGER": "_TRIGGER", "cron_text": "_cron_text"})
