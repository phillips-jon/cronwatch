using System;
using System.Diagnostics;
using System.Diagnostics.CodeAnalysis;
using Hangfire.Common;
using Hangfire.Server;
using Hangfire.States;
using CronwatchJob = Cronwatch.Job;

namespace Cronwatch.Hangfire;

/// <summary>
/// The filter <see cref="CronwatchHangfire"/> adds to Hangfire: a server filter that records each
/// attempt of a watched job as a run, and a state election filter that records a job Hangfire
/// fails before it performs it. Nothing in it ever throws into Hangfire; what fails is reported to
/// the client's error handler.
/// </summary>
/// <remarks>
/// Hangfire calls <see cref="OnPerforming"/> in the worker's thread just before the job's method
/// and <see cref="OnPerformed"/> there just after, synchronously, awaiting an async method between
/// them. So the run is opened and made current in the first, which reaches the method (Hangfire
/// runs it inside the worker's execution context), and closed in the second, which takes it off
/// the worker's thread whatever happened, so a pooled worker keeps nothing.
/// </remarks>
[DebuggerDisplay("{ToString(),nq}")]
[SuppressMessage("Naming", "CA1725", Justification = "Hangfire renamed these parameters within 1.8 (filterContext in 1.8.0, context later), so no one name matches every supported release.")]
public sealed class CronwatchHangfireFilter : JobFilterAttribute, IServerFilter, IElectStateFilter
{
    private const string RunKey = "cronwatch.run";
    private const string CurrentKey = "cronwatch.current";

    private readonly CronwatchHangfire _integration;

    internal CronwatchHangfireFilter(CronwatchHangfire integration)
    {
        _integration = integration;
    }

    /// <summary>Opens a run for a watched job and makes it current in the worker's thread.</summary>
    public void OnPerforming(PerformingContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        try
        {
            if (_integration.Disposed || context.BackgroundJob.Job == null)
            {
                return; // a job that does not load is recorded from its state change
            }
            string? name = _integration.NameOf(context.BackgroundJob.Job, context.GetJobParameter<string>("RecurringJobId", true));
            if (name == null)
            {
                return;
            }
            // Hangfire's worker has no synchronization context and the client awaits nothing on
            // the caller's, so this blocks only for the store's write.
            CronwatchJob? job = _integration.JobAsync(name).GetAwaiter().GetResult();
            if (job == null)
            {
                return;
            }
            int retry = context.GetJobParameter<int>("RetryCount", true);
            var options = new RunOptions { Trigger = CronwatchHangfire.Trigger, Id = _integration.RunId(context.BackgroundJob.Id, retry), MayTakeBack = true };
            ObservedRun run = job.OpenAsync(options, context.CancellationToken.ShutdownToken).GetAwaiter().GetResult();
            context.Items[RunKey] = run;
            context.Items[CurrentKey] = run.MakeCurrent();
        }
        catch (Exception e)
        {
            _integration.Client.ReportError(e, "hangfire");
        }
    }

    /// <summary>
    /// Closes the run: failed with what the job's method threw, given back when the server's
    /// shutdown stopped it or a filter after this one cancelled it, and succeeded otherwise.
    /// </summary>
    public void OnPerformed(PerformedContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        if (!context.Items.TryGetValue(RunKey, out object? found) || found is not ObservedRun run)
        {
            return;
        }
        context.Items.Remove(RunKey);
        try
        {
            if (context.Items.TryGetValue(CurrentKey, out object? current) && current is IDisposable restore)
            {
                context.Items.Remove(CurrentKey);
                restore.Dispose();
            }
            Exception? thrown = context.Exception;
            if (context.Canceled || GivenBack(thrown, context))
            {
                run.TakeBackAsync().GetAwaiter().GetResult();
            }
            else if (thrown == null)
            {
                run.CloseWithAsync(context.Result).GetAwaiter().GetResult();
            }
            else
            {
                run.CloseAsync(thrown is JobPerformanceException { InnerException: { } inner } ? inner : thrown).GetAwaiter().GetResult();
            }
        }
        catch (Exception e)
        {
            _integration.Client.ReportError(e, "hangfire");
        }
    }

    /// <summary>
    /// A job stopped by its server's shutdown, which Hangfire puts back in its queue rather than
    /// fail; one aborted because it was deleted is a failure.
    /// </summary>
    private static bool GivenBack(Exception? thrown, PerformedContext context) =>
        thrown is OperationCanceledException and not JobAbortedException && context.CancellationToken.ShutdownToken.IsCancellationRequested;

    /// <summary>
    /// Records a failed run for a recurring job Hangfire fails before it performs it (its type or
    /// arguments no longer load), which never reaches <see cref="OnPerforming"/>: a failed state
    /// among the election's candidates, before a retry filter moves it to a scheduled one.
    /// </summary>
    public void OnStateElection(ElectStateContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        try
        {
            if (_integration.Disposed || context.BackgroundJob.Job != null)
            {
                return;
            }
            FailedState? failed = context.CandidateState as FailedState;
            if (failed == null)
            {
                foreach (IState state in context.TraversedStates)
                {
                    if (state is FailedState f)
                    {
                        failed = f;
                        break;
                    }
                }
            }
            if (failed == null)
            {
                return;
            }
            string? name = _integration.NameOf(null, context.GetJobParameter<string>("RecurringJobId", true));
            if (name == null)
            {
                return;
            }
            int retry = context.GetJobParameter<int>("RetryCount", true);
            Exception cause = failed.Exception is JobLoadException { InnerException: { } inner } ? inner : failed.Exception;
            string error = cause.GetType().Name + ": " + cause.Message;
            _integration.RecordLoadFailure(name, _integration.RunId(context.BackgroundJob.Id, retry), error);
        }
        catch (Exception e)
        {
            _integration.Client.ReportError(e, "hangfire");
        }
    }

    /// <summary>Names the integration.</summary>
    public override string ToString() => "CronwatchHangfireFilter(" + _integration.Watch.AppTag + ")";
}
