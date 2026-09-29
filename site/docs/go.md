---
title: Go
description: cronwatch.dev/go in a Go app: jobs with context, the check, the dashboard as an http.Handler, job handlers and AWS Lambda, the database/sql store, alert channels, Claude triage, pg_cron, and sharing one database with the other languages.
order: 3.291
---

# Go

`cronwatch.dev/go` is a port of `@cronwatch/sdk`, not a new design. It decides missed, failed, stuck, slow and over budget by the same rules, sends the same alert text, and writes the same rows, so a Go process can share one database with a Node, Ruby, Python or PHP process and the [MCP server](/docs/mcp/) works against any of them. This page covers the module itself: a `main` a crontab runs, a service with a `net/http` server, a Lambda function. robfig/cron, gocron, River and Asynq have a page of their own: [Go schedulers](/docs/go-schedulers/).

```bash
go get cronwatch.dev/go
```

Go 1.25 or newer. The module requires nothing at all: cron expressions are read by a port of [croner](https://github.com/hexagon/croner), the parser the SDK uses, zones come from Go's own `time` package, and the SQL store works over the `*sql.DB` your app already has, with the driver it already uses. A program built for a machine with no zone database (a `scratch` container, say) imports `time/tzdata`.

The package is `cronwatch`, so the import reads `cronwatch "cronwatch.dev/go"`, as goimports writes it. The other packages come with it under the same version:

| Import | For |
|---|---|
| `cronwatch.dev/go` | the client, jobs and runs, the memory store, the dashboard and job handlers as `http.Handler`s, the Lambda adapter, `Console` and `ChannelFunc` |
| `cronwatch.dev/go/sqlstore` | SQLite, Postgres, MySQL and MariaDB through `database/sql` |
| `cronwatch.dev/go/alerts` | Slack, Discord, webhook, email, SMS and error tracker channels, on `net/http` alone |
| `cronwatch.dev/go/triage` | Claude triage, over plain HTTP |
| `cronwatch.dev/go/pgcron` | watching pg_cron's jobs |
| `cronwatch.dev/go/storetest` | the contract test for a store of your own |

The scheduler integrations are modules of their own (`cronwatch.dev/go/robfigcron`, `/gocron`, `/river`, `/asynq`), so an app pulls only the scheduler it uses; see [Go schedulers](/docs/go-schedulers/).

## Create one client

```go
import (
	"database/sql"
	"os"

	cronwatch "cronwatch.dev/go"
	"cronwatch.dev/go/alerts"
	"cronwatch.dev/go/sqlstore"
	_ "modernc.org/sqlite"
)

db, err := sql.Open("sqlite", "file:/var/lib/app/app.db")
if err != nil {
	log.Fatal(err)
}
store, err := sqlstore.New(db, sqlstore.SQLite) // or sqlstore.Postgres, sqlstore.MySQL
if err != nil {
	log.Fatal(err)
}
slack, err := alerts.Slack(alerts.SlackOptions{WebhookURL: os.Getenv("SLACK_WEBHOOK_URL")})
if err != nil {
	log.Fatal(err)
}
cw, err := cronwatch.New(
	cronwatch.WithStore(store),
	cronwatch.WithAlerts(slack),
	cronwatch.WithRetention("30d"),
)
if err != nil {
	log.Fatal(err)
}
defer cw.Close()
```

One client per app, made once at startup and shared: it is safe for use by many goroutines at once, as are its jobs, run handles, job contexts and every store. Options are functions, applied in the order given, and `New` returns an error for one it cannot take. `cronwatch.MustNew(...)` panics instead, for a package-level variable. With no options the client keeps everything in memory and writes alerts to the console.

## Declare and run a job

```go
nightly, err := cw.Job("nightly-report",
	cronwatch.Schedule("0 2 * * *"), cronwatch.Timezone("UTC"),
	cronwatch.Grace("15m"), cronwatch.Timeout(30*time.Minute),
	cronwatch.Expect("Report written"), cronwatch.Budget("cost", 2))
if err != nil {
	log.Fatal(err)
}

err = nightly.Run(ctx, func(ctx context.Context, job *cronwatch.JobContext) error {
	path, err := buildReport(ctx)
	if err != nil {
		return err
	}
	job.Log("Report written:", path) // kept with the run, shown in alerts
	job.Metric("cost", 1.2)          // watched against budgets and baselines
	return nil
})
```

The run is recorded when the function returns. A returned error is the failure, and `Run` returns it, so your own error handling still works. A panic is recorded as a failed run (`panic: <value>` and the frames where it happened) and then carries on up the stack, so a run is never left running to be reported stuck later. The store failing never stops a job: store errors go to the error handler (`cronwatch.WithErrorHandler`, standard error by default), and the job's own outcome is returned. A run is recorded as it ended even when the caller's context was cancelled first: the store is written under `context.WithoutCancel`, so the context's values (a trace id) still reach it.

Declare each job once, at startup, and keep the handle; `cw.MustJob` panics where `Job` returns an error, for a package-level declaration. Without a handle, `cw.Run(ctx, "nightly-report", fn)` declares the job on first use (or again, when given options). A name is 1 to 120 letters, digits, `.`, `_`, `:` or `-`.

Options are applied in the order given, and a stored definition keeps that order, so a Go process writes the same JSON a Node process does for the same options in the same order. Durations take the SDK's text or a Go value: `Grace("15m")`, `Grace(15*time.Minute)` and `Grace(900000)` (milliseconds) are all the same grace. Text is stored as written, a `time.Duration` as its milliseconds.

A function that returns a value runs through `cronwatch.RunValue`, which returns it. A string is the run's output when nothing was logged (and what `Expect` checks), and an `*http.Response` with a status of 400 or more fails the run with `HTTP <status> <reason>`, so a job that calls an API and returns its answer fails when the API does:

```go
res, err := cronwatch.RunValue(ctx, sync, func(ctx context.Context, job *cronwatch.JobContext) (*http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, "POST", "https://partner.example.com/sync", nil)
	if err != nil {
		return nil, err
	}
	return http.DefaultClient.Do(req)
})
```

The `JobContext` has `Name()`, `RunID()`, `StartedAt()` (epoch milliseconds), `Log(parts...)`, `Metric(name, value)` and `Metrics(values)`. `Log` joins its parts with spaces: strings as they are, errors as `Name: message` (`PathError: open x: no such file or directory`, or `Error: ...` for an unnamed error), anything else as JSON. The run keeps the last 16 KB. Code deep in a call chain finds the run with `cronwatch.Current(ctx)`, which is nil outside one.

### Context and the timeout

The context the function gets is the caller's with the job's `Timeout` added (an hour by default), and it carries the `JobContext`. When the timeout passes, the context is cancelled with a cause that names the job: `context.Cause(ctx)` is `job "nightly-report" passed its timeout of 30m`. Go cannot stop a goroutine, so nothing is interrupted: pass the context to everything that takes one, and return `context.Cause(ctx)` from a loop that stops early, which fails the run with that reason. A run that goes on past its timeout is marked stuck by the next check; if it finishes later, a late failure is written without a second alert and a late success closes the stuck alert with a recovery.

## Run the check

A job that never starts cannot report itself, so something has to look. A long-running process (a server, a worker, a process running a scheduler) checks in a goroutine:

```go
cw.Start(time.Minute) // until cw.Stop() or cw.Close()
```

The first check runs a second after `Start`, then one every interval (a minute when 0, five seconds at least). A second `Start` does nothing, and `Stop` lets a check in flight finish. One process checking is enough; running `Start` in every replica is harmless, since a check judges each run once. A serverless function does not run between requests, so call `cw.Check` from a cron there instead, or point one at the dashboard's `/api/check`.

A program run from a crontab exits when it is done, so nothing inside it notices the run that never happened. Add a second crontab line that checks, on a store both reach. Both commands declare the job, so the check knows its schedule before its first run:

```
# m  h  dom mon dow  command
0    2  *   *   *    /usr/local/bin/nightly report
*/5  *  *   *   *    /usr/local/bin/nightly check
```

```go
// The same declaration in both commands: the crontab's line, as a schedule.
nightly := cw.MustJob("nightly-report",
	cronwatch.Schedule("0 2 * * *"), cronwatch.Timezone("UTC"), cronwatch.Grace("15m"))

switch os.Args[1] {
case "check":
	result, err := cw.Check(ctx)
	if err != nil {
		log.Fatal(err)
	}
	fmt.Printf("checked %d jobs, sent %d alerts\n", len(result.Jobs), len(result.Alerts))
case "report":
	// A returned error fails the run and is returned here, so the process exits non-zero.
	if err := nightly.Run(ctx, report); err != nil {
		log.Fatal(err)
	}
}
```

[`examples/crontab`](https://github.com/phillips-jon/cronwatch/tree/main/packages/go/examples/crontab) in the repository is this program, with a test that runs its two commands on one SQLite file. `Check` returns a `*CheckResult` with `CheckedAt`, `Jobs`, `Alerts` and `Pruned`; its error is for the store failing as the check starts. Calls at the same time share one check, which runs to the end even when the first caller's context is cancelled, while each caller stops waiting when its own context ends.

## The dashboard

`cw.Routes(...)` is the dashboard and JSON API as an `http.Handler`, the same pages and endpoints as the TypeScript routes, byte for byte: the board's counts by health, a timeline of the last day with a lane per job, the table of every job, and for each job its last seven days, runs and definition, all drawn on the server with no script.

```go
routes, err := cw.Routes(cronwatch.WithToken(os.Getenv("CRONWATCH_TOKEN")))
if err != nil {
	log.Fatal(err)
}
mux := http.NewServeMux()
mux.Handle("/cronwatch/", routes)                               // mounted at /cronwatch
mux.Handle("/ops/cron/", http.StripPrefix("/ops/cron", routes)) // or anywhere, stripped
```

The base path its links use is found from the request: what `http.StripPrefix` took off, else the part of the `ServeMux` pattern before its trailing slash or wildcard (`/cronwatch/`, `/cronwatch/{path...}` and `GET /t/{tenant}/cron/` all work), else `/cronwatch`. A router that does neither passes `cronwatch.WithBasePath("/ops/cron")`, or `""` for the root. `cw.MustRoutes(...)` panics where `Routes` returns an error, which is only for a `WithOrigin` that is not an http or https URL.

- `cronwatch.WithToken(t)`: the token. Without the option it reads `CRONWATCH_TOKEN`; an empty string counts as unset. Send it as `Authorization: Bearer <token>`, or open the dashboard once with `?token=<token>` and a cookie keeps the browser signed in. Without a token, while the environment is development, the routes make a token of their own and print a sign-in link to standard output on the first request (naming the host only when `WithOrigin` is set or the request's host is loopback, `localhost`, a name ending in `.localhost`, `127.0.0.0/8` or `::1`, and otherwise leaving it out, since a client chooses it: `Sign in: /cronwatch/?token=... on this server (the first request's host is not local, so the link leaves it out)`); anywhere else they answer 503. The environment is the first of `CRONWATCH_ENV`, `APP_ENV` and `GO_ENV` that is set, and `development`, `dev`, `local`, `test` and `testing` count as development.
- `cronwatch.WithoutToken()`: serve the routes to anyone, for a mount behind your own auth.
- `cronwatch.WithOrigin("https://app.example.com")`: the public origin, pinned whatever a request says, for the cross-site check on writes, the cookie's `Secure` flag, redirects and the sign-in line.
- `cronwatch.WithTrustProxy()`: take the origin from the first `X-Forwarded-Proto` and `X-Forwarded-Host`. Only behind a proxy that sets or overwrites both.

The token rules, cookie, cross-site rule and every endpoint are the SDK's; see [Dashboard and API](/docs/dashboard/). `/api/check` also accepts the client's cron secret as a bearer, so an outside cron can run the check over HTTP (`POST`, or `GET` with the bearer). A body over 1 MiB is answered 413. The dashboard is installable as a web app, with its manifest, icons and service worker under the mount point; see [Install it as an app](/docs/dashboard/#install-it-as-an-app). A store failure, or a panic, is answered 500 and reported to the error handler as `routes`.

## Jobs a URL starts

Some platforms run scheduled work by calling a URL: Cloud Scheduler, a hosting provider's cron, an outside cron service, a crontab line running curl. `job.Handler(fn)` is that endpoint, an `http.Handler` that runs `fn` as a recorded run for each request carrying `Authorization: Bearer <secret>`, and answers with JSON saying how the run went:

```go
mux.Handle("POST /api/cron/nightly", nightly.Handler(func(ctx context.Context, job *cronwatch.JobContext, w http.ResponseWriter, r *http.Request) error {
	path, err := buildReport(ctx)
	job.Log("Report written:", path)
	return err
}))
```

The secret is `cronwatch.WithSecret(s)` on the handler, else the client's cron secret (`cronwatch.WithCronSecret`, which reads `CRON_SECRET` by default), compared in constant time. A wrong or missing bearer is answered 401 and runs nothing. With no secret at all, outside development, the handler answers 503 and reports it once to the error handler, rather than let anyone on the internet run the job; `cronwatch.WithoutSecret()` (or a client made `WithoutCronSecret()`) opts out on purpose, for an endpoint your platform already protects.

A run is answered 200 or 500 with `{"ok","job","run","status","durationMs"}`, and the error's first line as `"error"` for a caller who sent the secret. The context is the request's with the job's timeout. The function may answer the request itself through `w`, and a status of 400 or more written there fails the run. `cronwatch.HandlerValue(job, fn)` takes a function that returns a value: an `*http.Response` it returns (the answer of a call it made, say) is copied to the caller and fails the run at 400 or more, and a string is the run's output when nothing was logged. A panic in the function is a failed run, answered 500.

### AWS Lambda

`cronwatch.Lambda(h)` turns any handler, a job's or the dashboard, into an AWS Lambda function behind API Gateway (a REST API, or an HTTP API with either payload format) or a function URL, for `lambda.Start` from `github.com/aws/aws-lambda-go`, which your app already imports; this module needs no AWS module.

```go
func main() {
	handler := nightly.Handler(func(ctx context.Context, job *cronwatch.JobContext, w http.ResponseWriter, r *http.Request) error {
		path, err := buildReport(ctx)
		job.Log("Report written:", path)
		return err
	})
	lambda.Start(cronwatch.Lambda(handler))
}
```

A function EventBridge Scheduler invokes directly has no headers to carry a bearer, and IAM already decides who may invoke it, so give its handler `cronwatch.WithoutSecret()`. Without a server that runs between requests, run the check from a schedule of its own.

## Stores

`cronwatch.NewMemoryStore()` is the default. Nothing survives a restart, so a miss cannot be noticed across one, and each process has its own. When the environment is production (`CRONWATCH_ENV`, `APP_ENV` or `GO_ENV` set to `production` or `prod`), the client warns once that it is using it.

`sqlstore.New(db, dialect, sqlstore.Prefix("cronwatch_"))` keeps the same three tables as the SDK's SQL stores in your database, through the `*sql.DB` you opened, with your driver. The package imports none:

| Dialect | Driver, for example | |
|---|---|---|
| `sqlstore.SQLite` | `modernc.org/sqlite` (`"sqlite"`) | WAL mode, `busy_timeout` 5000, `synchronous` NORMAL |
| `sqlstore.Postgres` | `github.com/jackc/pgx/v5/stdlib` (`"pgx"`) | tables made under an advisory lock, so many processes can start at once |
| `sqlstore.MySQL` | `github.com/go-sql-driver/mysql` (`"mysql"`) | MySQL 8.0.13 or newer, or MariaDB 10.6 or newer |

The tables (`cronwatch_jobs`, `cronwatch_runs`, `cronwatch_state`) are made on the client's first use. On Postgres and MySQL each statement runs on the pool on its own, in autocommit, so a run recorded inside a transaction of yours stays recorded if it rolls back. On SQLite the store holds one connection of the pool for its statements, so a pool limited to one connection (`db.SetMaxOpenConns(1)`) leaves your app none: give it room. MySQL commits `CREATE TABLE` at once, so let the first use happen outside a transaction. `store.Close()`, which `cw.Close()` calls, gives SQLite's connection back to the pool; the `*sql.DB` is yours and stays open. `Prefix` names the tables: lowercase letters, digits and underscores.

A store of your own implements `cronwatch.Store`: `Init`, `UpsertJob`, `GetJob`, `ListJobs`, `DeleteJob`, `InsertRun`, `UpdateRun`, `GetRun`, `ListRuns`, `LastRun`, `RunningRuns`, `GetState`, `SetState`, `Prune` and `Close`, with epoch milliseconds for every time. Three optional interfaces, checked by type assertion, are what keep processes sharing a store from judging a run twice or losing each other's updates: `RunUpdater` (`UpdateRunIf`), `StateComparer` (`CompareAndSetState`) and `RunDeleter` (`DeleteRunIf`, which takes back a queue attempt given back without failing; see [Go schedulers](/docs/go-schedulers/#retries)). They mean what the [TypeScript interface](/docs/stores/#writing-a-store) says. `storetest.Run(t, newStore)` runs the contract test the built-in stores pass.

## Alerts

```go
slack, err := alerts.Slack(alerts.SlackOptions{
	WebhookURL: os.Getenv("SLACK_WEBHOOK_URL"),
	Link:       func(a cronwatch.Alert) string { return "https://app.example.com/cronwatch/jobs/" + a.Job },
})
discord, err := alerts.Discord(alerts.DiscordOptions{WebhookURL: os.Getenv("DISCORD_WEBHOOK_URL")})
hook, err := alerts.Webhook(alerts.WebhookOptions{
	URL:    "https://hooks.example.com/cronwatch",
	Secret: os.Getenv("CRONWATCH_WEBHOOK_SECRET"),
})

page := cronwatch.ChannelFunc("pagerduty", func(ctx context.Context, a cronwatch.Alert) error {
	if a.Type == cronwatch.AlertRecovered {
		return nil
	}
	return pagerduty.Trigger(ctx, a.Title, a.Message)
})

cw, err := cronwatch.New(cronwatch.WithStore(store),
	cronwatch.WithAlerts(slack, discord, hook, page, cronwatch.Console()))
```

Each channel is made from an options struct and returns a `cronwatch.Channel`, or an error when a key, address or URL is missing. Every alert goes to every channel at once, each in a goroutine of its own with a 15 second context; a channel that returns an error goes to the error handler (as `alert channel <name>`) and never holds up the others. A channel that ignores its context and has not returned by then is left to finish, and gets nothing more until it has. `WithAlerts()` with no channels sends nothing.

A channel is any type with `Name() string` and `Send(ctx, alert, cc) error` that returns an error when the alert went nowhere; `cc.ReportError(err)` reports a problem that did not stop it (one of several recipients refusing it, say) to the error handler.

### Email, SMS and error trackers

The SDK's provider channels are in `cronwatch.dev/go/alerts` too, on `net/http` alone, with SES requests signed by SigV4 and no AWS SDK:

```go
email := alerts.EmailOptions{From: "CronWatch <alerts@example.com>", To: []string{"ops@example.com"}}

// Email. Each takes the EmailOptions, and returns a channel and an error.
alerts.Resend(alerts.ResendOptions{APIKey: os.Getenv("RESEND_API_KEY"), EmailOptions: email})
alerts.Postmark(alerts.PostmarkOptions{
	ServerToken: os.Getenv("POSTMARK_SERVER_TOKEN"), EmailOptions: email})
alerts.Sendgrid(alerts.SendgridOptions{APIKey: os.Getenv("SENDGRID_API_KEY"), EmailOptions: email})
alerts.Mailgun(alerts.MailgunOptions{APIKey: os.Getenv("MAILGUN_API_KEY"),
	Domain: "mg.example.com", Region: "eu", EmailOptions: email})
alerts.SES(alerts.SESOptions{Region: "us-east-1", AccessKeyID: os.Getenv("AWS_ACCESS_KEY_ID"),
	SecretAccessKey: os.Getenv("AWS_SECRET_ACCESS_KEY"), EmailOptions: email})

// SMS, one message per number, all at once. Recovered: true texts recoveries too.
alerts.Twilio(alerts.TwilioOptions{AccountSID: os.Getenv("TWILIO_ACCOUNT_SID"),
	AuthToken: os.Getenv("TWILIO_AUTH_TOKEN"), From: "+15005550006", To: []string{"+15551110000"}})

// Error trackers: one issue per job and alert type.
alerts.Sentry(alerts.SentryOptions{DSN: os.Getenv("SENTRY_DSN")})
alerts.Honeybadger(alerts.HoneybadgerOptions{APIKey: os.Getenv("HONEYBADGER_API_KEY")})
alerts.Datadog(alerts.DatadogOptions{APIKey: os.Getenv("DD_API_KEY"),
	Site: "datadoghq.eu", Tags: []string{"env:prod"}})
alerts.Rollbar(alerts.RollbarOptions{AccessToken: os.Getenv("ROLLBAR_ACCESS_TOKEN")})
alerts.Bugsnag(alerts.BugsnagOptions{APIKey: os.Getenv("BUGSNAG_API_KEY")})
alerts.NewRelic(alerts.NewRelicOptions{AccountID: os.Getenv("NEW_RELIC_ACCOUNT_ID"),
	APIKey: os.Getenv("NEW_RELIC_LICENSE_KEY")})
```

The options are the SDK's in Go's case: `SubjectPrefix` and `Link` in `EmailOptions`; `MessageStream` (Postmark); `Region` (`"eu"` for SendGrid, Mailgun and New Relic, the AWS region for SES); `SessionToken` and `ConfigurationSetName` (SES); `APIKeySID`, `APIKeySecret`, `MessagingServiceSID` and `Segments` (Twilio, 1 to 10, 0 for the default of 3); `Environment` and `Release` (Sentry); `Endpoint` (Honeybadger, Bugsnag); `Host` (Datadog); `ReleaseStage` (Bugsnag); `EventType` (New Relic); and `Recovered` and `Link` wherever the SDK has them. The zero value is always the default, so where the SDK sends recoveries unless told not to, Go has the negative: `SkipRecovered` for Sentry and Rollbar.

Each sends exactly the request the SDK's does: the same URL, headers and body, byte for byte (the package's tests replay the SDK's recorded requests), with the same idempotency key, event id or UUID for one alert, so a provider that deduplicates drops a resend whichever language sent it. Each request has one ten second deadline for connecting, sending and reading the answer, reads at most 1 MiB of it, and follows no redirect, so credentials never reach another address. A refused request is `<Provider> <origin> answered <status>: <start of the body>`, never the URL's path, with the channel's keys cut out. Every options struct takes an `HTTPClient` for a proxy or a test; without one, Go's default transport is used, which honours `HTTP_PROXY` and `HTTPS_PROXY`. [Alerts](/docs/alerts/#email-sms-and-error-trackers) describes what each one sends.

A webhook signs its body with `X-CronWatch-Signature: sha256=<hex>`. `alerts.Signature(secret, body)` is that hex, for a receiver in Go:

```go
body, err := io.ReadAll(r.Body)
if err != nil {
	return
}
want := "sha256=" + alerts.Signature(secret, string(body))
ok := hmac.Equal([]byte(want), []byte(r.Header.Get("X-CronWatch-Signature")))
```

### Processes that cannot send

A job can run somewhere that cannot reach Slack or a mail relay: a sandboxed worker, a program without the app's secrets. Give that process `cronwatch.WithDeliver(cronwatch.DeliverAtCheck)`:

```go
recorder, err := cronwatch.New(cronwatch.WithStore(store),
	cronwatch.WithDeliver(cronwatch.DeliverAtCheck))
```

It still records and evaluates every run, but queues each alert in the store instead of sending it. The next check in a process that sends normally delivers it, with triage if that process has it. Both processes must use the same store. See [processes that cannot send](/docs/alerts/#processes-that-cannot-send).

## pg_cron

pg_cron runs jobs inside Postgres, where nothing can wrap them. The `pgcron` source reads what pg_cron records instead: on every check it reads `cron.job`, declares each job with its schedule, and copies new rows of `cron.job_run_details` in as runs, so a job that stops running is missed, a failed run alerts and a run that never ends is stuck.

```go
import "cronwatch.dev/go/pgcron"

source := pgcron.New(db, pgcron.Options{Prefix: "db:"}) // the app's *sql.DB, any Postgres driver
cw, err := cronwatch.New(cronwatch.WithStore(store), cronwatch.WithSources(source))
cw.Start(time.Minute)
```

It reads through anything with `QueryContext`: a `*sql.DB`, `*sql.Conn` or `*sql.Tx`, opened with whatever Postgres driver the app uses (pgx's `stdlib` and `lib/pq` are both tested). Settings are read from `pg_settings`, so a setting the role may not read never aborts your transaction, and the source never commits or rolls back. `pgcron.Options` has `Jobs`, `JobIDs` and `Pick` to choose jobs, `Prefix`, `JobName`, `Options` and `OptionsFor` (job options for every job, or per job; the schedule and zone always come from pg_cron) and `Timezone` (by default the server's `cron.timezone`, else UTC). The rules for renamed jobs, runs cut off by a restart and history seen for the first time are the SDK's; see [Supabase and pg_cron](/docs/supabase/).

## Redaction

Before a run's output and error are stored, shown or sent anywhere, they are redacted. The default blanks values that look like secrets (secret-named pairs, credentials in URLs, authorization headers, private keys, JWTs, webhook URLs, and AWS, GitHub, Slack, Stripe, Google and API key formats), exactly what the SDK's default blanks: the patterns are the SDK's, run by an engine with JavaScript's semantics, so every case the SDK's tests hold gives the same bytes. An `Expect` rule is checked before redaction, so it still sees what was logged.

```go
cronwatch.New(cronwatch.WithoutRedaction()) // keep output as logged
cronwatch.New(cronwatch.WithRedact(func(text string) string {
	return cardNumber.ReplaceAllString(cronwatch.RedactSecrets(text), "[card]")
}))
```

A function given to `WithRedact` replaces the default; call `cronwatch.RedactSecrets` inside it, as above, to keep the default patterns and add your own. One that panics is reported to the error handler (as `redact`) and the default is used for that text.

## Triage

```go
import "cronwatch.dev/go/triage"

diagnose, err := triage.Anthropic(triage.AnthropicOptions{
	Context: "A Go service on Fly.io with a Postgres database.",
})
if err != nil {
	log.Fatal(err) // no ANTHROPIC_API_KEY
}
cw, err := cronwatch.New(cronwatch.WithAlerts(slack), cronwatch.WithTriage(diagnose))
```

`triage.AnthropicOptions`:

| Field | Default | |
|---|---|---|
| `Model` | `"claude-opus-5"` | any current model id |
| `Effort` | `"medium"` | `"low"`, `"medium"` or `"high"` |
| `MaxTokens` | `800` | a diagnosis is a paragraph |
| `Context` | | a sentence about the app, so advice is specific |
| `NoFallbacks` | `false` | set it to stop routing a policy refusal to Anthropic's default fallback model inside the same request, if your account or gateway rejects the beta |
| `APIKey` | `ANTHROPIC_API_KEY` | a missing key is an error from `Anthropic` |
| `BaseURL` | `ANTHROPIC_BASE_URL`, else `https://api.anthropic.com` | |
| `HTTPClient` | Go's default transport | used as a copy that never follows a redirect |

There is no Anthropic SDK to install: the Messages API is one POST, and it sends the request the SDK's official client sends. It runs only when an alert is sent (never per run, never for a recovery), once per alert, with one attempt and no retries. The client waits 25 seconds for it and the request gives up at 24, so the alert goes out without a diagnosis rather than late, and the failure is reported to the error handler. What is sent is in [AI triage](/docs/triage/). A triage of your own is any `cronwatch.TriageFunc`: `func(ctx context.Context, tc cronwatch.TriageContext) (string, error)`, given the alert and the job's five newest runs, answering `""` for no diagnosis.

## API

`cronwatch.New(options...)` and `cronwatch.MustNew(options...)`:

| Option | Default | |
|---|---|---|
| `WithStore(store)` | in memory | a store |
| `WithAlerts(channels...)` | the console | channels. `WithAlerts()` sends nothing |
| `WithTriage(fn)` | | a function returning a diagnosis |
| `WithSources(sources...)` | | where runs this process does not wrap come from, such as [pg_cron](#pg-cron). Each is synced at the start of every check; one that fails is reported and the check carries on |
| `WithCronSecret(s)`, `WithoutCronSecret()` | `$CRON_SECRET` | the bearer job handlers take and the dashboard's check endpoint accepts beside the token. `""` counts as unset |
| `WithRetention(d)` | `"30d"` | how long finished runs are kept. Each job's newest run is always kept |
| `WithDefaults(options...)` | | `Grace`, `Timeout`, `Timezone` and `FailuresBeforeAlert` for every job that does not set its own; any other option is an error |
| `WithRedact(fn)`, `WithoutRedaction()` | secret patterns | see [Redaction](#redaction) |
| `WithDeliver(mode)` | `DeliverNow` | `DeliverAtCheck` queues alerts for another process's check to send |
| `WithErrorHandler(fn)` | standard error | `func(err error, where string)` for failures outside jobs: the store, a channel, triage |
| `WithClock(fn)` | the system clock | a function returning epoch milliseconds; for tests |

`cw.Job(name, options...)` takes `Schedule` (five or six field cron, a nickname such as `"@hourly"`, or `"every 5m"`), `Timezone` (IANA; the process's zone, `time.Local`, by default), `Grace` (`"10m"`), `Timeout` (`"1h"`), `MaxDuration`, `Budget(metric, ceiling)` (once per metric), `Expect(text)` (the output must contain it), `ExpectMatch(re)` (a `*regexp.Regexp` it must match, stored as `matches /source/`), `ExpectFunc(fn)` (a function of the output; a panic in it fails the run), `FailuresBeforeAlert` (1), `Description` and `Tags`, with the rules in the [API reference](/docs/api/). `cronwatch.DescribeJob(name, options...)` is the definition options give, without a client.

The client:

| Method | |
|---|---|
| `Job(name, options...)`, `MustJob` | declare a job and get its handle |
| `Run(ctx, name, fn, options...)` | run without keeping a handle |
| `Check(ctx)` | find missed and stuck runs, send alerts, retry alerts no channel accepted, prune |
| `Start(every)`, `Stop()` | check in a goroutine; the interval is at least five seconds |
| `Jobs(ctx)`, `JobsWithRuns(ctx, limit)`, `JobSummary(ctx, name)` | summaries, without alerting |
| `Runs(ctx, name, limit)`, `GetRun(ctx, id)` | newest first; `limit` is 1 to 500 |
| `Silence(ctx, name, d)`, `Unsilence(ctx, name)` | stop alerts for a while; state keeps updating underneath |
| `Forget(ctx, name)` | remove a job and its runs |
| `ResumeRun(ctx, name, runID)` | `Resume` for a job declared in this process |
| `RecordRun(ctx, run, options...)` | record a run that happened elsewhere, for a source; returns the alerts it sent |
| `SyncJob(ctx, name)` | write a declaration to the store now, unless it already holds it |
| `Routes(options...)`, `MustRoutes` | the dashboard and JSON API |
| `DefinedJobs()` | the definitions declared in this process |
| `Close()` | stop the goroutine and close the store |

Every call that can reach the store takes a `context.Context` first and returns an error. Nothing panics for a bad option or a store failure, except the `Must` helpers.

## Runs that span calls

A run is normally one call. Work that starts in one place and ends in another (a job that hands work to a queue, a webhook that reports completion later) can be one run too: `Start` records it as running and returns a `*RunHandle`, and `Finish` on that handle, or on one from `Resume` in another process, ends it.

```go
sync := cw.MustJob("partner-sync",
	cronwatch.Schedule("0 * * * *"), cronwatch.Timeout(2*time.Hour))

h, err := sync.Start(ctx, cronwatch.WithRunID(batchID)) // records a running run
// later, perhaps in another process
h, err = sync.Resume(ctx, batchID) // or cw.ResumeRun(ctx, "partner-sync", batchID)
h.Log("imported", count, "rows")
h.Finish(ctx) // or h.Fail(ctx, err), or h.FinishWith(ctx, result)
```

`WithRunID` takes your own stable id, 1 to 200 characters: a start with an id already recorded for this job records nothing and returns a handle on that run, and one recorded for another job is an error, as is an id starting `pgcron:`. A store that fails is reported to the error handler, never returned. The handle has `ID()`, `Job()`, `StartedAt()`, `Log`, `Metric`, `Flush(ctx)` (append what is logged so far to the stored run), `Finish`, `FinishWith` and `Fail`, and `Active()`, false once it is finished. A run is judged once however many processes finish it: only the process whose conditional write lands evaluates it, and `Finish` returns nil when it recorded nothing. A run that is never finished is marked stuck by the first check after the job's `Timeout`, so set it to cover the whole span.

## Sharing a database with the other languages

The SQL store writes the same three tables as `@cronwatch/sdk/sqlite` and `@cronwatch/sdk/postgres`, the Ruby gem, and the Python and PHP stores (the MySQL tables are the PHP port's): the same names, columns and indexes, epoch milliseconds in the time columns, and the same JSON in the JSON columns, byte for byte, keys in the SDK's order. The module's tests share a SQLite file with the built SDK, and have a Node client and a Go client take turns on one job's state. Create the tables from any side; the others find them and leave them alone. Use the same prefix everywhere.

Each process alerts on the jobs it runs, and any side's check sees every job in the store. One dashboard shows them all, and one MCP server reads it. Give each job a name only one side uses.

The public types write the SDK's JSON through their `MarshalJSON`. Call it directly, or use a `json.Encoder` with `SetEscapeHTML(false)`, when the bytes must match: `json.Marshal` passes a type's own JSON through its HTML escaping, which rewrites `<`, `>` and `&`.

The cron reader matches croner with two exceptions, both for schedules that never make sense: a date no month has (`0 0 30 2 *`) is a schedule that never fires, where croner gives up; and a one-time date in place of a cron expression (`2026-12-01T00:00:00`) is refused.

## Kept in step

The TypeScript SDK is the source of truth. Its build generates cases (duration parsing, schedules across daylight saving, sequences of runs and checks with the alerts and state they must produce, alert titles and messages, redaction, each channel's requests, stats and health) into `conformance/` in the repository, and the Go tests replay every one, as the Ruby gem's and the Python and PHP packages' do; the dashboard is checked against the SDK's pages byte for byte. Cron parsing is also checked against croner itself on thousands of generated expressions. A change of behaviour lands in TypeScript first, the cases are regenerated, and the port is fixed until they pass. Where they disagree, the port is wrong: [open an issue](https://github.com/phillips-jon/cronwatch/issues).
