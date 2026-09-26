import { Cron } from "croner";
import { parseDuration } from "./duration.js";

export interface ParsedSchedule {
  kind: "cron" | "interval";
  source: string;
  /** For intervals, the period in milliseconds. */
  everyMs?: number;
  cron?: Cron;
}

const cache = new Map<string, ParsedSchedule>();

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
    parsed = { kind: "cron", source: text, cron };
  }
  cache.set(key, parsed);
  return parsed;
}

/** The next time the cron fires strictly after `from`. */
export function nextFire(parsed: ParsedSchedule, from: number, lastRunAt: number | null): number | null {
  if (parsed.kind === "interval") {
    const base = lastRunAt ?? from;
    return base + parsed.everyMs!;
  }
  const next = parsed.cron!.nextRun(new Date(from));
  return next ? next.getTime() : null;
}

/**
 * The most recent time the cron fired at or before `now`, or null when the
 * expression never fires in the year before `now`.
 *
 * croner only looks forward, so this searches: widen a window behind `now`
 * until a fire time falls inside it, then bisect on the window's start for
 * the latest start whose next fire is still at or before `now`.
 */
export function previousFire(parsed: ParsedSchedule, now: number): number | null {
  if (parsed.kind !== "cron") throw new Error("previousFire is for cron schedules");
  const cron = parsed.cron!;
  // nextRun(from) is strictly after `from`, so start one millisecond behind.
  const fireAtOrBefore = (from: number): number | null => {
    const next = cron.nextRun(new Date(from - 1));
    if (!next) return null;
    const t = next.getTime();
    return t <= now ? t : null;
  };

  const YEAR = 366 * 86_400_000;
  let step = 60_000;
  let lo: number | null = null;
  while (step <= YEAR) {
    if (fireAtOrBefore(now - step) !== null) {
      lo = now - step;
      break;
    }
    step *= 2;
  }
  if (lo === null) return null;

  // Invariant: fireAtOrBefore(lo) !== null. Find the largest start that still
  // has a fire at or before now; its fire is the previous one.
  let hi = now;
  while (hi - lo > 1) {
    const mid = Math.floor((lo + hi) / 2);
    if (fireAtOrBefore(mid) !== null) lo = mid;
    else hi = mid;
  }
  return fireAtOrBefore(lo);
}

export interface Expectation {
  /** When the current period's run was due. */
  dueAt: number;
  /** Missed once now passes this. */
  deadline: number;
}

/**
 * What the schedule expects given the last run. Returns null when nothing is
 * due yet (a cron whose first fire since registration is still ahead, or an
 * interval that has not elapsed).
 */
export function expectation(
  parsed: ParsedSchedule,
  now: number,
  lastRunAt: number | null,
  registeredAt: number,
  graceMs: number,
): Expectation | null {
  if (parsed.kind === "interval") {
    const dueAt = (lastRunAt ?? registeredAt) + parsed.everyMs!;
    return { dueAt, deadline: dueAt + graceMs };
  }
  const prev = previousFire(parsed, now);
  if (prev === null || prev < registeredAt) return null;
  return { dueAt: prev, deadline: prev + graceMs };
}

/**
 * Whether a run starting at `startedAt` covers the fire at `dueAt`. A minute of
 * slack before the tick absorbs schedulers that fire a touch early.
 */
export function runCovers(startedAt: number, dueAt: number): boolean {
  return startedAt >= dueAt - 60_000;
}
