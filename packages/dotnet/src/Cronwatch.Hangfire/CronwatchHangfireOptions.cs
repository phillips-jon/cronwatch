using System;
using System.Collections.Generic;
using System.Diagnostics;
using Hangfire;

namespace Cronwatch.Hangfire;

/// <summary>
/// Options for <see cref="CronwatchHangfire"/>. Nothing here is a secret; <see cref="ToString"/>
/// names what is set.
/// </summary>
[DebuggerDisplay("{ToString(),nq}")]
public sealed class CronwatchHangfireOptions
{
    /// <summary>
    /// Names the app in its tag (<c>hangfire:&lt;app&gt;</c>) and in its runs' ids, so two apps
    /// sharing a store never declare each other's jobs without a schedule. Every server of one app
    /// needs the same. Default: <c>CRONWATCH_APP_ID</c>, else the entry assembly's name (which is
    /// the Generic Host's application name unless the app set another).
    /// </summary>
    public string? App { get; init; }

    /// <summary>Job options for every job, before its schedule and its own options.</summary>
    public JobOptions? JobDefaults { get; init; }

    /// <summary>
    /// Job options for one job, by its CronWatch name (a recurring job's id), after its schedule,
    /// so a schedule given here replaces the cron's.
    /// </summary>
    public IDictionary<string, JobOptions> Jobs { get; init; } = new Dictionary<string, JobOptions>(StringComparer.Ordinal);

    /// <summary>
    /// Jobs that are not recurring to watch, by the method's full name
    /// (<c>Example.Imports.Run</c>, its type's full name and the method's name) and the
    /// CronWatch name to record them under, for a method the app cannot mark with
    /// <see cref="CronwatchJobAttribute"/>. A job that is neither recurring nor named is not
    /// watched, so a queue of a million email jobs is not a million runs.
    /// </summary>
    public IDictionary<string, string> Named { get; init; } = new Dictionary<string, string>(StringComparer.Ordinal);

    /// <summary>How often the recurring jobs are read again. Default a minute.</summary>
    public TimeSpan ReadEvery { get; init; } = TimeSpan.FromMinutes(1);

    /// <summary>The storage whose recurring jobs are read. Default <see cref="JobStorage.Current"/> when it is read.</summary>
    public JobStorage? Storage { get; init; }

    /// <summary>Names what is set.</summary>
    public override string ToString() =>
        "CronwatchHangfireOptions(app " + (App ?? "default") + ", " + Jobs.Count + " jobs, " + Named.Count + " named, readEvery " + ReadEvery + ")";
}

/// <summary>
/// Watches a job that is not recurring under a CronWatch name: every attempt of a job whose method
/// carries it is recorded as a run of that job.
/// </summary>
/// <param name="name">The CronWatch job name.</param>
[AttributeUsage(AttributeTargets.Method, AllowMultiple = false)]
public sealed class CronwatchJobAttribute(string name) : Attribute
{
    /// <summary>The CronWatch job name.</summary>
    public string Name { get; } = name ?? throw new ArgumentNullException(nameof(name));
}
