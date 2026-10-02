"""CronWatch: cron and scheduled-job monitoring that lives inside your app.

    import cronwatch
    from cronwatch.stores import SqliteStore

    cw = cronwatch.Cronwatch(store=SqliteStore("./data/cronwatch.db"))
    nightly = cw.job("nightly-report", schedule="0 2 * * *", grace="15m")

    with nightly.run() as ctx:
        ctx.log("Report written")
        ctx.metric("cost", 1.2)

    cw.start_checking()  # checks for missed and stuck runs every minute, in a daemon thread

The Python port of @cronwatch/sdk: the same rules, the same alert text and
the same stored rows, so a Python, a Node and a Ruby process can share one
database.
"""

from __future__ import annotations

import importlib
import threading
from typing import Any

from . import alerts, stores
from .alerts import ChannelContext, Console, Custom
from ._client import ChannelTimeout, CheckInterrupted, Cronwatch, JobHandle, TriageContext
from ._duration import format_duration, parse_duration
from ._job import AbortError, AbortSignal, JobContext, current
from ._output import redact_secrets
from ._run_handle import RunHandle
from ._schedule import parse_schedule
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
    SendingAlert,
    StoredJob,
)

# cronwatch.client, the module 1.0 made internal (it is cronwatch._client),
# is also the function below: its deprecated name is imported here, before
# the function takes the name back, so importing it later cannot replace the
# function.
from . import client as _client_module  # noqa: E402, F401

__version__ = "0.11.1"

#: The internal modules, under their old public names: each still works,
#: warning when a name of it is used, until 1.0 removes it.
_MOVED = ("duration", "stats", "output", "schedule", "evaluate", "format", "serialize", "job", "run_handle", "handler")

_configured: Cronwatch | None = None
_lock = threading.Lock()


def configure(**options: Any) -> Cronwatch:
    """Make the process's client, taking the same options as Cronwatch(), and
    return it. cronwatch.client() hands it out afterwards. Calling it again
    replaces the client (stopping the old one's interval checks)."""
    global _configured
    made = Cronwatch(**options)
    with _lock:
        previous, _configured = _configured, made
    if previous is not None:
        previous.stop()
    return made


def client() -> Cronwatch:
    """The client configure() made, or a default one (memory store, console alerts) when it was never called."""
    global _configured
    with _lock:
        if _configured is None:
            _configured = Cronwatch()
        return _configured


def __getattr__(name: str) -> Any:
    if name in _MOVED:
        return importlib.import_module(f"{__name__}.{name}")
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")


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
    "SendingAlert",
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
