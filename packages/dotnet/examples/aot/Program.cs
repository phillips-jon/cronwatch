// CronWatch in an ASP.NET Core app published with Native AOT: the client from AddCronwatch on
// SQLite, a hosted job, a job run by hand, a check, and the dashboard at /cronwatch through
// MapCronwatch. With `once`, it serves on a free loopback port, runs the job, checks, asks the
// dashboard for its page and its JSON, prints what it saw, and exits 0 when all of it worked,
// which is how CI runs the published binary.
//
//   dotnet publish examples/aot -c Release -o artifacts/aot && artifacts/aot/aot once
using System;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch;
using Cronwatch.AspNetCore;
using Cronwatch.Hosting;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.Data.Sqlite;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

string file = Path.Combine(Path.GetTempPath(), "cronwatch-aot-" + Guid.NewGuid().ToString("N") + ".db");
WebApplicationBuilder builder = WebApplication.CreateSlimBuilder(args);
builder.Logging.ClearProviders();
builder.WebHost.UseUrls("http://127.0.0.1:0");
builder.Services.AddCronwatch(o =>
{
    o.Store = SqlStore.Sqlite(SqliteFactory.Instance.CreateDataSource("Data Source=" + file + ";Pooling=False"));
    o.Alerts.Add(CustomChannel.Create("print", (alert, ctx, ct) => Console.Out.WriteLineAsync("alert " + alert.Job + " " + alert.Type.Value)));
    o.Token = "aot-example-token";
    o.ProcessExitHook = false;
});
builder.Services.AddCronwatchJob<Tidy>("tidy", new JobOptions { Schedule = "*/5 * * * *", Timezone = "UTC" });

int status = 1;
await using (WebApplication app = builder.Build())
{
    app.MapCronwatch();
    await app.StartAsync();
    CronwatchClient cw = app.Services.GetRequiredService<CronwatchClient>();
    try
    {
        string output = await cw.Job("nightly-report", new JobOptions { Schedule = "0 2 * * *", Timezone = "UTC", Expect = "Report written" })
            .RunAsync(async (job, ct) =>
            {
                await Task.Delay(5, ct);
                job.Log("Report written");
                job.Metric("rows", 42);
                return "done";
            });
        CheckResult result = await cw.CheckAsync();
        string address = app.Services.GetRequiredService<IServer>().Features.Get<IServerAddressesFeature>()!.Addresses.First();
        using var http = new HttpClient { BaseAddress = new Uri(address) };
        http.DefaultRequestHeaders.Authorization = new("Bearer", "aot-example-token");
        using HttpResponseMessage page = await http.GetAsync(new Uri("/cronwatch", UriKind.Relative));
        using HttpResponseMessage jobs = await http.GetAsync(new Uri("/cronwatch/api/jobs", UriKind.Relative));
        string json = await jobs.Content.ReadAsStringAsync();
        Run run = (await cw.RunsAsync("nightly-report", 1))[0];
        await Console.Out.WriteLineAsync("run " + run.Status.Value + ", checked " + result.Jobs.Count + ", page " + (int)page.StatusCode + ", api " + (int)jobs.StatusCode);
        status = run.Status == RunStatus.Ok && output == "done" && page.IsSuccessStatusCode && jobs.IsSuccessStatusCode && json.Contains("\"nightly-report\"", StringComparison.Ordinal) ? 0 : 1;
    }
    finally
    {
        if (args is not ["once"])
        {
            await app.WaitForShutdownAsync();
        }
        await app.StopAsync();
    }
}
SqliteConnection.ClearAllPools();
File.Delete(file);
return status;

/// <summary>A hosted job: tidies every five minutes.</summary>
internal sealed class Tidy : ICronwatchJob
{
    public Task RunAsync(JobContext job, CancellationToken cancellationToken)
    {
        job.Log("tidied");
        return Task.CompletedTask;
    }
}
