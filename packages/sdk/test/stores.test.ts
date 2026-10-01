import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import Database from "better-sqlite3";
import pg from "pg";
import { cronwatch, custom } from "../src/index.js";
import { retryBusy } from "../src/stores/busy.js";
import { memory } from "../src/stores/memory.js";
import { postgres } from "../src/stores/postgres.js";
import { sqlite } from "../src/stores/sqlite.js";
import type { Alert, JobState, Store } from "../src/types.js";
import { normalizeState } from "../src/evaluate.js";
import { readStoredJob } from "../src/serialize.js";
import { conformance, run } from "./store-conformance.js";

const PG = process.env.CRONWATCH_TEST_PG;
const NO_PG = PG ? false : "set CRONWATCH_TEST_PG to a Postgres URL to run";

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

await test("sqlite: opening retries a busy database, and keeps nothing from a failed open", async () => {
  const file = path.join(dir, "busy.db");
  const holder = new Database(file);
  holder.exec("CREATE TABLE t (x)");
  holder.exec("BEGIN EXCLUSIVE");
  const store = sqlite({ path: file });
  const started = Date.now();
  await assert.rejects(store.init!(), (e: { code?: string }) => e.code === "SQLITE_BUSY");
  assert.ok(Date.now() - started >= 1_500, "it kept trying for a while first");
  holder.exec("COMMIT");
  holder.close();
  // The next use opens afresh, and gets WAL and the busy timeout this time.
  await store.init!();
  await store.upsertJob({ name: "after" }, 1);
  const check = new Database(file);
  assert.equal(check.pragma("journal_mode", { simple: true }), "wal");
  check.close();
  await store.close!();
});

await test("retryBusy retries only SQLITE_BUSY and SQLITE_LOCKED, within its budget", () => {
  const pauses: number[] = [];
  const sleep = (ms: number) => { pauses.push(ms); };
  let calls = 0;
  const busy = Object.assign(new Error("database is locked"), { code: "SQLITE_BUSY" });
  assert.equal(retryBusy(() => { if (++calls < 4) throw busy; return "ok"; }, 2_000, sleep), "ok");
  assert.deepEqual(pauses, [10, 20, 40]);
  pauses.length = 0;
  assert.throws(() => retryBusy(() => { throw Object.assign(new Error("x"), { code: "SQLITE_LOCKED_SHAREDCACHE" }); }, 100, sleep), /x/);
  assert.equal(pauses.reduce((a, b) => a + b, 0), 100, "gave up once the budget was spent");
  pauses.length = 0;
  assert.throws(() => retryBusy(() => { throw Object.assign(new Error("corrupt"), { code: "SQLITE_CORRUPT" }); }, 2_000, sleep), /corrupt/);
  assert.deepEqual(pauses, [], "anything else is thrown at once");
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

// Rows another process wrote: a state whose version is 1.5 or "x", and a
// running run that started at the lowest BIGINT. Neither may make a
// statement fail, or refuse every write of the job for good.
interface ForeignVersion { stored: string; counts: number; steps: { cas: JobState; expected: number; written: boolean; state?: JobState }[] }
const storeFixture = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "..", "..", "conformance", "store.json");
const foreignVersions = (JSON.parse(readFileSync(storeFixture, "utf8")) as { foreignVersion: ForeignVersion[] }).foreignVersion;

async function replayForeignVersions(store: Store, writeRaw: (text: string) => Promise<void>) {
  await store.init!();
  for (const c of foreignVersions) {
    await store.deleteJob("v");
    await writeRaw(c.stored);
    for (const step of c.steps) {
      assert.equal(await store.compareAndSetState!(step.cas, step.expected), step.written, `${c.stored} expecting ${step.expected}`);
      if (step.state) assert.deepEqual(await store.getState("v"), step.state, c.stored);
    }
  }
}

// The stuck alert is sent: its text writes a start before the year 1 as
// words, not as a date.
async function checkOverForeignRows(store: Store, exec: (sql: string) => Promise<void>, p = "cronwatch_") {
  const sent: Alert[] = [];
  const cw = cronwatch({ store, alerts: [custom("capture", (alert) => void sent.push(alert))], cronSecret: null, onError: (e) => { throw e; } });
  await store.init!();
  await store.upsertJob({ name: "far", timeout: "5m" }, 1);
  await exec(`INSERT INTO ${p}runs (id, job, status, started_at, metrics, trigger) VALUES ('far1', 'far', 'running', -9223372036854775808, '{}', 'run')`);
  await exec(`INSERT INTO ${p}state (job, state) VALUES ('far', '{"job":"far","open":{},"consecutiveFailures":0,"silencedUntil":null,"lastAlertAt":null,"version":1.5}')`);
  for (let i = 0; i < 2; i++) await cw.check();
  const run = (await store.getRun("far1"))!;
  assert.equal(run.status, "timeout");
  assert.equal(run.durationMs, Number.MAX_SAFE_INTEGER, "the duration is held at 2^53 - 1");
  const state = (await store.getState("far"))!;
  assert.equal(state.version, 2, "the state's 1.5 counted as 0, then the timeout and the alert each wrote it");
  assert.equal(state.consecutiveFailures, 1);
  assert.deepEqual(sent.map((a) => a.type), ["stuck"]);
  assert.equal(sent[0]!.message.split("\n")[0], "Started before 0001-01-01 00:00:00 UTC and never reported finishing. Marked as timed out after 104249991d 8h.");
}

// A cron job's last run as a foreign or damaged row could hold it: before
// the year 1 (the first fire of the year 1 was missed) or after 9999 (never
// due again), and past JavaScript's Date range. Neither a check nor the
// dashboard reports an error.
const FAR_STARTS = ["-62135596800001", "253402300800000", "-9223372036854775808", "9223372036854775807"];
async function cronOverForeignRow(store: Store, exec: (sql: string) => Promise<void>, startedAt: string, p = "cronwatch_") {
  const errors: string[] = [];
  const sent: Alert[] = [];
  const cw = cronwatch({
    store, alerts: [custom("capture", (alert) => void sent.push(alert))], cronSecret: null,
    onError: (e, context) => void errors.push(`${context}: ${(e as Error).message}`),
  });
  await store.init!();
  await store.upsertJob({ name: "far", schedule: "0 2 * * *", timezone: "UTC", grace: "10m" }, 1);
  await exec(`INSERT INTO ${p}runs (id, job, status, started_at, finished_at, duration_ms, metrics, trigger) VALUES ('far1', 'far', 'ok', ${startedAt}, ${startedAt}, 0, '{}', 'run')`);
  await cw.check();
  const routes = cw.routes({ token: "tok" });
  for (const url of ["/cronwatch", "/cronwatch/jobs/far", "/cronwatch/api/jobs/far"]) {
    const res = await routes.GET(new Request(`http://app.test${url}`, { headers: { authorization: "Bearer tok" } }));
    assert.equal(res.status, 200, url);
    await res.text();
  }
  assert.deepEqual(errors, [], startedAt);
  assert.deepEqual(sent.map((a) => a.type), startedAt.startsWith("-") ? ["missed"] : [], startedAt);
  if (sent.length) assert.match(sent[0]!.message, /^Due 0001-01-01 02:00:00 UTC /);
}

for (const startedAt of FAR_STARTS) {
  await test(`sqlite: a check and the dashboard over a cron job whose last run started at ${startedAt}`, async () => {
    const db = new Database(":memory:");
    await cronOverForeignRow(sqlite({ database: db }), async (sql) => void db.exec(sql), startedAt);
    db.close();
  });
}

await test("sqlite: a foreign state's version counts as stateVersion() reads it (store.json foreignVersion)", async () => {
  const db = new Database(":memory:");
  await replayForeignVersions(sqlite({ database: db }), async (text) => void db.prepare("INSERT INTO cronwatch_state (job, state) VALUES ('v', ?)").run(text));
  db.close();
});

await test("sqlite: a check over a run that started at the lowest BIGINT, and a state whose version is 1.5", async () => {
  const db = new Database(":memory:");
  await checkOverForeignRows(sqlite({ database: db }), async (sql) => void db.exec(sql));
  db.close();
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

await test("postgres: output and errors with NUL characters are still recorded", { skip: NO_PG }, async () => {
  const prefix = pgPrefix();
  const cw = cronwatch({ store: postgres({ connectionString: PG, prefix }), alerts: [], cronSecret: null, onError: (e) => { throw e; } });
  try {
    await assert.rejects(cw.run("nul", async (job) => {
      job.log("before\u0000after");
      throw new Error("bad\u0000byte");
    }), /bad/);
    const [run] = await cw.runs("nul");
    assert.equal(run!.status, "failed");
    assert.equal(run!.output, "beforeafter");
    assert.match(run!.error!, /^Error: badbyte/);
    assert.equal((await cw.store.getState("nul"))!.consecutiveFailures, 1, "the state, with its alert, was written too");
    // So are a trigger, metric names and a definition's text.
    const nul2 = cw.job("nul2", { description: "a\u0000b", tags: ["t\u0000"], budget: { "c\u0000": 5 } });
    await nul2.run(async (job) => void job.metric("ro\u0000ws", 2), { trigger: "cr\u0000on" });
    const [second] = await cw.runs("nul2");
    assert.deepEqual([second!.status, second!.trigger, second!.metrics], ["ok", "cron", { rows: 2 }]);
    assert.deepEqual((await cw.store.getJob("nul2"))!.definition, { name: "nul2", description: "ab", tags: ["t"], budget: { c: 5 } });
  } finally {
    await cw.close();
    await drop(prefix);
  }
});

await test("postgres: two stores racing on one job's state", { skip: NO_PG }, async () => {
  const prefix = pgPrefix();
  const one = postgres({ connectionString: PG, prefix });
  const two = postgres({ connectionString: PG, prefix });
  try {
    await one.init!();
    await two.init!();
    const state = (version: number, n: number): JobState => ({ job: "r", open: {}, consecutiveFailures: n, silencedUntil: null, lastAlertAt: null, version });
    const results = await Promise.all([one.compareAndSetState!(state(1, 1), 0), two.compareAndSetState!(state(1, 2), 0)]);
    assert.deepEqual(results.sort(), [false, true], "exactly one insert wins");
    const results2 = await Promise.all([one.compareAndSetState!(state(2, 3), 1), two.compareAndSetState!(state(2, 4), 1)]);
    assert.deepEqual(results2.sort(), [false, true], "exactly one update wins");
    assert.equal((await one.getState("r"))!.version, 2);
  } finally {
    await one.close!();
    await two.close!();
    await drop(prefix);
  }
});

await test("postgres: a foreign state's version counts as stateVersion() reads it (store.json foreignVersion)", { skip: NO_PG }, async () => {
  const prefix = pgPrefix();
  const store = postgres({ connectionString: PG, prefix });
  const pool = new pg.Pool({ connectionString: PG });
  try {
    await replayForeignVersions(store, async (text) => void await pool.query(`INSERT INTO ${prefix}state (job, state) VALUES ('v', $1::jsonb)`, [text]));
  } finally {
    await pool.end();
    await store.close!();
    await drop(prefix);
  }
});

await test("postgres: a check over a run that started at the lowest BIGINT, and a state whose version is 1.5", { skip: NO_PG }, async () => {
  const prefix = pgPrefix();
  const store = postgres({ connectionString: PG, prefix });
  const pool = new pg.Pool({ connectionString: PG });
  try {
    await checkOverForeignRows(store, async (sql) => void await pool.query(sql), prefix);
  } finally {
    await pool.end();
    await store.close!();
    await drop(prefix);
  }
});

for (const startedAt of FAR_STARTS) {
  await test(`postgres: a check and the dashboard over a cron job whose last run started at ${startedAt}`, { skip: NO_PG }, async () => {
    const prefix = pgPrefix();
    const store = postgres({ connectionString: PG, prefix });
    const pool = new pg.Pool({ connectionString: PG });
    try {
      await cronOverForeignRow(store, async (sql) => void await pool.query(sql), startedAt, prefix);
    } finally {
      await pool.end();
      await store.close!();
      await drop(prefix);
    }
  });
}

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

// Rows a foreign, hand-edited or damaged writer could leave (store.json
// foreignRows): each is read leniently, and one affects only its own job.
interface ForeignRows {
  rows: { table: "jobs" | "runs" | "state"; row: Record<string, unknown>; read: unknown; readable?: boolean }[];
  check: {
    now: number; extraJobs: Record<string, unknown>[]; extraRuns: Record<string, unknown>[]; reported: string[];
    alerts: { type: string; job: string; at: number }[]; health: Record<string, string>;
    silence: { job: string; for: string; reported: string[]; state: JobState };
    states: Record<string, unknown>; read: { reported: string[]; pages: { path: string; status: number }[] };
  };
}
const foreignRows = (JSON.parse(readFileSync(storeFixture, "utf8")) as { foreignRows: ForeignRows }).foreignRows;

function insertRow(db: Database.Database, table: string, row: Record<string, unknown>) {
  const keys = Object.keys(row);
  db.prepare(`INSERT INTO cronwatch_${table} (${keys.join(", ")}) VALUES (${keys.map(() => "?").join(", ")})`).run(...keys.map((k) => row[k]));
}

await test("sqlite: each foreign row reads leniently (store.json foreignRows.rows)", async () => {
  for (const c of foreignRows.rows) {
    const db = new Database(":memory:");
    const store = sqlite({ database: db });
    await store.init!();
    insertRow(db, c.table, c.row);
    const label = `${c.table} ${JSON.stringify(c.row)}`;
    if (c.table === "jobs") {
      const { job, readable } = readStoredJob((await store.getJob(c.row.name as string))!);
      assert.deepEqual(job, c.read, label);
      assert.equal(readable, c.readable, label);
      assert.deepEqual((await store.listJobs()).map((j) => readStoredJob(j).job), [c.read], label);
    } else if (c.table === "runs") {
      assert.deepEqual(await store.getRun(c.row.id as string), c.read, label);
      assert.deepEqual(await store.listRuns(c.row.job as string, 10), [c.read], label);
    } else {
      assert.deepEqual(normalizeState(await store.getState(c.row.job as string), c.row.job as string), c.read, label);
    }
    db.close();
  }
});

await test("sqlite: a check, a silence and every page over foreign rows (store.json foreignRows.check)", async () => {
  const c = foreignRows.check;
  const db = new Database(":memory:");
  const store = sqlite({ database: db });
  await store.init!();
  const jobs = [...foreignRows.rows.filter((r) => r.table === "jobs").map((r) => r.row), ...c.extraJobs];
  for (const row of jobs) insertRow(db, "jobs", row);
  for (const row of [...foreignRows.rows.filter((r) => r.table === "runs").map((r) => r.row), ...c.extraRuns]) insertRow(db, "runs", row);
  for (const row of foreignRows.rows.filter((r) => r.table === "state").map((r) => r.row)) insertRow(db, "state", row);
  const names = jobs.map((j) => j.name as string);
  const errors: string[] = [];
  const reported = () => [...new Set(errors.splice(0).map((where) => names.find((n) => where.endsWith(` ${n}`)) ?? where))].sort();
  const sent: Alert[] = [];
  const cw = cronwatch({
    store, now: () => c.now, cronSecret: null,
    alerts: [custom("capture", (alert) => void sent.push(alert))],
    onError: (_e, where) => void errors.push(where),
  });
  const result = await cw.check();
  assert.deepEqual(reported(), c.reported);
  assert.deepEqual(sent.splice(0).map((a) => ({ type: a.type, job: a.job, at: a.at })), c.alerts);
  assert.deepEqual(Object.fromEntries(result.jobs.map((j) => [j.name, j.health])), c.health);
  await cw.silence(c.silence.job, c.silence.for);
  assert.deepEqual(reported(), c.silence.reported);
  assert.deepEqual(await store.getState(c.silence.job), c.silence.state);
  for (const [job, state] of Object.entries(c.states)) assert.deepEqual(await store.getState(job), state, job);
  const routes = cw.routes({ token: "tok" });
  for (const page of c.read.pages) {
    const res = await routes.handler(new Request(`http://app.test${page.path}`, { headers: { authorization: "Bearer tok" } }));
    await res.text();
    assert.equal(res.status, page.status, page.path);
  }
  assert.deepEqual(reported(), c.read.reported);
  await cw.close();
  db.close();
});
