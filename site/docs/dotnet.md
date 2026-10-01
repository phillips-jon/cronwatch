---
title: .NET
description: The Cronwatch package in a .NET service: one client, jobs run in the caller's flow, the check, the SQL store over your DbDataSource, alert channels, Claude triage, pg_cron, the dashboard and job handlers on ASP.NET Core or any server, AddCronwatch in the Generic Host, a crontab's check with CronwatchCli, Native AOT, and sharing one database with the other languages.
order: 3.97
group: .NET
---

# .NET

The `Cronwatch` package is a port of `@cronwatch/sdk`, not a new design. It decides missed, failed, stuck, slow and over budget by the same rules, sends the same alert text, and writes the same rows, so a .NET process can share one database with a Node, Ruby, Python, PHP, Go, Rust, Elixir or Java process and the [MCP server](/docs/mcp/) works against any of them. This page covers the library itself: a console program a crontab runs, a Generic Host or ASP.NET Core app, hosted jobs on a cron. Hangfire and Quartz.NET have a page of their own: [.NET schedulers](/docs/dotnet-schedulers/).

```bash
dotnet add package Cronwatch
```

.NET 10 or newer. The `Cronwatch` package depends on no other package: cron expressions are read by a port of [croner](https://github.com/hexagon/croner), the parser the SDK uses, so every port agrees on every fire time; zones come from the system's IANA database through `TimeZoneInfo`; the alert channels and Claude triage post through `HttpClient`, part of .NET. The rest comes from your app, or from a package of its own, all at the same version:

| Package or dependency | For |
|---|---|
| your ADO.NET driver: `Microsoft.Data.Sqlite`, `Npgsql` or `MySqlConnector` | `SqlStore` over your `DbDataSource`, and the pg_cron source; none is a dependency of CronWatch |
| `Cronwatch.Hosting` | the client in the Generic Host's container (`AddCronwatch`), the check as a hosted service, errors through `ILogger`, hosted jobs on a cron (`AddCronwatchJob`), and `cronwatch check` from the app's own command line |
| `Cronwatch.AspNetCore` | the dashboard and a job's handler on ASP.NET Core (`MapCronwatch`, `UseCronwatch`, `MapCronwatchHandler`); it brings `Cronwatch.Hosting` |
| `Cronwatch.Hangfire` | Hangfire 1.8; see [.NET schedulers](/docs/dotnet-schedulers/#hangfire) |
| `Cronwatch.Quartz` | Quartz.NET 4; see [.NET schedulers](/docs/dotnet-schedulers/#quartz-net) |

## Create one client

In a Generic Host or ASP.NET Core app, `Cronwatch.Hosting` makes the client a singleton in the container:

```csharp
var pg = NpgsqlDataSource.Create(builder.Configuration.GetConnectionString("app")!);

builder.Services.AddCronwatch(o =>
{
    o.Store = SqlStore.Postgres(pg);                         // default: a MemoryStore
    o.Alerts.Add(Slack.Webhook(builder.Configuration["SLACK_WEBHOOK_URL"]!));
    o.Retention = "30d";
});
```

It reads `Retention`, `Token`, `CheckEvery` and `Environment` from the `Cronwatch` section of the configuration, with the code's options applied after; takes every `IChannel` registered in the container as a channel when `Alerts` is left alone; sends the client's own errors and warnings to the app's `ILogger`; runs a check every minute as a hosted service once the host has started (`CheckEvery` sets the interval, `NoCheck = true` runs none, for an app whose checks run elsewhere); and disposes the client when the host stops, after the hosted services have stopped. `AddCronwatch((services, o) => ...)` takes the options from other services, such as the app's own data source. Each run's function runs inside a log scope holding `cronwatch_job` and `cronwatch_run`, so every line the app logs inside a job carries them.

Anywhere else, make one and dispose it when the app stops:

```csharp
await using var cw = new CronwatchClient(new CronwatchOptions
{
    Store = SqlStore.Postgres(pg),
    Alerts = { Slack.Webhook(Environment.GetEnvironmentVariable("SLACK_WEBHOOK_URL")!) },
    Retention = "30d",
});
cw.Start();                                                  // check every minute, in a long-running service
```

Every option has the SDK's default, and the constructor checks them, so a bad option fails at startup with the SDK's message, as a `CronwatchException`. With no options it keeps everything in memory and writes alerts to the console. `DisposeAsync` stops the check, records the runs still open in this process, waits up to five seconds for sends in flight, and lets go of the store.

The client's own work (recording a run, sending alerts, checking) runs as tasks of its own, so a caller that stops waiting never cuts a write in half. Everything on `CronwatchClient`, `Job` and a run's `JobContext` is safe to use from any thread and task. Every call that reaches the store or the network is async, takes a `CancellationToken` last, and awaits with `ConfigureAwait(false)`, so a caller that blocks on one cannot deadlock.

## Declare and run a job

Declare each job once, at startup, and keep its handle:

```csharp
Job nightly = cw.Job("nightly-report", new JobOptions
{
    Schedule = "0 2 * * *",
    Timezone = "UTC",
    Grace = "15m",
    Timeout = TimeSpan.FromMinutes(30),
    Expect = "Report written",
    Budget = { ["cost"] = 2 },
});

string path = await nightly.RunAsync(async (job, ct) =>
{
    string p = await reports.BuildAsync(ct);                 // ct is cancelled at the job's timeout
    job.Log($"Report written: {p}");                         // kept with the run, shown in alerts
    job.Metric("cost", 1.2);                                 // watched against budgets and baselines
    return p;                                                // an exception thrown here is thrown from RunAsync
});
```

`RunAsync` runs the function in the caller's flow, awaited by the caller, where your log scope, `Activity` and DI scope live, as a recorded run. A function that returns a value hands it back; one that returns a `Task` returns nothing. Any exception fails the run, `OperationCanceledException` included, and is thrown again as it came, its type and stack intact, once the run is recorded, so your own error handling sees exactly what it would have without CronWatch. The store failing never stops a job: its failures go to the error handler (`OnError`, by default a line to standard error, the app's `ILogger` under `AddCronwatch`), and the job's own outcome is what you get.

A name is 1 to 120 letters, digits, `.`, `_`, `:` or `-`, starting with a letter or digit. `cw.RunAsync(name, fn)` declares a name it has not seen, for a job run once. `JobOptions` keeps its fields in the order you set them in the initializer, so the stored definition is the JSON a Node process writes for the same options in the same order. Durations take the SDK's text (`"15m"`, `"1h30m"`, stored as written), a `TimeSpan` or milliseconds. `Expect` takes the text the output must contain, `Expect.Matches(source, flags)` for a JavaScript pattern, or `Expect.That(output => ...)`.

A `string` the function returns is the run's output when nothing was logged, and what `Expect` checks. An `HttpResponseMessage` of 400 or more (or on ASP.NET Core an `IResult` with such a status) fails the run with `HTTP <status> <reason>`, so a job that calls an API and returns its answer fails when the API does. The run keeps the last 16 KB of output.

A failed run's error is written as the SDK writes a JavaScript error: the exception's simple name and message (`IOException: disk full`), then up to five frames of its stack, each `Example.Reports.BuildAsync (Reports.cs:42)`, async state machines written as the methods you wrote. Inner exceptions are not written.

### The current run and the timeout

`CronwatchClient.Current` answers the run of the calling flow, so code deep in a call chain can log to it. It flows into everything the function awaits and every task, `Parallel.ForEachAsync` body and thread it starts, and it is gone when `RunAsync` returns:

```csharp
await cw.Job("import").RunAsync(async (job, ct) =>
{
    await Parallel.ForEachAsync(files, ct, async (file, token) =>
    {
        await ImportAsync(file, token);
        CronwatchClient.Current?.Log($"imported {file}");   // the same run
    });
});
```

A job's timeout (an hour by default) cancels the function's token, the SDK's abort signal, as does the token you gave `RunAsync`; nothing is stopped. A function that honours it throws what the cancelled call throws, and the run is recorded failed with that exception. A run that goes on past its timeout is marked stuck by the next check; if it finishes later, a late failure is written without a second alert and a late success closes the stuck alert with a recovery.

When the process stops with a run open (`Environment.Exit`, a console program's `SIGTERM`), a `ProcessExit` handler records every run still open in the process as failed (`Shutdown: the process stopped while the run was in progress`), rather than leave it to be reported stuck later. In a Generic Host, a `SIGTERM` cancels the stopping token first, so a job that honours it is recorded through the ordinary path. `ProcessExitHook = false` leaves the handler out.

## Hosted jobs

.NET has no cron scheduler in the box, and a `BackgroundService` looping on a timer runs on a clock of its own while the job CronWatch watches is declared with a schedule written somewhere else. `AddCronwatchJob` makes them one definition: `Cronwatch.Hosting` runs the job class on the job's own cron, inside the host:

```csharp
builder.Services.AddCronwatchJob<NightlyReport>("nightly-report", new JobOptions
{
    Schedule = "0 2 * * *",
    Timezone = "UTC",
    Grace = "15m",
});

public sealed class NightlyReport(ReportBuilder reports) : ICronwatchJob
{
    public async Task RunAsync(JobContext job, CancellationToken cancellationToken)
    {
        string path = await reports.BuildAsync(cancellationToken);   // cancelled at the timeout and at shutdown
        job.Log($"Report written: {path}");
    }
}
```

Each fire is a run with the trigger `hosting` (runs recorded before 1.0 carry `schedule`; see [Triggers, tags and job names](/docs/dashboard/#triggers-tags-and-job-names)), its class resolved from a new DI scope and disposed after it. A cron or `every 5m` both work. The jobs are declared as the host starts (a bad schedule stops it, with the SDK's message) and first fire once the host has started. A fire that comes while the previous run is still going is skipped and logged once, so a slow job cannot pile up behind itself; a paused process does not catch up in a burst. It is a scheduler for one process: every replica of a service runs its hosted jobs, so a job that must run once across a cluster belongs in [Hangfire or Quartz.NET](/docs/dotnet-schedulers/) with a shared store.

A loop of your own needs no helper: declare the job with its schedule and call `job.RunAsync` in the loop. `job.NextFire(after, lastRunAt)` answers the job's next fire time in epoch milliseconds, for a scheduler of your own.

## Run the check

A job that never starts cannot report itself, so something has to look. `AddCronwatch` runs the check as a hosted service every minute. Outside the host, `cw.Start()` checks every minute, the first a second after it is called; `cw.Start("5m")` or a `TimeSpan` sets the interval (five seconds at least), and `Stop()` ends it. Where another process checks, call `CheckAsync()` there:

```csharp
CheckResult result = await cw.CheckAsync();   // CheckedAt, Jobs, Alerts, Pruned
```

One process checking is enough; every instance of a service checking is harmless, since a check judges each run once. Calls at the same time share one check, and a caller's token ends only its own wait. Hangfire and Quartz.NET each have a check job that runs once per cluster; see [.NET schedulers](/docs/dotnet-schedulers/#the-check).

### From a crontab

A program a crontab runs exits when it is done, so nothing inside it notices the run that never happened. Add a second crontab line that checks, on a store both reach. The check needs the same store and channels as the job, which only your app knows, so it is your own program handing `CronwatchCli` the factory for your client:

```csharp
static CronwatchClient MakeClient()
{
    var cw = new CronwatchClient(new CronwatchOptions
    {
        Store = SqlStore.Sqlite(SqliteFactory.Instance.CreateDataSource("Data Source=/var/lib/app/cronwatch.db")),
    });
    cw.Job("nightly-report", new JobOptions { Schedule = "0 2 * * *", Timezone = "UTC", Grace = "15m" });
    return cw;
}

if (args is ["cronwatch", .. var rest])
{
    return await CronwatchCli.RunAsync(MakeClient, rest, Console.Out, Console.Error);
}

await using CronwatchClient cw = MakeClient();
try
{
    await cw.Job("nightly-report").RunAsync((job, ct) => reports.BuildAsync(job, ct));
    return 0;
}
catch (IOException)
{
    return 1;                                                // a failed run exits non-zero, so cron mails it
}
```

```
# m  h  dom mon dow  command
0    2  *   *   *    dotnet /app/MyApp.dll nightly-report
*    *  *   *   *    dotnet /app/MyApp.dll cronwatch check
```

The job is declared in the factory too, so the check knows its schedule before its first run. `check` makes the client, runs one check, prints what it did (`cronwatch: checked 3 jobs, sent 1 alert`), disposes the client, and answers 0, 1 when the check fails, or 2 for a command it does not know; it never ends the process, so `Main` returns the status. In a Generic Host app, `return await app.RunCronwatchCommandAsync(args);` does the same with the host's own services: given `cronwatch check` it takes the client from the container without starting the host (no web server, queue or hosted job starts), and given anything else it runs the app as `RunAsync` would. [`examples/crontab`](https://github.com/phillips-jon/cronwatch/tree/main/packages/dotnet/examples/crontab) in the repository is this program on SQLite, with a test that runs both lines as two processes on one file.

## The dashboard

`cw.Routes()` is the dashboard and JSON API, the same pages and endpoints as the TypeScript routes, byte for byte: the board's counts by health, a timeline of the last day with a lane per job, the table of every job, and for each job its last seven days, runs and definition, all drawn on the server with no script. On ASP.NET Core, `Cronwatch.AspNetCore` maps it:

```csharp
WebApplication app = builder.Build();
app.MapCronwatch("/cronwatch");   // the token from CRONWATCH_TOKEN or Cronwatch:Token
```

`MapCronwatch` maps the path and everything beneath it on endpoint routing, which minimal APIs, MVC, Razor Pages and Blazor all use, and answers the convention builder. Under a route group (`app.MapGroup("/admin").MapCronwatch()`) the group sets the base path. The endpoints skip antiforgery (the dashboard has its own cross-site check) and are left out of OpenAPI. While the dashboard has a token they allow anonymous requests, so an app whose fallback policy requires a signed-in user still reaches the dashboard's own sign-in; `Token = DashboardToken.None` serves it open, and then it takes the app's authorization policy. `app.UseCronwatch("/cronwatch")` serves it as middleware instead, ahead of the app's other middleware: middleware is no endpoint, so an open dashboard served that way is behind your sign-in only when `UseAuthentication` and `UseAuthorization`, with a fallback policy, come before it.

Without ASP.NET Core, the routes are framework-free: any server hands them a `WebRequest` and writes the `WebResponse` back.

```csharp
Routes routes = cw.Routes(new RoutesOptions { Token = Environment.GetEnvironmentVariable("CRONWATCH_TOKEN") });
WebResponse answer = await routes.HandleAsync(new WebRequest("GET", "/cronwatch/api/jobs")
{
    Headers = [new("host", "app.example.com"), new("authorization", "Bearer " + token)],
});
```

`RoutesOptions`:

- `Token`: the token. Left out, it is `CRONWATCH_TOKEN` (under `AddCronwatch`, `Cronwatch:Token` first). Send it as `Authorization: Bearer <token>`, or open the dashboard once with `?token=<token>` and a cookie holds a digest of it. Without a token, in development, the dashboard makes one and prints a sign-in link to standard output on its first request (naming the host only when `Origin` is set or the request came to a loopback host); anywhere else it answers 503. The environment is `CRONWATCH_ENV`, else `APP_ENV`, else the options' `Environment` (under `AddCronwatch`, `Cronwatch:Environment`, else the host's environment, `--environment` included), else `ASPNETCORE_ENVIRONMENT` or `DOTNET_ENVIRONMENT`, and `development`, `dev`, `local`, `test` and `testing` count as development, so ASP.NET Core's `Development` does.
- `Token = DashboardToken.None`: serve it to anyone, for a mount behind your own auth.
- `Origin = "https://app.example.com"`: the public origin, pinned whatever a request says, for the cross-site check on writes, the cookie's `Secure` flag, redirects and the sign-in line.
- `TrustProxy = true`: take the origin from the first `X-Forwarded-Proto` and `X-Forwarded-Host`. Only behind a proxy that sets or overwrites both.
- `BasePath`: where it is mounted, when the adapter cannot tell; `MapCronwatch` and `UseCronwatch` say so already.

A request body past 1 MiB is answered 413. The token rules, cookie, cross-site rule and every endpoint are the SDK's; see [Dashboard and API](/docs/dashboard/). `GET /api` names what is serving it, `{"ok":true,"library":"Cronwatch","language":"dotnet","version":"1.0.0","api":1}` with the package's version, and the silence and unsilence endpoints answer the job's summary, `{"ok":true,"job":{...}}`. `/api/check` also accepts the client's cron secret as a bearer, so an outside cron can run the check over HTTP. The dashboard is installable as a web app, with its manifest, icons and service worker under the mount point; see [Install it as an app](/docs/dashboard/#install-it-as-an-app).

## Jobs a URL starts

Some platforms run scheduled work by calling a URL: a Kubernetes CronJob running `curl`, Azure Container Apps jobs, Render, Fly.io, an outside cron service. A job's handler is that endpoint: each request carrying `Authorization: Bearer <secret>` runs the function in the request as a recorded run (trigger `handler`), answered with JSON saying how the run went.

```csharp
CronwatchClient cw = app.Services.GetRequiredService<CronwatchClient>();
cw.Job("nightly-report", new JobOptions { Schedule = "0 2 * * *", Timezone = "UTC" });

app.MapCronwatchHandler("/cron/nightly", "nightly-report", async (JobContext job, HttpContext http, CancellationToken ct) =>
{
    await reports.BuildAsync(ct);
    job.Log("Report written");
});
```

The job is looked up by name on the app's client, so declare it first (or pass the `Job` itself). Without ASP.NET Core, `job.Handler((job, request, ct) => ...)` answers a framework-free `Handler` whose `HandleAsync` takes a `WebRequest`. The secret is `HandlerOptions.Secret`, else the client's `CronSecret` (`CRON_SECRET` by default), compared in constant time; `""` counts as unset. A wrong or missing bearer is answered 401 and runs nothing. With no secret at all, outside development, the handler answers 503 rather than let anyone on the internet run the job; `HandlerSecret.None` (or the client's `CronSecret.None`) opts out on purpose, for an endpoint your platform already protects, and then the endpoint takes the app's authorization policy.

A run is answered 200 or 500 with `{"ok","job","run","status","durationMs"}`, and the error's first line as `"error"` for a caller who sent the secret. A `string` the function returns is the run's output when nothing was logged; a `WebResponse` or an `IResult` it returns is the answer itself, and a status of 400 or more fails the run. The request's `RequestAborted` token is linked into the run's, so a caller that goes away cancels the job as a platform's timeout would.

## Stores

`MemoryStore` is the default, for tests and trying it out. Nothing survives a restart, so a miss cannot be noticed across one, and each process has its own. When the environment is production, the client warns once that it is using it.

`SqlStore` keeps the same three tables as the SDK's SQL stores in your database, through your `System.Data.Common.DbDataSource`:

| Factory | |
|---|---|
| `SqlStore.Sqlite(dataSource)` | Microsoft.Data.Sqlite, whose `SqliteFactory.Instance.CreateDataSource(...)` is a data source. The store takes one connection and keeps it, in WAL mode with a `busy_timeout` of 5000, as the SDK's store holds one |
| `SqlStore.Postgres(dataSource)` | Npgsql's `NpgsqlDataSource`. `JSONB` for the JSON; tables made under an advisory lock, so many processes can start at once |
| `SqlStore.MySql(dataSource)` | MySqlConnector's `MySqlDataSource`, for MySQL 8.0.13 or newer and MariaDB 10.6 or newer |
| `SqlStore.For(dataSource)` | the dialect picked from the driver |

```csharp
var store = SqlStore.Postgres(pg).WithPrefix("app_cron_");
```

The tables (`cronwatch_jobs`, `cronwatch_runs`, `cronwatch_state`) are made on the client's first use, byte for byte as the SDK makes them. `WithPrefix` names them: lowercase letters, digits and underscores, not starting with a digit, at most 47 characters. An app on EF Core or Dapper gives the store the data source underneath. The store's writes never join a transaction your code has open: each opens its connection with the ambient `TransactionScope` suppressed and never uses your connection, so a run recorded inside a transaction that rolls back stays recorded.

A store of your own implements `IStore`: `InitAsync`, `UpsertJobAsync`, `GetJobAsync`, `ListJobsAsync`, `DeleteJobAsync`, `InsertRunAsync`, `UpdateRunAsync`, `GetRunAsync`, `ListRunsAsync`, `LastRunAsync`, `RunningRunsAsync`, `GetStateAsync`, `SetStateAsync` and `PruneAsync`, with epoch milliseconds for every time. Three capability interfaces keep processes sharing a store from judging a run twice or losing each other's updates: `IConditionalRunStore` (`UpdateRunIfAsync`), `IStateCasStore` (`CompareAndSetStateAsync`) and `IRunDeletingStore` (`DeleteRunIfAsync`, which takes back an attempt a scheduler gave back without failing; see [.NET schedulers](/docs/dotnet-schedulers/#retries)). They mean what the [TypeScript interface](/docs/stores/#writing-a-store) says. `Cronwatch.StoreTesting` is the contract the built-in stores pass, from any test framework:

```csharp
await StoreContract.RunAsync(new MyStore());
```

`StoreReplay` replays the SDK's recorded store cases (`conformance/store.json`, which your test reads), and `FinishOnce` runs several clients over one database to hold a run to being recorded and judged once.

## Alerts

`ConsoleChannel` is the default channel: a recovery to standard output and anything else to standard error, where a crontab's mail and a container's log collector read them. Adding to `Alerts` replaces it; `Alerts = []` sends nothing. Under `AddCronwatch`, every `IChannel` in the container is a channel unless `Alerts` is set. The SDK's fifteen channels are in `Cronwatch.Alerts`, each made from its options, whose constructor refuses what the SDK refuses:

```csharp
await using var cw = new CronwatchClient(new CronwatchOptions
{
    Alerts =
    {
        Slack.Webhook(Environment.GetEnvironmentVariable("SLACK_WEBHOOK_URL")!),
        Discord.Webhook(Environment.GetEnvironmentVariable("DISCORD_WEBHOOK_URL")!),
        new WebhookChannel(new WebhookOptions
        {
            Url = "https://hooks.example.com/cronwatch",
            Secret = Environment.GetEnvironmentVariable("CRONWATCH_WEBHOOK_SECRET"),
        }),
        CustomChannel.Create("pagerduty", (alert, ctx, ct) =>
            alert.Type == AlertType.Recovered ? Task.CompletedTask : pagerDuty.TriggerAsync(alert.Title, alert.Message, ct)),
    },
});
```

Every alert goes to every channel at once, each as a task of its own with a token cancelled after 15 seconds; a send past its time is counted as failed, and a channel that fails goes to the error handler (as `alert channel <name>`) and never holds up the others. `CustomChannel.Create(name, fn)` wraps a function of the alert, a `ChannelContext` and a token; a channel of your own implements `IChannel` (`Name` and `SendAsync(alert, context, cancellationToken)`).

### Email, SMS and error trackers

```csharp
// Email. Each takes the email options: From, To, SubjectPrefix, Link.
new ResendChannel(new ResendOptions { ApiKey = Env("RESEND_API_KEY"),
    From = "CronWatch <alerts@example.com>", To = { "ops@example.com" } });
new PostmarkChannel(new PostmarkOptions { ServerToken = Env("POSTMARK_SERVER_TOKEN"),
    From = "CronWatch <alerts@example.com>", To = { "ops@example.com" } });
new SendGridChannel(new SendGridOptions { ApiKey = Env("SENDGRID_API_KEY"),
    From = "CronWatch <alerts@example.com>", To = { "ops@example.com" } });
new MailgunChannel(new MailgunOptions { ApiKey = Env("MAILGUN_API_KEY"),
    Domain = "mg.example.com", Region = "eu",
    From = "CronWatch <alerts@example.com>", To = { "ops@example.com" } });
new SesChannel(new SesOptions { Region = "us-east-1",
    AccessKeyId = Env("AWS_ACCESS_KEY_ID"), SecretAccessKey = Env("AWS_SECRET_ACCESS_KEY"),
    From = "CronWatch <alerts@example.com>", To = { "ops@example.com" } });

// SMS, one message per number, all at once. Recovered = true texts recoveries too.
new TwilioChannel(new TwilioOptions { AccountSid = Env("TWILIO_ACCOUNT_SID"),
    AuthToken = Env("TWILIO_AUTH_TOKEN"), From = "+15005550006", To = { "+15551110000" } });

// Error trackers: one issue per job and alert type.
new SentryChannel(new SentryOptions { Dsn = Env("SENTRY_DSN") });
new HoneybadgerChannel(new HoneybadgerOptions { ApiKey = Env("HONEYBADGER_API_KEY") });
new DatadogChannel(new DatadogOptions { ApiKey = Env("DD_API_KEY"), Site = "datadoghq.eu", Tags = { "env:prod" } });
new RollbarChannel(new RollbarOptions { AccessToken = Env("ROLLBAR_ACCESS_TOKEN") });
new BugsnagChannel(new BugsnagOptions { ApiKey = Env("BUGSNAG_API_KEY") });
new NewRelicChannel(new NewRelicOptions { AccountId = "1234567", ApiKey = Env("NEW_RELIC_LICENSE_KEY") });
```

The options are the SDK's in PascalCase: `SubjectPrefix` and `Link` among the email options; `MessageStream` (Postmark); `Region` (`"eu"` for SendGrid, Mailgun and New Relic, the AWS region for SES); `SessionToken` and `ConfigurationSetName` (SES); `ApiKeySid`, `ApiKeySecret`, `MessagingServiceSid` and `Segments` (Twilio, 1 to 10, default 3); `Environment` (Sentry, Honeybadger and Rollbar, `"production"` by default); `Release` (Sentry); `Headers` (the webhook, extra request headers in the order sent); `Endpoint` (Honeybadger, Bugsnag); `Host` (Datadog); `ReleaseStage` (Bugsnag); `EventType` (New Relic); and `Recovered` and `Link` wherever the SDK has them, with the SDK's defaults. No options class's `ToString()` prints a credential, and neither does a logger that walks its public properties.

Each sends exactly the request the SDK's does: the same URL, headers and body, byte for byte (the package's tests replay the SDK's recorded requests), with the same idempotency key, event id or UUID for one alert, so a provider that deduplicates drops a resend whichever language sent it. SES is signed with SigV4, with no AWS SDK. Each request has one ten second deadline for the whole request, reads at most 1 MiB of the answer, follows no redirect (so credentials never reach another address), uses no proxy, and always verifies TLS. A refused request names only the URL's origin, never its path, with the channel's keys cut out. The requests go through the client's `ITransport`, by default an `HttpClientTransport` over one `HttpClient` the client makes on its first send and disposes with itself; `Transport` on the client's options, or on one channel's or triage's, takes one of your own, for `IHttpClientFactory`, a proxy or your own trust store. [Alerts](/docs/alerts/#email-sms-and-error-trackers) describes what each one sends.

A webhook posts the alert as JSON with `"schema": 1` as its first field, the same body every CronWatch library posts, described by its [JSON Schema](/docs/alerts/#the-webhook-39-s-schema); parse the fields, not `Title` and `Message`, whose wording is not promised. It signs the body with `X-CronWatch-Signature: sha256=<hex>`. `WebhookChannel.Signature(secret, body)` is that hex, for a receiver in .NET; compare it with `CryptographicOperations.FixedTimeEquals`:

```csharp
string body = await new StreamReader(request.Body).ReadToEndAsync();
byte[] want = Encoding.ASCII.GetBytes("sha256=" + WebhookChannel.Signature(secret, body));
byte[] got = Encoding.ASCII.GetBytes(request.Headers["X-CronWatch-Signature"].ToString());
bool genuine = CryptographicOperations.FixedTimeEquals(want, got);
```

### Processes that cannot send

A job can run somewhere that cannot reach Slack or a mail relay: a sandboxed worker, a batch host without the app's secrets. Give that client `Deliver = Deliver.AtCheck`:

```csharp
await using var cw = new CronwatchClient(new CronwatchOptions { Store = store, Deliver = Deliver.AtCheck });
```

It still records and evaluates every run, but queues each alert in the store instead of sending it. The next check in a client that sends normally delivers it, with triage if that client has it. Both must use the same store. See [processes that cannot send](/docs/alerts/#processes-that-cannot-send).

## pg_cron

pg_cron runs jobs inside Postgres, where nothing can wrap them. `PgCronSource` reads what pg_cron records instead: on every check it reads `cron.job`, declares each job with its schedule, and copies new rows of `cron.job_run_details` in as runs, so a job that stops running is missed, a failed run alerts and a run that never ends is stuck.

```csharp
await using var cw = new CronwatchClient(new CronwatchOptions
{
    Store = SqlStore.Postgres(pg),
    Sources = { new PgCronSource(pg, new PgCronOptions { Prefix = "db:", Options = new JobOptions { Grace = "5m" } }) },
});
```

It reads through a data source on the database pg_cron runs in (its `cron.database_name`), each query on a connection of its own, outside any ambient transaction. Its options: `Jobs`, `JobIds` and `Pick` to choose jobs; `Prefix`, `JobName`, and `Options` or `OptionsFor` (job options for every job, or per job; the schedule and zone always come from pg_cron); and `Timezone` (by default the server's `cron.timezone`, else UTC). The rules for renamed jobs, runs cut off by a restart and history seen for the first time are the SDK's; see [Supabase and pg_cron](/docs/supabase/).

## Redaction

Before a run's output and error are stored, shown or sent anywhere, they are redacted. The default blanks values that look like secrets (secret-named pairs, credentials in URLs, authorization headers, private keys, JWTs, webhook URLs, and AWS, GitHub, Slack, Stripe, Google and API key formats), exactly what the SDK's default blanks: the patterns are the SDK's, run by an engine with JavaScript's semantics, so every case the SDK's tests hold gives the same bytes. An `Expect` rule is checked before redaction, so it still sees what was logged. Redaction runs before the cap, so the cut never keeps the rest of a secret whose label it cut off.

```csharp
new CronwatchOptions { Redact = Redaction.None };                                            // keep output as logged
new CronwatchOptions { Redact = text => Regex.Replace(text, @"\b\d{16}\b", "[card]") };     // your own
```

A function given to `Redact` replaces the default; one that throws falls back to the default.

`Expect.Matches(source, flags)` takes a JavaScript regular expression, stored as `matches /source/flags` and run by the same engine, so it reads as the SDK reads it; `Expect.That(predicate)` takes a function of the output (a throw in it fails the run). A `System.Text.RegularExpressions.Regex` is not taken: it reads a pattern differently (its `$`, `\s` and case folding are its own), and another port could not run what it stored. A stored pattern that runs past fifty million steps (one that backtracks over an output it does not match) fails the run.

## Triage

```csharp
await using var cw = new CronwatchClient(new CronwatchOptions
{
    Alerts = { Slack.Webhook(slackWebhookUrl) },
    Triage = new AnthropicTriage(new AnthropicTriageOptions
    {
        Context = "An ASP.NET Core service on Kubernetes with a Postgres database.",
    }),
});
```

`AnthropicTriageOptions`:

| Option | Default | |
|---|---|---|
| `Model` | `"claude-opus-5"` | any current model id |
| `Effort` | `"medium"` | `"low"`, `"medium"` or `"high"` |
| `MaxTokens` | 800 | a diagnosis is a paragraph |
| `Context` | | a sentence about the app, so advice is specific |
| `Fallbacks` | `true` | `false` stops routing a policy refusal to Anthropic's default fallback model inside the same request, if your account or gateway rejects the beta |
| `ApiKey` | `ANTHROPIC_API_KEY`, read when triage runs | |
| `BaseUrl` | `ANTHROPIC_BASE_URL`, else `https://api.anthropic.com` | |
| `Transport` | the client's | as for the channels |

There is no Anthropic package to add: the Messages API is one POST, and it sends the request the SDK's official client sends. It runs only when an alert is sent (never per run, never for a recovery), once per alert, with one attempt and no retries. The client waits 25 seconds for it and the request gives up first, so the alert goes out without a diagnosis rather than late, and the failure is reported to the error handler. What is sent is in [AI triage](/docs/triage/). A triage of your own implements `ITriage`: it is given the alert and the job's newest runs, and answers a diagnosis, or null for none.

## Telemetry

An `ActivitySource` and a `Meter`, both named `Cronwatch`: an activity around each run (a child of the caller's, so a job's database calls nest under it) and each check, and counters of runs, alerts and checks with a histogram of run durations. Add `.AddSource("Cronwatch")` and `.AddMeter("Cronwatch")` to an OpenTelemetry setup.

## Native AOT

The core, `Cronwatch.Hosting`, `Cronwatch.AspNetCore` and `Cronwatch.Quartz` are trimming and Native AOT compatible: no reflection, no reflection-based JSON, no runtime code generation, and the configuration binding through the binder's source generator. [`examples/aot`](https://github.com/phillips-jon/cronwatch/tree/main/packages/dotnet/examples/aot), an ASP.NET Core app with `AddCronwatch` on SQLite, a hosted job and the dashboard, is published with Native AOT and warnings as errors in CI, then run. `Cronwatch.Hangfire` is not, since Hangfire itself is not. A container image without `tzdata` (the chiseled and distroless images, unless you pick an `-extra` one) has no named zones, so a job naming one is refused when it is declared.

## API

`CronwatchOptions`:

| Option | Default | |
|---|---|---|
| `Store` | `MemoryStore` | |
| `Alerts` | `ConsoleChannel` | channels. `Alerts = []` sends nothing |
| `Triage` | | `new AnthropicTriage(...)`, or an `ITriage` of your own |
| `Sources` | | where runs this client does not wrap come from, such as [pg_cron](#pg-cron). Each is synced at the start of every check; one that fails is reported and the check carries on |
| `CronSecret` | `$CRON_SECRET` | the bearer job handlers take and the dashboard's check endpoint accepts beside the token; `CronSecret.None` for none |
| `Retention` | `"30d"` | how long finished runs are kept. Each job's newest run is always kept |
| `Defaults` | | `Grace`, `Timeout`, `Timezone` and `FailuresBeforeAlert` for every job that does not set its own; any other option is refused |
| `Redact` | secret patterns | see [Redaction](#redaction) |
| `Deliver` | `Deliver.Now` | `Deliver.AtCheck` queues alerts for another client's check to send |
| `Transport` | an `HttpClientTransport` | for every channel and triage without one of their own |
| `OnError`, `OnWarning` | a line to standard error | the error and where, for failures outside jobs: the store, a channel, triage |
| `Environment` | | the environment when neither `CRONWATCH_ENV` nor `APP_ENV` is set; it outranks `ASPNETCORE_ENVIRONMENT` and `DOTNET_ENVIRONMENT` |
| `ProcessExitHook` | `true` | see [The current run and the timeout](#the-current-run-and-the-timeout) |
| `Clock` | `TimeProvider.System` | every time and timer the client uses; a `FakeTimeProvider` in tests |

A job's options, on `JobOptions`: `Schedule` (five or six field cron, a nickname such as `"@hourly"`, or `"every 5m"`), `Timezone` (IANA; the clock's local zone by default), `Grace` (`"10m"`), `Timeout` (`"1h"`), `MaxDuration`, `Budget` (metrics and their ceilings), `Expect`, `FailuresBeforeAlert` (1), `Description` and `Tags`, with the rules in the [TypeScript API reference](/docs/api/).

| Method | |
|---|---|
| `Job(name, options)` | declare a job and get its handle |
| `job.RunAsync(fn)`, and with `RunOptions` | run as a recorded run; `RunOptions.Trigger` and `DiscardWhen` |
| `CronwatchClient.Current`, `Log`, `Metric`, `CancellationToken` | the run in progress, on its `JobContext` |
| `CheckAsync()` | find missed and stuck runs, send alerts, retry alerts no channel accepted, prune |
| `Start()`, `Start(every)`, `Stop()` | check on an interval |
| `JobsAsync()`, `JobsWithRunsAsync(limit)`, `JobSummaryAsync(name)` | summaries, without alerting |
| `RunsAsync(name, limit)`, `GetRunAsync(id)` | newest first; `limit` is held to 1 to 500 |
| `SilenceAsync(name, duration)`, `UnsilenceAsync(name)` | stop alerts for a while; state keeps updating underneath |
| `ForgetAsync(name)` | remove a job and its runs. A job still declared in code comes back: on its next run, or at the next check or dashboard read of a process that declares it |
| `job.StartAsync(options)`, `job.ResumeAsync(id)`, `ResumeRunAsync(name, id)` | runs that span calls |
| `job.OpenAsync(options)` | a run seen from outside the function, for a scheduler integration: an `ObservedRun` to close or take back |
| `RecordRunAsync(run)` | record a run that happened elsewhere, for a source, its id 1 to 200 characters; answers the alerts it sent |
| `SyncJobAsync(name)` | write a declaration to the store now, unless it already holds it |
| `DefinedJobs` | the jobs declared in this client |
| `Routes()`, `job.Handler(fn)` | the dashboard and a job's handler |
| `DisposeAsync()` | stop the check, record open runs, wait up to five seconds for a check under way, and let go of the store |

`CronwatchException` has a `Kind`: `Invalid` (an option, name, schedule or run id the SDK refuses, with its message), `Store` (the store's own exception as `InnerException`) and `Other`. Reads (`JobsAsync`, `JobSummaryAsync`, `RunsAsync`) and `CheckAsync` throw it when the store fails; `RunAsync`, `Start`, `FlushAsync` and `FinishAsync` never do.

## Runs that span calls

A run is normally one call. Work that starts in one place and ends in another (a job that hands work to a queue, a webhook that reports completion later) can be one run too: `job.StartAsync` records it as running and answers a `RunHandle`, and `FinishAsync` on that handle, or on one from `ResumeRunAsync` in another process, ends it.

```csharp
RunHandle run = await ingest.StartAsync(new StartOptions { Id = "batch-42" });   // records a running run
run.Log("fetched 1,200 rows");
await run.FlushAsync();                                                          // appends what was logged so far
// later, perhaps in another process:
RunHandle again = await cw.ResumeRunAsync("import", "batch-42");
await again.FinishAsync();                                                       // or again.FailAsync(exception)
```

`StartOptions.Id` takes your own stable id, 1 to 200 characters: a start with an id already recorded for this job records nothing and answers a handle on that run, and one recorded for another job is an error, as is an id starting `pgcron:`. The store never fails out of a handle: a failure goes to the error handler, and a finish the store failed leaves the handle active, its lines kept, so it can be called again. A run is judged once however many processes finish it: only the process whose conditional write lands evaluates it. A run that is never finished is marked stuck by the first check after the job's `Timeout`, so set it to cover the whole span.

## Sharing a database with the other languages

`SqlStore` writes the same three tables as `@cronwatch/sdk/sqlite` and `@cronwatch/sdk/postgres`, the Ruby gem, and the Python, PHP, Go, Rust, Elixir and Java stores (the MySQL tables are the PHP, Go, Rust, Elixir and Java ports'): the same names, columns and indexes, epoch milliseconds in the time columns, and the same JSON in the JSON columns, byte for byte, keys in the SDK's order. The package's tests share a SQLite file with the built SDK, and have a Node client and a .NET client take turns on one job's state. Create the tables from any side; the others find them and leave them alone. Use the same prefix everywhere.

Each process alerts on the jobs it runs, and any side's check sees every job in the store. One dashboard shows them all, and one MCP server reads it. Give each job a name only one side uses.

A 1.x release keeps what it does not know in the stored data: a field of a job's state or definition a newer release added, a condition it does not alert on, a run status or trigger it has not seen. It writes them back as they were, never treating an unknown status as running, so any 1.x release of any language can share a store with any other. 0.x releases are not covered: upgrade every process to 1.0 together.

## Kept in step

The TypeScript SDK is the source of truth. Its build generates cases (duration parsing, schedules across daylight saving, sequences of runs and checks with the alerts and state they must produce, alert titles and messages, redaction, each channel's requests, stats and health) into `conformance/` in the repository, and the .NET tests replay every one, as the Ruby gem's and the Python, PHP, Go, Rust, Elixir and Java packages' do, once more under the `tr-TR` culture so no format reads the thread's culture; the dashboard is checked against the SDK's pages byte for byte, straight into the routes, through ASP.NET Core's test server (behind `MapCronwatch` in a route group and behind `UseCronwatch`) and through Kestrel. Cron parsing is also checked against croner itself on thousands of generated expressions. A change of behaviour lands in TypeScript first, the cases are regenerated, and the port is fixed until they pass. Where they disagree, the port is wrong: [open an issue](https://github.com/phillips-jon/cronwatch/issues).
