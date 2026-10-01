"""The environment, as the SDK's env.test.ts reads it, with ENVIRONMENT in
NODE_ENV's place: CRONWATCH_ENV, then APP_ENV, then ENVIRONMENT, the first
that holds more than spaces, trimmed, lowercased and its alias resolved."""

from __future__ import annotations

import pytest

from cronwatch import _env

CASES = [
    # (CRONWATCH_ENV, APP_ENV, ENVIRONMENT, environment)
    (None, None, None, None),
    (None, None, "development", "development"),
    (None, None, "test", "development"),
    (None, None, "production", "production"),
    (None, "local", "production", "development"),
    ("production", "dev", "development", "production"),
    ("staging", None, "development", "staging"),
    ("  PROD ", None, None, "production"),
    (None, "Testing", None, "development"),
    (None, "DEV", None, "development"),
    ("", "   ", "production", "production"),
    (" \t", None, None, None),
]


@pytest.fixture(autouse=True)
def _clean(monkeypatch: pytest.MonkeyPatch) -> None:
    for name in _env._VARIABLES:
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setattr(_env, "_fallback", None)


@pytest.mark.parametrize(("cronwatch_env", "app_env", "own", "expected"), CASES)
def test_the_first_variable_with_a_value_names_the_environment(
    monkeypatch: pytest.MonkeyPatch, cronwatch_env: str | None, app_env: str | None, own: str | None, expected: str | None
) -> None:
    for name, value in zip(_env._VARIABLES, (cronwatch_env, app_env, own), strict=True):
        if value is not None:
            monkeypatch.setenv(name, value)
    assert _env.environment() == expected
    assert _env.is_development() is (expected == "development")
    assert _env.is_production() is (expected == "production")


def test_a_framework_names_it_only_when_no_variable_does(monkeypatch: pytest.MonkeyPatch) -> None:
    _env.set_fallback(lambda: "development")
    assert _env.is_development()
    monkeypatch.setenv("APP_ENV", "prod")
    assert _env.is_production()
    monkeypatch.setenv("APP_ENV", "  ")
    assert _env.is_development()
    _env.set_fallback(lambda: " ")
    assert _env.environment() is None
