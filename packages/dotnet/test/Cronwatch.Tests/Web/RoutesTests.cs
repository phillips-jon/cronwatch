using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch.Web;
using Xunit;
using static Cronwatch.Tests.Support;

namespace Cronwatch.Tests.Web;

/// <summary>
/// What the dashboard and handler tests share: a client on a clock the test drives, whose alerts
/// and errors are kept (the SDK tests' <c>make()</c>), its routes, and a way to send them a
/// request for a full URL as a server would hand it over.
/// </summary>
internal sealed class WebKit : IAsyncDisposable
{
    public static readonly KeyValuePair<string, string> Auth = new("authorization", "Bearer tok");
    public static readonly KeyValuePair<string, string> Form = new("content-type", "application/x-www-form-urlencoded");
    public static readonly KeyValuePair<string, string> JsonType = new("content-type", "application/json");

    public WebKit(RoutesOptions? options = null, IStore? store = null)
    {
        M = Make(store: store);
        Routes = M.Cw.Routes(options ?? new RoutesOptions { Token = "tok", BasePath = "/cronwatch" });
    }

    public Made M { get; }

    public CronwatchClient Cw => M.Cw;

    public Routes Routes { get; }

    public ValueTask DisposeAsync() => M.DisposeAsync();

    public void Advance(long ms) => M.Clock.Advance(ms);

    /// <summary>Runs a job that succeeds.</summary>
    public Task Ok(string name) => Cw.RunAsync(name, (j, ct) => Task.CompletedTask);

    public Task<JobSummary?> Summary(string name) => Cw.JobSummaryAsync(name);

    public List<string> Wheres() => M.Errors.Wheres();

    public List<string> Messages() => M.Errors.Messages();

    public static KeyValuePair<string, string> H(string name, string value) => new(name, value);

    public static List<KeyValuePair<string, string>> Headers(params KeyValuePair<string, string>[] pairs) => [.. pairs];

    public static List<KeyValuePair<string, string>> With(params List<KeyValuePair<string, string>>[] sets) => sets.SelectMany(s => s).ToList();

    /// <summary>A request for a full URL, as a server would hand it over.</summary>
    public static WebRequest Request(string method, string url, IEnumerable<KeyValuePair<string, string>> headers, string body, string? mount = null)
    {
        bool tls = url.StartsWith("https://", StringComparison.Ordinal);
        string rest = url[(url.IndexOf("://", StringComparison.Ordinal) + 3)..];
        int slash = rest.IndexOf('/', StringComparison.Ordinal);
        string host = slash < 0 ? rest : rest[..slash];
        string path = slash < 0 ? "/" : rest[slash..];
        var all = new List<KeyValuePair<string, string>> { new("host", host) };
        all.AddRange(headers);
        return body.Length > 0
            ? new WebRequest(method, path) { Headers = all, IsTls = tls, Body = Encoding.UTF8.GetBytes(body), Mount = mount }
            : new WebRequest(method, path) { Headers = all, IsTls = tls, Mount = mount };
    }

    public static Task<WebResponse> Serve(Routes routes, string method, string url, IEnumerable<KeyValuePair<string, string>> headers, string body = "") =>
        routes.HandleAsync(Request(method, url, headers, body));

    public Task<WebResponse> Send(string method, string path, IEnumerable<KeyValuePair<string, string>> headers, string body = "") =>
        Serve(Routes, method, "http://app.test" + path, headers, body);

    public Task<WebResponse> Get(string path, params KeyValuePair<string, string>[] headers) => Send("GET", path, headers);

    public static JsObject JsonOf(WebResponse r)
    {
        object? v = Json.Parse(r.Text());
        return Assert.IsType<JsObject>(v);
    }

    public static object? Field(JsObject o, params string[] path)
    {
        object? v = o;
        foreach (string key in path)
        {
            var x = Assert.IsType<JsObject>(v);
            Assert.True(x.Has(key), "no " + key + " in " + o.ToJson());
            v = x.Get(key);
        }
        return v;
    }

    public static void Status(string what, WebResponse r, int want)
    {
        string text = r.Text();
        Assert.True(r.Status == want, what + ": " + r.Status + ", want " + want + ": " + text[..Math.Min(300, text.Length)]);
    }

    public static void Contains(string what, string? text, string want)
    {
        text ??= "";
        Assert.True(text.Contains(want, StringComparison.Ordinal), what + ": " + want + " is not in " + text[..Math.Min(600, text.Length)]);
    }

    /// <summary>The cookie the routes set for the token <c>tok</c>.</summary>
    public static string TokenCookie() =>
        "cronwatch_token=" + Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes("cronwatch-cookie:tok")));
}

/// <summary>
/// The SDK's routes tests, as the Go, Rust, Elixir and Java ports have them, with their audits'
/// cases: the body cap, a body cut short, a body nested deeply, a long host outside ASCII, huge
/// durations, and the base path from the mount. What needs an environment of its own (locked,
/// the development token) is in <see cref="RoutesEnvTests"/>.
/// </summary>
public class RoutesTests
{
    private static readonly KeyValuePair<string, string> Auth = WebKit.Auth;
    private static readonly KeyValuePair<string, string> Form = WebKit.Form;
    private static readonly KeyValuePair<string, string> JsonType = WebKit.JsonType;

    private static KeyValuePair<string, string> H(string n, string v) => WebKit.H(n, v);

    private static List<KeyValuePair<string, string>> Hs(params KeyValuePair<string, string>[] p) => WebKit.Headers(p);

    private static void Status(string what, WebResponse r, int want) => WebKit.Status(what, r, want);

    private static void Contains(string what, string? text, string want) => WebKit.Contains(what, text, want);

    [Fact]
    public async Task Everything_needs_the_token()
    {
        await using var w = new WebKit();
        Status("page", await w.Get("/cronwatch"), 401);
        Status("api", await w.Get("/cronwatch/api/jobs"), 401);
        Status("wrong", await w.Get("/cronwatch/api/jobs", H("authorization", "Bearer wrong")), 401);
        Status("right", await w.Get("/cronwatch/api/jobs", Auth), 200);
        Status("any case and spaces", await w.Get("/cronwatch/api/jobs", H("authorization", "bEaReR \t tok")), 200);
        Assert.Equal("tok", w.Routes.Token());
    }

    [Fact]
    public async Task Check_accepts_the_cron_secret_and_nothing_else_does()
    {
        const string secret = "cron-check-word";
        await using var cw = new CronwatchClient(new CronwatchOptions { CronSecret = secret, ProcessExitHook = false, Alerts = [], Clock = Clock() });
        Routes routes = cw.Routes(new RoutesOptions { Token = "tok" });
        var bearer = Hs(H("authorization", "Bearer " + secret));
        Status("check", await WebKit.Serve(routes, "GET", "http://app.test/cronwatch/api/check", bearer), 200);
        Status("jobs", await WebKit.Serve(routes, "GET", "http://app.test/cronwatch/api/jobs", bearer), 401);
        Status("only as a bearer", await WebKit.Serve(routes, "GET", "http://app.test/cronwatch/api/check?token=" + secret, []), 401);
    }

    [Fact]
    public async Task Sign_in_sets_a_cookie_and_redirects_to_a_clean_url()
    {
        await using var w = new WebKit();
        string cookie = WebKit.TokenCookie();
        WebResponse res = await w.Get("/cronwatch/?token=tok");
        Status("sign-in", res, 303);
        Assert.Equal("/cronwatch/", res.Header("location"));
        string set = res.Header("set-cookie")!;
        Assert.Equal(cookie, set[..set.IndexOf(';', StringComparison.Ordinal)]);
        Contains("cookie", set, "; Path=/cronwatch; HttpOnly; SameSite=Lax; Max-Age=2592000");
        WebResponse page = await w.Get("/cronwatch/", H("cookie", "other=1; " + cookie));
        Status("with the cookie", page, 200);
        Contains("type", page.Header("content-type"), "text/html");
        Status("the raw token is not a cookie", await w.Get("/cronwatch/", H("cookie", "cronwatch_token=tok")), 401);
        // HTTP/2 may send each cookie as a header of its own.
        Status("split cookies", await w.Get("/cronwatch/", H("cookie", "other=1"), H("cookie", cookie)), 200);
        WebResponse other = await w.Get("/cronwatch/jobs/x?view=all&token=tok&a=b+c");
        Assert.Equal("/cronwatch/jobs/x?view=all&a=b+c", other.Header("location"));
    }

    [Fact]
    public async Task Pages_render_and_the_api_answers()
    {
        await using var w = new WebKit();
        Job job = w.Cw.Job("nightly-report", new JobOptions { Schedule = "0 2 * * *", Description = "Builds the PDF" });
        await job.RunAsync((j, ct) =>
        {
            j.Log("built");
            w.Advance(2000);
            return Task.CompletedTask;
        });
        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            w.Cw.RunAsync("broken", (j, ct) => Task.FromException(new InvalidOperationException("kaboom <script>"))));

        string dash = (await w.Get("/cronwatch", Auth)).Text();
        foreach (string want in new[]
        {
            "nightly-report",
            "Builds the PDF",
            "healthy",
            "failing",
            "<p class=\"headline\">2 jobs, <b>1 needing attention</b>.</p>",
            "<div class=\"bad\"><dt><i class=\"sq bad\" aria-hidden=\"true\"></i>failing</dt><dd>1</dd></div>",
            "<figure class=\"timeline day\">",
            "<table class=\"board\">",
            "<form class=\"inline\" method=\"post\" action=\"/cronwatch/check\"><button class=\"primary\" type=\"submit\">Run check now</button></form>",
        })
        {
            Contains("dashboard", dash, want);
        }
        WebResponse page = await w.Get("/cronwatch/jobs/broken", Auth);
        Status("job page", page, 200);
        string html = page.Text();
        Contains("escaped", html, "kaboom &lt;script&gt;");
        Assert.DoesNotContain("<script>", html, StringComparison.Ordinal);
        Contains("heading", html, "<h1 class=\"jobname\">broken</h1>");
        Contains("week", html, "<figure class=\"timeline week\">");
        Contains("error", html, "<details class=\"out error\" open><summary>error</summary><pre>InvalidOperationException: kaboom &lt;script&gt;");

        JsObject list = WebKit.JsonOf(await w.Get("/cronwatch/api/jobs", Auth));
        Assert.Equal(2, ((List<object?>)WebKit.Field(list, "jobs")!).Count);
        JsObject one = WebKit.JsonOf(await w.Get("/cronwatch/api/jobs/nightly-report?runs=5", Auth));
        Assert.Equal("healthy", WebKit.Field(one, "job", "health"));
        var runs = (List<object?>)WebKit.Field(one, "runs")!;
        Assert.Single(runs);
        Assert.Equal("built", ((JsObject)runs[0]!).Get("output"));
        Status("api missing", await w.Get("/cronwatch/api/jobs/missing", Auth), 404);
        Status("page missing", await w.Get("/cronwatch/jobs/missing", Auth), 404);
        Status("nope", await w.Get("/cronwatch/nope", Auth), 404);
        string runId = (string)((JsObject)runs[0]!).Get("id")!;
        JsObject run = WebKit.JsonOf(await w.Get("/cronwatch/api/runs/" + runId, Auth));
        Assert.Equal("nightly-report", WebKit.Field(run, "run", "job"));
    }

    [Fact]
    public async Task Names_break_after_their_separators_only_as_text()
    {
        await using var w = new WebKit();
        const string name = "wp:store_sync.inventory--eu";
        await w.Ok(name);
        const string shown = "wp:<wbr>store_<wbr>sync.<wbr>inventory--<wbr>eu";
        const string href = "/cronwatch/jobs/wp%3Astore_sync.inventory--eu";
        string dash = (await w.Get("/cronwatch", Auth)).Text();
        Contains("the lane", dash, "<a class=\"name\" href=\"" + href + "\">" + shown + "</a><span class=\"sched\">");
        Contains("the board", dash, "<td class=\"job\"><a class=\"name\" href=\"" + href + "\">" + shown + "</a></td>");
        Contains("the words", dash, "<li>wp:store_sync.inventory--eu (");
        string page = (await w.Get(href, Auth)).Text();
        Contains("crumb", page, "<span class=\"crumb\">" + shown + "</span>");
        Contains("heading", page, "<h1 class=\"jobname\">" + shown + "</h1>");
        Contains("title", page, "<title>wp:store_sync.inventory--eu: CronWatch</title>");
        Contains("marks", page, "<title>wp:store_sync.inventory--eu, ");
        Assert.Equal(8, page.Split("<wbr>").Length - 1);
    }

    [Fact]
    public async Task Api_writes()
    {
        await using var w = new WebKit();
        await w.Ok("s");
        JsObject result = WebKit.JsonOf(await w.Send("POST", "/cronwatch/api/check", Hs(Auth, JsonType)));
        Assert.Equal(true, WebKit.Field(result, "ok"));
        Assert.Single((List<object?>)WebKit.Field(result, "jobs")!);
        JsObject silenced = WebKit.JsonOf(await w.Send("POST", "/cronwatch/api/jobs/s/silence", Hs(Auth, JsonType), "{\"for\":\"2h\"}"));
        Assert.Equal((double)(T0 + (2 * Hour)), WebKit.Field(silenced, "state", "silencedUntil"));
        Assert.Equal(JobHealth.Silenced, (await w.Summary("s"))!.Health);
        JsObject un = WebKit.JsonOf(await w.Send("POST", "/cronwatch/api/jobs/s/unsilence", Hs(Auth, JsonType)));
        Assert.Null(WebKit.Field(un, "state", "silencedUntil"));
        Status("ghost", await w.Send("POST", "/cronwatch/api/jobs/nope/silence", Hs(Auth, JsonType), "{\"for\":\"1h\"}"), 404);
        Status("delete", await w.Send("DELETE", "/cronwatch/api/jobs/s", Hs(Auth)), 200);
        Assert.Null(await w.Summary("s"));
        Status("delete again", await w.Send("DELETE", "/cronwatch/api/jobs/s", Hs(Auth)), 404);
    }

    [Fact]
    public async Task Forms_post_and_redirect_back()
    {
        await using var w = new WebKit();
        await w.Ok("f");
        WebResponse res = await w.Send("POST", "/cronwatch/jobs/f/silence", Hs(Auth, Form, H("referer", "http://app.test/cronwatch/jobs/f")), "for=4h");
        Status("silence", res, 303);
        Assert.Equal("http://app.test/cronwatch/jobs/f", res.Header("location"));
        Assert.Equal(JobHealth.Silenced, (await w.Summary("f"))!.Health);
        WebResponse elsewhere = await w.Send("POST", "/cronwatch/jobs/f/unsilence", Hs(Auth, H("referer", "https://evil.example/phish")));
        Assert.Equal("/cronwatch/", elsewhere.Header("location"));
        const string multipart = "--b\r\nContent-Disposition: form-data; name=\"for\"\r\n\r\n2h\r\n--b--\r\n";
        res = await w.Send("POST", "/cronwatch/jobs/f/silence", Hs(Auth, H("content-type", "multipart/form-data; boundary=b")), multipart);
        Status("multipart", res, 303);
        Assert.Equal(T0 + (2 * Hour), (await w.Summary("f"))!.SilencedUntil);
        Status("forget", await w.Send("POST", "/cronwatch/jobs/f/forget", Hs(Auth)), 303);
        Assert.Null(await w.Summary("f"));
    }

    [Fact]
    public async Task Cross_site_writes_are_refused()
    {
        await using var w = new WebKit();
        await w.Ok("x");
        var cookie = H("cookie", WebKit.TokenCookie());
        foreach (var hs in new[]
        {
            Hs(H("origin", "https://evil.example")),
            Hs(H("origin", "null")),
            Hs(H("sec-fetch-site", "cross-site")),
            Hs(H("sec-fetch-site", "same-site")),
            Hs(H("origin", "http://app.test"), H("sec-fetch-site", "cross-site")),
        })
        {
            Status("form", await w.Send("POST", "/cronwatch/jobs/x/silence", WebKit.With(Hs(cookie, Form), hs), "for=1h"), 403);
            Status("check", await w.Send("POST", "/cronwatch/api/check", WebKit.With(Hs(Auth), hs)), 403);
            Status("delete", await w.Send("DELETE", "/cronwatch/api/jobs/x", WebKit.With(Hs(cookie), hs)), 403);
        }
        Assert.Null((await w.Summary("x"))!.SilencedUntil);
        var same = Hs(H("origin", "http://app.test"), H("sec-fetch-site", "same-origin"), H("referer", "http://app.test/cronwatch/jobs/x"));
        Status("run check now", await w.Send("POST", "/cronwatch/check", WebKit.With(Hs(cookie), same)), 303);
        Status("api client", await w.Send("POST", "/cronwatch/api/jobs/x/unsilence", Hs(Auth)), 200);
        Status("none", await w.Send("POST", "/cronwatch/api/check", Hs(Auth, H("sec-fetch-site", "none"))), 200);
        WebResponse refused = await w.Send("POST", "/cronwatch/api/check", Hs(Auth, H("origin", "https://evil.example")));
        Assert.Equal("{\"ok\":false,\"error\":\"Cross-site request refused\"}", refused.Text());
    }

    [Fact]
    public async Task Get_check_needs_a_bearer_and_query_tokens_only_sign_in()
    {
        await using var w = new WebKit();
        await w.Ok("x");
        var cookie = H("cookie", WebKit.TokenCookie());
        WebResponse viaCookie = await w.Get("/cronwatch/api/check", cookie);
        Status("cookie GET", viaCookie, 405);
        Assert.Equal("POST", viaCookie.Header("allow"));
        Status("cookie POST", await w.Send("POST", "/cronwatch/api/check", Hs(cookie)), 200);
        Status("bearer GET", await w.Get("/cronwatch/api/check", Auth), 200);
        Status("api", await w.Get("/cronwatch/api/jobs?token=tok"), 401);
        Status("api job", await w.Get("/cronwatch/api/jobs/x?token=tok"), 401);
        Status("api check", await w.Send("POST", "/cronwatch/api/check?token=tok", []), 401);
        Status("check", await w.Send("POST", "/cronwatch/check?token=tok", []), 401);
        Status("forget", await w.Send("POST", "/cronwatch/jobs/x/forget?token=tok", []), 401);
        Assert.NotNull(await w.Summary("x"));
        Status("page", await w.Get("/cronwatch/jobs/x?token=tok"), 303);
    }

    [Fact]
    public async Task Malformed_cookies_and_paths_are_answered()
    {
        await using var w = new WebKit();
        Status("cookie", await w.Get("/cronwatch/", H("cookie", "cronwatch_token=%E0%A4%A")), 401);
        Status("cookie %", await w.Get("/cronwatch/api/jobs", H("cookie", "cronwatch_token=%")), 401);
        Status("path", await w.Get("/cronwatch/jobs/%E0%A4%A", Auth), 400);
        WebResponse api = await w.Get("/cronwatch/api/jobs/%zz", Auth);
        Status("api path", api, 400);
        Assert.Equal(false, WebKit.JsonOf(api).Get("ok"));
        Status("api silence", await w.Send("POST", "/cronwatch/api/jobs/%zz/silence", Hs(Auth)), 400);
        Status("not UTF-8", await w.Get("/cronwatch/jobs/%E9", Auth), 400);
    }

    [Fact]
    public async Task Runs_is_clamped()
    {
        await using var w = new WebKit();
        for (int i = 0; i < 3; i++)
        {
            await w.Ok("r");
            w.Advance(1000);
        }
        (string Q, int N)[] cases = [("0", 1), ("-5", 1), ("2.7", 2), ("abc", 3), ("", 3), ("1e9", 3), ("Infinity", 3), ("0x2", 2), ("%202%20", 2)];
        foreach (var (q, n) in cases)
        {
            JsObject res = WebKit.JsonOf(await w.Get("/cronwatch/api/jobs/r?runs=" + q, Auth));
            Assert.True(n == ((List<object?>)WebKit.Field(res, "runs")!).Count, "runs=" + q);
        }
    }

    [Fact]
    public async Task An_unexpected_error_is_a_generic_500()
    {
        var store = new Wrapped();
        await using (var w = new WebKit(new RoutesOptions { Token = "tok" }, store))
        {
            store.Break("listJobs");
            WebResponse api = await w.Get("/cronwatch/api/jobs", Auth);
            Status("api", api, 500);
            Assert.Equal("{\"ok\":false,\"error\":\"Internal error\"}", api.Text());
            WebResponse page = await w.Get("/cronwatch/", Auth);
            Status("page", page, 500);
            Contains("type", page.Header("content-type"), "text/html");
            Assert.DoesNotContain("store down", page.Text(), StringComparison.Ordinal);
            Assert.Equal(["routes", "routes"], w.Wheres());
            Assert.All(w.Messages(), m => Contains("message", m, "store down: listJobs"));
        }
        await using var throwing = new CronwatchClient(new CronwatchOptions
        {
            Store = store,
            CronSecret = CronSecret.None,
            ProcessExitHook = false,
            Alerts = [],
            OnError = (e, where) => throw new InvalidOperationException("logger down"),
        });
        Routes routes = throwing.Routes(new RoutesOptions { Token = "tok" });
        Status("a throwing error handler", await WebKit.Serve(routes, "GET", "http://app.test/cronwatch/api/jobs", Hs(Auth)), 500);
    }

    [Fact]
    public async Task A_request_whose_client_went_away_reports_nothing()
    {
        await using var w = new WebKit();
        await w.Ok("x");
        using var cts = new CancellationTokenSource();
        await cts.CancelAsync();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => w.Routes.HandleAsync(WebKit.Request("GET", "http://app.test/cronwatch/api/jobs", Hs(Auth), ""), cts.Token));
        Assert.Empty(w.Wheres());
    }

    // The Rust audit: a body nested a few thousand arrays deep overflowed a thread's stack. The
    // JSON reader refuses nesting past 256, so the body reads as none and the silence is the
    // default hour.
    [Fact]
    public async Task A_body_nested_deeply_is_read_as_none()
    {
        await using var w = new WebKit();
        await w.Ok("s");
        string body = new string('[', 100_000) + new string(']', 100_000);
        WebResponse res = await Task.Run(() => w.Send("POST", "/cronwatch/api/jobs/s/silence", Hs(Auth, JsonType), body));
        Status("deep", res, 200);
        Assert.Equal(T0 + Hour, (await w.Summary("s"))!.SilencedUntil);
    }

    private static async Task<long> Until(WebKit w, string body)
    {
        JsObject r = WebKit.JsonOf(await w.Send("POST", "/cronwatch/api/jobs/s/silence", Hs(Auth, JsonType), body));
        return (long)(double)WebKit.Field(r, "state", "silencedUntil")! - T0;
    }

    [Fact]
    public async Task Silence_durations()
    {
        await using var w = new WebKit();
        await w.Ok("s");
        foreach (string bad in new[] { "\"forever\"", "\"2 hours\"", "\"\"", "\"-5\"", "\"1h then some\"", "true" })
        {
            WebResponse res = await w.Send("POST", "/cronwatch/api/jobs/s/silence", Hs(Auth, JsonType), "{\"for\":" + bad + "}");
            Status(bad, res, 400);
            Contains(bad, (string?)WebKit.Field(WebKit.JsonOf(res), "error"), "silence duration");
        }
        Assert.Null((await w.Summary("s"))!.SilencedUntil);
        Assert.Equal(7_200_000, await Until(w, "{\"for\":7200000}"));
        Assert.Equal(60_000, await Until(w, "{\"for\":\"60000\"}"));
        Assert.Equal(90 * Min, await Until(w, "{\"for\":\"90m\"}"));
        Assert.Equal(Hour, await Until(w, "{}"));
        Assert.Equal(2 * Hour, await Until(w, "﻿{\"for\":\"2h\"}"));
        // The SDK's 64-character cap: longer text is refused before it is read, quoting its start.
        WebResponse longText = await w.Send("POST", "/cronwatch/api/jobs/s/silence", Hs(Auth, JsonType), "{\"for\":\"" + new string('1', 65) + "h\"}");
        Status("65 characters", longText, 400);
        Contains("65 characters", (string?)WebKit.Field(WebKit.JsonOf(longText), "error"), "silence duration");
        Status("query", await w.Send("POST", "/cronwatch/api/jobs/s/silence?for=forever", Hs(Auth)), 400);
        JsObject query = WebKit.JsonOf(await w.Send("POST", "/cronwatch/api/jobs/s/silence?for=3h", Hs(Auth)));
        Assert.Equal((double)(T0 + (3 * Hour)), WebKit.Field(query, "state", "silencedUntil"));
    }

    // The Go audit: a body cut short was read as far as it came, so "for=7d" silenced the job for
    // 7 ms. The SDK reads a body it cannot read as none.
    [Fact]
    public async Task A_body_cut_short_is_none()
    {
        await using var w = new WebKit();
        await w.Ok("s");
        var req = new WebRequest("POST", "/cronwatch/api/jobs/s/silence")
        {
            Headers = Hs(H("host", "app.test"), Auth, Form),
            DeclaredLength = 6,
            BodyReader = (limit, ct) => throw new IOException("the client went away after for=7"),
        };
        Status("silenced", await w.Routes.HandleAsync(req), 200);
        Assert.Equal(T0 + Hour, (await w.Summary("s"))!.SilencedUntil);
        Assert.Empty(w.Wheres());
    }

    [Fact]
    public async Task The_silence_form_shows_an_error()
    {
        await using var w = new WebKit();
        await w.Ok("s");
        var f = Hs(H("cookie", WebKit.TokenCookie()), Form);
        WebResponse bad = await w.Send("POST", "/cronwatch/jobs/s/silence", f, "for=forever");
        Status("bad", bad, 400);
        Contains("type", bad.Header("content-type"), "text/html");
        Contains("message", bad.Text(), "silence duration &quot;forever&quot;");
        Status("ghost", await w.Send("POST", "/cronwatch/jobs/ghost/silence", f, "for=1h"), 404);
        Status("ghost unsilence", await w.Send("POST", "/cronwatch/jobs/ghost/unsilence", f), 404);
        Status("explode", await w.Send("POST", "/cronwatch/jobs/s/explode", f), 404);
    }

    [Fact]
    public async Task A_body_past_the_cap_is_413()
    {
        await using var w = new WebKit();
        await w.Ok("s");
        string big = "{\"for\":\"2h\",\"pad\":\"" + new string('x', WebRequest.MaxBody) + "\"}";
        WebResponse api = await w.Send("POST", "/cronwatch/api/jobs/s/silence", Hs(Auth, JsonType), big);
        Status("api", api, 413);
        Assert.Equal("{\"ok\":false,\"error\":\"Request body too large\"}", api.Text());
        WebResponse page = await w.Send("POST", "/cronwatch/jobs/s/silence", Hs(Auth, Form), "for=2h&pad=" + new string('x', WebRequest.MaxBody));
        Status("form", page, 413);
        Contains("form body", page.Text(), "The request was too large.");
        // Without a length, by reading one byte past the cap.
        byte[] data = Encoding.UTF8.GetBytes(big);
        var chunked = new WebRequest("POST", "/cronwatch/api/jobs/s/silence")
        {
            Headers = Hs(H("host", "app.test"), Auth, JsonType),
            BodyReader = (limit, ct) => Task.FromResult(data[..Math.Min(data.Length, limit + 1)]),
        };
        Status("chunked", await w.Routes.HandleAsync(chunked), 413);
        // A body of exactly the cap is read.
        string exact = "for=2h&pad=";
        exact += new string('x', WebRequest.MaxBody - exact.Length);
        Status("exactly the cap", await w.Send("POST", "/cronwatch/api/jobs/s/silence", Hs(Auth, Form), exact), 200);
        await w.Cw.UnsilenceAsync("s");
        // Refused before the body is read: no token, no read.
        int read = 0;
        var noToken = new WebRequest("POST", "/cronwatch/api/jobs/s/silence")
        {
            Headers = Hs(H("host", "app.test"), JsonType),
            BodyReader = (limit, ct) =>
            {
                Interlocked.Increment(ref read);
                return Task.FromResult(Array.Empty<byte>());
            },
        };
        Status("no token", await w.Routes.HandleAsync(noToken), 401);
        Assert.Equal(0, read);
    }

    [Fact]
    public async Task Security_headers()
    {
        await using var w = new WebKit();
        await w.Ok("h");
        foreach (string path in new[] { "/cronwatch/", "/cronwatch/jobs/h", "/cronwatch/nope" })
        {
            WebResponse res = await w.Get(path, Auth);
            Assert.Equal(
                "default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; img-src 'self' data:; manifest-src 'self'; worker-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'",
                res.Header("content-security-policy"));
            Assert.Equal("DENY", res.Header("x-frame-options"));
            Assert.Equal("nosniff", res.Header("x-content-type-options"));
            Assert.Equal("same-origin", res.Header("referrer-policy"));
            Assert.Equal("no-store", res.Header("cache-control"));
            string text = res.Text();
            Assert.Equal(1, text.Split("<script").Length - 1);
            Contains(path, text, "<script src=\"/cronwatch/app.js\" defer></script>");
        }
        WebResponse api = await w.Get("/cronwatch/api/jobs", Auth);
        Assert.Equal("nosniff", api.Header("x-content-type-options"));
        Assert.Equal("no-store", api.Header("cache-control"));
    }

    [Fact]
    public async Task Markup_stays_escaped()
    {
        await using var w = new WebKit();
        Job job = w.Cw.Job("m", new JobOptions { Schedule = "0 2 * * *", Description = "<img src=x>", Tags = ["<t>"], Expect = "<e>" });
        await Quietly(() => job.RunAsync((j, ct) =>
        {
            j.Log("<o>");
            j.Metric("<k>", 1);
            return Task.CompletedTask;
        }));
        foreach (string path in new[] { "/cronwatch/", "/cronwatch/jobs/m", "/cronwatch/jobs/%3Cx%3E" })
        {
            string text = (await w.Get(path, Auth)).Text();
            foreach (string bad in new[] { "<img", "<t>", "<e>", "<o>", "<k>", "<x>" })
            {
                Assert.False(text.Contains(bad, StringComparison.Ordinal), path + ": " + bad + " unescaped");
            }
        }
    }

    private const string Internal = "http://10.0.0.5:8080";

    private static Task<WebResponse> SendInternal(WebKit w, string method, string path, List<KeyValuePair<string, string>> hs, string body = "") =>
        WebKit.Serve(w.Routes, method, Internal + path, WebKit.With(hs, Hs(H("cookie", WebKit.TokenCookie()))), body);

    private static async Task<WebKit> App(string? origin = null, bool trustProxy = false)
    {
        var w = new WebKit(new RoutesOptions { Token = "tok", BasePath = "/cronwatch", Origin = origin, TrustProxy = trustProxy });
        await w.Ok("x");
        return w;
    }

    [Fact]
    public async Task The_requests_own_origin_by_default()
    {
        await using WebKit w = await App();
        Status("foreign", await SendInternal(w, "POST", "/cronwatch/jobs/x/silence", Hs(Form, H("origin", "https://app.example.com")), "for=1h"), 403);
        Assert.Null((await w.Summary("x"))!.SilencedUntil);
        Status("own", await SendInternal(w, "POST", "/cronwatch/jobs/x/silence", Hs(Form, H("origin", Internal)), "for=1h"), 303);
        WebResponse set = await SendInternal(w, "GET", "/cronwatch/?token=tok", []);
        Assert.DoesNotContain("Secure", set.Header("set-cookie")!, StringComparison.Ordinal);
    }

    [Fact]
    public async Task The_origin_option_replaces_it()
    {
        await using WebKit w = await App("https://app.example.com/ignored/path");
        Status("internal", await SendInternal(w, "POST", "/cronwatch/jobs/x/silence", Hs(Form, H("origin", Internal)), "for=1h"), 403);
        Assert.Null((await w.Summary("x"))!.SilencedUntil);
        const string referer = "https://app.example.com/cronwatch/jobs/x";
        WebResponse res = await SendInternal(w, "POST", "/cronwatch/jobs/x/silence", Hs(Form, H("origin", "https://app.example.com"), H("referer", referer)), "for=2h");
        Status("public", res, 303);
        Assert.Equal(referer, res.Header("location"));
        Assert.Equal(T0 + (2 * Hour), (await w.Summary("x"))!.SilencedUntil);
        WebResponse signIn = await SendInternal(w, "GET", "/cronwatch/jobs/x?token=tok", []);
        Assert.Equal("/cronwatch/jobs/x", signIn.Header("location"));
        Assert.EndsWith("; Secure", signIn.Header("set-cookie")!, StringComparison.Ordinal);
    }

    [Fact]
    public async Task The_origin_option_wins_over_trust_proxy()
    {
        await using WebKit w = await App("https://app.example.com", trustProxy: true);
        var fwd = Hs(H("x-forwarded-proto", "https"), H("x-forwarded-host", "other.example"));
        Status("forwarded", await SendInternal(w, "POST", "/cronwatch/check", WebKit.With(fwd, Hs(H("origin", "https://other.example")))), 403);
        Status("configured", await SendInternal(w, "POST", "/cronwatch/check", WebKit.With(fwd, Hs(H("origin", "https://app.example.com")))), 303);
    }

    [Fact]
    public async Task Trust_proxy_takes_the_first_forwarded_values()
    {
        await using WebKit w = await App(trustProxy: true);
        var fwd = Hs(H("x-forwarded-proto", "https, http"), H("x-forwarded-host", "app.example.com, 10.0.0.5:8080"));
        Status("internal", await SendInternal(w, "POST", "/cronwatch/jobs/x/silence", WebKit.With(fwd, Hs(Form, H("origin", Internal))), "for=1h"), 403);
        Status("public", await SendInternal(w, "POST", "/cronwatch/jobs/x/silence", WebKit.With(fwd, Hs(Form, H("origin", "https://app.example.com"))), "for=1h"), 303);
        Assert.EndsWith("; Secure", (await SendInternal(w, "GET", "/cronwatch/?token=tok", fwd)).Header("set-cookie")!, StringComparison.Ordinal);
        Status("proto only", await SendInternal(w, "POST", "/cronwatch/check", Hs(H("x-forwarded-proto", "https"), H("origin", "https://10.0.0.5:8080"))), 303);
        Status("neither", await SendInternal(w, "POST", "/cronwatch/check", Hs(H("origin", Internal))), 303);
        (string Proto, string Host, string Origin)[] cases =
        [
            ("javascript", "evil.example", "javascript://evil.example"),
            ("https", "evil.example/path", "https://evil.example"),
            ("https", "user@evil.example", "https://evil.example"),
        ];
        foreach (var (proto, host, origin) in cases)
        {
            var hs = Hs(H("x-forwarded-proto", proto), H("x-forwarded-host", host));
            Status(origin, await SendInternal(w, "POST", "/cronwatch/check", WebKit.With(hs, Hs(H("origin", origin)))), 403);
            Status(origin, await SendInternal(w, "POST", "/cronwatch/check", WebKit.With(hs, Hs(H("origin", Internal)))), 303);
        }
    }

    [Fact]
    public async Task Without_trust_proxy_forwarded_headers_change_nothing()
    {
        await using var w = new WebKit();
        await w.Ok("x");
        var cookie = H("cookie", WebKit.TokenCookie());
        var spoofed = Hs(H("x-forwarded-host", "evil.example"), H("x-forwarded-proto", "https"));
        Status("foreign", await w.Send("POST", "/cronwatch/jobs/x/silence", WebKit.With(Hs(cookie, Form), spoofed, Hs(H("origin", "https://evil.example"))), "for=1h"), 403);
        WebResponse back = await w.Send("POST", "/cronwatch/check", WebKit.With(Hs(cookie), spoofed, Hs(H("origin", "http://app.test"), H("referer", "https://evil.example/cronwatch/jobs/x"))));
        Assert.Equal("/cronwatch/", back.Header("location"));
        Assert.DoesNotContain("Secure", (await w.Send("GET", "/cronwatch/?token=tok", spoofed)).Header("set-cookie")!, StringComparison.Ordinal);
        // TLS makes the request's own origin https.
        WebResponse tls = await WebKit.Serve(w.Routes, "GET", "https://app.test/cronwatch/?token=tok", []);
        Assert.EndsWith("; Secure", tls.Header("set-cookie")!, StringComparison.Ordinal);
    }

    [Fact]
    public async Task A_bad_origin_is_refused_when_the_routes_are_made()
    {
        await using var w = new WebKit();
        var e = Assert.Throws<CronwatchException>(() => w.Cw.Routes(new RoutesOptions { Token = "tok", Origin = "app.example.com" }));
        Assert.Equal("routes: origin must be an absolute URL such as \"https://app.example.com\", got \"app.example.com\"", e.Message);
        Assert.Equal(CronwatchErrorKind.Invalid, e.Kind);
        e = Assert.Throws<CronwatchException>(() => w.Cw.Routes(new RoutesOptions { Token = "tok", Origin = "ftp://app.example.com" }));
        Assert.Equal("routes: origin must be http or https, got \"ftp://app.example.com\"", e.Message);
        Assert.NotNull(w.Cw.Routes(new RoutesOptions { Token = "tok", Origin = "" }));
    }

    [Theory]
    [InlineData(" HTTPS://App.Example.COM:443/x ", "https://app.example.com")]
    [InlineData("http:\\\\example.com:8080", "http://example.com:8080")]
    [InlineData("http://0x7f.1", "http://127.0.0.1")]
    [InlineData("http://[0:0::1]:80", "http://[::1]")]
    [InlineData("https://bücher.example", "https://xn--bcher-kva.example")]
    [InlineData("http://user:pw@example.com", "http://example.com")]
    public async Task Origins_are_read_as_url_origin_reads_them(string option, string origin)
    {
        await using var w = new WebKit();
        Routes routes = w.Cw.Routes(new RoutesOptions { Token = "tok", Origin = option });
        Status(option, await WebKit.Serve(routes, "POST", "http://10.0.0.5/cronwatch/api/check", Hs(Auth, H("origin", origin))), 200);
    }

    // The Go audit: a Host header outside ASCII over 1024 bytes is not punycoded (which takes
    // time in its length times its distinct characters) or read as a URL; the request is
    // answered all the same.
    [Fact]
    public async Task A_long_host_outside_ascii_is_not_read_as_a_url()
    {
        await using var w = new WebKit();
        await w.Ok("x");
        var chars = new StringBuilder();
        for (int i = 0; i < 2000; i++)
        {
            chars.Append(char.ConvertFromUtf32(0x4e00 + i));
        }
        // As a server reads it: each byte of its UTF-8 one character.
        string host = Encoding.Latin1.GetString(Encoding.UTF8.GetBytes(chars.ToString()));
        WebRequest Req(params KeyValuePair<string, string>[] more) =>
            new("POST", "/cronwatch/api/check") { Headers = WebKit.With(Hs(H("host", host), Auth), Hs(more)) };
        Status("answered", await w.Routes.HandleAsync(Req()), 200);
        // The origin a browser sends is the host's own bytes, which the routes read as UTF-8.
        Status("its own origin", await w.Routes.HandleAsync(Req(H("origin", "http://" + chars))), 200);
        Status("the bytes as characters are another origin", await w.Routes.HandleAsync(Req(H("origin", "http://" + host))), 403);
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task The_app_shell_is_public_and_only_for_reads(bool withToken)
    {
        await using var k = new WebKit(withToken ? new RoutesOptions { Token = "tok" } : new RoutesOptions { Token = DashboardToken.None });
        foreach (string path in new[] { "/manifest.webmanifest", "/sw.js", "/app.js", "/offline", "/icons/icon.svg", "/icons/icon-192.png" })
        {
            string url = "http://app.test/cronwatch" + path;
            Status(path, await WebKit.Serve(k.Routes, "GET", url, []), 200);
            Status(path, await WebKit.Serve(k.Routes, "HEAD", url, []), 200);
        }
        WebResponse sw = await WebKit.Serve(k.Routes, "GET", "http://app.test/cronwatch/sw.js", []);
        Assert.Equal("/cronwatch/", sw.Header("service-worker-allowed"));
        WebResponse svg = await WebKit.Serve(k.Routes, "GET", "http://app.test/cronwatch/icons/icon.svg", []);
        Assert.Equal("default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'", svg.Header("content-security-policy"));
        Assert.Equal("public, max-age=31536000, immutable", svg.Header("cache-control"));
    }

    [Fact]
    public async Task The_shell_is_only_for_reads_and_an_open_dashboard_answers_anyone()
    {
        await using (var w = new WebKit())
        {
            Status("a write to the shell", await w.Send("POST", "/cronwatch/sw.js", []), 401);
            Status("HEAD elsewhere", await w.Send("HEAD", "/cronwatch/", Hs(Auth)), 404);
        }
        await using var open = new WebKit(new RoutesOptions { Token = DashboardToken.None });
        Assert.Null(open.Routes.Token());
        Assert.True(open.Routes.IsOpen);
        Status("open", await WebKit.Serve(open.Routes, "GET", "http://app.test/cronwatch/api/jobs", []), 200);
    }

    private static async Task<string> ManifestId(Routes routes, string path, string? mount = null)
    {
        WebResponse res = await routes.HandleAsync(new WebRequest("GET", path) { Mount = mount });
        return res.Status != 200 ? res.Status.ToString(System.Globalization.CultureInfo.InvariantCulture) : (string)WebKit.Field(WebKit.JsonOf(res), "id")!;
    }

    [Fact]
    public async Task The_base_path()
    {
        await using var k = new WebKit(new RoutesOptions { Token = DashboardToken.None });
        await k.Ok("x");
        Assert.Equal("/cronwatch/", await ManifestId(k.Routes, "/cronwatch/manifest.webmanifest"));
        Routes root = k.Cw.Routes(new RoutesOptions { Token = DashboardToken.None, BasePath = "" });
        Assert.Equal("/", await ManifestId(root, "/manifest.webmanifest"));
        Routes deep = k.Cw.Routes(new RoutesOptions { Token = DashboardToken.None, BasePath = "/a/b/" });
        Assert.Equal("/a/b/", await ManifestId(deep, "/a/b/manifest.webmanifest"));
        Assert.Equal("/x/y/", await ManifestId(k.Routes, "/x/y/manifest.webmanifest", "/x/y/"));
        Assert.Equal("/a/b/", await ManifestId(deep, "/a/b/manifest.webmanifest", "/x"));
    }

    [Fact]
    public async Task Paths_are_read_as_the_url_parser_leaves_them()
    {
        await using var w = new WebKit();
        await w.Ok("x");
        foreach (string path in new[] { "/cronwatch/./jobs/x", "/cronwatch/nope/../jobs/x", "/cronwatch\\jobs\\x", "/cronwatch/%2e/jobs/x", "/cronwatch/jobs/%78" })
        {
            WebResponse res = await w.Get(path, Auth);
            Status(path, res, 200);
            Contains(path, res.Text(), "<h1 class=\"jobname\">x</h1>");
        }
        Status("a slash inside a name", await w.Get("/cronwatch/api/jobs/a%2Fb", Auth), 404);
    }

    // The Go audit: an interval past what a long of milliseconds holds wrapped round, and drawing
    // the board's timeline never ended; a silence for longer than that ended at once.
    [Fact]
    public async Task Huge_durations_neither_hang_nor_wrap()
    {
        await using var w = new WebKit();
        Job job = w.Cw.Job("rare", new JobOptions { Schedule = "every 20000000000w" });
        await job.RunAsync((j, ct) => Task.CompletedTask);
        w.Advance(10 * 24 * Hour);
        await w.Cw.CheckAsync();
        foreach (string path in new[] { "/cronwatch/", "/cronwatch/jobs/rare", "/cronwatch/api/jobs/rare" })
        {
            Status(path, await w.Get(path, Auth), 200);
        }
        JsObject silenced = WebKit.JsonOf(await w.Send("POST", "/cronwatch/api/jobs/rare/silence", Hs(Auth, JsonType), "{\"for\":\"99999999999999999999999\"}"));
        double until = (double)WebKit.Field(silenced, "state", "silencedUntil")!;
        Assert.True(until > w.M.Clock.Ms(), "a long silence ended at once: " + until);
    }

    // A foreign row's far times on the pages: the seed of golden.mjs holds them; here a run that
    // started at the lowest long is drawn and answered.
    [Fact]
    public async Task Far_times_are_answered()
    {
        var store = new Wrapped();
        await using var w = new WebKit(new RoutesOptions { Token = "tok" }, store);
        await w.Ok("far");
        await store.Inner.InsertRunAsync(Run.Running("far-run", "far", long.MinValue, "run"));
        foreach (string path in new[] { "/cronwatch/", "/cronwatch/jobs/far", "/cronwatch/api/jobs/far" })
        {
            Status(path, await w.Get(path, Auth), 200);
        }
        Assert.Empty(w.Wheres());
    }

    [Fact]
    public async Task Nothing_prints_a_secret()
    {
        const string token = "t0k-value";
        Assert.DoesNotContain(token, new RoutesOptions { Token = token }.ToString(), StringComparison.Ordinal);
        Assert.DoesNotContain(token, new HandlerOptions { Secret = token }.ToString(), StringComparison.Ordinal);
        Assert.DoesNotContain(token, ((DashboardToken)token).ToString(), StringComparison.Ordinal);
        Assert.DoesNotContain(token, ((HandlerSecret)token).ToString(), StringComparison.Ordinal);
        var req = new WebRequest("GET", "/cronwatch/?token=" + token)
        {
            Headers = Hs(H("authorization", "Bearer " + token), H("cookie", "cronwatch_token=" + token)),
            Body = Encoding.UTF8.GetBytes(token),
        };
        Assert.DoesNotContain(token, req.ToString(), StringComparison.Ordinal);
        Assert.Equal("/cronwatch/", req.Path);
        await using var w = new WebKit(new RoutesOptions { Token = token });
        Assert.DoesNotContain(token, w.Routes.ToString(), StringComparison.Ordinal);
        Handler handler = w.Cw.Job("h").Handler((j, r, ct) => Task.CompletedTask, new HandlerOptions { Secret = token });
        Assert.DoesNotContain(token, handler.ToString(), StringComparison.Ordinal);
        WebResponse r = new WebResponse(200).WithHeader("set-cookie", "cronwatch_token=" + token).WithBody(token);
        Assert.DoesNotContain(token, r.ToString(), StringComparison.Ordinal);
        // A URL's credentials: an origin given with them, and a target in the absolute form.
        var withUser = new RoutesOptions { Token = "tok", Origin = "https://ops:" + token + "@app.example" };
        Assert.DoesNotContain(token, withUser.ToString(), StringComparison.Ordinal);
        await using var o = new WebKit(withUser);
        Assert.Contains("origin https://app.example", o.Routes.ToString(), StringComparison.Ordinal);
        var absolute = new WebRequest("GET", "http://ops:" + token + "@app.example/cronwatch/");
        Assert.DoesNotContain(token, absolute.ToString(), StringComparison.Ordinal);
        Assert.Equal("/cronwatch/", absolute.Path);
    }
}
