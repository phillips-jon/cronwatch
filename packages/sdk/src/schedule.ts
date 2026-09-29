import { Cron } from "croner";
import { FIRST_DATE_MS, LAST_DATE_MS, parseDuration } from "./duration.js";

export interface ParsedSchedule {
  kind: "cron" | "interval";
  source: string;
  /** The IANA timezone a cron is read in, when one was given. */
  timezone?: string;
  /** For intervals, the period in milliseconds. */
  everyMs?: number;
}

const cache = new Map<string, ParsedSchedule>();
/** The croner instance behind each cron schedule, kept out of the public type. */
const crons = new WeakMap<ParsedSchedule, Cron>();

/** How early a run may start and still count for the fire it was meant for. */
export const EARLY_SLACK_MS = 60_000;

/**
 * "0 2 * * *" (cron, five or six fields), "@hourly", or "every 5m".
 * Parsed once per (schedule, timezone) pair and cached. The croner instance
 * gets no callback, so it schedules nothing; it is only used to compute fire
 * times. Without a timezone the expression is read in the process timezone,
 * like crontab. Vercel and GitHub Actions run their crons in UTC, so pass
 * timezone: "UTC" for those.
 */
export function parseSchedule(schedule: string, timezone?: string): ParsedSchedule {
  const key = `${timezone ?? ""}|${schedule}`;
  const hit = cache.get(key);
  if (hit) return hit;

  const text = schedule.trim();
  const every = /^every\s+(.+)$/i.exec(text);
  let parsed: ParsedSchedule;
  if (every) {
    const everyMs = parseDuration(every[1]!, "schedule interval");
    if (everyMs < 1000) throw new Error(`schedule "${schedule}" is shorter than one second`);
    parsed = { kind: "interval", source: text, everyMs };
  } else {
    let cron: Cron;
    try {
      cron = new Cron(text, timezone ? { timezone } : {});
    } catch (error) {
      throw new Error(`schedule "${schedule}" is not a cron expression or "every <duration>": ${(error as Error).message}`);
    }
    parsed = { kind: "cron", source: text, ...(timezone ? { timezone } : {}) };
    crons.set(parsed, cron);
  }
  cache.set(key, parsed);
  return parsed;
}

/**
 * Four hundred Gregorian years: 146,097 days, a whole number of weeks, after
 * which the calendar repeats date for date and weekday for weekday.
 */
const CYCLE_MS = 146_097 * 86_400_000;
/** croner misreads a year below 100 as 1900 plus it, so earlier times are asked a cycle or more later. */
const CRONER_FIRST_MS = Date.UTC(400, 0, 1);
/** croner finds no fire past the year 3000, so later times are asked a cycle or more earlier. */
const CRONER_LAST_MS = Date.UTC(2800, 0, 1);

/**
 * The next `n` fires of a cron strictly after `from`, which lies within the
 * years 1 to 9999, dropping any after 9999. A time croner cannot answer for
 * is moved by whole 400-year cycles into the years it can, and its fires
 * moved back: a time before 400 goes forward, into the same local mean time
 * every zone kept then, and one from 2800 goes back, to where the zone's
 * present rules already hold.
 */
function runsAfter(cron: Cron, n: number, from: number): number[] {
  let shift = 0;
  if (from < CRONER_FIRST_MS) shift = Math.ceil((CRONER_FIRST_MS - from) / CYCLE_MS) * CYCLE_MS;
  else if (from >= CRONER_LAST_MS) shift = -(Math.floor((from - CRONER_LAST_MS) / CYCLE_MS) + 1) * CYCLE_MS;
  const out: number[] = [];
  for (const date of cron.nextRuns(n, new Date(from + shift))) {
    const t = date.getTime() - shift;
    if (t > LAST_DATE_MS) break;
    out.push(t);
  }
  return out;
}

/**
 * A stored time as a cron's fires are counted from it. A start read from a
 * foreign or damaged row can be any number: one before the year 1 counts
 * from just before its first millisecond, so the first fire of the year 1 is
 * the next one, and one at or after the last millisecond of 9999 has no
 * fire after it at all (null). No fire is ever after 9999.
 */
function countFrom(from: number): number | null {
  if (from >= LAST_DATE_MS) return null;
  return from >= FIRST_DATE_MS ? from : FIRST_DATE_MS - 1;
}

/**
 * The first fire strictly after `from`, or null when the cron never fires
 * again. croner answers with times in the past when asked from inside the
 * hour that repeats when clocks go back, so its answers are filtered, and a
 * stretch of nothing but past times is stepped over an hour at a time.
 */
function fireAfter(parsed: ParsedSchedule, from: number): number | null {
  const cron = crons.get(parsed);
  if (!cron) throw new Error(`schedule "${parsed.source}" was not made by parseSchedule`);
  const start = countFrom(from);
  if (start === null) return null;
  let probe = start;
  for (let attempt = 0; attempt < 4; attempt++) {
    const runs = runsAfter(cron, 8, probe);
    if (runs.length === 0) return null;
    const found = runs.find((t) => t > start);
    if (found !== undefined) return found;
    probe += 3_600_000;
  }
  return null;
}

/**
 * Every fire of a cron strictly after `from` and at or before `to`,
 * ascending, or null when there are more than `limit`. Asks croner for fires
 * in batches, which is far cheaper than one nextFire per fire, and drops any
 * that do not move forward (see fireAfter).
 */
export function firesBetween(parsed: ParsedSchedule, from: number, to: number, limit: number): number[] | null {
  const cron = crons.get(parsed);
  if (!cron) throw new Error(`schedule "${parsed.source}" was not made by parseSchedule`);
  const out: number[] = [];
  const start = countFrom(from);
  if (start === null) return out;
  let probe = start;
  let last = start;
  for (let guard = 0; guard < 1000; guard++) {
    const batch = runsAfter(cron, Math.min(limit + 1 - out.length, 24), probe);
    if (batch.length === 0) return out;
    for (const t of batch) {
      if (t <= last) continue;
      if (t > to) return out;
      out.push(t);
      last = t;
      if (out.length > limit) return null;
    }
    const end = batch[batch.length - 1]!;
    probe = end > probe ? end : probe + 3_600_000;
  }
  return out;
}

/** The next time the schedule fires strictly after `from`. For an interval, counted from the last run when there is one. */
export function nextFire(parsed: ParsedSchedule, from: number, lastRunAt: number | null): number | null {
  if (parsed.kind === "interval") {
    const base = lastRunAt ?? from;
    return base + parsed.everyMs!;
  }
  return fireAfter(parsed, from);
}

export interface Expectation {
  /** When the next run the schedule asks for is due. */
  dueAt: number;
  /** Missed once now passes this. */
  deadline: number;
}

/**
 * When the schedule next wants a run, given the last one. For a cron that is
 * the first fire the last run does not already cover; with no run yet, the
 * first fire at or after registration. For an interval it is the last run's
 * start (or registration) plus the interval. Null for a cron that never
 * fires again.
 *
 * Counting forward from the last run, rather than back from now, is what
 * lets a job whose period is shorter than its grace be missed at all, and it
 * works for a cron that fires once a year or less.
 */
export function expectation(
  parsed: ParsedSchedule,
  lastRunAt: number | null,
  registeredAt: number,
  graceMs: number,
): Expectation | null {
  let dueAt: number | null;
  if (parsed.kind === "interval") {
    dueAt = (lastRunAt ?? registeredAt) + parsed.everyMs!;
  } else if (lastRunAt === null) {
    dueAt = fireAfter(parsed, registeredAt - 1);
  } else {
    dueAt = dueAfterRun(parsed, lastRunAt);
  }
  return dueAt === null ? null : { dueAt, deadline: dueAt + graceMs };
}

/**
 * The first fire that a run starting at `startedAt` does not cover. A start
 * before the year 1 covers none of them, so the first fire of the year 1 is
 * due; after 9999 there is none (see countFrom).
 */
function dueAfterRun(parsed: ParsedSchedule, startedAt: number): number | null {
  // A fire at or before the start is covered by the run itself.
  const next = fireAfter(parsed, startedAt);
  if (next === null) return null;
  const following = fireAfter(parsed, next);
  const covers = runCovers(startedAt, next, following) || inSpringForwardGap(parsed, startedAt, next);
  return covers ? following : next;
}

/**
 * Whether a run starting at `startedAt` covers the fire at `dueAt`. A minute
 * of slack before the tick absorbs schedulers that fire a touch early. When
 * the fire after `dueAt` is known, the slack is at most half the gap between
 * the two, so one run of an every-minute cron never covers two fires.
 */
export function runCovers(startedAt: number, dueAt: number, followingAt: number | null = null): boolean {
  const slack = followingAt === null ? EARLY_SLACK_MS : Math.min(EARLY_SLACK_MS, Math.floor((followingAt - dueAt) / 2));
  return startedAt >= dueAt - slack;
}

/**
 * On the night clocks spring forward, a fire whose local time does not exist
 * (02:30 when 02:00 jumps to 03:00) is moved by croner to the same distance
 * past the jump (03:30), while vixie cron runs it at the jump itself (03:00).
 * A run that starts at or after the jump, and before the first fire after
 * it when that fire lies within one gap of it, is taken to cover that fire,
 * so neither scheduler's run is reported as missed. A cron that really fires
 * at 03:30 that night is treated the same way, which only matters if it also
 * ran early by up to an hour.
 */
function inSpringForwardGap(parsed: ParsedSchedule, startedAt: number, fireAt: number): boolean {
  const LOOKBACK = 3 * 3_600_000;
  // Every zone kept its local mean time, with no clock change, in the year 1.
  if (fireAt - LOOKBACK < FIRST_DATE_MS) return false;
  const after = utcOffset(fireAt, parsed.timezone);
  const before = utcOffset(fireAt - LOOKBACK, parsed.timezone);
  const gap = after - before;
  if (gap <= 0) return false;
  // Find the jump: the first minute in the window with the later offset.
  let lo = fireAt - LOOKBACK;
  let hi = fireAt;
  while (hi - lo > 60_000) {
    const mid = lo + Math.floor((hi - lo) / 2);
    if (utcOffset(mid, parsed.timezone) === after) hi = mid;
    else lo = mid;
  }
  const jumpAt = Math.floor(hi / 60_000) * 60_000;
  if (fireAt - jumpAt >= gap || startedAt < jumpAt - EARLY_SLACK_MS || startedAt >= fireAt) return false;
  // Only the first fire after the jump can be a moved one; a cron that also
  // fires at the jump (every 10 minutes, say) was not moved at all.
  return fireAfter(parsed, jumpAt - 1) === fireAt;
}

const formatters = new Map<string, Intl.DateTimeFormat>();

/** Milliseconds the zone's wall clock is ahead of UTC at `at`. */
function utcOffset(at: number, timezone: string | undefined): number {
  const key = timezone ?? "";
  let format = formatters.get(key);
  if (!format) {
    format = new Intl.DateTimeFormat("en-US", {
      ...(timezone ? { timeZone: timezone } : {}),
      hourCycle: "h23",
      year: "numeric", month: "numeric", day: "numeric", hour: "numeric", minute: "numeric", second: "numeric",
    });
    formatters.set(key, format);
  }
  const parts: Record<string, number> = {};
  for (const part of format.formatToParts(new Date(at))) {
    if (part.type !== "literal") parts[part.type] = Number(part.value);
  }
  // Date.UTC would read a year below 100 as 1900 plus it; setUTCFullYear does not.
  const wall = new Date(0);
  wall.setUTCFullYear(parts.year!, parts.month! - 1, parts.day!);
  wall.setUTCHours(parts.hour!, parts.minute!, parts.second!);
  return wall.getTime() - Math.floor(at / 1000) * 1000;
}
