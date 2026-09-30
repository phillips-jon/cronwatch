using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using Cronwatch.Bridge;
using NCrontab;
using Xunit;

namespace Cronwatch.Quartz.Tests;

/// <summary>
/// A report, not a gate: generated cron expressions read by Cronos (the reader Hangfire carries),
/// Quartz.NET's <c>CronExpression</c> and NCrontab, each checked against CronWatch's reading (the
/// croner port) as the integrations check a schedule (<see cref="SchedulerBridge.CheckFires"/>),
/// and how many each reads alike printed, with why the rest differ. It keeps measured why the port
/// carries croner rather than depending on a .NET cron library (see DESIGN.md, Keeping in step),
/// as the Java port's <c>ReadingsReportTest</c> does, whose generator, seed and zones these are,
/// so the numbers can be set side by side. It takes some seconds, so it runs only when asked:
/// <c>CRONWATCH_READINGS=1</c>.
/// </summary>
public class ReadingsReportTests
{
    private static readonly string[] Zones = ["UTC", "America/New_York", "Europe/London", "Australia/Lord_Howe"];
    private const int Count = 40;

    /// <summary>2026-08-01 00:00 UTC, the Elixir and Java reports' start.</summary>
    private const long Now = 1_785_542_400_000L;

    private ulong _state = 20_260_929UL;

    private enum Reading
    {
        Alike,
        Refused,
        Other,
    }

    /// <summary>SplitMix64, as the Elixir and Java reports'.</summary>
    private ulong Next()
    {
        _state += 0x9e3779b97f4a7c15UL;
        ulong z = _state;
        z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9UL;
        z = (z ^ (z >> 27)) * 0x94d049bb133111ebUL;
        return z ^ (z >> 31);
    }

    private double Chance() => (Next() >> 11) / (double)(1UL << 53);

    private long Between(long lo, long hi) => lo + (long)(Next() % (ulong)(hi - lo + 1));

    /// <summary>A field in the grammar every library here shares: *, a value, a range, a step or a list.</summary>
    private string Field(long low, long high)
    {
        double kind = Chance();
        if (kind < 0.35)
        {
            return "*";
        }
        if (kind < 0.6)
        {
            return Between(low, high).ToString(System.Globalization.CultureInfo.InvariantCulture);
        }
        if (kind < 0.75)
        {
            long a = Between(low, high);
            return a.ToString(System.Globalization.CultureInfo.InvariantCulture) + "-" + Between(a, high).ToString(System.Globalization.CultureInfo.InvariantCulture);
        }
        if (kind < 0.9)
        {
            return "*/" + Between(2, Math.Max(2, (high - low + 1) / 2)).ToString(System.Globalization.CultureInfo.InvariantCulture);
        }
        var values = new List<string>();
        long n = Between(2, 3);
        for (int i = 0; i < n; i++)
        {
            string v = Between(low, high).ToString(System.Globalization.CultureInfo.InvariantCulture);
            if (!values.Contains(v))
            {
                values.Add(v);
            }
        }
        return string.Join(',', values);
    }

    /// <summary>The five fields every crontab has: minute, hour, day of the month, month, day of the week.</summary>
    private string[] Fields() => [Field(0, 59), Field(0, 23), Field(1, 28), Field(1, 12), Field(0, 6)];

    private static Reading Check(FireTimes fires, string expr, string zone, bool daily)
    {
        try
        {
            SchedulerBridge.CheckFires(fires, expr, zone, "x", "the library", daily, Now);
            return Reading.Alike;
        }
        catch (ScheduleException)
        {
            return Reading.Other;
        }
    }

    private static Reading Cronos(string expr, string zone, bool daily)
    {
        global::Cronos.CronExpression cron;
        try
        {
            cron = global::Cronos.CronExpression.Parse(expr, global::Cronos.CronFormat.IncludeSeconds);
        }
        catch (global::Cronos.CronFormatException)
        {
            return Reading.Refused;
        }
        TimeZoneInfo tz = TimeZoneInfo.FindSystemTimeZoneById(zone);
        return Check(
            SchedulerBridge.Walking(
                at =>
                {
                    DateTime? n = cron.GetNextOccurrence(DateTime.UnixEpoch.AddMilliseconds(at), tz);
                    return n == null ? null : (long)(n.Value - DateTime.UnixEpoch).TotalMilliseconds;
                },
                "Cronos"),
            expr,
            zone,
            daily);
    }

    private static Reading Quartz(string text, string expr, string zone, bool daily)
    {
        global::Quartz.CronExpression cron;
        try
        {
            cron = new global::Quartz.CronExpression(text).WithTimeZone(TimeZoneInfo.FindSystemTimeZoneById(zone));
        }
        catch (Exception e) when (e is FormatException or ArgumentException)
        {
            return Reading.Refused;
        }
        return Check(
            SchedulerBridge.Walking(
                at =>
                {
                    DateTimeOffset? n = cron.GetNextValidTimeAfter(DateTimeOffset.FromUnixTimeMilliseconds(at));
                    return n?.ToUnixTimeMilliseconds();
                },
                "Quartz"),
            expr,
            zone,
            daily);
    }

    /// <summary>
    /// NCrontab has no zones: it is given the zone's wall clock and its answer is read back in the
    /// zone, a time the zone skips passed over, as an app using it with a zone would write it.
    /// </summary>
    private static Reading NCrontab(string expr, string zone, bool daily)
    {
        CrontabSchedule cron;
        try
        {
            cron = CrontabSchedule.Parse(expr, new CrontabSchedule.ParseOptions { IncludingSeconds = true });
        }
        catch (CrontabException)
        {
            return Reading.Refused;
        }
        TimeZoneInfo tz = TimeZoneInfo.FindSystemTimeZoneById(zone);
        return Check(
            SchedulerBridge.Walking(
                at =>
                {
                    DateTime local = TimeZoneInfo.ConvertTimeFromUtc(DateTime.UnixEpoch.AddMilliseconds(at), tz);
                    DateTime next = cron.GetNextOccurrence(local);
                    while (tz.IsInvalidTime(next))
                    {
                        next = cron.GetNextOccurrence(next);
                    }
                    return (long)(TimeZoneInfo.ConvertTimeToUtc(next, tz) - DateTime.UnixEpoch).TotalMilliseconds;
                },
                "NCrontab"),
            expr,
            zone,
            daily);
    }

    private static bool Any(string f) => f is "*" or "?";

    /// <summary>Why a reading differs: refused, both day fields named, the day of the week named, other.</summary>
    private static string Why(Reading r, string[] f)
    {
        if (r == Reading.Refused)
        {
            return "refused";
        }
        if (!Any(f[2]) && !Any(f[4]))
        {
            return "both days named";
        }
        return !Any(f[4]) ? "day of the week named" : "other";
    }

    [Fact]
    public void Cronos_quartz_and_ncrontab_readings_against_cronwatchs()
    {
        Assert.SkipUnless(Environment.GetEnvironmentVariable("CRONWATCH_READINGS") == "1", "a report: CRONWATCH_READINGS=1");
        var tally = new Dictionary<string, Dictionary<string, int>>(StringComparer.Ordinal);
        var order = new List<string>();
        var others = new List<string>();
        for (int n = 0; n < Count; n++)
        {
            string[] f = Fields();
            string zone = Zones[n % Zones.Length];
            bool daily = Any(f[2]) && Any(f[3]) && Any(f[4]);
            string six = "0 " + string.Join(' ', f);
            // Quartz asks for a ? in one of the day fields; given where the other is *, as an app
            // writes it, and read by CronWatch as * again, as the integration declares it. Both
            // named, Quartz refuses.
            string quartzText = Any(f[4])
                ? "0 " + f[0] + " " + f[1] + " " + f[2] + " " + f[3] + " ?"
                : Any(f[2]) ? "0 " + f[0] + " " + f[1] + " ? " + f[3] + " " + f[4] : six;
            (string Library, Reading Reading)[] readings =
            [
                ("Cronos", Cronos(six, zone, daily)),
                ("Quartz", Quartz(quartzText, six, zone, daily)),
                ("NCrontab", NCrontab(six, zone, daily)),
            ];
            foreach (var (library, reading) in readings)
            {
                string what = reading == Reading.Alike ? "alike" : Why(reading, f);
                if (!tally.TryGetValue(library, out var counts))
                {
                    tally[library] = counts = new Dictionary<string, int>(StringComparer.Ordinal);
                    order.Add(library);
                }
                counts[what] = counts.GetValueOrDefault(what) + 1;
                if (what is "other" or "refused")
                {
                    others.Add(what + " by " + library + ": " + (library == "Quartz" ? quartzText : six) + " in " + zone);
                }
            }
        }
        var output = new StringBuilder("readings report: of " + Count + " expressions in four zones,");
        foreach (string library in order)
        {
            output.Append("\n  ").Append(library).Append(": ")
                .Append(string.Join(", ", tally[library].Select(p => p.Key + " " + p.Value)));
        }
        foreach (string other in others)
        {
            output.Append("\n  ").Append(other);
        }
        Console.Out.Write(output.Append('\n').ToString());
        TestContext.Current.SendDiagnosticMessage(output.ToString());
        Assert.True(tally["Cronos"].GetValueOrDefault("alike") > 0, output.ToString());
    }
}
