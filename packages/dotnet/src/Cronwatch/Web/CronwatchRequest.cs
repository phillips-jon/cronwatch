using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch.Internal;

namespace Cronwatch.Web;

/// <summary>
/// Reads a request's body when a route wants it: at most <c>limit</c> bytes and one more, so a
/// body past the limit is known without reading the rest. It throws when the body could not be
/// read to its end (the client went away, a read deadline passed); the routes then read the body
/// as none, never as the part that arrived.
/// </summary>
/// <param name="limit">The most the caller needs; reading <c>limit + 1</c> bytes is enough to refuse more.</param>
/// <param name="cancellationToken">The request's token.</param>
public delegate Task<byte[]> WebBodyReader(int limit, CancellationToken cancellationToken);

/// <summary>
/// A request as a server hands it over: the method, the request target as sent (so a <c>%2F</c>
/// in a job name stays one), the headers, a body read only when a route wants it, whether it came
/// over TLS, and where an adapter found the dashboard mounted. What
/// <see cref="Routes.HandleAsync"/> and <see cref="Handler.HandleAsync"/> take, so any framework
/// can be an adapter over them. The body is read once.
/// </summary>
/// <remarks>
/// The target and the headers can carry the dashboard's token or a cron secret, so they have no
/// public getter: read a header with <see cref="Header"/> and the path with <see cref="Path"/>.
/// <see cref="ToString"/> names the method, the path, and the header names, never a value.
/// </remarks>
[DebuggerDisplay("{ToString(),nq}")]
public sealed class CronwatchRequest
{
    /// <summary>
    /// The most of a request body the dashboard reads: its forms and JSON are a few bytes. A body
    /// past it is answered 413; the SDK leaves this to the server in front of it.
    /// </summary>
    public const int MaxBody = 1 << 20;

    private readonly Lock _lock = new();
    private readonly List<KeyValuePair<string, string>> _headers = [];
    private bool _read;
    private byte[]? _body;

    /// <summary>A request with this method and target (the path and query as sent, or the absolute form a proxy is sent).</summary>
    public CronwatchRequest(string method, string target)
    {
        ArgumentNullException.ThrowIfNull(method);
        ArgumentNullException.ThrowIfNull(target);
        Method = method;
        Target = target;
    }

    /// <summary>The method, as sent.</summary>
    public string Method { get; }

    /// <summary>The request target as sent, the query included.</summary>
    public string Target { internal get; init; }

    /// <summary>
    /// The headers, in the order sent, each value as the server read it. A name sent more than
    /// once is read as fetch's <c>Headers.get</c> reads it. Names are matched without regard to
    /// case. <c>Host</c> gives the request's origin.
    /// </summary>
    public IReadOnlyList<KeyValuePair<string, string>> Headers
    {
        internal get => _headers;
        init
        {
            ArgumentNullException.ThrowIfNull(value);
            _headers.Clear();
            _headers.AddRange(value);
        }
    }

    /// <summary>The body, already read.</summary>
    public ReadOnlyMemory<byte> Body
    {
        internal get => _body ?? ReadOnlyMemory<byte>.Empty;
        init
        {
            _body = value.ToArray();
            DeclaredLength = _body.Length;
        }
    }

    /// <summary>Reads the body only when a route wants it, so a request refused for want of the token is never read.</summary>
    public WebBodyReader? BodyReader { internal get; init; }

    /// <summary>The body's declared length (<c>Content-Length</c>), or null when unknown, so a body past the cap is refused unread.</summary>
    public long? DeclaredLength { get; init; }

    /// <summary>Whether the request came over TLS, which makes its origin https.</summary>
    public bool IsTls { get; init; }

    /// <summary>
    /// Where an adapter found the dashboard mounted (<c>PathBase</c> and the route's prefix).
    /// <see cref="RoutesOptions.BasePath"/> wins over it.
    /// </summary>
    public string? Mount { get; init; }

    /// <summary>The path of the target, without its query.</summary>
    public string Path => Requests.Target(Target).Path;

    /// <summary>
    /// A header as fetch's <c>Headers.get</c> gives it: every value of that name joined with
    /// <c>", "</c> (a cookie's with <c>"; "</c>), or null when there is none.
    /// </summary>
    public string? Header(string name)
    {
        ArgumentNullException.ThrowIfNull(name);
        return Requests.Header(_headers, name);
    }

    /// <summary>
    /// Reads the body, once: a second read answers none. A body declared or found to be longer
    /// than <paramref name="limit"/> bytes is refused without reading the rest.
    /// </summary>
    /// <exception cref="WebBodyTooLargeException">Past <paramref name="limit"/>.</exception>
    /// <exception cref="IOException">When the body could not be read to its end (the reader's own exception otherwise).</exception>
    public async Task<byte[]> ReadBodyAsync(int limit = MaxBody, CancellationToken cancellationToken = default)
    {
        lock (_lock)
        {
            if (_read)
            {
                return [];
            }
            _read = true;
        }
        if (DeclaredLength is long declared && declared > limit)
        {
            throw new WebBodyTooLargeException();
        }
        byte[] data;
        if (BodyReader is { } reader)
        {
            data = await reader(limit, cancellationToken).ConfigureAwait(false) ?? [];
        }
        else
        {
            data = _body ?? [];
        }
        if (data.Length > limit)
        {
            throw new WebBodyTooLargeException();
        }
        return data;
    }

    /// <summary>
    /// Names the method, the path, and the header names; the query, every value, and the scheme and
    /// authority of a target in the absolute form (which can carry credentials) are left out.
    /// </summary>
    public override string ToString()
    {
        var (p, query) = Requests.Target(Target);
        string path = query.Length == 0 && Target.IndexOf('?', StringComparison.Ordinal) < 0 ? p : p + "?...";
        var names = new List<string>(_headers.Count);
        foreach (var h in _headers)
        {
            names.Add(h.Key);
        }
        return "CronwatchRequest(" + Method + " " + path + ", headers [" + string.Join(", ", names) + "]" + (IsTls ? ", tls" : "") + ")";
    }
}

/// <summary>A request body longer than the limit it was read with.</summary>
public sealed class WebBodyTooLargeException : IOException
{
    /// <summary>The exception.</summary>
    public WebBodyTooLargeException()
        : base("the request body is too large")
    {
    }

    /// <summary>The exception with a message.</summary>
    public WebBodyTooLargeException(string message)
        : base(message)
    {
    }

    /// <summary>The exception with a message and its cause.</summary>
    public WebBodyTooLargeException(string message, Exception inner)
        : base(message, inner)
    {
    }
}
