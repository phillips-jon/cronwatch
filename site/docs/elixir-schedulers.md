---
title: Elixir schedulers
description: Watch Oban and Quantum with one entry in the instance's options and no change to your workers: jobs declared from the scheduler's own crontab, checked against its fire times, every run and retry recorded through its telemetry, and the check running beside them. Plus a plain crontab.
order: 3.94
group: Elixir
---

# Elixir schedulers

A scheduler your Elixir app already runs is watched with one entry in the instance's `integrations:`, and no change to the workers or jobs themselves: the integration reads the scheduler's own configuration and records each run through its telemetry. Each is compiled only when its scheduler is a dependency of your app, and one given without it stops the app's boot, naming it. Everything else (the instance, the store, the channels, the dashboard) is the [Elixir page](/docs/elixir/).

| Scheduler | Integration | Supported | The check |
|---|---|---|---|
| [Oban](#oban) | `Cronwatch.Oban` | 2.20 or newer | `Cronwatch.Oban.CheckWorker` in the Cron plugin's crontab |
| [Quantum](#quantum) | `Cronwatch.Quantum` | 3.5 | a job whose task is `{Cronwatch.Quantum, :check, [...]}` |

A release that a crontab runs needs no integration: see [a crontab](#a-crontab) below.

## What every integration does

- **Jobs are declared from the scheduler.** Each entry the scheduler runs on a schedule is a CronWatch job with that schedule, in that entry's zone, so a job that stops running is reported missed without you writing a cron expression twice. Each schedule is checked against the scheduler's own fire times: Oban and Quantum both match a day of the month and a day of the week together, where CronWatch (like cron, and croner in the SDK) matches either when both are set, so an expression the two read differently is reported once to the error handler and its job watched without a schedule. Its failures, duration and budgets still alert, but it is never reported missed. A worker or job with several entries on different expressions is one job without a schedule.
- **Jobs gone lose their schedule.** A job taken out of the scheduler, in this node or since an earlier deploy, is declared again without its schedule and with ` (no longer scheduled)` after its description, so it keeps its history and is never reported missed; a missed alert already open closes with a recovery.
- **Jobs belong to an app.** Every job is tagged with the integration (`oban`, `quantum`) and the app (`oban:billing`), so two apps sharing a store never take each other's jobs for gone. The app is the integration's `app:` option, else `CRONWATCH_APP_ID`, else the OTP application that started the instance. Set `CRONWATCH_APP_ID` when two apps that share a store have the same OTP application name; every node of one app needs the same.
- **Each run is a run in the scheduler's own process.** The integration attaches to the scheduler's `:telemetry` events, which fire in the process that runs the job, so the run's context is there: `Cronwatch.log/1`, `Cronwatch.metric/2` and `Cronwatch.current/0` work inside the job with no code, and Logger metadata carries `cronwatch_job` and `cronwatch_run`. The process is monitored like any run's, so a job killed part way is a failed run at once.
- **Options per job.** `defaults:` are job options for every job, before its schedule, and each integration takes options per job after them.

### Retries

For Oban, every attempt is a run of its own. An attempt that fails (an error, a raise, `{:error, reason}`, or a `{:cancel, reason}` the worker gives up with) is a failed run with its cause, so failing attempts open one failed alert and the attempt that succeeds closes it with a recovery; `failures_before_alert: 3` counts failed attempts in a row. An attempt that snoozes did not fail and did not do its work: its run is taken back, so nothing is judged, no alert is sent and the failures in a row are left as they were. If the job was due, its schedule reports it missed. Taking a run back needs a store with `delete_run_if`, which the memory store and `Cronwatch.Store.Ecto` have; with a store of your own without it, the snooze is kept as an `ok` run, still not judged.

### The check

Each integration has a check of its own, which runs a sync first: the scheduler's jobs are declared again, and the jobs of this app's that the store holds with a schedule the scheduler no longer has are declared again without it. Run it once a minute. `check_every:` on the instance checks too, but without the sync, so a job taken out of the scheduler's configuration by a deploy keeps its schedule and is reported missed; prefer the integration's check.

## Oban

```elixir
# lib/my_app/application.ex, among the children
{Cronwatch,
 store: {Cronwatch.Store.Ecto, repo: MyApp.Repo},
 integrations: [
   {Cronwatch.Oban,
    oban: Oban,
    defaults: [grace: "5m"],
    workers: [{MyApp.Workers.NightlyReport, timeout: "1h"}, MyApp.Workers.Import]}
 ]}
```

```elixir
# config/config.exs
config :my_app, Oban,
  repo: MyApp.Repo,
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       {"0 2 * * *", MyApp.Workers.NightlyReport},
       {"@hourly", MyApp.Workers.Sync, timezone: "Europe/London"},
       {"* * * * *", Cronwatch.Oban.CheckWorker}   # the check, once a minute across the cluster
     ]}
  ]
```

`oban:` names the Oban instance, `Oban` by default. Oban 2.20 or newer is needed: it is the first release whose Cron plugin marks each job it inserts with its expression and zone.

**Which jobs.** Every worker in the Cron plugin's crontab is a job, named after its module as Elixir writes it (`MyApp.Workers.NightlyReport`), on the entry's expression in the entry's `timezone`, else the plugin's, else `Etc/UTC`. Oban's nicknames are written out as Oban reads them (`@daily` is `0 0 * * *`; `@reboot` is no schedule). The crontab is read from `Oban.config/1` when the instance starts, and again whenever Oban or its Cron plugin starts, so an Oban started after the instance is found. Workers outside the crontab are watched only when named in `workers:` (a module, or `{module, job_options}`, which also gives a crontab worker's job its options), so a queue of a million email jobs is not a million runs. A job the Cron plugin inserted is known by its `meta["cron"]`, so a node whose own crontab lacks it, or whose Oban runs in a testing mode, still records its runs, declared from the definition the store holds.

**Runs.** Each attempt is a run with the trigger `oban`, recorded through Oban's `[:oban, :job, :start]`, `:stop` and `:exception` events in the worker's own process, so `Cronwatch.log/1` inside `perform/1` adds to its output:

```elixir
defmodule MyApp.Workers.NightlyReport do
  use Oban.Worker, queue: :default

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    path = MyApp.Reports.build()
    Cronwatch.log("Report written: #{path}")
    :ok
  end
end
```

What `perform/1` answers is judged as Oban judges it: `:ok` or `{:ok, _}` succeeds; a raise, `{:error, reason}` and `{:cancel, reason}` (the older `:discard` too) fail the run, a cancel written as Oban writes it (`MyApp.Workers.Import failed with {:cancel, reason}`); a `{:snooze, seconds}` gives the run back, since the job did not fail and will run again (see [Retries](#retries)). A job killed at its `timeout/1`, or by a node shutting down, is a failed run at once. An attempt left running by a node that died outright is closed when Oban's Lifeline rescues the job and its next attempt starts, failed with `Oban rescued the job after its node stopped`. A job Oban discards after its last attempt is that attempt's failure, nothing more.

**The check.** `Cronwatch.Oban.CheckWorker` in the crontab runs the sync and a check once per minute across the cluster, since the Cron plugin inserts it once, on the leader; its runs are never a job. An instance other than the default is named in its args: `{"* * * * *", Cronwatch.Oban.CheckWorker, args: %{instance: "MyApp.Cronwatch"}}`. `Cronwatch.Oban.sync/1` runs the sync alone.

**Not supported.** Oban Pro's `DynamicCron` keeps its crontab in the database; its workers can be named in `workers:`, and are then watched without a schedule.

## Quantum

```elixir
# lib/my_app/application.ex, among the children, after the scheduler
{Cronwatch,
 store: {Cronwatch.Store.Ecto, repo: MyApp.Repo},
 integrations: [{Cronwatch.Quantum, scheduler: MyApp.Scheduler, jobs: [nightly_report: [grace: "15m"]]}]}
```

```elixir
# config/config.exs
config :my_app, MyApp.Scheduler,
  jobs: [
    nightly_report: [schedule: "0 2 * * *", timezone: "Europe/London", task: {MyApp.Reports, :nightly, []}],
    cronwatch_check: [schedule: "* * * * *", task: {Cronwatch.Quantum, :check, [[scheduler: MyApp.Scheduler]]}]
  ]
```

`scheduler:` is your Quantum scheduler module, and is required; `jobs:` gives job options by the Quantum job's name.

**Which jobs.** Every active job of `MyApp.Scheduler.jobs()` is a job, named after its name (`:nightly_report` is `nightly_report`). A job without a name (Quantum gives it a reference) is named after its task when that is `{Module, :function, args}` (`MyApp.Reports.nightly`), and otherwise reported once and not watched, so give such a job a name. Its schedule is Quantum's expression written back as text (an extended one with its seconds first, as CronWatch reads six fields) in the job's `timezone` (`:utc` is `UTC`), checked against Quantum's own fire times. Quantum skips a time that does not exist or happens twice in the zone when the clocks change, and CronWatch expects it to. Jobs added, deleted, activated or deactivated at run time are followed through Quantum's own telemetry, and the jobs are read again every minute besides, which also finds a scheduler started after the instance; a job no longer active is declared again without its schedule.

**Runs.** Each run is a run with the trigger `quantum`, recorded through Quantum's `[:quantum, :job, :start]`, `:stop` and `:exception` events in the task that runs the job, so `Cronwatch.log/1` works inside the job's function. A raise fails the run, and so does a function answering `{:error, reason}`, as `Cronwatch.run/3` has it.

**The check.** A Quantum job whose task is `{Cronwatch.Quantum, :check, [[scheduler: MyApp.Scheduler]]}` runs the sync and a check; it is never a job itself. `Cronwatch.Quantum.sync/1` runs the sync alone.

## A crontab

A release that a crontab runs needs no integration: the job's line wraps its work in `Cronwatch.run/3`, and a second line runs the check, both on a store they share.

```
# m  h  dom mon dow  command
0    2  *   *   *    /app/bin/my_app eval "MyApp.Nightly.main()"
*/5  *  *   *   *    /app/bin/my_app eval "Cronwatch.Release.check(MyApp.Cronwatch)"
```

`Cronwatch.Release.check/2` starts the store's repo and an instance with the options under `config :my_app, MyApp.Cronwatch`, without the app's endpoint or queues, runs one check, prints what it did and exits non-zero when it fails. From source, `mix cronwatch.check MyApp.Cronwatch` does the same. [From a crontab](/docs/elixir/#from-a-crontab) on the Elixir page has the job's side.
