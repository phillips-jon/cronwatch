using System;
using System.Collections.Generic;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch.Alerts;

namespace Cronwatch.Tests.Alerts;

/// <summary>
/// A transport that keeps each request and answers each with the status and body its answer gives
/// for the request's body, as the SDK's tests stub fetch.
/// </summary>
internal sealed class Recorder : ITransport
{
    private readonly Lock _lock = new();
    private readonly List<TransportRequest> _taken = [];
    private Func<string, (int Status, string Body)> _answer = _ => (200, "");

    /// <summary>Answers every request with this, and forgets what was taken.</summary>
    public void AnswerWith(int status, string body) => Answer(_ => (status, body));

    /// <summary>Answers each request by its body, and forgets what was taken.</summary>
    public void Answer(Func<string, (int Status, string Body)> answer)
    {
        lock (_lock)
        {
            _answer = answer;
            _taken.Clear();
        }
    }

    /// <summary>The requests taken, in the order they came.</summary>
    public List<TransportRequest> Taken()
    {
        lock (_lock)
        {
            return [.. _taken];
        }
    }

    /// <summary>A request's body as text.</summary>
    public static string Body(TransportRequest r) => Encoding.UTF8.GetString(r.Body.Span);

    public Task<TransportResponse> PostAsync(TransportRequest request, CancellationToken cancellationToken)
    {
        (int status, string body) reply;
        lock (_lock)
        {
            reply = _answer(Body(request));
            _taken.Add(request);
        }
        return Task.FromResult(new TransportResponse(reply.status, reply.body));
    }
}
