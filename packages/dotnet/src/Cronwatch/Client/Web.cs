using System;
using System.Diagnostics;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch.Internal;
using Cronwatch.Web;

namespace Cronwatch;

/// <summary>What the dashboard and a job's handler need of the client.</summary>
public sealed partial class CronwatchClient
{
    private int _warnedNoSecret;

    /// <summary>
    /// The dashboard and its JSON API for this client: the SDK's <c>cw.routes()</c>. Serve it with
    /// <c>Cronwatch.AspNetCore</c>'s <c>MapCronwatch</c>, or hand <see cref="Web.Routes.HandleAsync"/>
    /// requests from any server.
    /// </summary>
    /// <exception cref="CronwatchException">For an <see cref="RoutesOptions.Origin"/> that is not an http or https URL, with the SDK's message.</exception>
    public Routes Routes(RoutesOptions? options = null) => new(this, options ?? new RoutesOptions());

    /// <summary>The handle of a job declared on this client, or null when none of that name is.</summary>
    public Job? DeclaredJob(string name)
    {
        ArgumentNullException.ThrowIfNull(name);
        lock (_declaredLock)
        {
            return _definitions.TryGetValue(name, out JobDef? def) ? new Job(this, def) : null;
        }
    }

    /// <summary>The environment, lowercased: CronWatch's variables, else the option the app gave.</summary>
    internal string EnvironmentName => Env.Environment(_environment);

    /// <summary>The cron secret, or null when none is set.</summary>
    internal string? CronSecretValue => _cronSecret;

    /// <summary>Whether the app said a handler needs no secret (<see cref="CronSecret.None"/>).</summary>
    internal bool SecretOptedOut => _secretOptOut;

    /// <summary>True once: the first time a handler refuses a request for want of a secret.</summary>
    internal bool FirstNoSecretRefusal() => Interlocked.Exchange(ref _warnedNoSecret, 1) == 0;

    /// <summary>
    /// Runs <paramref name="fn"/> as a recorded run and answers the run as recorded with what the
    /// function answered or threw, rather than throwing: what a job's handler answers from, and
    /// what <c>RunAsync</c> throws from. The run is current, its activity open and the app's run
    /// scope open while the function runs.
    /// </summary>
    internal async Task<(Run Run, T? Value, Exception? Thrown)> ExecuteCaughtAsync<T>(
        JobDef def,
        RunOptions options,
        Func<JobContext, CancellationToken, Task<T>> fn,
        CancellationToken cancellationToken)
    {
        Opened o = await OpenAsync(def, options, cancellationToken).ConfigureAwait(false);
        // Set in this async method, so it flows into everything the function awaits and starts,
        // and is gone when this method returns: its caller's context is restored.
        CurrentRun.Set(o.Context);
        Activity? activity = CronwatchTelemetry.StartActivity("cronwatch.run");
        try
        {
            activity?.SetTag("cronwatch.job", def.Name);
            activity?.SetTag("cronwatch.run_id", o.Run.Id);
            activity?.SetTag("cronwatch.trigger", options.Trigger);
            IDisposable? scope = OpenRunScope(o.Context);
            T? value = default;
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
            return (finished, value, thrown);
        }
        finally
        {
            CronwatchTelemetry.StopActivity(activity);
        }
    }
}
