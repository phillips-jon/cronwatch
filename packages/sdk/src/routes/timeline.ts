/**
 * The dashboard's timelines: one lane per job (or per day, on a job's page),
 * drawn on the server as inline SVG so the page needs no script.
 *
 * Every time a job was due is a faint tick, worked out from its schedule with
 * the same functions the checks use (nextFire and expectation), so the lane
 * shows the cadence the job is meant to keep. Every run it recorded is a
 * solid mark on top, as wide as it took and coloured by how it ended. A slot
 * the check has reported missed is a dashed box. The empty part of a lane
 * carries a short note about anything open, and a visually hidden list says
 * the same things in words.
 *
 * Every time is UTC: without script the page cannot know the viewer's zone.
 */
import { FIRST_DATE_MS, LAST_DATE_MS, formatDuration } from "../duration.js";
import { graceMs, isStuck, timeoutMs } from "../evaluate.js";
import { expectation, firesBetween, parseSchedule, type ParsedSchedule } from "../schedule.js";
import type { JobSummary, Run } from "../types.js";
import { escapeHtml as h, escapeName } from "./escape.js";

const HOUR = 3_600_000;
const DAY = 24 * HOUR;

/** The board's span: the last day, plus a few hours ahead so what is due soon shows. */
export const BOARD_BEHIND_MS = DAY;
export const BOARD_AHEAD_MS = 3 * HOUR;
/** How many jobs the board's timeline draws. The table below it lists every job. */
export const BOARD_LANES = 30;
/**
 * Runs read for a lane when the twenty the table reads start inside the span,
 * so a frequent job's lane is not cut short. Older runs than this are shown
 * as not loaded rather than as absent.
 */
export const BOARD_RUNS = 200;
/** How many days a job's page draws. */
export const WEEK_DAYS = 7;

/** Width of a lane in SVG units. Lanes stretch to fit, so strokes do not scale. */
const W = 1000;
/** A lane with more due times than this shows its cadence as a dotted line instead. */
const MAX_TICKS = 330;
/** More missed slots than this are drawn as one dashed band. */
const MAX_BOXES = 8;
/** The narrowest a missed box is drawn, in SVG units. */
const MIN_BOX = 10;

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

/** "22:42", in UTC. */
export function clock(t: number): string {
  return new Date(t).toISOString().slice(11, 16);
}

/** "Sat 26 Sep", in UTC. */
export function dayLabel(t: number): string {
  const d = new Date(t);
  return `${WEEKDAYS[d.getUTCDay()]} ${d.getUTCDate()} ${MONTHS[d.getUTCMonth()]}`;
}

/**
 * "22:42" on the same UTC day as `now`, otherwise "25 Sep 22:42", and
 * "1 Jan 0001 02:00" in another UTC year. A time before the year 1 or after
 * 9999 (a start read from a foreign or damaged row) is "before 1 Jan 0001
 * 00:00" or "after 31 Dec 9999 23:59".
 */
export function when(t: number, now: number): string {
  if (t > LAST_DATE_MS) return "after 31 Dec 9999 23:59";
  if (!(t >= FIRST_DATE_MS)) return "before 1 Jan 0001 00:00";
  if (Math.floor(t / DAY) === Math.floor(now / DAY)) return clock(t);
  const d = new Date(t);
  const year = d.getUTCFullYear();
  const other = year === new Date(now).getUTCFullYear() ? "" : ` ${String(year).padStart(4, "0")}`;
  return `${d.getUTCDate()} ${MONTHS[d.getUTCMonth()]}${other} ${clock(t)}`;
}

/** The stretch of time a timeline draws, and the moment it was drawn. */
export interface Span {
  from: number;
  to: number;
  now: number;
}

/** The job's schedule, parsed, or null when it has none or it no longer parses. */
export function parsedSchedule(job: JobSummary): ParsedSchedule | null {
  if (!job.definition.schedule) return null;
  try {
    return parseSchedule(job.definition.schedule, job.definition.timezone);
  } catch {
    return null;
  }
}

function safely<T>(fn: () => T, fallback: T): T {
  try {
    return fn();
  } catch {
    return fallback;
  }
}

export interface DueTimes {
  /** Every time the job was or will be due within the span, ascending. */
  times: number[];
  /** True when there are too many to draw one by one; `times` is then empty. */
  dense: boolean;
}

/**
 * When the job was due within `from` to `to`. A cron's fires come from
 * nextFire. An interval is due one period after each run started, and after
 * the last run once a period for as long as nothing runs (the times a
 * missed interval job keeps being asked for); with no run yet, from its
 * next expected time.
 */
export function dueTimes(job: JobSummary, parsed: ParsedSchedule | null, runs: Run[], from: number, to: number): DueTimes {
  if (!parsed) return { times: [], dense: false };
  if (parsed.kind === "interval") {
    const every = parsed.everyMs!;
    if ((to - from) / every > MAX_TICKS) return { times: [], dense: true };
    const starts = runs.map((r) => r.startedAt).sort((a, b) => a - b);
    const times = new Set<number>();
    for (const start of starts) {
      const t = start + every;
      if (t >= from && t <= to) times.add(t);
    }
    let t = starts.length ? starts[starts.length - 1]! + every : job.nextExpectedAt;
    if (t !== null) {
      if (t < from) t += Math.ceil((from - t) / every) * every;
      for (; t <= to; t += every) times.add(t);
    }
    return { times: [...times].sort((a, b) => a - b), dense: false };
  }
  const times = safely(() => firesBetween(parsed, from - 1, to, MAX_TICKS), []);
  return times === null ? { times: [], dense: true } : { times, dense: false };
}

/**
 * The slot a missed job was due at, the one the check reported: the first
 * fire its last run does not cover (expectation(), as onCheck works it
 * out). A job that never ran has no run to count from, so the latest due
 * time whose grace has passed stands in. Null when missed is not open.
 */
export function missedAt(job: JobSummary, parsed: ParsedSchedule | null, times: number[], now: number): number | null {
  if (!parsed || !job.open.includes("missed")) return null;
  const grace = safely(() => graceMs(job.definition), 0);
  const last = job.lastRun?.startedAt ?? null;
  if (last !== null) return safely(() => expectation(parsed, last, last, grace)?.dueAt ?? null, null);
  const past = times.filter((t) => t + grace < now);
  return past.length ? past[past.length - 1]! : null;
}

type Tone = "ok" | "bad" | "timeout" | "warn" | "running" | "stuck";

function toneOf(run: Run, job: JobSummary, now: number): Tone {
  if (run.status === "running") return safely(() => isStuck(job.definition, run, now), false) ? "stuck" : "running";
  if (run.status === "failed") return "bad";
  if (run.status === "timeout") return "timeout";
  const latest = job.lastRun?.id === run.id;
  return latest && (job.open.includes("over_budget") || job.open.includes("under_floor") || job.open.includes("slow")) ? "warn" : "ok";
}

function timeoutText(job: JobSummary): string {
  return safely(() => formatDuration(timeoutMs(job.definition)), "configured");
}

/** One run, as its tooltip says it. */
function describeRun(run: Run, tone: Tone, job: JobSummary, now: number): string {
  const at = `${when(run.startedAt, now)} UTC`;
  if (tone === "running") return `running since ${at}, ${formatDuration(now - run.startedAt)} so far`;
  if (tone === "stuck") return `running since ${at}, past its ${timeoutText(job)} timeout`;
  const took = run.durationMs !== null ? `, took ${formatDuration(run.durationMs)}` : "";
  const extra = tone === "warn" ? (job.open.includes("over_budget") ? ", over budget" : job.open.includes("under_floor") ? ", under floor" : ", slow") : "";
  return `${run.status} at ${at}${took}${extra}`;
}

/** The metrics of the job's last run that went over their ceilings. */
function overCeilings(job: JobSummary): string[] {
  const metrics = job.lastRun?.metrics ?? {};
  return Object.entries(job.definition.budget ?? {}).filter(([k, limit]) => (metrics[k] ?? -Infinity) > limit).map(([k]) => k);
}

/** The metrics of the job's last run under their floors, or at 0 or less without one. */
function underFloors(job: JobSummary): string[] {
  const floors = job.definition.floor ?? {};
  return Object.entries(job.lastRun?.metrics ?? {}).filter(([k, v]) => (floors[k] !== undefined ? v < floors[k] : v <= 0)).map(([k]) => k);
}

/** What is worth saying about the job in a few words, or null when all is well. */
export function laneNote(job: JobSummary, missed: number | null, now: number): string | null {
  const last = job.lastRun;
  if (job.silencedUntil !== null && job.silencedUntil > now) return `silenced until ${when(job.silencedUntil, now)}`;
  if (job.open.includes("missed")) return missed !== null ? `due ${when(missed, now)}, nothing ran` : "overdue, nothing ran";
  if (last?.status === "running") {
    const stuck = safely(() => isStuck(job.definition, last, now), false);
    return stuck ? `running since ${when(last.startedAt, now)}, past its ${timeoutText(job)} timeout` : `running since ${when(last.startedAt, now)}`;
  }
  if (last?.status === "failed") return `failed at ${when(last.startedAt, now)}${job.consecutiveFailures > 1 ? `, ${job.consecutiveFailures} in a row` : ""}`;
  if (last?.status === "timeout") return `timed out at ${when(last.startedAt, now)}`;
  if (job.open.includes("stuck")) return "stuck";
  if (job.open.includes("over_budget") && last) {
    const over = overCeilings(job);
    return `went over budget${over.length ? ` on ${over.join(" and ")}` : ""} at ${when(last.startedAt, now)}`;
  }
  if (job.open.includes("under_floor") && last) {
    const under = underFloors(job);
    return `fell short${under.length ? ` on ${under.join(" and ")}` : ""} at ${when(last.startedAt, now)}`;
  }
  if (job.open.includes("slow") && last?.durationMs != null) return `slow: took ${formatDuration(last.durationMs)}`;
  if (job.open.includes("failed")) return "failing";
  if (!last && job.nextExpectedAt !== null) return `no runs yet, first due ${when(job.nextExpectedAt, now)}`;
  return null;
}

/** Everything one lane shows: the marks, the note, and the same in words. */
export interface LaneInput {
  job: JobSummary;
  /** The job's runs, any order. Only those overlapping the span are drawn. */
  runs: Run[];
  /** False when older runs exist that were not read; the lane says so before its oldest run. */
  complete: boolean;
}

interface LaneParts {
  svg: string;
  note: string;
  words: string;
}

const f = (n: number) => n.toFixed(1);

/** Animation delay for a mark at x, so marks arrive in time order, left to right. */
const delay = (x: number, base = 80, perUnit = 0.75) => `--d:${Math.round(base + Math.max(0, x) * perUnit)}ms`;

function lane(input: LaneInput, span: Span, options: { nowInLane: boolean; label: string }): LaneParts {
  const { job } = input;
  const { from, to, now } = span;
  const x = (t: number) => Math.min(W, Math.max(0, ((t - from) / (to - from)) * W));
  const parsed = parsedSchedule(job);
  const due = dueTimes(job, parsed, input.runs, from, to);
  const missed = missedAt(job, parsed, due.times, now);
  const grace = safely(() => graceMs(job.definition), 0);
  const name = options.label;
  const busy: [number, number][] = [];

  let s = `<svg class="marks" viewBox="0 0 ${W} 24" preserveAspectRatio="none" aria-hidden="true" focusable="false">`;
  if (options.nowInLane && now > from && now < to) s += `<rect class="ahead" x="${f(x(now))}" y="0" width="${f(W - x(now))}" height="24"/>`;
  s += `<line class="base" x1="0" y1="12" x2="${W}" y2="12"/>`;

  const inSpan = input.runs.filter((r) => r.startedAt <= to && (r.finishedAt ?? now) >= from).sort((a, b) => a.startedAt - b.startedAt);
  if (!input.complete) {
    const oldest = Math.min(...input.runs.map((r) => r.startedAt));
    if (Number.isFinite(oldest) && oldest > from) {
      s += `<rect class="unloaded" x="0" y="4" width="${f(x(oldest))}" height="16"><title>${h(`${name}: runs before ${when(oldest, now)} UTC are not loaded here`)}</title></rect>`;
    }
  }

  if (due.dense) {
    s += `<line class="cadence" x1="0" y1="12" x2="${W}" y2="12"><title>${h(`${name}: due ${job.definition.schedule ?? ""}, too often to mark each time`)}</title></line>`;
  }
  for (const t of due.times) {
    const tx = x(t);
    s += `<line class="tick${t > now ? " ahead" : ""}" x1="${f(tx)}" y1="6" x2="${f(tx)}" y2="18" style="${delay(tx, 0, 0.45)}"/>`;
  }

  // Missed slots: the reported one and every later one whose grace has run out.
  if (missed !== null && missed <= to) {
    const slots = due.dense ? [] : due.times.filter((t) => t >= missed && t + grace < now);
    if (!slots.includes(missed) && missed >= from) slots.unshift(missed);
    const title = h(`${name}: due ${when(missed, now)} UTC, nothing started${slots.length > 1 ? ` (${slots.length} slots in this span)` : ""}`);
    if (due.dense || slots.length > MAX_BOXES) {
      const x1 = x(Math.max(missed, from)), x2 = Math.max(x(now), x1 + MIN_BOX);
      s += `<rect class="missed" x="${f(x1)}" y="5" width="${f(x2 - x1)}" height="14" style="${delay(x1)}"><title>${title}</title></rect>`;
      busy.push([x1, x2]);
    } else {
      for (const t of slots) {
        if (t < from) continue;
        const x1 = x(t), width = Math.max(x(t + grace) - x1, MIN_BOX);
        s += `<rect class="missed" x="${f(x1)}" y="5" width="${f(width)}" height="14" style="${delay(x1)}"><title>${title}</title></rect>`;
        busy.push([x1, x1 + width]);
      }
    }
  }

  for (const run of inSpan) {
    const tone = toneOf(run, job, now);
    // A zero-width rect is not drawn at all; its stroke gives short runs their width.
    const x1 = x(run.startedAt), x2 = Math.max(x(run.finishedAt ?? now), x1 + 0.5);
    s += `<rect class="run ${tone}" x="${f(x1)}" y="5" width="${f(x2 - x1)}" height="14" style="${delay(x1)}"><title>${h(`${name}: ${describeRun(run, tone, job, now)}`)}</title></rect>`;
    busy.push([x1, x2]);
  }

  if (options.nowInLane && now > from && now < to) s += `<line class="nowline" x1="${f(x(now))}" y1="0" x2="${f(x(now))}" y2="24"/>`;
  s += `</svg>`;

  // The note goes wherever the lane is actually empty, so it never sits on
  // the marks it describes; it is cut short with an ellipsis when narrow.
  const text = laneNote(job, missed, now);
  let note = "";
  if (text) {
    const nowX = x(now);
    const lo = busy.length ? Math.min(...busy.map((b) => b[0])) : nowX;
    const hi = busy.length ? Math.max(...busy.map((b) => b[1])) : nowX;
    const right = W - hi >= lo;
    const room = right ? W - hi : lo;
    if (room > 90) {
      const edge = right ? hi + 14 : lo - 14;
      const place = right ? `left:${f(edge / 10)}%` : `right:${f(100 - edge / 10)}%`;
      note = `<span class="note${right ? "" : " before"}" style="${place};max-width:${f((room - 18) / 10)}%">${h(text)}</span>`;
    }
  }

  return { svg: s, note, words: words(job, inSpan, due, missed, span, text) };
}

/** The lane in words, for anyone who cannot see it. */
function words(job: JobSummary, runs: Run[], due: DueTimes, missed: number | null, span: Span, note: string | null): string {
  const parts: string[] = [];
  if (due.dense) parts.push(`due ${job.definition.schedule}`);
  else if (job.definition.schedule) {
    const n = due.times.filter((t) => t <= span.now).length;
    parts.push(`due ${n === 0 ? "no times" : n === 1 ? "once" : `${n} times`} so far`);
  }
  const ok = runs.filter((r) => r.status === "ok").length;
  parts.push(`${runs.length} ${runs.length === 1 ? "run" : "runs"} recorded${!runs.length ? "" : ok === runs.length ? (ok === 1 ? ", ok" : ", all ok") : ok ? `, ${ok} ok` : ""}`);
  for (const r of runs.filter((r) => r.status === "failed" || r.status === "timeout").slice(-5)) {
    parts.push(`${r.status} at ${when(r.startedAt, span.now)} UTC after ${formatDuration(r.durationMs ?? 0)}`);
  }
  if (missed !== null) parts.push(`due at ${when(missed, span.now)} UTC and nothing started`);
  if (note && !/^(due |failed at|timed out)/.test(note)) parts.push(note);
  return parts.join("; ");
}

/** Grid lines and hour labels every `step`, on UTC boundaries. */
function hours(span: Span, step: number, nowLabel: boolean): { lines: string; labels: string } {
  const x = (t: number) => ((t - span.from) / (span.to - span.from)) * W;
  const nowX = x(span.now);
  let lines = "", labels = "";
  for (let t = Math.ceil(span.from / step) * step; t <= span.to; t += step) {
    const gx = x(t);
    lines += `<i class="gl" style="left:${f(gx / 10)}%"></i>`;
    const nearNow = nowLabel && Math.abs(gx - nowX) < 70;
    if (gx < 25 || gx > W - 25 || nearNow) continue;
    const minor = Math.round(t / HOUR) % 6 !== 0;
    // On a phone the track is too narrow for a label this close to "now"; CSS hides it there.
    const near = nowLabel && Math.abs(gx - nowX) < 170;
    const cls = [minor && "minor", near && "near"].filter(Boolean).join(" ");
    labels += `<span class="${cls}" style="left:${f(gx / 10)}%">${clock(t)}</span>`;
  }
  if (nowLabel && span.now >= span.from && span.now <= span.to) labels += `<span class="nowlabel" style="left:${f(nowX / 10)}%">now ${clock(span.now)}</span>`;
  return { lines, labels };
}

/** The key under a timeline: a small sample of each mark and what it means. */
function legend(): string {
  const key = (inner: string) => `<svg class="key" viewBox="0 0 16 12" aria-hidden="true" focusable="false">${inner}</svg>`;
  const box = (cls: string) => key(`<rect class="${cls}" x="2" y="1" width="12" height="10"/>`);
  const items: [string, string][] = [
    [key(`<line class="tick" x1="8" y1="1" x2="8" y2="11"/>`), "due"],
    [box("run ok"), "ran"],
    [box("run bad"), "failed"],
    [box("run timeout"), "timed out"],
    [box("run warn"), "over budget, under floor or slow"],
    [box("run running"), "running"],
    [box("missed"), "missed"],
  ];
  return `<p class="legend" aria-hidden="true">${items.map(([k, label]) => `<span>${k}${label}</span>`).join("")}</p>`;
}

function stateClass(job: JobSummary): string {
  return ({ healthy: "ok", late: "warn", failing: "bad", stuck: "bad", silenced: "muted", never_ran: "muted" } as const)[job.health];
}

/**
 * The board's timeline: one lane per job across `span`, with a shared now
 * line and the first BOARD_LANES jobs only. `total` is how many jobs there
 * are in all, for the note when some are left out.
 */
export function dayTimeline(lanes: LaneInput[], span: Span, base: string, total: number): string {
  const grid = hours(span, 3 * HOUR, true);
  const nowX = ((span.now - span.from) / (span.to - span.from)) * 100;
  const rows = lanes.map((input) => {
    const { job } = input;
    const parts = lane(input, span, { nowInLane: false, label: job.name });
    return {
      html: `<li class="lane"><div class="who"><i class="sq ${stateClass(job)}" aria-hidden="true"></i><a class="name" href="${h(base)}/jobs/${encodeURIComponent(job.name)}">${escapeName(job.name)}</a><span class="sched">${h(job.definition.schedule ?? "no schedule")}</span></div><div class="track">${parts.svg}${parts.note}</div></li>`,
      words: `<li>${h(`${job.name} (${job.definition.schedule ?? "no schedule"}): ${parts.words}.`)}</li>`,
    };
  });
  const more = total > lanes.length ? `<p class="more">Showing the first ${lanes.length} of ${total} jobs here; the table below lists them all.</p>` : "";
  return `<figure class="timeline day">
<div class="axis" aria-hidden="true"><span></span><div class="hours">${grid.labels}</div></div>
<div class="field">
<div class="under" aria-hidden="true"><span></span><div>${grid.lines}<i class="future" style="left:${f(nowX)}%"></i></div></div>
<ol class="lanes">${rows.map((r) => r.html).join("")}</ol>
<div class="over" aria-hidden="true"><span></span><div><i class="now" style="left:${f(nowX)}%"></i></div></div>
</div>
${legend()}${more}
<ul class="vh">${rows.map((r) => r.words).join("")}</ul>
</figure>`;
}

/**
 * A job's page: its last WEEK_DAYS UTC days, today first, one lane each.
 * `complete` is false when the runs read do not reach back over the week.
 */
export function weekTimeline(job: JobSummary, runs: Run[], complete: boolean, now: number): string {
  const today = Math.floor(now / DAY) * DAY;
  const oldest = runs.length ? Math.min(...runs.map((r) => r.startedAt)) : null;
  const first: Span = { from: today, to: today + DAY, now };
  const grid = hours(first, 3 * HOUR, false);
  const rows: { html: string; words: string }[] = [];
  for (let i = 0; i < WEEK_DAYS; i++) {
    const from = today - i * DAY;
    const span: Span = { from, to: from + DAY, now };
    const dayRuns = runs.filter((r) => r.startedAt < span.to && (r.finishedAt ?? now) >= from);
    const known = complete || (oldest !== null && oldest <= from);
    const label = i === 0 ? "today" : dayLabel(from);
    const parts = lane({ job, runs, complete: known }, span, { nowInLane: i === 0, label: `${job.name}, ${label}` });
    const count = `${dayRuns.length} ${dayRuns.length === 1 ? "run" : "runs"}`;
    rows.push({
      html: `<li class="lane${i === 0 ? " today" : ""}"><div class="who"><span class="name">${h(i === 0 ? `Today, ${dayLabel(from).slice(4)}` : dayLabel(from))}</span><span class="sched">${h(count)}</span></div><div class="track">${parts.svg}${i === 0 ? parts.note : ""}</div></li>`,
      words: `<li>${h(`${i === 0 ? "Today" : dayLabel(from)}: ${parts.words}.`)}</li>`,
    });
  }
  return `<figure class="timeline week">
<div class="axis" aria-hidden="true"><span></span><div class="hours">${grid.labels}</div></div>
<div class="field">
<div class="under" aria-hidden="true"><span></span><div>${grid.lines}</div></div>
<ol class="lanes">${rows.map((r) => r.html).join("")}</ol>
</div>
${legend()}
<ul class="vh">${rows.map((r) => r.words).join("")}</ul>
</figure>`;
}

/**
 * How many runs a job's page reads so its week is drawn in full: roughly how
 * often the schedule was due over the week, with room to spare, from 50 (what
 * the run list shows) to 500 (the most runs() returns).
 */
export function weekRunsLimit(job: JobSummary, now: number): number {
  const parsed = parsedSchedule(job);
  if (!parsed) return 50;
  const from = Math.floor(now / DAY) * DAY - (WEEK_DAYS - 1) * DAY;
  const span = now + DAY - from;
  // A cron's fires over one day, times the week: close enough, and cheap.
  const expected = parsed.kind === "interval"
    ? span / parsed.everyMs!
    : (() => {
        const due = dueTimes(job, parsed, [], now - DAY, now);
        return due.dense ? Infinity : (due.times.length * span) / DAY;
      })();
  return Math.min(500, Math.max(50, Math.ceil(expected * 1.2) + 10));
}
