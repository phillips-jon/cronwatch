using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Threading.Tasks;
using Xunit;
using static Cronwatch.Tests.Support;

namespace Cronwatch.Tests;

/// <summary>
/// The SDK's <c>start-finish.test.ts</c>, ported: runs that span calls, started, found again with
/// resume, flushed and finished, perhaps by another client on the same store.
/// </summary>
public class StartFinishTests
{
    [Fact]
    public async Task Start_records_a_running_run_and_finish_records_it_ok()
    {
        await using var m = Make();
        var job = m.Cw.Job("sync", new JobOptions { Schedule = "@hourly" });
        RunHandle run = await job.StartAsync(new StartOptions { Trigger = "queue" });
        Assert.Equal("sync", run.Job);
        Assert.True(run.IsActive);
        Run stored = (await m.Cw.GetRunAsync(run.Id))!;
        Assert.Equal(RunStatus.Running, stored.Status);
        Assert.Equal("queue", stored.Trigger);
        run.Log("imported 12 rows");
        run.Metric("rows", 12);
        m.Clock.Advance(90_000);
        Run finished = (await run.FinishAsync())!;
        Assert.Equal(RunStatus.Ok, finished.Status);
        Assert.Equal(90_000L, finished.DurationMs);
        Assert.False(run.IsActive);
        Run recorded = (await m.Cw.RunsAsync("sync", 50))[0];
        Assert.Equal(RunStatus.Ok, recorded.Status);
        Assert.Equal("imported 12 rows", recorded.Output);
        Assert.Equal("{\"rows\":12}", recorded.Metrics.ToJson());
        Assert.Empty(m.Alerts.Types());
        Assert.Equal(JobHealth.Healthy, (await m.Cw.JobSummaryAsync("sync"))!.Health);
    }

    [Fact]
    public async Task Fail_records_a_failure_and_alerts_once()
    {
        await using var m = Make();
        var job = m.Cw.Job("import", new JobOptions { FailuresBeforeAlert = 2 });
        await (await job.StartAsync()).FailAsync(new InvalidOperationException("api down"));
        Run run = (await (await job.StartAsync()).FailAsync(new InvalidOperationException("still down")))!;
        Assert.Equal(RunStatus.Failed, run.Status);
        Assert.StartsWith("InvalidOperationException: still down", run.Error, StringComparison.Ordinal);
        Assert.Equal(["failed"], m.Alerts.Types());
        await (await job.StartAsync(new StartOptions { Trigger = "retry" })).FinishAsync();
        Assert.Equal(["failed", "recovered"], m.Alerts.Types());
    }

    [Fact]
    public async Task A_second_finish_is_ignored_and_reported_not_thrown()
    {
        await using var m = Make();
        var job = m.Cw.Job("once");
        RunHandle run = await job.StartAsync();
        var a = Task.Run(() => run.FailAsync(new InvalidOperationException("boom")));
        var b = Task.Run(() => run.FinishAsync());
        Run? first = await a;
        Run? second = await b;
        // Whichever call came first records; the other is ignored.
        Assert.True((first == null) != (second == null), "exactly one recorded");
        Assert.Null(await run.FinishAsync());
        Assert.Single(await m.Cw.RunsAsync("once", 50));
        Assert.Equal(2, m.Errors.Entries.Count);
        Assert.Contains("was already finished by this handle; ignored", m.Errors.Messages()[0], StringComparison.Ordinal);
        Assert.Equal("finishing once", m.Errors.Wheres()[0]);
    }

    [Fact]
    public async Task A_second_finish_of_a_failure_is_ignored()
    {
        await using var m = Make();
        var job = m.Cw.Job("once");
        RunHandle run = await job.StartAsync();
        Run failed = (await run.FailAsync(new InvalidOperationException("boom")))!;
        Assert.Equal(RunStatus.Failed, failed.Status);
        Assert.Null(await run.FinishAsync());
        Assert.Equal(["failed"], m.Alerts.Types());
        Assert.Equal(RunStatus.Failed, (await m.Cw.RunsAsync("once", 1))[0].Status);
    }

    [Fact]
    public async Task Start_with_an_id_twice_records_one_run_and_returns_a_handle_on_it()
    {
        await using var m = Make();
        var job = m.Cw.Job("inngest-fn");
        var one = Task.Run(() => job.StartAsync(new StartOptions { Id = "01HX-run" }));
        var two = Task.Run(() => job.StartAsync(new StartOptions { Id = "01HX-run" }));
        Assert.Equal("01HX-run", (await one).Id);
        Assert.Equal("01HX-run", (await two).Id);
        RunHandle again = await job.StartAsync(new StartOptions { Id = "01HX-run", Trigger = "ignored" });
        Assert.True(again.IsActive);
        Assert.Single(await m.Cw.RunsAsync("inngest-fn", 50));
        Assert.Equal("start", (await m.Cw.GetRunAsync("01HX-run"))!.Trigger);
        await again.FinishAsync("done");
        // Finished elsewhere: this handle's finish is a reported no-op.
        Assert.Null(await (await one).FinishAsync());
        Assert.Contains("already finished as ok; ignored", m.Errors.Messages().Last(), StringComparison.Ordinal);
        RunHandle late = await job.StartAsync(new StartOptions { Id = "01HX-run" });
        Assert.False(late.IsActive);
        Assert.Null(await late.FinishAsync());
        Assert.Single(await m.Cw.RunsAsync("inngest-fn", 50));
        Assert.Contains(
            "belongs to job \"inngest-fn\"",
            (await Assert.ThrowsAsync<CronwatchException>(() => m.Cw.Job("other").StartAsync(new StartOptions { Id = "01HX-run" }))).Message,
            StringComparison.Ordinal);
        Assert.Contains(
            "run id of 1 to 200 characters",
            (await Assert.ThrowsAsync<CronwatchException>(() => job.StartAsync(new StartOptions { Id = "" }))).Message,
            StringComparison.Ordinal);
        Assert.Contains(
            "which the pg_cron source uses",
            (await Assert.ThrowsAsync<CronwatchException>(() => job.StartAsync(new StartOptions { Id = "pgcron:1" }))).Message,
            StringComparison.Ordinal);
        // No store could hold a NUL (Postgres refuses it), so such an id is refused wherever one is taken.
        Assert.Contains(
            "start() cannot take a run id containing a NUL character",
            (await Assert.ThrowsAsync<CronwatchException>(() => job.StartAsync(new StartOptions { Id = "01HX\0run" }))).Message,
            StringComparison.Ordinal);
        Assert.Contains(
            "resume() cannot take a run id containing a NUL character",
            (await Assert.ThrowsAsync<CronwatchException>(() => job.ResumeAsync("01HX\0run"))).Message,
            StringComparison.Ordinal);
        Assert.Contains(
            "run() cannot take a run id containing a NUL character",
            (await Assert.ThrowsAsync<CronwatchException>(() => job.RunAsync(new RunOptions { Id = "01HX\0run" }, (j, ct) => Task.CompletedTask))).Message,
            StringComparison.Ordinal);
        var nul = new Run { Id = "x\0y", Job = "inngest-fn", Status = RunStatus.Ok, StartedAt = 1, FinishedAt = 2, DurationMs = 1, Trigger = "run" };
        Assert.Contains(
            "recordRun: run ids cannot contain a NUL character",
            (await Assert.ThrowsAsync<CronwatchException>(() => m.Cw.RecordRunAsync(nul))).Message,
            StringComparison.Ordinal);
        Assert.Single(await m.Cw.RunsAsync("inngest-fn", 50));
    }

    // Two clients over one store, or over two stores on one SQLite file.
    private static async Task ResumeInASecondClient(IStore a, IStore b)
    {
        var clock = Clock();
        await using var first = Make(store: a, clock: clock);
        await using var second = Make(store: b, clock: clock);
        RunHandle started = await first.Cw
            .Job("digest", new JobOptions { Expect = "sent", Budget = { ["emails"] = 100 } })
            .StartAsync(new StartOptions { Id = "evt-1" });
        started.Log("loaded 40 recipients");
        started.Log("token=abc123");
        started.Metric("recipients", 40);
        await started.FlushAsync();
        Run midway = (await first.Cw.GetRunAsync("evt-1"))!;
        Assert.Equal(RunStatus.Running, midway.Status);
        Assert.Equal("loaded 40 recipients\ntoken=[redacted]", midway.Output);

        clock.Advance(5 * Min);
        second.Cw.Job("digest", new JobOptions { Expect = "sent", Budget = { ["emails"] = 100 } });
        RunHandle resumed = await second.Cw.ResumeRunAsync("digest", "evt-1");
        Assert.True(resumed.IsActive);
        Assert.Equal(midway.StartedAt, resumed.StartedAt);
        resumed.Log("sent 40 emails");
        resumed.Metric("emails", 40);
        Run run = (await resumed.FinishAsync())!;
        Assert.Equal(RunStatus.Ok, run.Status);
        Assert.Equal(5 * Min, run.DurationMs);
        Run stored = (await first.Cw.GetRunAsync("evt-1"))!;
        Assert.Equal(RunStatus.Ok, stored.Status);
        Assert.Equal("loaded 40 recipients\ntoken=[redacted]\nsent 40 emails", stored.Output);
        Assert.Equal(
            new Dictionary<string, double> { ["recipients"] = 40, ["emails"] = 40 }.OrderBy(e => e.Key, StringComparer.Ordinal),
            stored.Metrics.OrderBy(e => e.Key, StringComparer.Ordinal));
        Assert.Empty(first.Alerts.Types());
        Assert.Empty(second.Alerts.Types());
        Assert.Empty(first.Errors.Wheres());
        Assert.Empty(second.Errors.Wheres());
    }

    [Fact]
    public async Task Resume_in_a_second_client_on_the_same_memory_store()
    {
        var store = new MemoryStore();
        await ResumeInASecondClient(store, store);
    }

    [Fact]
    public async Task Resume_in_a_second_client_on_the_same_sqlite_file()
    {
        using var dir = new TempDir();
        string file = dir.File("cw.db");
        await ResumeInASecondClient(SqlStore.Sqlite(StoreTests.Sqlite(file)), SqlStore.Sqlite(StoreTests.Sqlite(file)));
    }

    [Fact]
    public async Task Resume_of_an_unknown_or_finished_run_returns_a_handle_whose_finish_is_a_reported_no_op()
    {
        await using var m = Make();
        var job = m.Cw.Job("webhook");
        RunHandle missing = await job.ResumeAsync("nope");
        Assert.False(missing.IsActive);
        Assert.Null(missing.StartedAt);
        missing.Log("dropped");
        await missing.FlushAsync();
        Assert.Null(await missing.FinishAsync());
        Assert.Contains("run nope of webhook was not found; ignored", m.Errors.Messages()[0], StringComparison.Ordinal);
        await job.RunAsync((j, ct) => Task.FromResult("done"));
        Run done = (await m.Cw.RunsAsync("webhook", 1))[0];
        RunHandle finished = await job.ResumeAsync(done.Id);
        Assert.False(finished.IsActive);
        Assert.Null(await finished.FailAsync(new InvalidOperationException("late")));
        Assert.Contains("already finished as ok; ignored", m.Errors.Messages()[1], StringComparison.Ordinal);
        Assert.Equal(RunStatus.Ok, (await m.Cw.RunsAsync("webhook", 1))[0].Status);
        Assert.Contains(
            "not declared",
            (await Assert.ThrowsAsync<CronwatchException>(() => m.Cw.ResumeRunAsync("undeclared", "x"))).Message,
            StringComparison.Ordinal);
    }

    [Fact]
    public async Task A_run_never_finished_is_marked_stuck_after_the_jobs_timeout()
    {
        await using var m = Make();
        var job = m.Cw.Job("callback", new JobOptions { Timeout = "30m" });
        RunHandle run = await job.StartAsync();
        m.Clock.Advance(29 * Min);
        await m.Cw.CheckAsync();
        Assert.Equal(RunStatus.Running, (await m.Cw.GetRunAsync(run.Id))!.Status);
        m.Clock.Advance(2 * Min);
        await m.Cw.CheckAsync();
        Run stored = (await m.Cw.GetRunAsync(run.Id))!;
        Assert.Equal(RunStatus.Timeout, stored.Status);
        Assert.StartsWith("Still running after 30m", stored.Error, StringComparison.Ordinal);
        Assert.Equal(["stuck"], m.Alerts.Types());
    }

    [Fact]
    public async Task A_late_success_after_a_timeout_mark_recovers_and_a_late_failure_does_not_count_twice()
    {
        await using var m = Make();
        var job = m.Cw.Job("slowpoke", new JobOptions { Timeout = "10m", FailuresBeforeAlert = 2 });
        RunHandle first = await job.StartAsync();
        m.Clock.Advance(11 * Min);
        await m.Cw.CheckAsync();
        Assert.Empty(m.Alerts.Types());
        Run failed = (await first.FailAsync(new InvalidOperationException("gave up")))!;
        Assert.Equal(RunStatus.Failed, failed.Status);
        Assert.Equal("InvalidOperationException: gave up", FirstLine((await m.Cw.GetRunAsync(first.Id))!.Error!));
        Assert.Empty(m.Alerts.Types());

        RunHandle second = await job.StartAsync();
        m.Clock.Advance(11 * Min);
        await m.Cw.CheckAsync();
        Assert.Equal(["stuck"], m.Alerts.Types());
        RunHandle resumed = await m.Cw.ResumeRunAsync("slowpoke", second.Id);
        Assert.True(resumed.IsActive, "a run marked timeout can still be finished late");
        Run late = (await resumed.FinishAsync())!;
        Assert.Equal(RunStatus.Ok, late.Status);
        Assert.Equal(["stuck", "recovered"], m.Alerts.Types());
        Assert.Null(await second.FinishAsync());
    }

    [Fact]
    public async Task Expect_is_applied_at_finish_to_the_logged_lines_or_the_string_passed()
    {
        await using var m = Make();
        var job = m.Cw.Job("export", new JobOptions { Expect = Expect.Matches("wrote \\d+ files") });
        RunHandle quiet = await job.StartAsync();
        Run run = (await quiet.FinishAsync("nothing to do"))!;
        Assert.Equal(RunStatus.Failed, run.Status);
        Assert.Equal("nothing to do", run.Output);
        Assert.Contains("did not match", run.Error, StringComparison.Ordinal);
        Assert.Equal(["failed"], m.Alerts.Types());

        RunHandle busy = await job.StartAsync();
        busy.Log("wrote 3 files");
        await busy.FlushAsync();
        RunHandle resumed = await job.ResumeAsync(busy.Id);
        Assert.Equal(RunStatus.Ok, (await resumed.FinishAsync("uploaded"))!.Status);
        Assert.Equal(["failed", "recovered"], m.Alerts.Types());

        using var answer = new HttpResponseMessage(HttpStatusCode.BadGateway);
        Run bad = (await (await job.StartAsync()).FinishAsync(answer))!;
        Assert.Equal("HTTP 502 Bad Gateway", bad.Error);
    }

    [Fact]
    public async Task A_store_failing_during_start_does_not_throw_and_finish_records_once_the_store_is_back()
    {
        var store = new Wrapped();
        store.Break("insertRun");
        await using var m = Make(store: store);
        var job = m.Cw.Job("backup", new JobOptions { Schedule = "@hourly" });
        RunHandle run = await job.StartAsync();
        Assert.True(run.IsActive);
        Assert.Equal("recording backup", m.Errors.Wheres()[0]);
        Assert.Null(await m.Cw.GetRunAsync(run.Id));
        run.Log("copied");
        await run.FlushAsync(); // nothing stored to append to; kept for the finish
        store.Mend("insertRun");
        m.Clock.Advance(Hour / 2);
        Run finished = (await run.FinishAsync())!;
        Assert.Equal(RunStatus.Ok, finished.Status);
        Run stored = (await m.Cw.GetRunAsync(run.Id))!;
        Assert.Equal(RunStatus.Ok, stored.Status);
        Assert.Equal("copied", stored.Output);
        Assert.Equal(Hour / 2, stored.DurationMs);
        Assert.Empty(m.Alerts.Types());
    }

    [Fact]
    public async Task A_store_failing_at_finish_is_reported_and_the_handle_can_finish_again()
    {
        var store = new Wrapped();
        await using var m = Make(store: store);
        var job = m.Cw.Job("flaky");
        RunHandle run = await job.StartAsync();
        run.Log("working");
        store.Break("getRun", "updateRun", "updateRunIf");
        await run.FlushAsync();
        Assert.Equal("flushing flaky", m.Errors.Wheres().Last());
        Assert.Null(await run.FinishAsync());
        Assert.Contains("finishing flaky", m.Errors.Wheres());
        Assert.True(run.IsActive, "still active, to finish again");
        // The read works but the write fails: still retryable.
        store.Mend("getRun");
        Assert.Null(await run.FinishAsync());
        Assert.True(run.IsActive);
        store.Mend("updateRun", "updateRunIf");
        Assert.Equal(RunStatus.Running, (await m.Cw.GetRunAsync(run.Id))!.Status);
        Run finished = (await run.FinishAsync())!;
        Assert.Equal(RunStatus.Ok, finished.Status);
        Assert.Equal("working", finished.Output);
        Assert.False(run.IsActive);
        Assert.Null(await run.FinishAsync());
    }
}
