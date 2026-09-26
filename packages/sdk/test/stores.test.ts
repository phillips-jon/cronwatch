import assert from "node:assert/strict";
import { mkdtempSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";
import Database from "better-sqlite3";
import pg from "pg";
import { memory } from "../src/stores/memory.js";
import { postgres } from "../src/stores/postgres.js";
import { sqlite } from "../src/stores/sqlite.js";
import type { Alert, JobState, Run, Store } from "../src/types.js";

const PG = process.env.CRONWATCH_TEST_PG;
const NO_PG = PG ? false : "set CRONWATCH_TEST_PG to a Postgres URL to run";

function run(id: string, job: string, status: Run["status"], startedAt: number): Run {
  return { id, job, status, startedAt, finishedAt: status === "running" ? null : startedAt + 10, durationMs: status === "running" ? null : 10, error: null, output: null, metrics: { n: 1 }, trigger: "run" };
}

async function conformance(name: string, make: () => Store, skip: string | false = false) {
  await test(`${name}: store conformance`, { skip }, async () => {
    const store = make();
    await store.init?.();
    assert.equal(await store.getJob("a"), null);
    await store.upsertJob({ name: "a", schedule: "every 5m" }, 100);
    await store.upsertJob({ name: "a", schedule: "every 10m", tags: ["x"] }, 200);
    await store.upsertJob({ name: "b" }, 300);
    await store.upsertJob({ name: "B" }, 300);
    await store.upsertJob({ name: "_c" }, 300);
    const a = (await store.getJob("a"))!;
    assert.equal(a.createdAt, 100, "createdAt survives upsert");
    assert.equal(a.updatedAt, 200);
    assert.deepEqual(a.definition, { name: "a", schedule: "every 10m", tags: ["x"] });
    assert.deepEqual((await store.listJobs()).map((j) => j.name), ["B", "_c", "a", "b"], "code unit order, not locale");

    await store.insertRun(run("r1", "a", "ok", 1000));
    await store.insertRun(run("r2", "a", "failed", 2000));
    await store.insertRun(run("r3", "a", "running", 3000));
    await store.insertRun(run("r4", "b", "ok", 1500));
    await store.insertRun(run("rb", "B", "running", 2000));
    await store.insertRun(run("rc", "_c", "running", 2000));
    assert.deepEqual((await store.listRuns("a", 10)).map((r) => r.id), ["r3", "r2", "r1"]);
    assert.deepEqual((await store.listRuns("a", 2)).map((r) => r.id), ["r3", "r2"]);
    assert.equal((await store.lastRun("a"))!.id, "r3");
    assert.equal(await store.lastRun("none"), null);
    assert.deepEqual((await store.runningRuns()).map((r) => r.id), ["rb", "rc", "r3"], "oldest first, then insertion order");
    const r1 = (await store.getRun("r1"))!;
    assert.deepEqual(r1.metrics, { n: 1 });
    assert.equal(r1.durationMs, 10);

    const updated = { ...run("r3", "a", "ok", 3000), output: "line1\nline2", error: null, metrics: { cost: 0.25 } };
    await store.updateRun(updated);
    const r3 = (await store.getRun("r3"))!;
    assert.equal(r3.status, "ok");
    assert.equal(r3.output, "line1\nline2");
    assert.deepEqual(r3.metrics, { cost: 0.25 });
    assert.deepEqual((await store.runningRuns()).map((r) => r.id), ["rb", "rc"]);

    // Forgetting a job while one of its runs is in flight: the run finishing later changes nothing.
    await store.deleteJob("B");
    await store.updateRun({ ...run("rb", "B", "ok", 2000), output: "late" });
    assert.equal(await store.getRun("rb"), null);
    assert.deepEqual(await store.listRuns("B", 10), []);
    assert.deepEqual((await store.runningRuns()).map((r) => r.id), ["rc"]);
    await store.deleteJob("_c");

    assert.equal(await store.getState("a"), null);
    await store.setState({ job: "a", open: { failed: 5 }, consecutiveFailures: 2, silencedUntil: null, lastAlertAt: 6 });
    await store.setState({ job: "a", open: {}, consecutiveFailures: 0, silencedUntil: 99, lastAlertAt: 6 });
    assert.deepEqual(await store.getState("a"), { job: "a", open: {}, consecutiveFailures: 0, silencedUntil: 99, lastAlertAt: 6 });
    const undelivered = { type: "failed", job: "a", title: "a failed", message: "boom", at: 7, details: { consecutiveFailures: 1 } } as unknown as Alert;
    const full = { job: "a", open: { stuck: 7 }, consecutiveFailures: 1, silencedUntil: null, lastAlertAt: 6, pendingRecovery: ["missed"], undelivered: [undelivered] } as JobState;
    await store.setState(full);
    assert.deepEqual(await store.getState("a"), full, "pendingRecovery and undelivered round-trip");
    await store.setState({ job: "a", open: {}, consecutiveFailures: 0, silencedUntil: 99, lastAlertAt: 6 });

    await store.insertRun(run("r5", "a", "running", 500));
    assert.equal(await store.prune(2500), 3, "r1, r2 and b's r4 pruned; running r5 kept");
    assert.deepEqual((await store.listRuns("a", 10)).map((r) => r.id), ["r3", "r5"]);
    assert.deepEqual(await store.listRuns("b", 10), []);

    await store.deleteJob("a");
    assert.equal(await store.getJob("a"), null);
    assert.deepEqual(await store.listRuns("a", 10), []);
    assert.equal(await store.getState("a"), null);
    assert.equal((await store.getJob("b"))!.name, "b");
    await store.close?.();
  });
}

await conformance("memory", () => memory());
await conformance("sqlite in memory", () => sqlite({ path: ":memory:" }));

const dir = mkdtempSync(path.join(tmpdir(), "cronwatch-"));
await conformance("sqlite on disk", () => sqlite({ path: path.join(dir, "nested", "cw.db") }));
await test("sqlite: the file persists between opens", async () => {
  const file = path.join(dir, "persist.db");
  const a = sqlite({ path: file });
  await a.init!();
  await a.upsertJob({ name: "keep" }, 1);
  await a.close!();
  const b = sqlite({ path: file });
  await b.init!();
  assert.equal((await b.getJob("keep"))!.createdAt, 1);
  await b.close!();
});

await test("sqlite: the database file and its -wal and -shm files are private", { skip: process.platform === "win32" && "no POSIX modes" }, async () => {
  const file = path.join(dir, "private.db");
  const store = sqlite({ path: file });
  await store.init!();
  await store.insertRun(run("r1", "a", "running", 1));
  for (const f of [file, `${file}-wal`, `${file}-shm`]) {
    assert.equal(statSync(f).mode & 0o777, 0o600, f);
  }
  await store.close!();
});

await test("sqlite: a prefix keeps two stores apart in one database", async () => {
  const db = new Database(":memory:");
  const one = sqlite({ database: db });
  const two = sqlite({ database: db, prefix: "other_" });
  await one.init!();
  await two.init!();
  await one.upsertJob({ name: "a" }, 1);
  assert.equal(await two.getJob("a"), null);
  const tables = (db.prepare("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name").all() as { name: string }[]).map((t) => t.name);
  assert.deepEqual(tables, ["cronwatch_jobs", "cronwatch_runs", "cronwatch_state", "other_jobs", "other_runs", "other_state"]);
  db.close();
  rmSync(dir, { recursive: true, force: true });
});

await test("a prefix that is not a plain lowercase identifier is refused", () => {
  for (const prefix of ["1cw_", "cw-", "Cw_", "cw_;drop", "", "x".repeat(48)]) {
    assert.throws(() => sqlite({ path: ":memory:", prefix }), /invalid table prefix/, prefix);
    assert.throws(() => postgres({ connectionString: "postgres://unused", prefix }), /invalid table prefix/, prefix);
  }
  assert.doesNotThrow(() => sqlite({ path: ":memory:", prefix: "_cw2_" }));
});

// Each Postgres test gets its own tables and drops them afterwards.
const pgPrefix = () => `t${Date.now()}_${Math.floor(Math.random() * 1e6)}_`;
async function drop(prefix: string) {
  const pool = new pg.Pool({ connectionString: PG });
  await pool.query(`DROP TABLE IF EXISTS ${prefix}jobs, ${prefix}runs, ${prefix}state`);
  await pool.end();
}

const conformancePrefix = pgPrefix();
await conformance("postgres", () => postgres({ connectionString: PG, prefix: conformancePrefix }), NO_PG);
if (PG) await drop(conformancePrefix);

await test("postgres: many instances can init at once", { skip: NO_PG }, async () => {
  const prefix = pgPrefix();
  const stores = Array.from({ length: 8 }, () => postgres({ connectionString: PG, prefix }));
  try {
    await Promise.all(stores.map((s) => s.init!()));
    await stores[0]!.upsertJob({ name: "a" }, 1);
    assert.equal((await stores[7]!.getJob("a"))!.createdAt, 1);
  } finally {
    await Promise.all(stores.map((s) => s.close!()));
    await drop(prefix);
  }
});
