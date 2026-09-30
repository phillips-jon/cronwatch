using System;
using System.Collections.Generic;
using System.Linq;
using Cronwatch.Internal;
using Xunit;

namespace Cronwatch.Tests;

/// <summary>
/// The walk's habits, each checked against what croner answers (the parity test checks thousands
/// more against croner itself).
/// </summary>
public class CronTests
{
    private static List<string> Runs(string text, string zone, int count, long from)
    {
        TimeZoneInfo tz = CronZones.Find(zone)!;
        return CronExpression.Parse(text, tz).NextRuns(count, from).Select(Js.IsoString).ToList();
    }

    public static TheoryData<string, string, string, int, string[]> Habits => new()
    {
        { "a wall-clock time in a spring-forward gap moves forward by the gap", "30 2 8 3 *", "America/New_York", 1, ["2026-03-08T07:30:00.000Z"] },
        { "a time that happens twice is the earlier one", "30 1 1 11 *", "America/New_York", 2, ["2026-11-01T05:30:00.000Z", "2027-11-01T05:30:00.000Z"] },
        { "a year field fires in that year only", "0 0 0 1 1 * 2030", "UTC", 2, ["2030-01-01T00:00:00.000Z"] },
        { "a fixed offset is a zone", "0 2 * * *", "+05:30", 1, ["2026-01-01T20:30:00.000Z"] },
        { "a date no month has never fires", "0 0 30 2 *", "UTC", 1, [] },
        { "the last weekday of the month", "0 0 LW * *", "UTC", 2, ["2026-01-30T00:00:00.000Z", "2026-02-27T00:00:00.000Z"] },
        { "the nearest weekday to the first", "0 0 1W * *", "UTC", 2, ["2026-02-02T00:00:00.000Z", "2026-03-02T00:00:00.000Z"] },
        { "the second Friday", "0 0 * * 5#2", "UTC", 2, ["2026-01-09T00:00:00.000Z", "2026-02-13T00:00:00.000Z"] },
    };

    [Theory]
    [MemberData(nameof(Habits))]
    public void Croners_habits(string what, string text, string zone, int count, string[] expected)
    {
        long jan = Js.DateUtc(2026, 0, 1, 0, 0, 0, 0);
        Assert.True(expected.SequenceEqual(Runs(text, zone, count, jan)), what + ": " + text);
    }

    [Theory]
    [InlineData("", "CronPattern: invalid configuration format (''), exactly five, six, or seven space separated parts are required.")]
    [InlineData("0 0 * * 5W", "CronPattern: configuration entry 5 (5W) contains illegal characters.")]
    [InlineData("0 0 1#2 * *", "CronPattern: configuration entry 3 (1#2) contains illegal characters.")]
    [InlineData("0 0 * 2L *", "CronPattern: configuration entry 4 (2L) contains illegal characters.")]
    [InlineData("0 0 1-5W * *", "CronPattern: Syntax error, W is not allowed in a range.")]
    [InlineData("* * * * * * 0", "CronPattern: Invalid value for year: 0 (supported range: 1-9999)")]
    [InlineData("0 0 * * 1#2.5", "CronPattern: configuration entry 5 (1#2.5) contains illegal characters.")]
    [InlineData("@reboot", "CronPattern: @reboot is not supported in this environment. This is an event-based trigger that requires system startup detection.")]
    // Croner takes these for a one-time date; the port refuses them (see CronExpression).
    [InlineData("0 12:30 * * *", "Invalid ISO8601 passed to timezone parser.")]
    [InlineData("2026-12-01T00:00:00", "CronPattern: a one-time date is not supported by the .NET port")]
    public void Croners_messages(string text, string message)
    {
        var e = Assert.Throws<CronException>(() => CronExpression.Parse(text, TimeZoneInfo.Utc));
        Assert.Equal(message, e.Message);
    }

    [Fact]
    public void From_tz()
    {
        TimeZoneInfo ny = CronZones.Find("America/New_York")!;
        // 02:30 does not exist on 2026-03-08: croner's fromTZ moves it to 03:30 EDT.
        Assert.Equal(Js.DateUtc(2026, 2, 8, 7, 30, 0, 0), CronZones.ToUtc([2026, 3, 8, 2, 30, 0], ny) * 1000);
        // 01:30 happens twice on 2026-11-01: the earlier, EDT.
        Assert.Equal(Js.DateUtc(2026, 10, 1, 5, 30, 0, 0), CronZones.ToUtc([2026, 11, 1, 1, 30, 0], ny) * 1000);
        Assert.Equal([2026, 7, 1, 8, 0, 0], CronZones.WallAt(Js.DateUtc(2026, 6, 1, 12, 0, 0, 0) / 1000, ny));
    }

    [Fact]
    public void Local_mean_time_is_held_to_whole_minutes()
    {
        // New York kept 4:56:02 behind Greenwich until 1883, as Intl reports it; TimeZoneInfo
        // holds every offset to whole minutes, so a fire before then is up to a minute from
        // Node's. Only a foreign row's far-past start meets it (see DESIGN.md).
        TimeZoneInfo ny = CronZones.Find("America/New_York")!;
        long offset = CronZones.Offset(Js.DateUtc(1800, 0, 1, 0, 0, 0, 0) / 1000, ny);
        Assert.InRange(offset, -(4 * 3600 + 57 * 60), -(4 * 3600 + 56 * 60));
    }

    [Fact]
    public void To_number_and_parse_int()
    {
        Assert.Equal(5.0, CronPattern.ParseInt("5"));
        Assert.Equal(7.0, CronPattern.ParseInt(" 7x"));
        Assert.Equal(-3.0, CronPattern.ParseInt("-3"));
        Assert.Equal(2.0, CronPattern.ParseInt("+2"));
        Assert.Equal(0.0, CronPattern.ToNumber(""));
        Assert.Equal(2.0, CronPattern.ToNumber(" 2 "));
        Assert.Equal(10.0, CronPattern.ToNumber("1e1"));
        Assert.Equal(2.0, CronPattern.ToNumber("2."));
        Assert.Equal(0.5, CronPattern.ToNumber(".5"));
        foreach (string text in new[] { "x", "1L", "e1", ".", "1e", "--1" })
        {
            Assert.True(double.IsNaN(CronPattern.ToNumber(text)), "Number(" + text + ")");
        }
    }

    [Fact]
    public void A_start_no_javascript_date_holds_has_no_fires()
    {
        // A foreign row's time near long.MinValue or long.MaxValue; croner is never given one.
        foreach (string text in new[] { "0 * * * *", "0 0 L * ?", "0 0 * * 5#2" })
        {
            foreach (long from in new[] { long.MinValue, long.MinValue + 1, -8_640_000_000_000_001L, 8_640_000_000_000_001L, long.MaxValue })
            {
                Assert.Empty(Runs(text, "Europe/London", 2, from));
            }
        }
        Assert.Equal(["-271820-01-01T00:00:00.000Z"], Runs("0 0 1 1 *", "UTC", 1, -8_640_000_000_000_000L));
    }

    [Fact]
    public void Zones_are_found_without_regard_to_case()
    {
        foreach (string name in new[] { "America/New_York", "america/new_york", "AMERICA/NEW_YORK", "utc", "UTC", "Etc/GMT+5", "etc/gmt+5", "+05:30", "-0800", "+05", "asia/calcutta", "US/Eastern" })
        {
            Assert.True(CronZones.Find(name) != null, name + " should be a zone");
        }
        foreach (string name in new[] { "Local", "local", "Bogus/Zone", "+25:00", "+5", "America/New_York/../New_York", "a\0b", "Etc/Unknown" })
        {
            Assert.True(CronZones.Find(name) == null, name + " should not be a zone");
        }
        Assert.Same(TimeZoneInfo.Utc, CronZones.Find("", TimeZoneInfo.Utc));
    }

    [Fact]
    public void The_list_has_names_the_system_finds()
    {
        // Every name on the list is refused or found; on Linux and macOS, with the system's
        // database, nearly all are found.
        int found = ZoneNames.All.Count(n => CronZones.Find(n) != null);
        Assert.True(found > ZoneNames.All.Length / 2, found + " of " + ZoneNames.All.Length + " names found");
        Assert.Equal(ZoneNames.All.Order(StringComparer.Ordinal), ZoneNames.All);
    }
}
