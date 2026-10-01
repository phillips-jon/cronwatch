using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch.Web;
using Microsoft.Extensions.Time.Testing;
using Xunit;
using static Cronwatch.Tests.Support;

namespace Cronwatch.Tests.Web;

/// <summary>
/// <c>job.Handler()</c>: the SDK's handler tests (<c>client.test.ts</c> and
/// <c>client-hardening.test.ts</c>), as the Go, Rust, Elixir and Java ports have them, and the
/// .NET answers: a <see cref="CronwatchResponse"/> the function returns, a throw answered 500, and the
/// request's token linked into the run's. Without a secret, and in development, it is tested in
/// <see cref="RoutesEnvTests"/>.
/// </summary>
public class HandlerTests
{
    private const string Secret = "hourly-word";

    private static CronwatchClient Client(CronSecret secret, Capture? capture = null, FakeTimeProvider? clock = null) =>
        new(new CronwatchOptions
        {
            CronSecret = secret,
            ProcessExitHook = false,
            Alerts = capture == null ? [] : [capture],
            Clock = clock ?? Support.Clock(),
            OnWarning = _ => { },
        });

    private static CronwatchRequest Get(string? auth, bool fail = false)
    {
        var headers = new List<KeyValuePair<string, string>>();
        if (auth != null)
        {
            headers.Add(new("authorization", auth));
        }
        if (fail)
        {
            headers.Add(new("x-fail", "1"));
        }
        return new CronwatchRequest("GET", "/api/cron/hourly") { Headers = headers };
    }

    private static CronwatchRequest Post(string secret) =>
        new("POST", "/") { Headers = [new("authorization", "Bearer " + secret)] };

    [Fact]
    public async Task The_handler_checks_the_bearer_and_reports_the_run()
    {
        var time = Support.Clock();
        await using var cw = Client(Secret, clock: time);
        Job job = cw.Job("hourly", new JobOptions { Schedule = "@hourly" });
        Handler h = job.Handler((j, req, ct) =>
        {
            j.Log(req.Path);
            if (req.Header("x-fail") != null)
            {
                throw new IOException("nope\nsecond line");
            }
            return Task.CompletedTask;
        });
        Assert.Equal(401, (await h.HandleAsync(Get(null))).Status);
        CronwatchResponse wrong = await h.HandleAsync(Get("Bearer wrong"));
        Assert.Equal("{\"ok\":false,\"error\":\"Unauthorized\"}", wrong.Text());
        Assert.Equal(401, (await h.HandleAsync(Get("bearer " + Secret))).Status);
        CronwatchResponse res = await h.HandleAsync(Get("Bearer " + Secret));
        Assert.Equal(200, res.Status);
        Assert.Equal("application/json; charset=utf-8", res.Header("content-type"));
        Assert.Equal("no-store", res.Header("cache-control"));
        var runs = await cw.RunsAsync("hourly", 10);
        Assert.Equal("{\"ok\":true,\"job\":\"hourly\",\"run\":\"" + runs[0].Id + "\",\"status\":\"ok\",\"durationMs\":0}", res.Text());
        time.Advance(1000);
        CronwatchResponse failed = await h.HandleAsync(Get("Bearer " + Secret, fail: true));
        Assert.Equal(500, failed.Status);
        Assert.Equal("IOException: nope", WebKit.JsonOf(failed).Get("error"));
        runs = await cw.RunsAsync("hourly", 10);
        Assert.Equal(2, runs.Count);
        Assert.Equal("/api/cron/hourly", runs[1].Output);
        Assert.Equal("handler", runs[0].Trigger);
        Assert.StartsWith("IOException: nope\nsecond line\n", runs[0].Error, StringComparison.Ordinal);
    }

    [Fact]
    public async Task A_secret_of_its_own_replaces_the_clients()
    {
        const string clientSecret = "client-word";
        const string own = "own-word";
        await using var cw = Client(clientSecret);
        Job job = cw.Job("own");
        Task Ok(JobContext j, CronwatchRequest r, CancellationToken ct) => Task.CompletedTask;
        Handler h = job.Handler(Ok, new HandlerOptions { Secret = own });
        Assert.Equal(401, (await h.HandleAsync(Post(clientSecret))).Status);
        Assert.Equal(200, (await h.HandleAsync(Post(own))).Status);
        Handler empty = job.Handler(Ok, new HandlerOptions { Secret = "" });
        Assert.Equal(200, (await empty.HandleAsync(Post(clientSecret))).Status);
        Handler open = job.Handler(Ok, new HandlerOptions { Secret = HandlerSecret.None });
        Assert.Equal(200, (await open.HandleAsync(new CronwatchRequest("POST", "/"))).Status);
    }

    [Fact]
    public async Task A_client_without_a_cron_secret_lets_anyone_in()
    {
        await using var cw = Client(CronSecret.None);
        Handler h = cw.Job("any").Handler((j, r, ct) => Task.CompletedTask);
        Assert.Equal(200, (await h.HandleAsync(new CronwatchRequest("GET", "/"))).Status);
    }

    [Fact]
    public async Task A_response_is_the_answer_and_fails_the_run_at_400()
    {
        var capture = new Capture();
        var time = Support.Clock();
        await using var cw = Client(CronSecret.None, capture, time);
        Job job = cw.Job("h");
        Handler returned = job.Handler((j, r, ct) => Task.FromResult(new CronwatchResponse(503).WithHeader("x-upstream", "1").WithBody("bad")));
        CronwatchResponse res = await returned.HandleAsync(new CronwatchRequest("GET", "/"));
        Assert.Equal(503, res.Status);
        Assert.Equal("bad", res.Text());
        Assert.Equal("1", res.Header("x-upstream"));
        Assert.Equal("HTTP 503 Service Unavailable", (await cw.RunsAsync("h", 10))[0].Error);
        await Eventually("the failed alert", () => capture.Types().Count == 1);
        Assert.Equal(["failed"], capture.Types());

        time.Advance(1000);
        Handler fine = job.Handler((j, r, ct) => Task.FromResult(new CronwatchResponse(202).WithHeader("content-type", "text/plain").WithBody("queued")));
        res = await fine.HandleAsync(new CronwatchRequest("GET", "/"));
        Assert.Equal(202, res.Status);
        Assert.Equal("queued", res.Text());
        Assert.Equal("text/plain", res.Header("content-type"));
        Assert.Equal(RunStatus.Ok, (await cw.RunsAsync("h", 10))[0].Status);

        time.Advance(1000);
        Handler text = job.Handler((j, r, ct) => Task.FromResult("Report written"));
        res = await text.HandleAsync(new CronwatchRequest("GET", "/"));
        Assert.Equal(200, res.Status);
        Assert.Equal("Report written", (await cw.RunsAsync("h", 10))[0].Output);
    }

    [Fact]
    public async Task A_throw_is_a_failed_run_answered_with_the_run()
    {
        var capture = new Capture();
        await using var cw = Client(Secret, capture);
        Handler h = cw.Job("p").Handler((j, r, ct) => Task.FromException(new InvalidOperationException("boom")));
        CronwatchResponse res = await h.HandleAsync(Post(Secret));
        Assert.Equal(500, res.Status);
        Assert.Equal("application/json; charset=utf-8", res.Header("content-type"));
        var runs = await cw.RunsAsync("p", 10);
        Assert.Equal(RunStatus.Failed, runs[0].Status);
        Assert.Equal(
            "{\"ok\":false,\"job\":\"p\",\"run\":\"" + runs[0].Id + "\",\"status\":\"failed\",\"durationMs\":0,\"error\":\"InvalidOperationException: boom\"}",
            res.Text());
        await Eventually("the failed alert", () => capture.Types().Count == 1);

        // A caller without the secret gets no error text, as for any failure.
        Handler open = cw.Job("q").Handler(
            (j, r, ct) => throw new InvalidOperationException("private detail"),
            new HandlerOptions { Secret = HandlerSecret.None });
        CronwatchResponse anyone = await open.HandleAsync(new CronwatchRequest("GET", "/"));
        Assert.Equal(500, anyone.Status);
        Assert.False(WebKit.JsonOf(anyone).Has("error"));

        // A function that throws before it returns a task is the same failed run.
        Assert.Equal(RunStatus.Failed, (await cw.RunsAsync("q", 10))[0].Status);
    }

    [Fact]
    public async Task The_requests_token_is_linked_into_the_runs()
    {
        await using var cw = Client(CronSecret.None);
        var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        Handler h = cw.Job("long").Handler(async (j, r, ct) =>
        {
            started.SetResult();
            await Task.Delay(Timeout.Infinite, ct);
        });
        using var cts = new CancellationTokenSource();
        Task<CronwatchResponse> answer = h.HandleAsync(new CronwatchRequest("GET", "/"), cts.Token);
        await started.Task;
        await cts.CancelAsync();
        // The caller may stop waiting or be answered; either way the run is recorded failed.
        try
        {
            await answer;
        }
        catch (OperationCanceledException)
        {
            // The request ended; the recording goes on without it.
        }
        await Eventually("the run recorded", async () => (await cw.RunsAsync("long", 1)) is [{ Status.Value: "failed" }]);
        Assert.StartsWith("TaskCanceledException", (await cw.RunsAsync("long", 1))[0].Error, StringComparison.Ordinal);
    }

    [Fact]
    public async Task A_run_fails_for_an_http_answer_of_400_or_more()
    {
        var time = Support.Clock();
        await using var cw = Client(CronSecret.None, clock: time);
        Job job = cw.Job("fetch");
        CronwatchResponse res = await job.RunAsync((j, ct) => Task.FromResult(new CronwatchResponse(502)));
        Assert.Equal(502, res.Status);
        Assert.Equal("HTTP 502 Bad Gateway", (await cw.RunsAsync("fetch", 10))[0].Error);
        time.Advance(1000);
        CronwatchResponse unknown = await job.RunAsync((j, ct) => Task.FromResult(new CronwatchResponse(599)));
        Assert.Equal(599, unknown.Status);
        Assert.Equal("HTTP 599", (await cw.RunsAsync("fetch", 10))[0].Error);
        time.Advance(1000);
        await job.RunAsync((j, ct) => Task.FromResult(new CronwatchResponse(204)));
        Assert.Equal(RunStatus.Ok, (await cw.RunsAsync("fetch", 10))[0].Status);
    }
}
