"""POSTs for the alert channels, on the standard library's urllib.request.
Anything with ``post(url, body, headers)`` returning a ``Response`` can stand
in for it (each channel takes ``http=``), which is how the tests run.

The SDK's channels call ``fetch`` with ``redirect: "error"`` and
``AbortSignal.timeout(10_000)``; this does the same: a redirect is an answer
like any other outside 2xx (never followed, so credential headers never go
where it points), and the whole request has one ten second deadline."""

from __future__ import annotations

import http.client
import re
import socket
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Any, Protocol

from .._js import well_formed

__all__ = ["HTTP", "MAX_BODY", "RequestTimeout", "Response", "TIMEOUT", "UrllibHTTP", "default", "text", "trim_header", "web_url"]

#: Seconds a request may take, as the SDK's AbortSignal.timeout(10_000).
TIMEOUT = 10.0

#: The most of an answer's body kept (1 MiB): a channel reads 200 characters
#: of a refusal, and a hostile or broken endpoint could otherwise send hundreds
#: of megabytes within the deadline. Reading stops there.
MAX_BODY = 1_048_576

_AROUND = re.compile(r"^[ \t\r\n]+|[ \t\r\n]+\Z")
# What the URL parser drops before it reads a URL: C0 controls and spaces around it, tabs and line breaks anywhere.
_C0_AROUND = re.compile(r"^[\x00-\x20]+|[\x00-\x20]+\Z")
_TAB_OR_NEWLINE = re.compile(r"[\t\n\r]")
# What a header name or value may not hold (http.client refuses them, quoting the value).
_BAD_HEADER = re.compile(r"[\x00\r\n]")


@dataclass
class Response:
    status: int
    #: The body as fetch's response.text() reads it: UTF-8, U+FFFD for bytes that are not, no byte order mark.
    body: str = ""

    @property
    def ok(self) -> bool:
        return 200 <= self.status < 300


class HTTP(Protocol):
    def post(self, url: str, body: str, headers: dict[str, str]) -> Response: ...


class RequestTimeout(TimeoutError):
    """The request took longer than its deadline. fetch's message for it."""

    def __init__(self, message: str = "The operation was aborted due to timeout") -> None:
        super().__init__(message)


def web_url(url: str) -> str:
    """The URL as fetch reads it: the spaces and control characters around it
    and any tab or line break inside it dropped (a URL pasted with a newline
    works), and only http or https, where urllib would also open file: and
    ftp: URLs. Raises ValueError naming no more than the scheme or the origin,
    since a webhook URL's path or query is often its credential."""
    text = _TAB_OR_NEWLINE.sub("", _C0_AROUND.sub("", str(url)))
    scheme = text.split(":", 1)[0].lower() if ":" in text else ""
    if scheme not in ("http", "https"):
        shown = f"{scheme}:" if scheme and re.fullmatch(r"[a-z][a-z0-9+.-]*", scheme) else "this URL"
        raise ValueError(f"only http and https URLs can be posted to, not {shown}")
    return text


def _origin_of(url: str) -> str:
    try:
        parts = urllib.parse.urlsplit(url)
        return f"{parts.scheme.lower()}://{parts.hostname or ''}"
    except ValueError:
        return "(invalid URL)"


def trim_header(value: Any) -> str:
    """A header value without the spaces, tabs, and line breaks around it, as fetch sends it."""
    return _AROUND.sub("", str(value))


def text(data: bytes) -> str:
    """Bytes as response.text() reads them."""
    decoded = data.decode("utf-8", "replace")
    return decoded[1:] if decoded.startswith("﻿") else decoded


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Refuses to follow: urllib then hands the 3xx back as an HTTPError."""

    def redirect_request(self, req: Any, fp: Any, code: int, msg: str, headers: Any, newurl: str) -> None:
        return None


class _Deadline:
    """One request's deadline, kept by a timer: when it passes, every socket
    the request opened is shut, so a read waiting on it ends however the
    server paces what it sends (a status line and headers a line at a time
    included, which a per-read timeout never catches). finish() says whether
    the request ended in time, and once it has, the timer no longer shuts
    anything."""

    def __init__(self, seconds: float) -> None:
        self._lock = threading.Lock()
        self._sockets: list[socket.socket] = []
        self._expired = False
        self._finished = False
        self._timer = threading.Timer(max(seconds, 0.0), self._expire)
        self._timer.daemon = True
        self._timer.start()

    @property
    def expired(self) -> bool:
        with self._lock:
            return self._expired

    def watch(self, sock: socket.socket) -> None:
        with self._lock:
            if not self._expired:
                self._sockets.append(sock)
                return
        _shut(sock)

    def _expire(self) -> None:
        with self._lock:
            if self._finished:
                return
            self._expired = True
            sockets = list(self._sockets)
        for sock in sockets:
            _shut(sock)

    def finish(self) -> bool:
        """Ends the watch: True when the request ended before the deadline."""
        self._timer.cancel()
        with self._lock:
            self._finished = True
            return not self._expired


def _shut(sock: socket.socket) -> None:
    try:
        sock.shutdown(socket.SHUT_RDWR)
    except OSError:
        pass


def _watched(http_class: Any, deadline: _Deadline) -> Any:
    """`http_class` (http.client's HTTPConnection or HTTPSConnection) with each
    socket it opens handed to `deadline` as soon as it is connected, before
    any TLS handshake."""

    class Watched(http_class):  # type: ignore[misc, valid-type]
        def __init__(self, *args: Any, **kwargs: Any) -> None:
            super().__init__(*args, **kwargs)
            create = self._create_connection

            def create_connection(*a: Any, **k: Any) -> socket.socket:
                sock = create(*a, **k)
                deadline.watch(sock)
                return sock

            self._create_connection = create_connection

    return Watched


class _HTTPHandler(urllib.request.HTTPHandler):
    def __init__(self, deadline: _Deadline) -> None:
        super().__init__()
        self._deadline = deadline

    def do_open(self, http_class: Any, req: Any, **kwargs: Any) -> Any:
        return super().do_open(_watched(http_class, self._deadline), req, **kwargs)


class _HTTPSHandler(urllib.request.HTTPSHandler):
    def __init__(self, deadline: _Deadline) -> None:
        super().__init__()
        self._deadline = deadline

    def do_open(self, http_class: Any, req: Any, **kwargs: Any) -> Any:
        return super().do_open(_watched(http_class, self._deadline), req, **kwargs)


class UrllibHTTP:
    """The default: urllib.request, no redirects followed, one deadline for
    the whole request, from connecting to the last byte of the body. Past the
    deadline before an answer it raises RequestTimeout; past it while the
    body is still arriving it returns the answer with an empty body, as the
    SDK's channels treat a body they could not read. The body kept is at most
    MAX_BODY bytes. ``timeout`` (seconds) is for tests."""

    def __init__(self, timeout: float = TIMEOUT) -> None:
        self.timeout = timeout

    def post(self, url: str, body: str, headers: dict[str, str]) -> Response:
        deadline = time.monotonic() + self.timeout
        target = web_url(url)
        request = urllib.request.Request(target, data=well_formed(body).encode("utf-8"), method="POST")
        for name, value in headers.items():
            text = trim_header(value)
            if _BAD_HEADER.search(text) or _BAD_HEADER.search(str(name)):
                # http.client's own error would quote the value, which may be a credential.
                raise ValueError(f"the {name!r} header has a line break or control character in it")
            request.add_header(name, text)
        watch = _Deadline(deadline - time.monotonic())
        opener = urllib.request.build_opener(_NoRedirect(), _HTTPHandler(watch), _HTTPSHandler(watch))
        try:
            try:
                response = opener.open(request, timeout=_remaining(deadline))
            except urllib.error.HTTPError as error:
                try:
                    if watch.expired:
                        # The headers ended only because the deadline shut the socket.
                        raise RequestTimeout() from None
                    return Response(error.code, _read(error.fp, watch))
                finally:
                    error.close()
            except (http.client.InvalidURL, ValueError):
                # Their messages quote the URL, whose path or query may be the credential.
                raise ValueError(f"cannot post to {_origin_of(target)}: the URL is not valid") from None
            except (OSError, http.client.HTTPException) as error:
                # Past the deadline the timer shut the socket, which surfaces as
                # whatever the read then saw (a reset, a closed connection).
                reason = error.reason if isinstance(error, urllib.error.URLError) else error
                if watch.expired or isinstance(reason, (TimeoutError, socket.timeout)):
                    raise RequestTimeout() from error
                raise
            with response:
                if watch.expired:
                    # The headers ended only because the deadline shut the socket.
                    raise RequestTimeout()
                return Response(response.status, _read(response, watch))
        finally:
            watch.finish()


def _remaining(deadline: float) -> float:
    """Seconds left before `deadline`, never quite zero (zero would mean no wait at all)."""
    return max(deadline - time.monotonic(), 0.001)


def _read(response: Any, watch: _Deadline) -> str:
    """The body, at most MAX_BODY bytes of it, read until the answer ends or
    the deadline passes; "" when the deadline passes first. A response that
    has read its whole body (by its length) closes itself, and a read after
    that gives nothing, which ends the loop."""
    if response is None:
        return ""
    chunks: list[bytes] = []
    size = 0
    try:
        while size < MAX_BODY:
            chunk = response.read1(65536) if hasattr(response, "read1") else response.read(65536)
            if not chunk:
                break
            chunk = chunk[: MAX_BODY - size]
            chunks.append(chunk)
            size += len(chunk)
    except (OSError, http.client.HTTPException):
        return ""
    if not watch.finish():
        return ""
    return text(b"".join(chunks))


_default: UrllibHTTP | None = None


def default() -> UrllibHTTP:
    global _default
    if _default is None:
        _default = UrllibHTTP()
    return _default
