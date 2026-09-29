---
title: Schedules, grace and timeouts
description: Cron expressions, intervals, timezones, and exactly how a missed or stuck run is decided.
order: 4
---

# Schedules, grace and timeouts

Every port applies these rules the same way: TypeScript, Ruby, Python, PHP, Go and Rust. The examples use the TypeScript names; each language's page has its own spelling (`cw.check()` is `client.check` in Ruby, for one). In Rails, a job can take its schedule and timezone from Solid Queue or sidekiq-cron instead; see [Schedule the job](/docs/rails/#schedule-the-job).

## Schedule syntax

| Form | Example | Notes |
|---|---|---|
| Cron, five fields | `0 2 * * *` | minute hour day month weekday, standard syntax with `*/n`, ranges and lists |
| Cron, six fields | `0 */30 * * * *` | a leading seconds field |
| Nickname | `@yearly` (or `@annually`), `@monthly`, `@weekly`, `@daily` (or `@midnight`), `@hourly` | each fires at the start of its period: `@weekly` is Sunday at 00:00, `@yearly` January 1st. `@reboot` is not a schedule and is refused |
| Interval | `every 15m`, `every 6h`, `every 2d` | at least one second (`every 500ms` throws); counted from the last run's start, or from registration before the first run |
| None | | watched for failures, duration and budgets; never missed |

Durations everywhere use the same units: `ms`, `s`, `m`, `h`, `d`, `w`, and compounds like `1h30m`. A number is milliseconds. A duration string is at most 64 characters; a longer one is refused.

## Timezone

A cron expression is read in the process's timezone unless the job (or the client's `defaults`) sets `timezone` to an IANA name. Vercel and GitHub Actions run their crons in UTC, so declare `timezone: "UTC"` for those or the two schedules will disagree and you will see phantom misses around midnight.

## How a missed run is decided

Each `cw.check()` counts forward from the job's last run:

1. Finds the **due time**: the first time the schedule fires after the last run started. A run covers a fire it started up to one minute before (schedulers sometimes fire a touch early), so a run at 01:59:30 counts for 02:00 and the next day's 02:00 is due. For a cron that fires more often than every two minutes, that slack shrinks to half the gap between fires, so one run never covers two. For an interval, the due time is the last run's start plus the interval.
2. Adds `grace` (default `10m`) to get the **deadline**.
3. If now is past the deadline, the job is **missed**. An interval job whose last run is still going is busy, not missed; **stuck** covers a run that never ends.

Because the due time comes from the last run rather than from the latest fire, a job that runs more often than its grace (every five minutes with the default ten minutes of grace) is still caught, and so is a cron that fires once a year.

A missed condition opens once and sends one alert. It closes, without a message, the moment a run starts; the recovered message is sent by the next successful run, even if the run that closed it failed. If a run never comes, you hear about it once, not every check.

A job that has never run counts from when it was first registered: the first check or run in a process that declared it. Its due time is the first fire at or after registration; a fire that happened before registration is not expected.

## Daylight saving time

A cron read in a timezone with daylight saving follows that zone's clock. When clocks spring forward, a fire whose local time does not exist that night (02:30 when 02:00 jumps to 03:00) is expected at the same distance past the jump (03:30), and a run that starts at or after the jump and before that time also covers it. That is where vixie cron runs such a job (03:00), so either scheduler's run counts. When clocks fall back, the repeated hour's fire is expected once. Declaring `timezone: "UTC"` avoids the question entirely.

## Timeouts and stuck runs

Every run is recorded as `running` when it starts. Normally it is updated to `ok` or `failed` within the same call. If the process dies first, the row stays `running`. Each check marks any run older than the job's `timeout` (default `1h`) as `timeout`, counts it as a failure, and opens a **stuck** condition. The next run's start closes it, and the next successful run sends the recovery. If the timed-out run does finish later, a success closes stuck and recovers, and a failure is not counted a second time.

Inside the process, `job.signal` is an `AbortSignal` that fires when the timeout elapses, so work that can stop early may honour it; nothing is killed for you. In Ruby, `job.aborted?` turns true and `job.signal.check!` raises once the timeout has passed.

In Go the run's `ctx` is cancelled at the timeout, with a cause that names the job; in Rust `job.cancelled()` resolves then.

## Next due

The dashboard and API show `nextExpectedAt`: the next fire after now for a cron, or the last run's start plus the interval.

## Choosing a grace period

Grace absorbs the normal jitter between "scheduled" and "started": queue delays, cold starts, a scheduler that ticks once a minute. Ten minutes suits most daily jobs. A frequent job can use a shorter grace (`every 5m` with `grace: "2m"`) to hear about a stop sooner, and a job that queues behind others a longer one. The grace only affects when a miss is reported, never whether a run counts.
