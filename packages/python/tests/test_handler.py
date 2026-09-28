"""job.handler(), the SDK's fetch-style job handler (client.test.ts and
client-hardening.test.ts's handler tests), its adapters for WSGI, ASGI, Flask
and Starlette (Django's is in test_django.py), and the rule it brings to every
run: a returned HTTP response of 400 or more is a failure."""

from __future__ import annotations

import asyncio
import http.client
import io
import json
from collections.abc import Iterator
from typing import Any

import pytest

import cronwatch
from cronwatch.web import Request, Response

from helpers import Errors, make, send


@pytest.fixture(autouse=True)
def no_environment(monkeypatch: pytest.MonkeyPatch) -> Iterator[None]:
    for name in ("CRONWATCH_ENV", "APP_ENV", "ENVIRONMENT", "CRON_SECRET"):
        monkeypatch.delenv(name, raising=False)
    yield


def get(path: str = "/api/cron/hourly", **headers: str) -> Request:
    return Request("GET", path, "", {k.replace("_", "-"): v for k, v in headers.items()})


def body(response: Response) -> Any:
    return json.loads(response.body)


def test_handler_checks_the_bearer_secret_and_reports_the_run() -> None:
    cw, _, _ = make(cron_secret="s3cret")

    def work(ctx: cronwatch.JobContext, request: Request) -> dict[str, bool]:
        ctx.log(request.path)
        if request.header("x-fail"):
            raise RuntimeError("nope")
        return {"fine": True}

    handler = cw.job("hourly", schedule="@hourly").handler(work)
    no_auth = handler(get())
    assert no_auth.status == 401
    assert body(no_auth) == {"ok": False, "error": "Unauthorized"}
    ok = handler(get(authorization="Bearer s3cret"))
    assert ok.status == 200
    assert ok.headers == {"content-type": "application/json; charset=utf-8", "cache-control": "no-store"}
    run = cw.runs("hourly")[0]
    assert ok.body == f'{{"ok":true,"job":"hourly","run":"{run.id}","status":"ok","durationMs":0}}'.encode()
    assert run.trigger == "handler"
    failed = handler(get(authorization="Bearer s3cret", x_fail="1"))
    assert failed.status == 500
    assert body(failed)["error"] == "RuntimeError: nope", "the first line only"
    runs = cw.runs("hourly")
    assert len(runs) == 2
    assert runs[1].output == "/api/cron/hourly"
    assert handler(get(authorization="Bearer s3cret ")).status == 401, "compared exactly"


def test_a_handler_returning_a_response_passes_it_through_and_4xx_or_5xx_count_as_failure() -> None:
    cw, _, alerts = make()
    handler = cw.job("h").handler(lambda ctx, request: Response(503, {"content-type": "text/plain"}, b"bad"))
    res = handler(get())
    assert (res.status, res.body) == (503, b"bad")
    assert cw.runs("h")[0].error == "HTTP 503"
    assert alerts.types() == ["failed"]
    fine = cw.job("fine").handler(lambda ctx, request: Response(204, {}, b""))
    assert fine(get()).status == 204
    assert cw.runs("fine")[0].status == "ok"


def test_handler_fails_closed_without_a_secret_outside_development(monkeypatch: pytest.MonkeyPatch) -> None:
    errors = Errors()
    cw, _, _ = make(cron_secret="", on_error=errors)
    ran: list[int] = []
    handler = cw.job("closed").handler(lambda ctx, request: ran.append(1))
    assert cw.cron_secret is None, "an empty secret is no secret"
    res = handler(get())
    assert res.status == 503
    assert "CRON_SECRET" in body(res)["error"]
    assert body(res)["error"].endswith("pass secret=None to handler() to allow anyone.")
    handler(get())
    assert ran == []
    assert errors.wheres == ["handler"], "reported once"

    # Opting out with None runs the job, and does not show the error to the caller.
    def fail(ctx: object, request: object) -> None:
        raise RuntimeError("private detail")

    opened = cw.job("open").handler(fail, secret=None)
    failed = opened(get())
    assert failed.status == 500
    assert "error" not in body(failed)

    monkeypatch.setenv("CRONWATCH_ENV", "development")
    assert handler(get()).status == 200
    assert ran == [1]


def test_the_client_secret_is_used_unless_the_handler_has_its_own_and_none_opts_out_for_every_handler(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("CRON_SECRET", "from-env")
    cw = cronwatch.Cronwatch(alerts=[])
    job = cw.job("j")
    assert job.handler(lambda ctx, r: None)(get(authorization="Bearer from-env")).status == 200
    own = job.handler(lambda ctx, r: None, secret="mine")
    assert own(get(authorization="Bearer from-env")).status == 401
    assert own(get(authorization="Bearer mine")).status == 200
    opted = cronwatch.Cronwatch(alerts=[], cron_secret=None)
    assert opted.job("j").handler(lambda ctx, r: None)(get()).status == 200


def test_an_interrupt_is_recorded_and_raised_rather_than_answered() -> None:
    cw, _, _ = make()

    def stop(ctx: object, request: object) -> None:
        raise KeyboardInterrupt

    with pytest.raises(KeyboardInterrupt):
        cw.job("k").handler(stop)(get())
    assert cw.runs("k")[0].error == "Interrupted: KeyboardInterrupt" or cw.runs("k")[0].error.startswith("Interrupted: KeyboardInterrupt\n")


def test_the_authorization_header_is_read_from_any_kind_of_request() -> None:
    from cronwatch.handler import authorization

    class Headers:
        def get(self, name: str) -> str | None:
            return "Bearer a" if name == "authorization" else None

    class Framework:
        headers = Headers()

    class Plain:
        headers = {"Authorization": "Bearer b"}

    assert authorization(get(authorization="Bearer c")) == "Bearer c"
    assert authorization(Framework()) == "Bearer a"
    assert authorization(Plain()) == "Bearer b"
    assert authorization({"REQUEST_METHOD": "GET", "HTTP_AUTHORIZATION": "Bearer d"}) == "Bearer d"
    assert authorization({"headers": {"AUTHORIZATION": "Bearer e"}, "body": ""}) == "Bearer e", "a serverless event"
    assert authorization({"authorization": [b"Bearer f"]}) == "Bearer f"
    assert authorization(None) == ""
    assert authorization(object()) == ""


# ---------------------------------------------------------------- responses as outcomes


class DjangoLike:
    def __init__(self, status: int) -> None:
        self.status_code = status
        self.reason_phrase = "Service Unavailable"


class RequestsLike:
    status_code = 404
    reason = "Not Found"


class StarletteLike:
    status_code = 500


def test_any_kind_of_http_response_of_400_or_more_fails_a_run_as_a_fetch_response_does() -> None:
    cw, _, _ = make()
    job = cw.job("r")
    job.run(lambda ctx: DjangoLike(503))
    assert cw.runs("r")[0].error == "HTTP 503 Service Unavailable"
    job.run(lambda ctx: RequestsLike())
    assert cw.runs("r")[0].error == "HTTP 404 Not Found"
    job.run(lambda ctx: StarletteLike())
    assert cw.runs("r")[0].error == "HTTP 500"
    job.run(lambda ctx: DjangoLike(302))
    assert cw.runs("r")[0].status == "ok"

    from werkzeug.wrappers import Response as WerkzeugResponse

    job.run(lambda ctx: WerkzeugResponse("gone", status=410))
    assert cw.runs("r")[0].error == "HTTP 410 GONE"

    class Socket:
        def makefile(self, mode: str) -> io.BytesIO:
            return io.BytesIO(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")

    raw = http.client.HTTPResponse(Socket())  # type: ignore[arg-type]
    raw.begin()
    job.run(lambda ctx: raw)
    raw.close()
    assert cw.runs("r")[0].error == "HTTP 502 Bad Gateway"

    class NotAResponse:
        status_code = "500"

    job.run(lambda ctx: NotAResponse())
    assert cw.runs("r")[0].status == "ok", "a status_code that is not a whole number is not a response"


def test_a_handle_finished_with_a_failing_response_is_failed() -> None:
    cw, _, _ = make()
    handle = cw.job("http").start()
    run = handle.finish(result=Response(502, {}, b"no"))
    assert run is not None
    assert run.error == "HTTP 502"


# ---------------------------------------------------------------- servers


def test_the_wsgi_adapter_answers_a_server_and_hands_the_function_a_request() -> None:
    cw, _, _ = make(cron_secret="s3cret")
    seen: list[Request] = []
    cron = cw.job("w").handler(lambda ctx, request: seen.append(request))
    res = send(cron.wsgi, "GET", "/api/cron/w", headers={"authorization": "Bearer s3cret"})
    assert res.status == 200
    assert res.json()["ok"] is True
    assert res.headers["content-length"] == str(len(res.body))
    assert seen[0].path == "/api/cron/w"
    assert send(cron.wsgi, "GET", "/api/cron/w").status == 401
    head = send(cron.wsgi, "HEAD", "/api/cron/w", headers={"authorization": "Bearer s3cret"})
    assert head.body == b""


def asgi_call(app: Any, path: str, headers: dict[str, str] | None = None) -> tuple[int, dict[str, str], bytes]:
    sent: list[dict[str, Any]] = []

    async def receive() -> dict[str, Any]:
        return {"type": "http.request", "body": b"", "more_body": False}

    async def emit(message: dict[str, Any]) -> None:
        sent.append(message)

    scope = {
        "type": "http",
        "method": "GET",
        "path": path,
        "raw_path": path.encode(),
        "query_string": b"",
        "root_path": "",
        "scheme": "http",
        "server": ("app.test", 80),
        "headers": [(k.encode(), v.encode()) for k, v in (headers or {}).items()],
    }
    asyncio.run(app(scope, receive, emit))
    start = sent[0]
    return start["status"], {k.decode(): v.decode() for k, v in start["headers"]}, b"".join(m.get("body", b"") for m in sent[1:])


def test_the_asgi_adapter_for_a_plain_and_an_async_function() -> None:
    cw, _, _ = make(cron_secret="s3cret")

    async def work(ctx: cronwatch.JobContext, request: Request) -> str:
        await asyncio.sleep(0)
        ctx.log("async", request.path)
        return "done"

    status, headers, data = asgi_call(cw.job("a").handler(work).asgi, "/cron/a", {"authorization": "Bearer s3cret"})
    assert status == 200
    assert json.loads(data)["status"] == "ok"
    assert headers["content-type"] == "application/json; charset=utf-8"
    assert cw.runs("a")[0].output == "async /cron/a"
    status, _, _ = asgi_call(cw.job("p").handler(lambda ctx, r: None).asgi, "/cron/p")
    assert status == 401


def test_flask_views_answer_with_werkzeug_responses() -> None:
    flask = pytest.importorskip("flask")
    cw, _, _ = make(cron_secret="s3cret")
    app = flask.Flask(__name__)
    first = cw.job("nightly-report").handler(lambda ctx, request: ctx.log(request.path))
    second = cw.job("other").handler(lambda ctx, request: Response(418, {"content-type": "text/plain"}, b"teapot"))
    app.add_url_rule("/cron/nightly", view_func=first.flask)
    app.add_url_rule("/cron/other", view_func=second.flask)
    client = app.test_client()
    ok = client.get("/cron/nightly", headers={"authorization": "Bearer s3cret"})
    assert ok.status_code == 200
    assert ok.json["job"] == "nightly-report"
    assert cw.runs("nightly-report")[0].output == "/cron/nightly"
    assert client.get("/cron/nightly").status_code == 401
    tea = client.get("/cron/other", headers={"authorization": "Bearer s3cret"})
    assert (tea.status_code, tea.data) == (418, b"teapot")
    assert first.flask.__name__ == "cronwatch_nightly_report"


def test_starlette_routes_take_its_endpoint_plain_or_async() -> None:
    starlette = pytest.importorskip("starlette")
    from starlette.applications import Starlette
    from starlette.requests import Request as StarletteRequest
    from starlette.responses import Response as StarletteResponse
    from starlette.routing import Route

    assert starlette
    cw, _, _ = make(cron_secret="s3cret")

    def plain(ctx: cronwatch.JobContext, request: StarletteRequest) -> None:
        ctx.log(request.url.path)

    async def asynchronous(ctx: cronwatch.JobContext, request: StarletteRequest) -> StarletteResponse:
        return StarletteResponse("custom", status_code=202)

    app = Starlette(routes=[Route("/cron/plain", cw.job("plain").handler(plain).starlette), Route("/cron/async", cw.job("async").handler(asynchronous).starlette)])
    status, headers, data = asgi_call(app, "/cron/plain", {"authorization": "Bearer s3cret", "host": "app.test"})
    assert status == 200
    assert json.loads(data)["job"] == "plain"
    assert cw.runs("plain")[0].output == "/cron/plain"
    status, _, data = asgi_call(app, "/cron/async", {"authorization": "Bearer s3cret", "host": "app.test"})
    assert (status, data) == (202, b"custom")
    assert asgi_call(app, "/cron/async", {"host": "app.test"})[0] == 401


def test_an_async_handler_called_directly_is_awaited() -> None:
    cw, _, _ = make()

    async def work(ctx: object, request: object) -> str:
        return "ok"

    handler = cw.job("d").handler(work)
    response = asyncio.run(handler(get()))
    assert response.status == 200
    assert cw.runs("d")[0].output == "ok"
    from cronwatch.handler import AsyncHandler

    assert isinstance(handler, AsyncHandler)
    with pytest.raises(TypeError, match="handler"):
        cw.job("d").handler("not a function")  # type: ignore[arg-type]


def test_a_werkzeug_request_gets_a_werkzeug_response() -> None:
    from werkzeug.test import EnvironBuilder
    from werkzeug.wrappers import Request as WerkzeugRequest
    from werkzeug.wrappers import Response as WerkzeugResponse

    cw, _, _ = make(cron_secret="k")
    request = WerkzeugRequest(EnvironBuilder(path="/x", headers={"Authorization": "Bearer k"}).get_environ())
    answer = cw.job("wz").handler(lambda ctx, r: None)(request)
    assert isinstance(answer, WerkzeugResponse)
    assert answer.status_code == 200
    assert json.loads(answer.get_data())["ok"] is True
