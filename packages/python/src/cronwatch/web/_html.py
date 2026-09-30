"""The dashboard's pages, markup for markup the SDK's routes/html.ts. The one
script, app.js, only registers the service worker: the pages refresh
themselves and the forget button confirms with a <details>.

Set like cronwatch.dev: a printed sheet on grey paper, a serif for what a
person reads, a mono for what a machine printed, neutral greys, and colour
only for the states CronWatch reports. The page loads nothing but its own app
shell (its CSP is default-src 'none' plus 'self' for the script, the
manifest, the worker and images), so the fonts are system stacks that echo
the site's Newsreader and IBM Plex Mono, and use them when they are installed.

Installed as an app (display-mode: standalone) the header stays at the top as
the app's bar, and the page keeps clear of notches and the home indicator
with the safe-area insets (the viewport is viewport-fit=cover).

Motion is CSS only and says something: marks arrive in time order, the now
line drops in last, and open problems (a missed slot, a running bar) breathe
slowly. prefers-reduced-motion turns all of it off.
"""

from __future__ import annotations

from collections.abc import Mapping, Sequence

from .. import _js
from ..duration import beyond_dates, format_duration, format_relative, iso_time
from ..types import JobSummary, Run
from . import _timeline as timeline
from ._escape import encode_uri_component, entries, h, name_html, text, to_fixed, truthy
from ._pwa import THEME_COLOR, THEME_COLOR_DARK

CSS = r"""
:root{color-scheme:light dark;--paper:#f4f4f5;--sheet:#fff;--sunk:#fafafa;--rule:#e4e4e7;--rule-2:#d4d4d8;--tick:#909098;--ink:#000;--body:#18181b;--muted:#71717a;--ok:#15803d;--warn:#a16207;--bad:#b91c1c;--serif:"Newsreader",ui-serif,Georgia,Cambria,"Times New Roman",serif;--mono:"IBM Plex Mono",ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;--who:200px}
@media(prefers-color-scheme:dark){:root{--paper:#09090b;--sheet:#111113;--sunk:#18181b;--rule:#27272a;--rule-2:#3f3f46;--tick:#66666f;--ink:#fff;--body:#e4e4e7;--muted:#a1a1aa;--ok:#4ade80;--warn:#fbbf24;--bad:#f87171}}
*{box-sizing:border-box}html{-webkit-text-size-adjust:100%}
body{margin:0;background:var(--paper);color:var(--ink);font:400 16px/1.55 var(--serif);-webkit-font-smoothing:antialiased;-moz-osx-font-smoothing:grayscale}
a{color:inherit;text-decoration:underline;text-decoration-thickness:1px;text-underline-offset:.16em;text-decoration-color:var(--rule-2)}a:hover{text-decoration-color:currentColor}
:focus-visible{outline:2px solid var(--ink);outline-offset:2px}
code,pre,.mono{font-family:var(--mono)}
.vh{position:absolute!important;width:1px;height:1px;margin:-1px;padding:0;overflow:hidden;clip:rect(0 0 0 0);white-space:nowrap;border:0}
.sheet{max-width:1180px;min-height:100vh;margin:0 auto;background:var(--sheet);border-inline:1px solid var(--rule);padding:0 clamp(16px,4vw,48px)}
.top{display:flex;align-items:center;justify-content:space-between;gap:12px 20px;flex-wrap:wrap;padding:18px 0 17px;border-bottom:1px solid var(--rule)}
.brand{display:flex;align-items:center;gap:10px;margin:0;font:600 18px/1.2 var(--serif);letter-spacing:-.01em;min-width:0}
.brand a{display:inline-flex;align-items:center;gap:10px;text-decoration:none}.brand svg{width:24px;height:24px;flex:none;color:var(--ink)}
.brand .crumb{font:500 15px/1.2 var(--mono);color:var(--body);overflow-wrap:anywhere}.brand .slash{color:var(--rule-2);font-weight:400}
.actions{display:flex;align-items:center;gap:10px;flex-wrap:wrap}
.meta{font:400 12px/1.4 var(--mono);color:var(--muted)}
button,select,details.confirm>summary{font:500 12.5px/1 var(--mono);color:var(--ink);background:var(--sheet);border:1px solid var(--rule-2);border-radius:3px;padding:8px 11px;cursor:pointer}
select{padding:7px 8px}
button:hover,select:hover,details.confirm>summary:hover{border-color:var(--muted)}
button.primary{background:var(--ink);border-color:var(--ink);color:var(--sheet)}button.primary:hover{opacity:.86}
form.inline{display:inline-flex;align-items:center;gap:6px;margin:0}
details.confirm{display:inline-flex;align-items:center;gap:8px;margin:0}details.confirm>summary{list-style:none;display:inline-block}
details.confirm>summary::-webkit-details-marker{display:none}details.confirm[open]>summary{border-color:var(--muted)}
details.confirm form{margin-left:8px;font-size:14px;color:var(--muted)}
.sec{display:grid;grid-template-columns:150px minmax(0,1fr);gap:10px 40px;padding:30px 0;border-top:1px solid var(--rule)}
.top+main>.sec:first-child{border-top:0}
.sec>h2{margin:0;font:500 11px/1.5 var(--mono);letter-spacing:.12em;text-transform:uppercase;color:var(--muted);padding-top:5px}
.sec>.wide{grid-column:1/-1;min-width:0}
.lede{margin:0;color:var(--muted);font-size:16px;max-width:64ch;text-wrap:pretty}
.headline{margin:0;font:400 clamp(24px,3.2vw,32px)/1.2 var(--serif);letter-spacing:-.01em;text-wrap:balance}
.headline b{font-weight:600}
.state{font:500 12.5px/1.4 var(--mono);white-space:nowrap}.state+.state::before{content:" \00b7  ";color:var(--muted);font-weight:400}
.ok{color:var(--ok)}.warn{color:var(--warn)}.bad{color:var(--bad)}.muted{color:var(--muted)}.info{color:var(--ink)}
.sq{display:inline-block;width:8px;height:8px;border-radius:1.5px;background:currentColor;margin-right:7px;vertical-align:1px;flex:none}
.sq.muted{background:none;box-shadow:inset 0 0 0 1.5px var(--tick)}
.figures{display:grid;grid-template-columns:repeat(auto-fit,minmax(120px,1fr));gap:0;margin:22px 0 0;border-top:1px solid var(--rule)}
.figures>div{display:flex;flex-direction:column-reverse;justify-content:flex-end;gap:4px;padding:14px 16px 2px 0}
.figures dt{font:500 11px/1.4 var(--mono);letter-spacing:.08em;text-transform:uppercase;color:var(--muted);display:flex;align-items:center}
.figures dd{margin:0;font:400 30px/1.1 var(--serif);font-variant-numeric:tabular-nums;color:var(--ink)}
.figures dd small{font-size:17px;color:var(--muted)}
.figures .zero dd{color:var(--rule-2)}
.figures .bad dd{color:var(--bad)}.figures .warn dd{color:var(--warn)}
.stateline{margin:12px 0 0;display:flex;flex-wrap:wrap;align-items:baseline;gap:4px 12px}
.stateline .why{font-style:italic;color:var(--muted)}
.jobname{margin:0;font:500 clamp(22px,3vw,28px)/1.2 var(--mono);letter-spacing:-.01em;overflow-wrap:anywhere}
.desc{margin:6px 0 0;color:var(--body);max-width:64ch}
.intro .actions{margin-top:18px}
table{width:100%;border-collapse:collapse}
th{text-align:left;font:500 10.5px/1.2 var(--mono);letter-spacing:.08em;text-transform:uppercase;color:var(--muted);padding:0 14px 10px 0;border-bottom:1px solid var(--rule);white-space:nowrap}
td{padding:12px 14px 12px 0;border-bottom:1px solid var(--rule);vertical-align:top;font:400 12.5px/1.5 var(--mono);color:var(--body)}
tbody tr:last-child td{border-bottom:0}
td.job{font-family:var(--serif);font-size:15px;min-width:180px}
td.job .name{font:500 13.5px/1.5 var(--mono);color:var(--ink)}
td.job .desc{display:block;margin:2px 0 0;font-size:14px;color:var(--muted);line-height:1.4}
td .tz,td .sub{display:block;color:var(--muted);font-size:11.5px}
.nowrap{white-space:nowrap}
.spark{display:block;overflow:visible}.spark rect{fill:var(--tick)}.spark rect.bad{fill:var(--bad)}.spark rect.warn{fill:var(--warn)}.spark rect.running{fill:none;stroke:var(--ink);stroke-width:1}
.runs td{padding-top:11px;padding-bottom:11px}.runs tr.has-detail td{border-bottom:0;padding-bottom:4px}.runs tr.detail td{padding-top:0}
.metrics{display:flex;flex-wrap:wrap;gap:2px 14px}.metrics .k{color:var(--muted)}
pre{margin:6px 0 0;padding:12px 14px;background:var(--sunk);border:1px solid var(--rule);border-radius:3px;font:400 12.5px/1.55 var(--mono);color:var(--body);white-space:pre-wrap;overflow-wrap:anywhere;max-height:340px;overflow:auto}
details.out{margin-top:4px}details.out>summary{cursor:pointer;font:400 12px/1.6 var(--mono);color:var(--muted)}details.out>summary:hover{color:var(--ink)}
details.out.error>summary{color:var(--bad)}
dl.def{display:grid;grid-template-columns:max-content minmax(0,1fr);gap:8px 28px;margin:0}
dl.def dt{font:500 11px/1.9 var(--mono);letter-spacing:.08em;text-transform:uppercase;color:var(--muted)}
dl.def dd{margin:0;font:400 13.5px/1.7 var(--mono);color:var(--body);overflow-wrap:anywhere}dl.def dd.prose{font:400 16px/1.55 var(--serif)}
.empty{padding:28px 0 8px;color:var(--muted);max-width:60ch}
.empty code{font-size:.86em;color:var(--ink)}
.message{padding:clamp(56px,12vh,120px) 0;text-align:center}
.message h1{margin:0;font:400 clamp(28px,4vw,40px)/1.15 var(--serif);letter-spacing:-.015em}
.message p{margin:14px auto 0;max-width:52ch;color:var(--muted);text-wrap:pretty}
.signin{display:flex;flex-wrap:wrap;align-items:center;justify-content:center;gap:8px;margin:28px auto 0;max-width:420px}
.signin label{font:500 11px/1.4 var(--mono);letter-spacing:.08em;text-transform:uppercase;color:var(--muted)}
.signin input{flex:1 1 180px;min-width:0;font:400 16px/1.2 var(--mono);color:var(--ink);background:var(--sheet);border:1px solid var(--rule-2);border-radius:3px;padding:8px 10px}
footer{display:flex;flex-wrap:wrap;gap:6px 18px;padding:20px 0 40px;border-top:1px solid var(--rule);font:400 12px/1.5 var(--mono);color:var(--muted)}
.timeline{margin:18px 0 0}
.timeline .axis,.timeline .under,.timeline .over,.timeline .lane{display:grid;grid-template-columns:var(--who) minmax(0,1fr)}
.timeline .hours{position:relative;height:22px;font:400 11px/1 var(--mono);color:var(--muted);letter-spacing:.04em}
.timeline .hours span{position:absolute;top:2px;transform:translateX(-50%);white-space:nowrap}
.timeline .hours .nowlabel{color:var(--ink);font-weight:500;animation:cw-fade .5s 1s both}
.timeline .field{position:relative}
.timeline .under,.timeline .over{position:absolute;inset:0;pointer-events:none}
.timeline .under>div,.timeline .over>div{position:relative}
.timeline .gl{position:absolute;top:0;bottom:0;width:1px;background:var(--rule)}
.timeline .future{position:absolute;top:0;bottom:0;right:0;background:var(--sunk)}
.timeline .now{position:absolute;top:-6px;bottom:0;width:1.5px;margin-left:-.75px;background:var(--ink);transform-origin:top;animation:cw-drop .6s .85s cubic-bezier(.2,.8,.2,1) both}
.timeline .lanes{position:relative;list-style:none;margin:0;padding:0;border-top:1px solid var(--rule);border-bottom:1px solid var(--rule)}
.timeline .lane{align-items:center;min-height:40px}
.timeline .who{display:grid;grid-template-columns:auto minmax(0,1fr);align-items:center;column-gap:0;padding:6px 14px 6px 0;min-width:0}
.timeline .who .sched{grid-column:2}
.timeline.week .who{display:flex;align-items:baseline;gap:10px}
.timeline .who .name{font:500 13px/1.35 var(--mono);color:var(--ink);overflow-wrap:anywhere}
.timeline .who .sched{font:400 11px/1.35 var(--mono);color:var(--muted);white-space:nowrap}
.timeline .track{position:relative;height:24px}
.timeline .marks{display:block;width:100%;height:24px;overflow:visible}
.timeline .note{position:absolute;top:50%;transform:translateY(-50%);font:italic 400 14px/1.2 var(--serif);color:var(--muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;padding:0 3px;text-shadow:0 0 3px var(--sheet),0 0 3px var(--sheet),0 0 6px var(--sheet);animation:cw-fade .6s 1.1s both}
.timeline .note.before{text-align:right}
.timeline .legend{display:flex;flex-wrap:wrap;gap:6px 18px;margin:14px 0 0;padding-left:var(--who);font:400 11.5px/1.4 var(--mono);color:var(--muted)}
.timeline .legend span{display:inline-flex;align-items:center;gap:7px}
.timeline .more{margin:10px 0 0;padding-left:var(--who);font-size:14px;color:var(--muted);font-style:italic}
.key{width:16px;height:12px;overflow:visible}
.marks *{vector-effect:non-scaling-stroke}
svg .base{stroke:var(--rule);stroke-width:1}
svg .tick{stroke:var(--tick);stroke-width:1.5}svg .tick.ahead{stroke-dasharray:2 2;opacity:.75}
svg .cadence{stroke:var(--tick);stroke-width:2;stroke-dasharray:1 3}
svg .run{stroke-width:2;stroke-linejoin:round}
svg .run.ok{fill:var(--ok);stroke:var(--ok)}
svg .run.bad{fill:var(--bad);stroke:var(--bad)}
svg .run.timeout{fill:var(--bad);fill-opacity:.28;stroke:var(--bad);stroke-width:1.5}
svg .run.warn{fill:var(--warn);stroke:var(--warn)}
svg .run.running{fill:none;stroke:var(--ink);stroke-width:1.5}
svg .run.stuck{fill:var(--bad);fill-opacity:.12;stroke:var(--bad);stroke-width:1.5}
svg .missed{fill:none;stroke:var(--bad);stroke-width:1.5;stroke-dasharray:3 2.5}
svg .unloaded{fill:var(--sunk)}
svg .ahead{fill:var(--sunk)}
svg .nowline{stroke:var(--ink);stroke-width:1.5}
.marks .tick{animation:cw-fade .4s var(--d,0ms) both}
.marks .run,.marks .missed{transform-box:fill-box;transform-origin:0 50%;animation:cw-grow .55s cubic-bezier(.2,.8,.2,1) var(--d,0ms) both}
.marks .missed,.marks .run.running,.marks .run.stuck{animation:cw-grow .55s cubic-bezier(.2,.8,.2,1) var(--d,0ms) both,cw-breathe 2.6s ease-in-out calc(var(--d,0ms) + .6s) infinite alternate}
.figures>div{animation:cw-rise .5s cubic-bezier(.2,.8,.2,1) both}
.figures>div:nth-child(2){animation-delay:40ms}.figures>div:nth-child(3){animation-delay:80ms}.figures>div:nth-child(4){animation-delay:120ms}.figures>div:nth-child(5){animation-delay:160ms}.figures>div:nth-child(6){animation-delay:200ms}
@keyframes cw-fade{from{opacity:0}}
@keyframes cw-grow{from{opacity:0;transform:scaleX(0)}}
@keyframes cw-drop{from{opacity:0;transform:scaleY(0)}}
@keyframes cw-rise{from{opacity:0;transform:translateY(4px)}}
@keyframes cw-breathe{to{opacity:.38}}
body{padding:0 env(safe-area-inset-right) 0 env(safe-area-inset-left)}
footer{padding-bottom:calc(40px + env(safe-area-inset-bottom))}
@media(display-mode:standalone){
.top{position:sticky;top:0;z-index:2;background:var(--sheet);padding-top:calc(14px + env(safe-area-inset-top));padding-bottom:13px;-webkit-user-select:none;user-select:none}
.message{padding-top:clamp(40px,8vh,80px)}
}
@media(prefers-reduced-motion:reduce){*,*::before,*::after{animation:none!important;transition:none!important}}
@media(max-width:760px){
.sec{grid-template-columns:minmax(0,1fr);gap:10px;padding:24px 0}
.hide-sm{display:none}
:root{--who:0px}
.timeline .lane{grid-template-columns:minmax(0,1fr);padding:6px 0 8px}
.timeline .who{padding:0 0 4px}
.timeline .who .name{background:var(--sheet);padding-right:4px}
.timeline .hours .minor,.timeline .hours .near{display:none}
.timeline .note{font-size:13px}
td.job{min-width:0}
table.board thead{display:none}
table.board tr{display:grid;grid-template-columns:minmax(0,1fr) auto;column-gap:14px;padding:12px 0;border-bottom:1px solid var(--rule)}
table.board tbody tr:last-child{border-bottom:0}
table.board td{border:0;padding:0}
table.board td.last{grid-column:1/-1;margin-top:4px;white-space:normal}
table.board td.last .sub{display:inline;margin-left:8px}
.runs td.nowrap{white-space:normal}
dl.def{grid-template-columns:minmax(0,1fr);gap:0}dl.def dd{margin-bottom:10px}
}
"""

#: The clock face from cronwatch.dev, in the text colour.
MARK = '<svg viewBox="0 0 40 40" aria-hidden="true" focusable="false"><rect x="1" y="1" width="38" height="38" rx="9.5" fill="none" stroke="currentColor" stroke-opacity=".22" stroke-width="1.5"/><circle cx="20" cy="20" r="10.5" fill="none" stroke="currentColor" stroke-width="2"/><path d="M20 12.5V20h6" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>'

#: In the order the board counts them, the ones needing attention first.
HEALTH = {
    "failing": ("bad", "failing"),
    "stuck": ("bad", "stuck"),
    "late": ("warn", "late"),
    "healthy": ("ok", "healthy"),
    "silenced": ("muted", "silenced"),
    "never_ran": ("muted", "never ran"),
}
#: Conditions the health state already says; the others are named after it.
SHOWN_BY_HEALTH = ("missed", "failed", "stuck")

#: What the empty board tells a Python app to write (the SDK shows its own TypeScript).
DECLARE_ONE = 'cw.job("name", schedule="0 2 * * *")'


def layout(title: str, body: str, base: str, refresh: int | None = None) -> str:
    """A page. `base` is where the dashboard is mounted ("" at the root): the
    head links the web app manifest, the icons and app.js, the one script,
    which only registers the service worker (_pwa.py). Everything works
    without it."""
    b = h(base)
    meta_refresh = f'<meta http-equiv="refresh" content="{text(refresh)}">' if truthy(refresh) else ""
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="robots" content="noindex,nofollow">
<meta name="color-scheme" content="light dark">
{meta_refresh}
<title>{h(title)}</title>
<meta name="theme-color" content="{THEME_COLOR}" media="(prefers-color-scheme: light)">
<meta name="theme-color" content="{THEME_COLOR_DARK}" media="(prefers-color-scheme: dark)">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-title" content="CronWatch">
<meta name="apple-mobile-web-app-status-bar-style" content="default">
<link rel="manifest" href="{b}/manifest.webmanifest">
<link rel="icon" href="{b}/icons/icon.svg" type="image/svg+xml">
<link rel="apple-touch-icon" href="{b}/icons/apple-touch-icon.png">
<script src="{b}/app.js" defer></script>
<style>{CSS}</style>
</head>
<body><div class="sheet">{body}</div></body>
</html>"""


def _brand(base: str, crumb: str | None = None) -> str:
    home = f'<a href="{h(base)}/">{MARK}<span>CronWatch</span></a>'
    if crumb is None:
        return f'<p class="brand">{home}</p>'
    return f'<p class="brand">{home}<span class="slash" aria-hidden="true">/</span><span class="crumb">{name_html(crumb)}</span></p>'


def _health_state(job: JobSummary) -> str:
    """The job's health, with any open condition it does not already say (over budget, slow) after it."""
    cls, label = HEALTH[str(job.health)]
    extras = "".join(f'<span class="state warn">{h(str(c).replace("_", " ", 1))}</span>' for c in job.open if str(c) not in SHOWN_BY_HEALTH)
    return f'<span class="state {cls}"><i class="sq {cls}" aria-hidden="true"></i>{label}</span>{extras}'


def _run_state(run: Run) -> str:
    status = str(run.status)
    cls = "ok" if status == "ok" else "info" if status == "running" else "bad"
    return f'<span class="state {cls}">{h(status)}</span>'


def _sparkline(runs: Sequence[Run]) -> str:
    """The last twenty runs, oldest first, as bars as tall as they took; grey unless something went wrong."""
    points = list(runs)[:20][::-1]
    if len(points) < 2:
        return ""
    bar, gap, hgt = 4, 1.5, 22
    top = max([*(r.duration_ms or 0 for r in points), 1])
    bars = []
    for i, r in enumerate(points):
        x = to_fixed(i * (bar + gap), 1)
        status = str(r.status)
        if status == "running":
            bars.append(f'<rect class="running" x="{x}" y="{text(hgt - 6.5)}" width="{bar - 1}" height="6"/>')
            continue
        tall = max(2 if status == "ok" else 6, ((r.duration_ms or 0) / top) * hgt)
        cls = "" if status == "ok" else ' class="bad"'
        bars.append(f'<rect{cls} x="{x}" y="{to_fixed(hgt - tall, 1)}" width="{bar}" height="{to_fixed(tall, 1)}" rx=".5"/>')
    w = to_fixed(len(points) * (bar + gap) - gap, 1)
    return f'<svg class="spark" width="{w}" height="{hgt}" viewBox="0 0 {w} {hgt}" aria-hidden="true" focusable="false">{"".join(bars)}</svg>'


def _stamp(at: float | None, now: int) -> str:
    if at is None:
        return '<span class="muted">never</span>'
    iso = iso_time(int(at))
    if iso is None:
        return f'<span class="nowrap">{beyond_dates(at)}</span>'
    return f'<time class="nowrap" datetime="{iso}" title="{iso.replace("T", " ", 1)[:19]} UTC">{h(format_relative(at, now))}</time>'


def _health_figures(jobs: Sequence[JobSummary]) -> str:
    """Counts by health, the ones needing attention first; a zero is set faint
    rather than left out, so the row keeps its shape."""
    cells = []
    for health, (cls, label) in HEALTH.items():
        n = sum(1 for j in jobs if str(j.health) == health)
        cells.append(f'<div class="{"zero" if n == 0 else cls}"><dt><i class="sq {cls}" aria-hidden="true"></i>{label}</dt><dd>{n}</dd></div>')
    return f'<dl class="figures">{"".join(cells)}</dl>'


def dashboard_page(
    jobs: Sequence[JobSummary],
    runs_by_job: Mapping[str, Sequence[Run]],
    now: int,
    base: str,
    checked_at: int | None,
    lanes: Sequence[timeline.LaneInput] | None = None,
) -> str:
    if lanes is None:
        lanes = [timeline.LaneInput(job, runs_by_job.get(job.name, []), True) for job in jobs[: timeline.BOARD_LANES]]
    attention = sum(1 for j in jobs if str(j.health) != "healthy")
    if not jobs:
        headline = "No jobs yet."
    elif attention == 0:
        headline = f"{'The one job is' if len(jobs) == 1 else f'All {len(jobs)} jobs are'} healthy."
    else:
        headline = f"{len(jobs)} job{'' if len(jobs) == 1 else 's'}, <b>{attention} needing attention</b>."

    rows = []
    for job in jobs:
        last = job.last_run
        d = job.definition
        description = f'<span class="desc">{h(d.description)}</span>' if truthy(d.description) else ""
        if truthy(d.schedule):
            zone = f'<span class="tz">{h(d.timezone)}</span>' if truthy(d.timezone) else ""
            schedule = f"{h(d.schedule)}{zone}"
        else:
            schedule = '<span class="muted">no schedule</span>'
        if last is not None:
            took = "" if last.duration_ms is None else f'<span class="sub">took {h(format_duration(last.duration_ms))}</span>'
            last_cell = f"{_run_state(last)} {_stamp(last.started_at, now)}{took}"
        else:
            last_cell = '<span class="muted">never</span>'
        next_at = job.next_expected_at
        if next_at is None:
            next_cell = '<span class="muted">not scheduled</span>'
        else:
            overdue = '<span class="state warn">overdue</span> ' if next_at < now else ""
            next_cell = f'{overdue}{_stamp(next_at, now)}<span class="sub">{h(timeline.when(next_at, now))} UTC</span>'
        rows.append(
            f"""<tr>
<td class="job"><a class="name" href="{h(base)}/jobs/{encode_uri_component(job.name)}">{name_html(job.name)}</a>{description}</td>
<td class="health">{_health_state(job)}</td>
<td class="nowrap hide-sm">{schedule}</td>
<td class="nowrap last">{last_cell}</td>
<td class="nowrap hide-sm">{next_cell}</td>
<td class="hide-sm">{_sparkline(runs_by_job.get(job.name, []))}</td>
</tr>"""
        )

    span = timeline.Span(now - timeline.BOARD_BEHIND_MS, now + timeline.BOARD_AHEAD_MS, now)
    checked = f", checked {h(format_relative(checked_at, now))}" if checked_at else ""
    if jobs:
        figures = _health_figures(jobs)
    else:
        figures = f'<p class="empty">Declare one with <code>{h(DECLARE_ONE)}</code> and run it once, and it shows up here.</p>'
    if jobs:
        board = "\n".join(rows)
        sections = f"""<section class="sec" aria-label="Last 24 hours">
  <h2>Last 24 hours</h2>
  <p class="lede">One lane per job. Faint ticks mark when it was due, bars the runs it recorded, as long as they took. A dashed box is a slot nothing ran in. Times are UTC.</p>
  <div class="wide">{timeline.day_timeline(lanes, span, base, len(jobs))}</div>
</section>
<section class="sec" aria-label="Jobs">
  <h2>Jobs</h2>
  <p class="lede">Every job in the store. Open one for its week, its runs and their output.</p>
  <div class="wide"><table class="board">
<thead><tr><th>Job</th><th>Health</th><th class="hide-sm">Schedule</th><th>Last run</th><th class="hide-sm">Next due</th><th class="hide-sm">Recent runs</th></tr></thead>
<tbody>{board}</tbody></table></div>
</section>"""
    else:
        sections = ""
    body = f"""
<header class="top">
  {_brand(base)}
  <div class="actions">
    <span class="meta">{h(timeline.clock(now))} UTC{checked}</span>
    <form class="inline" method="post" action="{h(base)}/check"><button class="primary" type="submit">Run check now</button></form>
  </div>
</header>
<main>
<section class="sec" aria-label="Health">
  <h2>Health</h2>
  <div>
    <p class="headline">{headline}</p>
    {figures}
  </div>
</section>
{sections}
</main>
<footer><span>Refreshes every minute. Times are UTC.</span><a href="{h(base)}/api/jobs">JSON</a></footer>"""
    return layout("CronWatch", body, base, refresh=60)


def job_page(job: JobSummary, runs: Sequence[Run], now: int, base: str, complete: bool = True) -> str:
    """One job: its state and figures, its last seven days, its runs with
    their output, and its definition. `complete` is False when `runs` does not
    reach back over the whole week (the run list shows the newest fifty)."""
    d = job.definition
    ok_rate = f"{_js.number(_js.js_round(job.stats.ok_rate * 100))}%"
    listed = list(runs)[:50]
    run_rows = []
    for run in listed:
        error = f'<details class="out error" open><summary>error</summary><pre>{h(run.error)}</pre></details>' if truthy(run.error) else ""
        opened = "" if str(run.status) == "ok" else " open"
        output = f'<details class="out"{opened}><summary>output</summary><pre>{h(run.output)}</pre></details>' if truthy(run.output) else ""
        detail = error + output
        # A foreign row may hold a metric that is no finite number (null, text); it is left out.
        metrics = "".join(
            f'<span><span class="k">{h(k)}</span> {h(v if _js.is_integer(v) else to_fixed(v, 4))}</span>'
            for k, v in entries(run.metrics)
            if _js.is_finite(v)
        )
        took = '<span class="muted">running</span>' if run.duration_ms is None else h(format_duration(run.duration_ms))
        has_detail = ' class="has-detail"' if detail else ""
        detail_row = f'<tr class="detail"><td colspan="5">{detail}</td></tr>' if detail else ""
        metrics_cell = f'<span class="metrics">{metrics}</span>' if metrics else ""
        run_rows.append(
            f"""<tr{has_detail}>
<td class="nowrap">{_run_state(run)}</td>
<td class="nowrap">{h(timeline.when(run.started_at, now))} <span class="muted">UTC</span><span class="sub">{_stamp(run.started_at, now)}</span></td>
<td class="nowrap">{took}</td>
<td class="hide-sm">{metrics_cell}</td>
<td class="hide-sm muted">{h(run.trigger)}</td>
</tr>{detail_row}"""
        )

    silenced = job.silenced_until is not None and job.silenced_until > now
    path = f"{h(base)}/jobs/{encode_uri_component(job.name)}"
    parsed = timeline.parsed_schedule(job)
    why = timeline.lane_note(job, timeline.missed_at(job, parsed, [], now), now)
    if silenced:
        assert job.silenced_until is not None
        silence_form = (
            f'<form class="inline" method="post" action="{path}/unsilence"><button type="submit">'
            f"Unsilence (until {h(format_relative(job.silenced_until, now))})</button></form>"
        )
    else:
        silence_form = (
            f'<form class="inline" method="post" action="{path}/silence"><select name="for" aria-label="Silence for">'
            '<option value="1h">1 hour</option><option value="4h">4 hours</option><option value="1d">1 day</option>'
            '<option value="7d">1 week</option></select><button type="submit">Silence</button></form>'
        )
    stats = job.stats
    p50 = "?" if stats.p50_ms is None else h(format_duration(stats.p50_ms))
    p95 = "?" if stats.p95_ms is None else h(format_duration(stats.p95_ms))
    if truthy(d.schedule):
        schedule = h(d.schedule) + (f' <span class="muted">{h(d.timezone)}</span>' if truthy(d.timezone) else "")
    else:
        schedule = '<span class="muted">none</span>'
    budget = f"<dt>Budget</dt><dd>{h(', '.join(f'{k} ≤ {text(v)}' for k, v in entries(d.budget)))}</dd>" if truthy(d.budget) else ""
    failures = d.failures_before_alert
    alert_after = (
        f"<dt>Alert after</dt><dd>{h(failures)} consecutive failures</dd>"
        if truthy(failures) and isinstance(failures, (int, float)) and failures > 1
        else ""
    )
    tags = d.tags
    tag_list = f"<dt>Tags</dt><dd>{', '.join(h(t) for t in tags)}</dd>" if isinstance(tags, (list, tuple)) and tags else ""
    open_states = "".join(
        f'<span class="state {"bad" if str(c) in ("failed", "stuck") else "warn"}">{h(str(c).replace("_", " ", 1))}</span>' for c in job.open
    )
    open_list = f"<dt>Open</dt><dd>{open_states}</dd>" if job.open else ""
    in_a_row = f"<dt>Failures in a row</dt><dd>{h(job.consecutive_failures)}</dd>" if job.consecutive_failures > 0 else ""
    max_duration = f"<dt>Max duration</dt><dd>{h(d.max_duration)}</dd>" if truthy(d.max_duration) else ""
    expect = f"<dt>Expect</dt><dd>{h(d.expect)}</dd>" if truthy(d.expect) else ""
    description = f'<p class="desc">{h(d.description)}</p>' if truthy(d.description) else ""
    why_note = f'<span class="why">{h(why)}</span>' if why else ""
    last_run = h(format_relative(job.last_run.started_at, now)) if job.last_run is not None else "never"
    next_due = "<small>no schedule</small>" if job.next_expected_at is None else h(format_relative(job.next_expected_at, now))
    if not listed:
        runs_section = '<p class="lede">No runs yet.</p>'
    else:
        newest = "run" if len(listed) == 1 else f"{len(listed)} runs"
        board = "\n".join(run_rows)
        runs_section = f"""<p class="lede">The newest {newest}, with any error and output.</p>
  <div class="wide"><table class="runs">
<thead><tr><th>Status</th><th>Started</th><th>Took</th><th class="hide-sm">Metrics</th><th class="hide-sm">Trigger</th></tr></thead>
<tbody>{board}</tbody></table></div>"""
    grace = "10m" if d.grace is None else d.grace
    timeout = "1h" if d.timeout is None else d.timeout

    body = f"""
<header class="top">
  {_brand(base, job.name)}
  <div class="actions"><span class="meta">{h(timeline.clock(now))} UTC</span></div>
</header>
<main>
<section class="sec intro" aria-label="Job">
  <h2>Job</h2>
  <div>
    <h1 class="jobname">{name_html(job.name)}</h1>
    {description}
    <p class="stateline">{_health_state(job)}{why_note}</p>
    <div class="actions">
      {silence_form}
      <details class="confirm"><summary>Forget</summary><form class="inline" method="post" action="{path}/forget"><span>Remove this job and its runs from the store?</span> <button type="submit">Forget</button></form></details>
    </div>
    <dl class="figures">
      <div><dt>Last run</dt><dd>{last_run}</dd></div>
      <div><dt>Next due</dt><dd>{next_due}</dd></div>
      <div><dt>Success, last {h(stats.runs)}</dt><dd>{h(ok_rate)}</dd></div>
      <div><dt>p50 / p95</dt><dd>{p50} <small>/ {p95}</small></dd></div>
    </dl>
  </div>
</section>
<section class="sec" aria-label="Last 7 days">
  <h2>Last 7 days</h2>
  <p class="lede">A lane per UTC day, today first. Faint ticks mark when the job was due, bars its runs, as long as they took.</p>
  <div class="wide">{timeline.week_timeline(job, runs, complete, now)}</div>
</section>
<section class="sec" aria-label="Runs">
  <h2>Runs</h2>
  {runs_section}
</section>
<section class="sec" aria-label="Definition">
  <h2>Definition</h2>
  <dl class="def">
  <dt>Schedule</dt><dd>{schedule}</dd>
  <dt>Grace</dt><dd>{h(grace)}</dd>
  <dt>Timeout</dt><dd>{h(timeout)}</dd>
  {max_duration}
  {budget}
  {expect}
  {alert_after}
  {tag_list}
  {open_list}
  {in_a_row}
  </dl>
</section>
</main>
<footer><span>Refreshes every minute. Times are UTC.</span><a href="{h(base)}/api/jobs/{encode_uri_component(job.name)}">JSON</a></footer>"""
    return layout(f"{job.name}: CronWatch", body, base, refresh=60)


def message_page(title: str, message: str, base: str, sign_in: bool = False) -> str:
    """A page with one message. With `sign_in`, a form under it takes the
    token and sends it as ?token=, which the routes move into the cookie: the
    way in where there is no address bar to open a link with, such as an app
    on an iPhone's home screen, which keeps its cookies apart from Safari's."""
    form = (
        f'<form class="signin" method="get" action="{h(base)}/"><label for="token">Token</label>'
        '<input id="token" name="token" type="password" autocomplete="current-password" autocapitalize="off" spellcheck="false" required>'
        '<button class="primary" type="submit">Sign in</button></form>'
        if sign_in
        else ""
    )
    return layout(title, f'<header class="top">{_brand(base)}</header><main class="message"><h1>{h(title)}</h1><p>{h(message)}</p>{form}</main>', base)
