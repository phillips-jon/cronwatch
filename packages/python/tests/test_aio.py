"""Async jobs: the synchronous JobHandle with async functions (async with,
an async @monitor, await job.run(fn)) and cronwatch.aio's AsyncCronwatch,
with the store kept off the event loop."""

from __future__ import annotations

import asyncio
import inspect
import threading
from typing import Any

import pytest

import cronwatch
from cronwatch.aio import AsyncCronwatch, AsyncRunHandle
from cronwatch.stores import MemoryStore

from helpers import MIN, Capture, Clock, make


class OffLoop(MemoryStore):
    """A memory store that notes whether each call came from the event loop's thread."""

    def __init__(self) -> None:
        super().__init__()
        self.loop_thread: int | None = None
        self.on_loop: list[str] = []

    def __getattribute__(self, name: str) -> Any:
        value = super().__getattribute__(name)
        if callable(value) and not name.startswith("_") and name not in ("on_loop", "loop_thread"):
            loop = super().__getattribute__("loop_thread")
            if loop is not None and threading.get_ident() == loop:
                super().__getattribute__("on_loop").append(name)
        return value


def run(coroutine: Any) -> Any:
    return asyncio.run(coroutine)


def test_async_functions_run_through_the_sync_handle_as_recorded_runs() -> None:
    cw, clock, alerts = make()
    job = cw.job("a", schedule="every 1h")

    @job.monitor
    async def work(rows: int) -> int:
        context = cronwatch.current()
        assert context is not None
        context.log("rows", rows)
        context.metric("rows", rows)
        await asyncio.sleep(0)
        clock.advance(250)
        return rows * 2

    assert inspect.iscoroutinefunction(work), "it stays async"
    assert run(work(21)) == 42
    [done] = cw.runs("a")
    assert (done.status, done.output, done.metrics, done.duration_ms) == ("ok", "rows 21", {"rows": 21}, 250)
    assert cronwatch.current() is None

    async def block() -> None:
        async with job.run() as ctx:
            ctx.log("in a block")

    run(block())
    assert cw.runs("a")[0].output == "in a block"

    async def fail(ctx: cronwatch.JobContext) -> None:
        raise ValueError("async boom")

    with pytest.raises(ValueError, match="async boom"):
        run(job.run(fail))
    assert cw.runs("a")[0].error.startswith("ValueError: async boom\n    at fail (")
    assert alerts.types() == ["failed"]
    async def fine(ctx: cronwatch.JobContext) -> str:
        return "awaited"

    assert run(job.run(fine)) == "awaited"
    assert alerts.types() == ["failed", "recovered"]


def test_a_cancelled_run_is_recorded_as_interrupted_and_the_cancellation_goes_on() -> None:
    cw, _, _ = make()
    job = cw.job("c")
    started = asyncio.Event()

    async def forever(ctx: cronwatch.JobContext) -> None:
        started.set()
        await asyncio.sleep(3600)

    async def main() -> None:
        task = asyncio.create_task(job.run(forever))
        await started.wait()
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task

    run(main())
    [done] = cw.runs("c")
    assert done.status == "failed"
    assert done.error.split("\n")[0] == "Interrupted: CancelledError"


def test_concurrent_async_runs_each_see_their_own_context() -> None:
    cw, _, _ = make()
    job = cw.job("many")

    @job.monitor
    async def work(n: int) -> None:
        for _ in range(3):
            current = cronwatch.current()
            assert current is not None
            current.log(f"n={n}")
            await asyncio.sleep(0)

    async def main() -> None:
        await asyncio.gather(*(work(n) for n in range(5)))

    run(main())
    outputs = sorted(r.output for r in cw.runs("many"))
    assert outputs == [f"n={n}\nn={n}\nn={n}" for n in range(5)]


def test_the_async_client_keeps_the_store_off_the_event_loop() -> None:
    store = OffLoop()
    clock = Clock()
    alerts = Capture()
    cw = AsyncCronwatch(store=store, now=clock.now, alerts=[alerts], cron_secret=None)
    nightly = cw.job("nightly", schedule="every 1h", grace="10m")

    async def main() -> None:
        store.loop_thread = threading.get_ident()

        @nightly.monitor
        async def build() -> str:
            return "Report written"

        assert await build() == "Report written"
        async with nightly.run() as ctx:
            ctx.log("block")
        assert await nightly.run(lambda ctx: "plain, in a thread") == "plain, in a thread"
        handle = await nightly.start(id="batch-1")
        assert isinstance(handle, AsyncRunHandle)
        handle.log("sent 40 emails")
        await handle.flush()
        again = await cw.resume_run("nightly", "batch-1")
        finished = await again.finish()
        assert finished is not None and finished.output == "sent 40 emails"
        assert [r.output for r in await cw.runs("nightly")] == ["sent 40 emails", "plain, in a thread", "block", "Report written"]
        clock.advance(71 * MIN)
        result = await cw.check()
        assert [a.type for a in result.alerts] == ["missed"]
        [summary] = await cw.jobs()
        assert summary.health == "late"
        await cw.silence("nightly", "1h")
        assert (await cw.job_summary("nightly")).silenced_until is not None
        await cw.unsilence("nightly")
        assert len((await cw.jobs_with_runs(2))[0].runs) == 2
        run_id = (await cw.runs("nightly"))[0].id
        assert (await cw.get_run(run_id)).id == run_id
        await cw.forget("nightly")
        assert await cw.jobs() == []
        await cw.close()

    run(main())
    assert store.on_loop == [], f"store calls made on the event loop: {store.on_loop}"
    assert alerts.types() == ["missed"]


def test_the_async_client_shares_a_synchronous_one() -> None:
    sync, _, _ = make()
    shared = AsyncCronwatch(sync)
    assert shared.sync is sync
    run(shared.run("adhoc", lambda ctx: None))
    assert [r.job for r in sync.runs("adhoc")] == ["adhoc"]
    with pytest.raises(TypeError, match="not both"):
        AsyncCronwatch(sync, alerts=[])


def test_an_async_run_whose_store_fails_still_runs_and_reports() -> None:
    errors: list[str] = []

    class Broken(MemoryStore):
        def insert_run(self, run: Any) -> None:
            raise RuntimeError("store down")

    cw, _, _ = make(store=Broken(), on_error=lambda e, where: errors.append(where))

    async def work(ctx: cronwatch.JobContext) -> str:
        return "ran"

    assert run(cw.job("s").run(work)) == "ran"
    assert errors == ["recording s", "recording s"]
