using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

namespace Cronwatch.Internal;

/// <summary>
/// Reading a request the way the SDK's routes read a fetch <c>Request</c>, carried over from the
/// Java port's <c>internal/web/Requests</c> (the Go port's <c>routes_request.go</c> through the
/// Rust port's <c>web/request.rs</c>): the path as the URL parser leaves it, the query as
/// <c>URLSearchParams</c> parses it, headers as <c>Headers.get</c> joins them, and the body as
/// <c>request.json()</c> and <c>request.formData()</c> read it.
/// </summary>
internal static class Requests
{
    private const string Hex = "0123456789ABCDEF";

    /// <summary>
    /// A header as fetch's <c>Headers.get</c> gives it: every value joined with <c>", "</c> (a
    /// cookie's with <c>"; "</c>, as HTTP/2 sends each cookie apart), or null when there is none.
    /// Names are compared without regard to ASCII case.
    /// </summary>
    public static string? Header(IReadOnlyList<KeyValuePair<string, string>> headers, string name)
    {
        string? first = null;
        StringBuilder? joined = null;
        string sep = string.Equals(name, "cookie", StringComparison.OrdinalIgnoreCase) ? "; " : ", ";
        foreach (var h in headers)
        {
            if (!string.Equals(h.Key, name, StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }
            if (first == null)
            {
                first = h.Value;
            }
            else
            {
                joined ??= new StringBuilder(first);
                joined.Append(sep).Append(h.Value);
            }
        }
        return joined != null ? joined.ToString() : first;
    }

    /// <summary>
    /// The path and query the client sent. A target in the absolute form a proxy is sent starts
    /// its path after the host; a fragment is dropped.
    /// </summary>
    public static (string Path, string Query) Target(string target)
    {
        string t = target;
        if (!t.StartsWith('/'))
        {
            int i = t.IndexOf("://", StringComparison.Ordinal);
            if (i >= 0)
            {
                string rest = t[(i + 3)..];
                int j = rest.AsSpan().IndexOfAny('/', '?');
                t = j < 0 ? "/" : rest[j..];
            }
        }
        int q = t.IndexOf('?', StringComparison.Ordinal);
        string path = q < 0 ? t : t[..q];
        string query = q < 0 ? "" : t[(q + 1)..];
        int hash = path.IndexOf('#', StringComparison.Ordinal);
        if (hash >= 0)
        {
            path = path[..hash];
        }
        hash = query.IndexOf('#', StringComparison.Ordinal);
        if (hash >= 0)
        {
            query = query[..hash];
        }
        if (path.Length == 0 || path == "*")
        {
            path = "/";
        }
        return (path, query);
    }

    /// <summary>
    /// Whether the URL parser leaves <paramref name="c"/> in a path as it is: the path
    /// percent-encode set is C0 controls, space, <c>" # &lt; &gt; ? ` { }</c> and everything past
    /// <c>~</c>.
    /// </summary>
    private static bool PathSafe(int c) => c > 0x20 && c < 0x7f && "\"#<>?`{}".IndexOf((char)c, StringComparison.Ordinal) < 0;

    /// <summary>
    /// A path as <c>new URL()</c> leaves it for an http URL: backslashes read as slashes,
    /// characters outside the path set escaped as UTF-8, and <c>.</c> and <c>..</c> segments
    /// (written plainly or as <c>%2e</c>) resolved.
    /// </summary>
    public static string NormalizePath(string raw)
    {
        var b = new StringBuilder(raw.Length);
        foreach (byte x in Js.Utf8(raw))
        {
            int c = x;
            if (c == '\\')
            {
                b.Append('/');
            }
            else if (PathSafe(c) || c == '%')
            {
                b.Append((char)c);
            }
            else
            {
                b.Append('%').Append(Hex[c >> 4]).Append(Hex[c & 15]);
            }
        }
        string s = b.ToString();
        string trimmed = s.StartsWith('/') ? s[1..] : s;
        string[] segments = trimmed.Split('/');
        var output = new List<string>();
        for (int i = 0; i < segments.Length; i++)
        {
            bool last = i == segments.Length - 1;
            switch (segments[i].ToLowerInvariant())
            {
                case "." or "%2e":
                    if (last)
                    {
                        output.Add("");
                    }
                    break;
                case ".." or ".%2e" or "%2e." or "%2e%2e":
                    if (output.Count > 0)
                    {
                        output.RemoveAt(output.Count - 1);
                    }
                    if (last)
                    {
                        output.Add("");
                    }
                    break;
                default:
                    output.Add(segments[i]);
                    break;
            }
        }
        return "/" + string.Join('/', output);
    }

    /// <summary>The path under the base, without a trailing slash.</summary>
    public static string StripBase(string pathname, string basePath)
    {
        string path = pathname.StartsWith(basePath, StringComparison.Ordinal) ? pathname[basePath.Length..] : pathname;
        if (path.Length == 0)
        {
            path = "/";
        }
        if (path.Length > 1 && path.EndsWith('/'))
        {
            path = path[..^1];
        }
        return path;
    }

    private static bool IsHexDigit(int c) => c is (>= '0' and <= '9') or (>= 'a' and <= 'f') or (>= 'A' and <= 'F');

    private static int HexValue(int c) => c <= '9' ? c - '0' : (c | 0x20) - 'a' + 10;

    /// <summary>
    /// <c>decodeURIComponent</c>, or null where it would throw: an escape that is not one, or
    /// bytes that are not UTF-8.
    /// </summary>
    public static string? SafeDecode(string s)
    {
        for (int i = 0; i < s.Length; i++)
        {
            if (s[i] == '%' && (i + 2 >= s.Length || !IsHexDigit(s[i + 1]) || !IsHexDigit(s[i + 2])))
            {
                return null;
            }
        }
        return WebText.StrictUtf8(PercentDecode(Js.Utf8(s)));
    }

    /// <summary>Decodes every <c>%XX</c>, leaving anything else as it is.</summary>
    public static byte[] PercentDecode(byte[] s)
    {
        using var output = new MemoryStream(s.Length);
        int i = 0;
        while (i < s.Length)
        {
            if (s[i] == '%' && i + 2 < s.Length && IsHexDigit(s[i + 1]) && IsHexDigit(s[i + 2]))
            {
                output.WriteByte((byte)((HexValue(s[i + 1]) << 4) | HexValue(s[i + 2])));
                i += 3;
                continue;
            }
            output.WriteByte(s[i]);
            i++;
        }
        return output.ToArray();
    }

    /// <summary>
    /// <c>application/x-www-form-urlencoded</c> parsing as <c>URLSearchParams</c> does it:
    /// <c>+</c> is a space, an escape that is not one is kept as written, and bytes that are not
    /// UTF-8 become U+FFFD.
    /// </summary>
    public static List<KeyValuePair<string, string>> ParseForm(byte[] text)
    {
        var output = new List<KeyValuePair<string, string>>();
        int start = 0;
        for (int i = 0; i <= text.Length; i++)
        {
            if (i < text.Length && text[i] != '&')
            {
                continue;
            }
            if (i > start)
            {
                int eq = Array.IndexOf(text, (byte)'=', start, i - start);
                string name = FormDecode(text, start, eq < 0 ? i : eq);
                string value = eq < 0 ? "" : FormDecode(text, eq + 1, i);
                output.Add(new KeyValuePair<string, string>(name, value));
            }
            start = i + 1;
        }
        return output;
    }

    /// <summary><see cref="ParseForm"/> of a query as the URL holds it: its text written out as UTF-8.</summary>
    public static List<KeyValuePair<string, string>> ParseQuery(string query) => ParseForm(Js.Utf8(query));

    private static string FormDecode(byte[] s, int from, int to)
    {
        byte[] spaced = new byte[to - from];
        for (int i = from; i < to; i++)
        {
            spaced[i - from] = s[i] == '+' ? (byte)' ' : s[i];
        }
        return Encoding.UTF8.GetString(PercentDecode(spaced));
    }

    /// <summary>The <c>application/x-www-form-urlencoded</c> serializer <c>URLSearchParams</c> writes.</summary>
    public static string FormEncode(string s)
    {
        var output = new StringBuilder(s.Length);
        foreach (byte x in Js.Utf8(s))
        {
            int c = x;
            if (WebText.IsAsciiAlphanumeric(c) || c is '*' or '-' or '.' or '_')
            {
                output.Append((char)c);
            }
            else if (c == ' ')
            {
                output.Append('+');
            }
            else
            {
                output.Append('%').Append(Hex[c >> 4]).Append(Hex[c & 15]);
            }
        }
        return output.ToString();
    }

    /// <summary><c>URLSearchParams#get</c>: the first value, or null.</summary>
    public static string? Param(IReadOnlyList<KeyValuePair<string, string>> pairs, string name)
    {
        foreach (var p in pairs)
        {
            if (p.Key == name)
            {
                return p.Value;
            }
        }
        return null;
    }

    private static string? LastField(List<KeyValuePair<string, string>> pairs, string name)
    {
        string? found = null;
        foreach (var p in pairs)
        {
            if (p.Key == name)
            {
                found = p.Value;
            }
        }
        return found;
    }

    /// <summary>
    /// A field of a request's form or JSON object, as <c>String(value)</c> gives it in
    /// JavaScript; null for anything else, or a body that cannot be read as its type says. The
    /// last of several fields of one name wins, as <c>Object.fromEntries</c> has it.
    /// </summary>
    public static string? BodyField(string contentType, byte[] data, string name)
    {
        if (contentType.Contains("application/json", StringComparison.Ordinal))
        {
            string text = Encoding.UTF8.GetString(data);
            if (text.StartsWith('﻿'))
            {
                text = text[1..];
            }
            object? value;
            try
            {
                value = Json.Parse(text);
            }
            catch (JsonParseException)
            {
                // Not JSON, or nested past Json.MaxDepth: the SDK's readBody reads it as none.
                return null;
            }
            return JsonField(value, name);
        }
        if (contentType.Contains("multipart/form-data", StringComparison.Ordinal))
        {
            var fields = MultipartFields(contentType, data);
            return fields == null ? null : LastField(fields, name);
        }
        if (contentType.Contains("application/x-www-form-urlencoded", StringComparison.Ordinal))
        {
            return LastField(ParseForm(data), name);
        }
        return null;
    }

    /// <summary><c>String(data[name])</c> of a parsed JSON body, or null when it has no such field.</summary>
    internal static string? JsonField(object? value, string name)
    {
        if (value is JsObject o)
        {
            return o.Has(name) ? AlertFormat.JsText(o.Get(name)) : null;
        }
        if (value is IReadOnlyList<object?> list)
        {
            long i = ArrayIndex(name);
            return i >= 0 && i < list.Count ? AlertFormat.JsText(list[(int)i]) : null;
        }
        return null;
    }

    /// <summary>A key that is an array index (a canonical whole number below 2^32 - 1), or -1.</summary>
    internal static long ArrayIndex(string key)
    {
        int n = key.Length;
        if (n == 0 || n > 10 || (n > 1 && key[0] == '0'))
        {
            return -1;
        }
        long v = 0;
        foreach (char c in key)
        {
            if (c is < '0' or > '9')
            {
                return -1;
            }
            v = (v * 10) + (c - '0');
        }
        return v >= (1L << 32) - 1 ? -1 : v;
    }

    /// <summary>Java's <c>String.trim</c>: every character up to U+0020 off both ends.</summary>
    private static string TrimControls(string s)
    {
        int start = 0;
        int end = s.Length;
        while (start < end && s[start] <= ' ')
        {
            start++;
        }
        while (end > start && s[end - 1] <= ' ')
        {
            end--;
        }
        return s[start..end];
    }

    /// <summary>A media type's parameter, unquoted, its name matched without regard to case.</summary>
    internal static string? MediaParam(string contentType, string name)
    {
        string[] parts = contentType.Split(';');
        for (int i = 1; i < parts.Length; i++)
        {
            int eq = parts[i].IndexOf('=', StringComparison.Ordinal);
            if (eq < 0)
            {
                continue;
            }
            if (!string.Equals(TrimControls(parts[i][..eq]), name, StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }
            return Unquote(TrimControls(parts[i][(eq + 1)..]));
        }
        return null;
    }

    private static string Unquote(string v)
    {
        if (v.Length < 2 || !v.StartsWith('"') || !v.EndsWith('"'))
        {
            return v;
        }
        string inner = v[1..^1];
        var output = new StringBuilder();
        for (int i = 0; i < inner.Length; i++)
        {
            char c = inner[i];
            if (c == '\\')
            {
                if (i + 1 < inner.Length)
                {
                    output.Append(inner[++i]);
                }
            }
            else
            {
                output.Append(c);
            }
        }
        return output.ToString();
    }

    private static int Find(byte[] haystack, byte[] needle, int from)
    {
        if (needle.Length == 0 || from > haystack.Length)
        {
            return -1;
        }
        int at = haystack.AsSpan(from).IndexOf(needle);
        return at < 0 ? -1 : at + from;
    }

    private static byte[] Concat(string prefix, byte[] b)
    {
        byte[] p = Encoding.Latin1.GetBytes(prefix);
        byte[] output = new byte[p.Length + b.Length];
        p.CopyTo(output, 0);
        b.CopyTo(output, p.Length);
        return output;
    }

    private static bool StartsWith(byte[] data, int at, byte[] prefix) =>
        at + prefix.Length <= data.Length && data.AsSpan(at, prefix.Length).SequenceEqual(prefix);

    /// <summary>
    /// The fields of a <c>multipart/form-data</c> body, as <c>formData()</c> reads them: a file
    /// part's value is <c>[object File]</c>. Null for a body that does not parse, as
    /// <c>formData()</c> throws on one.
    /// </summary>
    internal static List<KeyValuePair<string, string>>? MultipartFields(string contentType, byte[] data)
    {
        string? boundary = MediaParam(contentType, "boundary");
        if (string.IsNullOrEmpty(boundary))
        {
            return null;
        }
        byte[] delimiter = Js.Utf8("--" + boundary);
        int at;
        if (StartsWith(data, 0, delimiter))
        {
            at = 0;
        }
        else
        {
            int crlf = Find(data, Concat("\r\n", delimiter), 0);
            int lf = Find(data, Concat("\n", delimiter), 0);
            if (crlf >= 0)
            {
                at = crlf + 2;
            }
            else if (lf >= 0)
            {
                at = lf + 1;
            }
            else
            {
                return null;
            }
        }
        byte[] nl = [(byte)'\n'];
        byte[] dashes = [(byte)'-', (byte)'-'];
        byte[] nextDelimiter = Concat("\n", delimiter);
        var fields = new List<KeyValuePair<string, string>>();
        while (true)
        {
            at += delimiter.Length;
            if (StartsWith(data, at, dashes))
            {
                return fields;
            }
            // The rest of the delimiter's line.
            int eol = Find(data, nl, at);
            if (eol < 0)
            {
                return null;
            }
            at = eol + 1;
            // The part's headers, up to an empty line.
            string disposition = "";
            while (true)
            {
                int end = Find(data, nl, at);
                if (end < 0)
                {
                    return null;
                }
                int lineEnd = end > at && data[end - 1] == '\r' ? end - 1 : end;
                string line = Encoding.UTF8.GetString(data, at, lineEnd - at);
                at = end + 1;
                if (line.Length == 0)
                {
                    break;
                }
                int colon = line.IndexOf(':', StringComparison.Ordinal);
                if (colon >= 0 && string.Equals(TrimControls(line[..colon]), "content-disposition", StringComparison.OrdinalIgnoreCase))
                {
                    disposition = TrimControls(line[(colon + 1)..]);
                }
            }
            // The part's body, up to the next delimiter on a line of its own.
            int next = Find(data, nextDelimiter, at);
            if (next < 0)
            {
                return null;
            }
            int stop = next;
            if (stop > at && data[stop - 1] == '\r')
            {
                stop--;
            }
            string value = Encoding.UTF8.GetString(data, at, Math.Max(stop, at) - at);
            at = next + 1;
            string kind = TrimControls(disposition.Split(';')[0]);
            if (!string.Equals(kind, "form-data", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }
            string? name = MediaParam(disposition, "name");
            if (string.IsNullOrEmpty(name))
            {
                continue;
            }
            string? filename = MediaParam(disposition, "filename");
            fields.Add(new KeyValuePair<string, string>(name, !string.IsNullOrEmpty(filename) ? "[object File]" : value));
        }
    }
}
