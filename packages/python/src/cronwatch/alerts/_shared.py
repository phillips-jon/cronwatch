"""What the channels share (alerts/shared.ts): the POST that names the
provider and the URL's origin on failure with every secret cut out, the
stable alert id, the run summary trackers attach, and JavaScript's text
functions where the channels lean on them. Standard library only."""

from __future__ import annotations

import base64
import hashlib
import math
import urllib.parse
import warnings
from collections.abc import Callable, Iterable, Sequence
from typing import Any

from .. import _js
from ..duration import iso_time
from ..types import Alert
from ._http import HTTP, Response
from ._http import default as default_http

#: How much of a provider's error body goes into the error message.
ERROR_BODY_MAX = 200


def http_or_default(http: HTTP | None) -> HTTP:
    return default_http() if http is None else http


def severity(type_: object) -> str:
    """Severity for trackers that have levels. Recovered is informational."""
    kind = str(type_)
    if kind == "recovered":
        return "info"
    if kind in ("slow", "over_budget"):
        return "warning"
    return "error"


def origin(url: str) -> str:
    """The scheme, host and port only, as ``new URL(url).origin``. A URL's path or query can hold a credential."""
    try:
        parts = urllib.parse.urlsplit(_js.trim(str(url)))
        host = host_of(parts)
    except ValueError:
        return "(invalid URL)"
    if not parts.scheme or not host:
        return "(invalid URL)"
    return f"{parts.scheme.lower()}://{host}"


_DEFAULT_PORTS = {"http": 80, "https": 443, "ws": 80, "wss": 443, "ftp": 21}


def host_of(parts: urllib.parse.SplitResult) -> str:
    """URL#host: the hostname, lowercased, and the port when it is not the scheme's default."""
    hostname = parts.hostname or ""
    if ":" in hostname:
        hostname = f"[{hostname}]"
    port = parts.port
    if port is not None and port != _DEFAULT_PORTS.get(parts.scheme.lower()):
        return f"{hostname}:{port}"
    return hostname


def post(http: HTTP, provider: str, url: str, headers: dict[str, str], body: str, secrets: Sequence[str | None] = ()) -> Response:
    """POSTs and raises on a non-2xx answer. The error names the provider and
    the URL's origin, plus the start of the response body with every secret
    the channel holds cut out, in case a provider echoes one back (see
    error_body). A redirect is not followed: its 3xx is an error like any
    other answer outside 2xx, so the credential headers never go where it
    points."""
    response = http.post(url, body, headers)
    if response.ok:
        return response
    text = response.body or ""
    if text.startswith("﻿"):
        text = text[1:]
    raise RuntimeError(f"{provider} {origin(url)} answered {response.status}{': ' + error_body(text, secrets) if text else ''}")


def error_body(text: str, secrets: Iterable[str | None] = ()) -> str:
    """The start of an error body: secrets are cut out of a prefix long enough
    to hold one that starts inside the first ERROR_BODY_MAX characters, and
    only then is it cut to that length, on a code point, so no part of a
    secret survives at the edge."""
    kept = [s for s in secrets if isinstance(s, str) and _js.length16(s) >= 4]
    longest = max((_js.length16(s) for s in kept), default=0)
    head = cut(text, ERROR_BODY_MAX + longest)
    for secret in kept:
        head = head.replace(secret, "[redacted]")
    return cut(head, ERROR_BODY_MAX)


def trimmed(value: Any) -> str:
    """A credential with the spaces and newlines a paste leaves around it taken off. Anything not a string is ""."""
    return _js.trim(value) if isinstance(value, str) else ""


def required(value: Any, message: str) -> str:
    """A required credential, trimmed: raises ValueError when it is missing, not a string, or only whitespace."""
    credential = trimmed(value)
    if not credential:
        raise ValueError(message)
    return credential


def present(value: Any) -> bool:
    """JavaScript's truthiness for an optional string: None and "" are absent."""
    return value is not None and value != "" and value is not False


def link_for(link: Callable[[Alert], Any] | None, alert: Alert) -> str | None:
    """The link option's answer for this alert, or None."""
    if link is None:
        return None
    value = link(alert)
    return str(value) if present(value) else None


def b64(text: str) -> str:
    """Base64 of UTF-8."""
    return base64.b64encode(_js.well_formed(text).encode("utf-8")).decode("ascii")


def basic_auth(user: str, password: str) -> str:
    return f"Basic {b64(f'{user}:{password}')}"


def sha256_hex(text: str) -> str:
    return hashlib.sha256(_js.well_formed(text).encode("utf-8")).hexdigest()


def alert_id(alert: Alert) -> str:
    """A stable 32 hex character id for one alert: the same job, type and time
    always give the same id, so a provider that deduplicates on it drops a
    resend of an alert it already took."""
    return sha256_hex(f"{alert.job}\n{alert.type}\n{_js.number(alert.at)}")[:32]


def as_uuid(id_: str) -> str:
    """The same id laid out as a UUID, for APIs that ask for one."""
    return f"{id_[0:8]}-{id_[8:12]}-{id_[12:16]}-{id_[16:20]}-{id_[20:32]}"


def _units(text: str) -> bytes:
    return text.encode("utf-16-le", "surrogatepass")


def cut(text: str, max_units: int) -> str:
    """At most `max_units` UTF-16 units, without splitting a surrogate pair (shared.ts's cut)."""
    if text.isascii():
        return text[: max(max_units, 0)]
    if _js.length16(text) <= max_units:
        return text
    data = _units(text)[: max_units * 2]
    if data and 0xD800 <= int.from_bytes(data[-2:], "little") <= 0xDBFF:
        data = data[:-2]
    return data.decode("utf-16-le", "surrogatepass")


def slice16(text: str, end: int) -> str:
    """text.slice(0, end) as JavaScript takes it, in UTF-16 units. A cut
    through a surrogate pair keeps the lone half, as JavaScript does; the
    JSON writer then escapes it as JSON.stringify does, so a JSON body
    carries the same bytes."""
    if text.isascii():
        return text[: max(end, 0)]
    return _units(text)[: max(end, 0) * 2].decode("utf-16-le", "surrogatepass")


def iso(at: float) -> str:
    """new Date(at).toISOString()."""
    return _js.iso(at)


def floor_div(at: float, by: int) -> int:
    """Math.floor(at / by)."""
    return math.floor(at / by)


def run_summary(alert: Alert) -> dict[str, Any] | None:
    """The run fields worth attaching to a tracker event. A start before the year 1 or after 9999 is None."""
    run = alert.run
    if run is None:
        return None
    return {"id": run.id, "status": str(run.status), "startedAt": iso_time(run.started_at), "durationMs": run.duration_ms, "trigger": run.trigger}


def plain_text(alert: Alert, link: str | None) -> str:
    """Title, message, triage and link as one plain text block, the way every channel reads."""
    lines = [alert.title, "", alert.message]
    if present(alert.triage):
        lines += ["", f"Triage: {alert.triage}"]
    if present(link):
        lines += ["", f"Open: {link}"]
    return "\n".join(lines)


_COMPONENT_SAFE = frozenset(b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
_FORM_SAFE = frozenset(b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789*-._")


def encode_uri_component(text: str) -> str:
    """encodeURIComponent."""
    return "".join(chr(b) if b in _COMPONENT_SAFE else f"%{b:02X}" for b in _js.well_formed(str(text)).encode("utf-8"))


def _form_component(text: str) -> str:
    return "".join("+" if b == 0x20 else chr(b) if b in _FORM_SAFE else f"%{b:02X}" for b in _js.well_formed(str(text)).encode("utf-8"))


def form(pairs: Iterable[tuple[str, str]]) -> str:
    """URLSearchParams#toString for these pairs: application/x-www-form-urlencoded."""
    return "&".join(f"{_form_component(k)}={_form_component(v)}" for k, v in pairs)


def json_body(value: Any) -> str:
    """JSON.stringify."""
    return _js.dumps(value)


def positional_url(channel: str, positional: str | None, webhook_url: str | None) -> str | None:
    """The webhook URL given by name, or (deprecated, until 2.0) as the first argument."""
    if positional is None:
        return webhook_url
    if webhook_url is not None:
        raise TypeError(f"{channel}() got webhook_url twice: pass it by name only")
    warnings.warn(f"{channel}(url) is deprecated: pass {channel}(webhook_url=url)", DeprecationWarning, stacklevel=3)
    return positional
