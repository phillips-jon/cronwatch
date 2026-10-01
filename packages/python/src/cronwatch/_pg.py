"""Opening a psycopg connection from a connection string without letting
the string's secrets into an error: libpq quotes the part it could not read,
which for a password with a stray "%" is the password itself, and that error
goes to on_error and the "cronwatch" logger on every check and every run."""

from __future__ import annotations

import re
from typing import Any
from urllib.parse import urlsplit

__all__ = ["connect"]


def connect(psycopg: Any, conninfo: str, **kwargs: Any) -> Any:
    """psycopg.connect(conninfo, **kwargs). A string psycopg cannot read raises
    an error naming only its host; an error connecting keeps libpq's text with
    the password, if it shows there, blanked."""
    try:
        psycopg.conninfo.conninfo_to_dict(conninfo)
    except Exception:  # noqa: BLE001, libpq's text quotes the token it could not read
        raise psycopg.ProgrammingError(
            f"cronwatch: the Postgres connection string for {_host(conninfo)} could not be read; "
            "check that any % in its user name or password is written as %25"
        ) from None
    try:
        return psycopg.connect(conninfo, **kwargs)
    except psycopg.Error as error:
        password = _password(psycopg, conninfo)
        text = str(error)
        if password and password in text:
            raise type(error)(text.replace(password, "***")) from None
        raise


def _host(conninfo: str) -> str:
    """The host a connection string names, as well as it can be read, for an error."""
    host: str | None = None
    try:
        if "://" in conninfo:
            host = urlsplit(conninfo).hostname
        else:
            match = re.search(r"(?:^|\s)host\s*=\s*'?([^\s']+)", conninfo)
            host = match.group(1) if match else None
    except ValueError:
        host = None
    return f'"{host}"' if host else "the default host"


def _password(psycopg: Any, conninfo: str) -> str | None:
    try:
        value = psycopg.conninfo.conninfo_to_dict(conninfo).get("password")
    except Exception:  # noqa: BLE001
        return None
    return value if isinstance(value, str) and value else None
