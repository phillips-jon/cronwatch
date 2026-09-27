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

The link is built from the origin of that first request (the [public origin](#behind-a-proxy) when `origin` or `trustProxy` is set) and the base path. Open it and the cookie is set as with any token. Until then every request answers 401, and the page says the link is in the server log. Nothing about the request itself lets it in: a fetch handler cannot tell a caller on this machine from one elsewhere (Next.js keeps an `X-Forwarded-For` the client sent, `next dev` listens on every interface, and tunnels rewrite `Host`), so the log, which only you can read, is the proof. With no token and `NODE_ENV` anything else, or unset, the routes answer 503.

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

A `POST` or `DELETE` is refused with 403 when it carries an `Origin` header that is not the request's own origin, or a `Sec-Fetch-Site` header other than `same-origin` or `none`. Browsers send these on every form post, so another site cannot use a signed-in cookie to silence or forget a job. Scripts, crons and the MCP server send neither and are unaffected. The request's own origin is the request URL's, unless the app sits [behind a proxy](#behind-a-proxy) and says otherwise.

`GET /api/check` runs the check only when the request has an `Authorization` bearer (the token or the cron secret), which a page on another site cannot add. Signed in with the cookie, use `POST /api/check`; a cookie `GET` answers 405. The dashboard's "Run check now" button posts, so it is unaffected.

Pages are served with a Content Security Policy that allows no scripts, frames or outside origins, plus `X-Frame-Options: DENY`, `Referrer-Policy: same-origin` and `X-Content-Type-Options: nosniff`. JSON responses carry `nosniff` and `Cache-Control: no-store`.

## Behind a proxy

Behind a proxy or load balancer that terminates TLS, the request URL the app sees often has the internal scheme and host (`http://10.0.0.5:8080`) while the browser is on `https://app.example.com`. The browser's `Origin` then never matches, and every dashboard form is refused as cross-site. Where the framework already builds the request URL with the public origin (SvelteKit's `ORIGIN`, for one), nothing more is needed; otherwise tell the routes the public origin.

```ts
const routes = cw.routes({ basePath: "/cronwatch", origin: "https://app.example.com" });
```

`origin` is used instead of the request URL's origin in three places: the cross-site check on `POST` and `DELETE`, the sign-in redirect (the cookie is marked `Secure` when the origin is `https`, and a form's redirect back follows a `Referer` on this origin), and the development sign-in line printed to the log. It must be an `http` or `https` URL; only its origin is kept, and anything else throws when the routes are made.

When the proxy sets `X-Forwarded-Proto` and `X-Forwarded-Host`, `trustProxy: true` reads the origin from them instead:

```ts
const routes = cw.routes({ basePath: "/cronwatch", trustProxy: true });
```

The first value of each comma-separated header is used, and whichever header is missing falls back to the request URL's scheme or host. A scheme that is not `http` or `https`, or a host carrying a path or credentials, is ignored. Turn it on only when the proxy sets or overwrites both headers rather than appending to them, because a client can send them too. `origin`, when set, wins over `trustProxy`. With neither, the default, forwarded headers change nothing.

`toNodeHandler` and `toKoaMiddleware` from `@cronwatch/sdk/node` take their own `trustProxy`, which builds the whole request URL from the forwarded headers; see [Express, Koa and plain Node servers](/docs/node/#express-koa-and-plain-node-servers).

## Pages

| Path | What |
|---|---|
| `/` | counts by health, a timeline of the last day, and every job: health, schedule, last run, next due, recent runs |
| `/jobs/:name` | one job: its state and figures, its last seven days, the last fifty runs with errors, output and metrics, and its definition |

The board opens with how many jobs there are and how many need attention (any health but healthy), then a count for each health: failing, stuck, late, healthy, silenced and never ran.

Under it is the day. Each job gets a lane across the last 24 hours and the next three, in UTC. A faint tick marks every time the job was due, worked out from its schedule with the same code the checks use: for a cron, each time it fires; for an interval, one period after each run started, and once a period after the last one for as long as nothing runs. Ticks still ahead are dashed. Every run the store recorded is a mark on top, as wide as it took and coloured by how it ended: green for ok, red for failed, a pale red box for timed out, amber for the last run when it went over budget or ran slow, and an outline for a run still going (red once it is past its timeout). A dashed red box is the slot the check reported missed, and every later slot whose grace has run out. A solid vertical line marks now. The empty part of a lane carries a short note about anything open, such as `due 22:36, nothing ran`, `failed at 03:00, 2 in a row` or `running since 22:40`. A job due more often than every five minutes shows its cadence as a dotted line rather than a tick per fire.

The timeline draws the first thirty jobs and says so when there are more; the table below lists every job. Hovering a mark shows what it was, and a visually hidden list says the same for screen readers. A job page draws the same thing for that job, one lane per UTC day for the last seven days, today first, and reads as many runs as that takes (up to 500).

Times on the pages are UTC: without script a page cannot know your time zone. Pages refresh every minute and are marked `noindex`. They follow the system's light or dark setting, need no JavaScript, and load nothing from anywhere. Marks arrive in time order when a page loads and open problems pulse slowly; with reduced motion turned on in the system settings nothing moves.

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
