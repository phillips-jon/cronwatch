"""Everything public about a job, a run, and an alert.

Python names are snake_case (``failures_before_alert``, ``started_at``).
Anything that leaves the process (store rows, JSON columns, webhook bodies)
uses the SDK's exact camelCase field names and string values, so a Node, a
Ruby, and a Python process can share one database. Each type's ``to_dict()``
is that JSON shape, with the SDK's key order, and ``from_dict()`` reads it
(camelCase or snake_case keys).
"""

from __future__ import annotations

import copy
import re
from collections.abc import Mapping
from dataclasses import dataclass, field
from enum import StrEnum
from typing import Any, ClassVar

from ._deprecated import names as _deprecated_names

__all__ = [
    "Alert",
    "AlertDraft",
    "AlertType",
    "CheckResult",
    "Condition",
    "JobDefinition",
    "JobHealth",
    "JobState",
    "JobStats",
    "JobSummary",
    "JobWithRuns",
    "MISSING",
    "Run",
    "RunStatus",
    "SendingAlert",
    "StoredJob",
]


class RunStatus(StrEnum):
    RUNNING = "running"
    OK = "ok"
    FAILED = "failed"
    TIMEOUT = "timeout"


class Condition(StrEnum):
    MISSED = "missed"
    FAILED = "failed"
    STUCK = "stuck"
    SLOW = "slow"
    OVER_BUDGET = "over_budget"
    UNDER_FLOOR = "under_floor"


_CONDITIONS: tuple[Condition, ...] = tuple(Condition)


class AlertType(StrEnum):
    MISSED = "missed"
    FAILED = "failed"
    STUCK = "stuck"
    SLOW = "slow"
    OVER_BUDGET = "over_budget"
    UNDER_FLOOR = "under_floor"
    RECOVERED = "recovered"


class JobHealth(StrEnum):
    HEALTHY = "healthy"
    LATE = "late"
    FAILING = "failing"
    STUCK = "stuck"
    SILENCED = "silenced"
    NEVER_RAN = "never_ran"


def _camel(name: str) -> str:
    """failures_before_alert -> failuresBeforeAlert."""
    return re.sub(r"_([a-z0-9])", lambda m: m.group(1).upper(), name)


def _snake(name: str) -> str:
    """failuresBeforeAlert -> failures_before_alert."""
    return re.sub(r"([A-Z])", lambda m: "_" + m.group(1).lower(), name)


def _enum(kind: type[StrEnum], value: Any) -> Any:
    """A known wire string as its enum member; anything else as it came."""
    try:
        return kind(value)
    except (ValueError, TypeError):  # TypeError: a foreign row's list or object
        return value


def _get(data: Mapping[str, Any], key: str, default: Any = None) -> Any:
    """A camelCase field from a mapping with camelCase or snake_case keys."""
    if key in data:
        return data[key]
    s = _snake(key)
    if s in data:
        return data[s]
    return default


def _has(data: Mapping[str, Any], key: str) -> bool:
    return key in data or _snake(key) in data


class JobDefinition:
    """A job's options. Kept as an ordered set of fields, in camelCase, so its
    JSON has the same keys in the same order as the SDK writes: defaults, then
    options as given, then name, and a stored ``expect`` last. Fields this
    version does not know (written by a newer one) are kept as they came."""

    __slots__ = ("_fields",)

    FIELDS: dict[str, str] = {
        "name": "name",
        "schedule": "schedule",
        "timezone": "timezone",
        "grace": "grace",
        "timeout": "timeout",
        "max_duration": "maxDuration",
        "budget": "budget",
        "floor": "floor",
        "expect": "expect",
        "failures_before_alert": "failuresBeforeAlert",
        "description": "description",
        "tags": "tags",
    }
    OPTIONS: tuple[str, ...] = tuple(k for k in FIELDS if k != "name")

    def __init__(self, fields: Mapping[str, Any] | None = None) -> None:
        by_snake = JobDefinition.FIELDS
        out: dict[str, Any] = {}
        for key, value in (fields or {}).items():
            out[by_snake.get(key, key)] = value
        self._fields = out

    @classmethod
    def from_dict(cls, data: Mapping[str, Any] | JobDefinition | None) -> JobDefinition:
        if isinstance(data, JobDefinition):
            return data
        return cls(data or {})

    # The fields, by their snake_case names.
    name = property(lambda self: self._fields.get("name"))
    schedule = property(lambda self: self._fields.get("schedule"))
    timezone = property(lambda self: self._fields.get("timezone"))
    grace = property(lambda self: self._fields.get("grace"))
    timeout = property(lambda self: self._fields.get("timeout"))
    max_duration = property(lambda self: self._fields.get("maxDuration"))
    budget = property(lambda self: self._fields.get("budget"))
    floor = property(lambda self: self._fields.get("floor"))
    expect = property(lambda self: self._fields.get("expect"))
    failures_before_alert = property(lambda self: self._fields.get("failuresBeforeAlert"))
    description = property(lambda self: self._fields.get("description"))
    tags = property(lambda self: self._fields.get("tags"))

    @property
    def fields(self) -> dict[str, Any]:
        """The fields in order, camelCase keys, as given."""
        return dict(self._fields)

    def get(self, key: str, default: Any = None) -> Any:
        return self._fields.get(JobDefinition.FIELDS.get(key, key), default)

    def replace(self, **changes: Any) -> JobDefinition:
        """A copy with some fields changed, or added at the end as in JavaScript."""
        fields = dict(self._fields)
        for key, value in changes.items():
            fields[JobDefinition.FIELDS.get(key, key)] = value
        return JobDefinition(fields)

    def to_dict(self) -> dict[str, Any]:
        """The JSON shape: fields set to None are left out, as undefined is."""
        return {k: (dict(v) if isinstance(v, Mapping) else v) for k, v in self._fields.items() if v is not None}

    def __eq__(self, other: object) -> bool:
        return isinstance(other, JobDefinition) and self._fields == other._fields

    def __hash__(self) -> int:
        return hash(tuple(self._fields))

    def __repr__(self) -> str:
        return f"JobDefinition({self._fields!r})"


@dataclass
class Run:
    id: str
    job: str
    status: RunStatus | str
    #: Epoch milliseconds.
    started_at: int
    finished_at: int | None = None
    duration_ms: int | None = None
    error: str | None = None
    #: Lines written with log(), or the string the job returned. Capped at 16 KB.
    output: str | None = None
    metrics: dict[str, float] = field(default_factory=dict)
    #: What started the run: "run", "start", or a value you pass.
    trigger: str = "run"

    def __post_init__(self) -> None:
        self.status = _enum(RunStatus, self.status)

    @classmethod
    def from_dict(cls, data: Mapping[str, Any] | Run) -> Run:
        if isinstance(data, Run):
            return data
        metrics = _get(data, "metrics")
        if not isinstance(metrics, Mapping):
            metrics = {}
        return cls(
            id=_get(data, "id"),
            job=_get(data, "job"),
            status=_get(data, "status"),
            started_at=_get(data, "startedAt"),
            finished_at=_get(data, "finishedAt"),
            duration_ms=_get(data, "durationMs"),
            error=_get(data, "error"),
            output=_get(data, "output"),
            metrics={str(k): v for k, v in metrics.items()},
            trigger=_get(data, "trigger", "run"),
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "job": self.job,
            "status": str(self.status),
            "startedAt": self.started_at,
            "finishedAt": self.finished_at,
            "durationMs": self.duration_ms,
            "error": self.error,
            "output": self.output,
            "metrics": dict(self.metrics or {}),
            "trigger": self.trigger,
        }

    def copy(self) -> Run:
        return Run(**{**self.__dict__, "metrics": dict(self.metrics or {})})

    @property
    def running(self) -> bool:
        return self.status == RunStatus.RUNNING

    @property
    def ok(self) -> bool:
        return self.status == RunStatus.OK


@dataclass
class StoredJob:
    name: str
    definition: JobDefinition
    created_at: int
    updated_at: int

    @classmethod
    def from_dict(cls, data: Mapping[str, Any] | StoredJob) -> StoredJob:
        if isinstance(data, StoredJob):
            return data
        return cls(
            name=_get(data, "name"),
            definition=JobDefinition.from_dict(_get(data, "definition") or {}),
            created_at=_get(data, "createdAt"),
            updated_at=_get(data, "updatedAt"),
        )

    def to_dict(self) -> dict[str, Any]:
        return {"name": self.name, "definition": self.definition.to_dict(), "createdAt": self.created_at, "updatedAt": self.updated_at}


def _details_to_json(value: Any) -> Any:
    """An alert's details, snake_case keys in Python, as their camelCase JSON."""
    if isinstance(value, Mapping):
        return {_camel(k) if isinstance(k, str) else str(k): _details_to_json(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [_details_to_json(v) for v in value]
    if isinstance(value, StrEnum):
        return str(value)
    return value


def _details_from_json(value: Any) -> dict[str, Any]:
    """An alert's details read from JSON, with snake_case keys and conditions as Condition."""

    def convert(v: Any) -> Any:
        if isinstance(v, Mapping):
            return {_snake(k): convert(x) for k, x in v.items()}
        if isinstance(v, list):
            return [convert(x) for x in v]
        return v

    details = convert(value or {})
    if isinstance(details.get("after"), list):
        details["after"] = [_enum(Condition, c) for c in details["after"]]
    return details


@dataclass
class AlertDraft:
    """An alert before it has a title and message. See format.compose_alert()."""

    type: AlertType | str
    run: Run | None
    details: dict[str, Any]

    def __post_init__(self) -> None:
        self.type = _enum(AlertType, self.type)

    def to_dict(self) -> dict[str, Any]:
        return {"type": str(self.type), "run": self.run.to_dict() if self.run else None, "details": _details_to_json(self.details)}


@dataclass
class Alert:
    """An alert as every channel receives it.

    ``triage`` is the triage function's diagnosis, or None. A None triage is
    one of two things, as in the SDK: never tried (no "triage" key in the
    JSON), or tried and nothing came of it (``"triage": null``, and
    ``triage_tried`` is True). A tried alert is not triaged again.
    """

    type: AlertType | str
    run: Run | None
    details: dict[str, Any]
    job: str
    definition: JobDefinition
    #: One line, suitable as a notification title.
    title: str
    #: A few lines of plain text with the specifics.
    message: str
    at: int
    triage: str | None = None
    triage_tried: bool = False
    # Keys a newer release wrote that this one does not know, kept as their
    # JSON and written back after the known ones, as the SDK carries a queued
    # alert along whole.
    _extra: dict[str, Any] = field(default_factory=dict, init=False, compare=False, repr=False)
    # The details as read, and what they were read as: written back as they
    # came while unchanged, so a key the snake_case round trip would respell
    # (a stored "a_b" would come back "aB") is kept.
    _details_json: Any = field(default=None, init=False, compare=False, repr=False)
    _details_read: Any = field(default=None, init=False, compare=False, repr=False)
    # Known keys the stored entry lacked, and a `run` or `definition` it held
    # that was not an object: written back as they came while still unset.
    _absent: frozenset[str] = field(default=frozenset(), init=False, compare=False, repr=False)
    _raw: dict[str, Any] = field(default_factory=dict, init=False, compare=False, repr=False)

    #: The keys this release reads, as stored.
    _KEYS: ClassVar[tuple[str, ...]] = ("type", "run", "details", "job", "definition", "title", "message", "at", "triage")

    def __post_init__(self) -> None:
        self.type = _enum(AlertType, self.type)
        if self.triage is not None:
            self.triage_tried = True

    def set_triage(self, diagnosis: str | None) -> None:
        """Records a triage attempt: the diagnosis, or None when there was none."""
        self.triage = diagnosis
        self.triage_tried = True

    @classmethod
    def from_dict(cls, data: Mapping[str, Any] | Alert) -> Alert:
        """Read leniently, as a foreign or damaged row may hold anything: a
        `run`, `definition`, or `details` that is not an object reads as none
        (and is written back as it came while unchanged), and a key the
        entry lacked stays left out when it is written back."""
        if isinstance(data, Alert):
            return data
        run = _get(data, "run")
        raw_details = _get(data, "details")
        raw_definition = _get(data, "definition")
        alert = cls(
            type=_get(data, "type"),
            run=Run.from_dict(run) if isinstance(run, Mapping) else None,
            details=_details_from_json(raw_details if isinstance(raw_details, Mapping) else {}),
            job=_get(data, "job"),
            definition=JobDefinition.from_dict(raw_definition if isinstance(raw_definition, Mapping) else None),
            title=_get(data, "title"),
            message=_get(data, "message"),
            at=_get(data, "at"),
        )
        if _has(data, "triage"):
            alert.set_triage(_get(data, "triage"))
        if _has(data, "details"):
            alert._details_json = copy.deepcopy(dict(raw_details) if isinstance(raw_details, Mapping) else raw_details)
            alert._details_read = copy.deepcopy(alert.details)
        alert._absent = frozenset(k for k in cls._KEYS if k != "triage" and not _has(data, k))
        alert._raw = {k: v for k, v in (("run", run), ("definition", raw_definition)) if v is not None and not isinstance(v, Mapping)}
        known = set(cls._KEYS) | {_snake(k) for k in cls._KEYS}
        alert._extra = {k: v for k, v in data.items() if k not in known}
        return alert

    def to_dict(self) -> dict[str, Any]:
        out: dict[str, Any] = {
            "type": str(self.type) if isinstance(self.type, str) else self.type,
            "run": self.run.to_dict() if self.run else self._raw.get("run"),
            "details": self._details_out(),
            "job": self.job,
            "definition": self.definition.to_dict() if isinstance(self.definition, JobDefinition) else self.definition,
            "title": self.title,
            "message": self.message,
            "at": self.at,
        }
        if "definition" in self._raw and out["definition"] == {}:
            out["definition"] = self._raw["definition"]
        for key in self._absent:
            # A key the stored entry lacked, still unset, stays left out.
            if out[key] is None or (key in ("details", "definition") and out[key] == {}):
                del out[key]
        if self.triage_tried:
            out["triage"] = self.triage
        for key, value in self._extra.items():
            out.setdefault(key, value)
        return out

    def _details_out(self) -> Any:
        if self._details_read is not None and self.details == self._details_read:
            return copy.deepcopy(self._details_json)
        return _details_to_json(self.details)


class _Missing:
    def __repr__(self) -> str:
        return "missing"


#: A key a stored entry did not have, so it is written back without it.
MISSING: Any = _Missing()


@dataclass
class SendingAlert:
    """An alert in JobState.sending, the outbox: ``until`` (epoch
    milliseconds) is when its sender's lease runs out. Read leniently, as a
    check releases it: an entry with no numeric ``until`` counts as run out,
    and one whose ``alert`` is not an object is dropped then, so a malformed
    entry never makes the whole state unreadable. A key the entry lacked is
    MISSING, and stays left out when it is written back."""

    until: Any
    alert: Any
    # Keys a newer release wrote on the entry, written back after the known ones.
    _extra: dict[str, Any] = field(default_factory=dict, init=False, compare=False, repr=False)

    @classmethod
    def from_json(cls, entry: Any) -> Any:
        """A stored entry: a SendingAlert for an object, anything else as it came."""
        if isinstance(entry, SendingAlert) or not isinstance(entry, Mapping):
            return entry
        alert = entry.get("alert", MISSING)
        if isinstance(alert, Mapping):
            try:
                alert = Alert.from_dict(alert)
            except Exception:  # noqa: BLE001, an alert that cannot be read is left as it came
                pass
        out = cls(until=entry.get("until", MISSING), alert=alert)
        out._extra = {k: v for k, v in entry.items() if k not in ("until", "alert")}
        return out

    def to_dict(self) -> dict[str, Any]:
        out: dict[str, Any] = {}
        if self.until is not MISSING:
            out["until"] = self.until
        if self.alert is not MISSING:
            out["alert"] = self.alert.to_dict() if isinstance(self.alert, Alert) else self.alert
        for key, value in self._extra.items():
            out.setdefault(key, value)
        return out


# A stored state is read leniently, since a foreign, hand-edited, or damaged
# row must affect only its own job, and the next write puts it right (the
# SDK's normalizeState): `open` keeps only its entries whose value is a
# number (anything but an object reads as {}); `silencedUntil` and
# `lastAlertAt` that are not numbers read as None; `pendingRecovery` keeps
# only its strings, and `undelivered` only its entries that are objects (a
# value of neither shape reads as []).


def _is_number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _read_number(value: Any) -> Any:
    return value if _is_number(value) else None


def _read_open(value: Any) -> dict[str, Any]:
    if not isinstance(value, Mapping):
        return {}
    return {_enum(Condition, k): v for k, v in value.items() if _is_number(v)}


def _read_conditions(value: Any) -> list[Condition | str]:
    if not isinstance(value, (list, tuple)):
        return []
    return [_enum(Condition, c) for c in value if isinstance(c, str)]


def _read_metric_names(value: Any) -> list[str] | None:
    names = [m for m in value if isinstance(m, str)] if isinstance(value, (list, tuple)) else []
    return names or None


def _read_alerts(value: Any) -> list[Alert]:
    if not isinstance(value, (list, tuple)):
        return []
    return [a if isinstance(a, Alert) else Alert.from_dict(a) for a in value if isinstance(a, (Alert, Mapping))]


def _sending_to_json(entry: Any) -> Any:
    return entry.to_dict() if isinstance(entry, SendingAlert) else entry


@dataclass
class JobState:
    """A job's state. ``version`` goes up by one on every write, so a store can
    refuse a write made from a stale read (see compare_and_set_state). None
    counts as 0."""

    job: str
    #: Conditions currently open, with the time each one opened.
    open: dict[str, int] = field(default_factory=dict)
    consecutive_failures: int = 0
    silenced_until: float | None = None
    #: When an alert last reached at least one channel.
    last_alert_at: int | None = None
    #: Conditions that alerted and have since closed, waiting for the recovered message.
    pending_recovery: list[Condition | str] | None = None
    #: Alerts that no channel accepted. Each check retries them once.
    undelivered: list[Alert] | None = None
    #: The outbox: alerts written with the state that opened their condition,
    #: while the process that wrote them sends them (see SendingAlert). None
    #: when empty: the key is never written as an empty list.
    sending: list[Any] | None = None
    version: int | None = None
    #: The metrics under their floor at the job's last successful run (see
    #: floor_breaches). None when none: the key is never written as an empty list.
    under_floor: list[str] | None = None
    #: Keys a newer release wrote that this one does not know, as their JSON,
    #: written back unchanged so a shared store never loses them.
    extra: dict[str, Any] = field(default_factory=dict, compare=False, repr=False)

    #: The keys this release reads, camelCase as stored.
    _KEYS: ClassVar[tuple[str, ...]] = ("job", "open", "consecutiveFailures", "silencedUntil", "lastAlertAt", "pendingRecovery", "undelivered", "sending", "underFloor", "version")

    @classmethod
    def from_dict(cls, data: Mapping[str, Any] | JobState) -> JobState:
        if isinstance(data, JobState):
            return data
        known = set(cls._KEYS) | {_snake(k) for k in cls._KEYS}
        pending = _get(data, "pendingRecovery")
        undelivered = _get(data, "undelivered")
        sending = _get(data, "sending")
        return cls(
            job=_get(data, "job"),
            open=_read_open(_get(data, "open")),
            consecutive_failures=_get(data, "consecutiveFailures", 0),
            silenced_until=_read_number(_get(data, "silencedUntil")),
            last_alert_at=_read_number(_get(data, "lastAlertAt")),
            pending_recovery=None if pending is None else _read_conditions(pending),
            undelivered=None if undelivered is None else _read_alerts(undelivered),
            sending=[SendingAlert.from_json(e) for e in sending] if isinstance(sending, list) and sending else None,
            under_floor=_read_metric_names(_get(data, "underFloor")),
            version=_get(data, "version"),
            extra={k: v for k, v in data.items() if k not in known},
        )

    def to_dict(self) -> dict[str, Any]:
        """pendingRecovery, undelivered, sending, underFloor, and version are
        left out when unset, as in state written before they existed (sending
        and underFloor also when empty). The version comes after the known keys, where the SDK's
        spread of a normalized state puts it, and the keys this release does
        not know come after it, as they were read."""
        out: dict[str, Any] = {
            "job": self.job,
            "open": {str(k): v for k, v in (self.open or {}).items()},
            "consecutiveFailures": self.consecutive_failures,
            "silencedUntil": self.silenced_until,
            "lastAlertAt": self.last_alert_at,
        }
        if self.pending_recovery is not None:
            out["pendingRecovery"] = [str(c) for c in self.pending_recovery]
        if self.undelivered is not None:
            out["undelivered"] = [a.to_dict() for a in self.undelivered]
        if self.sending:
            out["sending"] = [_sending_to_json(e) for e in self.sending]
        if self.under_floor:
            out["underFloor"] = list(self.under_floor)
        if self.version is not None:
            out["version"] = self.version
        for key, value in self.extra.items():
            out.setdefault(key, value)
        return out

    def copy(self) -> JobState:
        return JobState(
            job=self.job,
            open=dict(self.open or {}),
            consecutive_failures=self.consecutive_failures,
            silenced_until=self.silenced_until,
            last_alert_at=self.last_alert_at,
            pending_recovery=None if self.pending_recovery is None else list(self.pending_recovery),
            undelivered=None if self.undelivered is None else list(self.undelivered),
            sending=None if self.sending is None else list(self.sending),
            under_floor=None if self.under_floor is None else list(self.under_floor),
            version=self.version,
            extra=dict(self.extra),
        )


@dataclass
class JobStats:
    runs: int
    ok_rate: float
    p50_ms: int | None
    p95_ms: int | None

    def to_dict(self) -> dict[str, Any]:
        return {"runs": self.runs, "okRate": self.ok_rate, "p50Ms": self.p50_ms, "p95Ms": self.p95_ms}


@dataclass
class JobSummary:
    name: str
    definition: JobDefinition
    health: JobHealth
    open: list[Condition | str]
    last_run: Run | None
    #: When the schedule says the next run is due. None without a schedule.
    next_expected_at: int | None
    consecutive_failures: int
    silenced_until: float | None
    #: From the last twenty runs of any status; p50 and p95 are over the successful ones among them.
    stats: JobStats

    def to_dict(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "definition": self.definition.to_dict(),
            "health": str(self.health),
            "open": [str(c) for c in self.open],
            "lastRun": self.last_run.to_dict() if self.last_run else None,
            "nextExpectedAt": self.next_expected_at,
            "consecutiveFailures": self.consecutive_failures,
            "silencedUntil": self.silenced_until,
            "stats": self.stats.to_dict(),
        }


@dataclass
class CheckResult:
    checked_at: int
    jobs: list[JobSummary]
    alerts: list[Alert]
    pruned: int

    def to_dict(self) -> dict[str, Any]:
        return {
            "checkedAt": self.checked_at,
            "jobs": [j.to_dict() for j in self.jobs],
            "alerts": [a.to_dict() for a in self.alerts],
            "pruned": self.pruned,
        }


@dataclass
class JobWithRuns:
    """A job's summary and its newest runs, as the dashboard shows them."""

    job: JobSummary
    runs: list[Run]

    def to_dict(self) -> dict[str, Any]:
        return {"job": self.job.to_dict(), "runs": [r.to_dict() for r in self.runs]}


#: Internal names, still answering under their old public names (each
#: warning, until 1.0 removes them).
__getattr__ = _deprecated_names(__name__, globals(), {"camel": "_camel", "snake": "_snake", "details_to_json": "_details_to_json", "details_from_json": "_details_from_json", "CONDITIONS": "_CONDITIONS"})
