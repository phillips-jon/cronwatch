"""What was public by accident before 0.11 still works under its old name,
warning with a DeprecationWarning, until 1.0 removes it: the implementation
modules, now underscored, and the helpers the public modules exposed. The
renames of documented API warn the same way and go in 2.0."""

from __future__ import annotations

import importlib
import subprocess
import sys

import pytest

import cronwatch

MOVED = ["duration", "stats", "output", "schedule", "evaluate", "format", "serialize", "job", "run_handle", "client", "handler", "alerts.email", "alerts.sigv4"]


@pytest.mark.parametrize("old", MOVED)
def test_an_internal_module_answers_under_its_old_name_with_a_warning(old: str) -> None:
    head, _, last = old.rpartition(".")
    new = importlib.import_module(f"cronwatch.{head + '.' if head else ''}_{last}")
    shim = importlib.import_module(f"cronwatch.{old}")
    name = new.__all__[0]
    with pytest.warns(DeprecationWarning, match=rf"cronwatch\.{old} is internal and deprecated"):
        value = getattr(shim, name)
    assert value is getattr(new, name)
    assert name in dir(shim)


def test_the_old_module_names_are_attributes_of_the_package_too() -> None:
    with pytest.warns(DeprecationWarning):
        assert cronwatch.evaluate.empty_state is importlib.import_module("cronwatch._evaluate").empty_state  # type: ignore[attr-defined]
    with pytest.raises(AttributeError):
        cronwatch.nothing_here  # type: ignore[attr-defined]  # noqa: B018


def test_cronwatch_client_stays_the_function_whatever_is_imported() -> None:
    code = (
        "import warnings; warnings.simplefilter('error')\n"
        "import cronwatch.client\n"
        "import cronwatch\n"
        "assert callable(cronwatch.client), cronwatch.client\n"
        "try:\n"
        "    from cronwatch.client import Cronwatch\n"
        "except DeprecationWarning:\n"
        "    pass\n"
        "else:\n"
        "    raise SystemExit('no warning')\n"
    )
    subprocess.run([sys.executable, "-c", code], check=True)


@pytest.mark.parametrize(
    ("module", "old"),
    [
        ("cronwatch.types", "camel"),
        ("cronwatch.types", "snake"),
        ("cronwatch.types", "CONDITIONS"),
        ("cronwatch.alerts", "send_to"),
        ("cronwatch.alerts.twilio", "sms_segments"),
        ("cronwatch.alerts.discord", "DESCRIPTION_MAX"),
        ("cronwatch.alerts.sentry", "parse_dsn"),
        ("cronwatch.alerts.slack", "EMOJI"),
        ("cronwatch.sources.pgcron", "run"),
        ("cronwatch.sources.pgcron", "HOLD_MS"),
        ("cronwatch.triage.anthropic", "describe"),
        ("cronwatch.stores.sqlite", "retry_busy"),
        ("cronwatch.web", "cookie_value"),
        ("cronwatch.web", "MAX_BODY"),
        ("cronwatch.celery", "convert"),
        ("cronwatch.apscheduler", "TRIGGER"),
        ("cronwatch.django", "KEYS"),
    ],
)
def test_a_helper_made_internal_answers_under_its_old_name_with_a_warning(module: str, old: str) -> None:
    if module in ("cronwatch.celery", "cronwatch.django"):
        pytest.importorskip(module.split(".")[1])
    mod = importlib.import_module(module)
    with pytest.warns(DeprecationWarning, match=rf"{module}\.{old} is internal and deprecated"):
        value = getattr(mod, old)
    assert value is getattr(mod, f"_{old}")
    assert old not in mod.__all__


def test_an_unknown_name_is_still_an_attribute_error() -> None:
    from cronwatch import types

    with pytest.raises(AttributeError, match="no attribute 'nothing'"):
        types.nothing  # type: ignore[attr-defined]  # noqa: B018
