"""Stored definitions and expect rules (serialize.ts)."""

from __future__ import annotations

import re
from collections.abc import Callable
from datetime import timedelta
from typing import Any, Union

from . import _js
from .duration import parse_duration
from .types import JobDefinition

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
