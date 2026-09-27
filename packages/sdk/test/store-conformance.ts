import assert from "node:assert/strict";
import { test } from "node:test";
import type { Alert, JobState, Run, Store } from "../src/types.js";

/**
 * The test every store passes: memory, SQLite and Postgres in stores.test.ts,
 * D1 in workers.test.ts. Copy it to check a store of your own.
 */
export function run(id: string, job: string, status: Run["status"], startedAt: number): Run {
  return { id, job, status, startedAt, finishedAt: status === "running" ? null : startedAt + 10, durationMs: status === "running" ? null : 10, error: null, output: null, metrics: { n: 1 }, trigger: "run" };
}

export async function conformance(name: string, make: () => Store, skip: string | false = false) {
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

    // compareAndSetState: writes only over the version it was told to expect.
    const cas = store.compareAndSetState!.bind(store);
    const v = (version: number, extra: Partial<JobState> = {}): JobState => ({ job: "v", open: {}, consecutiveFailures: 0, silencedUntil: null, lastAlertAt: null, version, ...extra });
    assert.equal(await cas(v(2), 1), false, "no row matches only version 0");
    assert.equal(await store.getState("v"), null);
    assert.equal(await cas(v(1), 0), true, "no row counts as version 0");
    assert.equal(await cas(v(1, { consecutiveFailures: 9 }), 0), false, "a write from a stale read is refused");
    assert.equal(await cas(v(2, { consecutiveFailures: 1 }), 1), true);
    assert.equal(await cas(v(3), 1), false);
    assert.deepEqual(await store.getState("v"), v(2, { consecutiveFailures: 1 }));
    await store.setState({ job: "w", open: {}, consecutiveFailures: 3, silencedUntil: null, lastAlertAt: null });
    assert.equal(await cas({ ...v(1), job: "w" }, 1), false, "state written before versions counts as 0");
    assert.equal(await cas({ ...v(1), job: "w" }, 0), true);
    assert.equal((await store.getState("w"))!.version, 1);
    await store.deleteJob("v");
    assert.equal(await cas(v(3), 2), false, "a forgotten job's state is not written back");
    assert.equal(await store.getState("v"), null);
    await store.deleteJob("w");

    await store.insertRun(run("r5", "a", "running", 500));
    assert.equal(await store.prune(2500), 2, "r1 and r2 pruned; running r5 kept, and b's r4 kept as b's newest run");
    assert.deepEqual((await store.listRuns("a", 10)).map((r) => r.id), ["r3", "r5"]);
    assert.deepEqual((await store.listRuns("b", 10)).map((r) => r.id), ["r4"]);
    assert.equal(await store.prune(1_000_000), 0, "however old, each job keeps its newest run, and running runs stay");

    await store.deleteJob("a");
    assert.equal(await store.getJob("a"), null);
    assert.deepEqual(await store.listRuns("a", 10), []);
    assert.equal(await store.getState("a"), null);
    assert.equal((await store.getJob("b"))!.name, "b");
    await store.close?.();
  });
}
