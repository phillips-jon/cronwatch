using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Threading.Tasks;
using Cronwatch.Web;
using Cronwatch.WebTest;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Http.Features;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using Xunit;
using CronwatchResponse = Cronwatch.Web.CronwatchResponse;

namespace Cronwatch.AspNetCore.Tests;

/// <summary>
/// The golden replay three ways: straight into the routes, through ASP.NET Core's test server
/// (behind <c>MapCronwatch</c> in a route group, and behind <c>UseCronwatch</c>), and through a
/// real Kestrel over a raw socket, so header order and casing are seen as Kestrel sends them.
/// </summary>
public class GoldenTests
{
    private static readonly RoutesOptions Options = new() { Token = "tok" };

    [Fact]
    public async Task Every_capture_matches_straight_into_the_routes()
    {
        await using Seeded seeded = await Golden.SeedAsync();
        int matched = await Golden.IntoRoutesAsync(seeded, seeded.Client.Routes(new RoutesOptions { Token = "tok", BasePath = "/cronwatch" }));
        Assert.Equal(Golden.CaptureCount, matched);
    }

    [Fact]
    public async Task Every_capture_matches_straight_into_the_routes_with_the_base_from_the_mount()
    {
        await using Seeded seeded = await Golden.SeedAsync();
        Routes routes = seeded.Client.Routes(Options);
        var ids = new Golden.Ids();
        foreach (Capture c in Golden.Captures())
        {
            string path = await Golden.ResolveAsync(seeded.Client, c.Path);
            CronwatchResponse a = await routes.HandleAsync(Golden.Request(c, path, "/cronwatch/"));
            Golden.Compare(c, a.Status, a.Headers, a.Body.ToArray(), ids, new HashSet<string>());
        }
        Golden.NoErrors(seeded);
    }

    private static WebApplication App(Seeded seeded, bool testServer)
    {
        WebApplicationBuilder builder = WebApplication.CreateSlimBuilder();
        builder.Logging.ClearProviders();
        builder.Services.AddSingleton(seeded.Client);
        if (testServer)
        {
            builder.WebHost.UseTestServer();
        }
        else
        {
            builder.WebHost.UseKestrel(k => k.Listen(IPAddress.Loopback, 0));
        }
        return builder.Build();
    }

    /// <summary>Sends a capture through the test server with the target as sent, answering status, headers and body.</summary>
    private static async Task<(int Status, List<KeyValuePair<string, string>> Headers, byte[] Body)> ThroughTestServerAsync(TestServer server, Capture c, string target)
    {
        HttpContext context = await server.SendAsync(ctx =>
        {
            int q = target.IndexOf('?', StringComparison.Ordinal);
            ctx.Request.Method = c.Method;
            ctx.Request.Path = PathString.FromUriComponent(q < 0 ? target : target[..q]);
            ctx.Request.QueryString = q < 0 ? QueryString.Empty : new QueryString(target[q..]);
            ctx.Features.Get<IHttpRequestFeature>()!.RawTarget = target;
            ctx.Request.Headers.Host = "app.test";
            foreach (var h in c.Headers)
            {
                ctx.Request.Headers.Append(h.Key, h.Value);
            }
            if (c.BodyBytes is { } body)
            {
                ctx.Request.Body = new MemoryStream(body);
                ctx.Request.ContentLength = body.Length;
            }
        });
        var headers = new List<KeyValuePair<string, string>>();
        foreach (var h in context.Response.Headers)
        {
            foreach (string? v in h.Value)
            {
                headers.Add(new(h.Key, v ?? ""));
            }
        }
        var output = new MemoryStream();
        await context.Response.Body.CopyToAsync(output);
        return (context.Response.StatusCode, headers, output.ToArray());
    }

    private static async Task ReplayThroughTestServerAsync(Seeded seeded, WebApplication app)
    {
        await app.StartAsync();
        try
        {
            TestServer server = app.GetTestServer();
            var ids = new Golden.Ids();
            int matched = 0;
            foreach (Capture c in Golden.Captures())
            {
                string path = await Golden.ResolveAsync(seeded.Client, c.Path);
                var (status, headers, body) = await ThroughTestServerAsync(server, c, path);
                Golden.Compare(c, status, headers, body, ids, new HashSet<string> { "content-length" });
                matched++;
            }
            Golden.NoErrors(seeded);
            Assert.Equal(Golden.CaptureCount, matched);
        }
        finally
        {
            await app.StopAsync();
        }
    }

    [Fact]
    public async Task Every_capture_matches_through_the_test_server_behind_MapCronwatch_in_a_route_group()
    {
        await using Seeded seeded = await Golden.SeedAsync();
        await using WebApplication app = App(seeded, testServer: true);
        app.MapGroup("/cronwatch").MapCronwatch("", Options);
        await ReplayThroughTestServerAsync(seeded, app);
    }

    [Fact]
    public async Task Every_capture_matches_through_the_test_server_behind_UseCronwatch()
    {
        await using Seeded seeded = await Golden.SeedAsync();
        await using WebApplication app = App(seeded, testServer: true);
        app.UseCronwatch("/cronwatch", Options);
        await ReplayThroughTestServerAsync(seeded, app);
    }

    internal static int PortOf(WebApplication app) =>
        new Uri(app.Services.GetRequiredService<IServer>().Features.Get<IServerAddressesFeature>()!.Addresses.First()).Port;

    [Fact]
    public async Task Every_capture_matches_through_Kestrel_over_a_socket()
    {
        await using Seeded seeded = await Golden.SeedAsync();
        await using WebApplication app = App(seeded, testServer: false);
        app.MapCronwatch("/cronwatch", Options);
        await app.StartAsync();
        try
        {
            // Kestrel passes /cronwatch/jobs/%zz through to the app, so no capture is refused.
            int matched = await Golden.ThroughServerAsync(seeded, PortOf(app), Golden.ServerHeaders, new HashSet<string>());
            Assert.Equal(Golden.CaptureCount, matched);
        }
        finally
        {
            await app.StopAsync();
        }
    }
}
