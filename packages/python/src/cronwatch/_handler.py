"""job.handler(): the SDK's fetch-style job handler, for a cron that calls a
URL (Vercel's crons, Cloud Scheduler, a crontab line running curl). Each
request carrying the cron secret runs the function as a recorded run and is
answered with how it went:

    nightly = cw.job("nightly-report", schedule="0 2 * * *", timezone="UTC")
    cron = nightly.handler(lambda ctx, request: build_report(ctx))

    # Django: path("api/cron/nightly", cron.django)
    # Flask: app.add_url_rule("/api/cron/nightly", view_func=cron.flask)
    # Starlette or FastAPI: app.add_route("/api/cron/nightly", cron.starlette)
    # a WSGI or ASGI server (Vercel's Python runtime): app = cron.wsgi, or app = cron.asgi
    # AWS Lambda behind API Gateway or a function URL: lambda_handler = cron.aws_lambda
    # anything else: response = cron(request), for any request with headers

The caller must send ``Authorization: Bearer <secret>``. The secret is the
handler's ``secret=``, else the client's cron_secret (which defaults to
$CRON_SECRET, what Vercel sends its cron requests with); "" or a string of
only whitespace counts as unset, and anything but a string or None raises
TypeError.
With no secret at all the handler answers 503 unless the environment is
development or test (see cronwatch._env), and reports it once to on_error as
"handler". ``secret=None`` lets anyone run the job.

The answer is JSON: ``{"ok", "job", "run", "status", "durationMs"}``, status
200 when the run was ok and 500 when it failed, with the error's first line
as "error" only for a caller who sent the secret. A function that returns a
response (any the run() rules read as one, see cronwatch._response) is
answered with that response instead, and a status of 400 or more fails the
run, as it does for run().

Calling the handler with a request answers in the request's own kind: a
Django HttpResponse for a Django request, a Werkzeug (Flask) Response for a
Werkzeug request, a Starlette Response for a Starlette request, and a
cronwatch.web.Response otherwise. An async function makes an async handler,
awaited the same way (``await cron(request)``), and its adapters are async
too. The function is called as ``fn(ctx, request)`` with the request it was
given: the framework's own, or a cronwatch.web.Request for .wsgi and .asgi.
"""

from __future__ import annotations

import asyncio
import base64
import http
import re
from collections.abc import Callable, Mapping
from typing import TYPE_CHECKING, Any

from . import _env, _js
from ._response import is_lambda_result, response_status

if TYPE_CHECKING:
    from ._client import Cronwatch, _Outcome
    from .types import JobDefinition
    from .web import Request as WebRequest
    from .web import Response as WebResponse

__all__ = ["AsyncHandler", "Handler"]

NO_SECRET = (
    "CRON_SECRET is not set, so this job will not run for an unauthenticated request. "
    "Set it, or pass secret=None to handler() to allow anyone."
)
NO_SECRET_REPORT = "handler() refused a request because no CRON_SECRET is set; pass secret=None to allow unauthenticated requests"


def make_handler(client: Cronwatch, definition: JobDefinition, fn: Callable[..., Any], secret: Any) -> Handler:
    from ._client import _UNSET, is_async_callable

    if not callable(fn):
        raise TypeError(f"job {definition.name}: handler() takes a function of (ctx, request)")
    # A blank secret falls back to the client's; one that is not a string raises.
    given = _env.secret_option(secret, "handler: secret", _UNSET)
    own = None if given is None else ("" if given is _UNSET else str(given))
    kind = AsyncHandler if is_async_callable(fn) else Handler
    return kind(client, definition, fn, own)


def _json(body: Mapping[str, Any], status: int) -> WebResponse:
    from .web import Response

    return Response(
        status,
        {"content-type": "application/json; charset=utf-8", "cache-control": "no-store"},
        _js.dumps(dict(body)).encode("utf-8", "surrogatepass"),
    )


def authorization(request: Any) -> str:
    """The Authorization header of a request of any kind: a cronwatch.web.Request,
    a framework's request (its headers read without regard to case), a WSGI
    environ, or an event carrying a "headers" mapping (a serverless platform's)."""
    from .web import Request

    if request is None:
        return ""
    if isinstance(request, Request):
        return request.header("authorization") or ""
    # A framework's request may be a Mapping of its own (Starlette's is one of its scope), so its headers come first.
    headers = None if isinstance(request, dict) else getattr(request, "headers", None)
    if headers is None:
        if not isinstance(request, Mapping):
            return ""
        if "REQUEST_METHOD" in request or "wsgi.version" in request:
            return _text(request.get("HTTP_AUTHORIZATION"))
        inner = request.get("headers")
        found = _lookup(inner if isinstance(inner, Mapping) else request)
        # API Gateway's REST API event also lists every header's values in multiValueHeaders.
        multi = request.get("multiValueHeaders")
        return found or (_lookup(multi) if isinstance(multi, Mapping) else "")
    if isinstance(headers, Mapping):
        return _lookup(headers)
    get = getattr(headers, "get", None)
    return _text(get("authorization")) if callable(get) else ""


def _lookup(headers: Mapping[Any, Any]) -> str:
    for name, value in headers.items():
        key = name.decode("latin-1") if isinstance(name, bytes) else str(name)
        if key.lower() == "authorization":
            return _text(value)
    return ""


def _text(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, bytes):
        return value.decode("latin-1")
    if isinstance(value, (list, tuple)):
        return _text(value[0]) if value else ""
    return str(value)


def _family(request: Any) -> str:
    """Which framework a request comes from, by its class's module."""
    for klass in type(request).__mro__:
        module = klass.__module__.split(".", 1)[0]
        if module in ("django", "werkzeug", "starlette"):
            return module
    return "web"


def _is_response(value: Any) -> bool:
    return response_status(value) is not None


class Handler:
    """A job's request handler. See the module's docstring."""

    #: Django's CSRF middleware leaves it alone: the caller proves itself with the bearer secret, not a cookie.
    csrf_exempt = True

    def __init__(self, client: Cronwatch, definition: JobDefinition, fn: Callable[..., Any], own: str | None) -> None:
        self._client = client
        self._definition = definition
        self._fn = fn
        self.secret: str | None = None if own is None else (own or client.cron_secret)
        self._opted_out = own is None or (not own and client._secret_opt_out)

    @property
    def job(self) -> str:
        return str(self._definition.name)

    # ------------------------------------------------------------ the core

    def _refusal(self, request: Any) -> WebResponse | None:
        """The answer for a request that may not run the job, or None when it may."""
        if not self.secret and not self._opted_out and not _env.is_development():
            self._warn_no_secret()
            return _json({"ok": False, "error": NO_SECRET}, 503)
        if self.secret:
            from .web import _constant_time_equal

            if not _constant_time_equal(authorization(request), f"Bearer {self.secret}"):
                return _json({"ok": False, "error": "Unauthorized"}, 401)
        return None

    def _warn_no_secret(self) -> None:
        client = self._client
        if client._warned_no_secret:
            return
        client._warned_no_secret = True
        client._report(RuntimeError(NO_SECRET_REPORT), "handler")

    def _answer(self, outcome: _Outcome) -> Any:
        if _is_response(outcome.result):
            return outcome.result
        run = outcome.run
        body: dict[str, Any] = {
            "ok": run.status == "ok",
            "job": self._definition.name,
            "run": run.id,
            "status": str(run.status),
            "durationMs": run.duration_ms,
        }
        # Error text only goes to a caller who proved they hold the secret.
        if self.secret and run.error:
            body["error"] = run.error.split("\n")[0]
        return _json(body, 200 if run.status == "ok" else 500)

    def respond(self, request: Any) -> Any:
        """Runs the job for a request and returns the answer: a cronwatch.web.Response,
        or the response the function returned."""
        refused = self._refusal(request)
        if refused is not None:
            return refused
        fn = self._fn
        outcome = self._client._execute_outcome(self._definition, "handler", lambda ctx: fn(ctx, request))
        return self._answer(outcome)

    # ------------------------------------------------------------ servers

    def __call__(self, request: Any) -> Any:
        """Answers a request of any kind in its own kind (see the module's docstring)."""
        return _convert(self.respond(request), _family(request))

    @property
    def django(self) -> Callable[..., Any]:
        """A Django view, exempt from CSRF (the caller sends the secret instead)."""

        def view(request: Any, *args: Any, **kwargs: Any) -> Any:
            return _convert(self.respond(request), "django")

        view.csrf_exempt = True  # type: ignore[attr-defined]
        return _named(view, self)

    @property
    def flask(self) -> Callable[..., Any]:
        """A Flask view function (reads flask.request)."""

        def view(*args: Any, **kwargs: Any) -> Any:
            from flask import request as proxy

            return _convert(self.respond(_flask_request(proxy)), "werkzeug")

        return _named(view, self)

    @property
    def starlette(self) -> Callable[..., Any]:
        """A Starlette (or FastAPI) endpoint taking the request: a plain one,
        which Starlette runs in its thread pool, for a plain function."""

        def endpoint(request: Any) -> Any:
            return _convert(self.respond(request), "starlette")

        return _named(endpoint, self)

    def wsgi(self, environ: Mapping[str, Any], start_response: Callable[..., Any]) -> list[bytes]:
        """The handler as a WSGI app. The function gets a cronwatch.web.Request."""
        from .web import Request

        request = Request.from_wsgi(environ)
        return _wsgi_answer(self.respond(request), environ, start_response)

    async def asgi(self, scope: Mapping[str, Any], receive: Callable[..., Any], send: Callable[..., Any]) -> None:
        """The handler as an ASGI app. A plain function runs in a worker thread.
        The function gets a cronwatch.web.Request."""
        request = await _asgi_request(scope, receive, send)
        if request is None:
            return
        answer = await asyncio.to_thread(self.respond, request)
        await _asgi_answer(answer, scope, receive, send)

    def aws_lambda(self, event: Any, context: Any = None) -> dict[str, Any]:
        """The handler as an AWS Lambda function (``lambda_handler = cron.aws_lambda``)
        behind API Gateway (a REST or an HTTP API) or a function URL: the bearer
        is read from the event's headers (or a REST API's multiValueHeaders),
        and the answer is the proxy result, ``{"statusCode", "headers", "body",
        "isBase64Encoded"}``. The function gets the event; one that returns a
        proxy result dict of its own is answered with it."""
        return _lambda_answer(self.respond(event))

    def __repr__(self) -> str:
        return f"{type(self).__name__}({self._definition.name!r})"


class AsyncHandler(Handler):
    """The handler of an async function: awaited, and its adapters are async.
    The store is used from a worker thread, so the event loop is not held up."""

    async def respond(self, request: Any) -> Any:
        refused = self._refusal(request)
        if refused is not None:
            return refused
        fn = self._fn
        outcome = await self._client._aexecute_outcome(self._definition, "handler", lambda ctx: fn(ctx, request))
        return self._answer(outcome)

    async def __call__(self, request: Any) -> Any:
        return _convert(await self.respond(request), _family(request))

    @property
    def django(self) -> Callable[..., Any]:
        async def view(request: Any, *args: Any, **kwargs: Any) -> Any:
            return _convert(await self.respond(request), "django")

        view.csrf_exempt = True  # type: ignore[attr-defined]
        return _named(view, self)

    @property
    def flask(self) -> Callable[..., Any]:
        """An async Flask view (Flask runs it with its async extra, flask[async])."""

        async def view(*args: Any, **kwargs: Any) -> Any:
            from flask import request as proxy

            return _convert(await self.respond(_flask_request(proxy)), "werkzeug")

        return _named(view, self)

    @property
    def starlette(self) -> Callable[..., Any]:
        async def endpoint(request: Any) -> Any:
            return _convert(await self.respond(request), "starlette")

        return _named(endpoint, self)

    def wsgi(self, environ: Mapping[str, Any], start_response: Callable[..., Any]) -> list[bytes]:
        """The handler as a WSGI app: the async function runs to completion on an event loop of its own."""
        from .web import Request

        request = Request.from_wsgi(environ)
        return _wsgi_answer(asyncio.run(self.respond(request)), environ, start_response)

    async def asgi(self, scope: Mapping[str, Any], receive: Callable[..., Any], send: Callable[..., Any]) -> None:
        request = await _asgi_request(scope, receive, send)
        if request is None:
            return
        await _asgi_answer(await self.respond(request), scope, receive, send)

    def aws_lambda(self, event: Any, context: Any = None) -> dict[str, Any]:
        """The handler as an AWS Lambda function: the async function runs to completion on an event loop of its own."""
        return _lambda_answer(asyncio.run(self.respond(event)))


def _flask_request(proxy: Any) -> Any:
    """The request behind flask.request (a proxy that only means something in this thread)."""
    return proxy._get_current_object()


def _named(view: Callable[..., Any], handler: Handler) -> Callable[..., Any]:
    """A view named after the job, so a framework that names routes by their function (Flask) tells two apart."""
    view.__name__ = "cronwatch_" + re.sub(r"[^A-Za-z0-9_]", "_", handler.job)
    view.__qualname__ = view.__name__
    view.__doc__ = f"Runs the job {handler.job} for a request carrying the cron secret."
    return view


# ---------------------------------------------------------------- answers


def _parts(response: Any) -> tuple[int, list[tuple[str, str]], bytes]:
    """Status, headers, and body of a response of any of the kinds handled here."""
    from .web import Response

    if isinstance(response, Response):
        return response.status, response.wsgi_headers(), response.body
    if is_lambda_result(response):
        text = response.get("body") or ""
        data = base64.b64decode(text) if response.get("isBase64Encoded") else str(text).encode("utf-8")
        headers = [(str(k), str(v)) for k, v in (response.get("headers") or {}).items()]
        return int(response["statusCode"]), [*headers, ("content-length", str(len(data)))], data
    status = int(response.status_code)
    if hasattr(response, "items") and hasattr(response, "content"):  # Django
        return status, [(str(k), str(v)) for k, v in response.items()], bytes(response.content)
    if hasattr(response, "get_data"):  # Werkzeug
        return status, [(str(k), str(v)) for k, v in response.headers.items()], bytes(response.get_data())
    if hasattr(response, "raw_headers"):  # Starlette
        return status, [(k.decode("latin-1"), v.decode("latin-1")) for k, v in response.raw_headers], bytes(getattr(response, "body", b""))
    raise TypeError(f"{type(response).__name__} is a response this server cannot send; return a cronwatch.web.Response, or use the adapter for your framework")


def _convert(answer: Any, family: str) -> Any:
    """Our own answers in the framework's kind; a response the function returned as it is."""
    from .web import Response

    if not isinstance(answer, Response) or family == "web":
        return answer
    if family == "django":
        from django.http import HttpResponse

        out = HttpResponse(answer.body, status=answer.status)
        del out["Content-Type"]
        for name, value in answer.headers.items():
            out[name] = value
        return out
    if family == "werkzeug":
        from werkzeug.wrappers import Response as WerkzeugResponse

        return WerkzeugResponse(answer.body, status=answer.status, headers=list(answer.headers.items()))
    from starlette.responses import Response as StarletteResponse

    return StarletteResponse(answer.body, status_code=answer.status, headers=dict(answer.headers))


def _lambda_answer(answer: Any) -> dict[str, Any]:
    """An answer as a Lambda proxy result. The body is text when it is UTF-8, else base64."""
    if is_lambda_result(answer):
        return dict(answer)
    status, headers, data = _parts(answer)
    out: dict[str, str] = {}
    for name, value in headers:
        if name.lower() == "content-length":
            continue  # API Gateway and function URLs set their own.
        out[name] = f"{out[name]}, {value}" if name in out else value
    try:
        return {"statusCode": status, "headers": out, "body": data.decode("utf-8"), "isBase64Encoded": False}
    except UnicodeDecodeError:
        return {"statusCode": status, "headers": out, "body": base64.b64encode(data).decode("ascii"), "isBase64Encoded": True}


def _status_line(status: int) -> str:
    try:
        return f"{status} {http.HTTPStatus(status).phrase}"
    except ValueError:
        return f"{status} Unknown"


def _wsgi_answer(answer: Any, environ: Mapping[str, Any], start_response: Callable[..., Any]) -> list[bytes]:
    if callable(answer) and hasattr(answer, "get_data"):
        # A Werkzeug response is a WSGI app of its own.
        return list(answer(environ, start_response))
    status, headers, body = _parts(answer)
    start_response(_status_line(status), headers)
    return [] if str(environ.get("REQUEST_METHOD", "")).upper() == "HEAD" else [body]


async def _asgi_request(scope: Mapping[str, Any], receive: Callable[..., Any], send: Callable[..., Any]) -> WebRequest | None:
    """The request of an HTTP scope, or None once the scope is dealt with
    (lifespan, websocket, a client gone, a body over web._MAX_BODY answered 413)."""
    from .web import BodyTooLarge, Request, _read_asgi_body, _too_large

    kind = scope.get("type")
    if kind == "lifespan":
        while True:
            message = await receive()
            if message["type"] == "lifespan.startup":
                await send({"type": "lifespan.startup.complete"})
            elif message["type"] == "lifespan.shutdown":
                await send({"type": "lifespan.shutdown.complete"})
                return None
    if kind != "http":
        if kind == "websocket":
            await send({"type": "websocket.close", "code": 1000})
        return None
    body = await _read_asgi_body(receive)
    if body is None:
        return None
    if isinstance(body, BodyTooLarge):
        await _asgi_answer(_too_large(), scope, receive, send)
        return None
    return Request.from_asgi(scope, body)


async def _asgi_answer(answer: Any, scope: Mapping[str, Any], receive: Callable[..., Any], send: Callable[..., Any]) -> None:
    if hasattr(answer, "raw_headers") and callable(answer):
        # A Starlette response is an ASGI app of its own.
        await answer(scope, receive, send)
        return
    status, headers, body = _parts(answer)
    encoded = [(k.encode("latin-1"), v.encode("latin-1")) for k, v in headers]
    await send({"type": "http.response.start", "status": status, "headers": encoded})
    await send({"type": "http.response.body", "body": b"" if str(scope.get("method", "")).upper() == "HEAD" else body})
