using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

namespace Cronwatch.Internal;

/// <summary>
/// Origins read as the SDK's <c>new URL(value).origin</c> reads them, through
/// <see cref="WhatwgUrl"/>, the reader the channels' URLs go through, with its host step taught
/// to write a host outside ASCII in punycode (lowercased, labels encoded by RFC 3492) where the
/// channels refuse one: spaces and control characters around the value and tabs or line breaks in
/// it are dropped, slashes after the scheme may be missing or backslashes, credentials are
/// ignored, the host is lowercased (percent escapes decoded, IPv4 numbers written out, IPv6
/// compressed) and a default port is left out. Not <see cref="Uri"/> or
/// <see cref="IdnMapping"/>, which read hosts their own way, and never DNS.
/// </summary>
internal static class Origins
{
    /// <summary>
    /// The longest host outside ASCII read, in bytes. Punycode takes time in the label's length
    /// times its distinct characters, and a <c>Host</c> header is anyone's to send: a name no DNS
    /// could hold (253 bytes) is refused well past that bound.
    /// </summary>
    public const int MaxIdnHost = 1024;

    private const long Base = 36;
    private const long TMin = 1;
    private const long TMax = 26;
    private const long Skew = 38;
    private const long Damp = 700;

    /// <summary>
    /// The origin option as <c>scheme://host[:port]</c>, null for <c>""</c>, or the SDK's error for
    /// anything that is not an http or https URL, so a typo fails when the routes are made.
    /// </summary>
    /// <exception cref="ArgumentException">With the SDK's message.</exception>
    public static string? Configured(string? value)
    {
        if (string.IsNullOrEmpty(value))
        {
            return null;
        }
        var (kind, _, url) = WhatwgUrl.Parse(value, idn: true);
        if (kind == UrlKind.Invalid)
        {
            throw new ArgumentException(
                "routes: origin must be an absolute URL such as \"https://app.example.com\", got " + Json.Quote(value));
        }
        if (url is not { Scheme: "http" or "https" })
        {
            throw new ArgumentException("routes: origin must be http or https, got " + Json.Quote(value));
        }
        return url.Origin;
    }

    /// <summary>
    /// <c>scheme://host[:port]</c> for text that is an http or https URL whose path is <c>/</c>
    /// with no credentials, query or fragment, as the SDK's <c>forwardedOrigin</c> takes a
    /// forwarded host, or null.
    /// </summary>
    public static string? Bare(string value)
    {
        var (_, _, url) = WhatwgUrl.Parse(value, idn: true);
        if (url is not { Scheme: "http" or "https" } || url.HasCredentials || url.Path != "/"
            || !string.IsNullOrEmpty(url.Query) || !string.IsNullOrEmpty(url.Fragment))
        {
            return null;
        }
        return url.Origin;
    }

    /// <summary>RFC 3492's encoding of one label, without the <c>xn--</c>, or null past its limits.</summary>
    internal static string? Punycode(string label)
    {
        var runes = new List<int>();
        foreach (Rune rune in label.EnumerateRunes())
        {
            runes.Add(rune.Value);
        }
        var output = new StringBuilder();
        foreach (int r in runes)
        {
            if (r < 0x80)
            {
                output.Append((char)r);
            }
        }
        int basic = output.Length;
        int handled = basic;
        if (basic > 0)
        {
            output.Append('-');
        }
        long n = 128;
        long delta = 0;
        long bias = 72;
        while (handled < runes.Count)
        {
            long m = int.MaxValue;
            foreach (int r in runes)
            {
                if (r >= n && r < m)
                {
                    m = r;
                }
            }
            if ((m - n) * (handled + 1) > int.MaxValue - delta)
            {
                return null;
            }
            delta += (m - n) * (handled + 1);
            n = m;
            foreach (int r in runes)
            {
                if (r < n)
                {
                    delta++;
                }
                if (r == n)
                {
                    long q = delta;
                    for (long k = Base; ; k += Base)
                    {
                        long t = Math.Max(TMin, Math.Min(TMax, k - bias));
                        if (q < t)
                        {
                            break;
                        }
                        output.Append(Digit(t + ((q - t) % (Base - t))));
                        q = (q - t) / (Base - t);
                    }
                    output.Append(Digit(q));
                    bias = Adapt(delta, handled + 1, handled == basic);
                    delta = 0;
                    handled++;
                }
            }
            delta++;
            n++;
        }
        return output.ToString();
    }

    private static char Digit(long d) => d < 26 ? (char)('a' + d) : (char)('0' + (d - 26));

    private static long Adapt(long delta, long points, bool first)
    {
        long d = delta / (first ? Damp : 2);
        d += d / points;
        long k = 0;
        while (d > (Base - TMin) * TMax / 2)
        {
            d /= Base - TMin;
            k += Base;
        }
        return k + ((Base - TMin + 1) * d / (d + Skew));
    }

    /// <summary>
    /// The origin of a request's own URL: its scheme (https when it came over TLS) and
    /// <c>Host</c>, lowercased and without a default port. The host is read as UTF-8 from the
    /// bytes sent.
    /// </summary>
    public static string OfRequest(bool tls, string hostHeader)
    {
        string scheme = tls ? "https" : "http";
        string host = WebText.Utf8Lossy(hostHeader);
        return Bare(scheme + "://" + host) ?? scheme + "://" + host.ToLowerInvariant();
    }

    /// <summary>
    /// Whether an origin's host is loopback: <c>localhost</c>, a name ending in
    /// <c>.localhost</c>, an IPv4 address in 127.0.0.0/8, or the IPv6 address ::1. Only an origin
    /// that reads as one counts: a <c>Host</c> header is anyone's to send, and one such as
    /// <c>evil.example/.localhost</c> or <c>localhost:1@evil.example</c> must not put the
    /// development token in a link to another host.
    /// </summary>
    public static bool IsLoopback(string origin)
    {
        string? o = Bare(origin);
        if (o == null)
        {
            return false;
        }
        int sep = o.IndexOf("://", StringComparison.Ordinal);
        string authority = sep < 0 ? o : o[(sep + 3)..];
        string host;
        if (authority.StartsWith('['))
        {
            int end = authority.IndexOf(']', StringComparison.Ordinal);
            host = end < 0 ? authority : authority[..(end + 1)];
        }
        else
        {
            int c = authority.IndexOf(':', StringComparison.Ordinal);
            host = c < 0 ? authority : authority[..c];
        }
        host = host.ToLowerInvariant();
        if (host == "localhost" || host == "[::1]" || host.EndsWith(".localhost", StringComparison.Ordinal))
        {
            return true;
        }
        if (!host.StartsWith("127.", StringComparison.Ordinal))
        {
            return false;
        }
        string[] octets = host[4..].Split('.');
        if (octets.Length != 3)
        {
            return false;
        }
        foreach (string octet in octets)
        {
            if (octet.Length is 0 or > 3 || !IsDecimal(octet))
            {
                return false;
            }
            if (int.Parse(octet, NumberStyles.None, CultureInfo.InvariantCulture) > 255)
            {
                return false;
            }
        }
        return true;
    }

    private static bool IsDecimal(string s)
    {
        if (s.Length == 0)
        {
            return false;
        }
        foreach (char c in s)
        {
            if (c is < '0' or > '9')
            {
                return false;
            }
        }
        return true;
    }
}
