using System;
using System.Diagnostics;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch.Internal;

namespace Cronwatch;

/// <summary>
/// A run whose function is seen from outside, as a scheduler's filter or listener sees one:
/// opened when the scheduler says the function starts (<see cref="Job.OpenAsync"/>) and closed
/// when it says the function has ended. The two halves of <c>RunAsync</c>, so the running row, the
/// activity, the timeout and the process-exit hook's record are a run's. The first of
/// <see cref="CloseAsync"/>, <see cref="CloseWithAsync"/> and <see cref="TakeBackAsync"/> ends it,
/// and later calls do nothing. Safe to use from any thread.
/// </summary>
[DebuggerDisplay("{ToString(),nq}")]
public sealed class ObservedRun
{
    private readonly CronwatchClient _client;
    private readonly CronwatchClient.Opened _opened;
    private readonly Activity? _activity;
    private int _stopped;

    internal ObservedRun(CronwatchClient client, CronwatchClient.Opened opened, Activity? activity)
    {
        _client = client;
        _opened = opened;
        _activity = activity;
    }

    /// <summary>The run's context: what a job's function is given, and <see cref="CronwatchClient.Current"/> once it is made current.</summary>
    public JobContext Context => _opened.Context;

    /// <summary>The run's id.</summary>
    public string Id => _opened.Run.Id;

    /// <summary>The job's name.</summary>
    public string Job => _opened.Def.Name;

    /// <summary>Whether the run is still open.</summary>
    public bool IsOpen => !_opened.IsClosed;

    /// <summary>
    /// Makes this run <see cref="CronwatchClient.Current"/> in the calling flow, with its activity
    /// as <see cref="Activity.Current"/> and the client's run scope (see
    /// <see cref="CronwatchOptions.RunScope"/>) open, and answers what puts them back as they were.
    /// For an integration whose callbacks are synchronous and run on the thread that then runs the
    /// job: called there, it reaches the job, and disposed there after the job, the thread keeps
    /// nothing. Called in an async method, it lasts only until that method returns.
    /// </summary>
    public IDisposable MakeCurrent()
    {
        JobContext? previous = CurrentRun.Get();
        Activity? previousActivity = Activity.Current;
        CurrentRun.Set(_opened.Context);
        if (_activity != null)
        {
            Activity.Current = _activity;
        }
        IDisposable? scope = _client.OpenRunScope(_opened.Context);
        return new Restore(this, previous, previousActivity, scope);
    }

    /// <summary>
    /// Ends the part of the run in which the function runs: the timeout no longer applies. For a
    /// listener that learns how the run went only later; closing does it anyway.
    /// </summary>
    public void EndFunction() => _opened.EndFunction();

    /// <summary>
    /// Closes the run, failed with <paramref name="failure"/> when it is not null and succeeded
    /// otherwise, judges and records it, and answers the run as recorded. A failure the run's
    /// <see cref="RunOptions.DiscardWhen"/> answers true for takes the run back instead. The store
    /// never fails out of it; a caller whose token is cancelled stops waiting, not the recording.
    /// </summary>
    public Task<Run> CloseAsync(Exception? failure, CancellationToken cancellationToken = default) =>
        FinishAsync(null, failure, cancellationToken);

    /// <summary>
    /// Closes the run as a success with <paramref name="value"/>, what the function returned: a
    /// string is the output when nothing was logged, and an HTTP answer of 400 or more fails the run.
    /// </summary>
    public Task<Run> CloseWithAsync(object? value, CancellationToken cancellationToken = default) =>
        FinishAsync(value, null, cancellationToken);

    private async Task<Run> FinishAsync(object? value, Exception? failure, CancellationToken cancellationToken)
    {
        try
        {
            Run run = await _client.CloseAsync(_opened, value, failure, cancellationToken).ConfigureAwait(false);
            Stop(run.Status.Value);
            return run;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            Stop(null);
            throw;
        }
    }

    /// <summary>
    /// Gives the run back rather than judge it, for an attempt the scheduler did not really make
    /// (a job its server's shutdown put back in its queue): the running row is deleted, nothing is
    /// judged or alerted, and the job's state is left as it was. A row a check already marked
    /// stuck is left as it is. When the store cannot take a run back (it has no
    /// <see cref="IRunDeletingStore"/>, or it failed), which is reported, the run is closed as a
    /// success instead. Says whether it was given back.
    /// </summary>
    public async Task<bool> TakeBackAsync()
    {
        if (await _client.TakeBackAsync(_opened).ConfigureAwait(false))
        {
            Stop("given back");
            return true;
        }
        await FinishAsync(null, null, CancellationToken.None).ConfigureAwait(false);
        return false;
    }

    private void Stop(string? status)
    {
        if (Interlocked.Exchange(ref _stopped, 1) != 0 || _activity == null)
        {
            return;
        }
        if (status != null)
        {
            _activity.SetTag("cronwatch.status", status);
        }
        _activity.Stop();
    }

    /// <summary>Names the job and the run.</summary>
    public override string ToString() => "ObservedRun(" + _opened.Def.Name + ", run " + _opened.Run.Id + ")";

    private sealed class Restore(ObservedRun run, JobContext? previous, Activity? previousActivity, IDisposable? scope) : IDisposable
    {
        private int _done;

        public void Dispose()
        {
            if (Interlocked.Exchange(ref _done, 1) != 0)
            {
                return;
            }
            run._client.CloseRunScope(scope, run.Job);
            CurrentRun.Set(previous);
            if (run._activity != null && ReferenceEquals(Activity.Current, run._activity))
            {
                Activity.Current = previousActivity;
            }
        }
    }
}
