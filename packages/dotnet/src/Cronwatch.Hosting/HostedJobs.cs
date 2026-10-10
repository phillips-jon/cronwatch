using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace Cronwatch.Hosting;

/// <summary>One job <c>AddCronwatchJob</c> registered: its name, options, and how its class is resolved.</summary>
internal sealed class HostedJob(string name, JobOptions options, Type type, Func<IServiceProvider, ICronwatchJob> resolve)
{
    public string Name { get; } = name;

    public JobOptions Options { get; } = options;

    public Type Type { get; } = type;

    public Func<IServiceProvider, ICronwatchJob> Resolve { get; } = resolve;
}

/// <summary>
/// The one hosted service that runs every <c>AddCronwatchJob</c> job at its schedule's fire
/// times, on the client's clock: each fire a run with the trigger <c>hosting</c>, its class
/// resolved from a new scope, a fire that comes while the previous run is still going skipped.
/// The jobs are declared as the host starts, and the first fire waits for the host to have
/// started. Stopping cancels the runs' tokens and waits for them to be recorded.
/// </summary>
internal sealed partial class HostedJobs : IHostedService, IDisposable
{
    /// <summary>
    /// The trigger each fire's run records: the integration's name, as every integration's is.
    /// Runs recorded before 0.11 carry <c>schedule</c>; nothing reads it back.
    /// </summary>
    internal const string Trigger = "hosting";

    /// <summary>The longest a timer is armed for at once; a later fire is waited for in steps.</summary>
    private static readonly TimeSpan LongestWait = TimeSpan.FromDays(1);

    private readonly IReadOnlyList<HostedJob> _jobs;
    private readonly CronwatchClient _cw;
    private readonly IServiceScopeFactory _scopes;
    private readonly ILogger<HostedJobs> _log;
    private readonly IHostApplicationLifetime? _lifetime;
    private readonly CancellationTokenSource _stopping = new();
    private readonly ConcurrentDictionary<Task, byte> _runs = new();
    private Task? _loops;

    /// <summary>Told each job's next fire as its loop starts waiting for it; the tests' gate.</summary>
    internal Action<string, long>? Waiting { get; set; }

    /// <summary>How many runs are under way; the tests wait for none before the next fire.</summary>
    internal int Running => _runs.Count;

    public HostedJobs(IEnumerable<HostedJob> jobs, CronwatchClient cw, IServiceScopeFactory scopes, ILogger<HostedJobs> log, IHostApplicationLifetime? lifetime = null)
    {
        _jobs = [.. jobs];
        _cw = cw;
        _scopes = scopes;
        _log = log;
        _lifetime = lifetime;
    }

    public Task StartAsync(CancellationToken cancellationToken)
    {
        var declared = new List<(HostedJob Hosted, Job Job)>();
        foreach (HostedJob h in _jobs)
        {
            // A bad name or schedule stops the host here, with the SDK's message.
            declared.Add((h, _cw.Job(h.Name, h.Options)));
        }
        CancellationToken stop = _stopping.Token;
        // Without the flow of the host's start, so nothing it held (a log scope, an activity, an
        // AsyncLocal of the app's) reaches every run for the life of the app.
        using var suppressed = ExecutionContext.SuppressFlow();
        _loops = Task.Run(
            async () =>
            {
                await HostStartedAsync(stop).ConfigureAwait(false);
                var loops = new List<Task>();
                foreach (var (hosted, job) in declared)
                {
                    loops.Add(LoopAsync(hosted, job, stop));
                }
                await Task.WhenAll(loops).ConfigureAwait(false);
            },
            CancellationToken.None);
        return Task.CompletedTask;
    }

    private async Task HostStartedAsync(CancellationToken stop)
    {
        if (_lifetime == null)
        {
            return;
        }
        var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using (_lifetime.ApplicationStarted.Register(() => started.TrySetResult()))
        using (stop.Register(() => started.TrySetCanceled(stop)))
        {
            await started.Task.ConfigureAwait(false);
        }
    }

    private async Task LoopAsync(HostedJob hosted, Job job, CancellationToken stop)
    {
        TimeProvider clock = _cw.Clock;
        long start = _cw.NowMs;
        long? lastFire = null;
        Task? running = null;
        string? runningId = null;
        string? loggedFor = null;
        while (!stop.IsCancellationRequested)
        {
            long now = _cw.NowMs;
            long from = lastFire is long last ? Math.Max(last, now) : start;
            long? next;
            try
            {
                next = job.NextFire(from, lastFire);
            }
            catch (Exception e)
            {
                _cw.ReportError(e, "scheduling " + hosted.Name);
                return;
            }
            if (next is not long fire)
            {
                return; // the schedule never fires again
            }
            // Told once the first timer is armed, so a clock moved after the telling fires it.
            bool told = false;
            while (true)
            {
                now = _cw.NowMs;
                Task? delay = now < fire
                    ? Task.Delay(TimeSpan.FromMilliseconds(Math.Min(fire - now, LongestWait.TotalMilliseconds)), clock, stop)
                    : null;
                if (!told)
                {
                    told = true;
                    Waiting?.Invoke(hosted.Name, fire);
                }
                if (delay == null)
                {
                    break;
                }
                await delay.ConfigureAwait(false);
            }
            lastFire = fire;
            if (running is { IsCompleted: false })
            {
                if (loggedFor != runningId)
                {
                    loggedFor = runningId;
                    Skipped(_log, hosted.Name, runningId!, null);
                }
                continue;
            }
            string id = runningId = Guid.NewGuid().ToString();
            // Counted before it starts and uncounted only once its task has completed, so no run
            // is under way whenever Running is 0, and the next fire is never skipped for it.
            var begin = new Task<Task>(() => RunOnceAsync(hosted, job, id, stop));
            running = begin.Unwrap();
            _runs.TryAdd(running, 0);
            _ = running.ContinueWith(
                static (t, runs) => ((ConcurrentDictionary<Task, byte>)runs!).TryRemove(t, out _),
                _runs,
                CancellationToken.None,
                TaskContinuationOptions.ExecuteSynchronously,
                TaskScheduler.Default);
            // Off the loop, so the loop keeps the schedule while the job runs.
            begin.Start(TaskScheduler.Default);
        }
    }

    private async Task RunOnceAsync(HostedJob hosted, Job job, string id, CancellationToken stop)
    {
        AsyncServiceScope scope = _scopes.CreateAsyncScope();
        await using (scope.ConfigureAwait(false))
        {
            try
            {
                await job.RunAsync(
                    new RunOptions { Trigger = Trigger, Id = id },
                    (ctx, ct) => hosted.Resolve(scope.ServiceProvider).RunAsync(ctx, ct),
                    stop).ConfigureAwait(false);
            }
            catch (Exception)
            {
                // A failed run, recorded and alerted by the client.
            }
        }
    }

    public async Task StopAsync(CancellationToken cancellationToken)
    {
        await _stopping.CancelAsync().ConfigureAwait(false);
        var wait = new List<Task>(_runs.Keys);
        if (_loops != null)
        {
            wait.Add(_loops);
        }
        try
        {
            await Task.WhenAll(wait).WaitAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            // Stopped, or the host's shutdown timeout passed: the client records what is left.
        }
        // The runs started meanwhile, if any, are recorded by the client when it is disposed.
    }

    public void Dispose() => _stopping.Dispose();

    [LoggerMessage(EventId = 1, Level = LogLevel.Warning, Message = "cronwatch: {Job} is still running its run {RunId}, so its fires are skipped until it ends")]
    private static partial void Skipped(ILogger logger, string job, string runId, Exception? error);
}
