"""The async client, for apps built on asyncio (FastAPI, Starlette, aiohttp,
an async worker): the client's methods as coroutines, and jobs that run async
functions.

    from cronwatch.aio import AsyncCronwatch
    from cronwatch.stores import SqliteStore

    cw = AsyncCronwatch(store=SqliteStore("./data/cronwatch.db"))
    nightly = cw.job("nightly-report", schedule="0 2 * * *", grace="15m")

    async with nightly.run() as ctx:          # a block
        ctx.log("Report written")

    @nightly.monitor                           # each await of it is a run
    async def build_report() -> None:
        cronwatch.current().log("Report written")

    await nightly.run(lambda ctx: sync_accounts(ctx))   # awaited, returns what it returns
    result = await cw.check()

It is the synchronous client underneath (``cw.sync``), with every store read
and write, alert and triage done in a worker thread (asyncio.to_thread), so
the event loop is never held up by the store or a channel, and async and sync
code in one process share jobs, locks and state. The job's own coroutine runs
in the caller's task, where ``cronwatch.current()`` is its context. A plain
function passed to ``run()`` runs in a worker thread too. ``start()`` checks
in a daemon thread, as the synchronous client's does.

The synchronous JobHandle takes async functions as well (``async with
job.run()``, ``@job.monitor`` on an ``async def``, ``await job.run(fn)``), so a
process that made a synchronous client (a Django project) can run async jobs
without this module.
"""

from __future__ import annotations

import asyncio
from collections.abc import Callable, Mapping
from typing import Any

from .client import Cronwatch, JobHandle, is_async_callable
from .duration import Duration
from .job import JobContext
from .run_handle import UNSET, RunHandle
from .types import Alert, CheckResult, JobDefinition, JobState, JobSummary, JobWithRuns, Run

__all__ = ["AsyncCronwatch", "AsyncJobHandle", "AsyncRunHandle"]


class AsyncRunHandle:
    """RunHandle with flush(), finish() and fail() as coroutines. log() and
    metric() only add to the handle, so they stay plain calls."""

    def __init__(self, handle: RunHandle) -> None:
        #: The synchronous handle underneath.
        self.sync = handle

    @property
    def id(self) -> str:
        return self.sync.id

    @property
    def job(self) -> str:
        return self.sync.job

    @property
    def started_at(self) -> int | None:
        return self.sync.started_at

    @property
    def active(self) -> bool:
        return self.sync.active

    def log(self, *parts: Any) -> None:
        self.sync.log(*parts)

    def metric(self, name: str, value: float) -> None:
        self.sync.metric(name, value)

    def metrics(self, values: Mapping[str, float] | None = None, **more: float) -> None:
        self.sync.metrics(values, **more)

    async def flush(self) -> None:
        await asyncio.to_thread(self.sync.flush)

    async def finish(self, outcome: Any = None, *, result: Any = UNSET, error: Any = UNSET) -> Run | None:
        return await asyncio.to_thread(lambda: self.sync.finish(outcome, result=result, error=error))

    async def fail(self, error: Any) -> Run | None:
        return await asyncio.to_thread(self.sync.fail, error)

    def __repr__(self) -> str:
        return f"AsyncRunHandle(id={self.id!r}, job={self.job!r}, active={self.active})"


class AsyncJobHandle:
    """A declared job, run from async code. See the module's docstring."""

    def __init__(self, handle: JobHandle) -> None:
        #: The synchronous handle underneath.
        self.sync = handle
        #: The job as declared.
        self.definition: JobDefinition = handle.definition
        #: The job's name.
        self.name: str = handle.name

    def run(self, fn: Callable[[JobContext], Any] | None = None, *, trigger: str = "run") -> Any:
        """With a function: a coroutine that runs it as a recorded run and
        returns what it returns (an async function is awaited in the caller's
        task; a plain one runs in a worker thread). Without one: an async
        context manager whose block is the run."""
        if fn is None:
            return self.sync.run(trigger=trigger)
        if is_async_callable(fn):
            coroutine: Any = self.sync.run(fn, trigger=trigger)
            return coroutine
        return asyncio.to_thread(self.sync.run, fn, trigger=trigger)

    def monitor(self, fn: Callable[..., Any] | None = None, *, trigger: str = "run") -> Any:
        """A decorator: every call of the function is a recorded run. An async
        function stays async (each await is a run); a plain one stays plain."""
        return self.sync.monitor(fn, trigger=trigger)

    def handler(self, fn: Callable[..., Any], *, secret: str | None = UNSET) -> Any:
        """The SDK's fetch-style job handler; see cronwatch.handler."""
        if secret is UNSET:
            return self.sync.handler(fn)
        return self.sync.handler(fn, secret=secret)

    async def start(self, *, trigger: str | None = None, id: str | None = None) -> AsyncRunHandle:  # noqa: A002
        """job.start(), awaited: records a running run to finish later."""
        return AsyncRunHandle(await asyncio.to_thread(lambda: self.sync.start(trigger=trigger, id=id)))

    async def resume(self, run_id: str) -> AsyncRunHandle:
        return AsyncRunHandle(await asyncio.to_thread(self.sync.resume, run_id))

    def __repr__(self) -> str:
        return f"AsyncJobHandle({self.name!r})"


class AsyncCronwatch:
    """The client for async code. Takes Cronwatch()'s options, or ``client=``
    a synchronous client to share (cronwatch.client(), a Django project's)."""

    def __init__(self, client: Cronwatch | None = None, **options: Any) -> None:
        if client is not None and options:
            raise TypeError("AsyncCronwatch takes a client or the options to make one, not both")
        #: The synchronous client underneath.
        self.sync: Cronwatch = client if client is not None else Cronwatch(**options)

    @property
    def store(self) -> Any:
        return self.sync.store

    def now(self) -> int:
        return self.sync.now()

    def job(self, name: str, **options: Any) -> AsyncJobHandle:
        """Declare a job (no I/O: the store hears of it on its first run or check)."""
        return AsyncJobHandle(self.sync.job(name, **options))

    def run(self, name: str, fn: Callable[[JobContext], Any] | None = None, **options: Any) -> Any:
        """Run a job by name, declaring it on first use (or again, with options). Without a function, an async block."""
        with self.sync._registry:
            declared = self.sync._definitions.get(name)
        handle = self.job(name, **options) if options or declared is None else AsyncJobHandle(JobHandle(self.sync, declared))
        return handle.run(fn)

    def defined_jobs(self) -> list[JobDefinition]:
        return self.sync.defined_jobs()

    async def check(self) -> CheckResult:
        return await asyncio.to_thread(self.sync.check)

    async def jobs(self) -> list[JobSummary]:
        return await asyncio.to_thread(self.sync.jobs)

    async def jobs_with_runs(self, limit: int = 20) -> list[JobWithRuns]:
        return await asyncio.to_thread(self.sync.jobs_with_runs, limit)

    async def job_summary(self, name: str) -> JobSummary | None:
        return await asyncio.to_thread(self.sync.job_summary, name)

    async def runs(self, name: str, limit: int = 50) -> list[Run]:
        return await asyncio.to_thread(self.sync.runs, name, limit)

    async def get_run(self, run_id: str) -> Run | None:
        return await asyncio.to_thread(self.sync.get_run, run_id)

    async def silence(self, name: str, duration: Duration) -> JobState:
        return await asyncio.to_thread(self.sync.silence, name, duration)

    async def unsilence(self, name: str) -> JobState:
        return await asyncio.to_thread(self.sync.unsilence, name)

    async def forget(self, name: str) -> None:
        await asyncio.to_thread(self.sync.forget, name)

    async def record_run(self, run: Run | Mapping[str, Any], *, evaluate: bool = True) -> list[Alert]:
        return await asyncio.to_thread(lambda: self.sync.record_run(run, evaluate=evaluate))

    async def resume_run(self, name: str, run_id: str) -> AsyncRunHandle:
        return AsyncRunHandle(await asyncio.to_thread(self.sync.resume_run, name, run_id))

    def on_error(self, error: BaseException, where: str) -> None:
        self.sync.on_error(error, where)

    def routes(self, **options: Any) -> Any:
        """The dashboard (cronwatch.web.Web); mount its .asgi, which handles each request in a worker thread."""
        return self.sync.routes(**options)

    def start(self, every: Duration = "1m") -> None:
        """Check on an interval, in a daemon thread (it never blocks the event loop)."""
        self.sync.start(every)

    def stop(self) -> None:
        self.sync.stop()

    async def close(self) -> None:
        await asyncio.to_thread(self.sync.close)

    def __repr__(self) -> str:
        return f"AsyncCronwatch({self.sync!r})"
