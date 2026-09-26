import assert from "node:assert/strict";
import { test } from "node:test";
import { emptyState, muteOpens, onCheck, onRunFinish, onRunStart } from "../src/evaluate.js";
import type { JobDefinition, Run, StoredJob } from "../src/types.js";
import { MIN, HOUR, T0 } from "./helpers.js";

let counter = 0;
function run(job: string, status: Run["status"], startedAt: number, durationMs: number | null = 1000, extra: Partial<Run> = {}): Run {
  return {
    id: `r${++counter}`, job, status, startedAt, finishedAt: durationMs === null ? null : startedAt + durationMs,
    durationMs, error: status === "failed" ? "boom" : null, output: null, metrics: {}, trigger: "run", ...extra,
  };
}

const def: JobDefinition = { name: "j", schedule: "every 1h", grace: "10m" };

test("a failure opens `failed` once, and success recovers", () => {
  const s0 = emptyState("j");
  const r1 = run("j", "failed", T0);
  const e1 = onRunFinish(def, r1, s0, [], [], T0 + 1000);
  assert.deepEqual(e1.alerts.map((a) => a.type), ["failed"]);
  assert.equal(e1.state.consecutiveFailures, 1);

  const r2 = run("j", "failed", T0 + HOUR);
  const e2 = onRunFinish(def, r2, e1.state, [r1], [], T0 + HOUR + 1000);
  assert.deepEqual(e2.alerts, [], "already open: no second alert");
  assert.equal(e2.state.consecutiveFailures, 2);

  const r3 = run("j", "ok", T0 + 2 * HOUR);
  const started = onRunStart(e2.state);
  const e3 = onRunFinish(def, r3, started.state, [r2, r1], started.openBefore, T0 + 2 * HOUR + 1000);
  assert.deepEqual(e3.alerts.map((a) => a.type), ["recovered"]);
  assert.deepEqual(e3.state.open, {});
  assert.equal(e3.state.consecutiveFailures, 0);
});

test("failuresBeforeAlert waits for the Nth consecutive failure", () => {
  const d: JobDefinition = { name: "j", failuresBeforeAlert: 3 };
  let state = emptyState("j");
  const history: Run[] = [];
  for (let i = 1; i <= 3; i++) {
    const r = run("j", "failed", T0 + i * MIN);
    const e = onRunFinish(d, r, state, [...history], [], T0 + i * MIN + 100);
    history.unshift(r);
    state = e.state;
    assert.deepEqual(e.alerts.map((a) => a.type), i === 3 ? ["failed"] : [], `failure ${i}`);
  }
});

test("slow uses maxDuration, or twice the p95 once there are five runs", () => {
  const fixed: JobDefinition = { name: "j", maxDuration: "5s" };
  const e = onRunFinish(fixed, run("j", "ok", T0, 6000), emptyState("j"), [], [], T0 + 6000);
  assert.deepEqual(e.alerts.map((a) => a.type), ["slow"]);

  const baseline: JobDefinition = { name: "j" };
  const history = [1, 2, 3, 4].map((i) => run("j", "ok", T0 - i * HOUR, 1000));
  // Only four earlier runs: no baseline yet, a 30s run passes quietly.
  assert.deepEqual(onRunFinish(baseline, run("j", "ok", T0, 30_000), emptyState("j"), history, [], T0 + 30_000).alerts, []);
  history.push(run("j", "ok", T0 - 5 * HOUR, 1000));
  // Five earlier runs at 1s: threshold is max(2s, 10s floor) = 10s.
  assert.deepEqual(onRunFinish(baseline, run("j", "ok", T0, 9_000), emptyState("j"), history, [], T0 + 9_000).alerts, []);
  const slow = onRunFinish(baseline, run("j", "ok", T0, 11_000), emptyState("j"), history, [], T0 + 11_000);
  assert.deepEqual(slow.alerts.map((a) => a.type), ["slow"]);
  assert.equal(slow.alerts[0]!.details.thresholdMs, 10_000);
  // A normal run afterwards recovers.
  const back = onRunFinish(baseline, run("j", "ok", T0 + HOUR, 1_000), slow.state, [run("j", "ok", T0, 11_000), ...history], [], T0 + HOUR + 1000);
  assert.deepEqual(back.alerts.map((a) => a.type), ["recovered"]);
});

test("budgets: a ceiling, or three times the median once there are five runs", () => {
  const ceiling: JobDefinition = { name: "j", budget: { cost: 2 } };
  const over = onRunFinish(ceiling, run("j", "ok", T0, 1000, { metrics: { cost: 2.5 } }), emptyState("j"), [], [], T0 + 1000);
  assert.deepEqual(over.alerts.map((a) => a.type), ["over_budget"]);
  const under = onRunFinish(ceiling, run("j", "ok", T0 + HOUR, 1000, { metrics: { cost: 1 } }), over.state, [], [], T0 + HOUR + 1000);
  assert.deepEqual(under.alerts.map((a) => a.type), ["recovered"]);

  const baseline: JobDefinition = { name: "j" };
  const history = [1, 2, 3, 4, 5].map((i) => run("j", "ok", T0 - i * HOUR, 1000, { metrics: { tokens: 100 } }));
  assert.deepEqual(onRunFinish(baseline, run("j", "ok", T0, 1000, { metrics: { tokens: 299 } }), emptyState("j"), history, [], T0).alerts, []);
  const spike = onRunFinish(baseline, run("j", "ok", T0, 1000, { metrics: { tokens: 301 } }), emptyState("j"), history, [], T0);
  assert.deepEqual(spike.alerts.map((a) => a.type), ["over_budget"]);
});

test("onCheck reports a missed cron run once, and clears when a run covers it", () => {
  const d = { name: "j", schedule: "0 * * * *", grace: "10m" };
  const stored: StoredJob = { name: "j", definition: d, createdAt: T0 - 3 * HOUR, updatedAt: T0 };
  // 09:30, last run 08:00. The 09:00 fire is 30 minutes late: missed.
  const e1 = onCheck(d, stored, run("j", "ok", T0 - 90 * MIN), emptyState("j"), T0);
  assert.deepEqual(e1.alerts.map((a) => a.type), ["missed"]);
  assert.equal(e1.alerts[0]!.details.dueAt, T0 - 30 * MIN);
  assert.equal(e1.nextExpectedAt, T0 + 30 * MIN);
  const e2 = onCheck(d, stored, run("j", "ok", T0 - 90 * MIN), e1.state, T0 + MIN);
  assert.deepEqual(e2.alerts, [], "still missed, no repeat");
  // A run at 09:00:30 covers the 09:00 fire.
  const e3 = onCheck(d, stored, run("j", "ok", T0 - 30 * MIN + 30_000), e2.state, T0 + 2 * MIN);
  assert.deepEqual(e3.state.open, {});
  // Inside the grace window nothing is missed.
  const e4 = onCheck(d, stored, run("j", "ok", T0 - 90 * MIN), emptyState("j"), T0 - 25 * MIN);
  assert.deepEqual(e4.alerts, []);
});

test("onCheck for intervals counts from the last run, or from registration", () => {
  const d = { name: "j", schedule: "every 1h", grace: "5m" };
  const stored: StoredJob = { name: "j", definition: d, createdAt: T0 - 2 * HOUR, updatedAt: T0 };
  assert.deepEqual(onCheck(d, stored, null, emptyState("j"), T0).alerts.map((a) => a.type), ["missed"], "never ran, well past registration");
  assert.deepEqual(onCheck(d, stored, null, emptyState("j"), T0 - HOUR + 4 * MIN).alerts, [], "never ran, inside grace");
  assert.deepEqual(onCheck(d, stored, run("j", "ok", T0 - 50 * MIN), emptyState("j"), T0).alerts, [], "ran 50m ago");
  assert.deepEqual(onCheck(d, stored, run("j", "ok", T0 - 66 * MIN), emptyState("j"), T0).alerts.map((a) => a.type), ["missed"]);
});

test("a job without a schedule is never missed", () => {
  const d = { name: "j" };
  const stored: StoredJob = { name: "j", definition: d, createdAt: T0 - 30 * 86_400_000, updatedAt: T0 };
  const e = onCheck(d, stored, null, emptyState("j"), T0);
  assert.deepEqual(e.alerts, []);
  assert.equal(e.nextExpectedAt, null);
});

test("muteOpens keeps closes and drops new opens", () => {
  const previous = { ...emptyState("j"), open: { failed: T0 } };
  const next = { ...emptyState("j"), open: { slow: T0 + 1 } };
  const muted = muteOpens(previous, next);
  assert.deepEqual(muted.open, {});
});
