using System;
using System.Collections.Generic;
using System.Diagnostics;

namespace Cronwatch.PgCron;

/// <summary>
/// How a <see cref="PgCronSource"/> watches pg_cron: the SDK's <c>PgCronOptions</c>, with its
/// <c>jobs</c> as <see cref="Jobs"/>, <see cref="JobIds"/> and <see cref="Pick"/>, and its
/// <c>options</c> as <see cref="Options"/> or <see cref="OptionsFor"/>, as the other typed ports
/// have them. Checked when the source is made.
/// </summary>
/// <example>
/// <code>
/// new PgCronOptions { Prefix = "db:", Jobs = ["nightly vacuum", "rollup"], Options = new JobOptions { Grace = "5m" } }
/// </code>
/// </example>
[DebuggerDisplay("{ToString(),nq}")]
public sealed class PgCronOptions
{
    /// <summary>
    /// Watches the jobs of these names (with <see cref="JobIds"/>, a job either names). Default
    /// every job the role can see.
    /// </summary>
    public IReadOnlyList<string>? Jobs { get; init; }

    /// <summary>
    /// Watches the jobs of these ids (with <see cref="Jobs"/>, a job either names). Default every
    /// job the role can see.
    /// </summary>
    public IReadOnlyList<long>? JobIds { get; init; }

    /// <summary>Watches the jobs this answers true for, in place of <see cref="Jobs"/> and <see cref="JobIds"/>.</summary>
    public Func<PgCronJob, bool>? Pick { get; init; }

    /// <summary>
    /// Goes before every job name, to keep them apart from the app's own (<c>"db:"</c>). It also
    /// keeps run ids apart. Default none.
    /// </summary>
    public string Prefix { get; init; } = "";

    /// <summary>
    /// The CronWatch name for a job. Default <see cref="PgCronSource.DefaultJobName"/>: its jobname
    /// with anything other than letters, digits, <c>.</c>, <c>_</c>, <c>:</c> and <c>-</c> turned
    /// into <c>-</c>, or <c>pg_cron:&lt;jobid&gt;</c> when it has none. The prefix goes in front
    /// either way. One that throws or answers null, like a <see cref="Pick"/> or
    /// <see cref="OptionsFor"/> that throws, is reported once and fails only that job, which keeps
    /// its last declaration until the function works again.
    /// </summary>
    public Func<PgCronJob, string?>? JobName { get; init; }

    /// <summary>
    /// Grace, timeout, maxDuration, expect and the rest, for every job. The schedule and timezone
    /// always come from pg_cron, so options that set either are refused.
    /// </summary>
    public JobOptions? Options { get; init; }

    /// <summary>
    /// The options for each job, as a function of the job. Options that set a schedule or
    /// timezone are reported and the job is not declared.
    /// </summary>
    public Func<PgCronJob, JobOptions?>? OptionsFor { get; init; }

    /// <summary>
    /// The zone pg_cron reads its cron expressions in. Default the server's <c>cron.timezone</c>,
    /// read from <c>pg_settings</c>, which shows it only to roles with
    /// <c>pg_read_all_settings</c>; UTC (pg_cron's default) is assumed when it cannot be read.
    /// </summary>
    public string? Timezone { get; init; }

    /// <summary>The refusals, checked when the source is made; they never quote a value.</summary>
    internal void Check()
    {
        if (Pick != null && (Jobs != null || JobIds != null))
        {
            throw CronwatchException.Invalid("PgCronOptions: give Pick, or Jobs and JobIds, not both");
        }
        if (Options != null && OptionsFor != null)
        {
            throw CronwatchException.Invalid("PgCronOptions: give Options or OptionsFor, not both");
        }
        if (Options != null && FromPgCron(Options))
        {
            throw CronwatchException.Invalid(OptionsRefusal);
        }
        ArgumentNullException.ThrowIfNull(Prefix);
    }

    internal const string OptionsRefusal = "PgCronOptions: Options may not set a schedule or timezone; they come from pg_cron";

    /// <summary>Whether options set what only pg_cron gives: a schedule or a timezone.</summary>
    internal static bool FromPgCron(JobOptions options)
    {
        var fields = options.Fields();
        return fields.Has("schedule") || fields.Has("timezone");
    }

    /// <summary>Names what is set, never a value.</summary>
    public override string ToString()
    {
        var set = new List<string>();
        if (Jobs != null)
        {
            set.Add("Jobs");
        }
        if (JobIds != null)
        {
            set.Add("JobIds");
        }
        if (Pick != null)
        {
            set.Add("Pick");
        }
        if (!string.IsNullOrEmpty(Prefix))
        {
            set.Add("Prefix");
        }
        if (JobName != null)
        {
            set.Add("JobName");
        }
        if (Options != null)
        {
            set.Add("Options");
        }
        if (OptionsFor != null)
        {
            set.Add("OptionsFor");
        }
        if (!string.IsNullOrEmpty(Timezone))
        {
            set.Add("Timezone");
        }
        return "PgCronOptions(" + string.Join(", ", set) + ")";
    }
}
