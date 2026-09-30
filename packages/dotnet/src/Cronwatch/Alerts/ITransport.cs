using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch.Internal;

namespace Cronwatch.Alerts;

/// <summary>
/// Sends one POST and answers its status and body, whatever the status: the one request every
/// channel and Claude triage make. <see cref="HttpClientTransport"/> is the default; an app that
/// wants its <c>IHttpClientFactory</c> client, a proxy or its own trust store writes one and gives
/// it to the client (<see cref="CronwatchOptions.Transport"/>) or to a channel's options.
/// </summary>
/// <remarks>
/// A transport must not follow redirects: a 3xx is an answer like any other, and the channel fails
/// on it, so credential headers never go where it points. The deadline (ten seconds for the whole
/// request) and the answer's cap (1 MiB) are held around the transport whatever it does: the token
/// it is given is cancelled at the deadline, and its body is read a chunk at a time and disposed at
/// the cap. Its exceptions are rewritten so they name only the URL's origin, since a webhook URL's
/// path or query is often its credential.
/// </remarks>
public interface ITransport
{
    /// <summary>
    /// Sends the request and answers once the answer's head has arrived; the body is read from the
    /// response afterwards. Throws when no answer came.
    /// </summary>
    Task<TransportResponse> PostAsync(TransportRequest request, CancellationToken cancellationToken);
}

/// <summary>
/// One POST, as an <see cref="ITransport"/> is asked to send it: an http or https URL as the WHATWG
/// URL parser (and so fetch) writes it, the headers in the order they are sent, and the body. Its
/// <see cref="ToString"/> shows the URL's origin, the header names and the body's length only,
/// since the rest carries the channel's credentials.
/// </summary>
public sealed class TransportRequest
{
    private readonly byte[] _body;

    /// <summary>A request of these parts. The headers and the body are copied.</summary>
    public TransportRequest(string url, IEnumerable<KeyValuePair<string, string>> headers, ReadOnlySpan<byte> body)
    {
        ArgumentNullException.ThrowIfNull(url);
        ArgumentNullException.ThrowIfNull(headers);
        Url = url;
        Headers = headers.ToArray();
        _body = body.ToArray();
    }

    /// <summary>The URL. Its path or query may be a credential: never quote it.</summary>
    public string Url { get; }

    /// <summary>The headers in the order they are sent, names as the SDK writes them.</summary>
    public IReadOnlyList<KeyValuePair<string, string>> Headers { get; }

    /// <summary>The body: UTF-8 (JSON, a form, a Sentry envelope).</summary>
    public ReadOnlyMemory<byte> Body => _body;

    /// <summary>The value of the first header of this name, compared without regard to case, or null.</summary>
    public string? Header(string name)
    {
        foreach (var h in Headers)
        {
            if (string.Equals(h.Key, name, StringComparison.OrdinalIgnoreCase))
            {
                return h.Value;
            }
        }
        return null;
    }

    /// <summary>The URL's origin, the header names and the body's length.</summary>
    public override string ToString() =>
        "TransportRequest(origin " + Post.Origin(Url) + ", headers [" + string.Join(", ", Headers.Select(h => h.Key)) + "], body "
        + _body.Length.ToString(System.Globalization.CultureInfo.InvariantCulture) + " bytes)";
}

/// <summary>
/// An answer to an <see cref="ITransport"/>'s request: its status, and its body as it arrives.
/// Disposing it lets go of what is left of the body (the default transport closes the connection).
/// </summary>
public sealed class TransportResponse : IDisposable
{
    /// <summary>An answer of this status whose body arrives through <paramref name="body"/>, which the answer owns.</summary>
    public TransportResponse(int status, Stream body)
    {
        ArgumentNullException.ThrowIfNull(body);
        Status = status;
        Body = body;
    }

    /// <summary>An answer whose whole body is at hand.</summary>
    public TransportResponse(int status, byte[] body)
        : this(status, new MemoryStream(body ?? throw new ArgumentNullException(nameof(body)), false))
    {
    }

    /// <summary>An answer whose whole body is this text, as UTF-8.</summary>
    public TransportResponse(int status, string body)
        : this(status, Encoding.UTF8.GetBytes(body ?? throw new ArgumentNullException(nameof(body))))
    {
    }

    /// <summary>The status.</summary>
    public int Status { get; }

    /// <summary>The body, read a chunk at a time.</summary>
    public Stream Body { get; }

    /// <summary>Lets go of what is left of the body; a failure doing so is ignored.</summary>
    public void Dispose()
    {
        try
        {
            Body.Dispose();
        }
        catch (Exception e) when (e is IOException or ObjectDisposedException or InvalidOperationException)
        {
            // Nothing is left to read either way.
        }
    }

    /// <summary>The status only.</summary>
    public override string ToString() => "TransportResponse(" + Status.ToString(System.Globalization.CultureInfo.InvariantCulture) + ")";
}
