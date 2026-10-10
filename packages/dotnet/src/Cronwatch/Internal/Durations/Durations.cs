using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

namespace Cronwatch.Internal;

/// <summary>
/// The SDK's <c>duration.ts</c>: durations ("15m", "1h30m", a number of milliseconds) read and
/// written as the SDK does. Refusals are <see cref="ArgumentException"/>s with the SDK's message,
/// word for word; an empty label is "duration".
/// </summary>
internal static class Durations
{
    /// <summary>
    /// The longest duration text read, in characters (code points). No real duration comes near
    /// it, and the SDK's pattern is quadratic on a long run of digits, so a longer text is refused
    /// before it is read.
    /// </summary>
    public const int MaxLength = 64;

    /// <summary>How much of a refused, overlong text its error quotes.</summary>
    private const int Quoted = 32;

    private static string Label(string label) => label.Length == 0 ? "duration" : label;

    /// <summary>
    /// <c>parseDuration</c> over a JSON value, as a stored definition holds one: a string is read
    /// as text, a number as milliseconds, and anything else is refused, quoting it as
    /// <c>String()</c> would.
    /// </summary>
    public static double ParseValue(object? value, string label)
    {
        if (value is string s)
        {
            return Parse(s, label);
        }
        if (JsonText.TryNumber(value, out double n))
        {
            return Parse(n, label);
        }
        throw new ArgumentException(NotADuration(Label(label), JsString(value)));
    }

    /// <summary><c>String(value)</c> for a JSON value, as the SDK's message would quote it.</summary>
    private static string JsString(object? v)
    {
        switch (v)
        {
            case null:
                return "null";
            case bool b:
                return b ? "true" : "false";
            case string s:
                return s;
            case JsObject:
                return "[object Object]";
            case List<object?> list:
                {
                    var b = new StringBuilder();
                    for (int i = 0; i < list.Count; i++)
                    {
                        if (i > 0)
                        {
                            b.Append(',');
                        }
                        object? e = list[i];
                        if (e != null)
                        {
                            b.Append(JsString(e));
                        }
                    }
                    return b.ToString();
                }
            default:
                return JsonText.TryNumber(v, out double n) ? Js.FormatNumber(n) : Convert.ToString(v, CultureInfo.InvariantCulture) ?? "";
        }
    }

    /// <summary><c>parseDuration</c> of a number of milliseconds: any finite number from 0 up.</summary>
    public static double Parse(double ms, string label)
    {
        if (!double.IsFinite(ms) || ms < 0)
        {
            throw new ArgumentException(Label(label) + " must be a non-negative number of milliseconds");
        }
        return ms;
    }

    /// <summary>
    /// <c>parseDuration</c> of text: trimmed and lowercased, every
    /// <c>/(\d+(?:\.\d+)?)\s*(ms|s|m|h|d|w)/g</c> match summed, the whole refused unless the
    /// matches, spaces aside, are all of it, and the sum rounded as <c>Math.round</c> rounds.
    /// </summary>
    public static double Parse(string value, string label)
    {
        string name = Label(label);
        if (value.Length > MaxLength)
        {
            TooLong(value, name);
        }
        string text = Js.Trim(value).ToLowerInvariant();
        if (text.Length == 0)
        {
            throw new ArgumentException(name + " is empty");
        }
        double total = 0;
        var consumed = new StringBuilder();
        int i = 0;
        while (i < text.Length)
        {
            var m = MatchAt(text, i);
            if (m is not (double ms, int end))
            {
                // The global regular expression moves on one code unit.
                i++;
                continue;
            }
            total += ms;
            consumed.Append(text, i, end - i);
            i = end;
        }
        if (!string.Equals(StripSpaces(consumed.ToString()), StripSpaces(text), StringComparison.Ordinal))
        {
            throw new ArgumentException(NotADuration(name, value));
        }
        return Js.Round(total);
    }

    /// <summary>Tries <c>(\d+(?:\.\d+)?)\s*(ms|s|m|h|d|w)</c> at <paramref name="i"/>: its milliseconds and end, or null.</summary>
    private static (double Ms, int End)? MatchAt(string text, int i)
    {
        int n = text.Length;
        int j = i;
        while (j < n && IsDigit(text[j]))
        {
            j++;
        }
        if (j == i)
        {
            return null;
        }
        int end = j;
        if (j + 1 < n && text[j] == '.' && IsDigit(text[j + 1]))
        {
            end = j + 1;
            while (end < n && IsDigit(text[end]))
            {
                end++;
            }
        }
        int k = end;
        while (k < n && Js.IsSpace(text[k]))
        {
            k++;
        }
        double unit;
        int unitEnd;
        if (string.CompareOrdinal(text, k, "ms", 0, 2) == 0 && k + 2 <= n)
        {
            unit = 1;
            unitEnd = k + 2;
        }
        else if (k < n)
        {
            unit = text[k] switch
            {
                's' => 1000,
                'm' => 60_000,
                'h' => 3_600_000,
                'd' => 86_400_000,
                'w' => 604_800_000,
                _ => -1,
            };
            unitEnd = k + 1;
        }
        else
        {
            return null;
        }
        if (unit < 0)
        {
            return null;
        }
        return (double.Parse(text.AsSpan(i, end - i), NumberStyles.AllowDecimalPoint, CultureInfo.InvariantCulture) * unit, unitEnd);
    }

    private static bool IsDigit(char c) => c >= '0' && c <= '9';

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

    private static string NotADuration(string label, string value) =>
        label + " \"" + value + "\" is not a duration like \"15m\", \"1h30m\", or \"90s\"";

    /// <summary>Refuses a value over <see cref="MaxLength"/> characters, quoting its first <see cref="Quoted"/>.</summary>
    private static void TooLong(string value, string label)
    {
        int count = 0;
        int head = 0;
        for (int i = 0; i < value.Length; i += char.IsHighSurrogate(value[i]) && i + 1 < value.Length && char.IsLowSurrogate(value[i + 1]) ? 2 : 1)
        {
            if (count == Quoted)
            {
                head = i;
            }
            if (++count > MaxLength)
            {
                throw new ArgumentException(label + " \"" + value[..head] + "...\" is too long for a duration (more than "
                    + MaxLength.ToString(CultureInfo.InvariantCulture) + " characters)");
            }
        }
    }

    /// <summary><c>formatDuration</c>: 90000 is "1m 30s", at most two units; "?" when not finite.</summary>
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

    /// <summary><c>formatRelative</c>: "5m ago", "in 2h", or "now" within five seconds of <paramref name="now"/>.</summary>
    public static string FormatRelative(long at, long now)
    {
        long diff;
        try
        {
            diff = checked(at - now);
        }
        catch (OverflowException)
        {
            diff = at < now ? long.MinValue : long.MaxValue;
        }
        long abs = diff == long.MinValue ? long.MaxValue : Math.Abs(diff);
        if (abs < 5_000)
        {
            return "now";
        }
        string text = Format(abs);
        return diff < 0 ? text + " ago" : "in " + text;
    }
}
