using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch.Internal;
using Microsoft.Extensions.Time.Testing;
using Xunit;

namespace Cronwatch.Tests;

/// <summary>What the client tests share: a fake clock, a capturing channel, the errors reported, and a store that misbehaves on request.</summary>
internal static class Support
{
    /// <summary>Monday 2026-01-05 09:30:00 UTC.</summary>
    public static readonly long T0 = Js.DateUtc(2026, 0, 5, 9, 30, 0, 0);

    public const long Min = 60_000;
    public const long Hour = 3_600_000;

    /// <summary>A clock at <paramref name="start"/> (default <see cref="T0"/>) whose local zone is UTC on every system.</summary>
    public static FakeTimeProvider Clock(long? start = null)
    {
        var clock = new FakeTimeProvider(DateTimeOffset.FromUnixTimeMilliseconds(start ?? T0));
        clock.SetLocalTimeZone(TimeZoneInfo.Utc);
        return clock;
    }

    /// <summary>Moves the clock to <paramref name="ms"/>.</summary>
    public static void Set(this FakeTimeProvider clock, long ms) => clock.SetUtcNow(DateTimeOffset.FromUnixTimeMilliseconds(ms));

    /// <summary>Moves the clock on by <paramref name="ms"/>.</summary>
    public static long Advance(this FakeTimeProvider clock, long ms)
    {
        clock.Advance(TimeSpan.FromMilliseconds(ms));
        return clock.GetUtcNow().ToUnixTimeMilliseconds();
    }

    /// <summary>The clock's time in epoch milliseconds.</summary>
    public static long Ms(this FakeTimeProvider clock) => clock.GetUtcNow().ToUnixTimeMilliseconds();

    /// <summary>A channel that keeps every alert it is sent.</summary>
    public sealed class Capture : IChannel
    {
        public ConcurrentQueue<Alert> Alerts { get; } = new();

        public string Name => "capture";

        public Task SendAsync(Alert alert, ChannelContext context, CancellationToken cancellationToken)
        {
            Alerts.Enqueue(alert);
            return Task.CompletedTask;
        }

        public List<string> Types() => Alerts.Select(a => a.Type.Value).ToList();

        public List<Alert> List() => Alerts.ToList();
    }

    /// <summary>The errors a client reported, with where each happened.</summary>
    public sealed class Errors
    {
        public ConcurrentQueue<(string Where, Exception Error)> Entries { get; } = new();

        public void Handle(Exception error, string where) => Entries.Enqueue((where, error));

        public List<string> Wheres() => Entries.Select(e => e.Where).ToList();

        public List<string> Messages() => Entries.Select(e => e.Error.Message).ToList();
    }

    /// <summary>A test's client and what it watches.</summary>
    public sealed record Made(CronwatchClient Cw, FakeTimeProvider Clock, Capture Alerts, Errors Errors, IStore Store) : IAsyncDisposable
    {
        public ValueTask DisposeAsync() => Cw.DisposeAsync();
    }

    /// <summary>
    /// The SDK tests' <c>make()</c>: a client on a fake clock, a capturing channel, errors
    /// collected, no cron secret and no process-exit hook.
    /// </summary>
    public static Made Make(
        IStore? store = null,
        FakeTimeProvider? clock = null,
        Deliver deliver = Deliver.Now,
        JobOptions? defaults = null,
        ITriage? triage = null,
        Func<string, string>? redact = null,
        IEnumerable<ISource>? sources = null,
        Duration? retention = null,
        IEnumerable<IChannel>? channels = null,
        Timings? timings = null)
    {
        clock ??= Clock();
        var capture = new Capture();
        var errors = new Errors();
        store ??= new MemoryStore();
        var alerts = new List<IChannel> { capture };
        if (channels != null)
        {
            alerts.AddRange(channels);
        }
        var options = new CronwatchOptions
        {
            Store = store,
            Clock = clock,
            Alerts = alerts,
            CronSecret = CronSecret.None,
            OnError = errors.Handle,
            OnWarning = _ => { },
            ProcessExitHook = false,
            Deliver = deliver,
            Defaults = defaults,
            Triage = triage,
            Redact = redact,
            Sources = sources?.ToList() ?? [],
            Retention = retention ?? "30d",
            TimingsOverride = timings,
        };
        return new Made(new CronwatchClient(options), clock, capture, errors, store);
    }

    /// <summary>The text up to its first newline.</summary>
    public static string FirstLine(string text)
    {
        int n = text.IndexOf('\n', StringComparison.Ordinal);
        return n < 0 ? text : text[..n];
    }

    /// <summary>
    /// Waits up to thirty seconds for <paramref name="condition"/>, polling, and fails with
    /// <paramref name="what"/> if it never holds. For outcomes that arrive on the client's own
    /// tasks; never a bound on how long something took.
    /// </summary>
    public static async Task Eventually(string what, Func<bool> condition)
    {
        var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(30);
        while (!condition())
        {
            if (DateTime.UtcNow > deadline)
            {
                Assert.True(condition(), "waited thirty seconds for: " + what);
                return;
            }
            await Task.Delay(10);
        }
    }

    /// <summary>The polling wait, for an asynchronous condition.</summary>
    public static async Task Eventually(string what, Func<Task<bool>> condition)
    {
        var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(30);
        while (!await condition())
        {
            if (DateTime.UtcNow > deadline)
            {
                Assert.True(await condition(), "waited thirty seconds for: " + what);
                return;
            }
            await Task.Delay(10);
        }
    }

    /// <summary>Runs <paramref name="body"/> and swallows what it throws: the run's business, recorded by the client.</summary>
    public static async Task Quietly(Func<Task> body)
    {
        try
        {
            await body();
        }
        catch (Exception)
        {
            // The client recorded it.
        }
    }

    /// <summary>How the wrapped store answers compare-and-set.</summary>
    public enum Cas
    {
        /// <summary>As the store underneath does.</summary>
        Normal,

        /// <summary>Always refused, as if another process wrote between every read and write.</summary>
        Refused,
    }

    /// <summary>
    /// A store over another whose methods throw while named in <see cref="Broken"/>, whose
    /// conditional run update can be held at a gate, and whose compare-and-set can refuse.
    /// </summary>
    public class Wrapped(IStore inner) : IStore, IConditionalRunStore, IStateCasStore, IRunDeletingStore
    {
        public Wrapped()
            : this(new MemoryStore())
        {
        }

        public IStore Inner { get; } = inner;

        public ConcurrentDictionary<string, bool> Broken { get; } = new(StringComparer.Ordinal);

        public volatile Cas CasMode = Cas.Normal;
        public int InitFailures { get; set; }
        public int Inits;

        /// <summary>Completed when the conditional run update is entered, when set.</summary>
        public TaskCompletionSource? Entered { get; set; }

        /// <summary>Awaited inside the conditional run update, when set.</summary>
        public Task? Gate { get; set; }

        public void Break(params string[] methods)
        {
            foreach (var m in methods)
            {
                Broken[m] = true;
            }
        }

        public void Mend(params string[] methods)
        {
            foreach (var m in methods)
            {
                Broken.TryRemove(m, out _);
            }
        }

        protected void Check(string method)
        {
            if (Broken.ContainsKey(method))
            {
                throw new InvalidOperationException("store down: " + method);
            }
        }

        public Task InitAsync(CancellationToken cancellationToken = default)
        {
            Check("init");
            if (Interlocked.Increment(ref Inits) <= InitFailures)
            {
                throw new InvalidOperationException("not yet");
            }
            return Inner.InitAsync(cancellationToken);
        }

        /// <summary>Awaited before a definition is written, when set.</summary>
        public Func<Definition, Task>? BeforeUpsert { get; set; }

        public async Task UpsertJobAsync(Definition definition, long now, CancellationToken cancellationToken = default)
        {
            Check("upsertJob");
            if (BeforeUpsert is { } before)
            {
                await before(definition);
            }
            await Inner.UpsertJobAsync(definition, now, cancellationToken);
            if (AfterUpsert is { } after)
            {
                await after(definition);
            }
        }

        /// <summary>Awaited once a definition is written, when set.</summary>
        public Func<Definition, Task>? AfterUpsert { get; set; }

        public Task<StoredJob?> GetJobAsync(string name, CancellationToken cancellationToken = default)
        {
            Check("getJob");
            return Inner.GetJobAsync(name, cancellationToken);
        }

        public Task<IReadOnlyList<StoredJob>> ListJobsAsync(CancellationToken cancellationToken = default)
        {
            Check("listJobs");
            return Inner.ListJobsAsync(cancellationToken);
        }

        public Task DeleteJobAsync(string name, CancellationToken cancellationToken = default)
        {
            Check("deleteJob");
            return Inner.DeleteJobAsync(name, cancellationToken);
        }

        public Task InsertRunAsync(Run run, CancellationToken cancellationToken = default)
        {
            Check("insertRun");
            return Inner.InsertRunAsync(run, cancellationToken);
        }

        public Task UpdateRunAsync(Run run, CancellationToken cancellationToken = default)
        {
            Check("updateRun");
            return Inner.UpdateRunAsync(run, cancellationToken);
        }

        public Task<Run?> GetRunAsync(string id, CancellationToken cancellationToken = default)
        {
            Check("getRun");
            return Inner.GetRunAsync(id, cancellationToken);
        }

        public Task<IReadOnlyList<Run>> ListRunsAsync(string job, int limit, CancellationToken cancellationToken = default)
        {
            Check("listRuns");
            return Inner.ListRunsAsync(job, limit, cancellationToken);
        }

        public Task<Run?> LastRunAsync(string job, CancellationToken cancellationToken = default)
        {
            Check("lastRun");
            return Inner.LastRunAsync(job, cancellationToken);
        }

        public Task<IReadOnlyList<Run>> RunningRunsAsync(CancellationToken cancellationToken = default)
        {
            Check("runningRuns");
            return Inner.RunningRunsAsync(cancellationToken);
        }

        public Task<JobState?> GetStateAsync(string job, CancellationToken cancellationToken = default)
        {
            Check("getState");
            return Inner.GetStateAsync(job, cancellationToken);
        }

        public Task SetStateAsync(JobState state, CancellationToken cancellationToken = default)
        {
            Check("setState");
            return Inner.SetStateAsync(state, cancellationToken);
        }

        public Task<long> PruneAsync(long before, CancellationToken cancellationToken = default)
        {
            Check("prune");
            return Inner.PruneAsync(before, cancellationToken);
        }

        public async Task<bool> UpdateRunIfAsync(Run run, IReadOnlyList<RunStatus> from, CancellationToken cancellationToken = default)
        {
            Check("updateRunIf");
            Entered?.TrySetResult();
            if (Gate is { } gate)
            {
                await gate;
            }
            return await ((IConditionalRunStore)Inner).UpdateRunIfAsync(run, from, cancellationToken);
        }

        public Task<bool> CompareAndSetStateAsync(JobState state, long expected, CancellationToken cancellationToken = default)
        {
            Check("compareAndSetState");
            if (CasMode == Cas.Refused)
            {
                return Task.FromResult(false);
            }
            return ((IStateCasStore)Inner).CompareAndSetStateAsync(state, expected, cancellationToken);
        }

        public Task<bool> DeleteRunIfAsync(string id, string job, RunStatus status, CancellationToken cancellationToken = default)
        {
            Check("deleteRunIf");
            return ((IRunDeletingStore)Inner).DeleteRunIfAsync(id, job, status, cancellationToken);
        }
    }

    /// <summary>A store with none of the optional capabilities: the client falls back to a read and a write.</summary>
    public sealed class Plain(IStore inner) : IStore
    {
        public Task InitAsync(CancellationToken cancellationToken = default) => inner.InitAsync(cancellationToken);

        public Task UpsertJobAsync(Definition definition, long now, CancellationToken cancellationToken = default) => inner.UpsertJobAsync(definition, now, cancellationToken);

        public Task<StoredJob?> GetJobAsync(string name, CancellationToken cancellationToken = default) => inner.GetJobAsync(name, cancellationToken);

        public Task<IReadOnlyList<StoredJob>> ListJobsAsync(CancellationToken cancellationToken = default) => inner.ListJobsAsync(cancellationToken);

        public Task DeleteJobAsync(string name, CancellationToken cancellationToken = default) => inner.DeleteJobAsync(name, cancellationToken);

        public Task InsertRunAsync(Run run, CancellationToken cancellationToken = default) => inner.InsertRunAsync(run, cancellationToken);

        public Task UpdateRunAsync(Run run, CancellationToken cancellationToken = default) => inner.UpdateRunAsync(run, cancellationToken);

        public Task<Run?> GetRunAsync(string id, CancellationToken cancellationToken = default) => inner.GetRunAsync(id, cancellationToken);

        public Task<IReadOnlyList<Run>> ListRunsAsync(string job, int limit, CancellationToken cancellationToken = default) => inner.ListRunsAsync(job, limit, cancellationToken);

        public Task<Run?> LastRunAsync(string job, CancellationToken cancellationToken = default) => inner.LastRunAsync(job, cancellationToken);

        public Task<IReadOnlyList<Run>> RunningRunsAsync(CancellationToken cancellationToken = default) => inner.RunningRunsAsync(cancellationToken);

        public Task<JobState?> GetStateAsync(string job, CancellationToken cancellationToken = default) => inner.GetStateAsync(job, cancellationToken);

        public Task SetStateAsync(JobState state, CancellationToken cancellationToken = default) => inner.SetStateAsync(state, cancellationToken);

        public Task<long> PruneAsync(long before, CancellationToken cancellationToken = default) => inner.PruneAsync(before, cancellationToken);
    }
}
