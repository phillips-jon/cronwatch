using System;
using System.Collections.Concurrent;
using System.Collections.Generic;

namespace Cronwatch.Internal;

/// <summary>What kind of schedule a <see cref="ParsedSchedule"/> is.</summary>
internal enum ScheduleKind
{
    Cron,
    Interval,
}

/// <summary>
/// A schedule as <c>parseSchedule</c> returns it: a cron (with the zone it is read in, when one
/// was given) or an interval (with its period in milliseconds; 0 for a cron). Two are equal when
/// these four are; the croner expression behind a cron is carried beside them.
/// </summary>
internal sealed record ParsedSchedule(ScheduleKind Kind, string Source, string? Timezone, double EveryMs)
{
    /// <summary>The croner expression behind a cron, walked in its zone; null for an interval.</summary>
    internal CronExpression? Cron { get; init; }

    /// <summary>Whether this is "every duration" rather than a cron.</summary>
    public bool IsInterval => Kind == ScheduleKind.Interval;

    /// <inheritdoc/>
    public bool Equals(ParsedSchedule? other) =>
        other is not null && Kind == other.Kind && string.Equals(Source, other.Source, StringComparison.Ordinal)
        && string.Equals(Timezone, other.Timezone, StringComparison.Ordinal) && EveryMs.Equals(other.EveryMs);

    /// <inheritdoc/>
    public override int GetHashCode() => HashCode.Combine(Kind, StringComparer.Ordinal.GetHashCode(Source), EveryMs);
}

/// <summary>When the next run is due, and when it is missed.</summary>
internal readonly record struct Expectation(long DueAt, double Deadline);

/// <summary>
/// The SDK's <c>schedule.ts</c>: schedules ("0 2 * * *", "@hourly", "every 5m") with their fire
/// times, due times, deadlines and what a run covers. Cron fire times come from the port of
/// croner, so a .NET process and a Node, Ruby, Python, PHP, Go, Rust, Elixir or Java process
/// sharing one store agree on every due time. Refusals are <see cref="ArgumentException"/>s with
/// the SDK's message.
/// </summary>
internal static class Schedules
{
    /// <summary>How early a run may start and still count for the fire it was meant for.</summary>
    public const long EarlySlackMs = 60_000;

    /// <summary>
    /// The longest interval kept, 2^53 ms: added to any time the SDK meets it stays well inside a
    /// <c>long</c>. A longer "every" is read as this long, which fires no sooner in any run's
    /// lifetime.
    /// </summary>
    public const double MaxIntervalMs = 9_007_199_254_740_992.0;

    private const int CacheLimit = 10_000;
    private static readonly ConcurrentDictionary<string, ParsedSchedule> Cache = new(StringComparer.Ordinal);

    /// <summary>
    /// <c>parseSchedule</c>: a cron of five or six fields, a nickname, or "every 5m". Each
    /// (schedule, timezone) pair is parsed once and kept. Without a timezone (null or "") a cron
    /// is read in <paramref name="local"/>, else the system's zone, as crontab reads the system's.
    /// </summary>
    /// <exception cref="ArgumentException">With the SDK's message.</exception>
    public static ParsedSchedule Parse(string schedule, string? timezone, TimeZoneInfo? local = null)
    {
        string zone = timezone ?? "";
        TimeZoneInfo? home = zone.Length == 0 ? local ?? TimeZoneInfo.Local : null;
        // The local zone is part of the key: two clients with clocks in different zones read one
        // cron differently.
        string key = (home == null ? "" : home.Id + "\u0001") + zone + "|" + schedule;
        if (Cache.TryGetValue(key, out var hit))
        {
            return hit;
        }
        ParsedSchedule parsed = ParseUncached(schedule, zone, home);
        // A long-running process parses a handful of schedules; the bound only keeps one fed
        // endless distinct schedules from growing without end.
        if (Cache.Count >= CacheLimit)
        {
            Cache.Clear();
        }
        Cache[key] = parsed;
        return parsed;
    }

    private static ParsedSchedule ParseUncached(string schedule, string zone, TimeZoneInfo? home)
    {
        string text = Js.Trim(schedule);
        string? rest = Every(text);
        if (rest != null)
        {
            double ms = Durations.Parse(rest, "schedule interval");
            if (ms < 1000)
            {
                throw new ArgumentException("schedule \"" + schedule + "\" is shorter than one second");
            }
            return new ParsedSchedule(ScheduleKind.Interval, text, null, Math.Min(ms, MaxIntervalMs));
        }
        TimeZoneInfo? tz = home ?? CronZones.Find(zone);
        CronExpression cron;
        try
        {
            cron = CronExpression.Parse(text, tz ?? TimeZoneInfo.Utc);
        }
        catch (CronException e)
        {
            throw new ArgumentException("schedule \"" + schedule + "\" is not a cron expression or \"every <duration>\": " + e.Message, e);
        }
        if (tz == null)
        {
            throw new ArgumentException("CronDate: Failed to convert date to timezone '" + zone
                + "'. This may happen with invalid timezone names or dates. Original error: toTZ:"
                + " Invalid timezone '" + zone
                + "' or date. Please provide a valid IANA timezone (e.g., 'America/New_York',"
                + " 'Europe/Stockholm'). Original error: Invalid time zone specified: " + zone);
        }
        return new ParsedSchedule(ScheduleKind.Cron, text, zone.Length == 0 ? null : zone, 0) { Cron = cron };
    }

    /// <summary>The croner expression behind a cron schedule.</summary>
    private static CronExpression CronOf(ParsedSchedule p) =>
        p.Cron ?? throw new ArgumentException("schedule \"" + p.Source + "\" was not made by parseSchedule");

    /// <summary>
    /// <c>/^every\s+(.+)$/i</c>: "every" in any ASCII case, whitespace, and the rest, which must
    /// hold no line terminator (JavaScript's "." matches none). Null when it does not match.
    /// </summary>
    private static string? Every(string text)
    {
        if (text.Length < 5)
        {
            return null;
        }
        const string word = "every";
        for (int k = 0; k < 5; k++)
        {
            char c = text[k];
            if (c >= 'A' && c <= 'Z')
            {
                c = (char)(c + 32);
            }
            if (c != word[k])
            {
                return null;
            }
        }
        int i = 5;
        while (i < text.Length && Js.IsSpace(text[i]))
        {
            i++;
        }
        if (i == 5 || i == text.Length)
        {
            return null;
        }
        string rest = text[i..];
        foreach (char c in rest)
        {
            if (c == '\n' || c == '\r' || c == (char)0x2028 || c == (char)0x2029)
            {
                return null;
            }
        }
        return rest;
    }

    /// <summary>
    /// Four hundred Gregorian years: 146,097 days, a whole number of weeks, after which the
    /// calendar repeats date for date and weekday for weekday.
    /// </summary>
    private const long CycleMs = 146_097L * 86_400_000L;

    /// <summary>0400-01-01T00:00:00Z: croner misreads a year below 100, so an earlier time is asked later.</summary>
    private const long CronerFirstMs = -49_544_438_400_000L;

    /// <summary>2800-01-01T00:00:00Z: croner finds no fire past 3000, so a later time is asked earlier.</summary>
    private const long CronerLastMs = 26_192_246_400_000L;

    /// <summary>
    /// <c>runsAfter</c>: the next <paramref name="n"/> fires of a cron strictly after
    /// <paramref name="from"/>, which lies within the years 1 to 9999, dropping any after 9999. A
    /// time croner cannot answer for is moved by whole 400-year cycles into the years it can, and
    /// its fires moved back: a time before 400 goes forward, into the same local mean time every
    /// zone kept then, and one from 2800 goes back, to where the zone's present rules already hold.
    /// </summary>
    public static List<long> RunsAfter(CronExpression cron, int n, long from)
    {
        long shift = 0;
        if (from < CronerFirstMs)
        {
            long gap = CronerFirstMs - from;
            shift = (gap / CycleMs + (gap % CycleMs != 0 ? 1 : 0)) * CycleMs;
        }
        else if (from >= CronerLastMs)
        {
            shift = -((from - CronerLastMs) / CycleMs + 1) * CycleMs;
        }
        var output = new List<long>(n);
        foreach (long t in cron.NextRuns(n, from + shift))
        {
            long back = t - shift;
            if (back > Js.LastDateMs)
            {
                break;
            }
            output.Add(back);
        }
        return output;
    }

    /// <summary>
    /// <c>countFrom</c>: a stored time as a cron's fires are counted from it. A start read from a
    /// foreign or damaged row can be any number: one before the year 1 counts from just before its
    /// first millisecond, so the first fire of the year 1 is the next one, and one at or after the
    /// last millisecond of 9999 has no fire after it at all (null). No fire is ever after 9999.
    /// </summary>
    public static long? CountFrom(long from)
    {
        if (from >= Js.LastDateMs)
        {
            return null;
        }
        return Math.Max(from, Js.FirstDateMs - 1);
    }

    /// <summary>
    /// The first fire strictly after <paramref name="from"/>, or null when the cron never fires
    /// again. croner answers with times in the past when asked from inside the hour that repeats
    /// when clocks go back, so its answers are filtered, and a stretch of nothing but past times is
    /// stepped over an hour at a time.
    /// </summary>
    private static long? FireAfter(CronExpression cron, long from)
    {
        if (CountFrom(from) is not long start)
        {
            return null;
        }
        long probe = start;
        for (int attempt = 0; attempt < 4; attempt++)
        {
            List<long> runs = RunsAfter(cron, 8, probe);
            if (runs.Count == 0)
            {
                return null;
            }
            foreach (long t in runs)
            {
                if (t > start)
                {
                    return t;
                }
            }
            probe += 3_600_000L;
        }
        return null;
    }

    /// <summary>
    /// <c>firesBetween</c>: every fire of a cron strictly after <paramref name="from"/> and at or
    /// before <paramref name="to"/>, ascending, or null when there are more than
    /// <paramref name="limit"/>. Fires are asked for in batches, and any that do not move forward
    /// are dropped.
    /// </summary>
    public static List<long>? FiresBetween(ParsedSchedule parsed, long from, long to, int limit)
    {
        CronExpression cron = CronOf(parsed);
        var output = new List<long>();
        if (CountFrom(from) is not long start)
        {
            return output;
        }
        long probe = start;
        long last = start;
        for (int guard = 0; guard < 1000; guard++)
        {
            List<long> batch = RunsAfter(cron, Math.Min(limit + 1 - output.Count, 24), probe);
            if (batch.Count == 0)
            {
                return output;
            }
            foreach (long t in batch)
            {
                if (t <= last)
                {
                    continue;
                }
                if (t > to)
                {
                    return output;
                }
                output.Add(t);
                last = t;
                if (output.Count > limit)
                {
                    return null;
                }
            }
            long end = batch[^1];
            probe = end > probe ? end : probe + 3_600_000L;
        }
        return output;
    }

    /// <summary>A time plus an interval, held at the ends of a <c>long</c> rather than wrapping.</summary>
    private static long Add(long a, double ms)
    {
        long b = (long)ms;
        long sum = unchecked(a + b);
        if (((a ^ sum) & (b ^ sum)) < 0)
        {
            return a < 0 ? long.MinValue : long.MaxValue;
        }
        return sum;
    }

    /// <summary>
    /// <c>nextFire</c>: the next time the schedule fires strictly after <paramref name="from"/>;
    /// for an interval, counted from the last run when there is one. Null when a cron never fires
    /// again.
    /// </summary>
    public static long? NextFire(ParsedSchedule parsed, long from, long? lastRunAt)
    {
        if (parsed.IsInterval)
        {
            return Add(lastRunAt ?? from, parsed.EveryMs);
        }
        return FireAfter(CronOf(parsed), from);
    }

    /// <summary>
    /// <c>expectation</c>: when the schedule next wants a run, given the last one. For a cron that
    /// is the first fire the last run does not already cover; with no run yet, the first fire at or
    /// after registration. For an interval it is the last run's start (or registration) plus the
    /// interval. Null for a cron that never fires again.
    /// </summary>
    public static Expectation? GetExpectation(ParsedSchedule parsed, long? lastRunAt, long registeredAt, double graceMs)
    {
        long? due;
        if (parsed.IsInterval)
        {
            due = Add(lastRunAt ?? registeredAt, parsed.EveryMs);
        }
        else if (lastRunAt is not long last)
        {
            due = FireAfter(CronOf(parsed), registeredAt == long.MinValue ? registeredAt : registeredAt - 1);
        }
        else
        {
            due = DueAfterRun(parsed, last);
        }
        return due is long d ? new Expectation(d, d + graceMs) : null;
    }

    /// <summary>
    /// The first fire that a run starting at <paramref name="startedAt"/> does not cover. A start
    /// before the year 1 covers none of them, so the first fire of the year 1 is due; after 9999
    /// there is none.
    /// </summary>
    private static long? DueAfterRun(ParsedSchedule parsed, long startedAt)
    {
        CronExpression cron = CronOf(parsed);
        // A fire at or before the start is covered by the run itself.
        if (FireAfter(cron, startedAt) is not long next)
        {
            return null;
        }
        long? following = FireAfter(cron, next);
        bool covers = RunCovers(startedAt, next, following) || InSpringForwardGap(cron, startedAt, next);
        return covers ? following : next;
    }

    /// <summary>
    /// <c>runCovers</c>: whether a run starting at <paramref name="startedAt"/> covers the fire at
    /// <paramref name="dueAt"/>. A minute of slack before the tick absorbs schedulers that fire a
    /// touch early. When the fire after <paramref name="dueAt"/> is known, the slack is at most
    /// half the gap between the two, so one run of an every-minute cron never covers two fires.
    /// </summary>
    public static bool RunCovers(long startedAt, long dueAt, long? followingAt)
    {
        long slack = followingAt is long following
            ? Math.Min(EarlySlackMs, Js.FloorDiv(following - dueAt, 2))
            : EarlySlackMs;
        return startedAt >= dueAt - slack;
    }

    /// <summary>
    /// On the night clocks spring forward, a fire whose local time does not exist (02:30 when
    /// 02:00 jumps to 03:00) is moved by croner to the same distance past the jump (03:30), while
    /// vixie cron runs it at the jump itself (03:00). A run that starts at or after the jump, and
    /// before the first fire after it when that fire lies within one gap of it, is taken to cover
    /// that fire, so neither scheduler's run is reported as missed.
    /// </summary>
    private static bool InSpringForwardGap(CronExpression cron, long startedAt, long fireAt)
    {
        const long lookback = 3 * 3_600_000L;
        // Every zone kept its local mean time, with no clock change, in the year 1.
        if (fireAt - lookback < Js.FirstDateMs)
        {
            return false;
        }
        long after = UtcOffset(fireAt, cron);
        long before = UtcOffset(fireAt - lookback, cron);
        long gap = after - before;
        if (gap <= 0)
        {
            return false;
        }
        // Find the jump: the first minute in the window with the later offset.
        long lo = fireAt - lookback;
        long hi = fireAt;
        while (hi - lo > 60_000)
        {
            long mid = lo + (hi - lo) / 2;
            if (UtcOffset(mid, cron) == after)
            {
                hi = mid;
            }
            else
            {
                lo = mid;
            }
        }
        long jumpAt = Js.FloorDiv(hi, 60_000L) * 60_000L;
        if (fireAt - jumpAt >= gap || startedAt < jumpAt - EarlySlackMs || startedAt >= fireAt)
        {
            return false;
        }
        // Only the first fire after the jump can be a moved one; a cron that also fires at the
        // jump (every 10 minutes, say) was not moved at all.
        return FireAfter(cron, jumpAt - 1) == fireAt;
    }

    /// <summary>The milliseconds the zone's wall clock is ahead of UTC at <paramref name="at"/>.</summary>
    private static long UtcOffset(long at, CronExpression cron) => CronZones.Offset(Js.FloorDiv(at, 1000), cron.Zone) * 1000;

    /// <summary>
    /// Whether <c>new Intl.DateTimeFormat("en-US", { timeZone })</c> accepts the name: an IANA
    /// zone, matched without regard to case, or a fixed offset such as "+05:30".
    /// </summary>
    public static bool IsZone(string name) => name.Length != 0 && CronZones.Find(name) != null;
}
