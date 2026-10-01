using System.Collections.Generic;
using System.Text;
using System.Threading.Tasks;
using Cronwatch.Web;
using Xunit;

#pragma warning disable CS0618 // the former names, kept through 1.x, are what this file tests

namespace Cronwatch.Tests;

/// <summary>
/// The names 1.0 renamed, kept through 1.x as deprecated aliases (the 1.0 plan, D11): each still
/// compiles where it did and does what its replacement does.
/// </summary>
public class DeprecatedTests
{
    [Fact]
    public async Task WebRequest_and_WebResponse_still_drive_the_routes_and_a_handler()
    {
        await using var cw = new CronwatchClient(new CronwatchOptions
        {
            CronSecret = "hourly-word",
            ProcessExitHook = false,
            Clock = Support.Clock(),
            OnWarning = _ => { },
        });
        Routes routes = cw.Routes(new RoutesOptions { Token = "t0ken" });
        WebResponse answer = await routes.HandleAsync(new WebRequest("GET", "/cronwatch/api/jobs")
        {
            Headers = [new("host", "app.test"), new("authorization", "Bearer t0ken")],
        });
        Assert.Equal(200, answer.Status);
        Assert.Equal("{\"ok\":true,\"jobs\":[]}", answer.Text());
        Assert.Equal("application/json; charset=utf-8", answer.Header("content-type"));
        CronwatchResponse same = answer;
        Assert.Equal(answer.Status, same.Status);

        // A body given to the former type reaches the routes.
        cw.Job("s");
        WebResponse silenced = await routes.HandleAsync(new WebRequest("POST", "/cronwatch/api/jobs/s/silence")
        {
            Headers = [new("host", "app.test"), new("authorization", "Bearer t0ken"), new("content-type", "application/json")],
            Body = Encoding.UTF8.GetBytes("{\"for\":\"2h\"}"),
        });
        Assert.Equal(200, silenced.Status);
        Assert.Equal(JobHealth.Silenced, (await cw.JobSummaryAsync("s"))!.Health);

        // A handler's function may still return the former type, which is its answer.
        Handler h = cw.Job("hourly").Handler((job, req, ct) => Task.FromResult(new WebResponse(418).WithBody("teapot")));
        CronwatchResponse teapot = await h.HandleAsync(new WebRequest("POST", "/") { Headers = [new("authorization", "Bearer hourly-word")] });
        Assert.Equal(418, teapot.Status);
        Assert.Equal("teapot", teapot.Text());
        Assert.Equal("failed", (await cw.RunsAsync("hourly", 1))[0].Status.Value);
    }

    [Fact]
    public void WebAdapters_is_Adapters()
    {
        Assert.Equal(Adapters.Target("/cafÃ©"), WebAdapters.Target("/cafÃ©"));
        var fields = new List<KeyValuePair<string, string>> { new("for", "2h"), new("a b", "c&d") };
        Assert.Equal(Adapters.FormBody(fields), WebAdapters.FormBody(fields));
    }
}
