// conformance/client.json unknownFields, replayed over each store: what a
// newer release wrote (a definition or state key, a run status, a trigger,
// an open condition this release does not know) survives a check, a
// silence, an unsilence and a run, and the alerts carry the definition as
// stored. Postgres runs when CRONWATCH_TEST_PG is set.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import pg from "pg";
import { cronwatch, custom } from "../src/index.js";
import { memory } from "../src/stores/memory.js";
import { postgres } from "../src/stores/postgres.js";
import { sqlite } from "../src/stores/sqlite.js";
import type { Alert, JobState, Run, Store, StoredJob, StoredJobDefinition } from "../src/types.js";

interface Snapshot { job: StoredJob; state: JobState; runs: Run[]; alerts: Alert[]; errors: string[] }
interface Step { op: string; at: number; for?: string; summary?: unknown; declared?: Record<string, unknown>; id?: string; startedAt?: number; finishedAt?: number; output?: string; expect: Snapshot }
interface Fixture { seed: { definition: StoredJobDefinition; createdAt: number; state: JobState; runs: Run[] }; steps: Step[] }

const file = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "..", "..", "conformance", "client.json");
const fixture = (JSON.parse(readFileSync(file, "utf8")) as { unknownFields: Fixture }).unknownFields;
const clone = <T>(v: T): T => JSON.parse(JSON.stringify(v)) as T;

async function replay(store: Store) {
  let now = 0;
  const sent: Alert[] = [];
  const errors: string[] = [];
  await store.init?.();
  await store.upsertJob(clone(fixture.seed.definition), fixture.seed.createdAt);
  for (const run of fixture.seed.runs) await store.insertRun(clone(run));
  await store.setState(clone(fixture.seed.state));
  const cw = cronwatch({
    store, now: () => now, cronSecret: null,
    alerts: [custom("capture", (alert) => void sent.push(clone(alert)))],
    onError: (error, where) => void errors.push(`${where}: ${(error as Error).message}`),
  });
  for (const step of fixture.steps) {
    now = step.at;
    if (step.op === "check") await cw.check();
    else if (step.op === "silence") await cw.silence("keep", step.for!);
    else if (step.op === "unsilence") await cw.unsilence("keep");
    else if (step.op === "summary") assert.deepEqual(clone(await cw.jobSummary("keep")), step.summary, "summary");
    else if (step.op === "declareAndRun") {
      now = step.startedAt!;
      const handle = await cw.job("keep", step.declared).start({ id: step.id! });
      now = step.finishedAt!;
      await handle.finish(step.output!);
    } else throw new Error(`unknown step ${step.op}`);
    const got: Snapshot = {
      job: clone((await store.getJob("keep"))!),
      state: clone((await store.getState("keep"))!),
      runs: clone(await store.listRuns("keep", 10)),
      alerts: sent.splice(0),
      errors: errors.splice(0),
    };
    assert.deepEqual(got, step.expect, step.op);
  }
  await cw.close();
}

test("unknown fields: memory", () => replay(memory()));
test("unknown fields: sqlite", () => replay(sqlite({ path: ":memory:" })));

const PG = process.env.CRONWATCH_TEST_PG;
test("unknown fields: postgres", { skip: PG ? false : "set CRONWATCH_TEST_PG to a Postgres URL to run" }, async () => {
  const prefix = `t${Date.now()}_${Math.floor(Math.random() * 1e6)}_`;
  try {
    await replay(postgres({ connectionString: PG, prefix }));
  } finally {
    const pool = new pg.Pool({ connectionString: PG });
    await pool.query(`DROP TABLE IF EXISTS ${prefix}jobs, ${prefix}runs, ${prefix}state`);
    await pool.end();
  }
});
