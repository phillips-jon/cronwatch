using System;
using System.Collections.Concurrent;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using Xunit;
using static Cronwatch.Tests.Support;

namespace Cronwatch.Tests;

/// <summary>Runs seen from outside their function (<see cref="Job.OpenAsync"/>), the run scope, and the command line.</summary>
public class ObservedRunTests
{
    [Fact]
    public async Task An_observed_run_is_opened_and_closed_as_a_run_is()
    {
        await using var m = Make();
        Job job = m.Cw.Job("nightly", new JobOptions { Schedule = "0 2 * * *" });
        ObservedRun run = await job.OpenAsync(new RunOptions { Trigger = "hangfire", Id = "hangfire:app:1:0" });
        Assert.True(run.IsOpen);
        Assert.Equal("hangfire:app:1:0", run.Id);
        Assert.Equal("nightly", run.Job);
        Run stored = (await m.Cw.GetRunAsync("hangfire:app:1:0"))!;
        Assert.Equal(RunStatus.Running, stored.Status);
        Assert.Equal("hangfire", stored.Trigger);
        run.Context.Log("half way");
        m.Clock.Advance(2000);
        Run closed = await run.CloseWithAsync("done");
        Assert.False(run.IsOpen);
        Assert.Equal(RunStatus.Ok, closed.Status);
        stored = (await m.Cw.GetRunAsync("hangfire:app:1:0"))!;
        Assert.Equal(RunStatus.Ok, stored.Status);
        Assert.Equal("half way", stored.Output);
        Assert.Equal(2000L, stored.DurationMs);
        // Later calls do nothing.
        Assert.Equal(RunStatus.Ok, (await run.CloseAsync(new InvalidOperationException("late"))).Status);
        Assert.Equal(RunStatus.Ok, (await m.Cw.GetRunAsync("hangfire:app:1:0"))!.Status);
    }

    [Fact]
    public async Task A_failure_closes_it_failed_and_alerts()
    {
        await using var m = Make();
        Job job = m.Cw.Job("nightly");
        ObservedRun run = await job.OpenAsync();
        Run closed = await run.CloseAsync(new InvalidOperationException("db down"));
        Assert.Equal(RunStatus.Failed, closed.Status);
        Assert.StartsWith("InvalidOperationException: db down", closed.Error, StringComparison.Ordinal);
        Assert.Equal(["failed"], m.Alerts.Types());
    }

    [Fact]
    public async Task A_run_given_back_leaves_no_row_and_no_judgement()
    {
        await using var m = Make();
        Job job = m.Cw.Job("nightly");
        ObservedRun run = await job.OpenAsync(new RunOptions { MayTakeBack = true });
        Assert.True(await run.TakeBackAsync());
        Assert.False(run.IsOpen);
        Assert.Null(await m.Cw.GetRunAsync(run.Id));
        Assert.Empty(m.Alerts.Types());
        Assert.False(await run.TakeBackAsync() && run.IsOpen);
    }

    [Fact]
    public async Task Discard_when_takes_an_observed_run_back()
    {
        await using var m = Make();
        Job job = m.Cw.Job("nightly");
        ObservedRun run = await job.OpenAsync(new RunOptions { DiscardWhen = e => e is OperationCanceledException });
        await run.CloseAsync(new OperationCanceledException("shutdown"));
        Assert.Null(await m.Cw.GetRunAsync(run.Id));
        Assert.Empty(m.Alerts.Types());
    }

    [Fact]
    public async Task Make_current_sets_the_run_in_the_calling_flow_until_disposed()
    {
        await using var m = Make();
        Job job = m.Cw.Job("nightly");
        ObservedRun run = await job.OpenAsync();
        Assert.Null(CronwatchClient.Current);
        JobContext? seenInTask;
        // A synchronous callback, as Hangfire's filter is: what it sets reaches the code after it.
        IDisposable current = run.MakeCurrent();
        try
        {
            Assert.Same(run.Context, CronwatchClient.Current);
            seenInTask = await Task.Run(() => CronwatchClient.Current);
            CronwatchClient.Current!.Log("from the job");
        }
        finally
        {
            current.Dispose();
        }
        Assert.Same(run.Context, seenInTask);
        Assert.Null(CronwatchClient.Current);
        current.Dispose();
        Assert.Null(CronwatchClient.Current);
        await run.CloseAsync(null);
        Assert.Equal("from the job", (await m.Cw.GetRunAsync(run.Id))!.Output);
    }

    [Fact]
    public async Task The_run_scope_wraps_a_runs_function_and_a_current_observed_run()
    {
        var opened = new ConcurrentQueue<string>();
        var errors = new Errors();
        await using var cw = new CronwatchClient(new CronwatchOptions
        {
            Clock = Clock(),
            Alerts = [],
            ProcessExitHook = false,
            OnError = errors.Handle,
            OnWarning = _ => { },
            RunScope = ctx =>
            {
                opened.Enqueue("open " + ctx.Name);
                return new Scope(() => opened.Enqueue("close " + ctx.Name));
            },
        });
        await cw.Job("a").RunAsync((ctx, ct) =>
        {
            opened.Enqueue("in a");
            return Task.CompletedTask;
        });
        ObservedRun run = await cw.Job("b").OpenAsync();
        using (run.MakeCurrent())
        {
            opened.Enqueue("in b");
        }
        await run.CloseAsync(null);
        Assert.Equal(["open a", "in a", "close a", "open b", "in b", "close b"], opened.ToList());

        // A scope that throws is reported, and the run goes on without it.
        await using var broken = new CronwatchClient(new CronwatchOptions
        {
            Clock = Clock(),
            Alerts = [],
            ProcessExitHook = false,
            OnError = errors.Handle,
            OnWarning = _ => { },
            RunScope = _ => throw new InvalidOperationException("no scope"),
        });
        await broken.Job("c").RunAsync((ctx, ct) => Task.CompletedTask);
        Assert.Equal(RunStatus.Ok, (await broken.RunsAsync("c", 1))[0].Status);
        Assert.Equal(["run scope for c"], errors.Wheres());
    }

    private sealed class Scope(Action close) : IDisposable
    {
        public void Dispose() => close();
    }

    [Fact]
    public async Task Open_refuses_a_run_id_the_client_refuses()
    {
        await using var m = Make();
        Job job = m.Cw.Job("nightly");
        await Assert.ThrowsAsync<CronwatchException>(() => job.OpenAsync(new RunOptions { Id = "a\0b" }));
        await Assert.ThrowsAsync<CronwatchException>(() => job.OpenAsync(new RunOptions { Id = "pgcron:1" }));
    }

    [Fact]
    public async Task The_command_line_checks_and_answers_its_status()
    {
        var store = new MemoryStore();
        CronwatchClient Factory()
        {
            var cw = new CronwatchClient(new CronwatchOptions { Store = store, Clock = Clock(), Alerts = [], ProcessExitHook = false, OnWarning = _ => { } });
            cw.Job("nightly", new JobOptions { Schedule = "0 2 * * *" });
            return cw;
        }
        await using (var cw = Factory())
        {
            await cw.Job("nightly").RunAsync((ctx, ct) => Task.CompletedTask);
        }
        var output = new StringWriter();
        var error = new StringWriter();
        Assert.Equal(0, await CronwatchCli.RunAsync(Factory, ["check"], output, error));
        Assert.Equal("cronwatch: checked 1 job, sent 0 alerts\n", output.ToString());

        output = new StringWriter();
        Assert.Equal(0, await CronwatchCli.RunAsync(Factory, ["--help"], output, error));
        Assert.StartsWith("usage: cronwatch check\n", output.ToString(), StringComparison.Ordinal);
        Assert.Equal("", error.ToString());

        Assert.Equal(2, await CronwatchCli.RunAsync(Factory, [], output, error));
        Assert.StartsWith("cronwatch: no command given\nusage:", error.ToString(), StringComparison.Ordinal);
        error = new StringWriter();
        Assert.Equal(2, await CronwatchCli.RunAsync(Factory, ["chek", "now"], output, error));
        Assert.StartsWith("cronwatch: unknown command chek now\n", error.ToString(), StringComparison.Ordinal);

        error = new StringWriter();
        Assert.Equal(1, await CronwatchCli.RunAsync(() => throw new InvalidOperationException("no database"), ["check"], output, error));
        Assert.Equal("cronwatch: the client could not be made: no database\n", error.ToString());

        var broken = new Wrapped();
        broken.Break("listJobs", "runningRuns");
        error = new StringWriter();
        Assert.Equal(1, await CronwatchCli.RunAsync(() => new CronwatchClient(new CronwatchOptions { Store = broken, Clock = Clock(), Alerts = [], ProcessExitHook = false, OnError = (_, _) => { } }), ["check"], output, error));
        Assert.StartsWith("cronwatch: the check failed: ", error.ToString(), StringComparison.Ordinal);
    }
}
