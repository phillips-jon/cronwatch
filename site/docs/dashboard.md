---
title: Dashboard and API
description: The routes, the token, the endpoints and the JSON shapes the MCP server reads.
order: 8
---

# Dashboard and API

`cw.routes()` returns fetch-style handlers for a dashboard and a JSON API. They are the same handler; `GET`, `POST` and `DELETE` are aliases so a Next.js route file can export them directly.

```ts
export const { GET, POST, DELETE } = cw.routes({ token: process.env.CRONWATCH_TOKEN, basePath: "/cronwatch" });
```

`basePath` defaults to `/cronwatch` and is only used to build links. `token` defaults to `CRONWATCH_TOKEN`.

## Access

Every request needs the token, as `Authorization: Bearer <token>`, or as a `?token=` query once for the dashboard, after which an HttpOnly cookie keeps you signed in for thirty days. Comparison is constant-time.

With no token configured, the routes are open when `NODE_ENV` is not `production` and answer 503 when it is.

The check endpoint additionally accepts the client's `cronSecret` as a bearer, so a platform cron can call it.

The token grants everything, including silencing and forgetting jobs. Treat it like a password.

## Pages

| Path | What |
|---|---|
| `/` | every job: health, schedule, last run, next due, durations |
| `/jobs/:name` | one job: definition, stats, and the last fifty runs with errors, output and metrics |

Pages refresh every minute and are marked `noindex`.

## Endpoints

| Method and path | Does | Returns |
|---|---|---|
| `GET /api/jobs` | list jobs | `{ jobs: JobSummary[] }` |
| `GET /api/jobs/:name?runs=20` | one job with recent runs | `{ job: JobSummary, runs: Run[] }` |
| `DELETE /api/jobs/:name` | forget the job and its runs | `{ ok: true }` |
| `POST /api/jobs/:name/silence` | body `{ "for": "2h" }` | `{ state: JobState }` |
| `POST /api/jobs/:name/unsilence` | | `{ state: JobState }` |
| `GET or POST /api/check` | run the check now | `{ checkedAt, jobs, alerts, pruned }` |
| `GET /api/runs/:id` | one run | `{ run: Run }` |

Errors are `{ ok: false, error }` with 401, 404 or 503.

## JobSummary

```ts
interface JobSummary {
  name: string;
  definition: StoredJobDefinition;
  health: "healthy" | "late" | "failing" | "stuck" | "silenced" | "never_ran";
  open: Condition[];              // conditions currently open
  lastRun: Run | null;
  nextExpectedAt: number | null;  // epoch ms
  consecutiveFailures: number;
  silencedUntil: number | null;
  stats: { runs: number; okRate: number; p50Ms: number | null; p95Ms: number | null };
}
```

## Run

```ts
interface Run {
  id: string;
  job: string;
  status: "running" | "ok" | "failed" | "timeout";
  startedAt: number;
  finishedAt: number | null;
  durationMs: number | null;
  error: string | null;
  output: string | null;          // capped at 16 KB, tail kept
  metrics: Record<string, number>;
  trigger: string;                // "handler", "run", or what you passed
}
```
