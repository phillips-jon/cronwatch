import assert from "node:assert/strict";
import { test } from "node:test";
import { cronwatch, custom, nextFire, parseSchedule } from "../src/index.js";
import { composeAlert } from "../src/format.js";
import type { Alert } from "../src/types.js";
import { capture, clock, MIN, T0 } from "./helpers.js";

test("an alert still being sent cannot overwrite what a run did meanwhile", async () => {
  const c = clock();
  const sent: string[] = [];
  let release!: () => void;
  const gate = new Promise<void>((r) => { release = r; });
  const cw = cronwatch({
    now: c.now, cronSecret: null,
    // The missed alert takes a while (a slow webhook, or triage); everything else is instant.
    alerts: [custom("slow-for-missed", async (a: Alert) => { if (a.type === "missed") await gate; sent.push(a.type); })],
  });
  const job = cw.job("sync", { schedule: "every 5m", grace: "1m" });
  await job.run(async () => {});
  c.advance(7 * MIN);
  const checking = cw.check();
  await new Promise((r) => setTimeout(r, 20));
  await job.run(async () => {});   // the job turns up while the missed alert is in flight
  release();
  await checking;
  assert.deepEqual(sent, ["recovered", "missed"]);
  assert.deepEqual((await cw.store.getState("sync"))!.open, {}, "missed stays closed");
  c.advance(1 * MIN);
  await job.run(async () => {});
  assert.deepEqual(sent, ["recovered", "missed"], "no second recovered");
});

test("pruning keeps each job's newest run, so a monthly job is not reported missed", async () => {
  const c = clock(Date.UTC(2026, 0, 1, 0, 0));
  const alerts = capture();
  const cw = cronwatch({ now: c.now, alerts: [alerts], cronSecret: null, retention: "30d" });
  const monthly = cw.job("monthly", { schedule: "0 0 1 * *", timezone: "UTC" });
  await monthly.run(async () => {});
  c.set(Date.UTC(2026, 0, 31, 12));
  const first = await cw.check();
  assert.equal(first.pruned, 0);
  c.advance(2 * 60 * MIN);
  await cw.check();
  assert.deepEqual(alerts.types(), []);
  assert.equal((await cw.jobSummary("monthly"))!.health, "healthy");
});

test("an expect RegExp with the g flag gives the same answer every run", async () => {
  const cw = cronwatch({ alerts: [capture()], cronSecret: null });
  const job = cw.job("g", { expect: /done/g });
  for (let i = 0; i < 4; i++) await job.run(async (j) => { j.log("done"); });
  assert.deepEqual((await cw.runs("g")).map((r) => r.status), ["ok", "ok", "ok", "ok"]);
});

test("expect sees a line logged early, even after the stored output has dropped it", async () => {
  const cw = cronwatch({ alerts: [capture()], cronSecret: null });
  await cw.run("report", { expect: "Report written" }, async (j) => {
    j.log("Report written: /tmp/r.pdf");
    for (let i = 0; i < 3000; i++) j.log(`row ${i} ${"x".repeat(40)}`);
  });
  const [run] = await cw.runs("report");
  assert.equal(run!.status, "ok");
  assert.doesNotMatch(run!.output!, /Report written/, "the stored output is still only the tail");
});

test("an interval job whose run is still going is busy, not missed", async () => {
  const c = clock();
  const alerts = capture();
  const cw = cronwatch({ now: c.now, alerts: [alerts], cronSecret: null });
  const job = cw.job("long", { schedule: "every 5m", grace: "2m" });
  let finish!: () => void;
  const running = job.run(() => new Promise<void>((r) => { finish = r; }));
  await new Promise((r) => setTimeout(r, 10));
  c.advance(8 * MIN);
  await cw.check();
  assert.deepEqual(alerts.types(), []);
  finish();
  await running;
  assert.deepEqual(alerts.types(), [], "and no recovered for a miss that never was");
});

test("a run a check marked stuck, that then fails, counts once", async () => {
  const c = clock();
  const alerts = capture();
  const cw = cronwatch({ now: c.now, alerts: [alerts], cronSecret: null });
  const job = cw.job("slowpoke", { timeout: "1m", failuresBeforeAlert: 2 });
  let fail!: () => void;
  const running = job.run(() => new Promise<void>((_, reject) => { fail = () => reject(new Error("gave up")); }));
  await new Promise((r) => setTimeout(r, 10));
  c.advance(2 * MIN);
  await cw.check();
  assert.equal((await cw.store.getState("slowpoke"))!.consecutiveFailures, 1);
  fail();
  await assert.rejects(running);
  assert.equal((await cw.store.getState("slowpoke"))!.consecutiveFailures, 1);
  assert.deepEqual(alerts.types(), [], "one run is one failure, under the threshold of two");
  assert.equal((await cw.runs("slowpoke"))[0]!.error!.split("\n")[0], "Error: gave up", "the run keeps its real error");
});

test("a late success after a stuck mark closes stuck and recovers", async () => {
  const c = clock();
  const alerts = capture();
  const cw = cronwatch({ now: c.now, alerts: [alerts], cronSecret: null });
  const job = cw.job("late", { timeout: "30s" });
  let finish!: () => void;
  const running = job.run(() => new Promise<void>((r) => { finish = r; }));
  await new Promise((r) => setTimeout(r, 10));
  c.advance(MIN);
  const { alerts: fromCheck } = await cw.check();
  assert.match(fromCheck[0]!.run!.error!, /^Still running after 30s;/);
  finish();
  await running;
  assert.deepEqual(alerts.types(), ["stuck", "recovered"]);
});

test("stop() cancels the first check start() scheduled", async () => {
  const cw = cronwatch({ alerts: [capture()], cronSecret: null });
  let checks = 0;
  cw.check = async () => { checks++; return { checkedAt: 0, jobs: [], alerts: [], pruned: 0 }; };
  cw.start();
  cw.stop();
  await new Promise((r) => setTimeout(r, 1_300));
  assert.equal(checks, 0);
});

test("fire times around the autumn clock change are never in the past", () => {
  for (const [tz, day] of [["Europe/London", Date.UTC(2026, 9, 24, 22)], ["America/New_York", Date.UTC(2026, 10, 1, 3)]] as const) {
    for (const expr of ["*/15 * * * *", "30 1 * * *", "0 * * * *"]) {
      const p = parseSchedule(expr, tz);
      for (let t = day; t < day + 8 * 3_600_000; t += 5 * MIN) {
        const next = nextFire(p, t, null)!;
        assert.ok(next > t, `${tz} ${expr}: next ${new Date(next).toISOString()} after ${new Date(t).toISOString()}`);
      }
    }
  }
});

test("forgetting or silencing a job that does not exist answers 404 and creates nothing", async () => {
  const cw = cronwatch({ alerts: [capture()], cronSecret: null });
  const routes = cw.routes({ token: "tok" });
  const auth = { authorization: "Bearer tok" };
  assert.equal((await routes.DELETE(new Request("http://app.test/cronwatch/api/jobs/ghost", { method: "DELETE", headers: auth }))).status, 404);
  const form = await routes.POST(new Request("http://app.test/cronwatch/jobs/ghost/silence", {
    method: "POST", headers: { ...auth, "content-type": "application/x-www-form-urlencoded" }, body: "for=1h",
  }));
  assert.equal(form.status, 404);
  assert.equal(await cw.store.getState("ghost"), null);
});

test("a failed alert names the error once", () => {
  const now = T0;
  const alert = (error: string) => composeAlert({
    type: "failed",
    run: { id: "r", job: "j", status: "failed", startedAt: now, finishedAt: now, durationMs: 5, error, output: null, metrics: {}, trigger: "run" },
    details: { consecutiveFailures: 1, threshold: 1 },
  }, { name: "j" }, now).message;
  assert.match(alert("Error: connect ECONNREFUSED 10.0.0.12:5432"), /^Error: connect ECONNREFUSED/m);
  assert.doesNotMatch(alert("Error: connect ECONNREFUSED 10.0.0.12:5432"), /Error: Error:/);
  assert.match(alert("TypeError: x is undefined"), /^TypeError: x is undefined/m);
  assert.match(alert('Output did not contain "wrote"'), /^Error: Output did not contain "wrote"/m);
  assert.match(alert("HTTP 503 Service Unavailable"), /^Error: HTTP 503/m);
});
