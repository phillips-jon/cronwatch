using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Text;
using Cronwatch.Internal;

namespace Cronwatch.Web;

/// <summary>
/// An answer: a status, headers in order (names lowercase, as fetch and HTTP/2 write them), and a
/// body. Immutable; <see cref="WithHeader"/> and <see cref="WithBody(byte[])"/> give copies. An
/// adapter writes it with its <c>content-length</c>. A job's handler function may return one,
/// which is then the handler's answer, and fails the run at 400 or more.
/// </summary>
[DebuggerDisplay("{ToString(),nq}")]
public sealed class CronwatchResponse
{
    private readonly KeyValuePair<string, string>[] _headers;
    private readonly byte[] _body;

    private CronwatchResponse(int status, KeyValuePair<string, string>[] headers, byte[] body, object? result)
    {
        Status = status;
        _headers = headers;
        _body = body;
        Result = result;
    }

    /// <summary>An answer with this status, no headers, and no body.</summary>
    public CronwatchResponse(int status)
        : this(status, [], [], null)
    {
    }

    /// <summary>
    /// An answer a framework writes itself, carried through a job's handler: <paramref name="result"/>
    /// is the framework's own (an ASP.NET Core <c>IResult</c>), and <paramref name="status"/> is the
    /// status it answers with, which fails the run at 400 or more.
    /// </summary>
    public static CronwatchResponse Carrying(object result, int status)
    {
        ArgumentNullException.ThrowIfNull(result);
        return new CronwatchResponse(status, [], [], result);
    }

    /// <summary>The status.</summary>
    public int Status { get; }

    /// <summary>The framework's own answer this carries, or null (see <see cref="Carrying"/>).</summary>
    public object? Result { get; }

    /// <summary>The headers, in order, names lowercase.</summary>
    public IReadOnlyList<KeyValuePair<string, string>> Headers => _headers;

    /// <summary>The body.</summary>
    public ReadOnlyMemory<byte> Body => _body;

    /// <summary>A copy with a header added, its name lowercased.</summary>
    public CronwatchResponse WithHeader(string name, string value)
    {
        ArgumentNullException.ThrowIfNull(name);
        ArgumentNullException.ThrowIfNull(value);
        var headers = new KeyValuePair<string, string>[_headers.Length + 1];
        _headers.CopyTo(headers, 0);
        headers[^1] = new(name.ToLowerInvariant(), value);
        return new CronwatchResponse(Status, headers, _body, Result);
    }

    /// <summary>A copy with this body.</summary>
    public CronwatchResponse WithBody(byte[] body)
    {
        ArgumentNullException.ThrowIfNull(body);
        return new CronwatchResponse(Status, _headers, (byte[])body.Clone(), Result);
    }

    /// <summary>A copy with this body, written as UTF-8.</summary>
    public CronwatchResponse WithBody(string body)
    {
        ArgumentNullException.ThrowIfNull(body);
        return new CronwatchResponse(Status, _headers, Js.Utf8(body), Result);
    }

    internal CronwatchResponse WithOwnedBody(byte[] body) => new(Status, _headers, body, Result);

    /// <summary>The first value of a header, its name matched without regard to case, or null.</summary>
    public string? Header(string name)
    {
        ArgumentNullException.ThrowIfNull(name);
        foreach (var h in _headers)
        {
            if (string.Equals(h.Key, name, StringComparison.OrdinalIgnoreCase))
            {
                return h.Value;
            }
        }
        return null;
    }

    /// <summary>The body as text, with anything not UTF-8 replaced.</summary>
    public string Text() => Encoding.UTF8.GetString(_body);

    /// <summary>Names the status and the header names; the body and the header values are left out.</summary>
    public override string ToString()
    {
        var names = new List<string>(_headers.Length);
        foreach (var h in _headers)
        {
            names.Add(h.Key);
        }
        return "CronwatchResponse(" + Status + ", headers [" + string.Join(", ", names) + "], " + _body.Length + " bytes)";
    }
}
