import assert from "node:assert/strict";
import { test } from "node:test";
import { cronwatch } from "../src/index.js";
import { capture, clock, MIN, HOUR, T0 } from "./helpers.js";

function make(options: Parameters<typeof cronwatch>[0] = {}) {
  const c = clock();
  const alerts = capture();
  const cw = cronwatch({ now: c.now, alerts: [alerts], cronSecret: null, ...options });
  return { cw, c, alerts };
}

test("run records output, metrics and duration, and returns the result", async () => {
  const { cw, c } = make();
  const job = cw.job("report", { schedule: "0 2 * * *" });
  const result = await job.run(async (j) => {
    j.log("hello", { n: 1 });
    j.metric("rows", 42);
    c.advance(1500);
    return "done";
  });
  assert.equal(result, "done");
  const [run] = await cw.runs("report");
  assert.equal(run!.status, "ok");
  assert.equal(run!.durationMs, 1500);
  assert.equal(run!.output, 'hello {"n":1}');
  assert.deepEqual(run!.metrics, { rows: 42 });
  const summary = await cw.jobSummary("report");
  assert.equal(summary!.health, "healthy");
  assert.equal(summary!.nextExpectedAt, Date.UTC(2026, 0, 6, 2, 0));
});

test("a throwing job is recorded as failed, alerts, and rethrows", async () => {
  const { cw, alerts } = make();
  const job = cw.job("nightly");
  await assert.rejects(job.run(async () => { throw new Error("db down"); }), /db down/);
  const [run] = await cw.runs("nightly");
  assert.equal(run!.status, "failed");
  assert.match(run!.error!, /Error: db down/);
  assert.deepEqual(alerts.types(), ["failed"]);
  assert.match(alerts.alerts[0]!.message, /db down/);
  assert.equal((await cw.jobSummary("nightly"))!.health, "failing");
});

test("expect turns a quiet success into a failure", async () => {
  const { cw, c, alerts } = make();
  const job = cw.job("export", { expect: "wrote" });
  await job.run(async (j) => { j.log("wrote 12 files"); });
  assert.deepEqual(alerts.types(), []);
  c.advance(HOUR);
  await job.run(async (j) => { j.log("nothing to do"); });
  const [run] = await cw.runs("export");
  assert.equal(run!.status, "failed");
  assert.match(run!.error!, /did not contain "wrote"/);
  assert.deepEqual(alerts.types(), ["failed"]);
  // A returned string counts as output too.
  await job.run(async () => "wrote 3 files");
  assert.deepEqual(alerts.types(), ["failed", "recovered"]);
});

test("cw.run defines on first use and validates names and schedules", async () => {
  const { cw } = make();
  await cw.run("adhoc", { schedule: "every 5m" }, async () => 1);
  assert.equal((await cw.jobs()).length, 1);
  assert.throws(() => cw.job("bad name!"), /job name/);
  assert.throws(() => cw.job("x", { schedule: "nope" }), /not a cron expression/);
  assert.throws(() => cw.job("x", { grace: "soon" }), /grace/);
});

test("handler checks the bearer secret and reports the run", async () => {
  const { cw } = make({ cronSecret: "s3cret" });
  const handler = cw.job("hourly", { schedule: "@hourly" }).handler(async (j, req) => {
    j.log(new URL(req.url).pathname);
    if (req.headers.get("x-fail")) throw new Error("nope");
    return { fine: true };
  });
  const noAuth = await handler(new Request("http://x/api/cron/hourly"));
  assert.equal(noAuth.status, 401);
  const ok = await handler(new Request("http://x/api/cron/hourly", { headers: { authorization: "Bearer s3cret" } }));
  assert.equal(ok.status, 200);
  const body = await ok.json();
  assert.equal(body.ok, true);
  assert.equal(body.job, "hourly");
  const failed = await handler(new Request("http://x/api/cron/hourly", { headers: { authorization: "Bearer s3cret", "x-fail": "1" } }));
  assert.equal(failed.status, 500);
  assert.match((await failed.json()).error, /nope/);
  const runs = await cw.runs("hourly");
  assert.equal(runs.length, 2);
  assert.equal(runs[1]!.output, "/api/cron/hourly");
});

test("a handler returning a Response passes it through, and 4xx/5xx count as failure", async () => {
  const { cw, alerts } = make();
  const handler = cw.job("h").handler(async () => new Response("bad", { status: 503 }));
  const res = await handler(new Request("http://x/"));
  assert.equal(res.status, 503);
  assert.equal(await res.text(), "bad");
  assert.equal((await cw.runs("h"))[0]!.error, "HTTP 503");
  assert.deepEqual(alerts.types(), ["failed"]);
});

test("check finds a missed run, once, and a later run recovers", async () => {
  const { cw, c, alerts } = make();
  const job = cw.job("sync", { schedule: "every 1h", grace: "10m" });
  await cw.check(); // registers at T0
  c.advance(30 * MIN);
  assert.deepEqual((await cw.check()).alerts, []);
  c.set(T0 + 70 * MIN + 1);
  const r = await cw.check();
  assert.deepEqual(r.alerts.map((a) => a.type), ["missed"]);
  assert.equal(r.jobs[0]!.health, "late");
  assert.deepEqual((await cw.check()).alerts, [], "no repeat");
  await job.run(async () => {});
  assert.deepEqual(alerts.types(), ["missed", "recovered"]);
  assert.equal((await cw.jobSummary("sync"))!.health, "healthy");
});

test("check marks a run that never finished as stuck", async () => {
  const { cw, c, alerts } = make();
  const job = cw.job("long", { timeout: "5m" });
  const pending = job.run(() => new Promise<void>(() => {}));
  void pending;
  await new Promise((r) => setImmediate(r));
  assert.equal((await cw.runs("long"))[0]!.status, "running");
  c.advance(4 * MIN);
  assert.deepEqual((await cw.check()).alerts, []);
  c.advance(2 * MIN);
  const r = await cw.check();
  assert.deepEqual(r.alerts.map((a) => a.type), ["stuck"]);
  assert.equal((await cw.runs("long"))[0]!.status, "timeout");
  assert.equal(r.jobs[0]!.health, "stuck");
  assert.match(alerts.alerts[0]!.message, /never reported finishing/);
});

test("slow and over-budget alerts come from the job's own baseline", async () => {
  const { cw, c, alerts } = make();
  const job = cw.job("agent", { budget: { cost: 1 } });
  for (let i = 0; i < 5; i++) {
    await job.run(async (j) => { c.advance(1000); j.metrics({ tokens: 1000, cost: 0.5 }); });
    c.advance(HOUR);
  }
  assert.deepEqual(alerts.types(), []);
  await job.run(async (j) => { c.advance(15_000); j.metrics({ tokens: 1000, cost: 0.5 }); });
  assert.deepEqual(alerts.types(), ["slow"]);
  c.advance(HOUR);
  await job.run(async (j) => { c.advance(1000); j.metrics({ tokens: 5000, cost: 1.2 }); });
  assert.deepEqual(alerts.types(), ["slow", "over_budget"]);
  const last = alerts.alerts[1]!;
  assert.match(last.message, /cost: 1\.2, limit 1 \(budget\)/);
  assert.match(last.message, /tokens: 5,000, limit 3,000 \(three times the usual 1,000\)/);
  c.advance(HOUR);
  await job.run(async (j) => { c.advance(1000); j.metrics({ tokens: 1000, cost: 0.5 }); });
  assert.deepEqual(alerts.types(), ["slow", "over_budget", "recovered"]);
});

test("silence swallows alerts and nothing opens underneath; unsilence alerts again", async () => {
  const { cw, c, alerts } = make();
  const job = cw.job("flaky");
  await cw.silence("flaky", "1h");
  await assert.rejects(job.run(async () => { throw new Error("x"); }));
  assert.deepEqual(alerts.types(), []);
  assert.equal((await cw.jobSummary("flaky"))!.health, "silenced");
  await cw.unsilence("flaky");
  await assert.rejects(job.run(async () => { throw new Error("y"); }));
  assert.deepEqual(alerts.types(), ["failed"]);
  c.advance(1);
});

test("triage output is attached to failure alerts and never blocks them", async () => {
  const { cw, alerts } = make({ triage: async ({ alert }) => `Probably ${alert.job}'s database.` });
  await assert.rejects(cw.run("t", async () => { throw new Error("x"); }));
  assert.equal(alerts.alerts[0]!.triage, "Probably t's database.");
  const errors: string[] = [];
  const { cw: cw2, alerts: alerts2 } = make({ triage: async () => { throw new Error("api down"); }, onError: (e, where) => errors.push(where) });
  await assert.rejects(cw2.run("t", async () => { throw new Error("x"); }));
  assert.deepEqual(alerts2.types(), ["failed"]);
  assert.equal(alerts2.alerts[0]!.triage, null, "tried, and gave nothing");
  assert.deepEqual(errors, ["triage for t"]);
});

test("forget removes the job and its runs", async () => {
  const { cw } = make();
  await cw.run("gone", async () => {});
  assert.equal((await cw.jobs()).length, 1);
  await cw.forget("gone");
  assert.equal((await cw.jobs()).length, 0);
  assert.equal(await cw.jobSummary("gone"), null);
});

test("a failing alert channel does not break the run", async () => {
  const errors: string[] = [];
  const { cw } = make({ alerts: [{ name: "broken", send: async () => { throw new Error("no network"); } }], onError: (_e, where) => errors.push(where) });
  await assert.rejects(cw.run("x", async () => { throw new Error("job"); }), /job/);
  assert.deepEqual(errors, ["alert channel broken"]);
});
