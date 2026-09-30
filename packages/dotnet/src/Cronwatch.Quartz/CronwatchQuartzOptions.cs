using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;

namespace Cronwatch.Quartz;

/// <summary>
/// Options for <see cref="CronwatchQuartz"/>: the app's name for its tag and its runs' ids, job
/// options for every job and for each, how often the scheduler's jobs are read again, and whether
/// the check is scheduled as a Quartz job.
/// </summary>
[DebuggerDisplay("{ToString(),nq}")]
public sealed class CronwatchQuartzOptions
{
    private TimeSpan _readEvery = TimeSpan.FromMinutes(1);
    private TimeSpan _checkEvery = TimeSpan.FromMinutes(1);

    /// <summary>
    /// Names the app in its tag (<c>quartz:&lt;app&gt;</c>) and in its runs' ids, so two apps
    /// sharing a store never declare each other's jobs without a schedule or share a run id. Every
    /// node of one app needs the same. Default: <c>CRONWATCH_APP_ID</c>, else the host's
    /// application name, else the entry assembly's name.
    /// </summary>
    public string? App { get; set; }

    /// <summary>Job options for every job, before its schedule and its own options.</summary>
    public JobOptions? JobDefaults { get; set; }

    /// <summary>
    /// Job options for one job, by its CronWatch name (<c>nightlyReport</c> for a job in the
    /// <c>DEFAULT</c> group, <c>reports.nightly</c> for <c>nightly</c> in <c>reports</c>), after its
    /// schedule, so a schedule given here replaces the trigger's.
    /// </summary>
    public IDictionary<string, JobOptions> Jobs { get; } = new Dictionary<string, JobOptions>(StringComparer.Ordinal);

    /// <summary>How often the scheduler's jobs are read again besides when it says they changed. Default a minute.</summary>
    public TimeSpan ReadEvery
    {
        get => _readEvery;
        set => _readEvery = value > TimeSpan.Zero ? value : throw new ArgumentOutOfRangeException(nameof(value), "ReadEvery must be longer than zero");
    }

    /// <summary>
    /// Schedules <see cref="CronwatchCheckJob"/> on the scheduler, a sync and a CronWatch check once
    /// per <see cref="CheckEvery"/> across a cluster, in place of the client's own interval on
    /// every node. Default false.
    /// </summary>
    public bool ScheduleCheck { get; set; }

    /// <summary>How often the check job runs. Default a minute, five seconds at least.</summary>
    public TimeSpan CheckEvery
    {
        get => _checkEvery;
        set => _checkEvery = value >= TimeSpan.FromSeconds(5) ? value : throw new ArgumentOutOfRangeException(nameof(value), "CheckEvery must be five seconds or longer");
    }

    /// <summary>Names what is set.</summary>
    public override string ToString() =>
        "CronwatchQuartzOptions(app " + (App ?? "default") + ", " + Jobs.Count.ToString(CultureInfo.InvariantCulture) + " jobs, readEvery "
        + ReadEvery.ToString("c", CultureInfo.InvariantCulture) + (ScheduleCheck ? ", scheduleCheck" : "") + ")";
}
