using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch.Alerts;
using Cronwatch.Triage;
using Xunit;

namespace Cronwatch.Tests.Triage;

/// <summary>
/// Replays <c>conformance/triage.json</c>: the parameters the SDK hands the official client for
/// each context and option set, the diagnosis read from each answer, and (the <c>wire</c> cases)
/// the HTTP request that client sends, which the port makes itself.
/// </summary>
public class TriageConformanceTests
{
    /// <summary>The fixture's triage contexts, by name.</summary>
    internal static Dictionary<string, TriageContext> Contexts(JsObject f)
    {
        var output = new Dictionary<string, TriageContext>(StringComparer.Ordinal);
        foreach (JsObject c in Fixtures.Objects(f, "contexts"))
        {
            var runs = Fixtures.List(c, "recentRuns").Select(Run.FromValue).ToList();
            output[Fixtures.String(c, "name")!] = new TriageContext(Alert.FromValue(c.Get("alert")), runs);
        }
        return output;
    }

    /// <summary>A fixture's option set, with anything else the test adds.</summary>
    internal static AnthropicTriageOptions Options(JsObject o, string? apiKey = null, string? baseUrl = null, ITransport? transport = null)
    {
        var defaults = new AnthropicTriageOptions();
        return new AnthropicTriageOptions
        {
            Model = Fixtures.String(o, "model") ?? defaults.Model,
            Effort = Fixtures.String(o, "effort") ?? defaults.Effort,
            Context = Fixtures.String(o, "context"),
            MaxTokens = Fixtures.OptInteger(o, "maxTokens") ?? defaults.MaxTokens,
            Fallbacks = o.Get("fallbacks") is not false,
            ApiKey = apiKey,
            BaseUrl = baseUrl,
            Transport = transport,
        };
    }

    /// <summary>Answers every request with one answer and keeps the request.</summary>
    internal sealed class Recorder(int status = 200, string? body = null) : ITransport
    {
        public const string Ok =
            "{\"id\":\"msg_1\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"m\",\"stop_reason\":\"end_turn\","
            + "\"content\":[{\"type\":\"text\",\"text\":\"ok\"}],\"usage\":{}}";

        public ConcurrentQueue<TransportRequest> Taken { get; } = new();

        public Task<TransportResponse> PostAsync(TransportRequest request, CancellationToken cancellationToken)
        {
            Taken.Enqueue(request);
            return Task.FromResult(new TransportResponse(status, body ?? Ok));
        }
    }

    /// <summary>An environment with nothing set, so the replay never reads the process's own.</summary>
    internal static string? NoEnvironment(string name) => null;

    [Fact]
    public async Task Every_case_of_triage_json_is_the_sdks()
    {
        JsObject f = Fixtures.Load("triage");
        var byName = Contexts(f);
        Assert.Equal(Fixtures.Objects(f, "contexts").Count, byName.Count);
        var failures = new Fixtures.Failures();
        int count = 0;
        foreach (JsObject c in Fixtures.Objects(f, "requests"))
        {
            JsObject o = Fixtures.Object(c, "options");
            string context = Fixtures.String(c, "context")!;
            JsObject parameters = AnthropicTriage.Params(Options(o), byName[context]);
            failures.Same(o.ToJson() + " " + context + ": params", parameters, c.Get("params"));
            JsObject ro = Fixtures.Object(c, "requestOptions");
            Assert.Equal((long)AnthropicTriage.RequestTimeout.TotalMilliseconds, Fixtures.Integer(ro, "timeout"));
            Assert.Equal(0, Fixtures.Integer(ro, "maxRetries"));
            count++;
        }
        foreach (JsObject c in Fixtures.Objects(f, "responses"))
        {
            string got = AnthropicTriage.Diagnosis(c.Get("response"));
            failures.Same(Json.Stringify(c.Get("response")), got.Length == 0 ? null : got, c.Get("result"));
            count++;
        }
        string[] kept = ["accept", "anthropic-beta", "anthropic-version", "content-type", "x-api-key"];
        foreach (JsObject c in Fixtures.Objects(f, "wire"))
        {
            JsObject o = Fixtures.Object(c, "options");
            var rec = new Recorder();
            var triage = new AnthropicTriage(Options(o, "test-key", "https://api.anthropic.com", rec), NoEnvironment);
            string context = Fixtures.String(c, "context")!;
            Assert.Equal("ok", await triage.TriageAsync(byName[context], TestContext.Current.CancellationToken));
            TransportRequest r = Assert.Single(rec.Taken);
            JsObject want = Fixtures.Object(c, "request");
            Assert.Equal("POST", Fixtures.String(want, "method"));
            failures.Same(o.ToJson() + ": url", r.Url, want.Get("url"));
            var headers = new JsObject();
            foreach (var h in r.Headers)
            {
                if (kept.Contains(h.Key, StringComparer.Ordinal))
                {
                    headers.Set(h.Key, h.Value);
                }
            }
            failures.Same(o.ToJson() + ": headers", headers, want.Get("headers"));
            Assert.Equal("cronwatch-dotnet/" + CronwatchClient.Version, r.Header("user-agent"));
            failures.Same(o.ToJson() + ": body", Fixtures.Digest(Encoding.UTF8.GetString(r.Body.Span)), want.Get("body"));
            count++;
        }
        failures.Check("triage");
        int total = new[] { "requests", "responses", "wire" }.Sum(k => Fixtures.Objects(f, k).Count);
        Assert.Equal(total, count);
    }
}
