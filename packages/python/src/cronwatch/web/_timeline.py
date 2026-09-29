"""The dashboard's timelines, markup for markup the SDK's routes/timeline.ts:
one lane per job (or per day, on a job's page), drawn on the server as
inline SVG so the page needs no script.

Every time a job was due is a faint tick, worked out from its schedule with
the same functions the checks use (fires_between and expectation), so the
lane shows the cadence the job is meant to keep. Every run it recorded is a
solid mark on top, as wide as it took and coloured by how it ended. A slot
the check has reported missed is a dashed box. The empty part of a lane
carries a short note about anything open, and a visually hidden list says the
same things in words.

Every time is UTC: without script the page cannot know the viewer's zone.
"""

from __future__ import annotations

import math
import re
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from typing import Any, TypeVar

from .. import _js
from ..duration import FIRST_DATE_MS, LAST_DATE_MS, format_duration
from ..evaluate import grace_ms, is_stuck, timeout_ms
from ..schedule import ParsedSchedule, expectation, fires_between, parse_schedule
from ..types import JobSummary, Run
from ._escape import encode_uri_component, entries, h, name_html, text, to_fixed, truthy

HOUR = 3_600_000
DAY = 24 * HOUR

#: The board's span: the last day, plus a few hours ahead so what is due soon shows.
BOARD_BEHIND_MS = DAY
BOARD_AHEAD_MS = 3 * HOUR
#: How many jobs the board's timeline draws. The table below it lists every job.
BOARD_LANES = 30
#: Runs read for a lane when the twenty the table reads start inside the span,
#: so a frequent job's lane is not cut short. Older runs than this are shown
#: as not loaded rather than as absent.
BOARD_RUNS = 200
#: How many days a job's page draws.
WEEK_DAYS = 7

#: Width of a lane in SVG units. Lanes stretch to fit, so strokes do not scale.
W = 1000
#: A lane with more due times than this shows its cadence as a dotted line instead.
MAX_TICKS = 330
#: More missed slots than this are drawn as one dashed band.
MAX_BOXES = 8
#: The narrowest a missed box is drawn, in SVG units.
MIN_BOX = 10

MONTHS = ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")
WEEKDAYS = ("Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat")
STATE_CLASS = {"healthy": "ok", "late": "warn", "failing": "bad", "stuck": "bad", "silenced": "muted", "never_ran": "muted"}

_QUIET_NOTE = re.compile(r"(?:due |failed at|timed out)")

T = TypeVar("T")


@dataclass
class LaneInput:
    """What one lane is drawn from: the job, its runs (any order; only those
    overlapping the span are drawn), and whether older runs exist that were
    not read (the lane then says so before its oldest run)."""

    job: JobSummary
    runs: Sequence[Run]
    complete: bool


@dataclass
class DueTimes:
    #: Every time the job was or will be due within the span, ascending.
    times: list[int]
    #: True when there are too many to draw one by one; `times` is then empty.
    dense: bool


@dataclass
class Span:
    """The stretch of time a timeline draws, and the moment it was drawn."""

    start: int
    end: int
    now: int


@dataclass
class _LaneParts:
    svg: str
    note: str
    words: str


def f(n: float) -> str:
    """toFixed(1)."""
    return to_fixed(n, 1)


def _delay(x: float, base: float = 80, per_unit: float = 0.75) -> str:
    """Animation delay for a mark at x, so marks arrive in time order, left to right."""
    return f"--d:{_js.number(_js.js_round(base + max(0, x) * per_unit))}ms"


def _date(t: float) -> tuple[int, int, int, int]:
    """(year, month 1 to 12, day, weekday 0 for Sunday) of a UTC instant, as new Date(t) reads it."""
    days = math.floor(math.trunc(t) / DAY)
    year, month, day = _js.civil_from_days(days)
    return year, month, day, (days + 4) % 7


def clock(t: float) -> str:
    """ "22:42", in UTC."""
    return _js.iso(math.trunc(t))[11:16]


def day_label(t: float) -> str:
    """ "Sat 26 Sep", in UTC."""
    _, month, day, weekday = _date(t)
    return f"{WEEKDAYS[weekday]} {day} {MONTHS[month - 1]}"


def when(t: float, now: float) -> str:
    """ "22:42" on the same UTC day as `now`, otherwise "25 Sep 22:42", and
    "1 Jan 0001 02:00" in another UTC year. A time before the year 1 or after
    9999 (a start read from a foreign or damaged row) is "before 1 Jan 0001
    00:00" or "after 31 Dec 9999 23:59"."""
    if t > LAST_DATE_MS:
        return "after 31 Dec 9999 23:59"
    if not t >= FIRST_DATE_MS:
        return "before 1 Jan 0001 00:00"
    if math.floor(t / DAY) == math.floor(now / DAY):
        return clock(t)
    year, month, day, _ = _date(t)
    other = "" if year == _date(now)[0] else f" {year:04d}"
    return f"{day} {MONTHS[month - 1]}{other} {clock(t)}"


def parsed_schedule(job: JobSummary) -> ParsedSchedule | None:
    """The job's schedule, parsed, or None when it has none or it no longer parses."""
    schedule = job.definition.schedule
    if not truthy(schedule):
        return None
    try:
        return parse_schedule(schedule, job.definition.timezone)
    except Exception:
        return None


def _safely(fn: Callable[[], T], fallback: T) -> T:
    try:
        return fn()
    except Exception:
        return fallback


def _is_open(job: JobSummary, condition: str) -> bool:
    return any(str(c) == condition for c in job.open)


def due_times(job: JobSummary, parsed: ParsedSchedule | None, runs: Sequence[Run], start: int, end: int) -> DueTimes:
    """When the job was due within `start` to `end`. A cron's fires come from
    fires_between. An interval is due one period after each run started, and
    after the last run once a period for as long as nothing runs (the times a
    missed interval job keeps being asked for); with no run yet, from its
    next expected time."""
    if parsed is None:
        return DueTimes([], False)
    if parsed.kind == "interval":
        every = parsed.every_ms
        assert every is not None
        if (end - start) / every > MAX_TICKS:
            return DueTimes([], True)
        starts = sorted(r.started_at for r in runs)
        times: set[Any] = set()
        for begun in starts:
            t = begun + every
            if start <= t <= end:
                times.add(t)
        due: Any = starts[-1] + every if starts else job.next_expected_at
        if due is not None:
            if due < start:
                due += math.ceil((start - due) / every) * every
            while due <= end:
                times.add(due)
                due += every
        return DueTimes(sorted(times), False)
    nothing: list[int] | None = []
    fires = _safely(lambda: fires_between(parsed, start - 1, end, MAX_TICKS), nothing)
    return DueTimes([], True) if fires is None else DueTimes(fires, False)


def missed_at(job: JobSummary, parsed: ParsedSchedule | None, times: Sequence[int], now: int) -> int | None:
    """The slot a missed job was due at, the one the check reported: the first
    fire its last run does not cover (expectation(), as on_check works it
    out). A job that never ran has no run to count from, so the latest due
    time whose grace has passed stands in. None when missed is not open."""
    if parsed is None or not _is_open(job, "missed"):
        return None
    grace = _safely(lambda: grace_ms(job.definition), 0.0)
    last = job.last_run.started_at if job.last_run is not None else None
    if last is not None:

        def expected() -> int | None:
            found = expectation(parsed, last, last, grace)
            return None if found is None else found.due_at

        return _safely(expected, None)
    past = [t for t in times if t + grace < now]
    return past[-1] if past else None


def _tone_of(run: Run, job: JobSummary, now: int) -> str:
    status = str(run.status)
    if status == "running":
        return "stuck" if _safely(lambda: is_stuck(job.definition, run, now), False) else "running"
    if status == "failed":
        return "bad"
    if status == "timeout":
        return "timeout"
    latest = job.last_run is not None and job.last_run.id == run.id
    return "warn" if latest and (_is_open(job, "over_budget") or _is_open(job, "slow")) else "ok"


def _timeout_text(job: JobSummary) -> str:
    return _safely(lambda: format_duration(timeout_ms(job.definition)), "configured")


def _describe_run(run: Run, tone: str, job: JobSummary, now: int) -> str:
    """One run, as its tooltip says it."""
    at = f"{when(run.started_at, now)} UTC"
    if tone == "running":
        return f"running since {at}, {format_duration(now - run.started_at)} so far"
    if tone == "stuck":
        return f"running since {at}, past its {_timeout_text(job)} timeout"
    took = "" if run.duration_ms is None else f", took {format_duration(run.duration_ms)}"
    extra = (", over budget" if _is_open(job, "over_budget") else ", slow") if tone == "warn" else ""
    return f"{run.status} at {at}{took}{extra}"


def _over_ceilings(job: JobSummary) -> list[str]:
    """The metrics of the job's last run that went over their ceilings."""
    metrics = job.last_run.metrics if job.last_run is not None else {}
    over = []
    for key, limit in entries(job.definition.budget):
        value = metrics.get(key)
        if (-math.inf if value is None else value) > limit:
            over.append(key)
    return over


def lane_note(job: JobSummary, missed: int | None, now: int) -> str | None:
    """What is worth saying about the job in a few words, or None when all is well."""
    last = job.last_run
    status = str(last.status) if last is not None else None
    if job.silenced_until is not None and job.silenced_until > now:
        return f"silenced until {when(job.silenced_until, now)}"
    if _is_open(job, "missed"):
        return "overdue, nothing ran" if missed is None else f"due {when(missed, now)}, nothing ran"
    if last is not None and status == "running":
        stuck = _safely(lambda: is_stuck(job.definition, last, now), False)
        since = f"running since {when(last.started_at, now)}"
        return f"{since}, past its {_timeout_text(job)} timeout" if stuck else since
    if last is not None and status == "failed":
        row = f", {job.consecutive_failures} in a row" if job.consecutive_failures > 1 else ""
        return f"failed at {when(last.started_at, now)}{row}"
    if last is not None and status == "timeout":
        return f"timed out at {when(last.started_at, now)}"
    if _is_open(job, "stuck"):
        return "stuck"
    if _is_open(job, "over_budget") and last is not None:
        over = _over_ceilings(job)
        return f"went over budget{' on ' + ' and '.join(over) if over else ''} at {when(last.started_at, now)}"
    if _is_open(job, "slow") and last is not None and last.duration_ms is not None:
        return f"slow: took {format_duration(last.duration_ms)}"
    if _is_open(job, "failed"):
        return "failing"
    if last is None and job.next_expected_at is not None:
        return f"no runs yet, first due {when(job.next_expected_at, now)}"
    return None


def _lane(lane_input: LaneInput, span: Span, *, now_in_lane: bool, label: str) -> _LaneParts:
    job = lane_input.job
    start, end, now = span.start, span.end, span.now

    def x(t: float) -> float:
        return min(W, max(0, ((t - start) / (end - start)) * W))

    parsed = parsed_schedule(job)
    due = due_times(job, parsed, lane_input.runs, start, end)
    missed = missed_at(job, parsed, due.times, now)
    grace = _safely(lambda: grace_ms(job.definition), 0.0)
    name = label
    busy: list[tuple[float, float]] = []
    inside = now_in_lane and start < now < end

    s = f'<svg class="marks" viewBox="0 0 {W} 24" preserveAspectRatio="none" aria-hidden="true" focusable="false">'
    if inside:
        s += f'<rect class="ahead" x="{f(x(now))}" y="0" width="{f(W - x(now))}" height="24"/>'
    s += f'<line class="base" x1="0" y1="12" x2="{W}" y2="12"/>'

    in_span = sorted(
        (r for r in lane_input.runs if r.started_at <= end and (now if r.finished_at is None else r.finished_at) >= start),
        key=lambda r: r.started_at,
    )
    if not lane_input.complete and lane_input.runs:
        oldest = min(r.started_at for r in lane_input.runs)
        if oldest > start:
            title = h(f"{name}: runs before {when(oldest, now)} UTC are not loaded here")
            s += f'<rect class="unloaded" x="0" y="4" width="{f(x(oldest))}" height="16"><title>{title}</title></rect>'

    if due.dense:
        title = h(f"{name}: due {text(job.definition.schedule)}, too often to mark each time")
        s += f'<line class="cadence" x1="0" y1="12" x2="{W}" y2="12"><title>{title}</title></line>'
    for t in due.times:
        tx = x(t)
        ahead = " ahead" if t > now else ""
        s += f'<line class="tick{ahead}" x1="{f(tx)}" y1="6" x2="{f(tx)}" y2="18" style="{_delay(tx, 0, 0.45)}"/>'

    # Missed slots: the reported one and every later one whose grace has run out.
    if missed is not None and missed <= end:
        slots = [] if due.dense else [t for t in due.times if t >= missed and t + grace < now]
        if missed not in slots and missed >= start:
            slots.insert(0, missed)
        several = f" ({len(slots)} slots in this span)" if len(slots) > 1 else ""
        title = h(f"{name}: due {when(missed, now)} UTC, nothing started{several}")
        if due.dense or len(slots) > MAX_BOXES:
            x1 = x(max(missed, start))
            x2 = max(x(now), x1 + MIN_BOX)
            s += f'<rect class="missed" x="{f(x1)}" y="5" width="{f(x2 - x1)}" height="14" style="{_delay(x1)}"><title>{title}</title></rect>'
            busy.append((x1, x2))
        else:
            for t in slots:
                if t < start:
                    continue
                x1 = x(t)
                width = max(x(t + grace) - x1, MIN_BOX)
                s += f'<rect class="missed" x="{f(x1)}" y="5" width="{f(width)}" height="14" style="{_delay(x1)}"><title>{title}</title></rect>'
                busy.append((x1, x1 + width))

    for run in in_span:
        tone = _tone_of(run, job, now)
        # A zero-width rect is not drawn at all; its stroke gives short runs their width.
        x1 = x(run.started_at)
        x2 = max(x(now if run.finished_at is None else run.finished_at), x1 + 0.5)
        title = h(f"{name}: {_describe_run(run, tone, job, now)}")
        s += f'<rect class="run {tone}" x="{f(x1)}" y="5" width="{f(x2 - x1)}" height="14" style="{_delay(x1)}"><title>{title}</title></rect>'
        busy.append((x1, x2))

    if inside:
        s += f'<line class="nowline" x1="{f(x(now))}" y1="0" x2="{f(x(now))}" y2="24"/>'
    s += "</svg>"

    # The note goes wherever the lane is actually empty, so it never sits on
    # the marks it describes; it is cut short with an ellipsis when narrow.
    note_text = lane_note(job, missed, now)
    note = ""
    if note_text:
        now_x = x(now)
        lo = min(b[0] for b in busy) if busy else now_x
        hi = max(b[1] for b in busy) if busy else now_x
        right = W - hi >= lo
        room = W - hi if right else lo
        if room > 90:
            edge = hi + 14 if right else lo - 14
            place = f"left:{f(edge / 10)}%" if right else f"right:{f(100 - edge / 10)}%"
            before = "" if right else " before"
            note = f'<span class="note{before}" style="{place};max-width:{f((room - 18) / 10)}%">{h(note_text)}</span>'

    return _LaneParts(s, note, _words(job, in_span, due, missed, span, note_text))


def _words(job: JobSummary, runs: Sequence[Run], due: DueTimes, missed: int | None, span: Span, note: str | None) -> str:
    """The lane in words, for anyone who cannot see it."""
    parts: list[str] = []
    if due.dense:
        parts.append(f"due {text(job.definition.schedule)}")
    elif truthy(job.definition.schedule):
        n = sum(1 for t in due.times if t <= span.now)
        parts.append(f"due {'no times' if n == 0 else 'once' if n == 1 else f'{n} times'} so far")
    ok = sum(1 for r in runs if str(r.status) == "ok")
    if not runs:
        summary = ""
    elif ok == len(runs):
        summary = ", ok" if ok == 1 else ", all ok"
    else:
        summary = f", {ok} ok" if ok else ""
    parts.append(f"{len(runs)} {'run' if len(runs) == 1 else 'runs'} recorded{summary}")
    for r in [r for r in runs if str(r.status) in ("failed", "timeout")][-5:]:
        parts.append(f"{r.status} at {when(r.started_at, span.now)} UTC after {format_duration(r.duration_ms or 0)}")
    if missed is not None:
        parts.append(f"due at {when(missed, span.now)} UTC and nothing started")
    if note and not _QUIET_NOTE.match(note):
        parts.append(note)
    return "; ".join(parts)


def _hours(span: Span, step: int, now_label: bool) -> tuple[str, str]:
    """Grid lines and hour labels every `step`, on UTC boundaries."""

    def x(t: float) -> float:
        return ((t - span.start) / (span.end - span.start)) * W

    now_x = x(span.now)
    lines = ""
    labels = ""
    t = math.ceil(span.start / step) * step
    while t <= span.end:
        gx = x(t)
        lines += f'<i class="gl" style="left:{f(gx / 10)}%"></i>'
        near_now = now_label and abs(gx - now_x) < 70
        if not (gx < 25 or gx > W - 25 or near_now):
            minor = _js.js_round(t / HOUR) % 6 != 0
            # On a phone the track is too narrow for a label this close to "now"; CSS hides it there.
            near = now_label and abs(gx - now_x) < 170
            cls = " ".join(name for name, on in (("minor", minor), ("near", near)) if on)
            labels += f'<span class="{cls}" style="left:{f(gx / 10)}%">{clock(t)}</span>'
        t += step
    if now_label and span.start <= span.now <= span.end:
        labels += f'<span class="nowlabel" style="left:{f(now_x / 10)}%">now {clock(span.now)}</span>'
    return lines, labels


def _legend() -> str:
    """The key under a timeline: a small sample of each mark and what it means."""

    def key(inner: str) -> str:
        return f'<svg class="key" viewBox="0 0 16 12" aria-hidden="true" focusable="false">{inner}</svg>'

    def box(cls: str) -> str:
        return key(f'<rect class="{cls}" x="2" y="1" width="12" height="10"/>')

    items = [
        (key('<line class="tick" x1="8" y1="1" x2="8" y2="11"/>'), "due"),
        (box("run ok"), "ran"),
        (box("run bad"), "failed"),
        (box("run timeout"), "timed out"),
        (box("run warn"), "over budget or slow"),
        (box("run running"), "running"),
        (box("missed"), "missed"),
    ]
    return '<p class="legend" aria-hidden="true">' + "".join(f"<span>{k}{label}</span>" for k, label in items) + "</p>"


def _schedule_or(job: JobSummary, fallback: str) -> Any:
    schedule = job.definition.schedule
    return fallback if schedule is None else schedule


def day_timeline(lanes: Sequence[LaneInput], span: Span, base: str, total: int) -> str:
    """The board's timeline: one lane per job across `span`, with a shared now
    line and the first BOARD_LANES jobs only. `total` is how many jobs there
    are in all, for the note when some are left out."""
    lines, labels = _hours(span, 3 * HOUR, True)
    now_x = ((span.now - span.start) / (span.end - span.start)) * 100
    html_rows = []
    word_rows = []
    for lane_input in lanes:
        job = lane_input.job
        parts = _lane(lane_input, span, now_in_lane=False, label=job.name)
        schedule = _schedule_or(job, "no schedule")
        html_rows.append(
            f'<li class="lane"><div class="who"><i class="sq {STATE_CLASS[str(job.health)]}" aria-hidden="true"></i>'
            f'<a class="name" href="{h(base)}/jobs/{encode_uri_component(job.name)}">{name_html(job.name)}</a>'
            f'<span class="sched">{h(schedule)}</span></div><div class="track">{parts.svg}{parts.note}</div></li>'
        )
        word_rows.append(f"<li>{h(f'{job.name} ({text(schedule)}): {parts.words}.')}</li>")
    more = f'<p class="more">Showing the first {len(lanes)} of {total} jobs here; the table below lists them all.</p>' if total > len(lanes) else ""
    lane_rows = "".join(html_rows)
    words = "".join(word_rows)
    return f"""<figure class="timeline day">
<div class="axis" aria-hidden="true"><span></span><div class="hours">{labels}</div></div>
<div class="field">
<div class="under" aria-hidden="true"><span></span><div>{lines}<i class="future" style="left:{f(now_x)}%"></i></div></div>
<ol class="lanes">{lane_rows}</ol>
<div class="over" aria-hidden="true"><span></span><div><i class="now" style="left:{f(now_x)}%"></i></div></div>
</div>
{_legend()}{more}
<ul class="vh">{words}</ul>
</figure>"""


def week_timeline(job: JobSummary, runs: Sequence[Run], complete: bool, now: int) -> str:
    """A job's page: its last WEEK_DAYS UTC days, today first, one lane each.
    `complete` is False when the runs read do not reach back over the week."""
    today = math.floor(now / DAY) * DAY
    oldest = min((r.started_at for r in runs), default=None)
    lines, labels = _hours(Span(today, today + DAY, now), 3 * HOUR, False)
    html_rows = []
    word_rows = []
    for i in range(WEEK_DAYS):
        start = today - i * DAY
        span = Span(start, start + DAY, now)
        day_runs = [r for r in runs if r.started_at < span.end and (now if r.finished_at is None else r.finished_at) >= start]
        known = complete or (oldest is not None and oldest <= start)
        label = "today" if i == 0 else day_label(start)
        parts = _lane(LaneInput(job, runs, known), span, now_in_lane=i == 0, label=f"{job.name}, {label}")
        count = f"{len(day_runs)} {'run' if len(day_runs) == 1 else 'runs'}"
        name = f"Today, {day_label(start)[4:]}" if i == 0 else day_label(start)
        today_class = " today" if i == 0 else ""
        html_rows.append(
            f'<li class="lane{today_class}"><div class="who"><span class="name">{h(name)}</span><span class="sched">{h(count)}</span></div>'
            f'<div class="track">{parts.svg}{parts.note if i == 0 else ""}</div></li>'
        )
        said = "Today" if i == 0 else day_label(start)
        word_rows.append(f"<li>{h(f'{said}: {parts.words}.')}</li>")
    lane_rows = "".join(html_rows)
    words = "".join(word_rows)
    return f"""<figure class="timeline week">
<div class="axis" aria-hidden="true"><span></span><div class="hours">{labels}</div></div>
<div class="field">
<div class="under" aria-hidden="true"><span></span><div>{lines}</div></div>
<ol class="lanes">{lane_rows}</ol>
</div>
{_legend()}
<ul class="vh">{words}</ul>
</figure>"""


def week_runs_limit(job: JobSummary, now: int) -> int:
    """How many runs a job's page reads so its week is drawn in full: roughly
    how often the schedule was due over the week, with room to spare, from 50
    (what the run list shows) to 500 (the most runs() returns)."""
    parsed = parsed_schedule(job)
    if parsed is None:
        return 50
    start = math.floor(now / DAY) * DAY - (WEEK_DAYS - 1) * DAY
    span = now + DAY - start
    # A cron's fires over one day, times the week: close enough, and cheap.
    if parsed.kind == "interval":
        assert parsed.every_ms is not None
        expected: float = span / parsed.every_ms
    else:
        due = due_times(job, parsed, [], now - DAY, now)
        expected = math.inf if due.dense else (len(due.times) * span) / DAY
    wanted = expected * 1.2
    if not math.isfinite(wanted):
        return 500
    return min(500, max(50, math.ceil(wanted) + 10))
