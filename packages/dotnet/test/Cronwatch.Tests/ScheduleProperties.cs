using System;
using System.Globalization;
using System.Text;
using Cronwatch.Internal;
using Xunit;

namespace Cronwatch.Tests;

/// <summary>
/// Two doors untrusted input comes through: a cron expression (a stored definition, a source's
/// job) in nine zones, and duration text (a silence from the dashboard, a stored grace). Either is
/// read or refused with an <see cref="ArgumentException"/>, never another throw; fire times each
/// come later than the last; and a duration is never negative or not finite. Each property runs
/// its tries from a fixed seed, and <c>CRONWATCH_TRIES=N</c> multiplies them.
/// </summary>
public class ScheduleProperties
{
    private static readonly string[] Units = ["ms", "s", "m", "h", "d", "w", "x", ""];

    /// <summary>A seeded source of values, over SplitMix64, that names the case that failed.</summary>
    private sealed class Seeded(ulong seed)
    {
        private readonly CronFuzzer _f = new(seed);

        public ulong AnyULong() => _f.Next();

        public long Between(long lo, long hi) => lo + (long)(_f.Next() % (ulong)(hi - lo + 1));

        public bool Bool() => (_f.Next() & 1) == 1;

        public string AnyString(int max)
        {
            int n = (int)Between(0, max);
            var b = new StringBuilder(n);
            for (int i = 0; i < n; i++)
            {
                double kind = _f.Chance();
                b.Append(kind switch
                {
                    < 0.5 => "0123456789 mshdw.*/,-#LW?@every"[(int)Between(0, 30)],
                    < 0.8 => (char)Between(0x20, 0x7e),
                    < 0.9 => (char)Between(0, 0x1f),
                    _ => (char)Between(0x80, 0xffff),
                });
            }
            return b.ToString();
        }
    }

    private static void Check(ulong seed, int tries, Action<Seeded> property)
    {
        int times = tries * Math.Max(1, int.TryParse(Environment.GetEnvironmentVariable("CRONWATCH_TRIES"), NumberStyles.None, CultureInfo.InvariantCulture, out int n) ? n : 1);
        var root = new CronFuzzer(seed);
        for (int i = 0; i < times; i++)
        {
            ulong caseSeed = root.Next();
            try
            {
                property(new Seeded(caseSeed));
            }
            catch (Exception e)
            {
                throw new InvalidOperationException("case " + i + " of seed " + seed + " (case seed " + caseSeed + ") failed: " + e.Message, e);
            }
        }
    }

    [Fact]
    public void Cron_expressions_parse_or_are_refused_and_fire_forward()
    {
        Check(21, 300, g =>
        {
            var f = new CronFuzzer(g.AnyULong());
            string expression = f.Expression();
            long from = g.Between(Js.FirstDateMs, Js.LastDateMs);
            foreach (string zone in CronFuzzer.Zones)
            {
                ParsedSchedule p;
                try
                {
                    p = Schedules.Parse(expression, zone, TimeZoneInfo.Utc);
                }
                catch (ArgumentException)
                {
                    continue;
                }
                long at = from;
                for (int i = 0; i < 4; i++)
                {
                    if (Schedules.NextFire(p, at, null) is not long next)
                    {
                        break;
                    }
                    Assert.True(next > at, expression + " in " + zone + " went back from " + at);
                    Assert.True(next <= Js.LastDateMs, expression + " fired after 9999");
                    at = next;
                }
            }
        });
    }

    [Fact]
    public void Any_text_is_a_schedule_or_refused()
    {
        Check(22, 300, g =>
        {
            long from = (long)g.AnyULong();
            try
            {
                ParsedSchedule p = Schedules.Parse(g.AnyString(40), null, TimeZoneInfo.Utc);
                Schedules.NextFire(p, from, null);
                Schedules.GetExpectation(p, from, from, 0);
            }
            catch (ArgumentException)
            {
                // refused, as the SDK refuses it
            }
        });
    }

    [Fact]
    public void Duration_text_is_read_or_refused()
    {
        Check(23, 500, g =>
        {
            string text = g.AnyString(70);
            double ms;
            try
            {
                ms = Durations.Parse(text, "grace");
            }
            catch (ArgumentException)
            {
                return;
            }
            Assert.True(double.IsFinite(ms) && ms >= 0, text + " read as " + ms);
        });
    }

    [Fact]
    public void Duration_parts_are_read_or_refused()
    {
        Check(24, 300, g =>
        {
            long n = g.Between(0, 1_000_000_000L);
            string text = n.ToString(CultureInfo.InvariantCulture) + (g.Bool() ? ".5" : "") + Units[g.Between(0, Units.Length - 1)];
            try
            {
                double ms = Durations.Parse(text, "");
                Assert.True(double.IsFinite(ms) && ms >= 0, text + " read as " + ms);
            }
            catch (ArgumentException e)
            {
                Assert.StartsWith("duration \"", e.Message, StringComparison.Ordinal);
            }
        });
    }
}
