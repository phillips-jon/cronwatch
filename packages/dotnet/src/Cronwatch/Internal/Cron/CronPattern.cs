using System;
using System.Collections.Generic;
using System.Globalization;

namespace Cronwatch.Internal;

/// <summary>The fields of a pattern, by croner's names.</summary>
internal enum CronKind
{
    Second,
    Minute,
    Hour,
    Day,
    Month,
    DayOfWeek,
    Year,
    NearestWeekdays,
}

/// <summary>
/// Croner's CronPattern: the fields of an expression as tables of what matches, read with
/// croner's checks and its messages word for word.
/// </summary>
internal sealed class CronPattern
{
    // Croner's bits for "the nth weekday of the month"; 32 is the last one, 63 any.
    public static readonly int[] NthBits = [1, 2, 4, 8, 16];
    public const int LastBit = 32;
    public const int AnyBits = 63;

    private static readonly string[] MonthNames = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"];
    private static readonly string[] DayNames = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"];

    private static string Label(CronKind k) => k switch
    {
        CronKind.Second => "second",
        CronKind.Minute => "minute",
        CronKind.Hour => "hour",
        CronKind.Day => "day",
        CronKind.Month => "month",
        CronKind.DayOfWeek => "dayOfWeek",
        CronKind.Year => "year",
        _ => "nearestWeekdays",
    };

    private static int Size(CronKind k) => k switch
    {
        CronKind.Second or CronKind.Minute => 60,
        CronKind.Hour => 24,
        CronKind.Day or CronKind.NearestWeekdays => 31,
        CronKind.Month => 12,
        CronKind.DayOfWeek => 7,
        _ => 10_000,
    };

    /// <summary>
    /// What a field's table is set to: 1 (a match), croner's 63 for any nth weekday, or the text
    /// of a day-of-week modifier ("2" of "1#2", "L").
    /// </summary>
    private readonly record struct Val(int N, string? S)
    {
        public static Val Of(int n) => new(n, null);
    }

    private string _pattern;
    public readonly int[] SecondTable = new int[60];
    public readonly int[] MinuteTable = new int[60];
    public readonly int[] HourTable = new int[24];
    public readonly int[] DayTable = new int[31];
    public readonly int[] MonthTable = new int[12];
    public readonly int[] DayOfWeekTable = new int[7];
    public readonly int[] NearestWeekdaysTable = new int[31];

    // The years that match: every one ("*"), or the table croner keeps, made only when the field
    // names years.
    private bool _everyYear;
    private bool[]? _years;

    public bool LastDayOfMonth;
    public bool LastWeekday;
    public bool StarDom;
    public bool StarDow;
    public bool StarYear;
    public bool UseAndLogic;

    /// <summary>Reads an expression as croner's CronPattern does, or throws croner's message.</summary>
    public CronPattern(string text)
    {
        _pattern = text;
        Parse();
    }

    public int[] Table(CronKind k) => k switch
    {
        CronKind.Second => SecondTable,
        CronKind.Minute => MinuteTable,
        CronKind.Hour => HourTable,
        CronKind.Day => DayTable,
        CronKind.Month => MonthTable,
        CronKind.DayOfWeek => DayOfWeekTable,
        CronKind.NearestWeekdays => NearestWeekdaysTable,
        _ => [],
    };

    /// <summary>Croner's <c>year[y]</c>: whether year <paramref name="y"/> matches (none outside the table).</summary>
    public bool HasYear(long y)
    {
        if (y < 0 || y >= 10_000)
        {
            return false;
        }
        bool[]? t = _years;
        return _everyYear || (t != null && t[(int)y]);
    }

    private static CronException Fail(string message) => new(message);

    private static string Upper(string s) => s.ToUpperInvariant();

    private static string Num(long n) => n.ToString(CultureInfo.InvariantCulture);

    private void Parse()
    {
        if (_pattern.Contains('@', StringComparison.Ordinal))
        {
            _pattern = Js.Trim(Nicknames(_pattern));
        }
        var parts = new List<string>();
        int start = -1;
        for (int i = 0; i < _pattern.Length; i++)
        {
            if (Js.IsSpace(_pattern[i]))
            {
                if (start >= 0)
                {
                    parts.Add(_pattern[start..i]);
                    start = -1;
                }
            }
            else if (start < 0)
            {
                start = i;
            }
        }
        if (start >= 0)
        {
            parts.Add(_pattern[start..]);
        }
        if (parts.Count == 0)
        {
            parts.Add("");
        }
        if (parts.Count < 5 || parts.Count > 7)
        {
            throw Fail("CronPattern: invalid configuration format ('" + _pattern
                + "'), exactly five, six, or seven space separated parts are required.");
        }
        if (parts.Count == 5)
        {
            parts.Insert(0, "0");
        }
        if (parts.Count == 6)
        {
            parts.Add("*");
        }
        if (string.Equals(Upper(parts[3]), "LW", StringComparison.Ordinal))
        {
            LastWeekday = true;
            parts[3] = "";
        }
        else if (Upper(parts[3]).Contains('L', StringComparison.Ordinal))
        {
            parts[3] = ReplaceFold(parts[3], "l", "");
            LastDayOfMonth = true;
        }
        if (parts[3] == "*")
        {
            StarDom = true;
        }
        if (parts[6] == "*")
        {
            StarYear = true;
        }
        if (parts[4].Length >= 3)
        {
            for (int i = 0; i < MonthNames.Length; i++)
            {
                parts[4] = ReplaceFold(parts[4], MonthNames[i], Num(i + 1));
            }
        }
        if (parts[5].Length >= 3)
        {
            parts[5] = ReplaceFold(parts[5], "-sun", "-7");
            for (int i = 0; i < DayNames.Length; i++)
            {
                parts[5] = ReplaceFold(parts[5], DayNames[i], Num(i));
            }
        }
        if (parts[5].StartsWith('+'))
        {
            UseAndLogic = true;
            parts[5] = parts[5][1..];
            if (parts[5].Length == 0)
            {
                throw Fail("CronPattern: Day-of-week field cannot be empty after '+' modifier.");
            }
        }
        if (parts[5] == "*")
        {
            StarDow = true;
        }
        if (_pattern.Contains('?', StringComparison.Ordinal))
        {
            for (int i = 0; i < parts.Count; i++)
            {
                parts[i] = parts[i].Replace('?', '*');
            }
        }
        IllegalCharacters(parts);
        CronKind[] kinds = [CronKind.Second, CronKind.Minute, CronKind.Hour, CronKind.Day, CronKind.Month, CronKind.DayOfWeek, CronKind.Year];
        double[] offsets = [0, 0, 0, -1, -1, 0, 0];
        for (int i = 0; i < kinds.Length; i++)
        {
            Val v = kinds[i] == CronKind.DayOfWeek ? Val.Of(AnyBits) : Val.Of(1);
            Part(kinds[i], parts[i], offsets[i], v);
        }
    }

    private void Part(CronKind k, string text, double offset, Val v)
    {
        bool lastDom = k == CronKind.Day && LastDayOfMonth;
        bool lastWd = k == CronKind.Day && LastWeekday;
        if (text.Length == 0 && !lastDom && !lastWd)
        {
            throw Fail("CronPattern: configuration entry " + Label(k) + " (" + text + ") is empty, check for trailing spaces.");
        }
        if (text == "*")
        {
            if (k == CronKind.Year)
            {
                _everyYear = true;
                return;
            }
            Array.Fill(Table(k), v.N);
            return;
        }
        string[] items = text.Split(',');
        if (items.Length > 1)
        {
            foreach (string item in items)
            {
                Part(k, item, offset, v);
            }
        }
        else if (text.Contains('-', StringComparison.Ordinal) && text.Contains('/', StringComparison.Ordinal))
        {
            RangeWithStepping(text, k, offset, v);
        }
        else if (text.Contains('-', StringComparison.Ordinal))
        {
            RangeOf(text, k, offset, v);
        }
        else if (text.Contains('/', StringComparison.Ordinal))
        {
            Stepping(text, k, v);
        }
        else if (text.Length != 0)
        {
            Number(text, k, offset, v);
        }
    }

    private void Number(string text, CronKind k, double offset, Val v)
    {
        var (value, modifier) = ExtractNth(text, k);
        bool nearest = Upper(text).Contains('W', StringComparison.Ordinal);
        if (k != CronKind.Day && nearest)
        {
            throw Fail("CronPattern: Nearest weekday modifier (W) only allowed in day-of-month.");
        }
        CronKind kind = nearest ? CronKind.NearestWeekdays : k;
        double n = ParseInt(value);
        if (double.IsNaN(n))
        {
            throw Fail("CronPattern: " + Label(kind) + " is not a number: '" + text + "'");
        }
        Set(kind, n + offset, ModifierOr(modifier, v));
    }

    private void Set(CronKind k, double at0, Val v)
    {
        double at = at0;
        if (k == CronKind.DayOfWeek)
        {
            if (at == 7)
            {
                at = 0;
            }
            if (!(at >= 0 && at <= 6))
            {
                throw Fail("CronPattern: Invalid value for dayOfWeek: " + Js.FormatNumber(at));
            }
            NthWeekday((int)at, v);
            return;
        }
        if (k == CronKind.Year)
        {
            if (!(at >= 1 && at < 10_000))
            {
                throw Fail("CronPattern: Invalid value for " + Label(k) + ": " + Js.FormatNumber(at) + " (supported range: 1-9999)");
            }
            _years ??= new bool[10_000];
            _years[(int)at] = v.N != 0 || v.S != null;
            return;
        }
        if (!(at >= 0 && at < Size(k)))
        {
            throw Fail("CronPattern: Invalid value for " + Label(k) + ": " + Js.FormatNumber(at));
        }
        Table(k)[(int)at] = v.N;
    }

    private void RangeWithStepping(string text, CronKind k, double offset, Val v)
    {
        if (Upper(text).Contains('W', StringComparison.Ordinal))
        {
            throw Fail("CronPattern: Syntax error, W is not allowed in ranges with stepping.");
        }
        var (baseText, modifier) = ExtractNth(text, k);
        // /^(\d+)-(\d+)\/(\d+)$/
        string illegal = "CronPattern: Syntax error, illegal range with stepping: '" + text + "'";
        int slash = baseText.IndexOf('/', StringComparison.Ordinal);
        if (slash < 0)
        {
            throw Fail(illegal);
        }
        string range = baseText[..slash];
        string stepText = baseText[(slash + 1)..];
        int dash = range.IndexOf('-', StringComparison.Ordinal);
        if (dash < 0)
        {
            throw Fail(illegal);
        }
        string lowText = range[..dash];
        string highText = range[(dash + 1)..];
        if (!DigitsOnly(lowText) || !DigitsOnly(highText) || !DigitsOnly(stepText))
        {
            throw Fail(illegal);
        }
        double low = double.Parse(lowText, CultureInfo.InvariantCulture) + offset;
        double high = double.Parse(highText, CultureInfo.InvariantCulture) + offset;
        double step = double.Parse(stepText, CultureInfo.InvariantCulture);
        ValidateRange(low, high, step, Size(k), text);
        Val val = ModifierOr(modifier, v);
        for (double at = low; at <= high; at += step)
        {
            Set(k, at, val);
        }
    }

    private void RangeOf(string text, CronKind k, double offset, Val v)
    {
        if (Upper(text).Contains('W', StringComparison.Ordinal))
        {
            throw Fail("CronPattern: Syntax error, W is not allowed in a range.");
        }
        var (value, modifier) = ExtractNth(text, k);
        string[] bounds = value.Split('-');
        if (bounds.Length != 2)
        {
            throw Fail("CronPattern: Syntax error, illegal range: '" + text + "'");
        }
        double low = ParseInt(bounds[0]);
        double high = ParseInt(bounds[1]);
        if (double.IsNaN(low))
        {
            throw Fail("CronPattern: Syntax error, illegal lower range (NaN)");
        }
        if (double.IsNaN(high))
        {
            throw Fail("CronPattern: Syntax error, illegal upper range (NaN)");
        }
        low += offset;
        high += offset;
        ValidateRange(low, high, double.NaN, Size(k), text);
        Val val = ModifierOr(modifier, v);
        for (double at = low; at <= high; at += 1)
        {
            Set(k, at, val);
        }
    }

    private void Stepping(string text, CronKind k, Val v)
    {
        if (Upper(text).Contains('W', StringComparison.Ordinal))
        {
            throw Fail("CronPattern: Syntax error, W is not allowed in parts with stepping.");
        }
        var (value, modifier) = ExtractNth(text, k);
        string[] parts = value.Split('/');
        if (parts.Length != 2)
        {
            throw Fail("CronPattern: Syntax error, illegal stepping: '" + text + "'");
        }
        if (parts[0].Length == 0)
        {
            throw Fail("CronPattern: Syntax error, stepping with missing prefix ('" + text
                + "') is not allowed. Use wildcard (*/step) or range (min-max/step) instead.");
        }
        if (parts[0] != "*")
        {
            throw Fail("CronPattern: Syntax error, stepping with numeric prefix ('" + text
                + "') is not allowed. Use wildcard (*/step) or range (min-max/step) instead.");
        }
        double step = ParseInt(parts[1]);
        if (double.IsNaN(step))
        {
            throw Fail("CronPattern: Syntax error, illegal stepping: (NaN)");
        }
        int size = Size(k);
        ValidateRange(0, size - 1, step, size, text);
        if (step > 0)
        {
            Val val = ModifierOr(modifier, v);
            for (double at = 0; at < size; at += step)
            {
                Set(k, at, val);
            }
        }
    }

    private void NthWeekday(int d, Val nth)
    {
        string? s = nth.S;
        if (s != null)
        {
            if (Upper(s) == "L")
            {
                DayOfWeekTable[d] |= LastBit;
                return;
            }
        }
        else if (nth.N == AnyBits)
        {
            DayOfWeekTable[d] = AnyBits;
            return;
        }
        double n = s != null ? ToNumber(s) : nth.N;
        if (n < 6 && n > 0)
        {
            double index = n - 1;
            if (index == Math.Floor(index) && index >= 0 && index < NthBits.Length)
            {
                DayOfWeekTable[d] |= NthBits[(int)index];
            }
            return;
        }
        if (s != null)
        {
            throw Fail("CronPattern: nth weekday out of range, should be 1-5 or L. Value: " + s + ", Type: string");
        }
        throw Fail("CronPattern: nth weekday out of range, should be 1-5 or L. Value: " + Js.FormatNumber(n) + ", Type: number");
    }

    /// <summary>Croner's <c>nth[1] || value</c>: the modifier when there is one, else the field's value.</summary>
    private static Val ModifierOr(string? nth, Val v) => !string.IsNullOrEmpty(nth) ? new Val(0, nth) : v;

    private static string Nicknames(string pattern) => Js.Trim(pattern).ToLowerInvariant() switch
    {
        "@yearly" or "@annually" => "0 0 1 1 *",
        "@monthly" => "0 0 1 * *",
        "@weekly" => "0 0 * * 0",
        "@daily" or "@midnight" => "0 0 * * *",
        "@hourly" => "0 * * * *",
        "@reboot" => throw Fail("CronPattern: @reboot is not supported in this environment. This is an event-based"
            + " trigger that requires system startup detection."),
        _ => pattern,
    };

    /// <summary>
    /// Croner's check of each field's characters: digits, "/*,-" everywhere, W and L in the day of
    /// the month, # and L in the day of the week.
    /// </summary>
    private static void IllegalCharacters(List<string> parts)
    {
        for (int i = 0; i < parts.Count; i++)
        {
            string part = parts[i];
            string extra = i switch
            {
                3 => "WwLl",
                5 => "#Ll",
                _ => "",
            };
            foreach (char c in part)
            {
                if (!"/*0123456789,-".Contains(c, StringComparison.Ordinal) && !extra.Contains(c, StringComparison.Ordinal))
                {
                    throw Fail("CronPattern: configuration entry " + Num(i) + " (" + part + ") contains illegal characters.");
                }
            }
        }
    }

    /// <summary>Croner's range checks; <paramref name="step"/> is NaN for a range without one.</summary>
    private static void ValidateRange(double low, double high, double step, int size, string text)
    {
        if (low > high)
        {
            throw Fail("CronPattern: From value is larger than to value: '" + text + "'");
        }
        if (!double.IsNaN(step))
        {
            if (step == 0)
            {
                throw Fail("CronPattern: Syntax error, illegal stepping: 0");
            }
            if (step > size)
            {
                throw Fail("CronPattern: Syntax error, steps cannot be greater than maximum value of part (" + Num(size) + ")");
            }
        }
    }

    /// <summary>Whether <paramref name="s"/> is one or more ASCII digits.</summary>
    private static bool DigitsOnly(string s)
    {
        if (s.Length == 0)
        {
            return false;
        }
        foreach (char c in s)
        {
            if (c < '0' || c > '9')
            {
                return false;
            }
        }
        return true;
    }

    /// <summary>
    /// Splits a day-of-week modifier off: "1#2" is 1 and "2", "5L" is 5 and "L". Anywhere else a
    /// modifier is an error. The modifier is null when there is none.
    /// </summary>
    private static (string Value, string? Modifier) ExtractNth(string text, CronKind k)
    {
        int hash = text.IndexOf('#', StringComparison.Ordinal);
        if (hash >= 0)
        {
            if (k != CronKind.DayOfWeek)
            {
                throw Fail("CronPattern: nth (#) only allowed in day-of-week field");
            }
            int next = text.IndexOf('#', hash + 1);
            string second = next < 0 ? text[(hash + 1)..] : text[(hash + 1)..next];
            return (text[..hash], second);
        }
        if (Upper(text).EndsWith('L'))
        {
            if (k != CronKind.DayOfWeek)
            {
                throw Fail("CronPattern: L modifier only allowed in day-of-week field (use L alone for day-of-month)");
            }
            return (text[..^1], "L");
        }
        return (text, null);
    }

    /// <summary>
    /// Replaces every occurrence of an ASCII word, matched without regard to ASCII case (a
    /// JavaScript /gi regular expression without the u flag).
    /// </summary>
    private static string ReplaceFold(string text, string word, string with)
    {
        var b = new System.Text.StringBuilder(text.Length);
        int i = 0;
        while (i < text.Length)
        {
            if (AsciiFoldAt(text, i, word))
            {
                b.Append(with);
                i += word.Length;
                continue;
            }
            b.Append(text[i]);
            i++;
        }
        return b.ToString();
    }

    /// <summary>Whether <paramref name="word"/> (lowercase ASCII) is at <paramref name="i"/>, ASCII letters folded.</summary>
    private static bool AsciiFoldAt(string text, int i, string word)
    {
        if (i + word.Length > text.Length)
        {
            return false;
        }
        for (int j = 0; j < word.Length; j++)
        {
            char c = text[i + j];
            char w = word[j];
            if (c >= 'A' && c <= 'Z')
            {
                c = (char)(c + 32);
            }
            if (c != w)
            {
                return false;
            }
        }
        return true;
    }

    /// <summary><c>parseInt(text, 10)</c>: NaN when no digits lead.</summary>
    public static double ParseInt(string text)
    {
        int i = 0;
        int n = text.Length;
        while (i < n && Js.IsSpace(text[i]))
        {
            i++;
        }
        int start = i;
        if (i < n && (text[i] == '+' || text[i] == '-'))
        {
            i++;
        }
        int j = i;
        while (j < n && text[j] >= '0' && text[j] <= '9')
        {
            j++;
        }
        if (j == i)
        {
            return double.NaN;
        }
        return double.Parse(text.AsSpan(start, j - start), NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture);
    }

    /// <summary>JavaScript's <c>Number(text)</c> for the characters a field may hold: NaN when it is not one.</summary>
    public static double ToNumber(string text)
    {
        string s = Js.Trim(text);
        if (s.Length == 0)
        {
            return 0;
        }
        int i = 0;
        if (s[0] == '+' || s[0] == '-')
        {
            i++;
        }
        int digits = 0;
        int frac = 0;
        bool dot = false;
        while (i < s.Length)
        {
            char c = s[i];
            if (c >= '0' && c <= '9')
            {
                if (dot)
                {
                    frac++;
                }
                else
                {
                    digits++;
                }
            }
            else if (c == '.' && !dot)
            {
                dot = true;
            }
            else if ((c == 'e' || c == 'E') && digits + frac > 0)
            {
                int r = i + 1;
                if (r < s.Length && (s[r] == '+' || s[r] == '-'))
                {
                    r++;
                }
                if (r >= s.Length)
                {
                    return double.NaN;
                }
                for (int q = r; q < s.Length; q++)
                {
                    if (s[q] < '0' || s[q] > '9')
                    {
                        return double.NaN;
                    }
                }
                break;
            }
            else
            {
                return double.NaN;
            }
            i++;
        }
        if (digits + frac == 0)
        {
            return double.NaN;
        }
        return double.Parse(s, NumberStyles.Float, CultureInfo.InvariantCulture);
    }
}
