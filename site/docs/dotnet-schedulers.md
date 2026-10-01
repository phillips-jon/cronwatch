---
title: .NET schedulers
description: Watch Hangfire and Quartz.NET with no change to your jobs, or run hosted jobs on a cron in the Generic Host: jobs declared from the scheduler's own schedules, checked against its fire times, every attempt recorded in the flow that runs it, and the check running once per cluster. Plus a plain crontab.
order: 3.98
group: .NET
---

# .NET schedulers

A scheduler your .NET service already runs is watched with no change to its jobs: the integration reads the scheduler's own schedules and records each attempt around the code that runs it. Hangfire and Quartz.NET are one call each; a service with neither can run its jobs on a cron with `AddCronwatchJob`. Everything else (the client, the store, the channels, the dashboard) is the [.NET page](/docs/dotnet/).

| Scheduler | Package | Supported | The check |
|---|---|---|---|
| [Hangfire](#hangfire) | `Cronwatch.Hangfire` | Hangfire 1.8.0 or newer | a recurring job of its own, once per cluster |
| [Quartz.NET](#quartz-net) | `Cronwatch.Quartz` | Quartz.NET 4.0.0 or newer | `CronwatchCheckJob`, once per cluster |
| [Hosted jobs](#hosted-jobs) | `Cronwatch.Hosting` | .NET's Generic Host | `AddCronwatch`'s hosted check |

A program a crontab runs needs no integration: see [a crontab](#a-crontab) below.

## What every integration does

- **Jobs are declared from the scheduler.** Each recurring job or trigger the scheduler runs on a schedule is a CronWatch job with that schedule, in that entry's zone (a Windows zone id converted to its IANA name), so a job that stops running is reported missed without you writing a cron expression twice. Each cron is checked against the scheduler's own fire times: Hangfire (through Cronos) and Quartz.NET each read some expressions differently from CronWatch (like cron, and croner in the SDK), so an expression the two read differently is reported once to the error handler and its job watched without a schedule. Its failures, duration and budgets still alert, but it is never reported missed. A trigger repeating on an interval is `every <interval>`, and a job with several schedules is one job without a schedule.
- **Jobs gone lose their schedule.** A job taken out of the scheduler, in this process or since an earlier deploy, is declared again without its schedule, so it keeps its history and is never reported missed; a missed alert already open closes with a recovery.
- **Jobs belong to an app.** Every job is tagged with the integration (`hangfire`, `quartz`) and the app (`quartz:billing`), and the app is in its runs' ids, so two apps sharing a store never take each other's jobs for gone. The app is the integration's `App` option, else `CRONWATCH_APP_ID`, else the host's application name (Quartz.NET) or the entry assembly's name. Every instance of one app needs the same.
- **Each attempt is a run around the job's own code.** The run is opened just before the job's code runs and closed just after, so `CronwatchClient.Current` and `job.Log` work inside the job with no code. A job that throws fails its run, and the scheduler's own error handling does what it did before.
- **Options per job.** `JobDefaults` come first, then the schedule, then each job's own options from `Jobs`, so a schedule given to one job replaces the scheduler's.

### Retries

Every attempt is a run of its own. An attempt that fails is a failed run with its exception, so failing attempts open one failed alert and the attempt that succeeds closes it with a recovery; `FailuresBeforeAlert = 3` counts failed attempts in a row. A Hangfire retry and a Quartz.NET refire (`RefireImmediately`) are new runs. An attempt the scheduler gives back without failing it (a Hangfire job stopped by its server's shutdown, which Hangfire puts back in its queue) is taken back, so nothing is judged, no alert is sent and the failures in a row are left as they were. Taking a run back needs a store with `IRunDeletingStore`, which `MemoryStore` and `SqlStore` are.

### The check

Each integration's check runs a sync first: the scheduler's jobs are declared again, and the jobs of this app's that the store holds with a schedule the scheduler no longer has are declared again without it. It runs once a minute across the cluster, on the scheduler's own lock. `AddCronwatch`'s hosted check and `cw.StartChecking()` check too, but without the sync, so a job taken out of the scheduler by a deploy keeps its schedule and is reported missed; prefer the integration's check, and give `AddCronwatch` `NoCheck = true` so each instance does not check again.

## Hangfire

`Cronwatch.Hangfire` watches Hangfire 1.8 (1.8.0 or newer), on any storage. With the client from `AddCronwatch`:

```csharp
builder.Services.AddCronwatch(o =>
{
    o.Store = SqlStore.Postgres(pg);
    o.NoCheck = true;                                         // the check job below runs it once per cluster
});
builder.Services.AddHangfire((services, c) => c
    .UseSqlServerStorage(connectionString)                    // or any other storage
    .UseCronwatch(services));
builder.Services.AddHangfireServer();

WebApplication app = builder.Build();
CronwatchHangfire.ScheduleCheck(app.Services.GetRequiredService<IRecurringJobManager>());   // `cronwatch-check`, every minute
```

Without the container, `GlobalConfiguration.Configuration.UseCronwatch(cw)` watches for the life of the process, and `CronwatchHangfire.Start(cw, options)` answers an integration you can dispose. Call either before the server starts. Hangfire's filters belong to the process, so one integration watches Hangfire per process; starting another stops the first.

```csharp
GlobalConfiguration.Configuration.UseCronwatch(cw, new CronwatchHangfireOptions
{
    App = "billing",
    JobDefaults = new JobOptions { Grace = "5m" },
    Jobs = { ["nightly-report"] = new JobOptions { Expect = "Report written" } },
});
```

**Which jobs.** Every recurring job is a job, named after its id (`nightly-report`), on its cron in its zone. The recurring jobs are read when the integration starts and every minute besides (`ReadEvery` sets it), and a job a recurring job enqueued is recorded even on a server whose own code never registered it. Each cron is declared as written, with a `?` read as `*`, and checked against Cronos, the reader Hangfire carries; Hangfire 1.8.0's Cronos refuses a nickname such as `@daily`, which later 1.8 releases take. A job that is not recurring (a fire-and-forget or delayed job) is watched only when named, with `[CronwatchJob("import")]` on its method or by the method's full name in `Named`, each attempt a run of that job with no schedule, so a queue of a million emails is not a million runs.

**Runs.** A server filter opens each attempt's run (trigger `hangfire`) on the worker's thread just before the job's method and closes it just after, async methods included, and takes it off the thread, so the next job on a pooled worker sees none. The job's own exception fails the run, unwrapped from Hangfire's `JobPerformanceException`. A job stopped by its server's shutdown is given back (see [Retries](#retries)); one deleted from Hangfire's dashboard while running is a failure. A job Hangfire fails before it performs it, because its type, method or arguments no longer load after a deploy, never reaches the filter, so a state filter records it failed, and the job alerts at its first fire rather than waiting to be missed.

**The check.** `CronwatchHangfire.ScheduleCheck(recurringJobManager)` (or `ScheduleCheck()`, on the current storage's manager) adds the recurring job `cronwatch-check` every minute, unless it is there already, with no automatic retries and no concurrent runs. It runs the sync and a check once per minute across every server sharing the storage, since Hangfire enqueues a recurring job once per fire. Its runs are never a job.

`Cronwatch.Hangfire` is not Native AOT compatible, since Hangfire itself is not.

## Quartz.NET

`Cronwatch.Quartz` watches a Quartz.NET 4 scheduler (4.0.0 or newer; the 3.x line is not supported, since its listener interfaces differ). With the client from `AddCronwatch`:

```csharp
builder.Services.AddCronwatch(o =>
{
    o.Store = SqlStore.Postgres(pg);
    o.NoCheck = true;                                         // the check job runs it once per cluster
});
builder.Services.AddQuartz(q =>
{
    q.UseCronwatch(o =>
    {
        o.ScheduleCheck = true;                                // CronwatchCheckJob, every minute
        o.Jobs["reports.nightly"] = new JobOptions { Expect = "Report written" };   // the job `nightly` in the group `reports`
    });
    // your jobs and triggers, as before
});
builder.Services.AddQuartzHostedService();
```

The integration attaches when the scheduler starts and is disposed at its shutdown. A scheduler built without the container takes a client of your own (`QuartzSchedulerBuilder.Create(q => q.UseCronwatch(cw))`), and one built another way is watched with `await CronwatchQuartz.WatchAsync(cw, scheduler, options)`, called before it starts, with the check scheduled by `CronwatchQuartz.ScheduleCheckAsync(scheduler)`.

**Which jobs.** Every job the scheduler holds with a trigger is a job, named after its `JobKey`: `nightlyReport` in the `DEFAULT` group, `reports.nightly` for `nightly` in `reports`. The jobs are read when the integration starts, again when the scheduler says a job or trigger was added or removed, and every minute besides (`ReadEvery` sets it). A job with one cron trigger is declared on its expression in the trigger's zone (a `?` read as `*`, a year field of `*` or `?` left out), checked against Quartz's own `CronExpression`. Quartz counts the days of the week from 1 for Sunday, so an expression naming one by number is reported and watched without a schedule: write `MON`, not `2`. A simple trigger repeating forever is `every <interval>`; a calendar or daily time interval trigger, a trigger with an excluding calendar, and several triggers on one job make a job without a schedule.

**Runs.** A global job listener opens each firing's run (trigger `quartz`) before the job's `Execute` and closes it after, failed with what the job threw, unwrapped from Quartz's `JobExecutionException`. Through the builder, a job execution middleware makes the run current inside `Execute`, so `CronwatchClient.Current` works with no code; a scheduler watched with `WatchAsync` gets its run from `context.CronwatchRun()`. A vetoed firing opens nothing, and one another listener stopped after ours opened it is given back. In a clustered job store, a job a node was running when it died is fired again on another node, and that firing first finishes the earlier run, failed with `Quartz recovered the job after its node stopped`.

**The check.** `ScheduleCheck = true` schedules `CronwatchCheckJob` (`[DisallowConcurrentExecution]`), which runs the sync and a check every `CheckEvery` (a minute by default); in a clustered job store Quartz fires it on one node, so it runs once per cluster. Its runs are never a job.

## Hosted jobs

A service with no scheduler can run a job class on its own cron inside the Generic Host, on the same definition CronWatch watches, so the schedule it runs on and the one it is watched on cannot drift apart:

```csharp
builder.Services.AddCronwatch(o => o.Store = SqlStore.Postgres(pg));
builder.Services.AddCronwatchJob<NightlyReport>("nightly-report", new JobOptions
{
    Schedule = "0 2 * * *",
    Timezone = "UTC",
    Grace = "15m",
});
```

Each fire is a run with the trigger `hosting` (`schedule` before 1.0), the class (an `ICronwatchJob`) resolved from a new DI scope, its token cancelled at the job's timeout and at shutdown. A fire that comes while the previous run is still going is skipped and logged once. It is a scheduler for one process: every replica of a service runs its hosted jobs, so a job that must run once across a cluster belongs in Hangfire or Quartz.NET with a shared store. `AddCronwatch`'s hosted check watches these jobs. [Hosted jobs](/docs/dotnet/#hosted-jobs) on the .NET page has the rest.

Coravel is not integrated: an invocable that should be watched wraps its body in a run.

```csharp
public sealed class SendDigest(CronwatchClient cw) : IInvocable
{
    public Task Invoke() => cw.Job("send-digest").RunAsync((job, ct) => SendDigestAsync(ct));
}
```

## A crontab

A program a crontab runs needs no integration: the job's line wraps its work in `job.RunAsync`, and a second line runs the check, both on a store they share.

```
# m  h  dom mon dow  command
0    2  *   *   *    dotnet /app/MyApp.dll nightly-report
*    *  *   *   *    dotnet /app/MyApp.dll cronwatch check
```

The program hands `CronwatchCli.RunAsync` the factory for your client, or in a Generic Host app returns `await app.RunCronwatchCommandAsync(args)`, which checks from the host's own services without starting it; `check` runs one check, prints what it did and answers non-zero when it fails. [From a crontab](/docs/dotnet/#from-a-crontab) on the .NET page has both sides.

## Another scheduler

The two integrations are built on `Cronwatch.Bridge` (`SchedulerBridge`, `Watch`, `Entry`), which declares a scheduler's entries as jobs and checks their schedules against the scheduler's own fire times. It is public for integration authors, but outside the 1.x promise: it changes as the integrations need, in any minor release. A scheduler of your own can wrap each job's work in `job.RunAsync`, which is promised.
