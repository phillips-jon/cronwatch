using System;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch.Internal;

namespace Cronwatch;

/// <summary>
/// A run that spans calls, or processes: the SDK's <c>RunHandle</c>, from
/// <see cref="Job.StartAsync"/>, <see cref="Job.ResumeAsync"/> or
/// <see cref="CronwatchClient.ResumeRunAsync"/>. The store never fails out of it: failures go to
/// the client's error handler, and a store that fails during a finish leaves the handle active,
/// its lines kept, so the finish can be called again. A handle left unfinished is what the stuck
/// check is for.
/// </summary>
#pragma warning disable CA1001 // the turn's semaphore holds no wait handle, and a handle is never disposed
public sealed class RunHandle
#pragma warning restore CA1001
{
    private static readonly RunStatus[] OnlyRunning = [RunStatus.Running];

    private readonly CronwatchClient _client;
    private readonly JobDef _def;
    private readonly Run? _base;
    private readonly bool _recorded;
    private readonly string? _inactive;

    // Flushes and the finish take turns, in order.
    private readonly SemaphoreSlim _turn = new(1, 1);
    private readonly Lock _lock = new();
    private Recorder _recorder = new();
    private bool _finished;
    private bool _finishCalled;

    // What earlier flushes wrote, kept (up to the cap) for the expect check.
    private string? _head;

    internal RunHandle(CronwatchClient client, JobDef def, string id, Run? baseRun, bool recorded, string? inactive)
    {
        _client = client;
        _def = def;
        Id = id;
        _base = baseRun;
        _recorded = recorded;
        _inactive = inactive;
        _finished = inactive != null;
    }

    /// <summary>The run's id.</summary>
    public string Id { get; }

    /// <summary>The job's name.</summary>
    public string Job => _def.Name;

    /// <summary>When the run started, or null for a resumed run that was not found.</summary>
    public long? StartedAt => _base?.StartedAt;

    /// <summary>False once finished, and from the start for a resumed run that already finished or does not exist.</summary>
    public bool IsActive
    {
        get
        {
            lock (_lock)
            {
                return !_finished;
            }
        }
    }

    private Recorder CurrentRecorder
    {
        get
        {
            lock (_lock)
            {
                return _recorder;
            }
        }
    }

    /// <summary>Adds a line to the run's output.</summary>
    public void Log(string line) => CurrentRecorder.Log(line);

    /// <summary>Reports a metric.</summary>
    /// <exception cref="ArgumentException">When the value is not finite.</exception>
    public void Metric(string name, double value) => CurrentRecorder.Metric(name, value);

    private void Ignored(string why) => _client.Report("run " + Id + " of " + _def.Name + " " + why + "; ignored", "finishing " + _def.Name);

    private static string? JoinLines(string? before, string? after)
    {
        if (string.IsNullOrEmpty(before))
        {
            return after;
        }
        if (after == null)
        {
            return before;
        }
        return before + "\n" + after;
    }

    private static string? JoinOutput(string? before, string? after)
    {
        string? joined = JoinLines(before, after);
        return joined == null ? null : OutputText.Cap(joined);
    }

    /// <summary>
    /// Writes the lines and metrics so far to the stored run, only over a row still running and
    /// of this job, so another process resuming it sees them.
    /// </summary>
    public Task FlushAsync(CancellationToken cancellationToken = default) =>
        _client.Spawn(FlushNowAsync).WaitAsync(cancellationToken);

    private async Task FlushNowAsync()
    {
        string name = _def.Name;
        await _turn.WaitAsync().ConfigureAwait(false);
        try
        {
            Recorder taken;
            string? lines;
            Metrics metrics;
            lock (_lock)
            {
                if (_finished || !_recorded)
                {
                    return;
                }
                lines = _recorder.Output();
                metrics = _recorder.Metrics();
                if (lines == null && metrics.Count == 0)
                {
                    return;
                }
                // Lines logged while this waits on the store go to a new recorder.
                taken = _recorder;
                _recorder = new Recorder();
            }
            Run? stored;
            try
            {
                stored = await CronwatchClient.CallAsync(() => _client.Store.GetRunAsync(Id)).ConfigureAwait(false);
            }
            catch (Exception e)
            {
                PutBack(taken);
                _client.Report(e, "flushing " + name);
                return;
            }
            // Not running: the lines stay here for the finish, which reports why it cannot record them.
            if (stored == null || stored.Status != RunStatus.Running)
            {
                PutBack(taken);
                return;
            }
            if (stored.Job != name)
            {
                PutBack(taken);
                _client.Report("run " + Id + " of " + name + " belongs to job " + JsonText.Quote(stored.Job) + "; ignored", "flushing " + name);
                return;
            }
            string? output = lines == null ? stored.Output : JoinOutput(stored.Output, OutputText.RedactAndCap(lines, _client.Redact));
            Run next = stored with { Output = output, Metrics = stored.Metrics.Merged(metrics) };
            bool wrote;
            try
            {
                wrote = await _client.WriteRunIfAsync(next, OnlyRunning).ConfigureAwait(false);
            }
            catch (Exception e)
            {
                PutBack(taken);
                _client.Report(e, "flushing " + name);
                return;
            }
            if (!wrote)
            {
                PutBack(taken);
                return;
            }
            string? text = taken.ExpectText();
            if (text != null)
            {
                lock (_lock)
                {
                    if (_head == null || _head.Length < OutputText.OutputCap)
                    {
                        _head = Js.Head(JoinLines(_head, text) ?? "", OutputText.OutputCap);
                    }
                }
            }
        }
        finally
        {
            _turn.Release();
        }
    }

    private void PutBack(Recorder taken)
    {
        lock (_lock)
        {
            Recorder later = _recorder;
            var merged = new Recorder();
            foreach (string? text in new[] { taken.ExpectText(), later.ExpectText() })
            {
                if (text != null)
                {
                    merged.Log(text);
                }
            }
            foreach (var e in taken.Metrics().Merged(later.Metrics()))
            {
                merged.Metric(e.Key, e.Value);
            }
            _recorder = merged;
        }
    }

    /// <summary>
    /// Finishes the run: its output checked against the job's expect rule, written only over a row
    /// still running (else one a check marked timed out), and judged. Answers the run as recorded,
    /// or null when it was ignored (already finished, not found, another job's) or the store
    /// failed.
    /// </summary>
    public Task<Run?> FinishAsync(CancellationToken cancellationToken = default) => FinishWithAsync(null, null, cancellationToken);

    /// <summary>
    /// Finishes the run with the function's answer: a string is its output when nothing was
    /// logged, and an <see cref="System.Net.Http.HttpResponseMessage"/> of 400 or more fails it.
    /// </summary>
    public Task<Run?> FinishAsync(object? result, CancellationToken cancellationToken = default) =>
        FinishWithAsync(result as string, HttpFailure.Of(result), cancellationToken);

    /// <summary>Finishes the run as failed with the exception.</summary>
    public Task<Run?> FailAsync(Exception error, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(error);
        return FinishWithAsync(null, CronwatchClient.ErrorText(error), cancellationToken);
    }

    /// <summary>Finishes the run as failed with this error text, redacted and capped as an error is.</summary>
    public Task<Run?> FailAsync(string error, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(error);
        return FinishWithAsync(null, error, cancellationToken);
    }

    private Task<Run?> FinishWithAsync(string? resultText, string? failure, CancellationToken cancellationToken) =>
        _client.Spawn(() => FinishNowAsync(resultText, failure)).WaitAsync(cancellationToken);

    private async Task<Run?> FinishNowAsync(string? resultText, string? failure)
    {
        bool already;
        bool wasInactive = false;
        lock (_lock)
        {
            already = _finishCalled;
            if (!already)
            {
                _finishCalled = true;
                wasInactive = _finished;
                _finished = true;
            }
        }
        if (already)
        {
            Ignored("was already finished by this handle");
            return null;
        }
        await _turn.WaitAsync().ConfigureAwait(false);
        try
        {
            string name = _def.Name;
            if (wasInactive)
            {
                Ignored(_inactive ?? "was already finished");
                return null;
            }
            Run? prior = _base;
            if (_recorded)
            {
                try
                {
                    Run? stored = await CronwatchClient.CallAsync(() => _client.Store.GetRunAsync(Id)).ConfigureAwait(false);
                    if (stored != null)
                    {
                        prior = stored;
                    }
                }
                catch (Exception e)
                {
                    return Retryable(e);
                }
            }
            if (prior == null)
            {
                Ignored("was not found");
                return null;
            }
            if (prior.Job != name)
            {
                Ignored("belongs to job " + JsonText.Quote(prior.Job));
                return null;
            }
            if (prior.Status == RunStatus.Ok || prior.Status == RunStatus.Failed)
            {
                Ignored("was already finished as " + prior.Status.Value);
                return null;
            }
            Recorder rec;
            string? earlier;
            lock (_lock)
            {
                rec = _recorder;
                earlier = _head;
            }
            long finishedAt = _client.Now();
            string? added = rec.Output();
            if (added == null && resultText != null)
            {
                added = resultText;
            }
            Run run = prior with
            {
                Status = RunStatus.Running,
                FinishedAt = finishedAt,
                DurationMs = Evaluate.RunDuration(prior.StartedAt, finishedAt),
                Error = null,
                // Capped by Conclude, after it is redacted.
                Output = JoinLines(prior.Output, added),
                Metrics = prior.Metrics.Merged(rec.Metrics()),
            };
            string? expected = rec.ExpectText() ?? resultText;
            string? expectText = JoinLines(earlier, JoinLines(prior.Output, expected));
            run = _client.ConcludeGuarded(_def, run, failure, expectText, timedOut: false);
            string? why;
            try
            {
                why = await _client.RecordFinishAsync(_def, run, _recorded, finishedAt).ConfigureAwait(false);
            }
            catch (Exception e)
            {
                return Retryable(e);
            }
            if (why != null)
            {
                Ignored(why);
                return null;
            }
            return run;
        }
        finally
        {
            _turn.Release();
        }
    }

    private Run? Retryable(Exception e)
    {
        lock (_lock)
        {
            _finishCalled = false;
            _finished = false;
        }
        _client.Report(e, "finishing " + _def.Name);
        return null;
    }

    /// <summary>Names the job and the run.</summary>
    public override string ToString() => "RunHandle(" + _def.Name + ", run " + Id + ")";
}
