import assert from "node:assert/strict";
import { test } from "node:test";
import { expectation, nextFire, parseSchedule, previousFire, runCovers } from "../src/schedule.js";
import { MIN, HOUR } from "./helpers.js";

/** Linear scan backwards, minute by minute, as an independent oracle for previousFire. */
function bruteForcePrevious(expr: string, now: number, maxBackMs: number, timezone?: string): number | null {
  const parsed = parseSchedule(expr, timezone);
  const cron = parsed.cron!;
  const floor = Math.floor(now / MIN) * MIN;
  for (let t = floor; t >= now - maxBackMs; t -= MIN) {
    const next = cron.nextRun(new Date(t - 1));
    if (next && next.getTime() === t) return t;
  }
  return null;
}

test("parseSchedule accepts cron, nicknames and intervals; rejects junk", () => {
  assert.equal(parseSchedule("0 2 * * *").kind, "cron");
  assert.equal(parseSchedule("@hourly").kind, "cron");
  assert.equal(parseSchedule("*/5 * * * *").kind, "cron");
  const every = parseSchedule("every 5m");
  assert.equal(every.kind, "interval");
  assert.equal(every.everyMs, 5 * MIN);
  assert.throws(() => parseSchedule("every 500ms"), /shorter than one second/);
  assert.throws(() => parseSchedule("banana"), /not a cron expression/);
  assert.throws(() => parseSchedule("every banana"), /not a duration/);
});

test("previousFire agrees with a brute-force scan", () => {
  const cases: [string, number, number][] = [
    ["0 2 * * *", Date.UTC(2026, 0, 5, 9, 30), 2 * 86_400_000],
    ["0 2 * * *", Date.UTC(2026, 0, 5, 2, 0, 0), 2 * 86_400_000],
    ["0 2 * * *", Date.UTC(2026, 0, 5, 1, 59, 59), 2 * 86_400_000],
    ["*/15 * * * *", Date.UTC(2026, 0, 5, 9, 31), 2 * HOUR],
    ["0 9 * * 1", Date.UTC(2026, 0, 5, 9, 30), 8 * 86_400_000],   // Monday 09:00 just passed
    ["0 9 * * 1", Date.UTC(2026, 0, 4, 9, 30), 8 * 86_400_000],   // Sunday: last Monday
    ["30 6 1 * *", Date.UTC(2026, 2, 20, 12, 0), 40 * 86_400_000],
    ["@hourly", Date.UTC(2026, 0, 5, 9, 30), 3 * HOUR],
    ["0 0 29 2 *", Date.UTC(2026, 5, 1), 400 * 86_400_000],       // last 29 Feb was 2024: beyond a year
  ];
  for (const [expr, now, back] of cases) {
    const expected = bruteForcePrevious(expr, now, back);
    const actual = previousFire(parseSchedule(expr), now);
    if (back > 366 * 86_400_000) {
      assert.equal(actual, null, `${expr} at ${new Date(now).toISOString()} should be out of range`);
    } else {
      assert.equal(actual, expected, `${expr} at ${new Date(now).toISOString()}`);
      assert.ok(actual !== null && actual <= now);
    }
  }
});

test("previousFire respects a timezone", () => {
  const parsed = parseSchedule("0 2 * * *", "America/Toronto");
  const now = Date.UTC(2026, 6, 10, 12, 0); // July, EDT (UTC-4): 02:00 local is 06:00Z
  const prev = previousFire(parsed, now)!;
  assert.equal(prev, Date.UTC(2026, 6, 10, 6, 0));
  const hour = new Date(prev).toLocaleString("en-US", { timeZone: "America/Toronto", hour: "numeric", hour12: false });
  assert.equal(Number(hour), 2);
});

test("nextFire", () => {
  const daily = parseSchedule("0 2 * * *");
  assert.equal(nextFire(daily, Date.UTC(2026, 0, 5, 9, 30), null), Date.UTC(2026, 0, 6, 2, 0));
  const every = parseSchedule("every 1h");
  assert.equal(nextFire(every, 1_000, 500), 500 + HOUR);
  assert.equal(nextFire(every, 1_000, null), 1_000 + HOUR);
});

test("expectation for cron and interval schedules", () => {
  const daily = parseSchedule("0 2 * * *");
  const registered = Date.UTC(2026, 0, 4, 12, 0);
  const now = Date.UTC(2026, 0, 5, 9, 30);
  const exp = expectation(daily, now, null, registered, 10 * MIN)!;
  assert.equal(exp.dueAt, Date.UTC(2026, 0, 5, 2, 0));
  assert.equal(exp.deadline, Date.UTC(2026, 0, 5, 2, 10));

  // Registered after the last fire: nothing due yet.
  assert.equal(expectation(daily, now, null, Date.UTC(2026, 0, 5, 3, 0), 10 * MIN), null);

  const every = parseSchedule("every 1h");
  const e2 = expectation(every, now, now - 2 * HOUR, registered, 5 * MIN)!;
  assert.equal(e2.dueAt, now - HOUR);
  assert.equal(e2.deadline, now - HOUR + 5 * MIN);
  const e3 = expectation(every, now, null, now - 30 * MIN, 5 * MIN)!;
  assert.equal(e3.dueAt, now + 30 * MIN);
});

test("runCovers allows a minute of early start", () => {
  const due = Date.UTC(2026, 0, 5, 2, 0);
  assert.ok(runCovers(due, due));
  assert.ok(runCovers(due - 59_000, due));
  assert.ok(runCovers(due + 5 * MIN, due));
  assert.ok(!runCovers(due - 61_000, due));
});
