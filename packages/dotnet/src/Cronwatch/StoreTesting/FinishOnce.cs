using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using static Cronwatch.StoreTesting.Checks;

namespace Cronwatch.StoreTesting;

/// <summary>
/// The SDK's <c>finish-once.test.ts</c> over several stores sharing one database, as several
/// processes would have them: however many processes finish a run, it is recorded and judged
/// once. A store of the app's own that shares a database between processes should pass it:
/// <code>
/// await FinishOnce.RunAsync(() => new MySharedDatabase());
/// </code>
/// Each process is a <see cref="CronwatchClient"/> of its own over a store
/// <see cref="IShared.Open"/> gives, racing on tasks of their own. It throws a
/// <see cref="StoreContractException"/> at the first thing that goes wrong, and depends on no test
/// framework. Not part of the 1.x promise, which covers <see cref="StoreContract.RunAsync"/>
/// alone: the port's own tests race the SQL store with it.
/// </summary>
[Obsolete("Public by accident: the store kit promises StoreContract.RunAsync. It still works, and is removed in 1.0.")]
public static class FinishOnce
{
    private const long T0 = 1_767_605_400_000L;
    private const long Min = 60_000;

    /// <summary>Stores over one database: each <see cref="Open"/> is another store on the same data.</summary>
    public interface IShared
    {
        /// <summary>Another store over the shared data, as another process would open it.</summary>
        IStore Open();

        /// <summary>Closes what was opened and drops the data, at the end of a scenario.</summary>
        Task DoneAsync();
    }

    /// <summary>A clock the scenarios set by hand; timers are the system's.</summary>
    private sealed class ManualClock(long start) : TimeProvider
    {
        private long _now = start;

        public override DateTimeOffset GetUtcNow() => DateTimeOffset.FromUnixTimeMilliseconds(Interlocked.Read(ref _now));

        public override TimeZoneInfo LocalTimeZone => TimeZoneInfo.Utc;

        public void Advance(long ms) => Interlocked.Add(ref _now, ms);
    }

    /// <summary>One process: a client over its own store, with the alerts it sent and the errors it reported.</summary>
    private sealed class Worker : IAsyncDisposable
    {
        public ConcurrentQueue<string> Alerts { get; } = new();

        public ConcurrentQueue<string> Errors { get; } = new();

        public CronwatchClient Client { get; }

        public Worker(IStore store, TimeProvider clock)
        {
            Client = new CronwatchClient(new CronwatchOptions
            {
                Store = store,
                Alerts = { CustomChannel.Create("capture", (alert, _, _) => { Alerts.Enqueue(alert.Type.Value); return Task.CompletedTask; }) },
                CronSecret = CronSecret.None,
                OnError = (e, _) => Errors.Enqueue(e.Message),
                OnWarning = _ => { },
                Clock = clock,
                ProcessExitHook = false,
            });
        }

        public ValueTask DisposeAsync() => Client.DisposeAsync();
    }

    /// <summary>The three scenarios, each over a fresh database from <paramref name="shared"/>.</summary>
    /// <exception cref="StoreContractException">At the first thing that goes wrong.</exception>
    public static async Task RunAsync(Func<IShared> shared)
    {
        ArgumentNullException.ThrowIfNull(shared);
        await TwoProcessesFinishingOneRunAsync(shared()).ConfigureAwait(false);
        await TwoProcessesRecordingOneFinishedRunAsync(shared()).ConfigureAwait(false);
        await ManyProcessesStartingAndFinishingOneIdAsync(shared()).ConfigureAwait(false);
    }

    private static Run Failed(string id, string job, long startedAt) => new()
    {
        Id = id,
        Job = job,
        Status = RunStatus.Failed,
        StartedAt = startedAt,
        FinishedAt = startedAt + 1000,
        DurationMs = 1000,
        Error = "ERROR: deadlock detected",
        Trigger = "pg_cron",
    };

    /// <summary>Every task at once, each on a task of its own, and what each answered.</summary>
    private static async Task<List<T>> All<T>(IEnumerable<Func<Task<T>>> tasks)
    {
        var started = tasks.Select(t => Task.Run(t)).ToList();
        try
        {
            return [.. await Task.WhenAll(started).ConfigureAwait(false)];
        }
        catch (Exception e)
        {
            throw new StoreContractException("a process threw: " + e.GetType().Name + ": " + e.Message, e);
        }
    }

    private static void Ensure(bool ok, string what)
    {
        if (!ok)
        {
            throw new StoreContractException(what);
        }
    }

    private static async Task DoneAsync(IShared s)
    {
        try
        {
            await s.DoneAsync().ConfigureAwait(false);
        }
        catch (Exception e)
        {
            throw new StoreContractException("DoneAsync failed: " + e.Message, e);
        }
    }

    private static async Task<JobState> StateAsync(Worker p, string job)
    {
        JobState? s = await Get("getState", () => p.Client.Store.GetStateAsync(job)).ConfigureAwait(false);
        Ensure(s != null, job + " has a state");
        return s!;
    }

    // Two processes finishing one run: one records and judges it, the other reports it already
    // finished.
    private static async Task TwoProcessesFinishingOneRunAsync(IShared s)
    {
        var clock = new ManualClock(T0);
        try
        {
            var one = new Worker(s.Open(), clock);
            await using var disposeOne = one.ConfigureAwait(false);
            var two = new Worker(s.Open(), clock);
            await using var disposeTwo = two.ConfigureAwait(false);
            Job job = one.Client.Job("webhook-ingest", new JobOptions { FailuresBeforeAlert = 2 });
            two.Client.Job("webhook-ingest", new JobOptions { FailuresBeforeAlert = 2 });
            await job.StartAsync(new StartOptions { Id = "delivery-1" }).ConfigureAwait(false);
            RunHandle h1 = await one.Client.ResumeRunAsync("webhook-ingest", "delivery-1").ConfigureAwait(false);
            RunHandle h2 = await two.Client.ResumeRunAsync("webhook-ingest", "delivery-1").ConfigureAwait(false);
            clock.Advance(Min);
            var results = await All<Run?>(
            [
                () => h1.FailAsync(new InvalidOperationException("upstream 502")),
                () => h2.FailAsync(new InvalidOperationException("upstream 502")),
            ]).ConfigureAwait(false);
            Eq("finishes recorded", results.Count(r => r != null), 1);
            var errors = one.Errors.Concat(two.Errors).ToList();
            Ensure(
                errors.Any(e => e.Contains("already finished as failed; ignored", StringComparison.Ordinal)),
                "a process reported the run already finished: [" + string.Join(", ", errors) + "]");
            Eq("runs", (await one.Client.RunsAsync("webhook-ingest", 50).ConfigureAwait(false)).Count, 1);
            Eq("the failure counted once", (await StateAsync(one, "webhook-ingest").ConfigureAwait(false)).ConsecutiveFailures, 1L);
            var types = one.Alerts.Concat(two.Alerts).ToList();
            Ensure(types.Count == 0, "one failure is below failuresBeforeAlert 2: [" + string.Join(", ", types) + "]");
        }
        finally
        {
            await DoneAsync(s).ConfigureAwait(false);
        }
    }

    // Two processes recording one finished run from a source: it is judged once.
    private static async Task TwoProcessesRecordingOneFinishedRunAsync(IShared s)
    {
        var clock = new ManualClock(T0);
        try
        {
            var one = new Worker(s.Open(), clock);
            await using var disposeOne = one.ConfigureAwait(false);
            var two = new Worker(s.Open(), clock);
            await using var disposeTwo = two.ConfigureAwait(false);
            foreach (var p in new[] { one, two })
            {
                p.Client.Job("db:rollup", new JobOptions { FailuresBeforeAlert = 2 });
            }
            long at = T0 - Min;
            await one.Client.RecordRunAsync(Run.Running("pgcron:9", "db:rollup", at, "pg_cron")).ConfigureAwait(false);
            await two.Client.JobsAsync().ConfigureAwait(false);
            await All<IReadOnlyList<Alert>>(
            [
                () => one.Client.RecordRunAsync(Failed("pgcron:9", "db:rollup", at)),
                () => two.Client.RecordRunAsync(Failed("pgcron:9", "db:rollup", at)),
            ]).ConfigureAwait(false);
            Eq("judged once", (await StateAsync(one, "db:rollup").ConfigureAwait(false)).ConsecutiveFailures, 1L);
            var types = one.Alerts.Concat(two.Alerts).ToList();
            Ensure(types.Count == 0, "alerts [" + string.Join(", ", types) + "]");
            // Tasks may read the run after the first finish landed, and a run already finished is
            // left alone without a word; either way the only thing either process may report is
            // that finish.
            foreach (string e in one.Errors.Concat(two.Errors))
            {
                Ensure(e.Contains("pgcron:9 of db:rollup was already finished as failed; ignored", StringComparison.Ordinal), "unexpected error: " + e);
            }
        }
        finally
        {
            await DoneAsync(s).ConfigureAwait(false);
        }
    }

    // Many processes starting and finishing one id: exactly one finish is recorded.
    private static async Task ManyProcessesStartingAndFinishingOneIdAsync(IShared s)
    {
        var clock = new ManualClock(T0);
        var procs = new List<Worker>();
        try
        {
            for (int i = 0; i < 6; i++)
            {
                procs.Add(new Worker(s.Open(), clock));
            }
            var jobs = procs.ConvertAll(p => p.Client.Job("ingest"));
            await procs[0].Client.CheckAsync().ConfigureAwait(false);
            for (int k = 0; k < 5; k++)
            {
                string id = "evt_" + k.ToString(System.Globalization.CultureInfo.InvariantCulture);
                var handles = await All(jobs.Select(job => (Func<Task<RunHandle>>)(() => job.StartAsync(new StartOptions { Id = id })))).ConfigureAwait(false);
                var finishes = handles.Select((h, i) =>
                {
                    string result = "worker " + i.ToString(System.Globalization.CultureInfo.InvariantCulture);
                    return (Func<Task<Run?>>)(() => h.FinishAsync(result));
                });
                Eq(id + ": finishes recorded", (await All(finishes).ConfigureAwait(false)).Count(r => r != null), 1);
            }
            var runs = await procs[0].Client.RunsAsync("ingest", 500).ConfigureAwait(false);
            Eq("runs", runs.Count, 5);
            foreach (Run r in runs)
            {
                Eq("run " + r.Id, r.Status, RunStatus.Ok);
            }
            var unexpected = procs.SelectMany(p => p.Errors).Where(e => !e.Contains("already finished", StringComparison.Ordinal)).ToList();
            Ensure(unexpected.Count == 0, "unexpected errors: [" + string.Join(", ", unexpected) + "]");
        }
        finally
        {
            foreach (var p in procs)
            {
                await p.DisposeAsync().ConfigureAwait(false);
            }
            await DoneAsync(s).ConfigureAwait(false);
        }
    }
}
