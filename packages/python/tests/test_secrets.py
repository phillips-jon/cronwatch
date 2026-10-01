"""The dashboard's token and the cron secret: a blank one, given or read,
counts as unset, and one given in code that is not a string raises (the SDK's
routes-security.test.ts and client-hardening.test.ts). Also only a Bearer
Authorization header is a bearer."""

from __future__ import annotations

import urllib.parse
from collections.abc import Iterator
from typing import Any

import pytest

import cronwatch
from cronwatch.web import Request

from helpers import Capture, Errors, send

BLANK_TOKENS = ["", " ", "  ", "\t", " \n  ﻿ "]
BLANK_SECRETS = ["", " ", "\t\n", " ﻿"]
# What Python's str.strip() and JavaScript's trim() disagree on: only the latter counts these as space.
JS_ONLY_SPACES = [" ", " ", "﻿"]
NOT_STRINGS: list[Any] = [False, True, 0, 5, 1.5, b"tok", ["tok"], {"t": 1}]


@pytest.fixture(autouse=True)
def production(monkeypatch: pytest.MonkeyPatch) -> Iterator[None]:
    for name in ("CRONWATCH_ENV", "APP_ENV", "CRONWATCH_TOKEN", "CRON_SECRET"):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv("ENVIRONMENT", "production")
    yield


def client(**options: Any) -> cronwatch.Cronwatch:
    return cronwatch.Cronwatch(alerts=[Capture()], **options)


@pytest.mark.parametrize("blank", BLANK_TOKENS + JS_ONLY_SPACES)
def test_a_cronwatch_token_or_token_of_only_whitespace_counts_as_unset_so_the_routes_stay_locked(monkeypatch: pytest.MonkeyPatch, blank: str) -> None:
    monkeypatch.setenv("CRONWATCH_TOKEN", blank)
    for web in [client(cron_secret=None).routes(base_path="/cronwatch"), client(cron_secret=None).routes(token=blank, base_path="/cronwatch")]:
        assert web.token is None
        assert send(web, "GET", "/cronwatch/api/jobs").status == 503
        sign_in = send(web, "GET", f"/cronwatch/?token={urllib.parse.quote(blank)}")
        assert sign_in.status == 503
        assert "set-cookie" not in sign_in.headers
        assert send(web, "GET", "/cronwatch/api/jobs", {"authorization": "Bearer  "}).status == 503


def test_a_blank_token_given_in_code_falls_back_to_the_variable(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("CRONWATCH_TOKEN", "from-env")
    web = client(cron_secret=None).routes(token="  ", base_path="/cronwatch")
    assert send(web, "GET", "/cronwatch/api/jobs", {"authorization": "Bearer from-env"}).status == 200


def test_a_token_that_is_not_blank_is_used_as_it_is(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("CRONWATCH_TOKEN", " padded ")
    web = client(cron_secret=None).routes(base_path="/cronwatch")
    assert send(web, "GET", "/cronwatch/?token=%20padded%20").status == 303
    # U+0085 and U+001F are whitespace to str.strip() but not to JavaScript: a token of either is a token.
    for odd in ["\u0085", "\u001f"]:
        assert client(cron_secret=None).routes(token=odd).token == odd


@pytest.mark.parametrize("token", NOT_STRINGS)
def test_a_token_given_in_code_that_is_not_a_string_or_none_raises(token: Any) -> None:
    cw = client(cron_secret=None)
    with pytest.raises(TypeError, match=rf"^routes: token must be a string, or None to opt out, not {type(token).__name__}$"):
        cw.routes(token=token)


@pytest.mark.parametrize("blank", BLANK_SECRETS + JS_ONLY_SPACES)
def test_a_cron_secret_or_secret_of_only_whitespace_counts_as_unset(monkeypatch: pytest.MonkeyPatch, blank: str) -> None:
    for options, handler_secret in [({}, None), ({"cron_secret": blank}, None), ({"cron_secret": None}, blank)]:
        monkeypatch.setenv("CRON_SECRET", blank)
        errors = Errors()
        cw = client(on_error=errors, **options)
        if handler_secret is None:
            assert cw.cron_secret is None, repr(blank)
            handler = cw.job("j").handler(lambda ctx, request: None)
        else:
            handler = cw.job("j").handler(lambda ctx, request: None, secret=handler_secret)
        res = handler(Request("GET", "/", "", {"authorization": "Bearer  "}))
        if handler_secret is None:
            assert res.status == 503, repr(blank)
            assert errors.wheres == ["handler"], repr(blank)
        else:
            # A blank handler secret falls back to the client's, here opted out with None.
            assert res.status == 200, repr(blank)


def test_a_blank_cron_secret_is_no_secret_for_api_check_either(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("CRON_SECRET", "  ")
    web = client().routes(token="tok", base_path="/cronwatch")
    assert send(web, "POST", "/cronwatch/api/check", {"authorization": "Bearer   "}).status == 401
    # Anything else is used as it is.
    monkeypatch.setenv("CRON_SECRET", "s3cret")
    assert client().cron_secret == "s3cret"


@pytest.mark.parametrize("value", NOT_STRINGS)
def test_a_cron_secret_or_handler_secret_that_is_not_a_string_or_none_raises(value: Any) -> None:
    name = type(value).__name__
    with pytest.raises(TypeError, match=rf"^cron_secret must be a string, or None to opt out, not {name}$"):
        client(cron_secret=value)
    cw = client(cron_secret="s")
    with pytest.raises(TypeError, match=rf"^handler: secret must be a string, or None to opt out, not {name}$"):
        cw.job("j").handler(lambda ctx, request: None, secret=value)


def test_an_authorization_header_that_is_not_a_bearer_leaves_the_cookie_and_query_to_sign_in() -> None:
    web = client(cron_secret=None).routes(token="tok", base_path="/cronwatch")
    cookie = {"cookie": send(web, "GET", "/cronwatch/?token=tok").headers["set-cookie"].split(";")[0]}
    basic = {"authorization": "Basic dXNlcjpwYXNz"}
    assert send(web, "GET", "/cronwatch/api/jobs", {**basic, **cookie}).status == 200
    assert send(web, "GET", "/cronwatch/", {**basic, **cookie}).status == 200
    assert send(web, "GET", "/cronwatch/api/jobs", basic).status == 401
    link = send(web, "GET", "/cronwatch/jobs/x?token=tok", basic)
    assert link.status == 303
    assert link.headers["set-cookie"]
    # Not a bearer, so GET /api/check does not run on its strength.
    assert send(web, "GET", "/cronwatch/api/check", {**basic, **cookie}).status == 405
    # A bearer is matched whatever the scheme's case, and with any whitespace after it.
    for authorization in ["Bearer tok", "bearer tok", "BEARER\ttok", "Bearer   tok"]:
        assert send(web, "GET", "/cronwatch/api/jobs", {"authorization": authorization}).status == 200, authorization
    # A wrong bearer still wins over a good cookie; "Bearer" with nothing after it, or run on, is no bearer.
    assert send(web, "GET", "/cronwatch/api/jobs", {"authorization": "Bearer wrong", **cookie}).status == 401
    assert send(web, "GET", "/cronwatch/api/jobs", {"authorization": "Bearer", **cookie}).status == 200
    assert send(web, "GET", "/cronwatch/api/jobs", {"authorization": "Bearertok", **cookie}).status == 200
