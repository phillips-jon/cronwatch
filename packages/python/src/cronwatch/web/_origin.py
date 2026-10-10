"""Origins read as the SDK's `new URL(value).origin` reads them: whitespace
around the value and tabs or line breaks in it are dropped, slashes after the
scheme may be missing or backslashes, credentials are ignored, the host is
lowercased (percent escapes decoded, IPv4 numbers written out, IPv6
compressed, a non-ASCII host converted to punycode) and a default port is
left out."""

from __future__ import annotations

import ipaddress
import re
from urllib.parse import unquote_to_bytes

from .. import _js

__all__ = ["ABSOLUTE", "DEFAULT_PORTS", "InvalidOrigin", "NOT_HTTP", "bare", "parse", "read"]

ABSOLUTE = 'routes: origin must be an absolute URL such as "https://app.example.com", got {}'
NOT_HTTP = "routes: origin must be http or https, got {}"
DEFAULT_PORTS = {"http": 80, "https": 443}

_SCHEME = re.compile(r"([A-Za-z][A-Za-z0-9+.\-]*):(.*)\Z", re.DOTALL)
_FORBIDDEN_HOST = re.compile(r"[\x00-\x20#%/:<>?@\[\\\]^|\x7f]")
_EDGES = re.compile(r"\A[\x00-\x20]+|[\x00-\x20]+\Z")
_DIGITS = re.compile(r"[0-9]+\Z")
_HEX = re.compile(r"0[xX][0-9A-Fa-f]*\Z")
_OCTAL = re.compile(r"0[0-7]+\Z")


class InvalidOrigin(ValueError):
    """The value is not an absolute http or https URL."""


def parse(value: object) -> str | None:
    """The `origin` option as scheme://host[:port], or None for None or "".
    Raises ValueError with the SDK's message otherwise, so a typo fails at startup."""
    if value is None or value == "":
        return None
    if not isinstance(value, str):
        raise ValueError(ABSOLUTE.format(_shown(value)))
    try:
        origin, _ = read(value)
    except _NotHttp:
        raise ValueError(NOT_HTTP.format(_js.dumps(value))) from None
    except InvalidOrigin:
        raise ValueError(ABSOLUTE.format(_js.dumps(value))) from None
    return origin


def bare(value: str) -> str | None:
    """scheme://host[:port] for text that is a scheme and a bare host (what
    trust_proxy builds from the forwarded headers), or None when it carries a
    path, credentials, a query, or a fragment, or is not an http or https URL."""
    try:
        origin, extra = read(value)
    except (InvalidOrigin, _NotHttp):
        return None
    return None if extra else origin


class _NotHttp(Exception):
    pass


def _shown(value: object) -> str:
    try:
        return _js.dumps(value)
    except TypeError:
        return repr(value)


def read(value: str) -> tuple[str, bool]:
    """(origin, whether anything past the host would show in the URL: a path
    other than "/", credentials, a query, or a fragment). Raises InvalidOrigin
    for anything that is not one, never another error."""
    try:
        return _read(value)
    except (InvalidOrigin, _NotHttp):
        raise
    except ValueError:  # a conversion this parser did not foresee
        raise InvalidOrigin from None


def _read(value: str) -> tuple[str, bool]:
    text = _EDGES.sub("", value).replace("\t", "").replace("\n", "").replace("\r", "")
    match = _SCHEME.match(text)
    if not match:
        raise InvalidOrigin
    scheme = match.group(1).lower()
    if scheme not in DEFAULT_PORTS:
        raise _NotHttp
    rest = match.group(2).lstrip("/\\")
    end = len(rest)
    for stop in "/\\?#":
        found = rest.find(stop)
        if found != -1:
            end = min(end, found)
    authority, after = rest[:end], rest[end:]
    userinfo, at, hostport = authority.rpartition("@")
    host, port = _split_port(hostport if at else authority)
    host = _read_host(host)
    shown_port = "" if port is None or port == DEFAULT_PORTS[scheme] else f":{port}"
    extra = bool(at and userinfo not in ("", ":")) or _past_host(after)
    return f"{scheme}://{host}{shown_port}", extra


def _past_host(after: str) -> bool:
    path, _, fragment = after.partition("#")
    path, question, query = path.partition("?")
    return path not in ("", "/", "\\") or query != "" or fragment != ""


def _split_port(authority: str) -> tuple[str, int | None]:
    if authority.startswith("["):
        close = authority.find("]")
        if close == -1:
            raise InvalidOrigin
        host, rest = authority[: close + 1], authority[close + 1 :]
    else:
        host, colon, rest = authority.rpartition(":")
        if not colon:
            host, rest = rest, ""
        else:
            rest = ":" + rest
    if rest in ("", ":"):
        return host, None
    if not rest.startswith(":") or not _DIGITS.match(rest[1:]):
        raise InvalidOrigin
    # Leading zeros are allowed; past them, more than five digits is no port
    # (and Python will not read a decimal of more than 4300 digits at all).
    digits = rest[1:].lstrip("0") or "0"
    if len(digits) > 5 or int(digits) > 65_535:
        raise InvalidOrigin
    port = int(digits)
    return host, port


def _read_host(host: str) -> str:
    if host == "":
        raise InvalidOrigin
    if host.startswith("["):
        if not host.endswith("]") or "%" in host:
            raise InvalidOrigin
        try:
            address = ipaddress.IPv6Address(host[1:-1])
        except ValueError:
            raise InvalidOrigin from None
        return f"[{address.compressed}]"
    try:
        decoded = unquote_to_bytes(host).decode("utf-8")
    except UnicodeDecodeError:
        raise InvalidOrigin from None
    if not decoded.isascii():
        try:
            decoded = decoded.encode("idna").decode("ascii")
        except UnicodeError:
            raise InvalidOrigin from None
    decoded = decoded.lower()
    if decoded == "" or _FORBIDDEN_HOST.search(decoded):
        raise InvalidOrigin
    return _ipv4(decoded) or decoded


def _ipv4(host: str) -> str | None:
    """WHATWG's IPv4 parser, for a host whose last label is a number: "127.1"
    and "0x7f.1" are 127.0.0.1. None for a host that is a name."""
    parts = host.split(".")
    if len(parts) > 1 and parts[-1] == "":
        parts.pop()
    if not (_DIGITS.match(parts[-1]) or _HEX.match(parts[-1])):
        return None
    if len(parts) > 4:
        raise InvalidOrigin
    numbers = [_number(part) for part in parts]
    last = numbers.pop()
    if any(n > 255 for n in numbers) or last >= 256 ** (4 - len(numbers)):
        raise InvalidOrigin
    address = sum(n * 256 ** (3 - i) for i, n in enumerate(numbers)) + last
    return ".".join(str((address >> shift) & 255) for shift in (24, 16, 8, 0))


def _number(part: str) -> int:
    if part == "":
        raise InvalidOrigin
    # Read without leading zeros, and a decimal of more than ten digits (past
    # any address, and past the 4300 digits Python will read) as too large.
    if _HEX.match(part):
        return int(part[2:].lstrip("0") or "0", 16)
    if _OCTAL.match(part):
        return int(part.lstrip("0") or "0", 8)
    if _DIGITS.match(part) and (part == "0" or not part.startswith("0")):
        return int(part) if len(part) <= 10 else 2**40
    raise InvalidOrigin
