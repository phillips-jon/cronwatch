"""The dashboard and the small JSON API: the SDK's routes (routes/index.ts)
with the same URLs, JSON, auth, CSRF rules, headers and pages, byte for byte,
so @cronwatch/mcp works against a Python app as it does against a Node one.

One core takes a Request and returns a Response (Web.handle). A Web is a WSGI
app, and Web.asgi is the same routes as an ASGI app:

    web = cw.routes(token=os.environ["CRONWATCH_TOKEN"])

    # Flask, or any WSGI app: mount it under /cronwatch
    from werkzeug.middleware.dispatcher import DispatcherMiddleware
    app.wsgi_app = DispatcherMiddleware(app.wsgi_app, {"/cronwatch": web})

    # FastAPI or Starlette
    app.mount("/cronwatch", web.asgi)

    # Django: path("cronwatch/", include("cronwatch.django.urls")) (see cronwatch.django)

token:       required to reach anything. Send it as `Authorization: Bearer <token>`, or
             open the dashboard once with `?token=<token>` and a cookie is set. Defaults to
             $CRONWATCH_TOKEN; "" counts as unset. With no token while the environment is
             development or test (cronwatch._env), the routes make a random one and print a
             sign-in link to stdout on their first request; with no token otherwise they
             answer 503. Pass token=None to opt out and serve them open everywhere, for
             example behind your own auth. /api/check also accepts the client's cron_secret
             as a bearer, for a platform cron.
base_path:   where the routes are mounted, so links resolve. Defaults to the mount point
             the server passes (SCRIPT_NAME, or ASGI's root_path).
origin:      the public origin the dashboard is served from, such as
             "https://app.example.com", for an app behind a proxy whose requests carry an
             internal host or scheme. Used in place of the request's origin for the
             cross-site check on writes, the sign-in cookie's Secure flag, the Referer the
             redirect back after a form follows, and the development sign-in line. Read as
             `new URL(value).origin` reads it; anything that is not an absolute http or https
             URL raises ValueError here. Takes precedence over trust_proxy.
trust_proxy: take the public origin from X-Forwarded-Proto and X-Forwarded-Host (the first
             value of each, falling back to the request's scheme or host for whichever is
             missing) when a request carries either. Only for an app whose proxy sets or
             overwrites both headers: a client can send them too. Default False.
"""

from __future__ import annotations

import asyncio
import base64
import hashlib
import hmac
import http
import math
import os
import re
import secrets
import sys
import threading
import warnings
from collections.abc import Callable, Mapping
from dataclasses import dataclass, field
from email.parser import BytesParser
from email.policy import HTTP
from typing import Any
from urllib.parse import quote, quote_plus, unquote_to_bytes, urlsplit

from .. import _env, _js
from .._deprecated import names as _deprecated_names
from .._duration import parse_duration
from . import _html, _origin, _pwa
from . import _timeline as timeline

__all__ = ["BodyTooLarge", "Request", "Response", "Web"]


class _Unset:
    def __repr__(self) -> str:
        return "UNSET"


#: Tells "token not given" (read CRONWATCH_TOKEN) from "token=None" (open on purpose).
_UNSET: Any = _Unset()

_COOKIE = "cronwatch_token"
#: What GET <base>/api says is serving it: the package, as PyPI names it, and the language.
_LIBRARY = "cronwatch-sdk"
_LANGUAGE = "python"
#: The dashboard JSON API's version, which GET <base>/api answers. It goes up
#: only for a change that is not additive, and such a change waits for a major release.
_API_VERSION = 1
_DEFAULT_RUNS = 20
_MAX_RUNS = 500
#: Runs per job the board reads in one go: the table's sparkline, and most jobs' lanes.
_BOARD_PAGE_RUNS = 20
_COOKIE_MAX_AGE = 60 * 60 * 24 * 30
#: The most of a request body read into memory. The routes' forms and JSON are
#: a few bytes, and an ASGI server hands the body over before the routes can
#: ask for a token, so without a limit anyone could make the process hold any size.
_MAX_BODY = 1024 * 1024

# 'self' only for what the app shell needs: app.js (which registers the
# service worker and nothing else), the manifest, the worker and the icons.
# No inline script, and the pages work without any.
_CSP = (
    "default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; img-src 'self' data:; "
    "manifest-src 'self'; worker-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'"
)
#: For the SVG icons, should one be opened on its own.
_ASSET_CSP = "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'"
# same-origin rather than no-referrer: under no-referrer browsers send
# `Origin: null` on form posts, which the CSRF check would refuse, and the
# forms redirect back to the page named by the same-origin Referer.
_SECURITY_HEADERS = {"x-content-type-options": "nosniff", "referrer-policy": "same-origin", "x-robots-tag": "noindex"}

_LOCKED = (
    "Set CRONWATCH_TOKEN (or pass token= to cw.routes(), or TOKEN in Django's CRONWATCH setting), "
    "or pass token=None to serve them open behind your own auth."
)

_BEARER = re.compile(f"^Bearer[{_js.WHITESPACE}]+", re.IGNORECASE)
_BAD_ESCAPE = re.compile(r"%(?![0-9A-Fa-f]{2})")
_WHOLE = re.compile(r"[0-9]+(?:\.[0-9]+)?\Z")
_DECIMAL = re.compile(r"[+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?\Z")
_RADIX = re.compile(r"0([xXoObB])([0-9a-fA-F]+)\Z")
# What a browser leaves as it is in a path; everything else is percent-encoded.
_PATH_SAFE = "/!$&'()*+,;=:@-._~[]|^{}`"


class BodyTooLarge(Exception):
    """A request body over MAX_BODY bytes: answered 413, never read into memory."""

    def __init__(self) -> None:
        super().__init__(f"the request body is larger than {_MAX_BODY} bytes")


@dataclass
class Request:
    """What the routes read of a request, in the shape of a fetch Request.

    path:    the path as the browser sent it, still percent-encoded, mount point included.
    query:   the query string, without the "?", as sent.
    headers: lowercase names; the values as the server read them (bytes as latin-1).
    body:    the body's bytes, or a function that reads them (called at most once).
    origin:  the origin of the request's own URL (scheme://host[:port]).
    mount:   where the server mounted the app (SCRIPT_NAME, root_path), the default base path.
    form:    fields a framework already parsed from the body, used when the body is gone.
    """

    method: str
    path: str
    query: str = ""
    headers: dict[str, str] = field(default_factory=dict)
    body: bytes | Callable[[], bytes] = b""
    origin: str = "http://localhost"
    mount: str = ""
    form: Mapping[str, Any] | None = None

    def header(self, name: str) -> str | None:
        return self.headers.get(name)

    def read(self) -> bytes:
        if callable(self.body):
            self.body = self.body()
        return self.body

    def params(self) -> list[tuple[str, str]]:
        """The query's pairs, as URLSearchParams reads them."""
        return _parse_query(self.query)

    def param(self, name: str) -> str | None:
        """URLSearchParams#get: the first value, or None."""
        for key, value in self.params():
            if key == name:
                return value
        return None

    @classmethod
    def from_wsgi(cls, environ: Mapping[str, Any]) -> Request:
        """A WSGI environ, read as the SDK reads a fetch Request."""
        headers: dict[str, str] = {}
        for key, value in environ.items():
            if key.startswith("HTTP_"):
                headers[key[5:].replace("_", "-").lower()] = value
        if environ.get("CONTENT_TYPE"):
            headers["content-type"] = environ["CONTENT_TYPE"]
        if environ.get("CONTENT_LENGTH"):
            headers["content-length"] = environ["CONTENT_LENGTH"]
        scheme = environ.get("wsgi.url_scheme", "http")
        host = environ.get("HTTP_HOST") or _server_host(environ.get("SERVER_NAME", "localhost"), environ.get("SERVER_PORT"), scheme)
        mount = environ.get("SCRIPT_NAME", "")
        decoded = (mount + environ.get("PATH_INFO", "")).encode("latin-1")
        raw = environ.get("RAW_URI") or environ.get("REQUEST_URI")
        query = environ.get("QUERY_STRING", "")

        def body() -> bytes:
            stream = environ.get("wsgi.input")
            if stream is None:
                return b""
            length = environ.get("CONTENT_LENGTH")
            if length:
                size = int(length)
                if size > _MAX_BODY:
                    raise BodyTooLarge()
                # read(-1) would read everything.
                data: bytes = stream.read(size) if size > 0 else b""
                return data
            if environ.get("wsgi.input_terminated"):
                data = stream.read(_MAX_BODY + 1)
                if len(data) > _MAX_BODY:
                    raise BodyTooLarge()
                return data
            return b""

        return cls(
            method=environ.get("REQUEST_METHOD", "GET"),
            path=_request_path(decoded, raw),
            query=_raw_text(query),
            headers=headers,
            body=body,
            origin=_url_origin(scheme, host),
            mount=mount,
        )

    @classmethod
    def from_asgi(cls, scope: Mapping[str, Any], body: bytes) -> Request:
        """An ASGI HTTP scope and its body, read as the SDK reads a fetch Request."""
        headers: dict[str, str] = {}
        for name, value in scope.get("headers", []):
            key = name.decode("latin-1").lower()
            text = value.decode("latin-1")
            if key in headers:
                # Cookies split over several headers (HTTP/2) are one list again.
                text = f"{headers[key]}{'; ' if key == 'cookie' else ', '}{text}"
            headers[key] = text
        scheme = scope.get("scheme", "http")
        server = scope.get("server")
        host = headers.get("host") or (_server_host(server[0], server[1], scheme) if server else "localhost")
        mount = scope.get("root_path", "")
        path = scope.get("path", "/")
        # Servers and frameworks differ on whether the path includes root_path.
        if mount and not path.startswith(mount):
            path = mount + path
        raw = scope.get("raw_path")
        raw_text = raw.decode("latin-1") if raw else None
        candidates = [] if raw_text is None else [raw_text, quote(mount, safe=_PATH_SAFE) + raw_text] if mount else [raw_text]
        return cls(
            method=scope.get("method", "GET"),
            path=_request_path(path.encode("utf-8", "surrogateescape"), *candidates),
            query=_raw_text(scope.get("query_string", b"").decode("latin-1")),
            headers=headers,
            body=body,
            origin=_url_origin(scheme, host),
            mount=mount,
        )


@dataclass
class Response:
    status: int
    headers: dict[str, str]
    body: bytes = b""

    @property
    def text(self) -> str:
        return self.body.decode("utf-8")

    def wsgi_headers(self) -> list[tuple[str, str]]:
        """The headers with a Content-Length, for a server."""
        return [*self.headers.items(), ("content-length", str(len(self.body)))]


def _server_host(name: str, port: Any, scheme: str) -> str:
    if port is None or str(port) == str(_origin.DEFAULT_PORTS.get(scheme)):
        return str(name)
    return f"{name}:{port}"


def _raw_text(text: str) -> str:
    """A query string as a URL holds it: bytes outside ASCII percent-encoded."""
    if text.isascii():
        return text
    return quote(text.encode("latin-1", "replace"), safe="".join(chr(c) for c in range(0x21, 0x7F)))


def _url_origin(scheme: str, host: str) -> str:
    """The origin of scheme://host, as URL#origin writes it (lowercased, no default port)."""
    try:
        read = _origin.bare(f"{scheme}://{host}")
    except Exception:
        read = None
    return read or f"{scheme.lower()}://{host.lower()}"


def _request_path(decoded: bytes, *raw: str | None) -> str:
    """The path as the browser sent it. A server hands over the path already
    decoded; the raw request target, when the server passes it (gunicorn's
    RAW_URI, uWSGI's REQUEST_URI, ASGI's raw_path), is used when it decodes to
    the same path. Otherwise the decoded path is encoded again, as a browser
    encodes it (a "%" in it as %25)."""
    for target in raw:
        if not target:
            continue
        if "://" in target.split("?", 1)[0]:
            target = urlsplit(target).path or "/"
        target = target.split("?", 1)[0].split("#", 1)[0]
        if unquote_to_bytes(target.encode("latin-1", "replace")) == decoded:
            return target
    path = quote(decoded, safe=_PATH_SAFE)
    return path or "/"


def _parse_query(text: str) -> list[tuple[str, str]]:
    """application/x-www-form-urlencoded parsing as URLSearchParams does it:
    "+" is a space, a bad escape is kept as written, bytes that are not UTF-8 become U+FFFD."""
    text = text[1:] if text.startswith("?") else text
    pairs = []
    for part in text.split("&"):
        if part == "":
            continue
        key, _, value = part.partition("=")
        pairs.append((_form_decode(key), _form_decode(value)))
    return pairs


def _form_decode(text: str) -> str:
    """Percent-decoded bytes as UTF-8. Text read from the wire holds one byte per character (latin-1)."""
    text = text.replace("+", " ")
    data = text.encode("latin-1") if all(ord(c) < 256 for c in text) else text.encode("utf-8", "surrogatepass")
    return unquote_to_bytes(data).decode("utf-8", "replace")


def _form_encode(text: str) -> str:
    """The application/x-www-form-urlencoded serializer URLSearchParams writes with."""
    return quote_plus(_js.well_formed(text), safe="*").replace("~", "%7E")


def _safe_decode(value: str) -> str | None:
    """decodeURIComponent, or None where it would throw: a bad escape, or bytes that are not UTF-8."""
    if _BAD_ESCAPE.search(value):
        return None
    try:
        return unquote_to_bytes(value).decode("utf-8")
    except UnicodeDecodeError:
        return None


def _constant_time_equal(a: str, b: str) -> bool:
    """Compares two secrets without stopping at the first differing character (UTF-16 units, as the SDK compares)."""
    return hmac.compare_digest(a.encode("utf-16-le", "surrogatepass"), b.encode("utf-16-le", "surrogatepass"))


def _cookie_value(token: str) -> str:
    """The cookie holds a digest of the token, so a leaked cookie does not
    reveal the bearer token itself: the SHA-256 of "cronwatch-cookie:<token>", as hex."""
    return hashlib.sha256(f"cronwatch-cookie:{token}".encode("utf-8", "surrogatepass")).hexdigest()


def _development_token() -> str:
    """A token for one routes instance in development, when none is configured:
    32 random bytes, base64url (43 characters)."""
    return base64.urlsafe_b64encode(secrets.token_bytes(32)).decode().rstrip("=")


def _development_sign_in_line(origin: str | None, base: str, token: str) -> str:
    """The line a development token is announced with, printed once to stdout
    on the routes' first request. `origin` is the `origin` option when set,
    otherwise the first request's public origin when its host is loopback,
    and None for any other host: the request's host is the client's to
    choose, so the line then leaves it out rather than point the link, token
    and all, somewhere else. `base` is the base path without a trailing slash
    ("" when mounted at the root)."""
    intro = "[cronwatch] CRONWATCH_TOKEN is not set, so this development server made a token for the dashboard. Sign in: "
    if origin is None:
        return f"{intro}{base}/?token={token} on this server (the first request's host is not local, so the link leaves it out)"
    return f"{intro}{origin}{base}/?token={token}"


_LOOPBACK_V4 = re.compile(r"127\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})")


def _is_loopback_origin(origin: str) -> bool:
    """Whether an origin's host is loopback: "localhost", a name ending in
    ".localhost", an IPv4 address in 127.0.0.0/8, or the IPv6 address ::1.
    Only an origin that reads as one counts: a Host header is anyone's to
    send, and one such as "evil.example/.localhost" or
    "localhost:1@evil.example" must not put the development token in a link
    to another host."""
    bare = _origin.bare(origin)
    if bare is None:
        return False
    authority = bare.split("://", 1)[1] if "://" in bare else bare
    if authority.startswith("["):
        end = authority.find("]")
        host = authority[: end + 1] if end >= 0 else authority
    else:
        host = authority.split(":", 1)[0]
    host = host.lower()
    if host in ("localhost", "[::1]") or host.endswith(".localhost"):
        return True
    octets = _LOOPBACK_V4.fullmatch(host)
    return octets is not None and all(int(o) <= 255 for o in octets.groups())


def _strip_base(pathname: str, base: str) -> str:
    path = pathname[len(base) :] if pathname.startswith(base) else pathname
    if path == "":
        path = "/"
    if len(path) > 1 and path.endswith("/"):
        path = path[:-1]
    return path


def _first_value(value: str | None) -> str | None:
    """The first entry of a comma-separated header, trimmed, or None when there is none."""
    if value is None:
        return None
    first = _js.trim(value.split(",")[0])
    return first or None


def _js_string(value: Any) -> str:
    """String(value) for a parsed JSON value."""
    if value is None:
        return "null"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, list):
        return ",".join("" if v is None else _js_string(v) for v in value)
    if isinstance(value, dict):
        return "[object Object]"
    if isinstance(value, (int, float)):
        return _js.number(value)
    return str(value)


def _refuse_constant(name: str) -> Any:
    raise ValueError(f"{name} is not JSON")


def _js_number(value: str) -> float:
    """Number(string): decimal, 0x/0o/0b, Infinity, or NaN."""
    text = _js.trim(value)
    if text == "":
        return 0
    if _DECIMAL.match(text):
        return float(text)
    if text in ("Infinity", "+Infinity"):
        return math.inf
    if text == "-Infinity":
        return -math.inf
    match = _RADIX.match(text)
    if match:
        try:
            return int(match.group(2), {"x": 16, "o": 8, "b": 2}[match.group(1).lower()])
        except ValueError:
            return math.nan
    return math.nan


def _silence_duration(value: str | None) -> Any:
    """Absent means one hour; a number or numeric string is milliseconds. Raises on anything else."""
    if value is None:
        return "1h"
    text = _js.trim(value)
    duration: Any = text
    if _WHOLE.match(text):
        number = float(text)
        duration = int(number) if number.is_integer() and abs(number) <= _js.MAX_SAFE_INTEGER else number
    parse_duration(duration, "silence duration")
    return duration


def _runs_limit(value: str | None) -> int:
    n = math.nan if value is None or _js.trim(value) == "" else _js_number(value)
    if not _js.is_finite(n):
        return _DEFAULT_RUNS
    return min(_MAX_RUNS, max(1, math.trunc(n)))


def _api(body: Any, status: int = 200, headers: Mapping[str, str] | None = None) -> Response:
    return Response(
        status,
        {"content-type": "application/json; charset=utf-8", "cache-control": "no-store", **_SECURITY_HEADERS, **(headers or {})},
        _js.dumps(body).encode("utf-8", "surrogatepass"),
    )


def _redirect(location: str, headers: Mapping[str, str] | None = None) -> Response:
    return Response(303, {"location": location, "cache-control": "no-store", **_SECURITY_HEADERS, **(headers or {})})


def _shell(asset: _pwa.Asset, base: str) -> Response:
    """An app shell file. The worker may be scoped to the base (it is served
    from there anyway); the SVGs get a CSP of their own."""
    headers = {"content-type": asset.type, "cache-control": asset.cache, **_SECURITY_HEADERS}
    if asset.type == "image/svg+xml":
        headers["content-security-policy"] = _ASSET_CSP
    if asset.worker:
        headers["service-worker-allowed"] = f"{base}/"
    return Response(200, headers, asset.body)


def _html_response(body: str, status: int = 200, cache: str = "no-store") -> Response:
    return Response(
        status,
        {
            "content-type": "text/html; charset=utf-8",
            "cache-control": cache,
            "content-security-policy": _CSP,
            "x-frame-options": "DENY",
            **_SECURITY_HEADERS,
        },
        _js.well_formed(body).encode("utf-8"),
    )


class Web:
    """The dashboard and JSON API, as ``cw.routes()`` makes it. Call it as a
    WSGI app, mount .asgi as an ASGI app, or hand .handle a Request. See the
    module's docstring for the options.

    Making one directly, ``Web(client)``, is deprecated (it warns, and goes in
    2.0): ``cw.routes()`` is the one way, and ``cronwatch.client().routes()``
    for the process's client."""

    def __init__(
        self,
        client: Any = None,
        *,
        token: str | None = _UNSET,
        base_path: str | None = None,
        origin: str | None = None,
        trust_proxy: bool = False,
    ) -> None:
        if type(self) is Web:
            warnings.warn("cronwatch.web.Web(client) is deprecated: use cw.routes()", DeprecationWarning, stacklevel=2)
        self._setup(client, token=token, base_path=base_path, origin=origin, trust_proxy=trust_proxy)

    @classmethod
    def _for(cls, client: Any, **options: Any) -> Web:
        """What cw.routes() makes, without the warning Web(client) gives."""
        web = cls.__new__(cls)
        web._setup(client, **options)
        return web

    def _setup(
        self,
        client: Any = None,
        *,
        token: str | None = _UNSET,
        base_path: str | None = None,
        origin: str | None = None,
        trust_proxy: bool = False,
    ) -> None:
        self._client = client
        self._opted_out = token is None
        given = None if token is _UNSET or token is None else str(token)
        configured = None if self._opted_out else (given or os.environ.get("CRONWATCH_TOKEN") or None)
        self._base_path = None if base_path is None else re.sub(r"/+\Z", "", str(base_path))
        self._origin = _origin.parse(origin)
        self._trust_proxy = trust_proxy is True
        # A request handler cannot tell a local caller from a remote one
        # (proxies, tunnels and a server bound to every interface all look
        # alike), so development gets a token too: made here, and shown only
        # in the server log.
        self._generated = configured is None and not self._opted_out and _env.is_development()
        self._token: str | None = _development_token() if self._generated else configured
        self._cookie = _cookie_value(self._token) if self._token else None
        self._announced = False
        self._announce_lock = threading.Lock()

    @property
    def client(self) -> Any:
        """The client given, or cronwatch.client() when none was."""
        if self._client is not None:
            return self._client
        import cronwatch

        return cronwatch.client()

    @property
    def token(self) -> str | None:
        """The token the routes ask for (the generated one in development), or None when open."""
        return self._token

    # ------------------------------------------------------------ servers

    def __call__(self, environ: Mapping[str, Any], start_response: Callable[..., Any]) -> list[bytes]:
        """The WSGI app."""
        response = self.handle(Request.from_wsgi(environ))
        start_response(f"{response.status} {http.HTTPStatus(response.status).phrase}", response.wsgi_headers())
        return [] if str(environ.get("REQUEST_METHOD", "")).upper() == "HEAD" else [response.body]

    async def asgi(self, scope: Mapping[str, Any], receive: Callable[..., Any], send: Callable[..., Any]) -> None:
        """The ASGI app. The routes are synchronous, like the client they
        read, so each request runs in a worker thread (asyncio.to_thread)."""
        kind = scope.get("type")
        if kind == "lifespan":
            while True:
                message = await receive()
                if message["type"] == "lifespan.startup":
                    await send({"type": "lifespan.startup.complete"})
                elif message["type"] == "lifespan.shutdown":
                    await send({"type": "lifespan.shutdown.complete"})
                    return
        if kind != "http":
            if kind == "websocket":
                await send({"type": "websocket.close", "code": 1000})
            return
        body = await _read_asgi_body(receive)
        if body is None:
            return
        head = str(scope.get("method", "")).upper() == "HEAD"
        if isinstance(body, BodyTooLarge):
            response = _too_large()
        else:
            response = await asyncio.to_thread(self.handle, Request.from_asgi(scope, body))
        headers = [(k.encode("latin-1"), v.encode("latin-1")) for k, v in response.wsgi_headers()]
        await send({"type": "http.response.start", "status": response.status, "headers": headers})
        await send({"type": "http.response.body", "body": b"" if head else response.body})

    # ------------------------------------------------------------ the routes

    def handle(self, request: Request) -> Response:
        """One request, answered as the SDK's routes answer it."""
        wants_html = True
        base = self._base_path if self._base_path is not None else re.sub(r"/+\Z", "", request.mount)
        try:
            path = _strip_base(request.path, base)
            wants_html = not path.startswith("/api")
            return self._serve(request, path, wants_html, base)
        except BodyTooLarge:
            return _too_large()
        except Exception as error:
            try:
                self.client.on_error(error, "routes")
            except Exception:
                pass  # Reporting must not turn a 500 into an exception.
            if wants_html:
                return _html_response(_html.message_page("Something went wrong", "The request failed and the error was reported.", base), 500)
            return _api({"ok": False, "error": "Internal error"}, 500)

    def public_origin(self, request: Request) -> str:
        """The origin a browser sees: the `origin` option, the forwarded one under trust_proxy, else the request's own."""
        if self._origin is not None:
            return self._origin
        if self._trust_proxy:
            return self._forwarded_origin(request)
        return request.origin

    def _forwarded_origin(self, request: Request) -> str:
        """With trust_proxy: the forwarded scheme and host when present and well formed, otherwise the request's own."""
        proto = _first_value(request.header("x-forwarded-proto"))
        proto = proto.lower() if proto is not None else None
        host = _first_value(request.header("x-forwarded-host"))
        if proto is None and host is None:
            return request.origin
        if proto is not None and proto not in ("http", "https"):
            return request.origin
        own = urlsplit(request.origin)
        built = _origin.bare(f"{proto or own.scheme}://{host or own.netloc}")
        return built or request.origin

    def _announce(self, origin: str, base: str) -> None:
        """Prints the development sign-in link, once per routes instance."""
        with self._announce_lock:
            if self._announced:
                return
            self._announced = True
        shown = self._origin if self._origin is not None else (origin if _is_loopback_origin(origin) else None)
        print(_development_sign_in_line(shown, base, self._token or ""), file=sys.stdout, flush=True)

    def _serve(self, request: Request, path: str, wants_html: bool, base: str) -> Response:
        method = request.method.upper()
        public_origin = self.public_origin(request)

        if self._generated and not self._announced:
            self._announce(public_origin, base)

        # The app shell: the manifest, icons, service worker, app.js and the
        # offline page. Served to anyone, since a browser fetches some of it
        # without cookies and none of it says anything about the jobs.
        if method in ("GET", "HEAD"):
            if path == "/offline":
                return _html_response(_html.message_page("You are offline", "CronWatch shows live data from your app, so it needs a connection.", base), 200, "no-cache")
            asset = _pwa.asset(path, base)
            if asset is not None:
                return _shell(asset, base)

        # No token outside development: fail closed.
        if not self._token and not self._opted_out:
            if wants_html:
                return _html_response(_html.message_page("CronWatch routes are locked", _LOCKED, base), 503)
            return _api({"ok": False, "error": "CRONWATCH_TOKEN is not set"}, 503)

        if method not in ("GET", "HEAD") and self._cross_site(request, public_origin):
            if wants_html:
                return _html_response(_html.message_page("Cross-site request refused", "Changes can only be made from the dashboard itself.", base), 403)
            return _api({"ok": False, "error": "Cross-site request refused"}, 403)

        cw = self.client
        authorization = request.header("authorization")
        bearer = None if authorization is None else _BEARER.sub("", authorization, count=1)
        if self._token:
            # ?token= is only the sign-in that moves the token into a cookie.
            query = request.param("token") if wants_html and method == "GET" else None
            sent = self._read_cookie(request, _COOKIE)
            secret = getattr(cw, "cron_secret", None)
            cron_secret_ok = path == "/api/check" and bearer is not None and secret is not None and _constant_time_equal(bearer, secret)
            if bearer is not None:
                token_ok = _constant_time_equal(bearer, self._token)
            elif query is not None:
                token_ok = _constant_time_equal(query, self._token)
            else:
                token_ok = sent is not None and self._cookie is not None and _constant_time_equal(sent, self._cookie)
            if not cron_secret_ok and not token_ok:
                if self._generated:
                    if wants_html:
                        message = (
                            "CRONWATCH_TOKEN is not set, so this development server made a token. "
                            "The sign-in link is in the server log: open it once and this browser stays signed in."
                        )
                        return _html_response(_html.message_page("Sign in", message, base, sign_in=True), 401)
                    return _api({"ok": False, "error": "Unauthorized: CRONWATCH_TOKEN is not set, so this development server made a token; it is in the server log"}, 401)
                if wants_html:
                    message = "Open this page with ?token=<your CRONWATCH_TOKEN> once and it will stay signed in."
                    return _html_response(_html.message_page("Sign in", message, base, sign_in=True), 401)
                return _api({"ok": False, "error": "Unauthorized"}, 401)
            if query is not None:
                # Move the token from the URL into a cookie so it is not in history or logs.
                rest = [(k, v) for k, v in request.params() if k != "token"]
                search = "?" + "&".join(f"{_form_encode(k)}={_form_encode(v)}" for k, v in rest) if rest else ""
                secure = "; Secure" if public_origin.startswith("https:") else ""
                cookie = f"{_COOKIE}={self._cookie}; Path={base or '/'}; HttpOnly; SameSite=Lax; Max-Age={_COOKIE_MAX_AGE}{secure}"
                return _redirect(request.path + search, {"set-cookie": cookie})

        def redirect_back() -> Response:
            referer = request.header("referer") or ""
            return _redirect(referer if referer.startswith(public_origin + "/") else f"{base}/")

        decoded = [_safe_decode(part) for part in path.split("/") if part]
        if any(part is None for part in decoded):
            if wants_html:
                return _html_response(_html.message_page("Bad request", "The path is not valid.", base), 400)
            return _api({"ok": False, "error": "Bad path"}, 400)
        parts: list[str] = [p for p in decoded if p is not None]

        # HTML
        if method == "GET" and path == "/":
            entries = cw.jobs_with_runs(_BOARD_PAGE_RUNS)
            now = cw.now()
            runs_by_job = {entry.job.name: entry.runs for entry in entries}
            lanes = self._board_lanes(cw, entries, now)
            return _html_response(_html.dashboard_page([entry.job for entry in entries], runs_by_job, now, base, None, lanes))
        if method == "GET" and len(parts) == 2 and parts[0] == "jobs":
            job = cw.job_summary(parts[1])
            if job is None:
                return _html_response(_html.message_page("No such job", f"{parts[1]} is not in the store.", base), 404)
            now = cw.now()
            # Enough runs to draw the job's week; the page lists the newest fifty.
            limit = timeline.week_runs_limit(job, now)
            runs = cw.runs(job.name, limit)
            return _html_response(_html.job_page(job, runs, now, base, len(runs) < limit))
        if method == "POST" and path == "/check":
            cw.check()
            return redirect_back()
        if method == "POST" and len(parts) == 3 and parts[0] == "jobs":
            name, action = parts[1], parts[2]
            if action == "forget":
                cw.forget(name)
                return _redirect(f"{base}/")
            if action not in ("silence", "unsilence"):
                return _html_response(_html.message_page("Not found", path, base), 404)
            if cw.job_summary(name) is None:
                return _html_response(_html.message_page("No such job", f"{name} is not in the store.", base), 404)
            if action == "silence":
                try:
                    duration = _silence_duration(self._read_body(request).get("for"))
                except ValueError as error:
                    return _html_response(_html.message_page("Not silenced", str(error), base), 400)
                cw.silence(name, duration)
            else:
                cw.unsilence(name)
            return redirect_back()

        # JSON API
        if parts and parts[0] == "api":
            return self._serve_api(cw, request, method, parts[1:], bearer)

        return _html_response(_html.message_page("Not found", path, base), 404)

    def _serve_api(self, cw: Any, request: Request, method: str, rest: list[str], bearer: str | None) -> Response:
        # What is serving the API, so a client such as @cronwatch/mcp can tell.
        if method == "GET" and rest == []:
            from .. import __version__

            return _api({"ok": True, "library": _LIBRARY, "language": _LANGUAGE, "version": __version__, "api": _API_VERSION})
        if method == "GET" and rest == ["jobs"]:
            return _api({"ok": True, "jobs": cw.jobs()})
        if len(rest) == 2 and rest[0] == "jobs":
            name = rest[1]
            if method == "GET":
                job = cw.job_summary(name)
                if job is None:
                    return _api({"ok": False, "error": "No such job"}, 404)
                return _api({"ok": True, "job": job, "runs": cw.runs(name, _runs_limit(request.param("runs")))})
            if method == "DELETE":
                if cw.job_summary(name) is None:
                    return _api({"ok": False, "error": "No such job"}, 404)
                cw.forget(name)
                return _api({"ok": True})
        if method == "POST" and len(rest) == 3 and rest[0] == "jobs":
            name = rest[1]
            if cw.job_summary(name) is None:
                return _api({"ok": False, "error": "No such job"}, 404)
            if rest[2] == "silence":
                body = self._read_body(request)
                try:
                    duration = _silence_duration(body["for"] if "for" in body else request.param("for"))
                except ValueError as error:
                    return _api({"ok": False, "error": str(error)}, 400)
                cw.silence(name, duration)
                return _api({"ok": True, "job": cw.job_summary(name)})
            if rest[2] == "unsilence":
                cw.unsilence(name)
                return _api({"ok": True, "job": cw.job_summary(name)})
        if rest == ["check"]:
            # A page cannot send an Authorization header cross-site, so a GET
            # may only run the check when it carries a bearer (token or cron secret).
            if method == "GET" and bearer is None:
                return _api({"ok": False, "error": "Use POST, or GET with an Authorization bearer"}, 405, {"allow": "POST"})
            if method in ("GET", "POST"):
                result = cw.check()
                return _api({"ok": True, **result.to_dict()})
        if method == "GET" and len(rest) == 2 and rest[0] == "runs":
            run = cw.get_run(rest[1])
            return _api({"ok": True, "run": run}) if run is not None else _api({"ok": False, "error": "No such run"}, 404)
        return _api({"ok": False, "error": "Not found"}, 404)

    def _board_lanes(self, cw: Any, entries: list[Any], now: int) -> list[timeline.LaneInput]:
        """The board's timeline lanes, the first BOARD_LANES jobs. The runs
        already read for the table usually cover the last day; only a job
        whose twenty newest runs all fall inside it (one that runs more often
        than every hour or so) is read again, deeper."""
        start = now - timeline.BOARD_BEHIND_MS
        lanes = []
        for entry in entries[: timeline.BOARD_LANES]:
            runs = entry.runs
            short = len(runs) >= _BOARD_PAGE_RUNS and runs[-1].started_at > start
            if not short:
                lanes.append(timeline.LaneInput(entry.job, runs, True))
                continue
            deeper = cw.runs(entry.job.name, timeline.BOARD_RUNS)
            lanes.append(timeline.LaneInput(entry.job, deeper, len(deeper) < timeline.BOARD_RUNS))
        return lanes

    @staticmethod
    def _read_cookie(request: Request, name: str) -> str | None:
        header = request.header("cookie")
        if not header:
            return None
        for part in header.split(";"):
            key, *rest = _js.trim(part).split("=")
            # A malformed escape counts as no cookie.
            if key == name:
                return _safe_decode("=".join(rest))
        return None

    @staticmethod
    def _cross_site(request: Request, public_origin: str) -> bool:
        """A browser attaches Origin or Sec-Fetch-Site to a cross-site form post,
        and a page cannot forge either. Non-browser clients send neither."""
        origin = request.header("origin")
        if origin is not None and origin != public_origin:
            return True
        site = request.header("sec-fetch-site")
        return site is not None and site not in ("same-origin", "none")

    @staticmethod
    def _read_body(request: Request) -> dict[str, str]:
        """The form fields or JSON object of a request, each value as String(value)
        gives it in JavaScript. JSON is read as request.json() reads it: bytes
        that are not UTF-8 become U+FFFD, and a leading byte order mark is dropped."""
        kind = request.header("content-type") or ""
        try:
            if "application/json" in kind:
                text = request.read().decode("utf-8", "replace")
                data = _js_loads(text[1:] if text.startswith("﻿") else text)
                if isinstance(data, dict):
                    return {str(k): _js_string(v) for k, v in data.items()}
                if isinstance(data, list):
                    return {str(i): _js_string(v) for i, v in enumerate(data)}
                return {}
            if "application/x-www-form-urlencoded" in kind or "multipart/form-data" in kind:
                if request.form is not None:
                    return {str(k): _form_value(v) for k, v in request.form.items()}
                data = request.read()
                if "multipart/form-data" in kind:
                    return _multipart(kind, data)
                out: dict[str, str] = {}
                for key, value in _parse_query(data.decode("latin-1")):
                    out[key] = value
                return out
        except BodyTooLarge:
            raise
        except Exception:
            return {}
        return {}


def _too_large() -> Response:
    """The answer to a body over MAX_BODY bytes."""
    return _api({"ok": False, "error": "Request body too large"}, 413)


async def _read_asgi_body(receive: Callable[..., Any]) -> bytes | BodyTooLarge | None:
    """An ASGI request's body; BodyTooLarge once it passes MAX_BODY bytes (the
    rest is not read); None when the client went away."""
    chunks: list[bytes] = []
    size = 0
    while True:
        message = await receive()
        if message["type"] == "http.disconnect":
            return None
        chunk = message.get("body", b"")
        size += len(chunk)
        if size > _MAX_BODY:
            return BodyTooLarge()
        chunks.append(chunk)
        if not message.get("more_body", False):
            return b"".join(chunks)


def _js_loads(text: str) -> Any:
    """JSON.parse: NaN and Infinity are not JSON there."""
    import json

    return json.loads(text, parse_constant=_refuse_constant)


def _form_value(value: Any) -> str:
    """String(value) for a field a framework parsed: a file is "[object File]"."""
    if isinstance(value, str):
        return value
    if isinstance(value, (list, tuple)):
        return _form_value(value[-1]) if value else ""
    if hasattr(value, "read"):
        return "[object File]"
    return _js_string(value)


def _multipart(kind: str, data: bytes) -> dict[str, str]:
    """multipart/form-data as request.formData() reads it: fields as text, files as "[object File]"."""
    message = BytesParser(policy=HTTP).parsebytes(f"content-type: {kind}\r\n\r\n".encode("latin-1") + data)
    if not message.is_multipart():
        raise ValueError("not multipart")
    out: dict[str, str] = {}
    for part in message.iter_parts():
        name = part.get_param("name", header="content-disposition")
        if name is None:
            continue
        if part.get_filename() is not None:
            out[str(name)] = "[object File]"
        else:
            payload = part.get_payload(decode=True)
            out[str(name)] = payload.decode("utf-8", "replace") if isinstance(payload, bytes) else ""
    return out


#: Internal names, still answering under their old public names (each
#: warning, until 1.0 removes them).
__getattr__ = _deprecated_names(__name__, globals(), {"UNSET": "_UNSET", "COOKIE": "_COOKIE", "DEFAULT_RUNS": "_DEFAULT_RUNS", "MAX_RUNS": "_MAX_RUNS", "BOARD_PAGE_RUNS": "_BOARD_PAGE_RUNS", "COOKIE_MAX_AGE": "_COOKIE_MAX_AGE", "MAX_BODY": "_MAX_BODY", "CSP": "_CSP", "ASSET_CSP": "_ASSET_CSP", "SECURITY_HEADERS": "_SECURITY_HEADERS", "LOCKED": "_LOCKED", "url_origin": "_url_origin", "request_path": "_request_path", "parse_query": "_parse_query", "safe_decode": "_safe_decode", "constant_time_equal": "_constant_time_equal", "cookie_value": "_cookie_value", "development_token": "_development_token", "development_sign_in_line": "_development_sign_in_line", "is_loopback_origin": "_is_loopback_origin", "too_large": "_too_large", "read_asgi_body": "_read_asgi_body"})
