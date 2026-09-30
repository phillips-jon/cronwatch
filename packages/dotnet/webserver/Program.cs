using System;
using System.Globalization;
using System.Net;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch;
using Cronwatch.AspNetCore;
using Cronwatch.Hosting;
using Cronwatch.Web;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;

// Serves the dashboard over HTTP for packages/mcp/test/dotnet-web.test.ts, which drives
// @cronwatch/mcp against it. Seeded like the MCP tests' own end-to-end case: a nightly job with
// one good run and one failed one, and a fixed clock. Served by Kestrel with the dashboard at
// /cronwatch through MapCronwatch, the client from AddCronwatch. Alerts are printed as
// `alert <job> <type>` lines.
//
//   dotnet webserver/bin/Release/net10.0/webserver.dll PORT
if (args.Length != 1 || !int.TryParse(args[0], NumberStyles.None, CultureInfo.InvariantCulture, out int port))
{
    Console.Error.WriteLine("usage: webserver PORT");
    return 2;
}

var clock = new FixedClock(1_767_578_400_000L); // 2026-01-05 02:00:00 UTC
WebApplicationBuilder builder = WebApplication.CreateSlimBuilder();
builder.Logging.ClearProviders();
builder.WebHost.UseKestrel(k => k.Listen(IPAddress.Loopback, port));
builder.Services.AddCronwatch(o =>
{
    o.Alerts.Add(CustomChannel.Create("test", (alert, ctx, ct) =>
    {
        Console.Out.Write("alert " + alert.Job + " " + alert.Type.Value + "\n");
        Console.Out.Flush();
        return Task.CompletedTask;
    }));
    o.CronSecret = CronSecret.None;
    o.ProcessExitHook = false;
    o.Clock = clock;
    o.NoCheck = true;
});
await using WebApplication app = builder.Build();

CronwatchClient cw = app.Services.GetRequiredService<CronwatchClient>();
Job nightly = cw.Job("nightly", new JobOptions { Schedule = "0 2 * * *", Timezone = "UTC", Grace = "15m" });
await nightly.RunAsync((job, ct) =>
{
    job.Log("step 1");
    return Task.CompletedTask;
});
clock.Advance(60_000);
try
{
    await nightly.RunAsync((job, ct) =>
    {
        job.Log("step 2");
        throw new InvalidOperationException("db down");
    });
}
catch (InvalidOperationException)
{
    // The failed run is the seed.
}

app.MapCronwatch("/cronwatch", new RoutesOptions { Token = "tok" });
app.Lifetime.ApplicationStarted.Register(() =>
{
    Console.Out.Write("serving on " + port.ToString(CultureInfo.InvariantCulture) + "\n");
    Console.Out.Flush();
});
await app.RunAsync();
return 0;

/// <summary>A clock that moves only when told, its zone UTC.</summary>
internal sealed class FixedClock(long now) : TimeProvider
{
    private long _now = now;

    public override TimeZoneInfo LocalTimeZone => TimeZoneInfo.Utc;

    public override DateTimeOffset GetUtcNow() => DateTimeOffset.FromUnixTimeMilliseconds(Interlocked.Read(ref _now));

    public void Advance(long ms) => Interlocked.Add(ref _now, ms);
}
