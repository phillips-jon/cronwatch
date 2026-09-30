using System;
using System.Collections.Concurrent;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch.Internal;
using Xunit;
using static Cronwatch.Tests.Support;

namespace Cronwatch.Tests;

/// <summary>
/// The SDK's <c>correctness.test.ts</c>, ported: state an alert in flight cannot overwrite,
/// pruning, expect, runs a check marks stuck, the interval stopped before its first check, fire
/// times around the autumn clock change, and an error named once.
/// </summary>
public class CorrectnessTests
{
    private static Task Ok(Job job) => job.RunAsync((j, ct) => Task.CompletedTask);

    [Fact]
    public async Task An_alert_still_being_sent_cannot_overwrite_what_a_run_did_meanwhile()
    {
        var sent = new ConcurrentQueue<string>();
        var inFlight = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var slowForMissed = Channel.Create("slow-for-missed", async (a, ctx, ct) =>
        {
            if (a.Type == AlertType.Missed)
            {
                inFlight.TrySetResult();
                await release.Task;
            }
            sent.Enqueue(a.Type.Value);
        });
        await using var m = Make(channels: [slowForMissed]);
        var job = m.Cw.Job("sync", new JobOptions { Schedule = "every 5m", Grace = "1m" });
        await Ok(job);
        m.Clock.Advance(7 * Min);
        var checking = m.Cw.CheckAsync();
        await inFlight.Task;
        await Ok(job); // the job turns up while the missed alert is in flight
        release.SetResult();
        await checking;
        Assert.Equal(["recovered", "missed"], sent.ToList());
        Assert.Empty((await m.Store.GetStateAsync("sync"))!.Open);
        m.Clock.Advance(Min);
        await Ok(job);
        Assert.Equal(["recovered", "missed"], sent.ToList());
    }

    [Fact]
    public async Task Pruning_keeps_each_jobs_newest_run_so_a_monthly_job_is_not_reported_missed()
    {
        await using var m = Make(clock: Clock(Js.DateUtc(2026, 0, 1, 0, 0, 0, 0)), retention: "30d");
        var monthly = m.Cw.Job("monthly", new JobOptions { Schedule = "0 0 1 * *", Timezone = "UTC" });
        await Ok(monthly);
        m.Clock.Set(Js.DateUtc(2026, 0, 31, 12, 0, 0, 0));
        Assert.Equal(0, (await m.Cw.CheckAsync()).Pruned);
        m.Clock.Advance(2 * 60 * Min);
        await m.Cw.CheckAsync();
        Assert.Empty(m.Alerts.Types());
        Assert.Equal(JobHealth.Healthy, (await m.Cw.JobSummaryAsync("monthly"))!.Health);
    }

    [Fact]
    public async Task An_expect_pattern_with_the_g_flag_gives_the_same_answer_every_run()
    {
        await using var m = Make();
        var job = m.Cw.Job("g", new JobOptions { Expect = Expect.Matches("done", "g") });
        for (int i = 0; i < 4; i++)
        {
            await job.RunAsync((j, ct) =>
            {
                j.Log("done");
                return Task.CompletedTask;
            });
        }
        Assert.All(await m.Cw.RunsAsync("g", 50), r => Assert.Equal(RunStatus.Ok, r.Status));
    }

    [Fact]
    public async Task Expect_sees_a_line_logged_early_even_after_the_stored_output_has_dropped_it()
    {
        await using var m = Make();
        await m.Cw.Job("report", new JobOptions { Expect = "Report written" }).RunAsync((j, ct) =>
        {
            j.Log("Report written: /tmp/r.pdf");
            for (int i = 0; i < 3000; i++)
            {
                j.Log("row " + i + " " + new string('x', 40));
            }
            return Task.CompletedTask;
        });
        var run = (await m.Cw.RunsAsync("report", 1))[0];
        Assert.Equal(RunStatus.Ok, run.Status);
        Assert.DoesNotContain("Report written", run.Output, StringComparison.Ordinal);
    }

    [Fact]
    public async Task An_interval_job_whose_run_is_still_going_is_busy_not_missed()
    {
        await using var m = Make();
        var job = m.Cw.Job("long", new JobOptions { Schedule = "every 5m", Grace = "2m" });
        var finish = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var running = job.RunAsync((j, ct) => finish.Task);
        await Eventually("the run to start", async () => (await m.Cw.RunsAsync("long", 1)).Count == 1);
        m.Clock.Advance(8 * Min);
        await m.Cw.CheckAsync();
        Assert.Empty(m.Alerts.Types());
        finish.SetResult();
        await running;
        Assert.Empty(m.Alerts.Types());
    }

    [Fact]
    public async Task A_run_a_check_marked_stuck_that_then_fails_counts_once()
    {
        await using var m = Make();
        var job = m.Cw.Job("slowpoke", new JobOptions { Timeout = "1m", FailuresBeforeAlert = 2 });
        var fail = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var running = Quietly(() => job.RunAsync(async (j, ct) =>
        {
            await fail.Task;
            throw new InvalidOperationException("gave up");
        }));
        await Eventually("the run to start", async () => (await m.Cw.RunsAsync("slowpoke", 1)).Count == 1);
        m.Clock.Advance(2 * Min);
        await m.Cw.CheckAsync();
        Assert.Equal(1, (await m.Store.GetStateAsync("slowpoke"))!.ConsecutiveFailures);
        fail.SetResult();
        await running;
        Assert.Equal(1, (await m.Store.GetStateAsync("slowpoke"))!.ConsecutiveFailures);
        Assert.Empty(m.Alerts.Types());
        Assert.Equal("InvalidOperationException: gave up", FirstLine((await m.Cw.RunsAsync("slowpoke", 1))[0].Error!));
    }

    [Fact]
    public async Task A_late_success_after_a_stuck_mark_closes_stuck_and_recovers()
    {
        await using var m = Make();
        var job = m.Cw.Job("late", new JobOptions { Timeout = "30s" });
        var finish = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        // The function ignores its token, as a JavaScript function may ignore its signal.
        var running = job.RunAsync((j, ct) => finish.Task);
        await Eventually("the run to start", async () => (await m.Cw.RunsAsync("late", 1)).Count == 1);
        m.Clock.Advance(Min);
        var fromCheck = (await m.Cw.CheckAsync()).Alerts;
        Assert.StartsWith("Still running after 30s;", fromCheck[0].Run!.Error, StringComparison.Ordinal);
        finish.SetResult();
        await running;
        Assert.Equal(["stuck", "recovered"], m.Alerts.Types());
    }

    [Fact]
    public void Fire_times_around_the_autumn_clock_change_are_never_in_the_past()
    {
        (string Zone, long Day)[] zones =
        [
            ("Europe/London", Js.DateUtc(2026, 9, 24, 22, 0, 0, 0)),
            ("America/New_York", Js.DateUtc(2026, 10, 1, 3, 0, 0, 0)),
        ];
        foreach (var (tz, day) in zones)
        {
            foreach (string expr in new[] { "*/15 * * * *", "30 1 * * *", "0 * * * *" })
            {
                var p = Schedules.Parse(expr, tz, TimeZoneInfo.Utc);
                for (long t = day; t < day + 8 * 3_600_000L; t += 5 * Min)
                {
                    long? next = Schedules.NextFire(p, t, null);
                    Assert.True(next != null && next > t, tz + " " + expr + " after " + Js.IsoString(t));
                }
            }
        }
    }

    [Fact]
    public void A_failed_alert_names_the_error_once()
    {
        string[][] cases =
        [
            ["IOException: connect ECONNREFUSED 10.0.0.12:5432", "IOException: connect ECONNREFUSED"],
            ["TypeError: x is undefined", "TypeError: x is undefined"],
            ["Output did not contain \"wrote\"", "Error: Output did not contain \"wrote\""],
            ["HTTP 503 Service Unavailable", "Error: HTTP 503"],
        ];
        foreach (var c in cases)
        {
            var run = new Run { Id = "r", Job = "j", Status = RunStatus.Failed, StartedAt = T0, FinishedAt = T0, DurationMs = 5, Error = c[0], Trigger = "run" };
            string message = AlertFormat.ComposeAlert(
                new AlertDraft(AlertType.Failed, run, new AlertDetails.Failure(1, 1)),
                Definition.Of(new JsObject().Set("name", "j")),
                T0).Message;
            Assert.Contains(message.Split('\n'), l => l.StartsWith(c[1], StringComparison.Ordinal));
            Assert.DoesNotContain("Error: Error:", message, StringComparison.Ordinal);
            Assert.DoesNotContain("Error: IOException", message, StringComparison.Ordinal);
        }
    }

    [Fact]
    public async Task An_expect_pattern_the_engine_cannot_read_is_refused_when_declared()
    {
        await using var m = Make();
        var e = Assert.Throws<CronwatchException>(() => m.Cw.Job("p", new JobOptions { Expect = Expect.Matches("(?<=a)+", "") }));
        Assert.Equal(CronwatchErrorKind.Invalid, e.Kind);
    }

    [Fact]
    public async Task Stop_cancels_the_first_check_start_scheduled()
    {
        var counter = new CountingSource();
        await using var m = Make(sources: [counter]);
        m.Cw.Start();
        m.Cw.Stop();
        m.Clock.Advance(5_000);
        await Task.Delay(50);
        Assert.Equal(0, counter.Syncs);
    }
}

/// <summary>A source that counts the checks that sync it, and can hold them.</summary>
internal sealed class CountingSource : ISource
{
    private int _syncs;

    public int Syncs => Volatile.Read(ref _syncs);

    /// <summary>Completed when a sync is entered.</summary>
    public TaskCompletionSource Entered { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);

    /// <summary>When set, each sync waits for it.</summary>
    public Task? Hold { get; set; }

    public string Name => "counting";

    public async Task<System.Collections.Generic.IReadOnlyList<Alert>?> SyncAsync(CronwatchClient client, CancellationToken cancellationToken)
    {
        Interlocked.Increment(ref _syncs);
        Entered.TrySetResult();
        if (Hold is { } hold)
        {
            await hold;
        }
        return null;
    }
}
