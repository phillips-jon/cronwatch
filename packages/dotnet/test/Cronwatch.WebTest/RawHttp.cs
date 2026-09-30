using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace Cronwatch.WebTest;

/// <summary>
/// A small HTTP/1.1 client over a socket, for the tests that go through a real server: it sends
/// exactly the headers given (<c>Host</c> included, which <c>HttpClient</c> will not send as a
/// test chooses) and reads the answer as it arrives, with its headers in the order and casing the
/// server wrote them, and a body by length, chunked, or up to the close.
/// </summary>
public static class RawHttp
{
    /// <summary>An answer: the status, the headers in order as written, and the body.</summary>
    public sealed record Answer(int Status, IReadOnlyList<KeyValuePair<string, string>> Headers, byte[] Body)
    {
        /// <summary>The first value of a header, its name matched without regard to case, or null.</summary>
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

        /// <summary>The body as UTF-8.</summary>
        public string Text => Encoding.UTF8.GetString(Body);
    }

    /// <summary>
    /// Sends one request on a connection of its own and reads the answer. <paramref name="headers"/>
    /// are sent as given, after <c>host: app.test</c> when they do not name a host. Header text is
    /// written a byte a character (Latin-1), so a test can send any byte.
    /// </summary>
    public static async Task<Answer> SendAsync(int port, string method, string target, IEnumerable<KeyValuePair<string, string>> headers, byte[]? body, bool close = true)
    {
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(60));
        using var client = new TcpClient();
        await client.ConnectAsync(IPAddress.Loopback, port, cts.Token);
        NetworkStream stream = client.GetStream();
        var head = new StringBuilder();
        head.Append(method).Append(' ').Append(target).Append(" HTTP/1.1\r\n");
        bool host = false;
        var list = new List<KeyValuePair<string, string>>(headers);
        foreach (var h in list)
        {
            host |= string.Equals(h.Key, "host", StringComparison.OrdinalIgnoreCase);
        }
        if (!host)
        {
            head.Append("host: app.test\r\n");
        }
        foreach (var h in list)
        {
            head.Append(h.Key).Append(": ").Append(h.Value).Append("\r\n");
        }
        if (body != null)
        {
            head.Append("content-length: ").Append(body.Length.ToString(CultureInfo.InvariantCulture)).Append("\r\n");
        }
        else if (method != "GET" && method != "HEAD")
        {
            head.Append("content-length: 0\r\n");
        }
        if (close)
        {
            head.Append("connection: close\r\n");
        }
        head.Append("\r\n");
        try
        {
            await stream.WriteAsync(Encoding.Latin1.GetBytes(head.ToString()), cts.Token);
            if (body != null)
            {
                await stream.WriteAsync(body, cts.Token);
            }
            await stream.FlushAsync(cts.Token);
        }
        catch (IOException)
        {
            // A server may answer (a 413) and close before it has read the whole body; its answer
            // is still there to read.
        }
        return await ReadAsync(stream, method == "HEAD", cts.Token);
    }

    /// <summary>Writes raw bytes on a new connection and reads the answer: for a request no well-behaved client would send.</summary>
    public static async Task<Answer> SendRawAsync(int port, byte[] request, bool head = false)
    {
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(60));
        using var client = new TcpClient();
        await client.ConnectAsync(IPAddress.Loopback, port, cts.Token);
        NetworkStream stream = client.GetStream();
        await stream.WriteAsync(request, cts.Token);
        await stream.FlushAsync(cts.Token);
        return await ReadAsync(stream, head, cts.Token);
    }

    private static async Task<int> ByteAsync(Stream s, CancellationToken ct)
    {
        byte[] one = new byte[1];
        int n = await s.ReadAsync(one, ct);
        return n == 0 ? -1 : one[0];
    }

    private static async Task<string> LineAsync(Stream s, CancellationToken ct)
    {
        var b = new List<byte>();
        int c;
        while ((c = await ByteAsync(s, ct)) != -1)
        {
            if (c == '\n')
            {
                break;
            }
            if (c != '\r')
            {
                b.Add((byte)c);
            }
        }
        return Encoding.Latin1.GetString(b.ToArray());
    }

    private static async Task<byte[]> ExactlyAsync(Stream s, int n, CancellationToken ct)
    {
        byte[] b = new byte[n];
        await s.ReadExactlyAsync(b, ct);
        return b;
    }

    private static async Task<Answer> ReadAsync(Stream s, bool head, CancellationToken ct)
    {
        string status = await LineAsync(s, ct);
        while (status.StartsWith("HTTP/1.1 1", StringComparison.Ordinal))
        {
            // An interim answer: skip it and its headers.
            while ((await LineAsync(s, ct)).Length > 0)
            {
            }
            status = await LineAsync(s, ct);
        }
        string[] parts = status.Split(' ', 3);
        int code = int.Parse(parts[1], CultureInfo.InvariantCulture);
        var headers = new List<KeyValuePair<string, string>>();
        long length = -1;
        bool chunked = false;
        for (string l = await LineAsync(s, ct); l.Length > 0; l = await LineAsync(s, ct))
        {
            int colon = l.IndexOf(':', StringComparison.Ordinal);
            string name = l[..colon].Trim();
            string value = l[(colon + 1)..].Trim();
            headers.Add(new(name, value));
            if (string.Equals(name, "content-length", StringComparison.OrdinalIgnoreCase))
            {
                length = long.Parse(value, CultureInfo.InvariantCulture);
            }
            else if (string.Equals(name, "transfer-encoding", StringComparison.OrdinalIgnoreCase) && string.Equals(value, "chunked", StringComparison.OrdinalIgnoreCase))
            {
                chunked = true;
            }
        }
        byte[] body;
        if (head || code == 204 || code == 304)
        {
            body = [];
        }
        else if (chunked)
        {
            var b = new MemoryStream();
            while (true)
            {
                string size = await LineAsync(s, ct);
                int semi = size.IndexOf(';', StringComparison.Ordinal);
                int n = int.Parse((semi < 0 ? size : size[..semi]).Trim(), NumberStyles.HexNumber, CultureInfo.InvariantCulture);
                if (n == 0)
                {
                    while ((await LineAsync(s, ct)).Length > 0)
                    {
                    }
                    break;
                }
                byte[] chunk = await ExactlyAsync(s, n, ct);
                await b.WriteAsync(chunk, ct);
                await LineAsync(s, ct);
            }
            body = b.ToArray();
        }
        else if (length >= 0)
        {
            body = await ExactlyAsync(s, (int)length, ct);
        }
        else
        {
            var b = new MemoryStream();
            await s.CopyToAsync(b, ct);
            body = b.ToArray();
        }
        return new Answer(code, headers, body);
    }
}
