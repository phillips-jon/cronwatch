"""What a job receives while it runs (job.ts): its context, with log() and
metric(), and the recorder that keeps its output and metrics."""

from __future__ import annotations

import contextvars
import threading
import time
from collections import deque
from collections.abc import Mapping
from typing import Any

from . import _js
from .output import OUTPUT_CAP, cap_output
from .types import Run

#: Lines are dropped from the front once the output is well past the cap; cap_output trims it exactly at the end.
KEEP = 64 * 1024


class AbortError(Exception):
    """Raised by AbortSignal.throw_if_aborted() once the signal has aborted."""


class AbortSignal:
    """A cancellation flag, like JavaScript's AbortSignal. A job's signal
    aborts once the job's timeout has passed; triage gets one that aborts when
    the client stops waiting. Nothing is interrupted: code that can stop early
    checks it."""

    def __init__(self, timeout_ms: float | None = None) -> None:
        self._deadline = None if timeout_ms is None else time.monotonic() + timeout_ms / 1000
        self._aborted = False
        self._settled = False
        self._lock = threading.Lock()

    @property
    def aborted(self) -> bool:
        with self._lock:
            if not self._aborted and not self._settled and self._deadline is not None and time.monotonic() >= self._deadline:
                self._aborted = True
            return self._aborted

    def abort(self) -> None:
        with self._lock:
            if not self._settled:
                self._aborted = True

    def throw_if_aborted(self) -> None:
        """Raises AbortError when aborted, for a loop that should stop there."""
        if self.aborted:
            raise AbortError("This operation was aborted")

    def settle(self) -> None:
        """Called when the work is over: a timeout that passes later no longer aborts it."""
        _ = self.aborted
        with self._lock:
            self._settled = True


def stringify(part: Any) -> str:
    """A logged value as text, the way the SDK writes it."""
    if isinstance(part, str):
        return part
    if isinstance(part, BaseException):
        return f"{type(part).__name__}: {part}"
    try:
        return _js.dumps(part)
    except (TypeError, ValueError, RecursionError):
        return str(part)


class RunRecorder:
    """Collects a run's output and metrics while its function runs."""

    def __init__(self, run: Run, timeout_ms: float | None) -> None:
        self._lines: deque[str] = deque()
        self._size = 0
        # The first lines logged, up to the cap, and whether any line has been
        # dropped from _lines: what expect_text needs once the output runs long.
        self._head: list[str] = []
        self._head_size = 0
        self._dropped = False
        self._metrics: dict[str, float] = {}
        self._lock = threading.Lock()
        self.signal = AbortSignal(timeout_ms)
        self.context = JobContext(run, self.signal, self)

    def log(self, line: str) -> None:
        length = _js.length16(line)
        with self._lock:
            if self._head_size < OUTPUT_CAP:
                self._head.append(line)
                self._head_size += length + 1
            self._lines.append(line)
            self._size += length + 1
            while self._size > KEEP and len(self._lines) > 1:
                self._size -= _js.length16(self._lines.popleft()) + 1
                self._dropped = True

    def metric(self, name: str, value: float) -> None:
        with self._lock:
            self._metrics[name] = value

    def output(self) -> str | None:
        with self._lock:
            return None if not self._lines else cap_output("\n".join(self._lines))

    def expect_text(self) -> str | None:
        """What an expect rule is checked against: everything logged, or when
        that ran long, the first 16 KB and the last 16 KB. The stored output
        keeps only the tail, so a "done" line printed early would otherwise be lost."""
        with self._lock:
            if not self._lines:
                return None
            everything = "\n".join(self._lines)
            if not self._dropped and _js.length16(everything) <= 2 * OUTPUT_CAP:
                return everything
            return _js.head16("\n".join(self._head), OUTPUT_CAP) + "\n" + _js.tail16(everything, OUTPUT_CAP)

    def metrics(self) -> dict[str, float]:
        with self._lock:
            return dict(self._metrics)


class JobContext:
    """What a job receives: its name, run id and start, a signal that aborts
    at the job's timeout, and log() and metric()."""

    def __init__(self, run: Run, signal: AbortSignal, recorder: RunRecorder) -> None:
        self.name = run.job
        self.run_id = run.id
        self.started_at = run.started_at
        self.signal = signal
        self._recorder = recorder

    def log(self, *parts: Any) -> None:
        """Append a line of output. Kept with the run, capped at 16 KB, shown in alerts and the dashboard."""
        self._recorder.log(" ".join(stringify(part) for part in parts))

    def metric(self, name: str, value: float) -> None:
        """Report a number for this run: tokens, cost, rows, anything. Watched against budgets and baselines."""
        if not _js.is_finite(value):
            raise ValueError(f'metric "{name}" must be a finite number')
        self._recorder.metric(str(name), value)

    def metrics(self, values: Mapping[str, float] | None = None, **more: float) -> None:
        for key, value in {**(values or {}), **more}.items():
            self.metric(key, value)

    @property
    def aborted(self) -> bool:
        """True once the job's timeout has passed. Honour it if the work can stop."""
        return self.signal.aborted


_current: contextvars.ContextVar[JobContext | None] = contextvars.ContextVar("cronwatch_current", default=None)


def current() -> JobContext | None:
    """The context of the run in progress here (this thread or task), or None.
    What a function wrapped with ``@job.monitor`` logs through."""
    return _current.get()
