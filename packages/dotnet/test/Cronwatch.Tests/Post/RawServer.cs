using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace Cronwatch.Tests.Posting;

/// <summary>A request a <see cref="RawServer"/> read: its head as sent, byte for byte, and its body.</summary>
internal sealed class Seen
{
    public Seen(string head, byte[] body)
    {
        Head = head;
        Body = body;
        var lines = head.Split("\r\n");
        RequestLine = lines[0];
        var headers = new List<KeyValuePair<string, string>>();
        for (int i = 1; i < lines.Length; i++)
        {
            int colon = lines[i].IndexOf(':', StringComparison.Ordinal);
            if (colon > 0)
            {
                headers.Add(new(lines[i][..colon], lines[i][(colon + 1)..].Trim()));
            }
        }
        Headers = headers;
    }

    /// <summary>The request line and headers, up to the blank line, as sent.</summary>
    public string Head { get; }

    public string RequestLine { get; }

    public IReadOnlyList<KeyValuePair<string, string>> Headers { get; }

    public byte[] Body { get; }

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
}

/// <summary>
/// A local HTTP/1.1 server made of a raw <see cref="TcpListener"/> (and an <see cref="SslStream"/>
/// when given a certificate), so it can misbehave as a test needs: it reads each request's head
/// and its <c>content-length</c> body, records them, and hands the stream to the test's answer,
/// which writes whatever bytes it likes. Each connection answers one request and is closed.
/// </summary>
internal sealed class RawServer : IAsyncDisposable
{
    private readonly TcpListener _listener;
    private readonly Func<Seen, Stream, CancellationToken, Task> _answer;
    private readonly X509Certificate2? _certificate;
    private readonly CancellationTokenSource _stop = new();
    private readonly ConcurrentQueue<Seen> _seen = new();
    private readonly ConcurrentBag<Task> _connections = [];
    private readonly Task _accepting;

    private RawServer(Func<Seen, Stream, CancellationToken, Task> answer, X509Certificate2? certificate)
    {
        _answer = answer;
        _certificate = certificate;
        _listener = new TcpListener(IPAddress.Loopback, 0);
        _listener.Start();
        _accepting = AcceptAsync();
    }

    /// <summary>A plain HTTP server answering with <paramref name="answer"/>.</summary>
    public static RawServer Start(Func<Seen, Stream, CancellationToken, Task> answer) => new(answer, null);

    /// <summary>An HTTPS server presenting <paramref name="certificate"/>.</summary>
    public static RawServer StartTls(X509Certificate2 certificate, Func<Seen, Stream, CancellationToken, Task> answer) => new(answer, certificate);

    /// <summary>An answer of a status, headers, and a body, framed with its length.</summary>
    public static Func<Seen, Stream, CancellationToken, Task> Answer(int status, string body = "", params string[] headers) =>
        async (_, stream, ct) =>
        {
            byte[] bytes = Encoding.UTF8.GetBytes(body);
            var head = new StringBuilder("HTTP/1.1 " + status.ToString(CultureInfo.InvariantCulture) + " X\r\n");
            foreach (string h in headers)
            {
                head.Append(h).Append("\r\n");
            }
            head.Append("content-length: ").Append(bytes.Length.ToString(CultureInfo.InvariantCulture)).Append("\r\nconnection: close\r\n\r\n");
            await stream.WriteAsync(Encoding.ASCII.GetBytes(head.ToString()), ct);
            await stream.WriteAsync(bytes, ct);
            await stream.FlushAsync(ct);
        };

    public int Port => ((IPEndPoint)_listener.LocalEndpoint).Port;

    /// <summary><c>http://127.0.0.1:port</c>, or https for a TLS server.</summary>
    public string Url => (_certificate == null ? "http" : "https") + "://127.0.0.1:" + Port.ToString(CultureInfo.InvariantCulture);

    /// <summary>The requests read so far, in the order they arrived.</summary>
    public IReadOnlyList<Seen> SeenRequests => [.. _seen];

    /// <summary>Waits for every connection's answer to have finished, however it ended.</summary>
    public async Task SettledAsync()
    {
        foreach (Task t in _connections)
        {
            await t.WaitAsync(TimeSpan.FromSeconds(60));
        }
    }

    private async Task AcceptAsync()
    {
        while (!_stop.IsCancellationRequested)
        {
            TcpClient client;
            try
            {
                client = await _listener.AcceptTcpClientAsync(_stop.Token);
            }
            catch (Exception)
            {
                return;
            }
            _connections.Add(Task.Run(() => ServeAsync(client)));
        }
    }

    private async Task ServeAsync(TcpClient client)
    {
        using (client)
        {
            Stream stream = client.GetStream();
            try
            {
                if (_certificate != null)
                {
                    var ssl = new SslStream(stream, false);
                    stream = ssl;
                    await ssl.AuthenticateAsServerAsync(new SslServerAuthenticationOptions { ServerCertificate = _certificate }, _stop.Token);
                }
                Seen? seen = await ReadRequestAsync(stream, _stop.Token);
                if (seen == null)
                {
                    return;
                }
                _seen.Enqueue(seen);
                await _answer(seen, stream, _stop.Token);
            }
            catch (Exception)
            {
                // The client went away, TLS was refused, or the server is stopping: the
                // connection is done either way.
            }
            finally
            {
                await stream.DisposeAsync();
            }
        }
    }

    private static async Task<Seen?> ReadRequestAsync(Stream stream, CancellationToken ct)
    {
        var head = new List<byte>();
        var one = new byte[1];
        while (true)
        {
            int n = await stream.ReadAsync(one, ct);
            if (n == 0)
            {
                return null;
            }
            head.Add(one[0]);
            int c = head.Count;
            if (c >= 4 && head[c - 4] == '\r' && head[c - 3] == '\n' && head[c - 2] == '\r' && head[c - 1] == '\n')
            {
                break;
            }
        }
        string text = Encoding.Latin1.GetString(head.ToArray(), 0, head.Count - 4);
        var seen = new Seen(text, []);
        int length = int.Parse(seen.Header("content-length") ?? "0", CultureInfo.InvariantCulture);
        var body = new byte[length];
        int read = 0;
        while (read < length)
        {
            int n = await stream.ReadAsync(body.AsMemory(read), ct);
            if (n == 0)
            {
                break;
            }
            read += n;
        }
        return new Seen(text, body);
    }

    public async ValueTask DisposeAsync()
    {
        await _stop.CancelAsync();
        _listener.Stop();
        try
        {
            await _accepting.WaitAsync(TimeSpan.FromSeconds(30));
            foreach (Task t in _connections)
            {
                await t.WaitAsync(TimeSpan.FromSeconds(30));
            }
        }
        catch (TimeoutException)
        {
            // A connection that never ends is left to the process.
        }
        _stop.Dispose();
    }
}
