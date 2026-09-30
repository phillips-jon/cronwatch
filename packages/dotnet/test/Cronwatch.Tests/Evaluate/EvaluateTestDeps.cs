using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;
using Cronwatch.Internal;

namespace Cronwatch.Tests;

/// <summary>
/// A stand-in for the duration and schedule code, bound into <see cref="EvaluateDeps"/> until the
/// port's own <c>Durations</c> and <c>Schedules</c> are: durations as <c>duration.ts</c> reads and
/// writes them, and interval schedules (<c>every 1h</c>) alone. A cron schedule throws
/// <see cref="CronNotBoundException"/>, and the replays skip what needs one.
/// </summary>
internal static class EvaluateTestDeps
{
    /// <summary>A cron schedule, which only the croner port can read.</summary>
    internal sealed class CronNotBoundException : Exception
    {
        public CronNotBoundException(string schedule)
            : base("cron schedules wait for the croner port: " + schedule)
        {
        }
    }

    private sealed record Interval(double EveryMs);

    private static readonly object Gate = new();
    private static bool _bound;

    /// <summary>Binds the stand-ins, once.</summary>
    public static void Bind()
    {
        lock (Gate)
        {
            if (_bound)
            {
                return;
            }
            EvaluateDeps.ParseDurationImpl ??= ParseValue;
            EvaluateDeps.FormatDurationImpl ??= Format;
            EvaluateDeps.ParseScheduleImpl ??= ParseSchedule;
            EvaluateDeps.IsIntervalImpl ??= p => p is Interval;
            EvaluateDeps.ExpectationImpl ??= (p, lastRunAt, createdAt, grace) =>
            {
                double due = (lastRunAt ?? createdAt) + ((Interval)p).EveryMs;
                return ((long)due, due + grace);
            };
            EvaluateDeps.NextFireImpl ??= (p, from, lastRunAt) => (long)((lastRunAt ?? from) + ((Interval)p).EveryMs);
            _bound = true;
        }
    }

    private static object ParseSchedule(string schedule, string? zone)
    {
        string text = Js.Trim(schedule);
        if (text.Length > 6 && string.Compare(text, 0, "every", 0, 5, StringComparison.OrdinalIgnoreCase) == 0 && Js.IsSpace(text[5]))
        {
            double every = Parse(Js.Trim(text[5..]), "schedule interval");
            if (every < 1000)
            {
                throw new ArgumentException("schedule \"" + schedule + "\" is shorter than one second");
            }
            return new Interval(every);
        }
        throw new CronNotBoundException(schedule);
    }

    private static string JsString(object? v) => v switch
    {
        null => "null",
        List<object?> list => string.Join(",", list.ConvertAll(e => e == null ? "" : JsString(e))),
        _ => AlertFormat.JsText(v),
    };

    public static double ParseValue(object? value, string label)
    {
        if (value is string s)
        {
            return Parse(s, label);
        }
        if (Json.TryNumber(value, out double n))
        {
            if (!double.IsFinite(n) || n < 0)
            {
                throw new ArgumentException(label + " must be a non-negative number of milliseconds");
            }
            return n;
        }
        throw new ArgumentException(NotADuration(label, JsString(value)));
    }

    private static string NotADuration(string label, string value) =>
        label + " \"" + value + "\" is not a duration like \"15m\", \"1h30m\" or \"90s\"";

    public static double Parse(string value, string label)
    {
        if (value.Length > 64)
        {
            int count = 0;
            int head = 0;
            for (int i = 0; i < value.Length; i += char.IsSurrogatePair(value, i) ? 2 : 1)
            {
                if (count == 32)
                {
                    head = i;
                }
                if (++count > 64)
                {
                    throw new ArgumentException(label + " \"" + value[..head] + "...\" is too long for a duration (more than 64 characters)");
                }
            }
        }
        string text = Js.Trim(value).ToLowerInvariant();
        if (text.Length == 0)
        {
            throw new ArgumentException(label + " is empty");
        }
        double total = 0;
        var consumed = new StringBuilder();
        int at = 0;
        while (at < text.Length)
        {
            int j = at;
            while (j < text.Length && char.IsAsciiDigit(text[j]))
            {
                j++;
            }
            if (j == at)
            {
                at++;
                continue;
            }
            int end = j;
            if (j + 1 < text.Length && text[j] == '.' && char.IsAsciiDigit(text[j + 1]))
            {
                end = j + 1;
                while (end < text.Length && char.IsAsciiDigit(text[end]))
                {
                    end++;
                }
            }
            int k = end;
            while (k < text.Length && Js.IsSpace(text[k]))
            {
                k++;
            }
            double unit = -1;
            int unitEnd = k + 1;
            if (k + 1 < text.Length && text[k] == 'm' && text[k + 1] == 's')
            {
                unit = 1;
                unitEnd = k + 2;
            }
            else if (k < text.Length)
            {
                unit = text[k] switch { 's' => 1000, 'm' => 60_000, 'h' => 3_600_000, 'd' => 86_400_000, 'w' => 604_800_000, _ => -1 };
            }
            if (unit < 0)
            {
                at++;
                continue;
            }
            total += double.Parse(text[at..end], CultureInfo.InvariantCulture) * unit;
            consumed.Append(text, at, unitEnd - at);
            at = unitEnd;
        }
        if (StripSpaces(consumed.ToString()) != StripSpaces(text))
        {
            throw new ArgumentException(NotADuration(label, value));
        }
        return Js.Round(total);
    }

    private static string StripSpaces(string s)
    {
        var b = new StringBuilder(s.Length);
        foreach (char c in s)
        {
            if (!Js.IsSpace(c))
            {
                b.Append(c);
            }
        }
        return b.ToString();
    }

    public static string Format(double ms)
    {
        if (!double.IsFinite(ms))
        {
            return "?";
        }
        if (ms < 1000)
        {
            return Js.FormatNumber(Js.Round(ms)) + "ms";
        }
        var b = new StringBuilder();
        int parts = 0;
        double rest = Js.Round(ms / 1000);
        string[] units = ["d", "h", "m", "s"];
        double[] sizes = [86_400, 3_600, 60, 1];
        for (int u = 0; u < units.Length; u++)
        {
            if (rest >= sizes[u])
            {
                double n = Math.Floor(rest / sizes[u]);
                rest -= n * sizes[u];
                if (parts > 0)
                {
                    b.Append(' ');
                }
                b.Append(Js.FormatNumber(n)).Append(units[u]);
                parts++;
            }
            if (parts == 2)
            {
                break;
            }
        }
        return parts == 0 ? "0s" : b.ToString();
    }
}
