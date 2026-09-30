using System;

namespace Cronwatch.Internal;

/// <summary>
/// Croner's CronDate: a wall-clock time whose fields are moved forward to the next match, a field
/// at a time, spilling into the next month or year as croner does. The fields are year, month (0
/// based), day, hour, minute, second and milliseconds.
/// </summary>
internal sealed class CronDate
{
    private static readonly long[] DaysInMonth = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];

    // The fields of a date, by index.
    private const int Year = 0;
    private const int Month = 1;
    private const int Day = 2;
    private const int Hour = 3;
    private const int Minute = 4;
    private const int Second = 5;
    private const int Millis = 6;

    /// <summary>
    /// A step of the walk: the field, the field above it, and the offset from a field value to its
    /// pattern index (croner's fieldOrder).
    /// </summary>
    private readonly record struct Step(int Field, int Above, CronKind K, long Offset);

    private static readonly Step[] Order =
    [
        new(Month, Year, CronKind.Month, 0),
        new(Day, Month, CronKind.Day, -1),
        new(Hour, Day, CronKind.Hour, 0),
        new(Minute, Hour, CronKind.Minute, 0),
        new(Second, Minute, CronKind.Second, 0),
    ];

    private readonly long[] _f;

    private CronDate(long[] f)
    {
        _f = f;
    }

    /// <summary><c>new CronDate(new Date(at), tz)</c>.</summary>
    public static CronDate FromMs(long at, TimeZoneInfo zone)
    {
        long sec = Js.FloorDiv(at, 1000);
        long[] w = CronZones.WallAt(sec, zone);
        return new CronDate([w[0], w[1] - 1, w[2], w[3], w[4], w[5], at - sec * 1000]);
    }

    /// <summary>
    /// Croner's <c>getLastDayOfMonth</c>, month 0 based; -1 for a month outside 0 to 11 (croner's
    /// undefined).
    /// </summary>
    private static long LastDayOfMonth(long year, long month)
    {
        if (month != 1)
        {
            return month >= 0 && month < 12 ? DaysInMonth[(int)month] : -1;
        }
        return Js.CivilFromDays(Js.FloorDiv(Js.DateUtc(year, month + 1, 0, 0, 0, 0, 0), 86_400_000L)).Day;
    }

    /// <summary><c>new Date(Date.UTC(year, month, day)).getUTCDay()</c>, month 0 based. 0 is Sunday.</summary>
    private static long Weekday(long year, long month, long day) =>
        Js.FloorMod(Js.FloorDiv(Js.DateUtc(year, month, day, 0, 0, 0, 0), 86_400_000L) + 4, 7);

    /// <summary>
    /// Croner's <c>apply()</c>: fields out of their range are carried into the fields above, as a
    /// Date made from them would be. It says whether it changed anything.
    /// </summary>
    private bool Apply()
    {
        long month = _f[Month];
        bool outside = month < 0 || month >= 12 || _f[Day] > DaysInMonth[(int)month] || _f[Day] < 1
            || _f[Hour] > 59 || _f[Minute] > 59 || _f[Second] > 59 || _f[Hour] < 0 || _f[Minute] < 0
            || _f[Second] < 0;
        if (!outside)
        {
            return false;
        }
        long at = Js.DateUtc(_f[Year], month, _f[Day], _f[Hour], _f[Minute], _f[Second], _f[Millis]);
        long sec = Js.FloorDiv(at, 1000);
        long days = Js.FloorDiv(sec, 86_400);
        long rest = sec - days * 86_400;
        var (y, m, d) = Js.CivilFromDays(days);
        _f[Year] = y;
        _f[Month] = m - 1;
        _f[Day] = d;
        _f[Hour] = rest / 3600;
        _f[Minute] = rest % 3600 / 60;
        _f[Second] = rest % 60;
        _f[Millis] = at - sec * 1000;
        return true;
    }

    private static long LastWeekdayOf(long year, long month)
    {
        long last = Math.Max(LastDayOfMonth(year, month), 0);
        long wd = Weekday(year, month, last);
        if (wd == 0)
        {
            return last - 2;
        }
        if (wd == 6)
        {
            return last - 1;
        }
        return last;
    }

    private static long NearestWeekday(long year, long month, long day)
    {
        long last = LastDayOfMonth(year, month);
        if (last >= 0 && day > last)
        {
            return -1;
        }
        long wd = Weekday(year, month, day);
        if (wd == 0)
        {
            return last == day ? day - 2 : day + 1;
        }
        if (wd == 6)
        {
            return day == 1 ? day + 2 : day - 1;
        }
        return day;
    }

    private static bool IsNthWeekday(long year, long month, long day, int bits)
    {
        long wd = Weekday(year, month, day);
        int count = 0;
        for (long x = 1; x <= day; x++)
        {
            if (Weekday(year, month, x) == wd)
            {
                count++;
            }
        }
        if ((bits & CronPattern.AnyBits) != 0 && count >= 1 && count <= CronPattern.NthBits.Length
            && (CronPattern.NthBits[count - 1] & bits) != 0)
        {
            return true;
        }
        if ((bits & CronPattern.LastBit) != 0)
        {
            long last = Math.Max(LastDayOfMonth(year, month), 0);
            for (long x = day + 1; x <= last; x++)
            {
                if (Weekday(year, month, x) == wd)
                {
                    return false;
                }
            }
            return true;
        }
        return false;
    }

    /// <summary>
    /// Croner's <c>findNext</c>: 1 when the field already matches, 2 when it was moved forward to
    /// a match, 3 when none is left in its range.
    /// </summary>
    private int FindNext(CronPattern p, Step s)
    {
        long before = _f[s.Field];
        int[] table = p.Table(s.K);
        long size = table.Length;
        long year = _f[Year];
        long month = _f[Month];
        long last = p.LastDayOfMonth ? LastDayOfMonth(year, month) : -2;
        long firstWeekday = !p.StarDow && s.K == CronKind.Day ? Weekday(year, month, 1) : 0;
        bool isDay = s.K == CronKind.Day;
        for (long u = before + s.Offset; u < size; u++)
        {
            int matched = u >= 0 ? table[(int)u] : 0;
            long value = u - s.Offset;
            if (isDay && matched == 0)
            {
                for (int c = 0; c < p.NearestWeekdaysTable.Length; c++)
                {
                    if (p.NearestWeekdaysTable[c] != 0)
                    {
                        long m = NearestWeekday(year, month, c - s.Offset);
                        if (m == -1)
                        {
                            continue;
                        }
                        if (m == value)
                        {
                            matched = 1;
                            break;
                        }
                    }
                }
            }
            if (isDay && p.LastWeekday && value == LastWeekdayOf(year, month))
            {
                matched = 1;
            }
            if (isDay && p.LastDayOfMonth && last >= 0 && last == value)
            {
                matched = 1;
            }
            if (isDay && !p.StarDow)
            {
                int bits = p.DayOfWeekTable[(int)Js.FloorMod(firstWeekday + (value - 1), 7)];
                if (bits != 0 && (bits & CronPattern.AnyBits) != 0)
                {
                    bits = IsNthWeekday(year, month, value, bits) ? 1 : 0;
                }
                else if (bits != 0)
                {
                    throw new CronException("CronDate: Invalid value for dayOfWeek encountered. " + Js.FormatLong(bits));
                }
                if (p.UseAndLogic)
                {
                    if (matched != 0)
                    {
                        matched = bits;
                    }
                }
                else if (!p.StarDom)
                {
                    if (matched == 0)
                    {
                        matched = bits;
                    }
                }
                else if (matched != 0)
                {
                    matched = bits;
                }
            }
            if (matched != 0)
            {
                _f[s.Field] = value;
                return before != _f[s.Field] ? 2 : 1;
            }
        }
        return 3;
    }

    /// <summary>
    /// Croner's <c>recurse()</c>, walked in a loop: each field in turn from the month down is moved
    /// to its next match, a field that runs out carries into the one above and the walk starts
    /// again from the month. Croner recurses a year at a time, so for a date no month has it runs
    /// out of stack; the loop answers false (never) at the year croner gives up at.
    /// </summary>
    private bool Recurse(CronPattern p)
    {
        const long years = 10_000;
        int n = Order.Length;
        int level = 0;
        while (true)
        {
            if (level == 0 && !p.StarYear)
            {
                long y = _f[Year];
                if (y >= 0 && y < years && !p.HasYear(y))
                {
                    long found = -1;
                    for (long x = y + 1; x < years; x++)
                    {
                        if (p.HasYear(x))
                        {
                            found = x;
                            break;
                        }
                    }
                    if (found < 0)
                    {
                        return false;
                    }
                    _f[Year] = found;
                    _f[Month] = 0;
                    _f[Day] = 1;
                    _f[Hour] = 0;
                    _f[Minute] = 0;
                    _f[Second] = 0;
                    _f[Millis] = 0;
                }
                if (_f[Year] >= years)
                {
                    return false;
                }
            }
            // A level below 0 counts from the end, as croner's own array lookup of it does.
            Step s = Order[(int)Js.FloorMod(level, n)];
            int result = FindNext(p, s);
            if (result > 1)
            {
                for (int i = level + 1; i < n; i++)
                {
                    Step below = Order[(int)Js.FloorMod(i, n)];
                    _f[below.Field] = -below.Offset;
                }
                if (result == 3)
                {
                    _f[s.Above] += 1;
                    _f[s.Field] = -s.Offset;
                    Apply();
                    if (level == 0 && !p.StarYear)
                    {
                        while (_f[Year] >= 0 && _f[Year] < years && !p.HasYear(_f[Year]))
                        {
                            _f[Year] += 1;
                        }
                        if (_f[Year] >= years)
                        {
                            return false;
                        }
                    }
                    level = 0;
                    continue;
                }
                if (Apply())
                {
                    level -= 1;
                    continue;
                }
            }
            level += 1;
            if (level >= n)
            {
                return true;
            }
            if ((p.StarYear && _f[Year] >= 3000) || (!p.StarYear && _f[Year] >= years))
            {
                return false;
            }
        }
    }

    /// <summary>Croner's <c>increment()</c>: one second on, then the next match. False when there is none.</summary>
    public bool Increment(CronPattern p)
    {
        _f[Second] += 1;
        _f[Millis] = 0;
        Apply();
        return Recurse(p);
    }

    /// <summary><c>getDate(false).getTime()</c>: the instant this wall-clock time names.</summary>
    public long TimeMs(TimeZoneInfo zone) =>
        CronZones.ToUtc([_f[Year], _f[Month] + 1, _f[Day], _f[Hour], _f[Minute], _f[Second]], zone) * 1000;
}
