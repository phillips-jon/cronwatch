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

One file through `better-sqlite3`, in WAL mode with a five second busy timeout. The directory is created if missing and the file's mode is set to 0600 where the filesystem allows. Version 13 of the driver needs Node 22 or newer; older majors work with the same adapter.

```ts
import { sqlite } from "@cronwatch/sdk/sqlite";
cronwatch({ store: sqlite({ path: "./data/cronwatch.db" }) });
// or reuse an open database:
cronwatch({ store: sqlite({ database: existingDb }) });
```

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

## Retention

Finished runs older than `retention` (default `30d`) are deleted during a check, at most once an hour. Running rows are never pruned.

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
  listJobs(): Promise<StoredJob[]>;
  deleteJob(name: string): Promise<void>;                                   // and its runs and state
  insertRun(run: Run): Promise<void>;
  updateRun(run: Run): Promise<void>;
  getRun(id: string): Promise<Run | null>;
  listRuns(job: string, limit: number): Promise<Run[]>;                     // newest first
  lastRun(job: string): Promise<Run | null>;
  runningRuns(): Promise<Run[]>;
  getState(job: string): Promise<JobState | null>;
  setState(state: JobState): Promise<void>;
  prune(before: number): Promise<number>;                                   // finished runs started before this
  close?(): Promise<void>;
}
```

The SDK's test suite has a conformance test you can copy; the three built-in stores pass the same one.
