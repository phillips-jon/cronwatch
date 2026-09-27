import type { Source, SourceHost } from "../client.js";
import type { Alert, JobOptions, Run } from "../types.js";

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
   */
  jobName?: (job: PgCronJob) => string;
  /** Grace, timeout, maxDuration, expect and the rest, for every job or per job. The schedule always comes from pg_cron. */
  options?: Omit<JobOptions, "schedule" | "timezone"> | ((job: PgCronJob) => Omit<JobOptions, "schedule" | "timezone">);
  /**
   * The timezone pg_cron reads its cron expressions in. Default the server's
   * cron.timezone, which only roles with pg_read_all_settings may read; UTC
   * (pg_cron's default) is assumed when it cannot be read.
   */
  timezone?: string;
}

/** How many of a job's newest runs are copied, without alerting, the first time it is seen. */
const BACKFILL = 20;
/** Run details read per query, and the most read in one sync. */
const PAGE = 500;
const MAX_PAGES = 10;

const JOBS_SQL = `SELECT jobid, jobname, schedule, database, username, active FROM cron.job ORDER BY jobid`;
const COLUMNS = `d.runid, d.jobid, d.status, d.return_message, d.start_time, d.end_time`;
// Every tracked job's runs after its cursor, and any run still open here.
const RUNS_SQL = `SELECT ${COLUMNS}
  FROM cron.job_run_details d
  JOIN unnest($1::bigint[], $2::bigint[]) AS c(jobid, after) ON d.jobid = c.jobid
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

/**
 * pg_cron takes a cron expression, with "$" for the last day of the month,
 * or "N seconds" for 1 to 59 seconds. Returns the CronWatch schedule, or
 * null for one that has no cadence to watch.
 */
export function pgCronSchedule(schedule: string): string | null {
  const text = schedule.trim();
  const seconds = /^(\d+)\s*seconds?$/i.exec(text);
  if (seconds) return `every ${Number(seconds[1])}s`;
  if (/^@reboot$/i.test(text)) return null;
  const fields = text.split(/\s+/);
  if (fields.length === 5 && fields[2]!.includes("$")) fields[2] = fields[2]!.replace(/\$/g, "L");
  return fields.join(" ");
}

/** The default CronWatch name for a pg_cron job, before the prefix. */
export function pgCronJobName(job: Pick<PgCronJob, "jobid" | "jobname">): string {
  const cleaned = (job.jobname ?? "").replace(/[^A-Za-z0-9._:-]+/g, "-").replace(/^[^A-Za-z0-9]+/, "").slice(0, 100);
  return cleaned || `pg_cron:${job.jobid}`;
}

/** A row of cron.job_run_details as a CronWatch run, or null while it has not started. */
export function pgCronRun(row: DetailRow, job: string, idPrefix: string): Run | null {
  if (row.start_time === null) return null;
  const startedAt = new Date(row.start_time).getTime();
  const finishedAt = row.end_time === null ? null : new Date(row.end_time).getTime();
  const message = row.return_message === null ? null : row.return_message.trim() || null;
  const status: Run["status"] = row.status === "succeeded" ? "ok" : row.status === "failed" ? "failed" : "running";
  const done = status !== "running";
  const end = done ? (finishedAt ?? startedAt) : null;
  return {
    id: `${idPrefix}${row.runid}`,
    job,
    status,
    startedAt,
    finishedAt: end,
    durationMs: end === null ? null : Math.max(0, end - startedAt),
    error: status === "failed" ? (message ?? "pg_cron reported the run as failed") : null,
    output: status === "ok" ? message : null,
    metrics: {},
    trigger: "pg_cron",
  };
}

/**
 * Watches pg_cron jobs, which run inside Postgres where nothing can wrap
 * them. As a source, on every check it reads cron.job and declares each job
 * with its schedule, then copies new rows of cron.job_run_details in as runs
 * (ids "pgcron:<runid>"), so the usual evaluation raises missed, failed,
 * stuck and slow alerts.
 *
 *   cronwatch({ store: postgres({ pool }), sources: [pgCron(pool)] }).start();
 */
export function pgCron(db: Queryable, options: PgCronOptions = {}): Source {
  const prefix = options.prefix ?? "";
  const idPrefix = `pgcron:${prefix}`;
  /** The newest runid copied for each jobid, once known. */
  const cursors = new Map<number, number>();
  /** The last definition declared for each name, so an unchanged job is not declared again. */
  const declared = new Map<string, string>();
  const warned = new Set<string>();

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
      const { rows } = await db.query(`SELECT current_setting($1, true) AS value`, [name]);
      return (rows[0]?.value as string | null | undefined) ?? null;
    } catch {
      // Unprivileged roles may not read cron.* settings at all.
      return null;
    }
  };

  const runIdOf = (id: string): number | null => {
    if (!id.startsWith(idPrefix)) return null;
    const n = Number(id.slice(idPrefix.length));
    return Number.isSafeInteger(n) ? n : null;
  };

  return {
    name: "pg_cron",
    async sync(host) {
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
      const jobs = (rows as PgCronJob[])
        .map((r) => ({ ...r, jobid: Number(r.jobid) }))
        .filter(picks);

      // Declare each job. A paused one (active = false) keeps its failures but loses its schedule, so it is not missed.
      const names = new Map<number, string>();
      const used = new Set<string>();
      for (const job of jobs) {
        let name = prefix + (options.jobName ? options.jobName(job) : pgCronJobName(job));
        if (used.has(name)) name = `${name}:${job.jobid}`;
        used.add(name);
        const extra = typeof options.options === "function" ? options.options(job) : (options.options ?? {});
        const schedule = job.active && recording ? pgCronSchedule(job.schedule) : null;
        const definition: JobOptions = {
          description: `pg_cron job ${job.jobid} in ${job.database} as ${job.username}${job.active ? "" : " (paused)"}`,
          tags: ["pg_cron"],
          ...extra,
          ...(schedule ? { schedule, timezone } : {}),
        };
        const key = JSON.stringify(definition, (_k, v: unknown) => (v instanceof RegExp || typeof v === "function" ? String(v) : v));
        try {
          if (declared.get(name) !== key) {
            try {
              host.job(name, definition);
            } catch (e) {
              if (!schedule) throw e;
              // A schedule CronWatch cannot read: watch the runs, not the cadence.
              host.onError(new Error(`pg_cron job ${job.jobid}: ${(e as Error).message}; watching it without a schedule`), "source pg_cron");
              const { schedule: _s, timezone: _t, ...rest } = definition;
              host.job(name, rest);
            }
            declared.set(name, key);
          }
          names.set(job.jobid, name);
        } catch (e) {
          host.onError(e, `source pg_cron: job ${job.jobid}`);
        }
      }
      if (!recording || names.size === 0) return [];

      const alerts: Alert[] = [];
      const record = async (row: DetailRow, evaluate: boolean): Promise<boolean> => {
        const name = names.get(Number(row.jobid));
        if (!name) return true;
        const run = pgCronRun(row, name, idPrefix);
        if (!run) return false;
        alerts.push(...(await host.recordRun(run, { evaluate })));
        return true;
      };

      // Where each job left off. Found from the store the first time, so a restart carries on.
      for (const [jobid, name] of names) {
        if (cursors.has(jobid)) continue;
        const ids = (await host.store.listRuns(name, BACKFILL)).map((r) => runIdOf(r.id)).filter((n): n is number => n !== null);
        if (ids.length > 0) {
          cursors.set(jobid, Math.max(...ids));
          continue;
        }
        // First sight: copy recent history quietly, and judge only from the newest finished run on.
        const { rows: newest } = await db.query(NEWEST_SQL, [jobid]);
        const ordered = (newest as DetailRow[]).slice().reverse();
        let lastFinished = -1;
        ordered.forEach((r, i) => { if (r.status === "succeeded" || r.status === "failed") lastFinished = i; });
        let cursor = 0;
        let held = false;
        for (const [i, row] of ordered.entries()) {
          const copied = await record(row, i >= lastFinished);
          if (!copied) held = true;
          if (!held) cursor = Number(row.runid);
        }
        cursors.set(jobid, cursor);
      }

      // New runs, and runs copied while still going.
      const open = new Set<number>();
      const watched = new Set(names.values());
      for (const run of await host.store.runningRuns()) {
        const id = runIdOf(run.id);
        if (id !== null && watched.has(run.job)) open.add(id);
      }
      for (let page = 0; page < MAX_PAGES; page++) {
        const jobids = [...names.keys()];
        const { rows: details } = await db.query(RUNS_SQL, [jobids, jobids.map((j) => cursors.get(j) ?? 0), [...open]]);
        const heldFrom = new Map<number, number>();
        for (const row of details as DetailRow[]) {
          const jobid = Number(row.jobid);
          const runid = Number(row.runid);
          open.delete(runid);
          const copied = await record(row, true);
          // A run not yet started holds its job's cursor, so it is read again next time.
          if (!copied && !heldFrom.has(jobid)) heldFrom.set(jobid, runid);
          if (!heldFrom.has(jobid) && runid > (cursors.get(jobid) ?? 0)) cursors.set(jobid, runid);
        }
        if (details.length < PAGE || heldFrom.size > 0) break;
      }
      return alerts;
    },
  };
}
