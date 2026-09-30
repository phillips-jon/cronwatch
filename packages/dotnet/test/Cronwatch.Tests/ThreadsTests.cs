using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using Xunit;
using static Cronwatch.Tests.Support;

namespace Cronwatch.Tests;

/// <summary>
/// .NET's own cases for runs and checks: tokens, the current run across tasks and threads, the
/// shared check, the app's hooks that throw, and a process that ends with a run open.
/// </summary>
public class ThreadsTests
{
    [Fact]
    public async Task The_jobs_timeout_cancels_the_runs_token_and_a_function_honouring_it_fails()
    {
        await using var m = Make();
        var job = m.Cw.Job("runaway", new JobOptions { Timeout = "1m" });
        var running = job.RunAsync((j, ct) => Task.Delay(Timeout.Infinite, ct));
        await Eventually("the run to start", async () => (await m.Cw.RunsAsync("runaway", 1)).Count == 1);
        m.Clock.Advance(Min);
        var e = await Assert.ThrowsAsync<TaskCanceledException>(() => running);
        Assert.Equal("A task was canceled.", e.Message);
        var run = (await m.Cw.RunsAsync("runaway", 1))[0];
        Assert.Equal(RunStatus.Failed, run.Status);
        Assert.Equal("TaskCanceledException: A task was canceled.", FirstLine(run.Error!));
        Assert.Equal(["failed"], m.Alerts.Types());
    }

    [Fact]
    public async Task A_function_that_ignores_its_token_runs_on_and_is_only_asked_to_stop()
    {
        await using var m = Make();
        var job = m.Cw.Job("patient", new JobOptions { Timeout = "1m" });
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        CancellationToken seen = default;
        var running = job.RunAsync(async (j, ct) =>
        {
            seen = ct;
            await release.Task;
            return ct.IsCancellationRequested;
        });
        await Eventually("the run to start", async () => (await m.Cw.RunsAsync("patient", 1)).Count == 1);
        m.Clock.Advance(Min);
        await Eventually("the token to be cancelled", () => seen.IsCancellationRequested);
        release.SetResult();
        Assert.True(await running);
        Assert.Equal(RunStatus.Ok, (await m.Cw.RunsAsync("patient", 1))[0].Status);
    }

    [Fact]
    public async Task The_callers_token_cancels_the_runs_token()
    {
        await using var m = Make();
        using var cts = new CancellationTokenSource();
        var running = m.Cw.RunAsync("stopped", (j, ct) => Task.Delay(Timeout.Infinite, ct), cts.Token);
        await Eventually("the run to start", async () => (await m.Cw.RunsAsync("stopped", 1)).Count == 1);
        await cts.CancelAsync();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => running);
        await Eventually("the run to be recorded", async () => (await m.Cw.RunsAsync("stopped", 1))[0].Status == RunStatus.Failed);
    }

    [Fact]
    public async Task A_caller_whose_token_is_cancelled_while_its_run_is_recorded_leaves_the_recording_to_complete()
    {
        var gate = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var store = new Wrapped { Entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously), Gate = gate.Task };
        await using var m = Make(store: store);
        var job = m.Cw.Job("recorded");
        using var cts = new CancellationTokenSource();
        var running = job.RunAsync((j, ct) => Task.FromResult("done"), cts.Token);
        await store.Entered.Task; // the recording is writing the finish
        await cts.CancelAsync();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => running);
        store.Entered = null;
        store.Gate = null;
        gate.SetResult();
        await Eventually("the recording to complete", async () => (await store.Inner.GetRunAsync((await m.Cw.RunsAsync("recorded", 1))[0].Id))!.Status == RunStatus.Ok);
        var run = (await m.Cw.RunsAsync("recorded", 1))[0];
        Assert.Equal("done", run.Output);
        Assert.Empty(m.Errors.Wheres());
    }

    [Fact]
    public async Task A_function_that_throws_before_returning_a_task_is_a_failed_run()
    {
        await using var m = Make();
        var job = m.Cw.Job("eager");
        Func<JobContext, CancellationToken, Task> plain = (j, ct) => throw new ArgumentException("no task");
        Func<JobContext, CancellationToken, Task<int>> valued = (j, ct) => throw new ArgumentException("no task either");
        Assert.Equal("no task", (await Assert.ThrowsAsync<ArgumentException>(() => job.RunAsync(plain))).Message);
        Assert.Equal("no task either", (await Assert.ThrowsAsync<ArgumentException>(() => job.RunAsync(valued))).Message);
        var runs = await m.Cw.RunsAsync("eager", 5);
        Assert.Equal(2, runs.Count);
        Assert.All(runs, r => Assert.Equal(RunStatus.Failed, r.Status));
        Assert.Equal("ArgumentException: no task either", FirstLine(runs[0].Error!));
    }

    [Fact]
    public async Task A_faulted_or_cancelled_task_is_a_failed_run()
    {
        await using var m = Make();
        await Assert.ThrowsAsync<InvalidOperationException>(() => m.Cw.RunAsync("faulted", (j, ct) => Task.FromException(new InvalidOperationException("faulted"))));
        await Assert.ThrowsAsync<TaskCanceledException>(() => m.Cw.RunAsync("cancelled", (j, ct) => Task.FromCanceled(new CancellationToken(true))));
        Assert.Equal(RunStatus.Failed, (await m.Cw.RunsAsync("faulted", 1))[0].Status);
        Assert.Equal("TaskCanceledException: A task was canceled.", FirstLine((await m.Cw.RunsAsync("cancelled", 1))[0].Error!));
    }

    [Fact]
    public async Task The_current_run_flows_into_tasks_threads_and_parallel_loops_and_is_gone_afterward()
    {
        await using var m = Make();
        var seen = new ConcurrentQueue<string?>();
        await m.Cw.RunAsync("flowing", async (j, ct) =>
        {
            seen.Enqueue(CronwatchClient.Current?.Name);
            await Task.Run(() => seen.Enqueue(CronwatchClient.Current?.Name), ct);
            var thread = new Thread(() => seen.Enqueue(CronwatchClient.Current?.Name));
            thread.Start();
            thread.Join();
            await Parallel.ForEachAsync(Enumerable.Range(0, 4), ct, (i, c) =>
            {
                seen.Enqueue(CronwatchClient.Current?.Name);
                return ValueTask.CompletedTask;
            });
            CronwatchClient.Current!.Log("from the context");
        });
        Assert.Equal(7, seen.Count);
        Assert.All(seen, name => Assert.Equal("flowing", name));
        Assert.Null(CronwatchClient.Current);
        Assert.Equal("from the context", (await m.Cw.RunsAsync("flowing", 1))[0].Output);
        // No pooled thread keeps the run: every thread the pool has answers none.
        var after = await Task.WhenAll(Enumerable.Range(0, 64).Select(_ => Task.Run(() => CronwatchClient.Current)));
        Assert.All(after, Assert.Null);
    }

    [Fact]
    public async Task Work_started_without_the_execution_context_has_no_current_run()
    {
        await using var m = Make();
        JobContext? suppressed = null;
        JobContext? unsafeQueued = null;
        await m.Cw.RunAsync("bare", async (j, ct) =>
        {
            Task<JobContext?> t;
            using (ExecutionContext.SuppressFlow())
            {
                t = Task.Run(() => CronwatchClient.Current);
            }
            suppressed = await t;
            var done = new TaskCompletionSource<JobContext?>(TaskCreationOptions.RunContinuationsAsynchronously);
            ThreadPool.UnsafeQueueUserWorkItem(_ => done.SetResult(CronwatchClient.Current), null);
            unsafeQueued = await done.Task;
            Assert.NotNull(CronwatchClient.Current);
        });
        Assert.Null(suppressed);
        Assert.Null(unsafeQueued);
    }

    [Fact]
    public async Task Nested_runs_put_the_outer_run_back()
    {
        await using var m = Make();
        var seen = new List<string>();
        await m.Cw.RunAsync("outer", async (j, ct) =>
        {
            await m.Cw.RunAsync("inner", (k, c) =>
            {
                seen.Add(CronwatchClient.Current!.Name);
                return Task.CompletedTask;
            }, ct);
            seen.Add(CronwatchClient.Current!.Name);
        });
        Assert.Equal(["inner", "outer"], seen);
        Assert.Null(CronwatchClient.Current);
    }

    [Fact]
    public async Task Callers_share_one_check_and_a_callers_token_ends_only_its_own_wait()
    {
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var held = new CountingSource { Hold = release.Task };
        await using var m = Make(sources: [held]);
        var a = m.Cw.CheckAsync();
        await held.Entered.Task;
        var b = m.Cw.CheckAsync();
        using var cts = new CancellationTokenSource();
        var c = m.Cw.CheckAsync(cts.Token);
        await cts.CancelAsync();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => c);
        release.SetResult();
        Assert.Same(await a, await b);
        Assert.Equal(1, held.Syncs);
        await m.Cw.CheckAsync();
        Assert.Equal(2, held.Syncs);
    }

    [Fact]
    public async Task A_continuation_of_a_finished_check_that_checks_again_starts_a_new_check()
    {
        var held = new CountingSource();
        await using var m = Make(sources: [held]);
        var first = m.Cw.CheckAsync();
        var second = first.ContinueWith(_ => m.Cw.CheckAsync(), CancellationToken.None, TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default).Unwrap();
        var r1 = await first;
        var r2 = await second;
        Assert.NotSame(r1, r2);
        Assert.Equal(2, held.Syncs);
    }

    [Fact]
    public async Task A_check_that_throws_is_that_checks_and_the_next_one_runs_again()
    {
        var store = new Wrapped();
        await using var m = Make(store: store);
        m.Cw.Job("j");
        store.Break("runningRuns");
        var e = await Assert.ThrowsAsync<CronwatchException>(() => m.Cw.CheckAsync());
        Assert.Equal(CronwatchErrorKind.Store, e.Kind);
        Assert.Contains("store down: runningRuns", e.Message, StringComparison.Ordinal);
        store.Broken.Clear();
        Assert.Single((await m.Cw.CheckAsync()).Jobs);
    }

    /// <summary>An exception whose message cannot be read.</summary>
    private sealed class Mute : Exception
    {
        public override string Message => throw new InvalidOperationException("no words");
    }

    [Fact]
    public async Task An_exception_whose_message_throws_still_fails_its_run()
    {
        await using var m = Make();
        // Caught by hand: the test framework's own assertion reads the message.
        Exception? thrown = null;
        try
        {
            await m.Cw.RunAsync("grumpy", (j, ct) => throw new Mute());
        }
        catch (Exception e)
        {
            thrown = e;
        }
        Assert.IsType<Mute>(thrown);
        var run = (await m.Cw.RunsAsync("grumpy", 1))[0];
        Assert.Equal(RunStatus.Failed, run.Status);
        Assert.StartsWith("Mute", run.Error, StringComparison.Ordinal);
    }

    [Fact]
    public async Task An_expect_check_that_throws_fails_the_run()
    {
        await using var m = Make();
        var job = m.Cw.Job("picky", new JobOptions { Expect = Expect.That(_ => throw new InvalidOperationException("cannot read it")) });
        await job.RunAsync((j, ct) => Task.FromResult("output"));
        var run = (await m.Cw.RunsAsync("picky", 1))[0];
        Assert.Equal(RunStatus.Failed, run.Status);
        Assert.Equal("Output check threw: cannot read it", run.Error);
        Assert.Equal("custom function", job.Definition.Expect);
        var mute = m.Cw.Job("mute-expect", new JobOptions { Expect = Expect.That(_ => throw new Mute()) });
        await mute.RunAsync((j, ct) => Task.FromResult("fine"));
        Assert.Equal("Output check threw: ", (await m.Cw.RunsAsync("mute-expect", 1))[0].Error);
    }

    [Fact]
    public async Task A_redact_that_throws_is_reported_and_the_default_redaction_used()
    {
        await using var m = Make(redact: _ => throw new InvalidOperationException("redact broke"));
        await m.Cw.RunAsync("redacting", (j, ct) =>
        {
            j.Log("token=not-a-real-one");
            return Task.CompletedTask;
        });
        var run = (await m.Cw.RunsAsync("redacting", 1))[0];
        Assert.Equal(RunStatus.Ok, run.Status);
        Assert.Contains("redact", m.Errors.Wheres());
    }

    [Fact]
    public async Task A_handle_finished_through_an_expect_that_throws_is_recorded()
    {
        await using var m = Make();
        var job = m.Cw.Job("handle-expect", new JobOptions { Expect = Expect.That(_ => throw new InvalidOperationException("no")) });
        var handle = await job.StartAsync();
        var run = await handle.FinishAsync();
        Assert.Equal(RunStatus.Failed, run!.Status);
        Assert.False(handle.IsActive);
        Assert.Equal(RunStatus.Failed, (await m.Cw.RunsAsync("handle-expect", 1))[0].Status);
    }

    [Fact]
    public async Task A_run_with_many_metrics_is_recorded()
    {
        await using var m = Make();
        const int n = 100_000;
        await m.Cw.RunAsync("many-metrics", (j, ct) =>
        {
            for (int i = 0; i < n; i++)
            {
                j.Metric("m" + i, i);
            }
            return Task.CompletedTask;
        });
        Assert.Equal(n, (await m.Cw.RunsAsync("many-metrics", 1))[0].Metrics.Count);
    }

    [Fact]
    public async Task A_store_that_throws_while_recording_is_reported()
    {
        var store = new Wrapped();
        await using var m = Make(store: store);
        store.Break("updateRunIf");
        await m.Cw.RunAsync("x", (j, ct) => Task.CompletedTask);
        Assert.Contains("recording x", m.Errors.Wheres());
        Assert.Contains(m.Errors.Messages(), msg => msg.Contains("store down: updateRunIf", StringComparison.Ordinal));
    }

    [Fact]
    public async Task A_run_id_holding_a_nul_is_refused()
    {
        await using var m = Make();
        var job = m.Cw.Job("ids");
        var e = await Assert.ThrowsAsync<CronwatchException>(() => job.RunAsync(new RunOptions { Id = "a\0b" }, (j, ct) => Task.CompletedTask));
        Assert.Equal("job \"ids\": run() cannot take a run id containing a NUL character", e.Message);
        await Assert.ThrowsAsync<CronwatchException>(() => job.StartAsync(new StartOptions { Id = "a\0b" }));
        await Assert.ThrowsAsync<CronwatchException>(() => job.ResumeAsync("a\0b"));
        var r = await Assert.ThrowsAsync<CronwatchException>(() => m.Cw.RecordRunAsync(Run.Running("a\0b", "ids", T0, "run")));
        Assert.Equal("recordRun: run ids cannot contain a NUL character (job \"ids\")", r.Message);
    }

    [Fact]
    public async Task A_process_that_exits_with_a_run_open_records_it_failed()
    {
        using var dir = new TempDir();
        string file = dir.File("cw.db");
        await RunProcessExitChild(file, "open");
        var store = SqlStore.Sqlite(StoreTests.Sqlite(file));
        await using (store)
        {
            var run = Assert.Single(await store.ListRunsAsync("long", 10));
            Assert.Equal(RunStatus.Failed, run.Status);
            Assert.Equal("Shutdown: the process stopped while the run was in progress", run.Error);
            Assert.Equal("working", run.Output);
            Assert.NotNull(run.FinishedAt);
        }
    }

    /// <summary>
    /// The process begins to stop the moment the run's row is written, before the client has gone
    /// on to the function: the hook already knows of the run, waits for its row, and records it
    /// failed (the Java port's gap, closed in both).
    /// </summary>
    [Fact]
    public async Task A_process_that_exits_as_the_run_row_is_written_records_it_failed()
    {
        using var dir = new TempDir();
        string file = dir.File("cw.db");
        await RunProcessExitChild(file, "atstart");
        var store = SqlStore.Sqlite(StoreTests.Sqlite(file));
        await using (store)
        {
            var run = Assert.Single(await store.ListRunsAsync("long", 10));
            Assert.Equal(RunStatus.Failed, run.Status);
            Assert.Equal("Shutdown: the process stopped while the run was in progress", run.Error);
            Assert.NotNull(run.FinishedAt);
        }
    }

    /// <summary>
    /// A run id given again while its first run is open here: the second's insert is refused, and
    /// while both functions run the first stays on the list the hook and disposal record, rather
    /// than being pushed off it.
    /// </summary>
    [Fact]
    public async Task A_run_id_given_again_while_open_leaves_the_first_run_recorded_at_disposal()
    {
        var m = Make();
        var job = m.Cw.Job("dup");
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var gate = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        Task first = job.RunAsync(new RunOptions { Id = "same" }, async (j, ct) =>
        {
            entered.SetResult();
            await gate.Task;
        });
        await entered.Task;
        var enteredAgain = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        Task second = job.RunAsync(new RunOptions { Id = "same" }, async (j, ct) =>
        {
            enteredAgain.SetResult();
            await gate.Task;
        });
        await enteredAgain.Task;
        await m.Cw.DisposeAsync();
        Run? run = await m.Store.GetRunAsync("same");
        Assert.NotNull(run);
        Assert.Equal(RunStatus.Failed, run.Status);
        Assert.Equal("Shutdown: the process stopped while the run was in progress", run.Error);
        gate.SetResult();
        await first;
        await second;
    }

    private static async Task RunProcessExitChild(string file, string mode)
    {
        string child = Path.Combine(
            Path.GetDirectoryName(AppContext.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar))!.Replace("Cronwatch.Tests", "ProcessExitChild", StringComparison.Ordinal),
            Path.GetFileName(AppContext.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar)),
            "ProcessExitChild.dll");
        Assert.True(File.Exists(child), "the child is built beside the tests: " + child);
        var start = new ProcessStartInfo(DotnetHost(), [child, file, mode])
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
        };
        using var process = Process.Start(start)!;
        var stdout = process.StandardOutput.ReadToEndAsync();
        var stderr = process.StandardError.ReadToEndAsync();
        await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(60));
        string output = (await stdout).Replace("\r\n", "\n", StringComparison.Ordinal);
        Assert.True(process.ExitCode == 3, "exit " + process.ExitCode + ": " + output + await stderr);
        Assert.Equal("started\n", output);
    }

    /// <summary>The <c>dotnet</c> host of the runtime running the tests.</summary>
    internal static string DotnetHost()
    {
        string exe = OperatingSystem.IsWindows() ? "dotnet.exe" : "dotnet";
        // .../dotnet/shared/Microsoft.NETCore.App/10.0.x/
        var runtime = new DirectoryInfo(RuntimeEnvironment.GetRuntimeDirectory().TrimEnd(Path.DirectorySeparatorChar));
        string? root = runtime.Parent?.Parent?.Parent?.FullName;
        if (root != null && File.Exists(Path.Combine(root, exe)))
        {
            return Path.Combine(root, exe);
        }
        return exe;
    }
}
