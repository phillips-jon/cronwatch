using System;
using System.Buffers;
using System.Collections.Generic;
using System.Globalization;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch.Alerts;

namespace Cronwatch.Internal;

/// <summary>
/// The one POST the alert channels and Claude triage make, as the SDK makes it with fetch
/// (<c>alerts/shared.ts</c>), the Java port's <c>internal/post</c>: the URL read as fetch reads it,
/// only http and https, headers checked as fetch checks them, one ten second deadline for the
/// whole request, a redirect refused rather than followed (the transport's rule), at most 1 MiB of
/// an answer read, and an error that names only the URL's origin, with every secret the caller
/// holds cut out of a quoted answer before it is cut to 200 characters.
/// </summary>
/// <remarks>
/// The deadline is one linked <see cref="CancellationTokenSource"/> spanning the transport's call
/// and every read of the body, and each await is bounded by it too (<c>WaitAsync</c>), so the
/// deadline holds whatever the transport does, while connecting, sending or reading the answer.
/// </remarks>
internal static class Post
{
    /// <summary>How long one request may take, as the SDK's <c>AbortSignal.timeout(10_000)</c>.</summary>
    public static readonly TimeSpan DefaultTimeout = TimeSpan.FromSeconds(10);

    /// <summary>How much of an answer is read.</summary>
    public const int MaxBody = 1 << 20;

    /// <summary>How much of an answer's body goes into an error, in UTF-16 code units.</summary>
    public const int ErrorBodyMax = 200;

    /// <summary>Fetch's message for a request past its deadline.</summary>
    public const string TimedOut = "The operation was aborted due to timeout";

    private static long s_timeoutTicks = DefaultTimeout.Ticks;

    /// <summary>The deadline channels post within: ten seconds unless a test shortened it.</summary>
    public static TimeSpan Timeout
    {
        get => TimeSpan.FromTicks(Interlocked.Read(ref s_timeoutTicks));
        set => Interlocked.Exchange(ref s_timeoutTicks, value.Ticks);
    }

    /// <summary>An answer: its status, and as much of its body as was read, as <c>response.text()</c> reads it.</summary>
    public readonly record struct Answer(int Status, string Body)
    {
        /// <summary><c>response.ok</c>: a 2xx status.</summary>
        public bool Ok => Status >= 200 && Status < 300;
    }

    /// <summary>An error of this module's, with its message.</summary>
    public static CronwatchException Fail(string message) => new(CronwatchErrorKind.Other, message);

    /// <summary>
    /// The URL, once it is one a channel can post to: http or https with a host, no user name or
    /// password, and one <see cref="Uri"/> reads with the same host and port. Refused without
    /// quoting it, since a webhook URL's path is its credential: "not ftp:" for another scheme, "not
    /// this URL" for anything else.
    /// </summary>
    public static (WhatwgUrl Url, Uri Uri) Postable(string raw)
    {
        var refused = Fail("only http and https URLs can be posted to, not this URL");
        var (kind, scheme, url) = WhatwgUrl.Parse(raw ?? "");
        if (kind == UrlKind.Other || (url != null && url.Scheme != "http" && url.Scheme != "https"))
        {
            throw Fail("only http and https URLs can be posted to, not " + scheme + ":");
        }
        if (url == null || url.HasCredentials)
        {
            throw refused;
        }
        Uri uri = ToUri(url) ?? throw refused;
        return (url, uri);
    }

    /// <summary>
    /// The URL as a <see cref="Uri"/> that sends its path and query as written (no fragment, which
    /// is never sent); null when the host or port the <see cref="Uri"/> reads is not the one WHATWG
    /// read, so what the URL names and what is reached cannot differ.
    /// </summary>
    public static Uri? ToUri(WhatwgUrl u)
    {
        var options = new UriCreationOptions { DangerousDisablePathAndQueryCanonicalization = true };
        if (!Uri.TryCreate(u.Origin + u.Target, in options, out Uri? uri) || !uri.IsAbsoluteUri)
        {
            return null;
        }
        string host = WhatwgUrl.AsciiLower(uri.Host);
        int port = u.Port < 0 ? WhatwgUrl.DefaultPort(u.Scheme) : u.Port;
        return host == u.Host && uri.Port == port && uri.Scheme == u.Scheme ? uri : null;
    }

    /// <summary>
    /// <c>new URL(url).origin</c>: the scheme, host and port only; <c>"null"</c> for a URL of a
    /// scheme that has no origin and <c>"(invalid URL)"</c> for text that is no URL. A URL's path
    /// or query can hold a credential, so an error names only this.
    /// </summary>
    public static string Origin(string raw)
    {
        var (kind, _, url) = WhatwgUrl.Parse(raw ?? "");
        return kind switch
        {
            UrlKind.Special => url!.Origin,
            UrlKind.Other => "null",
            _ => "(invalid URL)",
        };
    }

    /// <summary>Whether a header name is an HTTP token (RFC 9110).</summary>
    public static bool IsToken(string name)
    {
        if (string.IsNullOrEmpty(name))
        {
            return false;
        }
        foreach (char c in name)
        {
            bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || "!#$%&'*+.^_`|~-".Contains(c, StringComparison.Ordinal);
            if (!ok)
            {
                return false;
            }
        }
        return true;
    }

    /// <summary>
    /// The headers as a request sends them: each name a token, each value without the spaces,
    /// tabs and line breaks around it, as fetch sends it. A name that is not a token, or a value
    /// with a line break or NUL inside, is refused, as fetch refuses them, so no header can add
    /// another; the error names the header, never its value, which may be a credential.
    /// </summary>
    public static List<KeyValuePair<string, string>> Headers(IEnumerable<KeyValuePair<string, string>> list)
    {
        var output = new List<KeyValuePair<string, string>>();
        foreach (var h in list)
        {
            string name = h.Key;
            if (!IsToken(name))
            {
                throw Fail("a header name must be a token (letters, digits and !#$%&'*+.^_`|~-)");
            }
            string value = TrimHttp(h.Value ?? "");
            if (value.Contains('\r', StringComparison.Ordinal) || value.Contains('\n', StringComparison.Ordinal) || value.Contains('\0', StringComparison.Ordinal))
            {
                throw Fail("the " + name + " header's value may not contain a line break");
            }
            output.Add(new(name, value));
        }
        return output;
    }

    private static bool HttpSpace(char c) => c is ' ' or '\t' or '\r' or '\n';

    private static string TrimHttp(string s)
    {
        int a = 0;
        int b = s.Length;
        while (a < b && HttpSpace(s[a]))
        {
            a++;
        }
        while (b > a && HttpSpace(s[b - 1]))
        {
            b--;
        }
        return s[a..b];
    }

    /// <summary>Bytes as <c>response.text()</c> reads them: UTF-8, U+FFFD for bytes that are not, no BOM.</summary>
    public static string Text(ReadOnlySpan<byte> data)
    {
        string s = Encoding.UTF8.GetString(data);
        return s.StartsWith('﻿') ? s[1..] : s;
    }

    /// <summary>
    /// Posts <paramref name="body"/> to <paramref name="rawUrl"/> through
    /// <paramref name="transport"/> within <paramref name="within"/>, and answers whatever the
    /// status. A refused URL or header, a request past the deadline (<see cref="TimedOut"/>) or the
    /// transport's own error is a <see cref="CronwatchException"/> naming no more of the URL than
    /// its origin. A body the deadline cut short, or one that could not be read, is <c>""</c>. The
    /// caller's own token cancelled is an <see cref="OperationCanceledException"/>.
    /// </summary>
    public static async Task<Answer> FetchAsync(
        ITransport transport,
        TimeSpan within,
        string rawUrl,
        IEnumerable<KeyValuePair<string, string>> headers,
        string body,
        CancellationToken cancellationToken)
    {
        var (url, _) = Postable(rawUrl);
        var checkedHeaders = Headers(headers);
        // UTF-8 as fetch sends a string, U+FFFD for a lone surrogate.
        var request = new TransportRequest(url.ToString(), checkedHeaders, Js.Utf8(body));
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(within);
        CancellationToken token = deadline.Token;
        Task<TransportResponse> sent;
        TransportResponse response;
        try
        {
            sent = transport.PostAsync(request, token);
        }
        catch (Exception e) when (e is not OperationCanceledException || !token.IsCancellationRequested)
        {
            throw WithoutUrl(WithoutValues(Describe(e), checkedHeaders), rawUrl, url);
        }
        try
        {
            response = await sent.WaitAsync(token).ConfigureAwait(false) ?? throw new InvalidOperationException("the transport answered nothing");
        }
        catch (Exception e)
        {
            // An answer that arrives after it was given up on is let go of.
            _ = sent.ContinueWith(
                static t =>
                {
                    if (t.Status == TaskStatus.RanToCompletion)
                    {
                        t.Result?.Dispose();
                    }
                },
                CancellationToken.None,
                TaskContinuationOptions.ExecuteSynchronously,
                TaskScheduler.Default);
            cancellationToken.ThrowIfCancellationRequested();
            if (token.IsCancellationRequested)
            {
                throw Fail(TimedOut);
            }
            throw WithoutUrl(WithoutValues(Describe(e), checkedHeaders), rawUrl, url);
        }
        using (response)
        {
            byte[] bytes = await ReadCappedAsync(response, token).ConfigureAwait(false);
            cancellationToken.ThrowIfCancellationRequested();
            return new Answer(response.Status, Text(bytes));
        }
    }

    /// <summary>At most <see cref="MaxBody"/> bytes of the body, or none when it could not be read in time.</summary>
    private static async Task<byte[]> ReadCappedAsync(TransportResponse response, CancellationToken token)
    {
        var chunk = new byte[16 * 1024];
        var output = new ArrayBufferWriter<byte>();
        try
        {
            while (output.WrittenCount < MaxBody)
            {
                int want = Math.Min(chunk.Length, MaxBody - output.WrittenCount);
                int n = await response.Body.ReadAsync(chunk.AsMemory(0, want), token).AsTask().WaitAsync(token).ConfigureAwait(false);
                if (n <= 0)
                {
                    break;
                }
                output.Write(chunk.AsSpan(0, n));
            }
        }
        catch (Exception e) when (e is not OutOfMemoryException)
        {
            // A body the deadline cut short, or one that could not be read, is none.
            return [];
        }
        return output.WrittenSpan.ToArray();
    }

    /// <summary>
    /// A transport's error as one line: its simple type name and message, and each inner
    /// exception's that adds something, as the Rust port writes an error's chain.
    /// </summary>
    public static string Describe(Exception error)
    {
        Exception e = error;
        while (e is AggregateException { InnerExceptions.Count: 1 } a)
        {
            e = a.InnerExceptions[0];
        }
        var b = new StringBuilder();
        int depth = 0;
        for (Exception? t = e; t != null && depth < 5; t = t.InnerException, depth++)
        {
            string message = t.Message ?? "";
            string one = Name(t) + (message.Length == 0 ? "" : ": " + message);
            string sofar = b.ToString();
            if (sofar.Contains(one, StringComparison.Ordinal) || (depth > 0 && message.Length > 0 && sofar.Contains(message, StringComparison.Ordinal)))
            {
                continue;
            }
            if (b.Length > 0)
            {
                b.Append(": ");
            }
            b.Append(one);
        }
        return b.ToString();
    }

    private static string Name(Exception e)
    {
        string name = e.GetType().Name;
        int tick = name.IndexOf('`', StringComparison.Ordinal);
        return tick < 0 ? name : name[..tick];
    }

    /// <summary>The headers whose values say nothing secret, and so are left in a transport's error.</summary>
    private static readonly HashSet<string> PlainHeaders = new(StringComparer.OrdinalIgnoreCase) { "accept", "content-type", "user-agent" };

    /// <summary>
    /// A transport's error with every header value it quotes cut out (a transport of the app's own
    /// may quote a value it refused), bar the few that are never a credential.
    /// </summary>
    public static string WithoutValues(string text, IEnumerable<KeyValuePair<string, string>> headers)
    {
        string output = text;
        foreach (var h in headers)
        {
            if (h.Value.Length >= 4 && !PlainHeaders.Contains(h.Key))
            {
                output = output.Replace(h.Value, "[redacted]", StringComparison.Ordinal);
            }
        }
        return output;
    }

    /// <summary>
    /// <c>&lt;origin&gt;: &lt;text&gt;</c>, with every spelling of the URL in the text written as its
    /// origin and its path and query cut out. No inner exception: its message may quote the URL.
    /// </summary>
    private static CronwatchException WithoutUrl(string text, string raw, WhatwgUrl url)
    {
        string origin = url.Origin;
        string output = text;
        foreach (string s in new[] { Js.Trim(raw), url.ToString() })
        {
            if (s.Length > 0 && s != origin && s != origin + "/")
            {
                output = output.Replace(s, origin, StringComparison.Ordinal);
            }
        }
        string query = url.Query ?? "";
        string decoded = Text(WhatwgUrl.PercentDecodeBytes(url.Path));
        foreach (string s in new[] { url.Target, url.Path, decoded, query })
        {
            if (s.Length > 1)
            {
                output = output.Replace(s, "", StringComparison.Ordinal);
            }
        }
        return Fail(origin + ": " + output);
    }

    /// <summary>At most <paramref name="max"/> UTF-16 code units of text, never half a surrogate pair (shared.ts).</summary>
    public static string Cut(string text, int max)
    {
        if (text.Length <= max)
        {
            return text;
        }
        int end = max;
        if (end > 0 && char.IsHighSurrogate(text[end - 1]))
        {
            end--;
        }
        return text[..end];
    }

    /// <summary>
    /// The start of an error body: every secret of four or more characters cut out of a prefix
    /// long enough to hold one that starts inside the first 200 characters, and only then cut to
    /// that length, so no part of a secret survives at the edge.
    /// </summary>
    public static string ErrorBody(string text, IEnumerable<string?> secrets)
    {
        var kept = new List<string>();
        int longest = 0;
        foreach (string? s in secrets)
        {
            if (s != null && s.Length >= 4)
            {
                kept.Add(s);
                longest = Math.Max(longest, s.Length);
            }
        }
        string head = Cut(text, ErrorBodyMax + longest);
        foreach (string s in kept)
        {
            head = head.Replace(s, "[redacted]", StringComparison.Ordinal);
        }
        return Cut(head, ErrorBodyMax);
    }

    /// <summary>
    /// The error for an answer outside 2xx: <c>&lt;provider&gt; &lt;origin&gt; answered
    /// &lt;status&gt;: &lt;body&gt;</c>, the body's secrets cut out.
    /// </summary>
    public static CronwatchException Refused(string provider, string url, Answer answer, IEnumerable<string?> secrets)
    {
        string tail = answer.Body.Length == 0 ? "" : ": " + ErrorBody(answer.Body, secrets);
        return Fail(provider + " " + Origin(url) + " answered " + answer.Status.ToString(CultureInfo.InvariantCulture) + tail);
    }

    /// <summary><see cref="FetchAsync"/> within <see cref="Timeout"/> that fails on an answer outside 2xx.</summary>
    public static async Task<Answer> SendAsync(
        ITransport transport,
        string provider,
        string url,
        IEnumerable<KeyValuePair<string, string>> headers,
        string body,
        IEnumerable<string?> secrets,
        CancellationToken cancellationToken)
    {
        Answer answer = await FetchAsync(transport, Timeout, url, headers, body, cancellationToken).ConfigureAwait(false);
        if (!answer.Ok)
        {
            throw Refused(provider, url, answer, secrets);
        }
        return answer;
    }
}
