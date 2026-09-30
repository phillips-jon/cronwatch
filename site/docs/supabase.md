---
title: Supabase and pg_cron
description: Watch pg_cron jobs, including Supabase Cron, by reading cron.job and cron.job_run_details on every check.
order: 3.392
group: More JavaScript platforms
---

# Supabase and pg_cron

pg_cron runs jobs inside Postgres, so there is no function for CronWatch to wrap. Instead `@cronwatch/sdk/pg-cron` reads what pg_cron already records. On every check it reads `cron.job`, declares each job with its schedule, and copies new rows of `cron.job_run_details` in as runs. From there the usual evaluation takes over: a job that stops running is missed, a failed run alerts, a run that never ends is stuck, a run far slower than usual is slow.

It works the same for self-hosted pg_cron and for Supabase, where the dashboard's Cron integration is pg_cron with a screen in front of it.

## Setup

The reader takes anything with a `pg`-style `query()`, usually the pool you already have. It uses only the `cron` schema; it creates nothing there.

```bash
npm install @cronwatch/sdk pg
```

```ts
import pg from "pg";
import { cronwatch } from "@cronwatch/sdk";
import { postgres } from "@cronwatch/sdk/postgres";
import { pgCron } from "@cronwatch/sdk/pg-cron";
import { slack } from "@cronwatch/sdk/slack";

const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL });

export const cw = cronwatch({
  store: postgres({ pool }),              // CronWatch's own three tables, in the same database or any other
  alerts: [slack({ webhookUrl: process.env.SLACK_WEBHOOK_URL! })],
  sources: [pgCron(pool)],
});

cw.start();                               // or call cw.check() from wherever your checks run
```

Jobs you wrap in code and pg_cron jobs live side by side in the same store, dashboard and alerts.

### Options

```ts
pgCron(pool, {
  jobs: ["nightly-rollup", 12],           // names or jobids, or (job) => boolean. Default every job the role can see
  prefix: "db:",                          // before every name: "db:nightly-rollup"
  jobName: (job) => `job-${job.jobid}`,   // default: its jobname, other characters as "-", else "pg_cron:<jobid>"
  options: { grace: "5m", timeout: "30m" },  // or (job) => ({ ... }); the schedule always comes from pg_cron
  timezone: "UTC",                        // see Timezones below
});
```

`options` takes everything a job does except the schedule and timezone: `grace`, `timeout`, `maxDuration`, `expect` (tested against pg_cron's return message, such as `"1 row"` or `"UPDATE 42"`), `failuresBeforeAlert`, `description` and `tags`.

## What is read, and how it maps

| pg_cron | CronWatch |
| --- | --- |
| `jobname` | the job name, with anything other than letters, digits, `.`, `_`, `:` and `-` turned into `-`. `pg_cron:<jobid>` for a job with no name |
| `schedule` in cron syntax | the same schedule; `$` (last day of the month) becomes `L`, and fields past the fifth are dropped, as pg_cron ignores them |
| `schedule` as `30 seconds` | `every 30s` |
| `active = false` | declared without a schedule, so a paused job is never reported missed (one already missed recovers as no longer scheduled); its runs are still copied |
| a row of `job_run_details` | a run with id `pgcron:<runid>` and trigger `pg_cron` |
| `status` `succeeded` | `ok`, with `return_message` as the output |
| `status` `failed` | `failed`, with `return_message` as the error |
| `status` `running` and the rest | `running`, updated when pg_cron finishes it |
| `status` `starting` (no `start_time` yet) | waited for, up to ten minutes; then copied as `running` from when it was first seen, so one that never starts is marked stuck |
| `status` `failed` with no `start_time` | what pg_cron writes for a run a server restart cut off (`server restarted`): a failure, starting at its `end_time`, else at the job's newest run before it |
| `start_time`, `end_time` | the run's start, finish and duration |

Output and errors go through the client's `redact` like any other run. The job's `command` is not copied, since commands that call HTTP endpoints often carry keys; the description says which database and role the job runs as instead.

Imports are idempotent. Each run is stored under `pgcron:<runid>`, so reading a row again changes nothing, and a row that was `running` last time is updated in place when it finishes, even after a check has marked it timed out. The update is conditional, so when several processes run the check and read the same finish, one records and judges it and the others report it as already finished through `onError`. Where each job left off is kept in memory and, after a restart, worked out from the runs already in the store, so a fresh process (a serverless function, say) carries on rather than starting over. A run that has not started yet never holds the others up: it is read again by its id until it starts.

The first time a job is seen, its twenty newest runs are copied for history (durations, the dashboard), but only the newest finished one is judged, so a history of old failures does not arrive as a burst of alerts. From then on only runs newer than those are read, and every run is judged as it arrives.

Run ids starting with `pgcron:` belong to the reader: `job.start({ id })` and `job.resume(id)` refuse them, and a run of one job is never finished under another.

## Where the check runs

Nothing is read until something calls `cw.check()`. Any of these does:

- **A server that is up anyway.** `cw.start()` checks every minute.
- **A cron outside the database.** Mount the routes and have Vercel cron, GitHub Actions or any scheduler call `/cronwatch/api/check` with the bearer secret (see [Dashboard and API](/docs/dashboard/)).
- **A Supabase Edge Function.** Edge Functions run on Deno, which can import npm packages. The function builds the client, runs one check and returns its result:

```ts
// supabase/functions/cronwatch-check/index.ts
import pg from "npm:pg";
import { cronwatch } from "npm:@cronwatch/sdk";
import { postgres } from "npm:@cronwatch/sdk/postgres";
import { pgCron } from "npm:@cronwatch/sdk/pg-cron";
import { slack } from "npm:@cronwatch/sdk/slack";

const pool = new pg.Pool({ connectionString: Deno.env.get("CRONWATCH_DATABASE_URL"), max: 1 });
const cw = cronwatch({
  store: postgres({ pool }),
  alerts: [slack({ webhookUrl: Deno.env.get("SLACK_WEBHOOK_URL")! })],
  sources: [pgCron(pool)],
});

Deno.serve(async (request) => {
  const secret = Deno.env.get("CRON_SECRET");
  if (!secret) return new Response("CRON_SECRET is not set", { status: 503 });
  if (request.headers.get("authorization") !== `Bearer ${secret}`) {
    return new Response("Unauthorized", { status: 401 });
  }
  const result = await cw.check();
  return Response.json({ checkedAt: result.checkedAt, alerts: result.alerts.length });
});
```

The function refuses every request while `CRON_SECRET` is unset or empty. Without that line, an unset secret would make the expected header `Bearer undefined`, which anyone can send. Set it with `supabase secrets set CRON_SECRET=...`.

By default Supabase lets a request reach an Edge Function only when its `Authorization` header holds a valid Supabase JWT. The scheduler here sends the cron secret in that header instead, so turn the gateway's check off for this function and let the secret do the job: deploy with `supabase functions deploy cronwatch-check --no-verify-jwt`, or set it in `supabase/config.toml`:

```toml
[functions.cronwatch-check]
verify_jwt = false
```

Call it every few minutes. Supabase's own way to schedule an Edge Function is a pg_cron job that posts to it with `pg_net`, and that works, but think about what it means: if pg_cron itself stops (the database restarted without it, the scheduler worker died), the check that would notice stops with it. Prefer a scheduler outside the database for the check, and let pg_cron run everything else.

## Permissions

Connecting as the role that scheduled the jobs is the simplest: on Supabase that is `postgres`, which is what the dashboard's Cron screen uses. It can read the `cron` tables and sees every job it scheduled.

A dedicated monitoring role needs three things:

```sql
CREATE ROLE cronwatch_reader LOGIN PASSWORD '...';
GRANT USAGE ON SCHEMA cron TO cronwatch_reader;
GRANT SELECT ON cron.job, cron.job_run_details TO cronwatch_reader;

-- pg_cron turns on row level security for both tables, with a policy that
-- shows each role only the jobs it scheduled. To see everyone's:
ALTER ROLE cronwatch_reader BYPASSRLS;

-- Optional: lets it read cron.timezone and cron.log_run.
GRANT pg_read_all_settings TO cronwatch_reader;
```

The settings are read from `pg_settings`, which simply has no row for a setting the role may not read (`current_setting()` would raise an error instead, and inside a transaction that aborts it). So without `pg_read_all_settings` the check still works: `cron.timezone` is taken as UTC and `onError` hears about it once, and `cron.log_run` is taken as on. Pass `timezone` when yours is not UTC.

Without `BYPASSRLS` the role sees an empty `cron.job` and the reader says so once through `onError`. Granting `BYPASSRLS` takes a superuser, or on PostgreSQL 16 and later a role with `CREATEROLE` that has `BYPASSRLS` itself; where you cannot, connect as the owning role instead. The role that runs CronWatch's own store also needs to create and write its three tables (see [Stores](/docs/stores/)); that can be a different pool.

## Timezones

pg_cron reads cron expressions in `cron.timezone`, which is GMT unless it was changed. The reader reads the setting on every check and passes it along, so a job scheduled at `0 3 * * *` is expected at 03:00 in that zone. Reading it needs `pg_read_all_settings` (or a superuser); when it cannot be read, UTC is assumed and `onError` hears about it once. Pass `timezone` to set it yourself. Interval schedules (`30 seconds`) do not depend on it.

## Run details, log_run and purging

Failures, durations and output all come from `cron.job_run_details`, so they need `cron.log_run` on (the default). Missed runs are judged from the schedule and the newest run CronWatch has copied, not from the details table, which has two consequences:

- **Purging is fine.** pg_cron keeps every run detail forever unless something deletes them, and a cleanup job (`DELETE FROM cron.job_run_details WHERE end_time < now() - interval '7 days'`) is common and recommended. CronWatch keeps its own copy of each run, with its own `retention`, so deleting old details loses nothing as long as checks run more often than the purge. A run deleted before any check read it is simply never seen.
- **With log_run off there is nothing to read.** pg_cron then records no runs at all, so every scheduled job would look missed. The reader notices the setting, declares the jobs without their schedules so nothing is reported falsely, and says so once through `onError`. Turn `log_run` on to watch them properly.

## Limits

- **A queued HTTP call is a success.** Jobs that call an Edge Function or a webhook with `net.http_post` succeed as soon as the request is queued; `pg_net` sends it later and keeps the response in `net._http_response`. A 500 from the function is invisible to pg_cron and so to CronWatch. Wrap the function itself with `cw.job(...).handler()` to watch what it does.
- **A job removed or renamed in pg_cron keeps its history under its old name.** The reader tracks jobs by `jobid`. When one is unscheduled, renamed, or no longer picked by `jobs`, its old name is declared again without a schedule, so it is never reported missed again, and its description says why (`renamed to <new name>`, `no longer watched`, `no longer in cron.job`). Runs it had open are still read and finished under the old name; new runs go to the new one. A process that starts after the change (a fresh serverless function, say) notices it too, from the job id in the stored description, unless `options` replaced that description. `cw.forget(name)` removes the old name and its runs for good.
- **Removing, renaming or pausing closes missed with a recovery.** Once a name has no schedule nothing is due under it, so if it was missed, the check that drops the schedule closes missed and sends a recovered alert saying the job is no longer scheduled (`reason: "unscheduled"` in its details). Anything else open under that name, a failure say, stays open until a successful run, as usual. See [recovered](/docs/conditions/#recovered).
- **Minimum cadence.** pg_cron's second intervals go down to 1 second, but CronWatch's default grace is ten minutes; set `options.grace` to something sensible for fast jobs.
- **One reader per store for a given cluster.** Run ids are `pgcron:<runid>` (with the `prefix` after `pgcron:` when one is set). Two databases with pg_cron writing into one CronWatch store need different prefixes.
- **Stuck is judged by CronWatch.** A run still `running` after the job's `timeout` (default one hour) is marked timed out and alerts as stuck. The reader keeps reading it: when pg_cron later says it succeeded, the run is recorded as it ended and stuck closes with a recovery; a late failure is recorded without counting twice.
- **Checks read at most 5,000 run details each.** A backlog larger than that (a checker that was down for a long time over a busy job) is worked through over the following checks.

Every port has the same pg_cron reader, with the same rules: see pg_cron in [Ruby](/docs/ruby/#pg-cron), [Python](/docs/python/#pg-cron), [PHP](/docs/php/#pg-cron), [Go](/docs/go/#pg-cron), [Rust](/docs/rust/#pg-cron), [Elixir](/docs/elixir/#pg-cron), [Java](/docs/java/#pg-cron) and [.NET](/docs/dotnet/#pg-cron).
