using System;
using System.Threading.Tasks;
using Hangfire;

namespace Cronwatch.Hangfire;

/// <summary>
/// CronWatch's check as a Hangfire recurring job, added with
/// <see cref="CronwatchHangfire.ScheduleCheck(IRecurringJobManager, string)"/>: a sync and a check,
/// once per minute across every server sharing the storage, since Hangfire enqueues a recurring job
/// once per fire. Never retried, never run twice at once, and its runs are never a job. On a server
/// that does not watch Hangfire, it does nothing.
/// </summary>
public static class CronwatchCheckJob
{
    /// <summary>Runs the sync and the check. Never throws.</summary>
    [AutomaticRetry(Attempts = 0)]
    [DisableConcurrentExecution(60)]
    public static Task RunAsync() => CronwatchHangfire.Active is { } integration ? integration.CheckNowAsync() : Task.CompletedTask;
}

/// <summary>Watching Hangfire from its configuration.</summary>
public static class CronwatchGlobalConfigurationExtensions
{
    /// <summary>
    /// Watches Hangfire with <paramref name="cw"/> for the life of the process (see
    /// <see cref="CronwatchHangfire.Start"/>, which answers an integration the app can stop).
    /// </summary>
    public static IGlobalConfiguration UseCronwatch(this IGlobalConfiguration configuration, CronwatchClient cw, CronwatchHangfireOptions? options = null)
    {
        ArgumentNullException.ThrowIfNull(configuration);
#pragma warning disable CA2000 // Kept for the life of the process, as Hangfire's own global filters are.
        CronwatchHangfire.Start(cw, options);
#pragma warning restore CA2000
        return configuration;
    }

    /// <summary>
    /// Watches Hangfire with the <see cref="CronwatchClient"/> the app's container holds, for
    /// <c>services.AddHangfire((sp, c) =&gt; c.UseCronwatch(sp))</c>, for the life of the process.
    /// </summary>
    /// <exception cref="InvalidOperationException">When the container holds no client.</exception>
    public static IGlobalConfiguration UseCronwatch(this IGlobalConfiguration configuration, IServiceProvider services, CronwatchHangfireOptions? options = null)
    {
        ArgumentNullException.ThrowIfNull(configuration);
        ArgumentNullException.ThrowIfNull(services);
        var cw = services.GetService(typeof(CronwatchClient)) as CronwatchClient
            ?? throw new InvalidOperationException("UseCronwatch needs a CronwatchClient in the container: add one with AddCronwatch or AddSingleton");
#pragma warning disable CA2000 // Kept for the life of the process, as Hangfire's own global filters are.
        CronwatchHangfire.Start(cw, options);
#pragma warning restore CA2000
        return configuration;
    }
}
