"""Keeps everything in process memory (stores/memory.ts). The default when no
store is given, good for tests and for trying the library out. State is gone
on restart, so a missed run cannot be noticed across one."""

from __future__ import annotations

import threading
from collections.abc import Sequence
from typing import Any, TypeVar

from .. import _js
from ..evaluate import state_version
from ..output import strip_json_nul, strip_nul
from ..types import JobDefinition, JobState, Run, RunStatus, StoredJob

T = TypeVar("T")


def _clone(value: Any, kind: type[T]) -> T:
    """A copy through JSON, as the SDK's memory store makes, so nothing the
    caller holds is shared and values read back as any store returns them."""
    return kind.from_dict(_js.loads(_js.dumps(value.to_dict())))  # type: ignore[attr-defined, no-any-return]


def _kept(value: Any, kind: type[T]) -> T:
    """A copy as the SQL stores write it (see _sql.py), without U+0000 in
    any key or string, so every store reads back the same."""
    return kind.from_dict(_js.loads(strip_json_nul(_js.dumps(value.to_dict()))))  # type: ignore[attr-defined, no-any-return]


def _kept_run(run: Run) -> Run:
    """A run as the SQL stores write it: no U+0000 in its trigger, output,
    error or metric names. Its id and job are identifiers, kept as given."""
    copy = _clone(run, Run)
    copy.trigger = strip_nul(copy.trigger)
    copy.output = None if copy.output is None else strip_nul(copy.output)
    copy.error = None if copy.error is None else strip_nul(copy.error)
    copy.metrics = _js.loads(strip_json_nul(_js.dumps(copy.metrics or {})))
    return copy


def _units(name: str) -> bytes:
    """Code unit order, as the SQL stores sort by bytes rather than by locale."""
    return name.encode("utf-16-be", "surrogatepass")


class MemoryStore:
    def __init__(self) -> None:
        self._jobs: dict[str, StoredJob] = {}
        self._runs: dict[str, Run] = {}
        self._order: dict[str, int] = {}
        self._states: dict[str, JobState] = {}
        self._seq = 0
        self._lock = threading.RLock()

    def upsert_job(self, definition: JobDefinition, now: int) -> None:
        definition = JobDefinition.from_dict(definition)
        with self._lock:
            existing = self._jobs.get(definition.name)
            self._jobs[definition.name] = StoredJob(
                name=definition.name,
                definition=_kept(definition, JobDefinition),
                created_at=existing.created_at if existing else now,
                updated_at=now,
            )

    def get_job(self, name: str) -> StoredJob | None:
        with self._lock:
            job = self._jobs.get(name)
            return _clone(job, StoredJob) if job else None

    def list_jobs(self) -> list[StoredJob]:
        with self._lock:
            jobs = [_clone(j, StoredJob) for j in self._jobs.values()]
        return sorted(jobs, key=lambda j: _units(j.name))

    def delete_job(self, name: str) -> None:
        with self._lock:
            self._jobs.pop(name, None)
            self._states.pop(name, None)
            for run_id in [i for i, r in self._runs.items() if r.job == name]:
                del self._runs[run_id]
                del self._order[run_id]

    def insert_run(self, run: Run) -> None:
        """Like SQL's primary key: an id already recorded is refused, never overwritten."""
        with self._lock:
            if run.id in self._runs:
                raise ValueError(f"run {run.id} already exists")
            self._runs[run.id] = _kept_run(run)
            self._seq += 1
            self._order[run.id] = self._seq

    def update_run(self, run: Run) -> None:
        """Like SQL's UPDATE: a run that is gone (its job was forgotten) stays gone, and only these fields change."""
        with self._lock:
            existing = self._runs.get(run.id)
            if existing is not None:
                self._runs[run.id] = self._finished_fields(existing, run)

    def update_run_if(self, run: Run, from_statuses: Sequence[RunStatus | str]) -> bool:
        """update_run, only while the stored run's status is one of
        `from_statuses`, in one step. Returns whether it wrote."""
        statuses = [str(s) for s in from_statuses]
        with self._lock:
            existing = self._runs.get(run.id)
            if existing is None or str(existing.status) not in statuses:
                return False
            self._runs[run.id] = self._finished_fields(existing, run)
            return True

    def get_run(self, run_id: str) -> Run | None:
        with self._lock:
            run = self._runs.get(run_id)
            return _clone(run, Run) if run else None

    def list_runs(self, job: str, limit: int) -> list[Run]:
        """Newest first."""
        with self._lock:
            runs = [r for r in self._runs.values() if r.job == job]
            runs.sort(key=lambda r: (-r.started_at, -self._order[r.id]))
            return [_clone(r, Run) for r in runs[: max(int(limit), 0)]]

    def last_run(self, job: str) -> Run | None:
        runs = self.list_runs(job, 1)
        return runs[0] if runs else None

    def running_runs(self) -> list[Run]:
        """Oldest first, then in the order they were written."""
        with self._lock:
            runs = [r for r in self._runs.values() if r.status == RunStatus.RUNNING]
            runs.sort(key=lambda r: (r.started_at, self._order[r.id]))
            return [_clone(r, Run) for r in runs]

    def get_state(self, job: str) -> JobState | None:
        with self._lock:
            state = self._states.get(job)
            return _clone(state, JobState) if state else None

    def set_state(self, state: JobState) -> None:
        with self._lock:
            self._states[state.job] = _kept(state, JobState)

    def compare_and_set_state(self, state: JobState, expected_version: int) -> bool:
        """Writes `state` only when the stored state's version (absent, or no
        state at all, counts as 0) is `expected_version`. Returns whether it wrote."""
        with self._lock:
            current = self._states.get(state.job)
            if state_version(current) != expected_version:
                return False
            self._states[state.job] = _kept(state, JobState)
            return True

    def prune(self, before: int) -> int:
        """Delete finished runs that started before this time. Returns how many.
        Each job's newest run is kept whatever its age: without it, a job that
        runs less often than the retention looks like it never ran."""
        with self._lock:
            newest: dict[str, int] = {}
            for r in self._runs.values():
                newest[r.job] = max(newest.get(r.job, r.started_at), r.started_at)
            gone = [
                i
                for i, r in self._runs.items()
                if r.status != RunStatus.RUNNING and r.started_at < before and r.started_at < newest[r.job]
            ]
            for run_id in gone:
                del self._runs[run_id]
                del self._order[run_id]
            return len(gone)

    def close(self) -> None:
        pass

    @staticmethod
    def _finished_fields(existing: Run, run: Run) -> Run:
        copy = _kept_run(run)
        updated = _clone(existing, Run)
        updated.status = copy.status
        updated.finished_at = copy.finished_at
        updated.duration_ms = copy.duration_ms
        updated.error = copy.error
        updated.output = copy.output
        updated.metrics = copy.metrics
        return updated
