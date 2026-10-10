using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Xunit;
using static Cronwatch.Tests.Support;

namespace Cronwatch.Tests;

/// <summary>
/// The SDK's <c>client-hardening.test.ts</c>, ported, with the Java and Go audits' core cases:
/// missed with a short period, store outages, a store that initialises late, a hung channel and
/// triage, the retry queue and its budget, deliver at check, refused options, capped output, an
/// error named once, the baseline, a job that cannot be evaluated, and the interval's bounds.
/// </summary>
public class HardeningTests
{
    private static Task Fail(CronwatchClient cw, string name, string message = "x") =>
        Assert.ThrowsAsync<InvalidOperationException>(() => cw.RunAsync(name, (j, ct) => throw new InvalidOperationException(message)));

    private static Task Ok(CronwatchClient cw, string name) => cw.RunAsync(name, (j, ct) => Task.CompletedTask);

    private static async Task<JobState> State(Made m, string job)
    {
        var s = await m.Store.GetStateAsync(job);
        Assert.NotNull(s);
        return s;
    }

    private static async Task<List<string>> QueuedTypes(Made m, string job) =>
        (await State(m, job)).Undelivered!.Select(a => a.Type.Value).ToList();

    private static IChannel Throwing(string name, Func<bool> down, Action<Alert>? sent = null, Action? attempt = null) =>
        CustomChannel.Create(name, (a, ctx, ct) =>
        {
            attempt?.Invoke();
            if (down())
            {
                throw new IOException("down");
            }
            sent?.Invoke(a);
            return Task.CompletedTask;
        });

    [Fact]
    public async Task A_cron_firing_more_often_than_its_grace_is_still_missed()
    {
        await using var m = Make();
        var job = m.Cw.Job("often", new JobOptions { Schedule = "*/5 * * * *" });
        await Ok(m.Cw, "often"); // 09:30
        m.Clock.Advance(14 * Min);
        Assert.Empty((await m.Cw.CheckAsync()).Alerts);
        m.Clock.Advance(2 * Min);
        Assert.Equal([AlertType.Missed], (await m.Cw.CheckAsync()).Alerts.Select(a => a.Type));
        await job.RunAsync((j, ct) => Task.CompletedTask);
        Assert.Equal(["missed", "recovered"], m.Alerts.Types());
    }

    [Fact]
    public async Task A_missed_run_whose_next_run_fails_below_the_threshold_still_recovers_later()
    {
        await using var m = Make();
        m.Cw.Job("quiet", new JobOptions { Schedule = "every 1h", FailuresBeforeAlert = 3 });
        await m.Cw.CheckAsync();
        m.Clock.Advance(2 * Hour);
        await m.Cw.CheckAsync();
        await Fail(m.Cw, "quiet");
        Assert.Equal(["missed"], m.Alerts.Types());
        await Ok(m.Cw, "quiet");
        Assert.Equal(["missed", "recovered"], m.Alerts.Types());
        Assert.Contains("after: missed", m.Alerts.List()[1].Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task A_store_outage_never_stops_the_job_and_store_errors_go_to_on_error()
    {
        var store = new Wrapped();
        store.Break("upsertJob", "insertRun", "getState", "setState", "updateRun", "listRuns");
        await using var m = Make(store: store);
        int ran = 0;
        int seven = await m.Cw.RunAsync("s", (j, ct) =>
        {
            Interlocked.Increment(ref ran);
            return Task.FromResult(7);
        });
        Assert.Equal(7, seven);
        await Assert.ThrowsAsync<InvalidOperationException>(() => m.Cw.RunAsync("s", (j, ct) =>
        {
            Interlocked.Increment(ref ran);
            throw new InvalidOperationException("the job's own");
        }));
        Assert.Equal(2, ran);
        var wheres = m.Errors.Wheres();
        Assert.NotEmpty(wheres);
        Assert.All(wheres, w => Assert.Equal("recording s", w));
        store.Broken.Clear();
        await m.Cw.RunAsync("s", (j, ct) => Task.FromResult("back"));
        Assert.Single(await m.Cw.RunsAsync("s", 50));
    }

    [Fact]
    public async Task A_store_that_fails_to_initialise_is_tried_again_on_the_next_call()
    {
        var store = new Wrapped { InitFailures = 1 };
        await using var m = Make(store: store);
        Assert.Equal(1, await m.Cw.RunAsync("i", (j, ct) => Task.FromResult(1)));
        Assert.Equal(["recording i"], m.Errors.Wheres());
        // The finished run was written on the retry, once init went through.
        Assert.Equal(2, store.Inits);
        await m.Cw.RunAsync("i", (j, ct) => Task.FromResult(2));
        Assert.Equal(2, store.Inits);
        Assert.Equal(2, (await m.Cw.RunsAsync("i", 50)).Count);
    }

    [Fact]
    public async Task Dispatch_does_not_overwrite_a_silence_made_while_an_alert_was_being_sent()
    {
        CronwatchClient? cw = null;
        var silencer = CustomChannel.Create("silencer", (a, ctx, ct) => cw!.SilenceAsync("loud", "1h", ct));
        await using var m = Make(channels: [silencer]);
        cw = m.Cw;
        await Fail(m.Cw, "loud");
        var state = await State(m, "loud");
        Assert.NotNull(state.SilencedUntil);
        Assert.Equal([new KeyValuePair<Condition, long>(Condition.Failed, T0)], state.Open.ToList());
        Assert.Equal(T0, state.LastAlertAt);
    }

    [Fact]
    public async Task A_hung_channel_times_out_without_holding_up_the_others()
    {
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var cancelled = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var hung = CustomChannel.Create("hung", async (a, ctx, ct) =>
        {
            entered.TrySetResult();
            try
            {
                await Task.Delay(Timeout.Infinite, ct);
            }
            catch (OperationCanceledException)
            {
                cancelled.TrySetResult();
                throw;
            }
        });
        await using var m = Make(channels: [hung], timings: new Timings { Channel = TimeSpan.FromSeconds(1) });
        var failing = Fail(m.Cw, "h");
        await entered.Task;
        await Eventually("the good channel's send", () => m.Alerts.Types().Count == 1);
        // The channel's deadline is on the client's clock.
        await Eventually("the run to be recorded", () =>
        {
            m.Clock.Advance(1000);
            return failing.IsCompleted;
        });
        await failing;
        Assert.Equal(["failed"], m.Alerts.Types());
        Assert.Equal(["alert channel hung"], m.Errors.Wheres());
        Assert.Contains("timed out after 1000ms", m.Errors.Messages()[0], StringComparison.Ordinal);
        Assert.Empty((await State(m, "h")).Undelivered!);
        await cancelled.Task.WaitAsync(TimeSpan.FromSeconds(30));
    }

    private sealed class HungTriage : ITriage
    {
        public TaskCompletionSource Entered { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);

        public TaskCompletionSource Cancelled { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);

        public async Task<string?> TriageAsync(TriageContext context, CancellationToken cancellationToken)
        {
            Entered.TrySetResult();
            try
            {
                await Task.Delay(Timeout.Infinite, cancellationToken);
            }
            catch (OperationCanceledException)
            {
                Cancelled.TrySetResult();
                throw;
            }
            return "never";
        }
    }

    private sealed class FuncTriage(Func<TriageContext, Task<string?>> answer) : ITriage
    {
        public Task<string?> TriageAsync(TriageContext context, CancellationToken cancellationToken) => answer(context);
    }

    [Fact]
    public async Task Triage_is_cancelled_when_the_client_stops_waiting_for_it()
    {
        var triage = new HungTriage();
        await using var m = Make(triage: triage, timings: new Timings { Triage = TimeSpan.FromMilliseconds(300) });
        var failing = Fail(m.Cw, "t");
        await triage.Entered.Task;
        await Eventually("the run to be recorded", () =>
        {
            m.Clock.Advance(300);
            return failing.IsCompleted;
        });
        await failing;
        await triage.Cancelled.Task.WaitAsync(TimeSpan.FromSeconds(30));
        Assert.Equal(["triage for t"], m.Errors.Wheres());
        Assert.Equal(["failed"], m.Alerts.Types());
        Assert.Null(m.Alerts.List()[0].Triage);
    }

    [Fact]
    public async Task An_alert_no_channel_took_is_retried_once_per_check_until_one_does()
    {
        bool down = true;
        int attempts = 0;
        var got = new ConcurrentQueue<Alert>();
        var flaky = Throwing("flaky", () => Volatile.Read(ref down), got.Enqueue, () => Interlocked.Increment(ref attempts));
        await using var m = MakeOnly(flaky);
        await Fail(m.Cw, "r");
        var state = await State(m, "r");
        Assert.Single(state.Undelivered!);
        Assert.Null(state.LastAlertAt);
        m.Clock.Advance(Min);
        await m.Cw.CheckAsync();
        Assert.Equal(2, attempts);
        Volatile.Write(ref down, false);
        m.Clock.Advance(Min);
        var result = await m.Cw.CheckAsync();
        Assert.Equal([AlertType.Failed], result.Alerts.Select(a => a.Type));
        Assert.Single(got);
        Assert.Equal(T0, got.First().At);
        state = await State(m, "r");
        Assert.Empty(state.Undelivered!);
        Assert.Equal(T0 + 2 * Min, state.LastAlertAt);
        await m.Cw.CheckAsync();
        Assert.Equal(3, attempts);
    }

    /// <summary>A client whose only channel is <paramref name="channel"/>.</summary>
    private static Made MakeOnly(IChannel channel, IStore? store = null, Support.Capture? unused = null, ITriage? triage = null, Timings? timings = null, Microsoft.Extensions.Time.Testing.FakeTimeProvider? clock = null, Deliver deliver = Deliver.Now)
    {
        clock ??= Clock();
        store ??= new MemoryStore();
        var errors = new Errors();
        var cw = new CronwatchClient(new CronwatchOptions
        {
            Store = store,
            Clock = clock,
            Alerts = { channel },
            CronSecret = CronSecret.None,
            OnError = errors.Handle,
            OnWarning = _ => { },
            ProcessExitHook = false,
            Triage = triage,
            TimingsOverride = timings,
            Deliver = deliver,
        });
        return new Made(cw, clock, unused ?? new Support.Capture(), errors, store);
    }

    [Fact]
    public async Task Deliver_at_check_queues_alerts_for_another_processes_check_which_sends_them_with_triage()
    {
        var clock = Clock();
        var store = new MemoryStore();
        int triaged = 0;
        await using var recorder = Make(store: store, clock: clock, deliver: Deliver.AtCheck, triage: new FuncTriage(_ => Task.FromResult<string?>("never asked")));
        await using var server = Make(store: store, clock: clock, triage: new FuncTriage(_ =>
        {
            Interlocked.Increment(ref triaged);
            return Task.FromResult<string?>("The disk is full.");
        }));
        recorder.Cw.Job("backup", new JobOptions { Schedule = "40 3 * * *", Timezone = "UTC" });
        await Fail(recorder.Cw, "backup", "disk full");
        Assert.Empty(recorder.Alerts.Types());
        Assert.Equal(["failed"], await QueuedTypes(recorder, "backup"));
        Assert.Null((await State(recorder, "backup")).LastAlertAt);
        Assert.Empty((await recorder.Cw.CheckAsync()).Alerts);
        clock.Advance(Min);
        var result = await server.Cw.CheckAsync();
        Assert.Equal([AlertType.Failed], result.Alerts.Select(a => a.Type));
        Assert.Equal(["failed"], server.Alerts.Types());
        Assert.Equal("The disk is full.", server.Alerts.List()[0].Triage);
        Assert.Equal(T0, server.Alerts.List()[0].At);
        Assert.Equal(1, triaged);
        Assert.Empty((await State(server, "backup")).Undelivered!);
        Assert.Equal(T0 + Min, (await State(server, "backup")).LastAlertAt);
        await server.Cw.CheckAsync();
        Assert.Equal(["failed"], server.Alerts.Types());
        await Ok(recorder.Cw, "backup");
        await server.Cw.CheckAsync();
        Assert.Equal(["failed", "recovered"], server.Alerts.Types());
        Assert.Equal(1, triaged);
    }

    private static async Task Refused(CronwatchClient cw, JobOptions options, string field)
    {
        var e = Assert.Throws<CronwatchException>(() => cw.Job("a", options));
        Assert.Contains(field, e.Message, StringComparison.Ordinal);
        Assert.Equal(CronwatchErrorKind.Invalid, e.Kind);
        await Task.CompletedTask;
    }

    [Fact]
    public async Task Job_refuses_numbers_that_would_quietly_turn_a_check_off()
    {
        await using var m = Make();
        var cw = m.Cw;
        await Refused(cw, new JobOptions().Field("failuresBeforeAlert", double.NaN), "failuresBeforeAlert");
        await Refused(cw, new JobOptions { FailuresBeforeAlert = 0 }, "failuresBeforeAlert");
        await Refused(cw, new JobOptions().Field("failuresBeforeAlert", 1.5), "failuresBeforeAlert");
        await Refused(cw, new JobOptions { Budget = { ["cost"] = double.NaN } }, "budget.cost");
        await Refused(cw, new JobOptions { Budget = { ["cost"] = double.PositiveInfinity } }, "budget.cost");
        await Refused(cw, new JobOptions { Budget = { ["cost"] = -1 } }, "budget.cost");
        await Refused(cw, new JobOptions { Grace = double.NaN }, "grace");
        await Refused(cw, new JobOptions { Timeout = 0 }, "timeout");
        await Refused(cw, new JobOptions { MaxDuration = "0s" }, "maxDuration");
        await Refused(cw, new JobOptions { Schedule = "0 2 * * *", Timezone = "Mars/Olympus" }, "timezone");
        await using (var withDefaults = new CronwatchClient(new CronwatchOptions
        {
            Defaults = new JobOptions().Field("failuresBeforeAlert", double.NaN),
            ProcessExitHook = false,
        }))
        {
            Assert.Contains("failuresBeforeAlert", Assert.Throws<CronwatchException>(() => withDefaults.Job("a")).Message, StringComparison.Ordinal);
        }
        Assert.Equal(
            "defaults takes grace, timeout, timezone, and failuresBeforeAlert, not schedule",
            Assert.Throws<CronwatchException>(() => new CronwatchClient(new CronwatchOptions { Defaults = new JobOptions { Schedule = "@hourly" } })).Message);
        Assert.Equal(
            "defaults takes grace, timeout, timezone, and failuresBeforeAlert, not schedule",
            Assert.Throws<CronwatchException>(() => new CronwatchClient(new CronwatchOptions { Defaults = new JobOptions().Field("schedule", "@hourly") })).Message);
        cw.Job("a", new JobOptions { Budget = { ["errors"] = 0 }, FailuresBeforeAlert = 2, Timeout = "5m" });
    }

    [Fact]
    public async Task A_returned_string_is_capped_like_logged_output()
    {
        await using var m = Make();
        await m.Cw.RunAsync("big", (j, ct) => Task.FromResult(new string('x', 40_000)));
        string output = (await m.Cw.RunsAsync("big", 1))[0].Output!;
        Assert.True(output.Length < 17 * 1024);
        Assert.StartsWith("[earlier output trimmed]", output, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Runs_takes_a_whole_number_of_runs_in_range()
    {
        await using var m = Make();
        for (int i = 0; i < 3; i++)
        {
            await Ok(m.Cw, "n");
        }
        Assert.Equal(2, (await m.Cw.RunsAsync("n", 2)).Count);
        Assert.Single(await m.Cw.RunsAsync("n", -4));
        Assert.Equal(3, (await m.Cw.RunsAsync("n", 50)).Count);
        var entry = (await m.Cw.JobsWithRunsAsync(2))[0];
        Assert.Equal(2, entry.Runs.Count);
        Assert.Equal(entry.Job.LastRun!.Id, entry.Runs[0].Id);
        Assert.Empty((await m.Cw.JobsWithRunsAsync(-1))[0].Runs);
    }

    [Fact]
    public async Task An_error_whose_text_already_names_it_is_not_labelled_twice()
    {
        await using var m = Make();
        await Assert.ThrowsAsync<IOException>(() => m.Cw.RunAsync("db", (j, ct) => throw new IOException("connect ECONNREFUSED 10.0.0.12:5432")));
        Assert.StartsWith("IOException: connect ECONNREFUSED 10.0.0.12:5432\n    at ", (await m.Cw.RunsAsync("db", 1))[0].Error, StringComparison.Ordinal);
        string message = m.Alerts.List()[0].Message;
        Assert.DoesNotContain("Error: IOException", message, StringComparison.Ordinal);
        Assert.Contains(message.Split('\n'), l => l.StartsWith("IOException: connect ECONNREFUSED", StringComparison.Ordinal));
        await Fail(m.Cw, "db", "two\nlines");
        Assert.StartsWith("InvalidOperationException: two\nlines\n    at ", (await m.Cw.RunsAsync("db", 1))[0].Error, StringComparison.Ordinal);
    }

    [Fact]
    public async Task The_baseline_reads_past_recent_failures_to_twenty_successful_runs()
    {
        await using var m = Make();
        var job = m.Cw.Job("base");
        var plan = new List<(long Ms, bool Fails)>();
        plan.AddRange(Enumerable.Repeat((100_000L, false), 5));
        plan.AddRange(Enumerable.Repeat((1_000L, false), 15));
        plan.AddRange(Enumerable.Repeat((1_000L, true), 10));
        // Fifteen 1s runs alone would make 10s the limit; with the five 100s runs, p95 is 100s.
        plan.Add((30_000L, false));
        foreach (var (ms, fails) in plan)
        {
            await Quietly(() => job.RunAsync((j, ct) =>
            {
                m.Clock.Advance(ms);
                return fails ? throw new InvalidOperationException("x") : Task.CompletedTask;
            }));
            m.Clock.Advance(Min);
        }
        Assert.Equal(["failed", "recovered"], m.Alerts.Types());
    }

    /// <summary>A failure queued by a process that delivers at check, for a check elsewhere to send.</summary>
    private static async Task Queued(IStore store, Microsoft.Extensions.Time.Testing.FakeTimeProvider clock, string name)
    {
        await using var recorder = Make(store: store, clock: clock, deliver: Deliver.AtCheck);
        await Fail(recorder.Cw, name, "disk full");
    }

    [Fact]
    public async Task A_diagnosis_made_on_a_retry_is_kept_with_the_queued_alert_and_triage_runs_once_per_alert()
    {
        var clock = Clock();
        var store = new MemoryStore();
        await Queued(store, clock, "backup");
        int asked = 0;
        bool down = true;
        var sent = new ConcurrentQueue<Alert>();
        var flaky = Throwing("flaky", () => Volatile.Read(ref down), sent.Enqueue);
        await using var server = MakeOnly(flaky, store: store, clock: clock, triage: new FuncTriage(_ =>
        {
            Interlocked.Increment(ref asked);
            return Task.FromResult<string?>("The disk is full.");
        }));
        await server.Cw.CheckAsync();
        Assert.Equal(1, asked);
        Assert.Equal("The disk is full.", (await State(server, "backup")).Undelivered![0].Triage);
        await server.Cw.CheckAsync();
        await server.Cw.CheckAsync();
        Assert.Equal(1, asked);
        Volatile.Write(ref down, false);
        await server.Cw.CheckAsync();
        var alert = Assert.Single(sent);
        Assert.Equal(AlertType.Failed, alert.Type);
        Assert.Equal("The disk is full.", alert.Triage);
    }

    [Fact]
    public async Task A_triage_that_throws_or_answers_nothing_is_tried_once_recorded_as_null()
    {
        Func<TriageContext, Task<string?>>[] answers =
        [
            _ => throw new IOException("api down"),
            _ => Task.FromResult<string?>(""),
            _ => Task.FromResult<string?>(null),
        ];
        foreach (var answer in answers)
        {
            var clock = Clock();
            var store = new MemoryStore();
            await Queued(store, clock, "backup");
            int asked = 0;
            await using var server = MakeOnly(Throwing("down", () => true), store: store, clock: clock, triage: new FuncTriage(ctx =>
            {
                Interlocked.Increment(ref asked);
                return answer(ctx);
            }));
            for (int i = 0; i < 3; i++)
            {
                await server.Cw.CheckAsync();
            }
            Assert.Equal(1, asked);
            var queued = (await State(server, "backup")).Undelivered![0];
            Assert.Null(queued.Triage);
            Assert.True(queued.TriageTried);
            Assert.Contains("\"triage\":null", queued.ToJson(), StringComparison.Ordinal);
        }
    }

    [Fact]
    public async Task Retries_stop_once_a_check_has_spent_its_budget_and_the_rest_wait()
    {
        var clock = Clock();
        var store = new MemoryStore();
        foreach (string name in new[] { "a", "b", "c" })
        {
            await Queued(store, clock, name);
        }
        var tried = new ConcurrentQueue<string>();
        // Each attempt takes a second of the client's clock and fails; the budget covers two.
        var slow = CustomChannel.Create("slow", (a, ctx, ct) =>
        {
            tried.Enqueue(a.Job);
            clock.Advance(TimeSpan.FromSeconds(1));
            throw new IOException("timed out");
        });
        await using var server = MakeOnly(slow, store: store, clock: clock, timings: new Timings { RetryBudget = TimeSpan.FromMilliseconds(1500) });
        await server.Cw.CheckAsync();
        Assert.Equal(["a", "b"], tried.ToList());
        Assert.Single((await State(server, "c")).Undelivered!);
        tried.Clear();
        await server.Cw.CheckAsync();
        Assert.Equal(["a", "b"], tried.ToList());
    }

    [Fact]
    public async Task An_alert_whose_condition_closed_is_dropped_and_a_recovery_whose_conditions_stay_closed_is_sent()
    {
        bool down = true;
        var sent = new ConcurrentQueue<string>();
        await using var m = MakeOnly(Throwing("flaky", () => Volatile.Read(ref down), a => sent.Enqueue(a.Type.Value + "@" + a.At)));
        await Fail(m.Cw, "s");
        m.Clock.Advance(Min);
        await Ok(m.Cw, "s");
        Assert.Equal(["failed", "recovered"], await QueuedTypes(m, "s"));
        Volatile.Write(ref down, false);
        m.Clock.Advance(Min);
        await m.Cw.CheckAsync();
        Assert.Equal(["recovered@" + (T0 + Min)], sent.ToList());
        Assert.Empty((await State(m, "s")).Undelivered!);
    }

    [Fact]
    public async Task An_alert_whose_condition_opened_again_is_dropped_and_so_is_a_recovery_it_undoes()
    {
        bool down = true;
        var sent = new ConcurrentQueue<string>();
        await using var m = MakeOnly(Throwing("flaky", () => Volatile.Read(ref down), a => sent.Enqueue(a.Type.Value + "@" + a.At)));
        await Fail(m.Cw, "s");
        m.Clock.Advance(Min);
        await Ok(m.Cw, "s");
        m.Clock.Advance(Min);
        await Fail(m.Cw, "s", "again");
        Assert.Equal(["failed", "recovered", "failed"], await QueuedTypes(m, "s"));
        Volatile.Write(ref down, false);
        m.Clock.Advance(Min);
        await m.Cw.CheckAsync();
        Assert.Equal(["failed@" + (T0 + 2 * Min)], sent.ToList());
    }

    [Fact]
    public async Task A_job_that_cannot_be_evaluated_is_reported_and_shown_as_failing_and_the_others_are_checked()
    {
        await using var m = Make();
        m.Cw.Job("good", new JobOptions { Schedule = "every 1h" });
        await Ok(m.Cw, "good");
        await m.Store.UpsertJobAsync(Definition.Of(new JsObject().Set("name", "bad").Set("schedule", "not a schedule")), T0);
        await m.Store.UpsertJobAsync(Definition.Of(new JsObject().Set("name", "odd").Set("timeout", "soon")), T0);
        await m.Store.InsertRunAsync(Run.Running("hung", "odd", T0, "run"));
        m.Clock.Advance(2 * Hour);
        var result = await m.Cw.CheckAsync();
        Assert.Equal(["good:missed"], result.Alerts.Select(a => a.Job + ":" + a.Type.Value));
        Assert.Equal(
            ["bad failing", "good late", "odd failing"],
            result.Jobs.Select(j => j.Name + " " + j.Health.Value).OrderBy(x => x, StringComparer.Ordinal));
        Assert.Equal(["checking odd", "checking bad", "checking odd"], m.Errors.Wheres());
        Assert.Equal(["missed"], m.Alerts.Types());
        m.Errors.Entries.Clear();
        Assert.Equal(
            ["bad failing True", "good late False", "odd failing True"],
            (await m.Cw.JobsAsync()).Select(j => j.Name + " " + j.Health.Value + " " + (j.NextExpectedAt == null)));
        Assert.Equal(["reading bad", "reading odd"], m.Errors.Wheres());
        Assert.Equal(JobHealth.Failing, (await m.Cw.JobSummaryAsync("bad"))!.Health);
        await m.Cw.SilenceAsync("bad", "1h");
        Assert.Equal(JobHealth.Silenced, (await m.Cw.JobSummaryAsync("bad"))!.Health);
    }

    [Fact]
    public async Task Trimming_the_undelivered_queue_past_twenty_is_reported()
    {
        await using var m = Make(deliver: Deliver.AtCheck);
        for (int i = 0; i < 10; i++)
        {
            await Fail(m.Cw, "q");
            await Ok(m.Cw, "q");
        }
        Assert.Equal(20, (await State(m, "q")).Undelivered!.Count);
        Assert.Empty(m.Errors.Wheres());
        await Fail(m.Cw, "q");
        Assert.Equal(20, (await State(m, "q")).Undelivered!.Count);
        Assert.Equal(["alert queue for q"], m.Errors.Wheres());
    }

    [Fact]
    public async Task Start_with_deliver_at_check_says_once_that_another_process_must_send()
    {
        var warnings = new ConcurrentQueue<string>();
        await using var deferred = new CronwatchClient(new CronwatchOptions
        {
            Deliver = Deliver.AtCheck,
            OnWarning = warnings.Enqueue,
            ProcessExitHook = false,
            Clock = Clock(),
        });
        await using var delivering = new CronwatchClient(new CronwatchOptions
        {
            OnWarning = warnings.Enqueue,
            ProcessExitHook = false,
            Clock = Clock(),
        });
        deferred.StartChecking();
        deferred.Stop();
        deferred.StartChecking();
        deferred.Stop();
        string warning = Assert.Single(warnings);
        Assert.Equal(
            "[cronwatch] StartChecking() was called with Deliver.AtCheck, so these checks send no alerts. Another process must run checks with Deliver.Now (the default) to send them.",
            warning);
        delivering.StartChecking();
        delivering.Stop();
        Assert.Single(warnings);
    }

    [Fact]
    public async Task A_long_timeout_does_not_cancel_the_job_at_once()
    {
        await using var m = Make();
        var job = m.Cw.Job("monthly", new JobOptions { Timeout = "30d" });
        bool cancelled = await job.RunAsync(async (j, ct) =>
        {
            await Task.Delay(20, CancellationToken.None);
            return ct.IsCancellationRequested;
        });
        Assert.False(cancelled);
    }

    [Fact]
    public async Task A_timeout_past_what_a_timer_holds_does_not_cancel_the_job()
    {
        await using var m = Make();
        var job = m.Cw.Job("century", new JobOptions { Timeout = TimeSpan.FromDays(36_500) });
        Assert.False(await job.RunAsync((j, ct) => Task.FromResult(ct.IsCancellationRequested)));
    }

    [Fact]
    public async Task Start_checks_after_a_second_then_on_the_interval_and_stop_ends_it()
    {
        var counter = new CountingSource();
        await using var m = Make(sources: [counter]);
        m.Cw.StartChecking(TimeSpan.FromMinutes(1));
        m.Cw.StartChecking("5s"); // a second start does nothing
        m.Clock.Advance(999);
        await Task.Delay(20);
        Assert.Equal(0, counter.Syncs);
        m.Clock.Advance(1);
        await Eventually("the first check", () => counter.Syncs == 1 && !m.Cw.Checking);
        m.Clock.Advance(30_000);
        await Task.Delay(20);
        Assert.Equal(1, counter.Syncs);
        m.Clock.Advance(30_000);
        await Eventually("the check on the interval", () => counter.Syncs == 2);
        m.Cw.Stop();
        m.Clock.Advance(10 * Min);
        await Task.Delay(50);
        Assert.Equal(2, counter.Syncs);
    }

    [Fact]
    public async Task Start_is_StartChecking_under_its_former_name()
    {
        var counter = new CountingSource();
        await using var m = Make(sources: [counter]);
#pragma warning disable CS0618 // the deprecated name, kept through 1.x
        m.Cw.Start("5s");
        m.Cw.StartChecking("1m"); // a second start, under either name, does nothing
#pragma warning restore CS0618
        m.Clock.Advance(1000);
        await Eventually("the first check", () => counter.Syncs == 1 && !m.Cw.Checking);
        m.Clock.Advance(5000);
        await Eventually("the check on the interval Start gave", () => counter.Syncs == 2);
        m.Cw.Stop();
    }

    [Fact]
    public async Task Start_again_after_stop_checks_and_a_long_interval_does_not_check_every_millisecond()
    {
        var counter = new CountingSource();
        await using var m = Make(sources: [counter]);
        m.Cw.StartChecking("30d");
        m.Clock.Advance(1000);
        await Eventually("the first check", () => counter.Syncs == 1 && !m.Cw.Checking);
        m.Clock.Advance(Hour);
        await Task.Delay(50);
        Assert.Equal(1, counter.Syncs);
        m.Cw.Stop();
        m.Cw.StartChecking();
        m.Clock.Advance(1000);
        await Eventually("the first check after starting again", () => counter.Syncs == 2 && !m.Cw.Checking);
    }

    [Fact]
    public async Task Start_holds_its_interval_at_the_sdks_longest()
    {
        var counter = new CountingSource();
        await using var m = Make(sources: [counter]);
        m.Cw.StartChecking(TimeSpan.FromDays(100_000));
        m.Clock.Advance(1000);
        await Eventually("the first check", () => counter.Syncs == 1 && !m.Cw.Checking);
        m.Clock.Advance(CronwatchClient.TimerMaxMs);
        await Eventually("the check at 2^31 - 1 ms", () => counter.Syncs == 2);
    }

    [Fact]
    public async Task A_long_check_is_not_followed_by_the_ticks_it_missed()
    {
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var counter = new CountingSource { Hold = release.Task };
        await using var m = Make(sources: [counter]);
        m.Cw.StartChecking("5s");
        m.Clock.Advance(1000);
        await counter.Entered.Task;
        // The first check waits on the source through several ticks, which share it.
        for (int i = 0; i < 6; i++)
        {
            m.Clock.Advance(5000);
        }
        await Task.Delay(50);
        Assert.Equal(1, counter.Syncs);
        counter.Hold = null;
        release.SetResult();
        await Eventually("the held check to finish", () => !m.Cw.Checking);
        await Task.Delay(50);
        Assert.True(counter.Syncs == 1, "no burst of the ticks it missed: " + counter.Syncs);
        m.Clock.Advance(5000);
        await Eventually("the next tick on the interval", () => counter.Syncs == 2);
    }

    [Fact]
    public async Task A_foreign_rows_far_times_do_not_fail_the_check()
    {
        await using var m = Make();
        await m.Cw.Job("far", new JobOptions { Schedule = "every 5m" }).RunAsync((j, ct) => Task.CompletedTask);
        await Ok(m.Cw, "old");
        var far = (await m.Cw.RunsAsync("far", 1))[0];
        await m.Store.InsertRunAsync(far with { Id = "far-future", StartedAt = long.MaxValue - 1 });
        await m.Store.InsertRunAsync(Run.Running("long-ago", "old", long.MinValue + 1, "run"));
        var result = await m.Cw.CheckAsync();
        Assert.Equal(2, result.Jobs.Count);
        Assert.Equal(["stuck"], m.Alerts.Types());
        Assert.Contains("before 0001-01-01 00:00:00 UTC", m.Alerts.List()[0].Message, StringComparison.Ordinal);
        var marked = m.Alerts.List()[0].Run!;
        Assert.Equal(RunStatus.Timeout, marked.Status);
        Assert.Equal(9_007_199_254_740_991L, marked.DurationMs);
        Assert.Equal(2, (await m.Cw.JobsAsync()).Count);
        Assert.Empty(m.Errors.Wheres());
    }

    [Fact]
    public async Task Every_channel_given_is_kept()
    {
        var seen = new ConcurrentQueue<string>();
        await using var cw = new CronwatchClient(new CronwatchOptions
        {
            Alerts =
            {
                CustomChannel.Create("console", (a, ctx, ct) =>
                {
                    seen.Enqueue("console");
                    return Task.CompletedTask;
                }),
                CustomChannel.Create("second", (a, ctx, ct) =>
                {
                    seen.Enqueue("second");
                    return Task.CompletedTask;
                }),
            },
            ProcessExitHook = false,
            OnWarning = _ => { },
        });
        await Fail(cw, "two", "down");
        Assert.Equal(["console", "second"], seen.OrderBy(x => x, StringComparer.Ordinal));
    }

    [Fact]
    public async Task An_empty_list_of_channels_sends_nowhere()
    {
        await using var cw = new CronwatchClient(new CronwatchOptions { Alerts = [], ProcessExitHook = false, OnWarning = _ => { } });
        await Fail(cw, "quiet");
        Assert.Empty((await cw.Store.GetStateAsync("quiet"))!.Undelivered!);
    }
}
