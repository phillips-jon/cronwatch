using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;

namespace Cronwatch.Internal;

/// <summary>
/// Everything one lane of the board shows: the job, its runs in any order (only those overlapping
/// the span are drawn), and whether they reach back over the span (false when older runs exist
/// that were not read; the lane says so before its oldest run).
/// </summary>
internal sealed record LaneInput(JobSummary Job, IReadOnlyList<Run> Runs, bool Complete);

/// <summary>The stretch of time a timeline draws, and the moment it was drawn.</summary>
internal readonly record struct Span(long From, long To, long Now);

/// <summary>
/// The dashboard's timelines (<c>routes/timeline.ts</c>), markup for markup, carried over from the
/// Java port's <c>internal/web/Timeline</c>: one lane per job (or per day, on a job's page), drawn
/// on the server as inline SVG so the page needs no script.
/// </summary>
/// <remarks>
/// Every time a job was due is a faint tick, worked out from its schedule with the same functions
/// the checks use. Every run it recorded is a solid mark on top, as wide as it took and coloured by
/// how it ended. A slot the check has reported missed is a dashed box. The empty part of a lane
/// carries a short note about anything open, and a visually hidden list says the same things in
/// words. Every time is UTC: without script the page cannot know the viewer's zone.
/// </remarks>
internal static class Timeline
{
    private const long HourMs = 3_600_000L;
    private const long DayMs = 24 * HourMs;

    /// <summary>The board's span: the last day, plus a few hours ahead so what is due soon shows.</summary>
    public const long BoardBehindMs = DayMs;

    /// <summary>How far ahead the board looks.</summary>
    public const long BoardAheadMs = 3 * HourMs;

    /// <summary>How many jobs the board's timeline draws. The table below it lists every job.</summary>
    public const int BoardLanes = 30;

    /// <summary>
    /// Runs read for a lane when the twenty the table reads start inside the span, so a frequent
    /// job's lane is not cut short.
    /// </summary>
    public const int BoardRuns = 200;

    /// <summary>How many days a job's page draws.</summary>
    private const long WeekDays = 7;

    /// <summary>Width of a lane in SVG units. Lanes stretch to fit, so strokes do not scale.</summary>
    private const double LaneWidth = 1000;

    /// <summary>A lane with more due times than this shows its cadence as a dotted line instead.</summary>
    private const int MaxTicks = 330;

    /// <summary>More missed slots than this are drawn as one dashed band.</summary>
    private const int MaxBoxes = 8;

    /// <summary>The narrowest a missed box is drawn, in SVG units.</summary>
    private const double MinBox = 10;

    private static readonly string[] Months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
    private static readonly string[] Weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

    private static string Int(long n) => n.ToString(CultureInfo.InvariantCulture);

    /// <summary>"22:42", in UTC.</summary>
    public static string Clock(long t) => Js.IsoString(t).Substring(11, 5);

    /// <summary>"Sat 26 Sep", in UTC.</summary>
    internal static string DayLabel(long t)
    {
        long days = Js.FloorDiv(t, DayMs);
        var (_, month, day) = Js.CivilFromDays(days);
        long weekday = Js.FloorMod(days + 4, 7);
        return Weekdays[weekday] + " " + Int(day) + " " + Months[month - 1];
    }

    /// <summary>
    /// "22:42" on the same UTC day as <paramref name="now"/>, otherwise "25 Sep 22:42", and
    /// "1 Jan 0001 02:00" in another UTC year. A time before the year 1 or after 9999 is
    /// "before 1 Jan 0001 00:00" or "after 31 Dec 9999 23:59".
    /// </summary>
    public static string When(long t, long now)
    {
        if (t > Js.LastDateMs)
        {
            return "after 31 Dec 9999 23:59";
        }
        if (t < Js.FirstDateMs)
        {
            return "before 1 Jan 0001 00:00";
        }
        if (Js.FloorDiv(t, DayMs) == Js.FloorDiv(now, DayMs))
        {
            return Clock(t);
        }
        var (year, month, day) = Js.CivilFromDays(Js.FloorDiv(t, DayMs));
        var (nowYear, _, _) = Js.CivilFromDays(Js.FloorDiv(now, DayMs));
        string other = year == nowYear ? "" : " " + Js.Pad(year, 4);
        return Int(day) + " " + Months[month - 1] + other + " " + Clock(t);
    }

    /// <summary>The job's schedule, parsed, or null when it has none or it no longer parses.</summary>
    public static ParsedSchedule? LaneSchedule(JobSummary job)
    {
        if (!Evaluate.Truthy(job.Definition.Get("schedule")))
        {
            return null;
        }
        try
        {
            return Evaluate.ScheduleOf(job.Definition);
        }
        catch (Exception)
        {
            return null;
        }
    }

    private readonly record struct Due(List<long> Times, bool Dense);

    private static long SaturatingAdd(long a, long b)
    {
        long sum = unchecked(a + b);
        if (((a ^ sum) & (b ^ sum)) < 0)
        {
            return a < 0 ? long.MinValue : long.MaxValue;
        }
        return sum;
    }

    private static long SaturatingMul(long a, long b)
    {
        long high = Math.BigMul(a, b, out long low);
        if ((high == 0 && low >= 0) || (high == -1 && low < 0))
        {
            return low;
        }
        return (a < 0) == (b < 0) ? long.MaxValue : long.MinValue;
    }

    /// <summary>
    /// When the job was due within <paramref name="from"/> to <paramref name="to"/>, ascending,
    /// and whether they are too many to draw one by one. A cron's fires come from its schedule. An
    /// interval is due one period after each run started, and after the last run once a period for
    /// as long as nothing runs; with no run yet, from its next expected time.
    /// </summary>
    private static Due DueTimes(JobSummary job, ParsedSchedule? parsed, IReadOnlyList<Run> runs, long from, long to)
    {
        if (parsed == null)
        {
            return new Due([], false);
        }
        if (parsed.IsInterval)
        {
            long every = (long)parsed.EveryMs;
            if (every <= 0)
            {
                return new Due([], false);
            }
            if ((double)(to - from) / every > MaxTicks)
            {
                return new Due([], true);
            }
            var starts = runs.Select(r => r.StartedAt).ToList();
            starts.Sort();
            var set = new SortedSet<long>();
            foreach (long start in starts)
            {
                long t = SaturatingAdd(start, every);
                if (t >= from && t <= to)
                {
                    set.Add(t);
                }
            }
            long? next = starts.Count == 0 ? job.NextExpectedAt : SaturatingAdd(starts[^1], every);
            if (next is long n)
            {
                long t = n;
                if (t < from)
                {
                    // Saturating: a foreign row's start can be anywhere.
                    long steps = (long)Math.Ceiling((double)Evaluate.SaturatingSub(from, t) / every);
                    t = SaturatingAdd(t, SaturatingMul(steps, every));
                }
                while (t <= to)
                {
                    set.Add(t);
                    t += every;
                }
            }
            return new Due([.. set], false);
        }
        List<long>? fires;
        try
        {
            fires = Schedules.FiresBetween(parsed, from - 1, to, MaxTicks);
        }
        catch (Exception)
        {
            return new Due([], false);
        }
        return fires == null ? new Due([], true) : new Due(fires, false);
    }

    private static double GraceOrZero(Definition d)
    {
        try
        {
            return Evaluate.GraceMs(d);
        }
        catch (Exception)
        {
            return 0;
        }
    }

    /// <summary>
    /// The slot a missed job was due at, the one the check reported: the first fire its last run
    /// does not cover. A job that never ran has no run to count from, so the latest due time whose
    /// grace has passed stands in. Null when missed is not open.
    /// </summary>
    public static long? MissedAt(JobSummary job, ParsedSchedule? parsed, IReadOnlyList<long> times, long now)
    {
        if (parsed == null || !job.Open.Contains(Condition.Missed))
        {
            return null;
        }
        double grace = GraceOrZero(job.Definition);
        Run? last = job.LastRun;
        if (last != null)
        {
            long started = last.StartedAt;
            try
            {
                return Schedules.GetExpectation(parsed, started, started, grace)?.DueAt;
            }
            catch (Exception)
            {
                return null;
            }
        }
        for (int i = times.Count - 1; i >= 0; i--)
        {
            long t = times[i];
            if ((double)t + grace < now)
            {
                return t;
            }
        }
        return null;
    }

    private static bool Stuck(JobSummary job, Run run, long now)
    {
        try
        {
            return Evaluate.IsStuck(job.Definition, run, now);
        }
        catch (Exception)
        {
            return false;
        }
    }

    private static string ToneOf(Run run, JobSummary job, long now)
    {
        if (run.Status == RunStatus.Running)
        {
            return Stuck(job, run, now) ? "stuck" : "running";
        }
        if (run.Status == RunStatus.Failed)
        {
            return "bad";
        }
        if (run.Status == RunStatus.Timeout)
        {
            return "timeout";
        }
        Run? last = job.LastRun;
        bool latest = last != null && string.Equals(last.Id, run.Id, StringComparison.Ordinal);
        if (latest && (job.Open.Contains(Condition.OverBudget) || job.Open.Contains(Condition.Slow)))
        {
            return "warn";
        }
        return "ok";
    }

    private static string TimeoutText(JobSummary job)
    {
        try
        {
            return Durations.Format(Evaluate.TimeoutMs(job.Definition));
        }
        catch (Exception)
        {
            return "configured";
        }
    }

    /// <summary>One run, as its tooltip says it.</summary>
    private static string DescribeRun(Run run, string tone, JobSummary job, long now)
    {
        string at = When(run.StartedAt, now) + " UTC";
        switch (tone)
        {
            case "running":
                return "running since " + at + ", " + Durations.Format(Evaluate.SaturatingSub(now, run.StartedAt)) + " so far";
            case "stuck":
                return "running since " + at + ", past its " + TimeoutText(job) + " timeout";
        }
        string took = run.DurationMs is long d ? ", took " + Durations.Format(d) : "";
        string extra = "";
        if (tone == "warn")
        {
            extra = job.Open.Contains(Condition.OverBudget) ? ", over budget" : ", slow";
        }
        return run.Status.Value + " at " + at + took + extra;
    }

    /// <summary>The metrics of the job's last run that went over their ceilings.</summary>
    private static List<string> OverCeilings(JobSummary job)
    {
        var output = new List<string>();
        if (job.Definition.Get("budget") is not JsObject budget)
        {
            return output;
        }
        Run? last = job.LastRun;
        foreach (var e in budget)
        {
            double value = last != null && last.Metrics.TryGetValue(e.Key, out double v) ? v : double.NegativeInfinity;
            if (value > Evaluate.JsNumber(e.Value))
            {
                output.Add(e.Key);
            }
        }
        return output;
    }

    /// <summary>What is worth saying about the job in a few words, or <c>""</c> when all is well.</summary>
    public static string LaneNote(JobSummary job, long? missed, long now)
    {
        Run? last = job.LastRun;
        var open = job.Open;
        if (job.SilencedUntil is long until && until > now)
        {
            return "silenced until " + When(until, now);
        }
        if (open.Contains(Condition.Missed))
        {
            return missed is long m ? "due " + When(m, now) + ", nothing ran" : "overdue, nothing ran";
        }
        if (last != null)
        {
            if (last.Status == RunStatus.Running)
            {
                if (Stuck(job, last, now))
                {
                    return "running since " + When(last.StartedAt, now) + ", past its " + TimeoutText(job) + " timeout";
                }
                return "running since " + When(last.StartedAt, now);
            }
            if (last.Status == RunStatus.Failed)
            {
                string text = "failed at " + When(last.StartedAt, now);
                if (job.ConsecutiveFailures > 1)
                {
                    text += ", " + WebText.Num(job.ConsecutiveFailures) + " in a row";
                }
                return text;
            }
            if (last.Status == RunStatus.Timeout)
            {
                return "timed out at " + When(last.StartedAt, now);
            }
        }
        if (open.Contains(Condition.Stuck))
        {
            return "stuck";
        }
        if (open.Contains(Condition.OverBudget) && last != null)
        {
            string text = "went over budget";
            var over = OverCeilings(job);
            if (over.Count > 0)
            {
                text += " on " + string.Join(" and ", over);
            }
            return text + " at " + When(last.StartedAt, now);
        }
        if (open.Contains(Condition.Slow) && last is { DurationMs: long took })
        {
            return "slow: took " + Durations.Format(took);
        }
        if (open.Contains(Condition.Failed))
        {
            return "failing";
        }
        if (last == null && job.NextExpectedAt is long next)
        {
            return "no runs yet, first due " + When(next, now);
        }
        return "";
    }

    private readonly record struct LaneParts(string Svg, string Note, string Words);

    /// <summary><c>toFixed(1)</c>, the precision every coordinate is written with.</summary>
    private static string Fx(double n) => WebText.ToFixed(n, 1);

    /// <summary>The animation delay for a mark at <paramref name="x"/>, so marks arrive in time order, left to right.</summary>
    private static string Delay(double x, double basis, double perUnit) =>
        "--d:" + WebText.Num(Js.Round(basis + (Math.Max(x, 0) * perUnit))) + "ms";

    private static long FinishedOr(Run r, long now) => r.FinishedAt ?? now;

    private static double ClampLane(double v) => Math.Max(0, Math.Min(LaneWidth, v));

    /// <summary>A lane's x for a time.</summary>
    private static double X(long t, Span sp) => ClampLane((double)(t - sp.From) / (sp.To - sp.From) * LaneWidth);

    /// <summary>A lane's x for a time that need not be whole (a slot plus its grace).</summary>
    private static double Xf(double t, Span sp) => ClampLane((t - sp.From) / (sp.To - sp.From) * LaneWidth);

    private static LaneParts Lane(JobSummary job, IReadOnlyList<Run> runs, bool complete, Span sp, bool nowInLane, string name)
    {
        long from = sp.From;
        long to = sp.To;
        long now = sp.Now;
        ParsedSchedule? parsed = LaneSchedule(job);
        Due due = DueTimes(job, parsed, runs, from, to);
        List<long> times = due.Times;
        bool dense = due.Dense;
        long? missed = MissedAt(job, parsed, times, now);
        double grace = GraceOrZero(job.Definition);
        var busy = new List<(double Lo, double Hi)>();

        var s = new StringBuilder("<svg class=\"marks\" viewBox=\"0 0 1000 24\" preserveAspectRatio=\"none\" aria-hidden=\"true\" focusable=\"false\">");
        if (nowInLane && now > from && now < to)
        {
            s.Append("<rect class=\"ahead\" x=\"").Append(Fx(X(now, sp))).Append("\" y=\"0\" width=\"")
                .Append(Fx(LaneWidth - X(now, sp))).Append("\" height=\"24\"/>");
        }
        s.Append("<line class=\"base\" x1=\"0\" y1=\"12\" x2=\"1000\" y2=\"12\"/>");

        var inSpan = runs.Where(r => r.StartedAt <= to && FinishedOr(r, now) >= from).OrderBy(r => r.StartedAt).ToList();
        if (!complete && runs.Count > 0)
        {
            long oldest = runs.Min(r => r.StartedAt);
            if (oldest > from)
            {
                s.Append("<rect class=\"unloaded\" x=\"0\" y=\"4\" width=\"").Append(Fx(X(oldest, sp)))
                    .Append("\" height=\"16\"><title>")
                    .Append(WebText.EscapeHtml(name + ": runs before " + When(oldest, now) + " UTC are not loaded here"))
                    .Append("</title></rect>");
            }
        }

        if (dense)
        {
            s.Append("<line class=\"cadence\" x1=\"0\" y1=\"12\" x2=\"1000\" y2=\"12\"><title>")
                .Append(WebText.EscapeHtml(name + ": due " + ScheduleText(job, "") + ", too often to mark each time"))
                .Append("</title></line>");
        }
        foreach (long t in times)
        {
            double tx = X(t, sp);
            string ahead = t > now ? " ahead" : "";
            s.Append("<line class=\"tick").Append(ahead).Append("\" x1=\"").Append(Fx(tx)).Append("\" y1=\"6\" x2=\"")
                .Append(Fx(tx)).Append("\" y2=\"18\" style=\"").Append(Delay(tx, 0, 0.45)).Append("\"/>");
        }

        // Missed slots: the reported one and every later one whose grace has run out.
        if (missed is long m && m <= to)
        {
            var slots = new List<long>();
            if (!dense)
            {
                foreach (long t in times)
                {
                    if (t >= m && (double)t + grace < now)
                    {
                        slots.Add(t);
                    }
                }
            }
            if (!slots.Contains(m) && m >= from)
            {
                slots.Insert(0, m);
            }
            string title = name + ": due " + When(m, now) + " UTC, nothing started";
            if (slots.Count > 1)
            {
                title += " (" + WebText.Count(slots.Count) + " slots in this span)";
            }
            title = WebText.EscapeHtml(title);
            if (dense || slots.Count > MaxBoxes)
            {
                double x1 = X(Math.Max(m, from), sp);
                double x2 = Math.Max(X(now, sp), x1 + MinBox);
                MissedBox(s, x1, x2 - x1, title);
                busy.Add((x1, x2));
            }
            else
            {
                foreach (long t in slots)
                {
                    if (t < from)
                    {
                        continue;
                    }
                    double x1 = X(t, sp);
                    double width = Math.Max(Xf((double)t + grace, sp) - x1, MinBox);
                    MissedBox(s, x1, width, title);
                    busy.Add((x1, x1 + width));
                }
            }
        }

        foreach (Run run in inSpan)
        {
            string tone = ToneOf(run, job, now);
            // A zero-width rect is not drawn at all; its stroke gives short runs their width.
            double x1 = X(run.StartedAt, sp);
            double x2 = Math.Max(X(FinishedOr(run, now), sp), x1 + 0.5);
            s.Append("<rect class=\"run ").Append(tone).Append("\" x=\"").Append(Fx(x1)).Append("\" y=\"5\" width=\"")
                .Append(Fx(x2 - x1)).Append("\" height=\"14\" style=\"").Append(Delay(x1, 80, 0.75)).Append("\"><title>")
                .Append(WebText.EscapeHtml(name + ": " + DescribeRun(run, tone, job, now))).Append("</title></rect>");
            busy.Add((x1, x2));
        }

        if (nowInLane && now > from && now < to)
        {
            string nx = Fx(X(now, sp));
            s.Append("<line class=\"nowline\" x1=\"").Append(nx).Append("\" y1=\"0\" x2=\"").Append(nx).Append("\" y2=\"24\"/>");
        }
        s.Append("</svg>");

        // The note goes wherever the lane is actually empty, so it never sits on the marks it
        // describes; it is cut short with an ellipsis when narrow.
        string text = LaneNote(job, missed, now);
        string note = "";
        if (text.Length > 0)
        {
            double nowX = X(now, sp);
            double lo = nowX;
            double hi = nowX;
            if (busy.Count > 0)
            {
                lo = double.PositiveInfinity;
                hi = double.NegativeInfinity;
                foreach (var b in busy)
                {
                    lo = Math.Min(lo, b.Lo);
                    hi = Math.Max(hi, b.Hi);
                }
            }
            bool right = LaneWidth - hi >= lo;
            double room = right ? LaneWidth - hi : lo;
            if (room > 90)
            {
                string place = right ? "left:" + Fx((hi + 14) / 10) + "%" : "right:" + Fx(100 - ((lo - 14) / 10)) + "%";
                string cls = right ? "" : " before";
                note = "<span class=\"note" + cls + "\" style=\"" + place + ";max-width:" + Fx((room - 18) / 10) + "%\">"
                    + WebText.EscapeHtml(text) + "</span>";
            }
        }
        string words = LaneWords(job, inSpan, times, dense, missed, sp, text);
        return new LaneParts(s.ToString(), note, words);
    }

    private static void MissedBox(StringBuilder s, double x1, double width, string title) =>
        s.Append("<rect class=\"missed\" x=\"").Append(Fx(x1)).Append("\" y=\"5\" width=\"").Append(Fx(width))
            .Append("\" height=\"14\" style=\"").Append(Delay(x1, 80, 0.75)).Append("\"><title>").Append(title).Append("</title></rect>");

    /// <summary><c>`${definition.schedule ?? fallback}`</c>.</summary>
    private static string ScheduleText(JobSummary job, string fallback)
    {
        object? v = job.Definition.Get("schedule");
        return v == null ? fallback : AlertFormat.JsText(v);
    }

    /// <summary>The lane in words, for anyone who cannot see it.</summary>
    private static string LaneWords(JobSummary job, List<Run> runs, List<long> times, bool dense, long? missed, Span sp, string note)
    {
        var parts = new List<string>();
        if (dense)
        {
            parts.Add("due " + AlertFormat.JsText(job.Definition, "schedule"));
        }
        else if (Evaluate.Truthy(job.Definition.Get("schedule")))
        {
            long n = times.Count(t => t <= sp.Now);
            parts.Add(n == 0 ? "due no times so far" : n == 1 ? "due once so far" : "due " + WebText.Count(n) + " times so far");
        }
        long ok = runs.Count(r => r.Status == RunStatus.Ok);
        string recorded = runs.Count == 1 ? "1 run recorded" : WebText.Count(runs.Count) + " runs recorded";
        if (runs.Count > 0)
        {
            if (ok == runs.Count && ok == 1)
            {
                recorded += ", ok";
            }
            else if (ok == runs.Count)
            {
                recorded += ", all ok";
            }
            else if (ok > 0)
            {
                recorded += ", " + WebText.Count(ok) + " ok";
            }
        }
        parts.Add(recorded);
        var bad = runs.Where(r => r.Status == RunStatus.Failed || r.Status == RunStatus.Timeout).ToList();
        foreach (Run r in bad.Skip(Math.Max(0, bad.Count - 5)))
        {
            parts.Add(r.Status.Value + " at " + When(r.StartedAt, sp.Now) + " UTC after " + Durations.Format(r.DurationMs ?? 0));
        }
        if (missed is long m)
        {
            parts.Add("due at " + When(m, sp.Now) + " UTC and nothing started");
        }
        if (note.Length > 0
            && !note.StartsWith("due ", StringComparison.Ordinal)
            && !note.StartsWith("failed at", StringComparison.Ordinal)
            && !note.StartsWith("timed out", StringComparison.Ordinal))
        {
            parts.Add(note);
        }
        return string.Join("; ", parts);
    }

    /// <summary>The grid lines and hour labels every <paramref name="step"/>, on UTC boundaries.</summary>
    private static (string Lines, string Labels) HourGrid(Span sp, long step, bool nowLabel)
    {
        double nowX = GridX(sp.Now, sp);
        var lines = new StringBuilder();
        var labels = new StringBuilder();
        long t = -Js.FloorDiv(-sp.From, step) * step;
        while (t <= sp.To)
        {
            double gx = GridX(t, sp);
            lines.Append("<i class=\"gl\" style=\"left:").Append(Fx(gx / 10)).Append("%\"></i>");
            bool nearNow = nowLabel && Math.Abs(gx - nowX) < 70;
            if (gx >= 25 && gx <= LaneWidth - 25 && !nearNow)
            {
                var cls = new List<string>();
                if (Js.Round((double)t / HourMs) % 6.0 != 0.0)
                {
                    cls.Add("minor");
                }
                // On a phone the track is too narrow for a label this close to "now"; CSS hides it there.
                if (nowLabel && Math.Abs(gx - nowX) < 170)
                {
                    cls.Add("near");
                }
                labels.Append("<span class=\"").Append(string.Join(" ", cls)).Append("\" style=\"left:").Append(Fx(gx / 10))
                    .Append("%\">").Append(Clock(t)).Append("</span>");
            }
            t += step;
        }
        if (nowLabel && sp.Now >= sp.From && sp.Now <= sp.To)
        {
            labels.Append("<span class=\"nowlabel\" style=\"left:").Append(Fx(nowX / 10)).Append("%\">now ").Append(Clock(sp.Now)).Append("</span>");
        }
        return (lines.ToString(), labels.ToString());
    }

    private static double GridX(long t, Span sp) => (double)(t - sp.From) / (sp.To - sp.From) * LaneWidth;

    private static string Key(string inner) =>
        "<svg class=\"key\" viewBox=\"0 0 16 12\" aria-hidden=\"true\" focusable=\"false\">" + inner + "</svg>";

    private static string Boxed(string cls) => Key("<rect class=\"" + cls + "\" x=\"2\" y=\"1\" width=\"12\" height=\"10\"/>");

    /// <summary>The key under a timeline: a small sample of each mark and what it means.</summary>
    private static string Legend()
    {
        (string Mark, string Label)[] items =
        [
            (Key("<line class=\"tick\" x1=\"8\" y1=\"1\" x2=\"8\" y2=\"11\"/>"), "due"),
            (Boxed("run ok"), "ran"),
            (Boxed("run bad"), "failed"),
            (Boxed("run timeout"), "timed out"),
            (Boxed("run warn"), "over budget or slow"),
            (Boxed("run running"), "running"),
            (Boxed("missed"), "missed"),
        ];
        var b = new StringBuilder("<p class=\"legend\" aria-hidden=\"true\">");
        foreach (var (mark, label) in items)
        {
            b.Append("<span>").Append(mark).Append(label).Append("</span>");
        }
        return b.Append("</p>").ToString();
    }

    private static string StateClass(JobSummary job)
    {
        JobHealth h = job.Health;
        if (h == JobHealth.Healthy)
        {
            return "ok";
        }
        if (h == JobHealth.Late)
        {
            return "warn";
        }
        if (h == JobHealth.Failing || h == JobHealth.Stuck)
        {
            return "bad";
        }
        return "muted";
    }

    /// <summary>
    /// The board's timeline: one lane per job across <paramref name="sp"/>, with a shared now line
    /// and the first <see cref="BoardLanes"/> jobs only. <paramref name="total"/> is how many jobs
    /// there are in all, for the note when some are left out.
    /// </summary>
    public static string DayTimeline(IReadOnlyList<LaneInput> lanes, Span sp, string basePath, int total)
    {
        var (gridLines, gridLabels) = HourGrid(sp, 3 * HourMs, true);
        double nowX = (double)(sp.Now - sp.From) / (sp.To - sp.From) * 100;
        var rows = new StringBuilder();
        var words = new StringBuilder();
        foreach (LaneInput input in lanes)
        {
            JobSummary job = input.Job;
            LaneParts parts = Lane(job, input.Runs, input.Complete, sp, false, job.Name);
            string sched = ScheduleText(job, "no schedule");
            rows.Append("<li class=\"lane\"><div class=\"who\"><i class=\"sq ").Append(StateClass(job))
                .Append("\" aria-hidden=\"true\"></i><a class=\"name\" href=\"").Append(WebText.EscapeHtml(basePath))
                .Append("/jobs/").Append(WebText.EncodeUriComponent(job.Name)).Append("\">").Append(WebText.EscapeName(job.Name))
                .Append("</a><span class=\"sched\">").Append(WebText.EscapeHtml(sched)).Append("</span></div><div class=\"track\">")
                .Append(parts.Svg).Append(parts.Note).Append("</div></li>");
            words.Append("<li>").Append(WebText.EscapeHtml(job.Name + " (" + sched + "): " + parts.Words + ".")).Append("</li>");
        }
        string more = "";
        if (total > lanes.Count)
        {
            more = "<p class=\"more\">Showing the first " + WebText.Count(lanes.Count) + " of " + WebText.Count(total)
                + " jobs here; the table below lists them all.</p>";
        }
        return "<figure class=\"timeline day\">\n<div class=\"axis\" aria-hidden=\"true\"><span></span><div class=\"hours\">"
            + gridLabels
            + "</div></div>\n<div class=\"field\">\n<div class=\"under\" aria-hidden=\"true\"><span></span><div>"
            + gridLines
            + "<i class=\"future\" style=\"left:"
            + Fx(nowX)
            + "%\"></i></div></div>\n<ol class=\"lanes\">"
            + rows
            + "</ol>\n<div class=\"over\" aria-hidden=\"true\"><span></span><div><i class=\"now\" style=\"left:"
            + Fx(nowX)
            + "%\"></i></div></div>\n</div>\n"
            + Legend()
            + more
            + "\n<ul class=\"vh\">"
            + words
            + "</ul>\n</figure>";
    }

    /// <summary>
    /// A job's page: its last seven UTC days, today first, one lane each.
    /// <paramref name="complete"/> is false when the runs read do not reach back over the week.
    /// </summary>
    public static string WeekTimeline(JobSummary job, IReadOnlyList<Run> runs, bool complete, long now)
    {
        long today = Js.FloorDiv(now, DayMs) * DayMs;
        long? oldest = runs.Count == 0 ? null : runs.Min(r => r.StartedAt);
        var (gridLines, gridLabels) = HourGrid(new Span(today, today + DayMs, now), 3 * HourMs, false);
        var rows = new StringBuilder();
        var words = new StringBuilder();
        for (long i = 0; i < WeekDays; i++)
        {
            long from = today - (i * DayMs);
            var sp = new Span(from, from + DayMs, now);
            long n = runs.Count(r => r.StartedAt < sp.To && FinishedOr(r, now) >= from);
            bool known = complete || (oldest is long o && o <= from);
            string label = i == 0 ? "today" : DayLabel(from);
            LaneParts parts = Lane(job, runs, known, sp, i == 0, job.Name + ", " + label);
            string countText = n == 1 ? "1 run" : WebText.Count(n) + " runs";
            string cls;
            string name;
            string note;
            string said;
            if (i == 0)
            {
                cls = " today";
                name = "Today, " + DayLabel(from)[4..];
                note = parts.Note;
                said = "Today";
            }
            else
            {
                cls = "";
                name = DayLabel(from);
                note = "";
                said = DayLabel(from);
            }
            rows.Append("<li class=\"lane").Append(cls).Append("\"><div class=\"who\"><span class=\"name\">").Append(WebText.EscapeHtml(name))
                .Append("</span><span class=\"sched\">").Append(WebText.EscapeHtml(countText)).Append("</span></div><div class=\"track\">")
                .Append(parts.Svg).Append(note).Append("</div></li>");
            words.Append("<li>").Append(WebText.EscapeHtml(said + ": " + parts.Words + ".")).Append("</li>");
        }
        return "<figure class=\"timeline week\">\n<div class=\"axis\" aria-hidden=\"true\"><span></span><div class=\"hours\">"
            + gridLabels
            + "</div></div>\n<div class=\"field\">\n<div class=\"under\" aria-hidden=\"true\"><span></span><div>"
            + gridLines
            + "</div></div>\n<ol class=\"lanes\">"
            + rows
            + "</ol>\n</div>\n"
            + Legend()
            + "\n<ul class=\"vh\">"
            + words
            + "</ul>\n</figure>";
    }

    /// <summary>
    /// How many runs a job's page reads so its week is drawn in full: roughly how often the
    /// schedule was due over the week, with room to spare, from 50 (what the run list shows) to
    /// 500 (the most a read returns).
    /// </summary>
    public static int WeekRunsLimit(JobSummary job, long now)
    {
        ParsedSchedule? parsed = LaneSchedule(job);
        if (parsed == null)
        {
            return 50;
        }
        long from = (Js.FloorDiv(now, DayMs) * DayMs) - ((WeekDays - 1) * DayMs);
        double width = now + DayMs - from;
        double expected;
        if (parsed.IsInterval)
        {
            expected = width / (long)parsed.EveryMs;
        }
        else
        {
            // A cron's fires over one day, times the week: close enough, and cheap.
            Due due = DueTimes(job, parsed, [], now - DayMs, now);
            expected = due.Dense ? double.PositiveInfinity : due.Times.Count * width / DayMs;
        }
        return (int)Math.Max(50, Math.Min(500, Math.Ceiling(expected * 1.2) + 10));
    }
}
