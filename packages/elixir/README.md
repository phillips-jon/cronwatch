# cronwatch for Elixir

Cron and scheduled-job monitoring that lives inside your Elixir service. Wrap a job once; every run is recorded in a database you already have, and you are told when a run is missed, fails, gets stuck, runs slow, goes over budget or quietly does nothing. No server to run, no account to make. This is the library behind [cronwatch.dev](https://cronwatch.dev).

This is the Elixir port of [`@cronwatch/sdk`](https://www.npmjs.com/package/@cronwatch/sdk): the same rules, the same alert text and the same stored rows, so an Elixir process and a Node, Ruby, Python, PHP, Go, Rust, Java or .NET process can share one database, and every port reads the tables the others write. It has jobs, runs, runs that span calls, checks, silences and telemetry; the memory store and a SQL store over Ecto on SQLite, Postgres, MySQL and MariaDB; the pg_cron source, the fifteen alert channels and Claude triage; the dashboard and a job's handler, as Plugs; the Oban and Quantum integrations; and a crontab's check. [DESIGN.md](https://github.com/cronwatchdev/cronwatch/blob/main/packages/elixir/DESIGN.md) has how each part works.

Docs: [cronwatch.dev](https://cronwatch.dev/docs/)

## Install

Elixir 1.18 or newer on Erlang/OTP 27 or newer. The package depends on [`tz`](https://hex.pm/packages/tz) (the time zone database, compiled in, so zones work in a release on any image) and `telemetry`, and nothing else; cron expressions are read by a port of [croner](https://github.com/hexagon/croner), the parser the SDK uses, so every port agrees on every fire time. The SQL store needs `ecto_sql` and the adapter your repo uses; the dashboard and a job's handler need `plug` (every Phoenix app has it).

```elixir
def deps do
  [
    {:cronwatch, "~> 0.12"},
    {:ecto_sqlite3, "~> 0.17"} # for Cronwatch.Store.Ecto on SQLite, if your app has no repo yet
  ]
end
```

## Use

An instance is a child of your application's supervision tree:

```elixir
children = [
  MyApp.Repo,
  {Cronwatch,
   store: {Cronwatch.Store.Ecto, repo: MyApp.Repo},
   alerts: [Cronwatch.Alerts.fun("pager", fn alert -> MyApp.Pager.page(alert.title, alert.message) end)],
   retention: "30d",
   check_every: :timer.minutes(1),
   jobs: [
     {"nightly-report",
      schedule: "0 2 * * *", timezone: "UTC", grace: "15m", timeout: "30m",
      expect: "Report written", budget: [cost: 2]}
   ]}
]
```

and a job's function is run as a recorded run, in the calling process:

```elixir
Cronwatch.run("nightly-report", fn job ->
  path = MyApp.Reports.build()                 # Cronwatch.cancelled?(job) turns true at the timeout
  Cronwatch.log(job, "Report written: #{path}") # kept with the run, shown in alerts
  Cronwatch.metric(job, "cost", 1.2)            # watched against budgets, floors and baselines
  {:ok, path}
end)
```

A raise, throw, exit, `{:error, reason}` or `:error` fails the run and is handed back as it came, so your supervisor or queue sees exactly what it would have without CronWatch. A binary the function returns, or `{:ok, binary}`, is the run's output when nothing was logged, and what `expect` checks. A process killed while running a job has its run recorded as failed at once. `isolate: true` runs the function in a task of the instance instead, and with `kill_at_timeout: true` it is stopped at the job's timeout and recorded as timed out. `Cronwatch.current/0` (and `log/1`, `metric/2`) find the run from the calling process, or from the process that started it, so a `Task` inside a job logs to it.

The checks look for missed and stuck runs, retry alerts no channel accepted and prune old runs. `check_every` runs them on an interval; leave it out where another process checks, and call `Cronwatch.check/1` from there:

```elixir
{:ok, result} = Cronwatch.check()
{:ok, _state} = Cronwatch.silence("nightly-report", "2h")
```

Options are the SDK's in snake_case. Durations take the SDK's text (`"15m"`, `"1h30m"`), milliseconds, or anything `to_timeout/1` takes (`%Duration{minute: 15}`); text is stored as written. `expect` takes a string, `{:matches, "source", "flags"}` for a JavaScript regular expression (run by the port's own engine, so it reads as the SDK reads it), or a function of the output; an Elixir `Regex` is refused, since PCRE reads a pattern differently. Functions that read or write the store answer `{:ok, value}` or `{:error, %Cronwatch.Error{}}`, with a `!` variant that raises.

### Runs that span calls

```elixir
{:ok, run} = Cronwatch.start("import", id: "batch-42")   # records a running run
Cronwatch.log(run, "fetched 1,200 rows")
Cronwatch.flush(run)                                     # appends what was logged so far
# later, perhaps in another process or node:
{:ok, run} = Cronwatch.resume_run("import", "batch-42")
Cronwatch.finish(run)                                    # or Cronwatch.fail(run, reason)
```

### Stores

`Cronwatch.Store.Memory` is the default, for tests and trying it out. `{Cronwatch.Store.Ecto, repo: MyApp.Repo, prefix: "cw_"}` keeps the SDK's three tables in your database through your own repo, on SQLite (`ecto_sqlite3`), Postgres (`postgrex`), or MySQL 8.0.13 and MariaDB 10.6 or newer (`myxql`). The tables are made on first use, byte for byte as the SDK makes them, so a Node process and an Elixir process can share them in either order; `Cronwatch.Store.Ecto.create_statements/1` gives the statements for a migration of your own. On SQLite keep `journal_mode: :wal` and a `busy_timeout` of at least 5000, and an in-memory database needs `pool_size: 1`. A store's writes never join a transaction your code has open, so a failed run is not rolled back with it.

A store of your own implements `Cronwatch.Store` and is held to the contract every store passes:

```elixir
defmodule MyApp.StoreTest do
  use Cronwatch.StoreCase, store: {MyApp.Store, []}, fixture: File.read!("path/to/conformance/store.json")
end
```

The `use` is what 1.x promises; the functions `Cronwatch.StoreCase` had besides are deprecated, and go in 1.0.

### Alerts and triage

The SDK's channels, request for request: `Cronwatch.Alerts.Slack`, `Discord`, `Webhook` (signed), `Resend`, `Postmark`, `SendGrid`, `Mailgun`, `SES`, `Twilio`, `Sentry`, `Honeybadger`, `Datadog`, `Rollbar`, `Bugsnag` and `NewRelic`, each given as `{module, opts}` with the SDK's options in snake_case, checked when the instance starts:

```elixir
alerts: [
  {Cronwatch.Alerts.Slack, webhook_url: System.fetch_env!("SLACK_WEBHOOK_URL")},
  {Cronwatch.Alerts.Resend,
   api_key: System.fetch_env!("RESEND_API_KEY"),
   from: "CronWatch <alerts@example.com>", to: ["ops@example.com"]}
],
triage: {Cronwatch.Triage.Anthropic, context: "A Phoenix app with a Postgres database."}
```

Requests go through a small HTTP/1.1 client of the package's own, over OTP's `:gen_tcp` and `:ssl`, with one ten second deadline, redirects refused, at most 1 MiB of any answer read as it arrives, TLS always verified, and only a URL's origin in any error; no credential is printed by `inspect`. `transport:` on a channel or the instance takes a `Cronwatch.Transport` of your own (over Req or Finch, say). `Cronwatch.Triage.Anthropic` reads `ANTHROPIC_API_KEY` unless given `api_key:`.

The webhook posts the alert with `"schema": 1` as its first field, the payload every CronWatch library sends ([its JSON Schema](https://cronwatch.dev/schemas/webhook/1.json)); read its fields, not `title` and `message`, whose wording is not promised. With a `secret:` it is signed, and `Cronwatch.Alerts.Webhook.signature(secret, raw_body)` gives a receiver the hex to compare with `Plug.Crypto.secure_compare/2`.

### pg_cron

`{Cronwatch.Sources.PgCron, repo: MyApp.Repo}` in the instance's `sources:` records the runs of pg_cron jobs inside a Postgres database, as the SDK's source does; `jobs:`, `job_ids:` or `pick:` choose which.

### The dashboard

`Cronwatch.Web` is the SDK's dashboard and JSON API as a Plug: the same pages, byte for byte, and the same API, so [`@cronwatch/mcp`](https://www.npmjs.com/package/@cronwatch/mcp) works against it. In Phoenix, forward to it outside the `:browser` pipeline (it has its own cross-site check and cookie):

```elixir
# lib/my_app_web/router.ex
scope "/" do
  forward "/cronwatch", Cronwatch.Web
end
```

It finds its base path from where the router mounted it. The token is `CRONWATCH_TOKEN`, read on each request (`token: "..."`, `token: {:system, "VAR"}`, or `token: false` to serve it open behind your own auth); send it as `Authorization: Bearer <token>`, or open the page once with `?token=<token>` (or enter it in the sign-in form) and a cookie keeps you signed in. A token or `CRONWATCH_TOKEN` of only whitespace counts as unset. In development with no token it makes one and prints a sign-in link; elsewhere with none it answers 503. `origin: "https://app.example.com"` or `trust_proxy: true` tell it the public origin behind a proxy. A request body is read only when a route wants one, at most 1 MiB; behind a Phoenix endpoint the fields its `Plug.Parsers` read are used. `/api/check` also takes the instance's cron secret as a bearer.

### A job's handler

`Cronwatch.Handler` runs a job for a platform cron that calls a URL, when the request carries `Authorization: Bearer <CRON_SECRET>`:

```elixir
forward "/cron/nightly", Cronwatch.Handler, job: "nightly-report", run: {MyApp.Reports, :nightly, []}
```

`MyApp.Reports.nightly(job, conn)` runs as a recorded run with the trigger `"handler"`, and the request is answered with `{"ok","job","run","status","durationMs"}`, 200 or 500; a `%Plug.Conn{}` it returns is the answer instead, and fails the run at 400 or more. `secret:` sets a secret of its own, and `secret: false` lets anyone in. Without any secret, outside development, it answers 503.

### Oban

`Cronwatch.Oban` watches Oban 2.20 or newer with no changes to your workers: every worker in the Cron plugin's crontab is a job (named after its module, on the entry's expression in its zone), and each attempt is a run, recorded through Oban's own telemetry in the worker's process, so `Cronwatch.log/1` works inside `perform/1`.

```elixir
# among your application's children
{Cronwatch,
 store: {Cronwatch.Store.Ecto, repo: MyApp.Repo},
 integrations: [{Cronwatch.Oban, oban: Oban, defaults: [grace: "5m"], workers: [{MyApp.Workers.Import, timeout: "1h"}]}]}
```

```elixir
# config/config.exs
config :my_app, Oban,
  repo: MyApp.Repo,
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       {"0 2 * * *", MyApp.Workers.NightlyReport},
       {"* * * * *", Cronwatch.Oban.CheckWorker}   # the check, once a minute across the cluster
     ]}
  ]
```

A retry is a new run, so failing attempts open one failed alert and the one that succeeds closes it (`failures_before_alert` says how many attempts to allow first). A `{:snooze, _}` gives the run back, a `{:cancel, _}` fails it, a worker killed at its `timeout/1` is a failed run at once, and an attempt left running by a node that died is failed when Lifeline's rescue runs the job again. Each crontab expression is checked against Oban's own reading of it: Oban matches a day of the month and a day of the week both, where CronWatch (as cron and the SDK) matches either, so an expression the two read differently is reported once and watched without a schedule. Workers outside the crontab are watched only when named in `workers:`. The check worker also declares again, without its schedule, a job taken out of the crontab, so it is never reported missed.

### Quantum

`Cronwatch.Quantum` watches a Quantum 3.5 scheduler the same way: every active job is a job (named after its name), each run is a run through Quantum's telemetry, schedules are checked against the crontab package's fire times, and jobs added, deleted or deactivated at run time are followed.

```elixir
integrations: [{Cronwatch.Quantum, scheduler: MyApp.Scheduler, jobs: [nightly_report: [grace: "15m"]]}]
```

```elixir
# config/config.exs: the check among the scheduler's jobs
config :my_app, MyApp.Scheduler,
  jobs: [
    nightly_report: [schedule: "0 2 * * *", task: {MyApp.Reports, :nightly, []}],
    cronwatch_check: [schedule: "* * * * *", task: {Cronwatch.Quantum, :check, [[scheduler: MyApp.Scheduler]]}]
  ]
```

### A crontab

A script a crontab runs needs no integration: a release's two lines are `bin/my_app eval "MyApp.Nightly.main()"` (which starts the instance and runs the job with `Cronwatch.run/3`) and `bin/my_app eval "Cronwatch.Release.check(MyApp.Cronwatch)"`, which starts the store's repo and an instance with the options under `config :my_app, MyApp.Cronwatch`, runs one check, prints what it did and exits non-zero when it fails. From source, `mix cronwatch.check MyApp.Cronwatch` does the same. `examples/crontab` in the repository is that program on SQLite.

### Telemetry

`[:cronwatch, :run, :start | :stop | :exception]`, `[:cronwatch, :check, ...]`, `[:cronwatch, :alert, :sent | :failed | :queued | :dropped]` and `[:cronwatch, :error]`; see `Cronwatch.Telemetry`. During a run, Logger metadata carries `cronwatch_job` and `cronwatch_run`.

## Testing this package

```sh
cd packages/elixir
mix deps.get
mix test                      # sets TZ=UTC, as the fixtures are made
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict
mix dialyzer
```

The tests replay the repository's `conformance/` fixtures and the dashboard's (`packages/ruby/test/web/golden.json`, straight into the plug, through a `Plug.Router` under Bandit and through a Phoenix endpoint), check the croner port against croner itself in Node (3,000 expressions), and share a SQLite file with the SDK; the last two need `npm run build` at the root first, and skip, saying so, without it. The store's server tests and the pg_cron source's run when `CRONWATCH_TEST_PG`, `CRONWATCH_TEST_MYSQL`, `CRONWATCH_TEST_MARIADB` and `CRONWATCH_TEST_PGCRON` hold URLs (`postgres://postgres:pw@127.0.0.1:5432/cw`, `mysql://root:pw@127.0.0.1:3306/cw`), and skip without them. `CRONWATCH_TEST_ELIXIR=1 npm test --workspace packages/mcp`, from the root, drives the MCP server against `webserver/`, a seeded dashboard served by Bandit (`CRONWATCH_MIX` names another `mix`, such as `"$HOME/.local/elixir/floor mix"`).

The Oban tests run Oban on SQLite (its Lite engine), and on Postgres too when `CRONWATCH_TEST_PG` names one (`postgres://postgres:pw@127.0.0.1:5432/cw`); `CRONWATCH_PIN_OBAN` and `CRONWATCH_PIN_QUANTUM` pin the optional dependency to a release, for testing the oldest one claimed. `examples/crontab` has a test of its own (`mix test` there) that builds its release and runs the two crontab lines on one file.

## License

MIT
