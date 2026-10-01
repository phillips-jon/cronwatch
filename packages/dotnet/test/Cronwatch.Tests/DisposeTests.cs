using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using Xunit;

namespace Cronwatch.Tests;

/// <summary>
/// <c>DisposeAsync</c> waits for a check under way, as the SDK's <c>close()</c> awaits
/// <c>this.checking</c>, so the check never writes to a store already disposed.
/// </summary>
public class DisposeTests
{
    /// <summary>A store that notes when it is disposed and every call made after.</summary>
    private sealed class Noting : IStore, IAsyncDisposable
    {
        private readonly MemoryStore _inner = new();
        public volatile bool Disposed;
        public int AfterDispose;

        private T Note<T>(T value)
        {
            if (Disposed)
            {
                Interlocked.Increment(ref AfterDispose);
            }
            return value;
        }

        public ValueTask DisposeAsync()
        {
            Disposed = true;
            return ValueTask.CompletedTask;
        }

        public Task InitAsync(CancellationToken cancellationToken = default) => Note(_inner.InitAsync(cancellationToken));
        public Task UpsertJobAsync(Definition definition, long now, CancellationToken cancellationToken = default) => Note(_inner.UpsertJobAsync(definition, now, cancellationToken));
        public Task<StoredJob?> GetJobAsync(string name, CancellationToken cancellationToken = default) => Note(_inner.GetJobAsync(name, cancellationToken));
        public Task<IReadOnlyList<StoredJob>> ListJobsAsync(CancellationToken cancellationToken = default) => Note(_inner.ListJobsAsync(cancellationToken));
        public Task DeleteJobAsync(string name, CancellationToken cancellationToken = default) => Note(_inner.DeleteJobAsync(name, cancellationToken));
        public Task InsertRunAsync(Run run, CancellationToken cancellationToken = default) => Note(_inner.InsertRunAsync(run, cancellationToken));
        public Task UpdateRunAsync(Run run, CancellationToken cancellationToken = default) => Note(_inner.UpdateRunAsync(run, cancellationToken));
        public Task<Run?> GetRunAsync(string id, CancellationToken cancellationToken = default) => Note(_inner.GetRunAsync(id, cancellationToken));
        public Task<IReadOnlyList<Run>> ListRunsAsync(string job, int limit, CancellationToken cancellationToken = default) => Note(_inner.ListRunsAsync(job, limit, cancellationToken));
        public Task<Run?> LastRunAsync(string job, CancellationToken cancellationToken = default) => Note(_inner.LastRunAsync(job, cancellationToken));
        public Task<IReadOnlyList<Run>> RunningRunsAsync(CancellationToken cancellationToken = default) => Note(_inner.RunningRunsAsync(cancellationToken));
        public Task<JobState?> GetStateAsync(string job, CancellationToken cancellationToken = default) => Note(_inner.GetStateAsync(job, cancellationToken));
        public Task SetStateAsync(JobState state, CancellationToken cancellationToken = default) => Note(_inner.SetStateAsync(state, cancellationToken));
        public Task<long> PruneAsync(long before, CancellationToken cancellationToken = default) => Note(_inner.PruneAsync(before, cancellationToken));
    }

    /// <summary>A source that waits, ignoring the client's cancellation, until the test lets it go.</summary>
    private sealed class Held : ISource
    {
        public readonly TaskCompletionSource Entered = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public readonly TaskCompletionSource Gate = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public bool StoreDisposedWhenLetGo;
        public Noting? Store;

        public string Name => "held";

        public async Task<IReadOnlyList<Alert>?> SyncAsync(CronwatchClient client, CancellationToken cancellationToken)
        {
            Entered.TrySetResult();
            await Gate.Task.ConfigureAwait(false);
            StoreDisposedWhenLetGo = Store!.Disposed;
            return null;
        }
    }

    [Fact]
    public async Task Dispose_waits_for_the_check_under_way_before_the_store_goes()
    {
        var store = new Noting();
        var source = new Held { Store = store };
        // No wait for the other sends: what keeps the store open is the wait for the check.
        var m = Support.Make(store: store, sources: [source], timings: new Timings { CloseWait = TimeSpan.Zero });
        m.Cw.Job("j", new JobOptions { Schedule = "* * * * *" });
        Task<CheckResult> check = m.Cw.CheckAsync();
        await source.Entered.Task;
        Task dispose = m.Cw.DisposeAsync().AsTask();
        // Before the fix, the dispose ended here with the check still held, and the store went.
        await Task.WhenAny(dispose, Task.Delay(200, TestContext.Current.CancellationToken));
        Assert.False(store.Disposed, "the store is disposed while the check is under way");
        source.Gate.SetResult();
        await dispose;
        Assert.True(check.IsCompleted);
        Assert.False(source.StoreDisposedWhenLetGo);
        Assert.True(store.Disposed);
        Assert.Equal(0, store.AfterDispose);
    }

    /// <summary>A source that disposes the client it syncs for, from inside the check.</summary>
    private sealed class Disposing : ISource
    {
        public string Name => "disposing";

        public async Task<IReadOnlyList<Alert>?> SyncAsync(CronwatchClient client, CancellationToken cancellationToken)
        {
            await client.DisposeAsync();
            return null;
        }
    }

    [Fact]
    public async Task Dispose_from_the_check_itself_does_not_wait_for_it()
    {
        var m = Support.Make(sources: [new Disposing()], timings: new Timings { CloseWait = TimeSpan.Zero });
        Task<CheckResult> check = m.Cw.CheckAsync();
        // Waiting for itself, the check would never end.
        await Support.Eventually("the check ends", () => check.IsCompleted);
    }
}
