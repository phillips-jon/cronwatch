using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Text;
using System.Threading.Tasks;
using Cronwatch.Web;
using Cronwatch.WebTest;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using Xunit;

namespace Cronwatch.AspNetCore.Tests;

/// <summary>
/// What Kestrel does to the dashboard's answers and requests on the wire, which the golden replay
/// through it sets aside: its own order and casing for the headers it knows, <c>Date</c> and
/// <c>Server</c> added, and requests it refuses itself before the routes see them.
/// </summary>
public class KestrelTests
{
    private static readonly KeyValuePair<string, string>[] Bearer = [new("authorization", "Bearer tok")];

    private static async Task<(WebApplication App, int Port)> StartAsync(CronwatchClient cw)
    {
        WebApplicationBuilder b = WebApplication.CreateSlimBuilder();
        b.Logging.ClearProviders();
        b.Services.AddSingleton(cw);
        b.WebHost.UseKestrel(k => k.Listen(IPAddress.Loopback, 0));
        WebApplication app = b.Build();
        app.MapCronwatch("/cronwatch", new RoutesOptions { Token = "tok" });
        await app.StartAsync();
        return (app, GoldenTests.PortOf(app));
    }

    [Fact]
    public async Task Kestrel_writes_the_headers_it_knows_first_in_its_own_casing_and_adds_date_and_server()
    {
        await using var cw = new CronwatchClient(new CronwatchOptions { ProcessExitHook = false, Alerts = [] });
        var (app, port) = await StartAsync(cw);
        await using (app)
        {
            RawHttp.Answer a = await RawHttp.SendAsync(port, "GET", "/cronwatch/api/jobs", Bearer, null);
            Assert.Equal(200, a.Status);
            Assert.Equal(
                ["Content-Length", "Connection", "Content-Type", "Date", "Server", "Cache-Control", "X-Content-Type-Options", "referrer-policy", "x-robots-tag"],
                a.Headers.Select(h => h.Key));
            Assert.Equal("Kestrel", a.Header("server"));
            // The routes' order was content-type, cache-control, then the security headers.
            Assert.Equal("no-store", a.Header("cache-control"));

            RawHttp.Answer signIn = await RawHttp.SendAsync(port, "GET", "/cronwatch/?token=tok", [], null);
            Assert.Equal(303, signIn.Status);
            Assert.Equal(
                ["Content-Length", "Connection", "Date", "Server", "Cache-Control", "Location", "Set-Cookie", "X-Content-Type-Options", "referrer-policy", "x-robots-tag"],
                signIn.Headers.Select(h => h.Key));
            Assert.Equal("0", signIn.Header("content-length"));
            await app.StopAsync();
        }
    }

    [Theory]
    [InlineData("host: evil.example/.localhost")]
    [InlineData("host: localhost:1@evil.example")]
    [InlineData("host: bücher.example")]
    [InlineData("host: app.test\r\nx-a: café")]
    public async Task Kestrel_refuses_a_host_that_is_not_one_and_bytes_outside_ascii_itself(string head)
    {
        await using var cw = new CronwatchClient(new CronwatchOptions { ProcessExitHook = false, Alerts = [] });
        var (app, port) = await StartAsync(cw);
        await using (app)
        {
            RawHttp.Answer a = await RawHttp.SendRawAsync(port, Encoding.Latin1.GetBytes("GET /cronwatch/ HTTP/1.1\r\n" + head + "\r\nconnection: close\r\n\r\n"));
            Assert.Equal(400, a.Status);
            await app.StopAsync();
        }
    }

    [Fact]
    public async Task Kestrel_refuses_a_target_outside_ascii_and_passes_a_bad_escape_through()
    {
        await using var cw = new CronwatchClient(new CronwatchOptions { ProcessExitHook = false, Alerts = [] });
        var (app, port) = await StartAsync(cw);
        await using (app)
        {
            RawHttp.Answer raw = await RawHttp.SendRawAsync(port, Encoding.Latin1.GetBytes("GET /cronwatch/jobs/é HTTP/1.1\r\nhost: app.test\r\nconnection: close\r\n\r\n"));
            Assert.Equal(400, raw.Status);
            RawHttp.Answer escaped = await RawHttp.SendAsync(port, "GET", "/cronwatch/api/jobs/%zz", Bearer, null);
            Assert.Equal(400, escaped.Status);
            Assert.Equal("{\"ok\":false,\"error\":\"Bad path\"}", escaped.Text);
            await app.StopAsync();
        }
    }

    /// <summary>
    /// A mount whose path is percent-encoded on the wire, by a literal of the app's (<c>/ops tools</c>)
    /// or a route group's parameter: the routes find their base in the target as sent, so they
    /// serve under it, and the sign-in cookie's path is the one the browser sends.
    /// </summary>
    [Fact]
    public async Task A_mount_percent_encoded_on_the_wire_is_the_base_as_sent()
    {
        await using var cw = new CronwatchClient(new CronwatchOptions { ProcessExitHook = false, Alerts = [] });
        WebApplicationBuilder b = WebApplication.CreateSlimBuilder();
        b.Logging.ClearProviders();
        b.Services.AddSingleton(cw);
        b.WebHost.UseKestrel(k => k.Listen(IPAddress.Loopback, 0));
        await using WebApplication app = b.Build();
        app.UseCronwatch("/mw tools", new RoutesOptions { Token = "tok" });
        app.MapCronwatch("/ops tools", new RoutesOptions { Token = "tok" });
        app.MapGroup("/{tenant}/admin").MapCronwatch("/cronwatch", new RoutesOptions { Token = "tok" });
        await app.StartAsync();
        int port = GoldenTests.PortOf(app);

        RawHttp.Answer literal = await RawHttp.SendAsync(port, "GET", "/ops%20tools/api/jobs", Bearer, null);
        Assert.Equal(200, literal.Status);
        Assert.Equal("{\"ok\":true,\"jobs\":[]}", literal.Text);
        RawHttp.Answer middleware = await RawHttp.SendAsync(port, "GET", "/mw%20tools/api/jobs", Bearer, null);
        Assert.Equal(200, middleware.Status);

        RawHttp.Answer signIn = await RawHttp.SendAsync(port, "GET", "/acme%3B%20co/admin/cronwatch/?token=tok", [], null);
        Assert.Equal(303, signIn.Status);
        Assert.Equal("/acme%3B%20co/admin/cronwatch/", signIn.Header("location"));
        Assert.Contains("; Path=/acme%3B%20co/admin/cronwatch; HttpOnly;", signIn.Header("set-cookie"), System.StringComparison.Ordinal);
        await app.StopAsync();
    }
}
