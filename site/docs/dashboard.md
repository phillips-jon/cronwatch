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

`basePath` defaults to `/cronwatch` and must match where the routes are mounted: it routes requests, builds links and scopes the cookie path. `token` defaults to `CRONWATCH_TOKEN`; an empty string counts as unset.

## Access

Every request needs the token, as `Authorization: Bearer <token>` or as the cookie the dashboard sets. Comparison is constant-time.

To sign in to the dashboard, open any page once with `?token=<token>`. The response moves it into an HttpOnly cookie that lasts thirty days (holding a digest of the token, not the token) and redirects to the same URL without it. `?token=` is read only there, on a `GET` of a page; the JSON API and every `POST` or `DELETE` ignore it, so use the bearer header or the cookie.

With no token configured while `NODE_ENV` is `development` or `test`, the routes make one: 32 random bytes, new each time the routes are created (so each dev server restart or reload signs you out). On the first request they print a sign-in link to the server log, once:

```text
[cronwatch] CRONWATCH_TOKEN is not set, so this development server made a token for the dashboard. Sign in: http://localhost:3000/cronwatch/?token=...
```

The link is built from the origin of that first request and the base path. Open it and the cookie is set as with any token. Until then every request answers 401, and the page says the link is in the server log. Nothing about the request itself lets it in: a fetch handler cannot tell a caller on this machine from one elsewhere (Next.js keeps an `X-Forwarded-For` the client sent, `next dev` listens on every interface, and tunnels rewrite `Host`), so the log, which only you can read, is the proof. With no token and `NODE_ENV` anything else, or unset, the routes answer 503.

Pass `token: null` to serve them open everywhere, for example when the mount already sits behind your own auth:

```ts
// app/admin/cronwatch/[[...path]]/route.ts: your guard is the lock
import { requireAdmin } from "@/lib/auth";
import { cw } from "@/lib/cronwatch";

const routes = cw.routes({ token: null, basePath: "/admin/cronwatch" });
const guarded = (handler: (request: Request) => Promise<Response>) => async (request: Request) => {
  await requireAdmin(); // throws or redirects when the viewer is not allowed
  return handler(request);
};

export const GET = guarded(routes.GET);
export const POST = guarded(routes.POST);
export const DELETE = guarded(routes.DELETE);
```

The cross-site checks below still apply to requests that pass your guard.

The check endpoint additionally accepts the client's `cronSecret` as a bearer, so a platform cron can call it.

The token grants everything, including silencing and forgetting jobs. Treat it like a password.

## Cross-site requests

A `POST` or `DELETE` is refused with 403 when it carries an `Origin` header that is not the request's own origin, or a `Sec-Fetch-Site` header other than `same-origin` or `none`. Browsers send these on every form post, so another site cannot use a signed-in cookie to silence or forget a job. Scripts, crons and the MCP server send neither and are unaffected. If the app sits behind a proxy, make sure the request URL it sees carries the public host and scheme, or same-origin posts from the dashboard will look foreign.

`GET /api/check` runs the check only when the request has an `Authorization` bearer (the token or the cron secret), which a page on another site cannot add. Signed in with the cookie, use `POST /api/check`; a cookie `GET` answers 405. The dashboard's "Run check now" button posts, so it is unaffected.

Pages are served with a Content Security Policy that allows no scripts, frames or outside origins, plus `X-Frame-Options: DENY`, `Referrer-Policy: same-origin` and `X-Content-Type-Options: nosniff`. JSON responses carry `nosniff` and `Cache-Control: no-store`.

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
| `GET /api/jobs/:name?runs=20` | one job with recent runs (`runs` is 1 to 500) | `{ job: JobSummary, runs: Run[] }` |
| `DELETE /api/jobs/:name` | forget the job and its runs | `{ ok: true }` |
| `POST /api/jobs/:name/silence` | body `{ "for": "2h" }` | `{ state: JobState }` |
| `POST /api/jobs/:name/unsilence` | | `{ state: JobState }` |
| `POST /api/check` | run the check now | `{ checkedAt, jobs, alerts, pruned }` |
| `GET /api/check` | the same, with a bearer only | `{ checkedAt, jobs, alerts, pruned }` |
| `GET /api/runs/:id` | one run | `{ run: Run }` |

`for` is a duration string such as `"30m"`, `"2h"` or `"1h30m"`, or a number of milliseconds (a JSON number or a string of digits). It defaults to one hour when left out, from the body or a `?for=` query. Anything else, such as `"forever"` or `"2 hours"`, is refused with 400 and the reason, and nothing is silenced. The dashboard's silence form shows the same error as a page. Silencing or unsilencing a job that is not in the store answers 404.

Errors are `{ ok: false, error }` with 400, 401, 403, 404, 405 or 503. An unexpected failure answers a bare 500 (`"Internal error"`, or a plain page) and the error itself goes to the client's `onError`.

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

A job CronWatch cannot evaluate, for example one whose stored schedule or timeout no longer parses, shows as `failing` (or `silenced` while it is) with `nextExpectedAt: null`, and the reason goes to `onError`. Every other job is listed and checked as usual.

The `state` the silence endpoints return is the job's stored `JobState`, including its `version`, which goes up by one on every write (see [stores](/docs/stores/#two-processes-one-store)).

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
