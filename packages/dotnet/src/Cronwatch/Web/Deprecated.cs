using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Threading;
using System.Threading.Tasks;

namespace Cronwatch.Web;

/// <summary>
/// <see cref="CronwatchRequest"/>, under its former name, which <c>System.Net</c>'s obsolete
/// <c>WebRequest</c> shares. It converts to a <see cref="CronwatchRequest"/> wherever one is
/// taken, and from one.
/// </summary>
[Obsolete("Renamed CronwatchRequest, since System.Net has a WebRequest of its own. This name still works through 1.x and goes in 2.0.")]
[DebuggerDisplay("{ToString(),nq}")]
public sealed class WebRequest
{
    /// <summary>The most of a request body the dashboard reads (<see cref="CronwatchRequest.MaxBody"/>).</summary>
    public const int MaxBody = CronwatchRequest.MaxBody;

    private readonly Lock _lock = new();
    private readonly string _target;
    private IReadOnlyList<KeyValuePair<string, string>> _headers = [];
    private byte[]? _body;
    private CronwatchRequest? _request;

    /// <summary>A request with this method and target (<see cref="CronwatchRequest(string, string)"/>).</summary>
    public WebRequest(string method, string target)
    {
        ArgumentNullException.ThrowIfNull(method);
        ArgumentNullException.ThrowIfNull(target);
        Method = method;
        _target = target;
    }

    private WebRequest(CronwatchRequest request)
    {
        Method = request.Method;
        _target = request.Target;
        _request = request;
    }

    /// <summary>The method, as sent.</summary>
    public string Method { get; }

    /// <summary>The request target as sent (<see cref="CronwatchRequest.Target"/>).</summary>
    public string Target { internal get => _target; init => _target = value ?? throw new ArgumentNullException(nameof(value)); }

    /// <summary>The headers, in the order sent (<see cref="CronwatchRequest.Headers"/>).</summary>
    public IReadOnlyList<KeyValuePair<string, string>> Headers
    {
        internal get => _headers;
        init => _headers = value ?? throw new ArgumentNullException(nameof(value));
    }

    /// <summary>The body, already read (<see cref="CronwatchRequest.Body"/>).</summary>
    public ReadOnlyMemory<byte> Body
    {
        internal get => _body ?? ReadOnlyMemory<byte>.Empty;
        init
        {
            _body = value.ToArray();
            DeclaredLength = _body.Length;
        }
    }

    /// <summary>Reads the body only when a route wants it (<see cref="CronwatchRequest.BodyReader"/>).</summary>
    public WebBodyReader? BodyReader { internal get; init; }

    /// <summary>The body's declared length, or null when unknown.</summary>
    public long? DeclaredLength { get; init; }

    /// <summary>Whether the request came over TLS.</summary>
    public bool IsTls { get; init; }

    /// <summary>Where an adapter found the dashboard mounted.</summary>
    public string? Mount { get; init; }

    /// <summary>The path of the target, without its query.</summary>
    public string Path => Request.Path;

    /// <summary>The request this stands for, made once.</summary>
    private CronwatchRequest Request
    {
        get
        {
            lock (_lock)
            {
                _request ??= _body != null
                    ? new CronwatchRequest(Method, _target)
                    {
                        Headers = _headers,
                        Body = _body,
                        BodyReader = BodyReader,
                        DeclaredLength = DeclaredLength,
                        IsTls = IsTls,
                        Mount = Mount,
                    }
                    : new CronwatchRequest(Method, _target)
                    {
                        Headers = _headers,
                        BodyReader = BodyReader,
                        DeclaredLength = DeclaredLength,
                        IsTls = IsTls,
                        Mount = Mount,
                    };
                return _request;
            }
        }
    }

    /// <summary>A header as fetch's <c>Headers.get</c> gives it (<see cref="CronwatchRequest.Header"/>).</summary>
    public string? Header(string name) => Request.Header(name);

    /// <summary>Reads the body, once (<see cref="CronwatchRequest.ReadBodyAsync"/>).</summary>
    /// <exception cref="WebBodyTooLargeException">Past <paramref name="limit"/>.</exception>
    public Task<byte[]> ReadBodyAsync(int limit = MaxBody, CancellationToken cancellationToken = default) =>
        Request.ReadBodyAsync(limit, cancellationToken);

    /// <summary>The request as a <see cref="CronwatchRequest"/>.</summary>
    public static implicit operator CronwatchRequest(WebRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        return request.Request;
    }

    /// <summary>A <see cref="CronwatchRequest"/> under the former name.</summary>
    public static implicit operator WebRequest(CronwatchRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        return new WebRequest(request);
    }

    /// <summary>The request as a <see cref="CronwatchRequest"/>.</summary>
    public CronwatchRequest ToCronwatchRequest() => Request;

    /// <summary>A <see cref="CronwatchRequest"/> under the former name.</summary>
    public static WebRequest FromCronwatchRequest(CronwatchRequest request) => request;

    /// <summary>Names the method, the path and the header names, never a value.</summary>
    public override string ToString() => Request.ToString();
}

/// <summary>
/// <see cref="CronwatchResponse"/>, under its former name, which <c>System.Net</c>'s obsolete
/// <c>WebResponse</c> shares. It converts to a <see cref="CronwatchResponse"/> and from one, so
/// <c>WebResponse answer = await routes.HandleAsync(request)</c> still compiles, and a handler's
/// function may still return one.
/// </summary>
[Obsolete("Renamed CronwatchResponse, since System.Net has a WebResponse of its own. This name still works through 1.x and goes in 2.0.")]
[DebuggerDisplay("{ToString(),nq}")]
public sealed class WebResponse
{
    private readonly CronwatchResponse _response;

    private WebResponse(CronwatchResponse response)
    {
        _response = response;
    }

    /// <summary>An answer with this status, no headers and no body.</summary>
    public WebResponse(int status)
        : this(new CronwatchResponse(status))
    {
    }

    /// <summary>An answer a framework writes itself (<see cref="CronwatchResponse.Carrying"/>).</summary>
    public static WebResponse Carrying(object result, int status) => new(CronwatchResponse.Carrying(result, status));

    /// <summary>The status.</summary>
    public int Status => _response.Status;

    /// <summary>The framework's own answer this carries, or null.</summary>
    public object? Result => _response.Result;

    /// <summary>The headers, in order, names lowercase.</summary>
    public IReadOnlyList<KeyValuePair<string, string>> Headers => _response.Headers;

    /// <summary>The body.</summary>
    public ReadOnlyMemory<byte> Body => _response.Body;

    /// <summary>A copy with a header added, its name lowercased.</summary>
    public WebResponse WithHeader(string name, string value) => new(_response.WithHeader(name, value));

    /// <summary>A copy with this body.</summary>
    public WebResponse WithBody(byte[] body) => new(_response.WithBody(body));

    /// <summary>A copy with this body, written as UTF-8.</summary>
    public WebResponse WithBody(string body) => new(_response.WithBody(body));

    /// <summary>The first value of a header, its name matched without regard to case, or null.</summary>
    public string? Header(string name) => _response.Header(name);

    /// <summary>The body as text, with anything not UTF-8 replaced.</summary>
    public string Text() => _response.Text();

    /// <summary>The answer as a <see cref="CronwatchResponse"/>.</summary>
    public static implicit operator CronwatchResponse(WebResponse response)
    {
        ArgumentNullException.ThrowIfNull(response);
        return response._response;
    }

    /// <summary>A <see cref="CronwatchResponse"/> under the former name.</summary>
    public static implicit operator WebResponse(CronwatchResponse response)
    {
        ArgumentNullException.ThrowIfNull(response);
        return new WebResponse(response);
    }

    /// <summary>The answer as a <see cref="CronwatchResponse"/>.</summary>
    public CronwatchResponse ToCronwatchResponse() => _response;

    /// <summary>A <see cref="CronwatchResponse"/> under the former name.</summary>
    public static WebResponse FromCronwatchResponse(CronwatchResponse response) => response;

    /// <summary>Names the status and the header names; the body and the header values are left out.</summary>
    public override string ToString() => _response.ToString();
}

/// <summary><see cref="Adapters"/>, under its former name.</summary>
[Obsolete("Renamed Adapters, as the Java port names it. This name still works through 1.x and goes in 2.0.")]
public static class WebAdapters
{
    /// <summary>The request target as sent (<see cref="Adapters.Target"/>).</summary>
    public static string Target(string rawTarget) => Adapters.Target(rawTarget);

    /// <summary>A form body written back from a server's parsed form (<see cref="Adapters.FormBody"/>).</summary>
    public static byte[] FormBody(IEnumerable<KeyValuePair<string, string>> fields) => Adapters.FormBody(fields);
}
