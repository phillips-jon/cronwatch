import { formatDuration, formatRelative } from "../duration.js";
import type { JobSummary, Run } from "../types.js";

export function escapeHtml(value: unknown): string {
  return String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

const h = escapeHtml;

const CSS = `
:root{--bg:#fbfbf9;--fg:#1b1b18;--muted:#6b6b64;--line:#e6e5df;--card:#fff;--ok:#1f8a4c;--warn:#b7791f;--bad:#c62828;--info:#2b5fb3;--pill:#f1f0ea;--mono:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;--sans:-apple-system,BlinkMacSystemFont,"Segoe UI",Inter,Roboto,sans-serif}
@media(prefers-color-scheme:dark){:root{--bg:#121311;--fg:#ecece6;--muted:#9a9a91;--line:#2a2b27;--card:#1a1b18;--pill:#24251f}}
*{box-sizing:border-box}html{-webkit-text-size-adjust:100%}
body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.5 var(--sans)}
a{color:inherit}main{max-width:1080px;margin:0 auto;padding:24px 16px 64px}
header{display:flex;align-items:baseline;justify-content:space-between;gap:16px;flex-wrap:wrap;margin-bottom:20px}
header h1{font-size:18px;margin:0;letter-spacing:-.01em}header h1 a{text-decoration:none}
header .meta{color:var(--muted);font-size:13px}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;overflow:hidden}
table{width:100%;border-collapse:collapse;font-size:14px}
th{text-align:left;font-weight:600;color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.04em;padding:10px 12px;border-bottom:1px solid var(--line);white-space:nowrap}
td{padding:10px 12px;border-bottom:1px solid var(--line);vertical-align:top}
tr:last-child td{border-bottom:0}
.name{font-weight:600;white-space:nowrap}.name a{text-decoration:none}.name a:hover{text-decoration:underline}
.mono{font-family:var(--mono);font-size:13px}.muted{color:var(--muted)}.nowrap{white-space:nowrap}
.pill{display:inline-flex;align-items:center;gap:6px;padding:2px 9px;border-radius:999px;background:var(--pill);font-size:12px;font-weight:600;white-space:nowrap}
.pill::before{content:"";width:7px;height:7px;border-radius:50%;background:currentColor}
.ok{color:var(--ok)}.warn{color:var(--warn)}.bad{color:var(--bad)}.info{color:var(--info)}.mutedpill{color:var(--muted)}
.spark{display:block}
form.inline{display:inline}
button,select{font:inherit;font-size:13px;padding:5px 10px;border:1px solid var(--line);border-radius:7px;background:var(--card);color:var(--fg);cursor:pointer}
button:hover{border-color:var(--muted)}
.actions{display:flex;gap:8px;align-items:center;flex-wrap:wrap}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:12px;margin:0 0 20px}
.stat{padding:12px 14px}.stat .k{font-size:12px;color:var(--muted);text-transform:uppercase;letter-spacing:.04em}.stat .v{font-size:20px;font-weight:600;margin-top:2px}
pre{margin:0;padding:10px 12px;background:var(--pill);border-radius:8px;font:12.5px/1.45 var(--mono);white-space:pre-wrap;word-break:break-word;max-height:320px;overflow:auto}
details summary{cursor:pointer;color:var(--muted);font-size:13px}details{margin-top:6px}
details.confirm{margin:0}details.confirm summary{list-style:none;display:inline-block;font-size:13px;padding:5px 10px;border:1px solid var(--line);border-radius:7px;background:var(--card);color:var(--fg)}
details.confirm summary::-webkit-details-marker{display:none}details.confirm[open] summary{border-color:var(--muted)}details.confirm form{margin-left:8px;font-size:13px}
.empty{padding:40px 16px;text-align:center;color:var(--muted)}
dl{display:grid;grid-template-columns:max-content 1fr;gap:6px 16px;margin:0;padding:14px 16px;font-size:14px}dt{color:var(--muted)}dd{margin:0}
footer{margin-top:28px;color:var(--muted);font-size:12px}
@media(max-width:720px){.hide-sm{display:none}main{padding:16px 16px 48px}}
`;

export function layout(title: string, body: string, options: { refresh?: number } = {}): string {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow">
${options.refresh ? `<meta http-equiv="refresh" content="${options.refresh}">` : ""}
<title>${h(title)}</title>
<style>${CSS}</style>
</head>
<body><main>${body}</main></body>
</html>`;
}

function healthPill(job: JobSummary): string {
  const map: Record<JobSummary["health"], [string, string]> = {
    healthy: ["ok", "healthy"],
    late: ["warn", "late"],
    failing: ["bad", "failing"],
    stuck: ["bad", "stuck"],
    silenced: ["mutedpill", "silenced"],
    never_ran: ["info", "never ran"],
  };
  const [cls, label] = map[job.health];
  const extras = job.open.filter((c) => !["missed", "failed", "stuck"].includes(c)).map((c) => c.replace("_", " "));
  return `<span class="pill ${cls}">${label}</span>${extras.length ? ` <span class="pill warn">${h(extras.join(", "))}</span>` : ""}`;
}

function runPill(run: Run): string {
  const cls = run.status === "ok" ? "ok" : run.status === "running" ? "info" : "bad";
  return `<span class="pill ${cls}">${h(run.status)}</span>`;
}

function sparkline(runs: Run[]): string {
  const points = [...runs].reverse().filter((r) => r.durationMs !== null).slice(-20);
  if (points.length < 2) return "";
  const w = 96, hgt = 22;
  const max = Math.max(...points.map((r) => r.durationMs!), 1);
  const step = w / (points.length - 1);
  const path = points.map((r, i) => `${i === 0 ? "M" : "L"}${(i * step).toFixed(1)},${(hgt - 2 - (r.durationMs! / max) * (hgt - 4)).toFixed(1)}`).join(" ");
  const dots = points.map((r, i) => r.status === "ok" ? "" : `<circle cx="${(i * step).toFixed(1)}" cy="${(hgt - 2 - (r.durationMs! / max) * (hgt - 4)).toFixed(1)}" r="2.2" fill="var(--bad)"/>`).join("");
  return `<svg class="spark" width="${w}" height="${hgt}" viewBox="0 0 ${w} ${hgt}" aria-hidden="true"><path d="${path}" fill="none" stroke="var(--muted)" stroke-width="1.5"/>${dots}</svg>`;
}

function stamp(at: number | null, now: number): string {
  if (at === null) return `<span class="muted">never</span>`;
  const iso = new Date(at).toISOString().replace("T", " ").slice(0, 19);
  return `<span class="nowrap" title="${iso} UTC">${h(formatRelative(at, now))}</span>`;
}

export function dashboardPage(jobs: JobSummary[], runsByJob: Map<string, Run[]>, now: number, base: string, checkedAt: number | null): string {
  const rows = jobs.map((job) => {
    const last = job.lastRun;
    return `<tr>
<td class="name"><a href="${h(base)}/jobs/${encodeURIComponent(job.name)}">${h(job.name)}</a>${job.definition.description ? `<div class="muted" style="font-weight:400;font-size:13px;white-space:normal">${h(job.definition.description)}</div>` : ""}</td>
<td>${healthPill(job)}</td>
<td class="mono nowrap">${h(job.definition.schedule ?? "")}<span class="muted">${job.definition.schedule ? "" : "no schedule"}</span></td>
<td class="nowrap">${last ? `${runPill(last)} ${stamp(last.startedAt, now)}${last.durationMs !== null ? ` <span class="muted">${h(formatDuration(last.durationMs))}</span>` : ""}` : `<span class="muted">never</span>`}</td>
<td class="nowrap hide-sm">${stamp(job.nextExpectedAt, now)}</td>
<td class="hide-sm">${sparkline(runsByJob.get(job.name) ?? [])}</td>
</tr>`;
  }).join("\n");

  const body = `
<header>
  <h1><a href="${h(base)}/">CronWatch</a></h1>
  <div class="actions">
    <span class="meta">${jobs.length} job${jobs.length === 1 ? "" : "s"}${checkedAt ? `, checked ${h(formatRelative(checkedAt, now))}` : ""}</span>
    <form class="inline" method="post" action="${h(base)}/check"><button type="submit">Run check now</button></form>
  </div>
</header>
<div class="card">
${jobs.length === 0 ? `<div class="empty">No jobs yet. Declare one with <code class="mono">cw.job("name", { schedule: "0 2 * * *" })</code> and run it once.</div>` : `<table>
<thead><tr><th>Job</th><th>Health</th><th>Schedule</th><th>Last run</th><th class="hide-sm">Next due</th><th class="hide-sm">Durations</th></tr></thead>
<tbody>${rows}</tbody></table>`}
</div>
<footer>Refreshes every minute. <a href="${h(base)}/api/jobs">JSON</a></footer>`;
  return layout("CronWatch", body, { refresh: 60 });
}

export function jobPage(job: JobSummary, runs: Run[], now: number, base: string): string {
  const d = job.definition;
  const okRate = `${Math.round(job.stats.okRate * 100)}%`;
  const runRows = runs.map((run) => {
    const detail = [
      run.error ? `<details open><summary>error</summary><pre>${h(run.error)}</pre></details>` : "",
      run.output ? `<details${run.status === "ok" ? "" : " open"}><summary>output</summary><pre>${h(run.output)}</pre></details>` : "",
    ].join("");
    const metrics = Object.entries(run.metrics).map(([k, v]) => `<span class="pill mutedpill">${h(k)} ${h(Number.isInteger(v) ? v : v.toFixed(4))}</span>`).join(" ");
    return `<tr>
<td class="nowrap">${runPill(run)}</td>
<td class="nowrap">${stamp(run.startedAt, now)}</td>
<td class="nowrap">${run.durationMs !== null ? h(formatDuration(run.durationMs)) : `<span class="muted">running</span>`}</td>
<td class="hide-sm">${metrics}</td>
<td class="mono hide-sm muted">${h(run.trigger)}</td>
</tr>${detail ? `<tr><td colspan="5" style="padding-top:0">${detail}</td></tr>` : ""}`;
  }).join("\n");

  const silenced = job.silencedUntil !== null && job.silencedUntil > now;
  const body = `
<header>
  <h1><a href="${h(base)}/">CronWatch</a> <span class="muted">/</span> ${h(job.name)}</h1>
  <div class="actions">
    ${healthPill(job)}
    ${silenced
      ? `<form class="inline" method="post" action="${h(base)}/jobs/${encodeURIComponent(job.name)}/unsilence"><button type="submit">Unsilence (until ${h(formatRelative(job.silencedUntil!, now))})</button></form>`
      : `<form class="inline" method="post" action="${h(base)}/jobs/${encodeURIComponent(job.name)}/silence"><select name="for"><option value="1h">1 hour</option><option value="4h">4 hours</option><option value="1d">1 day</option><option value="7d">1 week</option></select> <button type="submit">Silence</button></form>`}
    <details class="confirm"><summary>Forget</summary><form class="inline" method="post" action="${h(base)}/jobs/${encodeURIComponent(job.name)}/forget"><span class="muted">Remove this job and its runs from the store?</span> <button type="submit">Forget</button></form></details>
  </div>
</header>
<div class="grid">
  <div class="card stat"><div class="k">Last run</div><div class="v">${job.lastRun ? h(formatRelative(job.lastRun.startedAt, now)) : "never"}</div></div>
  <div class="card stat"><div class="k">Next due</div><div class="v">${job.nextExpectedAt ? h(formatRelative(job.nextExpectedAt, now)) : "no schedule"}</div></div>
  <div class="card stat"><div class="k">Success, last ${h(job.stats.runs)}</div><div class="v">${h(okRate)}</div></div>
  <div class="card stat"><div class="k">p50 / p95</div><div class="v">${job.stats.p50Ms !== null ? h(formatDuration(job.stats.p50Ms)) : "?"} <span class="muted">/</span> ${job.stats.p95Ms !== null ? h(formatDuration(job.stats.p95Ms)) : "?"}</div></div>
</div>
<div class="card" style="margin-bottom:20px">
<dl>
  <dt>Schedule</dt><dd class="mono">${d.schedule ? h(d.schedule) + (d.timezone ? ` <span class="muted">${h(d.timezone)}</span>` : "") : `<span class="muted">none</span>`}</dd>
  <dt>Grace</dt><dd class="mono">${h(d.grace ?? "10m")}</dd>
  <dt>Timeout</dt><dd class="mono">${h(d.timeout ?? "1h")}</dd>
  ${d.maxDuration ? `<dt>Max duration</dt><dd class="mono">${h(d.maxDuration)}</dd>` : ""}
  ${d.budget ? `<dt>Budget</dt><dd class="mono">${h(Object.entries(d.budget).map(([k, v]) => `${k} ≤ ${v}`).join(", "))}</dd>` : ""}
  ${d.expect ? `<dt>Expect</dt><dd class="mono">${h(d.expect)}</dd>` : ""}
  ${d.failuresBeforeAlert && d.failuresBeforeAlert > 1 ? `<dt>Alert after</dt><dd>${h(d.failuresBeforeAlert)} consecutive failures</dd>` : ""}
  ${d.description ? `<dt>Description</dt><dd>${h(d.description)}</dd>` : ""}
  ${d.tags?.length ? `<dt>Tags</dt><dd>${d.tags.map((t) => `<span class="pill mutedpill">${h(t)}</span>`).join(" ")}</dd>` : ""}
  ${job.open.length ? `<dt>Open</dt><dd>${job.open.map((c) => `<span class="pill warn">${h(c.replace("_", " "))}</span>`).join(" ")}</dd>` : ""}
  ${job.consecutiveFailures > 0 ? `<dt>Consecutive failures</dt><dd>${h(job.consecutiveFailures)}</dd>` : ""}
</dl>
</div>
<div class="card">
${runs.length === 0 ? `<div class="empty">No runs yet.</div>` : `<table>
<thead><tr><th>Status</th><th>Started</th><th>Duration</th><th class="hide-sm">Metrics</th><th class="hide-sm">Trigger</th></tr></thead>
<tbody>${runRows}</tbody></table>`}
</div>
<footer><a href="${h(base)}/api/jobs/${encodeURIComponent(job.name)}">JSON</a></footer>`;
  return layout(`${job.name}: CronWatch`, body, { refresh: 60 });
}

export function messagePage(title: string, message: string, base: string): string {
  return layout(title, `<header><h1><a href="${h(base)}/">CronWatch</a></h1></header><div class="card"><div class="empty"><strong>${h(title)}</strong><br>${h(message)}</div></div>`);
}
