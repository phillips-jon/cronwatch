using System;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch.Alerts;
using Cronwatch.Triage;
using Xunit;
using static Cronwatch.Tests.Support;

namespace Cronwatch.Tests.Triage;

/// <summary>Claude triage beyond the fixture: refusals, answers that are not JSON, the key and base URL, a client.</summary>
public class AnthropicTriageTests
{
    private static TriageContext Context() =>
        TriageConformanceTests.Contexts(Fixtures.Load("triage"))["a failure with earlier runs"];

    private static string? Variables(string name, string? key, string? baseUrl) => name switch
    {
        "ANTHROPIC_API_KEY" => key,
        "ANTHROPIC_BASE_URL" => baseUrl,
        _ => null,
    };

    [Fact]
    public async Task A_refused_request_names_the_status_and_the_answer_with_the_key_cut_out()
    {
        string key = "not-a-real-" + "key-0001";
        var rec = new TriageConformanceTests.Recorder(401, "{\"error\":\"bad key " + key + "\"}");
        var options = new AnthropicTriageOptions { ApiKey = " " + key + "\n", BaseUrl = "https://gateway.example/anthropic//", Transport = rec };
        var triage = new AnthropicTriage(options, TriageConformanceTests.NoEnvironment);
        var e = await Assert.ThrowsAsync<CronwatchException>(() => triage.TriageAsync(Context(), TestContext.Current.CancellationToken));
        Assert.Equal("Anthropic https://gateway.example answered 401: {\"error\":\"bad key [redacted]\"}", e.Message);
        TransportRequest r = Assert.Single(rec.Taken);
        Assert.Equal("https://gateway.example/anthropic/v1/messages?beta=true", r.Url);
        Assert.Equal(key, r.Header("x-api-key"));
        Assert.DoesNotContain(key, triage.ToString(), StringComparison.Ordinal);
        Assert.DoesNotContain(key, options.ToString(), StringComparison.Ordinal);
        Assert.DoesNotContain("gateway", options.ToString(), StringComparison.Ordinal);
    }

    [Fact]
    public async Task An_answer_that_is_not_json_is_an_error_and_a_refusal_no_diagnosis()
    {
        var bad = new AnthropicTriage(
            new AnthropicTriageOptions { ApiKey = "k", BaseUrl = "https://api.anthropic.com", Transport = new TriageConformanceTests.Recorder(200, "not json") },
            TriageConformanceTests.NoEnvironment);
        var e = await Assert.ThrowsAsync<CronwatchException>(() => bad.TriageAsync(Context(), TestContext.Current.CancellationToken));
        Assert.StartsWith("Anthropic https://api.anthropic.com answered 200 with JSON that could not be read: ", e.Message, StringComparison.Ordinal);
        var refusal = new AnthropicTriage(
            new AnthropicTriageOptions
            {
                ApiKey = "k",
                BaseUrl = "https://api.anthropic.com",
                Transport = new TriageConformanceTests.Recorder(200, "{\"stop_reason\":\"refusal\",\"content\":[]}"),
            },
            TriageConformanceTests.NoEnvironment);
        Assert.Null(await refusal.TriageAsync(Context(), TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task With_no_key_triage_says_where_to_put_one()
    {
        var rec = new TriageConformanceTests.Recorder();
        var triage = new AnthropicTriage(new AnthropicTriageOptions { Transport = rec }, TriageConformanceTests.NoEnvironment);
        var e = await Assert.ThrowsAsync<CronwatchException>(() => triage.TriageAsync(Context(), TestContext.Current.CancellationToken));
        Assert.Equal("Anthropic triage needs an ApiKey, or ANTHROPIC_API_KEY set", e.Message);
        Assert.Empty(rec.Taken);
    }

    [Fact]
    public async Task The_key_and_base_url_come_from_the_environment_each_time_it_runs()
    {
        var rec = new TriageConformanceTests.Recorder();
        string? key = "not-a-real-key-a";
        string? baseUrl = null;
        var triage = new AnthropicTriage(new AnthropicTriageOptions { Transport = rec }, name => Variables(name, key, baseUrl));
        Assert.Equal("ok", await triage.TriageAsync(Context(), TestContext.Current.CancellationToken));
        key = "not-a-real-key-b";
        baseUrl = "http://127.0.0.1:9/proxy/";
        Assert.Equal("ok", await triage.TriageAsync(Context(), TestContext.Current.CancellationToken));
        var taken = rec.Taken.ToList();
        Assert.Equal("https://api.anthropic.com/v1/messages?beta=true", taken[0].Url);
        Assert.Equal("not-a-real-key-a", taken[0].Header("x-api-key"));
        Assert.Equal("http://127.0.0.1:9/proxy/v1/messages?beta=true", taken[1].Url);
        Assert.Equal("not-a-real-key-b", taken[1].Header("x-api-key"));
        // The options win over the environment.
        var own = new AnthropicTriage(
            new AnthropicTriageOptions { ApiKey = "not-a-real-key-c", BaseUrl = "https://gateway.example", Transport = rec },
            name => Variables(name, key, baseUrl));
        await own.TriageAsync(Context(), TestContext.Current.CancellationToken);
        Assert.Equal("https://gateway.example/v1/messages?beta=true", rec.Taken.Last().Url);
        Assert.Equal("not-a-real-key-c", rec.Taken.Last().Header("x-api-key"));
    }

    [Fact]
    public async Task No_fallbacks_sends_no_beta_and_zero_max_tokens_is_sent_as_zero()
    {
        var rec = new TriageConformanceTests.Recorder();
        var triage = new AnthropicTriage(
            new AnthropicTriageOptions { ApiKey = "k", BaseUrl = "https://api.anthropic.com", Fallbacks = false, MaxTokens = 0, Transport = rec },
            TriageConformanceTests.NoEnvironment);
        await triage.TriageAsync(Context(), TestContext.Current.CancellationToken);
        TransportRequest r = Assert.Single(rec.Taken);
        Assert.Null(r.Header("anthropic-beta"));
        string body = Encoding.UTF8.GetString(r.Body.Span);
        Assert.StartsWith("{\"model\":\"claude-opus-5\",\"max_tokens\":0,", body, StringComparison.Ordinal);
        Assert.DoesNotContain("fallbacks", body, StringComparison.Ordinal);
        Assert.DoesNotContain("betas", body, StringComparison.Ordinal);
        Assert.Equal(
            ["accept", "anthropic-version", "content-type", "x-api-key", "user-agent"],
            r.Headers.Select(h => h.Key).ToArray());
    }

    [Fact]
    public async Task The_callers_token_ends_a_request_that_never_answers()
    {
        var hung = new Hung();
        var triage = new AnthropicTriage(
            new AnthropicTriageOptions { ApiKey = "k", BaseUrl = "https://api.anthropic.com", Transport = hung },
            TriageConformanceTests.NoEnvironment);
        using var cts = new CancellationTokenSource();
        Task<string?> pending = triage.TriageAsync(Context(), cts.Token);
        await hung.Started.Task;
        await cts.CancelAsync();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => pending);
    }

    [Fact]
    public async Task A_client_triages_its_alerts_through_its_own_transport()
    {
        var rec = new TriageConformanceTests.Recorder(
            200,
            "{\"stop_reason\":\"end_turn\",\"content\":[{\"type\":\"text\",\"text\":\" Disk full. \"}]}");
        var clock = Clock();
        var capture = new Capture();
        var errors = new Errors();
        await using (var cw = new CronwatchClient(new CronwatchOptions
        {
            Clock = clock,
            Alerts = { capture },
            CronSecret = CronSecret.None,
            OnError = errors.Handle,
            OnWarning = _ => { },
            ProcessExitHook = false,
            Transport = rec,
            Triage = new AnthropicTriage(new AnthropicTriageOptions { ApiKey = "k", BaseUrl = "https://api.anthropic.com" }, TriageConformanceTests.NoEnvironment),
        }))
        {
            var job = cw.Job("nightly");
            await Assert.ThrowsAsync<InvalidOperationException>(() => job.RunAsync((j, ct) => throw new InvalidOperationException("disk full")));
        }
        Alert alert = Assert.Single(capture.List());
        Assert.Equal(AlertType.Failed, alert.Type);
        Assert.Equal("Disk full.", alert.Triage);
        TransportRequest r = Assert.Single(rec.Taken);
        Assert.Equal("cronwatch-dotnet/" + CronwatchClient.Version, r.Header("user-agent"));
        Assert.Contains("disk full", Encoding.UTF8.GetString(r.Body.Span), StringComparison.Ordinal);
        Assert.Empty(errors.Entries);
    }

    /// <summary>A transport that never answers until its token is cancelled.</summary>
    private sealed class Hung : ITransport
    {
        public TaskCompletionSource Started { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);

        public async Task<TransportResponse> PostAsync(TransportRequest request, CancellationToken cancellationToken)
        {
            Started.TrySetResult();
            await Task.Delay(Timeout.Infinite, cancellationToken);
            throw new InvalidOperationException("unreachable");
        }
    }
}
