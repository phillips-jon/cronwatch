using System;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Quartz;

namespace Cronwatch.Quartz;

/// <summary>CronWatch on a Quartz scheduler built with <c>services.AddQuartz(...)</c> or <c>QuartzSchedulerBuilder</c>.</summary>
public static class QuartzBuilderExtensions
{
    /// <summary>
    /// Watches the scheduler this builder makes, with the <see cref="CronwatchClient"/> in the
    /// host's container (<c>services.AddCronwatch(...)</c>): its jobs are declared when it starts
    /// and every firing is recorded, with <see cref="CronwatchClient.Current"/> and
    /// <c>job.Log</c> working inside each job. <c>services.AddQuartz(q =&gt; q.UseCronwatch())</c>.
    /// </summary>
    public static IQuartzBuilder UseCronwatch(this IQuartzBuilder builder, Action<CronwatchQuartzOptions>? configure = null) =>
        Use(builder, null, configure);

    /// <summary>
    /// <see cref="UseCronwatch(IQuartzBuilder, Action{CronwatchQuartzOptions})"/> with a client of
    /// the app's own, for a scheduler built without the host's container
    /// (<c>QuartzSchedulerBuilder.Create(q =&gt; q.UseCronwatch(cw))</c>).
    /// </summary>
    public static IQuartzBuilder UseCronwatch(this IQuartzBuilder builder, CronwatchClient cw, Action<CronwatchQuartzOptions>? configure = null)
    {
        ArgumentNullException.ThrowIfNull(cw);
        return Use(builder, cw, configure);
    }

    private static IQuartzBuilder Use(IQuartzBuilder builder, CronwatchClient? cw, Action<CronwatchQuartzOptions>? configure)
    {
        ArgumentNullException.ThrowIfNull(builder);
        var options = new CronwatchQuartzOptions();
        configure?.Invoke(options);
        var holder = new Holder(cw, options);
        builder.AddJobListener(sp => holder.Get(sp).JobListener, [Matchers.AllJobs()]);
        builder.AddSchedulerListener(sp => holder.Get(sp).SchedulerListener);
        builder.AddJobMiddleware(new CurrentRunMiddleware());
        return builder;
    }

    /// <summary>The one integration a builder's scheduler gets, made from its container the first time a listener is asked for.</summary>
    private sealed class Holder(CronwatchClient? cw, CronwatchQuartzOptions options)
    {
        private readonly Lock _lock = new();
        private CronwatchQuartz? _made;

        public CronwatchQuartz Get(IServiceProvider services)
        {
            lock (_lock)
            {
                return _made ??= new CronwatchQuartz(
                    cw ?? services.GetRequiredService<CronwatchClient>(),
                    options,
                    services.GetService<IHostEnvironment>()?.ApplicationName);
            }
        }
    }

    /// <summary>
    /// Makes the firing's run <see cref="CronwatchClient.Current"/> around the job, so it flows into
    /// everything the job awaits, and keeps the attempt's failure for a refire to report. A firing
    /// with no run passes through.
    /// </summary>
    private sealed class CurrentRunMiddleware : IJobExecutionMiddleware
    {
        public async ValueTask Invoke(IJobExecutionContext context, JobExecutionDelegate next, CancellationToken cancellationToken)
        {
            if (CronwatchQuartz.FiringOf(context) is not { } firing)
            {
                await next(context, cancellationToken).ConfigureAwait(false);
                return;
            }
            using (firing.Run.MakeCurrent())
            {
                try
                {
                    await next(context, cancellationToken).ConfigureAwait(false);
                }
                catch (Exception e)
                {
                    firing.Failure = e;
                    throw;
                }
            }
        }
    }
}

/// <summary>A firing's run, for a job whose scheduler is watched.</summary>
public static class QuartzContextExtensions
{
    /// <summary>
    /// The run CronWatch opened for this firing, or null when it opened none (the job is not
    /// watched, or its start could not be recorded). For a job in a scheduler watched with
    /// <see cref="CronwatchQuartz.WatchAsync"/>, where <see cref="CronwatchClient.Current"/> is not
    /// set: <c>using (context.CronwatchRun()?.MakeCurrent()) { ... }</c>.
    /// </summary>
    public static ObservedRun? CronwatchRun(this IJobExecutionContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        return CronwatchQuartz.FiringOf(context)?.Run;
    }
}
