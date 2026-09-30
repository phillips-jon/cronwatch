using System;
using System.Linq;
using System.Threading.Tasks;
using Xunit;
using static Cronwatch.Tests.Support;

namespace Cronwatch.Tests;

public class ClientSmokeTests
{
    [Fact]
    public async Task A_run_is_recorded_and_its_value_answered()
    {
        await using var m = Make();
        var job = m.Cw.Job("nightly", new JobOptions { Schedule = "0 2 * * *", Grace = "15m" });
        string answer = await job.RunAsync(async (ctx, ct) =>
        {
            ctx.Log("Report written");
            ctx.Metric("cost", 1.25);
            Assert.Same(ctx, CronwatchClient.Current);
            await Task.Yield();
            return "done";
        });
        Assert.Equal("done", answer);
        Assert.Null(CronwatchClient.Current);
        var runs = await m.Cw.RunsAsync("nightly");
        var run = Assert.Single(runs);
        Assert.Equal(RunStatus.Ok, run.Status);
        Assert.Equal("Report written", run.Output);
        Assert.Equal("{\"cost\":1.25}", run.Metrics.ToJson());
        Assert.Empty(m.Errors.Entries);
        Assert.Equal("{\"schedule\":\"0 2 * * *\",\"grace\":\"15m\",\"name\":\"nightly\"}", job.Definition.ToJson());
    }

    [Fact]
    public async Task A_throw_is_a_failed_run_and_an_alert_and_is_thrown_again()
    {
        await using var m = Make();
        var job = m.Cw.Job("fails");
        var e = await Assert.ThrowsAsync<InvalidOperationException>(() => job.RunAsync((ctx, ct) => throw new InvalidOperationException("boom")));
        Assert.Equal("boom", e.Message);
        var run = Assert.Single(await m.Cw.RunsAsync("fails"));
        Assert.Equal(RunStatus.Failed, run.Status);
        Assert.StartsWith("InvalidOperationException: boom", run.Error, StringComparison.Ordinal);
        Assert.Equal(["failed"], m.Alerts.Types());
        await job.RunAsync((ctx, ct) => Task.CompletedTask);
        Assert.Equal(["failed", "recovered"], m.Alerts.Types());
    }

    [Fact]
    public async Task A_missed_run_is_found_by_a_check()
    {
        await using var m = Make();
        m.Cw.Job("hourly", new JobOptions { Schedule = "every 1h", Grace = "5m" });
        await m.Cw.CheckAsync();
        Assert.Empty(m.Alerts.Types());
        m.Clock.Advance(2 * Hour);
        var result = await m.Cw.CheckAsync();
        Assert.Equal(["missed"], result.Alerts.Select(a => a.Type.Value));
        Assert.Equal(["missed"], m.Alerts.Types());
    }
}
