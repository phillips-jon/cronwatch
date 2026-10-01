---
title: Getting started
description: Install @cronwatch/sdk, declare a job, wrap it, mount the dashboard and run the first check.
order: 1
---

# Getting started

CronWatch is a library. You install it in the app that runs your scheduled jobs, it records every run in a database you already have, and it alerts when a run is missed, fails, gets stuck, runs slow or goes over budget. There is nothing to sign up for and no server to run.

This page sets up the TypeScript library. Every other language has a port with the same rules, alerts and stored rows, so processes in any of them can share one database:

- **Ruby**: the `cronwatch` gem. See [Ruby on Rails](/docs/rails/) and [Ruby](/docs/ruby/).
- **Python**: `cronwatch-sdk`. See [Django](/docs/django/), [Celery](/docs/celery/) and [Python](/docs/python/).
- **PHP**: `cronwatch/cronwatch`, and a plugin for WordPress. See [PHP](/docs/php/), [WordPress](/docs/wordpress/), [Laravel](/docs/laravel/), [Symfony](/docs/symfony/), [Drupal](/docs/drupal/) and [Craft CMS](/docs/craft/).
- **Go**: `cronwatch.dev/go`, with modules for robfig/cron, gocron, River and Asynq. See [Go](/docs/go/) and [Go schedulers](/docs/go-schedulers/).
- **Rust**: the `cronwatch` crate, with crates for tokio-cron-scheduler and apalis. See [Rust](/docs/rust/) and [Rust schedulers](/docs/rust-schedulers/).
- **Elixir**: the `cronwatch` package on Hex, with integrations for Oban and Quantum. See [Elixir](/docs/elixir/) and [Elixir schedulers](/docs/elixir-schedulers/).
- **Java**: `dev.cronwatch:cronwatch` on Maven Central, with a Spring Boot starter (`@Scheduled` and ShedLock) and modules for Quartz and JobRunr. See [Java](/docs/java/) and [Java schedulers](/docs/java-schedulers/).
- **.NET**: the `Cronwatch` package on NuGet, with `Cronwatch.Hosting` for the Generic Host (hosted jobs on a cron included), `Cronwatch.AspNetCore` for the dashboard, and packages for Hangfire and Quartz.NET. See [.NET](/docs/dotnet/) and [.NET schedulers](/docs/dotnet-schedulers/).

## Install

```bash
npm install @cronwatch/sdk
```

Pick a store. SQLite for one server, Postgres for anything on Vercel, Neon, Supabase or Railway, D1 on [Cloudflare Workers](/docs/cloudflare/) (no driver to install):

```bash
npm install better-sqlite3     # Node 22 or newer for better-sqlite3 13
# or
npm install pg
```

In TypeScript, add the driver's types too (`npm install -D @types/better-sqlite3` or `@types/pg`), unless your `tsconfig` sets `skipLibCheck`.

## Create one client

One client per app, at module level, in a file everything else imports from.

```ts
// lib/cronwatch.ts
import { cronwatch } from "@cronwatch/sdk";
import { sqlite } from "@cronwatch/sdk/sqlite";
import { slack } from "@cronwatch/sdk/slack";

export const cw = cronwatch({
  store: sqlite({ path: "./data/cronwatch.db" }),
  alerts: [slack({ webhookUrl: process.env.SLACK_WEBHOOK_URL! })],
});
```

Without a store, runs live in memory and vanish on restart. Without alerts, they go to the console. Both are fine while trying it out.

## Declare each job

The declaration is the schedule the job is supposed to keep. Declare it once, next to the client, and export the handle.

```ts
export const nightlyReport = cw.job("nightly-report", {
  schedule: "0 2 * * *",      // cron, "@hourly", or "every 15m"
  timezone: "UTC",            // Vercel and GitHub Actions run crons in UTC
  grace: "15m",               // how late a start may be before it is missed
  timeout: "30m",             // a run still going after this is stuck
  expect: "Report written",   // the output must contain this, or the run failed
  budget: { cost: 2 },        // a run reporting cost above 2 is over budget
});
```

Every option is optional. A job with no schedule is still watched for failures, duration and budgets; it just cannot be missed.

## Wrap the work

For an HTTP-triggered job (Vercel cron, GitHub Actions calling an endpoint), wrap a fetch-style handler:

```ts
// app/api/cron/nightly-report/route.ts
import { nightlyReport } from "@/lib/cronwatch";

export const GET = nightlyReport.handler(async (job, request) => {
  const report = await buildReport();
  job.log("Report written:", report.path);   // kept with the run, shown in alerts
  job.metric("cost", report.usdCost);        // watched against budgets and baselines
});
```

The handler checks `Authorization: Bearer <CRON_SECRET>` (from `process.env.CRON_SECRET`) before running, answers 200 with the run id on success and 500 with the first line of the error on failure, and records the run either way. Return a `Response` yourself if you need to; a 4xx or 5xx counts as a failure.

Set `CRON_SECRET`. Without one (an empty value counts as unset) the handler fails closed: it answers 503 and runs nothing, except [in development](/docs/dashboard/#development) (`NODE_ENV` of `development` or `test`, unless `CRONWATCH_ENV` or `APP_ENV` says otherwise). To accept unauthenticated requests on purpose, pass `{ secret: null }` as the handler's second argument, or `cronSecret: null` to `cronwatch()`; those responses leave out the error text.

For anything else, wrap a function:

```ts
await nightlyReport.run(async (job) => {
  job.log("starting");
  // ...
});
```

Whatever the function throws is recorded as the failure and rethrown, so your own error handling still works.

## Mount the dashboard

The routes serve a small dashboard and the JSON API the MCP server uses. In Next.js:

```ts
// app/cronwatch/[[...path]]/route.ts
import { cw } from "@/lib/cronwatch";
export const { GET, POST, DELETE } = cw.routes();
```

Set `CRONWATCH_TOKEN` to a long random string. Open `/cronwatch?token=<it>` once and the browser keeps a cookie. Without one, [in development](/docs/dashboard/#development), the routes make a token of their own and print a sign-in link to the server log on the first request. The link names the host only when that request came to a loopback host (`localhost`, a `.localhost` name, `127.0.0.0/8` or `::1`) or you set `origin`; otherwise it gives the path alone, for you to open on your own host. Outside development, they answer 503 (unless you pass `token: null` to serve them open).

## Run the check

Failures are caught as they happen. A run that never started, or never finished, can only be noticed by looking: that is `cw.check()`. Make sure something calls it every few minutes.

In a long-running server, once at startup:

```ts
cw.startChecking();  // every minute; cw.startChecking("5m") to change it
```

On a serverless platform, add a cron that hits the check endpoint with either the dashboard token or the cron secret as a bearer:

```
GET /cronwatch/api/check
Authorization: Bearer <CRON_SECRET>
```

See [Next.js and Vercel](/docs/nextjs/) and [Servers and scripts](/docs/node/) for the full shapes. Other frameworks and schedulers have pages of their own: [SvelteKit](/docs/sveltekit/), [Nuxt and Nitro](/docs/nuxt/), [React Router and Remix](/docs/react-router/), [NestJS](/docs/nestjs/), [Strapi](/docs/strapi/), [Netlify](/docs/netlify/), [Firebase](/docs/firebase/), [Convex](/docs/convex/), [Trigger.dev](/docs/trigger-dev/), [Inngest](/docs/inngest/), [Cloudflare Workers](/docs/cloudflare/), and [Supabase and pg_cron](/docs/supabase/).

## What you get

Open `/cronwatch` and every job is there with its health, last run, next due time and a sparkline of recent durations. Click through for the run history with errors, output tails and metrics. Alerts arrive in your channel with the specifics, and, if you turn on [triage](/docs/triage/), with a short diagnosis. Point the [MCP server](/docs/mcp/) at the same URL and your agent can read all of it.
