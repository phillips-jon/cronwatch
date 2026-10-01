using System;
using System.Collections.Generic;
using Cronwatch.Internal;
using Xunit;

namespace Cronwatch.Tests;

/// <summary>
/// Replays conformance/schedule.json, the cases scripts/conformance.mjs writes by running the SDK
/// in UTC, comparing every answer as the JSON the SDK writes, byte for byte. A cron without a zone
/// is read in UTC, named here rather than taken from the system, so the replay holds on Windows,
/// where <c>TZ</c> is not read.
/// </summary>
public class ScheduleConformanceTests
{
    /// <summary>The SDK's JSON of a parsed schedule.</summary>
    internal static JsObject ToJson(ParsedSchedule p)
    {
        var o = new JsObject().Set("kind", p.IsInterval ? "interval" : "cron").Set("source", p.Source);
        if (p.IsInterval)
        {
            o.Set("everyMs", p.EveryMs);
        }
        else if (p.Timezone != null)
        {
            o.Set("timezone", p.Timezone);
        }
        return o;
    }

    private static string? Zone(JsObject c) => Fixtures.String(c, "timezone");

    private static ParsedSchedule Parse(string schedule, string? zone) => Schedules.Parse(schedule, zone, TimeZoneInfo.Utc);

    [Fact]
    public void Every_case_matches_the_sdk()
    {
        JsObject f = Fixtures.Load("schedule");
        var failures = new Fixtures.Failures();

        var parse = Fixtures.Objects(f, "parse");
        foreach (JsObject c in parse)
        {
            var got = new JsObject().Set("schedule", c.Get("schedule"));
            if (c.Has("timezone"))
            {
                got.Set("timezone", c.Get("timezone"));
            }
            try
            {
                got.Set("parsed", ToJson(Parse(Fixtures.String(c, "schedule")!, Zone(c))));
            }
            catch (ArgumentException e)
            {
                got.Set("error", e.Message);
            }
            failures.Same("parse", got, c);
        }

        var fires = Fixtures.Objects(f, "fires");
        foreach (JsObject c in fires)
        {
            ParsedSchedule p = Parse(Fixtures.String(c, "schedule")!, Zone(c));
            var want = Fixtures.List(c, "fires");
            var output = new List<long?>();
            long at = Fixtures.Integer(c, "from");
            for (int i = 0; i < want.Count; i++)
            {
                long? next = Schedules.NextFire(p, at, null);
                output.Add(next);
                if (next is not long n)
                {
                    break;
                }
                at = n;
            }
            failures.Same("fires of " + c.Get("schedule") + " in " + Zone(c), output, want);
        }

        var nextFire = Fixtures.Objects(f, "nextFire");
        foreach (JsObject c in nextFire)
        {
            ParsedSchedule p = Parse(Fixtures.String(c, "schedule")!, null);
            long? got = Schedules.NextFire(p, Fixtures.Integer(c, "from"), Fixtures.OptInteger(c, "lastRunAt"));
            failures.Same("nextFire", got, c.Get("expected"));
        }

        var expectation = Fixtures.Objects(f, "expectation");
        foreach (JsObject c in expectation)
        {
            ParsedSchedule p = Parse(Fixtures.String(c, "schedule")!, Zone(c));
            Expectation? e = Schedules.GetExpectation(
                p,
                Fixtures.OptInteger(c, "lastRunAt"),
                Fixtures.Integer(c, "registeredAt"),
                DurationConformanceTests.Number(c.Get("graceMs")));
            object? got = e is Expectation x ? new JsObject().Set("dueAt", x.DueAt).Set("deadline", x.Deadline) : null;
            failures.Same(
                "expectation of " + c.Get("schedule") + " in " + Zone(c) + " after " + Json.Stringify(c.Get("lastRunAt")),
                got,
                c.Get("expected"));
        }

        var runCovers = Fixtures.Objects(f, "runCovers");
        foreach (JsObject c in runCovers)
        {
            bool got = Schedules.RunCovers(
                Fixtures.Integer(c, "startedAt"), Fixtures.Integer(c, "dueAt"), Fixtures.OptInteger(c, "followingAt"));
            failures.Same("runCovers", got, c.Get("expected"));
        }

        var autumn = Fixtures.Objects(f, "autumn");
        foreach (JsObject c in autumn)
        {
            ParsedSchedule p = Parse(Fixtures.String(c, "schedule")!, Zone(c));
            long from = Fixtures.Integer(c, "from");
            long step = Fixtures.Integer(c, "stepMs");
            var output = new List<long?>();
            for (long at = from; at < from + 8 * 3_600_000L; at += step)
            {
                output.Add(Schedules.NextFire(p, at, null));
            }
            failures.Same("autumn " + c.Get("schedule") + " in " + Zone(c), output, c.Get("next"));
        }

        failures.Check("schedule");
        Assert.Equal(75, parse.Count);
        Assert.Equal(70, fires.Count);
        Assert.Equal(4, nextFire.Count);
        Assert.Equal(575, expectation.Count);
        Assert.Equal(13, runCovers.Count);
        Assert.Equal(8, autumn.Count);
        DurationConformanceTests.Known(f, "parse", "fires", "nextFire", "expectation", "runCovers", "autumn");
    }
}
