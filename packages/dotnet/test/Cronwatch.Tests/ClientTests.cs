using System;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Threading.Tasks;
using Cronwatch.Internal;
using Xunit;
using static Cronwatch.Tests.Support;

namespace Cronwatch.Tests;

/// <summary>
/// The SDK's <c>client.test.ts</c>, ported: runs, failures, expect, the checks for missed and
/// stuck runs, baselines and budgets, silence, triage, forget and a failing channel.
/// </summary>
public class ClientTests
{
    private sealed class FuncTriage(Func<TriageContext, Task<string?>> f) : ITriage
    {
        public Task<string?> TriageAsync(TriageContext context, System.Threading.CancellationToken cancellationToken) => f(context);
    }

    [Fact]
    public async Task Run_records_output_metrics_and_duration_and_returns_the_result()
    {
        await using var m = Make();
        var job = m.Cw.Job("report", new JobOptions { Schedule = "0 2 * * *" });
        string result = await job.RunAsync((j, ct) =>
        {
            j.Log("hello {\"n\":1}");
            j.Metric("rows", 42);
            m.Clock.Advance(1500);
            return Task.FromResult("done");
        });
        Assert.Equal("done", result);
        Run run = (await m.Cw.RunsAsync("report", 50))[0];
        Assert.Equal(RunStatus.Ok, run.Status);
        Assert.Equal(1500L, run.DurationMs);
        Assert.Equal("hello {\"n\":1}", run.Output);
        Assert.Equal("{\"rows\":42}", run.Metrics.ToJson());
        JobSummary summary = (await m.Cw.JobSummaryAsync("report"))!;
        Assert.Equal(JobHealth.Healthy, summary.Health);
        Assert.Equal(Js.DateUtc(2026, 0, 6, 2, 0, 0, 0), summary.NextExpectedAt);
    }

    [Fact]
    public async Task A_throwing_job_is_recorded_as_failed_alerts_and_rethrows()
    {
        await using var m = Make();
        var job = m.Cw.Job("nightly");
        var e = await Assert.ThrowsAsync<InvalidOperationException>(() => job.RunAsync((j, ct) => throw new InvalidOperationException("db down")));
        Assert.Equal("db down", e.Message);
        Run run = (await m.Cw.RunsAsync("nightly", 50))[0];
        Assert.Equal(RunStatus.Failed, run.Status);
        Assert.StartsWith("InvalidOperationException: db down", run.Error, StringComparison.Ordinal);
        Assert.Equal(["failed"], m.Alerts.Types());
        Assert.Contains("db down", m.Alerts.List()[0].Message, StringComparison.Ordinal);
        Assert.Equal(JobHealth.Failing, (await m.Cw.JobSummaryAsync("nightly"))!.Health);
    }

    [Fact]
    public async Task A_function_that_throws_before_returning_a_task_is_a_failed_run()
    {
        await using var m = Make();
        var job = m.Cw.Job("sync-throw");
        Func<JobContext, System.Threading.CancellationToken, Task> fn = (j, ct) => throw new ArgumentException("bad input");
        await Assert.ThrowsAsync<ArgumentException>(() => job.RunAsync(fn));
        Run run = (await m.Cw.RunsAsync("sync-throw", 1))[0];
        Assert.Equal(RunStatus.Failed, run.Status);
        Assert.StartsWith("ArgumentException: bad input", run.Error, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Expect_turns_a_quiet_success_into_a_failure()
    {
        await using var m = Make();
        var job = m.Cw.Job("export", new JobOptions { Expect = "wrote" });
        await job.RunAsync((j, ct) =>
        {
            j.Log("wrote 12 files");
            return Task.CompletedTask;
        });
        Assert.Empty(m.Alerts.Types());
        m.Clock.Advance(Hour);
        await job.RunAsync((j, ct) =>
        {
            j.Log("nothing to do");
            return Task.CompletedTask;
        });
        Run run = (await m.Cw.RunsAsync("export", 50))[0];
        Assert.Equal(RunStatus.Failed, run.Status);
        Assert.Contains("did not contain \"wrote\"", run.Error, StringComparison.Ordinal);
        Assert.Equal(["failed"], m.Alerts.Types());
        // A returned string counts as output too.
        await job.RunAsync((j, ct) => Task.FromResult("wrote 3 files"));
        Assert.Equal(["failed", "recovered"], m.Alerts.Types());
    }

    [Fact]
    public async Task Run_defines_on_first_use_and_validates_names_and_schedules()
    {
        await using var m = Make();
        m.Cw.Job("adhoc", new JobOptions { Schedule = "every 5m" });
        int one = await m.Cw.RunAsync("adhoc", (j, ct) => Task.FromResult(1));
        Assert.Equal(1, one);
        await m.Cw.RunAsync("undeclared", (j, ct) => Task.CompletedTask);
        Assert.Equal(2, (await m.Cw.JobsAsync()).Count);
        Assert.Contains("job name", Assert.Throws<CronwatchException>(() => m.Cw.Job("bad name!")).Message, StringComparison.Ordinal);
        var cron = Assert.Throws<CronwatchException>(() => m.Cw.Job("x", new JobOptions { Schedule = "nope" }));
        Assert.Contains("not a cron expression", cron.Message, StringComparison.Ordinal);
        Assert.Equal(CronwatchErrorKind.Invalid, cron.Kind);
        Assert.Contains("grace", Assert.Throws<CronwatchException>(() => m.Cw.Job("x", new JobOptions { Grace = "soon" })).Message, StringComparison.Ordinal);
        Assert.Contains(
            "is not an IANA timezone",
            Assert.Throws<CronwatchException>(() => m.Cw.Job("x", new JobOptions { Schedule = "0 2 * * *", Timezone = "Mars/Olympus" })).Message,
            StringComparison.Ordinal);
        Assert.Equal(
            "job \"x\": failuresBeforeAlert must be a whole number, 1 or more (got 0)",
            Assert.Throws<CronwatchException>(() => m.Cw.Job("x", new JobOptions { FailuresBeforeAlert = 0 })).Message);
        Assert.Equal(
            "job \"x\": timeout must be longer than zero",
            Assert.Throws<CronwatchException>(() => m.Cw.Job("x", new JobOptions { Timeout = 0 })).Message);
        Assert.Equal(
            "defaults takes grace, timeout, timezone and failuresBeforeAlert, not schedule",
            Assert.Throws<CronwatchException>(() => Make(defaults: new JobOptions { Schedule = "@daily" })).Message);
    }

    [Fact]
    public async Task Options_keep_the_order_they_were_given_in()
    {
        await using var m = Make(defaults: new JobOptions { Grace = "5m" });
        var job = m.Cw.Job("ordered", new JobOptions
        {
            Timeout = TimeSpan.FromMinutes(30),
            Schedule = "0 2 * * *",
            Budget = { ["cost"] = 2, ["rows"] = 1.5 },
            Expect = "done",
            Tags = ["a"],
        });
        Assert.Equal(
            "{\"grace\":\"5m\",\"timeout\":1800000,\"schedule\":\"0 2 * * *\",\"budget\":{\"cost\":2,\"rows\":1.5},\"tags\":[\"a\"],\"name\":\"ordered\",\"expect\":\"contains \\\"done\\\"\"}",
            job.Definition.ToJson());
    }

    [Fact]
    public async Task An_http_answer_of_400_or_more_fails_the_run()
    {
        await using var m = Make();
        var job = m.Cw.Job("h");
        using var bad = new HttpResponseMessage(HttpStatusCode.ServiceUnavailable);
        Assert.Same(bad, await job.RunAsync((j, ct) => Task.FromResult(bad)));
        Assert.Equal("HTTP 503 Service Unavailable", (await m.Cw.RunsAsync("h", 1))[0].Error);
        Assert.Equal(["failed"], m.Alerts.Types());
        using var fine = new HttpResponseMessage(HttpStatusCode.NoContent);
        await job.RunAsync((j, ct) => Task.FromResult(fine));
        Assert.Equal(RunStatus.Ok, (await m.Cw.RunsAsync("h", 1))[0].Status);
    }

    [Fact]
    public async Task Check_finds_a_missed_run_once_and_a_later_run_recovers()
    {
        await using var m = Make();
        var job = m.Cw.Job("sync", new JobOptions { Schedule = "every 1h", Grace = "10m" });
        await m.Cw.CheckAsync(); // registers at T0
        m.Clock.Advance(30 * Min);
        Assert.Empty((await m.Cw.CheckAsync()).Alerts);
        m.Clock.Set(T0 + 70 * Min + 1);
        CheckResult r = await m.Cw.CheckAsync();
        Assert.Equal(T0 + 70 * Min + 1, r.CheckedAt);
        Assert.Equal([AlertType.Missed], r.Alerts.Select(a => a.Type));
        Assert.Equal(JobHealth.Late, r.Jobs[0].Health);
        Assert.Empty((await m.Cw.CheckAsync()).Alerts);
        await job.RunAsync((j, ct) => Task.CompletedTask);
        Assert.Equal(["missed", "recovered"], m.Alerts.Types());
        Assert.Equal(JobHealth.Healthy, (await m.Cw.JobSummaryAsync("sync"))!.Health);
    }

    [Fact]
    public async Task A_job_declared_again_without_its_schedule_closes_missed_with_a_recovery_once()
    {
        await using var m = Make();
        m.Cw.Job("sync", new JobOptions { Schedule = "every 1h", Grace = "10m" });
        await m.Cw.CheckAsync();
        m.Clock.Set(T0 + 70 * Min + 1);
        Assert.Single((await m.Cw.CheckAsync()).Alerts);
        var job = m.Cw.Job("sync");
        m.Clock.Advance(Min);
        CheckResult r = await m.Cw.CheckAsync();
        Alert alert = Assert.Single(r.Alerts);
        Assert.Equal(AlertType.Recovered, alert.Type);
        Assert.Equal("sync is no longer scheduled", alert.Title);
        Assert.Equal(
            "Missed since 2026-01-05 10:40:00 UTC (1m ago). It has no schedule now, so nothing is due; the missed alert is closed.",
            alert.Message);
        Assert.Equal(
            "{\"after\":[\"missed\"],\"reason\":\"unscheduled\",\"since\":" + (T0 + 70 * Min + 1) + "}",
            alert.Details.ToValue().ToJson());
        Assert.Equal(JobHealth.NeverRan, r.Jobs[0].Health);
        Assert.Empty((await m.Cw.CheckAsync()).Alerts);
        await job.RunAsync((j, ct) => Task.CompletedTask);
        Assert.Equal(["missed", "recovered"], m.Alerts.Types());
    }

    [Fact]
    public async Task A_schedule_removed_while_silenced_closes_missed_quietly()
    {
        await using var m = Make();
        m.Cw.Job("sync", new JobOptions { Schedule = "every 1h", Grace = "10m" });
        await m.Cw.CheckAsync();
        m.Clock.Set(T0 + 70 * Min + 1);
        await m.Cw.CheckAsync();
        await m.Cw.SilenceAsync("sync", "1h");
        m.Cw.Job("sync");
        m.Clock.Advance(Min);
        Assert.Empty((await m.Cw.CheckAsync()).Alerts);
        Assert.Empty((await m.Cw.JobSummaryAsync("sync"))!.Open);
        m.Clock.Advance(2 * Hour);
        Assert.Empty((await m.Cw.CheckAsync()).Alerts);
        Assert.Equal(["missed"], m.Alerts.Types());
    }

    [Fact]
    public async Task Check_marks_a_run_that_never_finished_as_stuck()
    {
        await using var m = Make();
        var job = m.Cw.Job("long", new JobOptions { Timeout = "5m" });
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        Task running = Quietly(() => job.RunAsync((j, ct) => release.Task));
        await Eventually("the run to start", async () => (await m.Cw.RunsAsync("long", 1)).Count == 1);
        Assert.Equal(RunStatus.Running, (await m.Cw.RunsAsync("long", 1))[0].Status);
        m.Clock.Advance(4 * Min);
        Assert.Empty((await m.Cw.CheckAsync()).Alerts);
        m.Clock.Advance(2 * Min);
        CheckResult r = await m.Cw.CheckAsync();
        Assert.Equal([AlertType.Stuck], r.Alerts.Select(a => a.Type));
        Assert.Equal(RunStatus.Timeout, (await m.Cw.RunsAsync("long", 1))[0].Status);
        Assert.Equal(JobHealth.Stuck, r.Jobs[0].Health);
        Assert.Contains("never reported finishing", m.Alerts.List()[0].Message, StringComparison.Ordinal);
        release.SetResult();
        await running;
    }

    [Fact]
    public async Task The_runs_token_is_cancelled_at_the_jobs_timeout_and_the_throw_is_a_failed_run()
    {
        await using var m = Make();
        var job = m.Cw.Job("honours", new JobOptions { Timeout = "5m" });
        Task running = job.RunAsync((j, ct) => Task.Delay(System.Threading.Timeout.Infinite, ct));
        await Eventually("the run to start", async () => (await m.Cw.RunsAsync("honours", 1)).Count == 1);
        m.Clock.Advance(5 * Min);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => running);
        Run run = (await m.Cw.RunsAsync("honours", 1))[0];
        Assert.Equal(RunStatus.Failed, run.Status);
        Assert.StartsWith("TaskCanceledException: A task was canceled.", run.Error, StringComparison.Ordinal);
        Assert.Equal(["failed"], m.Alerts.Types());
    }

    [Fact]
    public async Task Slow_and_over_budget_alerts_come_from_the_jobs_own_baseline()
    {
        await using var m = Make();
        var job = m.Cw.Job("agent", new JobOptions { Budget = { ["cost"] = 1 } });
        Task Body(long ms, double tokens, double cost) => job.RunAsync((j, ct) =>
        {
            m.Clock.Advance(ms);
            j.Metric("tokens", tokens);
            j.Metric("cost", cost);
            return Task.CompletedTask;
        });
        for (int i = 0; i < 5; i++)
        {
            await Body(1000, 1000, 0.5);
            m.Clock.Advance(Hour);
        }
        Assert.Empty(m.Alerts.Types());
        await Body(15_000, 1000, 0.5);
        Assert.Equal(["slow"], m.Alerts.Types());
        m.Clock.Advance(Hour);
        await Body(1000, 5000, 1.2);
        Assert.Equal(["slow", "over_budget"], m.Alerts.Types());
        string message = m.Alerts.List()[1].Message;
        Assert.Contains("cost: 1.2, limit 1 (budget)", message, StringComparison.Ordinal);
        Assert.Contains("tokens: 5,000, limit 3,000 (three times the usual 1,000)", message, StringComparison.Ordinal);
        m.Clock.Advance(Hour);
        await Body(1000, 1000, 0.5);
        Assert.Equal(["slow", "over_budget", "recovered"], m.Alerts.Types());
    }

    [Fact]
    public async Task Silence_swallows_alerts_and_nothing_opens_underneath()
    {
        await using var m = Make();
        var job = m.Cw.Job("flaky");
        await m.Cw.SilenceAsync("flaky", "1h");
        await Assert.ThrowsAsync<InvalidOperationException>(() => job.RunAsync((j, ct) => throw new InvalidOperationException("x")));
        Assert.Empty(m.Alerts.Types());
        Assert.Equal(JobHealth.Silenced, (await m.Cw.JobSummaryAsync("flaky"))!.Health);
        await m.Cw.UnsilenceAsync("flaky");
        await Assert.ThrowsAsync<InvalidOperationException>(() => job.RunAsync((j, ct) => throw new InvalidOperationException("y")));
        Assert.Equal(["failed"], m.Alerts.Types());
        var bad = await Assert.ThrowsAsync<CronwatchException>(() => m.Cw.SilenceAsync("flaky", "soon"));
        Assert.Equal(CronwatchErrorKind.Invalid, bad.Kind);
        Assert.Contains("silence duration", bad.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Triage_is_attached_to_failure_alerts_and_never_blocks_them()
    {
        await using var m = Make(triage: new FuncTriage(ctx => Task.FromResult<string?>("Probably " + ctx.Alert.Job + "'s database.")));
        await Assert.ThrowsAsync<InvalidOperationException>(() => m.Cw.RunAsync("t", (j, ct) => throw new InvalidOperationException("x")));
        Assert.Equal("Probably t's database.", m.Alerts.List()[0].Triage);

        await using var m2 = Make(triage: new FuncTriage(ctx => throw new InvalidOperationException("api down")));
        await Assert.ThrowsAsync<InvalidOperationException>(() => m2.Cw.RunAsync("t", (j, ct) => throw new InvalidOperationException("x")));
        Assert.Equal(["failed"], m2.Alerts.Types());
        Alert alert = m2.Alerts.List()[0];
        Assert.Null(alert.Triage);
        Assert.True(alert.TriageTried);
        Assert.Equal(["triage for t"], m2.Errors.Wheres());
    }

    [Fact]
    public async Task Forget_removes_the_job_and_its_runs()
    {
        await using var m = Make();
        await m.Cw.RunAsync("gone", (j, ct) => Task.CompletedTask);
        Assert.Single(await m.Cw.JobsAsync());
        await m.Cw.ForgetAsync("gone");
        Assert.Empty(await m.Cw.JobsAsync());
        Assert.Null(await m.Cw.JobSummaryAsync("gone"));
    }

    [Fact]
    public async Task A_failing_alert_channel_does_not_break_the_run()
    {
        var broken = Channel.Create("broken", (a, ctx, ct) => throw new InvalidOperationException("no network"));
        await using var m = Make(channels: [broken]);
        await Assert.ThrowsAsync<InvalidOperationException>(() => m.Cw.RunAsync("x", (j, ct) => throw new InvalidOperationException("job")));
        Assert.Equal(["alert channel broken"], m.Errors.Wheres());
        Assert.Equal(["failed"], m.Alerts.Types());
    }

    [Fact]
    public async Task An_alert_no_channel_accepted_is_queued_and_retried_at_the_next_check()
    {
        var failing = true;
        var flaky = Channel.Create("flaky", (a, ctx, ct) => failing ? throw new InvalidOperationException("down") : Task.CompletedTask);
        var clock = Clock();
        var options = new CronwatchOptions
        {
            Clock = clock,
            Alerts = [flaky],
            CronSecret = CronSecret.None,
            OnError = (e, w) => { },
            ProcessExitHook = false,
        };
        await using var cw = new CronwatchClient(options);
        await Assert.ThrowsAsync<InvalidOperationException>(() => cw.RunAsync("q", (j, ct) => throw new InvalidOperationException("x")));
        var state = await cw.Store.GetStateAsync("q");
        Assert.Single(state!.Undelivered!);
        failing = false;
        var r = await cw.CheckAsync();
        Assert.Single(r.Alerts);
        Assert.Empty((await cw.Store.GetStateAsync("q"))!.Undelivered!);
    }
}
