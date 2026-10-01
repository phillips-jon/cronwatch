using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;
using System.Threading.Tasks;
using Cronwatch.Internal;
using Cronwatch.Web;
using Xunit;

namespace Cronwatch.Tests.Web;

/// <summary>
/// A request, the door the dashboard's untrusted input comes through: any method, target, headers
/// and body, in five configurations of the routes, is answered without a throw and without a 500
/// (the routes catch a throw and answer 500, so a 500 here is a bug), and reports nothing. The
/// origin reader, which reads a <c>Host</c> and forwarded headers anyone can send, answers any
/// text. <c>CRONWATCH_TRIES=N</c> multiplies the tries; a failure names its seed.
/// </summary>
public class RoutesProperties
{
    private static readonly string[] Methods = ["GET", "POST", "DELETE", "HEAD", "PUT", "get", "OPTIONS"];

    private static readonly string[] Paths =
    [
        "/cronwatch", "/", "/cronwatch/", "/cronwatch/api/", "jobs/", "api/jobs/", "x", "%2F", "%zz", "%e9", "..", "./", "\\",
        "silence", "unsilence", "forget", "check", "runs/", "?", "&", "=", "token=tok", "runs=", "for=", "#", "é",
        "manifest.webmanifest", "icons/",
    ];

    private static readonly string[] Names =
    [
        "host", "authorization", "cookie", "origin", "referer", "content-type", "sec-fetch-site", "x-forwarded-proto", "x-forwarded-host",
    ];

    private static readonly string[] Values =
    [
        "Bearer tok", "bearer ", "cronwatch_token=", "http://app.test", "https://", "[::1]", "localhost:1@", "application/json",
        "application/x-www-form-urlencoded", "multipart/form-data; boundary=b", "same-origin", "none", ",", ";", "%", "é",
        "0x7f.1", "xn--", "evil.example/.localhost",
    ];

    private static readonly string[] Bodies =
    [
        "for=", "1h", "{\"for\":", "\"2h\"", "}", "[", "]", "--b\r\n", "Content-Disposition: form-data; name=\"for\"\r\n\r\n", "--b--", "&",
        new string('9', 30), "e", "%",
    ];

    private static int Scale =>
        int.TryParse(Environment.GetEnvironmentVariable("CRONWATCH_TRIES"), NumberStyles.None, CultureInfo.InvariantCulture, out int n) && n > 0 ? n : 1;

    [Fact]
    public async Task Any_request_is_answered_without_a_500()
    {
        RoutesOptions[] configurations =
        [
            new() { Token = "tok", BasePath = "/cronwatch" },
            new() { Token = DashboardToken.None },
            new() { Token = "tok", BasePath = "", TrustProxy = true },
            new() { Token = "tok", Origin = "https://app.example.com" },
            new() { Token = DashboardToken.None, BasePath = "/a/b/", TrustProxy = true },
        ];
        for (int c = 0; c < configurations.Length; c++)
        {
            await using var w = new WebKit(configurations[c]);
            await w.Ok("x");
            for (int t = 0; t < 150 * Scale; t++)
            {
                int seed = HashCode.Combine(100 + c, t);
                var g = new JsreGen(seed);
                string target = g.Bool() ? g.Joined(Paths, 8) : "/cronwatch/" + g.AnyString(30);
                var headers = new List<KeyValuePair<string, string>>();
                int n = g.Int(7);
                for (int i = 0; i < n; i++)
                {
                    headers.Add(new(Names[g.Int(Names.Length)], g.Bool() ? g.Joined(Values, 4) : g.AnyString(20)));
                }
                string method = Methods[g.Int(Methods.Length)];
                bool tls = g.Bool();
                byte[]? body = g.Bool() ? Encoding.UTF8.GetBytes(g.Bool() ? g.Joined(Bodies, 10) : g.AnyString(60)) : null;
                var request = body == null
                    ? new CronwatchRequest(method, target) { Headers = headers, IsTls = tls }
                    : new CronwatchRequest(method, target) { Headers = headers, IsTls = tls, Body = body };
                CronwatchResponse r = await w.Routes.HandleAsync(request);
                Assert.True(r.Status != 500, "seed " + seed.ToString(CultureInfo.InvariantCulture) + " answered 500: " + r.Text());
            }
            Assert.True(w.Wheres().Count == 0, "reported: " + string.Join("; ", w.Messages()));
        }
    }

    [Fact]
    public void Any_origin_text_is_read_or_refused()
    {
        for (int t = 0; t < 2000 * Scale; t++)
        {
            int seed = HashCode.Combine(7, t);
            var g = new JsreGen(seed);
            string text = g.Bool() ? g.Joined(Values, 6) : g.AnyString(40);
            try
            {
                string? read = Origins.Bare(text);
                if (read != null)
                {
                    Assert.Equal(read, Origins.Bare(read));
                }
                Origins.IsLoopback(text);
                Origins.OfRequest(g.Bool(), text);
                try
                {
                    Origins.Configured(text);
                }
                catch (ArgumentException e)
                {
                    Assert.StartsWith("routes: origin must be ", e.Message, StringComparison.Ordinal);
                }
            }
            catch (Exception e) when (e is not Xunit.Sdk.XunitException)
            {
                throw new InvalidOperationException("the property failed for seed " + seed.ToString(CultureInfo.InvariantCulture) + " on " + JsonText.Quote(text), e);
            }
        }
    }
}
