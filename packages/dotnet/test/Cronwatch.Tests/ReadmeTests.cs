using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Data.Sqlite;
using Xunit;

namespace Cronwatch.Tests;

/// <summary>
/// Every C# example in the README, compiled here and run: each <c>csharp</c> block of the README
/// must appear in this file, whitespace aside, so an example that stops compiling fails the build.
/// The first example uses a path relative to the working directory, so these run alone.
/// </summary>
[Collection(nameof(Alone))]
public class ReadmeTests
{
    private static readonly string[] Files = ["a.csv", "b.csv"];

    private static Task<string> BuildReportAsync(CancellationToken ct) => Task.FromResult("reports/nightly.pdf");

    private static Task ImportAsync(string file, CancellationToken ct) => Task.CompletedTask;

    [Fact]
    public async Task Use()
    {
        using var dir = new TempDir();
        Directory.CreateDirectory(Path.Combine(dir.Path, "data"));
        string cwd = Environment.CurrentDirectory;
        Environment.CurrentDirectory = dir.Path;
        try
        {
            // README: Use
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
            // End of the README's example.

            Assert.Equal("reports/nightly.pdf", path);
            Assert.Equal(
                "{\"schedule\":\"0 2 * * *\",\"timezone\":\"UTC\",\"grace\":\"15m\",\"timeout\":1800000,\"budget\":{\"cost\":2},\"failuresBeforeAlert\":1,\"name\":\"nightly-report\",\"expect\":\"contains \\\"Report written\\\"\"}",
                nightly.Definition.ToJson());
            Assert.Single(result.Jobs);
            cw.Stop();
        }
        finally
        {
            Environment.CurrentDirectory = cwd;
        }
    }

    [Fact]
    public async Task The_current_run()
    {
        await using var m = Support.Make();
        var cw = m.Cw;
        var files = Files;

        await cw.Job("import").RunAsync(async (job, ct) =>
        {
            await Parallel.ForEachAsync(files, ct, async (file, token) =>
            {
                await ImportAsync(file, token);
                CronwatchClient.Current?.Log($"imported {file}"); // the same run
            });
        });

        var run = Assert.Single(await cw.RunsAsync("import"));
        Assert.Contains("imported a.csv", run.Output, StringComparison.Ordinal);
        Assert.Contains("imported b.csv", run.Output, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Runs_that_span_calls()
    {
        await using var m = Support.Make();
        var cw = m.Cw;

        RunHandle handle = await cw.Job("export").StartAsync(new StartOptions { Id = "export-2026-01-05" });
        handle.Log("queued");
        await handle.FlushAsync();
        // ... later, maybe elsewhere:
        RunHandle again = await cw.ResumeRunAsync("export", "export-2026-01-05");
        await again.FinishAsync("export done");

        Run run = (await cw.GetRunAsync("export-2026-01-05"))!;
        Assert.Equal(RunStatus.Ok, run.Status);
        Assert.Equal("queued\nexport done", run.Output);
    }

    [Fact]
    public void Every_example_in_the_readme_is_here()
    {
        string readme = File.ReadAllText(Path.Combine(Fixtures.Repo, "packages", "dotnet", "README.md"), Encoding.UTF8);
        string here = Squash(File.ReadAllText(Path.Combine(Fixtures.Repo, "packages", "dotnet", "test", "Cronwatch.Tests", "ReadmeTests.cs"), Encoding.UTF8));
        var blocks = new List<string>();
        foreach (Match match in Regex.Matches(readme.Replace("\r\n", "\n", StringComparison.Ordinal), "```csharp\n(.*?)```", RegexOptions.Singleline))
        {
            blocks.Add(match.Groups[1].Value);
        }
        Assert.NotEmpty(blocks);
        foreach (string block in blocks)
        {
            Assert.True(here.Contains(Squash(block), StringComparison.Ordinal), "the README's example is not compiled here:\n" + block);
        }
    }

    private static string Squash(string text) => Regex.Replace(text, "\\s+", "");
}

/// <summary>Tests that change what the whole process shares (its working directory) run alone.</summary>
[CollectionDefinition(nameof(Alone), DisableParallelization = true)]
public sealed class Alone
{
}
