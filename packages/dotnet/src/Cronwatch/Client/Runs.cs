using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch.Internal;

namespace Cronwatch;

/// <summary>Runs: a function run in the caller's flow, recorded by the client's own tasks.</summary>
public sealed partial class CronwatchClient
{
    private static readonly int HistoryPage = Evaluate.BaselineWindow + 5;
    private const int HistoryMax = 200;
    private static readonly RunStatus[] OnlyRunning = [RunStatus.Running];
    private static readonly RunStatus[] OnlyTimeout = [RunStatus.Timeout];

    internal const string ShutdownError = "Shutdown: the process stopped while the run was in progress";

    /// <summary>Runs open in this process, for the process-exit hook.</summary>
    private readonly ConcurrentDictionary<string, OpenRun> _open = new(StringComparer.Ordinal);

    internal sealed class OpenRun(JobDef def, Run run, Recorder recorder, bool recorded)
    {
        public JobDef Def { get; } = def;

        public Run Run { get; } = run;

        public Recorder Recorder { get; } = recorder;

        public bool Recorded { get; } = recorded;

        public Task<Run>? Recording { get; set; }
    }

    /// <summary>A run opened by <see cref="OpenAsync"/>: its function running until it is closed.</summary>
    internal sealed class Opened
    {
        private readonly Lock _lock = new();
        private bool _closed;
        private bool _inFunction = true;

        public required JobDef Def { get; init; }

        public required RunOptions Options { get; init; }

        public required Run Run { get; init; }

        public required bool Recorded { get; init; }

        public required Task? Closing { get; init; }

        public required Recorder Recorder { get; init; }

        public required JobContext Context { get; init; }

        public required CancellationTokenSource Timeout { get; init; }

        public required CancellationTokenSource Linked { get; init; }

        public required OpenRun Open { get; init; }

        public bool Claim()
        {
            lock (_lock)
            {
                if (_closed)
                {
                    return false;
                }
                _closed = true;
                return true;
            }
        }

        public bool IsClosed
        {
            get
            {
                lock (_lock)
                {
                    return _closed;
                }
            }
        }

        public void EndFunction()
        {
            lock (_lock)
            {
                if (!_inFunction)
                {
                    return;
                }
                _inFunction = false;
            }
            Linked.Dispose();
            Timeout.Dispose();
        }
    }

    private static double TimeoutOrDefault(Definition def)
    {
        try
        {
            return Evaluate.TimeoutMs(def);
        }
        catch (Exception)
        {
            return Evaluate.DefaultTimeoutMs;
        }
    }

    internal static string TimeoutText(Definition def) =>
        "Still running after " + Durations.Format(TimeoutOrDefault(def)) + "; marked as timed out";

    internal static string ErrorText(Exception e)
    {
        try
        {
            return OutputText.ErrorMessage(e);
        }
        catch (Exception)
        {
            // An exception whose message or trace cannot be read must not leave its run running.
            return OutputText.ErrorMessage(OutputText.ErrorName(e), "", []);
        }
    }

    internal static void CheckRunId(string job, string id, string method)
    {
        if (id.Length == 0 || id.Length > 200)
        {
            throw CronwatchException.Invalid(
                "job " + Json.Quote(job) + ": " + method + "() needs a run id of 1 to 200 characters (got " + id.Length + " characters)");
        }
        // Postgres refuses NUL in text, so no store could hold such an id.
        if (id.Contains('\0', StringComparison.Ordinal))
        {
            throw CronwatchException.Invalid("job " + Json.Quote(job) + ": " + method + "() cannot take a run id containing a NUL character");
        }
        if (id.StartsWith(ReservedRunIdPrefix, StringComparison.Ordinal))
        {
            throw CronwatchException.Invalid(
                "job " + Json.Quote(job) + ": " + method + "() cannot take a run id starting with " + Json.Quote(ReservedRunIdPrefix)
                + ", which the pg_cron source uses for its runs");
        }
    }

    /// <summary>
    /// Runs <paramref name="fn"/> in the caller's flow as a recorded run, and answers what it
    /// answered, or throws what it threw, unchanged, once the run is recorded.
    /// </summary>
    internal async Task<T> ExecuteAsync<T>(JobDef def, RunOptions options, Func<JobContext, CancellationToken, Task<T>> fn, CancellationToken cancellationToken)
    {
        Opened o = await OpenAsync(def, options, cancellationToken).ConfigureAwait(false);
        // Set in this async method, so it flows into everything the function awaits and starts,
        // and is gone when this method returns: its caller's context is restored.
        CurrentRun.Set(o.Context);
        using Activity? activity = CronwatchTelemetry.Source.StartActivity("cronwatch.run");
        activity?.SetTag("cronwatch.job", def.Name);
        activity?.SetTag("cronwatch.run_id", o.Run.Id);
        activity?.SetTag("cronwatch.trigger", options.Trigger);
        IDisposable? scope = OpenRunScope(o.Context);
        T value = default!;
        Exception? thrown = null;
        try
        {
            value = await fn(o.Context, o.Context.CancellationToken).ConfigureAwait(false);
        }
        catch (Exception e)
        {
            thrown = e;
        }
        finally
        {
            CloseRunScope(scope, def.Name);
            o.EndFunction();
        }
        Run finished = await CloseAsync(o, value, thrown, cancellationToken).ConfigureAwait(false);
        activity?.SetTag("cronwatch.status", finished.Status.Value);
        if (thrown != null)
        {
            System.Runtime.ExceptionServices.ExceptionDispatchInfo.Throw(thrown);
        }
        return value;
    }

    /// <summary>A run opened from outside its function, with its activity: <see cref="Job.OpenAsync"/>.</summary>
    internal async Task<ObservedRun> OpenObservedAsync(JobDef def, RunOptions options, CancellationToken cancellationToken)
    {
        // Started here, so its parent is the caller's activity; this method's end puts the
        // caller's back as current, and the run's own is made current by MakeCurrent.
        Activity? activity = CronwatchTelemetry.Source.StartActivity("cronwatch.run");
        try
        {
            activity?.SetTag("cronwatch.job", def.Name);
            activity?.SetTag("cronwatch.trigger", options.Trigger);
            Opened o = await OpenAsync(def, options, cancellationToken).ConfigureAwait(false);
            activity?.SetTag("cronwatch.run_id", o.Run.Id);
            return new ObservedRun(this, o, activity);
        }
        catch (Exception)
        {
            activity?.Dispose();
            throw;
        }
    }

    /// <summary>Opens a run: the running row written by the client's own task, the timeout armed.</summary>
    internal async Task<Opened> OpenAsync(JobDef def, RunOptions options, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(options);
        if (options.Id != null)
        {
            CheckRunId(def.Name, options.Id, "run");
        }
        long startedAt = Now();
        Run run = Run.Running(options.Id ?? Guid.NewGuid().ToString(), def.Name, startedAt, options.Trigger ?? "run");
        // The start is written by the client's own task: a caller that stops waiting cannot cut it.
        bool recorded = await Spawn(() => BeginRunAsync(def, run)).ConfigureAwait(false);
        // Closing missed and stuck happens beside the job, which never waits on it. A run that may
        // be given back closes them only once it is known not to be.
        Task? closing = recorded && !options.TakesBack ? Spawn(() => CloseOnStartAsync(def.Name)) : null;

        var recorder = new Recorder();
        double timeout = TimeoutOrDefault(def.Stored);
        double delay = Math.Min(Math.Max(0, timeout), Evaluate.MaxDurationMs);
        // A timer holds at most 2^32 - 2 ms (some 49 days); a longer timeout never fires in a
        // process's life.
        var timeoutCts = delay <= uint.MaxValue - 1
            ? new CancellationTokenSource(TimeSpan.FromMilliseconds(Math.Floor(delay)), _time)
            : new CancellationTokenSource();
        var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, timeoutCts.Token);
        var context = new JobContext(def.Name, run.Id, startedAt, recorder, linked.Token);
        var open = new OpenRun(def, run, recorder, recorded);
        _open[run.Id] = open;
        return new Opened
        {
            Def = def,
            Options = options,
            Run = run,
            Recorded = recorded,
            Closing = closing,
            Recorder = recorder,
            Context = context,
            Timeout = timeoutCts,
            Linked = linked,
            Open = open,
        };
    }

    /// <summary>Closes a run as its function ended, answering the run as recorded.</summary>
    internal async Task<Run> CloseAsync(Opened o, object? value, Exception? thrown, CancellationToken cancellationToken)
    {
        o.EndFunction();
        if (!o.Claim())
        {
            // Closed already: the run as that close recorded it, or as it was opened when it was
            // given back.
            return o.Open.Recording is { } recorded ? await recorded.WaitAsync(cancellationToken).ConfigureAwait(false) : o.Run;
        }
        JobDef def = o.Def;
        Run run = o.Run;
        var discard = o.Options.DiscardWhen;
        if (discard != null && thrown != null && GivenBack(def.Name, discard, thrown) && await TakeBackNowAsync(o).ConfigureAwait(false))
        {
            return run;
        }
        Task? closing = o.Closing;
        if (o.Recorded && o.Options.TakesBack)
        {
            closing = Spawn(() => CloseOnStartAsync(def.Name));
        }
        string? failure;
        string? resultText = null;
        if (thrown != null)
        {
            failure = ErrorText(thrown);
        }
        else
        {
            failure = HttpFailure.Of(value);
            resultText = value as string;
        }
        Task<Run> recording = Spawn(() => FinishExecutedAsync(def, run, o.Recorder, resultText, failure, o.Recorded, closing));
        o.Open.Recording = recording;
        _ = recording.ContinueWith(
            _ => _open.TryRemove(new KeyValuePair<string, OpenRun>(run.Id, o.Open)),
            CancellationToken.None,
            TaskContinuationOptions.ExecuteSynchronously,
            TaskScheduler.Default);
        try
        {
            // The caller may stop waiting; the recording completes on its own.
            return await recording.WaitAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            if (thrown == null)
            {
                throw;
            }
            return run;
        }
        catch (Exception e)
        {
            Report(e, "recording " + def.Name);
            return run;
        }
    }

    /// <summary>Takes a run back: deletes its running row, judging nothing.</summary>
    internal async Task<bool> TakeBackAsync(Opened o)
    {
        o.EndFunction();
        if (o.IsClosed)
        {
            return true;
        }
        if (!await TakeBackNowAsync(o).ConfigureAwait(false))
        {
            return false;
        }
        o.Claim();
        return true;
    }

    private async Task<bool> TakeBackNowAsync(Opened o)
    {
        bool back = true;
        if (o.Recorded)
        {
            back = await Spawn(() => DiscardRunAsync(o.Run)).ConfigureAwait(false);
        }
        if (back)
        {
            _open.TryRemove(o.Run.Id, out _);
        }
        return back;
    }

    private bool GivenBack(string name, Func<Exception, bool> discard, Exception thrown)
    {
        try
        {
            return discard(thrown);
        }
        catch (Exception e)
        {
            Report(e, "discarding " + name);
            return false;
        }
    }

    private async Task<bool> DiscardRunAsync(Run run)
    {
        string where = "discarding " + run.Job;
        if (_store is not IRunDeletingStore deleting)
        {
            Report("the store cannot take back a run (it has no DeleteRunIfAsync); recorded as it ended", where);
            return false;
        }
        bool deleted;
        try
        {
            deleted = await CallAsync(() => deleting.DeleteRunIfAsync(run.Id, run.Job, RunStatus.Running)).ConfigureAwait(false);
        }
        catch (Exception e)
        {
            Report(e, where);
            return false;
        }
        if (!deleted)
        {
            Report("run " + run.Id + " of " + run.Job + " is no longer running; left as it is", where);
        }
        return true;
    }

    private async Task<bool> BeginRunAsync(JobDef def, Run run)
    {
        try
        {
            await SyncAsync(def).ConfigureAwait(false);
            await CallAsync(() => _store.InsertRunAsync(run)).ConfigureAwait(false);
            return true;
        }
        catch (Exception e)
        {
            Report(e, "recording " + def.Name);
            return false;
        }
    }

    internal async Task CloseOnStartAsync(string name)
    {
        try
        {
            await UpdateStateAsync(name, s => (Evaluate.OnRunStart(s), true)).ConfigureAwait(false);
        }
        catch (Exception e)
        {
            Report(e, "starting " + name);
        }
    }

    private async Task<Run> FinishExecutedAsync(JobDef def, Run run, Recorder recorder, string? resultText, string? failure, bool recorded, Task? closing)
    {
        string name = def.Name;
        long finishedAt = Now();
        string? output = recorder.Output();
        if (output == null && failure == null && resultText != null)
        {
            output = OutputText.Cap(resultText);
        }
        string? expectText = recorder.ExpectText();
        if (expectText == null && failure == null)
        {
            expectText = resultText;
        }
        Run finished = run with
        {
            FinishedAt = finishedAt,
            DurationMs = Evaluate.RunDuration(run.StartedAt, finishedAt),
            Output = output,
            Metrics = recorder.Metrics(),
        };
        finished = ConcludeGuarded(def, finished, failure, expectText, timedOut: false);
        if (closing != null)
        {
            try
            {
                await closing.ConfigureAwait(false);
            }
            catch (Exception e)
            {
                Report(e, "starting " + name);
            }
        }
        try
        {
            string? why = await RecordFinishAsync(def, finished, recorded, finishedAt).ConfigureAwait(false);
            if (why != null)
            {
                Report("run " + finished.Id + " of " + name + " " + why + "; ignored", "finishing " + name);
            }
        }
        catch (Exception e)
        {
            Report(e, "recording " + name);
        }
        return finished;
    }

    /// <summary>
    /// <see cref="Conclude"/>, and when the app's own redaction or expect check throws anyway, the
    /// run failed with that throw, written through the default redaction.
    /// </summary>
    internal Run ConcludeGuarded(JobDef def, Run run, string? failure, string? expectText, bool timedOut)
    {
        Run concluded;
        try
        {
            concluded = Conclude(def, run, failure, expectText, timedOut);
        }
        catch (Exception e)
        {
            concluded = run with
            {
                Status = timedOut ? RunStatus.Timeout : RunStatus.Failed,
                Error = NulText.StripNul(OutputText.RedactSecrets(ErrorText(e))),
                Output = run.Output == null ? null : NulText.StripNul(OutputText.RedactSecrets(run.Output)),
            };
        }
        CronwatchTelemetry.Runs.Add(1, new KeyValuePair<string, object?>("cronwatch.job", def.Name), new KeyValuePair<string, object?>("cronwatch.status", concluded.Status.Value));
        if (concluded.DurationMs is long ms)
        {
            CronwatchTelemetry.RunDuration.Record(ms, new KeyValuePair<string, object?>("cronwatch.job", def.Name));
        }
        return concluded;
    }

    internal Run Conclude(JobDef def, Run run, string? failure, string? expectText, bool timedOut)
    {
        RunStatus status;
        string? error;
        if (timedOut)
        {
            status = RunStatus.Timeout;
            error = failure;
        }
        else if (failure != null)
        {
            status = RunStatus.Failed;
            error = failure;
        }
        else
        {
            string? unmet = Expect.CheckExpectation(def.Expect, expectText);
            status = unmet == null ? RunStatus.Ok : RunStatus.Failed;
            error = unmet;
        }
        // Redacted after the expect check, so a rule can still match what was logged. NULs go
        // last, so not even a custom redact can store one.
        return run with
        {
            Status = status,
            Error = error == null ? null : NulText.StripNul(Redact(error)),
            Output = run.Output == null ? null : NulText.StripNul(Redact(run.Output)),
        };
    }

    /// <summary>Writes a finished run and judges it when this process's write landed; answers why it was ignored, or null.</summary>
    internal async Task<string?> RecordFinishAsync(JobDef def, Run run, bool recorded, long finishedAt)
    {
        if (!recorded)
        {
            // The start was never written; the store may be back by now.
            await SyncAsync(def).ConfigureAwait(false);
            try
            {
                await CallAsync(() => _store.InsertRunAsync(run)).ConfigureAwait(false);
                await FinishRunAsync(def.Stored, run, finishedAt).ConfigureAwait(false);
                return null;
            }
            catch (CronwatchException)
            {
                // Another process may have recorded a run with this id meanwhile.
                Run? stored;
                try
                {
                    stored = await CallAsync(() => _store.GetRunAsync(run.Id)).ConfigureAwait(false);
                }
                catch (Exception)
                {
                    throw;
                }
                if (stored == null)
                {
                    throw;
                }
                if (stored.Job != run.Job)
                {
                    return "belongs to job " + Json.Quote(stored.Job);
                }
            }
        }
        var (late, ignored) = await ClaimFinishAsync(run).ConfigureAwait(false);
        if (ignored != null)
        {
            return ignored;
        }
        if (!late || run.Status == RunStatus.Ok)
        {
            await FinishRunAsync(def.Stored, run, finishedAt).ConfigureAwait(false);
        }
        return null;
    }

    /// <summary>
    /// Writes the finish over a row still running, else over one a check marked timed out
    /// (<c>late</c>), else answers why it was ignored.
    /// </summary>
    internal async Task<(bool Late, string? Ignored)> ClaimFinishAsync(Run run)
    {
        if (await WriteRunIfAsync(run, OnlyRunning).ConfigureAwait(false))
        {
            return (false, null);
        }
        if (await WriteRunIfAsync(run, OnlyTimeout).ConfigureAwait(false))
        {
            return (true, null);
        }
        Run? stored = await CallAsync(() => _store.GetRunAsync(run.Id)).ConfigureAwait(false);
        return (false, stored == null ? "was not found" : "was already finished as " + stored.Status.Value);
    }

    /// <summary>Judges a finished run and sends what it raised.</summary>
    internal async Task<IReadOnlyList<Alert>> FinishRunAsync(Definition def, Run run, long now)
    {
        IReadOnlyList<AlertDraft> drafts;
        try
        {
            var result = await UpdateStateAsync<IReadOnlyList<Run>, IReadOnlyList<AlertDraft>>(
                run.Job,
                () => HistoryAsync(run),
                (previous, history) =>
                {
                    var settled = Evaluate.ApplySilence(previous, Evaluate.OnRunFinish(def, run, previous, history, now), now);
                    return (settled.State, settled.Alerts);
                }).ConfigureAwait(false);
            drafts = result.Result;
        }
        catch (Exception e)
        {
            Report(e, "evaluating " + run.Job);
            return [];
        }
        return await DispatchAsync(drafts, def, now).ConfigureAwait(false);
    }

    private async Task<IReadOnlyList<Run>> HistoryAsync(Run run)
    {
        var page = await _store.ListRunsAsync(run.Job, HistoryPage).ConfigureAwait(false);
        var runs = Without(page, run);
        bool full = page.Count == HistoryPage;
        int ok = 0;
        foreach (var r in runs)
        {
            if (r.Status == RunStatus.Ok)
            {
                ok++;
            }
        }
        if (full && ok < Evaluate.BaselineWindow)
        {
            runs = Without(await _store.ListRunsAsync(run.Job, HistoryMax).ConfigureAwait(false), run);
        }
        return runs;
    }

    private static List<Run> Without(IReadOnlyList<Run> runs, Run run)
    {
        var output = new List<Run>(runs.Count);
        foreach (var r in runs)
        {
            if (r.Id != run.Id)
            {
                output.Add(r);
            }
        }
        return output;
    }

    private async Task<IReadOnlyList<Alert>> RecordRunNowAsync(Run input, bool evaluate)
    {
        JobDef def = Declared(input.Job)
            ?? throw CronwatchException.Invalid("recordRun: job " + Json.Quote(input.Job) + " is not declared; call Job() first");
        if (input.Id.Contains('\0', StringComparison.Ordinal))
        {
            throw CronwatchException.Invalid("recordRun: run ids cannot contain a NUL character (job " + Json.Quote(input.Job) + ")");
        }
        await SyncAsync(def).ConfigureAwait(false);
        Run run = input;
        if (run.Status == RunStatus.Ok)
        {
            string? unmet = Expect.CheckExpectation(def.Expect, run.Output);
            if (unmet != null)
            {
                run = run with { Status = RunStatus.Failed, Error = unmet };
            }
        }
        run = run with
        {
            Output = run.Output == null ? null : NulText.StripNul(Redact(OutputText.Cap(run.Output))),
            Error = run.Error == null ? null : NulText.StripNul(Redact(OutputText.Cap(run.Error))),
        };
        Run toWrite = run;
        Run? stored = await CallAsync(() => _store.GetRunAsync(toWrite.Id)).ConfigureAwait(false);
        if (stored != null)
        {
            return await RecordOverAsync(def.Stored, stored, run, evaluate).ConfigureAwait(false);
        }
        try
        {
            await CallAsync(() => _store.InsertRunAsync(toWrite)).ConfigureAwait(false);
        }
        catch (CronwatchException)
        {
            // Another process recorded it first.
            Run? again;
            try
            {
                again = await CallAsync(() => _store.GetRunAsync(toWrite.Id)).ConfigureAwait(false);
            }
            catch (Exception)
            {
                throw;
            }
            if (again == null)
            {
                throw;
            }
            return await RecordOverAsync(def.Stored, again, run, evaluate).ConfigureAwait(false);
        }
        if (!evaluate)
        {
            return [];
        }
        await UpdateStateAsync(run.Job, s => (Evaluate.OnRunStart(s), true)).ConfigureAwait(false);
        if (run.Status == RunStatus.Running)
        {
            return [];
        }
        return await FinishRunAsync(def.Stored, run, Now()).ConfigureAwait(false);
    }

    private async Task<IReadOnlyList<Alert>> RecordOverAsync(Definition def, Run stored, Run run, bool evaluate)
    {
        string where = "recording " + run.Job;
        if (stored.Job != run.Job)
        {
            Report("run " + run.Id + " of " + run.Job + " belongs to job " + Json.Quote(stored.Job) + "; ignored", where);
            return [];
        }
        bool open = stored.Status == RunStatus.Running || stored.Status == RunStatus.Timeout;
        if (!open || run.Status == RunStatus.Running)
        {
            return [];
        }
        var (late, ignored) = await ClaimFinishAsync(run).ConfigureAwait(false);
        if (ignored != null)
        {
            Report("run " + run.Id + " of " + run.Job + " " + ignored + "; ignored", where);
            return [];
        }
        if (!evaluate || (late && run.Status != RunStatus.Ok))
        {
            return [];
        }
        return await FinishRunAsync(def, run, Now()).ConfigureAwait(false);
    }

    /// <summary>
    /// Records the runs still open in this process failed (a function's whose recording is under
    /// way is waited for instead), within the shutdown's five seconds, all at once.
    /// </summary>
    private async Task RecordOpenRunsAsync()
    {
        var work = new List<Task>();
        foreach (var o in _open.Values)
        {
            if (o.Recording is { } recording)
            {
                work.Add(recording);
                continue;
            }
            if (!o.Recorded)
            {
                continue;
            }
            work.Add(Spawn(() => FailOpenAsync(o)));
        }
        try
        {
            await Task.WhenAll(work).WaitAsync(Timings.Shutdown, _time).ConfigureAwait(false);
        }
        catch (TimeoutException)
        {
            // What is left is reported stuck at its timeout, as a killed process's run is.
        }
        catch (Exception e)
        {
            Report(e, "shutdown");
        }
    }

    private async Task FailOpenAsync(OpenRun o)
    {
        // The hook and a disposal during the shutdown may both get here: one records the run.
        if (!_open.TryRemove(new KeyValuePair<string, OpenRun>(o.Run.Id, o)))
        {
            return;
        }
        string name = o.Def.Name;
        long now = Now();
        Run run = o.Run;
        string? output = o.Recorder.Output();
        Run failed = run with
        {
            Status = RunStatus.Failed,
            FinishedAt = now,
            DurationMs = Evaluate.RunDuration(run.StartedAt, now),
            Error = NulText.StripNul(Redact(ShutdownError)),
            Output = output == null ? null : NulText.StripNul(Redact(output)),
            Metrics = o.Recorder.Metrics(),
        };
        try
        {
            if (await WriteRunIfAsync(failed, OnlyRunning).ConfigureAwait(false))
            {
                await FinishRunAsync(o.Def.Stored, failed, now).ConfigureAwait(false);
            }
        }
        catch (Exception e)
        {
            Report(e, "recording " + name);
        }
    }
}
