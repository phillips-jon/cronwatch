"""The cap on a duration string's length, which the conformance cases also
replay: the parts pattern is quadratic on a long run of digits."""

from __future__ import annotations

import re
import time

import pytest

from cronwatch._duration import parse_duration

TOO_LONG = "is too long for a duration (more than 64 characters)"


def test_a_string_over_64_characters_is_refused_quoting_its_first_32() -> None:
    assert parse_duration("1m" * 32) == 32 * 60_000
    long = " " + "1m" * 32
    with pytest.raises(ValueError) as error:
        parse_duration(long, "grace")
    assert str(error.value) == f'grace "{long[:32]}..." {TOO_LONG}'
    # Characters are code points: forty emoji are eighty UTF-16 units but under the cap.
    with pytest.raises(ValueError, match=re.compile('^duration "(\U0001f600){40}" is not a duration like')):
        parse_duration("\U0001f600" * 40)
    with pytest.raises(ValueError) as error:
        parse_duration("\U0001f600" * 65)
    head = "\U0001f600" * 32
    assert str(error.value) == f'duration "{head}..." {TOO_LONG}'


def test_a_megabyte_of_digits_is_refused_at_once() -> None:
    started = time.monotonic()
    with pytest.raises(ValueError) as error:
        parse_duration("1" * (1 << 20), "silence duration")
    head = "1" * 32
    assert str(error.value) == f'silence duration "{head}..." {TOO_LONG}'
    assert time.monotonic() - started < 1
