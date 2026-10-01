using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using Cronwatch;
using Cronwatch.Web;

// The cases of RoutesEnvTests, each run as a child process with the variables it needs, since
// the environment is shared by every test in a process. A case that fails exits 1 with what it
// found; the parent reads what it printed, as the sign-in line goes to standard output.
try
{
    switch (args[0])
    {
        case "locked":
            await Cases.Locked();
            break;
        case "developmentToken":
            await Cases.DevelopmentToken();
            break;
        case "emptyToken":
            await Cases.EmptyToken();
            break;
        case "openInDevelopment":
            await Cases.OpenInDevelopment();
            break;
        case "configuredInDevelopment":
            await Cases.ConfiguredInDevelopment();
            break;
        case "signInLines":
            await Cases.SignInLines();
            break;
        case "handlerClosed":
            await Cases.HandlerClosed();
            break;
        case "handlerDevelopment":
            await Cases.HandlerDevelopment();
            break;
        case "environmentFallback":
            await Cases.EnvironmentFallback();
            break;
        case "givenOverDotNet":
            await Cases.GivenOverDotNet();
            break;
        case "dotNetOrder":
            await Cases.DotNetOrder();
            break;
        default:
            throw new ArgumentException(args[0]);
    }
    Console.Out.Write("CHILD OK\n");
    return 0;
}
catch (Exception e)
{
    Console.Out.Write(e + "\n");
    return 1;
}

internal static class Cases
{
    private static readonly List<KeyValuePair<string, string>> None = [];

    private static void Check(bool ok, string what)
    {
        if (!ok)
        {
            throw new InvalidOperationException("failed: " + what);
        }
    }

    private static CronwatchClient Client(string? environment = null) =>
        new(new CronwatchOptions { CronSecret = CronSecret.None, ProcessExitHook = false, Alerts = [], Environment = environment });

    /// <summary>A request for a full URL, as a server would hand it over.</summary>
    private static Task<CronwatchResponse> Serve(Routes routes, string url, IEnumerable<KeyValuePair<string, string>> headers)
    {
        bool tls = url.StartsWith("https://", StringComparison.Ordinal);
        string rest = url[(url.IndexOf("://", StringComparison.Ordinal) + 3)..];
        int slash = rest.IndexOf('/', StringComparison.Ordinal);
        var all = new List<KeyValuePair<string, string>> { new("host", slash < 0 ? rest : rest[..slash]) };
        all.AddRange(headers);
        return routes.HandleAsync(new CronwatchRequest("GET", slash < 0 ? "/" : rest[slash..]) { Headers = all, IsTls = tls });
    }

    private static KeyValuePair<string, string> H(string name, string value) => new(name, value);

    public static async Task Locked()
    {
        await using var cw = Client();
        Routes routes = cw.Routes();
        Check(routes.Token() == null, "no token");
        CronwatchResponse api = await Serve(routes, "http://localhost/cronwatch/api/jobs", None);
        Check(api.Status == 503, "api 503");
        Check(api.Text() == "{\"ok\":false,\"error\":\"CRONWATCH_TOKEN is not set\"}", api.Text());
        CronwatchResponse page = await Serve(routes, "http://localhost/cronwatch", None);
        Check(page.Status == 503, "page 503");
        Check(page.Text().Contains("CronWatch routes are locked", StringComparison.Ordinal), "locked page");
        Check(page.Text().Contains("DashboardToken.None", StringComparison.Ordinal), "names the opt-out");
        Check(page.Text().Contains("RoutesOptions.Token", StringComparison.Ordinal), "names the option");
        // The app shell is public even so.
        foreach (string path in new[] { "/manifest.webmanifest", "/sw.js", "/app.js", "/offline", "/icons/icon.svg" })
        {
            Check((await Serve(routes, "http://localhost/cronwatch" + path, None)).Status == 200, path);
        }
    }

    public static async Task DevelopmentToken()
    {
        await using var cw = Client();
        Routes routes = cw.Routes(new RoutesOptions { BasePath = "/cronwatch/" });
        (string Url, KeyValuePair<string, string>? Header)[] urls =
        [
            ("http://localhost:3000/cronwatch/api/jobs", null),
            ("http://localhost:3000/cronwatch/api/jobs", H("x-forwarded-for", "127.0.0.1")),
            ("http://127.0.0.1:3000/cronwatch/", null),
            ("http://192.168.1.20:3000/cronwatch/api/jobs", null),
            ("http://[::1]:3000/cronwatch/api/jobs", H("x-real-ip", "127.0.0.1")),
        ];
        foreach (var (url, header) in urls)
        {
            Check((await Serve(routes, url, header is { } h ? [h] : None)).Status == 401, url);
        }
        string token = routes.Token()!;
        Console.Out.Write("TOKEN " + token + "\n");
        CronwatchResponse page = await Serve(routes, "http://localhost:3000/cronwatch/", None);
        Check(page.Text().Contains("sign-in link is in the server log", StringComparison.Ordinal), "the page says where");
        CronwatchResponse api = await Serve(routes, "http://localhost:3000/cronwatch/api/jobs", None);
        Check(api.Text().Contains("in the server log", StringComparison.Ordinal), "the api says where");
        CronwatchResponse signIn = await Serve(routes, "http://localhost:3000/cronwatch/?token=" + token, None);
        Check(signIn.Status == 303, "sign-in");
        Check(signIn.Header("location") == "/cronwatch/", "location");
        string setCookie = signIn.Header("set-cookie")!;
        string cookie = setCookie[..setCookie.IndexOf(';', StringComparison.Ordinal)];
        Check((await Serve(routes, "http://localhost:3000/cronwatch/", [H("cookie", cookie)])).Status == 200, "the cookie");
        Check((await Serve(routes, "http://localhost:3000/cronwatch/api/jobs", [H("authorization", "Bearer " + token)])).Status == 200, "the bearer");

        Routes other = cw.Routes(new RoutesOptions { BasePath = "/" });
        await Serve(other, "https://dev.example:8443/api/jobs", None);
    }

    private static async Task<int> Jobs(CronwatchClient cw, RoutesOptions options) =>
        (await Serve(cw.Routes(options), "http://app.test/cronwatch/api/jobs", None)).Status;

    public static async Task EmptyToken()
    {
        await using var cw = Client();
        Check(await Jobs(cw, new RoutesOptions()) == 503, "unset");
        Check(await Jobs(cw, new RoutesOptions { Token = "" }) == 503, "empty");
        Check(await Jobs(cw, new RoutesOptions { Token = DashboardToken.None }) == 200, "open");
    }

    public static async Task OpenInDevelopment()
    {
        await using var cw = Client();
        Check(await Jobs(cw, new RoutesOptions { Token = DashboardToken.None }) == 200, "open");
    }

    public static async Task ConfiguredInDevelopment()
    {
        await using var cw = Client();
        Check(await Jobs(cw, new RoutesOptions()) == 401, "the environment's token asked for");
        Routes routes = cw.Routes(new RoutesOptions { Token = "" });
        CronwatchResponse res = await Serve(routes, "http://app.test/cronwatch/api/jobs", [H("authorization", "Bearer envtok")]);
        Check(res.Status == 200, "the environment's token");
    }

    public static async Task SignInLines()
    {
        const string internalOrigin = "http://10.0.0.5:8080";
        List<KeyValuePair<string, string>> spoofed = [H("x-forwarded-proto", "https"), H("x-forwarded-host", "attacker.example")];
        await using var cw = Client();
        (RoutesOptions Options, string Url, List<KeyValuePair<string, string>> Headers)[] cases =
        [
            (new() { Origin = "https://app.example.com" }, internalOrigin + "/cronwatch/", None),
            (new() { Origin = "https://app.example.com", TrustProxy = true }, internalOrigin + "/cronwatch/", spoofed),
            (new(), "http://localhost:3000/cronwatch/", None),
            (new(), "http://app.localhost:3000/cronwatch/", None),
            (new(), "http://127.0.0.1:3000/cronwatch/", None),
            (new(), "http://127.8.9.10/cronwatch/", None),
            (new(), "http://[::1]:3000/cronwatch/", None),
            (new() { TrustProxy = true }, internalOrigin + "/cronwatch/", [H("x-forwarded-host", "localhost:5173")]),
            (new(), internalOrigin + "/cronwatch/", None),
            (new(), "https://app.example.com/cronwatch/", None),
            (new() { TrustProxy = true }, "http://localhost:3000/cronwatch/", spoofed),
            (new(), "http://localhost.example/cronwatch/", None),
            (new(), "http://128.0.0.1/cronwatch/", None),
            (new() { BasePath = "/" }, "http://attacker.example/", None),
        ];
        foreach (var (options, url, headers) in cases)
        {
            Routes routes = cw.Routes(options);
            await Serve(routes, url, headers);
            // Printed once per routes value, however many requests it answers.
            await Serve(routes, url, headers);
        }
        // A Host header that is not a host is not loopback, however it ends (the Rust audit): the
        // link leaves it out.
        foreach (string host in new[] { "evil.example/.localhost", "localhost:1@evil.example" })
        {
            Routes routes = cw.Routes();
            await routes.HandleAsync(new CronwatchRequest("GET", "/cronwatch/") { Headers = [H("host", host)] });
        }
    }

    public static async Task HandlerClosed()
    {
        int ran = 0;
        var wheres = new List<string>();
        var messages = new List<string>();
        await using (var cw = new CronwatchClient(new CronwatchOptions
        {
            CronSecret = "",
            ProcessExitHook = false,
            Alerts = [],
            OnError = (e, where) =>
            {
                lock (wheres)
                {
                    wheres.Add(where);
                    messages.Add(e.Message);
                }
            },
        }))
        {
            Handler h = cw.Job("closed").Handler((j, r, ct) =>
            {
                ran++;
                return Task.CompletedTask;
            });
            CronwatchResponse res = await h.HandleAsync(new CronwatchRequest("GET", "/"));
            Check(res.Status == 503, "503");
            Check(res.Text().Contains("CRON_SECRET is not set", StringComparison.Ordinal), res.Text());
            Check(res.Text().Contains("HandlerSecret.None", StringComparison.Ordinal), res.Text());
            Check(res.Header("content-type") == "application/json; charset=utf-8", "json");
            await h.HandleAsync(new CronwatchRequest("GET", "/"));
            Check(ran == 0, "ran");
            Check(wheres.Count == 1 && wheres[0] == "handler", "reported once: " + string.Join(", ", wheres));
            Check(messages[0].Contains("HandlerSecret.None", StringComparison.Ordinal), messages[0]);

            // Opting out runs the job, and does not show the error to the caller.
            Handler open = cw.Job("open").Handler(
                (j, r, ct) => Task.FromException(new InvalidOperationException("private detail")),
                new HandlerOptions { Secret = HandlerSecret.None });
            CronwatchResponse failed = await open.HandleAsync(new CronwatchRequest("GET", "/"));
            Check(failed.Status == 500, "500");
            Check(!failed.Text().Contains("error", StringComparison.Ordinal), failed.Text());
        }
        // A client made with CronSecret.None lets anyone in.
        await using var anyone = Client();
        Handler any = anyone.Job("any").Handler((j, r, ct) => Task.CompletedTask);
        Check((await any.HandleAsync(new CronwatchRequest("GET", "/"))).Status == 200, "anyone");
    }

    public static async Task HandlerDevelopment()
    {
        var wheres = new List<string>();
        await using var cw = new CronwatchClient(new CronwatchOptions
        {
            CronSecret = "",
            ProcessExitHook = false,
            Alerts = [],
            OnError = (e, where) =>
            {
                lock (wheres)
                {
                    wheres.Add(where);
                }
            },
        });
        Handler h = cw.Job("dev").Handler((j, r, ct) => Task.CompletedTask);
        Check((await h.HandleAsync(new CronwatchRequest("GET", "/"))).Status == 200, "development lets it run");
        Check(wheres.Count == 0, "nothing reported");
    }

    /// <summary>
    /// A stale <c>ASPNETCORE_ENVIRONMENT</c> or <c>DOTNET_ENVIRONMENT</c> of Development (the
    /// parent sets both) does not outrank the environment the app gives (a host's resolved
    /// <c>--environment Production</c>): the dashboard is locked and a handler without a secret
    /// fails closed.
    /// </summary>
    public static async Task GivenOverDotNet()
    {
        int ran = 0;
        await using var cw = new CronwatchClient(new CronwatchOptions
        {
            CronSecret = "",
            ProcessExitHook = false,
            Alerts = [],
            OnError = (e, where) => { },
            Environment = "Production",
        });
        Check(cw.Routes().Token() == null, "locked in production");
        Handler h = cw.Job("closed").Handler((j, r, ct) =>
        {
            ran++;
            return Task.CompletedTask;
        });
        Check((await h.HandleAsync(new CronwatchRequest("GET", "/"))).Status == 503, "503");
        Check(ran == 0, "ran");
        // With nothing given, the variables are read.
        await using var fallback = Client();
        Check(fallback.Routes().Token() != null, "development from the variables");
    }

    /// <summary>ASP.NET Core's order: <c>ASPNETCORE_ENVIRONMENT</c> (Production here) before <c>DOTNET_ENVIRONMENT</c> (Development).</summary>
    public static async Task DotNetOrder()
    {
        await using var cw = Client();
        Check(cw.Routes().Token() == null, "production from ASPNETCORE_ENVIRONMENT");
    }

    /// <summary>The environment an app gives, read when none of the variables says: a host's.</summary>
    public static async Task EnvironmentFallback()
    {
        await using (var cw = Client("Development"))
        {
            Check(cw.Routes().Token() != null, "a development token from the fallback");
        }
        await using (var cw = Client("Production"))
        {
            Check(cw.Routes().Token() == null, "locked in production");
        }
    }
}
