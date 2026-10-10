"""Shared by every test: the process timezone is UTC, as the conformance
fixtures were generated in, and helpers for clocks, captured alerts, and a
store that fails on demand."""

from __future__ import annotations

import os
import time

os.environ["TZ"] = "UTC"
time.tzset()

import pytest  # noqa: E402

from helpers import Capture, Clock  # noqa: E402


@pytest.fixture
def clock() -> Clock:
    return Clock()


@pytest.fixture
def capture() -> Capture:
    return Capture()
