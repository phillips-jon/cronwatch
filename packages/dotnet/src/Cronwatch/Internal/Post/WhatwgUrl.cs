using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;

namespace Cronwatch.Internal;

/// <summary>What reading a URL found.</summary>
internal enum UrlKind
{
    /// <summary>A URL of a special scheme (http, https, ws, wss, ftp) with a host.</summary>
    Special,

    /// <summary>A URL of another scheme.</summary>
    Other,

    /// <summary>Text that is no URL.</summary>
    Invalid,
}

/// <summary>
/// A URL read as the WHATWG URL parser (and so fetch) reads an http or https URL, the Java port's
/// <c>WhatwgUrl</c> (itself the Go, Rust and Elixir ports'): characters up to U+0020 around it
/// dropped and every tab, CR and LF inside it removed; the slashes after the scheme, and
/// backslashes, read as fetch reads them; the host lowercased, IPv4 in its dotted form (hex, octal
/// and short forms read) and IPv6 compressed; the scheme's own port left out; dot segments
/// resolved; and a space or other character a URL cannot hold percent-encoded in the path, query
/// and fragment. A host outside ASCII is refused rather than converted to punycode (.NET's IDN
/// mapping is the platform's, WHATWG's is UTS 46), and so is an IPv6 host with a zone, which
/// WHATWG's IPv6 parser does not read.
/// </summary>
internal sealed class WhatwgUrl
{
    private WhatwgUrl(string scheme, string username, string password, string host, int port, string path, string? query, string? fragment)
    {
        Scheme = scheme;
        Username = username;
        Password = password;
        Host = host;
        Port = port;
        Path = path;
        Query = query;
        Fragment = fragment;
    }

    /// <summary>The scheme, lowercased.</summary>
    public string Scheme { get; }

    /// <summary>The user name, percent-encoded as WHATWG writes it, or "".</summary>
    public string Username { get; }

    /// <summary>The password, percent-encoded, or "".</summary>
    public string Password { get; }

    /// <summary>The host as WHATWG writes it (an IPv6 address in brackets).</summary>
    public string Host { get; }

    /// <summary>The port, or -1 for the scheme's own.</summary>
    public int Port { get; }

    /// <summary>The path, starting with <c>/</c>.</summary>
    public string Path { get; }

    /// <summary>The query without its <c>?</c>, or null for none.</summary>
    public string? Query { get; }

    /// <summary>The fragment without its <c>#</c>, or null for none.</summary>
    public string? Fragment { get; }

    /// <summary>The port the scheme uses when none is written.</summary>
    public static int DefaultPort(string scheme) => scheme switch
    {
        "http" or "ws" => 80,
        "https" or "wss" => 443,
        "ftp" => 21,
        _ => -1,
    };

    /// <summary>Whether the URL has a user name or a password, which fetch refuses to send.</summary>
    public bool HasCredentials => Username.Length > 0 || Password.Length > 0;

    /// <summary><c>url.origin</c>: the scheme, host and port.</summary>
    public string Origin => Scheme + "://" + Host + (Port < 0 ? "" : ":" + Port.ToString(CultureInfo.InvariantCulture));

    /// <summary>The path and query, as a request's target.</summary>
    public string Target => Query == null ? Path : Path + "?" + Query;

    /// <summary>The URL as the parser writes it, without its user name and password.</summary>
    public override string ToString() => Origin + Path + (Query == null ? "" : "?" + Query) + (Fragment == null ? "" : "#" + Fragment);

    /// <summary>The text as the parser first cleans it.</summary>
    public static string Clean(string raw)
    {
        int start = 0;
        int end = raw.Length;
        while (start < end && raw[start] <= 0x20)
        {
            start++;
        }
        while (end > start && raw[end - 1] <= 0x20)
        {
            end--;
        }
        var b = new StringBuilder(end - start);
        for (int i = start; i < end; i++)
        {
            char c = raw[i];
            if (c != '\t' && c != '\r' && c != '\n')
            {
                b.Append(c);
            }
        }
        return b.ToString();
    }

    /// <summary>Reads a URL: its kind, the scheme for another scheme, and the URL for a special one.</summary>
    public static (UrlKind Kind, string Scheme, WhatwgUrl? Url) Parse(string raw)
    {
        string s = Clean(raw);
        if (s.Length == 0 || !AsciiAlpha(s[0]))
        {
            return (UrlKind.Invalid, "", null);
        }
        int colon = s.IndexOf(':', StringComparison.Ordinal);
        if (colon < 0)
        {
            return (UrlKind.Invalid, "", null);
        }
        for (int i = 1; i < colon; i++)
        {
            char c = s[i];
            if (!AsciiAlpha(c) && !(c >= '0' && c <= '9') && c != '+' && c != '.' && c != '-')
            {
                return (UrlKind.Invalid, "", null);
            }
        }
        string scheme = AsciiLower(s[..colon]);
        if (DefaultPort(scheme) < 0)
        {
            return (UrlKind.Other, scheme, null);
        }
        WhatwgUrl? url = Special(scheme, s[(colon + 1)..]);
        return url == null ? (UrlKind.Invalid, scheme, null) : (UrlKind.Special, scheme, url);
    }

    private static bool AsciiAlpha(char c) => (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');

    /// <summary>ASCII letters lowercased, whatever the culture.</summary>
    public static string AsciiLower(string s)
    {
        var b = new StringBuilder(s.Length);
        foreach (char c in s)
        {
            b.Append(c >= 'A' && c <= 'Z' ? (char)(c + 32) : c);
        }
        return b.ToString();
    }

    private static WhatwgUrl? Special(string scheme, string rest)
    {
        int i = 0;
        while (i < rest.Length && (rest[i] == '/' || rest[i] == '\\'))
        {
            i++;
        }
        rest = rest[i..];
        int stop = rest.Length;
        for (int k = 0; k < rest.Length; k++)
        {
            char c = rest[k];
            if (c == '/' || c == '\\' || c == '?' || c == '#')
            {
                stop = k;
                break;
            }
        }
        string authority = rest[..stop];
        string tail = rest[stop..];
        string? fragment = null;
        int hash = tail.IndexOf('#', StringComparison.Ordinal);
        if (hash >= 0)
        {
            fragment = tail[(hash + 1)..];
            tail = tail[..hash];
        }
        string? query = null;
        int q = tail.IndexOf('?', StringComparison.Ordinal);
        if (q >= 0)
        {
            query = tail[(q + 1)..];
            tail = tail[..q];
        }

        // The part before the last "@" is the user name and password.
        string username = "";
        string password = "";
        string hostPort = authority;
        int at = authority.LastIndexOf('@');
        if (at >= 0)
        {
            string info = authority[..at];
            hostPort = authority[(at + 1)..];
            int split = info.IndexOf(':', StringComparison.Ordinal);
            username = Encode(split < 0 ? info : info[..split], UserinfoChar);
            password = split < 0 ? "" : Encode(info[(split + 1)..], UserinfoChar);
        }

        string hostText;
        string portText;
        if (hostPort.StartsWith('['))
        {
            int close = hostPort.IndexOf(']', StringComparison.Ordinal);
            if (close < 0)
            {
                return null;
            }
            hostText = hostPort[..(close + 1)];
            string after = hostPort[(close + 1)..];
            if (after.Length == 0)
            {
                portText = "";
            }
            else if (after.StartsWith(':'))
            {
                portText = after[1..];
            }
            else
            {
                return null;
            }
        }
        else
        {
            int c = hostPort.IndexOf(':', StringComparison.Ordinal);
            hostText = c < 0 ? hostPort : hostPort[..c];
            portText = c < 0 ? "" : hostPort[(c + 1)..];
        }
        string? host = ReadHost(hostText);
        if (host == null)
        {
            return null;
        }
        int port = -1;
        if (portText.Length > 0)
        {
            foreach (char c in portText)
            {
                if (c < '0' || c > '9')
                {
                    return null;
                }
            }
            string digits = portText.TrimStart('0');
            if (digits.Length == 0)
            {
                digits = "0";
            }
            if (digits.Length > 5)
            {
                return null;
            }
            port = int.Parse(digits, NumberStyles.None, CultureInfo.InvariantCulture);
            if (port > 65_535)
            {
                return null;
            }
            if (port == DefaultPort(scheme))
            {
                port = -1;
            }
        }
        return new WhatwgUrl(
            scheme,
            username,
            password,
            host,
            port,
            ReadPath(tail),
            query == null ? null : Encode(query, QueryChar),
            fragment == null ? null : Encode(fragment, FragmentChar));
    }

    // ---- the host

    private static string? ReadHost(string text)
    {
        if (text.Length == 0)
        {
            return null;
        }
        if (text.StartsWith('['))
        {
            string v6 = text[1..^1];
            // WHATWG's IPv6 parser has no zone (%eth0).
            int[]? pieces = v6.Contains('%', StringComparison.Ordinal) ? null : Ipv6(v6);
            return pieces == null ? null : "[" + Ipv6Text(pieces) + "]";
        }
        byte[] decoded = PercentDecodeBytes(text);
        foreach (byte b in decoded)
        {
            // Outside ASCII: refused rather than converted to punycode, since .NET's IDN mapping
            // is not WHATWG's. Invalid UTF-8 is refused by the same test.
            if (b >= 0x80 || b < 0x21 || b == 0x7f || "#%/:<>?@[\\]^|".Contains((char)b, StringComparison.Ordinal))
            {
                return null;
            }
        }
        string host = AsciiLower(Encoding.ASCII.GetString(decoded));
        var labels = new List<string>(host.Split('.'));
        if (labels.Count > 1 && labels[^1].Length == 0)
        {
            labels.RemoveAt(labels.Count - 1);
        }
        return IsNumber(labels[^1]) ? Ipv4(labels) : host;
    }

    /// <summary>Whether a label reads as a number, so the host is an IPv4 address.</summary>
    private static bool IsNumber(string label)
    {
        if (label.Length == 0)
        {
            return false;
        }
        bool digits = true;
        foreach (char c in label)
        {
            digits &= c >= '0' && c <= '9';
        }
        if (digits)
        {
            return true;
        }
        if (label.Length < 2 || label[0] != '0' || (label[1] != 'x' && label[1] != 'X'))
        {
            return false;
        }
        for (int i = 2; i < label.Length; i++)
        {
            if (HexValue(label[i]) < 0)
            {
                return false;
            }
        }
        return true;
    }

    private static string? Ipv4(List<string> labels)
    {
        int n = labels.Count;
        if (n > 4)
        {
            return null;
        }
        var parts = new long[n];
        for (int i = 0; i < n; i++)
        {
            long v = Ipv4Number(labels[i]);
            if (v < 0)
            {
                return null;
            }
            parts[i] = v;
        }
        long address = parts[n - 1];
        if (address >= 1L << (8 * (5 - n)))
        {
            return null;
        }
        for (int i = 0; i < n - 1; i++)
        {
            if (parts[i] > 255)
            {
                return null;
            }
            address += parts[i] << (8 * (3 - i));
        }
        return ((address >> 24) & 255).ToString(CultureInfo.InvariantCulture) + "."
            + ((address >> 16) & 255).ToString(CultureInfo.InvariantCulture) + "."
            + ((address >> 8) & 255).ToString(CultureInfo.InvariantCulture) + "."
            + (address & 255).ToString(CultureInfo.InvariantCulture);
    }

    /// <summary>A label's number, or -1 when it is none (or past what an address can hold).</summary>
    private static long Ipv4Number(string label)
    {
        if (label.Length == 0)
        {
            return -1;
        }
        int radix = 10;
        string digits = label;
        if (label.Length >= 2 && label[0] == '0' && (label[1] | 0x20) == 'x')
        {
            radix = 16;
            digits = label[2..];
            if (digits.Length == 0)
            {
                return 0;
            }
        }
        else if (label.Length >= 2 && label[0] == '0')
        {
            radix = 8;
            digits = label[1..];
        }
        long v = 0;
        foreach (char c in digits)
        {
            int d = HexValue(c);
            if (d < 0 || d >= radix)
            {
                return -1;
            }
            v = (v * radix) + d;
            if (v > 0xFFFF_FFFFL)
            {
                // Past any address: the host is refused, as WHATWG refuses it.
                return 1L << 40;
            }
        }
        return v;
    }

    /// <summary>An ASCII hex digit's value, or -1.</summary>
    public static int HexValue(char c) => c switch
    {
        >= '0' and <= '9' => c - '0',
        >= 'a' and <= 'f' => c - 'a' + 10,
        >= 'A' and <= 'F' => c - 'A' + 10,
        _ => -1,
    };

    /// <summary>WHATWG's IPv6 parser: eight pieces, or null for text that is no IPv6 address.</summary>
    public static int[]? Ipv6(string input)
    {
        var address = new int[8];
        int piece = 0;
        int compress = -1;
        int p = 0;
        int n = input.Length;
        if (n > 0 && input[0] == ':')
        {
            if (n < 2 || input[1] != ':')
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
            if (input[p] == ':')
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
            while (length < 4 && p < n && HexValue(input[p]) >= 0)
            {
                value = (value * 16) + HexValue(input[p]);
                p++;
                length++;
            }
            if (p < n && input[p] == '.')
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
                    int v4 = -1;
                    if (seen > 0)
                    {
                        if (input[p] == '.' && seen < 4)
                        {
                            p++;
                        }
                        else
                        {
                            return null;
                        }
                    }
                    if (p >= n || input[p] < '0' || input[p] > '9')
                    {
                        return null;
                    }
                    while (p < n && input[p] >= '0' && input[p] <= '9')
                    {
                        int number = input[p] - '0';
                        if (v4 < 0)
                        {
                            v4 = number;
                        }
                        else if (v4 == 0)
                        {
                            return null;
                        }
                        else
                        {
                            v4 = (v4 * 10) + number;
                        }
                        if (v4 > 255)
                        {
                            return null;
                        }
                        p++;
                    }
                    address[piece] = (address[piece] * 0x100) + v4;
                    seen++;
                    if (seen == 2 || seen == 4)
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
            else if (p < n && input[p] == ':')
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

    /// <summary>WHATWG's IPv6 serializer: lowercase hex, the first longest run of two or more zeros cut.</summary>
    public static string Ipv6Text(int[] pieces)
    {
        int best = -1;
        int bestLength = 1;
        for (int i = 0; i < 8;)
        {
            if (pieces[i] != 0)
            {
                i++;
                continue;
            }
            int j = i;
            while (j < 8 && pieces[j] == 0)
            {
                j++;
            }
            if (j - i > bestLength)
            {
                best = i;
                bestLength = j - i;
            }
            i = j;
        }
        var b = new StringBuilder();
        bool ignore0 = false;
        for (int i = 0; i < 8; i++)
        {
            if (ignore0 && pieces[i] == 0)
            {
                continue;
            }
            ignore0 = false;
            if (best == i)
            {
                b.Append(i == 0 ? "::" : ":");
                ignore0 = true;
                continue;
            }
            b.Append(pieces[i].ToString("x", CultureInfo.InvariantCulture));
            if (i != 7)
            {
                b.Append(':');
            }
        }
        return b.ToString();
    }

    // ---- the path, query and fragment

    private static string ReadPath(string text)
    {
        string[] split = text.Replace('\\', '/').Split('/');
        var output = new List<string>();
        for (int i = 1; i < split.Length; i++)
        {
            string seg = split[i];
            bool last = i == split.Length - 1;
            string lower = AsciiLower(seg);
            if (lower is ".." or ".%2e" or "%2e." or "%2e%2e")
            {
                if (output.Count > 0)
                {
                    output.RemoveAt(output.Count - 1);
                }
                if (last)
                {
                    output.Add("");
                }
            }
            else if (lower is "." or "%2e")
            {
                if (last)
                {
                    output.Add("");
                }
            }
            else
            {
                output.Add(Encode(seg, PathChar));
            }
        }
        return "/" + string.Join('/', output);
    }

    private static bool C0OrHigh(int c) => c < 0x20 || c > 0x7e;

    private static bool PathChar(int c) => !(C0OrHigh(c) || " \"#<>?`{}".Contains((char)c, StringComparison.Ordinal));

    private static bool QueryChar(int c) => !(C0OrHigh(c) || " \"#<>'".Contains((char)c, StringComparison.Ordinal));

    private static bool FragmentChar(int c) => !(C0OrHigh(c) || " \"<>`".Contains((char)c, StringComparison.Ordinal));

    private static bool UserinfoChar(int c) => !(C0OrHigh(c) || " \"#<>?`{}/:;=@[\\]^|".Contains((char)c, StringComparison.Ordinal));

    private const string Hex = "0123456789ABCDEF";

    /// <summary>The text's UTF-8 (a lone surrogate as U+FFFD), each byte <paramref name="keep"/> refuses as <c>%XX</c>.</summary>
    private static string Encode(string text, Func<int, bool> keep)
    {
        var b = new StringBuilder(text.Length);
        foreach (byte x in Js.Utf8(text))
        {
            if (keep(x))
            {
                b.Append((char)x);
            }
            else
            {
                b.Append('%').Append(Hex[x >> 4]).Append(Hex[x & 15]);
            }
        }
        return b.ToString();
    }

    /// <summary><c>%XX</c> decoded, bytes as they are (the text's own as UTF-8).</summary>
    public static byte[] PercentDecodeBytes(string text)
    {
        byte[] input = Js.Utf8(text);
        using var output = new MemoryStream(input.Length);
        for (int i = 0; i < input.Length; i++)
        {
            if (input[i] == '%' && i + 2 < input.Length)
            {
                int h = HexValue((char)input[i + 1]);
                int l = HexValue((char)input[i + 2]);
                if (h >= 0 && l >= 0)
                {
                    output.WriteByte((byte)((h << 4) | l));
                    i += 2;
                    continue;
                }
            }
            output.WriteByte(input[i]);
        }
        return output.ToArray();
    }
}
