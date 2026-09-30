using System;

namespace Cronwatch.Internal;

/// <summary>
/// What the evaluation needs of durations and schedules, in one place, so the pure functions
/// reach the duration and schedule code through these calls alone. Each forwards to a function
/// set once; binding them to <c>Durations</c> and <c>Schedules</c> is a matter of writing these
/// bodies as direct calls.
/// </summary>
internal static class EvaluateDeps
{
    /// <summary><c>Durations.ParseValue(value, label)</c>: a stored duration (text or milliseconds) in milliseconds.</summary>
    internal static Func<object?, string, double>? ParseDurationImpl;

    /// <summary><c>Durations.Format(ms)</c>: <c>"1m 30s"</c>.</summary>
    internal static Func<double, string>? FormatDurationImpl;

    /// <summary><c>Schedules.Parse(text, zone)</c>: a parsed schedule, opaque here.</summary>
    internal static Func<string, string?, object>? ParseScheduleImpl;

    /// <summary>Whether a parsed schedule is an interval (<c>every 5m</c>) rather than a cron.</summary>
    internal static Func<object, bool>? IsIntervalImpl;

    /// <summary><c>Schedules.Expectation(parsed, lastRunAt, createdAt, graceMs)</c>: the run due and its deadline, or null.</summary>
    internal static Func<object, long?, long, double, (long DueAt, double Deadline)?>? ExpectationImpl;

    /// <summary><c>Schedules.NextFire(parsed, from, lastRunAt)</c>.</summary>
    internal static Func<object, long, long?, long?>? NextFireImpl;

    private static T Bound<T>(T? f, string name)
        where T : class => f ?? throw new InvalidOperationException("EvaluateDeps." + name + " is not bound");

    /// <summary>A stored duration value in milliseconds, or the SDK's message as an <see cref="ArgumentException"/>.</summary>
    public static double ParseDuration(object? value, string label) => Bound(ParseDurationImpl, nameof(ParseDurationImpl))(value, label);

    /// <summary><c>formatDuration</c>.</summary>
    public static string FormatDuration(double ms) => Bound(FormatDurationImpl, nameof(FormatDurationImpl))(ms);

    /// <summary><c>parseSchedule</c>, or the SDK's message as an <see cref="ArgumentException"/>.</summary>
    public static object ParseSchedule(string text, string? zone) => Bound(ParseScheduleImpl, nameof(ParseScheduleImpl))(text, zone);

    /// <summary>Whether the parsed schedule is an interval.</summary>
    public static bool IsInterval(object parsed) => Bound(IsIntervalImpl, nameof(IsIntervalImpl))(parsed);

    /// <summary><c>expectation</c>.</summary>
    public static (long DueAt, double Deadline)? Expectation(object parsed, long? lastRunAt, long createdAt, double graceMs) =>
        Bound(ExpectationImpl, nameof(ExpectationImpl))(parsed, lastRunAt, createdAt, graceMs);

    /// <summary><c>nextFire</c>.</summary>
    public static long? NextFire(object parsed, long from, long? lastRunAt) => Bound(NextFireImpl, nameof(NextFireImpl))(parsed, from, lastRunAt);
}
