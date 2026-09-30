# cronwatch for .NET

Cron and scheduled-job monitoring that lives inside your .NET service. Wrap a job once; every run is recorded in a database you already have, and you are told when a run is missed, fails, gets stuck, runs slow or goes over budget. No server to run, no account to make. This is the library behind [cronwatch.dev](https://cronwatch.dev).

This is the .NET port of [`@cronwatch/sdk`](https://www.npmjs.com/package/@cronwatch/sdk): the same rules, the same alert text and the same stored rows, so a .NET process and a Node, Ruby, Python, PHP, Go, Rust, Elixir or Java process can share one database, and every port reads the tables the others write. It is built in phases ([DESIGN.md](DESIGN.md) has the plan and how each part works). Phase 1 has the core: jobs, runs in the caller's flow, runs that span calls, checks, silences, sources, deferred delivery and the triage hook, the current run across tasks and threads, the process-exit hook, the memory store, and the SQL store over ADO.NET on SQLite. Phase 2 adds the SQL store on Postgres, MySQL and MariaDB, the SDK's fifteen alert channels, Claude triage and the pg_cron source. Later phases add the dashboard, a job's handler, `Cronwatch.Hosting`, `Cronwatch.AspNetCore`, and the Hangfire and Quartz.NET integrations.

It is not on NuGet yet. The first release will be the `Cronwatch` package:

```bash
dotnet add package Cronwatch --version 0.8.0
```

## Install

.NET 10 or newer. The `Cronwatch` package depends on no other package: cron expressions are read by a port of [croner](https://github.com/hexagon/croner), the parser the SDK uses, so every port agrees on every fire time; zones come from the system's IANA database through `TimeZoneInfo`; JSON, the JavaScript regular expressions a stored `expect` pattern holds, and secret redaction are the port's own. It is trimming and Native AOT compatible.

The SQL store takes the app's `System.Data.Common.DbDataSource` and driver, a normal dependency of your app: `Microsoft.Data.Sqlite` for SQLite (`SqliteFactory.Instance.CreateDataSource(...)` is a data source), `Npgsql` for Postgres (`NpgsqlDataSource`), and `MySqlConnector` for MySQL 8.0.13 or newer and MariaDB 10.6 or newer (`MySqlDataSource`). None is a dependency of CronWatch. The channels and triage post through `HttpClient`, part of .NET. A container image without `tzdata` (the chiseled and distroless images, unless you pick an `-extra` one) has no named zones, and a job naming one is refused when it is declared.

Until the first release, build it from this repository:

```bash
cd packages/dotnet && dotnet pack src/Cronwatch -c Release -o artifacts
```

## Use

One client per app, kept where the app keeps its data source and disposed at shutdown:

```csharp
var dataSource = SqliteFactory.Instance.CreateDataSource("Data Source=data/cronwatch.db");

await using var cw = new CronwatchClient(new CronwatchOptions
{
    Store = SqlStore.Sqlite(dataSource), // default: a MemoryStore
    Alerts = { Channel.Create("pager", (alert, ctx, ct) => Console.Out.WriteLineAsync(alert.Title)) }, // default: the console
    Retention = "30d",
});

Job nightly = cw.Job("nightly-report", new JobOptions
{
    Schedule = "0 2 * * *",
    Timezone = "UTC",
    Grace = "15m",
    Timeout = TimeSpan.FromMinutes(30),
    Expect = "Report written",
    Budget = { ["cost"] = 2 },
    FailuresBeforeAlert = 1,
});

string path = await nightly.RunAsync(async (job, ct) =>
{
    string p = await BuildReportAsync(ct); // ct is cancelled at the job's timeout
    job.Log($"Report written: {p}");
    job.Metric("cost", 1.2);
    return p; // an exception thrown here is thrown from RunAsync, once the run is recorded
});

CheckResult result = await cw.CheckAsync(); // missed and stuck runs, retries, pruning
cw.Start(TimeSpan.FromMinutes(1)); // a check every minute, for a long-running process
await cw.SilenceAsync("nightly-report", "2h");
```

Any exception is a failed run, and is thrown again as it came, its type and stack intact, once the run is recorded. The function's token is cancelled at the job's timeout and when the token given to `RunAsync` is; a function that ignores it runs on and is marked stuck by a check, as in the SDK. The store failing never stops a job: store errors go to `OnError`, and the job's own outcome is returned.

Durations are the SDK's text (`"15m"`, `"1h30m"`), a `TimeSpan` or milliseconds. The definition keeps its fields in the order they were set, as the SDK's object literal does. `Expect` takes text to contain, `Expect.Matches(source, flags)` for a JavaScript pattern, or `Expect.That(output => ...)`.

### The current run

`CronwatchClient.Current` is the run of the calling flow, set inside a job's function and flowing into everything it awaits, every task it starts and every thread that captures its execution context, and gone when the run ends:

```csharp
await cw.Job("import").RunAsync(async (job, ct) =>
{
    await Parallel.ForEachAsync(files, ct, async (file, token) =>
    {
        await ImportAsync(file, token);
        CronwatchClient.Current?.Log($"imported {file}"); // the same run
    });
});
```

### Runs that span calls

A run can start in one call and finish in another, or in another process:

```csharp
RunHandle handle = await cw.Job("export").StartAsync(new StartOptions { Id = "export-2026-01-05" });
handle.Log("queued");
await handle.FlushAsync();
// ... later, maybe elsewhere:
RunHandle again = await cw.ResumeRunAsync("export", "export-2026-01-05");
await again.FinishAsync("export done");
```

A run is judged once, however many processes finish it. A run id holding a NUL is refused.

### Alerts, triage and pg_cron

The SDK's fifteen channels are in `Cronwatch.Alerts`: Slack, Discord, a signed webhook, Resend, Postmark, SendGrid, Mailgun, SES, Twilio, Sentry, Honeybadger, Datadog, Rollbar, Bugsnag and New Relic, each made from its options (`new ResendChannel(new ResendOptions { ... })`), with `Slack.Webhook(url)` and `Discord.Webhook(url)` for the common case. `AnthropicTriage` adds a short diagnosis from Claude to each alert but recoveries, and `PgCronSource` watches the jobs Postgres's pg_cron runs:

```csharp
var pg = NpgsqlDataSource.Create(connectionString);

await using var cw = new CronwatchClient(new CronwatchOptions
{
    Store = SqlStore.Postgres(pg), // SqlStore.MySql(dataSource) for MySQL and MariaDB
    Alerts =
    {
        Slack.Webhook(slackWebhookUrl),
        new ResendChannel(new ResendOptions { ApiKey = resendApiKey, From = "cron@example.com", To = { "ops@example.com" } }),
    },
    Triage = new AnthropicTriage(), // reads ANTHROPIC_API_KEY when it runs
    Sources = { new PgCronSource(pg, new PgCronOptions { Jobs = ["nightly-vacuum"] }) },
});
```

A bad option is refused when the channel is made, and no refusal or error quotes a key, token or webhook URL; an options class's `ToString` says only what is set. Every request goes through one hardened POST: a redirect is an answer and never followed, no proxy is used, TLS is always verified, the whole request has ten seconds, at most 1 MiB of an answer is read, and an error names only the URL's origin. An app that wants its own `HttpClient` (a proxy, a trust store, `IHttpClientFactory`) implements `ITransport` and gives it to the client (`CronwatchOptions.Transport`) or to one channel's options.

### Stores

`MemoryStore` is the default and forgets on restart. `SqlStore.Sqlite(dataSource)`, `SqlStore.Postgres(dataSource)` and `SqlStore.MySql(dataSource)` (MySQL and MariaDB), or `SqlStore.For(dataSource)` to pick from the driver, keep the SDK's three tables (`cronwatch_jobs`, `cronwatch_runs`, `cronwatch_state`, their text byte for byte what the SDK writes) in the app's database; `WithPrefix("cw_")` names them otherwise. The store opens its connections with the app's ambient transaction suppressed and never uses the app's own connection, so a run survives the rollback its failure caused. A store of the app's own implements `IStore` and passes `Cronwatch.StoreTesting.StoreContract.RunAsync(store)`, which depends on no test framework.

### Telemetry

An `ActivitySource` and a `Meter`, both named `Cronwatch`: an activity around each run and each check, and counters of runs, alerts and checks with a histogram of run durations. Add `.AddSource("Cronwatch")` and `.AddMeter("Cronwatch")` to an OpenTelemetry setup.

## Testing this package

```bash
cd packages/dotnet
dotnet test
CRONWATCH_CULTURE=tr-TR dotnet test
```

The suite replays the repository's `conformance/` fixtures byte for byte, and runs the channels against real local servers. The server tests run when `CRONWATCH_TEST_PG`, `CRONWATCH_TEST_MYSQL`, `CRONWATCH_TEST_MARIADB` and `CRONWATCH_TEST_PGCRON` are set, as URLs like `postgres://postgres:pw@127.0.0.1:5432/cw` or `mysql://root:pw@127.0.0.1:3306/cw` (MariaDB's too), each test on tables of its own prefix. The croner parity check and the SQLite file shared with Node need the built SDK (`npm run build --workspace packages/sdk` at the repository's root) and skip without it. The tests run on a `FakeTimeProvider`, in UTC. `CRONWATCH_TRIES=N` runs the properties longer.

## License

MIT
