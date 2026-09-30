import type { Source, SourceHost } from "../client.js";
import { runDuration } from "../evaluate.js";
import type { Alert, JobOptions, Run, StoredJobDefinition } from "../types.js";

/**
 * Anything with a pg-style query(): a `pg` Pool or Client, or a wrapper
 * around another driver that answers with `{ rows }`.
 */
export interface Queryable {
  query(text: string, values?: unknown[]): Promise<{ rows: any[] }>;
}

/** A row of cron.job. */
export interface PgCronJob {
  jobid: number;
  jobname: string | null;
  schedule: string;
  database: string;
  username: string;
  active: boolean;
}

export interface PgCronOptions {
  /**
   * Which jobs to watch: names or ids, or a function that picks them. Default
   * every job the role can see.
   */
  jobs?: (string | number)[] | ((job: PgCronJob) => boolean);
  /** Put before every job name, to keep them apart from your own ("db:"). Also keeps run ids apart. */
  prefix?: string;
  /**
   * The CronWatch name for a job. Default its jobname with anything other
   * than letters, digits, ".", "_", ":" and "-" turned into "-", or
   * "pg_cron:<jobid>" when it has none. The prefix goes in front either way.
   * One that throws or returns no string, like a `jobs` or `options`
   * function that throws, is reported once and fails only that job, which
   * keeps its last declaration until the callback works again.
   */
  jobName?: (job: PgCronJob) => string;
  /** Grace, timeout, maxDuration, expect and the rest, for every job or per job. The schedule always comes from pg_cron. */
  options?: Omit<JobOptions, "schedule" | "timezone"> | ((job: PgCronJob) => Omit<JobOptions, "schedule" | "timezone">);
  /**
   * The timezone pg_cron reads its cron expressions in. Default the server's
   * cron.timezone, read from pg_settings, which shows it only to roles with
   * pg_read_all_settings; UTC (pg_cron's default) is assumed when it cannot
   * be read.
   */
  timezone?: string;
}

/** How many of a job's newest runs are copied, without alerting, the first time it is seen. */
const BACKFILL = 20;
/** Run details read per query, and the most read in one sync. */
const PAGE = 500;
const MAX_PAGES = 10;
/**
 * How long a run pg_cron has queued but not started (no start_time yet) is
 * waited for. After that it is copied as running from when it was first
 * seen, so a run that never starts is marked stuck like any other.
 */
export const PG_CRON_HOLD_MS = 10 * 60_000;

const JOBS_SQL = `SELECT jobid, jobname, schedule, database, username, active FROM cron.job ORDER BY jobid`;
// pg_settings has no row for a setting the role may not read, where
// current_setting() raises an error that would abort the caller's transaction.
const SETTING_SQL = `SELECT setting FROM pg_settings WHERE name = $1`;
const COLUMNS = `d.runid, d.jobid, d.status, d.return_message, d.start_time, d.end_time`;
// Every tracked job's runs after its cursor, and any run still open here, whatever its job.
const RUNS_SQL = `SELECT ${COLUMNS}
  FROM cron.job_run_details d
  LEFT JOIN unnest($1::bigint[], $2::bigint[]) AS c(jobid, after) ON d.jobid = c.jobid
  WHERE d.runid > c.after OR d.runid = ANY($3::bigint[])
  ORDER BY d.runid LIMIT ${PAGE}`;
const NEWEST_SQL = `SELECT ${COLUMNS} FROM cron.job_run_details d WHERE d.jobid = $1 ORDER BY d.runid DESC LIMIT ${BACKFILL}`;

interface DetailRow {
  runid: number | string;
  jobid: number | string;
  status: string | null;
  return_message: string | null;
  start_time: Date | string | null;
  end_time: Date | string | null;
}

const finishedStatus = (status: string | null) => status === "succeeded" || status === "failed";

/**
 * pg_cron takes a cron expression, with "$" for the last day of the month,
 * or "N seconds" for 1 to 59 seconds. Returns the CronWatch schedule, or
 * null for one that has no cadence to watch. pg_cron reads only the first
 * five fields of an expression and ignores the rest, so only those are kept
 * (a sixth would otherwise be read as seconds).
 */
export function pgCronSchedule(schedule: string): string | null {
  const text = schedule.trim();
  const seconds = /^(\d+)\s*seconds?$/i.exec(text);
  if (seconds) return `every ${Number(seconds[1])}s`;
  if (/^@reboot$/i.test(text)) return null;
  const fields = text.split(/\s+/);
  if (fields.length > 5 && !fields[0]!.startsWith("@")) fields.length = 5;
  if (fields.length === 5 && fields[2]!.includes("$")) fields[2] = fields[2]!.replace(/\$/g, "L");
  return fields.join(" ");
}

/** The default CronWatch name for a pg_cron job, before the prefix. */
export function pgCronJobName(job: Pick<PgCronJob, "jobid" | "jobname">): string {
  const cleaned = (job.jobname ?? "").replace(/[^A-Za-z0-9._:-]+/g, "-").replace(/^[^A-Za-z0-9]+/, "").slice(0, 100);
  return cleaned || `pg_cron:${job.jobid}`;
}

/**
 * A row of cron.job_run_details as a CronWatch run, or null for one that has
 * not started (no start_time, not finished). A finished row with no
 * start_time (pg_cron writes these for runs a server restart cut off,
 * "server restarted") starts at its end_time, else at `fallbackAt` (the
 * reader passes the job's newest run's start, or now).
 */
export function pgCronRun(row: DetailRow, job: string, idPrefix: string, fallbackAt: number = Date.now()): Run | null {
  const finishedAt = row.end_time === null ? null : new Date(row.end_time).getTime();
  const done = finishedStatus(row.status);
  if (row.start_time === null && !done) return null;
  const startedAt = row.start_time !== null ? new Date(row.start_time).getTime() : (finishedAt ?? fallbackAt);
  const message = row.return_message === null ? null : row.return_message.trim() || null;
  const status: Run["status"] = row.status === "succeeded" ? "ok" : row.status === "failed" ? "failed" : "running";
  const end = done ? Math.max(startedAt, finishedAt ?? startedAt) : null;
  return {
    id: `${idPrefix}${row.runid}`,
    job,
    status,
    startedAt,
    finishedAt: end,
    durationMs: end === null ? null : runDuration(startedAt, end),
    error: status === "failed" ? (message ?? "pg_cron reported the run as failed") : null,
    output: status === "ok" ? message : null,
    metrics: {},
    trigger: "pg_cron",
  };
}

/** The options of a stored definition that can be declared again, without its schedule. */
function unscheduled(definition: StoredJobDefinition | JobOptions): JobOptions {
  const { description, tags, grace, timeout, maxDuration, budget, failuresBeforeAlert } = definition;
  const out: JobOptions = {};
  if (description !== undefined) out.description = description;
  if (tags !== undefined) out.tags = tags;
  if (grace !== undefined) out.grace = grace;
  if (timeout !== undefined) out.timeout = timeout;
  if (maxDuration !== undefined) out.maxDuration = maxDuration;
  if (budget !== undefined) out.budget = budget;
  if (failuresBeforeAlert !== undefined) out.failuresBeforeAlert = failuresBeforeAlert;
  return out;
}

const keyOf = (definition: JobOptions) =>
  JSON.stringify(definition, (_k, v: unknown) => (v instanceof RegExp || typeof v === "function" ? String(v) : v));

/**
 * Watches pg_cron jobs, which run inside Postgres where nothing can wrap
 * them. As a source, on every check it reads cron.job and declares each job
 * with its schedule, then copies new rows of cron.job_run_details in as runs
 * (ids "pgcron:<runid>"), so the usual evaluation raises missed, failed,
 * stuck and slow alerts.
 *
 * A job that is renamed, unscheduled or no longer picked keeps its old name's
 * runs and history, and that name is declared again without a schedule, so
 * it is never reported missed. Its description says why.
 *
 *   cronwatch({ store: postgres({ pool }), sources: [pgCron(pool)] }).start();
 */
export function pgCron(db: Queryable, options: PgCronOptions = {}): Source {
  const prefix = options.prefix ?? "";
  const idPrefix = `pgcron:${prefix}`;
  /** The newest runid read for each jobid, once known. */
  const cursors = new Map<number, number>();
  /** The start of the newest run copied for each jobid: where a restart row with no times is put. */
  const lastAt = new Map<number, number>();
  /** Runs copied while still going, by runid, with their job: read again until they finish, even once a check marks them timeout. */
  const pending = new Map<number, string>();
  /** Runs read before they started, by runid, with when they were first seen. */
  const held = new Map<number, number>();
  /** Each job's name and definition as last declared, by jobid. */
  let known = new Map<number, { name: string; definition: JobOptions }>();
  /** The last definition declared for each name, so an unchanged job is not declared again. */
  const declared = new Map<string, string>();
  /** Names declared again without a schedule by retire(), whose open runs are still read. */
  const retired = new Set<string>();
  let scanned = false;
  const warned = new Set<string>();
  /** Jobids whose callback failed, reported once until it works again. */
  const failing = new Set<number>();

  const warnOnce = (host: SourceHost, key: string, message: string) => {
    if (warned.has(key)) return;
    warned.add(key);
    host.onError(new Error(message), "source pg_cron");
  };

  const picks = (job: PgCronJob): boolean => {
    const { jobs } = options;
    if (jobs === undefined) return true;
    if (typeof jobs === "function") return jobs(job);
    return jobs.some((j) => (typeof j === "number" ? j === job.jobid : j === job.jobname));
  };

  const setting = async (name: string): Promise<string | null> => {
    try {
      const { rows } = await db.query(SETTING_SQL, [name]);
      return (rows[0]?.setting as string | null | undefined) ?? null;
    } catch {
      return null;
    }
  };

  const runIdOf = (id: string): number | null => {
    if (!id.startsWith(idPrefix)) return null;
    const n = Number(id.slice(idPrefix.length));
    return Number.isSafeInteger(n) ? n : null;
  };

  /** Declares a name this source no longer uses for any job again, without its schedule. */
  const retire = (host: SourceHost, name: string, definition: StoredJobDefinition | JobOptions, why: string) => {
    const base = unscheduled(definition);
    const next: JobOptions = { ...base, description: `${base.description ?? "pg_cron job"} (${why})` };
    try {
      host.job(name, next);
      declared.set(name, keyOf(next));
      retired.add(name);
    } catch (e) {
      host.onError(e, `source pg_cron: job ${name}`);
    }
  };

  return {
    name: "pg_cron",
    async sync(host) {
      const now = host.now();
      let timezone = options.timezone;
      if (!timezone) {
        const tz = await setting("cron.timezone");
        if (tz === null) warnOnce(host, "tz", "could not read cron.timezone; assuming UTC. Grant pg_read_all_settings or pass pgCron(pool, { timezone }).");
        timezone = tz === null || /^(gmt|utc|z)$/i.test(tz) ? "UTC" : tz;
      }
      const logRun = await setting("cron.log_run");
      const recording = logRun !== "off";
      if (!recording) warnOnce(host, "log_run", "cron.log_run is off, so pg_cron records no runs: jobs are watched without their schedules and no run can fail. Turn it on to watch them.");

      const { rows } = await db.query(JOBS_SQL);
      if (rows.length === 0) {
        warnOnce(host, "empty", "cron.job shows no jobs. pg_cron's row level security shows a role only the jobs it scheduled: connect as that role, or give this one BYPASSRLS.");
      }
      const all = (rows as PgCronJob[]).map((r) => ({ ...r, jobid: Number(r.jobid) }));

      // Declare each job. A paused one (active = false) keeps its failures but loses its schedule, so it is not missed.
      const names = new Map<number, string>();
      const definitions = new Map<number, JobOptions>();
      const used = new Set<string>();
      /**
       * A callback of the app's (jobs, jobName, options) that threw, or a
       * jobName that gave no name, fails only its job, as a bad row does:
       * reported once until it works again, and the job carries on as last
       * declared (skipped when it never was), so its runs are still copied.
       */
      const trouble = (job: PgCronJob, what: string) => {
        if (!failing.has(job.jobid)) {
          failing.add(job.jobid);
          host.onError(new Error(`pg_cron job ${job.jobid}: ${what}; it keeps its last declaration until that works`), "source pg_cron");
        }
        const last = known.get(job.jobid);
        if (!last || used.has(last.name)) return;
        names.set(job.jobid, last.name);
        definitions.set(job.jobid, last.definition);
        used.add(last.name);
      };
      const threw = (e: unknown) => (e instanceof Error ? `${e.name}: ${e.message}` : String(e));
      for (const job of all) {
        let picked: boolean;
        try {
          picked = picks(job);
        } catch (e) {
          trouble(job, `the jobs callback threw ${threw(e)}`);
          continue;
        }
        if (!picked) {
          failing.delete(job.jobid);
          continue;
        }
        let base: unknown;
        let extra: Omit<JobOptions, "schedule" | "timezone">;
        try {
          base = options.jobName ? options.jobName(job) : pgCronJobName(job);
        } catch (e) {
          trouble(job, `jobName threw ${threw(e)}`);
          continue;
        }
        if (typeof base !== "string") {
          trouble(job, `jobName returned ${base === null ? "null" : typeof base}, not a name`);
          continue;
        }
        try {
          extra = typeof options.options === "function" ? options.options(job) : (options.options ?? {});
        } catch (e) {
          trouble(job, `the options callback threw ${threw(e)}`);
          continue;
        }
        failing.delete(job.jobid);
        let name = prefix + base;
        if (used.has(name)) name = `${name}:${job.jobid}`;
        used.add(name);
        const schedule = job.active && recording ? pgCronSchedule(job.schedule) : null;
        let definition: JobOptions = {
          description: `pg_cron job ${job.jobid} in ${job.database} as ${job.username}${job.active ? "" : " (paused)"}`,
          tags: ["pg_cron"],
          ...extra,
          ...(schedule ? { schedule, timezone } : {}),
        };
        try {
          if (declared.get(name) !== keyOf(definition)) {
            const key = keyOf(definition);
            try {
              host.job(name, definition);
            } catch (e) {
              if (!schedule) throw e;
              // A schedule CronWatch cannot read: watch the runs, not the cadence.
              host.onError(new Error(`pg_cron job ${job.jobid}: ${(e as Error).message}; watching it without a schedule`), "source pg_cron");
              const { schedule: _s, timezone: _t, ...rest } = definition;
              definition = rest;
              host.job(name, rest);
            }
            declared.set(name, key);
          }
          names.set(job.jobid, name);
          definitions.set(job.jobid, definition);
        } catch (e) {
          host.onError(e, `source pg_cron: job ${job.jobid}`);
        }
      }

      // A name this source used for a job that has since been renamed, unscheduled or dropped from `jobs`.
      const inUse = new Set(names.values());
      for (const name of inUse) retired.delete(name);
      for (const [jobid, previous] of known) {
        if (inUse.has(previous.name)) continue;
        const renamed = names.get(jobid);
        retire(host, previous.name, previous.definition, renamed ? `renamed to ${renamed}` : "no longer watched");
      }
      known = new Map([...names].map(([jobid, name]) => [jobid, { name, definition: definitions.get(jobid)! }]));
      // Once per process, the same for names left scheduled in the store while no process was watching.
      if (!scanned && rows.length > 0) {
        scanned = true;
        try {
          const visible = new Set(all.map((j) => j.jobid));
          for (const stored of await host.store.listJobs()) {
            const def = stored.definition;
            if (!stored.name.startsWith(prefix) || inUse.has(stored.name) || !def.schedule || !(def.tags ?? []).includes("pg_cron")) continue;
            const match = /^pg_cron job (\d+) in /.exec(def.description ?? "");
            if (!match) continue;
            const jobid = Number(match[1]);
            const current = names.get(jobid);
            if (!visible.has(jobid)) retire(host, stored.name, def, "no longer in cron.job");
            // Another pg_cron source's name for the same job ends the same way: that one is left alone.
            else if (current && !stored.name.endsWith(current.slice(prefix.length))) retire(host, stored.name, def, `renamed to ${current}`);
          }
        } catch (e) {
          host.onError(e, "source pg_cron");
        }
      }
      if (!recording || names.size === 0) return [];

      const alerts: Alert[] = [];
      /** Copies one row. A row that cannot be recorded is reported and skipped; it never stops the others. */
      const record = async (row: DetailRow, evaluate: boolean): Promise<void> => {
        const runid = Number(row.runid);
        const jobid = Number(row.jobid);
        const name = pending.get(runid) ?? names.get(jobid);
        if (!name) {
          held.delete(runid);
          return;
        }
        let run: Run | null;
        if (row.start_time === null && !finishedStatus(row.status)) {
          const since = held.get(runid) ?? now;
          if (now - since < PG_CRON_HOLD_MS) {
            held.set(runid, since);
            return;
          }
          run = pgCronRun({ ...row, start_time: new Date(since) }, name, idPrefix);
        } else {
          run = pgCronRun(row, name, idPrefix, lastAt.get(jobid) ?? now);
        }
        held.delete(runid);
        if (!run) return;
        try {
          alerts.push(...(await host.recordRun(run, { evaluate })));
        } catch (e) {
          host.onError(e, `source pg_cron: run ${runid}`);
          return;
        }
        if (run.status === "running") pending.set(runid, name);
        else pending.delete(runid);
        if (run.startedAt > (lastAt.get(jobid) ?? -Infinity)) lastAt.set(jobid, run.startedAt);
      };

      // Where each job left off. Found from the store the first time, so a restart carries on.
      for (const [jobid, name] of names) {
        if (cursors.has(jobid)) continue;
        const ours = (await host.store.listRuns(name, BACKFILL)).filter((r) => runIdOf(r.id) !== null);
        if (ours.length > 0) {
          cursors.set(jobid, Math.max(...ours.map((r) => runIdOf(r.id)!)));
          lastAt.set(jobid, Math.max(...ours.map((r) => r.startedAt)));
          for (const r of ours) if (r.status === "running" || r.status === "timeout") pending.set(runIdOf(r.id)!, r.job);
          continue;
        }
        // First sight: copy recent history quietly, and judge only from the newest finished run on.
        // The cursor goes to the newest row read, whatever is held, so history is never judged later.
        const { rows: newest } = await db.query(NEWEST_SQL, [jobid]);
        const ordered = (newest as DetailRow[]).slice().reverse();
        let lastFinished = -1;
        ordered.forEach((r, i) => { if (finishedStatus(r.status)) lastFinished = i; });
        for (const [i, row] of ordered.entries()) {
          // Already copied under another name (the job was renamed while no process watched): left there.
          if (await host.store.getRun(`${idPrefix}${row.runid}`)) continue;
          await record(row, i >= lastFinished);
        }
        cursors.set(jobid, ordered.length > 0 ? Number(ordered[ordered.length - 1]!.runid) : 0);
      }

      // New runs, runs copied while still going (or since marked timeout), and runs not yet started.
      const watched = new Set([...names.values(), ...retired]);
      for (const run of await host.store.runningRuns()) {
        const id = runIdOf(run.id);
        if (id !== null && watched.has(run.job)) pending.set(id, run.job);
      }
      const open = new Set([...pending.keys(), ...held.keys()]);
      let complete = false;
      for (let page = 0; page < MAX_PAGES; page++) {
        const jobids = [...names.keys()];
        const { rows: details } = await db.query(RUNS_SQL, [jobids, jobids.map((j) => cursors.get(j) ?? 0), [...open]]);
        for (const row of details as DetailRow[]) {
          const jobid = Number(row.jobid);
          const runid = Number(row.runid);
          open.delete(runid);
          await record(row, true);
          // Held or not, the cursor moves on: a held run is read again by its runid.
          if (names.has(jobid) && runid > (cursors.get(jobid) ?? 0)) cursors.set(jobid, runid);
        }
        if (details.length < PAGE) {
          complete = true;
          break;
        }
      }
      // Every row was read and these were not among them: pg_cron no longer has them.
      if (complete) {
        for (const runid of open) {
          pending.delete(runid);
          held.delete(runid);
        }
      }
      return alerts;
    },
  };
}
