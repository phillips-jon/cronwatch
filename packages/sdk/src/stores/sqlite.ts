import Database from "better-sqlite3";
import { chmodSync, closeSync, mkdirSync, openSync } from "node:fs";
import path from "node:path";
import type { Store, StoredJob, StoredJobDefinition } from "../types.js";
import { params, rowToJob, rowToRun, rowToState, schema, statements, tablePrefix, type JobRow, type RunRow, type StateRow } from "./sql.js";

export interface SqliteOptions {
  /** File path. The directory is created if missing. ":memory:" works too. */
  path?: string;
  /** Bring your own open better-sqlite3 database instead. */
  database?: Database.Database;
  /** Table name prefix: lowercase letters, digits and underscores. Default "cronwatch_". */
  prefix?: string;
}

/**
 * Keeps everything in one SQLite file through better-sqlite3. The right
 * choice for a single server. WAL mode, so the app's reads never block on a
 * run being written.
 */
export function sqlite(options: SqliteOptions = {}): Store {
  const p = tablePrefix(options.prefix);
  const sql = statements("sqlite", p);
  let db: Database.Database | null = options.database ?? null;
  const file = options.path ?? "./data/cronwatch.db";
  const cache = new Map<string, Database.Statement>();

  const open = (): Database.Database => {
    if (db) return db;
    const onDisk = file !== ":memory:" && file !== "";
    if (onDisk) {
      mkdirSync(path.dirname(file), { recursive: true });
      // Create the file private before SQLite opens it. SQLite gives the -wal and -shm files the
      // main file's mode, so the whole set stays 0600; the chmods cover files left by an earlier open.
      try {
        closeSync(openSync(file, "a", 0o600));
        for (const f of [file, `${file}-wal`, `${file}-shm`]) {
          try { chmodSync(f, 0o600); } catch { /* the sidecar may not exist yet */ }
        }
      } catch { /* best effort: not every filesystem cares */ }
    }
    db = new Database(file);
    db.pragma("journal_mode = WAL");
    db.pragma("busy_timeout = 5000");
    db.pragma("synchronous = NORMAL");
    return db;
  };

  // Each statement is prepared once per open database.
  const stmt = (text: string): Database.Statement => {
    let s = cache.get(text);
    if (!s) {
      s = open().prepare(text);
      cache.set(text, s);
    }
    return s;
  };

  const forget = (name: string) => {
    stmt(sql.deleteRuns).run(name);
    stmt(sql.deleteState).run(name);
    stmt(sql.deleteJob).run(name);
  };

  return {
    async init() {
      open().exec(schema("sqlite", p));
    },
    async upsertJob(definition: StoredJobDefinition, now: number) {
      stmt(sql.upsertJob).run(...params.upsertJob(definition, now));
    },
    async getJob(name) {
      const r = stmt(sql.getJob).get(name) as JobRow | undefined;
      return r ? rowToJob(r) : null;
    },
    async listJobs(): Promise<StoredJob[]> {
      return (stmt(sql.listJobs).all() as JobRow[]).map(rowToJob);
    },
    async deleteJob(name) {
      open().transaction(forget)(name);
    },
    async insertRun(run) {
      stmt(sql.insertRun).run(...params.insertRun(run));
    },
    async updateRun(run) {
      stmt(sql.updateRun).run(...params.updateRun(run));
    },
    async getRun(id) {
      const r = stmt(sql.getRun).get(id) as RunRow | undefined;
      return r ? rowToRun(r) : null;
    },
    async listRuns(job, limit) {
      return (stmt(sql.listRuns).all(job, limit) as RunRow[]).map(rowToRun);
    },
    async lastRun(job) {
      const r = stmt(sql.listRuns).get(job, 1) as RunRow | undefined;
      return r ? rowToRun(r) : null;
    },
    async runningRuns() {
      return (stmt(sql.runningRuns).all() as RunRow[]).map(rowToRun);
    },
    async getState(job) {
      const r = stmt(sql.getState).get(job) as StateRow | undefined;
      return r ? rowToState(r) : null;
    },
    async setState(state) {
      stmt(sql.setState).run(...params.setState(state));
    },
    async prune(before) {
      return stmt(sql.prune).run(before).changes;
    },
    async close() {
      cache.clear();
      if (db && !options.database) {
        db.close();
        db = null;
      }
    },
  };
}
