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
  const settings: Record<string, string | undefined> = { "cron.timezone": "GMT", "cron.log_run": "on" };
  let runid = 0;
  const db: Queryable = {
    async query(text: string, values: unknown[] = []) {
      if (text.includes("pg_settings")) {
        const value = settings[values[0] as string];
        return { rows: value === undefined ? [] : [{ setting: value }] };
      }
      if (text.includes("FROM cron.job ORDER BY")) return { rows: jobs.map((j) => ({ ...j, jobid: String(j.jobid) })) };
      const out = (rows: Detail[]) => ({ rows: rows.map((d) => ({ ...d, runid: String(d.runid), jobid: String(d.jobid) })) });
      if (text.includes("ORDER BY d.runid DESC")) {
        return out(details.filter((d) => d.jobid === values[0]).sort((a, b) => b.runid - a.runid).slice(0, 20));
      }
      if (text.includes("unnest")) {
        const [ids, afters, open] = values as [number[], number[], number[]];
        const after = new Map(ids.map((id, i) => [id, afters[i]!]));
        return out(details.filter((d) => (after.has(d.jobid) && d.runid > after.get(d.jobid)!) || open.map(Number).includes(d.runid)).sort((a, b) => a.runid - b.runid).slice(0, 500));
      }
      throw new Error(`unexpected query ${text}`);
    },
  };
  return {
    db,
    jobs,
    details,
    settings,
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

test("pg_cron: a jobs, jobName or options callback that fails fails only its job, reported once", async () => {
  const c = clock();
  const cron = fakeCron();
  cron.jobs.push(job(1, "one", "0 * * * *"), job(2, "two", "0 * * * *"), job(3, "three", "0 * * * *"), job(4, "four", "0 * * * *"));
  const broken = new Set<string>();
  const fault = (what: string, jobid: number) => broken.has(`${what}:${jobid}`);
  const errors: string[] = [];
  const cw = cronwatch({
    store: memory(),
    alerts: [],
    now: c.now,
    onError: (e) => errors.push((e as Error).message),
    sources: [
      pgCron(cron.db, {
        jobs: (j) => {
          if (fault("pick", j.jobid)) throw new Error("pick broke");
          return true;
        },
        jobName: (j) => {
          if (fault("throw", j.jobid)) throw new Error("name broke");
          if (fault("null", j.jobid)) return null as unknown as string;
          if (fault("undefined", j.jobid)) return undefined as unknown as string;
          return `j-${j.jobname}`;
        },
        options: (j) => {
          if (fault("options", j.jobid)) throw new Error("options broke");
          return {};
        },
      }),
    ],
  });
  const notices = () => errors.filter((e) => !/cron\.timezone|row level/.test(e));
  // First sight, with job 1's name callback throwing and job 2's giving null: only those two are skipped.
  broken.add("throw:1");
  broken.add("null:2");
  const first = cron.add(3, "succeeded", T0 - 60_000, T0 - 59_000, "ok");
  await cw.check();
  assert.deepEqual((await cw.store.listJobs()).map((j) => j.name), ["j-four", "j-three"]);
  assert.equal((await cw.getRun(`pgcron:${first.runid}`))?.job, "j-three");
  assert.deepEqual(notices(), [
    "pg_cron job 1: jobName threw Error: name broke; it keeps its last declaration until that works",
    "pg_cron job 2: jobName returned null, not a name; it keeps its last declaration until that works",
  ]);

  // Once they work, both are declared; then every callback fails in turn for jobs already declared.
  broken.clear();
  await cw.check();
  assert.deepEqual((await cw.store.listJobs()).map((j) => j.name), ["j-four", "j-one", "j-three", "j-two"]);
  broken.add("pick:1");
  broken.add("undefined:2");
  broken.add("options:3");
  broken.add("throw:4");
  errors.length = 0;
  const later = [cron.add(1, "failed", T0 + 1000, T0 + 2000, "ERROR:  one"), cron.add(3, "succeeded", T0 + 1000, T0 + 2000, "ok")];
  c.advance(5000);
  await cw.check();
  await cw.check();
  assert.deepEqual(notices(), [
    "pg_cron job 1: the jobs callback threw Error: pick broke; it keeps its last declaration until that works",
    "pg_cron job 2: jobName returned undefined, not a name; it keeps its last declaration until that works",
    "pg_cron job 3: the options callback threw Error: options broke; it keeps its last declaration until that works",
    "pg_cron job 4: jobName threw Error: name broke; it keeps its last declaration until that works",
  ], "each reported once, over two syncs");
  // Each keeps its name and schedule, is not retired, and its runs are still copied.
  for (const stored of await cw.store.listJobs()) {
    assert.equal(stored.definition.schedule, "0 * * * *", stored.name);
    assert.doesNotMatch(stored.definition.description ?? "", /no longer|renamed/, stored.name);
  }
  assert.equal((await cw.getRun(`pgcron:${later[0]!.runid}`))?.job, "j-one");
  assert.equal((await cw.getRun(`pgcron:${later[1]!.runid}`))?.job, "j-three");

  // Working again and then failing again is reported again.
  broken.clear();
  await cw.check();
  broken.add("pick:1");
  await cw.check();
  assert.equal(notices().length, 5);
  assert.match(notices()[4]!, /^pg_cron job 1: the jobs callback threw/);
});

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
  cron.add(2, "succeeded", c.now() - 2000, c.now() - 1000, "1 row");
  const later = await cw.check();
  assert.deepEqual(later.alerts.map((a) => `${a.type} ${a.job}`).sort(), ["missed db:nightly-vacuum", "recovered db:pg_cron:2"]);
  assert.ok(!(await cw.check()).alerts.length, "each condition alerts once");

  // Unscheduled: its name keeps its history but loses its schedule, so it is never missed again,
  // and the missed alert it had open closes with a recovery that says so.
  cron.jobs.splice(0, 1);
  c.set(Date.UTC(2026, 0, 8, 3, 11, 0));
  const gone = await cw.check();
  const vacuumNow = gone.jobs.find((j) => j.name === "db:nightly-vacuum")!;
  assert.equal(vacuumNow.definition.schedule, undefined);
  assert.match(vacuumNow.definition.description!, /no longer watched/);
  assert.deepEqual(vacuumNow.open, ["failed"], "its failure stays open until a successful run");
  const closed = gone.alerts.filter((a) => a.job === "db:nightly-vacuum");
  assert.deepEqual(closed.map((a) => a.type), ["recovered"]);
  assert.equal(closed[0]!.title, "db:nightly-vacuum is no longer scheduled");
  assert.deepEqual(closed[0]!.details, { after: ["missed"], reason: "unscheduled", since: Date.UTC(2026, 0, 6, 3, 11, 0) });
  assert.ok(!(await cw.check()).alerts.some((a) => a.job === "db:nightly-vacuum"), "once");
  assert.equal((await cw.runs("db:nightly-vacuum", 100)).length, 20, "its history is kept");
});

test("pg_cron: a job forgotten from the dashboard is declared again and its later runs recorded", async () => {
  const c = clock();
  const cron = fakeCron();
  cron.jobs.push(job(1, "vacuum", "0 3 * * *"));
  cron.add(1, "succeeded", T0 - 5000, T0 - 4000, "VACUUM");
  const errors: string[] = [];
  const cw = cronwatch({ store: memory(), alerts: [capture()], now: c.now, sources: [pgCron(cron.db)], onError: (e, where) => errors.push(`${where}: ${(e as Error).message}`) });
  await cw.check();
  await cw.forget("vacuum");
  cron.add(1, "succeeded", T0 - 3000, T0 - 2000, "VACUUM");
  cron.add(1, "failed", T0 - 1000, T0, "ERROR:  boom");
  c.advance(1000);
  const result = await cw.check();
  assert.deepEqual(errors, []);
  assert.deepEqual(result.jobs.map((j) => j.name), ["vacuum"]);
  assert.equal(result.jobs[0]!.definition.schedule, "0 3 * * *");
  assert.deepEqual((await cw.runs("vacuum")).map((r) => r.id), ["pgcron:3", "pgcron:2"], "the runs after the forget");
  assert.deepEqual(cw.definedJobs().map((d) => d.name), ["vacuum"]);
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

test("pg_cron: a run cut off by a server restart is recorded, and one held run never stops the others", async () => {
  const c = clock();
  const cron = fakeCron();
  cron.jobs.push(job(1, "fast", "30 seconds"), job(2, "other", "0 * * * *"));
  const errors: string[] = [];
  const alerts = capture();
  const cw = cronwatch({ store: memory(), alerts: [alerts], now: c.now, onError: (e) => errors.push((e as Error).message), sources: [pgCron(cron.db)] });
  cron.add(1, "succeeded", T0 - 60_000, T0 - 59_000, "1 row");
  await cw.check();
  // pg_cron restarts while a run is queued: it marks it failed, "server restarted", with no times at all.
  const restarted = cron.add(1, "failed", null, null, "server restarted");
  // The fast job then runs far more than a page's worth, and the other job fails after all of them.
  for (let i = 0; i < 520; i++) cron.add(1, "succeeded", T0 - 50_000 + i, T0 - 50_000 + i + 1, "1 row");
  const failure = cron.add(2, "failed", T0 - 1000, T0 - 500, "ERROR:  disk full");
  const queued = cron.add(1, "starting", null, null);
  c.advance(1000);
  await cw.check();
  await cw.check();
  const cut = (await cw.getRun(`pgcron:${restarted.runid}`))!;
  assert.equal(cut.status, "failed");
  assert.equal(cut.error, "server restarted");
  assert.equal(cut.startedAt, T0 - 60_000, "placed at the job's newest run before it");
  assert.equal((await cw.getRun(`pgcron:${failure.runid}`))?.status, "failed", "the other job's failure is not starved");
  assert.ok(alerts.alerts.some((a) => a.type === "failed" && a.job === "other"));
  assert.equal(await cw.getRun(`pgcron:${queued.runid}`), null, "a queued run is held");

  // Held only so long: then it is copied as running from when it was first seen, and a late start updates nothing but its end.
  c.advance(11 * MIN);
  await cw.check();
  const waiting = (await cw.getRun(`pgcron:${queued.runid}`))!;
  assert.equal(waiting.status, "running");
  assert.equal(waiting.startedAt, T0 + 1000);
  queued.status = "succeeded";
  queued.start_time = new Date(c.now() - 2000);
  queued.end_time = new Date(c.now() - 1000);
  c.advance(1000);
  await cw.check();
  assert.equal((await cw.getRun(`pgcron:${queued.runid}`))!.status, "ok");
  assert.deepEqual(errors.filter((e) => !/cron\.|row level/.test(e)), []);
});

test("pg_cron: first sight never judges history, even with a held or cut off run among the newest", async () => {
  const c = clock();
  const cron = fakeCron();
  cron.jobs.push(job(1, "nightly", "0 3 * * *"));
  for (let i = 0; i < 30; i++) cron.add(1, "failed", T0 - (40 - i) * HOUR, T0 - (40 - i) * HOUR + 1000, "ERROR:  old");
  cron.add(1, "failed", null, null, "server restarted");
  for (let i = 0; i < 19; i++) cron.add(1, "succeeded", T0 - (10 - i / 2) * HOUR, T0 - (10 - i / 2) * HOUR + 1000, "ok");
  const alerts = capture();
  const cw = cronwatch({ store: memory(), alerts: [alerts], now: c.now, sources: [pgCron(cron.db)] });
  await cw.check();
  await cw.check();
  assert.equal((await cw.runs("nightly", 500)).length, 20, "only the newest twenty are copied");
  assert.deepEqual(alerts.types(), [], "no alert from history");
});

test("pg_cron: pg_cron ignores fields past the fifth, and so does the reader", () => {
  assert.equal(pgCronSchedule("0 5 * * * *"), "0 5 * * *");
  assert.equal(pgCronSchedule("* * * * * *"), "* * * * *");
  assert.equal(pgCronSchedule("0 0 $ * * extra"), "0 0 L * *");
  assert.equal(pgCronSchedule("@hourly"), "@hourly");
});

test("pg_cron: a renamed job leaves no scheduled ghost, in this process or the next", async () => {
  const c = clock();
  const cron = fakeCron();
  cron.jobs.push(job(1, "rollup", "*/5 * * * *"));
  cron.add(1, "succeeded", T0 - 60_000, T0 - 59_000, "1 row");
  const store = memory();
  const alerts = capture();
  const errors: string[] = [];
  const make = () => cronwatch({ store, alerts: [alerts], now: c.now, onError: (e) => errors.push((e as Error).message), sources: [pgCron(cron.db)] });
  let cw = make();
  await cw.check();
  cron.jobs[0]!.jobname = "rollup-v2";
  const running = cron.add(1, "running", T0 - 1000, null);
  await cw.check();
  let summary = await cw.jobs();
  const old = summary.find((j) => j.name === "rollup")!;
  assert.equal(old.definition.schedule, undefined, "the old name has no schedule");
  assert.match(old.definition.description!, /renamed to rollup-v2/);
  assert.equal(summary.find((j) => j.name === "rollup-v2")!.definition.schedule, "*/5 * * * *");
  assert.equal((await cw.getRun(`pgcron:${running.runid}`))!.job, "rollup-v2");
  running.status = "succeeded";
  running.end_time = new Date(T0);
  c.advance(HOUR);
  cron.add(1, "succeeded", c.now() - 2000, c.now() - 1000, "1 row");
  await cw.check();
  assert.equal((await cw.getRun(`pgcron:${running.runid}`))!.status, "ok");
  assert.ok(!alerts.alerts.some((a) => a.job === "rollup"), "the old name is never missed");

  // Renamed again while no process watched: the next process retires the name the store still schedules.
  cron.jobs[0]!.jobname = "rollup-v3";
  cw = make();
  c.advance(MIN);
  await cw.check();
  summary = await cw.jobs();
  assert.equal(summary.find((j) => j.name === "rollup-v2")!.definition.schedule, undefined);
  assert.match(summary.find((j) => j.name === "rollup-v2")!.definition.description!, /renamed to rollup-v3/);
  assert.equal(summary.find((j) => j.name === "rollup-v3")!.definition.schedule, "*/5 * * * *");
  assert.equal((await cw.runs("rollup-v3")).length, 0, "runs already copied under an old name are not copied again");
  c.advance(HOUR);
  await cw.check();
  assert.deepEqual(alerts.alerts.filter((a) => a.job !== "rollup-v3").map((a) => `${a.type} ${a.job}`), [], "only the job's current name can be missed");
  assert.deepEqual(errors.filter((e) => !/cron\.|row level/.test(e)), []);
});

test("pg_cron: a job paused or renamed while missed closes missed with a recovery", async () => {
  const c = clock();
  const cron = fakeCron();
  cron.jobs.push(job(1, "hourly", "0 * * * *"), job(2, "rollup", "0 * * * *"));
  cron.add(1, "succeeded", T0 - 3 * HOUR, T0 - 3 * HOUR + 1000);
  cron.add(2, "succeeded", T0 - 3 * HOUR, T0 - 3 * HOUR + 1000);
  const alerts = capture();
  const cw = cronwatch({ store: memory(), alerts: [alerts], now: c.now, sources: [pgCron(cron.db)] });
  await cw.check();
  assert.deepEqual(alerts.alerts.map((a) => `${a.type} ${a.job}`).sort(), ["missed hourly", "missed rollup"]);
  cron.jobs[0]!.active = false;
  cron.jobs[1]!.jobname = "rollup-v2";
  c.advance(MIN);
  const r = await cw.check();
  assert.deepEqual(r.alerts.map((a) => `${a.type} ${a.job} ${a.title}`).sort(), [
    "recovered hourly hourly is no longer scheduled",
    "recovered rollup rollup is no longer scheduled",
  ]);
  c.advance(MIN);
  assert.deepEqual((await cw.check()).alerts, []);
});

test("pg_cron: a run marked timeout by a check is still read, and its late finish recorded", async () => {
  const c = clock();
  const cron = fakeCron();
  cron.jobs.push(job(1, "vacuum", "0 3 * * *"));
  const alerts = capture();
  const cw = cronwatch({ store: memory(), alerts: [alerts], now: c.now, sources: [pgCron(cron.db, { options: { timeout: "30m" } })] });
  const long = cron.add(1, "running", T0, null);
  await cw.check();
  assert.equal((await cw.getRun(`pgcron:${long.runid}`))!.status, "running");
  c.advance(45 * MIN);
  await cw.check();
  assert.equal((await cw.getRun(`pgcron:${long.runid}`))!.status, "timeout");
  assert.deepEqual(alerts.types(), ["stuck"]);
  c.advance(10 * MIN);
  long.status = "succeeded";
  long.end_time = new Date(c.now() - 60_000);
  long.return_message = "VACUUM";
  await cw.check();
  const done = (await cw.getRun(`pgcron:${long.runid}`))!;
  assert.equal(done.status, "ok");
  assert.equal(done.output, "VACUUM");
  assert.deepEqual(alerts.types(), ["stuck", "recovered"]);
  assert.equal((await cw.jobSummary("vacuum"))!.health, "healthy");
});

test("pg_cron: settings a role may not read are assumed, and reported once", async () => {
  const cron = fakeCron();
  cron.settings["cron.timezone"] = undefined;
  cron.settings["cron.log_run"] = undefined;
  cron.jobs.push(job(1, "nightly", "0 3 * * *"));
  const errors: string[] = [];
  const cw = cronwatch({ store: memory(), alerts: [], onError: (e) => errors.push((e as Error).message), sources: [pgCron(cron.db)] });
  const first = await cw.check();
  await cw.check();
  assert.equal(first.jobs[0]!.definition.timezone, "UTC");
  assert.equal(errors.filter((e) => /cron\.timezone/.test(e)).length, 1);
  assert.ok(!errors.some((e) => /log_run/.test(e)), "log_run unreadable is taken as on");
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
    assert.ok(!late.alerts.some((a) => a.type === "missed" && a.job === names.ok), "unscheduled job not missed: it is gone, not late");
    const okJob = late.jobs.find((j) => j.name === names.ok)!;
    assert.equal(okJob.definition.schedule, undefined);
    assert.match(okJob.definition.description!, /no longer in cron\.job/);
    assert.ok(!late.alerts.some((a) => a.job === names.fail && a.type === "missed"), "paused job not missed");
  } finally {
    await pool.query(`SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname LIKE $1`, [`${tag}%`]).catch(() => {});
    for (const t of ["jobs", "runs", "state"]) await pool.query(`DROP TABLE IF EXISTS ${prefix}${t}`).catch(() => {});
    await pool.end();
  }
});

test("pg_cron against a real pg_cron: restart rows, a crowded job, first sight and a rename", { skip: NO_PGCRON, timeout: 60_000 }, async () => {
  const pool = new pg.Pool({ connectionString: PGCRON });
  const tag = `cwrow${process.pid}`;
  const names = { busy: `${tag}-busy`, quiet: `${tag}-quiet`, hist: `${tag}-hist` };
  const insert = (jobid: number, status: string, times: string, message: string) => pool.query(
    `INSERT INTO cron.job_run_details (jobid, runid, database, username, command, status, return_message, start_time, end_time)
     SELECT $1, nextval('cron.runid_seq'), 'postgres', 'postgres', 'select 1', $2, $3, ${times} RETURNING runid`, [jobid, status, message],
  );
  try {
    await pool.query("CREATE EXTENSION IF NOT EXISTS pg_cron");
    const ids: Record<string, number> = {};
    for (const name of Object.values(names)) {
      ids[name] = Number((await pool.query(`SELECT cron.schedule($1, '0 3 * * *', 'SELECT 1') AS id`, [name])).rows[0].id);
      // Paused, so pg_cron itself adds no rows while the test writes its own.
      await pool.query(`SELECT cron.alter_job($1, active := false)`, [ids[name]]);
    }
    // First sight of a job whose newest rows include a run cut off by a restart, and older failures.
    await pool.query(`INSERT INTO cron.job_run_details (jobid, runid, database, username, command, status, return_message, start_time, end_time)
      SELECT $1, nextval('cron.runid_seq'), 'postgres', 'postgres', 'select 1', 'failed', 'ERROR: old', now() - interval '3 days', now() - interval '3 days' FROM generate_series(1, 5)`, [ids[names.hist]]);
    await insert(ids[names.hist]!, "failed", "NULL, NULL", "server restarted");
    await pool.query(`INSERT INTO cron.job_run_details (jobid, runid, database, username, command, status, return_message, start_time, end_time)
      SELECT $1, nextval('cron.runid_seq'), 'postgres', 'postgres', 'select 1', 'succeeded', '1 row', now() - make_interval(mins => 30 - g), now() - make_interval(mins => 30 - g) FROM generate_series(1, 19) g`, [ids[names.hist]]);

    const alerts = capture();
    const errors: string[] = [];
    const cw = cronwatch({ store: memory(), alerts: [alerts], onError: (e) => errors.push((e as Error).message), sources: [pgCron(pool, { jobs: (j) => (j.jobname ?? "").startsWith(tag), timezone: "UTC" })] });
    await cw.check();
    assert.equal((await cw.runs(names.hist, 500)).length, 20, "twenty newest copied");
    assert.deepEqual(alerts.alerts.map((a) => a.job), [], "history is never judged");
    await cw.check();
    assert.equal((await cw.runs(names.hist, 500)).length, 20, "and never read again");

    // A restart cuts off a busy job's queued run; the busy job then runs past a page; then the quiet job fails.
    const { rows: [cut] } = await insert(ids[names.busy]!, "failed", "NULL, NULL", "server restarted");
    await pool.query(`INSERT INTO cron.job_run_details (jobid, runid, database, username, command, status, return_message, start_time, end_time)
      SELECT $1, nextval('cron.runid_seq'), 'postgres', 'postgres', 'select 1', 'succeeded', '1 row', now() - make_interval(secs => 600 - g), now() - make_interval(secs => 600 - g) FROM generate_series(1, 520) g`, [ids[names.busy]]);
    const { rows: [disk] } = await insert(ids[names.quiet]!, "failed", "now(), now()", "ERROR: disk full");
    for (let i = 0; i < 3; i++) await cw.check();
    assert.equal((await cw.getRun(`pgcron:${cut.runid}`))?.error, "server restarted");
    assert.equal((await cw.getRun(`pgcron:${disk.runid}`))?.status, "failed", "the quiet job's failure is read");
    assert.ok(alerts.alerts.some((a) => a.type === "failed" && a.job === names.quiet));

    // Renamed in pg_cron: the old name keeps its runs and loses its schedule.
    await pool.query(`UPDATE cron.job SET jobname = $1 WHERE jobid = $2`, [`${names.quiet}-v2`, ids[names.quiet]]);
    await pool.query(`SELECT cron.alter_job($1, active := true)`, [ids[names.quiet]]);
    await cw.check();
    const jobs = await cw.jobs();
    const old = jobs.find((j) => j.name === names.quiet)!;
    assert.equal(old.definition.schedule, undefined);
    assert.match(old.definition.description!, /renamed to/);
    assert.equal(jobs.find((j) => j.name === `${names.quiet}-v2`)!.definition.schedule, "0 3 * * *");
    assert.deepEqual(errors.filter((e) => !/cron\.|row level/.test(e)), []);
  } finally {
    await pool.query(`SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname LIKE $1`, [`${tag}%`]).catch(() => {});
    await pool.end();
  }
});

test("pg_cron against a real pg_cron: a role that may not read cron settings never aborts the caller's transaction", { skip: NO_PGCRON, timeout: 30_000 }, async () => {
  const admin = new pg.Pool({ connectionString: PGCRON });
  const role = `cwrole${process.pid}`;
  const url = new URL(PGCRON!);
  url.username = role;
  url.password = "pw";
  const client = new pg.Client({ connectionString: url.toString() });
  try {
    await admin.query("CREATE EXTENSION IF NOT EXISTS pg_cron");
    await admin.query(`CREATE ROLE ${role} LOGIN PASSWORD 'pw'`);
    await admin.query(`GRANT USAGE ON SCHEMA cron TO ${role}`);
    await admin.query(`GRANT SELECT ON cron.job, cron.job_run_details TO ${role}`);
    await client.connect();
    await client.query(`SELECT cron.schedule($1, '0 3 * * *', 'SELECT 1')`, [`${role}-job`]);
    const errors: string[] = [];
    const cw = cronwatch({ store: memory(), alerts: [], onError: (e) => errors.push((e as Error).message), sources: [pgCron(client)] });
    await client.query("BEGIN");
    const result = await cw.check();
    assert.equal((await client.query("SELECT 1 AS one")).rows[0].one, 1, "the transaction is still usable");
    await client.query("ROLLBACK");
    const job = result.jobs.find((j) => j.name === `${role}-job`)!;
    assert.equal(job.definition.timezone, "UTC", "assumed");
    assert.equal(job.definition.schedule, "0 3 * * *", "cron.log_run unreadable is taken as on");
    assert.ok(errors.some((e) => /could not read cron\.timezone/.test(e)));
  } finally {
    await client.end().catch(() => {});
    // Every job of the role goes before the role: pg_cron's scheduler stops on a job whose role is gone.
    await admin.query(`SELECT cron.unschedule(jobid) FROM cron.job WHERE username = $1`, [role]).catch(() => {});
    await admin.query(`DROP OWNED BY ${role}`).catch(() => {});
    await admin.query(`DROP ROLE IF EXISTS ${role}`).catch(() => {});
    await admin.end();
  }
});
