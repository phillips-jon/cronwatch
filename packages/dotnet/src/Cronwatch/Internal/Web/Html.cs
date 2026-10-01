using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;

namespace Cronwatch.Internal;

/// <summary>
/// The dashboard's pages (<c>routes/html.ts</c>), byte for byte, carried over from the Java port's
/// <c>internal/web/Html</c>: set like cronwatch.dev, a printed sheet on grey paper, a serif for
/// what a person reads, a mono for what a machine printed, neutral greys, and colour only for the
/// states CronWatch reports. The page loads nothing but its own app shell, and works without its
/// one script.
/// </summary>
internal static class Html
{
    /// <summary>The clock face from cronwatch.dev, in the text colour.</summary>
    private const string Mark =
        "<svg viewBox=\"0 0 40 40\" aria-hidden=\"true\" focusable=\"false\"><rect x=\"1\" y=\"1\""
        + " width=\"38\" height=\"38\" rx=\"9.5\" fill=\"none\" stroke=\"currentColor\""
        + " stroke-opacity=\".22\" stroke-width=\"1.5\"/><circle cx=\"20\" cy=\"20\" r=\"10.5\""
        + " fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\"/><path d=\"M20 12.5V20h6\""
        + " fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\""
        + " stroke-linejoin=\"round\"/></svg>";

    /// <summary>The healths in the SDK's order, with their class and label.</summary>
    private static readonly (JobHealth Health, string Class, string Label)[] HealthOrder =
    [
        (JobHealth.Failing, "bad", "failing"),
        (JobHealth.Stuck, "bad", "stuck"),
        (JobHealth.Late, "warn", "late"),
        (JobHealth.Healthy, "ok", "healthy"),
        (JobHealth.Silenced, "muted", "silenced"),
        (JobHealth.NeverRan, "muted", "never ran"),
    ];

    private static string H(string s) => WebText.EscapeHtml(s);

    /// <summary>
    /// A page. <paramref name="basePath"/> is where the dashboard is mounted (<c>""</c> at the
    /// root); <paramref name="refresh"/>, when above 0, is the page's refresh in seconds.
    /// </summary>
    private static string Layout(string title, string body, string basePath, int refresh)
    {
        string b = H(basePath);
        string meta = refresh > 0 ? "<meta http-equiv=\"refresh\" content=\"" + refresh.ToString(CultureInfo.InvariantCulture) + "\">" : "";
        return "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n"
            + "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1,viewport-fit=cover\">\n"
            + "<meta name=\"robots\" content=\"noindex,nofollow\">\n"
            + "<meta name=\"color-scheme\" content=\"light dark\">\n"
            + meta
            + "\n<title>"
            + H(title)
            + "</title>\n<meta name=\"theme-color\" content=\""
            + Pwa.ThemeColor
            + "\" media=\"(prefers-color-scheme: light)\">\n<meta name=\"theme-color\" content=\""
            + Pwa.ThemeColorDark
            + "\" media=\"(prefers-color-scheme: dark)\">\n"
            + "<meta name=\"mobile-web-app-capable\" content=\"yes\">\n"
            + "<meta name=\"apple-mobile-web-app-capable\" content=\"yes\">\n"
            + "<meta name=\"apple-mobile-web-app-title\" content=\"CronWatch\">\n"
            + "<meta name=\"apple-mobile-web-app-status-bar-style\" content=\"default\">\n"
            + "<link rel=\"manifest\" href=\""
            + b
            + "/manifest.webmanifest\">\n<link rel=\"icon\" href=\""
            + b
            + "/icons/icon.svg\" type=\"image/svg+xml\">\n<link rel=\"apple-touch-icon\" href=\""
            + b
            + "/icons/apple-touch-icon.png\">\n<script src=\""
            + b
            + "/app.js\" defer></script>\n<style>"
            + Pwa.StyleCss()
            + "</style>\n</head>\n<body><div class=\"sheet\">"
            + body
            + "</div></body>\n</html>";
    }

    /// <summary>The header's mark and name, and a crumb after it when one is given.</summary>
    private static string Brand(string basePath, string? crumb)
    {
        string home = "<a href=\"" + H(basePath) + "/\">" + Mark + "<span>CronWatch</span></a>";
        if (crumb == null)
        {
            return "<p class=\"brand\">" + home + "</p>";
        }
        return "<p class=\"brand\">" + home + "<span class=\"slash\" aria-hidden=\"true\">/</span><span class=\"crumb\">"
            + WebText.EscapeName(crumb) + "</span></p>";
    }

    private static (string Class, string Label) HealthLabel(JobHealth health)
    {
        foreach (var e in HealthOrder)
        {
            if (e.Health == health)
            {
                return (e.Class, e.Label);
            }
        }
        // A health this version does not know, as the SDK's lookup would leave it.
        return ("undefined", "undefined");
    }

    /// <summary><c>c.replace("_", " ")</c>: the first underscore only.</summary>
    internal static string ConditionText(Condition c) => WebText.ReplaceFirst(c.Value, "_", " ");

    /// <summary>The job's health, with any open condition it does not already say (over budget, slow).</summary>
    private static string HealthState(JobSummary job)
    {
        var (cls, label) = HealthLabel(job.Health);
        var extras = new StringBuilder();
        foreach (Condition c in job.Open)
        {
            if (c != Condition.Missed && c != Condition.Failed && c != Condition.Stuck)
            {
                extras.Append("<span class=\"state warn\">").Append(H(ConditionText(c))).Append("</span>");
            }
        }
        return "<span class=\"state " + cls + "\"><i class=\"sq " + cls + "\" aria-hidden=\"true\"></i>" + label + "</span>" + extras;
    }

    private static string RunState(Run run)
    {
        string cls = run.Status == RunStatus.Ok ? "ok" : run.Status == RunStatus.Running ? "info" : "bad";
        return "<span class=\"state " + cls + "\">" + H(run.Status.Value) + "</span>";
    }

    private static double Took(Run r) => r.DurationMs ?? 0;

    /// <summary>The last twenty runs, oldest first, as bars as tall as they took; grey unless something went wrong.</summary>
    private static string Sparkline(IReadOnlyList<Run> runs)
    {
        var points = runs.Take(20).ToList();
        if (points.Count < 2)
        {
            return "";
        }
        const double Bar = 4;
        const double Gap = 1.5;
        const double Hgt = 22;
        double most = 1;
        foreach (Run r in points)
        {
            most = Math.Max(most, Took(r));
        }
        var bars = new StringBuilder();
        for (int i = 0; i < points.Count; i++)
        {
            Run r = points[points.Count - 1 - i];
            string x = WebText.ToFixed(i * (Bar + Gap), 1);
            if (r.Status == RunStatus.Running)
            {
                bars.Append("<rect class=\"running\" x=\"").Append(x).Append("\" y=\"15.5\" width=\"3\" height=\"6\"/>");
                continue;
            }
            bool ok = r.Status == RunStatus.Ok;
            double floor = ok ? 2 : 6;
            string cls = ok ? "" : " class=\"bad\"";
            double tall = Math.Max(floor, Took(r) / most * Hgt);
            bars.Append("<rect").Append(cls).Append(" x=\"").Append(x).Append("\" y=\"").Append(WebText.ToFixed(Hgt - tall, 1))
                .Append("\" width=\"4\" height=\"").Append(WebText.ToFixed(tall, 1)).Append("\" rx=\".5\"/>");
        }
        string w = WebText.ToFixed((points.Count * (Bar + Gap)) - Gap, 1);
        return "<svg class=\"spark\" width=\"" + w + "\" height=\"22\" viewBox=\"0 0 " + w
            + " 22\" aria-hidden=\"true\" focusable=\"false\">" + bars + "</svg>";
    }

    /// <summary>A time as "5m ago", with the full UTC time as its title.</summary>
    private static string Stamp(long? at, long now)
    {
        if (at is not long t)
        {
            return "<span class=\"muted\">never</span>";
        }
        string? iso = Js.IsoTime(t);
        if (iso == null)
        {
            return "<span class=\"nowrap\">" + Js.BeyondDates(t) + "</span>";
        }
        string title = WebText.ReplaceFirst(iso, "T", " ");
        return "<time class=\"nowrap\" datetime=\"" + iso + "\" title=\"" + title[..19] + " UTC\">"
            + H(Durations.FormatRelative(t, now)) + "</time>";
    }

    /// <summary>
    /// The counts by health, the ones needing attention first; a zero is set faint rather than
    /// left out, so the row keeps its shape.
    /// </summary>
    private static string HealthFigures(IReadOnlyList<JobSummary> jobs)
    {
        var b = new StringBuilder("<dl class=\"figures\">");
        foreach (var e in HealthOrder)
        {
            long n = jobs.Count(j => j.Health == e.Health);
            string shown = n == 0 ? "zero" : e.Class;
            b.Append("<div class=\"").Append(shown).Append("\"><dt><i class=\"sq ").Append(e.Class).Append("\" aria-hidden=\"true\"></i>")
                .Append(e.Label).Append("</dt><dd>").Append(WebText.Count(n)).Append("</dd></div>");
        }
        return b.Append("</dl>").ToString();
    }

    /// <summary>A definition's field when it is truthy, as a template's <c>d.x ? ... : ...</c> reads it.</summary>
    private static object? TruthyField(Definition d, string key)
    {
        object? v = d.Get(key);
        return Evaluate.Truthy(v) ? v : null;
    }

    /// <summary>The board's schedule column.</summary>
    private static string ScheduleCell(Definition d)
    {
        object? sched = TruthyField(d, "schedule");
        if (sched == null)
        {
            return "<span class=\"muted\">no schedule</span>";
        }
        string output = WebText.EscapeValue(sched);
        object? tz = TruthyField(d, "timezone");
        if (tz != null)
        {
            output += "<span class=\"tz\">" + WebText.EscapeValue(tz) + "</span>";
        }
        return output;
    }

    /// <summary>The board: every job's health, its last day and its recent runs.</summary>
    public static string DashboardPage(
        IReadOnlyList<JobSummary> jobs,
        IReadOnlyDictionary<string, IReadOnlyList<Run>> runsByJob,
        long now,
        string basePath,
        long? checkedAt,
        IReadOnlyList<LaneInput> lanes)
    {
        long attention = jobs.Count(j => j.Health != JobHealth.Healthy);
        string headline;
        if (jobs.Count == 0)
        {
            headline = "No jobs yet.";
        }
        else if (attention == 0 && jobs.Count == 1)
        {
            headline = "The one job is healthy.";
        }
        else if (attention == 0)
        {
            headline = "All " + WebText.Count(jobs.Count) + " jobs are healthy.";
        }
        else
        {
            string s = jobs.Count == 1 ? "" : "s";
            headline = WebText.Count(jobs.Count) + " job" + s + ", <b>" + WebText.Count(attention) + " needing attention</b>.";
        }

        var rows = new List<string>();
        foreach (JobSummary job in jobs)
        {
            Definition d = job.Definition;
            object? descValue = TruthyField(d, "description");
            string desc = descValue == null ? "" : "<span class=\"desc\">" + WebText.EscapeValue(descValue) + "</span>";
            string last;
            Run? r = job.LastRun;
            if (r == null)
            {
                last = "<span class=\"muted\">never</span>";
            }
            else
            {
                last = RunState(r) + " " + Stamp(r.StartedAt, now);
                if (r.DurationMs is long took)
                {
                    last += "<span class=\"sub\">took " + H(Durations.Format(took)) + "</span>";
                }
            }
            string next;
            if (job.NextExpectedAt is not long n)
            {
                next = "<span class=\"muted\">not scheduled</span>";
            }
            else
            {
                string overdue = n < now ? "<span class=\"state warn\">overdue</span> " : "";
                next = overdue + Stamp(n, now) + "<span class=\"sub\">" + H(Timeline.When(n, now)) + " UTC</span>";
            }
            IReadOnlyList<Run> jobRuns = runsByJob.TryGetValue(job.Name, out var found) ? found : [];
            rows.Add(
                "<tr>\n<td class=\"job\"><a class=\"name\" href=\""
                + H(basePath)
                + "/jobs/"
                + WebText.EncodeUriComponent(job.Name)
                + "\">"
                + WebText.EscapeName(job.Name)
                + "</a>"
                + desc
                + "</td>\n<td class=\"health\">"
                + HealthState(job)
                + "</td>\n<td class=\"nowrap hide-sm\">"
                + ScheduleCell(d)
                + "</td>\n<td class=\"nowrap last\">"
                + last
                + "</td>\n<td class=\"nowrap hide-sm\">"
                + next
                + "</td>\n<td class=\"hide-sm\">"
                + Sparkline(jobRuns)
                + "</td>\n</tr>");
        }

        string checkedText = checkedAt is long c && c != 0 ? ", checked " + H(Durations.FormatRelative(c, now)) : "";
        string health =
            "<p class=\"empty\">Declare one with <code>cw.job(\"name\", { schedule: \"0 2 * * *\""
            + " })</code> and run it once, and it shows up here.</p>";
        string sections = "";
        if (jobs.Count > 0)
        {
            health = HealthFigures(jobs);
            var sp = new Span(now - Timeline.BoardBehindMs, now + Timeline.BoardAheadMs, now);
            sections =
                "<section class=\"sec\" aria-label=\"Last 24 hours\">\n  <h2>Last 24 hours</h2>\n"
                + "  <p class=\"lede\">One lane per job. Faint ticks mark when it was due, bars the"
                + " runs it recorded, as long as they took. A dashed box is a slot nothing ran in."
                + " Times are UTC.</p>\n"
                + "  <div class=\"wide\">"
                + Timeline.DayTimeline(lanes, sp, basePath, jobs.Count)
                + "</div>\n</section>\n<section class=\"sec\" aria-label=\"Jobs\">\n  <h2>Jobs</h2>\n"
                + "  <p class=\"lede\">Every job in the store. Open one for its week, its runs and"
                + " their output.</p>\n"
                + "  <div class=\"wide\"><table class=\"board\">\n"
                + "<thead><tr><th>Job</th><th>Health</th><th class=\"hide-sm\">Schedule</th><th>Last"
                + " run</th><th class=\"hide-sm\">Next due</th><th class=\"hide-sm\">Recent"
                + " runs</th></tr></thead>\n"
                + "<tbody>"
                + string.Join("\n", rows)
                + "</tbody></table></div>\n</section>";
        }
        string body =
            "\n<header class=\"top\">\n  "
            + Brand(basePath, null)
            + "\n  <div class=\"actions\">\n    <span class=\"meta\">"
            + H(Timeline.Clock(now))
            + " UTC"
            + checkedText
            + "</span>\n    <form class=\"inline\" method=\"post\" action=\""
            + H(basePath)
            + "/check\"><button class=\"primary\" type=\"submit\">Run check now</button></form>\n"
            + "  </div>\n</header>\n<main>\n"
            + "<section class=\"sec\" aria-label=\"Health\">\n  <h2>Health</h2>\n  <div>\n"
            + "    <p class=\"headline\">"
            + headline
            + "</p>\n    "
            + health
            + "\n  </div>\n</section>\n"
            + sections
            + "\n</main>\n<footer><span>Refreshes every minute. Times are UTC.</span><a href=\""
            + H(basePath)
            + "/api/jobs\">JSON</a></footer>";
        return Layout("CronWatch", body, basePath, 60);
    }

    /// <summary>A metric's value as the run list shows it: whole numbers as they are, others to four places.</summary>
    private static string MetricText(double v) => Js.IsInteger(v) ? WebText.Num(v) : WebText.ToFixed(v, 4);

    /// <summary>
    /// One job: its state and figures, its last seven days, its runs with their output, and its
    /// definition. <paramref name="complete"/> is false when <paramref name="runs"/> does not reach
    /// back over the whole week (the run list shows the newest fifty).
    /// </summary>
    public static string JobPage(JobSummary job, IReadOnlyList<Run> runs, long now, string basePath, bool complete)
    {
        Definition d = job.Definition;
        string okRate = WebText.Num(Js.Round(job.Stats.OkRate * 100)) + "%";
        var listed = runs.Take(50).ToList();
        var runRows = new List<string>();
        foreach (Run run in listed)
        {
            var detail = new StringBuilder();
            if (!string.IsNullOrEmpty(run.Error))
            {
                detail.Append("<details class=\"out error\" open><summary>error</summary><pre>").Append(H(run.Error)).Append("</pre></details>");
            }
            if (!string.IsNullOrEmpty(run.Output))
            {
                string open = run.Status == RunStatus.Ok ? "" : " open";
                detail.Append("<details class=\"out\"").Append(open).Append("><summary>output</summary><pre>").Append(H(run.Output))
                    .Append("</pre></details>");
            }
            var metrics = new StringBuilder();
            foreach (var m in run.Metrics)
            {
                // A stored number that reads as Infinity (1e400 in a foreign row) is left out, as
                // the SDK's Number.isFinite leaves it out.
                if (!double.IsFinite(m.Value))
                {
                    continue;
                }
                metrics.Append("<span><span class=\"k\">").Append(H(m.Key)).Append("</span> ").Append(H(MetricText(m.Value))).Append("</span>");
            }
            string tookCell = run.DurationMs is long took ? H(Durations.Format(took)) : "<span class=\"muted\">running</span>";
            string metricCell = metrics.Length == 0 ? "" : "<span class=\"metrics\">" + metrics + "</span>";
            string hasDetail = detail.Length == 0 ? "" : " class=\"has-detail\"";
            string detailRow = detail.Length == 0 ? "" : "<tr class=\"detail\"><td colspan=\"5\">" + detail + "</td></tr>";
            runRows.Add(
                "<tr"
                + hasDetail
                + ">\n<td class=\"nowrap\">"
                + RunState(run)
                + "</td>\n<td class=\"nowrap\">"
                + H(Timeline.When(run.StartedAt, now))
                + " <span class=\"muted\">UTC</span><span class=\"sub\">"
                + Stamp(run.StartedAt, now)
                + "</span></td>\n<td class=\"nowrap\">"
                + tookCell
                + "</td>\n<td class=\"hide-sm\">"
                + metricCell
                + "</td>\n<td class=\"hide-sm muted\">"
                + H(run.Trigger)
                + "</td>\n</tr>"
                + detailRow);
        }

        string path = H(basePath) + "/jobs/" + WebText.EncodeUriComponent(job.Name);
        string why = Timeline.LaneNote(job, Timeline.MissedAt(job, Timeline.LaneSchedule(job), [], now), now);
        string whyHtml = why.Length == 0 ? "" : "<span class=\"why\">" + H(why) + "</span>";
        object? descValue = TruthyField(d, "description");
        string desc = descValue == null ? "" : "<p class=\"desc\">" + WebText.EscapeValue(descValue) + "</p>";
        string silence;
        if (job.SilencedUntil is long until && until > now)
        {
            silence = "<form class=\"inline\" method=\"post\" action=\"" + path + "/unsilence\"><button type=\"submit\">Unsilence (until "
                + H(Durations.FormatRelative(until, now)) + ")</button></form>";
        }
        else
        {
            silence = "<form class=\"inline\" method=\"post\" action=\""
                + path
                + "/silence\"><select name=\"for\" aria-label=\"Silence for\"><option"
                + " value=\"1h\">1 hour</option><option value=\"4h\">4 hours</option><option"
                + " value=\"1d\">1 day</option><option value=\"7d\">1 week</option></select><button"
                + " type=\"submit\">Silence</button></form>";
        }
        string lastRun = job.LastRun is { } lr ? H(Durations.FormatRelative(lr.StartedAt, now)) : "never";
        string nextDue = job.NextExpectedAt is long ne ? H(Durations.FormatRelative(ne, now)) : "<small>no schedule</small>";
        string runsSection;
        if (listed.Count == 0)
        {
            runsSection = "<p class=\"lede\">No runs yet.</p>";
        }
        else
        {
            string newest = listed.Count == 1 ? "run" : WebText.Count(listed.Count) + " runs";
            runsSection = "<p class=\"lede\">The newest "
                + newest
                + ", with any error and output.</p>\n  <div class=\"wide\"><table class=\"runs\">\n"
                + "<thead><tr><th>Status</th><th>Started</th><th>Took</th><th"
                + " class=\"hide-sm\">Metrics</th><th class=\"hide-sm\">Trigger</th></tr></thead>\n"
                + "<tbody>"
                + string.Join("\n", runRows)
                + "</tbody></table></div>";
        }

        string body =
            "\n<header class=\"top\">\n  "
            + Brand(basePath, job.Name)
            + "\n  <div class=\"actions\"><span class=\"meta\">"
            + H(Timeline.Clock(now))
            + " UTC</span></div>\n</header>\n<main>\n<section class=\"sec intro\""
            + " aria-label=\"Job\">\n  <h2>Job</h2>\n  <div>\n"
            + "    <h1 class=\"jobname\">"
            + WebText.EscapeName(job.Name)
            + "</h1>\n    "
            + desc
            + "\n    <p class=\"stateline\">"
            + HealthState(job)
            + whyHtml
            + "</p>\n    <div class=\"actions\">\n      "
            + silence
            + "\n      <details class=\"confirm\"><summary>Forget</summary><form class=\"inline\""
            + " method=\"post\" action=\""
            + path
            + "/forget\"><span>Remove this job and its runs from the store?</span> <button"
            + " type=\"submit\">Forget</button></form></details>\n"
            + "    </div>\n    <dl class=\"figures\">\n      <div><dt>Last run</dt><dd>"
            + lastRun
            + "</dd></div>\n      <div><dt>Next due</dt><dd>"
            + nextDue
            + "</dd></div>\n      <div><dt>Success, last "
            + H(WebText.Num(job.Stats.Runs))
            + "</dt><dd>"
            + H(okRate)
            + "</dd></div>\n      <div><dt>p50 / p95</dt><dd>"
            + Percentile(job.Stats.P50Ms)
            + " <small>/ "
            + Percentile(job.Stats.P95Ms)
            + "</small></dd></div>\n    </dl>\n  </div>\n</section>\n"
            + "<section class=\"sec\" aria-label=\"Last 7 days\">\n  <h2>Last 7 days</h2>\n"
            + "  <p class=\"lede\">A lane per UTC day, today first. Faint ticks mark when the job"
            + " was due, bars its runs, as long as they took.</p>\n"
            + "  <div class=\"wide\">"
            + Timeline.WeekTimeline(job, runs, complete, now)
            + "</div>\n</section>\n<section class=\"sec\" aria-label=\"Runs\">\n  <h2>Runs</h2>\n  "
            + runsSection
            + "\n</section>\n<section class=\"sec\" aria-label=\"Definition\">\n"
            + "  <h2>Definition</h2>\n  <dl class=\"def\">\n"
            + "  <dt>Schedule</dt><dd>"
            + DefinitionSchedule(d)
            + "</dd>\n  <dt>Grace</dt><dd>"
            + OrDefault(d, "grace", "10m")
            + "</dd>\n  <dt>Timeout</dt><dd>"
            + OrDefault(d, "timeout", "1h")
            + "</dd>\n  "
            + DefinitionRow(d, "maxDuration", "Max duration")
            + "\n  "
            + BudgetRow(d)
            + "\n  "
            + DefinitionRow(d, "expect", "Expect")
            + "\n  "
            + AlertAfterRow(d)
            + "\n  "
            + TagsRow(d)
            + "\n  "
            + OpenRow(job)
            + "\n  "
            + FailuresRow(job)
            + "\n  </dl>\n</section>\n</main>\n<footer><span>Refreshes every minute. Times are"
            + " UTC.</span><a href=\""
            + H(basePath)
            + "/api/jobs/"
            + WebText.EncodeUriComponent(job.Name)
            + "\">JSON</a></footer>";
        return Layout(job.Name + ": CronWatch", body, basePath, 60);
    }

    private static string Percentile(long? p) => p is long v ? H(Durations.Format(v)) : "?";

    private static string DefinitionSchedule(Definition d)
    {
        object? sched = TruthyField(d, "schedule");
        if (sched == null)
        {
            return "<span class=\"muted\">none</span>";
        }
        string output = WebText.EscapeValue(sched);
        object? tz = TruthyField(d, "timezone");
        if (tz != null)
        {
            output += " <span class=\"muted\">" + WebText.EscapeValue(tz) + "</span>";
        }
        return output;
    }

    /// <summary><c>h(d[key] ?? fallback)</c>.</summary>
    private static string OrDefault(Definition d, string key, string fallback)
    {
        object? v = d.Get(key);
        return v != null ? WebText.EscapeValue(v) : H(fallback);
    }

    private static string DefinitionRow(Definition d, string key, string label)
    {
        object? v = TruthyField(d, key);
        return v == null ? "" : "<dt>" + label + "</dt><dd>" + WebText.EscapeValue(v) + "</dd>";
    }

    private static string BudgetRow(Definition d)
    {
        object? v = TruthyField(d, "budget");
        if (v == null)
        {
            return "";
        }
        var parts = new List<string>();
        if (v is JsObject o)
        {
            foreach (var e in o)
            {
                parts.Add(e.Key + " ≤ " + AlertFormat.JsText(e.Value));
            }
        }
        return "<dt>Budget</dt><dd>" + H(string.Join(", ", parts)) + "</dd>";
    }

    private static string AlertAfterRow(Definition d)
    {
        object? v = TruthyField(d, "failuresBeforeAlert");
        if (v != null && Evaluate.JsNumber(v) > 1)
        {
            return "<dt>Alert after</dt><dd>" + WebText.EscapeValue(v) + " consecutive failures</dd>";
        }
        return "";
    }

    private static string TagsRow(Definition d)
    {
        var tags = new List<string>();
        object? v = d.Get("tags");
        if (v is List<object?> list)
        {
            foreach (object? e in list)
            {
                tags.Add(WebText.EscapeValue(e));
            }
        }
        else if (v is string t && t.Length > 0)
        {
            // A string's length and map are not an array's, so the SDK's page would fail on one;
            // show it as it is.
            tags.Add(H(t));
        }
        return tags.Count == 0 ? "" : "<dt>Tags</dt><dd>" + string.Join(", ", tags) + "</dd>";
    }

    private static string OpenRow(JobSummary job)
    {
        if (job.Open.Count == 0)
        {
            return "";
        }
        var spans = new StringBuilder();
        foreach (Condition c in job.Open)
        {
            string cls = c == Condition.Failed || c == Condition.Stuck ? "bad" : "warn";
            spans.Append("<span class=\"state ").Append(cls).Append("\">").Append(H(ConditionText(c))).Append("</span>");
        }
        return "<dt>Open</dt><dd>" + spans + "</dd>";
    }

    private static string FailuresRow(JobSummary job) =>
        job.ConsecutiveFailures <= 0 ? "" : "<dt>Failures in a row</dt><dd>" + WebText.Num(job.ConsecutiveFailures) + "</dd>";

    /// <summary>
    /// A page with one message. With <paramref name="signIn"/>, a form under it posts the token to
    /// <c>&lt;base&gt;/signin</c> in the body, keeping it out of the URL and access logs, and the
    /// routes set the cookie: the way in where there is no address bar to open a link with, such as
    /// an app on an iPhone's home screen.
    /// </summary>
    public static string MessagePage(string title, string message, string basePath, bool signIn)
    {
        string form = signIn
            ? "<form class=\"signin\" method=\"post\" action=\""
                + H(basePath)
                + "/signin\"><label for=\"token\">Token</label><input id=\"token\" name=\"token\""
                + " type=\"password\" autocomplete=\"current-password\" autocapitalize=\"off\""
                + " spellcheck=\"false\" required><button class=\"primary\" type=\"submit\">Sign"
                + " in</button></form>"
            : "";
        string body = "<header class=\"top\">" + Brand(basePath, null) + "</header><main class=\"message\"><h1>" + H(title) + "</h1><p>"
            + H(message) + "</p>" + form + "</main>";
        return Layout(title, body, basePath, 0);
    }
}
