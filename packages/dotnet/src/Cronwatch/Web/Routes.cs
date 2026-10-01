using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch.Internal;

namespace Cronwatch.Web;

/// <summary>
/// The dashboard and its small JSON API, the SDK's <c>cw.routes()</c> (<c>routes/index.ts</c>),
/// framework-free: <see cref="HandleAsync"/> takes a <see cref="CronwatchRequest"/> and answers a
/// <see cref="CronwatchResponse"/>, with the same URLs, JSON, status codes, headers, cookie, redirects,
/// cross-site rule and token rules as the SDK's routes, so <c>@cronwatch/mcp</c> works against a
/// .NET app as it does against a Node one. <c>Cronwatch.AspNetCore</c>'s <c>MapCronwatch</c> and
/// <c>UseCronwatch</c> are adapters over it, and so can any other server be. Made by
/// <see cref="CronwatchClient.Routes"/>. Safe to share between threads.
/// </summary>
[DebuggerDisplay("{ToString(),nq}")]
public sealed class Routes
{
    /// <summary>Where the dashboard is taken to be mounted when nothing else says.</summary>
    public const string DefaultBasePath = "/cronwatch";

    private const string TokenCookie = "cronwatch_token";
    private const int DefaultRuns = 20;
    private const int MaxRuns = 500;
    private const int BoardPageRuns = 20;
    private const int CookieMaxAge = 60 * 60 * 24 * 30;

    /// <summary>
    /// What <c>GET &lt;base&gt;/api</c> says is serving it: the package as NuGet names it, and the
    /// language; each port answers with its own.
    /// </summary>
    private const string Library = "Cronwatch";

    private const string Language = "dotnet";

    /// <summary>The API's version: it goes up only with a change that is not additive, in a major release.</summary>
    private const int ApiVersion = 1;

    // 'self' only for what the app shell needs: app.js (which registers the service worker and
    // nothing else), the manifest, the worker and the icons. No inline script, and the pages work
    // without any.
    private const string PageCsp =
        "default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; img-src 'self' data:; manifest-src 'self'; worker-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'";

    private const string AssetCsp = "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'";

    private const string SignInIntro =
        "[cronwatch] CRONWATCH_TOKEN is not set, so this development server made a token for the dashboard. Sign in: ";

    private readonly CronwatchClient _cw;
    private readonly bool _optedOut;
    private readonly string _token;
    private readonly bool _generated;
    private readonly string _cookie;
    private readonly string? _base;
    private readonly string? _origin;
    private readonly bool _trustProxy;
    private int _announced;

    internal Routes(CronwatchClient cw, RoutesOptions options)
    {
        _cw = cw;
        try
        {
            _origin = Origins.Configured(options.Origin);
        }
        catch (ArgumentException e)
        {
            throw CronwatchException.Invalid(e.Message);
        }
        _optedOut = options.Token != null && options.Token.Value == null;
        string configured;
        if (_optedOut)
        {
            configured = "";
        }
        else if (!string.IsNullOrEmpty(options.Token?.Value))
        {
            configured = options.Token.Value;
        }
        else
        {
            configured = Env.Read("CRONWATCH_TOKEN") ?? "";
        }
        // A handler cannot tell a local caller from a remote one (proxies, tunnels and a server
        // listening on every interface all look alike), so development gets a token too: made
        // here, and shown only in the log.
        bool generate = configured.Length == 0 && !_optedOut && cw.EnvironmentName == "development";
        _token = generate ? DevelopmentToken() : configured;
        _generated = generate && _token.Length > 0;
        _cookie = _token.Length == 0 ? "" : CookieValue(_token);
        _base = options.BasePath == null ? null : TrimTrailingSlashes(options.BasePath);
        _trustProxy = options.TrustProxy;
    }

    /// <summary>
    /// The token the dashboard asks for (the generated one in development), or null when it is
    /// open or locked for want of one. A method, not a property, so a logger that walks public
    /// getters never finds it.
    /// </summary>
    public string? Token() => _token.Length == 0 ? null : _token;

    /// <summary>
    /// Whether the dashboard is served open, with no token (<see cref="DashboardToken.None"/>): it is
    /// then meant to sit behind the app's own sign-in.
    /// </summary>
    public bool IsOpen => _optedOut;

    /// <summary>Names the base and the origin, never the token.</summary>
    public override string ToString() =>
        "Routes(" + (_base == null ? "base from the mount" : "base " + _base) + (_origin == null ? "" : ", origin " + _origin) + (_optedOut ? ", open" : "") + ")";

    private static string TrimTrailingSlashes(string s) => s.TrimEnd('/');

    /// <summary>
    /// The cookie holds a digest of the token, so a leaked cookie does not reveal the bearer token
    /// itself: the SHA-256 of <c>cronwatch-cookie:&lt;token&gt;</c>, as hex.
    /// </summary>
    private static string CookieValue(string token) =>
        Convert.ToHexStringLower(SHA256.HashData(Js.Utf8("cronwatch-cookie:" + token)));

    /// <summary>32 random bytes, base64url (43 characters), or <c>""</c> without system randomness.</summary>
    private static string DevelopmentToken()
    {
        byte[] b = new byte[32];
        try
        {
            RandomNumberGenerator.Fill(b);
        }
        catch (CryptographicException)
        {
            // No system randomness: a token nobody can guess cannot be made, so make one nobody
            // can use either.
            return "";
        }
        return System.Buffers.Text.Base64Url.EncodeToString(b);
    }

    /// <summary>
    /// The line a development token is announced with, once, on the routes' first request.
    /// <paramref name="shown"/> is the configured origin when set, otherwise that request's public
    /// origin when its host is loopback, and null for any other host: the request's host is the
    /// client's to choose, so the line then leaves it out rather than point the link, token and
    /// all, somewhere else.
    /// </summary>
    internal static string DevelopmentSignInLine(string? shown, string basePath, string token) =>
        shown == null
            ? SignInIntro + basePath + "/?token=" + token + " on this server (the first request's host is not local, so the link leaves it out)"
            : SignInIntro + shown + basePath + "/?token=" + token;

    // ---- answers

    private static CronwatchResponse WithSecurity(CronwatchResponse r) =>
        r.WithHeader("x-content-type-options", "nosniff").WithHeader("referrer-policy", "same-origin").WithHeader("x-robots-tag", "noindex");

    private static CronwatchResponse Api(JsObject body, int status, string? extraName = null, string? extraValue = null)
    {
        CronwatchResponse r = WithSecurity(new CronwatchResponse(status)
            .WithHeader("content-type", "application/json; charset=utf-8")
            .WithHeader("cache-control", "no-store"));
        if (extraName != null)
        {
            r = r.WithHeader(extraName, extraValue!);
        }
        return r.WithOwnedBody(Js.Utf8(body.ToJson()));
    }

    private static JsObject ErrorBody(string message) => new JsObject().Set("ok", false).Set("error", message);

    private static CronwatchResponse Redirect(string location, string? cookie = null)
    {
        CronwatchResponse r = WithSecurity(new CronwatchResponse(303).WithHeader("location", location).WithHeader("cache-control", "no-store"));
        return cookie == null ? r : r.WithHeader("set-cookie", cookie);
    }

    private static CronwatchResponse HtmlAnswer(string body, int status, string cache) =>
        WithSecurity(new CronwatchResponse(status)
            .WithHeader("content-type", "text/html; charset=utf-8")
            .WithHeader("cache-control", cache)
            .WithHeader("content-security-policy", PageCsp)
            .WithHeader("x-frame-options", "DENY"))
        .WithOwnedBody(Js.Utf8(body));

    private static CronwatchResponse Page(string body, int status) => HtmlAnswer(body, status, "no-store");

    private static CronwatchResponse Message(string title, string message, string basePath, int status, bool signIn = false) =>
        Page(Html.MessagePage(title, message, basePath, signIn), status);

    /// <summary>An app shell file. The worker may be scoped to the base; the SVGs get a CSP of their own.</summary>
    private static CronwatchResponse Shell(PwaAsset asset, string basePath)
    {
        CronwatchResponse r = WithSecurity(new CronwatchResponse(200).WithHeader("content-type", asset.ContentType).WithHeader("cache-control", asset.Cache));
        if (asset.ContentType == "image/svg+xml")
        {
            r = r.WithHeader("content-security-policy", AssetCsp);
        }
        if (asset.Worker)
        {
            r = r.WithHeader("service-worker-allowed", basePath + "/");
        }
        return r.WithOwnedBody(asset.Body);
    }

    private static CronwatchResponse TooLarge(bool wantsHtml, string basePath) =>
        wantsHtml ? Message("Not silenced", "The request was too large.", basePath, 413) : Api(ErrorBody("Request body too large"), 413);

    // ---- reading a request

    /// <summary>The first entry of a comma-separated header, trimmed, or null when there is none.</summary>
    private static string? FirstValue(CronwatchRequest req, string name)
    {
        string? value = req.Header(name);
        if (value == null)
        {
            return null;
        }
        int comma = value.IndexOf(',', StringComparison.Ordinal);
        string first = Js.Trim(comma < 0 ? value : value[..comma]);
        return first.Length == 0 ? null : first;
    }

    /// <summary>The named cookie, decoded, or null; a malformed escape counts as no cookie.</summary>
    private static string? ReadCookie(CronwatchRequest req, string name)
    {
        string? value = req.Header("cookie");
        if (string.IsNullOrEmpty(value))
        {
            return null;
        }
        foreach (string part in value.Split(';'))
        {
            string p = Js.Trim(part);
            int eq = p.IndexOf('=', StringComparison.Ordinal);
            string key = eq < 0 ? p : p[..eq];
            if (key == name)
            {
                return Requests.SafeDecode(eq < 0 ? "" : p[(eq + 1)..]);
            }
        }
        return null;
    }

    /// <summary>
    /// A browser attaches <c>Origin</c> or <c>Sec-Fetch-Site</c> to a cross-site form post, and a
    /// page cannot forge either. Non-browser clients send neither.
    /// </summary>
    private static bool CrossSite(CronwatchRequest req, string publicOrigin)
    {
        string? o = req.Header("origin");
        if (o != null && o != publicOrigin)
        {
            return true;
        }
        string? site = req.Header("sec-fetch-site");
        return site != null && site != "same-origin" && site != "none";
    }

    private static bool IsBearerPrefix(string text)
    {
        if (text.Length <= 6)
        {
            return false;
        }
        const string word = "bearer";
        for (int i = 0; i < 6; i++)
        {
            char c = text[i];
            char lower = c is >= 'A' and <= 'Z' ? (char)(c + 32) : c;
            if (lower != word[i])
            {
                return false;
            }
        }
        return true;
    }

    /// <summary>The <c>Authorization</c> header without its <c>Bearer </c> (in any case, with any spaces after it), or null.</summary>
    private static string? Bearer(CronwatchRequest req)
    {
        string? text = req.Header("authorization");
        if (text == null)
        {
            return null;
        }
        if (IsBearerPrefix(text))
        {
            int i = 6;
            while (i < text.Length && Js.IsSpace(text[i]))
            {
                i++;
            }
            if (i > 6)
            {
                return text[i..];
            }
        }
        return text;
    }

    /// <summary>Absent means one hour; a number or numeric string is milliseconds.</summary>
    /// <exception cref="ArgumentException">With the SDK's message for anything else.</exception>
    internal static double SilenceDuration(string? value)
    {
        if (value == null)
        {
            return Durations.ParseValue("1h", "silence duration");
        }
        string text = Js.Trim(value);
        object duration = IsNumeric(text) ? double.Parse(text, NumberStyles.AllowDecimalPoint, CultureInfo.InvariantCulture) : text;
        return Durations.ParseValue(duration, "silence duration");
    }

    /// <summary><c>/^\d+(\.\d+)?$/</c>.</summary>
    private static bool IsNumeric(string text)
    {
        int dot = text.IndexOf('.', StringComparison.Ordinal);
        string whole = dot < 0 ? text : text[..dot];
        return Digits(whole) && (dot < 0 || Digits(text[(dot + 1)..]));
    }

    private static bool Digits(string s)
    {
        if (s.Length == 0)
        {
            return false;
        }
        foreach (char c in s)
        {
            if (c is < '0' or > '9')
            {
                return false;
            }
        }
        return true;
    }

    internal static int RunsLimit(string? value)
    {
        if (value == null || Js.Trim(value).Length == 0)
        {
            return DefaultRuns;
        }
        double n = Evaluate.JsNumber(value);
        if (!double.IsFinite(n))
        {
            return DefaultRuns;
        }
        n = Math.Truncate(n);
        return (int)Math.Max(1, Math.Min(MaxRuns, n));
    }

    /// <summary>Where the dashboard is mounted for this request: the option, else the adapter's, else ours.</summary>
    private string BasePathOf(CronwatchRequest req, string pathname)
    {
        if (_base != null)
        {
            return _base;
        }
        return req.Mount is { } mount ? MountAsSent(pathname, TrimTrailingSlashes(mount)) : DefaultBasePath;
    }

    /// <summary>
    /// An adapter's mount as the target spells it. A server hands its mount over decoded
    /// (ASP.NET Core's <c>PathBase</c> and route values), where the target keeps what the client
    /// escaped, so <c>/ops tools</c> is <c>/ops%20tools</c> there: the base is the target's first as
    /// many segments as the mount has, since a server decodes within a segment and never a
    /// <c>%2F</c> into one more. A target with fewer segments keeps the mount as given.
    /// </summary>
    internal static string MountAsSent(string pathname, string mount)
    {
        int segments = 0;
        foreach (char c in mount)
        {
            if (c == '/')
            {
                segments++;
            }
        }
        int seen = 0;
        for (int i = 0; i < pathname.Length; i++)
        {
            if (pathname[i] == '/' && ++seen > segments)
            {
                return pathname[..i];
            }
        }
        return seen == segments ? pathname : mount;
    }

    /// <summary>The origin a browser sees: the configured one, the forwarded one under TrustProxy, or ours.</summary>
    private string PublicOrigin(CronwatchRequest req)
    {
        if (_origin != null)
        {
            return _origin;
        }
        string own = Origins.OfRequest(req.IsTls, req.Header("host") ?? "");
        if (!_trustProxy)
        {
            return own;
        }
        string? proto = FirstValue(req, "x-forwarded-proto")?.ToLowerInvariant();
        string? forwardedHost = FirstValue(req, "x-forwarded-host");
        if (proto == null && forwardedHost == null)
        {
            return own;
        }
        if (proto != null && proto != "http" && proto != "https")
        {
            return own;
        }
        int sep = own.IndexOf("://", StringComparison.Ordinal);
        string ownScheme = sep < 0 ? own : own[..sep];
        string ownHost = sep < 0 ? "" : own[(sep + 3)..];
        return Origins.Bare((proto ?? ownScheme) + "://" + (forwardedHost ?? ownHost)) ?? own;
    }

    /// <summary>What a request says, read before anything is served.</summary>
    private sealed record Said(
        string Method,
        string PublicOrigin,
        List<KeyValuePair<string, string>> Query,
        string? Bearer,
        string? Cookie,
        string Referer,
        string ContentType,
        bool CrossSite);

    // ---- serving

    /// <summary>
    /// Answers one request as the SDK's routes answer it. A store failure (or anything else thrown)
    /// is reported to the client's error handler as <c>routes</c> and answered 500. A request whose
    /// <paramref name="cancellationToken"/> is cancelled (its client went away) reports nothing and
    /// ends with an <see cref="OperationCanceledException"/>.
    /// </summary>
    public async Task<CronwatchResponse> HandleAsync(CronwatchRequest request, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        var (rawPath, rawQuery) = Requests.Target(request.Target);
        string pathname = Requests.NormalizePath(rawPath);
        string b = BasePathOf(request, pathname);
        string path = Requests.StripBase(pathname, b);
        bool wantsHtml = !path.StartsWith("/api", StringComparison.Ordinal);
        try
        {
            return await ServeAsync(request, pathname, path, rawQuery, b, wantsHtml, cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception e)
        {
            _cw.ReportError(e, "routes");
            return wantsHtml
                ? Message("Something went wrong", "The request failed and the error was reported.", b, 500)
                : Api(ErrorBody("Internal error"), 500);
        }
    }

    private Said Read(CronwatchRequest req, string rawQuery)
    {
        string publicOrigin = PublicOrigin(req);
        return new Said(
            req.Method.ToUpperInvariant(),
            publicOrigin,
            Requests.ParseQuery(rawQuery),
            Bearer(req),
            ReadCookie(req, TokenCookie),
            req.Header("referer") ?? "",
            req.Header("content-type") ?? "",
            CrossSite(req, publicOrigin));
    }

    /// <summary>The body up to the cap, none when it could not be read to its end, or null past the cap.</summary>
    private static async Task<byte[]?> ReadLimitedAsync(CronwatchRequest req, CancellationToken cancellationToken)
    {
        try
        {
            return await req.ReadBodyAsync(CronwatchRequest.MaxBody, cancellationToken).ConfigureAwait(false);
        }
        catch (WebBodyTooLargeException)
        {
            return null;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception)
        {
            // A body cut short is none, as the SDK's readBody has it, never the part that arrived:
            // "for=7d" cut short is "for=7", a silence of 7 ms.
            return [];
        }
    }

    private void Announce(Said said, string basePath)
    {
        if (!_generated || Interlocked.Exchange(ref _announced, 1) != 0)
        {
            return;
        }
        string? shown = _origin;
        if (shown == null && Origins.IsLoopback(said.PublicOrigin))
        {
            shown = said.PublicOrigin;
        }
        try
        {
            Console.Out.Write(DevelopmentSignInLine(shown, basePath, _token) + "\n");
            Console.Out.Flush();
        }
        catch (Exception)
        {
            // A closed or failing output is ignored, as console.info never throws.
        }
    }

    private async Task<CronwatchResponse> ServeAsync(CronwatchRequest req, string pathname, string path, string rawQuery, string basePath, bool wantsHtml, CancellationToken ct)
    {
        Said said = Read(req, rawQuery);
        string method = said.Method;
        Announce(said, basePath);

        // The app shell: the manifest, icons, service worker, app.js and the offline page. Served
        // to anyone, since a browser fetches some of it without cookies and none of it says
        // anything about the jobs.
        if (method is "GET" or "HEAD")
        {
            if (path == "/offline")
            {
                return HtmlAnswer(
                    Html.MessagePage("You are offline", "CronWatch shows live data from your app, so it needs a connection.", basePath, false),
                    200,
                    "no-cache");
            }
            if (Pwa.Asset(path, basePath) is { } asset)
            {
                return Shell(asset, basePath);
            }
        }

        // No token outside development: fail closed.
        if (_token.Length == 0 && !_optedOut)
        {
            return wantsHtml
                ? Message(
                    "CronWatch routes are locked",
                    "Set CRONWATCH_TOKEN (or pass RoutesOptions.Token to cw.Routes(), or set Cronwatch:Token in the app's configuration), or pass Token = DashboardToken.None to serve them open behind your own auth.",
                    basePath,
                    503)
                : Api(ErrorBody("CRONWATCH_TOKEN is not set"), 503);
        }

        if (method is not ("GET" or "HEAD") && said.CrossSite)
        {
            return wantsHtml
                ? Message("Cross-site request refused", "Changes can only be made from the dashboard itself.", basePath, 403)
                : Api(ErrorBody("Cross-site request refused"), 403);
        }

        if (_token.Length > 0)
        {
            // ?token= is only the sign-in that moves the token into a cookie.
            string? queryToken = wantsHtml && method == "GET" ? Requests.Param(said.Query, "token") : null;
            string? secret = _cw.CronSecretValue;
            bool cronSecretOk = path == "/api/check" && said.Bearer != null && secret != null && WebText.ConstantTimeEquals(said.Bearer, secret);
            bool tokenOk;
            if (said.Bearer != null)
            {
                tokenOk = WebText.ConstantTimeEquals(said.Bearer, _token);
            }
            else if (queryToken != null)
            {
                tokenOk = WebText.ConstantTimeEquals(queryToken, _token);
            }
            else if (said.Cookie != null)
            {
                tokenOk = WebText.ConstantTimeEquals(said.Cookie, _cookie);
            }
            else
            {
                tokenOk = false;
            }
            if (!cronSecretOk && !tokenOk)
            {
                if (_generated)
                {
                    return wantsHtml
                        ? Message(
                            "Sign in",
                            "CRONWATCH_TOKEN is not set, so this development server made a token. The sign-in link is in the server log: open it once and this browser stays signed in.",
                            basePath,
                            401,
                            true)
                        : Api(ErrorBody("Unauthorized: CRONWATCH_TOKEN is not set, so this development server made a token; it is in the server log"), 401);
                }
                return wantsHtml
                    ? Message("Sign in", "Open this page with ?token=<your CRONWATCH_TOKEN> once and it will stay signed in.", basePath, 401, true)
                    : Api(ErrorBody("Unauthorized"), 401);
            }
            if (queryToken != null)
            {
                // Move the token from the URL into a cookie so it is not in history or logs.
                var rest = new List<string>();
                foreach (var p in said.Query)
                {
                    if (p.Key != "token")
                    {
                        rest.Add(Requests.FormEncode(p.Key) + "=" + Requests.FormEncode(p.Value));
                    }
                }
                string search = rest.Count == 0 ? "" : "?" + string.Join('&', rest);
                string secure = said.PublicOrigin.StartsWith("https:", StringComparison.Ordinal) ? "; Secure" : "";
                string cookiePath = basePath.Length == 0 ? "/" : basePath;
                return Redirect(
                    pathname + search,
                    TokenCookie + "=" + _cookie + "; Path=" + cookiePath + "; HttpOnly; SameSite=Lax; Max-Age=" + CookieMaxAge.ToString(CultureInfo.InvariantCulture) + secure);
            }
        }

        var parts = new List<string>();
        foreach (string part in path.Split('/'))
        {
            if (part.Length == 0)
            {
                continue;
            }
            string? decoded = Requests.SafeDecode(part);
            if (decoded == null)
            {
                return wantsHtml ? Message("Bad request", "The path is not valid.", basePath, 400) : Api(ErrorBody("Bad path"), 400);
            }
            parts.Add(decoded);
        }

        // HTML
        if (method == "GET" && path == "/")
        {
            IReadOnlyList<JobWithRuns> entries = await _cw.JobsWithRunsAsync(BoardPageRuns, ct).ConfigureAwait(false);
            long now = _cw.NowMs;
            var runsByJob = new Dictionary<string, IReadOnlyList<Run>>(StringComparer.Ordinal);
            var jobs = new List<JobSummary>(entries.Count);
            foreach (var e in entries)
            {
                runsByJob[e.Job.Name] = e.Runs;
                jobs.Add(e.Job);
            }
            List<LaneInput> lanes = await BoardLanesAsync(entries, now, ct).ConfigureAwait(false);
            return Page(_cw.Evaluated(() => Html.DashboardPage(jobs, runsByJob, now, basePath, null, lanes)), 200);
        }
        if (method == "GET" && parts.Count == 2 && parts[0] == "jobs")
        {
            string name = parts[1];
            JobSummary? job = await _cw.JobSummaryAsync(name, ct).ConfigureAwait(false);
            if (job == null)
            {
                return Message("No such job", name + " is not in the store.", basePath, 404);
            }
            long now = _cw.NowMs;
            // Enough runs to draw the job's week; the page lists the newest fifty.
            int limit = _cw.Evaluated(() => Timeline.WeekRunsLimit(job, now));
            IReadOnlyList<Run> runs = await _cw.RunsAsync(job.Name, limit, ct).ConfigureAwait(false);
            return Page(_cw.Evaluated(() => Html.JobPage(job, runs, now, basePath, runs.Count < limit)), 200);
        }
        if (method == "POST" && path == "/check")
        {
            await _cw.CheckAsync(ct).ConfigureAwait(false);
            return RedirectBack(said, basePath);
        }
        if (method == "POST" && parts.Count == 3 && parts[0] == "jobs")
        {
            string name = parts[1];
            string action = parts[2];
            if (action == "forget")
            {
                await _cw.ForgetAsync(name, ct).ConfigureAwait(false);
                return Redirect(basePath + "/");
            }
            if (action is not ("silence" or "unsilence"))
            {
                return Message("Not found", path, basePath, 404);
            }
            if (await _cw.JobSummaryAsync(name, ct).ConfigureAwait(false) == null)
            {
                return Message("No such job", name + " is not in the store.", basePath, 404);
            }
            if (action == "silence")
            {
                byte[]? data = await ReadLimitedAsync(req, ct).ConfigureAwait(false);
                if (data == null)
                {
                    return TooLarge(true, basePath);
                }
                string? value = Requests.BodyField(said.ContentType, data, "for");
                double ms;
                try
                {
                    ms = SilenceDuration(value);
                }
                catch (ArgumentException e)
                {
                    return Message("Not silenced", e.Message, basePath, 400);
                }
                await _cw.SilenceAsync(name, ms, ct).ConfigureAwait(false);
            }
            else
            {
                await _cw.UnsilenceAsync(name, ct).ConfigureAwait(false);
            }
            return RedirectBack(said, basePath);
        }

        // JSON API
        if (parts.Count > 0 && parts[0] == "api")
        {
            return await ServeApiAsync(req, method, parts.GetRange(1, parts.Count - 1), said, ct).ConfigureAwait(false);
        }
        return Message("Not found", path, basePath, 404);
    }

    private static CronwatchResponse RedirectBack(Said said, string basePath) =>
        said.Referer.StartsWith(said.PublicOrigin + "/", StringComparison.Ordinal) ? Redirect(said.Referer) : Redirect(basePath + "/");

    /// <summary>
    /// The board's timeline lanes, the first <see cref="Timeline.BoardLanes"/> jobs. The runs
    /// already read for the table usually cover the last day; only a job whose twenty newest runs
    /// all fall inside it is read again, deeper.
    /// </summary>
    private async Task<List<LaneInput>> BoardLanesAsync(IReadOnlyList<JobWithRuns> entries, long now, CancellationToken ct)
    {
        long from = now - Timeline.BoardBehindMs;
        var lanes = new List<LaneInput>();
        for (int i = 0; i < entries.Count && i < Timeline.BoardLanes; i++)
        {
            JobWithRuns e = entries[i];
            var runs = e.Runs;
            bool isShort = runs.Count >= BoardPageRuns && runs[^1].StartedAt > from;
            if (!isShort)
            {
                lanes.Add(new LaneInput(e.Job, runs, true));
                continue;
            }
            IReadOnlyList<Run> deeper = await _cw.RunsAsync(e.Job.Name, Timeline.BoardRuns, ct).ConfigureAwait(false);
            lanes.Add(new LaneInput(e.Job, deeper, deeper.Count < Timeline.BoardRuns));
        }
        return lanes;
    }

    private async Task<CronwatchResponse> ServeApiAsync(CronwatchRequest req, string method, List<string> rest, Said said, CancellationToken ct)
    {
        int n = rest.Count;
        string first = n > 0 ? rest[0] : "";
        // What is serving the API, so a client such as @cronwatch/mcp can tell.
        if (method == "GET" && n == 0)
        {
            return Api(new JsObject().Set("ok", true).Set("library", Library).Set("language", Language).Set("version", CronwatchClient.Version).Set("api", ApiVersion), 200);
        }
        if (method == "GET" && n == 1 && first == "jobs")
        {
            var list = new List<object?>();
            foreach (JobSummary j in await _cw.JobsAsync(ct).ConfigureAwait(false))
            {
                list.Add(j.ToValue());
            }
            return Api(new JsObject().Set("ok", true).Set("jobs", list), 200);
        }
        if (n == 2 && first == "jobs")
        {
            string name = rest[1];
            if (method == "GET")
            {
                JobSummary? job = await _cw.JobSummaryAsync(name, ct).ConfigureAwait(false);
                if (job == null)
                {
                    return Api(ErrorBody("No such job"), 404);
                }
                var runs = new List<object?>();
                foreach (Run r in await _cw.RunsAsync(name, RunsLimit(Requests.Param(said.Query, "runs")), ct).ConfigureAwait(false))
                {
                    runs.Add(r.ToValue());
                }
                return Api(new JsObject().Set("ok", true).Set("job", job.ToValue()).Set("runs", runs), 200);
            }
            if (method == "DELETE")
            {
                if (await _cw.JobSummaryAsync(name, ct).ConfigureAwait(false) == null)
                {
                    return Api(ErrorBody("No such job"), 404);
                }
                await _cw.ForgetAsync(name, ct).ConfigureAwait(false);
                return Api(new JsObject().Set("ok", true), 200);
            }
        }
        if (method == "POST" && n == 3 && first == "jobs")
        {
            string name = rest[1];
            if (await _cw.JobSummaryAsync(name, ct).ConfigureAwait(false) == null)
            {
                return Api(ErrorBody("No such job"), 404);
            }
            string action = rest[2];
            if (action == "silence")
            {
                byte[]? data = await ReadLimitedAsync(req, ct).ConfigureAwait(false);
                if (data == null)
                {
                    return TooLarge(false, "");
                }
                string? value = Requests.BodyField(said.ContentType, data, "for") ?? Requests.Param(said.Query, "for");
                double ms;
                try
                {
                    ms = SilenceDuration(value);
                }
                catch (ArgumentException e)
                {
                    return Api(ErrorBody(e.Message), 400);
                }
                await _cw.SilenceAsync(name, ms, ct).ConfigureAwait(false);
                return Api(new JsObject().Set("ok", true).Set("job", (await _cw.JobSummaryAsync(name, ct).ConfigureAwait(false))?.ToValue()), 200);
            }
            if (action == "unsilence")
            {
                await _cw.UnsilenceAsync(name, ct).ConfigureAwait(false);
                return Api(new JsObject().Set("ok", true).Set("job", (await _cw.JobSummaryAsync(name, ct).ConfigureAwait(false))?.ToValue()), 200);
            }
        }
        if (n == 1 && first == "check")
        {
            // A page cannot send an Authorization header cross-site, so a GET may only run the
            // check when it carries a bearer (token or cron secret).
            if (method == "GET" && said.Bearer == null)
            {
                return Api(ErrorBody("Use POST, or GET with an Authorization bearer"), 405, "allow", "POST");
            }
            if (method is "GET" or "POST")
            {
                CheckResult result = await _cw.CheckAsync(ct).ConfigureAwait(false);
                var body = new JsObject().Set("ok", true);
                foreach (var e in result.ToValue())
                {
                    body.Set(e.Key, e.Value);
                }
                return Api(body, 200);
            }
        }
        if (method == "GET" && n == 2 && first == "runs")
        {
            Run? run = await _cw.GetRunAsync(rest[1], ct).ConfigureAwait(false);
            return run != null ? Api(new JsObject().Set("ok", true).Set("run", run.ToValue()), 200) : Api(ErrorBody("No such run"), 404);
        }
        return Api(ErrorBody("Not found"), 404);
    }
}
