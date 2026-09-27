import { formatDuration, formatRelative } from "../duration.js";
import type { JobSummary, Run } from "../types.js";
import { escapeHtml } from "./escape.js";
import { THEME_COLOR, THEME_COLOR_DARK } from "./pwa.js";
import { BOARD_LANES, BOARD_AHEAD_MS, BOARD_BEHIND_MS, clock, dayTimeline, laneNote, missedAt, parsedSchedule, weekTimeline, when, type LaneInput } from "./timeline.js";

export { escapeHtml };

const h = escapeHtml;

/*
 * Set like cronwatch.dev: a printed sheet on grey paper, a serif for what a
 * person reads, a mono for what a machine printed, neutral greys, and colour
 * only for the states CronWatch reports. The page loads nothing but its own
 * app shell (its CSP is default-src 'none' plus 'self' for the script, the
 * manifest, the worker and images), so the fonts are system stacks that echo
 * the site's Newsreader and IBM Plex Mono, and use them when they are installed.
 *
 * Installed as an app (display-mode: standalone) the header stays at the top
 * as the app's bar, and the page keeps clear of notches and the home
 * indicator with the safe-area insets (the viewport is viewport-fit=cover).
 *
 * Motion is CSS only and says something: marks arrive in time order, the now
 * line drops in last, and open problems (a missed slot, a running bar) breathe
 * slowly. prefers-reduced-motion turns all of it off. Only opacity and
 * transform move, so nothing shifts the layout.
 */
const CSS = `
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
.state{font:500 12.5px/1.4 var(--mono);white-space:nowrap}.state+.state::before{content:" \\00b7  ";color:var(--muted);font-weight:400}
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
`;

/** The clock face from cronwatch.dev, in the text colour. */
const MARK = `<svg viewBox="0 0 40 40" aria-hidden="true" focusable="false"><rect x="1" y="1" width="38" height="38" rx="9.5" fill="none" stroke="currentColor" stroke-opacity=".22" stroke-width="1.5"/><circle cx="20" cy="20" r="10.5" fill="none" stroke="currentColor" stroke-width="2"/><path d="M20 12.5V20h6" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>`;

/**
 * A page. `base` is where the dashboard is mounted ("" at the root): the head
 * links the web app manifest, the icons and app.js, the one script, which
 * only registers the service worker (routes/pwa.ts). Everything works
 * without it.
 */
export function layout(title: string, body: string, base: string, options: { refresh?: number } = {}): string {
  const b = h(base);
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="robots" content="noindex,nofollow">
<meta name="color-scheme" content="light dark">
${options.refresh ? `<meta http-equiv="refresh" content="${options.refresh}">` : ""}
<title>${h(title)}</title>
<meta name="theme-color" content="${THEME_COLOR}" media="(prefers-color-scheme: light)">
<meta name="theme-color" content="${THEME_COLOR_DARK}" media="(prefers-color-scheme: dark)">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-title" content="CronWatch">
<meta name="apple-mobile-web-app-status-bar-style" content="default">
<link rel="manifest" href="${b}/manifest.webmanifest">
<link rel="icon" href="${b}/icons/icon.svg" type="image/svg+xml">
<link rel="apple-touch-icon" href="${b}/icons/apple-touch-icon.png">
<script src="${b}/app.js" defer></script>
<style>${CSS}</style>
</head>
<body><div class="sheet">${body}</div></body>
</html>`;
}

function brand(base: string, crumb?: string): string {
  const home = `<a href="${h(base)}/">${MARK}<span>CronWatch</span></a>`;
  return crumb === undefined
    ? `<p class="brand">${home}</p>`
    : `<p class="brand">${home}<span class="slash" aria-hidden="true">/</span><span class="crumb">${h(crumb)}</span></p>`;
}

const HEALTH: Record<JobSummary["health"], [string, string]> = {
  failing: ["bad", "failing"],
  stuck: ["bad", "stuck"],
  late: ["warn", "late"],
  healthy: ["ok", "healthy"],
  silenced: ["muted", "silenced"],
  never_ran: ["muted", "never ran"],
};

/** The job's health, with any open condition it does not already say (over budget, slow) after it. */
function healthState(job: JobSummary): string {
  const [cls, label] = HEALTH[job.health];
  const extras = job.open.filter((c) => !["missed", "failed", "stuck"].includes(c)).map((c) => `<span class="state warn">${h(c.replace("_", " "))}</span>`).join("");
  return `<span class="state ${cls}"><i class="sq ${cls}" aria-hidden="true"></i>${label}</span>${extras}`;
}

function runState(run: Run): string {
  const cls = run.status === "ok" ? "ok" : run.status === "running" ? "info" : "bad";
  return `<span class="state ${cls}">${h(run.status)}</span>`;
}

/** The last twenty runs, oldest first, as bars as tall as they took; grey unless something went wrong. */
function sparkline(runs: Run[]): string {
  const points = [...runs].slice(0, 20).reverse();
  if (points.length < 2) return "";
  const bar = 4, gap = 1.5, hgt = 22;
  const max = Math.max(...points.map((r) => r.durationMs ?? 0), 1);
  const bars = points.map((r, i) => {
    const x = (i * (bar + gap)).toFixed(1);
    if (r.status === "running") return `<rect class="running" x="${x}" y="${hgt - 6.5}" width="${bar - 1}" height="6"/>`;
    const tall = Math.max(r.status === "ok" ? 2 : 6, ((r.durationMs ?? 0) / max) * hgt);
    const cls = r.status === "ok" ? "" : ` class="bad"`;
    return `<rect${cls} x="${x}" y="${(hgt - tall).toFixed(1)}" width="${bar}" height="${tall.toFixed(1)}" rx=".5"/>`;
  }).join("");
  const w = points.length * (bar + gap) - gap;
  return `<svg class="spark" width="${w.toFixed(1)}" height="${hgt}" viewBox="0 0 ${w.toFixed(1)} ${hgt}" aria-hidden="true" focusable="false">${bars}</svg>`;
}

function stamp(at: number | null, now: number): string {
  if (at === null) return `<span class="muted">never</span>`;
  const iso = new Date(at).toISOString();
  return `<time class="nowrap" datetime="${iso}" title="${iso.replace("T", " ").slice(0, 19)} UTC">${h(formatRelative(at, now))}</time>`;
}

/** Counts by health, the ones needing attention first; a zero is set faint rather than left out, so the row keeps its shape. */
function healthFigures(jobs: JobSummary[]): string {
  return `<dl class="figures">${(Object.keys(HEALTH) as JobSummary["health"][]).map((health) => {
    const [cls, label] = HEALTH[health];
    const n = jobs.filter((j) => j.health === health).length;
    return `<div class="${n === 0 ? "zero" : cls}"><dt><i class="sq ${cls}" aria-hidden="true"></i>${label}</dt><dd>${n}</dd></div>`;
  }).join("")}</dl>`;
}

export function dashboardPage(
  jobs: JobSummary[],
  runsByJob: Map<string, Run[]>,
  now: number,
  base: string,
  checkedAt: number | null,
  lanes: LaneInput[] = jobs.slice(0, BOARD_LANES).map((job) => ({ job, runs: runsByJob.get(job.name) ?? [], complete: true })),
): string {
  const attention = jobs.filter((j) => j.health !== "healthy").length;
  const headline = jobs.length === 0
    ? "No jobs yet."
    : attention === 0
      ? `${jobs.length === 1 ? "The one job is" : `All ${jobs.length} jobs are`} healthy.`
      : `${jobs.length} job${jobs.length === 1 ? "" : "s"}, <b>${attention} needing attention</b>.`;

  const rows = jobs.map((job) => {
    const last = job.lastRun;
    const d = job.definition;
    return `<tr>
<td class="job"><a class="name" href="${h(base)}/jobs/${encodeURIComponent(job.name)}">${h(job.name)}</a>${d.description ? `<span class="desc">${h(d.description)}</span>` : ""}</td>
<td class="health">${healthState(job)}</td>
<td class="nowrap hide-sm">${d.schedule ? `${h(d.schedule)}${d.timezone ? `<span class="tz">${h(d.timezone)}</span>` : ""}` : `<span class="muted">no schedule</span>`}</td>
<td class="nowrap last">${last ? `${runState(last)} ${stamp(last.startedAt, now)}${last.durationMs !== null ? `<span class="sub">took ${h(formatDuration(last.durationMs))}</span>` : ""}` : `<span class="muted">never</span>`}</td>
<td class="nowrap hide-sm">${job.nextExpectedAt !== null ? `${job.nextExpectedAt < now ? `<span class="state warn">overdue</span> ` : ""}${stamp(job.nextExpectedAt, now)}<span class="sub">${h(when(job.nextExpectedAt, now))} UTC</span>` : `<span class="muted">not scheduled</span>`}</td>
<td class="hide-sm">${sparkline(runsByJob.get(job.name) ?? [])}</td>
</tr>`;
  }).join("\n");

  const span = { from: now - BOARD_BEHIND_MS, to: now + BOARD_AHEAD_MS, now };
  const body = `
<header class="top">
  ${brand(base)}
  <div class="actions">
    <span class="meta">${h(clock(now))} UTC${checkedAt ? `, checked ${h(formatRelative(checkedAt, now))}` : ""}</span>
    <form class="inline" method="post" action="${h(base)}/check"><button class="primary" type="submit">Run check now</button></form>
  </div>
</header>
<main>
<section class="sec" aria-label="Health">
  <h2>Health</h2>
  <div>
    <p class="headline">${headline}</p>
    ${jobs.length ? healthFigures(jobs) : `<p class="empty">Declare one with <code>cw.job("name", { schedule: "0 2 * * *" })</code> and run it once, and it shows up here.</p>`}
  </div>
</section>
${jobs.length ? `<section class="sec" aria-label="Last 24 hours">
  <h2>Last 24 hours</h2>
  <p class="lede">One lane per job. Faint ticks mark when it was due, bars the runs it recorded, as long as they took. A dashed box is a slot nothing ran in. Times are UTC.</p>
  <div class="wide">${dayTimeline(lanes, span, base, jobs.length)}</div>
</section>
<section class="sec" aria-label="Jobs">
  <h2>Jobs</h2>
  <p class="lede">Every job in the store. Open one for its week, its runs and their output.</p>
  <div class="wide"><table class="board">
<thead><tr><th>Job</th><th>Health</th><th class="hide-sm">Schedule</th><th>Last run</th><th class="hide-sm">Next due</th><th class="hide-sm">Recent runs</th></tr></thead>
<tbody>${rows}</tbody></table></div>
</section>` : ""}
</main>
<footer><span>Refreshes every minute. Times are UTC.</span><a href="${h(base)}/api/jobs">JSON</a></footer>`;
  return layout("CronWatch", body, base, { refresh: 60 });
}

/**
 * One job: its state and figures, its last seven days, its runs with their
 * output, and its definition. `complete` is false when `runs` does not reach
 * back over the whole week (the run list shows the newest fifty).
 */
export function jobPage(job: JobSummary, runs: Run[], now: number, base: string, complete = true): string {
  const d = job.definition;
  const okRate = `${Math.round(job.stats.okRate * 100)}%`;
  const listed = runs.slice(0, 50);
  const runRows = listed.map((run) => {
    const detail = [
      run.error ? `<details class="out error" open><summary>error</summary><pre>${h(run.error)}</pre></details>` : "",
      run.output ? `<details class="out"${run.status === "ok" ? "" : " open"}><summary>output</summary><pre>${h(run.output)}</pre></details>` : "",
    ].join("");
    const metrics = Object.entries(run.metrics).map(([k, v]) => `<span><span class="k">${h(k)}</span> ${h(Number.isInteger(v) ? v : v.toFixed(4))}</span>`).join("");
    return `<tr${detail ? ` class="has-detail"` : ""}>
<td class="nowrap">${runState(run)}</td>
<td class="nowrap">${h(when(run.startedAt, now))} <span class="muted">UTC</span><span class="sub">${stamp(run.startedAt, now)}</span></td>
<td class="nowrap">${run.durationMs !== null ? h(formatDuration(run.durationMs)) : `<span class="muted">running</span>`}</td>
<td class="hide-sm">${metrics ? `<span class="metrics">${metrics}</span>` : ""}</td>
<td class="hide-sm muted">${h(run.trigger)}</td>
</tr>${detail ? `<tr class="detail"><td colspan="5">${detail}</td></tr>` : ""}`;
  }).join("\n");

  const silenced = job.silencedUntil !== null && job.silencedUntil > now;
  const path = `${h(base)}/jobs/${encodeURIComponent(job.name)}`;
  const parsed = parsedSchedule(job);
  const why = laneNote(job, missedAt(job, parsed, [], now), now);
  const body = `
<header class="top">
  ${brand(base, job.name)}
  <div class="actions"><span class="meta">${h(clock(now))} UTC</span></div>
</header>
<main>
<section class="sec intro" aria-label="Job">
  <h2>Job</h2>
  <div>
    <h1 class="jobname">${h(job.name)}</h1>
    ${d.description ? `<p class="desc">${h(d.description)}</p>` : ""}
    <p class="stateline">${healthState(job)}${why ? `<span class="why">${h(why)}</span>` : ""}</p>
    <div class="actions">
      ${silenced
        ? `<form class="inline" method="post" action="${path}/unsilence"><button type="submit">Unsilence (until ${h(formatRelative(job.silencedUntil!, now))})</button></form>`
        : `<form class="inline" method="post" action="${path}/silence"><select name="for" aria-label="Silence for"><option value="1h">1 hour</option><option value="4h">4 hours</option><option value="1d">1 day</option><option value="7d">1 week</option></select><button type="submit">Silence</button></form>`}
      <details class="confirm"><summary>Forget</summary><form class="inline" method="post" action="${path}/forget"><span>Remove this job and its runs from the store?</span> <button type="submit">Forget</button></form></details>
    </div>
    <dl class="figures">
      <div><dt>Last run</dt><dd>${job.lastRun ? h(formatRelative(job.lastRun.startedAt, now)) : "never"}</dd></div>
      <div><dt>Next due</dt><dd>${job.nextExpectedAt !== null ? h(formatRelative(job.nextExpectedAt, now)) : `<small>no schedule</small>`}</dd></div>
      <div><dt>Success, last ${h(job.stats.runs)}</dt><dd>${h(okRate)}</dd></div>
      <div><dt>p50 / p95</dt><dd>${job.stats.p50Ms !== null ? h(formatDuration(job.stats.p50Ms)) : "?"} <small>/ ${job.stats.p95Ms !== null ? h(formatDuration(job.stats.p95Ms)) : "?"}</small></dd></div>
    </dl>
  </div>
</section>
<section class="sec" aria-label="Last 7 days">
  <h2>Last 7 days</h2>
  <p class="lede">A lane per UTC day, today first. Faint ticks mark when the job was due, bars its runs, as long as they took.</p>
  <div class="wide">${weekTimeline(job, runs, complete, now)}</div>
</section>
<section class="sec" aria-label="Runs">
  <h2>Runs</h2>
  ${listed.length === 0 ? `<p class="lede">No runs yet.</p>` : `<p class="lede">The newest ${listed.length === 1 ? "run" : `${listed.length} runs`}, with any error and output.</p>
  <div class="wide"><table class="runs">
<thead><tr><th>Status</th><th>Started</th><th>Took</th><th class="hide-sm">Metrics</th><th class="hide-sm">Trigger</th></tr></thead>
<tbody>${runRows}</tbody></table></div>`}
</section>
<section class="sec" aria-label="Definition">
  <h2>Definition</h2>
  <dl class="def">
  <dt>Schedule</dt><dd>${d.schedule ? h(d.schedule) + (d.timezone ? ` <span class="muted">${h(d.timezone)}</span>` : "") : `<span class="muted">none</span>`}</dd>
  <dt>Grace</dt><dd>${h(d.grace ?? "10m")}</dd>
  <dt>Timeout</dt><dd>${h(d.timeout ?? "1h")}</dd>
  ${d.maxDuration ? `<dt>Max duration</dt><dd>${h(d.maxDuration)}</dd>` : ""}
  ${d.budget ? `<dt>Budget</dt><dd>${h(Object.entries(d.budget).map(([k, v]) => `${k} ≤ ${v}`).join(", "))}</dd>` : ""}
  ${d.expect ? `<dt>Expect</dt><dd>${h(d.expect)}</dd>` : ""}
  ${d.failuresBeforeAlert && d.failuresBeforeAlert > 1 ? `<dt>Alert after</dt><dd>${h(d.failuresBeforeAlert)} consecutive failures</dd>` : ""}
  ${d.tags?.length ? `<dt>Tags</dt><dd>${d.tags.map((t) => h(t)).join(", ")}</dd>` : ""}
  ${job.open.length ? `<dt>Open</dt><dd>${job.open.map((c) => `<span class="state ${c === "failed" || c === "stuck" ? "bad" : "warn"}">${h(c.replace("_", " "))}</span>`).join("")}</dd>` : ""}
  ${job.consecutiveFailures > 0 ? `<dt>Failures in a row</dt><dd>${h(job.consecutiveFailures)}</dd>` : ""}
  </dl>
</section>
</main>
<footer><span>Refreshes every minute. Times are UTC.</span><a href="${h(base)}/api/jobs/${encodeURIComponent(job.name)}">JSON</a></footer>`;
  return layout(`${job.name}: CronWatch`, body, base, { refresh: 60 });
}

/**
 * A page with one message. With `signIn`, a form under it takes the token
 * and sends it as ?token=, which the routes move into the cookie: the way in
 * where there is no address bar to open a link with, such as an app on an
 * iPhone's home screen, which keeps its cookies apart from Safari's.
 */
export function messagePage(title: string, message: string, base: string, signIn = false): string {
  const form = signIn ? `<form class="signin" method="get" action="${h(base)}/"><label for="token">Token</label><input id="token" name="token" type="password" autocomplete="current-password" autocapitalize="off" spellcheck="false" required><button class="primary" type="submit">Sign in</button></form>` : "";
  return layout(title, `<header class="top">${brand(base)}</header><main class="message"><h1>${h(title)}</h1><p>${h(message)}</p>${form}</main>`, base);
}
