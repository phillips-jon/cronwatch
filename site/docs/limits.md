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

Any number of app instances may share one store; runs from all of them are recorded. Checks are not coordinated across instances, so two instances checking at the same moment could both open the same condition and send two alerts. Run the interval on one instance, or let one platform cron call the check endpoint.

## Clocks

Missed detection compares the schedule with the store's timestamps, which come from the process that wrote them. Keep server clocks in sync; a minute of early-start slack absorbs small drift.

## Never-ran jobs

A job the store has never seen cannot be missed. Jobs are registered on their first run, or on the first check in a process that declared them. For crontab scripts, declare every job in the module the check script imports.

## Alert fatigue

Each condition alerts once when it opens and once when it clears. There is no repeat reminder for a job that stays broken; the dashboard and `list_jobs` show it as failing until it recovers.

## What it is not

Not a scheduler: it does not run anything. Not a queue: it does not retry. Not a service: it holds no copy of your data and needs no account. Those are choices, and they are why it fits in an afternoon of reading.
