using System.Threading;
using System.Threading.Tasks;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Xunit;

namespace Cronwatch.Hosting.Tests;

/// <summary>
/// The README's hosting examples, compiled here (the core's tests check that every C# block of
/// the README appears in a <c>ReadmeTests.cs</c>).
/// </summary>
public class ReadmeTests
{
    /// <summary>What the README's job is given.</summary>
    public sealed class ReportBuilder
    {
        public Task<string> BuildAsync(CancellationToken ct) => Task.FromResult("reports/nightly.csv");
    }

    public sealed class NightlyReport(ReportBuilder reports) : ICronwatchJob
    {
        public async Task RunAsync(JobContext job, CancellationToken cancellationToken)
        {
            string path = await reports.BuildAsync(cancellationToken); // cancelled at the timeout and at shutdown
            job.Log($"Report written: {path}");
        }
    }

    private static async Task<int> RunAppAsync(string[] args, CronwatchClient cw)
    {
        var builder = Host.CreateApplicationBuilder();
        builder.Logging.ClearProviders();
        builder.Services.AddSingleton(cw);
        builder.Services.AddSingleton<ReportBuilder>();

        builder.Services.AddCronwatchJob<NightlyReport>("nightly-report", new JobOptions
        {
            Schedule = "0 2 * * *",
            Timezone = "UTC",
            Grace = "15m",
        });

        var app = builder.Build();
        return await app.RunCronwatchCommandAsync(args); // `dotnet MyApp.dll cronwatch check`, else runs the app
    }

    [Fact]
    public async Task Hosted_jobs()
    {
        await using var cw = new CronwatchClient(new CronwatchOptions { Alerts = [], ProcessExitHook = false, OnWarning = _ => { } });
        Assert.Equal(2, await RunAppAsync(["cronwatch", "no-such-command"], cw));
        await using var again = new CronwatchClient(new CronwatchOptions { Alerts = [], ProcessExitHook = false, OnWarning = _ => { } });
        Assert.Equal(0, await RunAppAsync(["cronwatch", "help"], again));
    }
}
