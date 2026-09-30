using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch.Internal;

namespace Cronwatch.Alerts;

/// <summary>
/// The default <see cref="ITransport"/>: one <see cref="HttpClient"/> over a
/// <see cref="SocketsHttpHandler"/> that never follows a redirect, uses no proxy (not even
/// <c>HTTPS_PROXY</c>) and no cookies, decompresses nothing and sends no <c>accept-encoding</c>,
/// verifies TLS with the system's trust store and its host name check (a certificate for an IP
/// address checked against the address, never turned off), connects within ten seconds, holds an
/// answer's head to 64 KiB, and closes a connection whose answer was not read to its end rather
/// than draining it (<see cref="SocketsHttpHandler.MaxResponseDrainSize"/> 0). A client makes one
/// when it first sends and disposes it with itself.
/// </summary>
/// <remarks>
/// Headers are added with <c>TryAddWithoutValidation</c>, so their values are sent as given;
/// <c>content-type</c> belongs to the content, and <see cref="HttpClient"/> writes <c>Host</c>
/// first and <c>Content-Length</c> itself, so a header of the names it sets itself (<c>host</c>,
/// <c>content-length</c>, <c>connection</c>, <c>expect</c>, <c>upgrade</c>,
/// <c>transfer-encoding</c>) is dropped, as fetch drops a forbidden header. It sends no
/// <c>User-Agent</c> unless the request names one.
/// </remarks>
public sealed class HttpClientTransport : ITransport, IDisposable
{
    private static readonly HashSet<string> Restricted = new(StringComparer.OrdinalIgnoreCase)
    {
        "connection", "content-length", "expect", "host", "upgrade", "transfer-encoding", "keep-alive", "te", "trailer",
    };

    private readonly HttpClient _client;

    /// <summary>A transport with the system's trust store.</summary>
    public HttpClientTransport()
        : this(null)
    {
    }

    /// <summary>A transport that trusts only <paramref name="root"/>, host names still checked (the tests' own certificates).</summary>
    internal HttpClientTransport(X509Certificate2? root)
    {
        // The client owns the handler (disposeHandler) and disposes it with itself.
#pragma warning disable CA2000
        _client = new HttpClient(Handler(root), disposeHandler: true) { Timeout = System.Threading.Timeout.InfiniteTimeSpan };
#pragma warning restore CA2000
    }

    private static SocketsHttpHandler Handler(X509Certificate2? root)
    {
        var handler = new SocketsHttpHandler
        {
            AllowAutoRedirect = false,
            UseProxy = false,
            UseCookies = false,
            AutomaticDecompression = DecompressionMethods.None,
            MaxResponseDrainSize = 0,
            MaxResponseHeadersLength = 64,
            ConnectTimeout = TimeSpan.FromSeconds(10),
            PooledConnectionLifetime = TimeSpan.FromMinutes(5),
        };
        if (root != null)
        {
            handler.SslOptions = new SslClientAuthenticationOptions
            {
                CertificateChainPolicy = new X509ChainPolicy
                {
                    TrustMode = X509ChainTrustMode.CustomRootTrust,
                    CustomTrustStore = { root },
                    RevocationMode = X509RevocationMode.NoCheck,
                },
            };
        }
        return handler;
    }

    /// <inheritdoc/>
    public async Task<TransportResponse> PostAsync(TransportRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        var (url, uri) = Post.Postable(request.Url);
        _ = url;
        using var message = new HttpRequestMessage(HttpMethod.Post, uri)
        {
            Version = HttpVersion.Version11,
            VersionPolicy = HttpVersionPolicy.RequestVersionExact,
        };
        var content = new ByteArrayContent(request.Body.ToArray());
        content.Headers.ContentType = null;
        message.Content = content;
        foreach (var h in request.Headers)
        {
            if (Restricted.Contains(h.Key))
            {
                continue;
            }
            if (h.Key.StartsWith("content-", StringComparison.OrdinalIgnoreCase))
            {
                if (!content.Headers.TryAddWithoutValidation(h.Key, h.Value))
                {
                    throw new HttpRequestException("the " + h.Key + " header could not be sent");
                }
            }
            else if (!message.Headers.TryAddWithoutValidation(h.Key, h.Value))
            {
                throw new HttpRequestException("the " + h.Key + " header could not be sent");
            }
        }
        HttpResponseMessage response = await _client.SendAsync(message, HttpCompletionOption.ResponseHeadersRead, cancellationToken).ConfigureAwait(false);
        try
        {
            Stream body = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
            return new TransportResponse((int)response.StatusCode, new Owned(body, response));
        }
        catch
        {
            response.Dispose();
            throw;
        }
    }

    /// <summary>Stops the client, cancelling what is in flight. Sends made after this fail.</summary>
    public void Dispose() => _client.Dispose();

    /// <summary>Names the type.</summary>
    public override string ToString() => "HttpClientTransport";

    /// <summary>An answer's body that disposes the answer with itself, which closes an unread connection.</summary>
    private sealed class Owned(Stream inner, HttpResponseMessage owner) : Stream
    {
        public override bool CanRead => true;

        public override bool CanSeek => false;

        public override bool CanWrite => false;

        public override long Length => throw new NotSupportedException();

        public override long Position
        {
            get => throw new NotSupportedException();
            set => throw new NotSupportedException();
        }

        public override int Read(byte[] buffer, int offset, int count) => inner.Read(buffer, offset, count);

        public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default) => inner.ReadAsync(buffer, cancellationToken);

        public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken) =>
            inner.ReadAsync(buffer, offset, count, cancellationToken);

        public override void Flush()
        {
        }

        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();

        public override void SetLength(long value) => throw new NotSupportedException();

        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                inner.Dispose();
                owner.Dispose();
            }
            base.Dispose(disposing);
        }
    }
}
