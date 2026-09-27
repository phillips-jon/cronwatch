import assert from "node:assert/strict";
import { setTimeout as sleep } from "node:timers/promises";
import { test } from "node:test";
import pg from "pg";
import { cronwatch } from "../src/index.js";
import { pgCron, pgCronJobName, pgCronSchedule, type PgCronJob, type Queryable } from "../src/sources/pgcron.js";
import { memory } from "../src/stores/memory.js";
import { postgres } from "../src/stores/postgres.js";
import { capture, clock, HOUR, MIN, T0 } from "./helpers.js";

const PGCRON = process.env.CRONWATCH_TEST_PGCRON;
const NO_PGCRON = PGCRON ? false : "set CRONWATCH_TEST_PGCRON to the URL of a Postgres with pg_cron (in cron.database_name) to run";

interface Detail {
  runid: number;
  jobid: number;
  status: string;
  return_message: string | null;
  start_time: Date | null;
  end_time: Date | null;
}

/** cron.job and cron.job_run_details in memory, answering the reader's queries. */
function fakeCron() {
  const jobs: PgCronJob[] = [];
  const details: Detail[] = [];
  let runid = 0;
  const db: Queryable = {
    async query(text: string, values: unknown[] = []) {
      if (text.includes("current_setting")) return { rows: [{ value: values[0] === "cron.timezone" ? "GMT" : "on" }] };
      if (text.includes("FROM cron.job ORDER BY")) return { rows: jobs.map((j) => ({ ...j, jobid: String(j.jobid) })) };
      const out = (rows: Detail[]) => ({ rows: rows.map((d) => ({ ...d, runid: String(d.runid), jobid: String(d.jobid) })) });
      if (text.includes("ORDER BY d.runid DESC")) {
        return out(details.filter((d) => d.jobid === values[0]).sort((a, b) => b.runid - a.runid).slice(0, 20));
      }
      if (text.includes("unnest")) {
        const [ids, afters, open] = values as [number[], number[], number[]];
        const after = new Map(ids.map((id, i) => [id, afters[i]!]));
        return out(details.filter((d) => after.has(d.jobid) && (d.runid > after.get(d.jobid)! || open.includes(d.runid))).sort((a, b) => a.runid - b.runid).slice(0, 500));
      }
      throw new Error(`unexpected query ${text}`);
    },
  };
  return {
    db,
    jobs,
    details,
    add(jobid: number, status: string, start: number | null, end: number | null, message: string | null = null): Detail {
      const d = { runid: ++runid, jobid, status, return_message: message, start_time: start === null ? null : new Date(start), end_time: end === null ? null : new Date(end) };
      details.push(d);
      return d;
    },
  };
}

function job(jobid: number, jobname: string | null, schedule: string, active = true): PgCronJob {
  return { jobid, jobname, schedule, database: "postgres", username: "postgres", active };
}

test("pg_cron schedules become CronWatch schedules", () => {
  assert.equal(pgCronSchedule("30 seconds"), "every 30s");
  assert.equal(pgCronSchedule("1 second"), "every 1s");
  assert.equal(pgCronSchedule("0 0 $ * *"), "0 0 L * *");
  assert.equal(pgCronSchedule(" */5  * * * * "), "*/5 * * * *");
  assert.equal(pgCronSchedule("@reboot"), null);
  assert.equal(pgCronJobName({ jobid: 7, jobname: "nightly vacuum" }), "nightly-vacuum");
  assert.equal(pgCronJobName({ jobid: 7, jobname: null }), "pg_cron:7");
  assert.equal(pgCronJobName({ jobid: 7, jobname: "  " }), "pg_cron:7");
});

test("pg_cron: jobs are declared, history is copied quietly, and imports are idempotent", async () => {
  const c = clock();
  const cron = fakeCron();
  cron.jobs.push(job(1, "nightly vacuum", "0 3 * * *"), job(2, null, "10 seconds"), job(3, "paused", "0 * * * *", false), job(4, "other", "0 * * * *"));
  const day = 24 * HOUR;
  const three = Date.UTC(2026, 0, 5, 3, 0, 0);
  for (let i = 24; i >= 1; i--) cron.add(1, "succeeded", three - i * day, three - i * day + 5000, "VACUUM");
  cron.add(1, "failed", three, three + 2000, "ERROR:  deadlock detected\n");
  const store = memory();
  const alerts = capture();
  const source = () => pgCron(cron.db, { jobs: (j) => j.jobid !== 4, prefix: "db:" });
  let cw = cronwatch({ store, alerts: [alerts], now: c.now, sources: [source()] });

  const first = await cw.check();
  assert.deepEqual(first.jobs.map((j) => j.name), ["db:nightly-vacuum", "db:paused", "db:pg_cron:2"]);
  const vacuum = first.jobs.find((j) => j.name === "db:nightly-vacuum")!;
  assert.equal(vacuum.definition.schedule, "0 3 * * *");
  assert.equal(vacuum.definition.timezone, "UTC");
  assert.deepEqual(vacuum.definition.tags, ["pg_cron"]);
  assert.equal(first.jobs.find((j) => j.name === "db:pg_cron:2")!.definition.schedule, "every 10s");
  assert.equal(first.jobs.find((j) => j.name === "db:paused")!.definition.schedule, undefined, "a paused job is not expected to run");
  const runs = await cw.runs("db:nightly-vacuum", 100);
  assert.equal(runs.length, 20, "twenty newest runs copied on first sight");
  assert.equal(runs[0]!.id, "pgcron:db:25");
  assert.equal(runs[0]!.status, "failed");
  assert.equal(runs[0]!.error, "ERROR:  deadlock detected");
  assert.equal(runs[0]!.durationMs, 2000);
  assert.equal(runs[0]!.trigger, "pg_cron");
  assert.equal(runs[1]!.output, "VACUUM");
  assert.deepEqual(alerts.types(), ["failed"], "only the newest finished run is judged; history does not alert");

  await cw.check();
  cw = cronwatch({ store, alerts: [alerts], now: c.now, sources: [source()] });
  await cw.check();
  assert.equal((await cw.runs("db:nightly-vacuum", 100)).length, 20, "a re-import, even after a restart, adds nothing");
  assert.deepEqual(alerts.types(), ["failed"]);

  // A run not yet started holds the cursor; the run after it is copied now and it is copied once it starts.
  const starting = cron.add(2, "starting", null, null);
  cron.add(2, "succeeded", T0 - 5000, T0 - 4000, "1 row");
  c.advance(1000);
  await cw.check();
  assert.deepEqual((await cw.runs("db:pg_cron:2")).map((r) => r.id), ["pgcron:db:27"]);
  starting.status = "running";
  starting.start_time = new Date(T0 - 3000);
  await cw.check();
  assert.equal((await cw.getRun("pgcron:db:26"))!.status, "running");
  starting.status = "failed";
  starting.end_time = new Date(T0 - 1000);
  starting.return_message = "ERROR:  boom";
  c.advance(1000);
  await cw.check();
  const finished = (await cw.getRun("pgcron:db:26"))!;
  assert.equal(finished.status, "failed");
  assert.equal(finished.durationMs, 2000);
  assert.deepEqual(alerts.types(), ["failed", "failed"], "a run that was running and then failed is judged when it finishes");

  // The nightly job stops running: missed, from its schedule, with no run details at all.
  c.set(Date.UTC(2026, 0, 6, 3, 11, 0));
  cron.jobs.splice(0, 1);
  cron.add(2, "succeeded", c.now() - 2000, c.now() - 1000, "1 row");
  const later = await cw.check();
  assert.deepEqual(later.alerts.map((a) => `${a.type} ${a.job}`).sort(), ["missed db:nightly-vacuum", "recovered db:pg_cron:2"]);
  assert.ok(!(await cw.check()).alerts.length, "each condition alerts once");
});

test("pg_cron: runs a job's options, and reports a schedule it cannot read", async () => {
  const cron = fakeCron();
  cron.jobs.push(job(1, "odd", "not a schedule"));
  const errors: string[] = [];
  const cw = cronwatch({
    store: memory(),
    alerts: [],
    onError: (e) => errors.push((e as Error).message),
    sources: [pgCron(cron.db, { options: { grace: "1m", expect: /rows?/ } })],
  });
  cron.add(1, "succeeded", Date.now() - 1000, Date.now(), "nothing");
  const result = await cw.check();
  assert.equal(result.jobs[0]!.definition.schedule, undefined);
  assert.equal(result.jobs[0]!.definition.grace, "1m");
  assert.match(errors.join("\n"), /watching it without a schedule/);
  const [run] = await cw.runs("odd");
  assert.equal(run!.status, "failed", "expect applies to imported output");
  assert.match(run!.error!, /did not match/);
});

test("pg_cron against a real pg_cron", { skip: NO_PGCRON, timeout: 90_000 }, async () => {
  const pool = new pg.Pool({ connectionString: PGCRON });
  const tag = `cwtest${process.pid}`;
  const prefix = `${tag}_`;
  const names = { ok: `${tag}-ok`, fail: `${tag}-fail`, sleep: `${tag}-sleep` };
  let offset = 0;
  const now = () => Date.now() + offset;
  const store = postgres({ pool, prefix });
  const alerts = capture();
  const make = () => cronwatch({
    store,
    alerts: [alerts],
    now,
    sources: [pgCron(pool, { jobs: (j) => (j.jobname ?? "").startsWith(tag), options: { grace: "30s" } })],
  });
  const detailCount = async (name: string) => Number((await pool.query(
    `SELECT count(*) AS n FROM cron.job_run_details d JOIN cron.job j USING (jobid) WHERE j.jobname = $1 AND d.start_time IS NOT NULL`, [name],
  )).rows[0].n);
  try {
    await pool.query("CREATE EXTENSION IF NOT EXISTS pg_cron");
    await pool.query(`SELECT cron.schedule($1, '1 seconds', 'SELECT 1')`, [names.ok]);
    await pool.query(`SELECT cron.schedule($1, '1 seconds', 'SELECT 1/0')`, [names.fail]);
    await pool.query(`SELECT cron.schedule($1, '1 seconds', 'SELECT pg_sleep(3)')`, [names.sleep]);
    await sleep(3500);

    let cw = make();
    const first = await cw.check();
    const byName = new Map(first.jobs.map((j) => [j.name, j]));
    assert.equal(byName.get(names.ok)!.definition.schedule, "every 1s");
    assert.equal(byName.get(names.ok)!.definition.timezone, "UTC");
    const okRuns = await cw.runs(names.ok);
    assert.ok(okRuns.length >= 2, `ok runs imported (${okRuns.length})`);
    assert.ok(okRuns.every((r) => r.id.startsWith("pgcron:") && r.trigger === "pg_cron"));
    assert.ok(okRuns.some((r) => r.status === "ok" && r.output === "1 row"));
    const failRuns = await cw.runs(names.fail);
    assert.ok(failRuns.some((r) => r.status === "failed" && /division by zero/.test(r.error ?? "")), "failure and its message imported");
    assert.deepEqual(first.alerts.map((a) => `${a.type} ${a.job}`), [`failed ${names.fail}`]);
    assert.equal(byName.get(names.ok)!.health, "healthy");

    // A run imported while it was going is updated when it finishes.
    let running: string | undefined;
    for (let i = 0; i < 40 && !running; i++) {
      const { rows } = await pool.query(
        `SELECT d.runid FROM cron.job_run_details d JOIN cron.job j USING (jobid) WHERE j.jobname = $1 AND d.status = 'running' AND d.start_time IS NOT NULL`, [names.sleep],
      );
      running = rows[0]?.runid;
      if (!running) await sleep(250);
    }
    assert.ok(running, "saw the sleeping job running");
    await cw.check();
    assert.equal((await cw.getRun(`pgcron:${running}`))?.status, "running");
    await sleep(3500);
    await cw.check();
    const slept = (await cw.getRun(`pgcron:${running}`))!;
    assert.equal(slept.status, "ok");
    assert.ok(slept.durationMs! >= 2900, `duration ${slept.durationMs}`);

    // New runs keep arriving; nothing is copied twice, even by a fresh client after a restart.
    const before = (await cw.runs(names.ok, 500)).length;
    await sleep(2000);
    await cw.check();
    const after = await cw.runs(names.ok, 500);
    assert.ok(after.length > before, "later runs imported");
    assert.equal(new Set(after.map((r) => r.id)).size, after.length);

    // The ok job is unscheduled: it is missed once its grace passes.
    await pool.query(`SELECT cron.unschedule($1)`, [names.ok]);
    await pool.query(`SELECT cron.alter_job(jobid, active := false) FROM cron.job WHERE jobname = $1`, [names.fail]);
    await sleep(1500);
    cw = make();
    await cw.check();
    const settled = (await cw.runs(names.fail, 500)).length;
    await cw.check();
    assert.equal((await cw.runs(names.fail, 500)).length, settled, "re-import adds nothing");
    assert.equal((await cw.runs(names.fail, 500)).length, Math.min(await detailCount(names.fail), settled));
    offset = 2 * MIN;
    const late = await cw.check();
    assert.ok(late.alerts.some((a) => a.type === "missed" && a.job === names.ok), "unscheduled job reported missed");
    assert.ok(!late.alerts.some((a) => a.job === names.fail && a.type === "missed"), "paused job not missed");
  } finally {
    await pool.query(`SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname LIKE $1`, [`${tag}%`]).catch(() => {});
    for (const t of ["jobs", "runs", "state"]) await pool.query(`DROP TABLE IF EXISTS ${prefix}${t}`).catch(() => {});
    await pool.end();
  }
});
