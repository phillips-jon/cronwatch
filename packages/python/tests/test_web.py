"""The SDK's routes tests (routes.test.ts, routes-security.test.ts,
routes-origin.test.ts, routes-pwa.test.ts and routes-timeline.test.ts)
against cronwatch.web, through its WSGI app, plus what only a Python server
needs: decoded paths, the mount point, HEAD and the ASGI app."""

from __future__ import annotations

import asyncio
import hashlib
import json
import re
import struct
from typing import Any

import pytest

from cronwatch import Run
from cronwatch._js import date_utc
from cronwatch.stores import MemoryStore
from cronwatch.types import JobDefinition
from cronwatch.web import Request, Web
from cronwatch.web import _origin

from helpers import HOUR, MIN, T0, Clock, Errors, WebResponse, boom, make, send

DIGEST = hashlib.sha256(b"cronwatch-cookie:tok").hexdigest()
COOKIE = {"cookie": f"cronwatch_token={DIGEST}"}
BEARER = {"authorization": "Bearer tok"}
FORM = {"content-type": "application/x-www-form-urlencoded"}
JSON_BODY = {**BEARER, "content-type": "application/json"}
CSP = (
    "default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; img-src 'self' data:; manifest-src 'self'; "
    "worker-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'"
)


@pytest.fixture(autouse=True)
def production(monkeypatch: pytest.MonkeyPatch) -> None:
    """No environment names development unless a test says so, and no token comes from outside."""
    for name in ("CRONWATCH_ENV", "APP_ENV", "ENVIRONMENT", "CRONWATCH_TOKEN"):
        monkeypatch.delenv(name, raising=False)


def app(token: Any = "tok", base_path: str | None = "/cronwatch", on_error: Any = None, **options: Any) -> Any:
    extra = {} if on_error is None else {"on_error": on_error}
    cw, clock, _ = make(**extra)
    web = cw.routes(token=token, base_path=base_path, **options)
    return cw, clock, web


# ------------------------------------------------------------ routes.test.ts


def test_everything_needs_the_token() -> None:
    _, _, web = app()
    assert send(web, "GET", "/cronwatch").status == 401
    assert send(web, "GET", "/cronwatch/api/jobs").status == 401
    assert send(web, "GET", "/cronwatch/api/jobs", {"authorization": "Bearer wrong"}).status == 401
    assert send(web, "GET", "/cronwatch/api/jobs", BEARER).status == 200


def test_the_check_endpoint_also_accepts_the_cron_secret_nothing_else_does() -> None:
    cw, _, _ = make(cron_secret="cron-s3cret")
    web = cw.routes(token="tok", base_path="/cronwatch")
    with_cron = {"authorization": "Bearer cron-s3cret"}
    assert send(web, "GET", "/cronwatch/api/check", with_cron).status == 200
    assert send(web, "GET", "/cronwatch/api/jobs", with_cron).status == 401
    assert send(web, "GET", "/cronwatch/api/check?token=cron-s3cret").status == 401, "only as a bearer header"


def test_token_in_the_query_sets_a_cookie_and_redirects_to_a_clean_url() -> None:
    _, _, web = app()
    res = send(web, "GET", "/cronwatch/?token=tok")
    assert res.status == 303
    assert res.headers["location"] == "/cronwatch/"
    cookie = res.headers["set-cookie"]
    assert cookie.split(";")[0] == f"cronwatch_token={DIGEST}", "a digest, not the token"
    assert "; Path=/cronwatch; HttpOnly; SameSite=Lax" in cookie
    page = send(web, "GET", "/cronwatch/", {"cookie": f"other=1; cronwatch_token={DIGEST}"})
    assert page.status == 200
    assert send(web, "GET", "/cronwatch/", {"cookie": "cronwatch_token=tok"}).status == 401, "the raw token is not a cookie"
    assert "text/html" in page.headers["content-type"]


def test_the_sign_in_redirect_keeps_the_rest_of_the_query_as_url_search_params_writes_it() -> None:
    _, _, web = app()
    res = send(web, "GET", "/cronwatch/?a=1&token=tok&b=x+y%2Fz&c=%7E*&d")
    assert res.headers["location"] == "/cronwatch/?a=1&b=x+y%2Fz&c=%7E*&d="


def test_dashboard_and_job_pages_render_json_api_answers() -> None:
    cw, clock, web = app()
    job = cw.job("nightly-report", schedule="0 2 * * *", description="Builds the PDF")

    def built(ctx: Any) -> None:
        ctx.log("built")
        clock.advance(2000)

    job.run(built)
    with pytest.raises(RuntimeError):
        cw.run("broken", boom("kaboom <script>"))

    dash = send(web, "GET", "/cronwatch", BEARER).text
    assert "nightly-report" in dash
    assert "Builds the PDF" in dash
    assert "healthy" in dash
    assert "failing" in dash
    assert '<p class="headline">2 jobs, <b>1 needing attention</b>.</p>' in dash
    assert '<div class="bad"><dt><i class="sq bad" aria-hidden="true"></i>failing</dt><dd>1</dd></div>' in dash
    assert re.search(r'<section class="sec" aria-label="Last 24 hours">[\s\S]*<figure class="timeline day">', dash)
    assert '<table class="board">' in dash
    assert '<form class="inline" method="post" action="/cronwatch/check"><button class="primary" type="submit">Run check now</button></form>' in dash

    page = send(web, "GET", "/cronwatch/jobs/broken", BEARER)
    assert page.status == 200
    html = page.text
    assert "kaboom &lt;script&gt;" in html, "error text is escaped"
    assert "<script>" not in html
    assert '<h1 class="jobname">broken</h1>' in html
    assert '<figure class="timeline week">' in html
    assert '<details class="out error" open><summary>error</summary><pre>RuntimeError: kaboom &lt;script&gt;' in html

    listed = send(web, "GET", "/cronwatch/api/jobs", BEARER).json()
    assert len(listed["jobs"]) == 2
    one = send(web, "GET", "/cronwatch/api/jobs/nightly-report?runs=5", BEARER).json()
    assert one["job"]["health"] == "healthy"
    assert len(one["runs"]) == 1
    assert one["runs"][0]["output"] == "built"

    assert send(web, "GET", "/cronwatch/api/jobs/missing", BEARER).status == 404
    assert send(web, "GET", "/cronwatch/jobs/missing", BEARER).status == 404
    assert send(web, "GET", "/cronwatch/nope", BEARER).status == 404


def test_a_run_whose_metrics_hold_something_other_than_a_finite_number_still_shows_its_jobs_page() -> None:
    cw, c, web = app()
    cw.job("imported")
    nan = Run(id="nan", job="imported", status="ok", started_at=c.now(), finished_at=c.now(), duration_ms=0, trigger="source", metrics={"rows": float("nan")})
    with pytest.raises(ValueError, match='^record_run: metric "rows" must be a finite number \\(job "imported", run "nan"\\)$'):
        cw.record_run(nan)
    assert cw.get_run("nan") is None, "nothing is written"
    for value in (float("inf"), None, "3"):
        with pytest.raises(ValueError, match="must be a finite number"):
            cw.record_run(Run(id="bad", job="imported", status="ok", started_at=c.now(), trigger="source", metrics={"rows": value}))  # type: ignore[dict-item]
    # As a foreign row, or a store that kept NaN as null, may hold them.
    cw.store.insert_run(Run(id="odd", job="imported", status="ok", started_at=c.now(), finished_at=c.now(), duration_ms=0, trigger="source",
                            metrics={"rows": None, "label": "abc", "cost": 1.25, "n": 3}))  # type: ignore[dict-item]  # fmt: skip
    res = send(web, "GET", "/cronwatch/jobs/imported", BEARER)
    assert res.status == 200
    assert '<span class="k">cost</span> 1.2500</span><span><span class="k">n</span> 3<' in res.text
    assert not re.search(r'class="k">(rows|label)<', res.text)


def test_check_silence_unsilence_and_forget_over_the_api() -> None:
    cw, _, web = app()
    cw.run("s", lambda ctx: None)

    def post(path: str, body: Any = None) -> WebResponse:
        return send(web, "POST", path, JSON_BODY, None if body is None else json.dumps(body))

    check = post("/cronwatch/api/check").json()
    assert check["ok"] is True
    assert len(check["jobs"]) == 1
    silenced = post("/cronwatch/api/jobs/s/silence", {"for": "2h"}).json()
    assert silenced["state"]["silencedUntil"] > 0
    assert cw.job_summary("s").health == "silenced"
    un = post("/cronwatch/api/jobs/s/unsilence").json()
    assert un["state"]["silencedUntil"] is None
    assert post("/cronwatch/api/jobs/nope/silence", {"for": "1h"}).status == 404
    deleted = send(web, "DELETE", "/cronwatch/api/jobs/s", BEARER)
    assert deleted.status == 200
    assert cw.job_summary("s") is None


def test_dashboard_forms_post_and_redirect_back() -> None:
    cw, _, web = app()
    cw.run("f", lambda ctx: None)
    form = send(web, "POST", "/cronwatch/jobs/f/silence", {**BEARER, **FORM, "referer": "http://app.test/cronwatch/jobs/f"}, "for=4h")
    assert form.status == 303
    assert form.headers["location"] == "http://app.test/cronwatch/jobs/f"
    assert cw.job_summary("f").health == "silenced"
    elsewhere = send(web, "POST", "/cronwatch/jobs/f/unsilence", {**BEARER, "referer": "https://evil.example/phish"})
    assert elsewhere.headers["location"] == "/cronwatch/", "a foreign referer is not followed"


def test_a_multipart_form_is_read_like_form_data() -> None:
    cw, clock, web = app()
    cw.run("f", lambda ctx: None)
    boundary = "----cw"
    body = (
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"for\"\r\n\r\n2h\r\n"
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.txt\"\r\nContent-Type: text/plain\r\n\r\nhello\r\n"
        f"--{boundary}--\r\n"
    )
    res = send(web, "POST", "/cronwatch/jobs/f/silence", {**BEARER, "content-type": f"multipart/form-data; boundary={boundary}"}, body)
    assert res.status == 303
    assert cw.job_summary("f").silenced_until == clock.now() + 2 * HOUR


def unconfigured(token: Any = ..., base_path: str = "/cronwatch") -> Any:
    cw, _, _ = make()
    web = cw.routes(base_path=base_path) if token is ... else cw.routes(token=token, base_path=base_path)
    return lambda path, host="localhost": send(web, "GET", f"http://{host}{path}")


@pytest.mark.parametrize("env", [None, "production", "staging", ""])
def test_without_a_token_outside_development_the_routes_are_locked(monkeypatch: pytest.MonkeyPatch, env: str | None) -> None:
    if env is not None:
        monkeypatch.setenv("CRONWATCH_ENV", env)
    get = unconfigured()
    assert get("/cronwatch/api/jobs").status == 503
    locked = get("/cronwatch")
    assert locked.status == 503
    assert "CronWatch routes are locked" in locked.text


@pytest.mark.parametrize("env", ["development", "test"])
def test_without_a_token_in_development_a_made_up_token_is_printed_once_and_required(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str], env: str
) -> None:
    monkeypatch.setenv("CRONWATCH_ENV", env)
    cw, _, _ = make()
    web = cw.routes(base_path="/cronwatch/")
    # Every request is refused without the token, whatever it claims about where it came from.
    for url, headers in [
        ("http://localhost:3000/cronwatch/api/jobs", {}),
        ("http://localhost:3000/cronwatch/api/jobs", {"x-forwarded-for": "127.0.0.1"}),
        ("http://127.0.0.1:3000/cronwatch/", {}),
        ("http://192.168.1.20:3000/cronwatch/api/jobs", {}),
    ]:
        assert send(web, "GET", url, headers).status == 401, url
    lines = capsys.readouterr().out.splitlines()
    assert len(lines) == 1, "announced once, on the first request"
    match = re.fullmatch(
        r"\[cronwatch\] CRONWATCH_TOKEN is not set, so this development server made a token for the dashboard\. "
        r"Sign in: http://localhost:3000/cronwatch/\?token=([A-Za-z0-9_-]{43})",
        lines[0],
    )
    assert match, lines[0]
    token = match.group(1)

    page = send(web, "GET", "http://localhost:3000/cronwatch/")
    assert page.status == 401
    assert "sign-in link is in the server log" in page.text
    assert "in the server log" in send(web, "GET", "http://localhost:3000/cronwatch/api/jobs").json()["error"]

    sign_in = send(web, "GET", f"http://localhost:3000/cronwatch/?token={token}")
    assert sign_in.status == 303
    assert sign_in.headers["location"] == "/cronwatch/"
    cookie = sign_in.headers["set-cookie"].split(";")[0]
    assert send(web, "GET", "http://localhost:3000/cronwatch/", {"cookie": cookie}).status == 200
    assert send(web, "GET", "http://localhost:3000/cronwatch/api/jobs", {"authorization": f"Bearer {token}"}).status == 200

    other = make()[0].routes(base_path="/")
    send(other, "GET", "https://dev.example:8443/api/jobs")
    second = capsys.readouterr().out.splitlines()
    assert re.search(r"Sign in: /\?token=[A-Za-z0-9_-]{43} on this server \(the first request's host is not local, so the link leaves it out\)$", second[0]), "no host that is not local, and a root mount"
    other_token = re.search(r"token=([A-Za-z0-9_-]{43})", second[0])
    assert other_token and other_token.group(1) != token, "each routes instance makes its own"


def test_an_empty_token_counts_as_unset_none_opts_out_explicitly(monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]) -> None:
    monkeypatch.setenv("CRONWATCH_ENV", "production")
    monkeypatch.setenv("CRONWATCH_TOKEN", "")
    assert unconfigured()("/cronwatch/api/jobs").status == 503
    assert unconfigured("")("/cronwatch/api/jobs").status == 503
    assert unconfigured(None)("/cronwatch/api/jobs", "app.test").status == 200, "token=None serves open"

    monkeypatch.setenv("CRONWATCH_ENV", "development")
    monkeypatch.delenv("CRONWATCH_TOKEN")
    assert unconfigured(None)("/cronwatch/api/jobs", "app.test").status == 200, "token=None serves open in development too"
    assert capsys.readouterr().out == "", "and makes no token"

    monkeypatch.setenv("CRONWATCH_TOKEN", "envtok")
    assert unconfigured()("/cronwatch/api/jobs").status == 401, "a configured token is used in development"
    assert capsys.readouterr().out == ""

    monkeypatch.setenv("CRONWATCH_ENV", "production")
    cw, _, _ = make()
    web = cw.routes(token="", base_path="/cronwatch")
    assert send(web, "GET", "/cronwatch/api/jobs").status == 401
    assert send(web, "GET", "/cronwatch/api/jobs", {"authorization": "Bearer envtok"}).status == 200


# ------------------------------------------------------------ routes-security.test.ts


@pytest.mark.parametrize(
    "headers",
    [
        {"origin": "https://evil.example"},
        {"origin": "null"},
        {"sec-fetch-site": "cross-site"},
        {"sec-fetch-site": "same-site"},
        {"origin": "http://app.test", "sec-fetch-site": "cross-site"},
    ],
)
def test_cross_site_writes_are_refused_whatever_the_credentials(headers: dict[str, str]) -> None:
    cw, _, web = app()
    cw.run("x", lambda ctx: None)
    assert send(web, "POST", "/cronwatch/jobs/x/silence", {**COOKIE, **FORM, **headers}, "for=1h").status == 403
    assert send(web, "POST", "/cronwatch/api/check", {**BEARER, **headers}).status == 403
    assert send(web, "DELETE", "/cronwatch/api/jobs/x", {**COOKIE, **headers}).status == 403
    assert cw.job_summary("x") is not None
    assert cw.job_summary("x").silenced_until is None


def test_same_origin_forms_and_header_less_api_clients_still_write() -> None:
    cw, _, web = app()
    cw.run("x", lambda ctx: None)
    same = {"origin": "http://app.test", "sec-fetch-site": "same-origin", "referer": "http://app.test/cronwatch/jobs/x"}
    assert send(web, "POST", "/cronwatch/check", {**COOKIE, **same}).status == 303, "the dashboard's Run check now button"
    silence = send(web, "POST", "/cronwatch/jobs/x/silence", {**COOKIE, **same, **FORM}, "for=4h")
    assert silence.status == 303
    assert silence.headers["location"] == "http://app.test/cronwatch/jobs/x"
    assert send(web, "POST", "/cronwatch/api/jobs/x/unsilence", BEARER).status == 200
    assert send(web, "POST", "/cronwatch/api/check", {**BEARER, "sec-fetch-site": "none"}).status == 200


def test_get_api_check_runs_only_for_a_bearer_cookies_must_post() -> None:
    _, _, web = app()
    via_cookie = send(web, "GET", "/cronwatch/api/check", COOKIE)
    assert via_cookie.status == 405
    assert via_cookie.headers["allow"] == "POST"
    assert send(web, "POST", "/cronwatch/api/check", COOKIE).status == 200
    assert send(web, "GET", "/cronwatch/api/check", BEARER).status == 200


def test_token_in_the_query_is_only_accepted_on_an_html_get() -> None:
    cw, _, web = app()
    cw.run("x", lambda ctx: None)
    assert send(web, "GET", "/cronwatch/api/jobs?token=tok").status == 401
    assert send(web, "GET", "/cronwatch/api/jobs/x?token=tok").status == 401
    assert send(web, "POST", "/cronwatch/api/check?token=tok").status == 401
    assert send(web, "POST", "/cronwatch/check?token=tok").status == 401
    assert send(web, "POST", "/cronwatch/jobs/x/forget?token=tok").status == 401
    assert cw.job_summary("x") is not None
    assert send(web, "GET", "/cronwatch/jobs/x?token=tok").status == 303


def test_malformed_cookies_and_paths_are_answered_not_raised() -> None:
    _, _, web = app()
    assert send(web, "GET", "/cronwatch/", {"cookie": "cronwatch_token=%E0%A4%A"}).status == 401
    assert send(web, "GET", "/cronwatch/api/jobs", {"cookie": "cronwatch_token=%"}).status == 401
    assert send(web, "GET", "/cronwatch/jobs/%E0%A4%A", BEARER).status == 400
    api = send(web, "GET", "/cronwatch/api/jobs/%zz", BEARER)
    assert api.status == 400
    assert api.json()["ok"] is False
    assert send(web, "POST", "/cronwatch/api/jobs/%zz/silence", BEARER).status == 400


@pytest.mark.parametrize(("runs", "count"), [("0", 1), ("-5", 1), ("2.7", 2), ("abc", 3), ("", 3), ("1e9", 3), ("Infinity", 3), ("0x2", 2), (" 2 ", 2), ("1_0", 3)])
def test_runs_is_clamped_to_a_whole_number_in_range(runs: str, count: int) -> None:
    cw, _, web = app()
    for _ in range(3):
        cw.run("r", lambda ctx: None)
    assert len(send(web, "GET", f"/cronwatch/api/jobs/r?runs={runs}", BEARER).json()["runs"]) == count


def test_an_unexpected_error_is_a_generic_500_reported_through_on_error() -> None:
    errors = Errors()
    cw, _, web = app(on_error=errors)

    def fail(*args: Any) -> Any:
        raise RuntimeError("secret connection string")

    cw.jobs = fail  # type: ignore[method-assign]
    cw.jobs_with_runs = fail  # type: ignore[method-assign]
    api = send(web, "GET", "/cronwatch/api/jobs", BEARER)
    assert api.status == 500
    assert "secret" not in api.text
    assert api.json() == {"ok": False, "error": "Internal error"}
    page = send(web, "GET", "/cronwatch/", BEARER)
    assert page.status == 500
    assert "text/html" in page.headers["content-type"]
    assert "secret" not in page.text
    assert errors.wheres == ["routes", "routes"]
    assert "secret connection string" in errors.messages[0]


def test_a_raising_on_error_still_yields_a_500() -> None:
    def logger_down(error: BaseException, where: str) -> None:
        raise RuntimeError("logger down")

    cw, _, web = app(on_error=logger_down)
    cw.jobs = boom("boom")  # type: ignore[method-assign]
    assert send(web, "GET", "/cronwatch/api/jobs", BEARER).status == 500


def test_silence_durations_strings_are_validated_numbers_are_milliseconds() -> None:
    cw, clock, web = app()
    cw.run("s", lambda ctx: None)

    def silence(body: Any) -> WebResponse:
        return send(web, "POST", "/cronwatch/api/jobs/s/silence", JSON_BODY, json.dumps(body))

    for bad in ["forever", "2 hours", "", "-5", "1h then some"]:
        res = silence({"for": bad})
        assert res.status == 400, bad
        assert res.json()["ok"] is False
        assert "silence duration" in res.json()["error"], bad
    assert cw.job_summary("s").silenced_until is None, "a bad duration silences nothing"

    def until(body: Any) -> Any:
        return silence(body).json()["state"]["silencedUntil"] - clock.now()

    assert until({"for": 7_200_000}) == 7_200_000
    assert until({"for": "60000"}) == 60_000
    assert until({"for": "90m"}) == 90 * 60_000
    assert until({}) == HOUR
    assert send(web, "POST", "/cronwatch/api/jobs/s/silence?for=forever", BEARER).status == 400


def test_the_silence_form_shows_an_error_for_a_bad_duration_and_404s_a_missing_job() -> None:
    cw, _, web = app()
    cw.run("s", lambda ctx: None)
    form = {**COOKIE, **FORM}
    bad = send(web, "POST", "/cronwatch/jobs/s/silence", form, "for=forever")
    assert bad.status == 400
    assert "text/html" in bad.headers["content-type"]
    assert "silence duration &quot;forever&quot;" in bad.text
    assert cw.job_summary("s").silenced_until is None
    assert send(web, "POST", "/cronwatch/jobs/ghost/silence", form, "for=1h").status == 404
    assert send(web, "POST", "/cronwatch/jobs/ghost/unsilence", form).status == 404
    assert send(web, "POST", "/cronwatch/jobs/s/explode", form).status == 404


def test_pages_carry_a_strict_csp_and_security_headers_and_need_no_script_of_their_own() -> None:
    cw, _, web = app()
    cw.run("h", lambda ctx: None)
    for path in ["/cronwatch/", "/cronwatch/jobs/h", "/cronwatch/nope"]:
        res = send(web, "GET", path, BEARER)
        assert res.headers["content-security-policy"] == CSP
        assert res.headers["x-frame-options"] == "DENY"
        assert res.headers["x-content-type-options"] == "nosniff"
        assert res.headers["referrer-policy"] == "same-origin"
        assert res.headers["cache-control"] == "no-store"
        html = res.text
        assert re.findall(r"<script[^>]*>[^<]*</script>", html, re.I) == ['<script src="/cronwatch/app.js" defer></script>']
        assert len(re.findall(r"<script", html, re.I)) == 1
        assert not re.search(r"\son[a-z]+=", html, re.I), "no inline event handlers"
    page = send(web, "GET", "/cronwatch/jobs/h", BEARER).text
    assert '<details class="confirm"><summary>Forget</summary><form' in page
    api = send(web, "GET", "/cronwatch/api/jobs", BEARER)
    assert api.headers["x-content-type-options"] == "nosniff"
    assert api.headers["cache-control"] == "no-store"


def test_markup_in_definitions_output_and_metrics_stays_escaped_on_every_page() -> None:
    cw, _, web = app()
    job = cw.job("m", schedule="0 2 * * *", description="<img src=x>", tags=["<t>"], expect="<e>")

    def work(ctx: Any) -> None:
        ctx.log("<o>")
        ctx.metric("<k>", 1)

    job.run(work)
    for path in ["/cronwatch/", "/cronwatch/jobs/m", "/cronwatch/jobs/%3Cx%3E"]:
        html = send(web, "GET", path, BEARER).text
        assert not re.search(r"<img|<t>|<e>|<o>|<k>|<x>", html), path


def test_without_a_token_in_development_nothing_a_request_says_about_itself_lets_it_in(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setenv("CRONWATCH_ENV", "development")
    cw, _, _ = make()
    web = cw.routes(base_path="/cronwatch")
    local = "http://localhost:3000/cronwatch/api/jobs"
    looks_local = [
        {},
        {"x-forwarded-host": "localhost:3000", "x-forwarded-for": "::ffff:127.0.0.1", "x-forwarded-port": "3000", "x-forwarded-proto": "http"},
        {"x-forwarded-for": "::1"},
        {"forwarded": 'for="[::1]:51234";host=localhost;proto=http'},
        {"x-real-ip": "127.0.0.1"},
    ]
    for headers in looks_local:
        res = send(web, "GET", local, headers)
        assert res.status == 401, headers
        assert res.json()["ok"] is False
    assert send(web, "POST", "http://localhost:3000/cronwatch/api/check").status == 401


# ------------------------------------------------------------ routes-origin.test.ts

INTERNAL = "http://10.0.0.5:8080"


def behind(internal: str = INTERNAL, **options: Any) -> Any:
    """An app that sees its requests on an internal URL, as it does behind a proxy."""
    cw, clock, _ = make()
    web = cw.routes(token="tok", base_path="/cronwatch", **options)

    def go(method: str, path: str, headers: dict[str, str] | None = None, body: str | None = None) -> WebResponse:
        return send(web, method, f"{internal}{path}", headers, body)

    return cw, clock, go


def silenced(cw: Any) -> bool:
    return cw.job_summary("x").silenced_until is not None


def test_by_default_the_request_urls_origin_is_the_origin() -> None:
    cw, _, go = behind()
    cw.run("x", lambda ctx: None)
    assert go("POST", "/cronwatch/jobs/x/silence", {**COOKIE, **FORM, "origin": "https://app.example.com"}, "for=1h").status == 403
    assert not silenced(cw)
    assert go("POST", "/cronwatch/jobs/x/silence", {**COOKIE, **FORM, "origin": INTERNAL}, "for=1h").status == 303
    assert "Secure" not in go("GET", "/cronwatch/?token=tok").headers["set-cookie"]


def test_origin_replaces_the_request_urls_origin_for_writes_sign_in_and_redirects() -> None:
    cw, clock, go = behind(origin="https://app.example.com/ignored/path")
    cw.run("x", lambda ctx: None)
    assert go("POST", "/cronwatch/jobs/x/silence", {**COOKIE, **FORM, "origin": INTERNAL}, "for=1h").status == 403, "the internal origin is now foreign"
    assert not silenced(cw)
    referer = "https://app.example.com/cronwatch/jobs/x"
    ok = go("POST", "/cronwatch/jobs/x/silence", {**COOKIE, **FORM, "origin": "https://app.example.com", "referer": referer}, "for=2h")
    assert ok.status == 303
    assert ok.headers["location"] == referer, "the Referer on the public origin is followed back"
    assert cw.job_summary("x").silenced_until == clock.now() + 2 * HOUR
    sign_in = go("GET", "/cronwatch/jobs/x?token=tok")
    assert sign_in.status == 303
    assert sign_in.headers["location"] == "/cronwatch/jobs/x"
    assert sign_in.headers["set-cookie"].endswith("; Secure"), "the public origin is https, so the cookie is Secure"


def test_origin_takes_precedence_over_trust_proxy_and_forwarded_headers() -> None:
    cw, _, go = behind(origin="https://app.example.com", trust_proxy=True)
    cw.run("x", lambda ctx: None)
    forwarded = {"x-forwarded-proto": "https", "x-forwarded-host": "other.example"}
    assert go("POST", "/cronwatch/check", {**COOKIE, **forwarded, "origin": "https://other.example"}).status == 403
    assert go("POST", "/cronwatch/check", {**COOKIE, **forwarded, "origin": "https://app.example.com"}).status == 303


def test_an_origin_that_is_not_an_http_or_https_url_fails_when_the_routes_are_made() -> None:
    cw, _, _ = make()
    with pytest.raises(ValueError, match='^routes: origin must be an absolute URL such as "https://app.example.com", got "app.example.com"$'):
        cw.routes(token="tok", origin="app.example.com")
    with pytest.raises(ValueError, match='^routes: origin must be http or https, got "ftp://app.example.com"$'):
        cw.routes(token="tok", origin="ftp://app.example.com")
    cw.routes(token="tok", origin="")
    cw.routes(token="tok", origin=None)


# What `new URL(value).origin` gives for each, in Node 24.
@pytest.mark.parametrize(
    ("given", "expected"),
    [
        ("https://App.Example.com/cronwatch?x=1#y", "https://app.example.com"),
        ("HTTPS://app.example.com:443/", "https://app.example.com"),
        ("http://app.example.com:80", "http://app.example.com"),
        ("http://localhost:3000/", "http://localhost:3000"),
        ("https://app.example.com:8443", "https://app.example.com:8443"),
        (" https://app.example.com ", "https://app.example.com"),
        ("\thttps://a.example\n", "https://a.example"),
        ("https://app.exa\tmple.com", "https://app.example.com"),
        ("https://APP.example.com.", "https://app.example.com."),
        ("https://user:pw@app.example.com", "https://app.example.com"),
        ("https://app.example.com:", "https://app.example.com"),
        ("https:app.example.com", "https://app.example.com"),
        ("https:/app.example.com", "https://app.example.com"),
        ("https:\\\\app.example.com", "https://app.example.com"),
        ("https://[::1]:8080", "https://[::1]:8080"),
        ("https://[0:0::1]", "https://[::1]"),
        ("https://127.1", "https://127.0.0.1"),
        ("https://0x7f.1", "https://127.0.0.1"),
        ("https://app.example.com:0080", "https://app.example.com:80"),
        ("https://app.example.com:0", "https://app.example.com:0"),
        ("https://a_b.example.com", "https://a_b.example.com"),
        ("https://%61pp.example", "https://app.example"),
        ("https://xn--bcher-kva.example", "https://xn--bcher-kva.example"),
        ("https://Bücher.example", "https://xn--bcher-kva.example"),
        ("https://65535.example:65535", "https://65535.example:65535"),
    ],
)
def test_the_origin_is_read_as_the_url_parser_reads_it(given: str, expected: str) -> None:
    assert _origin.parse(given) == expected


@pytest.mark.parametrize(
    "given",
    [
        "https://app.example.com:65536",
        "https://app.example.com:99999999999",
        "https://ex ample.com",
        "https://app.example.com:8x",
        "https://[::1",
        "https://[nope]",
        "https://[::1%25eth0]",
        "https://256.1.1.1",
        "https://1.2.3.4.5",
        "https://09.1.1.1",
        "https://%zz.example",
        "https://%ff.example",
        "http://",
        "https:",
        "https://@",
        "https://a<b",
    ],
)
def test_an_origin_with_a_bad_host_or_port_raises(given: str) -> None:
    with pytest.raises(ValueError, match="^routes: origin must be an absolute URL"):
        _origin.parse(given)


def test_trust_proxy_takes_the_origin_from_the_first_forwarded_proto_and_host() -> None:
    cw, _, go = behind(trust_proxy=True)
    cw.run("x", lambda ctx: None)
    forwarded = {"x-forwarded-proto": "https, http", "x-forwarded-host": "app.example.com, 10.0.0.5:8080"}
    assert go("POST", "/cronwatch/jobs/x/silence", {**COOKIE, **FORM, **forwarded, "origin": INTERNAL}, "for=1h").status == 403
    assert go("POST", "/cronwatch/jobs/x/silence", {**COOKIE, **FORM, **forwarded, "origin": "https://app.example.com"}, "for=1h").status == 303
    assert go("GET", "/cronwatch/?token=tok", forwarded).headers["set-cookie"].endswith("; Secure")
    # Only the scheme forwarded: the host stays the request's.
    assert go("POST", "/cronwatch/check", {**COOKIE, "x-forwarded-proto": "https", "origin": "https://10.0.0.5:8080"}).status == 303
    # Neither forwarded: the request URL's origin, as without trust_proxy.
    assert go("POST", "/cronwatch/check", {**COOKIE, "origin": INTERNAL}).status == 303


@pytest.mark.parametrize(
    ("headers", "origin"),
    [
        ({"x-forwarded-proto": "javascript", "x-forwarded-host": "evil.example"}, "javascript://evil.example"),
        ({"x-forwarded-proto": "https", "x-forwarded-host": "evil.example/path"}, "https://evil.example"),
        ({"x-forwarded-proto": "https", "x-forwarded-host": "user@evil.example"}, "https://evil.example"),
    ],
)
def test_trust_proxy_ignores_forwarded_values_that_are_not_a_scheme_and_a_bare_host(headers: dict[str, str], origin: str) -> None:
    cw, _, go = behind(trust_proxy=True)
    cw.run("x", lambda ctx: None)
    assert go("POST", "/cronwatch/check", {**COOKIE, **headers, "origin": origin}).status == 403
    assert go("POST", "/cronwatch/check", {**COOKIE, **headers, "origin": INTERNAL}).status == 303


def test_without_trust_proxy_a_spoofed_forwarded_host_or_proto_changes_nothing() -> None:
    cw, _, go = behind("http://app.test")
    cw.run("x", lambda ctx: None)
    spoofed = {"x-forwarded-host": "evil.example", "x-forwarded-proto": "https"}
    assert go("POST", "/cronwatch/jobs/x/silence", {**COOKIE, **FORM, **spoofed, "origin": "https://evil.example"}, "for=1h").status == 403
    assert not silenced(cw)
    back = go("POST", "/cronwatch/check", {**COOKIE, **spoofed, "origin": "http://app.test", "referer": "https://evil.example/cronwatch/jobs/x"})
    assert back.status == 303
    assert back.headers["location"] == "/cronwatch/", "a Referer on the spoofed origin is not followed"
    assert "Secure" not in go("GET", "/cronwatch/?token=tok", spoofed).headers["set-cookie"]


def test_a_mixed_case_host_matches_the_browsers_lowercase_origin() -> None:
    cw, _, go = behind("http://App.Example.com")
    cw.run("x", lambda ctx: None)
    assert go("POST", "/cronwatch/check", {**COOKIE, "origin": "http://app.example.com"}).status == 303


def test_the_development_sign_in_line_uses_the_public_origin_when_set_or_loopback_and_otherwise_leaves_the_host_out(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setenv("CRONWATCH_ENV", "development")
    cw, _, _ = make()
    spoofed = {"x-forwarded-proto": "https", "x-forwarded-host": "attacker.example"}
    cases: list[tuple[dict[str, Any], str, dict[str, str]]] = [
        ({"origin": "https://app.example.com"}, f"{INTERNAL}/cronwatch/", {}),
        ({"origin": "https://app.example.com", "trust_proxy": True}, f"{INTERNAL}/cronwatch/", spoofed),
        ({}, "http://localhost:3000/cronwatch/", {}),
        ({}, "http://app.localhost:3000/cronwatch/", {}),
        ({}, "http://127.0.0.1:3000/cronwatch/", {}),
        ({}, "http://127.8.9.10/cronwatch/", {}),
        ({}, "http://[::1]:3000/cronwatch/", {}),
        ({"trust_proxy": True}, f"{INTERNAL}/cronwatch/", {"x-forwarded-host": "localhost:5173"}),
        ({}, f"{INTERNAL}/cronwatch/", {}),
        ({}, "https://app.example.com/cronwatch/", {}),
        ({"trust_proxy": True}, "http://localhost:3000/cronwatch/", spoofed),
        ({}, "http://localhost.example/cronwatch/", {}),
        ({}, "http://128.0.0.1/cronwatch/", {}),
        ({"base_path": "/"}, "http://attacker.example/", {}),
        # A WSGI server passes a Host header through as sent: it is read as a URL.
        ({}, f"{INTERNAL}/cronwatch/", {"host": "localhost:1@evil.example"}),
        ({}, f"{INTERNAL}/cronwatch/", {"host": "evil.example/.localhost"}),
        ({"trust_proxy": True}, f"{INTERNAL}/cronwatch/", {"x-forwarded-host": "localhost:1@evil.example"}),
        ({"trust_proxy": True}, f"{INTERNAL}/cronwatch/", {"x-forwarded-host": "evil.example/.localhost"}),
    ]
    for options, url, headers in cases:
        send(cw.routes(**{"base_path": "/cronwatch", **options}), "GET", url, headers)
    lines = capsys.readouterr().out.splitlines()
    intro = "[cronwatch] CRONWATCH_TOKEN is not set, so this development server made a token for the dashboard. Sign in: "
    hostless = " on this server (the first request's host is not local, so the link leaves it out)"
    expected = [
        ("https://app.example.com/cronwatch", ""),
        ("https://app.example.com/cronwatch", ""),
        ("http://localhost:3000/cronwatch", ""),
        ("http://app.localhost:3000/cronwatch", ""),
        ("http://127.0.0.1:3000/cronwatch", ""),
        ("http://127.8.9.10/cronwatch", ""),
        ("http://[::1]:3000/cronwatch", ""),
        ("http://localhost:5173/cronwatch", ""),
        ("/cronwatch", hostless),
        ("/cronwatch", hostless),
        ("/cronwatch", hostless),
        ("/cronwatch", hostless),
        ("/cronwatch", hostless),
        ("", hostless),
        ("/cronwatch", hostless),
        ("/cronwatch", hostless),
        ("/cronwatch", hostless),
        ("/cronwatch", hostless),
    ]
    assert len(lines) == len(expected)
    for i, ((link, tail), line) in enumerate(zip(expected, lines)):
        token = re.search(r"token=([A-Za-z0-9_-]{43})", line)
        assert token, line
        assert line == f"{intro}{link}/?token={token.group(1)}{tail}", f"line {i}"


def test_only_an_origin_that_reads_as_one_is_loopback() -> None:
    from cronwatch.web import is_loopback_origin

    for yes in ("http://localhost", "http://localhost:3000", "http://app.localhost", "https://127.0.0.1", "http://127.8.9.10:1", "http://[::1]:3000"):
        assert is_loopback_origin(yes), yes
    for no in (
        "http://localhost.example",
        "http://128.0.0.1",
        "http://127.0.0.256",
        "http://10.0.0.5:8080",
        "http://[::2]",
        # A Host header that is not a host (the Rust audit).
        "http://evil.example/.localhost",
        "http://localhost:1@evil.example",
        "http://evil.example?.localhost",
        "http://evil.example#.localhost",
        "http://localhost:1@evil.example:80",
    ):
        assert not is_loopback_origin(no), no


# ------------------------------------------------------------ routes-pwa.test.ts


def test_the_manifest_describes_the_app_at_its_base_path_without_the_token() -> None:
    _, _, web = app()
    res = send(web, "GET", "/cronwatch/manifest.webmanifest")
    assert res.status == 200
    assert res.headers["content-type"] == "application/manifest+json"
    assert res.headers["x-content-type-options"] == "nosniff"
    manifest = res.json()
    assert (manifest["name"], manifest["short_name"], manifest["id"], manifest["start_url"], manifest["scope"]) == (
        "CronWatch",
        "CronWatch",
        "/cronwatch/",
        "/cronwatch/",
        "/cronwatch/",
    )
    assert (manifest["display"], manifest["background_color"], manifest["theme_color"]) == ("standalone", "#f4f4f5", "#ffffff")
    assert [[i["src"], i["sizes"], i["type"], i["purpose"]] for i in manifest["icons"]] == [
        ["/cronwatch/icons/icon.svg", "any", "image/svg+xml", "any"],
        ["/cronwatch/icons/maskable.svg", "any", "image/svg+xml", "maskable"],
        ["/cronwatch/icons/icon-192.png", "192x192", "image/png", "any"],
        ["/cronwatch/icons/icon-512.png", "512x512", "image/png", "any"],
        ["/cronwatch/icons/maskable-512.png", "512x512", "image/png", "maskable"],
    ]


@pytest.mark.parametrize(("base_path", "prefix", "base"), [("", "", ""), ("/", "", ""), ("/ops/cron/", "/ops/cron", "/ops/cron")])
def test_the_manifest_follows_the_base_path_wherever_the_routes_are_mounted(base_path: str, prefix: str, base: str) -> None:
    _, _, web = app(base_path=base_path)
    manifest = send(web, "GET", f"{prefix}/manifest.webmanifest").json()
    assert (manifest["start_url"], manifest["scope"], manifest["id"]) == (f"{base}/", f"{base}/", f"{base}/")
    assert manifest["icons"][0]["src"] == f"{base}/icons/icon.svg"
    assert send(web, "GET", f"{prefix}/sw.js").headers["service-worker-allowed"] == f"{base}/"


def test_icons_are_served_with_their_types_a_long_cache_and_no_token() -> None:
    _, _, web = app()
    for name, size in [("icon-192.png", 192), ("icon-512.png", 512), ("maskable-512.png", 512), ("apple-touch-icon.png", 180)]:
        res = send(web, "GET", f"/cronwatch/icons/{name}")
        assert res.status == 200, name
        assert res.headers["content-type"] == "image/png"
        assert res.headers["cache-control"] == "public, max-age=31536000, immutable"
        assert res.headers["x-content-type-options"] == "nosniff"
        assert "set-cookie" not in res.headers
        assert res.body[:8] == b"\x89PNG\r\n\x1a\n"
        assert struct.unpack(">II", res.body[16:24]) == (size, size), name
        assert len(res.body) < 10_000
    for name in ["icon.svg", "maskable.svg"]:
        res = send(web, "GET", f"/cronwatch/icons/{name}")
        assert res.headers["content-type"] == "image/svg+xml"
        assert res.headers["content-security-policy"] == "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'"
        assert re.search(r'<circle cx="20" cy="20" r="10.5"[^>]*stroke-width="2"', res.text)
        assert not re.search(r"<script|\son[a-z]+=", res.text, re.I)
    assert send(web, "GET", "/cronwatch/icons/nope.png").status == 401, "anything else under /icons needs the token"


def test_the_app_shell_is_public_even_when_the_routes_are_locked_or_opened(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("CRONWATCH_ENV", "production")
    cw, _, _ = make()
    locked = cw.routes(base_path="/cronwatch")
    cw.run("secret-job", lambda ctx: None)
    assert send(locked, "GET", "/cronwatch/").status == 503
    for path in ["/cronwatch/manifest.webmanifest", "/cronwatch/sw.js", "/cronwatch/app.js", "/cronwatch/offline", "/cronwatch/icons/icon.svg"]:
        res = send(locked, "GET", path)
        assert res.status == 200, path
        assert "secret-job" not in res.text
    assert send(app(token=None)[2], "GET", "/cronwatch/manifest.webmanifest").status == 200


def test_only_get_and_head_reach_the_app_shell() -> None:
    _, _, web = app()
    head = send(web, "HEAD", "/cronwatch/sw.js")
    assert head.status == 200
    assert head.body == b"", "a WSGI answer to HEAD has no body"
    assert int(head.headers["content-length"]) > 0
    assert send(web, "POST", "/cronwatch/sw.js").status == 401
    assert send(web, "POST", "/cronwatch/manifest.webmanifest", BEARER).status == 404


def test_pages_link_the_manifest_icons_and_app_js_under_the_base() -> None:
    cw, _, web = app(base_path="/ops/cron")
    cw.run("h", lambda ctx: None)
    for path in ["/ops/cron/", "/ops/cron/jobs/h", "/ops/cron/nope", "/ops/cron/offline"]:
        html = send(web, "GET", path, BEARER).text
        assert '<link rel="manifest" href="/ops/cron/manifest.webmanifest">' in html, path
        assert '<link rel="icon" href="/ops/cron/icons/icon.svg" type="image/svg+xml">' in html
        assert '<link rel="apple-touch-icon" href="/ops/cron/icons/apple-touch-icon.png">' in html
        assert '<meta name="theme-color" content="#111113" media="(prefers-color-scheme: dark)">' in html
        assert re.findall(r"<script[^>]*>[^<]*</script>", html) == ['<script src="/ops/cron/app.js" defer></script>']
        assert "@media(display-mode:standalone){\n.top{position:sticky;top:0" in html


def test_the_page_csp_allows_exactly_the_app_shell_and_data_stays_uncacheable() -> None:
    cw, _, web = app()
    cw.run("h", lambda ctx: None)
    for path in ["/cronwatch/", "/cronwatch/jobs/h", "/cronwatch/nope", "/cronwatch/offline"]:
        assert send(web, "GET", path, BEARER).headers["content-security-policy"] == CSP, path
    for path in ["/cronwatch/", "/cronwatch/jobs/h", "/cronwatch/api/jobs", "/cronwatch/api/jobs/h"]:
        assert send(web, "GET", path, BEARER).headers["cache-control"] == "no-store", path
    assert send(web, "GET", "/cronwatch/").headers["cache-control"] == "no-store", "the sign-in page too"


def test_the_sign_in_page_takes_the_token_in_a_form() -> None:
    _, _, web = app(base_path="/ops/cron")
    page = send(web, "GET", "/ops/cron/jobs/x")
    assert page.status == 401
    assert re.search(
        r'<form class="signin" method="get" action="/ops/cron/"><label for="token">Token</label><input id="token" name="token" '
        r'type="password" autocomplete="current-password"[^>]*required><button class="primary" type="submit">Sign in</button></form>',
        page.text,
    )
    res = send(web, "GET", "/ops/cron/?token=tok")
    assert (res.status, res.headers["location"]) == (303, "/ops/cron/")
    assert "; Path=/ops/cron; HttpOnly; SameSite=Lax" in res.headers["set-cookie"]
    assert 'class="signin"' not in send(web, "GET", "/ops/cron/offline").text


# ------------------------------------------------------------ routes-timeline.test.ts


def seeded() -> Any:
    """A board with a daily cron that failed today, an interval job that stopped, and a busy one."""
    clock = Clock(T0 - 30 * HOUR)
    cw, _, _ = make(clock)
    web = cw.routes(token="tok", base_path="/cronwatch")
    day = date_utc(2026, 0, 5)
    hourly = cw.job("hourly", schedule="0 * * * *", timezone="UTC")
    t = day - 24 * HOUR
    while t <= T0 - 30 * MIN:
        clock.set(t)
        hourly.run(lambda ctx: clock.advance(5 * MIN) and None)
        t += HOUR
    nightly = cw.job("nightly", schedule="0 3 * * *", timezone="UTC")
    clock.set(day + 3 * HOUR)

    def fail(ctx: Any) -> None:
        clock.advance(400)
        raise RuntimeError("boom")

    with pytest.raises(RuntimeError):
        nightly.run(fail)
    sync = cw.job("sync", schedule="every 30m", grace="5m")
    clock.set(T0 - 2 * HOUR)
    sync.run(lambda ctx: clock.advance(8000) and None)
    busy = cw.job("busy", schedule="every 5m", grace="4m")
    t = T0 - 3 * HOUR
    while t < T0:
        clock.set(t)
        busy.run(lambda ctx: clock.advance(1000) and None)
        t += 5 * MIN
    clock.set(T0)
    cw.check()
    return lambda path: send(web, "GET", path, BEARER).text


def test_the_board_draws_a_day_timeline() -> None:
    html = seeded()("/cronwatch/")
    lanes = re.search(r'<ol class="lanes">([\s\S]*?)</ol>', html).group(1)  # type: ignore[union-attr]

    def lane(name: str) -> str:
        return next(part for part in lanes.split("<li ") if f">{name}</a>" in part)

    hourly = lane("hourly")
    assert len(re.findall(r'<line class="tick"', hourly)) == 24, "a tick each hour of the last day"
    assert len(re.findall(r'<line class="tick ahead"', hourly)) == 3, "and dashed ones ahead"
    assert len(re.findall(r'class="run ok"', hourly)) >= 23
    assert "<title>hourly: ok at 09:00 UTC, took 5m</title>" in hourly
    nightly = lane("nightly")
    assert re.search(r'class="run bad"[^>]*><title>nightly: failed at 03:00 UTC, took 400ms</title>', nightly)
    assert re.search(r'<span class="note[^"]*"[^>]*>failed at 03:00</span>', nightly)
    sync = lane("sync")
    assert re.search(r'<rect class="missed"[^>]*><title>sync: due 08:00 UTC, nothing started', sync)
    assert ">due 08:00, nothing ran</span>" in sync
    assert len(re.findall(r'class="run ok"', lane("busy"))) == 36
    assert re.search(r'<i class="now" style="left:[\d.]+%"></i>', html)
    assert re.search(r'<span class="nowlabel"[^>]*>now 09:30</span>', html)
    assert '<ul class="vh"><li>busy (every 5m): ' in html
    assert re.search(r"@media\(prefers-reduced-motion:reduce\)\{[^}]*animation:none!important", html)
    assert re.search(r'<p class="headline">(.*?)</p>', html).group(1) == "4 jobs, <b>2 needing attention</b>."  # type: ignore[union-attr]


def test_a_job_page_draws_its_last_seven_days_today_first() -> None:
    html = seeded()("/cronwatch/jobs/hourly")
    week = re.search(r'<figure class="timeline week">([\s\S]*?)</figure>', html).group(1)  # type: ignore[union-attr]
    assert len(re.findall(r'<li class="lane', week)) == 7
    assert "Today, 5 Jan" in week
    assert 'Sun 4 Jan</span><span class="sched">24 runs' in week
    assert len(re.findall(r'class="nowline"', week)) == 1


def test_job_names_are_escaped_inside_the_timelines_svg_and_notes() -> None:
    # Names made through cw.job are plain, but a store can hold anything another writer put there.
    store = MemoryStore()
    cw, _, _ = make(store=store)
    name = "<svg onload=alert(1)>\"&'"
    store.upsert_job(JobDefinition({"name": name, "schedule": "0 * * * *", "timezone": "UTC"}), T0 - HOUR)
    store.insert_run(
        Run(id="r1", job=name, status="failed", started_at=T0 - 10 * MIN, finished_at=T0 - 9 * MIN, duration_ms=MIN, error="x", output=None, metrics={}, trigger="run")
    )
    web = cw.routes(token=None, base_path="/cronwatch")
    from urllib.parse import quote

    for path in ["/cronwatch/", f"/cronwatch/jobs/{quote(name, safe='')}"]:
        html = send(web, "GET", path).text
        assert "<svg onload" not in html, path
        assert not re.search(r"<[a-z]+ onload", html, re.I)
        assert re.search(r"<title>&lt;svg onload=alert\(1\)&gt;&quot;&amp;&#39;[^<]*: failed at 09:20 UTC", html), path


def test_the_board_draws_at_most_thirty_lanes_and_says_so() -> None:
    cw, _, _ = make()
    for i in range(33):
        cw.run(f"job-{i:02d}", lambda ctx: None)
    html = send(cw.routes(token=None, base_path="/cronwatch"), "GET", "/cronwatch/").text
    assert len(re.findall(r'<li class="lane">', html)) == 30
    assert "Showing the first 30 of 33 jobs here" in html
    assert len(re.findall(r'<td class="job">', html)) == 33


def test_an_empty_store_shows_no_timeline_and_how_to_declare_a_job() -> None:
    cw, _, _ = make()
    html = send(cw.routes(token=None, base_path="/cronwatch"), "GET", "/cronwatch/").text
    assert "No jobs yet." in html
    assert 'class="timeline' not in html
    assert "<code>cw.job(&quot;name&quot;, schedule=&quot;0 2 * * *&quot;)</code>" in html


def test_a_job_due_more_often_than_can_be_drawn_shows_its_cadence_as_a_line() -> None:
    cw, _, _ = make()
    cw.job("minutely", schedule="* * * * *").run(lambda ctx: None)
    html = send(cw.routes(token=None, base_path="/cronwatch"), "GET", "/cronwatch/").text
    assert re.search(r'<line class="cadence"[^>]*><title>minutely: due \* \* \* \* \*, too often to mark each time</title>', html)
    assert not re.search(r'class="tick[^"]*" x1="[\d.]+" y1="6"', html)


# ------------------------------------------------------------ Python's servers


def test_the_base_path_defaults_to_the_mount_point() -> None:
    cw, _, _ = make()
    cw.run("x", lambda ctx: None)
    web = cw.routes(token="tok")
    res = send(web, "GET", "/ops/cron/jobs/x", BEARER, script_name="/ops/cron")
    assert res.status == 200
    assert '<link rel="manifest" href="/ops/cron/manifest.webmanifest">' in res.text
    sign_in = send(web, "GET", "/ops/cron/?token=tok", script_name="/ops/cron")
    assert sign_in.headers["location"] == "/ops/cron/"
    assert "; Path=/ops/cron;" in sign_in.headers["set-cookie"]
    root = send(web, "GET", "/?token=tok")
    assert "; Path=/;" in root.headers["set-cookie"], "mounted at the root"


def odd_names(*names: str) -> Any:
    """Routes over a store holding jobs named as cw.job would refuse, as another writer can."""
    store = MemoryStore()
    for name in names:
        store.upsert_job(JobDefinition({"name": name}), T0)
    cw, _, _ = make(store=store)
    return cw, cw.routes(token="tok", base_path="/cronwatch")


def test_a_decoded_path_is_encoded_again_when_the_server_passes_no_raw_target() -> None:
    _, web = odd_names("a b%c/é", "50% done")
    with_raw = send(web, "GET", "/cronwatch/api/jobs/a%20b%25c%2F%C3%A9", BEARER)
    assert with_raw.status == 200
    assert with_raw.json()["job"]["name"] == "a b%c/é"
    # Without the raw target a "/" in a name cannot be told from a separator.
    assert send(web, "GET", "/cronwatch/api/jobs/a%20b%25c%2F%C3%A9", BEARER, raw=False).status == 404
    assert send(web, "GET", "/cronwatch/api/jobs/50%25%20done", BEARER, raw=False).json()["job"]["name"] == "50% done"
    assert send(web, "GET", "/cronwatch/jobs/%zz", BEARER, raw=False).status == 404, "a bad escape reads as a literal % then"


def test_a_raw_target_that_does_not_match_the_path_is_not_used() -> None:
    cw, _, web = app()
    cw.run("x", lambda ctx: None)
    environ_path = "/cronwatch/jobs/x"
    res = web.handle(Request.from_wsgi({"REQUEST_METHOD": "GET", "PATH_INFO": environ_path, "RAW_URI": "/rewritten/elsewhere", "HTTP_AUTHORIZATION": "Bearer tok"}))
    assert res.status == 200


def test_the_asgi_app_answers_as_the_wsgi_app_does() -> None:
    store = MemoryStore()
    store.upsert_job(JobDefinition({"name": "a b"}), T0)
    cw, _, _ = make(store=store)
    web = cw.routes(token="tok")

    async def call(method: str, path: str, raw_path: bytes, headers: list[tuple[bytes, bytes]], body: bytes = b"") -> tuple[int, dict[str, str], bytes]:
        sent: list[dict[str, Any]] = []
        messages = [{"type": "http.request", "body": body, "more_body": False}]

        async def receive() -> dict[str, Any]:
            return messages.pop(0)

        async def emit(message: dict[str, Any]) -> None:
            sent.append(message)

        scope = {
            "type": "http",
            "method": method,
            "scheme": "http",
            "path": path,
            "raw_path": raw_path,
            "root_path": "/cronwatch",
            "query_string": b"runs=1",
            "headers": [(b"host", b"app.test"), *headers],
            "server": ("127.0.0.1", 8000),
        }
        await web.asgi(scope, receive, emit)
        start, content = sent
        return start["status"], {k.decode(): v.decode() for k, v in start["headers"]}, content["body"]

    status, headers, body = asyncio.run(call("GET", "/cronwatch/api/jobs/a b", b"/cronwatch/api/jobs/a%20b", [(b"authorization", b"Bearer tok")]))
    assert status == 200
    assert headers["content-type"] == "application/json; charset=utf-8"
    assert json.loads(body)["job"]["name"] == "a b"
    # A path without the root path in it (older servers), and cookies split over two headers.
    status, headers, body = asyncio.run(call("GET", "/", b"/", [(b"cookie", b"other=1"), (b"cookie", f"cronwatch_token={DIGEST}".encode())]))
    assert status == 200
    assert '<link rel="manifest" href="/cronwatch/manifest.webmanifest">' in body.decode()
    status, headers, body = asyncio.run(
        call("POST", "/cronwatch/jobs/a b/silence", b"/cronwatch/jobs/a%20b/silence", [(b"authorization", b"Bearer tok"), (b"content-type", b"application/x-www-form-urlencoded"), (b"origin", b"http://app.test")], b"for=2h")
    )
    assert (status, headers["location"]) == (303, "/cronwatch/")
    assert cw.job_summary("a b").silenced_until is not None
    status, headers, body = asyncio.run(call("HEAD", "/cronwatch/app.js", b"/cronwatch/app.js", []))
    assert (status, body) == (200, b"")


def test_the_asgi_app_completes_the_lifespan() -> None:
    web = Web(None, token=None)
    sent: list[str] = []
    messages = [{"type": "lifespan.startup"}, {"type": "lifespan.shutdown"}]

    async def receive() -> dict[str, Any]:
        return messages.pop(0)

    async def emit(message: dict[str, Any]) -> None:
        sent.append(message["type"])

    asyncio.run(web.asgi({"type": "lifespan"}, receive, emit))
    assert sent == ["lifespan.startup.complete", "lifespan.shutdown.complete"]


def test_a_web_without_a_client_uses_the_process_client(monkeypatch: pytest.MonkeyPatch) -> None:
    import cronwatch

    monkeypatch.setattr(cronwatch, "_client", None)
    cw = cronwatch.configure(alerts=[], cron_secret=None)
    try:
        cw.run("proc", lambda ctx: None)
        web = Web(token="tok")
        assert [j["name"] for j in send(web, "GET", "/api/jobs", BEARER).json()["jobs"]] == ["proc"]
    finally:
        cw.stop()


# ------------------------------------------------------------ request bodies


def test_an_asgi_body_over_the_limit_is_refused_before_anything_reads_it_whole() -> None:
    """An ASGI server hands the body over before the routes can ask for a
    token, so a body past MAX_BODY is answered 413 and the rest never read."""
    from cronwatch.web import MAX_BODY

    _, _, web = app()
    chunk = b"x" * (64 * 1024)
    chunks = MAX_BODY // len(chunk) + 50
    received = [0]
    sent: list[dict[str, Any]] = []

    async def receive() -> dict[str, Any]:
        received[0] += 1
        return {"type": "http.request", "body": chunk, "more_body": received[0] < chunks}

    async def emit(message: dict[str, Any]) -> None:
        sent.append(message)

    scope = {
        "type": "http",
        "method": "POST",
        "scheme": "http",
        "path": "/cronwatch/check",
        "raw_path": b"/cronwatch/check",
        "root_path": "",
        "query_string": b"",
        "headers": [(b"host", b"app.test")],
    }
    asyncio.run(web.asgi(scope, receive, emit))
    assert sent[0]["status"] == 413
    assert json.loads(sent[1]["body"]) == {"ok": False, "error": "Request body too large"}
    assert received[0] == MAX_BODY // len(chunk) + 1, "reading stops once the limit is passed"


def test_a_wsgi_body_over_the_limit_is_413_and_never_silences_the_job() -> None:
    from cronwatch.web import MAX_BODY

    cw, _, web = app()
    cw.run("big", lambda ctx: None)
    res = send(web, "POST", "/cronwatch/api/jobs/big/silence", {**JSON_BODY, "content-length": str(MAX_BODY + 1)}, b'{"for":"2h"}')
    assert res.status == 413
    assert cw.job_summary("big").silenced_until is None
    form = send(web, "POST", "/cronwatch/jobs/big/silence", {**BEARER, **FORM, "content-length": str(MAX_BODY + 1)}, b"for=2h")
    assert form.status == 413
    assert cw.job_summary("big").silenced_until is None


def test_a_negative_content_length_reads_no_body() -> None:
    import io

    class Endless(io.RawIOBase):
        def read(self, size: int | None = -1) -> bytes:
            if size is None or size < 0:
                raise AssertionError("read the whole stream")
            return b"x" * size

    request = Request.from_wsgi({"REQUEST_METHOD": "POST", "PATH_INFO": "/", "CONTENT_LENGTH": "-1", "wsgi.input": Endless()})
    assert request.read() == b""
