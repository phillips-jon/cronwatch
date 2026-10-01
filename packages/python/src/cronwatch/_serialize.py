"""Stored definitions and expect rules (serialize.ts)."""

from __future__ import annotations

import re
from collections.abc import Callable, Mapping
from datetime import timedelta
from typing import Any, Union

from . import _js
from ._duration import parse_duration
from .types import JobDefinition, StoredJob

__all__ = ["ExpectRule", "check_expectation", "describe_pattern", "is_readable", "read_stored_job", "to_stored", "unreadable_definition"]

#: What a successful run's output must satisfy: a string it must contain, a
#: compiled pattern it must match (re.search), or a function returning True.
ExpectRule = Union[str, "re.Pattern[str]", Callable[[str], Any]]

_DURATIONS = ("grace", "timeout", "maxDuration")


def describe_pattern(pattern: re.Pattern[str]) -> str:
    """A pattern as JavaScript's RegExp#toString writes one: /source/flags."""
    source = pattern.pattern if isinstance(pattern.pattern, str) else pattern.pattern.decode("utf-8", "replace")
    source = re.sub(r"(?<!\\)((?:\\\\)*)/", r"\1\\/", source) or "(?:)"
    source = source.replace("\n", "\\n").replace("\r", "\\r")
    flags = ""
    if pattern.flags & re.IGNORECASE:
        flags += "i"
    if pattern.flags & re.MULTILINE:
        flags += "m"
    if pattern.flags & re.DOTALL:
        flags += "s"
    return f"/{source}/{flags}"


def to_stored(definition: JobDefinition) -> JobDefinition:
    """A definition as a store can hold it: ``expect`` becomes a description
    and moves to the end, as it does in the SDK. A timedelta is stored as the
    milliseconds it means, the unit every reader takes a plain number in."""
    fields = definition.fields
    for key in _DURATIONS:
        if isinstance(fields.get(key), timedelta):
            fields[key] = parse_duration(fields[key], key)
    expect = fields.pop("expect", None)
    if expect is not None:
        if isinstance(expect, str):
            fields["expect"] = f"contains {_js.quote(expect)}"
        elif isinstance(expect, re.Pattern):
            fields["expect"] = f"matches {describe_pattern(expect)}"
        else:
            fields["expect"] = "custom function"
    return JobDefinition(fields)


class _UnreadableDefinition(JobDefinition):
    """The definition of a stored job whose own was not a JSON object: just
    its name. The client reports such a job and shows it as failing, without
    evaluating it."""

    __slots__ = ()


def unreadable_definition(name: str) -> JobDefinition:
    """What a store reads for a job row whose definition is not a JSON object
    (or whose text does not parse)."""
    return _UnreadableDefinition({"name": name})


def read_stored_job(stored: StoredJob) -> tuple[StoredJob, bool]:
    """A stored job as the client reads it (serialize.ts readStoredJob), so a
    foreign, hand-edited or damaged row affects only its own job. A
    definition that is not a JSON object becomes ``{name}`` and ``readable``
    is False. ``tags`` is kept only when it is a list of strings. Every other
    field is kept as stored."""
    definition: Any = stored.definition
    if isinstance(definition, _UnreadableDefinition):
        return stored, False
    if isinstance(definition, JobDefinition):
        fields = definition.fields
    elif isinstance(definition, Mapping):
        fields = JobDefinition(definition).fields
    else:
        return StoredJob(stored.name, unreadable_definition(stored.name), stored.created_at, stored.updated_at), False
    tags = fields.get("tags", _ABSENT)
    if tags is _ABSENT and isinstance(definition, JobDefinition):
        return stored, True
    if tags is not _ABSENT and not (isinstance(tags, list) and all(isinstance(t, str) for t in tags)):
        del fields["tags"]
    return StoredJob(stored.name, JobDefinition(fields), stored.created_at, stored.updated_at), True


def is_readable(stored: StoredJob) -> bool:
    """False for a stored job read_stored_job found unreadable."""
    return not isinstance(stored.definition, _UnreadableDefinition)


_ABSENT = object()


def check_expectation(expect: ExpectRule | None, output: str | None) -> str | None:
    """None when the output satisfies `expect`, or why it does not."""
    if expect is None:
        return None
    text = output if output is not None else ""
    if isinstance(expect, str):
        return None if expect in text else f"Output did not contain {_js.quote(expect)}"
    if isinstance(expect, re.Pattern):
        return None if expect.search(text) else f"Output did not match {describe_pattern(expect)}"
    try:
        ok = expect(text)
    except Exception as error:  # the rule is the app's code; its failure is the run's
        return f"Output check threw: {error}"
    return None if ok else "Output did not pass the expect() check"
