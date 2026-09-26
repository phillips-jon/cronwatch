---
title: Limits and design notes
description: What a library cannot see, how it behaves across instances, and what it deliberately does not do.
order: 13
---

# Limits and design notes

## A dead app cannot alert

CronWatch runs inside your app. If the whole app is down, nothing inside it can notice that the nightly job did not run. Pair it with any uptime monitor for that one case. Everything short of that, from a job that never fires to one that costs three times what it should, is caught from within.

## Someone has to call the check

Missed and stuck runs are only found by `cw.check()`. In a long-running process `cw.start()` does it; on serverless a platform cron has to. If neither is set up, failures are still caught but misses never are. The docs for [Next.js](/docs/nextjs/) and [servers and scripts](/docs/node/) show both.

## Several instances

Any number of app instances may share one store; runs from all of them are recorded. Within one process, every change to a job's state (a run starting or finishing, a check, a silence) waits its turn. Across processes each write names the state version it was based on, and one based on a stale read is refused and worked out again from a fresh read (see [two processes, one store](/docs/stores/#two-processes-one-store)). So overlapping runs of the same job on different instances count every failure, and a condition opens, and alerts, once. Two checks retrying the same queued alert at the same moment can each send it, so run the interval on one instance, or let one platform cron call the check endpoint. A custom store without `compareAndSetState` gets none of this across processes.

## The store going down

A job always runs, whatever the store is doing. If recording the run fails, the error goes to `onError`, the job's own result or error is returned as usual, and the finished run is written if the store is back by then. A store that fails to initialise is tried again on the next call.

## Alert delivery

Each channel gets 15 seconds per alert (Slack, Discord and webhook requests give up after 10). If no channel accepts an alert, it is kept with the job's state and each check tries it once more until one does. A process created with `deliver: "check"` uses the same queue on purpose, so another process sends its alerts. That is a retry of the same alert, not a reminder.

A queued alert that no longer describes the job is dropped instead of sent late: one whose condition has closed since, or closed and opened again (the newer alert is queued too), and a recovery once any condition it names is open again. A recovery whose conditions all stay closed is still sent. One check spends at most 20 seconds of retries across all jobs; whatever is left waits for the next check. More than twenty queued alerts for one job drops the oldest, and says so through `onError`. Otherwise an alert is only lost if the process dies while sending it.

## Output and errors

Output and errors are capped at 16 KB, keeping the tail. NUL characters are removed from both before anything else, because Postgres refuses them. A custom `redact` that throws is reported through `onError` and the default patterns are used instead, so the run is still recorded.

## A job that cannot be evaluated

If one job's stored definition cannot be used (a schedule or timeout written by a newer or older version that this one cannot parse, say), that job is reported through `onError` and shown as failing, with no next due time, and every other job is checked and listed as usual.

## Clocks

Missed detection compares the schedule with the store's timestamps, which come from the process that wrote them. Keep server clocks in sync; a minute of early-start slack absorbs small drift.

## Never-ran jobs

A job the store has never seen cannot be missed. Jobs are registered on their first run, or on the first check in a process that declared them. For crontab scripts, declare every job in the module the check script imports.

If each job is declared only in the worker that runs it, the checking process learns about a job when it first runs, so a job that stops is caught but a timer or crontab line that was never installed is not. To catch that too, declare the jobs in the process that runs the check as well. When installs differ (some run a job, some do not), declare each job there only where it is expected, using the configuration that already decides what that install runs; a job declared where it never runs is reported missed until it is forgotten.

## Alert fatigue

Each condition alerts once when it opens and is answered by one recovered message once the job succeeds again. There is no repeat reminder for a job that stays broken; the dashboard and `list_jobs` show it as failing until it recovers.

## What it is not

Not a scheduler: it does not run anything. Not a queue: it does not retry. Not a service: it holds no copy of your data and needs no account. Those are choices, and they are why it fits in an afternoon of reading.
