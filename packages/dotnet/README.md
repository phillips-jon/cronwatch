# cronwatch for .NET

Cron and scheduled-job monitoring that lives inside your .NET service. Wrap a job once; every run is recorded in a database you already have, and you are told when a run is missed, fails, gets stuck, runs slow or goes over budget. No server to run, no account to make. This is the library behind [cronwatch.dev](https://cronwatch.dev).

This is the .NET port of [`@cronwatch/sdk`](https://www.npmjs.com/package/@cronwatch/sdk): the same rules, the same alert text and the same stored rows, so a .NET process and a Node, Ruby, Python, PHP, Go, Rust, Elixir or Java process can share one database, and every port reads the tables the others write. It is built in phases ([DESIGN.md](DESIGN.md) has the plan and how each part works). Phase 1 has the core: jobs, runs in the caller's flow, runs that span calls, checks, silences, sources, deferred delivery and the triage hook, the current run across tasks and threads, the process-exit hook, the memory store, and the SQL store over ADO.NET on SQLite. Phase 2 adds the SQL store on Postgres, MySQL and MariaDB, the SDK's fifteen alert channels, Claude triage and the pg_cron source. Phase 3 adds the dashboard and a job's handler, framework-free in the core, `Cronwatch.Hosting` (the client in the Generic Host's container) and `Cronwatch.AspNetCore` (the dashboard and handler on ASP.NET Core). Phase 4 adds the bridge the scheduler integrations share, `Cronwatch.Hangfire`, `Cronwatch.Quartz`, hosted jobs (`AddCronwatchJob`) and `cronwatch check` from a crontab.

It is not on NuGet yet. The first release will be the `Cronwatch` package:

```bash
dotnet add package Cronwatch --version 0.10.0
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
    Alerts = { CustomChannel.Create("pager", (alert, ctx, ct) => Console.Out.WriteLineAsync(alert.Title)) }, // default: the console
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

### A plain crontab

A program a crontab runs needs no integration: it runs the job and returns 1 on failure, and a second crontab line runs a check on the same store, from the app's own program, since only the app knows its store and channels:

```csharp
if (args is ["cronwatch", .. var rest])
{
    return await CronwatchCli.RunAsync(MakeClient, rest, Console.Out, Console.Error);
}
```

with the lines `0 2 * * * dotnet /app/MyApp.dll nightly-report` and `* * * * * dotnet /app/MyApp.dll cronwatch check`. The check prints `cronwatch: checked 3 jobs, sent 1 alert` and answers 0, 1 for a failed check, or 2 for a command it does not know; it never ends the process. [`examples/crontab`](examples/crontab) is that program on SQLite.

### Hosted jobs

`Cronwatch.Hosting` runs a job class on its cron inside a Generic Host or ASP.NET Core app, on the same definition CronWatch watches, so the schedule it runs on and the one it is watched on cannot drift apart:

```csharp
builder.Services.AddCronwatchJob<NightlyReport>("nightly-report", new JobOptions
{
    Schedule = "0 2 * * *",
    Timezone = "UTC",
    Grace = "15m",
});
```

```csharp
public sealed class NightlyReport(ReportBuilder reports) : ICronwatchJob
{
    public async Task RunAsync(JobContext job, CancellationToken cancellationToken)
    {
        string path = await reports.BuildAsync(cancellationToken); // cancelled at the timeout and at shutdown
        job.Log($"Report written: {path}");
    }
}
```

Each fire is a run with the trigger `schedule`, its class resolved from a new DI scope. A fire that comes while the previous run is still going is skipped and logged once. It is a scheduler for one process: every replica of a service runs its hosted jobs, so a job that must run once across a cluster belongs in Hangfire or Quartz.NET with a shared store. A crontab line can check from the app's own host without starting it (no web server, queue or hosted job starts):

```csharp
var app = builder.Build();
return await app.RunCronwatchCommandAsync(args); // `dotnet MyApp.dll cronwatch check`, else runs the app
```

### Hangfire

`Cronwatch.Hangfire` (Hangfire 1.8.0 or newer) records every attempt of a job as a run, declares each recurring job on its cron and zone, and runs the check as a recurring job of its own, with nothing changed in the app's jobs:

```csharp
GlobalConfiguration.Configuration.UseInMemoryStorage().UseCronwatch(cw);
CronwatchHangfire.ScheduleCheck(); // `cronwatch-check`, every minute, once per cluster
```

(`services.AddHangfire((sp, c) => c.UseCronwatch(sp))` takes the client from the container.) Each recurring job is a job named after its id, tagged `hangfire` and `hangfire:<app>`, its cron checked against Cronos, Hangfire's own reader: one the two read differently is reported once and watched without a schedule. A retry is a new run, so failing attempts open one alert and the one that succeeds closes it (`FailuresBeforeAlert` allows some first). A job stopped by its server's shutdown, which Hangfire puts back in its queue, is given back rather than failed; one whose type or arguments no longer load is recorded failed. A job that is not recurring is watched only when named, with `[CronwatchJob("import")]` on its method. `CronwatchClient.Current` and `job.Log` work inside every watched job.

### Quartz.NET

`Cronwatch.Quartz` (Quartz.NET 4.0.0 or newer) records every firing as a run and declares each job on its trigger:

```csharp
builder.Services.AddQuartz(q =>
{
    q.UseCronwatch(o => o.ScheduleCheck = true); // a check job every minute, once per cluster
});
```

Jobs are named after their key (`nightlyReport` in the `DEFAULT` group, `reports.nightly` in another) and tagged `quartz` and `quartz:<app>`. A job with one cron trigger is declared on its expression in the trigger's zone, checked against Quartz's own `CronExpression` (Quartz counts the days of the week from 1 for Sunday, so a day it reads differently is reported and the job watched without a schedule); a simple trigger repeating forever is declared `every <interval>`; anything else is a job without a schedule. In a clustered job store, a firing Quartz recovers after its node stopped finishes the earlier firing's run as failed. `CronwatchClient.Current` works inside a job; a scheduler watched without the builder (`CronwatchQuartz.WatchAsync(cw, scheduler)`) gets its run from `context.CronwatchRun()`.

### Coravel

Coravel is not integrated: an invocable that should be watched wraps its body in a run.

```csharp
public sealed class SendDigest(CronwatchClient cw) : IInvocable
{
    public Task Invoke() => cw.Job("send-digest").RunAsync((job, ct) => SendDigestAsync(ct));
}
```

### Stores

`MemoryStore` is the default and forgets on restart. `SqlStore.Sqlite(dataSource)`, `SqlStore.Postgres(dataSource)` and `SqlStore.MySql(dataSource)` (MySQL and MariaDB), or `SqlStore.For(dataSource)` to pick from the driver, keep the SDK's three tables (`cronwatch_jobs`, `cronwatch_runs`, `cronwatch_state`, their text byte for byte what the SDK writes) in the app's database; `WithPrefix("cw_")` names them otherwise. The store opens its connections with the app's ambient transaction suppressed and never uses the app's own connection, so a run survives the rollback its failure caused. A store of the app's own implements `IStore` and passes `Cronwatch.StoreTesting.StoreContract.RunAsync(store)`, which depends on no test framework.

### The dashboard and a job's handler on ASP.NET Core

`Cronwatch.Hosting` holds the client in the app's container (`AddCronwatch`, a singleton disposed when the host stops, errors and warnings through the app's `ILogger`, a check every minute as a hosted service once the host has started, and `Retention`, `Token`, `CheckEvery` and `Environment` read from the `Cronwatch` section of the configuration). `Cronwatch.AspNetCore` serves the dashboard and its JSON API (the SDK's `cw.routes()`, the pages and answers byte for byte, so `@cronwatch/mcp` works against it) and a job's handler for a platform cron that calls a URL:

```csharp
WebApplicationBuilder builder = WebApplication.CreateBuilder();
builder.Services.AddCronwatch(o =>
{
    o.Retention = "30d";
    o.CheckEvery = TimeSpan.FromMinutes(1);
});
WebApplication app = builder.Build();

CronwatchClient cw = app.Services.GetRequiredService<CronwatchClient>();
cw.Job("nightly-report", new JobOptions { Schedule = "0 2 * * *", Timezone = "UTC" });

app.MapCronwatch("/cronwatch"); // the token from CRONWATCH_TOKEN or Cronwatch:Token
app.MapCronwatchHandler("/cron/nightly", "nightly-report", async (JobContext job, HttpContext http, CancellationToken ct) =>
{
    await BuildReportAsync(ct); // Authorization: Bearer <CRON_SECRET>, a run with the trigger "handler"
});
```

The dashboard asks for its token as `Authorization: Bearer <token>`, or once as `?token=` on a page, which moves it into a cookie. In development with no token it makes one and prints a sign-in link on its first request; outside development with none it answers 503. `Token = DashboardToken.None` serves it open, behind the app's own sign-in: while it has a token its endpoints allow anonymous requests (so an app whose fallback policy requires a signed-in user still reaches the dashboard's sign-in), and open it takes the app's authorization policy. The endpoints skip antiforgery (the dashboard has its own cross-site check) and are left out of OpenAPI. `app.UseCronwatch("/cronwatch")` serves it as middleware instead, and `MapGroup("/admin").MapCronwatch()` under a group; middleware is no endpoint, so an open dashboard served that way is behind the app's sign-in only when `UseAuthentication` and `UseAuthorization`, with a fallback policy, come before it. A job's handler follows the same rule: while it has a secret its endpoint allows anonymous requests, and one open to anyone (`HandlerSecret.None`, or the client's `CronSecret.None`) takes the app's authorization policy. Behind a proxy, `RoutesOptions.Origin` names the public origin, or `TrustProxy` reads `X-Forwarded-Proto` and `X-Forwarded-Host`.

Without ASP.NET Core, the routes and the handler are framework-free: any server hands them a `WebRequest` and writes the `WebResponse` back.

```csharp
Routes routes = cw.Routes(new RoutesOptions { Token = "letmein-example" });
WebResponse answer = await routes.HandleAsync(new WebRequest("GET", "/cronwatch/api/jobs")
{
    Headers = [new("host", "app.example.com"), new("authorization", "Bearer letmein-example")],
});
```

### Telemetry

An `ActivitySource` and a `Meter`, both named `Cronwatch`: an activity around each run and each check, and counters of runs, alerts and checks with a histogram of run durations. Add `.AddSource("Cronwatch")` and `.AddMeter("Cronwatch")` to an OpenTelemetry setup.

## Testing this package

```bash
cd packages/dotnet
dotnet test
CRONWATCH_CULTURE=tr-TR dotnet test
```

The suite replays the repository's `conformance/` fixtures byte for byte, and runs the channels against real local servers. The server tests run when `CRONWATCH_TEST_PG`, `CRONWATCH_TEST_MYSQL`, `CRONWATCH_TEST_MARIADB` and `CRONWATCH_TEST_PGCRON` are set, as URLs like `postgres://postgres:pw@127.0.0.1:5432/cw` or `mysql://root:pw@127.0.0.1:3306/cw` (MariaDB's too), each test on tables of its own prefix. The croner parity check and the SQLite file shared with Node need the built SDK (`npm run build --workspace packages/sdk` at the repository's root) and skip without it. The tests run on a `FakeTimeProvider`, in UTC. `CRONWATCH_TRIES=N` runs the properties longer. The dashboard replays the SDK's captures (`packages/ruby/test/web/golden.json`) three ways: straight into the routes, through ASP.NET Core's test server, and through Kestrel over a raw socket. `CRONWATCH_TEST_DOTNET=1 npm test --workspace packages/mcp`, at the repository's root, drives `@cronwatch/mcp` against `webserver`, a seeded dashboard. The integrations' tests run a real Hangfire server on its in-memory storage and a real Quartz scheduler on its RAM store, and the Quartz recovery test a clustered Postgres job store when `CRONWATCH_TEST_PG` is set; `-p:HangfireVersion=1.8.0` and `-p:QuartzVersion=4.0.0` run them on the oldest releases the packages support (the newest by default). `examples/aot` is published with Native AOT (`dotnet publish examples/aot -c Release -o artifacts/aot && artifacts/aot/aot once`).

## License

MIT
