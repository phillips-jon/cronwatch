"""The client (client.ts): declares jobs, records their runs, checks for
missed and stuck ones, and sends alerts.

Synchronous: a job runs in the caller's thread, and each state update holds a
per-job lock, so two runs (or a run and a check) in this process never write
a job's state over each other; other processes are kept in step by the
store's compare-and-set. The store failing never stops a job: store errors go
to ``on_error`` and the job's own outcome is returned or raised.
"""

from __future__ import annotations

import asyncio
import functools
import inspect
import logging
import os
import re
import threading
import time
import uuid
from collections.abc import Awaitable, Callable, Mapping, Sequence
from dataclasses import dataclass
from typing import TYPE_CHECKING, Any, ParamSpec, TypeVar, overload

from . import _js, _zone
from ._env import is_production
from ._response import response_status
from .alerts import ChannelContext, Console, channel_name, send_to
from .duration import Duration, format_duration, parse_duration
from .evaluate import (
    BASELINE_WINDOW,
    MAX_UNDELIVERED,
    SEND_LEASE_MS,
    Evaluation,
    apply_silence,
    empty_state,
    has_full_baseline,
    hold_alerts,
    is_silenced,
    is_stuck,
    normalize_state,
    on_check,
    on_run_finish,
    on_run_start,
    record_sent,
    release_sending,
    run_duration,
    silence_end,
    stale_alert,
    state_version,
    summarize,
    timeout_ms,
    unevaluable_summary,
)
from .format import compose_alert
from .job import AbortSignal, JobContext, RunRecorder, _current
from .output import cap_output, describe_error, redact_and_cap, redact_secrets
from .run_handle import RunHandle, _Retry
from .schedule import parse_schedule
from .serialize import check_expectation, to_stored
from .stores.memory import MemoryStore
from .types import (
    Alert,
    AlertType,
    CheckResult,
    JobDefinition,
    JobState,
    JobSummary,
    JobWithRuns,
    Run,
    RunStatus,
    StoredJob,
)

if TYPE_CHECKING:
    from .handler import Handler

T = TypeVar("T")
P = ParamSpec("P")
_log = logging.getLogger("cronwatch")

NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,119}")
TRIAGE_TIMEOUT_MS = 25_000
#: How long one channel may take to send one alert.
CHANNEL_TIMEOUT_MS = 15_000
PRUNE_INTERVAL_MS = 60 * 60_000
#: Wall-clock time one check spends retrying undelivered alerts, across every job.
RETRY_BUDGET_MS = 20_000
#: Reads and writes of one job's state before an update gives up on a store that keeps changing under it.
STATE_ATTEMPTS = 10
#: Runs read for a baseline, and the most read when failures crowd out the successes.
HISTORY_PAGE = BASELINE_WINDOW + 5
HISTORY_MAX = 200
#: Run ids that start with this belong to the pg_cron source.
RESERVED_RUN_ID_PREFIX = "pgcron:"
DEFAULT_OPTIONS = ("grace", "timeout", "timezone", "failures_before_alert")


class ChannelTimeout(Exception):
    """Handed to on_error when a channel or triage takes too long, or is
    skipped because its previous call has not finished."""


class CheckInterrupted(Exception):
    """What callers waiting on a shared check see when the check was stopped
    by an interrupt (KeyboardInterrupt, SystemExit). The caller that ran the
    check sees the original exception."""


@dataclass
class TriageContext:
    """What a triage function receives. Pass the signal to anything that can stop early."""

    alert: Alert
    recent_runs: list[Run]
    signal: AbortSignal


class _Unset:
    def __repr__(self) -> str:
        return "unset"


_UNSET: Any = _Unset()


def _js_string(value: Any) -> str:
    """String(value) as JavaScript writes it, for the messages below."""
    if value is None:
        return "null"
    if value is True or value is False:
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return _js.number(value)
    return str(value)


def _join_lines(before: str | None, after: str | None) -> str | None:
    """Two stretches of text as one, a line apart; either may be None."""
    if not before:
        return after
    if after is None:
        return before
    return f"{before}\n{after}"


def _join_output(before: str | None, after: str | None) -> str | None:
    """Output appended to stored output, capped like any run's."""
    joined = _join_lines(before, after)
    return None if joined is None else cap_output(joined)


def _clamp_limit(limit: Any, fallback: int, minimum: int) -> int:
    """A whole number in range, or the fallback for anything that is not a number."""
    n = int(limit) if _js.is_finite(limit) else fallback
    return min(500, max(minimum, n))


@dataclass
class _Held:
    """Alerts written with the state that opened their conditions, and how many older ones the queue let go."""

    alerts: list[Alert]
    dropped: int


def _check_run_id(job: str, run_id: Any, method: str) -> None:
    """Raises for a run id no store could hold, or one reserved for the pg_cron source."""
    if not isinstance(run_id, str) or run_id == "" or _js.length16(run_id) > 200:
        got = f"{_js.length16(run_id)} characters" if isinstance(run_id, str) else type(run_id).__name__
        raise ValueError(f'job "{job}": {method}() needs a run id of 1 to 200 characters (got {got})')
    # Postgres refuses NUL in text, so no store could hold such an id.
    if "\x00" in run_id:
        raise ValueError(f'job "{job}": {method}() cannot take a run id containing a NUL character')
    if run_id.startswith(RESERVED_RUN_ID_PREFIX):
        raise ValueError(
            f'job "{job}": {method}() cannot take a run id starting with "{RESERVED_RUN_ID_PREFIX}", which the pg_cron source uses for its runs'
        )


class _Flight:
    """One shared check: the first caller runs it, the others wait for its result."""

    def __init__(self) -> None:
        self._done = threading.Event()
        #: The thread running the check, which close() must not wait on.
        self.owner = threading.get_ident()
        self._value: CheckResult | None = None
        self._error: BaseException | None = None

    def resolve(self, value: CheckResult) -> None:
        self._value = value
        self._done.set()

    def reject(self, error: BaseException) -> None:
        self._error = error
        self._done.set()

    def wait(self) -> None:
        """Until the check is over, however it ended."""
        self._done.wait()

    def value(self) -> CheckResult:
        self._done.wait()
        if self._error is not None:
            raise self._error
        assert self._value is not None
        return self._value


class _Ticker:
    """Calls `tick` after `first` seconds, then every `interval` seconds counted
    from the start, in a daemon thread, until stopped."""

    def __init__(self, interval: float, first: float, tick: Callable[[], None]) -> None:
        self._wake = threading.Condition()
        self._stopped = False
        started = time.monotonic()

        def loop() -> None:
            first_at: float | None = started + first
            next_at = started + interval
            while True:
                due = min(first_at, next_at) if first_at is not None else next_at
                if not self._wait_until(due):
                    return
                clock = time.monotonic()
                if first_at is not None and clock >= first_at:
                    first_at = None
                else:
                    while next_at <= clock:
                        next_at += interval
                tick()

        self._thread = threading.Thread(target=loop, name="cronwatch-check", daemon=True)
        self._thread.start()

    def _wait_until(self, due: float) -> bool:
        with self._wake:
            while True:
                if self._stopped:
                    return False
                left = due - time.monotonic()
                if left <= 0:
                    return True
                self._wake.wait(left)

    def stop(self) -> None:
        with self._wake:
            self._stopped = True
            self._wake.notify_all()


def is_async_callable(fn: Any) -> bool:
    """An async def, or something whose call is one (a partial of one, an object with async __call__)."""
    return inspect.iscoroutinefunction(fn) or inspect.iscoroutinefunction(getattr(fn, "__call__", None))  # noqa: B004, whether __call__ is a coroutine function


class JobHandle:
    """A declared job. Keep it, and run the job through it:

        with job.run() as ctx:        # a block
            ctx.log("done")

        @job.monitor                  # a function, each call a run
        def nightly(): ...

        job.run(lambda ctx: work(ctx))   # a function taking the context

    Each works for async code too: ``async with job.run()``, ``@job.monitor``
    on an ``async def``, and ``await job.run(async_fn)``. The store is used
    from a worker thread then, so the event loop is not held up by it.
    """

    def __init__(self, client: Cronwatch, definition: JobDefinition) -> None:
        self._client = client
        #: The job as declared.
        self.definition = definition
        #: The job's name.
        self.name: str = definition.name

    @overload
    def run(self, fn: None = None, *, trigger: str = "run") -> _RunBlock: ...
    @overload
    def run(self, fn: Callable[[JobContext], Awaitable[T]], *, trigger: str = "run") -> Awaitable[T]: ...
    @overload
    def run(self, fn: Callable[[JobContext], T], *, trigger: str = "run") -> T: ...

    def run(self, fn: Callable[[JobContext], Any] | None = None, *, trigger: str = "run") -> Any:
        """With a function: run it now as a recorded run, passing the context.
        Returns what it returns and raises what it raises, after the run is
        recorded. A string it returns is the run's output when nothing was
        logged. An async function gives a coroutine to await instead. Without
        one: a context manager whose block is the run (``with`` or ``async with``)."""
        if fn is None:
            return _RunBlock(self._client, self.definition, trigger)
        if is_async_callable(fn):
            return self._client._aexecute(self.definition, trigger, fn)
        return self._client._execute(self.definition, trigger, fn)

    @overload
    def monitor(self, fn: Callable[P, T], *, trigger: str = "run") -> Callable[P, T]: ...
    @overload
    def monitor(self, fn: None = None, *, trigger: str = "run") -> Callable[[Callable[P, T]], Callable[P, T]]: ...

    def monitor(self, fn: Callable[..., Any] | None = None, *, trigger: str = "run") -> Any:
        """A decorator: every call of the function is a recorded run. Inside it,
        ``cronwatch.current()`` is the run's context, for log() and metric().
        An async function stays async: each await of it is a run."""

        def decorate(target: Callable[..., Any]) -> Callable[..., Any]:
            client = self._client
            definition = self.definition
            if is_async_callable(target):

                @functools.wraps(target)
                async def awrapper(*args: Any, **kwargs: Any) -> Any:
                    return await client._aexecute(definition, trigger, lambda _ctx: target(*args, **kwargs))

                return awrapper

            @functools.wraps(target)
            def wrapper(*args: Any, **kwargs: Any) -> Any:
                return client._execute(definition, trigger, lambda _ctx: target(*args, **kwargs))

            return wrapper

        return decorate(fn) if fn is not None else decorate

    def handler(self, fn: Callable[..., Any], *, secret: str | None = _UNSET) -> Handler:
        """A request handler that runs the function for each request carrying
        the cron secret and records the run: the SDK's handler(), for a
        platform cron (Vercel, a scheduler calling a URL). ``fn(ctx, request)``
        is called with the run's context and the request. See cronwatch.handler."""
        from .handler import make_handler

        return make_handler(self._client, self.definition, fn, secret)

    def start(self, *, trigger: str | None = None, id: str | None = None) -> RunHandle:  # noqa: A002
        """Record a running run now and finish it later, perhaps from another
        process (see resume()). ``id`` is your own stable id for the run, 1 to
        200 characters: a start with an id already recorded for this job
        records nothing and returns a handle on that run instead; an id
        recorded for another job raises. Store failures go to on_error; it
        never raises for them. A run that is never finished is marked stuck by
        the first check after the job's timeout."""
        return self._client._start_run(self.definition, trigger, id)

    def resume(self, run_id: str) -> RunHandle:
        """A handle on a run this job started elsewhere, by its id, so this process can log to it and finish it."""
        return self._client._resume_handle(self.definition, run_id)

    def __repr__(self) -> str:
        return f"JobHandle({self.name!r})"


class _RunBlock:
    """``with job.run() as ctx:`` or ``async with job.run() as ctx:``: the block is a recorded run."""

    def __init__(self, client: Cronwatch, definition: JobDefinition, trigger: str) -> None:
        self._client = client
        self._definition = definition
        self._trigger = trigger
        self._execution: _Execution | None = None

    def _fresh(self) -> _Execution:
        if self._execution is not None:
            raise RuntimeError("a job.run() block is entered once; call job.run() again for another run")
        self._execution = _Execution(self._client, self._definition, self._trigger)
        return self._execution

    def __enter__(self) -> JobContext:
        return self._fresh().begin()

    def __exit__(self, kind: Any, error: BaseException | None, tb: Any) -> None:
        assert self._execution is not None
        self._execution.end(None, error, error is not None)

    async def __aenter__(self) -> JobContext:
        execution = self._fresh()
        await _arecord_start(execution)
        return execution.enter()

    async def __aexit__(self, kind: Any, error: BaseException | None, tb: Any) -> None:
        execution = self._execution
        assert execution is not None
        execution.leave(None, error, error is not None)
        await asyncio.to_thread(execution.record_end)


@dataclass
class _Outcome:
    """How one run of a function ended: the run as recorded, and what the function returned or raised."""

    run: Run
    result: Any
    error: BaseException | None
    threw: bool


class _Execution:
    """One run of a function or a block. begin() records it as running and
    makes its context current; end() finishes it. Each is two halves, the
    store's (record_start, record_end) and the context's (enter, leave), so an
    async run can do the store's half in a worker thread and the context's in
    its own task."""

    def __init__(self, client: Cronwatch, definition: JobDefinition, trigger: str, run_id: str | None = None) -> None:
        self.client = client
        self.definition = definition
        self.trigger = trigger
        self.run_id = run_id

    def begin(self) -> JobContext:
        self.record_start()
        return self.enter()

    def end(self, result: Any, error: BaseException | None, threw: bool) -> None:
        self.leave(result, error, threw)
        self.record_end()

    def record_start(self) -> None:
        client = self.client
        name = self.definition.name
        client._after_fork_check()
        self.started_at = client.now()
        self.run = Run(
            id=self.run_id or str(uuid.uuid4()),
            job=name,
            status=RunStatus.RUNNING,
            started_at=self.started_at,
            trigger=self.trigger,
        )
        self.recorded = False
        try:
            client._sync(self.definition, confirm=True)
            client.store.insert_run(self.run.copy())
            self.recorded = True
        except Exception as error:
            client._report(error, f"recording {name}")
        # The SDK closes missed and stuck beside the running job; here it is
        # done just before the job runs. The result is the same.
        if self.recorded:
            try:
                client._update_state(name, lambda before: (on_run_start(before), None))
            except Exception as error:
                client._report(error, f"starting {name}")

    def enter(self) -> JobContext:
        self.recorder = RunRecorder(self.run, timeout_ms(self.definition))
        self._token = _current.set(self.recorder.context)
        return self.recorder.context

    def leave(self, result: Any, error: BaseException | None, threw: bool) -> None:
        client = self.client
        _current.reset(self._token)
        self.recorder.signal.settle()
        run = self.run
        finished_at = client.now()
        self.finished_at = finished_at
        run.finished_at = finished_at
        run.duration_ms = run_duration(self.started_at, finished_at)
        run.metrics = self.recorder.metrics()
        logged = self.recorder.output()
        run.output = logged if logged is not None else (result if isinstance(result, str) else None)
        seen = self.recorder.expect_text()
        expect_text = seen if seen is not None else (result if isinstance(result, str) else None)
        client._conclude(self.definition, run, result, error, threw, expect_text)

    def record_end(self) -> None:
        client = self.client
        name = self.definition.name
        run = self.run
        try:
            ignored = client._record_finish(self.definition, run, self.recorded, self.finished_at)
            if ignored:
                client._report(RuntimeError(f"run {run.id} of {name} {ignored}; ignored"), f"finishing {name}")
        except Exception as problem:
            client._report(problem, f"recording {name}")


async def _arecord_start(execution: _Execution) -> None:
    """execution.record_start() in a worker thread, for an async run. A
    cancellation while it is under way cannot stop the thread, whose insert
    still lands, so the run is not left running (to be called stuck later):
    the start is waited for, the run recorded as interrupted by the
    cancellation, and then the cancellation goes on."""
    started = asyncio.ensure_future(asyncio.to_thread(execution.record_start))
    try:
        await asyncio.shield(started)
    except asyncio.CancelledError as cancelled:

        async def interrupted() -> None:
            await started
            execution.enter()
            execution.leave(None, cancelled, True)
            await asyncio.to_thread(execution.record_end)

        await _settle(interrupted())
        raise


async def _settle(coroutine: Awaitable[None]) -> None:
    """Runs `coroutine` to its end, even when the task awaiting it is
    cancelled again meanwhile (the event loop shutting down still stops it)."""
    task = asyncio.ensure_future(coroutine)
    while not task.done():
        try:
            await asyncio.shield(task)
        except asyncio.CancelledError:
            pass
        except Exception:  # noqa: BLE001, record_end reports what goes wrong itself
            return


class Cronwatch:
    # Set by _reset_process_state(), again in a forked child.
    _pid: int
    _locks: dict[str, threading.RLock]
    _syncing: dict[str, threading.RLock]
    _check_lock: threading.Lock
    _checking: _Flight | None
    _ticker_lock: threading.Lock
    _ticker: _Ticker | None
    _ticker_ms: float | None
    _ready_lock: threading.Lock
    _sending_lock: threading.Lock
    _starting: dict[str, list[Any]]
    _abandoned: dict[Any, threading.Thread]

    """The client.

    store:    where jobs, runs and state live. Defaults to an in-memory store that forgets on restart.
    alerts:   where alerts go: channels (see cronwatch.alerts). Defaults to the console.
    triage:   a function taking a TriageContext and returning a short diagnosis, added to every alert but recoveries.
    sources:  where runs this process does not wrap come from. Each is synced at the start of every
              check(); one that raises is reported to on_error and the check carries on.
    cron_secret: the secret an outside cron must present to the check endpoint of the web dashboard
              (routes()). Defaults to $CRON_SECRET; "" counts as unset; None for none.
    retention: how long finished runs are kept. Default "30d".
    defaults: grace, timeout, timezone and failures_before_alert applied to every job unless it sets its own.
    redact:   applied to every run's output and error before it is stored, shown or sent. The default
              (output.redact_secrets) blanks values that look like secrets. Pass your own function, or
              False to keep output exactly as logged. A function that raises or returns something other
              than a str is reported to on_error ("redact") and the default is used.
    deliver:  "now" (the default) sends alerts from this process. "check" sends nothing from here: each
              alert is queued in the store and the next check, in a process that delivers now, sends it.
    on_error: called with (error, where) for anything that goes wrong outside a job: the store failing,
              an alert channel failing, a triage timeout. Defaults to the "cronwatch" logger.
    now:      the clock, a function returning epoch milliseconds. Tests use this.
    """

    def __init__(
        self,
        *,
        store: Any = None,
        alerts: Sequence[Any] | None = None,
        triage: Callable[[TriageContext], str | None] | None = None,
        sources: Sequence[Any] | None = None,
        cron_secret: str | None = _UNSET,
        retention: Duration = "30d",
        defaults: Mapping[str, Any] | None = None,
        redact: Callable[[str], str] | bool | None = None,
        deliver: str = "now",
        on_error: Callable[[BaseException, str], Any] | None = None,
        now: Callable[[], int] | None = None,
    ) -> None:
        self._using_default_store = store is None
        self.store: Any = store if store is not None else MemoryStore()
        self.alerts: list[Any] = [Console()] if alerts is None else list(alerts)
        self.triage = triage
        self.sources: list[Any] = [] if sources is None else list(sources)
        for source in self.sources:
            if not callable(getattr(source, "sync", None)):
                raise TypeError("a source must have sync(host)")
        secret = os.environ.get("CRON_SECRET") if cron_secret is _UNSET else cron_secret
        self.cron_secret: str | None = str(secret) if secret else None
        #: cron_secret was passed as None: handlers may run without a secret.
        self._secret_opt_out = cron_secret is None
        self._warned_no_secret = False
        self.retention_ms = parse_duration(retention if retention is not None else "30d", "retention")
        self.defaults: dict[str, Any] = {}
        for key, value in (defaults or {}).items():
            snake_key = next((k for k, v in JobDefinition.FIELDS.items() if v == key), key)
            if snake_key not in DEFAULT_OPTIONS:
                raise TypeError(f"defaults may set {', '.join(DEFAULT_OPTIONS)}, not {key}")
            self.defaults[snake_key] = value
        if redact is False:
            self._redact: Callable[[str], str] = lambda text: text
        elif redact is None or redact is True:
            self._redact = redact_secrets
        elif callable(redact):
            self._redact = self._guarded_redact(redact)
        else:
            raise TypeError("redact must be a function, or False to keep output as logged")
        if deliver not in ("now", "check"):
            try:
                shown = _js.dumps(deliver)
            except TypeError:
                shown = repr(deliver)
            raise ValueError(f'deliver must be "now" or "check", not {shown}')
        #: "check": queue alerts in the store for another process's check to send.
        self._defer_delivery = deliver == "check"
        self._clock = now if now is not None else (lambda: time.time_ns() // 1_000_000)
        self._on_error = on_error
        self._definitions: dict[str, JobDefinition] = {}
        self._synced: set[str] = set()
        self._registry = threading.RLock()
        self._ready = False
        self._last_prune_at = 0
        # Seconds before start()'s first check, and how long a channel or triage may take. Tests shorten them.
        self._first_tick_s = 1.0
        self._channel_timeout_ms: float = CHANNEL_TIMEOUT_MS
        self._triage_timeout_ms: float = TRIAGE_TIMEOUT_MS
        self._retry_budget_ms: float = RETRY_BUDGET_MS
        self._warned_deferred_start = False
        self._reset_process_state()

    # ------------------------------------------------------------ public API

    def now(self) -> int:
        """Epoch milliseconds, from the clock the client was given."""
        return self._clock()

    def job(self, name: str, **options: Any) -> JobHandle:
        """Declare a job. Call it once, when the module loads, and keep the handle.

        Options: schedule, timezone, grace, timeout, max_duration, budget,
        expect, failures_before_alert, description, tags."""
        if not isinstance(name, str) or not NAME_RE.fullmatch(name):
            raise ValueError(f'job name "{name}" must be 1 to 120 characters of letters, digits, ".", "_", ":" or "-"')
        definition = self._build_definition(name, options)
        self._validate_definition(definition)
        with self._registry:
            self._definitions[name] = definition
            self._synced.discard(name)
        return JobHandle(self, definition)

    def run(self, name: str, fn: Callable[[JobContext], T] | None = None, **options: Any) -> Any:
        """Run a job by name without keeping a handle, declaring it on first use
        (or again, when options are given). Without a function, a context manager."""
        with self._registry:
            declared = self._definitions.get(name)
        handle = self.job(name, **options) if options or declared is None else JobHandle(self, declared)
        return handle.run(fn)

    def defined_jobs(self) -> list[JobDefinition]:
        """The definitions declared in this process."""
        with self._registry:
            return list(self._definitions.values())

    def resume_run(self, name: str, run_id: str) -> RunHandle:
        """A handle on a run started elsewhere, as job(name).resume(run_id). The job must be declared in this process."""
        with self._registry:
            definition = self._definitions.get(name)
        if definition is None:
            raise ValueError(f'resume_run: job "{name}" is not declared; call job() first')
        return self._resume_handle(definition, run_id)

    def record_run(self, run: Run | Mapping[str, Any], *, evaluate: bool = True) -> list[Alert]:
        """Record a run that happened outside this process, for a source. Its job
        must be declared with job() first. Runs are keyed by id: a new one is
        inserted, a stored one still running (or marked timeout by a check) is
        finished when this one is not running, and anything else is left
        alone, so recording the same run twice changes nothing. When two
        processes record the same finish, only the one whose write lands
        evaluates it. ``evaluate=False`` stores it without judging it, for
        history imported on first sight. A metric that is not a finite number
        raises before anything is written, as metric() does. Returns the
        alerts it sent."""
        self._after_fork_check()
        given = run if isinstance(run, Run) else Run.from_dict(run)
        with self._registry:
            declared = self._definitions.get(given.job)
        if declared is None:
            raise ValueError(f'record_run: job "{given.job}" is not declared; call job() first')
        if "\x00" in given.id:
            raise ValueError(f'record_run: run ids cannot contain a NUL character (job "{given.job}")')
        # Refused as metric() refuses them: a store keeps NaN and Infinity as null.
        for metric, value in (given.metrics or {}).items():
            if not _js.is_finite(value):
                raise ValueError(f'record_run: metric "{metric}" must be a finite number (job "{given.job}", run "{given.id}")')
        self._sync(declared)
        run = given.copy()
        run.metrics = {str(k): v for k, v in (run.metrics or {}).items()}
        if run.status == RunStatus.OK:
            unmet = check_expectation(declared.expect, run.output)
            if unmet:
                run.status = RunStatus.FAILED
                run.error = unmet
        if run.output is not None:
            run.output = redact_and_cap(run.output, self._redact)
        if run.error is not None:
            run.error = redact_and_cap(run.error, self._redact)
        definition = to_stored(declared)

        stored = self.store.get_run(run.id)
        if stored is not None:
            return self._record_over(definition, stored, run, evaluate)
        try:
            self.store.insert_run(run)
        except Exception:
            # Another process recorded it first.
            try:
                again = self.store.get_run(run.id)
            except Exception:
                again = None
            if again is not None:
                return self._record_over(definition, again, run, evaluate)
            raise
        if not evaluate:
            return []
        self._update_state(run.job, lambda before: (on_run_start(before), None))
        if run.status == RunStatus.RUNNING:
            return []
        return self._finish_run(definition, run, self.now())

    def on_error(self, error: BaseException, where: str) -> None:
        """Hands an error to on_error, as a source reports what went wrong."""
        self._report(error, where)

    def check(self) -> CheckResult:
        """Look for missed and stuck runs across every job, send alerts, retry
        alerts no channel accepted, and prune old runs. Call it from start(), a
        scheduled task or by hand. Concurrent calls share one check."""
        self._after_fork_check()
        with self._check_lock:
            flight = self._checking
            mine = flight is None
            if flight is None:
                flight = self._checking = _Flight()
        if mine:
            try:
                flight.resolve(self._run_check())
            except BaseException as error:
                # An interrupt is meant for this thread only, so the waiters get
                # an error of their own and this thread the original.
                flight.reject(error if isinstance(error, Exception) else CheckInterrupted(f"the check was interrupted by {type(error).__name__}"))
                raise
            finally:
                with self._check_lock:
                    if self._checking is flight:
                        self._checking = None
        return flight.value()

    def jobs(self) -> list[JobSummary]:
        """Every job the store knows about, with its health. Does not send alerts."""
        return [entry.job for entry in self.jobs_with_runs(0)]

    def jobs_with_runs(self, limit: int = 20) -> list[JobWithRuns]:
        """Every job's summary with its newest `limit` runs, read together. What the dashboard shows."""
        self._after_fork_check()
        self._ensure_ready()
        stored_jobs = self._stored_jobs()
        at = self.now()
        count = _clamp_limit(limit, 20, 0)
        return [self._snapshot(stored, at, count) for stored in stored_jobs]

    def job_summary(self, name: str) -> JobSummary | None:
        """A job's summary, or None for one the store does not have. One declared
        here and forgotten elsewhere is written again, as a check would."""
        self._ensure_ready()
        with self._registry:
            definition = self._definitions.get(name)
        if definition is not None:
            self._sync(definition, confirm=True)
        stored = self.store.get_job(name)
        if stored is None:
            return None
        return self._snapshot(stored, self.now(), 0).job

    def runs(self, name: str, limit: int = 50) -> list[Run]:
        """A job's runs, newest first. `limit` is a whole number from 1 to 500."""
        self._ensure_ready()
        result: list[Run] = self.store.list_runs(name, _clamp_limit(limit, 50, 1))
        return result

    def get_run(self, run_id: str) -> Run | None:
        self._ensure_ready()
        result: Run | None = self.store.get_run(run_id)
        return result

    def silence(self, name: str, duration: Duration) -> JobState:
        """Stop alerts for a job for a while. State keeps updating underneath.
        The end is a whole millisecond, held at 2^53 - 1 (see silence_end)."""
        ms = parse_duration(duration, "silence duration")

        def change(state: JobState) -> None:
            state.silenced_until = silence_end(self.now(), ms)

        return self._patch_state(name, change)

    def unsilence(self, name: str) -> JobState:
        def change(state: JobState) -> None:
            state.silenced_until = None

        return self._patch_state(name, change)

    def forget(self, name: str) -> None:
        """Remove a job and its runs from the store. A job still declared in code
        comes back: here on its next run, and in any other process that
        declares it on its next run there, or at that process's next check or
        dashboard read."""
        self._ensure_ready()
        with self._registry:
            self._definitions.pop(name, None)
            self._synced.discard(name)
        self.store.delete_job(name)

    def routes(self, **options: Any) -> Any:
        """The dashboard and JSON API for this client: a cronwatch.web.Web, which
        is a WSGI app, with the same routes as an ASGI app in its .asgi. Takes
        token, base_path, origin and trust_proxy (see cronwatch.web)."""
        from .web import Web

        return Web(self, **options)

    def start(self, every: Duration = "1m") -> None:
        """Check on an interval, in a daemon thread, for long-running processes.
        Default every minute; the first check comes after a second. Calling it
        again while it runs does nothing (a different interval is reported to
        on_error and ignored: stop() first to change it). Not for a cron script
        that exits when done: call check() from a crontab line there instead."""
        self._after_fork_check()
        ms = max(5_000, parse_duration(every, "check interval"))
        with self._ticker_lock:
            if self._ticker is not None:
                if self._ticker_ms is not None and self._ticker_ms != ms:
                    self._report(
                        ValueError(f"start({every!r}) ignored: already checking every {format_duration(self._ticker_ms)}; call stop() first to change it"),
                        "start",
                    )
                return
            self._ticker_ms = ms
            if self._defer_delivery and not self._warned_deferred_start:
                self._warned_deferred_start = True
                _log.warning(
                    'start() was called with deliver="check", so these checks send no alerts. '
                    'Another process must run checks with deliver="now" (the default) to send them.'
                )

            def tick() -> None:
                try:
                    self.check()
                except Exception as error:
                    self._report(error, "check")

            self._ticker = _Ticker(ms / 1000, self._first_tick_s, tick)

    def stop(self) -> None:
        self._after_fork_check()
        with self._ticker_lock:
            ticker = self._ticker
            self._ticker = None
        if ticker is not None:
            ticker.stop()

    def close(self) -> None:
        """Stop the interval, wait for a check already under way (bounded by
        its own channel, triage and retry timeouts; what it raises was
        reported to whoever started it), then close the store, so that check
        neither writes after the store is closed nor loses the alerts it
        would queue. The interval's thread is waited for too, so a tick that
        woke just before the stop has not started a check the wait misses."""
        self._after_fork_check()
        with self._ticker_lock:
            ticker = self._ticker
        self.stop()
        if ticker is not None and ticker._thread is not threading.current_thread():
            ticker._thread.join()
        with self._check_lock:
            flight = self._checking
        if flight is not None and flight.owner != threading.get_ident():
            flight.wait()
        close = getattr(self.store, "close", None)
        if callable(close):
            close()

    # ------------------------------------------------------------ internals

    def _reset_process_state(self) -> None:
        """Locks, the check in flight, the interval thread and the channel and
        triage threads belong to one process. A forked child starts with fresh ones."""
        self._pid = os.getpid()
        self._locks = {}
        # Each job's lock for writing its declaration. See _sync().
        self._syncing = {}
        self._check_lock = threading.Lock()
        self._checking = None
        self._ticker_lock = threading.Lock()
        self._ticker = None
        self._ticker_ms = None
        self._ready_lock = threading.Lock()
        self._sending_lock = threading.Lock()
        # start() calls with an id still in flight: key -> [lock, callers].
        self._starting = {}
        # Channel (by index) and triage threads that timed out and are still going.
        self._abandoned = {}

    def _after_fork_check(self) -> None:
        if self._pid != os.getpid():
            self._registry = threading.RLock()
            self._reset_process_state()

    def _report(self, error: BaseException, where: str) -> None:
        """Hands an error to on_error. An on_error that raises is not allowed to take the job down with it."""
        try:
            if self._on_error is not None:
                self._on_error(error, where)
            else:
                _log.error("%s: %s: %s", where, type(error).__name__, error)
        except Exception as problem:
            _log.error("on_error raised %s: %s (reporting %s: %s)", type(problem).__name__, problem, where, error)

    def _guarded_redact(self, redact: Callable[[str], str]) -> Callable[[str], str]:
        """A custom redact, made safe: one that raises or returns something other
        than a str is reported and the default is used instead, so a broken
        redact neither stops the run finishing nor leaks what it was given."""

        def guarded(text: str) -> str:
            try:
                out = redact(text)
                if not isinstance(out, str):
                    raise TypeError(f"redact must return a string, not {'null' if out is None else type(out).__name__}")
                return _js.well_formed(out)
            except Exception as error:
                self._report(error, "redact")
                return redact_secrets(text)

        return guarded

    def _build_definition(self, name: str, options: Mapping[str, Any]) -> JobDefinition:
        unknown = [k for k in options if k not in JobDefinition.OPTIONS]
        if unknown:
            raise TypeError(f'job "{name}": unknown option {", ".join(unknown)}')
        fields: dict[str, Any] = {}
        for key, value in self.defaults.items():
            fields[JobDefinition.FIELDS[key]] = value
        for key, value in options.items():
            fields[JobDefinition.FIELDS[key]] = {str(k): v for k, v in value.items()} if key == "budget" and isinstance(value, Mapping) else value
        fields["name"] = name
        return JobDefinition(fields)

    def _validate_definition(self, definition: JobDefinition) -> None:
        """Raises a clear error for options that would otherwise quietly turn a check off."""
        name = definition.name
        if definition.schedule is not None:
            if not isinstance(definition.schedule, str) or _js.trim(definition.schedule) == "":
                raise ValueError(f'job "{name}": schedule must be a non-empty string')
            parse_schedule(definition.schedule, definition.timezone)
        if definition.timezone is not None and not _zone.is_valid(definition.timezone):
            raise ValueError(f'job "{name}": timezone "{definition.timezone}" is not an IANA timezone')
        if definition.grace is not None:
            parse_duration(definition.grace, "grace")
        if definition.timeout is not None and parse_duration(definition.timeout, "timeout") <= 0:
            raise ValueError(f'job "{name}": timeout must be longer than zero')
        if definition.max_duration is not None and parse_duration(definition.max_duration, "maxDuration") <= 0:
            raise ValueError(f'job "{name}": maxDuration must be longer than zero')
        failures = definition.failures_before_alert
        if failures is not None and not (_js.is_integer(failures) and failures >= 1):
            raise ValueError(f'job "{name}": failuresBeforeAlert must be a whole number, 1 or more (got {_js_string(failures)})')
        if definition.budget is not None:
            if not isinstance(definition.budget, Mapping):
                raise ValueError(f'job "{name}": budget must be an object of {{ metric: ceiling }}')
            for metric, ceiling in definition.budget.items():
                if not (_js.is_finite(ceiling) and ceiling >= 0):
                    raise ValueError(f'job "{name}": budget.{metric} must be a finite number, 0 or more (got {_js_string(ceiling)})')
        expect = definition.expect
        if expect is not None and not isinstance(expect, (str, re.Pattern)) and not callable(expect):
            raise ValueError(f'job "{name}": expect must be a string, a RegExp or a function')

    def _ensure_ready(self) -> None:
        if self._ready:
            return
        with self._ready_lock:
            if self._ready:
                return
            init = getattr(self.store, "init", None)
            if callable(init):
                init()
            if self._using_default_store and is_production():
                _log.warning(
                    "using the in-memory store: runs and state are lost on restart. Pass a store such as cronwatch.stores.SqliteStore."
                )
            # Only once init has gone through: a failure is tried again on the next call.
            self._ready = True

    def _sync(self, definition: JobDefinition, confirm: bool = False) -> None:
        """Writes the declaration of `definition`'s name as it stands, unless the
        store has it. A handle kept from an earlier declaration writes the one
        that replaced it, never its own over it, and one forgotten since writes
        its own. The writes of one name take turns, each reading what stands
        once its turn comes, so one still under way cannot land after a later
        one; and a name declared again while its write was under way is still
        to be written. A name is marked as written only while that same
        declaration stands, so a forget that lands during the write (deleting
        the row after it) leaves the name to be written again, as does one
        forgotten before it.

        With `confirm`, as a run starts, a name already written is read back:
        another process may have forgotten the job since, and a job still
        declared here comes back on its next run."""
        self._ensure_ready()
        name = definition.name
        with self._registry:
            written = name in self._synced
        if written:
            if not confirm or self.store.get_job(name) is not None:
                return
            with self._registry:
                self._synced.discard(name)
        with self._serial(name, syncing=True):
            with self._registry:
                if name in self._synced:
                    return
                standing = self._definitions.get(name, definition)
            self.store.upsert_job(to_stored(standing), self.now())
            with self._registry:
                if self._definitions.get(name) is standing:
                    self._synced.add(name)

    def _stored_jobs(self) -> list[StoredJob]:
        """Every stored job, once each declaration has been written. A job
        declared here that the store no longer has was forgotten by another
        process after this one wrote it: it is written again, as its next run
        would, so it is checked and shown while any process still declares it."""
        for definition in self.defined_jobs():
            self._sync(definition)
        jobs: list[StoredJob] = self.store.list_jobs()
        listed = {job.name for job in jobs}
        missing = [definition for definition in self.defined_jobs() if definition.name not in listed]
        if not missing:
            return jobs
        for definition in missing:
            with self._registry:
                # Not one forgotten here meanwhile.
                if self._definitions.get(definition.name) is not definition:
                    continue
                self._synced.discard(definition.name)
            self._sync(definition)
        again: list[StoredJob] = self.store.list_jobs()
        return again

    def _serial(self, job: str, syncing: bool = False) -> threading.RLock:
        """The job's lock: two runs (or a run and a check) in this process never
        read and write the job's state over each other. Other processes are
        coordinated by _update_state instead. With `syncing`, the lock of its
        own that _sync() writes the job's declaration under."""
        self._after_fork_check()
        with self._registry:
            locks = self._syncing if syncing else self._locks
            lock = locks.get(job)
            if lock is None:
                lock = locks[job] = threading.RLock()
            return lock

    def _read_state(self, job: str) -> JobState:
        return normalize_state(self.store.get_state(job), job)

    @staticmethod
    def _same_state(a: JobState, b: JobState) -> bool:
        return _js.dumps(a.to_dict()) == _js.dumps(b.to_dict())

    def _update_state(self, job: str, change: Callable[[JobState], tuple[JobState, T]]) -> tuple[JobState, T]:
        """Every read-modify-write of a job's state goes through here. Holding the
        job's lock, it reads the state, asks `change` for the next one, and
        writes it with the version one higher, only if the stored version is
        still the one read. When another process wrote in between, the write is
        refused and it starts again from a fresh read, up to STATE_ATTEMPTS
        times. So `change` may run more than once and must only compute.
        Nothing is written when the state is unchanged. Returns the state as
        stored and what `change` returned."""
        with self._serial(job):
            attempt = 0
            while True:
                attempt += 1
                current = self._read_state(job)
                state, result = change(current)
                if self._same_state(state, current):
                    return current, result
                version = state_version(current)
                following = state.copy()
                following.version = version + 1
                if self._write_state(following, version):
                    return following, result
                if attempt >= STATE_ATTEMPTS:
                    raise RuntimeError(f"the state of {job} changed under {STATE_ATTEMPTS} attempts in a row to update it; gave up")

    def _write_state(self, state: JobState, expected_version: int) -> bool:
        """A conditional write, or for a store without compare_and_set_state, a plain one that always succeeds."""
        cas = getattr(self.store, "compare_and_set_state", None)
        if callable(cas):
            return bool(cas(state, expected_version))
        self.store.set_state(state)
        return True

    def _patch_state(self, name: str, change: Callable[[JobState], None]) -> JobState:
        """Read, change and write one job's state, in turn with every other update to it."""
        self._ensure_ready()

        def apply(current: JobState) -> tuple[JobState, None]:
            following = normalize_state(current, name)
            change(following)
            return following, None

        state, _ = self._update_state(name, apply)
        return state

    def _execute(self, definition: JobDefinition, trigger: str, fn: Callable[[JobContext], T]) -> T:
        """Runs a function as a recorded run. The function always runs, whatever
        the store is doing: store errors go to on_error. Returns what it
        returns and raises what it raises, after the run is recorded."""
        outcome = self._execute_outcome(definition, trigger, fn)
        if outcome.threw:
            assert outcome.error is not None
            raise outcome.error
        result: T = outcome.result
        return result

    def _execute_outcome(self, definition: JobDefinition, trigger: str, fn: Callable[[JobContext], Any], run_id: str | None = None) -> _Outcome:
        """_execute(), handing back how the run ended instead of raising an
        Exception the function raised. Anything outside Exception
        (KeyboardInterrupt, SystemExit) is recorded and raised again."""
        if is_async_callable(fn):
            raise TypeError(f"job {definition.name}: this runs plain functions; await job.run(fn) or use @job.monitor for an async one")
        execution = _Execution(self, definition, trigger, run_id)
        context = execution.begin()
        try:
            result = fn(context)
            if inspect.iscoroutine(result):
                # A plain function that handed back a coroutine (a lambda around an
                # async call): it has not run, and cannot be awaited here.
                result.close()
                raise TypeError(
                    f"job {definition.name}: the function returned a coroutine, which cannot be awaited here; "
                    "pass the async function itself and await job.run(fn)"
                )
        except BaseException as error:
            execution.end(None, error, True)
            if not isinstance(error, Exception):
                raise
            return _Outcome(execution.run, None, error, True)
        execution.end(result, None, False)
        return _Outcome(execution.run, result, None, False)

    async def _aexecute(self, definition: JobDefinition, trigger: str, fn: Callable[[JobContext], Any]) -> Any:
        """_execute() for an async function: awaited in the caller's task, with
        the store's work done in a worker thread so the event loop is never
        held up by it."""
        outcome = await self._aexecute_outcome(definition, trigger, fn)
        if outcome.threw:
            assert outcome.error is not None
            raise outcome.error
        return outcome.result

    async def _aexecute_outcome(self, definition: JobDefinition, trigger: str, fn: Callable[[JobContext], Any]) -> _Outcome:
        execution = _Execution(self, definition, trigger)
        await _arecord_start(execution)
        context = execution.enter()
        try:
            result = fn(context)
            if inspect.isawaitable(result):
                result = await result
        except BaseException as error:
            # CancelledError too: the run is recorded as interrupted, then the cancellation goes on.
            execution.leave(None, error, True)
            await asyncio.to_thread(execution.record_end)
            if not isinstance(error, Exception):
                raise
            return _Outcome(execution.run, None, error, True)
        execution.leave(result, None, False)
        await asyncio.to_thread(execution.record_end)
        return _Outcome(execution.run, result, None, False)

    def _conclude(self, definition: JobDefinition, run: Run, result: Any, error: Any, threw: bool, expect_text: str | None) -> None:
        """Sets a finished run's status and error from how it ended, then redacts
        its output and error and caps them, in that order. Shared by runs and
        RunHandle.finish(). A result that is an HTTP response with a status of
        400 or more is a failure, as a fetch Response is in the SDK (see
        cronwatch._response)."""
        status = None if threw else response_status(result)
        if threw:
            run.status = RunStatus.FAILED
            run.error = describe_error(error)
        elif status is not None and status[0] >= 400:
            run.status = RunStatus.FAILED
            run.error = f"HTTP {status[0]}{' ' + status[1] if status[1] else ''}"
        else:
            unmet = check_expectation(definition.expect, expect_text)
            if unmet:
                run.status = RunStatus.FAILED
                run.error = unmet
            else:
                run.status = RunStatus.OK
        # Redacted after the expect check, so a rule can still match what was
        # logged, and before the cap, so the cut cannot keep half a secret.
        # NULs go last, so not even a custom redact can store one.
        if run.output is not None:
            run.output = redact_and_cap(run.output, self._redact)
        if run.error is not None:
            run.error = redact_and_cap(run.error, self._redact)

    def _record_finish(self, definition: JobDefinition, run: Run, recorded: bool, finished_at: int) -> str | None:
        """Writes a finished run and evaluates it. `recorded` says whether its
        start was written; if not, it is inserted now. Returns why nothing was
        recorded (another process finished the run first, say), or None.
        Raises when the store does, so a handle can be finished again."""
        if not recorded:
            # The start was never written; the store may be back by now.
            self._sync(definition)
            try:
                self.store.insert_run(run)
                self._finish_run(to_stored(definition), run, finished_at)
                return None
            except Exception:
                # Another process may have recorded a run with this id meanwhile.
                try:
                    stored = self.store.get_run(run.id)
                except Exception:
                    stored = None
                if stored is None:
                    raise
                if stored.job != run.job:
                    return f'belongs to job "{stored.job}"'
        late, ignored = self._claim_finish(run)
        if ignored:
            return ignored
        if not late or run.status == RunStatus.OK:
            self._finish_run(to_stored(definition), run, finished_at)
        return None

    def _write_run_if(self, run: Run, from_statuses: Sequence[RunStatus]) -> bool:
        """A conditional write (update_run_if), or for a store without one, a
        read then a plain write, which is safe only while one process at a time
        finishes a given run."""
        update_if = getattr(self.store, "update_run_if", None)
        if callable(update_if):
            return bool(update_if(run, list(from_statuses)))
        stored = self.store.get_run(run.id)
        if stored is None or stored.status not in from_statuses:
            return False
        self.store.update_run(run)
        return True

    def _claim_finish(self, run: Run) -> tuple[bool, str | None]:
        """Writes a finished run over its stored row, only while that row is still
        running, or else still marked timeout by a check. Only the process whose
        write lands goes on to evaluate the run. Returns (late_after_timeout,
        None) once written, or (False, why) when nothing was: late_after_timeout
        means a check already counted the run as a stuck failure, so a late
        failure must not count twice while a late success still closes stuck
        and recovers. Raises when the store does."""
        if self._write_run_if(run, [RunStatus.RUNNING]):
            return False, None
        if self._write_run_if(run, [RunStatus.TIMEOUT]):
            return True, None
        stored = self.store.get_run(run.id)
        return False, (f"was already finished as {stored.status}" if stored else "was not found")

    def _start_run(self, definition: JobDefinition, trigger: str | None, run_id: str | None) -> RunHandle:
        """job.start(): records a running run and returns a handle to finish it.
        Two starts with one id at once in this process record one run: the
        second waits for the first, then finds its run."""
        self._after_fork_check()
        trigger = "start" if trigger is None else trigger
        if run_id is None:
            return self._record_start(definition, trigger, None)
        _check_run_id(definition.name, run_id, "start")
        # Keyed by job as well, so another job's start with the same id is not
        # handed this job's run: it fails as it would one call later.
        key = f"{definition.name}\n{run_id}"
        with self._registry:
            entry = self._starting.get(key)
            if entry is None:
                entry = self._starting[key] = [threading.Lock(), 0]
            entry[1] += 1
        try:
            with entry[0]:
                return self._record_start(definition, trigger, run_id)
        finally:
            with self._registry:
                entry[1] -= 1
                if entry[1] == 0 and self._starting.get(key) is entry:
                    del self._starting[key]

    def _record_start(self, definition: JobDefinition, trigger: str, run_id: str | None) -> RunHandle:
        """The start of a run without the function: the run is inserted and missed
        and stuck close (on_run_start). A store that fails is reported and the
        handle inserts the finished run instead."""
        name = definition.name
        if run_id is not None:
            stored = None
            try:
                self._ensure_ready()
                stored = self.store.get_run(run_id)
            except Exception as error:
                self._report(error, f"recording {name}")
            if stored is not None:
                return self._existing_handle(definition, stored)
        run = Run(id=run_id or str(uuid.uuid4()), job=name, status=RunStatus.RUNNING, started_at=self.now(), trigger=trigger)
        recorded = False
        try:
            self._sync(definition, confirm=True)
            self.store.insert_run(run.copy())
            recorded = True
        except Exception as error:
            # Another process may have started a run with this id first.
            again = None
            if run_id is not None:
                try:
                    again = self.store.get_run(run_id)
                except Exception:
                    again = None
            if again is not None:
                return self._existing_handle(definition, again)
            self._report(error, f"recording {name}")
        if recorded:
            try:
                self._update_state(name, lambda before: (on_run_start(before), None))
            except Exception as error:
                self._report(error, f"starting {name}")
        handle = RunHandle(self, definition, run.id, run, recorded, None)
        handle._opened = True
        return handle

    def _resume_handle(self, definition: JobDefinition, run_id: str) -> RunHandle:
        """job.resume() and resume_run(). A store that cannot be read is reported, and finish() reads it again."""
        self._after_fork_check()
        _check_run_id(definition.name, run_id, "resume")
        try:
            self._ensure_ready()
            stored = self.store.get_run(run_id)
        except Exception as error:
            self._report(error, f"resuming {definition.name}")
            return RunHandle(self, definition, run_id, None, True, None)
        if stored is None:
            return RunHandle(self, definition, run_id, None, True, "was not found")
        return self._existing_handle(definition, stored)

    def _existing_handle(self, definition: JobDefinition, stored: Run) -> RunHandle:
        """A handle on a stored run. One still running, or marked timeout by a check, can be finished."""
        if stored.job != definition.name:
            raise ValueError(f'run "{stored.id}" belongs to job "{stored.job}", not "{definition.name}"')
        finished = stored.status in (RunStatus.OK, RunStatus.FAILED)
        return RunHandle(self, definition, stored.id, stored, True, f"already finished as {stored.status}" if finished else None)

    def _ignore_finish(self, run_id: str, name: str, why: str) -> None:
        """A finish that records nothing, reported rather than raised."""
        self._report(RuntimeError(f"run {run_id} of {name} {why}; ignored"), f"finishing {name}")

    def _finish_handle(self, handle: RunHandle, recorder: RunRecorder, failed: bool, result: Any, error: Any, head: str | None) -> Run | None:
        """RunHandle.finish(), in turn with the handle's flushes: the stored run,
        read again, with the handle's lines and metrics added, judged like any
        run. Returns the run as recorded, or None when nothing was. A store
        that fails is reported and raises _Retry, which leaves the handle
        active to be finished again."""
        definition = handle._definition
        name = definition.name
        run_id = handle.id
        base = handle._base
        recorded = handle._recorded
        source = base
        if recorded:
            try:
                source = self.store.get_run(run_id) or base
            except Exception as problem:
                self._report(problem, f"finishing {name}")
                raise _Retry() from problem
        if source is None:
            self._ignore_finish(run_id, name, "was not found")
            return None
        if source.job != name:
            self._ignore_finish(run_id, name, f'belongs to job "{source.job}"')
            return None
        if source.status in (RunStatus.OK, RunStatus.FAILED):
            self._ignore_finish(run_id, name, f"was already finished as {source.status}")
            return None
        finished_at = self.now()
        logged = recorder.output()
        added = logged if logged is not None else (result if isinstance(result, str) else None)
        run = source.copy()
        run.status = RunStatus.RUNNING
        run.finished_at = finished_at
        run.duration_ms = run_duration(source.started_at, finished_at)
        run.error = None
        # Capped by _conclude(), after it is redacted.
        run.output = _join_lines(source.output, added)
        run.metrics = {**(source.metrics or {}), **recorder.metrics()}
        seen = recorder.expect_text()
        expect_text = _join_lines(head, _join_lines(source.output, seen if seen is not None else (result if isinstance(result, str) else None)))
        self._conclude(definition, run, result, error, failed, expect_text)
        try:
            why = self._record_finish(definition, run, recorded, finished_at)
        except Exception as problem:
            self._report(problem, f"finishing {name}")
            raise _Retry() from problem
        if why:
            self._ignore_finish(run_id, name, why)
            return None
        return run

    def _flush_handle(self, handle: RunHandle, lines: str | None, metrics: Mapping[str, float]) -> bool:
        """RunHandle.flush(): appends lines and metrics to the stored run while it
        is still running and belongs to this job, written only over a row still
        running, so a flush never undoes a finish. True once written; False
        when the handle should keep them for finish()."""
        name = handle.job
        try:
            stored = self.store.get_run(handle.id)
            # Not running: the lines stay in the handle for finish, which reports why it cannot record them.
            if stored is None or stored.status != RunStatus.RUNNING:
                return False
            if stored.job != name:
                self._report(RuntimeError(f'run {handle.id} of {name} belongs to job "{stored.job}"; ignored'), f"flushing {name}")
                return False
            updated = stored.copy()
            if lines is not None:
                updated.output = _join_output(stored.output, redact_and_cap(lines, self._redact))
            updated.metrics = {**(stored.metrics or {}), **metrics}
            return self._write_run_if(updated, [RunStatus.RUNNING])
        except Exception as error:
            self._report(error, f"flushing {name}")
            return False

    def _record_over(self, definition: JobDefinition, stored: Run, run: Run, evaluate: bool) -> list[Alert]:
        """record_run() for a run already stored."""
        if stored.job != run.job:
            self._report(RuntimeError(f'run {run.id} of {run.job} belongs to job "{stored.job}"; ignored'), f"recording {run.job}")
            return []
        if stored.status not in (RunStatus.RUNNING, RunStatus.TIMEOUT) or run.status == RunStatus.RUNNING:
            return []
        late, ignored = self._claim_finish(run)
        if ignored:
            self._report(RuntimeError(f"run {run.id} of {run.job} {ignored}; ignored"), f"recording {run.job}")
            return []
        if not evaluate or (late and run.status != RunStatus.OK):
            return []
        return self._finish_run(definition, run, self.now())

    def _finish_run(self, definition: JobDefinition, run: Run, at: int) -> list[Alert]:
        """Evaluate a finished run (ok, failed, or timed out by a check), already
        written, against the job's state and send what that produces. The
        alerts are written with that state (see _outbox()). Never raises."""
        past: list[list[Run]] = []

        def change(previous: JobState) -> tuple[JobState, _Held]:
            if not past:
                past.append(self._history(run))
            return self._outbox(apply_silence(previous, on_run_finish(definition, run, previous, past[0], at), at), definition, at)

        try:
            _, held = self._update_state(run.job, change)
        except Exception as error:
            self._report(error, f"evaluating {run.job}")
            return []
        self._report_dropped(run.job, held.dropped)
        return self._dispatch(run.job, held.alerts, at)

    def _outbox(self, settled: Evaluation, definition: JobDefinition, at: int) -> tuple[JobState, _Held]:
        """An evaluation as it is written: its drafts composed into alerts and
        held in the same state (hold_alerts), so the write that opens a
        condition also keeps its alerts, and a process that stops before
        sending them does not lose them. Called inside _update_state(), so it
        only computes."""
        composed = [compose_alert(draft, definition, at) for draft in settled.alerts]
        held = hold_alerts(settled.state, composed, self.now() + SEND_LEASE_MS, self._defer_delivery)
        return held.state, _Held(composed, held.dropped)

    def _report_dropped(self, name: str, dropped: int) -> None:
        """Reports alerts let go because a job's queue was full."""
        if dropped <= 0:
            return
        self._report(
            RuntimeError(f"{dropped} undelivered alert{'' if dropped == 1 else 's'} for {name} dropped: only the newest {MAX_UNDELIVERED} are kept for retry"),
            f"alert queue for {name}",
        )

    def _history(self, run: Run) -> list[Run]:
        """The runs before `run`, newest first, with up to BASELINE_WINDOW
        successful ones when the store has them. One small read normally; a
        larger one only when failures crowd the successes out of it."""
        runs: list[Run] = self.store.list_runs(run.job, HISTORY_PAGE)
        if len(runs) == HISTORY_PAGE and not has_full_baseline([r for r in runs if r.id != run.id]):
            runs = self.store.list_runs(run.job, HISTORY_MAX)
        return [r for r in runs if r.id != run.id]

    def _run_check(self) -> CheckResult:
        self._ensure_ready()
        alerts: list[Alert] = []
        # Sources first, so what they record is evaluated in this check.
        for source in self.sources:
            try:
                found = source.sync(self)
                if found:
                    alerts.extend(found)
            except Exception as error:
                self._report(error, f"source {channel_name(source)}")
        for definition in self.defined_jobs():
            self._sync(definition)
        at = self.now()

        # Runs that never reported back. One that cannot be judged (its job's
        # stored timeout no longer parses, say) is reported and skipped.
        for listed in self.store.running_runs():
            try:
                with self._registry:
                    declared = self._definitions.get(listed.job)
                if declared is not None:
                    judged: JobDefinition | None = to_stored(declared)
                else:
                    stored_job = self.store.get_job(listed.job)
                    judged = stored_job.definition if stored_job else None
                if judged is None or not is_stuck(judged, listed, at):
                    continue
                # Read again just before the write: lines and metrics flushed since
                # the list was read (while earlier stuck runs were sent, say) are kept.
                run = self.store.get_run(listed.id)
                if run is None or run.status != RunStatus.RUNNING or run.job != listed.job:
                    continue
                timeout = timeout_ms(judged)
                run.status = RunStatus.TIMEOUT
                run.finished_at = at
                run.duration_ms = run_duration(run.started_at, at)
                run.error = f"Still running after {format_duration(timeout)}; marked as timed out"
                # Only over a row still running: a finish that landed meanwhile wins.
                if not self._write_run_if(run, [RunStatus.RUNNING]):
                    continue
                alerts.extend(self._finish_run(judged, run, at))
            except Exception as error:
                self._report(error, f"checking {listed.job}")

        # Each job on its own: one that cannot be evaluated is reported, shown
        # as failing (see unevaluable_summary) and does not stop the others.
        jobs: list[JobSummary] = []
        retries = [0.0]
        for stored in self._stored_jobs():
            try:
                recent = self.store.list_runs(stored.name, BASELINE_WINDOW)
                expected: list[int | None] = [None]

                def change(previous: JobState, stored: StoredJob = stored, recent: list[Run] = recent, expected: list[int | None] = expected) -> tuple[JobState, _Held]:
                    evaluation = on_check(stored.definition, stored, recent[0] if recent else None, previous, at)
                    expected[0] = evaluation.next_expected_at
                    settled = apply_silence(previous, evaluation, at)
                    # Alerts a process stopped sending part way go back to the retry queue.
                    released = release_sending(settled.state, self.now())
                    state, held = self._outbox(Evaluation(released.state, settled.alerts), stored.definition, at)
                    return state, _Held(held.alerts, released.dropped + held.dropped)

                state, held = self._update_state(stored.name, change)
                self._report_dropped(stored.name, held.dropped)
                alerts.extend(self._retry_undelivered(stored.name, state, at, retries))
                alerts.extend(self._dispatch(stored.name, held.alerts, at))
                jobs.append(summarize(stored, recent, state, expected[0], at))
            except Exception as error:
                self._report(error, f"checking {stored.name}")
                jobs.append(self._unevaluable(stored, at))

        pruned = 0
        if at - self._last_prune_at > PRUNE_INTERVAL_MS:
            self._last_prune_at = at
            try:
                pruned = self.store.prune(at - self.retention_ms)
            except Exception as error:
                self._report(error, "pruning")
        return CheckResult(checked_at=at, jobs=jobs, alerts=alerts, pruned=pruned)

    def _snapshot(self, stored: StoredJob, at: int, count: int) -> JobWithRuns:
        """A job's summary and its newest runs, without alerting. A job that cannot be evaluated is reported and shown as failing."""
        recent: list[Run] = []
        try:
            recent = self.store.list_runs(stored.name, max(count, BASELINE_WINDOW))
            state = self._read_state(stored.name)
            next_expected_at = on_check(stored.definition, stored, recent[0] if recent else None, state, at).next_expected_at
            return JobWithRuns(job=summarize(stored, recent, state, next_expected_at, at), runs=recent[:count])
        except Exception as error:
            self._report(error, f"reading {stored.name}")
            return JobWithRuns(job=self._unevaluable(stored, at), runs=recent[:count])

    def _unevaluable(self, stored: StoredJob, at: int) -> JobSummary:
        """The summary of a job whose evaluation failed, from whatever can still be read."""
        try:
            recent = self.store.list_runs(stored.name, BASELINE_WINDOW)
        except Exception:
            recent = []
        try:
            state = self._read_state(stored.name)
        except Exception:
            state = empty_state(stored.name)
        return unevaluable_summary(stored, recent, state, at)

    def _dispatch(self, name: str, alerts: list[Alert], at: int) -> list[Alert]:
        """Triage and send each alert the outbox holds (see _outbox()). The
        state, with the alerts in it, was saved before this, so a slow channel
        holds up nothing else; afterwards only the delivery fields are written
        back, onto a fresh read of the state, and the alerts leave `sending`.
        Triage is made here, never stored with the held alert: the write that
        opens a condition cannot wait for it, and a retry triages an alert
        that has none. With deliver="check" the alerts were queued for a
        check elsewhere instead."""
        if not alerts or self._defer_delivery:
            return alerts
        delivered: list[Alert] = []
        failed: list[Alert] = []
        for alert in alerts:
            if self.triage is not None and alert.type != AlertType.RECOVERED:
                self._add_triage(alert, self._triage_timeout_ms)
            (delivered if self._deliver(alert) else failed).append(alert)
        self._record_delivery(name, delivered, failed, [], at)
        return alerts

    def _retry_undelivered(self, name: str, state: JobState, at: int, budget: list[float]) -> list[Alert]:
        """Send the alerts that no channel accepted last time, once each, oldest
        first. An alert that no longer describes the job (stale_alert) is
        dropped instead. Retries across a check share RETRY_BUDGET_MS of
        wall-clock time; once it is spent the rest stay queued for the next check."""
        pending = state.undelivered or []
        if not pending or is_silenced(state, at) or self._defer_delivery:
            return []
        delivered: list[Alert] = []
        failed: list[Alert] = []
        dropped = [alert for alert in pending if stale_alert(alert, state)]
        for alert in pending:
            if any(alert is d for d in dropped):
                continue
            left = self._retry_budget_ms - budget[0]
            if left <= 0:
                break
            started = time.monotonic()
            # An alert queued by a process that delivers at check time was never
            # triaged. One that was tried (triage: null) is not tried again.
            if self.triage is not None and alert.type != AlertType.RECOVERED and not alert.triage_tried:
                self._add_triage(alert, min(self._triage_timeout_ms, left))
            (delivered if self._deliver(alert) else failed).append(alert)
            budget[0] += max(0.0, (time.monotonic() - started) * 1000)
        self._record_delivery(name, delivered, failed, dropped, at)
        return delivered

    def _record_delivery(self, name: str, delivered: list[Alert], failed: list[Alert], dropped: list[Alert], at: int) -> None:
        """Mark delivered alerts done, drop stale ones, and keep failed ones for
        the next check, taking them all out of `sending` (record_sent). A
        failed alert replaces its stored copy, so a triage made on this attempt
        is kept. last_alert_at moves only on a delivery. When this write fails,
        alerts still in `sending` are retried once their lease runs out."""

        def change(previous: JobState) -> tuple[JobState, int]:
            sent = record_sent(normalize_state(previous, name), delivered, failed, dropped, at)
            return sent.state, sent.dropped

        try:
            _, trimmed = self._update_state(name, change)
            self._report_dropped(name, trimmed)
        except Exception as error:
            self._report(error, f"recording alert delivery for {name}")

    def _deliver(self, alert: Alert) -> bool:
        """Send to every channel at once, each in a thread of its own with its own
        timeout. True when at least one accepted it, or there are none. A
        channel that times out is left to finish on its own, and nothing more
        is sent to it until it has: meanwhile its alerts count as not delivered
        there, to be retried by a later check. So a hung channel holds one
        thread, not one per alert."""
        if not self.alerts:
            return True
        outcomes: list[Any] = [None] * len(self.alerts)
        threads: list[threading.Thread | None] = []
        for i, channel in enumerate(self.alerts):
            with self._sending_lock:
                abandoned = self._abandoned.get(i)
                busy = abandoned is not None and abandoned.is_alive()
            if busy:
                outcomes[i] = ChannelTimeout("skipped: an earlier alert timed out and is still being sent")
                threads.append(None)
                continue

            def send(i: int = i, channel: Any = channel) -> None:
                try:
                    name = channel_name(channel)
                    context = ChannelContext(lambda error: self._report(error, f"alert channel {name}"))
                    send_to(channel, alert, context)
                    outcomes[i] = True
                except BaseException as error:  # a channel's failure is reported, never raised
                    outcomes[i] = error

            thread = threading.Thread(target=send, name=f"cronwatch-alert-{i}", daemon=True)
            thread.start()
            threads.append(thread)
        deadline = time.monotonic() + self._channel_timeout_ms / 1000
        results: list[Any] = []
        for i, sender in enumerate(threads):
            if sender is None:
                results.append(outcomes[i])
                continue
            sender.join(max(0.0, deadline - time.monotonic()))
            if sender.is_alive():
                with self._sending_lock:
                    self._abandoned[i] = sender
                results.append(ChannelTimeout(f"timed out after {_js.number(self._channel_timeout_ms)}ms"))
            else:
                results.append(outcomes[i])
        for i, result in enumerate(results):
            if result is not True:
                self._report(result if isinstance(result, BaseException) else RuntimeError(str(result)), f"alert channel {channel_name(self.alerts[i])}")
        return any(result is True for result in results)

    def _add_triage(self, alert: Alert, timeout: float) -> None:
        """Sets the alert's triage to the diagnosis, or to None (JSON null) when
        there is none (it raised, timed out or answered None or ""), so it is
        tried once per alert. While a triage that timed out is still going,
        alerts go out without one rather than start another beside it."""
        signal = AbortSignal()
        try:
            with self._sending_lock:
                abandoned = self._abandoned.get("triage")
                if abandoned is not None and abandoned.is_alive():
                    raise ChannelTimeout("skipped: an earlier triage timed out and is still running")
            recent = self.store.list_runs(alert.job, 5)
            context = TriageContext(alert=alert, recent_runs=recent, signal=signal)
            outcome: list[Any] = []
            triage = self.triage
            assert triage is not None

            def ask() -> None:
                try:
                    outcome.append((True, triage(context)))
                except BaseException as error:  # reported below
                    outcome.append((False, error))

            thread = threading.Thread(target=ask, name="cronwatch-triage", daemon=True)
            thread.start()
            thread.join(timeout / 1000)
            if thread.is_alive():
                with self._sending_lock:
                    self._abandoned["triage"] = thread
                raise ChannelTimeout(f"timed out after {_js.number(timeout)}ms")
            ok, value = outcome[0]
            if not ok:
                raise value
            alert.set_triage(_js.well_formed(value) if isinstance(value, str) and value != "" else None)
        except Exception as error:
            signal.abort()
            alert.set_triage(None)
            self._report(error, f"triage for {alert.job}")
