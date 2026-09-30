using System;
using System.Collections.Generic;
using System.Globalization;
using System.Numerics;
using System.Text;

namespace Cronwatch.Internal;

/// <summary>
/// Origins read as the SDK's <c>new URL(value).origin</c> reads them, carried over from the Java
/// port's <c>internal/web/Origins</c> (the Go port's <c>routes_origin.go</c> through the Rust
/// port's <c>web/origin.rs</c>): spaces and control characters around the value and tabs or line
/// breaks in it are dropped, slashes after the scheme may be missing or backslashes, credentials
/// are ignored, the host is lowercased (percent escapes decoded, IPv4 numbers written out, IPv6
/// compressed, a host outside ASCII written in punycode) and a default port is left out. Not
/// <see cref="Uri"/> or <see cref="IdnMapping"/>, which read hosts their own way, and never DNS.
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

    /// <summary>Why a value is not an origin.</summary>
    private sealed class NotOriginException(bool notHttp) : Exception
    {
        public bool NotHttp { get; } = notHttp;
    }

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
        try
        {
            return Read(value).Origin;
        }
        catch (NotOriginException e)
        {
            if (e.NotHttp)
            {
                throw new ArgumentException("routes: origin must be http or https, got " + Json.Quote(value));
            }
            throw new ArgumentException(
                "routes: origin must be an absolute URL such as \"https://app.example.com\", got " + Json.Quote(value));
        }
    }

    /// <summary>
    /// <c>scheme://host[:port]</c> for text that is a scheme and a bare host, or null when it
    /// carries a path, credentials, a query or a fragment, or is not an http or https URL.
    /// </summary>
    public static string? Bare(string value)
    {
        try
        {
            var (origin, extra) = Read(value);
            return extra ? null : origin;
        }
        catch (NotOriginException)
        {
            return null;
        }
    }

    private static bool IsSchemeChar(char c) => WebText.IsAsciiAlphanumeric(c) || c is '+' or '.' or '-';

    private static (string Origin, bool Extra) Read(string value)
    {
        int start = 0;
        int end = value.Length;
        while (start < end && value[start] <= ' ')
        {
            start++;
        }
        while (end > start && value[end - 1] <= ' ')
        {
            end--;
        }
        var t = new StringBuilder(end - start);
        for (int i = start; i < end; i++)
        {
            char c = value[i];
            if (c is not ('\t' or '\n' or '\r'))
            {
                t.Append(c);
            }
        }
        string text = t.ToString();
        int colon = text.IndexOf(':', StringComparison.Ordinal);
        if (colon <= 0)
        {
            throw new NotOriginException(false);
        }
        string scheme = text[..colon];
        char first = scheme[0];
        if (!(first is (>= 'a' and <= 'z') or (>= 'A' and <= 'Z')))
        {
            throw new NotOriginException(false);
        }
        foreach (char c in scheme)
        {
            if (!IsSchemeChar(c))
            {
                throw new NotOriginException(false);
            }
        }
        scheme = scheme.ToLowerInvariant();
        int defaultPort = scheme switch
        {
            "http" => 80,
            "https" => 443,
            _ => throw new NotOriginException(true),
        };
        int r = colon + 1;
        while (r < text.Length && text[r] is '/' or '\\')
        {
            r++;
        }
        string rest = text[r..];
        int stop = rest.Length;
        for (int i = 0; i < rest.Length; i++)
        {
            if (rest[i] is '/' or '\\' or '?' or '#')
            {
                stop = i;
                break;
            }
        }
        string authority = rest[..stop];
        string after = rest[stop..];
        int at = authority.LastIndexOf('@');
        string userinfo = at < 0 ? "" : authority[..at];
        string hostport = at < 0 ? authority : authority[(at + 1)..];
        var (hostText, port) = SplitPort(hostport);
        string host = ReadHost(hostText);
        string shown = port != null && port.Value != defaultPort ? ":" + port.Value.ToString(CultureInfo.InvariantCulture) : "";
        bool extra = (at >= 0 && userinfo.Length != 0 && userinfo != ":") || PastHost(after);
        return (scheme + "://" + host + shown, extra);
    }

    private static bool PastHost(string after)
    {
        string path = after;
        string? fragment = null;
        int hash = after.IndexOf('#', StringComparison.Ordinal);
        if (hash >= 0)
        {
            path = after[..hash];
            fragment = after[(hash + 1)..];
        }
        string query = "";
        int q = path.IndexOf('?', StringComparison.Ordinal);
        if (q >= 0)
        {
            query = path[(q + 1)..];
            path = path[..q];
        }
        return (path.Length != 0 && path != "/" && path != "\\") || query.Length != 0 || !string.IsNullOrEmpty(fragment);
    }

    /// <summary>The host and the port (null for none).</summary>
    private static (string Host, int? Port) SplitPort(string authority)
    {
        string host;
        string rest;
        if (authority.StartsWith('['))
        {
            int end = authority.IndexOf(']', StringComparison.Ordinal);
            if (end < 0)
            {
                throw new NotOriginException(false);
            }
            host = authority[..(end + 1)];
            rest = authority[(end + 1)..];
        }
        else
        {
            int i = authority.LastIndexOf(':');
            host = i < 0 ? authority : authority[..i];
            rest = i < 0 ? "" : authority[i..];
        }
        if (rest.Length == 0 || rest == ":")
        {
            return (host, null);
        }
        if (rest[0] != ':')
        {
            throw new NotOriginException(false);
        }
        string digits = rest[1..];
        foreach (char c in digits)
        {
            if (c is < '0' or > '9')
            {
                throw new NotOriginException(false);
            }
        }
        digits = digits.TrimStart('0');
        if (digits.Length > 5)
        {
            throw new NotOriginException(false);
        }
        int port = digits.Length == 0 ? 0 : int.Parse(digits, NumberStyles.None, CultureInfo.InvariantCulture);
        if (port > 65535)
        {
            throw new NotOriginException(false);
        }
        return (host, port);
    }

    private static bool ForbiddenHostChar(char c) => c <= ' ' || c == 0x7f || "#%/:<>?@[\\]^|".Contains(c, StringComparison.Ordinal);

    private static string ReadHost(string host)
    {
        if (host.Length == 0)
        {
            throw new NotOriginException(false);
        }
        if (host.StartsWith('['))
        {
            if (!host.EndsWith(']') || host.Length < 2)
            {
                throw new NotOriginException(false);
            }
            string inner = host[1..^1];
            if (inner.Contains('%', StringComparison.Ordinal))
            {
                throw new NotOriginException(false);
            }
            int[] groups = ParseIpv6(inner) ?? throw new NotOriginException(false);
            return "[" + Ipv6Text(groups) + "]";
        }
        string decoded = WebText.StrictUtf8(Requests.PercentDecode(Js.Utf8(host))) ?? throw new NotOriginException(false);
        decoded = decoded.ToLowerInvariant();
        if (!IsAscii(decoded))
        {
            if (Encoding.UTF8.GetByteCount(decoded) > MaxIdnHost)
            {
                throw new NotOriginException(false);
            }
            var labels = new List<string>();
            foreach (string label in decoded.Split('.'))
            {
                if (IsAscii(label))
                {
                    labels.Add(label);
                }
                else
                {
                    string code = Punycode(label) ?? throw new NotOriginException(false);
                    labels.Add("xn--" + code);
                }
            }
            decoded = string.Join('.', labels);
        }
        if (decoded.Length == 0)
        {
            throw new NotOriginException(false);
        }
        foreach (char c in decoded)
        {
            if (ForbiddenHostChar(c))
            {
                throw new NotOriginException(false);
            }
        }
        return Ipv4(decoded) ?? decoded;
    }

    private static bool IsAscii(string s)
    {
        foreach (char c in s)
        {
            if (c >= 0x80)
            {
                return false;
            }
        }
        return true;
    }

    private static int HexDigit(char c) => c switch
    {
        >= '0' and <= '9' => c - '0',
        >= 'a' and <= 'f' => c - 'a' + 10,
        >= 'A' and <= 'F' => c - 'A' + 10,
        _ => -1,
    };

    /// <summary>WHATWG's IPv6 parser: the eight groups, or null for text that is not an address.</summary>
    internal static int[]? ParseIpv6(string s)
    {
        int[] address = new int[8];
        int piece = 0;
        int compress = -1;
        int p = 0;
        int n = s.Length;
        if (p < n && s[p] == ':')
        {
            if (p + 1 >= n || s[p + 1] != ':')
            {
                return null;
            }
            p += 2;
            piece++;
            compress = piece;
        }
        while (p < n)
        {
            if (piece == 8)
            {
                return null;
            }
            if (s[p] == ':')
            {
                if (compress >= 0)
                {
                    return null;
                }
                p++;
                piece++;
                compress = piece;
                continue;
            }
            int value = 0;
            int length = 0;
            while (length < 4 && p < n && HexDigit(s[p]) >= 0)
            {
                value = (value * 16) + HexDigit(s[p]);
                p++;
                length++;
            }
            if (p < n && s[p] == '.')
            {
                if (length == 0)
                {
                    return null;
                }
                p -= length;
                if (piece > 6)
                {
                    return null;
                }
                int seen = 0;
                while (p < n)
                {
                    int part = -1;
                    if (seen > 0)
                    {
                        if (s[p] == '.' && seen < 4)
                        {
                            p++;
                        }
                        else
                        {
                            return null;
                        }
                    }
                    if (p >= n || s[p] is < '0' or > '9')
                    {
                        return null;
                    }
                    while (p < n && s[p] is >= '0' and <= '9')
                    {
                        int d = s[p] - '0';
                        if (part < 0)
                        {
                            part = d;
                        }
                        else if (part == 0)
                        {
                            return null;
                        }
                        else
                        {
                            part = (part * 10) + d;
                        }
                        if (part > 255)
                        {
                            return null;
                        }
                        p++;
                    }
                    address[piece] = (address[piece] * 0x100) + part;
                    seen++;
                    if (seen is 2 or 4)
                    {
                        piece++;
                    }
                }
                if (seen != 4)
                {
                    return null;
                }
                break;
            }
            else if (p < n && s[p] == ':')
            {
                p++;
                if (p >= n)
                {
                    return null;
                }
            }
            else if (p < n)
            {
                return null;
            }
            address[piece] = value;
            piece++;
        }
        if (compress >= 0)
        {
            int swaps = piece - compress;
            piece = 7;
            while (piece != 0 && swaps > 0)
            {
                int other = compress + swaps - 1;
                (address[piece], address[other]) = (address[other], address[piece]);
                piece--;
                swaps--;
            }
        }
        else if (piece != 8)
        {
            return null;
        }
        return address;
    }

    /// <summary>
    /// An IPv6 address as the URL serializer writes it: groups in lowercase hex, the first longest
    /// run of two or more zero groups as <c>::</c>, and never the dotted form.
    /// </summary>
    internal static string Ipv6Text(int[] groups)
    {
        int start = -1;
        int length = 0;
        int i = 0;
        while (i < 8)
        {
            if (groups[i] != 0)
            {
                i++;
                continue;
            }
            int j = i;
            while (j < 8 && groups[j] == 0)
            {
                j++;
            }
            if (j - i > length && j - i > 1)
            {
                start = i;
                length = j - i;
            }
            i = j;
        }
        var output = new StringBuilder();
        i = 0;
        while (i < 8)
        {
            if (i == start)
            {
                output.Append(i == 0 ? "::" : ":");
                i += length;
                continue;
            }
            output.Append(groups[i].ToString("x", CultureInfo.InvariantCulture));
            if (i < 7)
            {
                output.Append(':');
            }
            i++;
        }
        return output.ToString();
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

    private static bool IsHexLabel(string s)
    {
        if (s.Length < 2 || s[0] != '0' || s[1] is not ('x' or 'X'))
        {
            return false;
        }
        for (int i = 2; i < s.Length; i++)
        {
            if (HexDigit(s[i]) < 0)
            {
                return false;
            }
        }
        return true;
    }

    private static bool IsOctalLabel(string s)
    {
        if (s.Length < 2 || s[0] != '0')
        {
            return false;
        }
        for (int i = 1; i < s.Length; i++)
        {
            if (s[i] is < '0' or > '7')
            {
                return false;
            }
        }
        return true;
    }

    /// <summary>
    /// WHATWG's IPv4 parser, for a host whose last label is a number: <c>127.1</c> and
    /// <c>0x7f.1</c> are 127.0.0.1. Null for a host that is a name.
    /// </summary>
    private static string? Ipv4(string host)
    {
        var parts = new List<string>(host.Split('.'));
        if (parts.Count > 1 && parts[^1].Length == 0)
        {
            parts.RemoveAt(parts.Count - 1);
        }
        string last = parts[^1];
        if (!IsDecimal(last) && !IsHexLabel(last))
        {
            return null;
        }
        if (parts.Count > 4)
        {
            throw new NotOriginException(false);
        }
        double[] numbers = new double[parts.Count];
        for (int i = 0; i < numbers.Length; i++)
        {
            numbers[i] = Ipv4Number(parts[i]);
        }
        for (int i = 0; i < numbers.Length - 1; i++)
        {
            if (numbers[i] > 255)
            {
                throw new NotOriginException(false);
            }
        }
        double lastN = numbers[^1];
        if (lastN >= Math.Pow(256, 5 - numbers.Length))
        {
            throw new NotOriginException(false);
        }
        double address = lastN;
        for (int i = 0; i < numbers.Length - 1; i++)
        {
            address += numbers[i] * Math.Pow(256, 3 - i);
        }
        long a = (long)address;
        return string.Create(CultureInfo.InvariantCulture, $"{a >> 24}.{(a >> 16) & 255}.{(a >> 8) & 255}.{a & 255}");
    }

    private static double Ipv4Number(string part)
    {
        if (part.Length == 0)
        {
            throw new NotOriginException(false);
        }
        if (IsHexLabel(part))
        {
            return part.Length == 2 ? 0 : ParseBig(part[2..], 16);
        }
        if (IsOctalLabel(part))
        {
            return ParseBig(part[1..], 8);
        }
        if (IsDecimal(part) && (part == "0" || part[0] != '0'))
        {
            return ParseBig(part, 10);
        }
        throw new NotOriginException(false);
    }

    /// <summary>Digits as a number; too many to count are past every limit the checks test.</summary>
    private static double ParseBig(string digits, int radix)
    {
        int z = 0;
        while (z < digits.Length - 1 && digits[z] == '0')
        {
            z++;
        }
        string d = digits[z..];
        if (d.Length > 24)
        {
            return double.PositiveInfinity;
        }
        BigInteger value = BigInteger.Zero;
        foreach (char c in d)
        {
            value = (value * radix) + HexDigit(c);
        }
        return (double)value;
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
}
