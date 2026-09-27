import assert from "node:assert/strict";
import { test } from "node:test";
import { expectation, firesBetween, nextFire, parseSchedule, runCovers } from "../src/schedule.js";
import { MIN, HOUR } from "./helpers.js";

const DAY = 86_400_000;

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

test("a parsed schedule is plain data", () => {
  const parsed = parseSchedule("0 2 * * *", "UTC");
  assert.deepEqual(JSON.parse(JSON.stringify(parsed)), { kind: "cron", source: "0 2 * * *", timezone: "UTC" });
});

test("nextFire", () => {
  const daily = parseSchedule("0 2 * * *");
  assert.equal(nextFire(daily, Date.UTC(2026, 0, 5, 9, 30), null), Date.UTC(2026, 0, 6, 2, 0));
  const every = parseSchedule("every 1h");
  assert.equal(nextFire(every, 1_000, 500), 500 + HOUR);
  assert.equal(nextFire(every, 1_000, null), 1_000 + HOUR);
});

test("nextFire respects a timezone", () => {
  const parsed = parseSchedule("0 2 * * *", "America/Toronto");
  // July, EDT (UTC-4): 02:00 local is 06:00Z.
  assert.equal(nextFire(parsed, Date.UTC(2026, 6, 10, 0, 0), null), Date.UTC(2026, 6, 10, 6, 0));
});

test("expectation for a cron counts forward from the last run", () => {
  const daily = parseSchedule("0 2 * * *");
  const registered = Date.UTC(2026, 0, 4, 12, 0);
  // Never ran: the first fire at or after registration.
  const first = expectation(daily, null, registered, 10 * MIN)!;
  assert.equal(first.dueAt, Date.UTC(2026, 0, 5, 2, 0));
  assert.equal(first.deadline, Date.UTC(2026, 0, 5, 2, 10));
  assert.equal(expectation(daily, null, Date.UTC(2026, 0, 5, 2, 0), 0)!.dueAt, Date.UTC(2026, 0, 5, 2, 0), "a fire at registration counts");

  // Ran at 02:00:05 on the 5th: the 6th is next.
  assert.equal(expectation(daily, Date.UTC(2026, 0, 5, 2, 0, 5), registered, 0)!.dueAt, Date.UTC(2026, 0, 6, 2, 0));
  // Started 30 seconds early for the 02:00 fire: still covers it.
  assert.equal(expectation(daily, Date.UTC(2026, 0, 5, 1, 59, 30), registered, 0)!.dueAt, Date.UTC(2026, 0, 6, 2, 0));
  // Started two minutes early: that run does not count for 02:00.
  assert.equal(expectation(daily, Date.UTC(2026, 0, 5, 1, 58), registered, 0)!.dueAt, Date.UTC(2026, 0, 5, 2, 0));
});

test("one run of an every-minute cron covers one fire, not two", () => {
  const minutely = parseSchedule("* * * * *");
  const at = Date.UTC(2026, 0, 5, 9, 0, 0);
  // A run right on 09:00 covers 09:00; 09:01 is still due.
  assert.equal(expectation(minutely, at, at - HOUR, 0)!.dueAt, at + MIN);
  // One that starts at 09:00:50 is taken as an early start for 09:01.
  assert.equal(expectation(minutely, at + 50_000, at - HOUR, 0)!.dueAt, at + 2 * MIN);
});

test("expectation for a yearly cron", () => {
  const yearly = parseSchedule("0 0 1 1 *", "UTC");
  const lastRun = Date.UTC(2026, 0, 1, 0, 0, 3);
  assert.equal(expectation(yearly, lastRun, lastRun - DAY, 10 * MIN)!.dueAt, Date.UTC(2027, 0, 1));
  const leap = parseSchedule("0 0 29 2 *", "UTC");
  assert.equal(expectation(leap, Date.UTC(2024, 1, 29, 0, 0, 1), 0, 0)!.dueAt, Date.UTC(2028, 1, 29));
});

test("expectation for an interval", () => {
  const every = parseSchedule("every 1h");
  const now = Date.UTC(2026, 0, 5, 9, 30);
  const e2 = expectation(every, now - 2 * HOUR, now - DAY, 5 * MIN)!;
  assert.equal(e2.dueAt, now - HOUR);
  assert.equal(e2.deadline, now - HOUR + 5 * MIN);
  const e3 = expectation(every, null, now - 30 * MIN, 5 * MIN)!;
  assert.equal(e3.dueAt, now + 30 * MIN);
});

test("spring forward: a run at the jump covers a fire croner moved past it", () => {
  // 2026-03-08, America/New_York: 02:00 EST jumps to 03:00 EDT at 07:00Z.
  // croner moves the nonexistent 02:30 to 03:30 EDT (07:30Z); vixie cron runs it at 03:00 EDT.
  const tz = "America/New_York";
  const daily = parseSchedule("30 2 * * *", tz);
  const dayBefore = Date.UTC(2026, 2, 7, 7, 30); // 02:30 EST on the 7th
  assert.equal(expectation(daily, dayBefore, 0, 0)!.dueAt, Date.UTC(2026, 2, 8, 7, 30));
  const vixie = Date.UTC(2026, 2, 8, 7, 0, 2); // 03:00:02 EDT
  assert.equal(expectation(daily, vixie, 0, 0)!.dueAt, Date.UTC(2026, 2, 9, 6, 30), "the vixie run covers the day");
  const croner = Date.UTC(2026, 2, 8, 7, 30, 1);
  assert.equal(expectation(daily, croner, 0, 0)!.dueAt, Date.UTC(2026, 2, 9, 6, 30), "so does a run at croner's time");

  // A cron that fires at the jump itself was not moved: a run then covers only that fire.
  const tenMinutes = parseSchedule("*/10 * * * *", tz);
  assert.equal(expectation(tenMinutes, Date.UTC(2026, 2, 8, 7, 0, 2), 0, 0)!.dueAt, Date.UTC(2026, 2, 8, 7, 10));
  const hourly = parseSchedule("0 * * * *", tz);
  assert.equal(expectation(hourly, Date.UTC(2026, 2, 8, 7, 0, 2), 0, 0)!.dueAt, Date.UTC(2026, 2, 8, 8, 0));
});

test("runCovers allows a minute of early start, at most half the gap to the next fire", () => {
  const due = Date.UTC(2026, 0, 5, 2, 0);
  assert.ok(runCovers(due, due));
  assert.ok(runCovers(due - 59_000, due));
  assert.ok(runCovers(due + 5 * MIN, due));
  assert.ok(!runCovers(due - 61_000, due));
  assert.ok(runCovers(due - 30_000, due, due + MIN));
  assert.ok(!runCovers(due - 31_000, due, due + MIN));
});

test("firesBetween lists a cron's fires in a span, the same ones nextFire gives, or null past the limit", () => {
  const hourly = parseSchedule("0 * * * *", "UTC");
  const from = Date.UTC(2026, 0, 5, 9, 30);
  const fires = firesBetween(hourly, from, from + 24 * HOUR, 100)!;
  assert.equal(fires.length, 24);
  let t = from;
  for (const fire of fires) assert.equal(fire, (t = nextFire(hourly, t, null)!));
  assert.equal(firesBetween(hourly, from, from + 24 * HOUR, 23), null);
  assert.deepEqual(firesBetween(parseSchedule("0 3 * * *", "UTC"), from, from + HOUR, 5), []);
  // The night clocks go back in New York: fires only ever move forward.
  const ny = parseSchedule("30 * * * *", "America/New_York");
  const night = firesBetween(ny, Date.UTC(2026, 10, 1, 4), Date.UTC(2026, 10, 1, 9), 20)!;
  assert.ok(night.every((x, i) => i === 0 || x > night[i - 1]!));
  assert.ok(night.length >= 4 && night.length <= 5, String(night.length));
});
