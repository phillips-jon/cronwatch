using System;
using System.Collections.Generic;
using System.Globalization;
using Cronwatch.Internal;

namespace Cronwatch.Bridge;

/// <summary>
/// The check that a schedule taken from a scheduler (Cronos's reading of a Hangfire cron,
/// Quartz's <c>CronExpression</c>) makes CronWatch expect runs exactly when the scheduler makes
/// them: the scheduler's own runs, from its own code, walked beside CronWatch's fires around every
/// clock change in the next few years and from the start of each month of a sample year, so the
/// answer does not depend on when the app starts.
/// </summary>
/// <remarks>
/// Between two runs of the scheduler, CronWatch must not want one of its own, or it would report
/// it missed: a fire CronWatch has and the scheduler does not is refused unless the run before it
/// covers it. Away from clock changes every run the scheduler makes must also be one CronWatch
/// expects; near one, the scheduler may run a repeated time twice, which CronWatch takes as an
/// early run. The Go port's <c>bridge/check.go</c> through the Java port's <c>Checker</c>, line
/// for line; the zone's clock changes are found by a walk of the offsets, since
/// <see cref="TimeZoneInfo"/> has no list of its transitions.
/// </remarks>
internal sealed class Checker
{
    private const long HorizonYears = 5;
    private const long ChangeWindowMs = 2 * 86_400_000L;
    private const long SampleYear = 2026;
    private const long DayMs = 86_400_000L;

    private readonly FireTimes _runs;
    private readonly ParsedSchedule _parsed;
    private readonly TimeZoneInfo _tz;
    private readonly string _zone;
    private readonly string _where;
    private readonly string _scheduler;

    private Checker(FireTimes runs, ParsedSchedule parsed, TimeZoneInfo tz, string zone, string where, string scheduler)
    {
        _runs = runs;
        _parsed = parsed;
        _tz = tz;
        _zone = zone;
        _where = where;
        _scheduler = scheduler;
    }

    public static void Check(FireTimes runs, string expr, string zone, string where, string scheduler, bool daily, long now)
    {
        ParsedSchedule parsed;
        try
        {
            parsed = Schedules.Parse(expr, zone.Length == 0 ? null : zone);
        }
        catch (ArgumentException e)
        {
            throw new ScheduleException(where + " is " + Json.Quote(expr) + ", which CronWatch cannot read: " + e.Message);
        }
        TimeZoneInfo? tz = CronZones.Find(zone);
        if (tz == null)
        {
            throw new ScheduleException(where + ": timezone " + Json.Quote(zone) + " is not an IANA timezone");
        }
        var checker = new Checker(runs, parsed, tz, zone, where + " is " + Json.Quote(expr), scheduler);
        try
        {
            checker.Run(daily, now);
        }
        catch (ScheduleException e) when (e.Never)
        {
            throw new ScheduleException(checker._where + ", which never fires: " + e.Message);
        }
    }

    private readonly record struct Transition(long At, long Before, long After);

    private long OffsetAt(long ms) => CronZones.Offset(Js.FloorDiv(ms, 1000), _tz);

    /// <summary>
    /// The zone's clock changes after one instant and at or before another, epoch milliseconds:
    /// the offsets walked an hour at a time, and each change found to the second.
    /// </summary>
    private List<Transition> Transitions(long startMs, long endMs)
    {
        const long Step = 3_600_000L;
        var found = new List<Transition>();
        long at = startMs;
        long before = OffsetAt(at);
        while (at < endMs)
        {
            long next = Math.Min(at + Step, endMs);
            long after = OffsetAt(next);
            if (after != before)
            {
                long lo = at;
                long hi = next;
                while (hi - lo > 1000)
                {
                    long mid = lo + ((hi - lo) / 2);
                    if (OffsetAt(mid) == before)
                    {
                        lo = mid;
                    }
                    else
                    {
                        hi = mid;
                    }
                }
                // The offset is read a second at a time, and lo and hi lie in neighbouring seconds
                // or one: the change is the second hi lies in.
                long change = Js.FloorDiv(hi, 1000) * 1000;
                if (change > startMs && change <= endMs)
                {
                    found.Add(new Transition(change, before, after));
                }
                before = after;
            }
            at = next;
        }
        return found;
    }

    private static long YearStart(long year) => Js.DateUtc(year, 0, 1, 0, 0, 0, 0);

    private void Run(bool daily, long now)
    {
        long year = CronZones.WallAt(Js.FloorDiv(now, 1000), TimeZoneInfo.Utc)[0];
        var seen = new HashSet<(long, long)>();
        foreach (Transition change in Transitions(YearStart(year), YearStart(year + HorizonYears + 1)))
        {
            var kind = (Js.FloorMod((change.At / 1000) + change.Before, 86_400L), change.After - change.Before);
            if (daily && seen.Contains(kind))
            {
                continue;
            }
            seen.Add(kind);
            long start = change.At - ChangeWindowMs;
            long end = start + (2 * ChangeWindowMs);
            // Near a change only CronWatch's own fires can be refused, so a stretch where it has
            // none needs no walk.
            long? first = Schedules.NextFire(_parsed, start - 1, null);
            if (first == null || first > end)
            {
                continue;
            }
            Compare(_runs(start, end), strict: false);
        }

        long? comparedUntil = null;
        for (int month = 0; month < 12; month++)
        {
            long start = Js.DateUtc(SampleYear, month, 1, 0, 0, 0, 0);
            if (comparedUntil is long until && start < until)
            {
                continue; // a sparse cron's earlier sample reached past this month
            }
            IReadOnlyList<long> found = _runs(start, null);
            if (found.Count == 0)
            {
                continue;
            }
            long last = found[^1];
            comparedUntil = last;
            bool near = Transitions(found[0] - DayMs, last + DayMs).Count > 0;
            Compare(found, strict: !near);
        }
    }

    /// <summary>CronWatch's fires after <paramref name="start"/>, up to and including <paramref name="end"/>.</summary>
    private List<long> Fires(long start, long end)
    {
        var output = new List<long>();
        long at = start;
        while (true)
        {
            long? fire = Schedules.NextFire(_parsed, at, null);
            if (fire is not long f || f > end)
            {
                return output;
            }
            output.Add(f);
            at = f;
        }
    }

    /// <summary>The first fire a run starting at <paramref name="at"/> does not cover, or null.</summary>
    private long? DueAfterRun(long at) => Schedules.GetExpectation(_parsed, at, at, 0)?.DueAt;

    private void Compare(IReadOnlyList<long> runs, bool strict)
    {
        if (runs.Count < 2)
        {
            return;
        }
        List<long> fires = Fires(runs[0], runs[^1]);
        HashSet<long> expected = strict ? new HashSet<long>(fires) : [];
        int i = 0;
        for (int k = 0; k + 1 < runs.Count; k++)
        {
            long at = runs[k];
            long following = runs[k + 1];
            while (i < fires.Count && fires[i] <= at)
            {
                i++;
            }
            bool own = i >= fires.Count || fires[i] < following;
            bool unexpected = strict && !expected.Contains(following);
            if (!own && !unexpected)
            {
                continue;
            }
            long? due = DueAfterRun(at);
            if (!unexpected && due is long d && d >= following)
            {
                continue;
            }
            throw Mismatch(at, following, due);
        }
    }

    private string ZoneName => _zone.Length == 0 ? "the process's zone" : _zone;

    private string Stamp(long ms)
    {
        long[] w = CronZones.WallAt(Js.FloorDiv(ms, 1000), _tz);
        return string.Create(CultureInfo.InvariantCulture, $"{w[0]:D4}-{w[1]:D2}-{w[2]:D2} {w[3]:D2}:{w[4]:D2}:{w[5]:D2}");
    }

    private ScheduleException Mismatch(long at, long following, long? due)
    {
        Transition? skipped = null;
        if (due is long d)
        {
            foreach (Transition change in Transitions(d - DayMs, d + 1000))
            {
                long gap = change.After - change.Before;
                if (gap > 0 && d < change.At + (gap * 1000))
                {
                    skipped = change;
                    break;
                }
            }
        }
        if (skipped is not Transition s)
        {
            string expected = due is long e ? Stamp(e) : "nothing";
            return new ScheduleException(
                _where + " in " + ZoneName + ", but after a run at " + Stamp(at) + " " + _scheduler + " runs it next at "
                + Stamp(following) + " and CronWatch would expect " + expected
                + ", so it cannot be converted exactly; give the job a schedule of its own");
        }
        long[] old = CronZones.WallAt(Js.FloorDiv(s.At + (s.Before * 1000), 1000), TimeZoneInfo.Utc);
        long[] moved = CronZones.WallAt(Js.FloorDiv(s.At + (s.After * 1000), 1000), TimeZoneInfo.Utc);
        string day = string.Create(CultureInfo.InvariantCulture, $"{old[0]:D4}-{old[1]:D2}-{old[2]:D2}");
        string from = string.Create(CultureInfo.InvariantCulture, $"{old[3]:D2}:{old[4]:D2}");
        string to = string.Create(CultureInfo.InvariantCulture, $"{moved[3]:D2}:{moved[4]:D2}");
        return new ScheduleException(
            _where + ", due at a time that does not exist in " + ZoneName + " on " + day + ", when clocks go forward from "
            + from + " to " + to + ". " + _scheduler + " does not run it then and CronWatch would expect it at " + Stamp(due ?? 0)
            + ", so it would be reported missed. Move the time outside the change, give the schedule a zone without daylight"
            + " saving (such as UTC), or give the job a schedule of its own");
    }
}
