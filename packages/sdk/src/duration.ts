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
 * "15m" -> 900000. Accepts a plain number of milliseconds, and compound
 * strings such as "1h30m". Whitespace between parts is fine.
 */
export function parseDuration(value: Duration, label = "duration"): number {
  if (typeof value === "number") {
    if (!Number.isFinite(value) || value < 0) throw new Error(`${label} must be a non-negative number of milliseconds`);
    return value;
  }
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
    throw new Error(`${label} "${value}" is not a duration like "15m", "1h30m" or "90s"`);
  }
  return Math.round(total);
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
