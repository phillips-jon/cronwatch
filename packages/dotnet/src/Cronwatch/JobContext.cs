using System;
using System.Collections.Generic;
using System.Threading;
using Cronwatch.Internal;

namespace Cronwatch;

/// <summary>
/// The run a job's function is given, and <see cref="CronwatchClient.Current"/> inside it: its
/// lines, its metrics and its token. Safe to use from any number of threads at once.
/// </summary>
public sealed class JobContext
{
    private readonly Recorder _recorder;

    internal JobContext(string name, string runId, long startedAt, Recorder recorder, CancellationToken token)
    {
        Name = name;
        RunId = runId;
        StartedAt = startedAt;
        _recorder = recorder;
        CancellationToken = token;
    }

    /// <summary>The job's name.</summary>
    public string Name { get; }

    /// <summary>The run's id.</summary>
    public string RunId { get; }

    /// <summary>When the run started, in epoch milliseconds.</summary>
    public long StartedAt { get; }

    /// <summary>
    /// The run's token, the SDK's <c>signal</c>: cancelled at the job's timeout and when the token
    /// given to <c>RunAsync</c> is.
    /// </summary>
    public CancellationToken CancellationToken { get; }

    internal Recorder Recorder => _recorder;

    /// <summary>
    /// Adds a line to the run's output (kept to its last 16 KB, secrets taken out when it is
    /// stored), which an expect rule is checked against.
    /// </summary>
    public void Log(string line) => _recorder.Log(line);

    /// <summary>Reports a metric; a name reported again keeps its place and takes the new value.</summary>
    /// <exception cref="ArgumentException">When the value is not finite.</exception>
    public void Metric(string name, double value) => _recorder.Metric(name, value);

    /// <summary>Reports several metrics, in their order.</summary>
    public void Metrics(IEnumerable<KeyValuePair<string, double>> values)
    {
        ArgumentNullException.ThrowIfNull(values);
        foreach (var e in values)
        {
            _recorder.Metric(e.Key, e.Value);
        }
    }

    /// <summary>Names the job and the run.</summary>
    public override string ToString() => "JobContext(" + Name + ", run " + RunId + ")";
}

/// <summary>How a run is recorded: its trigger and id, and whether it may be given back.</summary>
public sealed class RunOptions
{
    /// <summary>What started the run. Default <c>run</c>.</summary>
    public string Trigger { get; init; } = "run";

    /// <summary>The run's id: 1 to 200 characters, no NUL. Default: a new GUID.</summary>
    public string? Id { get; init; }

    /// <summary>
    /// Takes a run back rather than judge it when the function throws an exception this answers
    /// true for: for an attempt a scheduler gives back without failing. The running row is
    /// deleted, nothing is judged, and the exception is still thrown.
    /// </summary>
    public Func<Exception, bool>? DiscardWhen { get; init; }

    /// <summary>Leaves missed and stuck open until the run is known not to be given back.</summary>
    public bool MayTakeBack { get; init; }

    internal bool TakesBack => MayTakeBack || DiscardWhen != null;

    /// <summary>Names what is set.</summary>
    public override string ToString() =>
        "RunOptions(trigger " + Trigger + (Id == null ? "" : ", id " + Id) + (DiscardWhen == null ? "" : ", discardWhen") + (TakesBack ? ", mayTakeBack" : "") + ")";
}

/// <summary>How a run that spans calls is started.</summary>
public sealed class StartOptions
{
    /// <summary>What started the run. Default <c>start</c>.</summary>
    public string Trigger { get; init; } = "start";

    /// <summary>
    /// The run's id, so another process can resume it: 1 to 200 characters, no NUL. A start with
    /// an id already recorded for this job answers a handle on that run. Default: a new GUID.
    /// </summary>
    public string? Id { get; init; }

    /// <summary>Names what is set.</summary>
    public override string ToString() => "StartOptions(trigger " + Trigger + (Id == null ? "" : ", id " + Id) + ")";
}
