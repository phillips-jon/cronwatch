# cronwatch for Elixir

Cron and scheduled-job monitoring that lives inside your Elixir service. Wrap a job once; every run is recorded in a database you already have, and you are told when a run is missed, fails, gets stuck, runs slow or goes over budget. No server to run, no account to make. This is the library behind [cronwatch.dev](https://cronwatch.dev).

This is the Elixir port of [`@cronwatch/sdk`](https://www.npmjs.com/package/@cronwatch/sdk): the same rules, the same alert text and the same stored rows, so an Elixir process and a Node, Ruby, Python, PHP, Go or Rust process can share one database, and every port reads the tables the others write. It is built in phases ([DESIGN.md](https://github.com/phillips-jon/cronwatch/blob/main/packages/elixir/DESIGN.md) has the plan and how each part works). Phases 1 and 2 have the core (jobs, runs, runs that span calls, checks, silences, sources, deferred delivery and the triage hook, telemetry), the memory store, the SQL store over Ecto on SQLite, Postgres, MySQL and MariaDB, the pg_cron source, the SDK's fifteen alert channels and Claude triage. The dashboard, a job's handler and the Oban and Quantum integrations follow.

Docs: [cronwatch.dev](https://cronwatch.dev/docs/)

## Install

Elixir 1.18 or newer on Erlang/OTP 27 or newer. The package depends on [`tz`](https://hex.pm/packages/tz) (the time zone database, compiled in, so zones work in a release on any image) and `telemetry`, and nothing else; cron expressions are read by a port of [croner](https://github.com/hexagon/croner), the parser the SDK uses, so every port agrees on every fire time. The SQL store needs `ecto_sql` and the adapter your repo uses.

```elixir
def deps do
  [
    {:cronwatch, "~> 0.7"},
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
  Cronwatch.metric(job, "cost", 1.2)            # watched against budgets and baselines
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

Requests go through OTP's own `:httpc`, with one ten second deadline, redirects refused, at most 1 MiB of an answer read, TLS always verified, and only a URL's origin in any error; no credential is printed by `inspect`. `transport:` on a channel or the instance takes a `Cronwatch.Transport` of your own (over Req or Finch, say). `Cronwatch.Triage.Anthropic` reads `ANTHROPIC_API_KEY` unless given `api_key:`.

### pg_cron

`{Cronwatch.Sources.PgCron, repo: MyApp.Repo}` in the instance's `sources:` records the runs of pg_cron jobs inside a Postgres database, as the SDK's source does; `jobs:`, `job_ids:` or `pick:` choose which.

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

The tests replay the repository's `conformance/` fixtures, check the croner port against croner itself in Node (3,000 expressions), and share a SQLite file with the SDK; the last two need `npm run build` at the root first, and skip, saying so, without it. The store's server tests and the pg_cron source's run when `CRONWATCH_TEST_PG`, `CRONWATCH_TEST_MYSQL`, `CRONWATCH_TEST_MARIADB` and `CRONWATCH_TEST_PGCRON` hold URLs (`postgres://postgres:pw@127.0.0.1:5432/cw`, `mysql://root:pw@127.0.0.1:3306/cw`), and skip without them.

## License

MIT
