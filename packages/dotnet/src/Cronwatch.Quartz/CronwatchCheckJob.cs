using System.Threading;
using System.Threading.Tasks;
using Quartz;

namespace Cronwatch.Quartz;

/// <summary>
/// CronWatch's check as a Quartz job, scheduled with <see cref="CronwatchQuartz.ScheduleCheckAsync"/>
/// or <see cref="CronwatchQuartzOptions.ScheduleCheck"/>: a sync (the scheduler's jobs declared
/// again, the declarations written, and jobs gone from it declared again without their schedule,
/// within 30 seconds) and a check, once per firing across a cluster. Its runs are never a job. On
/// a node that does not watch the scheduler, it does nothing. It never throws.
/// </summary>
[DisallowConcurrentExecution]
public sealed class CronwatchCheckJob : IJob
{
    /// <inheritdoc/>
    public async ValueTask Execute(IJobExecutionContext context, CancellationToken cancellationToken)
    {
        if (context.Scheduler.Context.TryGetValue(CronwatchQuartz.ContextKey, out object? found) && found is CronwatchQuartz q)
        {
            await q.CheckNowAsync(cancellationToken).ConfigureAwait(false);
        }
    }
}
