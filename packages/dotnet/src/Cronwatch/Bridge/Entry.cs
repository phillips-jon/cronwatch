using System;

namespace Cronwatch.Bridge;

/// <summary>One job a scheduler runs, as an integration reads it.</summary>
public sealed class Entry
{
    /// <summary>An entry.</summary>
    /// <param name="name">The job's name.</param>
    /// <param name="label">Names the entry in messages: <c>Quartz job "reports.nightly"</c>.</param>
    /// <param name="schedule">The scheduler's schedule as CronWatch reads it, <c>""</c> for none.</param>
    /// <param name="timezone">The zone the schedule is read in, <c>""</c> for the process's own.</param>
    /// <param name="problem">
    /// Why an entry with a schedule of its own has none here, or a note about the one it has:
    /// reported once; null for none.
    /// </param>
    /// <param name="defaults">
    /// The integration's options for every job, applied before the schedule, as the SDK spreads a
    /// client's defaults first.
    /// </param>
    /// <param name="options">
    /// The options the app gave this entry, applied after the schedule, so a schedule among them
    /// replaces the scheduler's.
    /// </param>
    public Entry(string name, string label, string schedule, string timezone, string? problem = null, JobOptions? defaults = null, JobOptions? options = null)
    {
        Name = name ?? throw new ArgumentNullException(nameof(name));
        Label = label ?? throw new ArgumentNullException(nameof(label));
        Schedule = schedule ?? throw new ArgumentNullException(nameof(schedule));
        Timezone = timezone ?? throw new ArgumentNullException(nameof(timezone));
        Problem = problem;
        Defaults = defaults?.Copy() ?? new JobOptions();
        Options = options?.Copy() ?? new JobOptions();
    }

    /// <summary>The job's name.</summary>
    public string Name { get; }

    /// <summary>Names the entry in messages.</summary>
    public string Label { get; }

    /// <summary>The schedule as CronWatch reads it, <c>""</c> for none.</summary>
    public string Schedule { get; }

    /// <summary>The zone the schedule is read in, <c>""</c> for the process's own.</summary>
    public string Timezone { get; }

    /// <summary>A problem to report once, or null.</summary>
    public string? Problem { get; }

    /// <summary>The integration's options for every job.</summary>
    public JobOptions Defaults { get; }

    /// <summary>The app's options for this entry.</summary>
    public JobOptions Options { get; }

    /// <summary>Names the entry and its schedule.</summary>
    public override string ToString() => "Entry(" + Name + ", " + (Schedule.Length == 0 ? "no schedule" : Schedule) + (Timezone.Length == 0 ? "" : " in " + Timezone) + ")";
}
