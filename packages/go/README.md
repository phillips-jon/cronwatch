# cronwatch.dev/go

Cron and scheduled-job monitoring that lives inside your Go app. Wrap a job once; every run is recorded in a database you already have, and you are told when a run is missed, fails, gets stuck, runs slow or goes over budget. No server to run, no account to make.

This is the Go port of [`@cronwatch/sdk`](https://www.npmjs.com/package/@cronwatch/sdk): the same rules, the same alert text and the same stored rows, so a Go process and a Node, Ruby, Python, PHP or Rust process can share one database, and every port reads the tables the others write. It has the core (jobs, runs, runs that span calls, checks, silences, sources, deferred delivery and the triage hook), the memory store, a `database/sql` store for SQLite, Postgres, MySQL and MariaDB, the SDK's alert channels, Claude triage, the pg_cron source, the dashboard with its JSON API, job handlers for platform crons, and integrations for robfig/cron, gocron, River and Asynq ([DESIGN.md](DESIGN.md) has how each part works).

Docs: [cronwatch.dev](https://cronwatch.dev/docs/)

## Install

```bash
go get cronwatch.dev/go
go get cronwatch.dev/go/robfigcron   # or /gocron, /river, /asynq, for a scheduler you run
```

Go 1.25 or newer. The module requires nothing: cron expressions are read by a port of [croner](https://github.com/hexagon/croner) (the parser the SDK uses) and zones come from Go's own `time` package. The SQL store works over the `*sql.DB` your app already has, with the driver it already uses; the module imports none.

## Use

```go
package main

import (
	"context"
	"database/sql"
	"log"
	"time"

	cronwatch "cronwatch.dev/go"
	"cronwatch.dev/go/sqlstore"
	_ "modernc.org/sqlite"
)

func main() {
	db, err := sql.Open("sqlite", "file:/var/lib/app/app.db")
	if err != nil {
		log.Fatal(err)
	}
	store, err := sqlstore.New(db, sqlstore.SQLite) // or sqlstore.Postgres, sqlstore.MySQL
	if err != nil {
		log.Fatal(err)
	}
	cw := cronwatch.MustNew(
		cronwatch.WithStore(store),
		cronwatch.WithAlerts(cronwatch.ChannelFunc("pager", func(ctx context.Context, a cronwatch.Alert) error {
			return page(ctx, a.Title, a.Message)
		})),
	)
	defer cw.Close()

	nightly := cw.MustJob("nightly-report",
		cronwatch.Schedule("0 2 * * *"), cronwatch.Timezone("UTC"),
		cronwatch.Grace("15m"), cronwatch.Timeout(30*time.Minute),
		cronwatch.Expect("Report written"), cronwatch.Budget("cost", 2))

	err = nightly.Run(context.Background(), func(ctx context.Context, job *cronwatch.JobContext) error {
		path, err := buildReport(ctx) // ctx is cancelled when the job's timeout passes
		job.Log("Report written:", path) // kept with the run, shown in alerts
		job.Metric("cost", 1.2)          // watched against budgets and baselines
		return err
	})
	if err != nil {
		log.Fatal(err)
	}
}
```

A run is recorded when the function returns: a returned error is the failure and is returned from `Run`, and a panic is recorded as a failed run and carries on up the stack (a job handler answers it 500 instead, as below). The store failing never stops a job; store errors go to the error handler (`cronwatch.WithErrorHandler`, standard error by default). `cronwatch.RunValue` runs a function that returns a value: a string is the output when nothing was logged, and an `*http.Response` of 400 or more fails the run. Inside a job, `cronwatch.Current(ctx)` is its `JobContext`.

## Schedulers

A scheduler you already run is watched with one line, each integration a module of its own so you pull only the one you use. Its jobs become CronWatch jobs with their schedules (checked against the scheduler's own fire times; one that cannot match exactly, such as a time daylight saving skips, is reported and watched without a schedule), every run is recorded, and a job taken out of the scheduler loses its schedule rather than being reported missed. Jobs are tagged with the integration and your app's name (`CRONWATCH_APP_ID`, else the executable's name), so two apps sharing a store never touch each other's jobs.

**robfig/cron v3** (`go get cronwatch.dev/go/robfigcron`): a `cron.Option`. A job is named after its function (`jobs.NightlyReport`) or type; name a closure, or give options, with `robfigcron.Named`. `watcher.Func` makes a job that gets the run's context and logs.

```go
c := cron.New(robfigcron.New(cw, robfigcron.Options{Chain: []cron.JobWrapper{cron.Recover(logger)}}).Option())
c.AddFunc("0 2 * * *", jobs.NightlyReport)
c.AddJob("*/15 * * * *", robfigcron.Named("sync-invoices", syncJob, cronwatch.Grace("5m")))
```

**gocron v2** (`go get cronwatch.dev/go/gocron`, gocron 2.21 or newer): its event listeners, as a scheduler option. Cron, duration, and daily, weekly and monthly jobs are read as schedules; a job is named by `gocron.WithName`, else its function.

```go
s, err := gocron.NewScheduler(cwgocron.New(cw, cwgocron.Options{}).Option())
s.NewJob(gocron.DailyJob(1, gocron.NewAtTimes(gocron.NewAtTime(2, 0, 0))), gocron.NewTask(jobs.NightlyReport))
```

**River** (`go get cronwatch.dev/go/river`, River 0.44.1 or newer): `w.PeriodicJob` in place of `river.NewPeriodicJob`, and a worker middleware that records each attempt, with `cronwatch.Current(ctx)` inside the worker.

```go
w := cwriver.New(cw, cwriver.Options{Kinds: map[string][]cronwatch.JobOption{"send_invoice": nil}})
river.AddWorker(workers, w.CheckWorker())
nightly, err := cron.ParseStandard("0 2 * * *") // github.com/robfig/cron/v3, as River's docs use
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
```

**Asynq** (`go get cronwatch.dev/go/asynq`, Asynq 0.25.1 or newer): a scheduler (or periodic task manager) that declares its entries, and a server middleware.

```go
w := cwasynq.New(cw, cwasynq.Options{})
scheduler := w.NewScheduler(redisOpt, &asynq.SchedulerOpts{Location: time.UTC})
scheduler.Register("0 2 * * *", asynq.NewTask("report:nightly", nil))
scheduler.Register("*/5 * * * *", cwasynq.CheckTask())

mux := asynq.NewServeMux()
mux.Use(w.Middleware())
mux.Handle(cwasynq.CheckType, w.CheckHandler())
```

Retries follow one rule everywhere: each attempt is a run, failing attempts open one alert and the attempt that succeeds closes it. An attempt given back without failing (a River snooze or cancel, an Asynq revoke) leaves no run.

## Alerts

Alerts go to the console until you give channels. `cronwatch.dev/go/alerts` has the SDK's, on `net/http` alone: Slack, Discord, a signed webhook, email through Resend, Postmark, SendGrid, Mailgun or SES, SMS through Twilio, and Sentry, Honeybadger, Datadog, Rollbar, Bugsnag and New Relic.

```go
slack, err := alerts.Slack(alerts.SlackOptions{WebhookURL: os.Getenv("SLACK_WEBHOOK_URL")})
email, err := alerts.Resend(alerts.ResendOptions{
	APIKey:       os.Getenv("RESEND_API_KEY"),
	EmailOptions: alerts.EmailOptions{From: "CronWatch <alerts@example.com>", To: []string{"ops@example.com"}},
})
cw, err := cronwatch.New(cronwatch.WithStore(store), cronwatch.WithAlerts(slack, email))
```

Each request is the SDK's, byte for byte, with one ten second deadline, no redirect followed, TLS verified, and errors that name only the provider and the URL's origin, with your keys cut out. Every options struct takes an `HTTPClient` for a proxy or a test.

## Triage

`cronwatch.dev/go/triage` asks Claude for a short diagnosis of each alert (never per run), over plain HTTP, with no SDK to install:

```go
diagnose, err := triage.Anthropic(triage.AnthropicOptions{Context: "A Go service on Fly.io with a Postgres database."}) // ANTHROPIC_API_KEY
cw, err := cronwatch.New(cronwatch.WithAlerts(slack), cronwatch.WithTriage(diagnose))
```

## pg_cron

`cronwatch.dev/go/pgcron` watches pg_cron's jobs, which run inside Postgres where nothing can wrap them: each check reads `cron.job` and `cron.job_run_details` through your `*sql.DB` (any driver) and records their runs, so missed, failed, stuck and slow jobs alert like your own.

```go
cw, err := cronwatch.New(cronwatch.WithStore(store), cronwatch.WithSources(pgcron.New(db, pgcron.Options{Prefix: "db:"})))
if err != nil {
	log.Fatal(err)
}
cw.StartChecking(time.Minute)
```

## Dashboard

`cw.Routes(...)` is the dashboard and its small JSON API as an `http.Handler`: every job's health, its last day and week drawn as timelines, its runs with their output, and buttons to check, silence and forget. It is the SDK's, page for page and byte for byte, so the `@cronwatch/mcp` server works against it as it does against a Node app. It installs as an app on a phone (a manifest, icons and a service worker, served without the token).

```go
routes, err := cw.Routes(cronwatch.WithToken(os.Getenv("CRONWATCH_TOKEN")))
mux.Handle("/cronwatch/", routes)                               // mounted at /cronwatch
mux.Handle("/ops/cron/", http.StripPrefix("/ops/cron", routes)) // or anywhere, stripped
```

Everything needs the token: send it as `Authorization: Bearer <token>`, or open the dashboard once with `?token=<token>` and a cookie keeps the browser signed in. `/api/check` also takes the client's cron secret, so a platform cron can run checks. With no token, the routes answer 503, except in development (`CRONWATCH_ENV`, `APP_ENV` or `GO_ENV` set to `development`, `dev`, `local`, `test` or `testing`), where they make one and print a sign-in link on the first request (naming the host only when `WithOrigin` is set or the request's host is loopback, since a client chooses it); `cronwatch.WithoutToken()` serves them open, behind your own auth. The base path is found from the request: what `http.StripPrefix` took off, else the part of the `ServeMux` pattern before its wildcard or trailing slash, else `/cronwatch`; `cronwatch.WithBasePath` sets it. Behind a proxy, `cronwatch.WithOrigin("https://app.example.com")` or `cronwatch.WithTrustProxy()` gives the public origin the cross-site check and the cookie use.

## Platform crons

`job.Handler(fn)` is a job as an `http.Handler`, for a cron that calls a URL (Cloud Scheduler, Vercel, a crontab line running curl). A request must carry `Authorization: Bearer <CRON_SECRET>`; each one runs the function as a recorded run and is answered with how it went.

```go
mux.Handle("POST /api/cron/nightly", nightly.Handler(func(ctx context.Context, job *cronwatch.JobContext, w http.ResponseWriter, r *http.Request) error {
	path, err := buildReport(ctx)
	job.Log("Report written:", path)
	return err
}))
```

The answer is `{"ok","job","run","status","durationMs"}`, 200 or 500 (a panic in the function too, recorded as a failed run), unless the function wrote its own, in which case a status of 400 or more fails the run; a panic after it began writing is recorded and then aborts the response, as net/http does. `cronwatch.HandlerValue` takes a function returning a value, such as the `*http.Response` of a call it made, which becomes the answer. Without a secret the handler answers 503 outside development; `cronwatch.WithoutSecret()` lets anyone in. `cronwatch.Lambda(handler)` is any handler (a job's, or the dashboard) as an AWS Lambda function behind API Gateway or a function URL, for `lambda.Start`, with no AWS module in this one.

## Checks

Missed and stuck runs are found by a check. A long-running service (a server, a worker, a process running a scheduler) calls `cw.StartChecking(time.Minute)`, a goroutine that checks every minute until `cw.Stop` or `cw.Close`; one process is enough, and more are harmless. A program run from a crontab checks from a second crontab line, on a store both reach ([`examples/crontab`](examples/crontab/main.go) is one):

```
# m  h  dom mon dow  command
0    2  *   *   *    /usr/local/bin/nightly report
*/5  *  *   *   *    /usr/local/bin/nightly check
```

Both commands declare the job, so the check knows its schedule before its first run; `report` runs it with `job.Run` and exits non-zero on the error `Run` returns, and `check` calls `cw.Check(ctx)`.

A run that starts in one call and ends in another (work handed to a queue, a webhook that reports back later) is one run too:

```go
h, err := nightly.Start(ctx, cronwatch.WithRunID(deliveryID))
// ... later, perhaps in another process:
h, err = nightly.Resume(ctx, deliveryID)
h.Log("done")
h.Finish(ctx) // or h.Fail(ctx, err); a run is judged once, however many processes finish it
```

## Testing

```bash
cd packages/go && go test -race ./...           # the core, the dashboard, the channels, triage and pg_cron (against fakes), standard library only
cd packages/go/sqltest && go test -race ./...   # the SQL store with real drivers
cd packages/go/robfigcron && go test -race ./... # and gocron, river, asynq, examples: each a module of its own
```

The integrations require their schedulers at the oldest release they support; CI also tests the newest (`go get` it first). River's tests need a Postgres (`CRONWATCH_TEST_PG`, each run in a schema of its own) and Asynq's end-to-end test a Redis (`CRONWATCH_TEST_REDIS=redis://127.0.0.1:56379/0`, from `docker run -d --name cw-redis -p 56379:6379 redis:7-alpine`); both skip without them.

Run `npm ci && npm run build` at the repository root first: the croner parity test (`internal/schedule`) and the SQLite file shared with Node (`sqltest`) use the built SDK, and skip, with the reason, without it. The dashboard is checked against `packages/ruby/test/web/golden.json`, the SDK's answers to a fixed seed, and `CRONWATCH_TEST_GO=1 npm test --workspace packages/mcp` drives the MCP server against it. The tests set the process zone to UTC, as the conformance fixtures are made in UTC.

`sqltest` is a module of its own so that the drivers it uses (`modernc.org/sqlite`, `github.com/jackc/pgx/v5`, `github.com/lib/pq`, `github.com/go-sql-driver/mysql`) never appear in the `cronwatch.dev/go` module. SQLite always runs; Postgres, MySQL and MariaDB run when these are set, and the pg_cron source against a real pg_cron (through pgx and lib/pq) when `CRONWATCH_TEST_PGCRON` names a Postgres with the extension preloaded:

```bash
docker run -d --name cw-pg -e POSTGRES_PASSWORD=cw -p 55432:5432 postgres:17
docker run -d --name cw-mysql -e MYSQL_ROOT_PASSWORD=cw -e MYSQL_DATABASE=cw -p 53306:3306 mysql:8.4
docker run -d --name cw-mariadb -e MARIADB_ROOT_PASSWORD=cw -e MARIADB_DATABASE=cw -p 53307:3306 mariadb:11.4
# pg_cron: postgres:16 with postgresql-16-cron installed, run with
#   postgres -c shared_preload_libraries=pg_cron -c cron.database_name=cw

CRONWATCH_TEST_PG=postgres://postgres:cw@127.0.0.1:55432/postgres \
CRONWATCH_TEST_MYSQL=mysql://root:cw@127.0.0.1:53306/cw \
CRONWATCH_TEST_MARIADB=mysql://root:cw@127.0.0.1:53307/cw \
CRONWATCH_TEST_PGCRON=postgres://postgres:cw@127.0.0.1:55433/cw \
go test -race ./...
```
