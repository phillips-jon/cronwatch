---
title: Dashboard and API
description: The routes, the token, the endpoints and the JSON shapes the MCP server reads.
order: 8
group: Reference
---

# Dashboard and API

`cw.routes()` returns fetch-style handlers for a dashboard and a JSON API. They are the same handler; `GET`, `POST` and `DELETE` are aliases so a Next.js route file can export them directly.

```ts
export const { GET, POST, DELETE } = cw.routes({ token: process.env.CRONWATCH_TOKEN, basePath: "/cronwatch" });
```

`basePath` defaults to `/cronwatch` and must match where the routes are mounted: it routes requests, builds links and scopes the cookie path. `token` defaults to `CRONWATCH_TOKEN`; an empty string counts as unset.

Every port serves the same pages and API at the same paths, with the same token rules, so everything below holds for them too: see [Rails](/docs/rails/#mount-the-dashboard), [Ruby](/docs/ruby/#the-dashboard-in-any-rack-app), [Django](/docs/django/#mount-the-dashboard), [Python](/docs/python/#the-dashboard), [PHP](/docs/php/#the-dashboard), [Go](/docs/go/#the-dashboard), [Rust](/docs/rust/#the-dashboard), [Elixir](/docs/elixir/#the-dashboard), [Java](/docs/java/#the-dashboard) and [.NET](/docs/dotnet/#the-dashboard) for how each mounts it.

## Access

Every request needs the token, as `Authorization: Bearer <token>` or as the cookie the dashboard sets. Comparison is constant-time.

To sign in to the dashboard, open any page once with `?token=<token>`, or paste the token into the form on the sign-in page (it sends the same `?token=`). The response moves it into an HttpOnly cookie that lasts thirty days (holding a digest of the token, not the token) and redirects to the same URL without it. `?token=` is read only there, on a `GET` of a page; the JSON API and every `POST` or `DELETE` ignore it, so use the bearer header or the cookie.

With no token configured [in development](#development), the routes make one: 32 random bytes, new each time the routes are created (so each dev server restart or reload signs you out). On the first request they print a sign-in link to the server log, once:

```text
[cronwatch] CRONWATCH_TOKEN is not set, so this development server made a token for the dashboard. Sign in: http://localhost:3000/cronwatch/?token=...
```

The link is built from `origin` when it is set, and otherwise from the origin of that first request (the forwarded one under [`trustProxy`](#behind-a-proxy)), and the base path. That origin comes from the request's `Host` or `X-Forwarded-Host`, which a client controls, so without `origin` the host is printed only when it is loopback (`localhost`, a name ending in `.localhost`, `127.0.0.0/8` or `::1`). For any other host the line leaves it out, and a spoofed first request cannot point the link, token and all, at a host of its choosing:

```text
[cronwatch] CRONWATCH_TOKEN is not set, so this development server made a token for the dashboard. Sign in: /cronwatch/?token=... on this server (the first request's host is not local, so the link leaves it out)
```

Open it and the cookie is set as with any token. Until then every request answers 401, and the page says the link is in the server log. Nothing about the request itself lets it in: a fetch handler cannot tell a caller on this machine from one elsewhere (Next.js keeps an `X-Forwarded-For` the client sent, `next dev` listens on every interface, and tunnels rewrite `Host`), so the log, which only you can read, is the proof. With no token outside development, the routes answer 503.

### Development

Whether the app is in development decides two things: the routes make a token of their own when none is set (above), and a job's `handler()` runs without a `CRON_SECRET`. Every CronWatch library reads it the same way. The environment is the first of `CRONWATCH_ENV`, `APP_ENV` and `NODE_ENV` that is set to more than spaces, trimmed and lowercased; `development`, `dev`, `local`, `test` and `testing` are development, and `production` and `prod` are production (which only makes the default in-memory store warn that it forgets on restart). With none of them set the app is not in development, which is the safe reading. The other languages read `CRONWATCH_ENV` and `APP_ENV` first too, then their own convention in place of `NODE_ENV`.

So `CRONWATCH_ENV=production` keeps a `next dev` server, or a test run, from making a token or running handlers without a secret, and `CRONWATCH_ENV=development` turns development on where `NODE_ENV` cannot be changed. An `APP_ENV` set for another tool counts too: `APP_ENV=local` with `NODE_ENV=production` is development.

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

The cross-site checks below still apply to requests that pass your guard. To keep the dashboard [installable](#install-it-as-an-app), let the app shell paths (`/manifest.webmanifest`, `/icons/...`, `/sw.js`, `/app.js` and `/offline` under the base) through the guard: browsers fetch the manifest and icons without cookies, and none of them says anything about your jobs.

The check endpoint additionally accepts the client's `cronSecret` as a bearer, so a platform cron can call it.

The token grants everything, including silencing and forgetting jobs. Treat it like a password.

## Cross-site requests

A `POST` or `DELETE` is refused with 403 when it carries an `Origin` header that is not the request's own origin, or a `Sec-Fetch-Site` header other than `same-origin` or `none`. Browsers send these on every form post, so another site cannot use a signed-in cookie to silence or forget a job. Scripts, crons and the MCP server send neither and are unaffected. The request's own origin is the request URL's, unless the app sits [behind a proxy](#behind-a-proxy) and says otherwise.

`GET /api/check` runs the check only when the request has an `Authorization` bearer (the token or the cron secret), which a page on another site cannot add. Signed in with the cookie, use `POST /api/check`; a cookie `GET` answers 405. The dashboard's "Run check now" button posts, so it is unaffected.

Pages are served with a Content Security Policy that allows no inline script, no frames and no outside origins, plus `X-Frame-Options: DENY`, `Referrer-Policy: same-origin` and `X-Content-Type-Options: nosniff`:

```text
default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; img-src 'self' data:; manifest-src 'self'; worker-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'
```

The one script is `app.js`, which registers the [service worker](#install-it-as-an-app) and does nothing else; the pages work the same without it. Pages and JSON responses carry `Cache-Control: no-store`, and JSON responses `nosniff`.

## Behind a proxy

Behind a proxy or load balancer that terminates TLS, the request URL the app sees often has the internal scheme and host (`http://10.0.0.5:8080`) while the browser is on `https://app.example.com`. The browser's `Origin` then never matches, and every dashboard form is refused as cross-site. Where the framework already builds the request URL with the public origin (SvelteKit's `ORIGIN`, for one), nothing more is needed; otherwise tell the routes the public origin.

```ts
const routes = cw.routes({ basePath: "/cronwatch", origin: "https://app.example.com" });
```

`origin` is used instead of the request URL's origin in three places: the cross-site check on `POST` and `DELETE`, the sign-in redirect (the cookie is marked `Secure` when the origin is `https`, and a form's redirect back follows a `Referer` on this origin), and the development sign-in line printed to the log (which, without `origin`, names the host only when it is loopback). It must be an `http` or `https` URL; only its origin is kept, and anything else throws when the routes are made.

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

Under it is the day. Each job gets a lane across the last 24 hours and the next three, in UTC, drawn with the marks below. Every run the store recorded is a mark as wide as it took, coloured by how it ended.

| Mark | Means |
|---|---|
| a faint tick | a time the job was due, worked out from its schedule with the same code the checks use: for a cron, each time it fires; for an interval, one period after each run started, and once a period after the last one for as long as nothing runs. Ticks still ahead are dashed |
| a dotted line | the cadence of a job due more often than every five minutes, in place of a tick per fire |
| green | a run that ended ok |
| red | a failed run |
| a pale red box | a run that timed out |
| amber | the last run, when it went over budget or ran slow |
| an outline | a run still going (red once it is past its timeout) |
| a dashed red box | the slot the check reported missed, and every later slot whose grace has run out |
| a solid vertical line | now |

The empty part of a lane carries a short note about anything open, such as `due 22:36, nothing ran`, `failed at 03:00, 2 in a row` or `running since 22:40`.

The timeline draws the first thirty jobs and says so when there are more; the table below lists every job. Hovering a mark shows what it was, and a visually hidden list says the same for screen readers. A job page draws the same thing for that job, one lane per UTC day for the last seven days, today first, and reads as many runs as that takes (up to 500).

Times on the pages are UTC: without script a page cannot know your time zone. Pages refresh every minute and are marked `noindex`. They follow the system's light or dark setting, need no JavaScript, and load nothing from anywhere but the dashboard itself. Marks arrive in time order when a page loads and open problems pulse slowly; with reduced motion turned on in the system settings nothing moves.

## Install it as an app

The dashboard is an installable web app: it has a manifest, icons and a small service worker, so a browser can put it on the dock, the desktop or the home screen, where it opens in a window of its own with the header as its bar. It is the same dashboard, reading live from your app; nothing about your jobs is kept on the device.

- **Chrome or Edge on a desktop.** Open the dashboard, signed in, and choose the install icon at the right of the address bar (or the menu's Cast, save and share, then Install page as app). The app shares the browser's cookie, so it is already signed in.
- **Android.** In Chrome, open the dashboard, signed in, then the menu's Add to home screen, then Install. It shares Chrome's cookie too.
- **iPhone and iPad.** In Safari, open the dashboard, then Share, then Add to Home Screen. A home screen app keeps its cookies apart from Safari's, so the first time it opens it shows the sign-in page: paste the token into the form there (a password manager can fill it) and it stays signed in, as a browser does, for thirty days at a time. There is no address bar in the app, so the form, rather than a `?token=` link, is the way in.

The cookie's path is the base path, and the app's scope and start URL are the base path too, so the installed app sends the same cookie as the pages. A token change signs the app out like any browser.

What makes it installable, all under the base path and served without the token, since browsers fetch some of it without cookies and none of it says anything about your jobs:

| Path | What | Cache |
|---|---|---|
| `/manifest.webmanifest` | the manifest (`application/manifest+json`): name, start URL and scope at the base path, standalone display, colours, icons | `no-cache` |
| `/icons/icon.svg`, `/icons/maskable.svg` | the clock on a dark rounded square, and a full square for masks | a year |
| `/icons/icon-192.png`, `/icons/icon-512.png`, `/icons/maskable-512.png` | PNGs for the manifest | a year |
| `/icons/apple-touch-icon.png` | the 180 pixel home screen icon iOS wants | a year |
| `/sw.js` | the service worker, with `Service-Worker-Allowed` set to the base path | `no-cache` |
| `/app.js` | registers the service worker | `no-cache` |
| `/offline` | the page shown when the network is down | `no-cache` |

The service worker keeps only that shell in its cache. Every page, form post and API call goes to the network as the browser made it and is never stored, since they carry job data (and are `no-store` anyway). When a page cannot be reached, it shows the offline page instead: "You are offline. CronWatch shows live data from your app, so it needs a connection." Service workers need a secure origin, so installing works over `https` or on `localhost`; elsewhere the dashboard is simply a web page.

## Endpoints

| Method and path | Does | Returns |
|---|---|---|
| `GET /api` | what is serving the API | `{ ok: true, library, language, version, api: 1 }` |
| `GET /api/jobs` | list jobs | `{ ok: true, jobs: JobSummary[] }` |
| `GET /api/jobs/:name?runs=20` | one job with recent runs (`runs` is 1 to 500) | `{ ok: true, job: JobSummary, runs: Run[] }` |
| `DELETE /api/jobs/:name` | forget the job and its runs | `{ ok: true }` |
| `POST /api/jobs/:name/silence` | body `{ "for": "2h" }` | `{ ok: true, job: JobSummary }` |
| `POST /api/jobs/:name/unsilence` | | `{ ok: true, job: JobSummary }` |
| `POST /api/check` | run the check now | `{ ok: true, checkedAt, jobs, alerts, pruned }` |
| `GET /api/check` | the same, with a bearer only | `{ ok: true, checkedAt, jobs, alerts, pruned }` |
| `GET /api/runs/:id` | one run | `{ ok: true, run: Run }` |

Every success body carries `ok: true` beside its fields.

`GET /api` says what is answering: `library` is the package as its registry names it (`@cronwatch/sdk`, or the port's own, such as `cronwatch` for the gem), `language` the language it is written in (`typescript`, `ruby`, `python`, `php`, `go`, `rust`, `elixir`, `java` or `dotnet`), `version` its release, and `api` the version of this API, now `1`. The API only grows: a later release may add fields and endpoints, but does not remove or retype one, or move a path, without a new `api` number in a major release. So read the fields you need and ignore the rest. [`@cronwatch/mcp`](/docs/mcp/) works with any dashboard that answers this way, and with the 0.x releases before it.

Silence and unsilence answer the job's summary, as `GET /api/jobs/:name` does, with `silencedUntil` set or cleared. Before 1.0 they answered the job's stored state instead (`{ ok: true, state }`); `@cronwatch/mcp` reads either.

`for` is a duration string such as `"30m"`, `"2h"` or `"1h30m"`, at most 64 characters, or a number of milliseconds (a JSON number or a string of digits). It defaults to one hour when left out, from the body or a `?for=` query. Anything else, such as `"forever"` or `"2 hours"`, is refused with 400 and the reason, and nothing is silenced. The dashboard's silence form shows the same error as a page. Silencing or unsilencing a job that is not in the store answers 404.

Errors are `{ ok: false, error }` with 400, 401, 403, 404, 405 or 503. An unexpected failure answers a bare 500 (`"Internal error"`, or a plain page) and the error itself goes to the client's `onError`.

The dashboard's own buttons post HTML forms to paths outside `/api`. They take the cookie or the bearer like everything else, are refused cross-site, and answer with a redirect rather than JSON:

| Method and path | Does | Then |
|---|---|---|
| `POST /check` | run the check now | redirects back to the page it came from (a `Referer` on this origin), or to the board |
| `POST /jobs/:name/silence` | form field `for`, read as above (one hour when left out) | redirects back; a bad `for` is a 400 page saying why |
| `POST /jobs/:name/unsilence` | resume alerts | redirects back |
| `POST /jobs/:name/forget` | forget the job and its runs | redirects to the board |

Silencing or unsilencing a job that is not in the store answers a 404 page here too.

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
  trigger: string;                // "run", "start", "handler", an integration's name, or what you passed
}
```

### Triggers, tags and job names

A run's `trigger` says what started it, and a job's `tags` say where it came from. Both are stored with every run and job, shown on the dashboard and filtered on, so their spellings are part of the stored data and do not change within a major release.

The library's own triggers are `run` (`job.run()`, and each port's decorator or wrapper), `start` (`job.start()`) and `handler` (a job's HTTP handler). An integration that starts runs uses its own name as the trigger, and the integrations that declare jobs tag them with the same name, most adding `<name>:<app>` as well, which tells one app's jobs from another's in a shared store. Integration names are lowercase words joined by hyphens, with one exception: `pg_cron`, the Postgres extension's own name.

| Integration | Trigger | Tags |
|---|---|---|
| pg_cron source (every language) | `pg_cron` | `pg_cron` |
| Rails ActiveJob, Solid Queue, sidekiq-cron | `active-job` | |
| Sidekiq | `sidekiq` | |
| Celery, APScheduler | `celery`, `apscheduler` | |
| Laravel scheduler | `laravel-scheduler` | `laravel-scheduler`, `laravel-scheduler:<app>` |
| Laravel queue | `laravel-queue` | `laravel-queue` |
| Symfony Scheduler | `symfony-scheduler` | `symfony-scheduler`, `symfony-scheduler:<app>` |
| Symfony Messenger | `symfony-messenger` | `symfony-messenger` |
| WordPress | `wp-cron` | `wp-cron` |
| Drupal cron, Drupal queues | `drupal-cron`, `drupal-queue` | the same, and each with `:<site>` |
| Craft CMS queue, console commands | `craft-queue`, `craft-command` | the same; jobs declared in config also `craft-config`, `craft-config:<app>` |
| robfig/cron, gocron, River, Asynq | `robfig-cron`, `gocron`, `river`, `asynq` | the same, and each with `:<app>` |
| tokio-cron-scheduler, apalis | `tokio-cron-scheduler`, `apalis` | the same, and each with `:<app>` |
| Oban, Quantum | `oban`, `quantum` | the same, and each with `:<app>` |
| Spring `@Scheduled`, Quartz, JobRunr | `spring-scheduled`, `quartz`, `jobrunr` | the same, and each with `:<app>` |
| Hangfire, Quartz.NET | `hangfire`, `quartz` | the same, and each with `:<app>` |
| .NET `AddCronwatchJob` | `hosting` | |

Releases before 1.0 wrote a few triggers differently: `active_job`, Laravel's `schedule` and `queue`, Symfony's `scheduler` and `messenger`, Drupal's `cron` and `queue`, Craft's `queue` and `command`, Spring's `scheduled` and .NET's `schedule`. Runs recorded then keep the trigger they were given, which is only a label; every 1.x release reads either spelling where it reads one back, so a filter on the trigger should look for both until those runs age out.

Job names are the app's own, or the scheduler's, as they are. An integration adds a prefix only where the platform's names would otherwise collide with the app's: WordPress hooks become `wp:<hook>`, Drupal's jobs `drupal:<module>` (and `drupal:cron`, `drupal:queue:<id>`), Craft's console commands `craft:<command>`, and a pg_cron job with no name `pg_cron:<jobid>`. Every other integration uses the scheduler's own name for the job. A job's name is its identity in the store, so these never change: renaming one would leave its history behind under the old name.
