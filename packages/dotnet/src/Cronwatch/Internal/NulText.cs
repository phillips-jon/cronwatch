using System;
using System.Text;

namespace Cronwatch.Internal;

/// <summary>
/// Text without U+0000, which Postgres refuses, as every store writes it (the SDK's
/// <c>stripNul</c> and <c>stripJsonNul</c>).
/// </summary>
internal static class NulText
{
    /// <summary>Removes every U+0000.</summary>
    public static string StripNul(string text) =>
        text.Contains('\0', StringComparison.Ordinal) ? text.Replace("\0", "", StringComparison.Ordinal) : text;

    /// <summary><see cref="StripNul"/>, keeping null.</summary>
    public static string? StripNulOrNull(string? text) => text == null ? null : StripNul(text);

    /// <summary>
    /// Removes every U+0000 from JSON text, keys and strings alike, by dropping each
    /// <c>\u0000</c> escape. Escapes are read left to right in pairs, so an escaped backslash
    /// followed by <c>u0000</c> is left as it is.
    /// </summary>
    public static string StripJsonNul(string json)
    {
        if (!json.Contains("\\u0000", StringComparison.Ordinal))
        {
            return json;
        }
        var b = new StringBuilder(json.Length);
        int i = 0;
        while (i < json.Length)
        {
            char c = json[i];
            if (c == '\\' && i + 1 < json.Length)
            {
                if (string.CompareOrdinal(json, i + 1, "u0000", 0, 5) == 0)
                {
                    i += 6;
                    continue;
                }
                b.Append(c).Append(json[i + 1]);
                i += 2;
                continue;
            }
            b.Append(c);
            i++;
        }
        return b.ToString();
    }
}
