using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Diagnostics.Metrics;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch.Web;
using Xunit;
using static Cronwatch.Tests.Support;

namespace Cronwatch.Tests;

/// <summary>The core pass of the .NET audit: each case failed before its fix.</summary>
public class AuditCoreTests
{
    /// <summary>Set in a test's own flow, so a listener throws for that test's runs only.</summary>
    private static readonly AsyncLocal<bool> Armed = new();

    private static string Tag(Activity activity, string name) => activity.GetTagItem(name) as string ?? "";

    [Fact]
    public async Task A_telemetry_listener_that_throws_as_a_run_starts_neither_skips_the_function_nor_leaves_the_run_running()
    {
        using var listener = new ActivityListener
        {
            ShouldListenTo = s => s.Name == CronwatchTelemetry.Name,
            Sample = (ref ActivityCreationOptions<ActivityContext> _) => ActivitySamplingResult.AllDataAndRecorded,
            ActivityStarted = a =>
            {
                if (Armed.Value)
                {
                    throw new InvalidOperationException("listener down");
                }
            },
        };
        ActivitySource.AddActivityListener(listener);
        await using var m = Make();
        Armed.Value = true;
        bool ran = false;
        await m.Cw.RunAsync("listened-start", (j, ct) =>
        {
            ran = true;
            return Task.CompletedTask;
        });
        Armed.Value = false;
        Assert.True(ran);
        var runs = await m.Cw.RunsAsync("listened-start");
        Assert.Equal(RunStatus.Ok, Assert.Single(runs).Status);
    }

    [Fact]
    public async Task A_telemetry_listener_that_throws_as_a_run_ends_does_not_replace_what_the_function_answered()
    {
        using var listener = new ActivityListener
        {
            ShouldListenTo = s => s.Name == CronwatchTelemetry.Name,
            Sample = (ref ActivityCreationOptions<ActivityContext> _) => ActivitySamplingResult.AllDataAndRecorded,
            ActivityStopped = a =>
            {
                if (Tag(a, "cronwatch.job") == "listened-stop")
                {
                    throw new InvalidOperationException("listener down");
                }
            },
        };
        ActivitySource.AddActivityListener(listener);
        await using var m = Make();
        string answer = await m.Cw.RunAsync("listened-stop", (j, ct) => Task.FromResult("done"));
        Assert.Equal("done", answer);
        Assert.Equal(RunStatus.Ok, Assert.Single(await m.Cw.RunsAsync("listened-stop")).Status);
    }

    [Fact]
    public async Task A_meter_listener_that_throws_as_a_run_is_counted_does_not_leave_the_run_running()
    {
        using var listener = new MeterListener
        {
            InstrumentPublished = (instrument, l) =>
            {
                if (instrument.Meter.Name == CronwatchTelemetry.Name)
                {
                    l.EnableMeasurementEvents(instrument);
                }
            },
        };
        MeasurementCallback<long> onLong = (instrument, value, tags, state) => ThrowFor(tags);
        MeasurementCallback<double> onDouble = (instrument, value, tags, state) => ThrowFor(tags);
        listener.SetMeasurementEventCallback(onLong);
        listener.SetMeasurementEventCallback(onDouble);
        listener.Start();
        await using var m = Make();
        await m.Cw.RunAsync("metered", (j, ct) => Task.CompletedTask);
        await Eventually("the run recorded", async () => (await m.Cw.RunsAsync("metered")).Single().Status != RunStatus.Running);
        Assert.Equal(RunStatus.Ok, Assert.Single(await m.Cw.RunsAsync("metered")).Status);

        static void ThrowFor(ReadOnlySpan<KeyValuePair<string, object?>> tags)
        {
            foreach (var t in tags)
            {
                if (t.Key == "cronwatch.job" && (t.Value as string) == "metered")
                {
                    throw new InvalidOperationException("listener down");
                }
            }
        }
    }

    [Fact]
    public async Task Disposing_a_client_whose_token_has_a_throwing_callback_still_lets_go_of_the_store()
    {
        var store = new Disposable();
        var source = new Registering();
        var m = Make(store: store, sources: [source]);
        await m.Cw.CheckAsync();
        await m.Cw.DisposeAsync();
        Assert.True(store.Disposed);
    }

    [Fact]
    public async Task A_finish_whose_insert_and_read_back_both_fail_reports_the_inserts_failure()
    {
        var store = new Wrapped();
        await using var m = Make(store: store);
        store.Break("insertRun", "getRun");
        await m.Cw.RunAsync("unrecorded", (j, ct) => Task.CompletedTask);
        await Eventually("the finish reported", () => m.Errors.Entries.Count >= 2);
        Assert.All(m.Errors.Messages(), message => Assert.Contains("insertRun", message, StringComparison.Ordinal));
    }

    [Fact]
    public async Task A_handlers_run_is_inside_the_run_scope_as_a_run_is()
    {
        var scopes = new List<string>();
        await using var cw = new CronwatchClient(new CronwatchOptions
        {
            Clock = Clock(),
            Alerts = [],
            CronSecret = CronSecret.None,
            OnError = (e, where) => { },
            ProcessExitHook = false,
            RunScope = j =>
            {
                lock (scopes)
                {
                    scopes.Add(j.Name);
                }
                return null;
            },
        });
        var job = cw.Job("scoped-handler");
        Handler handler = job.Handler((j, request, ct) => Task.CompletedTask);
        Assert.Equal(200, (await handler.HandleAsync(new WebRequest("GET", "/"))).Status);
        Assert.Equal(["scoped-handler"], scopes);
    }

    [Fact]
    public async Task A_foreign_failure_count_at_the_limit_does_not_wrap_below_the_threshold()
    {
        await using var m = Make();
        m.Cw.Job("counted");
        await m.Cw.CheckAsync();
        await m.Store.SetStateAsync(new JobState { Job = "counted", ConsecutiveFailures = long.MaxValue });
        await Quietly(() => m.Cw.RunAsync("counted", (j, ct) => throw new InvalidOperationException("x")));
        Assert.Equal(["failed"], m.Alerts.Types());
        Assert.Equal(long.MaxValue, (await m.Store.GetStateAsync("counted"))!.ConsecutiveFailures);
    }

    private sealed class Registering : ISource
    {
        public string Name => "registering";

        public Task<IReadOnlyList<Alert>?> SyncAsync(CronwatchClient client, CancellationToken cancellationToken)
        {
            cancellationToken.Register(() => throw new InvalidOperationException("callback down"));
            return Task.FromResult<IReadOnlyList<Alert>?>(null);
        }
    }

    private sealed class Disposable() : Wrapped(new MemoryStore()), IAsyncDisposable
    {
        public bool Disposed { get; private set; }

        public ValueTask DisposeAsync()
        {
            Disposed = true;
            return ValueTask.CompletedTask;
        }
    }
}
