---
title: Schedules, grace and timeouts
description: Cron expressions, intervals, timezones, and exactly how a missed or stuck run is decided.
order: 4
---

# Schedules, grace and timeouts

## Schedule syntax

| Form | Example | Notes |
|---|---|---|
| Cron, five fields | `0 2 * * *` | minute hour day month weekday, standard syntax with `*/n`, ranges and lists |
| Cron, six fields | `0 */30 * * * *` | a leading seconds field |
| Nickname | `@hourly`, `@daily`, `@weekly`, `@monthly` | |
| Interval | `every 15m`, `every 6h`, `every 2d` | counted from the last run's start, or from registration before the first run |
| None | | watched for failures, duration and budgets; never missed |

Durations everywhere use the same units: `ms`, `s`, `m`, `h`, `d`, `w`, and compounds like `1h30m`. A number is milliseconds.

## Timezone

A cron expression is read in the process's timezone unless the job (or the client's `defaults`) sets `timezone` to an IANA name. Vercel and GitHub Actions run their crons in UTC, so declare `timezone: "UTC"` for those or the two schedules will disagree and you will see phantom misses around midnight.

## How a missed run is decided

Each `cw.check()`:

1. Finds the most recent time the schedule fired at or before now, the **due time**. For an interval, that is the last run's start plus the interval.
2. Adds `grace` (default `10m`) to get the **deadline**.
3. Looks at the job's last run. The due time is **covered** if a run started at or after the due time minus one minute (schedulers sometimes fire a touch early).
4. If it is not covered and now is past the deadline, the job is **missed**.

A missed condition opens once and sends one alert. It closes, without a message, the moment a run starts, and the recovery is reported when that run finishes successfully. If a run never comes, you hear about it once, not every check.

A job that has never run counts from when it was first registered: the first check or run in a process that declared it. A cron fire that happened before registration is not expected.

## Timeouts and stuck runs

Every run is recorded as `running` when it starts. Normally it is updated to `ok` or `failed` within the same call. If the process dies first, the row stays `running`. Each check marks any run older than the job's `timeout` (default `1h`) as `timeout`, counts it as a failure, and opens a **stuck** condition.

Inside the process, `job.signal` is an `AbortSignal` that fires when the timeout elapses, so work that can stop early may honour it; nothing is killed for you.

## Next due

The dashboard and API show `nextExpectedAt`: the next fire after now for a cron, or the last run's start plus the interval.

## Choosing a grace period

Grace absorbs the normal jitter between "scheduled" and "started": queue delays, cold starts, a scheduler that ticks once a minute. Ten minutes suits most daily jobs. Use a shorter grace for frequent jobs (`every 5m` with `grace: "2m"`) and a longer one for jobs that queue behind others. The grace only affects when a miss is reported, never whether a run counts.
