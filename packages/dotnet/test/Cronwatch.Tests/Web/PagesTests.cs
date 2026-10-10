using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using Cronwatch.Internal;
using Xunit;

namespace Cronwatch.Tests;

/// <summary>
/// The dashboard's pages, timelines, and app shell, held to the SDK's captures in
/// <c>packages/ruby/test/web/golden.json</c> where a page can be built from what the captures
/// say, and to the Java port's cases for the pieces.
/// </summary>
public class PagesTests
{
    private static readonly Lazy<JsObject> Golden = new(() =>
        Json.ParseObject(File.ReadAllText(Path.Combine(Fixtures.Repo, "packages", "ruby", "test", "web", "golden.json"), Encoding.UTF8)));

    private static long T0 => Fixtures.Integer(Golden.Value, "t0");

    private static JsObject Capture(string method, string path, int nth = 0) =>
        Fixtures.Objects(Golden.Value, "captures")
            .Where(c => Fixtures.String(c, "method") == method && Fixtures.String(c, "path") == path)
            .ElementAt(nth);

    // A page's footer names the library and its version, which the fixture holds as placeholders.
    private static string Body(JsObject capture) => Fixtures.String(capture, "responseBody")!
        .Replace("><library> <version></a>", ">Cronwatch " + CronwatchClient.Version + "</a>", StringComparison.Ordinal);

    private static JobSummary Summary(JsObject o)
    {
        var stats = Fixtures.Object(o, "stats");
        return new JobSummary
        {
            Name = Fixtures.String(o, "name")!,
            Definition = Definition.Of(Fixtures.Object(o, "definition")),
            Health = new JobHealth(Fixtures.String(o, "health")!),
            Open = ValueList<Condition>.Of(Fixtures.List(o, "open").Select(c => new Condition((string)c!))),
            LastRun = o.Get("lastRun") is JsObject run ? Run.FromValue(run) : null,
            NextExpectedAt = o.Get("nextExpectedAt") is double next ? (long)next : null,
            ConsecutiveFailures = Fixtures.Integer(o, "consecutiveFailures"),
            SilencedUntil = o.Get("silencedUntil") is double until ? (long)until : null,
            Stats = new JobStats(
                Fixtures.Integer(stats, "runs"),
                stats.Get("okRate") is double rate ? rate : 0,
                stats.Get("p50Ms") is double p50 ? (long)p50 : null,
                stats.Get("p95Ms") is double p95 ? (long)p95 : null),
        };
    }

    public static TheoryData<string, string> JobPages() => new()
    {
        { "nightly-report", "/cronwatch/api/jobs/nightly-report" },
        { "broken", "/cronwatch/api/jobs/broken?runs=abc" },
        { "far-back", "/cronwatch/api/jobs/far-back" },
    };

    [Theory]
    [MemberData(nameof(JobPages))]
    public void A_job_page_is_the_sdk_s_byte_for_byte(string name, string api)
    {
        JsObject answer = Json.ParseObject(Body(Capture("GET", api)));
        JobSummary job = Summary(Fixtures.Object(answer, "job"));
        var runs = Fixtures.Objects(answer, "runs").Select(Run.FromValue).ToList();
        int limit = Timeline.WeekRunsLimit(job, T0);
        string page = EvaluateDeps.InZone(TimeZoneInfo.Utc, () => Html.JobPage(job, runs, T0, "/cronwatch", runs.Count < limit));
        Assert.Equal(Body(Capture("GET", "/cronwatch/jobs/" + name)), page);
    }

    // The cross-port check: a stored metric that reads as Infinity (1e400 in a foreign row) is
    // left out of the run list, as the SDK's Number.isFinite filter leaves it out.
    [Fact]
    public void A_metric_that_reads_as_infinity_is_left_off_the_job_page()
    {
        JsObject answer = Json.ParseObject(Body(Capture("GET", "/cronwatch/api/jobs/nightly-report")));
        JobSummary job = Summary(Fixtures.Object(answer, "job"));
        var runs = Fixtures.Objects(answer, "runs").Select(Run.FromValue).ToList();
        string Page(string metrics)
        {
            var with = runs.ToList();
            with[0] = with[0] with { Metrics = Metrics.Lenient(Json.Parse(metrics)) };
            return EvaluateDeps.InZone(TimeZoneInfo.Utc, () => Html.JobPage(job, with, T0, "/cronwatch", true));
        }
        Assert.Equal(Page("{\"ok\":2}"), Page("{\"rows\":1e400,\"ok\":2,\"low\":-1e400}"));
        Assert.Equal(Page("{}"), Page("{\"rows\":1e400}"));
        Assert.Contains("<span class=\"k\">ok</span>", Page("{\"ok\":2}"), StringComparison.Ordinal);
    }

    [Fact]
    public void A_job_that_never_ran_has_its_page()
    {
        JsObject all = Json.ParseObject(Body(Capture("GET", "/cronwatch/api/jobs")));
        JobSummary job = Fixtures.Objects(all, "jobs").Select(Summary).Single(j => j.Name == "never-ran");
        string page = EvaluateDeps.InZone(TimeZoneInfo.Utc, () => Html.JobPage(job, [], T0, "/cronwatch", true));
        Assert.Equal(Body(Capture("GET", "/cronwatch/jobs/never-ran")), page);
    }

    private static List<Run> ImportRuns(Run latest)
    {
        var runs = new List<Run> { latest };
        for (int i = 1; i <= 5; i++)
        {
            long at = latest.StartedAt - (i * 3_600_000L);
            runs.Add(latest with
            {
                Id = latest.Id + "-" + i,
                StartedAt = at,
                FinishedAt = at + 800,
                Metrics = Metrics.Of([new("rows", 125 - i)]),
            });
        }
        return runs;
    }

    [Fact]
    public void The_board_is_the_sdk_s_byte_for_byte()
    {
        // Every job of the seed but nightly-report and import has at most one run, its last, so the
        // board's inputs are in the API's captures from before anything changed. import's five
        // earlier runs are the seed's, an hour apart before its last.
        JsObject all = Json.ParseObject(Body(Capture("GET", "/cronwatch/api/jobs")));
        var jobs = Fixtures.Objects(all, "jobs").Select(Summary).ToList();
        JsObject nightly = Json.ParseObject(Body(Capture("GET", "/cronwatch/api/jobs/nightly-report")));
        var runsByJob = new Dictionary<string, IReadOnlyList<Run>>(StringComparer.Ordinal);
        foreach (JobSummary job in jobs)
        {
            runsByJob[job.Name] = job.Name == "nightly-report"
                ? Fixtures.Objects(nightly, "runs").Select(Run.FromValue).ToList()
                : job.Name == "import" && job.LastRun is { } latest ? ImportRuns(latest)
                : job.LastRun is { } last ? [last] : [];
        }
        var lanes = jobs.Take(Timeline.BoardLanes).Select(j => new LaneInput(j, runsByJob[j.Name], true)).ToList();
        string page = EvaluateDeps.InZone(TimeZoneInfo.Utc, () => Html.DashboardPage(jobs, runsByJob, T0, "/cronwatch", null, lanes));
        Assert.Equal(Body(Capture("GET", "/cronwatch/")), page);
    }

    [Fact]
    public void Message_pages_are_the_sdk_s_byte_for_byte()
    {
        Assert.Equal(
            Body(Capture("GET", "/cronwatch/offline")),
            Html.MessagePage("You are offline", "CronWatch shows live data from your app, so it needs a connection.", "/cronwatch", false));
        Assert.Equal(
            Body(Capture("GET", "/cronwatch/", 1)),
            Html.MessagePage("Sign in", "Enter your CRONWATCH_TOKEN and this browser stays signed in.", "/cronwatch", true));
        Assert.Equal(
            Body(Capture("GET", "/cronwatch/jobs/missing")),
            Html.MessagePage("No such job", "missing is not in the store.", "/cronwatch", false));
    }

    [Fact]
    public void The_app_shell_is_the_sdk_s_byte_for_byte()
    {
        string[] paths =
        [
            "/manifest.webmanifest", "/sw.js", "/app.js", "/icons/icon.svg", "/icons/maskable.svg",
            "/icons/icon-192.png", "/icons/icon-512.png", "/icons/maskable-512.png", "/icons/apple-touch-icon.png",
        ];
        foreach (string path in paths)
        {
            JsObject capture = Capture("GET", "/cronwatch" + path);
            JsObject headers = Fixtures.Object(capture, "responseHeaders");
            PwaAsset asset = Pwa.Asset(path, "/cronwatch") ?? throw new InvalidOperationException(path);
            string body = Body(capture);
            byte[] expected = body.StartsWith("base64:", StringComparison.Ordinal)
                ? Convert.FromBase64String(body["base64:".Length..])
                : Encoding.UTF8.GetBytes(body);
            Assert.Equal(expected, asset.Body);
            Assert.Equal(Fixtures.String(headers, "content-type"), asset.ContentType);
            Assert.Equal(Fixtures.String(headers, "cache-control"), asset.Cache);
            Assert.Equal(headers.Has("service-worker-allowed"), asset.Worker);
        }
        Assert.Null(Pwa.Asset("/icons/nope.png", "/cronwatch"));
        Assert.Null(Pwa.Asset("/offline", "/cronwatch"));
    }

    [Fact]
    public void Times_are_written_in_utc_as_the_timelines_write_them()
    {
        long t = Js.DateUtc(2026, 8, 26, 22, 42, 0, 0);
        Assert.Equal("22:42", Timeline.Clock(t));
        Assert.Equal("Sat 26 Sep", Timeline.DayLabel(t));
        Assert.Equal("22:42", Timeline.When(t, t + 60_000));
        Assert.Equal("26 Sep 22:42", Timeline.When(t, t + 86_400_000));
        Assert.Equal("26 Sep 2026 22:42", Timeline.When(t, Js.DateUtc(2027, 0, 5, 0, 0, 0, 0)));
        Assert.Equal("1 Jan 0001 02:00", Timeline.When(Js.FirstDateMs + 7_200_000, t));
        Assert.Equal("before 1 Jan 0001 00:00", Timeline.When(Js.FirstDateMs - 1, t));
        Assert.Equal("after 31 Dec 9999 23:59", Timeline.When(Js.LastDateMs + 1, t));
    }

    [Fact]
    public void A_week_reads_enough_runs_to_draw_it()
    {
        JobSummary Job(JsObject def) => new()
        {
            Name = "j",
            Definition = Definition.Of(def.Set("name", "j")),
            Health = JobHealth.Healthy,
            Stats = new JobStats(0, 0, null, null),
        };
        long now = T0;
        Assert.Equal(50, Timeline.WeekRunsLimit(Job(new JsObject()), now));
        Assert.Equal(50, EvaluateDeps.InZone(TimeZoneInfo.Utc, () => Timeline.WeekRunsLimit(Job(new JsObject().Set("schedule", "0 2 * * *")), now)));
        Assert.Equal(500, EvaluateDeps.InZone(TimeZoneInfo.Utc, () => Timeline.WeekRunsLimit(Job(new JsObject().Set("schedule", "every 5m")), now)));
        Assert.Equal(500, EvaluateDeps.InZone(TimeZoneInfo.Utc, () => Timeline.WeekRunsLimit(Job(new JsObject().Set("schedule", "* * * * *")), now)));
        Assert.Equal(50, Timeline.WeekRunsLimit(Job(new JsObject().Set("schedule", "not a cron")), now));
    }

    [Fact]
    public void Conditions_read_with_their_first_underscore_as_a_space()
    {
        Assert.Equal("over budget", Html.ConditionText(Condition.OverBudget));
        Assert.Equal("a b_c", Html.ConditionText(new Condition("a_b_c")));
    }

    [Theory]
    [InlineData(0.25, 1, "0.3")]
    [InlineData(0.35, 1, "0.3")]
    [InlineData(1.005, 2, "1.00")]
    [InlineData(2.5, 0, "3")]
    [InlineData(-2.5, 0, "-3")]
    [InlineData(-0.04, 1, "-0.0")]
    [InlineData(0.0, 1, "0.0")]
    [InlineData(123.456, 1, "123.5")]
    [InlineData(0.123456, 4, "0.1235")]
    [InlineData(1e20, 1, "100000000000000000000.0")]
    [InlineData(double.Epsilon, 4, "0.0000")]
    [InlineData(1000.0, 1, "1000.0")]
    [InlineData(1e21, 1, "1e+21")]
    public void ToFixed_rounds_a_half_away_from_zero_on_the_exact_value(double x, int digits, string expected)
    {
        Assert.Equal(expected, WebText.ToFixed(x, digits));
    }

    [Fact]
    public void Names_break_after_runs_of_separators()
    {
        Assert.Equal("wp:<wbr>store_<wbr>sync.<wbr>inventory--<wbr>eu", WebText.EscapeName("wp:store_sync.inventory--eu"));
        Assert.Equal("a-", WebText.EscapeName("a-"));
        Assert.Equal("&lt;a&gt;_<wbr>b", WebText.EscapeName("<a>_b"));
    }

    [Fact]
    public void Values_are_escaped_and_uri_components_encoded()
    {
        Assert.Equal("&amp;&lt;&gt;&quot;&#39;", WebText.EscapeHtml("&<>\"'"));
        Assert.Equal("1,,2", WebText.EscapeValue(new List<object?> { 1.0, null, 2.0 }));
        Assert.Equal("", WebText.EscapeValue(null));
        Assert.Equal("wp%3Astore_sync.inventory--eu", WebText.EncodeUriComponent("wp:store_sync.inventory--eu"));
        Assert.Equal("a%2Fb%20c!~*'()%C3%A9", WebText.EncodeUriComponent("a/b c!~*'()é"));
    }

    [Fact]
    public void Secrets_compare_as_utf16()
    {
        Assert.True(WebText.ConstantTimeEquals("tok", "tok"));
        Assert.False(WebText.ConstantTimeEquals("tok", "toK"));
        Assert.False(WebText.ConstantTimeEquals("tok", "tok2"));
        Assert.False(WebText.ConstantTimeEquals("é", Encoding.Latin1.GetString(Encoding.UTF8.GetBytes("é"))));
    }
}
