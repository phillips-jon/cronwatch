---
title: Stores
description: Memory, SQLite and Postgres stores, retention, and the interface for writing your own.
order: 7
---

# Stores

A store keeps three things: job definitions, runs, and per-job state (open conditions, consecutive failures, silence). All three stores are drop-in.

## Memory

The default when no store is given. Nothing persists across a restart, so a miss cannot be noticed across one. Good for tests and first tries.

```ts
import { memory } from "@cronwatch/sdk";
cronwatch({ store: memory() });
```

## SQLite

One file through `better-sqlite3`, in WAL mode with a five second busy timeout. Several processes opening a new file at once can find it busy while one of them switches it to WAL; opening retries that for up to two seconds, and a failed open is started afresh on the next use. The directory is created if missing. The database file is created with mode 0600 before SQLite opens it, and SQLite gives its `-wal` and `-shm` files the same mode, so the whole set is readable only by the process's user where the filesystem allows; files left by an earlier open are set to 0600 too. Version 13 of the driver needs Node 22 or newer; older majors work with the same adapter.

```ts
import { sqlite } from "@cronwatch/sdk/sqlite";
cronwatch({ store: sqlite({ path: "./data/cronwatch.db" }) });
// or reuse an open database:
cronwatch({ store: sqlite({ database: existingDb }) });
```

The three tables are named `cronwatch_jobs`, `cronwatch_runs` and `cronwatch_state`. Pass `prefix` to change `cronwatch_`, for example to keep them apart from your own tables in a shared database. The same rules apply as for Postgres below.

Keep the file outside your build output and inside whatever path the process may write to. With Next.js, add `**/*.db` to `outputFileTracingExcludes` so a build never copies it.

## Postgres

Through the `pg` driver. Three tables are created on first use, prefixed `cronwatch_`, with times stored as BIGINT epoch milliseconds and definitions, metrics and state as JSONB.

```ts
import { postgres } from "@cronwatch/sdk/postgres";
cronwatch({ store: postgres({ connectionString: process.env.DATABASE_URL }) });
// or share a pool (not closed by cw.close()):
cronwatch({ store: postgres({ pool, prefix: "monitoring_" }) });
```

`connectionString` defaults to `DATABASE_URL`.

A `prefix` must be a plain lowercase identifier: lowercase letters, digits and underscores, not starting with a digit, at most 47 characters. Anything else throws when the store is created rather than being changed quietly. Uppercase is refused because Postgres folds unquoted names to lowercase, so `Monitoring_` would become `monitoring_` behind your back.

The tables are created inside a transaction that holds an advisory lock for the prefix, so many instances starting at once (serverless cold starts, several replicas) take turns instead of racing `CREATE TABLE IF NOT EXISTS`.

## Retention

Finished runs older than `retention` (default `30d`) are deleted by `check()`, at most once an hour. Pruning happens only there: recording runs never deletes anything, so an app that never checks (no `cw.start()`, no cron hitting the check endpoint, no `cw.check()` of its own) keeps every run until something does. Running rows are never pruned, and neither is each job's newest run, so a job that runs less often than the retention is not mistaken for one that never ran.

```ts
cronwatch({ retention: "90d" });
```

## Writing a store

Implement the interface and pass it in. Every method is async; `init` runs once before first use.

```ts
interface Store {
  init?(): Promise<void>;
  upsertJob(definition: StoredJobDefinition, now: number): Promise<void>;   // keep createdAt on update
  getJob(name: string): Promise<StoredJob | null>;
  listJobs(): Promise<StoredJob[]>;                                         // by name, code unit order
  deleteJob(name: string): Promise<void>;                                   // and its runs and state
  insertRun(run: Run): Promise<void>;
  updateRun(run: Run): Promise<void>;                                       // no-op if the run is gone
  getRun(id: string): Promise<Run | null>;
  listRuns(job: string, limit: number): Promise<Run[]>;                     // newest first
  lastRun(job: string): Promise<Run | null>;
  runningRuns(): Promise<Run[]>;                                            // oldest first
  getState(job: string): Promise<JobState | null>;
  setState(state: JobState): Promise<void>;                                 // unconditional; used only without compareAndSetState
  compareAndSetState?(state: JobState, expectedVersion: number): Promise<boolean>;  // see below
  prune(before: number): Promise<number>;                                   // finished runs started before this, except each job's newest
  close?(): Promise<void>;
}
```

`compareAndSetState` writes `state` only when the stored state's `version` equals `expectedVersion`, and says whether it wrote. A missing row, or a stored state with no `version`, counts as version 0. It is optional so that stores written for earlier versions keep working: without it the client falls back to `setState`, which is safe only when one process at a time updates a job's state (see below). Implement it if your store may be shared.

## Two processes, one store

Any number of processes may share one store: web servers, workers, a `deliver: "check"` recorder, the Ruby gem. A job's state (open conditions, consecutive failures, silence, queued alerts) is read, changed and written back on every run start and finish, check, delivery and silence, so two processes doing that at the same moment could each overwrite the other's change: a failure not counted, a condition that never opened, a silence undone.

To prevent that the state carries a `version`, inside its JSON, that goes up by one on every write. A write goes through only if the version is still the one read (`compareAndSetState`); otherwise the client reads the state again, works the change out afresh and retries, up to ten times, before reporting to `onError`. Within one process updates to a job also wait their turn, so the retries are only ever between processes. Nothing is written when a change leaves the state as it was.

The built-in stores do this with one conditional statement and no schema change: SQLite compares `json_extract(state, '$.version')`, Postgres `(state->>'version')::bigint`, each treating a missing version as 0; expecting 0 is an upsert, so the first write for a job inserts its row. The Ruby gem's ActiveRecord store reads and writes the same three tables with the same bytes (the same JSON, the same `version`), so a Rails app and a Node service can share one database and keep each other's updates.

The three built-in stores pass the same conformance test, in [`packages/sdk/test/stores.test.ts`](https://github.com/phillips-jon/cronwatch/blob/main/packages/sdk/test/stores.test.ts) in the repository. It is not shipped in the npm package; copy it from there to check your own store.
