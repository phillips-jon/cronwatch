"""HTTP responses a job hands back. The SDK fails a run whose function
returns a fetch Response with a status of 400 or more; Python has no one
Response type, so any of the common ones counts, read by duck typing:
cronwatch.web.Response, anything with an integer status_code (Django,
Flask and Werkzeug, Starlette and FastAPI, requests, httpx), and the standard
library's http.client.HTTPResponse (what urllib.request.urlopen returns)."""

from __future__ import annotations

import http.client
import sys
from typing import Any

_PLAIN = (str, bytes, bytearray, int, float, bool, list, tuple, dict, set, type(None))


def response_status(value: Any) -> tuple[int, str] | None:
    """(status, reason) for an HTTP response, or None for anything else. The
    reason is the response's own reason phrase when it carries one (Django's
    reason_phrase, requests' reason, Werkzeug's status line), else "", as a
    fetch Response made without a statusText has none."""
    if isinstance(value, _PLAIN):
        return None
    web = sys.modules.get("cronwatch.web")
    if web is not None and isinstance(value, web.Response):
        return value.status, ""
    if isinstance(value, http.client.HTTPResponse):
        return value.status, value.reason or ""
    try:
        code = getattr(value, "status_code", None)
    except Exception:
        return None
    if not isinstance(code, int) or isinstance(code, bool) or not 100 <= code <= 599:
        return None
    return code, _reason(value, code)


def _reason(value: Any, code: int) -> str:
    for name in ("reason_phrase", "reason"):
        try:
            text = getattr(value, name, None)
        except Exception:
            text = None
        if isinstance(text, str):
            return text
    try:
        line = getattr(value, "status", None)
    except Exception:
        line = None
    # Werkzeug's status is the whole line, "404 NOT FOUND".
    if isinstance(line, str) and line.startswith(f"{code} "):
        return line[len(str(code)) + 1 :]
    return ""
