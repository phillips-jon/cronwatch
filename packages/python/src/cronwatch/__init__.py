"""CronWatch: cron and scheduled-job monitoring that lives inside your app.

    import cronwatch
    from cronwatch.stores import SqliteStore

    cw = cronwatch.Cronwatch(store=SqliteStore("./data/cronwatch.db"))
    nightly = cw.job("nightly-report", schedule="0 2 * * *", grace="15m")

    with nightly.run() as ctx:
        ctx.log("Report written")
        ctx.metric("cost", 1.2)

    cw.start()  # checks for missed and stuck runs every minute, in a daemon thread

The Python port of @cronwatch/sdk: the same rules, the same alert text and
the same stored rows, so a Python, a Node and a Ruby process can share one
database.
"""

from __future__ import annotations

import threading
from typing import Any

from . import alerts, stores
from .alerts import ChannelContext, Console, Custom
from .client import ChannelTimeout, CheckInterrupted, Cronwatch, JobHandle, TriageContext
from .duration import format_duration, parse_duration
from .job import AbortError, AbortSignal, JobContext, current
from .output import redact_secrets
from .run_handle import RunHandle
from .schedule import parse_schedule
from .types import (
    Alert,
    AlertDraft,
    AlertType,
    CheckResult,
    Condition,
    JobDefinition,
    JobHealth,
    JobState,
    JobStats,
    JobSummary,
    JobWithRuns,
    Run,
    RunStatus,
    StoredJob,
)

__version__ = "0.9.0"

_client: Cronwatch | None = None
_lock = threading.Lock()


def configure(**options: Any) -> Cronwatch:
    """Make the process's client, taking the same options as Cronwatch(), and
    return it. cronwatch.client() hands it out afterwards. Calling it again
    replaces the client (stopping the old one's interval checks)."""
    global _client
    made = Cronwatch(**options)
    with _lock:
        previous, _client = _client, made
    if previous is not None:
        previous.stop()
    return made


def client() -> Cronwatch:
    """The client configure() made, or a default one (memory store, console alerts) when it was never called."""
    global _client
    with _lock:
        if _client is None:
            _client = Cronwatch()
        return _client


__all__ = [
    "AbortError",
    "AbortSignal",
    "Alert",
    "AlertDraft",
    "AlertType",
    "ChannelContext",
    "ChannelTimeout",
    "CheckInterrupted",
    "CheckResult",
    "Condition",
    "Console",
    "Cronwatch",
    "Custom",
    "JobContext",
    "JobDefinition",
    "JobHandle",
    "JobHealth",
    "JobState",
    "JobStats",
    "JobSummary",
    "JobWithRuns",
    "Run",
    "RunHandle",
    "RunStatus",
    "StoredJob",
    "TriageContext",
    "__version__",
    "alerts",
    "client",
    "configure",
    "current",
    "format_duration",
    "parse_duration",
    "parse_schedule",
    "redact_secrets",
    "stores",
]
