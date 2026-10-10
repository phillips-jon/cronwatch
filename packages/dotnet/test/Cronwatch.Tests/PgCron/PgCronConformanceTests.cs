using System;
using System.Globalization;
using Cronwatch.PgCron;
using Xunit;

namespace Cronwatch.Tests.PgCron;

/// <summary>
/// Replays <c>conformance/pgcron.json</c>: the SDK's <c>pgCronSchedule</c>, <c>pgCronJobName</c>,
/// and <c>pgCronRun</c> over every case, and its hold.
/// </summary>
public class PgCronConformanceTests
{
    private static long? Time(JsObject row, string key) =>
        row.Get(key) is string s ? DateTimeOffset.Parse(s, CultureInfo.InvariantCulture).ToUnixTimeMilliseconds() : null;

    [Fact]
    public void Every_case_of_pgcron_json()
    {
        JsObject f = Fixtures.Load("pgcron");
        var failures = new Fixtures.Failures();
        int schedules = 0;
        int names = 0;
        int runs = 0;
        foreach (JsObject c in Fixtures.Objects(f, "schedules"))
        {
            string schedule = Fixtures.String(c, "schedule")!;
            failures.Same("schedule " + schedule, PgCronSource.ToSchedule(schedule), c.Get("result"));
            schedules++;
        }
        foreach (JsObject c in Fixtures.Objects(f, "names"))
        {
            JsObject j = Fixtures.Object(c, "job");
            var job = new PgCronJob(Fixtures.Integer(j, "jobid"), Fixtures.String(j, "jobname"), "", "", "", true);
            failures.Same("name of " + j.ToJson(), PgCronSource.DefaultJobName(job), c.Get("name"));
            names++;
        }
        foreach (JsObject c in Fixtures.Objects(f, "runs"))
        {
            JsObject r = Fixtures.Object(c, "row");
            var row = new PgCronRow(
                Fixtures.Integer(r, "runid"),
                Fixtures.Integer(r, "jobid"),
                Fixtures.String(r, "status"),
                Fixtures.String(r, "return_message"),
                Time(r, "start_time"),
                Time(r, "end_time"));
            long fallback = c.Get("fallbackAt") is double d ? (long)d : Support.T0;
            Run? run = PgCronSource.ToRun(row, "db:j", "pgcron:db:", fallback);
            failures.Same("run of " + r.ToJson(), run?.ToValue(), c.Get("run"));
            runs++;
        }
        failures.Same("holdMs", (double)PgCronSource.HoldMs, f.Get("holdMs"));
        failures.Check("pgcron");
        Assert.Equal((14, 6, 9), (schedules, names, runs));
    }
}
