# cronwatch.dev/go

Cron and scheduled-job monitoring that lives inside your Go app. Wrap a job once; every run is recorded in a database you already have, and you are told when a run is missed, fails, gets stuck, runs slow or goes over budget. No server to run, no account to make.

This is the Go port of [`@cronwatch/sdk`](https://www.npmjs.com/package/@cronwatch/sdk), under way: the same rules, the same alert text and the same stored rows, so a Go process and a Node process can share one database, and every port reads the tables the others write. It has the core (jobs, runs, runs that span calls, checks, silences, sources, deferred delivery and the triage hook), the memory store, a `database/sql` store for SQLite, Postgres and MySQL, the SDK's alert channels, Claude triage, the pg_cron source, the dashboard with its JSON API, and job handlers for platform crons; the scheduler integrations follow ([DESIGN.md](DESIGN.md) has the plan and how each part works). It is not released yet.

Docs: [cronwatch.dev](https://cronwatch.dev/docs/)

## Install

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

A run is recorded when the function returns: a returned error is the failure and is returned from `Run`, and a panic is recorded as a failed run and carries on up the stack. The store failing never stops a job; store errors go to the error handler (`cronwatch.WithErrorHandler`, standard error by default). `cronwatch.RunValue` runs a function that returns a value: a string is the output when nothing was logged, and an `*http.Response` of 400 or more fails the run. Inside a job, `cronwatch.Current(ctx)` is its `JobContext`.

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
cw.Start(time.Minute)
```

## Dashboard

`cw.Routes(...)` is the dashboard and its small JSON API as an `http.Handler`: every job's health, its last day and week drawn as timelines, its runs with their output, and buttons to check, silence and forget. It is the SDK's, page for page and byte for byte, so the `@cronwatch/mcp` server works against it as it does against a Node app. It installs as an app on a phone (a manifest, icons and a service worker, served without the token).

```go
routes, err := cw.Routes(cronwatch.WithToken(os.Getenv("CRONWATCH_TOKEN")))
mux.Handle("/cronwatch/", routes)                               // mounted at /cronwatch
mux.Handle("/ops/cron/", http.StripPrefix("/ops/cron", routes)) // or anywhere, stripped
```

Everything needs the token: send it as `Authorization: Bearer <token>`, or open the dashboard once with `?token=<token>` and a cookie keeps the browser signed in. `/api/check` also takes the client's cron secret, so a platform cron can run checks. With no token, the routes answer 503, except in development (`CRONWATCH_ENV`, `APP_ENV` or `GO_ENV` set to `development`, `dev`, `local`, `test` or `testing`), where they make one and print a sign-in link on the first request; `cronwatch.WithoutToken()` serves them open, behind your own auth. The base path is found from the request: what `http.StripPrefix` took off, else the part of the `ServeMux` pattern before its wildcard or trailing slash, else `/cronwatch`; `cronwatch.WithBasePath` sets it. Behind a proxy, `cronwatch.WithOrigin("https://app.example.com")` or `cronwatch.WithTrustProxy()` gives the public origin the cross-site check and the cookie use.

## Platform crons

`job.Handler(fn)` is a job as an `http.Handler`, for a cron that calls a URL (Cloud Scheduler, Vercel, a crontab line running curl). A request must carry `Authorization: Bearer <CRON_SECRET>`; each one runs the function as a recorded run and is answered with how it went.

```go
mux.Handle("POST /api/cron/nightly", nightly.Handler(func(ctx context.Context, job *cronwatch.JobContext, w http.ResponseWriter, r *http.Request) error {
	return buildReport(ctx)
}))
```

The answer is `{"ok","job","run","status","durationMs"}`, 200 or 500, unless the function wrote its own, in which case a status of 400 or more fails the run. `cronwatch.HandlerValue` takes a function returning a value, such as the `*http.Response` of a call it made, which becomes the answer. Without a secret the handler answers 503 outside development; `cronwatch.WithoutSecret()` lets anyone in. `cronwatch.Lambda(handler)` is any handler (a job's, or the dashboard) as an AWS Lambda function behind API Gateway or a function URL, for `lambda.Start`, with no AWS module in this one.

## Checks

Missed and stuck runs are found by a check. A long-running service calls `cw.Start(time.Minute)`; a program run from a crontab checks from a second crontab line, or calls `cw.Check(ctx)` itself.

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
```

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
