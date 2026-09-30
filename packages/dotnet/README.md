# cronwatch for .NET

Cron and scheduled-job monitoring that lives inside your .NET service. Wrap a job once; every run is recorded in a database you already have, and you are told when a run is missed, fails, gets stuck, runs slow or goes over budget. No server to run, no account to make. This is the library behind [cronwatch.dev](https://cronwatch.dev).

This is the .NET port of [`@cronwatch/sdk`](https://www.npmjs.com/package/@cronwatch/sdk): the same rules, the same alert text and the same stored rows, so a .NET process and a Node, Ruby, Python, PHP, Go, Rust, Elixir or Java process can share one database, and every port reads the tables the others write. It is built in phases ([DESIGN.md](DESIGN.md) has the plan and how each part works). Phase 1 has the core: jobs, runs in the caller's flow, runs that span calls, checks, silences, sources, deferred delivery and the triage hook, the current run across tasks and threads, the process-exit hook, the memory store, and the SQL store over ADO.NET on SQLite. Phase 3 adds the dashboard and a job's handler, framework-free in the core, `Cronwatch.Hosting` (the client in the Generic Host's container) and `Cronwatch.AspNetCore` (the dashboard and handler on ASP.NET Core). Other phases add the SQL store on Postgres, MySQL and MariaDB, the SDK's fifteen alert channels, Claude triage, the pg_cron source, and the Hangfire and Quartz.NET integrations.

It is not on NuGet yet. The first release will be the `Cronwatch` package:

```bash
dotnet add package Cronwatch --version 0.8.0
```

## Install

.NET 10 or newer. The `Cronwatch` package depends on no other package: cron expressions are read by a port of [croner](https://github.com/hexagon/croner), the parser the SDK uses, so every port agrees on every fire time; zones come from the system's IANA database through `TimeZoneInfo`; JSON, the JavaScript regular expressions a stored `expect` pattern holds, and secret redaction are the port's own. It is trimming and Native AOT compatible.

The SQL store takes the app's `System.Data.Common.DbDataSource` and driver, a normal dependency of your app: `Microsoft.Data.Sqlite` for SQLite (`SqliteFactory.Instance.CreateDataSource(...)` is a data source). None is a dependency of CronWatch. A container image without `tzdata` (the chiseled and distroless images, unless you pick an `-extra` one) has no named zones, and a job naming one is refused when it is declared.

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

### Stores

`MemoryStore` is the default and forgets on restart. `SqlStore.Sqlite(dataSource)` keeps the SDK's three tables (`cronwatch_jobs`, `cronwatch_runs`, `cronwatch_state`, their text byte for byte what the SDK writes) in the app's database; `WithPrefix("cw_")` names them otherwise. The store opens its connections with the app's ambient transaction suppressed, so a run survives the rollback its failure caused. A store of the app's own implements `IStore` and passes `Cronwatch.StoreTesting.StoreContract.RunAsync(store)`, which depends on no test framework.

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

The dashboard asks for its token as `Authorization: Bearer <token>`, or once as `?token=` on a page, which moves it into a cookie. In development with no token it makes one and prints a sign-in link on its first request; outside development with none it answers 503. `Token = DashboardToken.None` serves it open, behind the app's own sign-in: while it has a token its endpoints allow anonymous requests (so an app whose fallback policy requires a signed-in user still reaches the dashboard's sign-in), and open it takes the app's authorization policy. The endpoints skip antiforgery (the dashboard has its own cross-site check) and are left out of OpenAPI. `app.UseCronwatch("/cronwatch")` serves it as middleware instead, and `MapGroup("/admin").MapCronwatch()` under a group. Behind a proxy, `RoutesOptions.Origin` names the public origin, or `TrustProxy` reads `X-Forwarded-Proto` and `X-Forwarded-Host`.

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

The suite replays the repository's `conformance/` fixtures byte for byte. The croner parity check and the SQLite file shared with Node need the built SDK (`npm run build --workspace packages/sdk` at the repository's root) and skip without it. The tests run on a `FakeTimeProvider`, in UTC. `CRONWATCH_TRIES=N` runs the properties longer. The dashboard replays the SDK's captures (`packages/ruby/test/web/golden.json`) three ways: straight into the routes, through ASP.NET Core's test server, and through Kestrel over a raw socket. `CRONWATCH_TEST_DOTNET=1 npm test --workspace packages/mcp`, at the repository's root, drives `@cronwatch/mcp` against `webserver`, a seeded dashboard.

## License

MIT
