# cronwatch.dev/go

Cron and scheduled-job monitoring that lives inside your Go app. Wrap a job once; every run is recorded in a database you already have, and you are told when a run is missed, fails, gets stuck, runs slow or goes over budget. No server to run, no account to make.

This is the Go port of [`@cronwatch/sdk`](https://www.npmjs.com/package/@cronwatch/sdk), under way: the same rules, the same alert text and the same stored rows, so a Go process and a Node process can share one database, and every port reads the tables the others write. This first phase has the core (jobs, runs, runs that span calls, checks, silences, sources, deferred delivery and the triage hook), the memory store and a `database/sql` store for SQLite, Postgres and MySQL; the alert channels, Claude triage, the pg_cron source, the dashboard and the scheduler integrations follow ([DESIGN.md](DESIGN.md) has the plan and how each part works). It is not released yet.

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
cd packages/go && go test -race ./...           # the core, standard library only
cd packages/go/sqltest && go test -race ./...   # the SQL store with real drivers
```

Run `npm ci && npm run build` at the repository root first: the croner parity test (`internal/schedule`) and the SQLite file shared with Node (`sqltest`) use the built SDK, and skip, with the reason, without it. The tests set the process zone to UTC, as the conformance fixtures are made in UTC.

`sqltest` is a module of its own so that the drivers it uses (`modernc.org/sqlite`, `github.com/jackc/pgx/v5`, `github.com/go-sql-driver/mysql`) never appear in the `cronwatch.dev/go` module. SQLite always runs; Postgres, MySQL and MariaDB run when these are set:

```bash
docker run -d --name cw-pg -e POSTGRES_PASSWORD=cw -p 55432:5432 postgres:17
docker run -d --name cw-mysql -e MYSQL_ROOT_PASSWORD=cw -e MYSQL_DATABASE=cw -p 53306:3306 mysql:8.4
docker run -d --name cw-mariadb -e MARIADB_ROOT_PASSWORD=cw -e MARIADB_DATABASE=cw -p 53307:3306 mariadb:11.4

CRONWATCH_TEST_PG=postgres://postgres:cw@127.0.0.1:55432/postgres \
CRONWATCH_TEST_MYSQL=mysql://root:cw@127.0.0.1:53306/cw \
CRONWATCH_TEST_MARIADB=mysql://root:cw@127.0.0.1:53307/cw \
go test -race ./...
```
