using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch.Alerts;
using Xunit;
using P = Cronwatch.Internal.Post;

namespace Cronwatch.Tests.Posting;

/// <summary>
/// The POST every channel and triage make, against real local servers: redirects answered and
/// never followed, one deadline, bodies capped as they arrive in every framing, nothing
/// decompressed, only the origin in an error, TLS verified, and the bytes .NET puts on the wire.
/// Each confirms one of DESIGN.md's answers about <see cref="SocketsHttpHandler"/>.
/// </summary>
public class PostHardeningTests
{
    private static readonly TimeSpan Short = TimeSpan.FromMilliseconds(300);
    private static readonly TimeSpan Plenty = TimeSpan.FromSeconds(30);
    private static readonly KeyValuePair<string, string>[] Json = [new("content-type", "application/json")];

    private static Task<P.Answer> FetchAsync(ITransport t, string url, TimeSpan? within = null, IEnumerable<KeyValuePair<string, string>>? headers = null, string body = "{}") =>
        P.FetchAsync(t, within ?? Plenty, url, headers ?? Json, body, CancellationToken.None);

    [Fact]
    public async Task A_redirect_is_an_answer_and_is_never_followed()
    {
        await using var evil = RawServer.Start(RawServer.Answer(202));
        await using var provider = RawServer.Start(RawServer.Answer(307, "", "location: " + evil.Url + "/steal"));
        using var transport = new HttpClientTransport();
        var answer = await FetchAsync(transport, provider.Url + "/in", headers: [new("authorization", "Bearer not-a-real-token")]);
        Assert.Equal(307, answer.Status);
        var e = await Assert.ThrowsAsync<CronwatchException>(() =>
            P.SendAsync(transport, "Webhook", provider.Url + "/in/path-secret", Json, "{}", [], CancellationToken.None));
        Assert.Equal("Webhook " + provider.Url + " answered 307", e.Message);
        Assert.Empty(evil.SeenRequests);
        Assert.Equal(2, provider.SeenRequests.Count);
        Assert.Equal("Bearer not-a-real-token", provider.SeenRequests[0].Header("authorization"));
    }

    [Fact]
    public async Task One_deadline_before_the_answer_and_while_the_body_arrives()
    {
        Assert.Equal(TimeSpan.FromSeconds(10), P.DefaultTimeout);
        await using var hang = RawServer.Start(async (_, _, ct) => await Task.Delay(Timeout.Infinite, ct));
        await using var drip = RawServer.Start(async (_, s, ct) =>
        {
            await s.WriteAsync("HTTP/1.1 500 X\r\ncontent-length: 100\r\n\r\nx"u8.ToArray(), ct);
            await s.FlushAsync(ct);
            await Task.Delay(Timeout.Infinite, ct);
        });
        using var transport = new HttpClientTransport();
        var e = await Assert.ThrowsAsync<CronwatchException>(() => FetchAsync(transport, hang.Url + "/T/B/path-secret", Short));
        Assert.Equal(P.TimedOut, e.Message);

        // An answer whose body is still arriving at the deadline is the answer with no body.
        var answer = await FetchAsync(transport, drip.Url, Short);
        Assert.Equal(500, answer.Status);
        Assert.Equal("", answer.Body);
        Assert.Equal("Rollbar https://api.rollbar.com answered 500", P.Refused("Rollbar", "https://api.rollbar.com/api/1/item/", answer, []).Message);
    }

    [Fact]
    public async Task A_transport_that_ignores_its_token_is_held_to_the_deadline()
    {
        var never = new TaskCompletionSource<TransportResponse>(TaskCreationOptions.RunContinuationsAsynchronously);
        var e = await Assert.ThrowsAsync<CronwatchException>(() => FetchAsync(new FuncTransport((_, _) => never.Task), "https://hooks.example.com/in", Short));
        Assert.Equal(P.TimedOut, e.Message);

        // A body that never answers a read, token or not, is let go of at the deadline, and disposed.
        var body = new StuckStream();
        var answer = await FetchAsync(new FuncTransport((_, _) => Task.FromResult(new TransportResponse(200, body))), "https://hooks.example.com/in", Short);
        Assert.Equal(200, answer.Status);
        Assert.Equal("", answer.Body);
        Assert.True(body.Disposed);

        // An answer that arrives after it was given up on is disposed too.
        var late = new StuckStream();
        e = await Assert.ThrowsAsync<CronwatchException>(() => FetchAsync(new FuncTransport((_, _) => never.Task), "https://hooks.example.com/in", Short));
        never.SetResult(new TransportResponse(200, late));
        await WaitUntilAsync(() => late.Disposed);
    }

    [Fact]
    public async Task The_callers_own_token_cancels_as_a_cancellation_not_a_timeout()
    {
        using var cts = new CancellationTokenSource();
        var never = new TaskCompletionSource<TransportResponse>();
        Task<P.Answer> fetch = P.FetchAsync(new FuncTransport((_, _) => never.Task), Plenty, "https://hooks.example.com/in", Json, "{}", cts.Token);
        await cts.CancelAsync();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => fetch);
    }

    public static TheoryData<string> Framings => new() { "content-length", "chunked", "close" };

    [Theory]
    [MemberData(nameof(Framings))]
    public async Task An_answer_is_read_to_one_mebibyte_as_it_arrives_whatever_its_framing(string framing)
    {
        const int total = P.MaxBody + (8 << 20);
        bool wroteAll = false;
        await using var server = RawServer.Start(async (_, s, ct) =>
        {
            string head = framing switch
            {
                "content-length" => "HTTP/1.1 500 X\r\ncontent-length: " + total.ToString(CultureInfo.InvariantCulture) + "\r\n\r\n",
                "chunked" => "HTTP/1.1 500 X\r\ntransfer-encoding: chunked\r\n\r\n",
                _ => "HTTP/1.1 500 X\r\nconnection: close\r\n\r\n",
            };
            await s.WriteAsync(Encoding.ASCII.GetBytes(head), ct);
            var block = new byte[64 * 1024];
            Array.Fill(block, (byte)'a');
            for (int sent = 0; sent < total; sent += block.Length)
            {
                if (framing == "chunked")
                {
                    await s.WriteAsync(Encoding.ASCII.GetBytes(block.Length.ToString("x", CultureInfo.InvariantCulture) + "\r\n"), ct);
                    await s.WriteAsync(block, ct);
                    await s.WriteAsync("\r\n"u8.ToArray(), ct);
                }
                else
                {
                    await s.WriteAsync(block, ct);
                }
            }
            if (framing == "chunked")
            {
                await s.WriteAsync("0\r\n\r\n"u8.ToArray(), ct);
            }
            await s.FlushAsync(ct);
            wroteAll = true;
        });
        using var transport = new HttpClientTransport();
        var answer = await FetchAsync(transport, server.Url);
        Assert.Equal(500, answer.Status);
        Assert.Equal(P.MaxBody, answer.Body.Length);
        // The answer was disposed at the cap, which closed the connection rather than draining it:
        // the server could not write the rest.
        await server.SettledAsync();
        Assert.False(wroteAll, framing + ": the connection was drained past the cap");
    }

    [Fact]
    public async Task A_gzip_answer_is_read_as_its_compressed_bytes()
    {
        // 64 MiB of zeros, gzipped: nothing asks for an encoding or decodes one, so what is read
        // is the compressed bytes, never the 64 MiB.
        byte[] gzipped;
        using (var buffer = new MemoryStream())
        {
            using (var gz = new GZipStream(buffer, CompressionLevel.SmallestSize, leaveOpen: true))
            {
                var zeros = new byte[1 << 20];
                for (int i = 0; i < 64; i++)
                {
                    gz.Write(zeros);
                }
            }
            gzipped = buffer.ToArray();
        }
        await using var server = RawServer.Start(async (_, s, ct) =>
        {
            await s.WriteAsync(Encoding.ASCII.GetBytes("HTTP/1.1 500 X\r\ncontent-encoding: gzip\r\ncontent-length: " + gzipped.Length.ToString(CultureInfo.InvariantCulture) + "\r\n\r\n"), ct);
            await s.WriteAsync(gzipped, ct);
        });
        using var transport = new HttpClientTransport();
        var answer = await FetchAsync(transport, server.Url);
        Assert.Equal(500, answer.Status);
        Assert.StartsWith("\u001f�", answer.Body, StringComparison.Ordinal);
        Assert.True(answer.Body.Length < gzipped.Length + 1, "the answer was decompressed");
        Assert.Null(server.SeenRequests[0].Header("accept-encoding"));
        string err = P.Refused("Rollbar", "https://api.rollbar.com/x", answer, []).Message;
        Assert.True(err.Length <= "Rollbar https://api.rollbar.com answered 500: ".Length + 200, err);
    }

    [Fact]
    public async Task A_url_or_header_that_cannot_be_sent_is_refused_before_anything_is_sent_never_quoted()
    {
        await using var server = RawServer.Start(RawServer.Answer(200));
        using var transport = new HttpClientTransport();
        const string secretPath = "services/T0/B0/not-a-real-path-token";
        string port = server.Port.ToString(CultureInfo.InvariantCulture);
        foreach (var (url, tail) in new[]
        {
            ("ftp://hooks.example.com/" + secretPath, "ftp:"),
            ("javascript:alert('" + secretPath + "')", "javascript:"),
            ("https://user:pw@127.0.0.1:" + port + "/" + secretPath, "this URL"),
            ("https://127.0.0.1:99999/" + secretPath, "this URL"),
            ("https://[fe80::1%25eth0]:" + port + "/" + secretPath, "this URL"),
            ("https://bücher.example/" + secretPath, "this URL"),
        })
        {
            var e = await Assert.ThrowsAsync<CronwatchException>(() => FetchAsync(transport, url));
            Assert.Equal("only http and https URLs can be posted to, not " + tail, e.Message);
        }
        foreach (string bad in new[] { "Bearer not-a-real\r\nx-evil: 1", "Bearer not\na-real", "Bearer not\0a-real" })
        {
            var e = await Assert.ThrowsAsync<CronwatchException>(() => FetchAsync(transport, server.Url + "/in", headers: [new("authorization", "x " + bad)]));
            Assert.Equal("the authorization header's value may not contain a line break", e.Message);
        }
        Assert.Empty(server.SeenRequests);

        // A stray newline or space around a pasted URL, or a tab inside it, is dropped, as fetch
        // drops it; a space inside is encoded, and the path and query go as WHATWG wrote them.
        await FetchAsync(transport, "  " + server.Url + "/a\tb c|d?e={f}%zz\n");
        Assert.Equal("POST /ab%20c|d?e={f}%zz HTTP/1.1", server.SeenRequests[0].RequestLine);
    }

    [Fact]
    public async Task An_error_names_only_the_origin()
    {
        using var transport = new HttpClientTransport();
        const string secret = "not-a-real-secret-token";
        // Nothing listens on port 1: .NET's own error is kept, the URL's path and query are not.
        var e = await Assert.ThrowsAsync<CronwatchException>(() => FetchAsync(transport, "http://127.0.0.1:1/hooks/" + secret + "?token=" + secret));
        Assert.StartsWith("http://127.0.0.1:1: HttpRequestException", e.Message, StringComparison.Ordinal);
        Assert.DoesNotContain(secret, e.Message, StringComparison.Ordinal);
        Assert.Null(e.InnerException);

        // A transport of the app's own that quotes the URL, whole or decoded, and a header's value.
        string url = "https://hooks.example.com/services/" + secret + "%20x?token=" + secret;
        var quoting = new FuncTransport((request, _) => throw new InvalidOperationException(
            "failed " + request.Url + " (" + Uri.UnescapeDataString(new Uri(request.Url).AbsolutePath) + ") with " + request.Header("x-api-key") + " as " + request.Header("content-type")));
        e = await Assert.ThrowsAsync<CronwatchException>(() => FetchAsync(quoting, url, headers: [new("x-api-key", "not-a-real-key"), new("content-type", "text/plain")]));
        Assert.Equal("https://hooks.example.com: InvalidOperationException: failed https://hooks.example.com () with [redacted] as text/plain", e.Message);

        // A transport that throws before it returns a task is rewritten the same way.
        var eager = new FuncTransport((request, _) => throw new IOException("at " + request.Url));
        e = await Assert.ThrowsAsync<CronwatchException>(() => FetchAsync(eager, url));
        Assert.Equal("https://hooks.example.com: IOException: at https://hooks.example.com", e.Message);
    }

    [Fact]
    public async Task Tls_is_verified_for_a_name_and_for_an_address()
    {
        using var ca = new TestCertificates();
        using X509Leaf good = new(ca.Leaf(["localhost"], [IPAddress.Loopback]));
        await using var server = RawServer.StartTls(good.Certificate, RawServer.Answer(200, "ok"));
        using var trusting = new HttpClientTransport(ca.Root);
        string port = server.Port.ToString(CultureInfo.InvariantCulture);
        Assert.Equal("ok", (await FetchAsync(trusting, "https://127.0.0.1:" + port + "/by-address")).Body);
        Assert.Equal("ok", (await FetchAsync(trusting, "https://localhost:" + port + "/by-name")).Body);

        // The system's trust store does not know the root: refused, the path never quoted.
        using var system = new HttpClientTransport();
        var e = await Assert.ThrowsAsync<CronwatchException>(() => FetchAsync(system, "https://127.0.0.1:" + port + "/path-secret"));
        Assert.StartsWith("https://127.0.0.1:" + port + ": HttpRequestException", e.Message, StringComparison.Ordinal);
        Assert.DoesNotContain("path-secret", e.Message, StringComparison.Ordinal);

        // A trusted certificate for another name and address is refused at this one: the host
        // check runs for an address too (.NET sends no SNI for one and checks all the same).
        using X509Leaf other = new(ca.Leaf(["other.example"], [IPAddress.Parse("10.9.9.9")]));
        await using var wrong = RawServer.StartTls(other.Certificate, RawServer.Answer(200, "ok"));
        string wrongPort = wrong.Port.ToString(CultureInfo.InvariantCulture);
        foreach (string url in new[] { "https://127.0.0.1:" + wrongPort + "/x", "https://localhost:" + wrongPort + "/x" })
        {
            e = await Assert.ThrowsAsync<CronwatchException>(() => FetchAsync(trusting, url));
            Assert.Contains("HttpRequestException", e.Message, StringComparison.Ordinal);
        }
        Assert.Single(server.SeenRequests, s => s.RequestLine.Contains("/by-address", StringComparison.Ordinal));
        Assert.Empty(wrong.SeenRequests);
    }

    [Fact]
    public async Task The_bytes_the_default_transport_sends()
    {
        await using var server = RawServer.Start(RawServer.Answer(200));
        using var transport = new HttpClientTransport();
        await FetchAsync(transport, server.Url + "/p/a%2Fth?q=1&r=a b", headers:
        [
            new("content-type", "application/json"),
            new("authorization", "Bearer not-a-real-token"),
            new("x-b", "2"),
            new("X-A", "1"),
            new("host", "elsewhere.example"),
            new("content-length", "99"),
            new("connection", "keep-alive"),
        ], body: "{\"a\":1}");
        var seen = server.SeenRequests[0];
        // HttpClient writes Host first, then the request's headers in the order given, then the
        // content's, then Content-Length. A header it knows (authorization, content-type) is
        // written in its own casing, any other as given; host, content-length and connection
        // given by the request are dropped, and nothing is added (no User-Agent, no
        // Accept-Encoding).
        Assert.Equal(
            "POST /p/a%2Fth?q=1&r=a%20b HTTP/1.1\r\n"
            + "Host: 127.0.0.1:" + server.Port.ToString(CultureInfo.InvariantCulture) + "\r\n"
            + "Authorization: Bearer not-a-real-token\r\n"
            + "x-b: 2\r\n"
            + "X-A: 1\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: 7",
            seen.Head);
        Assert.Equal("{\"a\":1}", Encoding.UTF8.GetString(seen.Body));

        // A value outside ASCII (a credential pasted with a stray character) is refused by .NET,
        // naming neither the value nor the URL's path.
        var e = await Assert.ThrowsAsync<CronwatchException>(() => FetchAsync(transport, server.Url + "/path-secret", headers: [new("x-api-key", "not-a-real-kéyĀ")]));
        Assert.StartsWith(server.Url + ": HttpRequestException", e.Message, StringComparison.Ordinal);
        Assert.DoesNotContain("not-a-real", e.Message, StringComparison.Ordinal);
        Assert.DoesNotContain("path-secret", e.Message, StringComparison.Ordinal);
        Assert.Single(server.SeenRequests);

        // A user agent is sent only when the request names one.
        await FetchAsync(transport, server.Url, headers: [new("user-agent", "cronwatch-dotnet/test")]);
        Assert.Equal("cronwatch-dotnet/test", server.SeenRequests[1].Header("user-agent"));
    }

    [Fact]
    public async Task A_lone_surrogate_goes_out_as_the_replacement_character()
    {
        await using var server = RawServer.Start(RawServer.Answer(200));
        using var transport = new HttpClientTransport();
        await FetchAsync(transport, server.Url, body: "a\ud800b");
        Assert.Equal([(byte)'a', 0xEF, 0xBF, 0xBD, (byte)'b'], server.SeenRequests[0].Body);
    }

    [Fact]
    public async Task A_secret_straddling_the_cut_of_a_quoted_answer_is_cut_out()
    {
        const string secret = "not-a-real-secret-0123456789";
        await using var server = RawServer.Start(RawServer.Answer(400, new string('e', 190) + secret + " more"));
        using var transport = new HttpClientTransport();
        var e = await Assert.ThrowsAsync<CronwatchException>(() => P.SendAsync(transport, "Slack", server.Url + "/hook", Json, "{}", [secret], CancellationToken.None));
        Assert.Equal("Slack " + server.Url + " answered 400: " + new string('e', 190) + "[redacted]", e.Message);
    }

    private static async Task WaitUntilAsync(Func<bool> done)
    {
        for (int i = 0; i < 600 && !done(); i++)
        {
            await Task.Delay(50);
        }
        Assert.True(done());
    }

    /// <summary>A transport made of a function, as an app's own would be.</summary>
    internal sealed class FuncTransport(Func<TransportRequest, CancellationToken, Task<TransportResponse>> post) : ITransport
    {
        public Task<TransportResponse> PostAsync(TransportRequest request, CancellationToken cancellationToken) => post(request, cancellationToken);
    }

    /// <summary>A body whose reads never complete, whatever their token says.</summary>
    private sealed class StuckStream : Stream
    {
        private readonly TaskCompletionSource<int> _never = new();

        public bool Disposed { get; private set; }

        public override bool CanRead => true;

        public override bool CanSeek => false;

        public override bool CanWrite => false;

        public override long Length => throw new NotSupportedException();

        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }

        public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default) => new(_never.Task);

        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();

        public override void Flush()
        {
        }

        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();

        public override void SetLength(long value) => throw new NotSupportedException();

        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();

        protected override void Dispose(bool disposing)
        {
            Disposed = true;
            base.Dispose(disposing);
        }
    }

    /// <summary>A server certificate, disposed with the test.</summary>
    private sealed class X509Leaf(System.Security.Cryptography.X509Certificates.X509Certificate2 certificate) : IDisposable
    {
        public System.Security.Cryptography.X509Certificates.X509Certificate2 Certificate { get; } = certificate;

        public void Dispose() => Certificate.Dispose();
    }
}
