"""The dashboard as a Django view: a Django request read into the routes'
Request, and their Response written back, bytes and headers as they are."""

from __future__ import annotations

from django.http import HttpRequest, HttpResponse, RawPostDataException
from django.views.decorators.csrf import csrf_exempt

from .._deprecated import names as _deprecated_names
from ..web import Request, Response, _request_path, _url_origin
from . import routes

__all__ = ["dashboard"]


@csrf_exempt
def dashboard(request: HttpRequest, path: str = "") -> HttpResponse:
    """Every URL under the dashboard's prefix. Exempt from Django's CSRF
    middleware, since the forms carry no Django token: the routes refuse a
    cross-site write themselves (Origin and Sec-Fetch-Site, as the SDK does)."""
    return _to_django(routes().handle(_from_django(request, path)))


def _from_django(request: HttpRequest, path: str = "") -> Request:
    """A Django request as the routes read it. `path` is what the URL pattern
    matched after the prefix, so the prefix is the mount point."""
    full = request.path
    mount = full[: len(full) - len(path)] if path and full.endswith(path) else full
    meta = request.META
    scope = getattr(request, "scope", None)
    raw: list[str | None] = [meta.get("RAW_URI"), meta.get("REQUEST_URI")]
    if isinstance(scope, dict) and scope.get("raw_path"):
        raw.append(scope["raw_path"].decode("latin-1"))
    try:
        body: bytes = request.body
        form = None
    except RawPostDataException:
        # Something read the form from the stream first; its fields are still here.
        body, form = b"", request.POST
    return Request(
        method=request.method or "GET",
        path=_request_path(full.encode("utf-8", "surrogateescape"), *raw),
        query=meta.get("QUERY_STRING", ""),
        headers={name.lower(): value for name, value in request.headers.items()},
        body=body,
        origin=_url_origin(request.scheme or "http", request.get_host()),
        mount=mount.rstrip("/"),
        form=form,
    )


def _to_django(response: Response) -> HttpResponse:
    out = HttpResponse(response.body, status=response.status)
    if "content-type" not in response.headers:
        del out["Content-Type"]
    for name, value in response.headers.items():
        out[name] = value
    return out


#: Names 1.0 made internal, still answering under their old names (each
#: warning, until 2.0).
__getattr__ = _deprecated_names(__name__, globals(), {"from_django": "_from_django", "to_django": "_to_django"})
