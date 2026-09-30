using System.Collections.Generic;
using System.Globalization;

namespace Cronwatch.Tests;

/// <summary>
/// Cron expressions for the parity check and the properties: valid and not, nicknames, names,
/// ranges, steps, lists, L, W, LW, #, ?, +, six and seven fields. The generator is the Go, Python,
/// PHP, Rust and Java ports', over SplitMix64, so a seed gives the same expressions in every port.
/// </summary>
internal sealed class CronFuzzer(ulong seed)
{
    public static readonly string[] Zones =
    [
        "", "UTC", "America/New_York", "Europe/London", "Australia/Lord_Howe", "America/Santiago",
        "Asia/Kolkata", "Pacific/Chatham", "Europe/Berlin",
    ];

    private static readonly string[] Months = ["jan", "FEB", "Mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"];
    private static readonly string[] Days = ["sun", "MON", "Tue", "wed", "thu", "fri", "sat"];
    private static readonly string[] Nicknames = ["@yearly", "@annually", "@monthly", "@weekly", "@daily", "@midnight", "@hourly", "@HOURLY", "@reboot", "@every"];

    private ulong _state = seed;

    /// <summary>SplitMix64: small, seeded and the same on every platform.</summary>
    public ulong Next()
    {
        _state += 0x9e3779b97f4a7c15UL;
        ulong z = _state;
        z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9UL;
        z = (z ^ (z >> 27)) * 0x94d049bb133111ebUL;
        return z ^ (z >> 31);
    }

    public double Chance() => (Next() >> 11) / (double)(1UL << 53);

    public long Between(long lo, long hi) => lo + (long)(Next() % (ulong)(hi - lo + 1));

    public T Pick<T>(T[] items) => items[(int)(Next() % (ulong)items.Length)];

    private static string S(long n) => n.ToString(CultureInfo.InvariantCulture);

    /// <summary>One cron field: mostly valid, sometimes out of range or malformed.</summary>
    public string Field(long low, long high, string[] names)
    {
        long size = high - low + 1;
        double kind = Chance();
        if (kind < 0.3)
        {
            return "*";
        }
        if (kind < 0.45)
        {
            return Value(low, high, names);
        }
        if (kind < 0.6)
        {
            var (a, b) = Pair(low, high);
            if (Chance() < 0.05)
            {
                (a, b) = (b + 1, a);
            }
            return S(a) + "-" + S(b);
        }
        if (kind < 0.75)
        {
            return "*/" + S(Pick(new long[] { 1, 2, 3, 5, 7, 10, 15, 30, size, size + 1, 0 }));
        }
        if (kind < 0.85)
        {
            var (a, b) = Pair(low, high);
            long step = Between(1, System.Math.Max(size / 2, 1));
            return S(a) + "-" + S(b) + "/" + S(step);
        }
        if (kind < 0.97)
        {
            long n = Between(2, 4);
            var values = new List<string>();
            for (long i = 0; i < n; i++)
            {
                values.Add(Value(low, high, names));
            }
            return string.Join(",", values);
        }
        return Pick(new[] { "?", "x", "", "5/15", "/5", "1-", "-1" });
    }

    private string Value(long low, long high, string[] names)
    {
        if (names.Length > 0 && Chance() < 0.3)
        {
            return Pick(names);
        }
        if (Chance() < 0.05)
        {
            return S(Pick(new long[] { high + 1, low - 1, 99 }));
        }
        return S(Between(low, high));
    }

    private (long, long) Pair(long low, long high)
    {
        long a = Between(low, high);
        long b = Between(low, high);
        return a > b ? (b, a) : (a, b);
    }

    private string DayOfMonth()
    {
        double kind = Chance();
        if (kind < 0.1)
        {
            return Pick(new[] { "L", "LW", "15W", "1W", "31W", "5L", "L,15" });
        }
        if (kind < 0.2)
        {
            return "?";
        }
        return Field(1, 31, []);
    }

    private string DayOfWeek()
    {
        double kind = Chance();
        if (kind < 0.1)
        {
            long a = Between(0, 7);
            long b = Between(0, 6);
            return S(a) + "#" + S(b);
        }
        if (kind < 0.18)
        {
            return S(Between(0, 6)) + "L";
        }
        if (kind < 0.24)
        {
            return "+" + Field(0, 7, Days);
        }
        if (kind < 0.3)
        {
            string a = Pick(Days);
            string b = Pick(Days);
            return a + "-" + b;
        }
        return Field(0, 7, Days);
    }

    /// <summary>A cron expression.</summary>
    public string Expression()
    {
        if (Chance() < 0.05)
        {
            return Pick(Nicknames);
        }
        var parts = new List<string>
        {
            Field(0, 59, []),
            Field(0, 23, []),
            DayOfMonth(),
            Field(1, 12, Months),
            DayOfWeek(),
        };
        if (Chance() < 0.25)
        {
            parts.Insert(0, Field(0, 59, []));
        }
        if (Chance() < 0.02)
        {
            parts.Add("*");
        }
        return string.Join(" ", parts);
    }
}
