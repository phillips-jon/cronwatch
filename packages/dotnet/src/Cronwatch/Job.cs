using System;
using System.Threading;
using System.Threading.Tasks;

namespace Cronwatch;

/// <summary>A declared job's handle, from <see cref="CronwatchClient.Job"/>.</summary>
public sealed partial class Job
{
    private static readonly RunOptions DefaultRun = new();
    private static readonly StartOptions DefaultStart = new();

    private readonly CronwatchClient _client;

    internal Job(CronwatchClient client, JobDef def)
    {
        _client = client;
        Def = def;
    }

    internal JobDef Def { get; }

    /// <summary>The job's name.</summary>
    public string Name => Def.Name;

    /// <summary>The definition as it is stored.</summary>
    public Definition Definition => Def.Stored;

    /// <summary>The client the job was declared on.</summary>
    public CronwatchClient Client => _client;

    /// <summary>
    /// Runs <paramref name="fn"/> in the caller's flow as a recorded run. Any exception is a failed
    /// run, and is thrown again as it came once the run is recorded. The function's token is
    /// cancelled at the job's timeout and when <paramref name="cancellationToken"/> is; a caller
    /// whose token is cancelled while the run is recorded stops waiting, not the recording.
    /// </summary>
    public Task RunAsync(Func<JobContext, CancellationToken, Task> fn, CancellationToken cancellationToken = default) =>
        RunAsync(DefaultRun, fn, cancellationToken);

    /// <summary>Runs <paramref name="fn"/> as a recorded run with these options.</summary>
    public Task RunAsync(RunOptions options, Func<JobContext, CancellationToken, Task> fn, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(fn);
        return _client.ExecuteAsync<object?>(
            Def,
            options,
            async (job, ct) =>
            {
                await fn(job, ct).ConfigureAwait(false);
                return null;
            },
            cancellationToken);
    }

    /// <summary>
    /// Runs <paramref name="fn"/> as a recorded run and answers its value: a string is the run's
    /// output when nothing was logged (and what an expect rule checks), and an
    /// <see cref="System.Net.Http.HttpResponseMessage"/> of 400 or more fails the run.
    /// </summary>
    public Task<T> RunAsync<T>(Func<JobContext, CancellationToken, Task<T>> fn, CancellationToken cancellationToken = default) =>
        RunAsync(DefaultRun, fn, cancellationToken);

    /// <summary>Runs <paramref name="fn"/> as a recorded run with these options and answers its value.</summary>
    public Task<T> RunAsync<T>(RunOptions options, Func<JobContext, CancellationToken, Task<T>> fn, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(fn);
        return _client.ExecuteAsync(Def, options, fn, cancellationToken);
    }

    /// <summary>
    /// Opens a run whose function is seen from outside, as a scheduler's filter or listener is
    /// told of one starting: closed with <see cref="ObservedRun.CloseAsync"/> when it is told the
    /// function ended. The first half of <c>RunAsync</c>; see <see cref="ObservedRun"/>. The store
    /// never fails out of it. <paramref name="cancellationToken"/> is linked into the run's own
    /// token, as <c>RunAsync</c>'s is.
    /// </summary>
    /// <exception cref="CronwatchException">Of kind <see cref="CronwatchErrorKind.Invalid"/> for a run id the client refuses.</exception>
    public Task<ObservedRun> OpenAsync(RunOptions? options = null, CancellationToken cancellationToken = default) =>
        _client.OpenObservedAsync(Def, options ?? DefaultRun, cancellationToken);

    /// <summary>
    /// Starts a run that finishes later, maybe in another process: the SDK's <c>start()</c>. The
    /// store never fails out of it.
    /// </summary>
    public Task<RunHandle> StartAsync(StartOptions? options = null, CancellationToken cancellationToken = default) =>
        _client.StartRunAsync(Def, options ?? DefaultStart, cancellationToken);

    /// <summary>A handle on a run started elsewhere: the SDK's <c>resume()</c>.</summary>
    public Task<RunHandle> ResumeAsync(string runId, CancellationToken cancellationToken = default) =>
        _client.ResumeHandleAsync(Def, runId, cancellationToken);

    /// <summary>Names the job.</summary>
    public override string ToString() => "Job(" + Def.Name + ")";
}
