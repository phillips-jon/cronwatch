using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Globalization;

namespace Cronwatch.Internal;

/// <summary>
/// Zones are <see cref="TimeZoneInfo"/>'s, named as <c>Intl</c> names them: without regard to
/// case, so "america/new_york" is New York. The name is matched against the port's own list of
/// IANA names (<see cref="ZoneNames"/>) and <see cref="TimeZoneInfo"/> is asked for it as the
/// list spells it, since on Linux and macOS it matches case. A fixed offset ("+05:30", "-0800",
/// "+05") is a zone too, since <c>Intl</c> and croner both take one.
/// </summary>
internal static class CronZones
{
    /// <summary>Every IANA name the list has, by its lowercase spelling.</summary>
    private static readonly Dictionary<string, string> Names = BuildNames();

    /// <summary>What each name was found as, or null when the system lacks it.</summary>
    private static readonly ConcurrentDictionary<string, TimeZoneInfo?> Found = new(StringComparer.Ordinal);

    private static Dictionary<string, string> BuildNames()
    {
        var output = new Dictionary<string, string>(ZoneNames.All.Length, StringComparer.Ordinal);
        foreach (string id in ZoneNames.All)
        {
            output[AsciiLower(id)] = id;
        }
        return output;
    }

    /// <summary>ASCII letters lowercased; every IANA name is ASCII.</summary>
    private static string AsciiLower(string s)
    {
        char[]? chars = null;
        for (int i = 0; i < s.Length; i++)
        {
            char c = s[i];
            if (c >= 'A' && c <= 'Z')
            {
                chars ??= s.ToCharArray();
                chars[i] = (char)(c + 32);
            }
        }
        return chars == null ? s : new string(chars);
    }

    /// <summary>
    /// The zone an IANA name (or a fixed offset) names, matched without regard to case; ""
    /// is <paramref name="local"/>, else the system's own zone. Null when there is no such zone,
    /// or when the list has the name and the system does not.
    /// </summary>
    public static TimeZoneInfo? Find(string name, TimeZoneInfo? local = null)
    {
        if (name.Length == 0)
        {
            return local ?? TimeZoneInfo.Local;
        }
        TimeSpan? fixedOffset = FixedOffset(name);
        if (fixedOffset is TimeSpan offset)
        {
            return Found.GetOrAdd(name, n => TimeZoneInfo.CreateCustomTimeZone(n, offset, n, n));
        }
        // Only ASCII names can be on the list; anything else is lowercased the way Intl would
        // still not find it.
        if (!Names.TryGetValue(AsciiLower(name), out string? id))
        {
            return null;
        }
        return Found.GetOrAdd(id, System);
    }

    private static TimeZoneInfo? System(string id)
    {
        try
        {
            return TimeZoneInfo.FindSystemTimeZoneById(id);
        }
        catch (TimeZoneNotFoundException)
        {
            return null;
        }
        catch (InvalidTimeZoneException)
        {
            return null;
        }
    }

    /// <summary>Reads "+HH", "+HHMM", or "+HH:MM" (or "-"), as <c>Intl</c> reads an offset time zone.</summary>
    private static TimeSpan? FixedOffset(string name)
    {
        if (name.Length < 3 || (name[0] != '+' && name[0] != '-'))
        {
            return null;
        }
        string rest = name[1..];
        string hh;
        string mm;
        if (rest.Length == 2)
        {
            hh = rest;
            mm = "00";
        }
        else if (rest.Length == 4)
        {
            hh = rest[..2];
            mm = rest[2..];
        }
        else if (rest.Length == 5 && rest[2] == ':')
        {
            hh = rest[..2];
            mm = rest[3..];
        }
        else
        {
            return null;
        }
        foreach (char c in hh + mm)
        {
            if (c < '0' || c > '9')
            {
                return null;
            }
        }
        int h = int.Parse(hh, NumberStyles.None, CultureInfo.InvariantCulture);
        int m = int.Parse(mm, NumberStyles.None, CultureInfo.InvariantCulture);
        if (h > 23 || m > 59)
        {
            return null;
        }
        var span = new TimeSpan(h, m, 0);
        return name[0] == '-' ? -span : span;
    }

    // The instants a DateTimeOffset holds, in epoch seconds; the offset of a time outside them is
    // the offset at the nearer end.
    private const long MinSecond = -62_135_596_800L;
    private const long MaxSecond = 253_402_300_799L;

    /// <summary>The seconds a zone's wall clock is ahead of UTC at epoch second <paramref name="sec"/>.</summary>
    public static long Offset(long sec, TimeZoneInfo zone)
    {
        if (ReferenceEquals(zone, TimeZoneInfo.Utc))
        {
            return 0;
        }
        long at = Math.Max(MinSecond, Math.Min(MaxSecond, sec));
        TimeSpan offset = zone.GetUtcOffset(DateTimeOffset.FromUnixTimeSeconds(at));
        return (long)Math.Floor(offset.TotalSeconds);
    }

    /// <summary>The wall clock at an epoch second: year, month (1 to 12), day, hour, minute, second.</summary>
    public static long[] WallAt(long sec, TimeZoneInfo zone)
    {
        long local = sec + Offset(sec, zone);
        long days = Js.FloorDiv(local, 86_400);
        long rest = local - days * 86_400;
        var (y, m, d) = Js.CivilFromDays(days);
        return [y, m, d, rest / 3600, rest % 3600 / 60, rest % 60];
    }

    /// <summary>A wall-clock time read as if it were UTC, in epoch seconds (croner's <c>T()</c>).</summary>
    private static long CivilSeconds(long[] w) => Js.FloorDiv(Js.DateUtc(w[0], w[1] - 1, w[2], w[3], w[4], w[5], 0), 1000);

    private static bool Same(long[] a, long[] b) => a.AsSpan().SequenceEqual(b);

    /// <summary>
    /// Croner's <c>fromTZ</c>: the instant a wall-clock time names, in epoch seconds. A time in a
    /// spring-forward gap moves forward by the gap; a time that happens twice (fall back) is the
    /// earlier of the two.
    /// </summary>
    public static long ToUtc(long[] w, TimeZoneInfo zone)
    {
        long target = CivilSeconds(w);
        long guess = target + (target - CivilSeconds(WallAt(target, zone)));
        long[] seen = WallAt(guess, zone);
        if (Same(seen, w))
        {
            long earlier = guess - 3600;
            if (Same(WallAt(earlier, zone), w))
            {
                return earlier;
            }
            return guess;
        }
        long shifted = guess + target - CivilSeconds(seen);
        if (Same(WallAt(shifted, zone), w))
        {
            return shifted;
        }
        return Math.Max(guess, shifted);
    }
}
