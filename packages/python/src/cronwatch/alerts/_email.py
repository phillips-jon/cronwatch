"""What every email channel sends: one subject, a plain text body and a small
HTML body, so an alert reads the same whichever provider carries it
(alerts/email.ts). Resend, Postmark, SendGrid, Mailgun and SES each take the
same options:

    from_:          the sender, "alerts@example.com" or "CronWatch <alerts@example.com>"
    to:             one address or several
    subject_prefix: put in front of the title in the subject, "[prod]" say
    link:           lambda alert: f"https://app.example.com/cronwatch/jobs/{alert.job}"
"""

from __future__ import annotations

import re
from collections.abc import Callable
from dataclasses import dataclass
from typing import Any

from .. import _js
from ..types import Alert
from ._shared import cut, plain_text, present

__all__ = ["Email", "compose", "escape_html", "parse_address", "recipients"]

# Not a line terminator, as JavaScript's "." reads it.
_LINE = "[^\\n\\r\\u2028\\u2029]"
_ADDRESS = re.compile(f"^[{_js.WHITESPACE}]*({_LINE}*?)[{_js.WHITESPACE}]*<([^<>]+)>[{_js.WHITESPACE}]*\\Z")
_QUOTED = re.compile(f'^"({_LINE}*)"\\Z')
_NEWLINES = re.compile(r"[\r\n]+")
_HTTP = re.compile(r"^https?://", re.IGNORECASE | re.ASCII)


@dataclass
class Email:
    from_: str
    to: list[str]
    subject: str
    text: str
    html: str


def recipients(name: str, from_: Any, to: Any) -> list[str]:
    """Checks the shared options once, when the channel is made. Returns the recipients."""
    if not present(from_):
        raise ValueError(f"{name}() needs a from address")
    listed = to if isinstance(to, (list, tuple)) else [to]
    kept = [_js.trim(a) for a in listed if isinstance(a, str) and _js.trim(a) != ""]
    if not kept:
        raise ValueError(f"{name}() needs at least one to address")
    return kept


def compose(alert: Alert, *, from_: str, to: list[str], subject_prefix: str | None = None, link: Callable[[Alert], Any] | None = None) -> Email:
    url = _safe_link(link(alert) if link is not None else None)
    # One line: a newline in a subject is a header injection or a rejected send.
    prefix = f"{subject_prefix} " if present(subject_prefix) else ""
    subject = cut(_NEWLINES.sub(" ", f"{prefix}{alert.title}"), 250)
    return Email(from_=str(from_), to=to, subject=subject, text=plain_text(alert, url), html=_html(alert, url))


def escape_html(text: str) -> str:
    """Escapes text for HTML content and double quoted attributes."""
    return str(text).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;").replace("'", "&#39;")


def _safe_link(link: Any) -> str | None:
    """Only http and https links are put in a mail; anything else is dropped."""
    if not present(link):
        return None
    return str(link) if _HTTP.search(str(link)) else None


def _html(alert: Alert, link: str | None) -> str:
    parts = [
        "<!doctype html>",
        '<html><body style="margin:0;padding:16px;font-family:Georgia,serif;color:#1d1b16;background:#ffffff">',
        f'<p style="margin:0 0 12px;font-size:18px"><strong>{escape_html(alert.title)}</strong></p>',
        '<pre style="margin:0 0 12px;padding:12px;background:#f6f3ec;white-space:pre-wrap;word-break:break-word;'
        f'font:13px/1.45 Menlo,Consolas,monospace">{escape_html(alert.message)}</pre>',
    ]
    if present(alert.triage):
        parts.append(f'<p style="margin:0 0 12px"><em>Triage:</em> {escape_html(alert.triage)}</p>')  # type: ignore[arg-type]
    if link:
        parts.append(f'<p style="margin:0"><a href="{escape_html(link)}">Open {escape_html(alert.job)}</a></p>')
    parts.append("</body></html>")
    return "\n".join(parts)


def parse_address(address: str) -> dict[str, str]:
    """Splits "Name <a@b.c>" into its parts, as JSON-ready dicts; a bare address has no name."""
    match = _ADDRESS.search(address)
    if not match:
        return {"email": _js.trim(address)}
    name = _QUOTED.sub(lambda m: m.group(1), match.group(1), count=1)
    return {"email": _js.trim(match.group(2)), "name": name} if name else {"email": _js.trim(match.group(2))}
