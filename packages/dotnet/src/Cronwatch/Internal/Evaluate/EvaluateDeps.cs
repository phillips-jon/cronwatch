using System;

namespace Cronwatch.Internal;

/// <summary>
/// What the evaluation needs of durations and schedules, in one place, so the pure functions
/// reach the duration and schedule code through these calls alone.
/// </summary>
/// <remarks>
/// A cron without a zone is read in the client's local zone (its <see cref="TimeProvider"/>'s),
/// which the evaluation does not otherwise carry: the client runs each evaluation synchronously
/// inside <see cref="InZone{T}"/>, which holds the zone on the calling thread for that call only.
/// </remarks>
internal static class EvaluateDeps
{
    [ThreadStatic]
    private static TimeZoneInfo? _local;

    /// <summary>Runs <paramref name="work"/> with <paramref name="local"/> as the zone a cron without one is read in.</summary>
    public static T InZone<T>(TimeZoneInfo? local, Func<T> work)
    {
        TimeZoneInfo? previous = _local;
        _local = local;
        try
        {
            return work();
        }
        finally
        {
            _local = previous;
        }
    }

    /// <summary>The zone a cron without one is read in: the client's, else the system's.</summary>
    public static TimeZoneInfo? LocalZone => _local;

    /// <summary>A stored duration value in milliseconds, or the SDK's message as an <see cref="ArgumentException"/>.</summary>
    public static double ParseDuration(object? value, string label) => Durations.ParseValue(value, label);

    /// <summary><c>formatDuration</c>.</summary>
    public static string FormatDuration(double ms) => Durations.Format(ms);

    /// <summary><c>parseSchedule</c>, or the SDK's message as an <see cref="ArgumentException"/>.</summary>
    public static ParsedSchedule ParseSchedule(string text, string? zone) => Schedules.Parse(text, zone, _local);

    /// <summary>Whether the parsed schedule is an interval.</summary>
    public static bool IsInterval(ParsedSchedule parsed) => parsed.IsInterval;

    /// <summary><c>expectation</c>.</summary>
    public static (long DueAt, double Deadline)? Expectation(ParsedSchedule parsed, long? lastRunAt, long createdAt, double graceMs)
    {
        var e = Schedules.GetExpectation(parsed, lastRunAt, createdAt, graceMs);
        return e is { } x ? (x.DueAt, x.Deadline) : null;
    }

    /// <summary><c>nextFire</c>.</summary>
    public static long? NextFire(ParsedSchedule parsed, long from, long? lastRunAt) => Schedules.NextFire(parsed, from, lastRunAt);
}
