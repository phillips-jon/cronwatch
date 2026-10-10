using System;
using System.Globalization;
using System.Text;

namespace Cronwatch.Internal;

/// <summary>
/// What the port needs of JavaScript's own behaviour, so that every value the SDK writes,
/// compares, or counts is written, compared, and counted the same way here: numbers as
/// <c>Number.prototype.toString</c> prints them, the characters <c>\s</c> matches and
/// <c>trim</c> removes, <c>Date</c>'s calendar arithmetic and <c>toISOString</c>, and strings
/// written out as UTF-8 with a lone surrogate as U+FFFD.
/// </summary>
/// <remarks>
/// .NET strings are UTF-16, as JavaScript's are, so <c>Length</c>, <c>Substring</c>, and the
/// indexer count and cut as the SDK does.
/// </remarks>
internal static class Js
{
    /// <summary>2^53 - 1, the largest integer JavaScript holds exactly.</summary>
    public const long MaxSafeInteger = 9_007_199_254_740_991L;

    /// <summary>The first millisecond written as a date: 0001-01-01T00:00:00.000Z.</summary>
    public const long FirstDateMs = -62_135_596_800_000L;

    /// <summary>The last millisecond written as a date: 9999-12-31T23:59:59.999Z.</summary>
    public const long LastDateMs = 253_402_300_799_999L;

    // ---- numbers

    /// <summary>
    /// <c>String(n)</c>: the shortest digits that read back as <paramref name="n"/>, in plain
    /// notation from 1e-7 up to 1e21 and exponential notation outside it, as
    /// <c>Number.prototype.toString</c> writes them. The digits come from
    /// <c>double.ToString("R")</c>, the shortest round trip since .NET Core 3.0, laid out again,
    /// since .NET writes <c>1E+21</c> and <c>1E-07</c>.
    /// </summary>
    public static string FormatNumber(double n)
    {
        if (double.IsNaN(n))
        {
            return "NaN";
        }
        if (double.IsInfinity(n))
        {
            return n > 0 ? "Infinity" : "-Infinity";
        }
        if (n == 0)
        {
            return "0";
        }
        var (digits, point) = Shortest(Math.Abs(n));
        int k = digits.Length;
        var b = new StringBuilder(n < 0 ? "-" : "");
        if (k <= point && point <= 21)
        {
            b.Append(digits);
            b.Append('0', point - k);
        }
        else if (0 < point && point <= 21)
        {
            b.Append(digits, 0, point).Append('.').Append(digits, point, k - point);
        }
        else if (-6 < point && point <= 0)
        {
            b.Append("0.").Append('0', -point).Append(digits);
        }
        else
        {
            b.Append(digits[0]);
            if (k > 1)
            {
                b.Append('.').Append(digits, 1, k - 1);
            }
            b.Append('e');
            if (point >= 1)
            {
                b.Append('+');
            }
            b.Append((point - 1).ToString(CultureInfo.InvariantCulture));
        }
        return b.ToString();
    }

    /// <summary>
    /// The shortest decimal digits that read back as <paramref name="x"/> (positive and finite),
    /// without leading or trailing zeros, and ECMAScript's <c>n</c>: the value is
    /// <c>0.d1...dk * 10^point</c>.
    /// </summary>
    public static (string Digits, int Point) Shortest(double x)
    {
        string s = x.ToString("R", CultureInfo.InvariantCulture);
        int e = s.IndexOfAny(['E', 'e']);
        string mantissa = e >= 0 ? s[..e] : s;
        int exp = e >= 0 ? int.Parse(s[(e + 1)..], NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture) : 0;
        int dot = mantissa.IndexOf('.', StringComparison.Ordinal);
        string intPart = dot >= 0 ? mantissa[..dot] : mantissa;
        string frac = dot >= 0 ? mantissa[(dot + 1)..] : "";
        string all = intPart + frac;
        int point = intPart.Length + exp;
        int lead = 0;
        while (lead < all.Length - 1 && all[lead] == '0')
        {
            lead++;
        }
        all = all[lead..];
        point -= lead;
        int end = all.Length;
        while (end > 1 && all[end - 1] == '0')
        {
            end--;
        }
        return (all[..end], point);
    }

    /// <summary>
    /// A <c>long</c> as JavaScript prints the number it would hold: its digits within 2^53, else
    /// the double nearest to it.
    /// </summary>
    public static string FormatLong(long n)
    {
        if (n <= MaxSafeInteger && n >= -MaxSafeInteger)
        {
            return n.ToString(CultureInfo.InvariantCulture);
        }
        return FormatNumber(n);
    }

    /// <summary><c>Number.isInteger</c>.</summary>
    public static bool IsInteger(double n) => double.IsFinite(n) && n == Math.Round(n);

    /// <summary>
    /// A JavaScript number as a <c>long</c>, as the ports hold times: truncated, NaN as 0, and
    /// held at the ends of the range.
    /// </summary>
    public static long ToLong(double n)
    {
        if (double.IsNaN(n))
        {
            return 0;
        }
        if (n >= 9.2233720368547758E18)
        {
            return long.MaxValue;
        }
        if (n <= -9.2233720368547758E18)
        {
            return long.MinValue;
        }
        return (long)n;
    }

    /// <summary><c>Math.round</c>: halves round up, toward positive infinity.</summary>
    public static double Round(double n)
    {
        if (!double.IsFinite(n))
        {
            return n;
        }
        double f = Math.Floor(n);
        return n - f >= 0.5 ? f + 1 : f;
    }

    // ---- text

    /// <summary>
    /// Whether JavaScript's <c>\s</c> matches <paramref name="c"/>: WhiteSpace and
    /// LineTerminator, which is also what <c>String.prototype.trim</c> removes.
    /// </summary>
    public static bool IsSpace(char c) => c switch
    {
        (char)0x09 or (char)0x0a or (char)0x0b or (char)0x0c or (char)0x0d or (char)0x20
            or (char)0xa0 or (char)0x1680 or (char)0x2028 or (char)0x2029 or (char)0x202f
            or (char)0x205f or (char)0x3000 or (char)0xfeff => true,
        _ => c >= (char)0x2000 && c <= (char)0x200a,
    };

    /// <summary><c>String.prototype.trim</c>.</summary>
    public static string Trim(string s)
    {
        int start = 0;
        int end = s.Length;
        while (start < end && IsSpace(s[start]))
        {
            start++;
        }
        while (end > start && IsSpace(s[end - 1]))
        {
            end--;
        }
        return s.Substring(start, end - start);
    }

    /// <summary>
    /// Whether a token or secret counts as unset: null, empty, or only what
    /// <c>String.prototype.trim</c> removes (not .NET's <c>Trim</c>, which takes U+0085 and leaves
    /// U+FEFF). A value that is not blank is used as given, untrimmed.
    /// </summary>
    public static bool IsBlank(string? s)
    {
        if (s == null)
        {
            return true;
        }
        foreach (char c in s)
        {
            if (!IsSpace(c))
            {
                return false;
            }
        }
        return true;
    }

    /// <summary>A token or secret as given, or null when it is blank (<see cref="IsBlank"/>).</summary>
    public static string? Secret(string? s) => IsBlank(s) ? null : s;

    /// <summary><c>String.prototype.trimEnd</c>.</summary>
    public static string TrimEnd(string s)
    {
        int end = s.Length;
        while (end > 0 && IsSpace(s[end - 1]))
        {
            end--;
        }
        return s[..end];
    }

    /// <summary>
    /// <c>s.slice(start, end)</c>, with JavaScript's clamping (a negative index counts from the
    /// end).
    /// </summary>
    public static string Slice(string s, long start, long end)
    {
        long n = s.Length;
        long a = start < 0 ? Math.Max(start + n, 0) : Math.Min(start, n);
        long z = end < 0 ? Math.Max(end + n, 0) : Math.Min(end, n);
        return a >= z ? "" : s.Substring((int)a, (int)(z - a));
    }

    /// <summary><c>s.slice(-n)</c>: the last <paramref name="n"/> code units.</summary>
    public static string Tail(string s, int n) => s.Length <= n ? s : s[^n..];

    /// <summary><c>s.slice(0, n)</c>.</summary>
    public static string Head(string s, int n) => s.Length <= n ? s : s[..n];

    /// <summary>
    /// The string as UTF-8 bytes, as JavaScript writes a string out: a lone surrogate becomes
    /// U+FFFD, which <c>Encoding.UTF8</c> does.
    /// </summary>
    public static byte[] Utf8(string s) => Encoding.UTF8.GetBytes(s);

    /// <summary>
    /// The string as JavaScript would read it back once written out: each lone surrogate as
    /// U+FFFD.
    /// </summary>
    public static string WellFormed(string s)
    {
        for (int i = 0; i < s.Length; i++)
        {
            if (char.IsSurrogate(s[i]))
            {
                return Encoding.UTF8.GetString(Encoding.UTF8.GetBytes(s));
            }
        }
        return s;
    }

    /// <summary>Whether the string holds a lone surrogate.</summary>
    public static bool HasLoneSurrogate(string s)
    {
        for (int i = 0; i < s.Length; i++)
        {
            char c = s[i];
            if (char.IsHighSurrogate(c) && i + 1 < s.Length && char.IsLowSurrogate(s[i + 1]))
            {
                i++;
                continue;
            }
            if (char.IsSurrogate(c))
            {
                return true;
            }
        }
        return false;
    }

    /// <summary><c>n % m</c> for a floor division.</summary>
    public static long FloorMod(long n, long m)
    {
        long r = n % m;
        return r != 0 && (r < 0) != (m < 0) ? r + m : r;
    }

    /// <summary>A floor division.</summary>
    public static long FloorDiv(long n, long m)
    {
        long q = n / m;
        return (n % m != 0) && ((n < 0) != (m < 0)) ? q - 1 : q;
    }

    // ---- dates

    /// <summary>The days since 1970-01-01 of a proleptic Gregorian date, month 1 to 12.</summary>
    public static long DaysFromCivil(long y, long m, long d)
    {
        long yy = m <= 2 ? y - 1 : y;
        long era = FloorDiv(yy, 400);
        long yoe = yy - era * 400;
        long mp = (m + 9) % 12;
        long doy = (153 * mp + 2) / 5 + d - 1;
        long doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        return era * 146_097 + doe - 719_468;
    }

    /// <summary>The date of a day counted from 1970-01-01: year, month (1 to 12), and day.</summary>
    public static (long Year, long Month, long Day) CivilFromDays(long z0)
    {
        long z = z0 + 719_468;
        long era = FloorDiv(z, 146_097);
        long doe = z - era * 146_097;
        long yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
        long y = yoe + era * 400;
        long doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        long mp = (5 * doy + 2) / 153;
        long d = doy - (153 * mp + 2) / 5 + 1;
        long m = mp + 3;
        if (m > 12)
        {
            m -= 12;
        }
        if (m <= 2)
        {
            y += 1;
        }
        return (y, m, d);
    }

    /// <summary>
    /// <c>Date.UTC(year, month, day, hour, minute, second, ms)</c> with a 0-based month, every
    /// field free to overflow into the next, as <c>Date.UTC</c> allows.
    /// </summary>
    public static long DateUtc(long year, long month, long day, long hour, long minute, long second, long ms)
    {
        long y = year + FloorDiv(month, 12);
        long mo = FloorMod(month, 12);
        long days = DaysFromCivil(y, mo + 1, 1) + day - 1;
        return days * 86_400_000L + hour * 3_600_000L + minute * 60_000L + second * 1000L + ms;
    }

    /// <summary>
    /// <c>new Date(ms).toISOString()</c>: <c>"2026-01-05T09:30:00.000Z"</c>, with a signed
    /// six-digit year outside 0 to 9999.
    /// </summary>
    public static string IsoString(long ms)
    {
        long days = FloorDiv(ms, 86_400_000L);
        long rest = FloorMod(ms, 86_400_000L);
        var (y, m, d) = CivilFromDays(days);
        string year = y < 0 ? "-" + Pad(-y, 6) : y > 9999 ? "+" + Pad(y, 6) : Pad(y, 4);
        return year + "-" + Pad(m, 2) + "-" + Pad(d, 2) + "T" + Pad(rest / 3_600_000L, 2) + ":"
            + Pad(rest / 60_000L % 60, 2) + ":" + Pad(rest / 1000L % 60, 2) + "." + Pad(rest % 1000L, 3) + "Z";
    }

    /// <summary>The number with leading zeros to <paramref name="width"/> digits.</summary>
    public static string Pad(long n, int width)
    {
        string s = n.ToString(CultureInfo.InvariantCulture);
        return s.Length >= width ? s : new string('0', width - s.Length) + s;
    }

    /// <summary>Whether <paramref name="ms"/> falls in the years 1 to 9999, the times written as dates.</summary>
    public static bool InDateRange(long ms) => ms >= FirstDateMs && ms <= LastDateMs;

    /// <summary>
    /// <c>"2026-01-05T09:30:00.000Z"</c>, or null for a time before the year 1 or after 9999,
    /// such as a start read from a foreign or damaged row (the SDK's <c>isoTime</c>).
    /// </summary>
    public static string? IsoTime(long ms) => InDateRange(ms) ? IsoString(ms) : null;

    /// <summary>The words that stand in for a time <see cref="IsoTime"/> does not write (the SDK's <c>beyondDates</c>).</summary>
    public static string BeyondDates(long ms) =>
        ms > LastDateMs ? "after 9999-12-31 23:59:59 UTC" : "before 0001-01-01 00:00:00 UTC";

    /// <summary><see cref="IsoTime"/>, or the words for a time outside its years.</summary>
    public static string IsoOrWords(long ms) => IsoTime(ms) ?? BeyondDates(ms);
}
