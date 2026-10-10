import type { Duration } from "./types.js";

const UNIT_MS: Record<string, number> = {
  ms: 1,
  s: 1000,
  m: 60_000,
  h: 3_600_000,
  d: 86_400_000,
  w: 604_800_000,
};

/**
 * The longest duration string read, in characters (code points). No real
 * duration comes near it, and the pattern below is quadratic on a long run of
 * digits, so a longer string is refused before it is read.
 */
const MAX_LENGTH = 64;
/** How much of a refused, overlong string its error quotes. */
const QUOTED = 32;

/**
 * "15m" -> 900000. Accepts a plain number of milliseconds, and compound
 * strings such as "1h30m". Whitespace between parts is fine.
 */
export function parseDuration(value: Duration, label = "duration"): number {
  if (typeof value === "number") {
    if (!Number.isFinite(value) || value < 0) throw new Error(`${label} must be a non-negative number of milliseconds`);
    return value;
  }
  if (value.length > MAX_LENGTH) tooLong(value, label);
  const text = value.trim().toLowerCase();
  if (text === "") throw new Error(`${label} is empty`);
  const re = /(\d+(?:\.\d+)?)\s*(ms|s|m|h|d|w)/g;
  let total = 0;
  let consumed = "";
  let match: RegExpExecArray | null;
  while ((match = re.exec(text)) !== null) {
    total += parseFloat(match[1]!) * UNIT_MS[match[2]!]!;
    consumed += match[0];
  }
  if (consumed.replace(/\s+/g, "") !== text.replace(/\s+/g, "")) {
    throw new Error(`${label} "${value}" is not a duration like "15m", "1h30m", or "90s"`);
  }
  return Math.round(total);
}

/** Throws if `value` is over MAX_LENGTH characters, quoting the first QUOTED. */
function tooLong(value: string, label: string): void {
  let count = 0;
  let head = "";
  for (const char of value) {
    if (count < QUOTED) head += char;
    if (++count > MAX_LENGTH) {
      throw new Error(`${label} "${head}..." is too long for a duration (more than ${MAX_LENGTH} characters)`);
    }
  }
}

/** 90000 -> "1m 30s". For messages, not for parsing back. */
export function formatDuration(ms: number): string {
  if (!Number.isFinite(ms)) return "?";
  if (ms < 1000) return `${Math.round(ms)}ms`;
  const parts: string[] = [];
  let rest = Math.round(ms / 1000);
  const units: [string, number][] = [["d", 86_400], ["h", 3_600], ["m", 60], ["s", 1]];
  for (const [unit, size] of units) {
    if (rest >= size) {
      const n = Math.floor(rest / size);
      rest -= n * size;
      parts.push(`${n}${unit}`);
    }
    if (parts.length === 2) break;
  }
  return parts.join(" ") || "0s";
}

/** "5 minutes ago", "in 2h". Relative to `now`. */
export function formatRelative(at: number, now: number): string {
  const diff = at - now;
  const abs = Math.abs(diff);
  const text = abs < 5_000 ? "now" : formatDuration(abs);
  if (abs < 5_000) return text;
  return diff < 0 ? `${text} ago` : `in ${text}`;
}

/** The first millisecond written as a date: 0001-01-01T00:00:00.000Z. */
export const FIRST_DATE_MS = -62_135_596_800_000;
/** The last millisecond written as a date: 9999-12-31T23:59:59.999Z. */
export const LAST_DATE_MS = 253_402_300_799_999;

/**
 * "2026-01-05T09:30:00.000Z", or null for a time before the year 1 or after
 * 9999. A start read from another process's row, or a damaged one, can be
 * any number; outside those years it is not written as a date at all (and
 * past JavaScript's Date range, toISOString would throw).
 */
export function isoTime(at: number): string | null {
  return at >= FIRST_DATE_MS && at <= LAST_DATE_MS ? new Date(at).toISOString() : null;
}

/** The words that stand in for a time isoTime() does not write: "before 0001-01-01 00:00:00 UTC" or "after 9999-12-31 23:59:59 UTC". */
export function beyondDates(at: number): string {
  return at > LAST_DATE_MS ? "after 9999-12-31 23:59:59 UTC" : "before 0001-01-01 00:00:00 UTC";
}
