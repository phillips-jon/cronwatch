using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch.Internal;

namespace Cronwatch;

/// <summary>Checks, the reads the dashboard makes, silences and the interval.</summary>
public sealed partial class CronwatchClient
{
    private const long PruneIntervalMs = 60 * 60_000;

    /// <summary>The longest interval a timer of the SDK's holds: 2^31 - 1 ms.</summary>
    internal const long TimerMaxMs = (1L << 31) - 1;

    private TaskCompletionSource<CheckResult>? _checking;

    /// <summary>Whether a check is in flight, for the tests.</summary>
    internal bool Checking => Volatile.Read(ref _checking) != null;
    private long _lastPruneAt;
    private readonly Lock _intervalLock = new();
    private ITimer? _interval;
    private bool _warnedDeferredStart;

    /// <summary>
    /// Joins the check in flight or starts one; every caller waiting gets the same answer. The
    /// check in flight is let go of before its callers are answered, so a caller that asks again
    /// once answered starts a check of its own. A caller's token ends its own wait only.
    /// </summary>
    private Task<CheckResult> SharedCheckAsync(CancellationToken cancellationToken)
    {
        var mine = new TaskCompletionSource<CheckResult>(TaskCreationOptions.RunContinuationsAsynchronously);
        var shared = Interlocked.CompareExchange(ref _checking, mine, null);
        if (shared == null)
        {
            shared = mine;
            _ = Spawn(async () =>
            {
                try
                {
                    CheckResult result = await RunCheckAsync().ConfigureAwait(false);
                    Interlocked.CompareExchange(ref _checking, null, mine);
                    mine.SetResult(result);
                }
                catch (Exception e)
                {
                    Interlocked.CompareExchange(ref _checking, null, mine);
                    mine.SetException(e is CronwatchException ? e : new CronwatchException("the check failed: " + OutputText.ErrorName(e) + ": " + OutputText.MessageOf(e), e));
                }
            });
        }
        return shared.Task.WaitAsync(cancellationToken);
    }

    private async Task<CheckResult> RunCheckAsync()
    {
        Activity? activity = CronwatchTelemetry.StartActivity("cronwatch.check");
        try
        {
            return await CheckNowAsync().ConfigureAwait(false);
        }
        finally
        {
            CronwatchTelemetry.StopActivity(activity);
        }
    }

    private async Task<CheckResult> CheckNowAsync()
    {
        CronwatchTelemetry.Add(CronwatchTelemetry.Checks);
        await EnsureReadyAsync().ConfigureAwait(false);
        var alerts = new List<Alert>();
        foreach (ISource source in _sources)
        {
            try
            {
                var found = await source.SyncAsync(this, _closing.Token).ConfigureAwait(false);
                if (found != null)
                {
                    alerts.AddRange(found);
                }
            }
            catch (Exception e)
            {
                Report(e, "source " + source.Name);
            }
        }
        foreach (JobDef def in DeclaredAll())
        {
            await SyncAsync(def).ConfigureAwait(false);
        }
        long now = Now();

        // Runs that never reported back. One that cannot be judged (its job's stored timeout no
        // longer parses, say) is reported and skipped.
        foreach (Run run in await CallAsync(() => _store.RunningRunsAsync()).ConfigureAwait(false))
        {
            try
            {
                alerts.AddRange(await CheckRunningAsync(run, now).ConfigureAwait(false));
            }
            catch (Exception e)
            {
                Report(e, "checking " + run.Job);
            }
        }

        // Each job on its own: one that cannot be evaluated is reported, shown as failing and does
        // not stop the others.
        var jobs = new List<JobSummary>();
        var budget = new RetryBudget();
        foreach (StoredJob job in await CallAsync(() => _store.ListJobsAsync()).ConfigureAwait(false))
        {
            try
            {
                jobs.Add(await CheckJobAsync(job, now, budget, alerts).ConfigureAwait(false));
            }
            catch (Exception e)
            {
                Report(e, "checking " + job.Name);
                jobs.Add(await UnevaluableAsync(job, now).ConfigureAwait(false));
            }
        }

        long pruned = 0;
        if (now - Interlocked.Read(ref _lastPruneAt) > PruneIntervalMs)
        {
            Interlocked.Exchange(ref _lastPruneAt, now);
            try
            {
                long before = Js.ToLong(now - _retentionMs);
                pruned = await CallAsync(() => _store.PruneAsync(before)).ConfigureAwait(false);
            }
            catch (Exception e)
            {
                Report(e, "pruning");
            }
        }
        return new CheckResult(now, ValueList<JobSummary>.Of(jobs), ValueList<Alert>.Of(alerts), pruned);
    }

    private async Task<IReadOnlyList<Alert>> CheckRunningAsync(Run run, long now)
    {
        JobDef? declared = Declared(run.Job);
        Definition def;
        if (declared != null)
        {
            def = declared.Stored;
        }
        else
        {
            StoredJob? stored = await CallAsync(() => _store.GetJobAsync(run.Job)).ConfigureAwait(false);
            if (stored == null)
            {
                return [];
            }
            def = stored.Definition;
        }
        if (!Evaluated(() => Evaluate.IsStuck(def, run, now)))
        {
            return [];
        }
        Run marked = run with
        {
            Status = RunStatus.Timeout,
            FinishedAt = now,
            DurationMs = Evaluate.RunDuration(run.StartedAt, now),
            Error = TimeoutText(def),
        };
        // Only over a row still running: a finish that landed meanwhile wins.
        if (await WriteRunIfAsync(marked, OnlyRunning).ConfigureAwait(false))
        {
            return await FinishRunAsync(def, marked, now).ConfigureAwait(false);
        }
        return [];
    }

    private async Task<JobSummary> CheckJobAsync(StoredJob job, long now, RetryBudget budget, List<Alert> alerts)
    {
        var recent = await CallAsync(() => _store.ListRunsAsync(job.Name, Evaluate.BaselineWindow)).ConfigureAwait(false);
        Run? last = recent.Count == 0 ? null : recent[0];
        long? nextExpectedAt = null;
        var (state, drafts) = await UpdateStateAsync(job.Name, previous =>
        {
            CheckOutcome o = Evaluate.OnCheck(job.Definition, job, last, previous, now);
            nextExpectedAt = o.NextExpectedAt;
            var settled = Evaluate.ApplySilence(previous, o.Evaluation, now);
            return (settled.State, settled.Alerts);
        }).ConfigureAwait(false);
        alerts.AddRange(await RetryUndeliveredAsync(job.Name, state, now, budget).ConfigureAwait(false));
        alerts.AddRange(await DispatchAsync(drafts, job.Definition, now).ConfigureAwait(false));
        return Evaluated(() => Evaluate.Summarize(job, recent, state, nextExpectedAt, now));
    }

    private async Task<JobWithRuns> SnapshotAsync(StoredJob job, long now, int limit)
    {
        IReadOnlyList<Run> recent = [];
        try
        {
            recent = await CallAsync(() => _store.ListRunsAsync(job.Name, Math.Max(limit, Evaluate.BaselineWindow))).ConfigureAwait(false);
            JobState state = await ReadStateAsync(job.Name).ConfigureAwait(false);
            var runs = recent;
            JobSummary summary = Evaluated(() =>
            {
                CheckOutcome o = Evaluate.OnCheck(job.Definition, job, runs.Count == 0 ? null : runs[0], state, now);
                return Evaluate.Summarize(job, runs, state, o.NextExpectedAt, now);
            });
            return new JobWithRuns(summary, First(recent, limit));
        }
        catch (Exception e)
        {
            Report(e, "reading " + job.Name);
            return new JobWithRuns(await UnevaluableAsync(job, now).ConfigureAwait(false), First(recent, limit));
        }
    }

    private static ValueList<Run> First(IReadOnlyList<Run> runs, int n)
    {
        var output = new List<Run>();
        for (int i = 0; i < runs.Count && i < n; i++)
        {
            output.Add(runs[i]);
        }
        return ValueList<Run>.Of(output);
    }

    private async Task<JobSummary> UnevaluableAsync(StoredJob job, long now)
    {
        IReadOnlyList<Run> recent;
        try
        {
            recent = await CallAsync(() => _store.ListRunsAsync(job.Name, Evaluate.BaselineWindow)).ConfigureAwait(false);
        }
        catch (Exception)
        {
            recent = [];
        }
        JobState state;
        try
        {
            state = await ReadStateAsync(job.Name).ConfigureAwait(false);
        }
        catch (Exception)
        {
            state = Evaluate.EmptyState(job.Name);
        }
        return Evaluated(() => Evaluate.UnevaluableSummary(job, recent, state, now));
    }

    internal static int ClampLimit(int limit, int min) => Math.Min(500, Math.Max(min, limit));

    private async Task<IReadOnlyList<JobWithRuns>> JobsWithRunsNowAsync(int limit)
    {
        await EnsureReadyAsync().ConfigureAwait(false);
        foreach (JobDef def in DeclaredAll())
        {
            await SyncAsync(def).ConfigureAwait(false);
        }
        long now = Now();
        var output = new List<JobWithRuns>();
        foreach (StoredJob job in await CallAsync(() => _store.ListJobsAsync()).ConfigureAwait(false))
        {
            output.Add(await SnapshotAsync(job, now, ClampLimit(limit, 0)).ConfigureAwait(false));
        }
        return output;
    }

    private async Task<JobSummary?> JobSummaryNowAsync(string name)
    {
        await EnsureReadyAsync().ConfigureAwait(false);
        JobDef? def = Declared(name);
        if (def != null)
        {
            await SyncAsync(def).ConfigureAwait(false);
        }
        StoredJob? stored = await CallAsync(() => _store.GetJobAsync(name)).ConfigureAwait(false);
        return stored == null ? null : (await SnapshotAsync(stored, Now(), 0).ConfigureAwait(false)).Job;
    }

    private static long SaturatingAdd(long a, long b)
    {
        long r = unchecked(a + b);
        return ((a ^ r) & (b ^ r)) < 0 ? (a < 0 ? long.MinValue : long.MaxValue) : r;
    }

    private async Task<JobState> PatchStateAsync(string name, Action<MutableState> change)
    {
        await EnsureReadyAsync().ConfigureAwait(false);
        var (state, _) = await UpdateStateAsync(name, current =>
        {
            var next = MutableState.Of(Evaluate.NormalizeState(current, name));
            change(next);
            return (next.ToState(), true);
        }).ConfigureAwait(false);
        return state;
    }

    private Task<JobState> SilenceMsAsync(string name, double ms)
    {
        long now = Now();
        long until = SaturatingAdd(now, Js.ToLong(Math.Min(ms, Evaluate.MaxDurationMs)));
        return PatchStateAsync(name, s => s.SilencedUntil = until);
    }

    private async Task ForgetNowAsync(string name)
    {
        await EnsureReadyAsync().ConfigureAwait(false);
        Undeclare(name);
        await CallAsync(() => _store.DeleteJobAsync(name)).ConfigureAwait(false);
    }

    private void StartInterval(double everyMs)
    {
        lock (_intervalLock)
        {
            if (_interval != null || _closing.IsCancellationRequested)
            {
                return;
            }
            long ms = Js.ToLong(Math.Min(TimerMaxMs, Math.Max(Timings.MinInterval.TotalMilliseconds, everyMs)));
            if (_deferDelivery && !_warnedDeferredStart)
            {
                _warnedDeferredStart = true;
                Warn("[cronwatch] Start() was called with Deliver.AtCheck, so these checks send no alerts. Another process must run checks with Deliver.Now (the default) to send them.");
            }
            // Each tick asks for a check without waiting on it, as setInterval does: a tick while a
            // long check runs shares that check.
            _interval = WithoutFlow(() => _time.CreateTimer(
                static state =>
                {
                    var self = (CronwatchClient)state!;
                    _ = self.SharedCheckAsync(CancellationToken.None).ContinueWith(
                        t => self.Report(t.Exception!.GetBaseException(), "check"),
                        CancellationToken.None,
                        TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously,
                        TaskScheduler.Default);
                },
                this,
                Timings.FirstCheck,
                TimeSpan.FromMilliseconds(ms)));
        }
    }

    private void StopInterval()
    {
        ITimer? timer;
        lock (_intervalLock)
        {
            timer = _interval;
            _interval = null;
        }
        timer?.Dispose();
    }
}
