"""Celery: tasks watched as CronWatch jobs through Celery's signals, with
their schedules read from Celery beat. Needs Celery 5.5 or newer
(``pip install "cronwatch-sdk[celery]"``).

    # proj/celery.py
    from celery import Celery
    from celery.schedules import crontab
    import cronwatch.celery

    app = Celery("proj")
    app.conf.beat_schedule = {
        "nightly-report": {"task": "proj.tasks.nightly_report", "schedule": crontab(hour=2, minute=0)},
        "cronwatch-check": {"task": "cronwatch.celery.check", "schedule": 300},
    }
    cronwatch.celery.install(app, grace="15m")

Every task beat schedules is then a job, named after the task
("proj.tasks.nightly_report"), with the schedule beat gives it: each run of it
by a worker is recorded with the trigger "celery", and a check reports one
that never ran. No task needs changing. ``cronwatch.current()`` is the run's
context inside the task, for log() and metric(). A task that raises is
recorded as failed and raises on to Celery as before, so its retries, error
handlers and result backend see it unchanged.

Schedules come from ``app.conf.beat_schedule`` (crontab and interval entries)
and, when django-celery-beat is installed, its PeriodicTask table (enabled
recurring tasks; its rows win over beat_schedule entries of the same name).
A crontab becomes the cron expression CronWatch reads in the crontab's zone
(Celery's ``timezone`` setting, or django-celery-beat's per-row zone), and is
checked against Celery's own crontab code around every clock change in the
next five years and through a sample year, so a schedule CronWatch would
expect at other times than beat runs it is refused rather than reported
missed. A schedule that cannot be read (a solar schedule, one task scheduled
by several entries, a time that daylight saving skips) is reported to the
client's on_error as "declaring <entry>", and the task is watched without a
schedule: its failures still alert, a missed run does not.

Per-task options go on the task with the decorator, below ``@app.task``:

    @app.task
    @cronwatch_task(grace="30m", timeout="2h", expect="Report written")
    def nightly_report(): ...

It takes the options of Cronwatch.job() and ``name=``. With ``schedule=``
its own schedule is used rather than beat's (and a task beat does not
schedule is watched too); ``install(tasks={"proj.tasks.x": {...}})`` does the
same without touching the task. ``install(exclude=[...])`` leaves beat
entries (by key) or tasks (by name) alone, and install's own options (grace,
timeout, failures_before_alert, tags...) apply to every job it declares.

Retries follow the gem's Sidekiq rules: every attempt is a run of its own, and
an attempt that ends in ``self.retry()`` (or ``autoretry_for``) is a failed
run with the error that caused it, so a task failing and retrying opens one
failed alert, and the attempt that succeeds closes it with a recovery.
``failures_before_alert=3`` waits for three failed attempts in a row. A
worker process that dies under a task (a hard time limit, a revoke with
terminate, WorkerLostError) has its run failed by the worker's main process
when Celery reports it; one Celery does not report is marked stuck by a check
after the job's timeout.

Checks: schedule ``cronwatch.celery.check`` with beat (every five minutes,
above), once for the whole deployment. It declares every watched job first,
so a job that has never run is still missed.

The client is ``install(client=...)``, a Cronwatch or a function returning
one; by default the Django integration's (``cronwatch.django.client()``) in a
Django project, else ``cronwatch.client()``, looked up when used. With the
prefork pool, give it a store that processes share (SQLite, Postgres): each
task runs in a child process.
"""

from __future__ import annotations

import copy
import sys
import threading
import time
import uuid
from collections.abc import Callable, Iterable, Mapping
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any

try:
    import celery
    from celery import shared_task, signals
    from celery.exceptions import Retry, Terminated, TimeLimitExceeded, WorkerLostError
    from celery.local import Proxy
    from celery.schedules import crontab, maybe_schedule, schedule, solar
except ImportError as error:  # pragma: no cover
    raise ImportError('cronwatch.celery needs Celery: pip install "cronwatch-sdk[celery]"') from error

import cronwatch

from . import _zone
from ._convert import check_options, every_text, field_text, local_zone_name, zone_name
from ._scheduler_check import NeverFires, ScheduleError, check_fires
from .client import Cronwatch, JobHandle, _Execution
from .schedule import parse_schedule

__all__ = ["CHECK_TASK", "CeleryWatch", "ScheduleError", "check", "cronwatch_task", "install", "watch_for"]

#: The check task's name, for beat_schedule.
CHECK_TASK = "cronwatch.celery.check"
TRIGGER = "celery"
#: Tasks never watched: Celery's own, and the check.
SKIPPED_TASKS = frozenset({"celery.backend_cleanup", CHECK_TASK})
#: Seconds a reading of the beat schedule (and django-celery-beat's table) is used before it is read again.
REFRESH_S = 60.0
#: The attribute a request carries its run in, between the signals.
_RUN = "_cronwatch_run"
_OPTIONS = "__cronwatch__"


# ---------------------------------------------------------------- per-task options


_pending: list[tuple[Any, dict[str, Any]]] = []
_pending_lock = threading.Lock()


def cronwatch_task(**options: Any) -> Callable[[Any], Any]:
    """Per-task options, for a task defined with ``@app.task`` or
    ``@shared_task``. Put it below the task decorator (on the function); above
    it (on the task) works too. Takes Cronwatch.job()'s options and ``name=``."""
    given = check_options(options, "cronwatch_task", allow=("name",))

    def decorate(target: Any) -> Any:
        if isinstance(target, Proxy):
            # A task not made yet (the app is not finalized): its name is read once it is.
            with _pending_lock:
                _pending.append((target, given))
        else:
            setattr(target, _OPTIONS, given)
        return target

    return decorate


def _task_options(task: Any) -> dict[str, Any] | None:
    for holder in (task, getattr(task, "run", None), getattr(task, "__wrapped__", None)):
        found = getattr(holder, _OPTIONS, None) if holder is not None else None
        if isinstance(found, dict):
            return found
    return None


# ---------------------------------------------------------------- beat


@dataclass(frozen=True)
class BeatEntry:
    """One entry of beat's schedule, from beat_schedule or django-celery-beat."""

    key: str
    label: str
    task: str | None
    schedule: Any
    description: str | None = None


def _conf_entries(app: Any) -> list[BeatEntry]:
    found = []
    for key, entry in dict(app.conf.beat_schedule or {}).items():
        if not isinstance(entry, Mapping):
            continue
        found.append(
            BeatEntry(
                key=str(key),
                label=f"beat_schedule entry {cronwatch._js.dumps(str(key))}",
                task=entry.get("task"),
                schedule=maybe_schedule(entry.get("schedule"), entry.get("relative", False), app=app),
            )
        )
    return found


def _database_entries() -> list[BeatEntry]:
    """django-celery-beat's enabled recurring tasks."""
    from django_celery_beat.models import PeriodicTask

    found = []
    for task in PeriodicTask.objects.filter(enabled=True, one_off=False).select_related("interval", "crontab", "solar", "clocked"):
        if task.clocked_id is not None:
            continue  # runs once, at a time
        found.append(
            BeatEntry(
                key=task.name,
                label=f"django-celery-beat task {cronwatch._js.dumps(task.name)}",
                task=task.task,
                schedule=task.schedule,
                description=task.description or None,
            )
        )
    return found


def _django_celery_beat_installed() -> bool:
    if "django_celery_beat" not in sys.modules and "django" not in sys.modules:
        return False
    try:
        from django.apps import apps
        from django.conf import settings

        return bool(settings.configured) and apps.ready and apps.is_installed("django_celery_beat")
    except Exception:
        return False


def _crontab_zone(sched: Any, app: Any) -> str:
    """The IANA name of the zone a crontab fires in."""
    # A crontab's zone is its app's (Celery's timezone setting); django-celery-beat's carry their own.
    tz = getattr(sched, "tz", None)
    name = zone_name(tz)
    if name is None and app is not None and not app.conf.timezone and not app.conf.enable_utc:
        name = local_zone_name()
    if name is None:
        raise ScheduleError(
            f"is read in {tz!r}, which is not an IANA timezone; set Celery's timezone setting to one, such as UTC or Europe/London"
        )
    return name


def cron_text(sched: Any) -> str:
    """The five fields croner reads for a Celery crontab. Celery fires on a day
    that matches the day of the month, the month and the day of the week
    together, which croner reads with "+" before the day of the week when both
    days are restricted."""
    minute = field_text(sched.minute, 0, 59)
    hour = field_text(sched.hour, 0, 23)
    dom = field_text(sched.day_of_month, 1, 31)
    month = field_text(sched.month_of_year, 1, 12)
    dow = field_text(sched.day_of_week, 0, 6)
    if dom != "*" and dow != "*":
        dow = f"+{dow}"
    return f"{minute} {hour} {dom} {month} {dow}"


def _celery_runs(sched: Any, zone: str, app: Any) -> Callable[[int, int | None], list[int]]:
    """Beat's runs of a crontab, by Celery's own code: its is_due() asked as
    beat asks it, the clock moved on by what it answers (in steps of at most
    five minutes once a run is near), each run becoming the last run."""
    tz = _zone.get(zone)
    sim = copy.copy(sched)
    if app is not None:
        sim.app = app
    clock = [0]
    sim.nowfun = lambda: datetime.fromtimestamp(clock[0] / 1000, tz)
    sim.tz = tz

    def walk(start: int, stop: Callable[[list[int]], bool], limit_ms: int) -> list[int]:
        clock[0] = start
        last = datetime.fromtimestamp(start / 1000, tz)
        found: list[int] = []
        while clock[0] - start <= limit_ms:
            try:
                due, rem = sim.is_due(last)
            except RuntimeError as error:
                raise NeverFires(str(error)) from None
            if due:
                found.append(clock[0])
                last = datetime.fromtimestamp(clock[0] / 1000, tz)
                if stop(found):
                    return found
            ms = max(1, round(float(rem) * 1000))
            clock[0] += ms if ms <= 300_000 else max(300_000, ms - 7_200_000)
        return found

    def runs(start: int, end: int | None) -> list[int]:
        before: int | None = None
        for lookback in (3_600_000, 86_400_000, 8 * 86_400_000, 32 * 86_400_000, 367 * 86_400_000, 5 * 366 * 86_400_000):
            earlier = walk(start - lookback, lambda found: found[-1] > start, lookback + 1)
            earlier = [at for at in earlier if at <= start]
            if earlier:
                before = earlier[-1]
                break
        if before is None:
            raise NeverFires(f"Celery finds no run in the five years before {datetime.fromtimestamp(start / 1000, timezone.utc):%Y-%m-%d}")
        if end is None:
            after = walk(before, lambda found: len(found) >= 8, 6 * 366 * 86_400_000)
        else:
            after = walk(before, lambda found: found[-1] > end, end - before + 6 * 366 * 86_400_000)
        return [before, *after]

    return runs


_converted: dict[tuple[str, str, str], dict[str, Any]] = {}
_converted_lock = threading.Lock()


def convert(entry: BeatEntry, app: Any = None) -> dict[str, Any] | None:
    """{"schedule", "timezone"} for a beat entry, or None for one that runs
    once (django-celery-beat's clocked). Raises ScheduleError, its message
    naming the entry."""
    sched = entry.schedule
    where = f"cronwatch: {entry.label}"
    if sched is None:
        raise ScheduleError(f"{where} has no schedule")
    if type(sched).__name__ == "clocked":
        return None
    if isinstance(sched, crontab):
        try:
            zone = _crontab_zone(sched, app)
        except ScheduleError as error:
            raise ScheduleError(f"{where}: {sched!r} {error}") from None
        text = cron_text(sched)
        key = (type(sched).__qualname__, text, zone)
        with _converted_lock:
            hit = _converted.get(key)
        if hit is not None:
            return dict(hit)
        try:
            parsed = parse_schedule(text, zone)
        except ValueError as error:
            raise ScheduleError(f"{where} is {cronwatch._js.dumps(text)}, which CronWatch cannot read: {error}") from None
        daily = sched.day_of_month == set(range(1, 32)) and sched.month_of_year == set(range(1, 13)) and sched.day_of_week == set(range(7))
        check_fires(_celery_runs(sched, zone, app), parsed, f"{where}: {cronwatch._js.dumps(text)}", "Celery beat", daily=daily)
        made = {"schedule": text, "timezone": zone}
        with _converted_lock:
            _converted[key] = made
        return dict(made)
    if isinstance(sched, schedule):
        every = sched.run_every
        if every.total_seconds() < 1:
            raise ScheduleError(f"{where} runs every {every.total_seconds()}s; CronWatch watches intervals of one second or more")
        return {"schedule": every_text(every)}
    if isinstance(sched, solar):
        raise ScheduleError(f"{where} is a solar schedule ({sched.event}), whose times move every day, which CronWatch cannot read")
    raise ScheduleError(f"{where} is a {type(sched).__name__} schedule, which CronWatch cannot read")


# ---------------------------------------------------------------- the watch


@dataclass
class _Declaration:
    task: str
    name: str
    options: dict[str, Any]
    where: str


class CeleryWatch:
    """What install() sets up for one Celery app: which tasks are watched, as
    which jobs, on which client. See the module's docstring."""

    def __init__(
        self,
        app: Any,
        *,
        client: Cronwatch | Callable[[], Cronwatch] | None,
        beat: bool,
        django_celery_beat: bool | None,
        tasks: Mapping[str, Mapping[str, Any]],
        exclude: Iterable[str],
        options: Mapping[str, Any],
    ) -> None:
        self.app = app
        self._client = client
        self.beat = beat
        self.django_celery_beat = django_celery_beat
        self.tasks = {str(name): check_options(dict(given), f"install(tasks={{{name!r}: ...}})", allow=("name",)) for name, given in tasks.items()}
        self.exclude = frozenset(str(key) for key in exclude)
        self.options = check_options(options, "install()")
        for key in ("schedule", "timezone"):
            if key in self.options:
                raise TypeError(f"install() takes {key} from beat; give a task its own with @cronwatch_task({key}=...)")
        self._lock = threading.RLock()
        self._declarations: dict[str, _Declaration] | None = None
        self._read_at = 0.0
        self._handles: dict[str, tuple[Cronwatch, dict[str, Any], JobHandle]] = {}
        self._reported: set[str] = set()

    @property
    def client(self) -> Cronwatch:
        given = self._client
        if isinstance(given, Cronwatch):
            return given
        if callable(given):
            made: Cronwatch = given()
            return made
        return default_client()

    def _report(self, error: BaseException, where: str) -> None:
        key = f"{where}\n{error}"
        with self._lock:
            if key in self._reported:
                return
            self._reported.add(key)
        self.client._report(error, where)

    # ------------------------------------------------------------ reading

    def beat_entries(self, report: Callable[[BaseException, str], None] | None = None) -> list[BeatEntry]:
        """Beat's entries, beat_schedule's and django-celery-beat's (which win by name)."""
        if not self.beat:
            return []
        entries = {entry.key: entry for entry in _conf_entries(self.app)}
        use_db = self.django_celery_beat
        if use_db is None:
            use_db = _django_celery_beat_installed()
        if use_db:
            try:
                for entry in _database_entries():
                    entries[entry.key] = entry
            except Exception as error:
                (report or self._report)(error, "reading django-celery-beat")
        return list(entries.values())

    def _decorated(self, report: Callable[[BaseException, str], None]) -> dict[str, dict[str, Any]]:
        found: dict[str, dict[str, Any]] = {}
        with _pending_lock:
            pending = list(_pending)
        for proxy, options in pending:
            try:
                found[proxy.name] = options
            except Exception as error:
                report(error, "reading @cronwatch_task")
        for name, task in list(self.app.tasks.items()):
            options = _task_options(task)
            if options is not None:
                found[name] = options
        return found

    def _read(self, report: Callable[[BaseException, str], None]) -> dict[str, _Declaration]:
        by_task: dict[str, list[BeatEntry]] = {}
        for entry in self.beat_entries(report):
            if entry.task is None or entry.key in self.exclude or entry.task in self.exclude or entry.task in SKIPPED_TASKS:
                continue
            by_task.setdefault(entry.task, []).append(entry)
        own = {**self._decorated(report), **self.tasks}
        declarations: dict[str, _Declaration] = {}
        for task in sorted(set(by_task) | set(own)):
            if task in SKIPPED_TASKS or task in self.exclude:
                continue
            given = dict(own.get(task, {}))
            name = str(given.pop("name", None) or task)
            options = dict(self.options)
            entries = by_task.get(task, [])
            where = entries[0].label if len(entries) == 1 else f"task {task}"
            if "schedule" not in given:
                if len(entries) == 1:
                    try:
                        found = convert(entries[0], self.app)
                        if found:
                            options.update(found)
                    except ScheduleError as error:
                        report(error, f"declaring {where}")
                    if entries[0].description and "description" not in given:
                        options["description"] = entries[0].description
                elif len(entries) > 1:
                    labels = ", ".join(entry.label for entry in entries)
                    report(
                        ScheduleError(
                            f"cronwatch: task {task} is scheduled {len(entries)} times ({labels}); a job has one schedule, "
                            f"so give it one with @cronwatch_task(schedule=...), or leave entries out with install(exclude=[...])"
                        ),
                        f"declaring task {task}",
                    )
            options.update({k: v for k, v in given.items() if not (k == "schedule" and v is None)})
            declarations[task] = _Declaration(task=task, name=name, options=options, where=where)
        return declarations

    def declarations(self, refresh: bool = False, report: Callable[[BaseException, str], None] | None = None) -> dict[str, _Declaration]:
        """The watched tasks by name, read again once REFRESH_S has passed."""
        with self._lock:
            stale = self._declarations is None or refresh or time.monotonic() - self._read_at > REFRESH_S
            if not stale:
                assert self._declarations is not None
                return self._declarations
            self._read_at = time.monotonic()
            try:
                self._declarations = self._read(report or self._report)
            except Exception as error:
                (report or self._report)(error, "reading Celery's tasks")
                if self._declarations is None:
                    self._declarations = {}
            return self._declarations

    def handle(self, task: str, declaration: _Declaration | None = None, *, strict: bool = False) -> JobHandle | None:
        """The job a task runs as, declared on the client (again, when the options or the client changed)."""
        found = declaration if declaration is not None else self.declarations().get(task)
        if found is None:
            return None
        client = self.client
        with self._lock:
            known = self._handles.get(task)
            if known is not None and known[0] is client and known[1] == found.options and known[2].name == found.name:
                return known[2]
            try:
                made = client.job(found.name, **found.options)
            except Exception as error:
                if strict:
                    raise
                self._report(error, f"declaring {found.where}")
                return None
            self._handles[task] = (client, dict(found.options), made)
            return made

    def declare(self, *, strict: bool = True) -> list[JobHandle]:
        """Declares every watched task's job on the client, reading beat afresh,
        so a check knows jobs that have not run in this process. With strict
        (the default) the first schedule that cannot be read, or job that
        cannot be declared, raises; otherwise each goes to on_error, once."""
        problems: list[BaseException] = []

        def keep(error: BaseException, where: str) -> None:
            problems.append(error)

        declarations = self.declarations(refresh=True, report=keep if strict else None)
        if problems:
            raise problems[0]
        found = [self.handle(task, declaration, strict=strict) for task, declaration in declarations.items()]
        return [handle for handle in found if handle is not None]

    # ------------------------------------------------------------ runs

    def _begin(self, task: Any, task_id: str | None) -> None:
        declarations = self.declarations()
        if task.name not in declarations and _task_options(task) is not None:
            # Decorated in a module imported since beat's schedule was read.
            declarations = self.declarations(refresh=True)
        declaration = declarations.get(task.name)
        handle = self.handle(task.name, declaration) if declaration is not None else None
        if handle is None:
            return
        client = handle._client
        execution = _Execution(client, handle.definition, TRIGGER, _run_id(task_id))
        execution.begin()
        setattr(task.request, _RUN, execution)

    def _fail_elsewhere(self, task_name: str, task_id: str | None, error: BaseException) -> None:
        """A run whose worker process is gone, failed from the main process."""
        if not task_id:
            return
        handle = self.handle(task_name)
        if handle is None:
            return
        client = handle._client
        prefix = f"{task_id}:"
        try:
            running = [run for run in client.store.running_runs() if run.job == handle.name and run.id.startswith(prefix)]
        except Exception as problem:
            client._report(problem, f"finishing {handle.name}")
            return
        for run in running:
            handle.resume(run.id).fail(error)


def _run_id(task_id: str | None) -> str | None:
    """The task's id and a suffix of its own: each attempt of a task (a retry
    keeps the id) is a run of its own, and the main process can find them."""
    if not isinstance(task_id, str) or not task_id or len(task_id) > 180 or task_id.startswith("pgcron:"):
        return None
    return f"{task_id}:{uuid.uuid4().hex[:12]}"


def default_client() -> Cronwatch:
    """The Django integration's client in a Django project that uses it, else cronwatch.client()."""
    django = sys.modules.get("cronwatch.django")
    if django is not None:
        try:
            from django.conf import settings

            if settings.configured:
                made: Cronwatch = django.client()
                return made
        except Exception:
            pass
    return cronwatch.client()


_watchers: dict[int, CeleryWatch] = {}
_watchers_lock = threading.Lock()


def install(
    app: Any = None,
    *,
    client: Cronwatch | Callable[[], Cronwatch] | None = None,
    beat: bool = True,
    django_celery_beat: bool | None = None,
    tasks: Mapping[str, Mapping[str, Any]] | None = None,
    exclude: Iterable[str] = (),
    **options: Any,
) -> CeleryWatch:
    """Watches the app's tasks (see the module's docstring). Call it once, where
    the app is made; calling it again for the app replaces what it set up.

    client:             a Cronwatch, or a function returning one. Default: see default_client().
    beat:               read beat's schedule. Default True.
    django_celery_beat: read django-celery-beat's PeriodicTask table too. Default: when it is installed.
    tasks:              {task name: options} for tasks to watch without the decorator.
    exclude:            beat entry keys and task names to leave alone.
    options:            job options (grace, timeout, failures_before_alert, tags...) for every job declared here.
    """
    target = app if app is not None else celery.current_app._get_current_object()
    watch = CeleryWatch(
        target,
        client=client,
        beat=beat,
        django_celery_beat=django_celery_beat,
        tasks=tasks or {},
        exclude=[exclude] if isinstance(exclude, str) else exclude,
        options=options,
    )
    with _watchers_lock:
        _watchers[id(target)] = watch
    return watch


def watch_for(app: Any) -> CeleryWatch | None:
    """What install() set up for an app, or None. A pool process that was
    spawned rather than forked has the app made again from a pickle, so an app
    of the same name that install() was given is taken for it."""
    if app is None:
        return None
    found = _watchers.get(id(app))
    if found is not None:
        return found
    main = getattr(app, "main", None)
    if main:
        for watch in reversed(list(_watchers.values())):
            if getattr(watch.app, "main", None) == main:
                return watch
    return None


def _watch_of(task: Any) -> CeleryWatch | None:
    if task is None:
        return None
    try:
        return watch_for(task._get_app())
    except Exception:
        return None


# ---------------------------------------------------------------- signals


def _run_of(task: Any) -> _Execution | None:
    request = getattr(task, "request", None)
    return getattr(request, _RUN, None) if request is not None else None


def _end(task: Any, result: Any, error: BaseException | None, threw: bool) -> None:
    request = task.request
    execution: _Execution | None = getattr(request, _RUN, None)
    if execution is None:
        return
    delattr(request, _RUN)
    execution.end(result, error, threw)


@signals.task_prerun.connect(weak=False, dispatch_uid="cronwatch.celery.prerun")
def _on_prerun(sender: Any = None, task_id: str | None = None, task: Any = None, **_: Any) -> None:
    task = task if task is not None else sender
    watch = _watch_of(task)
    if watch is None or task.name in SKIPPED_TASKS:
        return
    try:
        watch._begin(task, task_id)
    except Exception as error:
        watch._report(error, f"recording {task.name}")


@signals.task_success.connect(weak=False, dispatch_uid="cronwatch.celery.success")
def _on_success(sender: Any = None, result: Any = None, **_: Any) -> None:
    if sender is not None and _run_of(sender) is not None:
        _end(sender, result, None, False)


@signals.task_failure.connect(weak=False, dispatch_uid="cronwatch.celery.failure")
def _on_failure(sender: Any = None, task_id: str | None = None, exception: BaseException | None = None, **_: Any) -> None:
    if sender is None:
        return
    error = exception if exception is not None else RuntimeError("the task failed")
    if _run_of(sender) is not None:
        _end(sender, None, error, True)
        return
    # No run here: the main process of a worker whose child ran the task and was lost.
    if isinstance(exception, (WorkerLostError, TimeLimitExceeded, Terminated)):
        watch = _watch_of(sender)
        if watch is not None and sender.name not in SKIPPED_TASKS:
            try:
                watch._fail_elsewhere(sender.name, task_id, error)
            except Exception as problem:
                watch._report(problem, f"finishing {sender.name}")


@signals.task_retry.connect(weak=False, dispatch_uid="cronwatch.celery.retry")
def _on_retry(sender: Any = None, request: Any = None, reason: Any = None, **_: Any) -> None:
    if sender is None:
        return
    cause = getattr(reason, "exc", None)
    error: BaseException = cause if isinstance(cause, BaseException) else reason if isinstance(reason, BaseException) else Retry("cancelled by Celery")
    if _run_of(sender) is not None:
        _end(sender, None, error, True)
        return
    # The main process cancelled the task (its connection to the broker was lost).
    watch = _watch_of(sender)
    if watch is not None and request is not None and sender.name not in SKIPPED_TASKS:
        try:
            watch._fail_elsewhere(sender.name, getattr(request, "id", None), error)
        except Exception as problem:
            watch._report(problem, f"finishing {sender.name}")


@signals.task_revoked.connect(weak=False, dispatch_uid="cronwatch.celery.revoked")
def _on_revoked(sender: Any = None, request: Any = None, terminated: bool = False, signum: Any = None, **_: Any) -> None:
    if not terminated or sender is None or request is None:
        return
    watch = _watch_of(sender)
    if watch is None or sender.name in SKIPPED_TASKS:
        return
    try:
        watch._fail_elsewhere(sender.name, getattr(request, "id", None), Terminated(f"revoked and terminated (signal {signum})"))
    except Exception as problem:
        watch._report(problem, f"finishing {sender.name}")


@signals.task_postrun.connect(weak=False, dispatch_uid="cronwatch.celery.postrun")
def _on_postrun(sender: Any = None, task: Any = None, retval: Any = None, state: str | None = None, **_: Any) -> None:
    task = task if task is not None else sender
    if task is None or _run_of(task) is None:
        return
    # Reached without success, failure or retry: Ignore, Reject, or an exception
    # that went past Celery's handling (an interrupt, or an eager task with
    # task_eager_propagates), which is still in flight here.
    if state == celery.states.IGNORED:
        _end(task, None, None, False)
    elif state == celery.states.REJECTED:
        _end(task, None, retval if isinstance(retval, BaseException) else RuntimeError("the task was rejected"), True)
    else:
        in_flight = sys.exc_info()[1]
        _end(task, None, in_flight if in_flight is not None else RuntimeError(f"the task ended in state {state}"), True)


@signals.worker_init.connect(weak=False, dispatch_uid="cronwatch.celery.worker_init")
def _on_worker_init(sender: Any = None, **_: Any) -> None:
    """Declares the jobs before the pool starts, so every process knows them."""
    app = getattr(sender, "app", None)
    watch = watch_for(app)
    if watch is not None:
        watch.declare(strict=False)


# ---------------------------------------------------------------- the check


@shared_task(name=CHECK_TASK, bind=True, ignore_result=True)
def check(self: Any) -> str:
    """Looks for missed and stuck runs across every job, sends alerts, retries
    undelivered ones and prunes old runs (cw.check()), after declaring every
    watched job. Schedule it with beat every few minutes, once for the whole
    deployment; nothing else notices a job that never ran."""
    watch = watch_for(self._get_app())
    if watch is not None:
        watch.declare(strict=False)
    client = watch.client if watch is not None else default_client()
    result = client.check()
    jobs = len(result.jobs)
    alerts = len(result.alerts)
    return f"cronwatch: checked {jobs} job{'' if jobs == 1 else 's'}, sent {alerts} alert{'' if alerts == 1 else 's'}"
