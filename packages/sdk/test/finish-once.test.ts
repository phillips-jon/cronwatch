import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";
import pg from "pg";
import { cronwatch, memory } from "../src/index.js";
import type { CronWatch } from "../src/index.js";
import { postgres } from "../src/stores/postgres.js";
import { sqlite } from "../src/stores/sqlite.js";
import type { Run, Store } from "../src/types.js";
import { capture, clock, HOUR, MIN, T0 } from "./helpers.js";

const PG = process.env.CRONWATCH_TEST_PG;
const NO_PG = PG ? false : "set CRONWATCH_TEST_PG to a Postgres URL to run";

type Stores = { open: () => Store; done: () => Promise<void> | void };

/** Several stores over one database, as several processes would have. */
const backends: [string, () => Stores, string | false][] = [
  ["memory", () => { const store = memory(); return { open: () => store, done: () => {} }; }, false],
  ["sqlite", () => {
    const dir = mkdtempSync(path.join(tmpdir(), "cronwatch-once-"));
    const file = path.join(dir, "cw.db");
    const opened: Store[] = [];
    return {
      open: () => { const s = sqlite({ path: file }); opened.push(s); return s; },
      done: async () => { for (const s of opened) await s.close?.(); rmSync(dir, { recursive: true, force: true }); },
    };
  }, false],
  ["postgres", () => {
    const prefix = `once${process.pid}_${Math.floor(Math.random() * 1e6)}_`;
    const opened: Store[] = [];
    return {
      open: () => { const s = postgres({ connectionString: PG, prefix }); opened.push(s); return s; },
      done: async () => {
        for (const s of opened) await s.close?.();
        const pool = new pg.Pool({ connectionString: PG });
        await pool.query(`DROP TABLE IF EXISTS ${prefix}jobs, ${prefix}runs, ${prefix}state`);
        await pool.end();
      },
    };
  }, NO_PG],
];

function client(store: Store, now: () => number) {
  const alerts = capture();
  const errors: string[] = [];
  const cw = cronwatch({ store, now, alerts: [alerts], cronSecret: null, onError: (e) => errors.push((e as Error).message) });
  return { cw, alerts, errors };
}

const failedRun = (id: string, job: string, startedAt: number): Run => ({
  id, job, status: "failed", startedAt, finishedAt: startedAt + 1000, durationMs: 1000, error: "ERROR: deadlock detected", output: null, metrics: {}, trigger: "pg_cron",
});

for (const [label, make, skip] of backends) {
  test(`${label}: two processes finishing one run: one records and judges it, the other reports it already finished`, { skip }, async () => {
    const stores = make();
    try {
      const c = clock();
      const [one, two] = [client(stores.open(), c.now), client(stores.open(), c.now)];
      const [job] = [one, two].map((p) => p.cw.job("webhook-ingest", { failuresBeforeAlert: 2 }));
      await job!.start({ id: "delivery-1" });
      const [h1, h2] = await Promise.all([one.cw.resumeRun("webhook-ingest", "delivery-1"), two.cw.resumeRun("webhook-ingest", "delivery-1")]);
      c.advance(MIN);
      const results = await Promise.all([h1.fail(new Error("upstream 502")), h2.fail(new Error("upstream 502"))]);
      assert.equal(results.filter(Boolean).length, 1, "one finish recorded");
      assert.ok([...one.errors, ...two.errors].some((e) => /already finished as failed; ignored/.test(e)));
      assert.equal((await one.cw.runs("webhook-ingest")).length, 1);
      assert.equal((await one.cw.store.getState("webhook-ingest"))!.consecutiveFailures, 1, "the failure counted once");
      assert.deepEqual([...one.alerts.types(), ...two.alerts.types()], [], "one failure is below failuresBeforeAlert 2");
    } finally {
      await stores.done();
    }
  });

  test(`${label}: two processes recording one finished run from a source: it is judged once`, { skip }, async () => {
    const stores = make();
    try {
      const c = clock();
      const [one, two] = [client(stores.open(), c.now), client(stores.open(), c.now)];
      for (const p of [one, two]) p.cw.job("db:rollup", { failuresBeforeAlert: 2 });
      const t = T0 - MIN;
      await one.cw.recordRun({ ...failedRun("pgcron:9", "db:rollup", t), status: "running", finishedAt: null, durationMs: null, error: null });
      await two.cw.jobs();
      const done = failedRun("pgcron:9", "db:rollup", t);
      await Promise.all([one.cw.recordRun(done), two.cw.recordRun(done)]);
      assert.equal((await one.cw.store.getState("db:rollup"))!.consecutiveFailures, 1);
      assert.deepEqual([...one.alerts.types(), ...two.alerts.types()], []);
      assert.ok([...one.errors, ...two.errors].some((e) => /pgcron:9 of db:rollup was already finished as failed; ignored/.test(e)));
    } finally {
      await stores.done();
    }
  });

  test(`${label}: many processes starting and finishing one id: exactly one finish is recorded`, { skip }, async () => {
    const stores = make();
    try {
      const c = clock();
      const clients = Array.from({ length: 6 }, () => client(stores.open(), c.now));
      const jobs = clients.map((p) => p.cw.job("ingest"));
      await clients[0]!.cw.check();
      for (let k = 0; k < 5; k++) {
        const id = `evt_${k}`;
        const handles = await Promise.all(jobs.map((j) => j.start({ id })));
        const finished = await Promise.all(handles.map((h, i) => h.finish(`worker ${i}`)));
        assert.equal(finished.filter(Boolean).length, 1, `${id}: one finish recorded`);
      }
      const runs = await clients[0]!.cw.runs("ingest", 500);
      assert.equal(runs.length, 5);
      assert.deepEqual([...new Set(runs.map((r) => r.status))], ["ok"]);
      const unexpected = clients.flatMap((p) => p.errors).filter((e) => !/already finished/.test(e));
      assert.deepEqual(unexpected, []);
    } finally {
      await stores.done();
    }
  });
}

test("a store without updateRunIf falls back to a read and a write", async () => {
  const inner = memory();
  const store = new Proxy(inner, { get: (t, p, r) => (p === "updateRunIf" ? undefined : Reflect.get(t, p, r)) });
  const { cw, errors } = client(store, clock().now);
  const job = cw.job("plain");
  const h = await job.start({ id: "p1" });
  assert.equal((await h.finish("done"))!.status, "ok");
  const again = await (await job.resume("p1")).finish("again");
  assert.equal(again, null);
  assert.ok(errors.some((e) => /already finished/.test(e)));
});

test("recordRun: a run a check marked timeout takes its late finish, as a handle's would", async () => {
  const c = clock(Date.UTC(2026, 0, 1, 3, 0));
  const { cw, alerts } = client(memory(), c.now);
  cw.job("db:vacuum", { schedule: "0 3 * * *", timeout: "30m" });
  const base = { id: "pgcron:77", job: "db:vacuum", startedAt: c.now(), error: null, output: null, metrics: {}, trigger: "pg_cron" };
  await cw.recordRun({ ...base, status: "running", finishedAt: null, durationMs: null });
  c.advance(45 * MIN);
  await cw.check();
  assert.equal((await cw.getRun("pgcron:77"))!.status, "timeout");
  c.advance(15 * MIN);
  await cw.recordRun({ ...base, status: "ok", finishedAt: c.now() - 5 * MIN, durationMs: 55 * MIN, output: "VACUUM" });
  await cw.check();
  const run = (await cw.getRun("pgcron:77"))!;
  assert.equal(run.status, "ok");
  assert.equal(run.output, "VACUUM");
  assert.equal((await cw.jobSummary("db:vacuum"))!.health, "healthy");
  assert.deepEqual(alerts.types(), ["stuck", "recovered"]);

  // A late failure is written but not counted twice.
  const other = { ...base, id: "pgcron:78", startedAt: c.now() };
  await cw.recordRun({ ...other, status: "running", finishedAt: null, durationMs: null });
  c.advance(45 * MIN);
  await cw.check();
  await cw.recordRun({ ...other, status: "failed", finishedAt: c.now(), durationMs: 45 * MIN, error: "ERROR: canceled" });
  assert.equal((await cw.getRun("pgcron:78"))!.status, "failed");
  assert.equal((await cw.store.getState("db:vacuum"))!.consecutiveFailures, 1);
  assert.deepEqual(alerts.types(), ["stuck", "recovered", "stuck"]);
});

test("recordRun leaves a stored run of another job alone, and reports it", async () => {
  const { cw, alerts, errors } = client(memory(), clock().now);
  const a = cw.job("webhook-job");
  cw.job("db:nightly");
  const h = await a.start({ id: "run-43" });
  const now = T0;
  const sent = await cw.recordRun({ id: "run-43", job: "db:nightly", status: "ok", startedAt: now - 1000, finishedAt: now, durationMs: 1000, error: null, output: null, metrics: {}, trigger: "pg_cron" });
  assert.deepEqual(sent, []);
  const stored = (await cw.getRun("run-43"))!;
  assert.equal(stored.job, "webhook-job");
  assert.equal(stored.status, "running");
  assert.ok(errors.some((e) => /run-43 of db:nightly belongs to job "webhook-job"; ignored/.test(e)));
  assert.equal((await h.finish())!.status, "ok");
  assert.deepEqual(alerts.types(), []);
});

test("start and resume refuse ids in the pg_cron source's pgcron: namespace", async () => {
  const { cw } = client(memory(), clock().now);
  const job = cw.job("webhook-job");
  await assert.rejects(job.start({ id: "pgcron:42" }), /cannot take a run id starting with "pgcron:"/);
  await assert.rejects(job.resume("pgcron:42"), /cannot take a run id starting with "pgcron:"/);
  await assert.rejects(cw.resumeRun("webhook-job", "pgcron:db:42"), /pgcron:/);
  assert.equal((await job.start({ id: "pgcron-42" })).active, true, "only the prefix with its colon is reserved");
});

test("start with an id another job holds fails the same whether its start is in flight or done", async () => {
  const { cw } = client(memory(), clock().now);
  const a = cw.job("import-a");
  const b = cw.job("import-b");
  const [ra, rb] = await Promise.allSettled([a.start({ id: "evt_123" }), b.start({ id: "evt_123" })]);
  assert.equal(ra.status, "fulfilled");
  assert.equal(rb.status, "rejected");
  assert.match(((rb as PromiseRejectedResult).reason as Error).message, /belongs to job "import-a", not "import-b"/);
  await assert.rejects(b.start({ id: "evt_123" }), /belongs to job "import-a", not "import-b"/);
  // The same job at once still shares one start.
  const [x, y] = await Promise.all([a.start({ id: "evt_9" }), a.start({ id: "evt_9" })]);
  assert.equal(x, y);
  assert.equal((await cw.getRun("evt_123"))!.job, "import-a");
});

test("a handle resumed while the store failed cannot finish or flush another job's run", async () => {
  const inner = memory();
  let fail = false;
  const store: Store = { ...inner, getRun: async (id: string) => { if (fail) { fail = false; throw new Error("blip"); } return inner.getRun(id); } };
  const { cw, errors } = client(store, clock().now);
  const billing = cw.job("billing");
  const webhook = cw.job("webhook");
  await billing.start({ id: "run-7" });
  fail = true;
  const h = await webhook.resume("run-7");
  assert.equal(h.active, true, "unknown yet: the read failed");
  h.log("attacker line");
  await h.flush();
  assert.ok(errors.some((e) => /run-7 of webhook belongs to job "billing"; ignored/.test(e)));
  assert.equal(await h.finish("ok"), null);
  const stored = (await inner.getRun("run-7"))!;
  assert.deepEqual([stored.job, stored.status, stored.output], ["billing", "running", null]);
});

test("expect at finish sees an early line even after flushes, as run() would", async () => {
  const { cw } = client(memory(), clock().now);
  const job = cw.job("export", { expect: "connected to warehouse" });
  await job.run(async (ctx) => { ctx.log("connected to warehouse"); for (let i = 0; i < 400; i++) ctx.log(`row batch ${i} `.padEnd(60, ".")); });
  assert.equal((await cw.runs("export"))[0]!.status, "ok");
  const h = await job.start();
  h.log("connected to warehouse");
  for (let i = 0; i < 400; i++) {
    h.log(`row batch ${i} `.padEnd(60, "."));
    if (i % 100 === 99) await h.flush();
  }
  const run = (await h.finish())!;
  assert.equal(run.status, "ok", run.error ?? "");
  assert.ok(!run.output!.includes("connected to warehouse"), "the stored output kept only the tail");
});

test("a flush never undoes a finish written while it read", async () => {
  const inner = memory();
  let finishFirst: (() => Promise<void>) | null = null;
  const store: Store = {
    ...inner,
    getRun: async (id: string) => {
      const run = await inner.getRun(id);
      if (finishFirst) {
        const f = finishFirst;
        finishFirst = null;
        await f();
      }
      return run;
    },
  };
  const { cw } = client(store, clock().now);
  const job = cw.job("sync");
  const h = await job.start({ id: "s1" });
  h.log("halfway");
  const other = await job.resume("s1");
  finishFirst = async () => { await other.finish("done elsewhere"); };
  await h.flush();
  const stored = (await inner.getRun("s1"))!;
  assert.equal(stored.status, "ok", "still finished");
  assert.equal(stored.output, "done elsewhere");
});

test("a run finished while a check marks it timeout is judged once", async () => {
  const c = clock();
  const inner = memory();
  let race: (() => Promise<void>) | null = null;
  const store: Store = {
    ...inner,
    runningRuns: async () => {
      const runs = await inner.runningRuns();
      if (race) { const r = race; race = null; await r(); }
      return runs;
    },
  };
  const { cw, alerts } = client(store, c.now);
  const job = cw.job("long", { timeout: "5m" });
  const h = await job.start();
  c.advance(10 * MIN);
  race = async () => { await h.finish("finally"); };
  await cw.check();
  assert.equal((await cw.getRun(h.id))!.status, "ok");
  assert.deepEqual(alerts.types(), [], "not marked stuck over a finish");
  c.advance(HOUR);
});

// Keeps the CronWatch type import used when only some tests run.
export type { CronWatch };
