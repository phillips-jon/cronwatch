using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using Xunit;

namespace Cronwatch.Tests;

/// <summary><c>examples/crontab</c>: its two crontab lines run as two processes on one SQLite file.</summary>
public class CrontabExampleTests
{
    private static string Example()
    {
        // .../packages/dotnet/test/Cronwatch.Tests/bin/<configuration>/<framework>/
        var bin = new DirectoryInfo(AppContext.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar));
        string framework = bin.Name;
        string configuration = bin.Parent!.Name;
        string root = bin.Parent!.Parent!.Parent!.Parent!.Parent!.FullName;
        return Path.Combine(root, "examples", "crontab", "bin", configuration, framework, "Crontab.dll");
    }

    private static async Task<(int Status, string Out, string Err)> Line(string file, bool fails, params string[] args)
    {
        var start = new ProcessStartInfo(ThreadsTests.DotnetHost(), [Example(), .. args])
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
        };
        start.Environment["CRONWATCH_DB"] = file;
        start.Environment["REPORT_FAILS"] = fails ? "1" : "0";
        using var process = Process.Start(start)!;
        var stdout = process.StandardOutput.ReadToEndAsync();
        var stderr = process.StandardError.ReadToEndAsync();
        try
        {
            await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(60));
        }
        catch (TimeoutException)
        {
            // Stopped, so it lets go of the database before the directory is deleted.
            process.Kill(entireProcessTree: true);
            throw;
        }
        return (process.ExitCode, (await stdout).Replace("\r\n", "\n", StringComparison.Ordinal), (await stderr).Replace("\r\n", "\n", StringComparison.Ordinal));
    }

    [Fact]
    public async Task The_job_and_its_check_run_as_two_processes_on_one_file()
    {
        Assert.True(File.Exists(Example()), "the example is built beside the tests: " + Example());
        using var dir = new TempDir();
        string file = dir.File("cw.db");

        var job = await Line(file, false, "nightly-report");
        Assert.True(job.Status == 0, job.Out + job.Err);
        var check = await Line(file, false, "cronwatch", "check");
        Assert.True(check.Status == 0, check.Out + check.Err);
        Assert.Equal("cronwatch: checked 1 job, sent 0 alerts\n", check.Out);

        var failed = await Line(file, true, "nightly-report");
        Assert.Equal(1, failed.Status);
        Assert.Contains("nightly-report failed: the reports disk is full", failed.Err, StringComparison.Ordinal);

        Assert.Equal(2, (await Line(file, false, "cronwatch", "nope")).Status);

        var store = SqlStore.Sqlite(StoreTests.Sqlite(file));
        await using (store)
        {
            var runs = await store.ListRunsAsync("nightly-report", 10);
            Assert.Equal([RunStatus.Failed, RunStatus.Ok], runs.Select(r => r.Status).ToArray());
            Assert.Equal("Report written: /var/reports/nightly.csv", runs[1].Output);
        }
    }
}
