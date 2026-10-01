---
title: Elixir
description: The cronwatch package in an Elixir app: an instance in the supervision tree, jobs run in the calling process, the check, the dashboard and job handlers as Plugs in a Phoenix router, the Ecto store, alert channels, Claude triage, pg_cron, telemetry, a release's crontab, and sharing one database with the other languages.
order: 3.93
group: Elixir
---

# Elixir

The `cronwatch` package is a port of `@cronwatch/sdk`, not a new design. It decides missed, failed, stuck, slow and over budget by the same rules, sends the same alert text, and writes the same rows, so an Elixir process can share one database with a Node, Ruby, Python, PHP, Go, Rust, Java or .NET process and the [MCP server](/docs/mcp/) works against any of them. This page covers the package itself: a Phoenix app, a worker, a release a crontab runs. Oban and Quantum have a page of their own: [Elixir schedulers](/docs/elixir-schedulers/).

```elixir
# mix.exs
def deps do
  [
    {:cronwatch, "~> 0.8"}
  ]
end
```

Elixir 1.18 or newer on Erlang/OTP 27 or newer. The package needs only [`tz`](https://hex.pm/packages/tz) (the IANA zone database, compiled in, so zones work in a release on any image, with no `/usr/share/zoneinfo`) and `telemetry`. Cron expressions are read by a port of [croner](https://github.com/hexagon/croner), the parser the SDK uses, so every port agrees on every fire time. The rest is optional, and used when your app already has it:

| Dependency | For |
|---|---|
| `ecto_sql` and your repo's adapter | `Cronwatch.Store.Ecto`, on SQLite (`ecto_sqlite3`), Postgres (`postgrex`), or MySQL and MariaDB (`myxql`), and the pg_cron source |
| `plug` | the dashboard (`Cronwatch.Web`) and a job's handler (`Cronwatch.Handler`); every Phoenix app has it |
| `oban` 2.20 or newer | `Cronwatch.Oban`; see [Elixir schedulers](/docs/elixir-schedulers/#oban) |
| `quantum` 3.5 | `Cronwatch.Quantum`; see [Elixir schedulers](/docs/elixir-schedulers/#quantum) |

The alert channels and Claude triage need no HTTP client: each is one POST, sent by a small HTTP/1.1 client of the package's own over OTP's `:gen_tcp` and `:ssl`.

## Start an instance

An instance is a child of your application's supervision tree, after the repo it writes through:

```elixir
# lib/my_app/application.ex
children = [
  MyApp.Repo,
  {Cronwatch,
   store: {Cronwatch.Store.Ecto, repo: MyApp.Repo},
   alerts: [{Cronwatch.Alerts.Slack, webhook_url: System.fetch_env!("SLACK_WEBHOOK_URL")}],
   retention: "30d",
   check_every: :timer.minutes(1),
   jobs: [
     {"nightly-report",
      schedule: "0 2 * * *", timezone: "UTC", grace: "15m", timeout: "30m",
      expect: "Report written", budget: [cost: 2]}
   ]},
  MyAppWeb.Endpoint
]
```

One instance per app, started once. Its options are checked when it starts, so a bad option, schedule or job fails the app's boot with the SDK's message rather than the first run. It is named `Cronwatch`; `name: MyApp.OtherCronwatch` starts a second one, and every function then takes `instance: MyApp.OtherCronwatch`. With no options it keeps everything in memory and writes alerts through `Logger`.

The options are the SDK's in snake_case. Durations take the SDK's text (`"15m"`, `"1h30m"`), milliseconds (`:timer.minutes(15)`, `900_000`), or anything `to_timeout/1` takes (`%Duration{minute: 15}`, `[minute: 15]`); text is stored as written, the rest as its milliseconds. Functions that read or write the store answer `{:ok, value}` or `{:error, %Cronwatch.Error{}}`, each with a `!` variant that raises.

## Declare and run a job

Jobs are declared in the instance's `jobs:`, when it starts, or with `Cronwatch.job/2` (and `job!/2`), which answers a `%Cronwatch.Job{}` handle. Either way, `Cronwatch.run/3` runs the function as a recorded run:

```elixir
Cronwatch.run("nightly-report", fn job ->
  path = MyApp.Reports.build()                  # Cronwatch.cancelled?(job) turns true at the timeout
  Cronwatch.log(job, "Report written: #{path}")  # kept with the run, shown in alerts
  Cronwatch.metric(job, "cost", 1.2)             # watched against budgets and baselines
  {:ok, path}
end)
```

The function runs in the calling process, where your app's context lives: the Ecto sandbox in tests, Logger metadata, an OpenTelemetry span, an Oban worker's own process. `run/3` answers what the function answered. A raise, throw, exit, `{:error, reason}` or `:error` fails the run and is handed back as it came (raised again with its stacktrace, or returned), so your supervisor or queue sees exactly what it would have without CronWatch; anything else succeeds. `{:error, reason}` failing the run is Elixir's convention, not the SDK's, so a job that succeeds with an `{:error, _}` result should wrap it. The store failing never stops a job: store errors go to the error handler (`on_error`, `Logger.error` by default), and the job's own outcome is returned.

A name is 1 to 120 letters, digits, `.`, `_`, `:` or `-`, starting with a letter or digit. A name `run/3` has not seen is declared on first use, and job options among `run/3`'s options declare it again. Options are kept in the order given, and a stored definition keeps that order, so an Elixir process writes the same JSON a Node process does for the same options in the same order.

A binary the function returns, or `{:ok, binary}`, is the run's output when nothing was logged, and what `expect` checks. A `%Plug.Conn{}` it returns with a status of 400 or more fails the run with `HTTP <status> <reason>`, and so does a `%Req.Response{}` (or `{:ok, %Req.Response{}}`) when Req is loaded, so a job that calls an API and returns its answer fails when the API does.

`Cronwatch.log(job, value)` adds one line (a value that is not a binary is written with `to_string/1`, or `inspect/1` when it has no `String.Chars`), and `Cronwatch.metric(job, name, value)` records a number. The run keeps the last 16 KB. Code deeper down finds the run with `Cronwatch.current/0`, and `Cronwatch.log/1` and `metric/2` use it; a `Task` the job starts (`Task.async_stream` included) finds its parent's run through `$callers`, so it logs to the same run. During a run, Logger metadata carries `cronwatch_job` and `cronwatch_run`.

### Timeouts and processes that die

`Cronwatch.cancelled?(job)` turns true when the job passes its `timeout` (an hour by default), the SDK's abort signal. Nothing is interrupted and nothing is sent to your process's mailbox: check it where the work can stop early. A run that goes on past its timeout is marked stuck by the next check; if it finishes later, a late failure is written without a second alert and a late success closes the stuck alert with a recovery.

A process can be killed without running any code of its own: `Process.exit(pid, :kill)`, a linked process's crash, a request process ended when its client goes away. Every run's process is monitored, so one that dies with a run open has that run recorded as failed at once, with the exit reason (`exit: killed`), rather than left running to be reported stuck later. The recording after the function returns runs in a task of the instance, so a caller killed while it waits cannot cut it short.

Two options of `run/3` change where the function runs. `isolate: true` runs it in a task of the instance, so a crash does not take the caller down (it is still a failed run, handed back as an exit); the task has its own process dictionary and Ecto ownership, so a test with the sandbox must allow it. With `isolate: true`, `kill_at_timeout: true` stops the task at the job's timeout and records the run as a check would mark it, timed out, so the stuck alert goes out sooner.

## Run the check

A job that never starts cannot report itself, so something has to look. `check_every:` on the instance runs the check on an interval: the first a second after it starts, then one every interval, five seconds at least. Leave it out where another process checks, and call `Cronwatch.check/1` there, or start the interval later with `Cronwatch.start(every: "1m")` and `Cronwatch.stop/0`:

```elixir
{:ok, result} = Cronwatch.check()   # %Cronwatch.CheckResult{checked_at, jobs, alerts, pruned}
```

One node checking is enough; `check_every` on every node of a cluster is harmless, since a check judges each run once. Calls at the same time share one check, which runs in a process of its own to the end even when a caller gives up. With Oban, `Cronwatch.Oban.CheckWorker` in the Cron plugin's crontab checks once a minute across the cluster; see [Elixir schedulers](/docs/elixir-schedulers/#the-check).

### From a crontab

A release a crontab runs exits when it is done, so nothing inside it notices the run that never happened. Add a second crontab line that checks, on a store both reach:

```
# m  h  dom mon dow  command
0    2  *   *   *    /app/bin/my_app eval "MyApp.Nightly.main()"
*/5  *  *   *   *    /app/bin/my_app eval "Cronwatch.Release.check(MyApp.Cronwatch)"
```

Keep the instance's options in `config/runtime.exs`, where both lines read them, with the job declared there so the check knows its schedule before its first run:

```elixir
# config/runtime.exs
config :my_app, MyApp.Cronwatch,
  store: {Cronwatch.Store.Ecto, repo: MyApp.Repo},
  jobs: [{"nightly-report", schedule: "0 2 * * *", timezone: "UTC", grace: "15m"}]
```

```elixir
defmodule MyApp.Nightly do
  def main do
    {:ok, _} = Application.ensure_all_started([:cronwatch, :ecto_sql, :postgrex])
    {:ok, _} = MyApp.Repo.start_link()
    config = Application.fetch_env!(:my_app, MyApp.Cronwatch)
    {:ok, _} = Cronwatch.start_link([name: MyApp.Cronwatch] ++ config)

    result = Cronwatch.run("nightly-report", &MyApp.Reports.nightly/1, instance: MyApp.Cronwatch)
    # A failed run exits non-zero, so cron mails it.
    if result == :error or match?({:error, _}, result), do: System.halt(1)
  end
end
```

`Cronwatch.Release.check/2` starts what the check needs and nothing else (the store's repo, with at most two connections, and an instance with the options under `config :my_app, MyApp.Cronwatch`), without the app's endpoint or queues; it runs one check, prints what it did (`cronwatch: checked 3 jobs, sent 1 alert`) and exits non-zero when the check fails. Called where the instance is already running (`bin/my_app rpc` into the live node), it checks that instance, starts and stops nothing, and never halts the node. From source, `mix cronwatch.check MyApp.Cronwatch` does the same (`--otp-app` names the application whose configuration holds the options). [`examples/crontab`](https://github.com/phillips-jon/cronwatch/tree/main/packages/elixir/examples/crontab) in the repository is this program on SQLite, with a test that runs its release's two lines on one file.

## The dashboard

`Cronwatch.Web` is the dashboard and JSON API as a Plug, the same pages and endpoints as the TypeScript routes, byte for byte: the board's counts by health, a timeline of the last day with a lane per job, the table of every job, and for each job its last seven days, runs and definition, all drawn on the server with no script. In Phoenix, forward to it outside the `:browser` pipeline, since it has its own cross-site check and cookie and Phoenix's CSRF protection would refuse its forms:

```elixir
# lib/my_app_web/router.ex
scope "/" do
  forward "/cronwatch", Cronwatch.Web
end
```

A plain `Plug.Router` forwards to it the same way. Its base path is where the router mounted it (`conn.script_name`), so a mount under a path parameter or inside a scope works; `base_path:` wins over the mount, and without either it is `/cronwatch`.

Its options:

- `token:` the token. Left out (or `""`), it is `CRONWATCH_TOKEN`, read on each request; `{:system, "VAR"}` reads another variable, also on each request, so a release never bakes in its build machine's value. Send it as `Authorization: Bearer <token>`, or open the dashboard once with `?token=<token>` and a cookie keeps the browser signed in. Without a token, in development, the dashboard makes one and prints a sign-in link on its first request (naming the host only when `origin` is set or the request's host is loopback); anywhere else it answers 503. The environment is the first of `CRONWATCH_ENV`, `APP_ENV` and `MIX_ENV` that is set, and `development`, `dev`, `local`, `test` and `testing` count as development.
- `token: false`: serve it to anyone, for a mount behind your own auth, such as a `pipe_through` that signs in your admins.
- `origin: "https://app.example.com"`: the public origin, pinned whatever a request says, for the cross-site check on writes, the cookie's `Secure` flag, redirects and the sign-in line. Anything but an http or https URL is refused.
- `trust_proxy: true`: take the origin from the first `X-Forwarded-Proto` and `X-Forwarded-Host`. Only behind a proxy that sets or overwrites both.
- `instance:` the instance to show, `Cronwatch` by default.

Phoenix reads a forwarded plug's options when the router compiles, so the token, the environment and the instance are read on each request instead. A request body is read only when a route wants one, at most 1 MiB (413 past it); behind a Phoenix endpoint, the fields its `Plug.Parsers` already read are used. The token rules, cookie, cross-site rule and every endpoint are the SDK's; see [Dashboard and API](/docs/dashboard/). `GET /api` answers `{"ok":true,"library":"cronwatch","language":"elixir","version":...,"api":1}`, and a silence or unsilence over the API answers the job's summary after it, as `job`. `/api/check` also accepts the instance's cron secret as a bearer, so an outside cron can run the check over HTTP. The dashboard is installable as a web app, with its manifest, icons and service worker under the mount point; see [Install it as an app](/docs/dashboard/#install-it-as-an-app).

## Jobs a URL starts

Some platforms run scheduled work by calling a URL: Fly.io, Render, Gigalixir, a Kubernetes CronJob running `curl`, an outside cron service. `Cronwatch.Handler` is that endpoint, as a Plug: each request carrying `Authorization: Bearer <secret>` runs the function as a recorded run (trigger `"handler"`), answered with JSON saying how the run went.

```elixir
# lib/my_app_web/router.ex
forward "/cron/nightly", Cronwatch.Handler, job: "nightly-report", run: {MyApp.Reports, :nightly, []}
```

A router's options cannot hold an anonymous function, so `run:` is `{module, function, args}`, called as `MyApp.Reports.nightly(job, conn)` with the run's context and the `conn` before the args. The job is the one the instance declares under `job:`, or declared with no options on the first request; declare it in `jobs:` to give it a schedule.

The secret is `secret:` (a binary, or `{:system, "VAR"}` read on each request), else the instance's `cron_secret` (`CRON_SECRET` by default, read on each request), compared in constant time; `""` counts as unset. A wrong or missing bearer is answered 401 and runs nothing. With no secret at all, outside development, the handler answers 503 and reports it once to the error handler, rather than let anyone on the internet run the job; `secret: false` (or the instance's `cron_secret: false`) opts out on purpose, for an endpoint your platform already protects.

A run is answered 200 or 500 with `{"ok","job","run","status","durationMs"}`, and the error's first line as `"error"` for a caller who sent the secret. A function that returns a `%Plug.Conn{}` answers the request itself: it is sent as it is, and a status of 400 or more fails the run. The function runs in the request's process, so a request whose client goes away and whose process the server ends records a failed run; start the work under your own `Task.Supervisor` if it should outlive the request.

## Stores

`Cronwatch.Store.Memory` is the default. Nothing survives a restart, so a miss cannot be noticed across one, and each node has its own. When the environment is production (`CRONWATCH_ENV`, `APP_ENV` or `MIX_ENV` set to `production` or `prod`), the instance warns once that it is using it.

`Cronwatch.Store.Ecto` keeps the same three tables as the SDK's SQL stores in your database, through the Ecto repo you already have. The repo's adapter picks the dialect:

| Adapter | |
|---|---|
| `Ecto.Adapters.SQLite3` (`ecto_sqlite3`) | keep the repo's `journal_mode: :wal` (its default) and a `busy_timeout` of at least 5000; a `":memory:"` database needs `pool_size: 1` |
| `Ecto.Adapters.Postgres` (`postgrex`) | tables made under an advisory lock, so many nodes can start at once |
| `Ecto.Adapters.MyXQL` (`myxql`) | MySQL 8.0.13 or newer, or MariaDB 10.6 or newer |

```elixir
store: {Cronwatch.Store.Ecto, repo: MyApp.Repo, prefix: "app_cron_"}
```

The tables (`cronwatch_jobs`, `cronwatch_runs`, `cronwatch_state`) are made on the instance's first use, byte for byte as the SDK makes them. `prefix:` names them: lowercase letters, digits and underscores, not starting with a digit, at most 47 characters. An app that keeps its schema in migrations can run `Cronwatch.Store.Ecto.create_statements/1` from one. `dynamic_repo:` takes a repo started with `name: nil` (its pid) or under another name. A store call made inside your own `Repo.transaction/1` runs on a connection of its own, so a run recorded inside a transaction that rolls back stays recorded. Nothing uses Ecto's schemas: every statement is the SDK's, run with `Ecto.Adapters.SQL.query/4`.

A store of your own implements the `Cronwatch.Store` behaviour: `new/2`, `init`, `upsert_job`, `get_job`, `list_jobs`, `delete_job`, `insert_run`, `update_run`, `get_run`, `list_runs`, `last_run`, `running_runs`, `get_state`, `set_state`, `prune` and `close`, with epoch milliseconds for every time, and an optional `child_spec/1` when it needs a process, which the instance supervises. Three optional callbacks are what keep nodes sharing a store from judging a run twice or losing each other's updates: `update_run_if`, `compare_and_set_state` and `delete_run_if` (which takes back an attempt a queue gave back without failing; see [Elixir schedulers](/docs/elixir-schedulers/#retries)). They mean what the [TypeScript interface](/docs/stores/#writing-a-store) says. `Cronwatch.StoreCase` is the contract the built-in stores pass, as an ExUnit case template:

```elixir
defmodule MyApp.StoreTest do
  use Cronwatch.StoreCase, store: {MyApp.Store, []}, fixture: File.read!("path/to/conformance/store.json")
end
```

## Alerts

`alerts:` is a list of channels, each `{module, options}` with the SDK's options in snake_case, checked when the instance starts:

```elixir
{Cronwatch,
 store: store,
 alerts: [
   {Cronwatch.Alerts.Slack,
    webhook_url: System.fetch_env!("SLACK_WEBHOOK_URL"),
    link: fn alert -> "https://app.example.com/cronwatch/jobs/#{alert.job}" end},
   {Cronwatch.Alerts.Discord, webhook_url: System.fetch_env!("DISCORD_WEBHOOK_URL")},
   {Cronwatch.Alerts.Webhook,
    url: "https://hooks.example.com/cronwatch",
    secret: System.fetch_env!("CRONWATCH_WEBHOOK_SECRET")},
   Cronwatch.Alerts.fun("pagerduty", fn alert ->
     if alert.type != "recovered", do: MyApp.PagerDuty.trigger(alert.title, alert.message), else: :ok
   end),
   Cronwatch.Alerts.Console
 ]}
```

Giving `alerts:` replaces the default console channel, and `alerts: []` sends nothing. Every alert goes to every channel at once, each in a task of its own with 15 seconds to finish; a send past its time is killed, its socket with it, and a channel that fails or raises goes to the error handler (as `alert channel <name>`) and never holds up the others. An alert is stored with the state that opens its condition before it is sent, so one whose node dies mid-send is sent by a later check, once, or twice if a channel took it just before the node died (see [Limits](/docs/limits/)). Stopping the instance waits for a check under way before the store and the rest of the instance stop. `Cronwatch.Alerts.fun(name, f)` wraps a function of the alert (or of the alert and a `Cronwatch.ChannelContext`) answering `:ok` or `{:error, reason}`; a channel of your own implements the `Cronwatch.Channel` behaviour (`init/1`, `name/1` and `send/3`). `Cronwatch.Alerts.Console` writes through `Logger`, `Logger.info` for a recovery and `Logger.error` for anything else, so the line carries your Logger's format and metadata.

### Email, SMS and error trackers

```elixir
email = [from: "CronWatch <alerts@example.com>", to: ["ops@example.com"]]

# Email. Each takes the email options, at the top level or under email:.
{Cronwatch.Alerts.Resend, [api_key: System.fetch_env!("RESEND_API_KEY")] ++ email}
{Cronwatch.Alerts.Postmark, [server_token: System.fetch_env!("POSTMARK_SERVER_TOKEN")] ++ email}
{Cronwatch.Alerts.SendGrid, [api_key: System.fetch_env!("SENDGRID_API_KEY")] ++ email}
{Cronwatch.Alerts.Mailgun, [api_key: System.fetch_env!("MAILGUN_API_KEY"), domain: "mg.example.com", region: "eu"] ++ email}
{Cronwatch.Alerts.SES,
 [region: "us-east-1",
  access_key_id: System.fetch_env!("AWS_ACCESS_KEY_ID"),
  secret_access_key: System.fetch_env!("AWS_SECRET_ACCESS_KEY")] ++ email}

# SMS, one message per number, all at once. recovered: true texts recoveries too.
{Cronwatch.Alerts.Twilio,
 account_sid: System.fetch_env!("TWILIO_ACCOUNT_SID"),
 auth_token: System.fetch_env!("TWILIO_AUTH_TOKEN"),
 from: "+15005550006", to: ["+15551110000"]}

# Error trackers: one issue per job and alert type.
{Cronwatch.Alerts.Sentry, dsn: System.fetch_env!("SENTRY_DSN")}
{Cronwatch.Alerts.Honeybadger, api_key: System.fetch_env!("HONEYBADGER_API_KEY")}
{Cronwatch.Alerts.Datadog, api_key: System.fetch_env!("DD_API_KEY"), site: "datadoghq.eu", tags: ["env:prod"]}
{Cronwatch.Alerts.Rollbar, access_token: System.fetch_env!("ROLLBAR_ACCESS_TOKEN")}
{Cronwatch.Alerts.Bugsnag, api_key: System.fetch_env!("BUGSNAG_API_KEY")}
{Cronwatch.Alerts.NewRelic, account_id: 1234567, api_key: System.fetch_env!("NEW_RELIC_LICENSE_KEY")}
```

The options are the SDK's in snake_case: `subject_prefix` and `link` among the email options; `message_stream` (Postmark); `region` (`"eu"` for SendGrid, Mailgun and New Relic, the AWS region for SES); `session_token` and `configuration_set_name` (SES); `api_key_sid`, `api_key_secret`, `messaging_service_sid` and `segments` (Twilio, 1 to 10, default 3); `environment` (Sentry, Honeybadger and Rollbar, `"production"` by default); `release` (Sentry); `headers` (the webhook, extra request headers as `{name, value}` pairs, in the order sent); `endpoint` (Honeybadger, Bugsnag); `host` (Datadog); `release_stage` (Bugsnag); `event_type` (New Relic); and `recovered` and `link` wherever the SDK has them, with the SDK's defaults (`recovered: false` leaves a Sentry or Rollbar channel's recoveries out). No channel's options print a credential with `inspect`, so a crash report or an `IO.inspect` of your config does not leak one.

Each sends exactly the request the SDK's does: the same URL, headers and body, byte for byte (the package's tests replay the SDK's recorded requests), with the same idempotency key, event id or UUID for one alert, so a provider that deduplicates drops a resend whichever language sent it. SES is signed with SigV4, with no AWS SDK. Each request has one ten second deadline for connecting, sending and reading the answer, reads at most 1 MiB of it, follows no redirect (so credentials never reach another address), always verifies TLS against the system's roots, and reads no proxy from the environment. A refused request names only the URL's origin, never its path, with the channel's keys cut out. `transport:` on a channel, triage or the instance takes a `Cronwatch.Transport` of your own, for your Finch pool, a proxy or Req's retries; the behaviour's docs have one over Req in a dozen lines. [Alerts](/docs/alerts/#email-sms-and-error-trackers) describes what each one sends.

A webhook posts the [alert payload](/docs/alerts/#the-alert-payload) with `"schema": 1` as its first field, the same bytes every port sends; its JSON Schema is [cronwatch.dev/schemas/webhook/1.json](/schemas/webhook/1.json). A receiver reads the fields, not `title` and `message`, whose wording is not promised. The webhook signs its body with `X-CronWatch-Signature: sha256=<hex>`. `Cronwatch.Alerts.Webhook.signature(secret, body)` is that hex, for a receiver in Elixir, over the raw body as it arrived:

```elixir
expected = "sha256=" <> Cronwatch.Alerts.Webhook.signature(secret, raw_body)
received = conn |> Plug.Conn.get_req_header("x-cronwatch-signature") |> List.first("")
ok? = Plug.Crypto.secure_compare(received, expected)
```

`Plug.Crypto.secure_compare/2` answers false for two strings of different lengths, so a request with no signature is refused rather than crashing the plug.

### Processes that cannot send

A job can run somewhere that cannot reach Slack or a mail relay: a sandboxed worker, a node without the app's secrets. Give that instance `deliver: :check`:

```elixir
{Cronwatch, store: store, deliver: :check}
```

It still records and evaluates every run, but queues each alert in the store instead of sending it. The next check in an instance that sends normally delivers it, with triage if that instance has it. Both must use the same store. See [processes that cannot send](/docs/alerts/#processes-that-cannot-send).

## pg_cron

pg_cron runs jobs inside Postgres, where nothing can wrap them. `Cronwatch.Sources.PgCron` reads what pg_cron records instead: on every check it reads `cron.job`, declares each job with its schedule, and copies new rows of `cron.job_run_details` in as runs, so a job that stops running is missed, a failed run alerts and a run that never ends is stuck.

```elixir
{Cronwatch,
 store: {Cronwatch.Store.Ecto, repo: MyApp.Repo},
 sources: [{Cronwatch.Sources.PgCron, repo: MyApp.Repo, prefix: "db:"}],
 check_every: :timer.minutes(1)}
```

It reads through a Postgres Ecto repo on the database pg_cron runs in (its `cron.database_name`), or through `query:`, a function of the SQL and its parameters, for a connection that is not a repo. Settings are read from `pg_settings`, so a setting the role may not read never fails the check or your transaction. Its options: `jobs`, `job_ids` and `pick` to choose jobs; `prefix`, `job_name`, and `options` (job options for every job, or a function answering them per job; the schedule and zone always come from pg_cron); and `timezone` (by default the server's `cron.timezone`, else UTC). The rules for renamed jobs, runs cut off by a restart and history seen for the first time are the SDK's; see [Supabase and pg_cron](/docs/supabase/).

## Redaction

Before a run's output and error are stored, shown or sent anywhere, they are redacted. The default blanks values that look like secrets (secret-named pairs, credentials in URLs, authorization headers, private keys, JWTs, webhook URLs, and AWS, GitHub, Slack, Stripe, Google and API key formats), exactly what the SDK's default blanks: the patterns are the SDK's, run by an engine with JavaScript's semantics, so every case the SDK's tests hold gives the same bytes. An `expect` rule is checked before redaction, so it still sees what was logged. Redaction runs before the cap, so the cut never keeps the rest of a secret whose label it cut off.

```elixir
redact: false  # keep output as logged
redact: fn text -> Regex.replace(~r/\b\d{4}(?:[ -]?\d{4}){3}\b/, Cronwatch.redact_secrets(text), "[card]") end
```

A function given to `redact:` replaces the default; call `Cronwatch.redact_secrets/1` inside it, as above, to keep the default patterns and add your own.

`expect:` takes a binary (the output must contain it), a function of the output answering true or false (a raise in it fails the run), or `{:matches, "source", "flags"}` for a JavaScript regular expression, stored as `matches /source/flags` and run by the same engine, so it reads as the SDK reads it. An Elixir `Regex` is refused: it is PCRE, which reads a pattern differently, and another port could not run what it stored.

## Triage

```elixir
{Cronwatch,
 alerts: [{Cronwatch.Alerts.Slack, webhook_url: System.fetch_env!("SLACK_WEBHOOK_URL")}],
 triage: {Cronwatch.Triage.Anthropic, context: "A Phoenix app on Fly.io with a Postgres database."}}
```

`Cronwatch.Triage.Anthropic`'s options:

| Option | Default | |
|---|---|---|
| `model` | `"claude-opus-5"` | any current model id |
| `effort` | `"medium"` | `"low"`, `"medium"` or `"high"` |
| `max_tokens` | 800 | a diagnosis is a paragraph |
| `context` | | a sentence about the app, so advice is specific |
| `fallbacks` | `true` | `false` stops routing a policy refusal to Anthropic's default fallback model inside the same request, if your account or gateway rejects the beta |
| `api_key` | `ANTHROPIC_API_KEY` | the instance refuses to start with neither |
| `base_url` | `ANTHROPIC_BASE_URL`, else `https://api.anthropic.com` | |
| `transport` | the instance's, else the built-in client | as for the channels |

There is no Anthropic package to add: the Messages API is one POST, and it sends the request the SDK's official client sends. It runs only when an alert is sent (never per run, never for a recovery), once per alert, with one attempt and no retries. The instance waits 25 seconds for it and the request gives up at 24, so the alert goes out without a diagnosis rather than late, and the failure is reported to the error handler. What is sent is in [AI triage](/docs/triage/). A triage of your own implements the `Cronwatch.Triage` behaviour: `triage/2` is given the alert and the job's newest runs, and answers `{:ok, diagnosis}`, or `nil` for none.

## Telemetry

The instance emits `:telemetry` events, which Phoenix LiveDashboard, `telemetry_metrics` and OpenTelemetry's handlers read:

| Event | |
|---|---|
| `[:cronwatch, :run, :start]`, `:stop`, `:exception` | a span around each run's function, with the job, run id and trigger, and the run's status on `:stop` |
| `[:cronwatch, :check, :start]`, `:stop`, `:exception` | each check, with its counts on `:stop` |
| `[:cronwatch, :alert, :sent]`, `:failed`, `:queued`, `:dropped` | each alert per channel |
| `[:cronwatch, :error]` | whatever the error handler hears |

## API

The instance's options:

| Option | Default | |
|---|---|---|
| `name` | `Cronwatch` | a second instance needs a name of its own |
| `store` | `Cronwatch.Store.Memory` | `{module, options}` |
| `alerts` | `[Cronwatch.Alerts.Console]` | channels. `[]` sends nothing |
| `triage` | | `{Cronwatch.Triage.Anthropic, options}`, or a module of your own |
| `sources` | | where runs this instance does not wrap come from, such as [pg_cron](#pg-cron). Each is synced at the start of every check; one that fails is reported and the check carries on |
| `integrations` | | `{Cronwatch.Oban, options}` or `{Cronwatch.Quantum, options}`; see [Elixir schedulers](/docs/elixir-schedulers/) |
| `jobs` | | `{name, options}` pairs, declared when the instance starts |
| `check_every` | | check on an interval |
| `cron_secret` | `$CRON_SECRET` | the bearer job handlers take and the dashboard's check endpoint accepts beside the token. `false` for none |
| `retention` | `"30d"` | how long finished runs are kept. Each job's newest run is always kept |
| `defaults` | | `grace`, `timeout`, `timezone` and `failures_before_alert` for every job that does not set its own; any other option is refused |
| `redact` | secret patterns | a function, or `false`; see [Redaction](#redaction) |
| `deliver` | `:now` | `:check` queues alerts for another instance's check to send |
| `transport` | the built-in client | for every channel and triage without one of their own |
| `on_error` | `Logger.error` | a function of the error and where, for failures outside jobs: the store, a channel, triage |
| `clock` | the system clock | a function answering epoch milliseconds; for tests |

A job's options: `schedule` (five or six field cron, a nickname such as `"@hourly"`, or `"every 5m"`), `timezone` (IANA, matched without regard to case; the zone `$TZ` or `/etc/localtime` names by default, else UTC), `grace` (`"10m"`), `timeout` (`"1h"`), `max_duration`, `budget` (a keyword list of metric and ceiling, `[cost: 2]`), `expect`, `failures_before_alert` (1), `description` and `tags`, with the rules in the [TypeScript API reference](/docs/api/).

The functions, each taking `instance:` among its options:

| Function | |
|---|---|
| `job(name, options)` | declare a job and get its handle |
| `run(job_or_name, fun, options)` | run as a recorded run; `trigger`, `isolate`, `kill_at_timeout` and `discard_when` among the options |
| `current()`, `log/1,2`, `metric/2,3`, `cancelled?/1` | the run in progress |
| `check()` | find missed and stuck runs, send alerts, retry alerts no channel accepted, prune |
| `start(every: d)`, `stop()` | check on an interval, for an instance started without `check_every` |
| `jobs()`, `jobs_with_runs(limit)`, `job_summary(name)` | summaries, without alerting |
| `runs(name, limit)`, `get_run(id)` | newest first; `limit` is 1 to 500 |
| `silence(name, d)`, `unsilence(name)` | stop alerts for a while; state keeps updating underneath |
| `forget(name)` | remove a job and its runs. A job still declared in code comes back: on its next run, or at the next check or dashboard read of a process that declares it |
| `start(job, options)`, `resume(job, id)`, `resume_run(name, id)` | runs that span calls |
| `record_run(run, options)` | record a run that happened elsewhere, for a source; answers the alerts it sent; a metric that is not a finite number is refused and nothing is recorded |
| `sync_job(name)` | write a declaration to the store now, unless it already holds it |
| `defined_jobs()` | the jobs declared in this instance |

`Cronwatch.Error` has a `kind`: `:invalid` (an option, name, schedule or run id the SDK refuses, with its message), `:store` (the store's own error as `reason`) and `:other`. A failed run's error is written `Name: message` from the exception's module (`RuntimeError: disk full`), with up to five frames of its stacktrace, each `Module.function/arity (file:line)`; a throw is written `throw: <value>`, an exit `exit: <reason>`, and a returned `{:error, reason}` as its reason (an exception in it as the exception, `:error` alone as `error`).

## Runs that span calls

A run is normally one call. Work that starts in one place and ends in another (a job that hands work to a queue, a webhook that reports completion later) can be one run too: `start` records it as running and answers a `%Cronwatch.RunHandle{}`, and `finish` on that handle, or on one from `resume` in another process or node, ends it.

```elixir
{:ok, run} = Cronwatch.start("partner-sync", id: batch_id)   # records a running run
Cronwatch.log(run, "fetched 1,200 rows")
Cronwatch.flush(run)                                          # appends what was logged so far
# later, perhaps on another node
{:ok, run} = Cronwatch.resume_run("partner-sync", batch_id)
Cronwatch.finish(run)                                         # or Cronwatch.fail(run, reason)
```

`id:` takes your own stable id, 1 to 200 characters: a start with an id already recorded for this job records nothing and answers a handle on that run, and one recorded for another job is an error, as is an id starting `pgcron:`. A store that fails is reported to the error handler, never returned. The handle has `id`, `job` and `started_at`, with `log/2`, `metric/3`, `flush/1`, `finish/2`, `fail/2` and `active?/1`. A run is judged once however many processes finish it: only the process whose conditional write lands evaluates it. A handle whose process ends while it is active records nothing; a run that is never finished is marked stuck by the first check after the job's `timeout`, so set it to cover the whole span.

## Sharing a database with the other languages

The Ecto store writes the same three tables as `@cronwatch/sdk/sqlite` and `@cronwatch/sdk/postgres`, the Ruby gem, and the Python, PHP, Go, Rust, Java and .NET stores (the MySQL tables are the PHP, Go, Rust, Java and .NET ports'): the same names, columns and indexes, epoch milliseconds in the time columns, and the same JSON in the JSON columns, byte for byte, keys in the SDK's order. The package's tests share a SQLite file with the built SDK, and have a Node client and an Elixir client take turns on one job's state. Create the tables from any side; the others find them and leave them alone. Use the same prefix everywhere.

Each process alerts on the jobs it runs, and any side's check sees every job in the store. One dashboard shows them all, and one MCP server reads it. Give each job a name only one side uses.

A map given where the SDK keeps an object's order (a `budget`, metrics) is written in its keys' term order, since Elixir maps have none; a keyword list keeps the order given. The cron reader matches croner, and the SDK, on every schedule, including the two that never make sense (see [Schedules](/docs/schedules/#schedule-syntax)).

## Kept in step

The TypeScript SDK is the source of truth. Its build generates cases (duration parsing, schedules across daylight saving, sequences of runs and checks with the alerts and state they must produce, alert titles and messages, redaction, each channel's requests, stats and health) into `conformance/` in the repository, and the Elixir tests replay every one, as the Ruby gem's and the Python, PHP, Go, Rust, Java and .NET packages' do; the dashboard is checked against the SDK's pages byte for byte, straight into the plug, through a `Plug.Router` under Bandit and through a Phoenix endpoint. Cron parsing is also checked against croner itself on thousands of generated expressions. A change of behaviour lands in TypeScript first, the cases are regenerated, and the port is fixed until they pass. Where they disagree, the port is wrong: [open an issue](https://github.com/phillips-jon/cronwatch/issues).
