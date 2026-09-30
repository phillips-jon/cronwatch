---
title: Go schedulers
description: Watch robfig/cron, gocron, River and Asynq with one line each: entries become jobs with their schedules, every run and retry is recorded, and the check runs beside them.
order: 3.82
group: Go
---

# Go schedulers

A scheduler your Go app already runs is watched with one option or constructor, and no change to the jobs themselves. Each integration is a module of its own, so an app pulls only the one it uses, and the core module stays free of requirements. Everything else (the client, the store, the channels, the dashboard) is the [Go page](/docs/go/).

```bash
go get cronwatch.dev/go/robfigcron   # or cronwatch.dev/go/gocron, /river, /asynq
```

| Scheduler | Module | Oldest supported | What you add |
|---|---|---|---|
| [robfig/cron](#robfig-cron) v3 | `cronwatch.dev/go/robfigcron` | v3.0.1 | `robfigcron.Watch(cw, ...)` to `cron.New` |
| [gocron](#gocron) v2 | `cronwatch.dev/go/gocron` | v2.21.0 | `cwgocron.Watch(cw, ...)` to `gocron.NewScheduler` |
| [River](#river) | `cronwatch.dev/go/river` | v0.44.1 | `w.PeriodicJob` for `river.NewPeriodicJob`, and a worker middleware |
| [Asynq](#asynq) | `cronwatch.dev/go/asynq` | v0.25.1 | `w.NewScheduler` for `asynq.NewScheduler`, and a server middleware |

A program that a crontab runs needs no integration: see [Run the check](/docs/go/#run-the-check) on the Go page.

## What every integration does

- **Entries become jobs.** Each of the scheduler's entries is a CronWatch job with the scheduler's own schedule, so a job that stops running is reported missed without you copying a cron expression anywhere. A schedule is converted only where it means exactly the same times: it is checked against the scheduler's own fire times around every clock change of the next five years and through a sample year. One that cannot match (a time a spring-forward gap removes, which each scheduler handles its own way, or a schedule type CronWatch cannot read) is reported once to the error handler and the job is watched without a schedule, so its failures, duration and budgets still alert.
- **Jobs gone lose their schedule.** An entry taken out of the scheduler, in this process or since an earlier deploy, has its job declared again without its schedule and with ` (no longer scheduled)` after its description, so it keeps its history and is never reported missed; a missed alert already open closes with a recovery.
- **Jobs belong to an app.** Every job is tagged with the integration (`robfig-cron`, `gocron`, `river`, `asynq`) and the app (`gocron:billing`), so two apps sharing a store never take each other's jobs for gone. The app is the `App` option, else `CRONWATCH_APP_ID`, else the running executable's name. Set `CRONWATCH_APP_ID` when one app's processes are different executables (an Asynq scheduler and its server, say), or two apps' executables share a name.
- **Declarations reach the store.** A process that only schedules (a River client inserting jobs its workers run elsewhere, an Asynq scheduler) neither runs nor checks, so what it declares is written to the store in the background, where the processes that run and check read it. Each watcher's `Wait()` waits for those writes, for tests and a clean exit.
- **Options per job.** `Options.Defaults` are job options for every job, and `Options.Jobs` (robfig/cron, gocron) gives options by job name, after the schedule, so a `Schedule` there replaces the scheduler's. `Options.Exclude` (robfig/cron, gocron, Asynq) leaves jobs out by name.

### Retries

For the queues, every attempt is a run of its own. An attempt that fails (an error, or a panic the queue recovers) is a failed run with its cause, so failing attempts open one failed alert and the attempt that succeeds closes it with a recovery; `cronwatch.FailuresBeforeAlert(3)` counts failed attempts in a row. An attempt the queue gives back without failing (a River job that snoozes or cancels itself, an Asynq task revoked) did not fail and did not do its work: its run is taken back with `cronwatch.DiscardWhen`, so nothing is judged, no alert is sent and the failures in a row are left as they were. If that job was due, its schedule reports it missed. Taking a run back needs a store with `DeleteRunIf`, which the memory store and `sqlstore` have.

### The check

robfig/cron and gocron run in the same process as the rest of the app, so that process checks: `cw.Start(time.Minute)` beside `c.Start()`. River and Asynq have a check job of their own, scheduled like any other and never a job itself, which also declares again without their schedules the jobs this app's scheduler no longer runs.

## robfig/cron

```go
import (
	cronwatch "cronwatch.dev/go"
	"cronwatch.dev/go/robfigcron"
	"github.com/robfig/cron/v3"
)

c := cron.New(robfigcron.Watch(cw, robfigcron.Options{
	Chain: []cron.JobWrapper{cron.Recover(logger)},
}))
c.AddFunc("0 2 * * *", jobs.NightlyReport) // the job "jobs.NightlyReport"
c.AddJob("*/15 * * * *", robfigcron.Named("sync-invoices", syncJob, cronwatch.Grace("5m")))
c.Start()
cw.Start(time.Minute) // checks for missed and stuck runs
```

`Watch` is a `cron.Option`. It sets the cron's chain to your wrappers (`Options.Chain`) with CronWatch's innermost, and its logger to one around yours (`Options.Logger`, else robfig/cron's default), which is how entries added or removed later are followed: robfig/cron logs `start`, `added` and `removed`, and each starts a sync. A `cron.WithChain` or `cron.WithLogger` given to `cron.New` after `Watch` replaces CronWatch's, so give yours to the options instead. A wrapper outside CronWatch's that skips a run (`cron.SkipIfStillRunning`) records nothing, and one that recovers panics (`cron.Recover`) sees the panic after the run is recorded as failed; without one, the panic ends the program, as it would without CronWatch.

**Names.** A job is named by `robfigcron.Named(name, job, options...)`, which also gives it options; else after the function a `FuncJob` holds, without its package's path (`jobs.NightlyReport`, or `jobs.Reporter.Run` for a method value); else after its type (`jobs.Nightly` for a `*jobs.Nightly`). A function literal has no stable name, since it moves with the code around it (`main.main.func1`), so it is not watched until it is named, and is reported once.

**Schedules.** robfig/cron keeps no spec text, so the schedule is read from what it parsed: five fields, a seconds field with a seconds parser, descriptors such as `@daily`, and `CRON_TZ=`, in the spec's zone or else the cron's `Location`. `@every 5m` is `every 5m`. A time a spring-forward gap removes is refused, since robfig/cron skips it where CronWatch would expect it later, as are a zone that is not an IANA zone and a `cron.Schedule` of your own.

**Context.** A robfig/cron job has no context and returns nothing, so it fails only by panicking and `cronwatch.Current` is nil inside it. For one that logs and fails by returning an error, make it with `Watcher.Func`, which gets the run's context (cancelled at the job's timeout) and its `JobContext`:

```go
w := robfigcron.New(cw, robfigcron.Options{})
c := cron.New(w.Option())
c.AddJob("0 2 * * *", w.Func("nightly-report", func(ctx context.Context, job *cronwatch.JobContext) error {
	path, err := buildReport(ctx)
	job.Log("Report written:", path)
	return err
}, cronwatch.Grace("15m")))
```

## gocron

```go
import (
	cronwatch "cronwatch.dev/go"
	cwgocron "cronwatch.dev/go/gocron"
	"github.com/go-co-op/gocron/v2"
)

s, err := gocron.NewScheduler(cwgocron.Watch(cw, cwgocron.Options{}))
if err != nil {
	log.Fatal(err)
}
s.NewJob(gocron.CronJob("0 2 * * *", false), gocron.NewTask(jobs.NightlyReport))
s.NewJob(gocron.DurationJob(15*time.Minute), gocron.NewTask(syncInvoices),
	gocron.WithName("sync-invoices"))
s.Start()
cw.Start(time.Minute) // checks for missed and stuck runs
```

The package is also called `gocron`, so import it under a name of its own. `Watch` is a `gocron.SchedulerOption` that adds gocron's event listeners to every job (`BeforeJobRuns`, `AfterJobRuns`, `AfterJobRunsWithError` and `AfterJobRunsWithPanic`): a run starts when gocron is about to run the job and ends with its outcome, an error failing it. A job added or updated later is declared at once, and one removed is unscheduled at the next sync (the next run of a job not declared yet, or the watcher's `Sync`).

**Names.** A job is named by `gocron.WithName`, else after its function without the package's path (`jobs.NightlyReport`). A function literal is not watched until it is named, and is reported once.

**Schedules.** Read from `Job.Schedule()`, which is why gocron 2.21 is the oldest supported. A cron job is converted as robfig/cron's, since gocron runs it with robfig/cron; a duration job is `every <duration>`, for an interval of one second or more (a shorter one is watched without a schedule and reported once); daily, weekly and monthly jobs with an interval of 1 become a cron of their times of day, days of the week and days of the month (the last day as `L`). Anything else (a random duration, an interval of more than one day, week or month, other days counted from the end of the month, a one-time job) is watched without a schedule and reported once. The zone is the scheduler's (`gocron.WithLocation`): gocron has no getter for it, so it is read from a job's next run once the scheduler has started, else `Options.Location`, else `time.Local`, gocron's default; set `Options.Location` to the scheduler's for jobs declared before it starts.

**Limits.** gocron's listeners are what CronWatch sees, and they leave some things out of reach:

- A task gets no CronWatch context: `cronwatch.Current` is nil inside it and a run's output is empty. For a job that should log, leave it out (`Options.Exclude`) and wrap its body in `job.Run` on a job you declare with the same schedule.
- gocron keeps one listener of each kind per job, so a job given its own `BeforeJobRuns`, `AfterJobRuns` or `AfterJobRunsWithError` replaces CronWatch's for that job. Without the before listener nothing is recorded; without an after listener its runs are left running, reported stuck at their timeout, and paired with that job's later ends. Leave such jobs out, or give them no listeners of their own.
- A run gocron skips before it starts (singleton mode, a distributed lock held elsewhere) records nothing, so it may be reported missed. `BeforeJobRunsSkipIfBeforeFuncErrors` is worse: gocron calls it after `BeforeJobRuns`, so a run it skips has already been started, is never ended, and is reported stuck. Leave jobs with that option out.
- gocron recovers a panic only for a job with a panic listener, so CronWatch's records the failed run and panics again with the same value, which ends the program, as the panic would have without CronWatch.
- Options that change when a job runs without showing in its definition are not seen: `WithIntervalFromCompletion` (CronWatch counts an interval from a run's start), `WithStartAt`, `WithStopAt`, `WithLimitedRuns`, and a daylight saving policy other than the default. Runs of one job at once are paired with their ends in order, since gocron names only the job that ended.

## River

```go
import (
	cronwatch "cronwatch.dev/go"
	cwriver "cronwatch.dev/go/river"
	"github.com/riverqueue/river"
	"github.com/riverqueue/river/riverdriver/riverpgxv5"
	"github.com/riverqueue/river/rivertype"
	"github.com/robfig/cron/v3"
)

w := cwriver.New(cw, cwriver.Options{
	Kinds: map[string][]cronwatch.JobOption{"send_invoice": nil}, // jobs that are not periodic
})
workers := river.NewWorkers()
river.AddWorker(workers, &NightlyReportWorker{})
river.AddWorker(workers, w.CheckWorker())

nightly, err := cron.ParseStandard("0 2 * * *")
if err != nil {
	log.Fatal(err)
}
config := &river.Config{
	Workers:    workers,
	Middleware: []rivertype.Middleware{w.Middleware()},
	PeriodicJobs: []*river.PeriodicJob{
		w.PeriodicJob(nightly, func() (river.JobArgs, *river.InsertOpts) {
			return NightlyReportArgs{}, nil
		}, &river.PeriodicJobOpts{ID: "nightly-report"}, cronwatch.Grace("15m")),
		w.CheckPeriodicJob(5 * time.Minute),
	},
}
client, err := river.NewClient(riverpgxv5.New(pool), config)
```

River keeps a periodic job's schedule to itself, so `w.PeriodicJob` stands in for `river.NewPeriodicJob`: the same arguments, then CronWatch's job options. It declares the job, named by the periodic job's `ID`, else by the kind of the args its constructor returns, and marks each job it inserts with the CronWatch job's name in its metadata (`"cronwatch"`), so whichever process works it records its runs under that name. A robfig/cron schedule (`cron.ParseStandard`, as River's own docs use) is converted in the process's zone, where River asks for its fire times; `river.PeriodicInterval`, or any schedule a constant time apart, is `every <interval>`; anything else is reported and watched without a schedule.

`w.Middleware()` goes in `river.Config.Middleware` and records each attempt of a marked job, and of the kinds `Options.Kinds` names (for jobs that are not periodic, each a job named after its kind), as a run. The worker's context carries the run's `JobContext`, so `cronwatch.Current(ctx)` logs to it, and the job's timeout. Retries follow [the rule above](#retries): River recovers a panic, which the run records first; a `river.JobSnooze` or `river.JobCancel`, or a job cancelled from outside while it runs, is given back.

`w.CheckWorker()` is the worker for the check job (kind `cronwatch_check`, one attempt, since the next check repeats a failed one), and `w.CheckPeriodicJob(5 * time.Minute)` schedules it; River's leader inserts it once for the whole deployment. Each check first declares again without its schedule any job of this app's that no periodic job holds any more. A worker process that makes no periodic jobs finds each job's definition in the store, so give every process of one app the same periodic jobs, as River asks you to anyway, and the same app name.

Periodic jobs changed while the client runs are followed through the watcher. One made again by `w.PeriodicJob` with the `ID` of an earlier one replaces it (after River's `Remove` or `Clear`, with a new schedule, say). One taken out of River's bundle is taken out of the watcher's too, beside the bundle's own call, and loses its schedule at once, so it is never reported missed:

```go
client.PeriodicJobs().RemoveByID("nightly-report")
w.RemoveByID("nightly-report") // also w.Remove(periodicJob) and w.Clear()
```

River 0.44.1 is the oldest supported. River 0.45 and newer need Go 1.26.

## Asynq

```go
import (
	cronwatch "cronwatch.dev/go"
	cwasynq "cronwatch.dev/go/asynq"
	"github.com/hibiken/asynq"
)

w := cwasynq.New(cw, cwasynq.Options{})

// The scheduler: asynq's own, declaring each entry.
scheduler := w.NewScheduler(redisOpt, &asynq.SchedulerOpts{Location: time.UTC})
scheduler.Register("0 2 * * *", asynq.NewTask("report:nightly", nil))
scheduler.RegisterWith("*/15 * * * *", asynq.NewTask("invoices:sync", nil),
	[]cronwatch.JobOption{cronwatch.Grace("5m")})
scheduler.Register("*/5 * * * *", cwasynq.CheckTask())

// The server, perhaps in another process.
mux := asynq.NewServeMux()
mux.Use(w.Middleware())
mux.HandleFunc("report:nightly", nightlyReport)
mux.Handle(cwasynq.CheckType, w.CheckHandler())
```

Asynq keeps a scheduler's entries to itself, so `w.NewScheduler` (and `w.NewSchedulerFromRedisClient`) make asynq's own `*asynq.Scheduler`, embedded in a `cwasynq.Scheduler` whose `Register` and `Unregister` also declare the entry's task type as a job. `RegisterWith` takes CronWatch's job options as a slice, before Asynq's own options. `w.NewPeriodicTaskManager(opts)` wraps a periodic task manager's config provider, so its configs are declared each time the manager reads them, and a config it stops giving is unscheduled. The cronspec is read as Asynq reads it (robfig/cron's standard parser: five fields, descriptors, `@every`, `CRON_TZ=`) in the scheduler's `Location`, UTC by default as in Asynq. The task type is the job's name; two entries of one type on different cronspecs are one job without a schedule, reported once.

`w.Middleware()` goes on the server's `ServeMux` and records each attempt of a task whose type a scheduler in this process declared, whose type `Options.Tasks` names, or whose type the store holds as this app's job: a server in a process of its own finds the scheduler's jobs there, looking each type up once a minute. The handler's context carries the run's `JobContext` and the job's timeout. Retries follow [the rule above](#retries): `asynq.SkipRetry` is a failure (Asynq archives the task), a panic is recorded and panicked again for Asynq to recover, and `asynq.RevokeTask` is given back.

`cwasynq.CheckTask()` (type `cronwatch:check`, no retries) and `w.CheckHandler()` run the check: register the task with the scheduler every five minutes and the handler on the server. The scheduler's process and the server's must agree on the app's name, so set `CRONWATCH_APP_ID` when their executables differ.

Asynq 0.25.1 is the oldest supported and 0.26.0 the newest tested.
