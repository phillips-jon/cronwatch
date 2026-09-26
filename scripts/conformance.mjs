/**
 * Writes conformance/*.json: cases produced by running the TypeScript SDK,
 * which the Ruby gem (packages/ruby/test/conformance_test.rb) replays to
 * prove it behaves the same. A behaviour change lands in TypeScript first,
 * these files are regenerated, and the gem is fixed until it passes.
 *
 * The public API comes from the built package (packages/sdk/dist). The pure
 * functions it does not export are imported from packages/sdk/src, so this
 * runs under tsx, in UTC:
 *
 *   npm run conformance          build the SDK and rewrite the files
 *   npm run check:conformance    build the SDK and fail if any file would change
 */
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import * as sdk from "../packages/sdk/dist/index.js";
import { formatRelative } from "../packages/sdk/src/duration.ts";
import { expectation, nextFire, parseSchedule, runCovers } from "../packages/sdk/src/schedule.ts";
import {
  emptyState,
  formatNumber,
  isStuck,
  jobHealth,
  muteOpens,
  normalizeState,
  onCheck,
  onRunFinish,
  onRunStart,
  isSilenced,
  summarize,
  timeoutMs,
} from "../packages/sdk/src/evaluate.ts";
import { median, percentile } from "../packages/sdk/src/stats.ts";
import { capOutput } from "../packages/sdk/src/output.ts";
import { checkExpectation, toStored } from "../packages/sdk/src/serialize.ts";

if (process.env.TZ !== "UTC") {
  console.error("conformance: run with TZ=UTC (npm run conformance does)");
  process.exit(2);
}

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const OUT = path.join(ROOT, "conformance");

const SEC = 1000;
const MIN = 60_000;
const HOUR = 3_600_000;
const DAY = 86_400_000;
const T0 = Date.UTC(2026, 0, 5, 9, 30); // Monday 2026-01-05 09:30:00Z
const at = (iso) => Date.parse(iso);

/** JSON has no NaN or Infinity; those travel as { "special": "NaN" }. */
function num(value) {
  return typeof value === "number" && !Number.isFinite(value) ? { special: String(value) } : value;
}

function attempt(fn) {
  try {
    return { value: fn() };
  } catch (error) {
    return { error: error.message };
  }
}

// ---------------------------------------------------------------- duration

function durationCases() {
  const parse = [
    ["15m"], ["1h30m"], ["90s"], ["2d"], ["1w"], ["250ms"], [" 1h 5m "], ["1.5h"], ["0.1s"], ["1H"], ["10 M"],
    ["1m 30s"], ["1.25s"], ["0.0005s"], ["0.0004s"], ["2w3d"], ["1h\t30m"], ["1h\u00a030m"], ["\u20031m\u2003"],
    ["1ms1s"], ["5m5m"], ["0m"], ["0.5ms"], ["1.5ms"], ["2.5ms"], ["999999999w"], ["1d23h59m59s999ms"],
    [""], ["   "], ["abc"], ["5"], ["5 minutes"], ["-1m"], ["1m2"], ["1.m"], [".5m"], ["m"], ["1mm"], ["1 h 30"],
    ["1y"], ["1h,30m"], ["+1m"],
    [1234], [0], [1.5], [-5], [NaN], [Infinity], [-Infinity],
    ["soon", "grace"], ["", "timeout"], [-1, "maxDuration"], ["every", "schedule interval"], ["2h", "silence duration"],
  ];
  const format = [
    0, 1, 0.4, 0.5, 499.5, 999.4, 999.5, 1000, 1499, 1500, 1999, 59_999, 60_000, 61_000, 90_000, 3_599_499,
    3_600_000, 3_660_000, 3_600_000 * 26 + MIN * 5, 90_061_000, 86_400_000 * 400, 172_800_000, -5, -1500,
    NaN, Infinity,
  ];
  const relative = [
    [1_000_000, 1_000_000 + 120_000], [1_000_000 + 120_000, 1_000_000], [1_000_000, 1_000_000 + 2_000],
    [1_000_000, 1_000_000 + 4_999], [1_000_000, 1_000_000 + 5_000], [1_000_000 + 5_000, 1_000_000], [T0, T0],
    [T0, T0 + 3 * DAY + 4 * HOUR], [T0 + 90 * MIN, T0],
  ];
  return {
    parse: parse.map(([input, label]) => {
      const r = attempt(() => (label ? sdk.parseDuration(input, label) : sdk.parseDuration(input)));
      return { input: num(input), ...(label ? { label } : {}), ...("error" in r ? { error: r.error } : { ms: r.value }) };
    }),
    format: format.map((ms) => ({ ms: num(ms), text: sdk.formatDuration(ms) })),
    relative: relative.map(([a, now]) => ({ at: a, now, text: formatRelative(a, now) })),
  };
}

// ---------------------------------------------------------------- schedule

const NY = "America/New_York";
const LONDON = "Europe/London";

function scheduleCases() {
  const parseInputs = [
    ["0 2 * * *"], ["0 2 * * *", "UTC"], ["  0 2 * * *  ", NY], ["@hourly"], ["@daily"], ["@weekly"], ["@monthly"],
    ["@yearly"], ["@annually"], ["@midnight"], ["@HOURLY"], ["*/5 * * * *"], ["0 */30 * * * *"], ["every 5m"],
    ["every 1h30m", NY], ["Every 90s"], ["every   2d"], ["every 1s"], ["0 0 * * mon-fri"], ["0 0 * JAN,jul *"],
    ["0 0 L * *"], ["0 0 * * 5L"], ["0 0 * * 5#2"], ["0 0 ? * *"], ["0 0 * * +1"], ["5-10/2 * * * *"],
    ["0 0 1,15 * *"], ["0 0 * * 0,7"], ["0 0 * * sun"], ["0 12 * * 1-5"],
    ["every 500ms"], ["every 0s"], ["every banana"], ["every "], ["banana"], ["* * * *"], ["60 * * * *"],
    ["0 24 * * *"], ["0 0 32 * *"], ["0 0 0 * *"], ["0 0 * 13 *"], ["0 0 * * 8"], ["*/0 * * * *"], ["*/61 * * * *"],
    ["5/15 * * * *"], ["/5 * * * *"], ["5-1 * * * *"], ["0 0 * * fri-mon"], ["0 0 * * 1#6"], ["0 0 * * 1#0"],
    ["@reboot"], ["@every 5m"], ["0 0 * * * * * *"], ["0 0 L * 1L"], ["0 0 15W * *"], ["0 0 * * +"],
    ["0 2 * * * UTC"], ["0 0 5L * *"], ["x * * * *"], ["0 0 1-5/0 * *"], ["0 0 * * 1-"], ["0 0 -1 * *"],
  ];
  const parse = parseInputs.map(([schedule, timezone]) => {
    const r = attempt(() => sdk.parseSchedule(schedule, timezone));
    return {
      schedule,
      ...(timezone ? { timezone } : {}),
      ...("error" in r ? { error: r.error } : { parsed: JSON.parse(JSON.stringify(r.value)) }),
    };
  });

  const fireInputs = [
    ["30 2 * * *", NY, "2026-03-07T12:00:00Z", 4],
    ["0 2 * * *", NY, "2026-03-07T12:00:00Z", 3],
    ["30 1 * * *", NY, "2026-10-31T12:00:00Z", 4],
    ["0 1 * * *", NY, "2026-10-31T12:00:00Z", 3],
    ["*/30 * * * *", NY, "2026-11-01T04:00:00Z", 8],
    ["*/30 * * * *", NY, "2026-11-01T06:10:00Z", 4],
    ["*/30 * * * *", NY, "2026-03-08T06:00:00Z", 6],
    ["*/10 * * * *", NY, "2026-03-08T06:45:00Z", 4],
    ["0 * * * *", NY, "2026-03-08T05:30:00Z", 4],
    ["0 * * * *", NY, "2026-11-01T04:30:00Z", 4],
    ["15 2 * * *", LONDON, "2026-03-28T12:00:00Z", 3],
    ["30 1 * * *", LONDON, "2026-10-24T12:00:00Z", 3],
    ["0 0 * * *", "America/Santiago", "2026-09-05T12:00:00Z", 3],
    ["30 0 * * *", "Australia/Lord_Howe", "2026-10-03T00:00:00Z", 3],
    ["0 30 2 * * *", NY, "2026-03-07T12:00:00Z", 2],
    ["0 0 31 * *", "UTC", "2026-01-05T00:00:00Z", 4],
    ["0 0 29 2 *", "UTC", "2026-01-05T00:00:00Z", 2],
    ["0 0 * * 1-5", "UTC", "2026-01-02T00:00:00Z", 6],
    ["0 0 1 * 1", "UTC", "2026-01-02T00:00:00Z", 7],
    ["0 0 1 * 1", "UTC", "2026-02-27T12:00:00Z", 3],
    ["0 0 */1 * 1", "UTC", "2026-01-02T00:00:00Z", 3],
    ["0 0 ? * 1", "UTC", "2026-01-02T00:00:00Z", 3],
    ["0 0 1 * +1", "UTC", "2026-01-02T00:00:00Z", 3],
    ["0 0 L * 1", "UTC", "2026-01-02T00:00:00Z", 4],
    ["0 0 * * 5L", "UTC", "2026-01-02T00:00:00Z", 3],
    ["0 0 * * 5#2", "UTC", "2026-01-02T00:00:00Z", 3],
    ["0 0 * * 1#1,5#5", "UTC", "2026-01-01T00:00:00Z", 5],
    ["@weekly", "UTC", "2026-01-02T00:00:00Z", 2],
    ["@monthly", NY, "2026-01-02T00:00:00Z", 3],
    ["0 0 L * *", "UTC", "2026-01-02T00:00:00Z", 3],
    ["0 0 L 2 *", "UTC", "2027-01-02T00:00:00Z", 2],
    ["* * * * *", "UTC", "2026-01-02T00:00:00.500Z", 2],
    ["* * * * * *", "UTC", "2026-01-02T00:00:00.500Z", 2],
    ["*/15 * * * * *", "UTC", "2026-01-02T00:00:59.999Z", 3],
    ["0 9-17/4 * * mon-fri", "UTC", "2026-01-09T12:00:00Z", 4],
    ["0 0 1 jan,jul *", "UTC", "2026-01-02T00:00:00Z", 3],
    ["45 23 31 12 *", "UTC", "2026-12-31T23:44:59Z", 2],
    ["0 2 * * *", undefined, "2026-01-05T09:30:00Z", 2],
    ["0 2 * * *", "Asia/Kolkata", "2026-01-05T09:30:00Z", 2],
    ["0 2 * * *", "Pacific/Chatham", "2026-04-04T00:00:00Z", 3],
    ["0 0 L * 1L", "UTC", "2026-01-02T00:00:00Z", 6],
    ["0 0 1-7 * 1", "UTC", "2026-01-02T00:00:00Z", 6],
    ["0 0 1-7 * +1", "UTC", "2026-01-02T00:00:00Z", 3],
    ["*/7 * * * *", "UTC", "2026-01-02T00:50:00Z", 3],
    ["0 0 */5 * *", "UTC", "2026-01-25T00:00:00Z", 3],
    ["0 0 1 */3 *", "UTC", "2026-01-25T00:00:00Z", 3],
    ["0 0 * * 0#5", "UTC", "2026-01-01T00:00:00Z", 3],
    ["0 0 30 * 5#1", "UTC", "2026-02-01T00:00:00Z", 4],
  ];
  const fires = fireInputs.map(([schedule, timezone, from, n]) => {
    const parsed = sdk.parseSchedule(schedule, timezone);
    const out = [];
    let t = at(from);
    for (let i = 0; i < n; i++) {
      t = sdk.nextFire(parsed, t, null);
      out.push(t);
      if (t === null) break;
    }
    return { schedule, ...(timezone ? { timezone } : {}), from: at(from), fires: out };
  });

  const intervalInputs = [
    ["every 1h", 1_000, 500], ["every 1h", 1_000, null], ["every 5m", T0, T0 - 7 * MIN], ["every 90s", T0, null],
  ];
  const next = intervalInputs.map(([schedule, from, lastRunAt]) => ({
    schedule, from, lastRunAt, expected: sdk.nextFire(sdk.parseSchedule(schedule), from, lastRunAt),
  }));

  const expectations = [];
  const expect = (schedule, timezone, lastRunAt, registeredAt, graceMs) => {
    const parsed = parseSchedule(schedule, timezone);
    const e = expectation(parsed, lastRunAt, registeredAt, graceMs);
    expectations.push({
      schedule, ...(timezone ? { timezone } : {}), lastRunAt, registeredAt, graceMs, expected: e ? { dueAt: e.dueAt, deadline: e.deadline } : null,
    });
  };
  // Around ordinary fires: early, on time, late, and never ran.
  const plain = [
    ["0 2 * * *", undefined], ["0 2 * * *", "UTC"], ["*/5 * * * *", undefined], ["* * * * *", "UTC"],
    ["0 * * * *", "UTC"], ["0 0 1 1 *", "UTC"], ["0 0 29 2 *", "UTC"], ["0 0 * * 1-5", "UTC"], ["*/2 * * * *", "UTC"],
    ["0 */30 * * * *", "UTC"], ["*/20 * * * * *", "UTC"], ["0 9 * * *", NY], ["every 1h", undefined],
    ["every 5m", undefined], ["every 90s", NY],
  ];
  const offsets = [-3 * MIN, -61_000, -60_000, -59_000, -31_000, -30_000, -1_000, 0, 1_000, 30_000, 5 * MIN, 50 * MIN];
  for (const [schedule, timezone] of plain) {
    const parsed = parseSchedule(schedule, timezone);
    const base = parsed.kind === "interval" ? T0 : nextFire(parsed, T0, null);
    for (const offset of offsets) expect(schedule, timezone, base + offset, T0 - DAY, 10 * MIN);
    for (const reg of [base - 1, base, base + 1, T0 - 3 * HOUR]) expect(schedule, timezone, null, reg, 0);
  }
  // Daylight saving: sweep the last run across each night the clocks change.
  const sweeps = [
    ["30 2 * * *", NY, "2026-03-08T05:00:00Z", "2026-03-08T09:00:00Z", 7 * MIN + 13 * SEC],
    ["0 2 * * *", NY, "2026-03-08T05:00:00Z", "2026-03-08T09:00:00Z", 7 * MIN + 13 * SEC],
    ["*/10 * * * *", NY, "2026-03-08T06:30:00Z", "2026-03-08T07:40:00Z", 3 * MIN + 1 * SEC],
    ["0 * * * *", NY, "2026-03-08T05:30:00Z", "2026-03-08T08:30:00Z", 11 * MIN],
    ["30 1 * * *", NY, "2026-11-01T04:00:00Z", "2026-11-01T08:00:00Z", 7 * MIN + 13 * SEC],
    ["*/30 * * * *", NY, "2026-11-01T04:00:00Z", "2026-11-01T08:00:00Z", 7 * MIN + 13 * SEC],
    ["0 * * * *", NY, "2026-11-01T04:30:00Z", "2026-11-01T07:30:00Z", 11 * MIN],
    ["15 2 * * *", NY, "2026-03-08T05:00:00Z", "2026-03-08T09:00:00Z", 9 * MIN],
    ["30 1 * * *", LONDON, "2026-03-29T00:00:00Z", "2026-03-29T02:30:00Z", 7 * MIN],
    ["30 1 * * *", LONDON, "2026-10-25T00:00:00Z", "2026-10-25T02:30:00Z", 7 * MIN],
  ];
  for (const [schedule, timezone, from, to, step] of sweeps) {
    for (let t = at(from); t <= at(to); t += step) expect(schedule, timezone, t, 0, 10 * MIN);
  }
  // The cases from the SDK's own tests.
  expect("30 2 * * *", NY, Date.UTC(2026, 2, 7, 7, 30), 0, 0);
  expect("30 2 * * *", NY, Date.UTC(2026, 2, 8, 7, 0, 2), 0, 0);
  expect("30 2 * * *", NY, Date.UTC(2026, 2, 8, 7, 30, 1), 0, 0);
  expect("*/10 * * * *", NY, Date.UTC(2026, 2, 8, 7, 0, 2), 0, 0);
  expect("0 * * * *", NY, Date.UTC(2026, 2, 8, 7, 0, 2), 0, 0);
  expect("0 0 1 1 *", "UTC", Date.UTC(2026, 0, 1, 0, 0, 3), Date.UTC(2025, 11, 31), 10 * MIN);
  expect("0 0 29 2 *", "UTC", Date.UTC(2024, 1, 29, 0, 0, 1), 0, 0);

  const covers = [
    [0, 0, null], [-59_000, 0, null], [5 * MIN, 0, null], [-61_000, 0, null], [-60_000, 0, null],
    [-30_000, 0, MIN], [-31_000, 0, MIN], [-15_000, 0, 30_000], [-15_001, 0, 30_000], [-60_000, 0, 10 * MIN],
    [-60_001, 0, 10 * MIN], [-30_000, 0, 61_001], [-30_500, 0, 61_001],
  ].map(([startedAt, dueAt, followingAt]) => {
    const due = T0 + dueAt;
    const following = followingAt === null ? null : T0 + followingAt;
    return { startedAt: T0 + startedAt, dueAt: due, followingAt: following, expected: runCovers(T0 + startedAt, due, following) };
  });

  return { parse, fires, nextFire: next, expectation: expectations, runCovers: covers };
}

// ---------------------------------------------------------------- evaluate

/**
 * Plays a job's life through the pure functions, the way the client does:
 * a run's start and finish, a check (stuck runs first, then missed), a
 * silence, and a changed definition. Silence is applied as the client's
 * settle() applies it. Records the alerts and state after each event.
 */
class Sim {
  constructor(definition, createdAt) {
    this.def = definition;
    this.stored = { name: definition.name, definition, createdAt, updatedAt: createdAt };
    this.state = emptyState(definition.name);
    this.runs = [];
    this.order = new Map();
    this.seq = 0;
  }

  sorted() {
    return [...this.runs].sort((a, b) => b.startedAt - a.startedAt || this.order.get(b.id) - this.order.get(a.id));
  }

  settle(previous, evaluation, now) {
    let { state, alerts } = evaluation;
    if (isSilenced(previous, now)) {
      state = muteOpens(previous, state);
      alerts = [];
    }
    this.state = state;
    return alerts.map((draft) => clone(sdk.composeAlert(draft, this.def, now)));
  }

  start(id, now) {
    const run = { id, job: this.def.name, status: "running", startedAt: now, finishedAt: null, durationMs: null, error: null, output: null, metrics: {}, trigger: "run" };
    this.runs.push(run);
    this.order.set(id, ++this.seq);
    this.state = onRunStart(this.state);
    return { state: clone(this.state) };
  }

  finishRun(run, now) {
    const history = this.sorted().filter((r) => r.id !== run.id).map(clone);
    const previous = this.state;
    return this.settle(previous, onRunFinish(this.def, clone(run), previous, history, now), now);
  }

  finish(id, now, fields) {
    const run = this.runs.find((r) => r.id === id);
    Object.assign(run, { finishedAt: now, durationMs: Math.max(0, now - run.startedAt), metrics: {}, output: null, error: null }, fields);
    const alerts = this.finishRun(run, now);
    return { alerts, state: clone(this.state) };
  }

  check(now) {
    const alerts = [];
    const running = this.runs
      .filter((r) => r.status === "running")
      .sort((a, b) => a.startedAt - b.startedAt || this.order.get(a.id) - this.order.get(b.id));
    for (const run of running) {
      if (!isStuck(this.def, run, now)) continue;
      Object.assign(run, {
        status: "timeout", finishedAt: now, durationMs: now - run.startedAt,
        error: `Still running after ${Math.round(timeoutMs(this.def) / 60_000)} minutes; marked as timed out`,
      });
      alerts.push(...this.finishRun(run, now));
    }
    const recent = this.sorted().slice(0, 20).map(clone);
    const previous = this.state;
    const evaluation = onCheck(this.def, this.stored, recent[0] ?? null, previous, now);
    alerts.push(...this.settle(previous, evaluation, now));
    return {
      alerts,
      state: clone(this.state),
      nextExpectedAt: evaluation.nextExpectedAt,
      dueAt: evaluation.dueAt,
      summary: clone(summarize(this.stored, recent, this.state, evaluation.nextExpectedAt, now)),
    };
  }
}

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

/** Runs a scenario's steps and returns it with every event's expected outcome. */
function play({ name, definition, createdAt = T0 - DAY, steps }) {
  const sim = new Sim(definition, createdAt);
  const events = [];
  let ids = 0;
  const finishFields = (s) => {
    const fields = { status: s.status ?? "ok" };
    if (s.metrics) fields.metrics = s.metrics;
    if (s.output !== undefined) fields.output = s.output;
    if (s.error !== undefined) fields.error = s.error;
    else if (fields.status === "failed") fields.error = "Error: boom";
    return fields;
  };
  for (const step of steps) {
    if (step.op === "run") {
      const id = `r${++ids}`;
      events.push({ op: "start", id, at: step.at, expect: sim.start(id, step.at) });
      const fields = finishFields(step);
      const end = step.at + (step.ms ?? 1000);
      events.push({ op: "finish", id, at: end, ...fields, expect: sim.finish(id, end, fields) });
    } else if (step.op === "start") {
      const id = step.id ?? `r${++ids}`;
      events.push({ op: "start", id, at: step.at, expect: sim.start(id, step.at) });
    } else if (step.op === "finish") {
      const fields = finishFields(step);
      events.push({ op: "finish", id: step.id, at: step.at, ...fields, expect: sim.finish(step.id, step.at, fields) });
    } else if (step.op === "check") {
      events.push({ op: "check", at: step.at, expect: sim.check(step.at) });
    } else if (step.op === "silence") {
      sim.state = { ...sim.state, silencedUntil: step.until };
      events.push({ op: "silence", until: step.until, expect: { state: clone(sim.state) } });
    } else if (step.op === "unsilence") {
      sim.state = { ...sim.state, silencedUntil: null };
      events.push({ op: "unsilence", expect: { state: clone(sim.state) } });
    } else if (step.op === "define") {
      sim.def = step.definition;
      sim.stored = { ...sim.stored, definition: step.definition };
      events.push({ op: "define", definition: step.definition });
    } else {
      throw new Error(`unknown step ${step.op}`);
    }
  }
  return { name, definition, createdAt, events };
}

const run = (atMs, extra = {}) => ({ op: "run", at: atMs, ...extra });
const fail = (atMs, extra = {}) => ({ op: "run", at: atMs, status: "failed", ...extra });
const check = (atMs) => ({ op: "check", at: atMs });
const start = (atMs, id) => ({ op: "start", at: atMs, ...(id ? { id } : {}) });
const finish = (id, atMs, extra = {}) => ({ op: "finish", id, at: atMs, ...extra });
const hourly = (n, from, extra = {}) => Array.from({ length: n }, (_, i) => run(from + i * HOUR, extra));

function evaluateCases() {
  const scenarios = [
    {
      name: "a failure opens failed once, and a success recovers",
      definition: { name: "j", schedule: "every 1h", grace: "10m" },
      steps: [fail(T0), fail(T0 + HOUR), run(T0 + 2 * HOUR), check(T0 + 2 * HOUR + MIN)],
    },
    {
      name: "failuresBeforeAlert waits for the third consecutive failure",
      definition: { name: "j", failuresBeforeAlert: 3 },
      steps: [fail(T0), fail(T0 + MIN), fail(T0 + 2 * MIN), fail(T0 + 3 * MIN), run(T0 + 4 * MIN), fail(T0 + 5 * MIN)],
    },
    {
      name: "a run that never finishes is stuck at the next check after its timeout",
      definition: { name: "long", timeout: "5m" },
      steps: [start(T0), check(T0 + 4 * MIN), check(T0 + 6 * MIN), check(T0 + 7 * MIN), run(T0 + 10 * MIN), check(T0 + 12 * MIN)],
    },
    {
      name: "a stuck run's next start closes stuck, and a failure then keeps the recovery waiting",
      definition: { name: "j", timeout: "90s", failuresBeforeAlert: 2 },
      steps: [start(T0), check(T0 + 2 * MIN), fail(T0 + 3 * MIN), run(T0 + 4 * MIN)],
    },
    {
      name: "timeouts below the threshold do not alert",
      definition: { name: "j", timeout: "2m", failuresBeforeAlert: 2 },
      steps: [start(T0), check(T0 + 3 * MIN), start(T0 + 4 * MIN), check(T0 + 7 * MIN), run(T0 + 8 * MIN)],
    },
    {
      name: "an interval missed once, not again, and recovered by a run",
      definition: { name: "sync", schedule: "every 1h", grace: "10m" },
      createdAt: T0,
      steps: [check(T0), check(T0 + 30 * MIN), check(T0 + 70 * MIN + 1), check(T0 + 80 * MIN), run(T0 + 81 * MIN), check(T0 + 90 * MIN)],
    },
    {
      name: "a cron firing more often than its grace is still missed",
      definition: { name: "often", schedule: "*/5 * * * *" },
      steps: [run(T0, { ms: 0 }), check(T0 + 14 * MIN), check(T0 + 16 * MIN), run(T0 + 16 * MIN, { ms: 0 }), check(T0 + 17 * MIN)],
    },
    {
      name: "a missed run whose next run fails below the threshold still recovers later",
      definition: { name: "quiet", schedule: "every 1h", failuresBeforeAlert: 3 },
      createdAt: T0,
      steps: [check(T0), check(T0 + 2 * HOUR), fail(T0 + 2 * HOUR + MIN), run(T0 + 2 * HOUR + 2 * MIN)],
    },
    {
      name: "slow against maxDuration, then back under it",
      definition: { name: "j", maxDuration: "5s" },
      steps: [run(T0, { ms: 6000 }), run(T0 + HOUR, { ms: 7000 }), run(T0 + 2 * HOUR, { ms: 1000 })],
    },
    {
      name: "slow against the baseline, with the ten second floor",
      definition: { name: "agent" },
      steps: [...hourly(4, T0, { ms: 1000 }), run(T0 + 4 * HOUR, { ms: 30_000 }), run(T0 + 5 * HOUR, { ms: 1000 }), run(T0 + 6 * HOUR, { ms: 9_000 }), run(T0 + 7 * HOUR, { ms: 11_000 }), run(T0 + 8 * HOUR, { ms: 1000 })],
    },
    {
      name: "the slow baseline reads past failures to twenty successful runs",
      definition: { name: "base" },
      steps: [
        ...Array.from({ length: 5 }, (_, i) => run(T0 + i * 10 * MIN, { ms: 100_000 })),
        ...Array.from({ length: 15 }, (_, i) => run(T0 + HOUR + i * 2 * MIN, { ms: 1_000 })),
        ...Array.from({ length: 10 }, (_, i) => fail(T0 + 2 * HOUR + i * 2 * MIN)),
        run(T0 + 3 * HOUR, { ms: 30_000 }),
        run(T0 + 4 * HOUR, { ms: 210_000 }),
      ],
    },
    {
      name: "slow and over budget from the job's own baseline, and a ceiling",
      definition: { name: "agent", budget: { cost: 1 } },
      steps: [
        ...hourly(5, T0, { ms: 1000, metrics: { tokens: 1000, cost: 0.5 } }),
        run(T0 + 5 * HOUR, { ms: 15_000, metrics: { tokens: 1000, cost: 0.5 } }),
        run(T0 + 6 * HOUR, { ms: 1000, metrics: { tokens: 5000, cost: 1.2 } }),
        run(T0 + 7 * HOUR, { ms: 1000, metrics: { tokens: 1000, cost: 0.5 } }),
      ],
    },
    {
      name: "a budget ceiling of zero, and a breach recovered",
      definition: { name: "j", budget: { errors: 0, cost: 2 } },
      steps: [run(T0, { metrics: { errors: 0, cost: 2 } }), run(T0 + HOUR, { metrics: { errors: 3, cost: 2.5 } }), run(T0 + 2 * HOUR, { metrics: { errors: 1 } }), run(T0 + 3 * HOUR, { metrics: { errors: 0, cost: 1 } })],
    },
    {
      name: "three times the median, with fractions and big numbers",
      definition: { name: "j" },
      steps: [
        ...[100, 120, 90, 110, 100, 95].map((tokens, i) => run(T0 + i * HOUR, { metrics: { tokens, usd: 0.012345 + i / 1000, rows: 1_250_000 } })),
        run(T0 + 6 * HOUR, { metrics: { tokens: 299, usd: 0.013, rows: 1_250_000 } }),
        run(T0 + 7 * HOUR, { metrics: { tokens: 301, usd: 0.05, rows: 4_000_001.5 } }),
        run(T0 + 8 * HOUR, { metrics: { tokens: 100 } }),
      ],
    },
    {
      name: "a metric that was never reported before has no baseline",
      definition: { name: "j" },
      steps: [...hourly(6, T0, { metrics: { a: 1 } }), run(T0 + 6 * HOUR, { metrics: { a: 1, b: 1_000_000 } })],
    },
    {
      name: "metrics named like numbers are read in JavaScript's key order",
      definition: { name: "j", budget: { "200": 1, "10": 1, zeta: 1 } },
      steps: [run(T0, { metrics: { zeta: 2, "200": 2, "10": 2 } }), run(T0 + HOUR, { metrics: { zeta: 0 } })],
    },
    {
      name: "a recovery waits while another condition is still open",
      definition: { name: "j", maxDuration: "5s" },
      steps: [fail(T0), run(T0 + HOUR, { ms: 6000 }), run(T0 + 2 * HOUR, { ms: 1000 })],
    },
    {
      name: "slow and over budget in one run, in that order",
      definition: { name: "j", maxDuration: "1s", budget: { cost: 1 } },
      steps: [run(T0, { ms: 2000, metrics: { cost: 5 } }), run(T0 + HOUR, { ms: 500, metrics: { cost: 5 } }), run(T0 + 2 * HOUR, { ms: 500, metrics: { cost: 0.25 } })],
    },
    {
      name: "silence swallows alerts and opens nothing, closes still close, and alerts return after",
      definition: { name: "flaky", schedule: "every 1h" },
      steps: [
        { op: "silence", until: T0 + HOUR },
        fail(T0),
        check(T0 + 30 * MIN),
        { op: "unsilence" },
        fail(T0 + 40 * MIN),
        { op: "silence", until: T0 + 3 * HOUR },
        run(T0 + 50 * MIN),
        fail(T0 + 3 * HOUR + MIN),
        check(T0 + 5 * HOUR),
      ],
    },
    {
      name: "a missed run found while silenced is not opened; after the silence it is",
      definition: { name: "j", schedule: "0 * * * *", grace: "5m" },
      steps: [run(Date.UTC(2026, 0, 5, 9, 0)), { op: "silence", until: T0 + HOUR }, check(T0 + 45 * MIN), check(T0 + 61 * MIN)],
    },
    {
      name: "a stuck run found while silenced",
      definition: { name: "j", timeout: "5m" },
      steps: [start(T0), { op: "silence", until: T0 + HOUR }, check(T0 + 10 * MIN), check(T0 + 2 * HOUR), run(T0 + 3 * HOUR)],
    },
    {
      name: "never ran: the first fire at or after registration is due",
      definition: { name: "j", schedule: "0 9 * * *" },
      createdAt: T0 - 45 * MIN,
      steps: [check(T0 - 20 * MIN), check(T0), check(T0 + MIN)],
    },
    {
      name: "never ran, registered after the fire",
      definition: { name: "j", schedule: "0 9 * * *" },
      createdAt: T0 - 20 * MIN,
      steps: [check(T0), check(Date.UTC(2026, 0, 6, 9, 10, 1))],
    },
    {
      name: "a cron missed against the last run, then covered by an early start",
      definition: { name: "j", schedule: "0 * * * *", grace: "10m" },
      steps: [run(T0 - 90 * MIN), check(T0), check(T0 + MIN), run(T0 + 29 * MIN + 30 * SEC), check(T0 + 31 * MIN), check(T0 + 95 * MIN)],
    },
    {
      name: "widening the grace closes a missed run without a run",
      definition: { name: "j", schedule: "every 1h", grace: "5m" },
      createdAt: T0,
      steps: [check(T0 + 70 * MIN), { op: "define", definition: { name: "j", schedule: "every 1h", grace: "30m" } }, check(T0 + 71 * MIN), run(T0 + 72 * MIN)],
    },
    {
      name: "a job without a schedule is never missed",
      definition: { name: "j" },
      createdAt: T0 - 30 * DAY,
      steps: [check(T0), fail(T0 + MIN), check(T0 + 2 * MIN)],
    },
    {
      name: "a daily cron in New York across spring forward, run at vixie's time",
      definition: { name: "ny", schedule: "30 2 * * *", timezone: NY, grace: "15m" },
      createdAt: Date.UTC(2026, 2, 6, 12),
      steps: [
        run(Date.UTC(2026, 2, 7, 7, 30, 1)),
        run(Date.UTC(2026, 2, 8, 7, 0, 2)),
        check(Date.UTC(2026, 2, 8, 12)),
        check(Date.UTC(2026, 2, 9, 6, 46)),
        run(Date.UTC(2026, 2, 9, 6, 50)),
        check(Date.UTC(2026, 2, 9, 7)),
      ],
    },
    {
      name: "a half-hourly cron in New York across fall back",
      definition: { name: "ny", schedule: "*/30 * * * *", timezone: NY, grace: "5m" },
      createdAt: Date.UTC(2026, 10, 1, 3),
      steps: [
        run(Date.UTC(2026, 10, 1, 5, 0)),
        run(Date.UTC(2026, 10, 1, 5, 30)),
        check(Date.UTC(2026, 10, 1, 6, 20)),
        check(Date.UTC(2026, 10, 1, 7, 6)),
        run(Date.UTC(2026, 10, 1, 7, 7)),
        check(Date.UTC(2026, 10, 1, 7, 20)),
      ],
    },
    {
      name: "every minute: one run covers one fire",
      definition: { name: "m", schedule: "* * * * *", grace: "90s" },
      steps: [run(T0, { ms: 0 }), check(T0 + 2 * MIN), check(T0 + 2 * MIN + 31 * SEC), run(T0 + 3 * MIN - 20 * SEC, { ms: 0 }), check(T0 + 4 * MIN + 30 * SEC)],
    },
    {
      name: "a weekly cron in London, missed and recovered",
      definition: { name: "w", schedule: "0 6 * * mon", timezone: LONDON, grace: "1h" },
      createdAt: Date.UTC(2026, 5, 1),
      steps: [check(Date.UTC(2026, 5, 1, 5, 30)), check(Date.UTC(2026, 5, 1, 6, 1)), run(Date.UTC(2026, 5, 1, 6, 2)), check(Date.UTC(2026, 5, 8, 5, 30))],
    },
    {
      name: "failure messages: named errors, bare messages, several lines, and output tails",
      definition: { name: "report", schedule: "every 1h", failuresBeforeAlert: 1 },
      steps: [
        fail(T0, { error: "TypeError: cannot read x\n    at a (app.js:1:1)\n    at b (app.js:2:2)\n    at c\n    at d\n    at e", output: "line 1\nline 2\n" }),
        run(T0 + HOUR),
        fail(T0 + 2 * HOUR, { error: "connect ECONNREFUSED 10.0.0.12:5432", output: Array.from({ length: 12 }, (_, i) => `row ${i}`).join("\n") + "\n\n  " }),
        fail(T0 + 3 * HOUR, { error: "Output did not contain \"wrote\"", output: "nothing to do" }),
        run(T0 + 4 * HOUR),
        fail(T0 + 5 * HOUR, { error: "ActiveRecord::RecordNotFound: missing", output: null }),
        run(T0 + 6 * HOUR),
        fail(T0 + 7 * HOUR, { error: "", ms: 0 }),
      ],
    },
    {
      name: "a missed run whose last run failed",
      definition: { name: "j", schedule: "every 30m", grace: "1m" },
      createdAt: T0,
      steps: [fail(T0 + MIN, { error: "Error: first" }), fail(T0 + 3 * MIN, { error: "Error: second" }), check(T0 + 40 * MIN), run(T0 + 41 * MIN, { ms: 2500 })],
    },
    {
      name: "overlapping runs of one job",
      definition: { name: "par", failuresBeforeAlert: 2 },
      steps: [start(T0, "a"), start(T0, "b"), start(T0 + 1, "c"), finish("b", T0 + 5 * SEC, { status: "failed" }), finish("a", T0 + 6 * SEC, { status: "failed" }), finish("c", T0 + 7 * SEC, { status: "ok" })],
    },
    {
      name: "a missed interval of ninety seconds",
      definition: { name: "fast", schedule: "every 90s", grace: "30s" },
      createdAt: T0,
      steps: [check(T0 + 2 * MIN), check(T0 + 2 * MIN + 1), run(T0 + 3 * MIN), check(T0 + 4 * MIN), check(T0 + 5 * MIN + 1)],
    },
  ];
  return { scenarios: scenarios.map(play) };
}

// ---------------------------------------------------------------- format

function sampleRun(extra = {}) {
  return { id: "r1", job: "nightly", status: "failed", startedAt: T0, finishedAt: T0 + 1500, durationMs: 1500, error: null, output: null, metrics: {}, trigger: "run", ...extra };
}

function formatCases() {
  const def = { name: "nightly", schedule: "0 2 * * *", grace: "15m" };
  const tzDef = { name: "nightly", schedule: "0 2 * * *", timezone: NY };
  const drafts = [
    [{ type: "missed", run: null, details: { dueAt: T0 - 30 * MIN, deadline: T0 - 15 * MIN, graceMs: 15 * MIN, lastRunAt: null } }, def, T0],
    [{ type: "missed", run: sampleRun({ status: "ok", startedAt: T0 - DAY }), details: { dueAt: T0 - 10 * MIN, deadline: T0 - 2 * SEC, graceMs: 8 * MIN, lastRunAt: T0 - DAY } }, tzDef, T0],
    [{ type: "missed", run: null, details: { dueAt: T0 + 2 * HOUR, deadline: T0 + 3 * HOUR, graceMs: HOUR, lastRunAt: null } }, { name: "odd" }, T0],
    [{ type: "failed", run: sampleRun({ error: "Error: boom" }), details: { consecutiveFailures: 1, threshold: 1 } }, def, T0 + 2000],
    [{ type: "failed", run: sampleRun({ error: "boom\nsecond line\nthird\nfourth\nfifth", output: "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\n\n" }), details: { consecutiveFailures: 4, threshold: 3 } }, def, T0 + HOUR],
    [{ type: "failed", run: sampleRun({ error: "HTTP 503 Service Unavailable", durationMs: null, finishedAt: null }), details: { consecutiveFailures: 2, threshold: 1 } }, def, T0 + 3 * DAY],
    [{ type: "failed", run: sampleRun({ error: "$weird: yes", output: "   " }), details: { consecutiveFailures: 1, threshold: 1 } }, def, T0],
    [{ type: "failed", run: sampleRun({ error: "Some::Error: namespaced" }), details: { consecutiveFailures: 1, threshold: 1 } }, def, T0],
    [{ type: "failed", run: null, details: { consecutiveFailures: 1, threshold: 1 } }, def, T0],
    [{ type: "stuck", run: sampleRun({ status: "timeout", durationMs: 3_600_000 + 1, output: "started\nhalfway" }), details: { consecutiveFailures: 1, threshold: 1 } }, def, T0 + HOUR],
    [{ type: "stuck", run: sampleRun({ status: "timeout", durationMs: null, finishedAt: null }), details: { consecutiveFailures: 2, threshold: 1 } }, def, T0 + 5 * HOUR],
    [{ type: "stuck", run: null, details: { consecutiveFailures: 1, threshold: 1 } }, def, T0],
    [{ type: "slow", run: sampleRun({ status: "ok", durationMs: 15_000 }), details: { durationMs: 15_000, thresholdMs: 10_000, basis: "twice the p95 of the last 5 runs (1s)" } }, def, T0 + MIN],
    [{ type: "slow", run: null, details: { durationMs: 999, thresholdMs: 500, basis: "maxDuration" } }, def, T0],
    [{ type: "over_budget", run: sampleRun({ status: "ok" }), details: { breaches: [{ metric: "cost", value: 1.2, limit: 1, basis: "budget" }, { metric: "tokens", value: 5000, limit: 3000, basis: "three times the usual 1,000" }] } }, def, T0],
    [{ type: "over_budget", run: null, details: { breaches: [{ metric: "rows", value: 1234567.891, limit: 1e21, basis: "budget" }, { metric: "tiny", value: 0.00005, limit: 0.00001, basis: "budget" }, { metric: "neg", value: -1234.5, limit: -2000, basis: "budget" }] } }, def, T0],
    [{ type: "recovered", run: sampleRun({ status: "ok" }), details: { after: ["missed", "over_budget", "failed"] } }, def, T0 + 2 * MIN],
    [{ type: "recovered", run: sampleRun({ status: "ok", durationMs: null }), details: { after: [] } }, def, T0],
    [{ type: "recovered", run: null, details: { after: ["stuck"] } }, def, T0],
  ];
  const numbers = [
    0, 1, -1, 12, 999, 1000, 1234, 12345.6789, 1234567.891, 0.5, 0.1 + 0.2, 1.00005, 0.00005, 0.00004, 1234.56785,
    999999.99995, 2.5, 1e21, 1.5e21, 123456789012, -0.5, -1234.5, 3 * 0.1, 1 / 3, 2 / 3, 100.12345, -0.00001,
    -0.00005, 0.99995, 9.99995, -9.99995, 0.00015, 1e-7, 1.23456e-10, 123456.00004, 99999.99999, 4000001.5, 1e-5,
  ];
  // Written as a prefix and a repeated piece; the output as its length (in UTF-16 code units) and hash.
  const capInputs = [
    ["short", "", 0], ["", "", 0], ["", "x", 16 * 1024], ["", "x", 16 * 1024 + 1], ["", "ab\n", 10_000],
    ["", "\u00e9", 17_000], ["", "\u{1F600}", 9_000], ["a", "\u{1F600}", 8_192], ["line\n", "\u00e9\u{1F600}x", 6_000],
  ];
  const storedInputs = [
    [{ name: "a", schedule: "0 2 * * *", expect: "wrote" }],
    [{ expect: "say \"hi\"\n\ttab\u0001", name: "b", grace: "5m" }],
    [{ name: "c", expect: /wrote \d+ files/ }],
    [{ name: "d", expect: /ok/i, timeout: 1000 }],
    [{ name: "e", expect: (o) => o.length > 3, budget: { cost: 2 }, tags: ["x", "y"] }],
    [{ name: "f", schedule: "@hourly", timezone: "UTC", grace: "15m", timeout: "1h", maxDuration: "5m", budget: { cost: 1.5 }, failuresBeforeAlert: 2, description: "Nightly", tags: ["billing"] }],
    [{ timezone: "UTC", grace: 60_000, schedule: "every 5m", name: "g" }],
  ];
  const expectInputs = [
    ["wrote", "wrote 12 files"], ["wrote", "nothing to do"], ["wrote", null], ["", ""], ["say \"hi\"", "hello"],
    [/wrote \d+ files/, "wrote 12 files"], [/wrote \d+ files/, "wrote files"], [/ok/i, "OK"], [/^done$/, "done"],
    [/^done$/, "not done"],
  ];
  const regex = (value) => (value instanceof RegExp ? { regex: { source: value.source, flags: value.flags } } : value);
  return {
    alerts: drafts.map(([draft, definition, now]) => ({ draft: clone(draft), definition, now, alert: clone(sdk.composeAlert(draft, definition, now)) })),
    numbers: numbers.map((n) => ({ n, text: formatNumber(n) })),
    capOutput: capInputs.map(([prefix, piece, times]) => {
      const output = capOutput(prefix + piece.repeat(times));
      return { prefix, piece, times, length: output.length, sha256: createHash("sha256").update(output).digest("hex") };
    }),
    toStored: storedInputs.map(([definition]) => ({
      definition: Object.fromEntries(Object.entries(definition).map(([k, v]) => [k, typeof v === "function" ? { callable: true } : regex(v)])),
      stored: clone(toStored(definition)),
    })),
    checkExpectation: expectInputs.map(([expect, output]) => ({ expect: regex(expect), output, result: checkExpectation(expect, output) })),
  };
}

// ---------------------------------------------------------------- health

function healthCases() {
  const r = (id, status, startedAt, durationMs = 1000, extra = {}) => ({
    id, job: "j", status, startedAt, finishedAt: durationMs === null ? null : startedAt + durationMs, durationMs,
    error: status === "failed" ? "Error: boom" : null, output: null, metrics: {}, trigger: "run", ...extra,
  });
  const state = (extra = {}) => ({ ...emptyState("j"), ...extra });
  const ok = r("ok", "ok", T0 - HOUR);
  const healthInputs = [
    [{ timeout: "5m" }, ok, state({ silencedUntil: T0 + 1, open: { failed: 1 } })],
    [{ timeout: "5m" }, ok, state({ silencedUntil: T0, open: { failed: 1 } })],
    [{ timeout: "5m" }, r("run", "running", T0 - 6 * MIN, null), state()],
    [{ timeout: "5m" }, r("run", "running", T0 - 5 * MIN, null), state()],
    [{}, r("run", "running", T0 - 61 * MIN, null), state()],
    [{ timeout: "5m" }, ok, state({ open: { stuck: 1 } })],
    [{ timeout: "5m" }, r("f", "failed", T0 - HOUR), state()],
    [{ timeout: "5m" }, r("t", "timeout", T0 - HOUR), state()],
    [{ timeout: "5m" }, ok, state({ open: { failed: 1, missed: 2 } })],
    [{ timeout: "5m" }, ok, state({ open: { missed: 1 } })],
    [{ timeout: "5m" }, null, state({ open: { missed: 1 } })],
    [{ timeout: "5m" }, null, state()],
    [{ timeout: "5m" }, ok, state({ open: { slow: 1, over_budget: 2 } })],
    [{ timeout: "5m" }, ok, state()],
  ];
  const jobHealthCases = healthInputs.map(([definition, lastRun, s]) => ({ definition, lastRun, state: s, now: T0, health: jobHealth(definition, lastRun, s, T0) }));

  const stored = { name: "j", definition: { name: "j", schedule: "every 1h", timeout: "10m" }, createdAt: T0 - 30 * HOUR, updatedAt: T0 };
  const recents = [
    [],
    [r("run", "running", T0 - MIN, null)],
    [r("run", "running", T0 - MIN, null), r("f", "failed", T0 - HOUR), ...Array.from({ length: 25 }, (_, i) => r(`o${i}`, "ok", T0 - (i + 2) * HOUR, 1000 * (i + 1)))],
    Array.from({ length: 7 }, (_, i) => r(`x${i}`, i % 3 === 0 ? "failed" : "ok", T0 - i * HOUR, 333 * (i + 1))),
    [r("t", "timeout", T0 - HOUR, 600_000), r("o", "ok", T0 - 2 * HOUR, null)],
    [r("o1", "ok", T0 - HOUR, 1500), r("o2", "ok", T0 - 2 * HOUR, 2500)],
  ];
  const summaries = recents.map((recent, i) => {
    const s = i === 4 ? state({ open: { stuck: T0 - HOUR }, consecutiveFailures: 1, lastAlertAt: T0 - HOUR }) : i === 5 ? state({ silencedUntil: T0 + HOUR }) : state();
    const nextExpectedAt = i === 0 ? null : T0 + 30 * MIN;
    return { stored, recent, state: s, nextExpectedAt, now: T0, summary: clone(summarize(stored, recent, s, nextExpectedAt, T0)) };
  });

  const values = [[], [5], [3, 1, 2], [1, 2, 3, 4], [10, 1, 100, 1000, 5, 7, 7, 7, 2, 3], Array.from({ length: 20 }, (_, i) => (i + 1) * 1000), [0.5, 0.25, 0.125], [2, 2, 3, 3]];
  const stats = values.flatMap((v) => [50, 90, 95, 99, 100, 0, 1].map((p) => ({ values: v, p, percentile: percentile(v, p) })));
  const medians = values.map((v) => ({ values: v, median: median(v) }));

  const olds = [
    null,
    { job: "j", open: { failed: 1 }, consecutiveFailures: 2, silencedUntil: null, lastAlertAt: 5 },
    { job: "j", open: {}, consecutiveFailures: 0, silencedUntil: 99, lastAlertAt: null, pendingRecovery: ["missed"] },
    { job: "j", open: { stuck: 7, slow: 8 }, consecutiveFailures: 1, silencedUntil: null, lastAlertAt: 6, pendingRecovery: ["missed", "failed"], undelivered: [] },
  ];
  const normalized = olds.map((old) => ({ state: old, normalized: clone(normalizeState(old, "j")) }));
  const mutes = [
    [state({ open: { failed: T0 } }), state({ open: { slow: T0 + 1 } })],
    [state({ open: { failed: T0 } }), state({ open: { failed: T0, missed: T0 + 1 } })],
    [state(), state({ open: { missed: T0 }, pendingRecovery: ["failed"], consecutiveFailures: 3 })],
  ].map(([previous, next]) => ({ previous, next, muted: clone(muteOpens(previous, next)) }));
  const stuck = [
    [{ timeout: "5m" }, r("a", "running", T0 - 5 * MIN, null)],
    [{ timeout: "5m" }, r("a", "running", T0 - 5 * MIN - 1, null)],
    [{ timeout: "5m" }, r("a", "ok", T0 - HOUR)],
    [{}, r("a", "running", T0 - HOUR - 1, null)],
    [{ timeout: 1000 }, r("a", "running", T0 - 1001, null)],
  ].map(([definition, runValue]) => ({ definition, run: runValue, now: T0, stuck: isStuck(definition, runValue, T0) }));

  return { jobHealth: jobHealthCases, summarize: summaries, percentile: stats, median: medians, normalizeState: normalized, muteOpens: mutes, isStuck: stuck };
}

// ---------------------------------------------------------------- write or check

const files = {
  "duration.json": durationCases(),
  "schedule.json": scheduleCases(),
  "evaluate.json": evaluateCases(),
  "format.json": formatCases(),
  "health.json": healthCases(),
};

const checking = process.argv.includes("--check");
const stale = [];
if (!checking) mkdirSync(OUT, { recursive: true });
for (const [name, content] of Object.entries(files)) {
  const text = JSON.stringify({ generatedBy: "scripts/conformance.mjs", sdkVersion: sdkVersion(), ...content }, null, 2) + "\n";
  const file = path.join(OUT, name);
  if (checking) {
    if (!existsSync(file) || readFileSync(file, "utf8") !== text) stale.push(name);
  } else {
    writeFileSync(file, text);
  }
}

if (checking && stale.length > 0) {
  console.error(`conformance: ${stale.join(", ")} would change. Run \`npm run conformance\`, then make the Ruby gem pass.`);
  process.exit(1);
}
console.log(checking ? "conformance: fixtures are current" : `conformance: wrote ${Object.keys(files).length} files to conformance/`);

function sdkVersion() {
  return JSON.parse(readFileSync(path.join(ROOT, "packages/sdk/package.json"), "utf8")).version;
}
