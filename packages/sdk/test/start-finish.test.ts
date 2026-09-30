import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";
import { cronwatch, custom, memory } from "../src/index.js";
import pg from "pg";
import { postgres } from "../src/stores/postgres.js";
import { sqlite } from "../src/stores/sqlite.js";
import type { Store } from "../src/types.js";
import { capture, clock, flaky, HOUR, MIN } from "./helpers.js";

function make(options: Parameters<typeof cronwatch>[0] = {}) {
  const c = clock();
  const alerts = capture();
  const errors: { error: unknown; where: string }[] = [];
  const cw = cronwatch({ now: c.now, alerts: [alerts], cronSecret: null, onError: (error, where) => errors.push({ error, where }), ...options });
  return { cw, c, alerts, errors };
}

const PG = process.env.CRONWATCH_TEST_PG;

const messages = (errors: { error: unknown }[]) => errors.map((e) => (e.error as Error).message);

test("start records a running run and finish records it ok", async () => {
  const { cw, c, alerts } = make();
  const job = cw.job("sync", { schedule: "@hourly" });
  const run = await job.start({ trigger: "queue" });
  assert.equal(run.job, "sync");
  assert.equal(run.active, true);
  const stored = await cw.getRun(run.id);
  assert.equal(stored!.status, "running");
  assert.equal(stored!.trigger, "queue");
  run.log("imported", 12, "rows");
  run.metric("rows", 12);
  c.advance(90_000);
  const finished = await run.finish();
  assert.equal(finished!.status, "ok");
  assert.equal(finished!.durationMs, 90_000);
  assert.equal(run.active, false);
  const [recorded] = await cw.runs("sync");
  assert.equal(recorded!.status, "ok");
  assert.equal(recorded!.output, "imported 12 rows");
  assert.deepEqual(recorded!.metrics, { rows: 12 });
  assert.deepEqual(alerts.types(), []);
  assert.equal((await cw.jobSummary("sync"))!.health, "healthy");
});

test("fail and finish({ error }) record a failure and alert once", async () => {
  const { cw, alerts } = make();
  const job = cw.job("import", { failuresBeforeAlert: 2 });
  const first = await job.start();
  await first.fail(new Error("api down"));
  const second = await job.start();
  const run = await second.finish({ error: new Error("still down") });
  assert.equal(run!.status, "failed");
  assert.match(run!.error!, /^Error: still down/);
  assert.deepEqual(alerts.types(), ["failed"]);
  const third = await job.start({ trigger: "retry" });
  await third.finish({ status: "ok" });
  assert.deepEqual(alerts.types(), ["failed", "recovered"]);
});

test("a second finish is ignored and reported, not thrown", async () => {
  const { cw, alerts, errors } = make();
  const job = cw.job("once");
  const run = await job.start();
  const [a, b] = await Promise.all([run.fail("boom"), run.finish()]);
  assert.equal(a!.status, "failed");
  assert.equal(b, null);
  assert.equal(await run.finish(), null);
  assert.deepEqual(alerts.types(), ["failed"]);
  assert.equal((await cw.runs("once"))[0]!.status, "failed");
  assert.equal(errors.length, 2);
  assert.match(messages(errors)[0]!, /was already finished by this handle; ignored/);
  assert.equal(errors[0]!.where, "finishing once");
});

test("start with an id twice records one run and returns a handle on it", async () => {
  const { cw, errors } = make();
  const job = cw.job("inngest-fn");
  const [one, two] = await Promise.all([job.start({ id: "01HX-run" }), job.start({ id: "01HX-run" })]);
  assert.equal(one.id, "01HX-run");
  assert.equal(two.id, "01HX-run");
  const again = await job.start({ id: "01HX-run", trigger: "ignored" });
  assert.equal(again.active, true);
  assert.equal((await cw.runs("inngest-fn")).length, 1);
  assert.equal((await cw.getRun("01HX-run"))!.trigger, "start");
  await again.finish("done");
  // Finished elsewhere: this handle's finish is a reported no-op.
  assert.equal(await one.finish(), null);
  assert.match(messages(errors).at(-1)!, /already finished as ok; ignored/);
  const late = await job.start({ id: "01HX-run" });
  assert.equal(late.active, false);
  assert.equal(await late.finish(), null);
  assert.equal((await cw.runs("inngest-fn")).length, 1);
  await assert.rejects(cw.job("other").start({ id: "01HX-run" }), /belongs to job "inngest-fn"/);
  await assert.rejects(job.start({ id: "" }), /run id of 1 to 200 characters/);
  // No store could hold a NUL (Postgres refuses it), so such an id is refused wherever one is taken.
  await assert.rejects(job.start({ id: "01HX\u0000run" }), /start\(\) cannot take a run id containing a NUL character/);
  await assert.rejects(job.resume("01HX\u0000run"), /resume\(\) cannot take a run id containing a NUL character/);
  const nulRun = { id: "x\u0000y", job: "inngest-fn", status: "ok" as const, startedAt: 1, finishedAt: 2, durationMs: 1, error: null, output: null, metrics: {}, trigger: "run" };
  await assert.rejects(cw.recordRun(nulRun), /recordRun: run ids cannot contain a NUL character/);
  assert.equal((await cw.runs("inngest-fn")).length, 1);
});

type Pair = { a: Store; b: Store; done: () => Promise<void> | void };
for (const [label, open, skip] of [
  ["memory", () => { const store = memory(); return { a: store, b: store, done: () => {} }; }, false],
  ["sqlite", () => {
    const dir = mkdtempSync(path.join(tmpdir(), "cronwatch-resume-"));
    const file = path.join(dir, "cw.db");
    const a = sqlite({ path: file });
    const b = sqlite({ path: file });
    return { a, b, done: () => rmSync(dir, { recursive: true, force: true }) };
  }, false],
  ["postgres", () => {
    const prefix = `t${Date.now()}_${Math.floor(Math.random() * 1e6)}_`;
    const a = postgres({ connectionString: PG, prefix });
    const b = postgres({ connectionString: PG, prefix });
    return {
      a,
      b,
      done: async () => {
        const pool = new pg.Pool({ connectionString: PG });
        await pool.query(`DROP TABLE IF EXISTS ${prefix}jobs, ${prefix}runs, ${prefix}state`);
        await pool.end();
      },
    };
  }, PG ? false : "set CRONWATCH_TEST_PG to a Postgres URL to run"],
] as [string, () => Pair, string | false][]) {
  test(`resume in a second client on the same store (${label}) appends and finishes`, { skip }, async () => {
    const stores = open();
    const c = clock();
    const alerts = capture();
    const errors: unknown[] = [];
    const onError = (e: unknown) => errors.push(e);
    const first = cronwatch({ store: stores.a, now: c.now, alerts: [alerts], cronSecret: null, onError });
    const second = cronwatch({ store: stores.b, now: c.now, alerts: [alerts], cronSecret: null, onError });
    const options = { expect: "sent", budget: { emails: 100 } };
    const started = await first.job("digest", options).start({ id: "evt-1" });
    started.log("loaded 40 recipients");
    started.log("token=abc123");
    started.metric("recipients", 40);
    await started.flush();
    const midway = await first.getRun("evt-1");
    assert.equal(midway!.status, "running");
    assert.equal(midway!.output, "loaded 40 recipients\ntoken=[redacted]");

    c.advance(5 * MIN);
    second.job("digest", options);
    const resumed = await second.resumeRun("digest", "evt-1");
    assert.equal(resumed.active, true);
    assert.equal(resumed.startedAt, midway!.startedAt);
    resumed.log("sent 40 emails");
    resumed.metric("emails", 40);
    const run = await resumed.finish();
    assert.equal(run!.status, "ok");
    assert.equal(run!.durationMs, 5 * MIN);
    const stored = await first.getRun("evt-1");
    assert.equal(stored!.status, "ok");
    assert.equal(stored!.output, "loaded 40 recipients\ntoken=[redacted]\nsent 40 emails");
    assert.deepEqual(stored!.metrics, { recipients: 40, emails: 40 });
    assert.deepEqual(alerts.types(), []);
    assert.deepEqual(errors, []);
    await first.close();
    await second.close();
    await stores.done();
  });
}

test("resume of an unknown or finished run returns a handle whose finish is a reported no-op", async () => {
  const { cw, errors } = make();
  const job = cw.job("webhook");
  const missing = await job.resume("nope");
  assert.equal(missing.active, false);
  assert.equal(missing.startedAt, null);
  missing.log("dropped");
  await missing.flush();
  assert.equal(await missing.finish(), null);
  assert.match(messages(errors)[0]!, /run nope of webhook was not found; ignored/);
  await job.run(() => "done");
  const [done] = await cw.runs("webhook");
  const finished = await job.resume(done!.id);
  assert.equal(finished.active, false);
  assert.equal(await finished.fail("late"), null);
  assert.match(messages(errors)[1]!, /already finished as ok; ignored/);
  assert.equal((await cw.runs("webhook"))[0]!.status, "ok");
  await assert.rejects(cw.resumeRun("undeclared", "x"), /not declared/);
});

test("a run never finished is marked stuck after the job's timeout", async () => {
  const { cw, c, alerts } = make();
  const job = cw.job("callback", { timeout: "30m" });
  const run = await job.start();
  c.advance(29 * MIN);
  await cw.check();
  assert.equal((await cw.getRun(run.id))!.status, "running");
  c.advance(2 * MIN);
  await cw.check();
  const stored = await cw.getRun(run.id);
  assert.equal(stored!.status, "timeout");
  assert.match(stored!.error!, /Still running after 30m/);
  assert.deepEqual(alerts.types(), ["stuck"]);
});

test("lines flushed while a check marks earlier runs stuck are kept on the run it marks next", async () => {
  let release!: () => void;
  let entered!: () => void;
  const gate = new Promise<void>((r) => { release = r; });
  const sending = new Promise<void>((r) => { entered = r; });
  const held = custom("held", async () => { entered(); await gate; });
  const { cw, c } = make({ alerts: [held] });
  const first = await cw.job("first", { timeout: "30m" }).start();
  c.advance(1000);
  const second = await cw.job("second", { timeout: "30m" }).start();
  second.log("early line");
  second.metric("rows", 1);
  await second.flush();
  c.advance(31 * MIN);
  const check = cw.check();
  // The first stuck run's alert is being sent; the second is still running, and flushes.
  await sending;
  second.log("important progress line");
  second.metric("rows", 2);
  await second.flush();
  release();
  await check;
  const stored = (await cw.getRun(second.id))!;
  assert.equal(stored.status, "timeout");
  assert.equal(stored.output, "early line\nimportant progress line");
  assert.deepEqual(stored.metrics, { rows: 2 });
  assert.equal((await cw.getRun(first.id))!.status, "timeout");
});

test("a late success after a timeout mark closes stuck and recovers; a late failure does not count twice", async () => {
  const { cw, c, alerts } = make();
  const job = cw.job("slowpoke", { timeout: "10m", failuresBeforeAlert: 2 });
  const first = await job.start();
  c.advance(11 * MIN);
  await cw.check();
  assert.deepEqual(alerts.types(), []);
  const failed = await first.fail(new Error("gave up"));
  assert.equal(failed!.status, "failed");
  assert.equal((await cw.getRun(first.id))!.error!.split("\n")[0], "Error: gave up", "the run keeps its real error");
  assert.deepEqual(alerts.types(), [], "the late failure did not count as a second one");

  const second = await job.start();
  c.advance(11 * MIN);
  await cw.check();
  assert.deepEqual(alerts.types(), ["stuck"]);
  const resumed = await cw.resumeRun("slowpoke", second.id);
  assert.equal(resumed.active, true, "a run marked timeout can still be finished late");
  const late = await resumed.finish();
  assert.equal(late!.status, "ok");
  assert.deepEqual(alerts.types(), ["stuck", "recovered"]);
  assert.equal(await second.finish(), null, "the handle that started it sees it finished elsewhere");
});

test("expect is applied at finish, to the logged lines or the string passed", async () => {
  const { cw, alerts } = make();
  const job = cw.job("export", { expect: /wrote \d+ files/ });
  const quiet = await job.start();
  const run = await quiet.finish({ status: "ok", result: "nothing to do" });
  assert.equal(run!.status, "failed");
  assert.equal(run!.output, "nothing to do");
  assert.match(run!.error!, /did not match/);
  assert.deepEqual(alerts.types(), ["failed"]);

  const busy = await job.start();
  busy.log("wrote 3 files");
  await busy.flush();
  const resumed = await job.resume(busy.id);
  assert.equal((await resumed.finish("uploaded"))!.status, "ok", "lines flushed earlier count toward expect");
  assert.deepEqual(alerts.types(), ["failed", "recovered"]);

  const http = await job.start();
  const bad = await http.finish({ result: new Response("no", { status: 502 }) });
  assert.equal(bad!.error, "HTTP 502");
});

test("a store failing during start does not throw; finish records the run once the store is back", async () => {
  const broken = new Set(["insertRun"]);
  const { cw, c, alerts, errors } = make({ store: flaky(memory(), broken) });
  const job = cw.job("backup", { schedule: "@hourly" });
  const run = await job.start();
  assert.equal(run.active, true);
  assert.equal(errors[0]!.where, "recording backup");
  assert.equal(await cw.getRun(run.id), null);
  run.log("copied");
  await run.flush(); // nothing stored to append to; kept for finish
  broken.clear();
  c.advance(HOUR / 2);
  const finished = await run.finish();
  assert.equal(finished!.status, "ok");
  const stored = await cw.getRun(run.id);
  assert.equal(stored!.status, "ok");
  assert.equal(stored!.output, "copied");
  assert.equal(stored!.durationMs, HOUR / 2);
  assert.deepEqual(alerts.types(), []);
});

test("a store failing at finish is reported, not thrown, and the handle can finish again", async () => {
  const broken = new Set<string>();
  const { cw, errors } = make({ store: flaky(memory(), broken) });
  const job = cw.job("flaky");
  const run = await job.start();
  run.log("working");
  broken.add("getRun").add("updateRun").add("updateRunIf");
  await run.flush();
  assert.equal(errors.at(-1)!.where, "flushing flaky");
  assert.equal(await run.finish(), null, "nothing recorded");
  assert.ok(errors.some((e) => e.where === "finishing flaky"));
  assert.equal(run.active, true, "still active, to finish again");
  // The read works but the write fails: still retryable.
  broken.delete("getRun");
  assert.equal(await run.finish(), null);
  assert.equal(run.active, true);
  broken.clear();
  assert.equal((await cw.getRun(run.id))!.status, "running", "nothing written yet");
  const finished = await run.finish();
  assert.equal(finished!.status, "ok");
  assert.equal(finished!.output, "working", "the lines logged before the failures are kept");
  assert.equal(run.active, false);
  assert.equal(await run.finish(), null, "finished once only");
});
