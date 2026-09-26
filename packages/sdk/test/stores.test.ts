import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";
import { memory } from "../src/stores/memory.js";
import { sqlite } from "../src/stores/sqlite.js";
import type { Run, Store } from "../src/types.js";

function run(id: string, job: string, status: Run["status"], startedAt: number): Run {
  return { id, job, status, startedAt, finishedAt: status === "running" ? null : startedAt + 10, durationMs: status === "running" ? null : 10, error: null, output: null, metrics: { n: 1 }, trigger: "run" };
}

async function conformance(name: string, make: () => Store) {
  await test(`${name}: store conformance`, async () => {
    const store = make();
    await store.init?.();
    assert.equal(await store.getJob("a"), null);
    await store.upsertJob({ name: "a", schedule: "every 5m" }, 100);
    await store.upsertJob({ name: "a", schedule: "every 10m", tags: ["x"] }, 200);
    await store.upsertJob({ name: "b" }, 300);
    const a = (await store.getJob("a"))!;
    assert.equal(a.createdAt, 100, "createdAt survives upsert");
    assert.equal(a.updatedAt, 200);
    assert.deepEqual(a.definition, { name: "a", schedule: "every 10m", tags: ["x"] });
    assert.deepEqual((await store.listJobs()).map((j) => j.name), ["a", "b"]);

    await store.insertRun(run("r1", "a", "ok", 1000));
    await store.insertRun(run("r2", "a", "failed", 2000));
    await store.insertRun(run("r3", "a", "running", 3000));
    await store.insertRun(run("r4", "b", "ok", 1500));
    assert.deepEqual((await store.listRuns("a", 10)).map((r) => r.id), ["r3", "r2", "r1"]);
    assert.deepEqual((await store.listRuns("a", 2)).map((r) => r.id), ["r3", "r2"]);
    assert.equal((await store.lastRun("a"))!.id, "r3");
    assert.equal(await store.lastRun("none"), null);
    assert.deepEqual((await store.runningRuns()).map((r) => r.id), ["r3"]);
    const r1 = (await store.getRun("r1"))!;
    assert.deepEqual(r1.metrics, { n: 1 });
    assert.equal(r1.durationMs, 10);

    const updated = { ...run("r3", "a", "ok", 3000), output: "line1\nline2", error: null, metrics: { cost: 0.25 } };
    await store.updateRun(updated);
    const r3 = (await store.getRun("r3"))!;
    assert.equal(r3.status, "ok");
    assert.equal(r3.output, "line1\nline2");
    assert.deepEqual(r3.metrics, { cost: 0.25 });
    assert.deepEqual(await store.runningRuns(), []);

    assert.equal(await store.getState("a"), null);
    await store.setState({ job: "a", open: { failed: 5 }, consecutiveFailures: 2, silencedUntil: null, lastAlertAt: 6 });
    await store.setState({ job: "a", open: {}, consecutiveFailures: 0, silencedUntil: 99, lastAlertAt: 6 });
    assert.deepEqual(await store.getState("a"), { job: "a", open: {}, consecutiveFailures: 0, silencedUntil: 99, lastAlertAt: 6 });

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
  rmSync(dir, { recursive: true, force: true });
});

if (process.env.CRONWATCH_TEST_PG) {
  const { postgres } = await import("../src/stores/postgres.js");
  await conformance("postgres", () => postgres({ connectionString: process.env.CRONWATCH_TEST_PG, prefix: `t${Date.now()}_` }));
}
