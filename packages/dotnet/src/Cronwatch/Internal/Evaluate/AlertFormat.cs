using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;

namespace Cronwatch.Internal;

/// <summary>
/// Alert titles and messages (the SDK's <c>format.ts</c>), character for character, and the
/// numbers in them as JavaScript's <c>toLocaleString("en-US")</c> writes them.
/// </summary>
internal static class AlertFormat
{
    private static readonly string Infinity = ((char)0x221E).ToString();

    /// <summary>
    /// <c>andList</c>: words joined as an English list, with a serial comma from three on:
    /// <c>a</c>, <c>a and b</c>, <c>a, b, and c</c>. Every port joins the same way.
    /// </summary>
    public static string AndList(IReadOnlyList<string> words)
    {
        if (words.Count <= 2)
        {
            return string.Join(" and ", words);
        }
        return string.Join(", ", words.Take(words.Count - 1)) + ", and " + words[words.Count - 1];
    }

    /// <summary>
    /// <c>formatNumber</c>: a whole number grouped in thousands (<c>1,234</c>), anything else
    /// rounded to at most four decimals (<c>0.0123</c>), as <c>Intl.NumberFormat("en-US")</c> writes
    /// them. ICU starts from the shortest decimal digits that read back as the number, rounds half
    /// away from zero (0.03125 is <c>0.0313</c>), and keeps the sign of a negative number that
    /// rounds to zero (<c>-0</c>). .NET's <c>"N"</c> rounds from the binary value, so it is not used.
    /// </summary>
    public static string FormatNumber(double n)
    {
        if (double.IsNaN(n))
        {
            return "NaN";
        }
        if (double.IsInfinity(n))
        {
            return n > 0 ? Infinity : "-" + Infinity;
        }
        bool negative = n < 0 || (n == 0 && double.IsNegative(n));
        string whole;
        string frac;
        if (n == 0)
        {
            whole = "0";
            frac = "";
        }
        else
        {
            var (digits, point) = Js.Shortest(Math.Abs(n));
            // The value is 0.d1...dk * 10^point; keep the digits down to 10^-4.
            int keep = point + 4;
            char[] kept;
            if (keep >= digits.Length)
            {
                kept = digits.ToCharArray();
            }
            else if (keep < 0)
            {
                kept = [];
            }
            else
            {
                kept = digits[..keep].ToCharArray();
                if (digits[keep] >= '5')
                {
                    // Half away from zero: add one at the last kept place, carrying.
                    int i = kept.Length - 1;
                    while (i >= 0 && kept[i] == '9')
                    {
                        kept[i] = '0';
                        i--;
                    }
                    if (i >= 0)
                    {
                        kept[i]++;
                    }
                    else
                    {
                        var grown = new char[kept.Length + 1];
                        grown[0] = '1';
                        Array.Copy(kept, 0, grown, 1, kept.Length);
                        kept = grown;
                        point++;
                    }
                }
            }
            // Lay the kept digits out around the point.
            var all = new StringBuilder();
            int intDigits;
            if (point <= 0)
            {
                all.Append('0', -point);
                all.Append(kept);
                intDigits = 0;
            }
            else
            {
                all.Append(kept);
                if (all.Length < point)
                {
                    all.Append('0', point - all.Length);
                }
                intDigits = point;
            }
            string s = all.ToString();
            whole = intDigits == 0 ? "0" : s[..intDigits];
            frac = s[intDigits..];
            if (frac.Length > 4)
            {
                frac = frac[..4];
            }
            frac = frac.TrimEnd('0');
            whole = whole.TrimStart('0');
            if (whole.Length == 0)
            {
                whole = "0";
            }
        }
        var b = new StringBuilder(negative ? "-" : "");
        b.Append(Group(whole));
        if (frac.Length > 0)
        {
            b.Append('.').Append(frac);
        }
        return b.ToString();
    }

    // A comma between each three digits, from the right.
    private static string Group(string digits)
    {
        if (digits.Length <= 3)
        {
            return digits;
        }
        var b = new StringBuilder();
        int head = digits.Length % 3;
        if (head > 0)
        {
            b.Append(digits, 0, head);
        }
        for (int i = head; i < digits.Length; i += 3)
        {
            if (b.Length > 0)
            {
                b.Append(',');
            }
            b.Append(digits, i, 3);
        }
        return b.ToString();
    }

    /// <summary>
    /// <c>2026-01-05 09:30:00 UTC (5m ago)</c>, or <c>before 0001-01-01 00:00:00 UTC</c> (with no
    /// relative part) for a time outside the years 1 to 9999.
    /// </summary>
    internal static string When(double at, long now)
    {
        if (!(at >= Js.FirstDateMs && at <= Js.LastDateMs))
        {
            return at > Js.LastDateMs ? Js.BeyondDates(long.MaxValue) : Js.BeyondDates(long.MinValue);
        }
        string iso = Js.IsoString((long)at);
        return iso[..10] + " " + iso[11..19] + " UTC (" + Relative(at, now) + ")";
    }

    // formatRelative, for a time that may carry a fraction of a millisecond.
    private static string Relative(double at, long now)
    {
        double diff = at - now;
        double abs = Math.Abs(diff);
        if (abs < 5_000)
        {
            return "now";
        }
        string text = EvaluateDeps.FormatDuration(abs);
        return diff < 0 ? text + " ago" : "in " + text;
    }

    private static string FirstLines(string text, int n)
    {
        string[] lines = text.Split('\n');
        return string.Join("\n", lines, 0, Math.Min(n, lines.Length));
    }

    private static string Tail(string? text, int n)
    {
        if (string.IsNullOrEmpty(text))
        {
            return "";
        }
        string[] lines = Js.TrimEnd(text).Split('\n');
        int from = Math.Max(0, lines.Length - n);
        return string.Join("\n", lines, from, lines.Length - from);
    }

    /// <summary>Whether the text starts <c>Name: </c>, as <c>/^[A-Za-z_$][\w$]*: /</c> matches.</summary>
    internal static bool NamesItself(string text)
    {
        if (text.Length == 0 || !(IsAsciiLetter(text[0]) || text[0] == '_' || text[0] == '$'))
        {
            return false;
        }
        int end = 1;
        while (end < text.Length)
        {
            char c = text[end];
            if (!(IsAsciiLetter(c) || (c >= '0' && c <= '9') || c == '_' || c == '$'))
            {
                break;
            }
            end++;
        }
        return string.CompareOrdinal(text, end, ": ", 0, 2) == 0 && end + 2 <= text.Length;
    }

    private static bool IsAsciiLetter(char c) => (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');

    /// <summary><c>Error: x</c> for a bare message, but not <c>Error: TypeError: x</c> for one that already names itself.</summary>
    internal static string ErrorLine(string error)
    {
        string text = FirstLines(error, 4);
        return NamesItself(text) ? text : "Error: " + text;
    }

    /// <summary>A JSON value as a JavaScript template literal writes it, and <c>undefined</c> for a field that is absent.</summary>
    public static string JsText(Definition def, string key) => def.Has(key) ? JsText(def.Get(key)) : "undefined";

    /// <summary>A JSON value as a JavaScript template literal writes it.</summary>
    public static string JsText(object? v)
    {
        switch (v)
        {
            case null:
                return "null";
            case string s:
                return s;
            case bool b:
                return b ? "true" : "false";
            case List<object?> list:
                var parts = new List<string>(list.Count);
                foreach (var e in list)
                {
                    parts.Add(e == null ? "" : JsText(e));
                }
                return string.Join(",", parts);
            case JsObject:
                return "[object Object]";
            default:
                return JsonText.TryNumber(v, out double n) ? Js.FormatNumber(n) : v.ToString() ?? "";
        }
    }

    /// <summary>Turns a draft into the title and message every channel shows.</summary>
    public static Alert ComposeAlert(AlertDraft draft, Definition def, long now)
    {
        string name = JsText(def, "name");
        var run = draft.Run;
        var lines = new List<string>();
        var type = draft.Type;
        var details = draft.Details;
        string title = "";
        if (type == AlertType.Missed && details is AlertDetails.Missed d)
        {
            lines.Add("Due " + When(d.DueAt, now) + ", and no run had started by " + When(d.Deadline, now)
                + " (grace " + EvaluateDeps.FormatDuration(d.GraceMs) + ").");
            object? tz = def.Get("timezone");
            string zone = Evaluate.Truthy(tz) ? " (" + JsText(tz) + ")" : "";
            lines.Add("Schedule: " + JsText(def, "schedule") + zone + ".");
            lines.Add("Last run: " + (run == null ? "never" : run.Status.Value + " " + When(run.StartedAt, now)) + ".");
            title = name + " missed its scheduled run";
        }
        else if (type == AlertType.Failed)
        {
            if (details is AlertDetails.Failure f && f.ConsecutiveFailures > 1)
            {
                lines.Add(Js.FormatLong(f.ConsecutiveFailures) + " consecutive failures.");
            }
            if (run != null)
            {
                string ran = run.DurationMs == null ? "" : ", ran " + EvaluateDeps.FormatDuration(run.DurationMs.Value);
                lines.Add("Started " + When(run.StartedAt, now) + ran + ".");
                if (!string.IsNullOrEmpty(run.Error))
                {
                    lines.Add(ErrorLine(run.Error));
                }
                string output = Tail(run.Output, 8);
                if (output.Length > 0)
                {
                    lines.Add("Output (tail):\n" + output);
                }
            }
            title = name + " failed";
        }
        else if (type == AlertType.Stuck)
        {
            if (run != null)
            {
                double ran = run.DurationMs ?? Evaluate.SaturatingSub(now, run.StartedAt);
                lines.Add("Started " + When(run.StartedAt, now) + " and never reported finishing. Marked as timed out after "
                    + EvaluateDeps.FormatDuration(ran) + ".");
                string output = Tail(run.Output, 8);
                if (output.Length > 0)
                {
                    lines.Add("Output so far (tail):\n" + output);
                }
            }
            lines.Add("If the process was killed mid-run (a serverless timeout, a deploy), this is what that looks like.");
            title = name + " is stuck";
        }
        else if (type == AlertType.Slow && details is AlertDetails.Slow s)
        {
            lines.Add("Took " + EvaluateDeps.FormatDuration(s.DurationMs) + "; the limit is " + EvaluateDeps.FormatDuration(s.ThresholdMs)
                + " (" + s.Basis + ").");
            if (run != null)
            {
                lines.Add("Started " + When(run.StartedAt, now) + ".");
            }
            title = name + " was slow";
        }
        else if (type == AlertType.OverBudget && details is AlertDetails.OverBudget o)
        {
            foreach (var b in o.Breaches)
            {
                lines.Add(b.Metric + ": " + FormatNumber(b.Value) + ", limit " + FormatNumber(b.Limit) + " (" + b.Basis + ").");
            }
            if (run != null)
            {
                lines.Add("Started " + When(run.StartedAt, now) + ".");
            }
            title = name + " went over budget";
        }
        else if (type == AlertType.UnderFloor && details is AlertDetails.UnderFloor u)
        {
            foreach (var b in u.Breaches)
            {
                lines.Add(b.Basis == "floor"
                    ? b.Metric + ": " + FormatNumber(b.Value) + ", below the floor of " + FormatNumber(b.Limit) + "."
                    : b.Metric + ": " + FormatNumber(b.Value) + " (" + b.Basis + ").");
            }
            if (run != null)
            {
                lines.Add("Started " + When(run.StartedAt, now) + ".");
            }
            title = name + " fell short";
        }
        else if (type == AlertType.Recovered && details is AlertDetails.Recovered r)
        {
            if (r.Reason == "unscheduled")
            {
                string missed = r.Since == null ? "" : "Missed since " + When(r.Since.Value, now) + ". ";
                lines.Add(missed + "It has no schedule now, so nothing is due; the missed alert is closed.");
                title = name + " is no longer scheduled";
            }
            else
            {
                var after = new List<string>();
                foreach (var c in r.After)
                {
                    string v = c.Value;
                    int us = v.IndexOf('_', StringComparison.Ordinal);
                    after.Add(us < 0 ? v : v[..us] + " " + v[(us + 1)..]);
                }
                string joined = AndList(after);
                string at = run == null ? "just now" : When(run.StartedAt, now);
                lines.Add("A run " + at + " succeeded" + (joined.Length == 0 ? "" : " after: " + joined) + ".");
                if (run?.DurationMs != null)
                {
                    lines.Add("Ran " + EvaluateDeps.FormatDuration(run.DurationMs.Value) + ".");
                }
                title = name + " recovered";
            }
        }
        return new Alert
        {
            Type = type,
            Run = run,
            Details = details,
            Job = name,
            Definition = def,
            Title = title,
            Message = string.Join("\n", lines),
            At = now,
        };
    }
}
