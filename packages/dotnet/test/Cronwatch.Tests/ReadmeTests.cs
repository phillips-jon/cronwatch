using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch.Alerts;
using Cronwatch.PgCron;
using Cronwatch.Triage;
using Microsoft.Data.Sqlite;
using Npgsql;
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
            cw.StartChecking(TimeSpan.FromMinutes(1)); // a check every minute, for a long-running process
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
    public async Task A_plain_crontab()
    {
        var store = new MemoryStore();
        CronwatchClient MakeClient() => new(new CronwatchOptions { Store = store, Alerts = [], ProcessExitHook = false, OnWarning = _ => { } });
        async Task<int> Main(string[] args)
        {
            if (args is ["cronwatch", .. var rest])
            {
                return await CronwatchCli.RunAsync(MakeClient, rest, Console.Out, Console.Error);
            }
            return -1;
        }
        Assert.Equal(0, await Main(["cronwatch", "help"]));
        Assert.Equal(-1, await Main(["nightly-report"]));
    }

    /// <summary>Coravel's interface, so the README's invocable compiles without Coravel.</summary>
    private interface IInvocable
    {
        Task Invoke();
    }

    private static Task SendDigestAsync(CancellationToken ct) => Task.CompletedTask;

    public sealed class SendDigest(CronwatchClient cw) : IInvocable
    {
        public Task Invoke() => cw.Job("send-digest").RunAsync((job, ct) => SendDigestAsync(ct));
    }

    [Fact]
    public async Task Coravel()
    {
        await using var m = Support.Make();
        await new SendDigest(m.Cw).Invoke();
        Assert.Equal(RunStatus.Ok, Assert.Single(await m.Cw.RunsAsync("send-digest")).Status);
    }

    [Fact]
    public async Task Alerts_triage_and_pg_cron()
    {
        // Nothing here reaches a server: the data source connects on first use, and the client
        // is only made and disposed.
        const string connectionString = "Host=127.0.0.1;Database=cw;Username=postgres";
        const string slackWebhookUrl = "https://hooks.slack.example/T/B/not-a-real-hook";
        const string resendApiKey = "not-a-real-key";

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

        Assert.Equal("postgres", ((SqlStore)cw.Store).Dialect);
        Assert.DoesNotContain(resendApiKey, cw.ToString(), StringComparison.Ordinal);
        await pg.DisposeAsync();
    }

    [Fact]
    public void Every_example_in_the_readme_is_here()
    {
        string readme = File.ReadAllText(Path.Combine(Fixtures.Repo, "packages", "dotnet", "README.md"), Encoding.UTF8);
        // The core's examples are compiled here, and each package's in its own tests' ReadmeTests.cs.
        var sources = new StringBuilder();
        foreach (string file in Directory.GetFiles(Path.Combine(Fixtures.Repo, "packages", "dotnet", "test"), "ReadmeTests.cs", SearchOption.AllDirectories))
        {
            sources.Append(File.ReadAllText(file, Encoding.UTF8));
        }
        string here = Squash(sources.ToString());
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
