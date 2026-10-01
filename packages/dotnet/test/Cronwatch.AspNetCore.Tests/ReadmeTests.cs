using System;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch.Web;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace Cronwatch.AspNetCore.Tests;

/// <summary>
/// The README's ASP.NET Core and framework-free examples, compiled and run here; the core's
/// <c>ReadmeTests</c> checks that every example of the README appears in one of the two files.
/// </summary>
public class ReadmeTests
{
    private static Task BuildReportAsync(CancellationToken ct) => Task.CompletedTask;

    [Fact]
    public async Task The_dashboard_and_a_jobs_handler_on_AspNetCore()
    {
        // README: The dashboard and a job's handler on ASP.NET Core
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
        // End of the README's example.

        Assert.NotNull(cw.DeclaredJob("nightly-report"));
        await app.DisposeAsync();
    }

    [Fact]
    public async Task The_routes_without_a_framework()
    {
        await using var cw = new CronwatchClient(new CronwatchOptions { ProcessExitHook = false, Alerts = [] });

        Routes routes = cw.Routes(new RoutesOptions { Token = "letmein-example" });
        CronwatchResponse answer = await routes.HandleAsync(new CronwatchRequest("GET", "/cronwatch/api/jobs")
        {
            Headers = [new("host", "app.example.com"), new("authorization", "Bearer letmein-example")],
        });

        Assert.Equal(200, answer.Status);
        Assert.Equal("{\"ok\":true,\"jobs\":[]}", answer.Text());
    }
}
