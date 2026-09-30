using System;
using System.Globalization;
using System.Numerics;
using System.Security.Cryptography;
using System.Text;

namespace Cronwatch.Internal;

/// <summary>
/// What the dashboard's pages need to write values the way the SDK's templates do
/// (<c>routes/escape.ts</c> and JavaScript itself): <c>escapeHtml</c>, <c>escapeName</c>,
/// <c>String(value)</c>, <c>toFixed</c> and <c>encodeURIComponent</c>, how text read from the wire
/// is decoded, and how a secret is compared. Carried over from the Java port's
/// <c>internal/web/Text</c>.
/// </summary>
internal static class WebText
{
    private const string Hex = "0123456789ABCDEF";

    private static readonly UTF8Encoding StrictUtf8Encoding = new(false, true);

    /// <summary><c>escapeHtml</c>: <c>&amp; &lt; &gt; " '</c> escaped. Every string a page shows goes through it.</summary>
    public static string EscapeHtml(string s)
    {
        StringBuilder? output = null;
        for (int i = 0; i < s.Length; i++)
        {
            char c = s[i];
            string? rep = c switch
            {
                '&' => "&amp;",
                '<' => "&lt;",
                '>' => "&gt;",
                '"' => "&quot;",
                '\'' => "&#39;",
                _ => null,
            };
            if (rep == null)
            {
                output?.Append(c);
                continue;
            }
            if (output == null)
            {
                output = new StringBuilder(s.Length + 16);
                output.Append(s, 0, i);
            }
            output.Append(rep);
        }
        return output == null ? s : output.ToString();
    }

    /// <summary><c>escapeHtml(value ?? "")</c> for a JSON value: <c>String(value)</c>, null as nothing.</summary>
    public static string EscapeValue(object? v) => v == null ? "" : EscapeHtml(AlertFormat.JsText(v));

    private static bool IsSeparator(char c) => c is '_' or ':' or '.' or '/' or '-';

    /// <summary>
    /// <c>escapeName</c>: a job name shown as text, with <c>&lt;wbr&gt;</c> after each run of
    /// <c>_ : . / -</c> that something else follows, so a long name wraps at its separators. Only
    /// for text, never an attribute, a URL or a title.
    /// </summary>
    public static string EscapeName(string s)
    {
        string text = EscapeHtml(s);
        var output = new StringBuilder(text.Length + 16);
        int from = 0;
        for (int i = 0; i < text.Length; i++)
        {
            if (IsSeparator(text[i]) && i + 1 < text.Length && !IsSeparator(text[i + 1]))
            {
                output.Append(text, from, i + 1 - from).Append("<wbr>");
                from = i + 1;
            }
        }
        return output.Append(text, from, text.Length - from).ToString();
    }

    /// <summary><c>String(n)</c> for a number.</summary>
    public static string Num(double n) => Js.FormatNumber(n);

    /// <summary><c>String(n)</c> for a count.</summary>
    public static string Count(long n) => Js.FormatLong(n);

    /// <summary>
    /// <c>Number.prototype.toFixed</c>: the decimal nearest the exact value of the double, a half
    /// rounded away from zero, worked out from the double's exact binary value.
    /// </summary>
    public static string ToFixed(double x, int digits)
    {
        if (!double.IsFinite(x) || Math.Abs(x) >= 1e21)
        {
            return Js.FormatNumber(x);
        }
        digits = Math.Clamp(digits, 0, 100);
        long bits = BitConverter.DoubleToInt64Bits(Math.Abs(x));
        int exponent = (int)((bits >> 52) & 0x7FF);
        long mantissa = bits & 0xF_FFFF_FFFF_FFFFL;
        if (exponent == 0)
        {
            exponent = 1;
        }
        else
        {
            mantissa |= 1L << 52;
        }
        // |x| = mantissa * 2^(exponent - 1075); scaled = |x| * 10^digits, rounded half up.
        int shift = exponent - 1075;
        BigInteger scaled = new BigInteger(mantissa) * BigInteger.Pow(10, digits);
        if (shift >= 0)
        {
            scaled <<= shift;
        }
        else
        {
            BigInteger denominator = BigInteger.One << -shift;
            BigInteger quotient = BigInteger.DivRem(scaled, denominator, out BigInteger remainder);
            scaled = remainder * 2 >= denominator ? quotient + 1 : quotient;
        }
        string text = scaled.ToString(CultureInfo.InvariantCulture);
        if (digits > 0)
        {
            if (text.Length <= digits)
            {
                text = new string('0', digits - text.Length + 1) + text;
            }
            text = text[..^digits] + "." + text[^digits..];
        }
        return x < 0 ? "-" + text : text;
    }

    /// <summary><c>encodeURIComponent</c>, over the text's UTF-8 bytes.</summary>
    public static string EncodeUriComponent(string s)
    {
        var output = new StringBuilder(s.Length);
        foreach (byte b in Js.Utf8(s))
        {
            int c = b;
            if (IsAsciiAlphanumeric(c) || "-_.!~*'()".Contains((char)c, StringComparison.Ordinal))
            {
                output.Append((char)c);
            }
            else
            {
                output.Append('%').Append(Hex[c >> 4]).Append(Hex[c & 15]);
            }
        }
        return output.ToString();
    }

    /// <summary>Whether <paramref name="c"/> is an ASCII letter or digit.</summary>
    public static bool IsAsciiAlphanumeric(int c) => c is (>= '0' and <= '9') or (>= 'a' and <= 'z') or (>= 'A' and <= 'Z');

    /// <summary>
    /// Compares two secrets without stopping at the first character that differs, over their
    /// UTF-16 code units as the SDK compares them. Only a difference in length answers early, as
    /// the SDK's does.
    /// </summary>
    public static bool ConstantTimeEquals(string a, string b) =>
        CryptographicOperations.FixedTimeEquals(Units(a), Units(b));

    private static byte[] Units(string s)
    {
        byte[] output = new byte[s.Length * 2];
        for (int i = 0; i < s.Length; i++)
        {
            char c = s[i];
            output[2 * i] = (byte)(c >> 8);
            output[(2 * i) + 1] = (byte)c;
        }
        return output;
    }

    /// <summary>Whether every character of <paramref name="s"/> is one byte, as text read from the wire as Latin-1 is.</summary>
    public static bool IsLatin1(string s)
    {
        foreach (char c in s)
        {
            if (c > 0xff)
            {
                return false;
            }
        }
        return true;
    }

    /// <summary>The bytes of text read from the wire as Latin-1, one a character.</summary>
    public static byte[] Latin1Bytes(string s) => Encoding.Latin1.GetBytes(s);

    /// <summary>
    /// Text a server read as Latin-1 (each byte a character) as the UTF-8 it was sent in, with
    /// anything that is not UTF-8 as U+FFFD. Text that already holds a character past U+00FF was
    /// decoded by the server and is left as it is.
    /// </summary>
    public static string Utf8Lossy(string s) => IsLatin1(s) ? Encoding.UTF8.GetString(Latin1Bytes(s)) : s;

    /// <summary><see cref="Utf8Lossy"/>, but text whose bytes are not UTF-8 is left as it is rather than changed.</summary>
    public static string Utf8OrAsIs(string s)
    {
        if (!IsLatin1(s))
        {
            return s;
        }
        bool ascii = true;
        foreach (char c in s)
        {
            if (c >= 0x80)
            {
                ascii = false;
                break;
            }
        }
        return ascii ? s : StrictUtf8(Latin1Bytes(s)) ?? s;
    }

    /// <summary>Bytes as UTF-8, or null when they are not.</summary>
    public static string? StrictUtf8(byte[] bytes)
    {
        try
        {
            return StrictUtf8Encoding.GetString(bytes);
        }
        catch (DecoderFallbackException)
        {
            return null;
        }
    }

    /// <summary><c>s.replace(from, to)</c> for a string pattern: the first occurrence only.</summary>
    public static string ReplaceFirst(string s, string from, string to)
    {
        int i = s.IndexOf(from, StringComparison.Ordinal);
        return i < 0 ? s : string.Concat(s.AsSpan(0, i), to, s.AsSpan(i + from.Length));
    }
}
