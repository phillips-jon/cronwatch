"""A run recorded by ``job.start()`` or found by ``job.resume()``, to finish
later, perhaps in another process. Lines and metrics wait in the handle until
flush() or finish(). Store failures go to on_error; none of these methods
raises for them.

    run = sync.start(id=event_id)
    # later, perhaps elsewhere
    run = sync.resume(event_id)
    run.log("sent 40 emails")
    run.finish()                  # or run.fail(error)
"""

from __future__ import annotations

import threading
from collections.abc import Mapping
from typing import TYPE_CHECKING, Any

from . import _js
from ._job import RunRecorder
from ._output import OUTPUT_CAP
from .types import Run, RunStatus

if TYPE_CHECKING:
    from ._client import Cronwatch
    from .types import JobDefinition

__all__ = ["RunHandle", "UNSET", "read_outcome"]


class _Retry(Exception):
    """The store failed part way through a finish and nothing was recorded
    (already reported): the handle stays active to be finished again."""


class _Unset:
    def __repr__(self) -> str:
        return "unset"


UNSET: Any = _Unset()


def read_outcome(outcome: Any, result: Any = UNSET, error: Any = UNSET) -> tuple[bool, Any, Any]:
    """(failed, result, error) from what finish() was given. A mapping with an
    "error" key, or error=, is a failure; a string, a mapping's "result", or
    result=, is the result."""
    if error is not UNSET:
        return True, None, error
    if result is not UNSET:
        return False, result, None
    if isinstance(outcome, str):
        return False, outcome, None
    if isinstance(outcome, Mapping):
        if "error" in outcome:
            return True, None, outcome["error"]
        return False, outcome.get("result"), None
    return False, None, None


class RunHandle:
    """A run to finish later. Made by the client, not by apps."""

    def __init__(
        self,
        client: Cronwatch,
        definition: JobDefinition,
        run_id: str,
        base: Run | None,
        recorded: bool,
        inactive: str | None,
    ) -> None:
        self._client = client
        self._definition = definition
        self._base = base
        self._recorded = recorded
        self._inactive = inactive
        # True for a run this handle's start opened, not one it found by its id.
        self._opened = False
        #: The run's id.
        self.id = run_id
        #: The job's name.
        self.job: str = definition.name
        #: When the run started; None when a resumed run could not be read.
        self.started_at: int | None = base.started_at if base else None
        # _state guards the flags and which recorder is current; _turn keeps
        # flush and finish in order, one at a time.
        self._state = threading.Lock()
        self._turn = threading.Lock()
        self._recorder = self._fresh()
        self._finished = inactive is not None
        self._finish_called = False
        # The first OUTPUT_CAP characters of every line flushed from this
        # handle, unredacted, or None before the first flush. The stored output
        # keeps only the tail, so without it an expect rule at finish would
        # miss a line logged early, which run() would have seen.
        self._head: str | None = None

    def _fresh(self) -> RunRecorder:
        return RunRecorder(Run(id=self.id, job=self.job, status=RunStatus.RUNNING, started_at=self.started_at or 0), None)

    @property
    def active(self) -> bool:
        """False once finished, and from the start for a resumed run that already finished or does not exist."""
        with self._state:
            return not self._finished

    def log(self, *parts: Any) -> None:
        """Add a line of output. Kept in the handle until flush() or finish()."""
        with self._state:
            self._recorder.context.log(*parts)

    def metric(self, name: str, value: float) -> None:
        """Report a number for this run. A later value for the same name replaces an earlier one."""
        with self._state:
            self._recorder.context.metric(name, value)

    def metrics(self, values: Mapping[str, float] | None = None, **more: float) -> None:
        with self._state:
            self._recorder.context.metrics(values, **more)

    def flush(self) -> None:
        """Append the lines and metrics added so far to the stored run, which must
        still be running and belong to this job. A read, change, and write of
        the run's row, written only while it is still running: two processes
        appending to one run at the same moment can lose one's lines, but a
        flush never undoes a finish. When the write fails the lines stay here
        for finish(). The first 16 KB of everything flushed stay in the handle,
        so an expect rule at finish() sees an early line as run() would."""
        with self._turn:
            with self._state:
                if self._finished or not self._recorded:
                    return
                lines = self._recorder.output()
                values = self._recorder.metrics()
                if lines is None and not values:
                    return
                # Lines logged while this waits on the store go to a new recorder.
                taken = self._recorder
                self._recorder = self._fresh()
            if self._client._flush_handle(self, lines, values):
                self._keep_head(taken.expect_text())
            else:
                self._put_back(taken)

    def finish(self, outcome: Any = None, *, result: Any = UNSET, error: Any = UNSET) -> Run | None:
        """Finish the run, judge it like any other, and send what that produces.

            finish()                       # ok
            finish({"status": "ok"})       # ok
            finish(error=e)                # failed, recorded like an error run() caught
            finish({"error": e})           # the same
            finish("text")                 # like run()'s return value: the output when
            finish(result="text")          # nothing was logged, checked by expect

        Returns the run as recorded, or None when nothing was: the run was
        already finished (here or elsewhere), was not found, or belongs to
        another job, which is reported to on_error. When several processes
        finish one run, only the one whose write lands judges it. A store that
        fails is reported, nothing is recorded, and the handle stays active so
        finish() can be called again."""
        with self._state:
            again = self._finish_called
            was_inactive = self._finished
            if not again:
                self._finish_called = True
                self._finished = True
        if again:
            self._client._ignore_finish(self.id, self.job, "was already finished by this handle")
            return None
        failed, value, problem = read_outcome(outcome, result, error)
        with self._turn:
            if was_inactive:
                self._client._ignore_finish(self.id, self.job, self._inactive or "was already finished")
                return None
            with self._state:
                recorder = self._recorder
            try:
                return self._client._finish_handle(self, recorder, failed, value, problem, self._head)
            except _Retry:
                self._reopen()
                return None
            except BaseException:
                # An interrupt mid-finish: the run may still be running, so the
                # handle stays open (lines kept) for finish to be called again.
                self._reopen()
                raise

    def fail(self, error: Any) -> Run | None:
        """finish(error=error)."""
        return self.finish(error=error)

    def _put_back(self, taken: RunRecorder) -> None:
        """A flush that could not write: its lines go back ahead of any logged since."""
        with self._state:
            later = self._recorder
            self._recorder = self._fresh()
            for text in (taken.expect_text(), later.expect_text()):
                if text is not None:
                    self._recorder.log(text)
            for name, value in {**taken.metrics(), **later.metrics()}.items():
                self._recorder.metric(name, value)

    def _reopen(self) -> None:
        with self._state:
            self._finish_called = False
            self._finished = False

    def _keep_head(self, text: str | None) -> None:
        """Keeps the start of what a flush wrote, up to the cap, for expect at finish."""
        if text is None or (self._head is not None and _js.length16(self._head) >= OUTPUT_CAP):
            return
        joined = text if not self._head else f"{self._head}\n{text}"
        self._head = _js.head16(joined, OUTPUT_CAP)

    def __repr__(self) -> str:
        return f"RunHandle(id={self.id!r}, job={self.job!r}, active={self.active})"

