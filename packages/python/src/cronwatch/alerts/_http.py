"""POSTs for the alert channels, on the standard library's urllib.request.
Anything with ``post(url, body, headers)`` returning a ``Response`` can stand
in for it (each channel takes ``http=``), which is how the tests run.

The SDK's channels call ``fetch`` with ``redirect: "error"`` and
``AbortSignal.timeout(10_000)``; this does the same: a redirect is an answer
like any other outside 2xx (never followed, so credential headers never go
where it points), and the whole request has one ten second deadline."""

from __future__ import annotations

import re
import socket
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Any, Protocol

from .._js import well_formed

#: Seconds a request may take, as the SDK's AbortSignal.timeout(10_000).
TIMEOUT = 10.0

_AROUND = re.compile(r"^[ \t\r\n]+|[ \t\r\n]+\Z")


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


def trim_header(value: Any) -> str:
    """A header value without the spaces, tabs and line breaks around it, as fetch sends it."""
    return _AROUND.sub("", str(value))


def text(data: bytes) -> str:
    """Bytes as response.text() reads them."""
    decoded = data.decode("utf-8", "replace")
    return decoded[1:] if decoded.startswith("﻿") else decoded


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Refuses to follow: urllib then hands the 3xx back as an HTTPError."""

    def redirect_request(self, req: Any, fp: Any, code: int, msg: str, headers: Any, newurl: str) -> None:
        return None


class UrllibHTTP:
    """The default: urllib.request, no redirects followed, one deadline for
    the whole request. Past the deadline before an answer it raises
    RequestTimeout; past it while the body is still arriving it returns the
    answer with an empty body, as the SDK's channels treat a body they could
    not read. ``timeout`` (seconds) is for tests."""

    def __init__(self, timeout: float = TIMEOUT) -> None:
        self.timeout = timeout
        self._opener = urllib.request.build_opener(_NoRedirect())

    def post(self, url: str, body: str, headers: dict[str, str]) -> Response:
        deadline = time.monotonic() + self.timeout
        request = urllib.request.Request(url, data=well_formed(body).encode("utf-8"), method="POST")
        for name, value in headers.items():
            request.add_header(name, trim_header(value))
        try:
            response = self._opener.open(request, timeout=_remaining(deadline))
        except urllib.error.HTTPError as error:
            return Response(error.code, _read(error.fp, deadline))
        except (TimeoutError, socket.timeout) as error:
            raise RequestTimeout() from error
        except urllib.error.URLError as error:
            if isinstance(error.reason, (TimeoutError, socket.timeout)):
                raise RequestTimeout() from error
            raise
        with response:
            return Response(response.status, _read(response, deadline))


def _remaining(deadline: float) -> float:
    """Seconds left before `deadline`, never quite zero (zero would mean no wait at all)."""
    return max(deadline - time.monotonic(), 0.001)


def _socket(response: Any) -> socket.socket | None:
    """The socket under an http.client response, to bound each read by the deadline."""
    raw = getattr(getattr(response, "fp", None), "raw", None)
    sock = getattr(raw, "_sock", None)
    return sock if isinstance(sock, socket.socket) else None


def _read(response: Any, deadline: float) -> str:
    """The body, read in chunks until the deadline; "" when it passes first."""
    if response is None:
        return ""
    chunks: list[bytes] = []
    sock = _socket(response)
    try:
        while True:
            if time.monotonic() >= deadline:
                return ""
            if sock is not None:
                sock.settimeout(_remaining(deadline))
            chunk = response.read1(65536) if hasattr(response, "read1") else response.read()
            if not chunk:
                break
            chunks.append(chunk)
    except (TimeoutError, socket.timeout, OSError):
        return ""
    return text(b"".join(chunks))


_default: UrllibHTTP | None = None


def default() -> UrllibHTTP:
    global _default
    if _default is None:
        _default = UrllibHTTP()
    return _default
