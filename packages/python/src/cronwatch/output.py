"""The output cap, error messages, and secret redaction (output.ts).

Lengths are counted in UTF-16 code units and the redaction patterns match
exactly what the SDK's JavaScript patterns match: ASCII-only case folding
and word boundaries, JavaScript's whitespace class spelled out, and text
outside the Basic Multilingual Plane matched as two code units a character.
"""

from __future__ import annotations

import re
import traceback
from collections.abc import Callable
from typing import Any

from . import _js

#: Output is capped so a chatty job cannot fill the store. The tail is kept.
OUTPUT_CAP = 16 * 1024

REDACTED = "[redacted]"


def strip_nul(text: str) -> str:
    """Removes every U+0000."""
    return text.replace("\x00", "") if "\x00" in text else text


def cap_output(text: str) -> str:
    """NUL characters are removed first, since Postgres refuses them in TEXT
    and JSONB and the whole run row would be lost. The cap then applies to
    what is left."""
    clean = strip_nul(text)
    if _js.length16(clean) <= OUTPUT_CAP:
        return clean
    return "[earlier output trimmed]\n" + _js.tail16(clean, OUTPUT_CAP)


def error_message(error: Any) -> str:
    """ "Name: message" and the first five stack frames, capped like output."""
    return cap_output(describe_error(error))


def _frames(error: BaseException) -> list[str]:
    """The innermost frames first, as a JavaScript stack lists them."""
    frames = traceback.extract_tb(error.__traceback__) if error.__traceback__ else []
    return [f"{f.name} ({f.filename}:{f.lineno})" for f in reversed(frames)]


def is_interruption(error: BaseException) -> bool:
    """An exception that stops the thread rather than reports a problem:
    KeyboardInterrupt, SystemExit, GeneratorExit, asyncio.CancelledError."""
    return not isinstance(error, Exception)


def describe_error(error: Any) -> str:
    if isinstance(error, BaseException):
        name = type(error).__name__
        message = str(error)
        if is_interruption(error):
            header = f"Interrupted: {name}" if message in ("", name) else f"Interrupted: {name}: {message}"
        else:
            header = f"{name}: {message}"
        frames = [f"    at {line}" for line in _frames(error)[:5]]
        return f"{header}\n" + "\n".join(frames) if frames else header
    if isinstance(error, str):
        return error
    try:
        return _js.dumps(error)
    except (TypeError, ValueError, RecursionError):
        return str(error)


def _ci(word: str) -> str:
    """ "secret" as [Ss][Ee][Cc][Rr][Ee][Tt]: ASCII-only case folding, as JavaScript's /i has it here."""
    return "".join(f"[{c.upper()}{c}]" if "a" <= c <= "z" else re.escape(c) for c in word)


_WS = _js.WHITESPACE
_FLAGS = re.ASCII

# Bounded quantifiers throughout, so a long line cannot make these backtrack.
# They apply in this order, each to the text the ones before it left. Each is
# (pattern, how to replace a match).
_Replacement = Callable[[re.Match[str]], str]


def _whole(_m: re.Match[str]) -> str:
    return REDACTED


def _keep_first(m: re.Match[str]) -> str:
    return (m.group(1) or "") + REDACTED


def _keep_quoted(m: re.Match[str]) -> str:
    quote = m.group(2) or m.group(3) or ""
    return f"{m.group(1)}{quote}{REDACTED}{quote}"


def _keep_url(m: re.Match[str]) -> str:
    return f"{m.group(1)}{REDACTED}@"


_NAMES = "|".join(
    [
        _ci("secret"),
        _ci("token"),
        f"{_ci('passw')}(?:{_ci('or')})?{_ci('d')}",
        _ci("pwd"),
        f"{_ci('api')}[_-]?{_ci('key')}",
        f"{_ci('access')}[_-]?{_ci('key')}",
        f"{_ci('private')}[_-]?{_ci('key')}",
        _ci("credential"),
    ]
)
_ASSIGN = "(?:=>|[=:])"

SECRET_PATTERNS: list[tuple[re.Pattern[str], _Replacement]] = [
    # A PEM private key, header to footer. Without a footer (the output was
    # trimmed) it runs to the end of the base64 body. A "-" that starts five
    # dashes ends the body, so the footer is never swallowed into it.
    (
        re.compile(
            f"-----BEGIN (?:[A-Z0-9]{{1,20}} ){{0,3}}PRIVATE KEY-----(?:[A-Za-z0-9+/={_WS},:]|-(?!----)){{0,16384}}"
            "(?:-----END (?:[A-Z0-9]{1,20} ){0,3}PRIVATE KEY-----)?",
            _FLAGS,
        ),
        _whole,
    ),
    # password=..., API_KEY: ..., "client_secret": "...", TOKEN='...', token=...,
    # :password=>"..." (but not max_tokens: 800). A quoted value is blanked to
    # its closing quote, spaces and all, and keeps its quotes.
    (
        re.compile(
            f"\\b([A-Za-z0-9_-]{{0,40}}(?:{_NAMES})[A-Za-z0-9_-]{{0,40}}(?<![Tt][Oo][Kk][Ee][Nn][Ss])\"?[{_WS}]{{0,3}}{_ASSIGN}[{_WS}]{{0,3}})"
            f"(?:(\")[^\"\\n]{{1,4096}}\"|(')[^'\\n]{{1,4096}}'|[\"']?[^{_WS}\"',;&]{{1,4096}})",
            _FLAGS,
        ),
        _keep_quoted,
    ),
    # Authorization: Basic <base64> and Authorization: Token <token>, also as a JSON or hash entry.
    (
        re.compile(
            f"\\b((?:{_ci('proxy-')})?{_ci('authorization')}[\"']?[{_WS}]{{0,3}}{_ASSIGN}[{_WS}]{{0,3}}[\"']?[{_WS}]{{0,3}}"
            f"(?:{_ci('basic')}|{_ci('token')})[{_WS}]{{1,3}})[A-Za-z0-9._~+/=:-]{{1,4096}}",
            _FLAGS,
        ),
        _keep_first,
    ),
    # Credentials inside a URL: postgres://user:password@host. The password
    # runs to the last "@" before a "/" or a space, so one that contains "@"
    # is blanked whole.
    (re.compile(f"(\\b[A-Za-z][A-Za-z0-9+.-]{{0,30}}://[^{_WS}/:@]{{0,256}}:)[^{_WS}/]{{1,256}}@", _FLAGS), _keep_url),
    # Authorization: Bearer <token>
    (re.compile(f"\\b(Bearer[{_WS}]{{1,3}})[A-Za-z0-9._~+/=-]{{8,4096}}", _FLAGS), _keep_first),
    # A bare JWT: three base64url segments, the first starting eyJ.
    (re.compile(r"\beyJ[A-Za-z0-9_-]{4,4096}\.[A-Za-z0-9_-]{4,4096}\.[A-Za-z0-9_-]{0,4096}", _FLAGS), _whole),
    # Incoming webhook URLs carry their secret in the path.
    (
        re.compile(f"(\\b{_ci('hooks.slack.com')}/(?:{_ci('services')}|{_ci('workflows')}|{_ci('triggers')})/)[A-Za-z0-9/_-]{{1,255}}", _FLAGS),
        _keep_first,
    ),
    (
        re.compile(
            f"(\\b{_ci('discord')}(?:{_ci('app')})?{_ci('.com/api/')}(?:[Vv][0-9]{{1,2}}/)?{_ci('webhooks/')})[A-Za-z0-9/_-]{{1,255}}",
            _FLAGS,
        ),
        _keep_first,
    ),
    # Well-known token shapes: AWS, GitHub, Slack, Stripe, Anthropic, OpenAI and Google style keys.
    (re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b", _FLAGS), _whole),
    (re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{30,255}|github_pat_[A-Za-z0-9_]{20,255})\b", _FLAGS), _whole),
    (re.compile(r"\bxox[abposr]-[A-Za-z0-9-]{10,255}", _FLAGS), _whole),
    (re.compile(r"\b[rsp]k_(?:live|test)_[A-Za-z0-9]{10,255}\b", _FLAGS), _whole),
    (re.compile(r"\bwhsec_[A-Za-z0-9+/=]{16,255}", _FLAGS), _whole),
    (re.compile(r"\bsk-[A-Za-z0-9_-]{20,255}", _FLAGS), _whole),
    (re.compile(r"\bAIza[0-9A-Za-z_-]{35}(?![0-9A-Za-z_-])", _FLAGS), _whole),
]


def _to_units(text: str) -> str:
    """Each character outside the BMP written as its two UTF-16 surrogates,
    as JavaScript's patterns (no u flag) see it: two characters to a negated
    class and to a bounded quantifier."""
    out = []
    for c in text:
        code = ord(c)
        if code > 0xFFFF:
            code -= 0x10000
            out.append(chr(0xD800 + (code >> 10)))
            out.append(chr(0xDC00 + (code & 0x3FF)))
        else:
            out.append(c)
    return "".join(out)


def _from_units(text: str) -> str:
    """Surrogate pairs put back together; a surrogate a replacement cut from
    its partner becomes U+FFFD, as it would once written out as UTF-8."""
    return text.encode("utf-16-le", "surrogatepass").decode("utf-16-le", "replace")


def redact_secrets(text: str) -> str:
    """The default ``redact``: blanks values that look like secrets (key=value
    pairs with secret-ish names, Authorization headers, URL credentials, bearer
    tokens, JWTs, PEM private keys, webhook URLs and well-known token formats)
    before output or an error is stored, shown or sent anywhere. Matches
    exactly what the SDK's redactSecrets matches."""
    astral = not text.isascii() and any(ord(c) > 0xFFFF for c in text)
    out = _to_units(text) if astral else text
    for pattern, replace in SECRET_PATTERNS:
        out = pattern.sub(replace, out)
    return _from_units(out) if astral else out
