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

/** A job's failure queued by a deliver: "check" process, so a check elsewhere must triage and send it. */
async function queued(store: Store, c: ReturnType<typeof clock>, name = "backup") {
  const recorder = cronwatch({ store, now: c.now, deliver: "check", cronSecret: null });
  await assert.rejects(recorder.run(name, async () => { throw new Error("disk full"); }));
  return recorder;
}

test("a diagnosis made on a retry is kept with the queued alert, and triage runs once per alert", async () => {
  const c = clock();
  const store = memory();
  await queued(store, c);
  let asked = 0;
  let down = true;
  const sent: Alert[] = [];
  const channel: AlertChannel = { name: "flaky", send: async (a) => { if (down) throw new Error("down"); sent.push(a); } };
  const server = cronwatch({ store, now: c.now, alerts: [channel], triage: async () => { asked++; return "The disk is full."; }, cronSecret: null, onError: () => {} });
  await server.check();
  assert.equal(asked, 1);
  assert.equal((await store.getState("backup"))!.undelivered![0]!.triage, "The disk is full.", "the stored copy has it");
  await server.check();
  await server.check();
  assert.equal(asked, 1, "not asked again on later retries");
  down = false;
  await server.check();
  assert.deepEqual(sent.map((a) => [a.type, a.triage]), [["failed", "The disk is full."]]);
});

test("a triage that throws or answers nothing is tried once, recorded as null", async () => {
  for (const triage of [async () => { throw new Error("api down"); }, async () => "", async () => null]) {
    const c = clock();
    const store = memory();
    await queued(store, c);
    let asked = 0;
    const server = cronwatch({
      store, now: c.now, cronSecret: null, onError: () => {},
      alerts: [{ name: "down", send: async () => { throw new Error("down"); } }],
      triage: async (ctx) => { asked++; return triage(); },
    });
    for (let i = 0; i < 3; i++) await server.check();
    assert.equal(asked, 1);
    assert.equal((await store.getState("backup"))!.undelivered![0]!.triage, null);
  }
});

test("retries stop once a check has spent its budget, and the rest wait", async (t) => {
  t.mock.timers.enable({ apis: ["Date"], now: T0 });
  const c = clock();
  const store = memory();
  for (const name of ["a", "b", "c"]) await queued(store, c, name);
  const tried: string[] = [];
  // Each attempt takes twelve seconds of wall clock and fails.
  const slow: AlertChannel = { name: "slow", send: async (a) => { tried.push(a.job); t.mock.timers.tick(12_000); throw new Error("timed out"); } };
  const server = cronwatch({ store, now: c.now, alerts: [slow], cronSecret: null, onError: () => {} });
  await server.check();
  assert.deepEqual(tried, ["a", "b"], "twenty seconds cover two attempts");
  assert.equal((await store.getState("c"))!.undelivered!.length, 1, "c is still queued");
  tried.length = 0;
  await server.check();
  assert.deepEqual(tried, ["a", "b"], "each check has a fresh budget");
});

test("an alert whose condition closed is dropped from the retry queue; a recovery whose conditions stay closed is sent", async () => {
  let down = true;
  const sent: string[] = [];
  const channel: AlertChannel = { name: "flaky", send: async (a) => { if (down) throw new Error("down"); sent.push(`${a.type}@${a.at}`); } };
  const { cw, c } = make({ alerts: [channel], onError: () => {} });
  await assert.rejects(cw.run("s", async () => { throw new Error("x"); }));
  c.advance(MIN);
  await cw.run("s", async () => {});
  assert.deepEqual((await cw.store.getState("s"))!.undelivered!.map((a) => a.type), ["failed", "recovered"]);
  down = false;
  c.advance(MIN);
  await cw.check();
  assert.deepEqual(sent, [`recovered@${T0 + MIN}`], "the failure is over, so only its recovery goes");
  assert.deepEqual((await cw.store.getState("s"))!.undelivered, []);
});

test("an alert whose condition opened again at another time is dropped, and so is a recovery it undoes", async () => {
  let down = true;
  const sent: string[] = [];
  const channel: AlertChannel = { name: "flaky", send: async (a) => { if (down) throw new Error("down"); sent.push(`${a.type}@${a.at}`); } };
  const { cw, c } = make({ alerts: [channel], onError: () => {} });
  await assert.rejects(cw.run("s", async () => { throw new Error("x"); }));
  c.advance(MIN);
  await cw.run("s", async () => {});
  c.advance(MIN);
  await assert.rejects(cw.run("s", async () => { throw new Error("again"); }));
  assert.deepEqual((await cw.store.getState("s"))!.undelivered!.map((a) => a.type), ["failed", "recovered", "failed"]);
  down = false;
  c.advance(MIN);
  await cw.check();
  assert.deepEqual(sent, [`failed@${T0 + 2 * MIN}`]);
});

test("a job that cannot be evaluated is reported and shown as failing, and the others are checked", async () => {
  const errors: [unknown, string][] = [];
  const { cw, c, alerts } = make({ onError: (e, where) => errors.push([e, where]) });
  const good = cw.job("good", { schedule: "every 1h" });
  await good.run(async () => {});
  await cw.store.upsertJob({ name: "bad", schedule: "not a schedule" }, T0);
  await cw.store.upsertJob({ name: "odd", timeout: "soon" }, T0);
  await cw.store.insertRun({ id: "hung", job: "odd", status: "running", startedAt: T0, finishedAt: null, durationMs: null, error: null, output: null, metrics: {}, trigger: "run" });
  c.advance(2 * HOUR);
  const result = await cw.check();
  assert.deepEqual(result.alerts.map((a) => `${a.job}:${a.type}`), ["good:missed"]);
  const health = Object.fromEntries(result.jobs.map((j) => [j.name, j.health]));
  assert.deepEqual(health, { bad: "failing", good: "late", odd: "failing" });
  assert.deepEqual(errors.map(([, where]) => where), ["checking odd", "checking bad", "checking odd"]);
  assert.deepEqual(alerts.types(), ["missed"]);

  errors.length = 0;
  const jobs = await cw.jobs();
  assert.deepEqual(jobs.map((j) => [j.name, j.health, j.nextExpectedAt === null]), [["bad", "failing", true], ["good", "late", false], ["odd", "failing", true]]);
  assert.deepEqual(errors.map(([, where]) => where), ["reading bad", "reading odd"]);
  assert.equal((await cw.jobSummary("bad"))!.health, "failing");
  await cw.silence("bad", "1h");
  assert.equal((await cw.jobSummary("bad"))!.health, "silenced");
});

test("trimming the undelivered queue past twenty is reported", async () => {
  const c = clock();
  const errors: string[] = [];
  const cw = cronwatch({ now: c.now, deliver: "check", cronSecret: null, onError: (_e, where) => errors.push(where) });
  for (let i = 0; i < 10; i++) {
    await assert.rejects(cw.run("q", async () => { throw new Error("x"); }));
    await cw.run("q", async () => {});
  }
  assert.equal((await cw.store.getState("q"))!.undelivered!.length, 20);
  assert.deepEqual(errors, []);
  await assert.rejects(cw.run("q", async () => { throw new Error("x"); }));
  assert.equal((await cw.store.getState("q"))!.undelivered!.length, 20);
  assert.deepEqual(errors, ["alert queue for q"]);
});

test('start() with deliver: "check" says once that another process must send', (t) => {
  t.mock.timers.enable({ apis: ["setTimeout", "setInterval"] });
  const warnings: string[] = [];
  const warn = console.warn;
  console.warn = (...parts: unknown[]) => { warnings.push(parts.map(String).join(" ")); };
  try {
    const cw = cronwatch({ deliver: "check", cronSecret: null });
    cw.check = async () => ({ checkedAt: 0, jobs: [], alerts: [], pruned: 0 });
    cw.start();
    cw.stop();
    cw.start();
    cw.stop();
    assert.equal(warnings.length, 1);
    assert.match(warnings[0]!, /deliver: "check".*send no alerts.*Another process/);
    cronwatch({ cronSecret: null }).start();
    assert.equal(warnings.length, 1, "a delivering client says nothing");
  } finally {
    console.warn = warn;
  }
});
