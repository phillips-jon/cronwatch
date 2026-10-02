import assert from "node:assert/strict";
import { test } from "node:test";
import {
  emptyState, failureCount, jobHealth, MAX_DURATION_MS, muteOpens, normalizeState, onCheck, onRunFinish, onRunStart, runDuration, stateVersion, summarize,
} from "../src/evaluate.js";
import type { AlertDetails, AlertDraft, JobDefinition, Run, StoredJob } from "../src/types.js";
import { MIN, HOUR, T0 } from "./helpers.js";

let counter = 0;
function run(job: string, status: Run["status"], startedAt: number, durationMs: number | null = 1000, extra: Partial<Run> = {}): Run {
  return {
    id: `r${++counter}`, job, status, startedAt, finishedAt: durationMs === null ? null : startedAt + durationMs,
    durationMs, error: status === "failed" ? "boom" : null, output: null, metrics: {}, trigger: "run", ...extra,
  };
}

function details<K extends AlertDraft["type"]>(draft: AlertDraft | undefined, type: K): AlertDetails[K] {
  assert.equal(draft?.type, type);
  return draft!.details as AlertDetails[K];
}

const def: JobDefinition = { name: "j", schedule: "every 1h", grace: "10m" };

test("a failure opens `failed` once, and success recovers", () => {
  const s0 = emptyState("j");
  const r1 = run("j", "failed", T0);
  const e1 = onRunFinish(def, r1, s0, [], T0 + 1000);
  assert.deepEqual(e1.alerts.map((a) => a.type), ["failed"]);
  assert.equal(e1.state.consecutiveFailures, 1);

  const r2 = run("j", "failed", T0 + HOUR);
  const e2 = onRunFinish(def, r2, e1.state, [r1], T0 + HOUR + 1000);
  assert.deepEqual(e2.alerts, [], "already open: no second alert");
  assert.equal(e2.state.consecutiveFailures, 2);

  const r3 = run("j", "ok", T0 + 2 * HOUR);
  const started = onRunStart(e2.state);
  const e3 = onRunFinish(def, r3, started, [r2, r1], T0 + 2 * HOUR + 1000);
  assert.deepEqual(e3.alerts.map((a) => a.type), ["recovered"]);
  assert.deepEqual(details(e3.alerts[0], "recovered").after, ["failed"]);
  assert.deepEqual(e3.state.open, {});
  assert.deepEqual(e3.state.pendingRecovery, []);
  assert.equal(e3.state.consecutiveFailures, 0);
});

test("failuresBeforeAlert waits for the Nth consecutive failure", () => {
  const d: JobDefinition = { name: "j", failuresBeforeAlert: 3 };
  let state = emptyState("j");
  const history: Run[] = [];
  for (let i = 1; i <= 3; i++) {
    const r = run("j", "failed", T0 + i * MIN);
    const e = onRunFinish(d, r, state, [...history], T0 + i * MIN + 100);
    history.unshift(r);
    state = e.state;
    assert.deepEqual(e.alerts.map((a) => a.type), i === 3 ? ["failed"] : [], `failure ${i}`);
  }
});

test("slow uses maxDuration, or twice the p95 once there are five runs", () => {
  const fixed: JobDefinition = { name: "j", maxDuration: "5s" };
  const e = onRunFinish(fixed, run("j", "ok", T0, 6000), emptyState("j"), [], T0 + 6000);
  assert.deepEqual(e.alerts.map((a) => a.type), ["slow"]);

  const baseline: JobDefinition = { name: "j" };
  const history = [1, 2, 3, 4].map((i) => run("j", "ok", T0 - i * HOUR, 1000));
  // Only four earlier runs: no baseline yet, a 30s run passes quietly.
  assert.deepEqual(onRunFinish(baseline, run("j", "ok", T0, 30_000), emptyState("j"), history, T0 + 30_000).alerts, []);
  history.push(run("j", "ok", T0 - 5 * HOUR, 1000));
  // Five earlier runs at 1s: threshold is max(2s, 10s floor) = 10s.
  assert.deepEqual(onRunFinish(baseline, run("j", "ok", T0, 9_000), emptyState("j"), history, T0 + 9_000).alerts, []);
  const slow = onRunFinish(baseline, run("j", "ok", T0, 11_000), emptyState("j"), history, T0 + 11_000);
  assert.equal(details(slow.alerts[0], "slow").thresholdMs, 10_000);
  // A normal run afterwards recovers.
  const back = onRunFinish(baseline, run("j", "ok", T0 + HOUR, 1_000), slow.state, [run("j", "ok", T0, 11_000), ...history], T0 + HOUR + 1000);
  assert.deepEqual(back.alerts.map((a) => a.type), ["recovered"]);
});

test("the slow baseline looks past failures to twenty successful runs", () => {
  const baseline: JobDefinition = { name: "j" };
  // Newest first: ten failures, then twenty ok runs at 20s, then older ok runs at 1s.
  const history = [
    ...Array.from({ length: 10 }, (_, i) => run("j", "failed", T0 - (i + 1) * MIN)),
    ...Array.from({ length: 20 }, (_, i) => run("j", "ok", T0 - HOUR - i * MIN, 20_000)),
    ...Array.from({ length: 20 }, (_, i) => run("j", "ok", T0 - 2 * HOUR - i * MIN, 1_000)),
  ];
  // Twice the p95 of the twenty 20s runs is 40s; the older 1s runs are outside the window.
  assert.deepEqual(onRunFinish(baseline, run("j", "ok", T0, 39_000), emptyState("j"), history, T0).alerts, []);
  const slow = onRunFinish(baseline, run("j", "ok", T0, 41_000), emptyState("j"), history, T0);
  assert.match(details(slow.alerts[0], "slow").basis, /last 20 runs/);
});

test("budgets: a ceiling, or three times the median once there are five runs", () => {
  const ceiling: JobDefinition = { name: "j", budget: { cost: 2 } };
  const over = onRunFinish(ceiling, run("j", "ok", T0, 1000, { metrics: { cost: 2.5 } }), emptyState("j"), [], T0 + 1000);
  assert.deepEqual(over.alerts.map((a) => a.type), ["over_budget"]);
  const under = onRunFinish(ceiling, run("j", "ok", T0 + HOUR, 1000, { metrics: { cost: 1 } }), over.state, [], T0 + HOUR + 1000);
  assert.deepEqual(under.alerts.map((a) => a.type), ["recovered"]);

  const baseline: JobDefinition = { name: "j" };
  const history = [1, 2, 3, 4, 5].map((i) => run("j", "ok", T0 - i * HOUR, 1000, { metrics: { tokens: 100 } }));
  assert.deepEqual(onRunFinish(baseline, run("j", "ok", T0, 1000, { metrics: { tokens: 299 } }), emptyState("j"), history, T0).alerts, []);
  const spike = onRunFinish(baseline, run("j", "ok", T0, 1000, { metrics: { tokens: 301 } }), emptyState("j"), history, T0);
  assert.deepEqual(spike.alerts.map((a) => a.type), ["over_budget"]);
});

test("floors: a floor, or 0 after five runs that all reported more", () => {
  const floored: JobDefinition = { name: "j", floor: { rows: 10 } };
  const short = onRunFinish(floored, run("j", "ok", T0, 1000, { metrics: { rows: 9 } }), emptyState("j"), [], T0 + 1000);
  assert.deepEqual(short.alerts.map((a) => a.type), ["under_floor"]);
  assert.deepEqual(details(short.alerts[0], "under_floor").breaches, [{ metric: "rows", value: 9, limit: 10, basis: "floor" }]);
  const back = onRunFinish(floored, run("j", "ok", T0 + HOUR, 1000, { metrics: { rows: 10 } }), short.state, [], T0 + HOUR + 1000);
  assert.deepEqual(back.alerts.map((a) => a.type), ["recovered"]);
  assert.equal(back.state.underFloor, undefined);

  const bare: JobDefinition = { name: "j" };
  const history = [1, 2, 3, 4, 5].map((i) => run("j", "ok", T0 - i * HOUR, 1000, { metrics: { rows: 100 * i, errors: 0 } }));
  assert.deepEqual(onRunFinish(bare, run("j", "ok", T0, 1000, { metrics: { rows: 0 } }), emptyState("j"), history.slice(1), T0).alerts, [], "four runs are not a baseline");
  assert.deepEqual(onRunFinish(bare, run("j", "ok", T0, 1000, { metrics: { rows: 1, errors: 0 } }), emptyState("j"), history, T0).alerts, [], "an always-0 metric never alerts");
  const zero = onRunFinish(bare, run("j", "ok", T0, 1000, { metrics: { rows: 0, errors: 0 } }), emptyState("j"), history, T0);
  assert.deepEqual(details(zero.alerts[0], "under_floor").breaches, [{ metric: "rows", value: 0, limit: 100, basis: "the last 5 runs all reported more than 0, the lowest 100" }]);
  assert.deepEqual(zero.state.underFloor, ["rows"]);

  // A job that keeps writing nothing stays open, past the point where its zeros are all the history there is.
  let state = zero.state;
  const runs = [...history];
  for (let i = 1; i <= 30; i++) {
    runs.unshift(run("j", "ok", T0 + (i - 1) * HOUR, 1000, { metrics: { rows: 0, errors: 0 } }));
    const next = onRunFinish(bare, run("j", "ok", T0 + i * HOUR, 1000, { metrics: { rows: 0, errors: 0 } }), state, runs.slice(0, 25), T0 + i * HOUR);
    assert.deepEqual(next.alerts, []);
    assert.equal(next.state.open.under_floor, T0);
    state = next.state;
  }
  const recovered = onRunFinish(bare, run("j", "ok", T0 + 31 * HOUR, 1000, { metrics: { rows: 5, errors: 0 } }), state, runs.slice(0, 25), T0 + 31 * HOUR);
  assert.deepEqual(recovered.alerts.map((a) => a.type), ["recovered"]);
  assert.deepEqual(details(recovered.alerts[0], "recovered").after, ["under_floor"]);

  // A metric that has reported 0 before is judged as usual for it, and a floor of 0 turns the check off.
  const mixed = [...history.slice(0, 4), run("j", "ok", T0 - 6 * HOUR, 1000, { metrics: { rows: 0 } })];
  assert.deepEqual(onRunFinish(bare, run("j", "ok", T0, 1000, { metrics: { rows: 0 } }), emptyState("j"), mixed, T0).alerts, []);
  assert.deepEqual(onRunFinish({ name: "j", floor: { rows: 0 } }, run("j", "ok", T0, 1000, { metrics: { rows: 0 } }), emptyState("j"), history, T0).alerts, []);
});

test("onCheck reports a missed cron run once, and clears when a run covers it", () => {
  const d = { name: "j", schedule: "0 * * * *", grace: "10m" };
  const stored: StoredJob = { name: "j", definition: d, createdAt: T0 - 3 * HOUR, updatedAt: T0 };
  // 09:30, last run 08:00. The 09:00 fire is 30 minutes late: missed.
  const e1 = onCheck(d, stored, run("j", "ok", T0 - 90 * MIN), emptyState("j"), T0);
  assert.equal(details(e1.alerts[0], "missed").dueAt, T0 - 30 * MIN);
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

test("onCheck catches a cron whose period is shorter than its grace", () => {
  // Every five minutes with the default ten minutes of grace.
  const d = { name: "j", schedule: "*/5 * * * *" };
  const stored: StoredJob = { name: "j", definition: d, createdAt: T0 - 3 * HOUR, updatedAt: T0 };
  const last = run("j", "ok", T0 - 30 * MIN); // 09:00; 09:05 was due, and nothing since
  const late = onCheck(d, stored, last, emptyState("j"), T0);
  assert.equal(details(late.alerts[0], "missed").dueAt, T0 - 25 * MIN);
  // Still inside the grace of the 09:05 fire: quiet.
  assert.deepEqual(onCheck(d, stored, last, emptyState("j"), T0 - 25 * MIN + 10 * MIN).alerts, []);
  // A check landing just after a fire no longer hides a job that stopped hours ago.
  const hourly = { name: "h", schedule: "0 * * * *" };
  const hStored: StoredJob = { name: "h", definition: hourly, createdAt: T0 - 5 * HOUR, updatedAt: T0 };
  const e = onCheck(hourly, hStored, run("h", "ok", T0 - 150 * MIN), emptyState("h"), T0 - 30 * MIN + MIN);
  assert.deepEqual(e.alerts.map((a) => a.type), ["missed"], "09:01, last run 07:00: 08:00 was missed");
});

test("onCheck never ran: the first fire at or after registration is due", () => {
  const d = { name: "j", schedule: "0 9 * * *" };
  const stored: StoredJob = { name: "j", definition: d, createdAt: T0 - 45 * MIN, updatedAt: T0 }; // registered 08:45
  assert.equal(details(onCheck(d, stored, null, emptyState("j"), T0).alerts[0], "missed").dueAt, T0 - 30 * MIN);
  const later: StoredJob = { ...stored, createdAt: T0 - 20 * MIN }; // registered 09:10, after the fire
  assert.deepEqual(onCheck(d, later, null, emptyState("j"), T0).alerts, []);
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

test("a schedule removed while missed is open closes missed with a recovery of its own", () => {
  const d = { name: "j", schedule: "every 1h", grace: "5m" };
  const stored: StoredJob = { name: "j", definition: d, createdAt: T0 - 2 * HOUR, updatedAt: T0 };
  const missed = onCheck(d, stored, null, emptyState("j"), T0);
  assert.deepEqual(missed.alerts.map((a) => a.type), ["missed"]);
  const bare = { name: "j" };
  const gone = onCheck(bare, { ...stored, definition: bare }, null, missed.state, T0 + MIN);
  assert.equal(gone.alerts.length, 1);
  assert.deepEqual(details(gone.alerts[0], "recovered"), { after: ["missed"], reason: "unscheduled", since: T0 });
  assert.equal(gone.alerts[0]!.run, null);
  assert.deepEqual(gone.state.open, {});
  assert.deepEqual(gone.state.pendingRecovery, []);
  assert.equal(gone.nextExpectedAt, null);
  assert.deepEqual(onCheck(bare, { ...stored, definition: bare }, null, gone.state, T0 + 2 * MIN).alerts, [], "once");
  // The next successful run has nothing left to recover.
  const ok = onRunFinish(bare, run("j", "ok", T0 + HOUR), onRunStart(gone.state), [], T0 + HOUR + 1000);
  assert.deepEqual(ok.alerts, []);
});

test("an unscheduled recovery names missed alone; other conditions keep their own rules", () => {
  const d = { name: "j", schedule: "every 30m", grace: "1m" };
  const stored: StoredJob = { name: "j", definition: d, createdAt: T0, updatedAt: T0 };
  const failedRun = run("j", "failed", T0 + MIN);
  const failed = onRunFinish(d, failedRun, onRunStart(emptyState("j")), [], T0 + MIN + 1000);
  const missed = onCheck(d, stored, failedRun, failed.state, T0 + 40 * MIN);
  assert.deepEqual(missed.alerts.map((a) => a.type), ["missed"]);
  // An earlier missed, closed by a run start, may already be waiting in pendingRecovery.
  const waiting = { ...missed.state, pendingRecovery: ["missed" as const] };
  const bare = { name: "j" };
  const gone = onCheck(bare, { ...stored, definition: bare }, failedRun, waiting, T0 + 41 * MIN);
  assert.deepEqual(details(gone.alerts[0], "recovered"), { after: ["missed"], reason: "unscheduled", since: T0 + 40 * MIN });
  assert.equal(gone.alerts[0]!.run?.id, failedRun.id);
  assert.deepEqual(Object.keys(gone.state.open), ["failed"], "failed stays open");
  assert.deepEqual(gone.state.pendingRecovery, [], "missed is not owed a second recovery");
  const ok = onRunFinish(bare, run("j", "ok", T0 + HOUR), onRunStart(gone.state), [failedRun], T0 + HOUR + 1000);
  assert.deepEqual(details(ok.alerts[0], "recovered"), { after: ["failed"] }, "the normal recovery names failed only");
});

test("a job without a schedule and no open missed gets nothing from a check", () => {
  const bare = { name: "j" };
  const stored: StoredJob = { name: "j", definition: bare, createdAt: T0 - HOUR, updatedAt: T0 };
  const state = { ...emptyState("j"), open: { failed: T0 }, pendingRecovery: ["missed" as const] };
  const e = onCheck(bare, stored, null, state, T0);
  assert.deepEqual(e.alerts, []);
  assert.deepEqual(e.state, state, "a missed already closed waits for the next successful run");
});

test("missed closed by a run start still recovers, even when that run fails quietly", () => {
  const d = { name: "j", schedule: "every 1h", failuresBeforeAlert: 3 };
  const stored: StoredJob = { name: "j", definition: d, createdAt: T0 - 3 * HOUR, updatedAt: T0 };
  const missed = onCheck(d, stored, null, emptyState("j"), T0);
  assert.deepEqual(missed.alerts.map((a) => a.type), ["missed"]);
  // A run starts (closing missed without a message) and fails, below the alert threshold.
  const started = onRunStart(missed.state);
  assert.deepEqual(started.open, {});
  const failed = onRunFinish(d, run("j", "failed", T0), started, [], T0 + 1000);
  assert.deepEqual(failed.alerts, []);
  // The next success owes the recovery.
  const ok = onRunFinish(d, run("j", "ok", T0 + HOUR), onRunStart(failed.state), [], T0 + HOUR + 1000);
  assert.deepEqual(ok.alerts.map((a) => a.type), ["recovered"]);
  assert.deepEqual(details(ok.alerts[0], "recovered").after, ["missed"]);
});

test("stuck closed by the next run start is recovered by a later success", () => {
  const d: JobDefinition = { name: "j" };
  const stuck = onRunFinish(d, run("j", "timeout", T0 - HOUR), emptyState("j"), [], T0);
  assert.deepEqual(stuck.alerts.map((a) => a.type), ["stuck"]);
  // The next run starts in another process, so its finish sees stuck already closed.
  const closed = onRunStart(stuck.state);
  const ok = onRunFinish(d, run("j", "ok", T0 + MIN), closed, [], T0 + 2 * MIN);
  assert.deepEqual(details(ok.alerts[0], "recovered").after, ["stuck"]);
});

test("a recovery waits while another condition is still open", () => {
  const d: JobDefinition = { name: "j", maxDuration: "5s" };
  const failed = onRunFinish(d, run("j", "failed", T0), emptyState("j"), [], T0);
  const slowOk = onRunFinish(d, run("j", "ok", T0 + HOUR, 6000), failed.state, [], T0 + HOUR);
  assert.deepEqual(slowOk.alerts.map((a) => a.type), ["slow"], "failed closed, slow opened: not recovered yet");
  const fine = onRunFinish(d, run("j", "ok", T0 + 2 * HOUR, 1000), slowOk.state, [], T0 + 2 * HOUR);
  assert.deepEqual(details(fine.alerts[0], "recovered").after, ["failed", "slow"]);
});

test("normalizeState fills fields that older stored state lacks", () => {
  const old = { job: "j", open: { failed: 1 }, consecutiveFailures: 2, silencedUntil: null, lastAlertAt: 5 };
  assert.deepEqual(normalizeState(old, "j"), { ...old, pendingRecovery: [], undelivered: [] });
  assert.deepEqual(normalizeState(null, "j"), emptyState("j"));
});

test("muteOpens keeps closes and drops new opens", () => {
  const previous = { ...emptyState("j"), open: { failed: T0 } };
  const next = { ...emptyState("j"), open: { slow: T0 + 1 } };
  const muted = muteOpens(previous, next);
  assert.deepEqual(muted.open, {});
});

test("jobHealth ranks silence, stuck, failing, late, never ran and healthy", () => {
  const d = { timeout: "5m" };
  const ok = run("j", "ok", T0 - HOUR);
  assert.equal(jobHealth(d, ok, { ...emptyState("j"), silencedUntil: T0 + 1, open: { failed: 1 } }, T0), "silenced");
  assert.equal(jobHealth(d, run("j", "running", T0 - 6 * MIN, null), emptyState("j"), T0), "stuck");
  assert.equal(jobHealth(d, ok, { ...emptyState("j"), open: { stuck: 1 } }, T0), "stuck");
  assert.equal(jobHealth(d, run("j", "failed", T0 - HOUR), emptyState("j"), T0), "failing");
  assert.equal(jobHealth(d, ok, { ...emptyState("j"), open: { missed: 1 } }, T0), "late");
  assert.equal(jobHealth(d, null, emptyState("j"), T0), "never_ran");
  assert.equal(jobHealth(d, ok, emptyState("j"), T0), "healthy");
});

test("summarize takes the last run and stats from the newest twenty runs", () => {
  const stored: StoredJob = { name: "j", definition: { name: "j" }, createdAt: T0 - 30 * HOUR, updatedAt: T0 };
  const recent = [
    run("j", "running", T0 - MIN, null),
    run("j", "failed", T0 - HOUR),
    ...Array.from({ length: 25 }, (_, i) => run("j", "ok", T0 - (i + 2) * HOUR, 1000 * (i + 1))),
  ];
  const s = summarize(stored, recent, emptyState("j"), null, T0);
  assert.equal(s.lastRun, recent[0]);
  assert.equal(s.health, "healthy", "a run in progress, inside its timeout");
  // Twenty runs in the window: one running, one failed, eighteen ok (1s to 18s).
  assert.equal(s.stats.runs, 19);
  assert.equal(s.stats.okRate, 18 / 19);
  assert.equal(s.stats.p50Ms, 9000);
  assert.equal(s.stats.p95Ms, 18000);
});

test("runDuration: 0 for a start after the finish, and at most 2^53 - 1 for a start far back", () => {
  assert.equal(runDuration(T0 - 1500, T0), 1500);
  assert.equal(runDuration(T0 + 5, T0), 0);
  assert.equal(runDuration(-9223372036854775808, T0), MAX_DURATION_MS);
  assert.equal(runDuration(Number.NaN, T0), 0);
  assert.equal(MAX_DURATION_MS, Number.MAX_SAFE_INTEGER);
});

test("stateVersion: a whole number from 0 to 2^53 - 1, else 0", () => {
  assert.equal(stateVersion(null), 0);
  assert.equal(stateVersion({}), 0);
  assert.equal(stateVersion({ version: 7 }), 7);
  for (const version of [1.5, "x", "3", true, -1, 2 ** 53, Infinity, Number.NaN]) {
    assert.equal(stateVersion({ version } as unknown as { version: number }), 0, String(version));
  }
  assert.ok(Object.is(stateVersion({ version: -0 }), 0));
});

test("failureCount: a whole number held at 2^53 - 1, else 0; a failed run from the top stays there", () => {
  assert.equal(failureCount(null), 0);
  assert.equal(failureCount({ consecutiveFailures: 4 }), 4);
  for (const count of [2 ** 53, 2 ** 63, 2 ** 64]) assert.equal(failureCount({ consecutiveFailures: count }), MAX_DURATION_MS, String(count));
  for (const count of [1.5, "3", true, null, -1, -(2 ** 63), Infinity, Number.NaN]) {
    assert.equal(failureCount({ consecutiveFailures: count } as unknown as { consecutiveFailures: number }), 0, String(count));
  }
  assert.ok(Object.is(failureCount({ consecutiveFailures: -0 }), 0));
  const foreign = normalizeState({ ...emptyState("j"), consecutiveFailures: 2 ** 63 }, "j");
  assert.equal(foreign.consecutiveFailures, MAX_DURATION_MS);
  const failedRun: Run = { id: "f", job: "j", status: "failed", startedAt: T0, finishedAt: T0 + 1, durationMs: 1, error: "boom", output: null, metrics: {}, trigger: "run" };
  const { state, alerts } = onRunFinish({ name: "j", failuresBeforeAlert: 3 }, failedRun, foreign, [], T0 + 1);
  assert.equal(state.consecutiveFailures, MAX_DURATION_MS);
  assert.deepEqual(alerts.map((a) => a.details), [{ consecutiveFailures: MAX_DURATION_MS, threshold: 3 }]);
});
