import assert from "node:assert/strict";
import { test } from "node:test";
import { cronwatch, memory } from "../src/index.js";
import type { Alert, AlertChannel, Store } from "../src/index.js";
import { capture, clock, flaky, settle, MIN, HOUR, T0 } from "./helpers.js";

function make(options: Parameters<typeof cronwatch>[0] = {}) {
  const c = clock();
  const alerts = capture();
  const cw = cronwatch({ now: c.now, alerts: [alerts], cronSecret: null, ...options });
  return { cw, c, alerts };
}

test("a cron firing more often than its grace is still missed", async () => {
  const { cw, c, alerts } = make();
  const job = cw.job("often", { schedule: "*/5 * * * *" }); // default grace 10m
  await job.run(async () => {}); // 09:30
  c.advance(14 * MIN);
  assert.deepEqual((await cw.check()).alerts, [], "09:35 is due, grace runs to 09:45");
  c.advance(2 * MIN);
  assert.deepEqual((await cw.check()).alerts.map((a) => a.type), ["missed"]);
  await job.run(async () => {});
  assert.deepEqual(alerts.types(), ["missed", "recovered"]);
});

test("a missed run whose next run fails below the threshold still recovers later", async () => {
  const { cw, c, alerts } = make();
  const job = cw.job("quiet", { schedule: "every 1h", failuresBeforeAlert: 3 });
  await cw.check();
  c.advance(2 * HOUR);
  await cw.check();
  await assert.rejects(job.run(async () => { throw new Error("x"); }));
  assert.deepEqual(alerts.types(), ["missed"]);
  await job.run(async () => {});
  assert.deepEqual(alerts.types(), ["missed", "recovered"]);
  assert.match(alerts.alerts[1]!.message, /after: missed/);
});

test("a store outage never stops the job, and store errors go to onError", async () => {
  const broken = new Set(["upsertJob", "insertRun", "getState", "setState", "updateRun", "listRuns"]);
  const errors: string[] = [];
  const { cw } = make({ store: flaky(memory(), broken), onError: (_e, where) => errors.push(where) });
  let ran = 0;
  assert.equal(await cw.run("s", async () => { ran++; return 7; }), 7);
  await assert.rejects(cw.run("s", async () => { ran++; throw new Error("the job's own"); }), /the job's own/);
  assert.equal(ran, 2);
  assert.ok(errors.length > 0 && errors.every((w) => w === "recording s"), errors.join(", "));
  broken.clear();
  await cw.run("s", async () => "back");
  assert.equal((await cw.runs("s")).length, 1);
});

test("a store that fails to initialise is tried again on the next call", async () => {
  let inits = 0;
  const store: Store = { ...memory(), async init() { if (++inits === 1) throw new Error("not yet"); } };
  const errors: string[] = [];
  const { cw } = make({ store, onError: (_e, where) => errors.push(where) });
  assert.equal(await cw.run("i", async () => 1), 1);
  assert.deepEqual(errors, ["recording i"]);
  // The finished run was written on the retry, once init went through.
  assert.equal(inits, 2);
  await cw.run("i", async () => 2);
  assert.equal(inits, 2);
  assert.equal((await cw.runs("i")).length, 2);
});

test("dispatch does not overwrite a silence made while an alert was being sent", async () => {
  let cwRef: ReturnType<typeof cronwatch> | null = null;
  const silencer: AlertChannel = { name: "silencer", send: async () => { await cwRef!.silence("loud", "1h"); } };
  const { cw } = make({ alerts: [silencer] });
  cwRef = cw;
  await assert.rejects(cw.run("loud", async () => { throw new Error("x"); }));
  const state = (await cw.store.getState("loud"))!;
  assert.ok(state.silencedUntil !== null, "the silence survived");
  assert.deepEqual(state.open, { failed: T0 });
  assert.equal(state.lastAlertAt, T0);
});

test("a hung channel times out without holding up the others", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const errors: string[] = [];
  const good = capture();
  const { cw } = make({ alerts: [{ name: "hung", send: () => new Promise(() => {}) }, good], onError: (_e, where) => errors.push(where) });
  const pending = cw.run("h", async () => { throw new Error("x"); }).catch(() => {});
  await settle();
  assert.deepEqual(good.types(), ["failed"], "the other channel already has it");
  t.mock.timers.tick(15_000);
  await pending;
  assert.deepEqual(errors, ["alert channel hung"]);
  assert.deepEqual((await cw.store.getState("h"))!.undelivered, [], "one channel took it: delivered");
});

test("triage is aborted when the client stops waiting for it", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  let signal: AbortSignal | null = null;
  const errors: string[] = [];
  const { cw, alerts } = make({
    triage: (ctx) => { signal = ctx.signal; return new Promise(() => {}); },
    onError: (_e, where) => errors.push(where),
  });
  const pending = cw.run("t", async () => { throw new Error("x"); }).catch(() => {});
  await settle();
  t.mock.timers.tick(25_000);
  await pending;
  assert.equal(signal!.aborted, true);
  assert.deepEqual(errors, ["triage for t"]);
  assert.deepEqual(alerts.types(), ["failed"]);
});

test("an alert no channel took is retried once per check until one does", async () => {
  let down = true;
  let attempts = 0;
  const got: Alert[] = [];
  const channel: AlertChannel = { name: "flaky", send: async (a) => { attempts++; if (down) throw new Error("down"); got.push(a); } };
  const { cw, c } = make({ alerts: [channel], onError: () => {} });
  await assert.rejects(cw.run("r", async () => { throw new Error("x"); }));
  let state = (await cw.store.getState("r"))!;
  assert.equal(state.undelivered!.length, 1);
  assert.equal(state.lastAlertAt, null, "nothing was delivered");
  c.advance(MIN);
  await cw.check();
  assert.equal(attempts, 2, "one retry per check");
  down = false;
  c.advance(MIN);
  const result = await cw.check();
  assert.deepEqual(result.alerts.map((a) => a.type), ["failed"]);
  assert.deepEqual(got.map((a) => a.type), ["failed"]);
  assert.equal(got[0]!.at, T0, "the same alert, not a new one");
  state = (await cw.store.getState("r"))!;
  assert.deepEqual(state.undelivered, []);
  assert.equal(state.lastAlertAt, T0 + 2 * MIN);
  await cw.check();
  assert.equal(attempts, 3, "not sent again");
});

test("deliver: check queues alerts for another process's check, which sends them with triage", async () => {
  const c = clock();
  const store = memory();
  const unused = capture();
  let triaged = 0;
  // The recording process: no network, so it sends nothing itself.
  const recorder = cronwatch({ store, now: c.now, alerts: [unused], deliver: "check", triage: async () => "never asked", cronSecret: null });
  const job = recorder.job("backup", { schedule: "40 3 * * *", timezone: "UTC" });
  await assert.rejects(job.run(async () => { throw new Error("disk full"); }));
  assert.deepEqual(unused.types(), [], "nothing sent from the recording process");
  let state = (await store.getState("backup"))!;
  assert.deepEqual(state.undelivered!.map((a) => a.type), ["failed"]);
  assert.equal(state.lastAlertAt, null);
  assert.deepEqual((await recorder.check()).alerts, [], "its own check does not send either");

  // The web server: can send, and has not declared the job.
  const sent = capture();
  const server = cronwatch({ store, now: c.now, alerts: [sent], triage: async () => { triaged++; return "The disk is full."; }, cronSecret: null });
  c.advance(MIN);
  const result = await server.check();
  assert.deepEqual(result.alerts.map((a) => a.type), ["failed"]);
  assert.deepEqual(sent.types(), ["failed"]);
  assert.equal(sent.alerts[0]!.triage, "The disk is full.");
  assert.equal(sent.alerts[0]!.at, T0, "the alert from the run, not a new one");
  assert.equal(triaged, 1);
  state = (await store.getState("backup"))!;
  assert.deepEqual(state.undelivered, []);
  assert.equal(state.lastAlertAt, T0 + MIN);
  await server.check();
  assert.deepEqual(sent.types(), ["failed"], "sent once");

  // The recovery takes the same route.
  await job.run(async () => {});
  await server.check();
  assert.deepEqual(sent.types(), ["failed", "recovered"]);
  assert.equal(triaged, 1, "recoveries are not triaged");
});

test("deliver takes only now or check", () => {
  assert.throws(() => cronwatch({ deliver: "later" as never }), /deliver must be "now" or "check"/);
});

test("overlapping runs of one job share its state without losing updates", async () => {
  const { cw, alerts } = make();
  const job = cw.job("par", { failuresBeforeAlert: 2 });
  await Promise.allSettled([1, 2, 3].map(() => job.run(async () => { throw new Error("x"); })));
  assert.equal((await cw.store.getState("par"))!.consecutiveFailures, 3);
  assert.deepEqual(alerts.types(), ["failed"], "one alert, not one per run");
});

test("job() rejects numbers that would quietly turn a check off", () => {
  const { cw } = make();
  assert.throws(() => cw.job("a", { failuresBeforeAlert: Number.NaN }), /failuresBeforeAlert/);
  assert.throws(() => cw.job("a", { failuresBeforeAlert: 0 }), /failuresBeforeAlert/);
  assert.throws(() => cw.job("a", { failuresBeforeAlert: 1.5 }), /failuresBeforeAlert/);
  assert.throws(() => cw.job("a", { budget: { cost: Number.NaN } }), /budget\.cost/);
  assert.throws(() => cw.job("a", { budget: { cost: Infinity } }), /budget\.cost/);
  assert.throws(() => cw.job("a", { budget: { cost: -1 } }), /budget\.cost/);
  assert.throws(() => cw.job("a", { grace: Number.NaN }), /grace/);
  assert.throws(() => cw.job("a", { timeout: 0 }), /timeout/);
  assert.throws(() => cw.job("a", { maxDuration: "0s" }), /maxDuration/);
  assert.throws(() => cw.job("a", { schedule: "0 2 * * *", timezone: "Mars/Olympus" }), /timezone/);
  assert.throws(() => cronwatch({ defaults: { failuresBeforeAlert: Number.NaN } }).job("a"), /failuresBeforeAlert/);
  cw.job("a", { budget: { errors: 0 }, failuresBeforeAlert: 2, timeout: "5m" });
});

test("a returned string is capped like logged output", async () => {
  const { cw } = make();
  await cw.run("big", async () => "x".repeat(40_000));
  const [run] = await cw.runs("big");
  assert.ok(run!.output!.length < 17 * 1024);
  assert.match(run!.output!, /^\[earlier output trimmed\]/);
});

test("runs() takes a whole number of runs in range", async () => {
  const { cw } = make();
  for (let i = 0; i < 3; i++) await cw.run("n", async () => {});
  assert.equal((await cw.runs("n", 2.7)).length, 2);
  assert.equal((await cw.runs("n", -4)).length, 1);
  assert.equal((await cw.runs("n", Number.NaN)).length, 3);
  const [entry] = await cw.jobsWithRuns(2);
  assert.equal(entry!.runs.length, 2);
  assert.equal(entry!.job.lastRun!.id, entry!.runs[0]!.id);
});

test("an error whose stack already names it is not labelled twice", async () => {
  const { cw, alerts } = make();
  await assert.rejects(cw.run("db", async () => {
    const err = new Error("connect ECONNREFUSED 10.0.0.12:5432");
    err.stack = "Error: connect ECONNREFUSED 10.0.0.12:5432\n    at TCPConnectWrap.afterConnect [as oncomplete] (node:net:1615:16)";
    throw err;
  }));
  const [run] = await cw.runs("db");
  assert.equal(run!.error, "Error: connect ECONNREFUSED 10.0.0.12:5432\n    at TCPConnectWrap.afterConnect [as oncomplete] (node:net:1615:16)");
  assert.doesNotMatch(alerts.alerts[0]!.message, /Error: Error:/);
  assert.match(alerts.alerts[0]!.message, /^Error: connect ECONNREFUSED/m);
  await assert.rejects(cw.run("db", async () => { throw new Error("two\nlines"); }));
  assert.match((await cw.runs("db"))[0]!.error!, /^Error: two\nlines\n    at /);
});

test("the baseline reads past recent failures to twenty successful runs", async () => {
  const { cw, c, alerts } = make();
  const job = cw.job("base");
  const at = async (ms: number, fail = false) => {
    await job.run(async () => { c.advance(ms); if (fail) throw new Error("x"); }).catch(() => {});
    c.advance(MIN);
  };
  for (let i = 0; i < 5; i++) await at(100_000);
  for (let i = 0; i < 15; i++) await at(1_000);
  for (let i = 0; i < 10; i++) await at(1_000, true);
  // Fifteen 1s runs alone would make 10s the limit; with the five 100s runs, p95 is 100s.
  await at(30_000);
  assert.deepEqual(alerts.types(), ["failed", "recovered"]);
});

test("handler fails closed without a secret outside development", async () => {
  const saved = process.env.NODE_ENV;
  const errors: string[] = [];
  try {
    delete process.env.NODE_ENV;
    const c = clock();
    const cw = cronwatch({ now: c.now, alerts: [capture()], cronSecret: "", onError: (_e, where) => errors.push(where) });
    let ran = 0;
    const handler = cw.job("closed").handler(async () => { ran++; });
    assert.equal(cw.cronSecret, null, "an empty secret is no secret");
    const res = await handler(new Request("http://x/"));
    assert.equal(res.status, 503);
    assert.match((await res.json()).error, /CRON_SECRET/);
    await handler(new Request("http://x/"));
    assert.equal(ran, 0);
    assert.deepEqual(errors, ["handler"], "reported once");

    // Opting out with null runs the job, and does not show the error to the caller.
    const open = cw.job("open").handler(async () => { throw new Error("private detail"); }, { secret: null });
    const failed = await open(new Request("http://x/"));
    assert.equal(failed.status, 500);
    assert.equal((await failed.json()).error, undefined);

    process.env.NODE_ENV = "development";
    assert.equal((await handler(new Request("http://x/"))).status, 200);
    assert.equal(ran, 1);
  } finally {
    if (saved === undefined) delete process.env.NODE_ENV;
    else process.env.NODE_ENV = saved;
  }
});

test("stop() also cancels the first check start() schedules", (t) => {
  t.mock.timers.enable({ apis: ["setTimeout", "setInterval"] });
  const { cw } = make();
  let checks = 0;
  cw.check = async () => { checks++; return { checkedAt: 0, jobs: [], alerts: [], pruned: 0 }; };
  cw.start();
  cw.stop();
  t.mock.timers.tick(120_000);
  assert.equal(checks, 0);
  cw.start();
  t.mock.timers.tick(1_000);
  assert.equal(checks, 1);
  cw.stop();
});

test("execute is not part of the public API", () => {
  const { cw } = make();
  // @ts-expect-error execute is private; use run() or a handle.
  void cw.execute;
});
