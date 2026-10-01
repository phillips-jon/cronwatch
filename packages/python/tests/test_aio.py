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


class HeldInsert(MemoryStore):
    """A memory store whose inserts wait for `gate`, saying when one has started and when it has landed."""

    def __init__(self) -> None:
        super().__init__()
        self.entered = threading.Event()
        self.gate = threading.Event()
        self.inserted = threading.Event()

    def insert_run(self, run: Any) -> None:
        self.entered.set()
        assert self.gate.wait(10)
        super().insert_run(run)
        self.inserted.set()


@pytest.mark.parametrize("shape", ["function", "block"])
def test_cancelling_an_async_run_while_its_start_is_recorded_leaves_no_run_open(shape: str) -> None:
    """The insert lands in its worker thread whatever the task does, so the
    run is recorded as interrupted before the cancellation goes on, rather
    than left running for a check to call stuck."""
    store = HeldInsert()
    cw, _, alerts = make(store=store)
    job = cw.job("cancelled", timeout="5m")
    ran: list[bool] = []

    async def work(ctx: cronwatch.JobContext) -> None:
        ran.append(True)

    async def block() -> None:
        async with job.run():
            ran.append(True)

    async def main() -> None:
        task = asyncio.ensure_future(job.run(work) if shape == "function" else block())
        assert await asyncio.to_thread(store.entered.wait, 5)
        task.cancel()
        await asyncio.sleep(0)
        store.gate.set()
        with pytest.raises(asyncio.CancelledError):
            await task
        assert await asyncio.to_thread(store.inserted.wait, 5)

    run(main())
    assert ran == [], "the job never started"
    assert store.running_runs() == []
    [recorded] = cw.runs("cancelled")
    assert recorded.status == "failed"
    assert recorded.error.startswith("Interrupted: CancelledError")
    assert alerts.types() == ["failed"]


def test_cancelling_an_async_start_while_it_is_recorded_leaves_no_run_open() -> None:
    """AsyncJobHandle.start() the same way: the run its insert opened is
    finished as interrupted before the cancellation goes on."""
    store = HeldInsert()
    cw, _, alerts = make(store=store)
    job = AsyncCronwatch(cw).job("cancelled-start", timeout="5m")

    async def main() -> None:
        task = asyncio.ensure_future(job.start())
        assert await asyncio.to_thread(store.entered.wait, 5)
        task.cancel()
        await asyncio.sleep(0)
        store.gate.set()
        with pytest.raises(asyncio.CancelledError):
            await task
        assert await asyncio.to_thread(store.inserted.wait, 5)

    run(main())
    assert store.running_runs() == []
    [recorded] = cw.runs("cancelled-start")
    assert recorded.status == "failed"
    assert recorded.error.startswith("Interrupted: CancelledError")
    assert alerts.types() == ["failed"]


class HeldRead(MemoryStore):
    """A memory store whose get_run waits for `gate` once `hold` is set."""

    def __init__(self) -> None:
        super().__init__()
        self.hold = False
        self.entered = threading.Event()
        self.gate = threading.Event()

    def get_run(self, run_id: str) -> Any:
        if self.hold:
            self.entered.set()
            assert self.gate.wait(10)
        return super().get_run(run_id)


def test_cancelling_an_async_start_that_found_its_id_leaves_that_run_open() -> None:
    """A start whose id is already recorded opens nothing: it is handed the
    run begun elsewhere, which its cancellation leaves for its owner."""
    store = HeldRead()
    cw, _, _ = make(store=store)
    first = cw.job("shared", timeout="5m").start(id="one")
    store.hold = True
    job = AsyncCronwatch(cw).job("shared", timeout="5m")

    async def main() -> None:
        task = asyncio.ensure_future(job.start(id="one"))
        assert await asyncio.to_thread(store.entered.wait, 5)
        task.cancel()
        await asyncio.sleep(0)
        store.gate.set()
        with pytest.raises(asyncio.CancelledError):
            await task

    run(main())
    store.hold = False
    assert [r.id for r in store.running_runs()] == ["one"]
    assert first.finish() is not None


def test_start_checking_is_the_sync_clients_and_start_is_its_deprecated_alias() -> None:
    cw, _, _ = make()
    cw.check = lambda: cronwatch.CheckResult(checked_at=0, jobs=[], alerts=[], pruned=0)  # type: ignore[method-assign]
    acw = AsyncCronwatch(cw)
    acw.start_checking("1m")
    assert cw._ticker is not None
    acw.stop()
    with pytest.warns(DeprecationWarning, match="start_checking"):
        acw.start("1m")
    assert cw._ticker is not None
    acw.stop()
