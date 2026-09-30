using Cronwatch.Internal;

namespace Cronwatch;

/// <summary>A declared job's schedule, read as the checks read it.</summary>
public sealed partial class Job
{
    /// <summary>
    /// The next time the job's schedule fires strictly after <paramref name="after"/> (epoch
    /// milliseconds), from the croner port in the job's zone (the client clock's local zone when it
    /// has none); for an interval (<c>every 5m</c>), <paramref name="lastRunAt"/> plus the interval,
    /// or <paramref name="after"/> plus it when there is no run yet. Null when the job has no
    /// schedule or its cron never fires again. For a scheduler of the app's own that runs the job
    /// on the schedule CronWatch watches, as <c>AddCronwatchJob</c> in <c>Cronwatch.Hosting</c> does.
    /// </summary>
    public long? NextFire(long after, long? lastRunAt = null)
    {
        Definition def = Def.Stored;
        if (def.Schedule is not { Length: > 0 } schedule)
        {
            return null;
        }
        ParsedSchedule parsed = Schedules.Parse(schedule, def.Timezone, _client.LocalZone);
        return Schedules.NextFire(parsed, after, lastRunAt);
    }
}
