import { stripJsonNul, stripNul } from "../output.js";
import type { JobState, Run, StoredJob, StoredJobDefinition } from "../types.js";

/**
 * The schema, statements and row mapping shared by the SQLite and Postgres
 * stores. Imports no driver, so either entry point can pull it in alone.
 * Statements are written with `?` placeholders; Postgres numbers them.
 */

export type Dialect = "sqlite" | "postgres";

export const DEFAULT_PREFIX = "cronwatch_";

// Postgres truncates identifiers past 63 bytes; the longest name we build is the prefix plus "runs_job_started".
const MAX_PREFIX = 63 - "runs_job_started".length;

/**
 * Table names are built from the prefix, so it must be a plain lowercase
 * identifier. Uppercase is refused rather than folded: Postgres lowercases
 * unquoted names, so "Monitoring_" would quietly become "monitoring_".
 */
export function tablePrefix(prefix: string = DEFAULT_PREFIX): string {
  if (!/^[a-z_][a-z0-9_]*$/.test(prefix) || prefix.length > MAX_PREFIX) {
    throw new Error(
      `cronwatch: invalid table prefix ${JSON.stringify(prefix)}. Use lowercase letters, digits and underscores, ` +
        `not starting with a digit, at most ${MAX_PREFIX} characters.`,
    );
  }
  return prefix;
}

export function schema(dialect: Dialect, p: string): string {
  const pg = dialect === "postgres";
  const int = pg ? "BIGINT" : "INTEGER";
  const json = pg ? "JSONB" : "TEXT";
  return `
    CREATE TABLE IF NOT EXISTS ${p}jobs (
      name TEXT PRIMARY KEY,
      definition ${json} NOT NULL,
      created_at ${int} NOT NULL,
      updated_at ${int} NOT NULL
    );
    CREATE TABLE IF NOT EXISTS ${p}runs (${pg ? "\n      seq BIGSERIAL," : ""}
      id TEXT PRIMARY KEY,
      job TEXT NOT NULL,
      status TEXT NOT NULL,
      started_at ${int} NOT NULL,
      finished_at ${int},
      duration_ms ${int},
      error TEXT,
      output TEXT,
      metrics ${json} NOT NULL DEFAULT '{}',
      trigger TEXT NOT NULL DEFAULT 'run'
    );
    CREATE INDEX IF NOT EXISTS ${p}runs_job_started ON ${p}runs (job, started_at DESC);
    CREATE INDEX IF NOT EXISTS ${p}runs_running ON ${p}runs (status) WHERE status = 'running';
    CREATE TABLE IF NOT EXISTS ${p}state (
      job TEXT PRIMARY KEY,
      state ${json} NOT NULL
    );
  `;
}

export function statements(dialect: Dialect, p: string) {
  const pg = dialect === "postgres";
  // Insertion order, to break ties between runs that started in the same millisecond.
  const seq = pg ? "seq" : "rowid";
  // Byte order on both, so names sort the same whatever the database's collation.
  const byName = pg ? `name COLLATE "C"` : "name";
  // The version inside a state's JSON, as stateVersion() reads it: a whole
  // number from 0 to 2^53 - 1, else 0 (none, or a foreign row's 1.5 or "x",
  // which must neither fail the statement nor refuse every write for good).
  // Each CASE tests the JSON type before any cast.
  const version = (column: string) => {
    if (pg) {
      const v = `(${column}->>'version')::numeric`;
      return `CASE WHEN jsonb_typeof(${column}->'version') <> 'number' THEN 0 WHEN ${v} % 1 = 0 AND ${v} BETWEEN 0 AND 9007199254740991 THEN ${v}::bigint ELSE 0 END`;
    }
    const v = `json_extract(${column}, '$.version')`;
    return `CASE WHEN json_type(${column}, '$.version') NOT IN ('integer', 'real') THEN 0 WHEN ${v} = CAST(${v} AS INTEGER) AND ${v} BETWEEN 0 AND 9007199254740991 THEN CAST(${v} AS INTEGER) ELSE 0 END`;
  };
  const sql = {
    upsertJob: `INSERT INTO ${p}jobs (name, definition, created_at, updated_at) VALUES (?, ?, ?, ?)
      ON CONFLICT (name) DO UPDATE SET definition = excluded.definition, updated_at = excluded.updated_at`,
    getJob: `SELECT * FROM ${p}jobs WHERE name = ?`,
    listJobs: `SELECT * FROM ${p}jobs ORDER BY ${byName}`,
    deleteRuns: `DELETE FROM ${p}runs WHERE job = ?`,
    deleteState: `DELETE FROM ${p}state WHERE job = ?`,
    deleteJob: `DELETE FROM ${p}jobs WHERE name = ?`,
    insertRun: `INSERT INTO ${p}runs (id, job, status, started_at, finished_at, duration_ms, error, output, metrics, trigger)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    updateRun: `UPDATE ${p}runs SET status = ?, finished_at = ?, duration_ms = ?, error = ?, output = ?, metrics = ? WHERE id = ?`,
    getRun: `SELECT * FROM ${p}runs WHERE id = ?`,
    listRuns: `SELECT * FROM ${p}runs WHERE job = ? ORDER BY started_at DESC, ${seq} DESC LIMIT ?`,
    runningRuns: `SELECT * FROM ${p}runs WHERE status = 'running' ORDER BY started_at, ${seq}`,
    getState: `SELECT state FROM ${p}state WHERE job = ?`,
    setState: `INSERT INTO ${p}state (job, state) VALUES (?, ?) ON CONFLICT (job) DO UPDATE SET state = excluded.state`,
    // compareAndSetState. Expecting version 0 also matches a missing row, so
    // that case inserts; any other version must find its row.
    casInsert: `INSERT INTO ${p}state (job, state) VALUES (?, ?)
      ON CONFLICT (job) DO UPDATE SET state = excluded.state WHERE ${version(`${p}state.state`)} = 0`,
    casUpdate: `UPDATE ${p}state SET state = ? WHERE job = ? AND ${version("state")} = ?`,
    // Each job's newest run is kept whatever its age: without it, a job that
    // runs less often than the retention looks like it never ran.
    prune: `DELETE FROM ${p}runs WHERE status <> 'running' AND started_at < ?
      AND started_at < (SELECT MAX(r.started_at) FROM ${p}runs r WHERE r.job = ${p}runs.job)`,
  };
  if (pg) {
    for (const key of Object.keys(sql) as (keyof typeof sql)[]) {
      let n = 0;
      sql[key] = sql[key].replace(/\?/g, () => `$${++n}`);
    }
  }
  return sql;
}

/**
 * updateRunIf: the update above, only while the stored status is one of
 * `count` statuses. Built per count, since the list is bound value by value.
 */
export function updateRunIfSql(dialect: Dialect, p: string, count: number): string {
  const text = `UPDATE ${p}runs SET status = ?, finished_at = ?, duration_ms = ?, error = ?, output = ?, metrics = ? WHERE id = ? AND status IN (${Array.from({ length: count }, () => "?").join(", ")})`;
  if (dialect !== "postgres") return text;
  let n = 0;
  return text.replace(/\?/g, () => `$${++n}`);
}

/**
 * Postgres refuses U+0000 in TEXT and JSONB, and a refused write loses the
 * whole row, so every dialect writes text without it: a run's trigger,
 * output, error and metric names, and every key and string of a definition
 * and a state. Identifiers (a job's name, a run's id) are written as given;
 * the client refuses one with a NUL before it gets here.
 */
const text = (value: string | null) => (value === null ? null : stripNul(value));
const jsonText = (value: unknown) => stripJsonNul(JSON.stringify(value));

// Parameters in statement order, so both drivers bind the same values.
export const params = {
  upsertJob: (definition: StoredJobDefinition, now: number) => [definition.name, jsonText(definition), now, now],
  insertRun: (run: Run) => [
    run.id, run.job, run.status, run.startedAt, run.finishedAt, run.durationMs, text(run.error), text(run.output), jsonText(run.metrics), stripNul(run.trigger),
  ],
  updateRun: (run: Run) => [run.status, run.finishedAt, run.durationMs, text(run.error), text(run.output), jsonText(run.metrics), run.id],
  updateRunIf: (run: Run, fromStatuses: Run["status"][]) => [
    run.status, run.finishedAt, run.durationMs, text(run.error), text(run.output), jsonText(run.metrics), run.id, ...fromStatuses,
  ],
  setState: (state: JobState) => [state.job, jsonText(state)],
  casInsert: (state: JobState) => [state.job, jsonText(state)],
  casUpdate: (state: JobState, expectedVersion: number) => [jsonText(state), state.job, expectedVersion],
};

// SQLite hands back JSON as TEXT and Postgres as parsed JSONB; Postgres returns BIGINT as a string.
type Json<T> = T | string;
type Int = number | string;

export interface JobRow { name: string; definition: Json<StoredJobDefinition>; created_at: Int; updated_at: Int }
export interface RunRow {
  id: string; job: string; status: Run["status"]; started_at: Int; finished_at: Int | null;
  duration_ms: Int | null; error: string | null; output: string | null; metrics: Json<Record<string, number>> | null; trigger: string;
}
export interface StateRow { state: Json<JobState> }

const json = <T>(v: Json<T>): T => (typeof v === "string" ? (JSON.parse(v) as T) : v);
const num = (v: Int | null): number | null => (v === null ? null : Number(v));

export function rowToJob(r: JobRow): StoredJob {
  return { name: r.name, definition: json(r.definition), createdAt: Number(r.created_at), updatedAt: Number(r.updated_at) };
}

export function rowToRun(r: RunRow): Run {
  return {
    id: r.id, job: r.job, status: r.status, startedAt: Number(r.started_at), finishedAt: num(r.finished_at),
    durationMs: num(r.duration_ms), error: r.error, output: r.output, metrics: r.metrics === null ? {} : json(r.metrics), trigger: r.trigger,
  };
}

export function rowToState(r: StateRow): JobState {
  return json(r.state);
}
