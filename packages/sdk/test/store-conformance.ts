import assert from "node:assert/strict";
import { test } from "node:test";
import { readFileSync } from "node:fs";
import type { Alert, JobState, Run, Store, StoredJobDefinition } from "../src/types.js";

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

    // updateRunIf: writes only over a row whose status is one of those given, and says whether it did.
    await assert.rejects(store.insertRun(run("r3", "a", "running", 3000)), Error, "an id already recorded is refused");
    await store.upsertJob({ name: "q" }, 300);
    await store.insertRun(run("rx", "q", "running", 2500));
    const once = store.updateRunIf!.bind(store);
    assert.equal(await once({ ...run("rx", "q", "failed", 2500), error: "first" }, ["running"]), true);
    assert.equal(await once({ ...run("rx", "q", "ok", 2500), output: "second" }, ["running"]), false, "a second finish over the first is refused");
    assert.equal((await store.getRun("rx"))!.error, "first");
    assert.equal(await once({ ...run("rx", "q", "ok", 2500), output: "late" }, ["running", "timeout"]), false);
    await store.updateRun({ ...run("rx", "q", "timeout", 2500), error: "stuck" });
    assert.equal(await once({ ...run("rx", "q", "ok", 2500), output: "late", metrics: { m: 2 } }, ["running", "timeout"]), true, "any of the statuses given");
    const late = (await store.getRun("rx"))!;
    assert.deepEqual([late.status, late.output, late.error, late.metrics, late.job, late.trigger], ["ok", "late", null, { m: 2 }, "q", "run"]);
    assert.equal(await once(run("missing", "q", "ok", 1), ["running"]), false, "a run that is not there is not written");
    assert.equal(await store.getRun("missing"), null);
    assert.equal(await once(run("rx", "q", "failed", 2500), []), false, "no statuses, no write");
    assert.equal((await store.getRun("rx"))!.status, "ok");
    await store.deleteJob("q");

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
    await store.deleteJob("b");

    // Text is written without U+0000 (conformance/store.json, nul).
    for (const [i, step] of NUL_STEPS.entries()) {
      const what = `nul step ${i}`;
      if (step.upsertJob) {
        await store.upsertJob(step.upsertJob, step.now!);
        assert.deepEqual(await store.getJob("nul"), step.stored, what);
      } else if (step.insertRun || step.updateRun) {
        if (step.insertRun) await store.insertRun(step.insertRun);
        else await store.updateRun(step.updateRun!);
        assert.deepEqual(await store.getRun("n1"), step.stored, what);
      } else if (step.updateRunIf) {
        assert.equal(await store.updateRunIf!(step.updateRunIf, step.from!), step.written, what);
        assert.deepEqual(await store.getRun("n1"), step.stored, what);
      } else if (step.setState) {
        await store.setState(step.setState);
        assert.deepEqual(await store.getState("nul"), step.stored, what);
      } else {
        assert.equal(await store.compareAndSetState!(step.compareAndSetState!, step.expected!), step.written, what);
        assert.deepEqual(await store.getState("nul"), step.stored, what);
      }
    }
    await store.deleteJob("nul");
    await store.close?.();
  });
}

interface NulStep {
  upsertJob?: StoredJobDefinition; now?: number; insertRun?: Run; updateRun?: Run; updateRunIf?: Run; from?: Run["status"][];
  setState?: JobState; compareAndSetState?: JobState; expected?: number; written?: boolean; stored: unknown;
}
const NUL_STEPS = (JSON.parse(readFileSync(new URL("../../../conformance/store.json", import.meta.url), "utf8")) as { nul: NulStep[] }).nul;
