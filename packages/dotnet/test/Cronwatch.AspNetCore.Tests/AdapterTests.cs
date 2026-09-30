using System;
using System.IO;
using System.Net.Http;
using System.Text.Encodings.Web;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch.Web;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using Xunit;

namespace Cronwatch.AspNetCore.Tests;

/// <summary>
/// The adapter's own rules: authorization and antiforgery on the endpoints, a form something
/// ahead already read, the middleware passing other requests on, and a job's handler.
/// </summary>
public class AdapterTests
{
    private static CronwatchClient Client() => new(new CronwatchOptions { ProcessExitHook = false, Alerts = [], CronSecret = CronSecret.None });

    private static WebApplication App(CronwatchClient cw, Action<IServiceCollection>? services = null)
    {
        WebApplicationBuilder builder = WebApplication.CreateSlimBuilder();
        builder.Logging.ClearProviders();
        builder.WebHost.UseTestServer();
        builder.Services.AddSingleton(cw);
        services?.Invoke(builder.Services);
        return builder.Build();
    }

    private static HttpRequestMessage Get(string path, string? bearer = null)
    {
        var m = new HttpRequestMessage(HttpMethod.Get, path);
        if (bearer != null)
        {
            m.Headers.Add("authorization", "Bearer " + bearer);
        }
        return m;
    }

    /// <summary>A scheme that never signs anyone in; its challenge is an empty 401.</summary>
    private sealed class NoOne(IOptionsMonitor<AuthenticationSchemeOptions> options, ILoggerFactory logger, UrlEncoder encoder)
        : AuthenticationHandler<AuthenticationSchemeOptions>(options, logger, encoder)
    {
        protected override Task<AuthenticateResult> HandleAuthenticateAsync() => Task.FromResult(AuthenticateResult.NoResult());
    }

    private static void SignedInOnly(IServiceCollection s)
    {
        s.AddAuthentication("none").AddScheme<AuthenticationSchemeOptions, NoOne>("none", null);
        s.AddAuthorizationBuilder().SetFallbackPolicy(new AuthorizationPolicyBuilder().RequireAuthenticatedUser().Build());
    }

    [Fact]
    public async Task A_dashboard_with_a_token_is_reached_past_a_fallback_policy_and_an_open_one_takes_the_policy()
    {
        await using CronwatchClient cw = Client();
        await using WebApplication app = App(cw, SignedInOnly);
        app.UseAuthentication();
        app.UseAuthorization();
        app.MapCronwatch("/cronwatch", new RoutesOptions { Token = "tok" });
        app.MapCronwatch("/open", new RoutesOptions { Token = DashboardToken.None });
        app.MapGet("/app", () => "the app's own");
        await app.StartAsync();
        HttpClient http = app.GetTestClient();

        // The dashboard's own sign-in answers, not the app's challenge.
        HttpResponseMessage unsigned = await http.SendAsync(Get("/cronwatch/api/jobs"));
        Assert.Equal(401, (int)unsigned.StatusCode);
        Assert.Equal("{\"ok\":false,\"error\":\"Unauthorized\"}", await unsigned.Content.ReadAsStringAsync());
        HttpResponseMessage signed = await http.SendAsync(Get("/cronwatch/api/jobs", "tok"));
        Assert.Equal(200, (int)signed.StatusCode);

        // An open dashboard is behind the app's policy: the scheme's empty challenge.
        HttpResponseMessage open = await http.SendAsync(Get("/open/api/jobs"));
        Assert.Equal(401, (int)open.StatusCode);
        Assert.Equal("", await open.Content.ReadAsStringAsync());
        HttpResponseMessage app401 = await http.SendAsync(Get("/app"));
        Assert.Equal(401, (int)app401.StatusCode);
        await app.StopAsync();
    }

    [Fact]
    public async Task The_forms_pass_the_apps_antiforgery_and_a_form_read_ahead_is_taken_from_the_parsed_form()
    {
        await using CronwatchClient cw = Client();
        await cw.Job("nightly").RunAsync((job, ct) => Task.CompletedTask);
        await using WebApplication app = App(cw, s => s.AddAntiforgery());
        // Something ahead of the dashboard reads every form.
        app.Use(async (context, next) =>
        {
            if (context.Request.HasFormContentType)
            {
                await context.Request.ReadFormAsync();
            }
            await next(context);
        });
        app.UseAntiforgery();
        app.MapCronwatch("/cronwatch", new RoutesOptions { Token = "tok" });
        await app.StartAsync();
        HttpClient http = app.GetTestClient();

        var post = new HttpRequestMessage(HttpMethod.Post, "/cronwatch/jobs/nightly/silence")
        {
            Content = new FormUrlEncodedContent([new("for", "4h")]),
        };
        post.Headers.Add("authorization", "Bearer tok");
        long before = cw.NowMs;
        HttpResponseMessage answer = await http.SendAsync(post);
        long after = cw.NowMs;
        Assert.Equal(303, (int)answer.StatusCode);
        JobSummary? job = await cw.JobSummaryAsync("nightly");
        Assert.InRange(job!.SilencedUntil!.Value, before + (4 * 3_600_000), after + (4 * 3_600_000));
        await app.StopAsync();
    }

    [Fact]
    public async Task UseCronwatch_answers_under_its_path_and_passes_every_other_request_on()
    {
        await using CronwatchClient cw = Client();
        await using WebApplication app = App(cw);
        app.UseCronwatch("/ops/cronwatch", new RoutesOptions { Token = "tok" });
        app.Run(context => context.Response.WriteAsync("next"));
        await app.StartAsync();
        HttpClient http = app.GetTestClient();

        HttpResponseMessage other = await http.SendAsync(Get("/ops/other"));
        Assert.Equal("next", await other.Content.ReadAsStringAsync());
        // The base is the branch's: the sign-in cookie's path says so.
        HttpResponseMessage signIn = await http.SendAsync(Get("/ops/cronwatch/?token=tok"));
        Assert.Equal(303, (int)signIn.StatusCode);
        Assert.Contains("Path=/ops/cronwatch;", string.Join(";", signIn.Headers.GetValues("set-cookie")), StringComparison.Ordinal);
        Assert.Equal("/ops/cronwatch/", signIn.Headers.Location!.OriginalString);
        await app.StopAsync();
    }

    [Fact]
    public async Task A_job_handler_needs_the_secret_records_its_run_and_passes_an_IResult_through()
    {
        await using var cw = new CronwatchClient(new CronwatchOptions { ProcessExitHook = false, Alerts = [], CronSecret = "letmein-test" });
        cw.Job("nightly");
        Job flaky = cw.Job("flaky");
        await using WebApplication app = App(cw);
        app.MapCronwatchHandler("/cron/nightly", "nightly", async (JobContext job, HttpContext http, CancellationToken ct) =>
        {
            job.Log("ran for " + http.Request.Path);
            await Task.Yield();
        });
        app.MapCronwatchHandler("/cron/flaky", flaky, (job, http, ct) => Task.FromResult<IResult>(Results.StatusCode(503)));
        await app.StartAsync();
        HttpClient client = app.GetTestClient();

        Assert.Equal(401, (int)(await client.PostAsync("/cron/nightly", null)).StatusCode);
        var ok = new HttpRequestMessage(HttpMethod.Post, "/cron/nightly");
        ok.Headers.Add("authorization", "Bearer letmein-test");
        HttpResponseMessage answer = await client.SendAsync(ok);
        Assert.Equal(200, (int)answer.StatusCode);
        Assert.Contains("\"status\":\"ok\"", await answer.Content.ReadAsStringAsync(), StringComparison.Ordinal);
        Run run = (await cw.RunsAsync("nightly"))[0];
        Assert.Equal("handler", run.Trigger);
        Assert.Equal("ran for /cron/nightly", run.Output);

        var failing = new HttpRequestMessage(HttpMethod.Get, "/cron/flaky");
        failing.Headers.Add("authorization", "Bearer letmein-test");
        HttpResponseMessage passed = await client.SendAsync(failing);
        Assert.Equal(503, (int)passed.StatusCode);
        Run failed = (await cw.RunsAsync("flaky"))[0];
        Assert.Equal(RunStatus.Failed, failed.Status);
        Assert.Equal("HTTP 503 Service Unavailable", failed.Error);

        Assert.Throws<InvalidOperationException>(() => app.MapCronwatchHandler("/cron/ghost", "ghost", (job, http, ct) => Task.CompletedTask));
        await app.StopAsync();
    }
}
