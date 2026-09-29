"""Alert titles and messages, character for character as format.ts writes them."""

from __future__ import annotations

import re

from . import _js
from .duration import beyond_dates, format_duration, format_relative, iso_time
from .evaluate import format_number
from .types import Alert, AlertDraft, AlertType, JobDefinition

_NAMED = re.compile(r"[A-Za-z_$][A-Za-z0-9_$]*: ", re.ASCII)


def _when(at: int | None, now: int) -> str:
    if at is None:
        return "never"
    iso = iso_time(at)
    if iso is None:
        return beyond_dates(at)
    return f"{iso.replace('T', ' ', 1)[:19]} UTC ({format_relative(at, now)})"


def _first_lines(text: str | None, n: int) -> str:
    if not text:
        return ""
    return "\n".join(text.split("\n")[:n])


def _tail(text: str | None, n: int) -> str:
    if not text:
        return ""
    lines = _js.trim_end(text).split("\n")
    return "\n".join(lines[max(0, len(lines) - n) :])


def _error_line(error: str) -> str:
    """ "Error: x" for a bare message, but not "Error: TypeError: x" for one that already names itself."""
    text = _first_lines(error, 4)
    return text if _NAMED.match(text) else f"Error: {text}"


def _text(value: object) -> str:
    """A value as a template literal writes it: undefined for a missing one."""
    if value is None:
        return "undefined"
    if _js.is_number(value):
        return _js.number(value)
    return str(value)


def compose_alert(draft: AlertDraft, definition: JobDefinition, now: int) -> Alert:
    """Turns a draft into the title and message every channel shows."""
    name = definition.name
    run = draft.run
    details = draft.details
    lines: list[str] = []

    if draft.type == AlertType.MISSED:
        title = f"{name} missed its scheduled run"
        lines.append(
            f"Due {_when(details['due_at'], now)}, and no run had started by {_when(details['deadline'], now)} (grace {format_duration(details['grace_ms'])})."
        )
        zone = f" ({definition.timezone})" if definition.timezone else ""
        lines.append(f"Schedule: {_text(definition.schedule)}{zone}.")
        lines.append(f"Last run: {f'{run.status} {_when(run.started_at, now)}' if run else 'never'}.")
    elif draft.type == AlertType.FAILED:
        title = f"{name} failed"
        n = details["consecutive_failures"]
        if n > 1:
            lines.append(f"{_js.number(n)} consecutive failures.")
        if run:
            ran = f", ran {format_duration(run.duration_ms)}" if run.duration_ms is not None else ""
            lines.append(f"Started {_when(run.started_at, now)}{ran}.")
            if run.error:
                lines.append(_error_line(run.error))
            out = _tail(run.output, 8)
            if out:
                lines.append(f"Output (tail):\n{out}")
    elif draft.type == AlertType.STUCK:
        title = f"{name} is stuck"
        if run:
            took = run.duration_ms if run.duration_ms is not None else now - run.started_at
            lines.append(f"Started {_when(run.started_at, now)} and never reported finishing. Marked as timed out after {format_duration(took)}.")
            out = _tail(run.output, 8)
            if out:
                lines.append(f"Output so far (tail):\n{out}")
        lines.append("If the process was killed mid-run (a serverless timeout, a deploy), this is what that looks like.")
    elif draft.type == AlertType.SLOW:
        title = f"{name} was slow"
        lines.append(f"Took {format_duration(details['duration_ms'])}; the limit is {format_duration(details['threshold_ms'])} ({details['basis']}).")
        if run:
            lines.append(f"Started {_when(run.started_at, now)}.")
    elif draft.type == AlertType.OVER_BUDGET:
        title = f"{name} went over budget"
        for b in details["breaches"]:
            lines.append(f"{b['metric']}: {format_number(b['value'])}, limit {format_number(b['limit'])} ({b['basis']}).")
        if run:
            lines.append(f"Started {_when(run.started_at, now)}.")
    elif draft.type == AlertType.RECOVERED:
        if details.get("reason") == "unscheduled":
            title = f"{name} is no longer scheduled"
            prefix = f"Missed since {_when(details['since'], now)}. " if "since" in details else ""
            lines.append(f"{prefix}It has no schedule now, so nothing is due; the missed alert is closed.")
        else:
            title = f"{name} recovered"
            after = ", ".join(str(c).replace("_", " ", 1) for c in details["after"])
            lines.append(f"A run {_when(run.started_at, now) if run else 'just now'} succeeded{f' after: {after}' if after else ''}.")
            if run is not None and run.duration_ms is not None:
                lines.append(f"Ran {format_duration(run.duration_ms)}.")
    else:
        raise ValueError(f"unknown alert type {draft.type!r}")

    return Alert(
        type=draft.type,
        run=run,
        details=details,
        job=name,
        definition=definition,
        title=title,
        message="\n".join(lines),
        at=now,
    )
