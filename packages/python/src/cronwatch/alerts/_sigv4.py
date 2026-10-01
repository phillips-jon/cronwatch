"""AWS Signature Version 4 on hashlib and hmac, for the SES channel
(alerts/sigv4.ts). Spec:
https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv-create-signed-request.html
Checked against the AWS SigV4 test suite (tests/test_channels.py)."""

from __future__ import annotations

import hashlib
import hmac
import re
import urllib.parse
from collections.abc import Mapping

from .. import _js
from ._shared import host_of, present, sha256_hex

__all__ = ["sign"]

_ISO_PUNCTUATION = re.compile(r"[-:]")
_MILLIS = re.compile(r"\.\d{3}")
_UNRESERVED = frozenset(b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")


def sign(
    *,
    method: str,
    url: str,
    headers: Mapping[str, str],
    body: str,
    region: str,
    service: str,
    now: int,
    access_key_id: str,
    secret_access_key: str,
    session_token: str | None = None,
) -> dict[str, str]:
    """Returns the headers to send: the given ones (lowercased) plus
    x-amz-date, the session token when there is one, and authorization. Host
    is signed but not returned; urllib sets it."""
    parts = urllib.parse.urlsplit(url)
    amz_date = _MILLIS.sub("", _ISO_PUNCTUATION.sub("", _js.iso(now)), count=1)
    day = amz_date[:8]
    out: dict[str, str] = {}
    for name, value in headers.items():
        out[name.lower()] = value
    out["x-amz-date"] = amz_date
    if present(session_token):
        out["x-amz-security-token"] = session_token  # type: ignore[assignment]

    signed = {**out, "host": host_of(parts)}
    names = sorted(signed)
    canonical_headers = "".join(f"{n}:{_js.SPACES.sub(' ', _js.trim(signed[n]))}\n" for n in names)
    signed_headers = ";".join(names)
    canonical_request = "\n".join(
        [
            method.upper(),
            _canonical_uri(parts.path),
            _canonical_query(parts.query),
            canonical_headers,
            signed_headers,
            sha256_hex(body),
        ]
    )
    scope = f"{day}/{region}/{service}/aws4_request"
    string_to_sign = "\n".join(["AWS4-HMAC-SHA256", amz_date, scope, sha256_hex(canonical_request)])

    key = _hmac(f"AWS4{secret_access_key}".encode(), day)
    key = _hmac(key, region)
    key = _hmac(key, service)
    key = _hmac(key, "aws4_request")
    signature = hmac.new(key, string_to_sign.encode(), hashlib.sha256).hexdigest()

    out["authorization"] = f"AWS4-HMAC-SHA256 Credential={access_key_id}/{scope}, SignedHeaders={signed_headers}, Signature={signature}"
    return out


def _hmac(key: bytes, data: str) -> bytes:
    return hmac.new(key, _js.well_formed(data).encode("utf-8"), hashlib.sha256).digest()


def _uri_encode(text: str) -> str:
    """RFC 3986 encoding of every byte but the unreserved characters."""
    return "".join(chr(b) if b in _UNRESERVED else f"%{b:02X}" for b in _js.well_formed(text).encode("utf-8"))


def _canonical_uri(path: str) -> str:
    if not path:
        return "/"
    # The path is already encoded once; every AWS service but S3 expects each segment encoded again.
    return "/".join(_uri_encode(segment) for segment in path.split("/"))


def _canonical_query(query: str) -> str:
    """The query as URLSearchParams reads it, each name and value encoded, sorted."""
    if not query:
        return ""
    pairs = [(_uri_encode(name), _uri_encode(value)) for name, value in urllib.parse.parse_qsl(query, keep_blank_values=True)]
    return "&".join(f"{name}={value}" for name, value in sorted(pairs))
