using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch.Internal;
using Xunit;
using static Cronwatch.Tests.Support;

namespace Cronwatch.Tests;

/// <summary>
/// The SDK's <c>outbox.test.ts</c>, ported: an alert is written with the state that opens its
/// condition, so a process that dies before sending it does not lose it, and while it is being
/// sent no check anywhere sends it too.
/// </summary>
public class OutboxTests
{
    private const long Min = 60_000;

    /// <summary>
    /// A store for a process that is about to die: once <see cref="Kill"/> is called, nothing it
    /// asks of the store ever completes, as when the process is gone. It counts the state writes.
    /// </summary>
    private sealed class Mortal(MemoryStore inner) : IStore, IConditionalRunStore, IStateCasStore
    {
        private volatile bool _dead;
        private int _stateWrites;

        public int StateWrites => Volatile.Read(ref _stateWrites);

        public void Kill() => _dead = true;

        private Task<T> Call<T>(Func<Task<T>> call) => _dead ? new TaskCompletionSource<T>().Task : call();

        private Task Call(Func<Task> call) => _dead ? new TaskCompletionSource().Task : call();

        public Task InitAsync(CancellationToken cancellationToken = default) => Call(() => inner.InitAsync(cancellationToken));

        public Task UpsertJobAsync(Definition definition, long now, CancellationToken cancellationToken = default) =>
            Call(() => inner.UpsertJobAsync(definition, now, cancellationToken));

        public Task<StoredJob?> GetJobAsync(string name, CancellationToken cancellationToken = default) => Call(() => inner.GetJobAsync(name, cancellationToken));

        public Task<IReadOnlyList<StoredJob>> ListJobsAsync(CancellationToken cancellationToken = default) => Call(() => inner.ListJobsAsync(cancellationToken));

        public Task DeleteJobAsync(string name, CancellationToken cancellationToken = default) => Call(() => inner.DeleteJobAsync(name, cancellationToken));

        public Task InsertRunAsync(Run run, CancellationToken cancellationToken = default) => Call(() => inner.InsertRunAsync(run, cancellationToken));

        public Task UpdateRunAsync(Run run, CancellationToken cancellationToken = default) => Call(() => inner.UpdateRunAsync(run, cancellationToken));

        public Task<Run?> GetRunAsync(string id, CancellationToken cancellationToken = default) => Call(() => inner.GetRunAsync(id, cancellationToken));

        public Task<IReadOnlyList<Run>> ListRunsAsync(string job, int limit, CancellationToken cancellationToken = default) =>
            Call(() => inner.ListRunsAsync(job, limit, cancellationToken));

        public Task<Run?> LastRunAsync(string job, CancellationToken cancellationToken = default) => Call(() => inner.LastRunAsync(job, cancellationToken));

        public Task<IReadOnlyList<Run>> RunningRunsAsync(CancellationToken cancellationToken = default) => Call(() => inner.RunningRunsAsync(cancellationToken));

        public Task<JobState?> GetStateAsync(string job, CancellationToken cancellationToken = default) => Call(() => inner.GetStateAsync(job, cancellationToken));

        public Task SetStateAsync(JobState state, CancellationToken cancellationToken = default) => Call(() => inner.SetStateAsync(state, cancellationToken));

        public Task<long> PruneAsync(long before, CancellationToken cancellationToken = default) => Call(() => inner.PruneAsync(before, cancellationToken));

        public Task<bool> UpdateRunIfAsync(Run run, IReadOnlyList<RunStatus> from, CancellationToken cancellationToken = default) =>
            Call(() => inner.UpdateRunIfAsync(run, from, cancellationToken));

        public Task<bool> CompareAndSetStateAsync(JobState state, long expected, CancellationToken cancellationToken = default) =>
            Call(() =>
            {
                Interlocked.Increment(ref _stateWrites);
                return inner.CompareAndSetStateAsync(state, expected, cancellationToken);
            });
    }

    private sealed class FuncTriage(Func<TriageContext, Task<string?>> answer) : ITriage
    {
        public Task<string?> TriageAsync(TriageContext context, CancellationToken cancellationToken) => answer(context);
    }

    /// <summary>A client for a process that is about to die: its own clock, no hook, errors ignored.</summary>
    private static CronwatchClient Dying(IStore store, IEnumerable<IChannel> channels, ITriage? triage = null) => new(new CronwatchOptions
    {
        Store = store,
        Clock = Clock(),
        Alerts = channels.ToList(),
        CronSecret = CronSecret.None,
        OnError = (e, where) => { },
        OnWarning = _ => { },
        ProcessExitHook = false,
        Triage = triage,
    });

    [Fact]
    public async Task The_write_that_opens_a_condition_holds_its_alert_so_a_process_that_dies_before_sending_it_does_not_lose_it()
    {
        var shared = new MemoryStore();
        var mortal = new Mortal(shared);
        var triaging = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        // The process dies while its triage call is out: no channel was ever called. Never
        // disposed, as a dead process is not.
        var dying = Dying(mortal, [new Capture()], new FuncTriage(_ =>
        {
            mortal.Kill();
            triaging.TrySetResult();
            return new TaskCompletionSource<string?>().Task;
        }));
        _ = dying.RunAsync("nightly", (j, ct) => throw new InvalidOperationException("disk full"));
        await triaging.Task.WaitAsync(TimeSpan.FromMinutes(1));
        JobState state = (await shared.GetStateAsync("nightly"))!;
        Assert.Equal(T0, state.OpenAt(Condition.Failed));
        SendingAlert entry = Assert.Single(state.Sending!);
        Assert.Equal((AlertType.Failed, T0, T0 + Evaluate.SendLeaseMs), (entry.Alert!.Type, entry.Alert.At, entry.Until!.Value));
        Assert.False(entry.Alert.TriageTried, "triage is made at send time, never stored here");
        Assert.DoesNotContain("triage", state.ToJson(), StringComparison.Ordinal);
        Assert.Empty(state.Undelivered!);

        // Another process's checks leave it alone while its sender's lease runs.
        await using var server = Make(store: shared, triage: new FuncTriage(_ => Task.FromResult<string?>("The disk is full.")));
        server.Clock.Advance(Min);
        await server.Cw.CheckAsync();
        Assert.Empty(server.Alerts.Types());

        // Once it has run out, the next check sends it, triaged, once.
        server.Clock.Set(T0 + Evaluate.SendLeaseMs + 1);
        CheckResult result = await server.Cw.CheckAsync();
        Assert.Equal([AlertType.Failed], result.Alerts.Select(a => a.Type));
        Alert sent = Assert.Single(server.Alerts.List());
        Assert.Equal((AlertType.Failed, T0, "The disk is full."), (sent.Type, sent.At, sent.Triage));
        JobState after = (await shared.GetStateAsync("nightly"))!;
        Assert.Null(after.Sending);
        Assert.DoesNotContain("\"sending\"", after.ToJson(), StringComparison.Ordinal);
        Assert.Empty(after.Undelivered!);
        await server.Cw.CheckAsync();
        await Quietly(() => server.Cw.RunAsync("nightly", (j, ct) => throw new InvalidOperationException("again")));
        Assert.Equal(["failed"], server.Alerts.Types());
    }

    [Fact]
    public async Task An_alert_a_channel_took_just_before_its_process_died_is_sent_again_after_the_lease()
    {
        var shared = new MemoryStore();
        var mortal = new Mortal(shared);
        var first = new ConcurrentQueue<Alert>();
        // Accepted, then the process is gone before it records that.
        var dying = Dying(mortal, [CustomChannel.Create("first", (a, ctx, ct) =>
        {
            first.Enqueue(a);
            mortal.Kill();
            return Task.CompletedTask;
        })]);
        _ = dying.RunAsync("nightly", (j, ct) => throw new InvalidOperationException("x"));
        await Eventually("the first send", () => !first.IsEmpty);
        await using var server = Make(store: shared);
        server.Clock.Set(T0 + Evaluate.SendLeaseMs + 1);
        await server.Cw.CheckAsync();
        // Sent a second time: the one duplicate a crash can cause.
        Assert.Equal(["failed"], server.Alerts.Types());
    }

    [Fact]
    public async Task While_an_alert_is_being_sent_no_check_anywhere_sends_it_too()
    {
        var shared = new MemoryStore();
        // Clocks of their own: moving the sender's would run out its channel's time.
        var clock = Clock();
        var sending = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var gate = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var sent = new ConcurrentQueue<Alert>();
        var held = CustomChannel.Create("held", async (a, ctx, ct) =>
        {
            sending.TrySetResult();
            await gate.Task;
            sent.Enqueue(a);
        });
        await using var worker = new CronwatchClient(new CronwatchOptions
        {
            Store = shared,
            Clock = clock,
            Alerts = [held],
            CronSecret = CronSecret.None,
            OnError = (e, where) => { },
            ProcessExitHook = false,
        });
        await using var server = Make(store: shared);
        Task run = Quietly(() => worker.RunAsync("nightly", (j, ct) => throw new InvalidOperationException("x")));
        await sending.Task.WaitAsync(TimeSpan.FromMinutes(1));
        server.Clock.Advance(Min);
        await server.Cw.CheckAsync();
        // The sending process's own check, too.
        await worker.CheckAsync().WaitAsync(TimeSpan.FromMinutes(1));
        gate.SetResult();
        await run;
        Assert.Equal([AlertType.Failed], sent.Select(a => a.Type));
        Assert.Empty(server.Alerts.Types());
        JobState state = (await shared.GetStateAsync("nightly"))!;
        Assert.Null(state.Sending);
        Assert.Empty(state.Undelivered!);
        Assert.Equal(T0, state.LastAlertAt);
        clock.Set(T0 + Evaluate.SendLeaseMs + Min);
        server.Clock.Set(T0 + Evaluate.SendLeaseMs + Min);
        await server.Cw.CheckAsync();
        await worker.CheckAsync();
        Assert.Empty(server.Alerts.Types());
        Assert.Single(sent);
    }

    [Fact]
    public async Task An_alert_no_channel_took_moves_from_the_outbox_to_the_retry_queue_with_its_triage()
    {
        var down = CustomChannel.Create("down", (a, ctx, ct) => throw new InvalidOperationException("down"));
        var store = new MemoryStore();
        await using var cw = new CronwatchClient(new CronwatchOptions
        {
            Store = store,
            Clock = Clock(),
            Alerts = [down],
            CronSecret = CronSecret.None,
            OnError = (e, where) => { },
            ProcessExitHook = false,
            Triage = new FuncTriage(_ => Task.FromResult<string?>("Look at the disk.")),
        });
        await Quietly(() => cw.RunAsync("nightly", (j, ct) => throw new InvalidOperationException("x")));
        JobState state = (await store.GetStateAsync("nightly"))!;
        Assert.Null(state.Sending);
        Alert queued = Assert.Single(state.Undelivered!);
        Assert.Equal((AlertType.Failed, "Look at the disk."), (queued.Type, queued.Triage));
    }

    [Fact]
    public async Task A_process_that_queues_its_alerts_for_a_check_elsewhere_writes_them_with_the_state_that_opens_the_condition()
    {
        var shared = new MemoryStore();
        var counting = new Mortal(shared);
        await using var recorder = Make(store: counting, deliver: Deliver.AtCheck);
        await Quietly(() => recorder.Cw.RunAsync("backup", (j, ct) => throw new InvalidOperationException("disk full")));
        JobState state = (await shared.GetStateAsync("backup"))!;
        Assert.Equal([AlertType.Failed], state.Undelivered!.Select(a => a.Type));
        Assert.Null(state.Sending);
        // One write: the failure and its alert together.
        Assert.Equal(1, counting.StateWrites);
    }

    [Fact]
    public void A_malformed_sending_entry_never_makes_the_state_unreadable()
    {
        JobState state = JobState.FromJson(
            "{\"job\":\"j\",\"open\":{},\"consecutiveFailures\":0,\"silencedUntil\":null,\"lastAlertAt\":null,"
            + "\"sending\":[null,7,{\"until\":\"x\"},{\"until\":5,\"alert\":\"x\"},{\"until\":1.5}]}");
        Assert.Equal(5, state.Sending!.Count);
        Assert.All(state.Sending, e => Assert.Null(e.Alert));
        Assert.Equal([null, null, null, 5L, 2L], state.Sending.Select(e => e.Until));
        // Every one has run out by 5, and none has an alert to queue.
        var (released, dropped) = Evaluate.ReleaseSending(state, 5);
        Assert.Null(released.Sending);
        Assert.Empty(released.Undelivered!);
        Assert.Equal(0, dropped);
        // An empty list is no key at all.
        Assert.Null(JobState.FromJson("{\"job\":\"j\",\"sending\":[]}").Sending);
    }
}
