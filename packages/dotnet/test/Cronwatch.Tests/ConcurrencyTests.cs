using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Xunit;
using static Cronwatch.Tests.Support;

namespace Cronwatch.Tests;

/// <summary>
/// The SDK's <c>concurrency.test.ts</c>, ported: two clients sharing one store, as two processes
/// do, keep each other's state updates through the version compare-and-set.
/// </summary>
public class ConcurrencyTests
{
    /// <summary>A store whose state reads take a while, as over a network, without compare-and-set.</summary>
    private class SlowReads(IStore inner) : IStore, IConditionalRunStore
    {
        protected IStore Inner { get; } = inner;

        public Task InitAsync(CancellationToken cancellationToken = default) => Inner.InitAsync(cancellationToken);

        public Task UpsertJobAsync(Definition definition, long now, CancellationToken cancellationToken = default) => Inner.UpsertJobAsync(definition, now, cancellationToken);

        public Task<StoredJob?> GetJobAsync(string name, CancellationToken cancellationToken = default) => Inner.GetJobAsync(name, cancellationToken);

        public Task<IReadOnlyList<StoredJob>> ListJobsAsync(CancellationToken cancellationToken = default) => Inner.ListJobsAsync(cancellationToken);

        public Task DeleteJobAsync(string name, CancellationToken cancellationToken = default) => Inner.DeleteJobAsync(name, cancellationToken);

        public Task InsertRunAsync(Run run, CancellationToken cancellationToken = default) => Inner.InsertRunAsync(run, cancellationToken);

        public Task UpdateRunAsync(Run run, CancellationToken cancellationToken = default) => Inner.UpdateRunAsync(run, cancellationToken);

        public Task<Run?> GetRunAsync(string id, CancellationToken cancellationToken = default) => Inner.GetRunAsync(id, cancellationToken);

        public Task<IReadOnlyList<Run>> ListRunsAsync(string job, int limit, CancellationToken cancellationToken = default) => Inner.ListRunsAsync(job, limit, cancellationToken);

        public Task<Run?> LastRunAsync(string job, CancellationToken cancellationToken = default) => Inner.LastRunAsync(job, cancellationToken);

        public Task<IReadOnlyList<Run>> RunningRunsAsync(CancellationToken cancellationToken = default) => Inner.RunningRunsAsync(cancellationToken);

        public async Task<JobState?> GetStateAsync(string job, CancellationToken cancellationToken = default)
        {
            await Task.Delay(25, cancellationToken);
            return await Inner.GetStateAsync(job, cancellationToken);
        }

        public Task SetStateAsync(JobState state, CancellationToken cancellationToken = default) => Inner.SetStateAsync(state, cancellationToken);

        public Task<long> PruneAsync(long before, CancellationToken cancellationToken = default) => Inner.PruneAsync(before, cancellationToken);

        public Task<bool> UpdateRunIfAsync(Run run, IReadOnlyList<RunStatus> from, CancellationToken cancellationToken = default) =>
            ((IConditionalRunStore)Inner).UpdateRunIfAsync(run, from, cancellationToken);
    }

    /// <summary>The same, with compare-and-set.</summary>
    private sealed class SlowReadsCas(IStore inner) : SlowReads(inner), IStateCasStore
    {
        public Task<bool> CompareAndSetStateAsync(JobState state, long expected, CancellationToken cancellationToken = default) =>
            ((IStateCasStore)Inner).CompareAndSetStateAsync(state, expected, cancellationToken);
    }

    private static async Task Fail(CronwatchClient cw, string name) =>
        await Assert.ThrowsAsync<InvalidOperationException>(() => cw.RunAsync(name, (j, ct) => throw new InvalidOperationException("x")));

    /// <summary>Two clients, as two processes sharing one store, each failing the job once at the same time.</summary>
    private static async Task<(JobState State, List<string> Types)> Race(IStore a, IStore b, IStore reader)
    {
        var clock = Clock();
        await using var first = Make(store: a, clock: clock);
        await using var second = Make(store: b, clock: clock);
        var options = new JobOptions { FailuresBeforeAlert = 2 };
        await first.Cw.Job("shared", options).RunAsync((j, ct) => Task.CompletedTask);
        second.Cw.Job("shared", options);
        await Task.WhenAll(Task.Run(() => Fail(first.Cw, "shared")), Task.Run(() => Fail(second.Cw, "shared")));
        var types = first.Alerts.Types().Concat(second.Alerts.Types()).ToList();
        var state = await reader.GetStateAsync("shared");
        Assert.NotNull(state);
        return (state, types);
    }

    [Fact]
    public async Task Two_processes_failing_a_job_at_once_count_both_and_alert_once()
    {
        var store = new MemoryStore();
        var (state, types) = await Race(new SlowReadsCas(store), new SlowReadsCas(store), store);
        Assert.Equal(2, state.ConsecutiveFailures);
        Assert.Equal([Condition.Failed], state.Open.Keys.ToList());
        Assert.Equal(["failed"], types);
        Assert.True(state.CountedVersion >= 3, "every write bumped the version");
    }

    [Fact]
    public async Task The_same_race_through_two_sqlite_connections_to_one_file()
    {
        using var dir = new TempDir();
        string file = dir.File("cw.db");
        var reader = SqlStore.Sqlite(StoreTests.Sqlite(file));
        // The wrappers are not disposable, so the clients cannot close the stores inside them.
        await using var a = SqlStore.Sqlite(StoreTests.Sqlite(file));
        await using var b = SqlStore.Sqlite(StoreTests.Sqlite(file));
        await using (reader)
        {
            var (state, types) = await Race(new SlowReadsCas(a), new SlowReadsCas(b), reader);
            Assert.Equal(2, state.ConsecutiveFailures);
            Assert.Equal(["failed"], types);
        }
    }

    [Fact]
    public async Task A_store_without_compare_and_set_still_works_but_cannot_keep_two_processes_apart()
    {
        var store = new MemoryStore();
        var (state, types) = await Race(new SlowReads(store), new SlowReads(store), store);
        // The documented caveat: when the two updates overlap the later write wins and one
        // failure is lost. Whether they overlap is up to the scheduler, so either count passes;
        // what matters is that the store still works, with no error and no alert.
        Assert.InRange(state.ConsecutiveFailures, 1, 2);
        // Two failures counted reach the job's threshold of two and alert once; one lost does not.
        Assert.Equal(state.ConsecutiveFailures == 2 ? ["failed"] : [], types);
    }

    [Fact]
    public async Task A_silence_made_by_one_process_survives_another_processes_run()
    {
        var store = new MemoryStore();
        var clock = Clock();
        await using var runner = Make(store: new SlowReadsCas(store), clock: clock);
        await using var admin = Make(store: new SlowReadsCas(store), clock: clock);
        await runner.Cw.RunAsync("s", (j, ct) => Task.CompletedTask);
        await Task.WhenAll(Task.Run(() => Fail(runner.Cw, "s")), Task.Run(() => admin.Cw.SilenceAsync("s", "1h")));
        var state = await store.GetStateAsync("s");
        Assert.NotNull(state!.SilencedUntil);
        Assert.Equal(1, state.ConsecutiveFailures);
    }

    [Fact]
    public async Task An_update_that_keeps_losing_gives_up_and_reports_and_the_run_still_finishes()
    {
        var contested = new Wrapped { CasMode = Cas.Refused };
        await using var m = Make(store: contested);
        await Fail(m.Cw, "busy");
        Assert.Equal(["evaluating busy"], m.Errors.Wheres());
        Assert.Equal(RunStatus.Failed, (await m.Cw.RunsAsync("busy", 1))[0].Status);
    }

    [Fact]
    public async Task Overlapping_runs_of_one_job_share_its_state_without_losing_updates()
    {
        await using var m = Make();
        m.Cw.Job("par", new JobOptions { FailuresBeforeAlert = 2 });
        await Task.WhenAll(Enumerable.Range(0, 3).Select(_ => Task.Run(() => Fail(m.Cw, "par"))));
        Assert.Equal(3, (await m.Store.GetStateAsync("par"))!.ConsecutiveFailures);
        Assert.Equal(["failed"], m.Alerts.Types());
    }

    [Fact]
    public async Task Two_hundred_runs_at_once_are_each_recorded()
    {
        await using var m = Make();
        var job = m.Cw.Job("wide");
        var runs = Enumerable.Range(0, 200).Select(i => Task.Run(() => job.RunAsync(async (j, ct) =>
        {
            await Task.Delay(5, ct);
            return "run " + i;
        })));
        foreach (string text in await Task.WhenAll(runs))
        {
            Assert.StartsWith("run ", text, StringComparison.Ordinal);
        }
        var recorded = await m.Cw.RunsAsync("wide", 500);
        Assert.Equal(200, recorded.Count);
        Assert.All(recorded, r => Assert.Equal(RunStatus.Ok, r.Status));
        Assert.Empty(m.Errors.Wheres());
        Assert.Equal(0, m.Cw.LockedJobs);
    }

    [Fact]
    public async Task The_queue_of_a_jobs_state_updates_is_let_go_of_once_idle()
    {
        await using var m = Make();
        for (int i = 0; i < 200; i++)
        {
            await m.Cw.SilenceAsync("gone-" + i, "1h");
        }
        await m.Cw.Job("kept").RunAsync((j, ct) =>
        {
            j.Log("ok");
            return Task.CompletedTask;
        });
        await Eventually("the queues to be let go of", () => m.Cw.LockedJobs == 0);
    }
}
