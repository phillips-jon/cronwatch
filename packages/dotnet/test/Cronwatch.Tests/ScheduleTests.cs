using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Cronwatch.Internal;
using Xunit;

namespace Cronwatch.Tests;

/// <summary>
/// The SDK's schedule.test.ts and duration.test.ts, as the Rust and Java ports have them, and what
/// only the ports have: zone names in any case, fixed offsets, far starts. A cron without a zone
/// is read in UTC, named here so the tests hold on Windows.
/// </summary>
public class ScheduleTests
{
    private const long Minute = 60_000;
    private const long Hour = 3_600_000;
    private const long Day = 86_400_000;

    private static long Utc(long y, long mo, long d, long h, long mi, long s) => Js.DateUtc(y, mo, d, h, mi, s, 0);

    private static ParsedSchedule Must(string schedule, string? zone) => Schedules.Parse(schedule, zone, TimeZoneInfo.Utc);

    private static long Due(ParsedSchedule p, long? lastRunAt, long registeredAt, double g) =>
        Schedules.GetExpectation(p, lastRunAt, registeredAt, g)!.Value.DueAt;

    private static string Error(Action a) => Assert.ThrowsAny<ArgumentException>(a).Message;

    [Fact]
    public void Parse_accepts_cron_nicknames_and_intervals()
    {
        foreach (string s in new[] { "0 2 * * *", "@hourly", "*/5 * * * *" })
        {
            Assert.Equal(ScheduleKind.Cron, Must(s, null).Kind);
        }
        ParsedSchedule every = Must("every 5m", null);
        Assert.True(every.IsInterval);
        Assert.Equal(5 * Minute, every.EveryMs);
        Assert.Contains("shorter than one", Error(() => Must("every 500ms", null)), StringComparison.Ordinal);
        Assert.Contains("not a cron expression", Error(() => Must("banana", null)), StringComparison.Ordinal);
        Assert.Contains("not a duration", Error(() => Must("every banana", null)), StringComparison.Ordinal);
        Assert.Equal(new ParsedSchedule(ScheduleKind.Interval, "every 90s", null, 90_000), Must(" every 90s ", "UTC"));
        Assert.Equal(new ParsedSchedule(ScheduleKind.Cron, "0 2 * * *", "UTC", 0), Must("0 2 * * *", "UTC"));
    }

    [Fact]
    public void Next_fire_of_crons_and_intervals()
    {
        ParsedSchedule daily = Must("0 2 * * *", null);
        Assert.Equal(Utc(2026, 0, 6, 2, 0, 0), Schedules.NextFire(daily, Utc(2026, 0, 5, 9, 30, 0), null));
        ParsedSchedule every = Must("every 1h", null);
        Assert.Equal(500 + Hour, Schedules.NextFire(every, 1_000, 500L));
        Assert.Equal(1_000 + Hour, Schedules.NextFire(every, 1_000, null));
        // July, EDT (UTC-4): 02:00 local is 06:00Z.
        ParsedSchedule toronto = Must("0 2 * * *", "America/Toronto");
        Assert.Equal(Utc(2026, 6, 10, 6, 0, 0), Schedules.NextFire(toronto, Utc(2026, 6, 10, 0, 0, 0), null));
        // An interval from a far start saturates rather than wrapping.
        Assert.Equal(long.MaxValue, Schedules.NextFire(every, 0, long.MaxValue - 5));
    }

    [Fact]
    public void A_cron_without_a_zone_is_read_in_the_local_zone_given()
    {
        TimeZoneInfo kolkata = CronZones.Find("Asia/Kolkata")!;
        ParsedSchedule local = Schedules.Parse("0 2 * * *", null, kolkata);
        Assert.Null(local.Timezone);
        Assert.Equal(Utc(2026, 0, 5, 20, 30, 0), Schedules.NextFire(local, Utc(2026, 0, 5, 9, 30, 0), null));
        Assert.Equal(Utc(2026, 0, 6, 2, 0, 0), Schedules.NextFire(Must("0 2 * * *", null), Utc(2026, 0, 5, 9, 30, 0), null));
    }

    [Fact]
    public void Expectation_for_a_cron_counts_forward_from_the_last_run()
    {
        ParsedSchedule daily = Must("0 2 * * *", null);
        long registered = Utc(2026, 0, 4, 12, 0, 0);
        Expectation first = Schedules.GetExpectation(daily, null, registered, 10 * Minute)!.Value;
        Assert.Equal(Utc(2026, 0, 5, 2, 0, 0), first.DueAt);
        Assert.Equal((double)Utc(2026, 0, 5, 2, 10, 0), first.Deadline);
        Assert.Equal(Utc(2026, 0, 5, 2, 0, 0), Due(daily, null, Utc(2026, 0, 5, 2, 0, 0), 0));
        // Ran at 02:00:05: the 6th is next; 30 seconds early still covers 02:00; two minutes does not.
        Assert.Equal(Utc(2026, 0, 6, 2, 0, 0), Due(daily, Utc(2026, 0, 5, 2, 0, 5), registered, 0));
        Assert.Equal(Utc(2026, 0, 6, 2, 0, 0), Due(daily, Utc(2026, 0, 5, 1, 59, 30), registered, 0));
        Assert.Equal(Utc(2026, 0, 5, 2, 0, 0), Due(daily, Utc(2026, 0, 5, 1, 58, 0), registered, 0));
    }

    [Fact]
    public void One_run_of_an_every_minute_cron_covers_one_fire()
    {
        ParsedSchedule minutely = Must("* * * * *", null);
        long t0 = Utc(2026, 0, 5, 9, 0, 0);
        Assert.Equal(t0 + Minute, Due(minutely, t0, t0 - Hour, 0));
        Assert.Equal(t0 + 2 * Minute, Due(minutely, t0 + 50_000, t0 - Hour, 0));
    }

    [Fact]
    public void Expectation_for_yearly_crons_and_intervals()
    {
        ParsedSchedule yearly = Must("0 0 1 1 *", "UTC");
        long last = Utc(2026, 0, 1, 0, 0, 3);
        Assert.Equal(Utc(2027, 0, 1, 0, 0, 0), Due(yearly, last, last - Day, 10 * Minute));
        ParsedSchedule leap = Must("0 0 29 2 *", "UTC");
        Assert.Equal(Utc(2028, 1, 29, 0, 0, 0), Due(leap, Utc(2024, 1, 29, 0, 0, 1), 0, 0));
        ParsedSchedule every = Must("every 1h", null);
        long now = Utc(2026, 0, 5, 9, 30, 0);
        Expectation e = Schedules.GetExpectation(every, now - 2 * Hour, now - Day, 5 * Minute)!.Value;
        Assert.Equal(now - Hour, e.DueAt);
        Assert.Equal((double)(now - Hour + 5 * Minute), e.Deadline);
        Assert.Equal(now + 30 * Minute, Due(every, null, now - 30 * Minute, 5 * Minute));
    }

    [Fact]
    public void Spring_forward_run_at_the_jump_covers_a_moved_fire()
    {
        // 2026-03-08, America/New_York: 02:00 EST jumps to 03:00 EDT at 07:00Z. croner moves the
        // nonexistent 02:30 to 03:30 EDT (07:30Z); vixie cron runs it at 03:00 EDT.
        string tz = "America/New_York";
        ParsedSchedule daily = Must("30 2 * * *", tz);
        Assert.Equal(Utc(2026, 2, 8, 7, 30, 0), Due(daily, Utc(2026, 2, 7, 7, 30, 0), 0, 0));
        Assert.Equal(Utc(2026, 2, 9, 6, 30, 0), Due(daily, Utc(2026, 2, 8, 7, 0, 2), 0, 0));
        Assert.Equal(Utc(2026, 2, 9, 6, 30, 0), Due(daily, Utc(2026, 2, 8, 7, 30, 1), 0, 0));
        // A cron that fires at the jump itself was not moved: a run then covers only that fire.
        Assert.Equal(Utc(2026, 2, 8, 7, 10, 0), Due(Must("*/10 * * * *", tz), Utc(2026, 2, 8, 7, 0, 2), 0, 0));
        Assert.Equal(Utc(2026, 2, 8, 8, 0, 0), Due(Must("0 * * * *", tz), Utc(2026, 2, 8, 7, 0, 2), 0, 0));
    }

    [Fact]
    public void Run_covers_allows_a_minute_at_most_half_the_gap()
    {
        long d = Utc(2026, 0, 5, 2, 0, 0);
        Assert.True(Schedules.RunCovers(d, d, null));
        Assert.True(Schedules.RunCovers(d - 59_000, d, null));
        Assert.True(Schedules.RunCovers(d + 5 * Minute, d, null));
        Assert.False(Schedules.RunCovers(d - 61_000, d, null));
        Assert.True(Schedules.RunCovers(d - 30_000, d, d + Minute));
        Assert.False(Schedules.RunCovers(d - 31_000, d, d + Minute));
    }

    [Fact]
    public void Fires_between_a_span()
    {
        ParsedSchedule hourly = Must("0 * * * *", "UTC");
        long from = Utc(2026, 0, 5, 9, 30, 0);
        List<long> fires = Schedules.FiresBetween(hourly, from, from + 24 * Hour, 100)!;
        Assert.Equal(24, fires.Count);
        long next = from;
        foreach (long fire in fires)
        {
            next = Schedules.NextFire(hourly, next, null)!.Value;
            Assert.Equal(next, fire);
        }
        Assert.Null(Schedules.FiresBetween(hourly, from, from + 24 * Hour, 23));
        Assert.Empty(Schedules.FiresBetween(Must("0 3 * * *", "UTC"), from, from + Hour, 5)!);
        // The night clocks go back in New York: fires only ever move forward.
        List<long> night = Schedules.FiresBetween(Must("30 * * * *", "America/New_York"), Utc(2026, 10, 1, 4, 0, 0), Utc(2026, 10, 1, 9, 0, 0), 20)!;
        for (int i = 1; i < night.Count; i++)
        {
            Assert.True(night[i] > night[i - 1], "fires went backwards");
        }
        Assert.InRange(night.Count, 4, 5);
    }

    [Fact]
    public void A_date_no_month_has_never_fires()
    {
        ParsedSchedule p = Must("0 0 30 2 *", "UTC");
        Assert.Null(Schedules.NextFire(p, Utc(2026, 0, 1, 0, 0, 0), null));
        Assert.Null(Schedules.GetExpectation(p, null, Utc(2026, 0, 1, 0, 0, 0), 0));
    }

    [Fact]
    public void A_far_start_counts_from_the_year_1_or_has_no_fire_after_it()
    {
        // A foreign or damaged row's start can be any long: before the year 1 it counts from the
        // year's first millisecond, and after 9999 nothing is due. Nothing overflows, in any zone.
        long first = Js.FirstDateMs;
        foreach (string zone in new[] { "UTC", "America/New_York", "Asia/Kolkata", "" })
        {
            foreach (string schedule in new[] { "0 2 * * *", "*/5 * * * *", "0 0 29 2 *", "0 0 30 2 *" })
            {
                ParsedSchedule p = Must(schedule, zone);
                foreach (long t in new[] { long.MinValue, long.MinValue + 1, -8_640_000_000_000_001L, first - 1, long.MaxValue, long.MaxValue - 1 })
                {
                    if (Schedules.NextFire(p, t, null) is long f)
                    {
                        Assert.True(t < first && f >= first && f <= Js.LastDateMs, schedule + " " + zone + " from " + t + ": " + f);
                    }
                    Schedules.GetExpectation(p, t, t, double.MaxValue);
                    Schedules.GetExpectation(p, null, t, 0);
                    Schedules.FiresBetween(p, t, long.MaxValue, 50);
                }
            }
        }
        ParsedSchedule daily = Must("0 2 * * *", "UTC");
        Assert.Equal(Utc(1, 0, 1, 2, 0, 0), Due(daily, long.MinValue, 0, 0));
        Assert.Null(Schedules.GetExpectation(daily, long.MaxValue, 0, 0));
        Assert.Equal(Utc(9999, 11, 31, 2, 0, 0), Schedules.NextFire(daily, Utc(9999, 11, 30, 12, 0, 0), null));
        Assert.Null(Schedules.NextFire(daily, Utc(9999, 11, 31, 2, 0, 0), null));
        Assert.Equal(Utc(5000, 0, 1, 2, 0, 0), Schedules.NextFire(daily, Utc(5000, 0, 1, 0, 0, 0), null));
    }

    [Fact]
    public void One_time_dates_are_refused()
    {
        Assert.EndsWith(": CronPattern: a one-time date is not supported", Error(() => Must("2026-12-01T00:00:00", null)), StringComparison.Ordinal);
        Assert.EndsWith(": Invalid ISO8601 passed to timezone parser.", Error(() => Must("0 2:30 * * *", null)), StringComparison.Ordinal);
    }

    [Fact]
    public void Zones()
    {
        Assert.True(Schedules.IsZone("america/new_york"));
        Assert.True(Schedules.IsZone("+05:30"));
        Assert.False(Schedules.IsZone(""));
        Assert.False(Schedules.IsZone("Bogus/Zone"));
        // A zone named in another case reads the same as its own spelling.
        long from = Utc(2026, 6, 10, 0, 0, 0);
        ParsedSchedule lower = Must("0 2 * * *", "america/new_york");
        Assert.Equal(Utc(2026, 6, 10, 6, 0, 0), Schedules.NextFire(lower, from, null));
        Assert.Equal("america/new_york", lower.Timezone);
        ParsedSchedule offset = Must("0 2 * * *", "+05:30");
        Assert.Equal(Utc(2026, 0, 1, 20, 30, 0), Schedules.NextFire(offset, Utc(2026, 0, 1, 0, 0, 0), null));
        Assert.StartsWith("CronDate: Failed to convert date to timezone 'Bogus/Zone'", Error(() => Must("0 2 * * *", "Bogus/Zone")), StringComparison.Ordinal);
        // A pattern error is reported before a zone error, as croner reads the pattern first.
        Assert.StartsWith("schedule \"x\"", Error(() => Must("x", "Bogus/Zone")), StringComparison.Ordinal);
    }

    [Fact]
    public async Task Parse_is_safe_from_many_threads()
    {
        var tasks = Enumerable.Range(0, 32).Select(_ => Task.Run(() =>
        {
            for (int j = 0; j < 50; j++)
            {
                ParsedSchedule p = Must("*/15 * * * *", "Europe/London");
                Schedules.NextFire(p, Utc(2026, 9, 25, 0, 0, j), null);
            }
        }));
        await Task.WhenAll(tasks);
    }

    [Fact]
    public void Parse_duration_text_and_numbers()
    {
        var good = new (string Text, double Ms)[]
        {
            ("15m", 900_000), ("1h30m", 5_400_000), ("90s", 90_000), ("2d", 172_800_000),
            ("1w", 604_800_000), ("250ms", 250), (" 1h 5m ", 3_900_000), ("1.5h", 5_400_000),
        };
        foreach (var (text, ms) in good)
        {
            Assert.Equal(ms, Durations.Parse(text, ""));
        }
        Assert.Equal(1.5, Durations.Parse(1.5, ""));
        foreach (string bad in new[] { "", "abc", "5", "5 minutes", "-1m", "1m2" })
        {
            Assert.Contains("duration", Error(() => Durations.Parse(bad, "")), StringComparison.Ordinal);
        }
        Assert.Equal("grace must be a non-negative number of milliseconds", Error(() => Durations.Parse(-5.0, "grace")));
    }

    [Fact]
    public void A_json_value_is_read_as_the_sdk_reads_it()
    {
        Assert.Equal(900_000.0, Durations.ParseValue("15m", "grace"));
        Assert.Equal(1.5, Durations.ParseValue(1.5, "grace"));
        string like = " is not a duration like \"15m\", \"1h30m\" or \"90s\"";
        Assert.Equal("grace \"true\"" + like, Error(() => Durations.ParseValue(true, "grace")));
        Assert.Equal("duration \"null\"" + like, Error(() => Durations.ParseValue(null, "")));
        Assert.Equal("grace \"[object Object]\"" + like, Error(() => Durations.ParseValue(new JsObject(), "grace")));
        Assert.Equal("grace \"1,,x\"" + like, Error(() => Durations.ParseValue(new List<object?> { 1.0, null, "x" }, "grace")));
    }

    [Fact]
    public void A_duration_over_64_characters_is_refused_quoting_its_first_32()
    {
        string tooLong = "is too long for a duration (more than 64 characters)";
        Assert.Equal(32.0 * 60_000, Durations.Parse(string.Concat(Enumerable.Repeat("1m", 32)), ""));
        string longer = " " + string.Concat(Enumerable.Repeat("1m", 32));
        Assert.Equal("grace \"" + longer[..32] + "...\" " + tooLong, Error(() => Durations.Parse(longer, "grace")));
        // Characters are code points: forty emoji are eighty UTF-16 units but under the cap.
        string emoji = "😀";
        string forty = string.Concat(Enumerable.Repeat(emoji, 40));
        Assert.Equal("duration \"" + forty + "\" is not a duration like \"15m\", \"1h30m\" or \"90s\"", Error(() => Durations.Parse(forty, "")));
        Assert.Equal("duration \"" + string.Concat(Enumerable.Repeat(emoji, 32)) + "...\" " + tooLong, Error(() => Durations.Parse(string.Concat(Enumerable.Repeat(emoji, 65)), "")));
        Assert.Equal("silence duration \"" + new string('1', 32) + "...\" " + tooLong, Error(() => Durations.Parse(new string('1', 1 << 20), "silence duration")));
    }

    [Fact]
    public void Format_duration_and_relative()
    {
        Assert.Equal("500ms", Durations.Format(500));
        Assert.Equal("1s", Durations.Format(1_000));
        Assert.Equal("1m 30s", Durations.Format(90_000));
        Assert.Equal("1d 2h", Durations.Format(Hour * 26 + Minute * 5));
        Assert.Equal("2m ago", Durations.FormatRelative(1_000_000, 1_120_000));
        Assert.Equal("in 2m", Durations.FormatRelative(1_120_000, 1_000_000));
        Assert.Equal("now", Durations.FormatRelative(1_000_000, 1_002_000));
        Durations.FormatRelative(long.MinValue, long.MaxValue);
        Durations.FormatRelative(long.MaxValue, long.MinValue);
    }
}
